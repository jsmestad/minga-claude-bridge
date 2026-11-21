defmodule MingaClaudeBridge.Route.Probe do
  @moduledoc """
  Starts Claude Code without a prompt to read its `initialize` answer: the account, the models, and the version. No model request is made.

  The probe session is not linked to the caller and stops when the caller exits, so a caller killed at a deadline leaves no `claude` process behind.

  ## Sign-in state

  Claude Code 2.1.330 answers `initialize` whether or not it is signed in. Signed out, `account` holds only `"tokenSource": "none"` and `"apiProvider"`. Signed in through `claude auth login`, `account` carries `subscriptionType` (for example `"Claude Pro"`) and the email. `signed_in?/1` treats a missing account or `"tokenSource": "none"` as signed out. This was checked with an empty `CLAUDE_CONFIG_DIR` and no token, which never touches the user's own login.
  """

  alias MingaClaudeBridge.{Launch, Session}
  alias MingaClaudeBridge.Route.Config

  @doc """
  Runs one readiness probe with the route credential's `env` and stops it. Returns `{:ok, info}` (see `MingaClaudeBridge.Session.info/1`) as soon as Claude Code answers `initialize`, or `{:error, reason}`, where `reason` is the transport start error (for example `:claude_not_found`), the session's death reason (for example `{:unsupported_version, v}`), or `:timeout`.
  """
  @spec run(Config.t(), %{optional(String.t()) => String.t()}) ::
          {:ok, MingaClaudeBridge.Session.State.info()} | {:error, term()}
  def run(%Config{} = config, credential_env) do
    case start_ready(config, credential_env, "probe-") do
      {:ok, session, info} ->
        stop(session)
        {:ok, info}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Starts a probe session owned by the caller and waits for `initialize`. Returns `{:ok, session, info}`; the caller stops the session (`stop/1`), and the session also stops when the caller exits.
  """
  @spec start_ready(Config.t(), %{optional(String.t()) => String.t()}, String.t()) ::
          {:ok, pid(), MingaClaudeBridge.Session.State.info()} | {:error, term()}
  def start_ready(%Config{} = config, credential_env, key_prefix) do
    {transport, transport_opts} = config.transport

    opts = [
      transport:
        {transport,
         Keyword.merge(transport_opts,
           credential_env: credential_env,
           session_key: key_prefix <> MingaClaudeBridge.Workdir.random_key()
         )},
      tools: [],
      min_version: Launch.min_version(),
      persist_session: false,
      owner: self(),
      idle_timeout: :infinity,
      startup_timeout: config.probe_timeout
    ]

    case Session.start(opts) do
      {:ok, session} ->
        case await(session, config.probe_timeout + 1_000) do
          {:ok, info} ->
            {:ok, session, info}

          {:error, _reason} = error ->
            stop(session)
            error
        end

      {:error, {:transport_start_failed, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Reads plan usage through `get_usage` (with `skip_behaviors: true`) on an idle probe session, until `deadline` (a `System.monotonic_time(:millisecond)` value). The answer holds the plan's rate-limit windows and `subscription_type`. Returns `nil` on any failure.

  This and `context_windows/3` never run on the availability path; see `MingaClaudeBridge.Route`.
  """
  @spec usage(GenServer.server(), integer()) :: map() | nil
  def usage(session, deadline) do
    case control(session, %{"subtype" => "get_usage", "skip_behaviors" => true}, deadline) do
      {:ok, answer} -> answer
      {:error, _reason} -> nil
    end
  end

  @doc """
  Measures `rawMaxTokens` with `get_context_usage` (with `detail: "summary"`, which uses local estimates and calls no API) after `set_model`, for each id in `model_ids`, until `deadline`. Returns model id to tokens; models not measured before the deadline, or that fail, are left out.
  """
  @spec context_windows(GenServer.server(), [String.t()], integer()) :: %{
          String.t() => pos_integer()
        }
  def context_windows(session, model_ids, deadline) do
    Enum.reduce_while(model_ids, %{}, fn id, windows ->
      case context_window(session, id, deadline) do
        {:ok, tokens} -> {:cont, Map.put(windows, id, tokens)}
        :skip -> {:cont, windows}
        :stop -> {:halt, windows}
      end
    end)
  end

  defp context_window(session, model_id, deadline) do
    with {:ok, _set} <-
           control(session, %{"subtype" => "set_model", "model" => model_id}, deadline),
         {:ok, %{"rawMaxTokens" => tokens}} when is_integer(tokens) and tokens > 0 <-
           control(session, %{"subtype" => "get_context_usage", "detail" => "summary"}, deadline) do
      {:ok, tokens}
    else
      {:error, reason} when reason in [:timeout, :deadline] -> :stop
      {:error, {:invalid_phase, _tag}} -> :stop
      {:error, :session_down} -> :stop
      _other -> :skip
    end
  end

  defp control(session, request, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> Session.control(session, request, remaining)
      _passed -> {:error, :deadline}
    end
  end

  @doc "Returns true when Claude Code's `initialize` account reports a sign-in."
  @spec signed_in?(map() | nil) :: boolean()
  def signed_in?(%{"tokenSource" => "none"}), do: false
  def signed_in?(account) when is_map(account) and map_size(account) > 0, do: true
  def signed_in?(_none), do: false

  @doc """
  Returns the plan label for a signed-in account, never the email: the account's `subscriptionType`, else `usage_label` (the plan named by the last `get_usage` answer, see `MingaClaudeBridge.Route.PlanUsage.plan_label/1`), else "Claude Code".
  """
  @spec plan_label(map(), String.t() | nil) :: String.t()
  def plan_label(account, usage_label \\ nil)

  def plan_label(%{"subscriptionType" => plan}, _usage_label) when is_binary(plan) and plan != "",
    do: plan

  def plan_label(_account, usage_label) when is_binary(usage_label), do: usage_label
  def plan_label(_account, nil), do: "Claude Code"

  defp await(session, timeout) do
    Session.await_ready(session, timeout)
  catch
    :exit, _reason -> {:error, :timeout}
  end

  @doc "Stops a probe session. Safe when it already stopped."
  @spec stop(GenServer.server()) :: :ok
  def stop(session) do
    GenServer.stop(session, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end
end
