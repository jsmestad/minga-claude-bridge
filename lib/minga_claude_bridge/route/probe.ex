defmodule MingaClaudeBridge.Route.Probe do
  @moduledoc """
  Starts Claude Code without a prompt to read its `initialize` answer: the account, the models, and the version. No model request is made.

  The probe session is not linked to the caller and stops when the caller exits, so a caller killed at a deadline leaves no `claude` process behind.

  ## Sign-in state

  Claude Code 2.1.330 answers `initialize` whether or not it is signed in. Signed out, `account` holds only `"tokenSource": "none"` and `"apiProvider"`. Signed in through `claude auth login`, `account` carries `subscriptionType` (for example `"Claude Pro"`) and the email. `signed_in?/1` treats a missing account or `"tokenSource": "none"` as signed out. This was checked with an empty `CLAUDE_CONFIG_DIR` and no token, which never touches the user's own login.
  """

  alias MingaClaudeBridge.{Launch, Session}
  alias MingaClaudeBridge.Route.{Config, PlanUsage}

  @doc """
  Runs one probe with the route credential's `env`. Returns `{:ok, info}`, where `info` is `MingaClaudeBridge.Session.info/1` plus the `:usage` and `:context_windows` of `measure/3`, or `{:error, reason}`, where `reason` is the transport start error (for example `:claude_not_found`), the session's death reason (for example `{:unsupported_version, v}`), or `:timeout`.
  """
  @spec run(Config.t(), %{optional(String.t()) => String.t()}) ::
          {:ok, MingaClaudeBridge.Session.State.info()} | {:error, term()}
  def run(%Config{} = config, credential_env) do
    {transport, transport_opts} = config.transport

    opts = [
      transport:
        {transport,
         Keyword.merge(transport_opts,
           credential_env: credential_env,
           session_key: "probe-" <> MingaClaudeBridge.Workdir.random_key()
         )},
      tools: [],
      min_version: Launch.min_version(),
      persist_session: false,
      owner: self(),
      idle_timeout: :infinity,
      startup_timeout: config.probe_timeout
    ]

    started = System.monotonic_time(:millisecond)

    case Session.start(opts) do
      {:ok, session} ->
        result =
          case await(session, config.probe_timeout + 1_000) do
            {:ok, info} -> {:ok, measure(session, info, measure_timeout(config, started))}
            {:error, _reason} = error -> error
          end

        stop(session)
        result

      {:error, {:transport_start_failed, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Reads what `initialize` does not report, through control requests on the idle probe session, within one deadline of `timeout` milliseconds:

    * `usage` - the `get_usage` answer (with `skip_behaviors: true`), or `nil`. It holds the plan's rate-limit windows and `subscription_type`.
    * `context_windows` - `rawMaxTokens` from `get_context_usage` (with `detail: "summary"`, which uses local estimates and calls no API) after `set_model` for each model id. Models not measured before the deadline are left out.

  Any failure or timeout only leaves data out. Readiness always comes from `initialize` alone.
  """
  @spec measure(GenServer.server(), map(), non_neg_integer()) :: map()
  def measure(session, info, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    usage =
      case control(session, %{"subtype" => "get_usage", "skip_behaviors" => true}, deadline) do
        {:ok, answer} -> answer
        {:error, _reason} -> nil
      end

    model_ids = for %{"value" => id} <- Map.get(info, :models, []), is_binary(id), do: id

    windows =
      Enum.reduce_while(model_ids, %{}, fn id, windows ->
        case context_window(session, id, deadline) do
          {:ok, tokens} -> {:cont, Map.put(windows, id, tokens)}
          :skip -> {:cont, windows}
          :stop -> {:halt, windows}
        end
      end)

    Map.merge(info, %{usage: usage, context_windows: windows})
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

  # Minga gives an availability check 5 s, and Claude Code itself takes about 2-3 s to start.
  # Measuring never runs past the probe budget, so it cannot cost the route its readiness.
  defp measure_timeout(config, started) do
    remaining = started + config.probe_budget - System.monotonic_time(:millisecond)
    max(0, min(config.measure_timeout, remaining))
  end

  @doc "Returns true when Claude Code's `initialize` account reports a sign-in."
  @spec signed_in?(map() | nil) :: boolean()
  def signed_in?(%{"tokenSource" => "none"}), do: false
  def signed_in?(account) when is_map(account) and map_size(account) > 0, do: true
  def signed_in?(_none), do: false

  @doc """
  Returns the plan label for a signed-in account, never the email: the account's `subscriptionType`, else the `subscription_type` of a `get_usage` answer, else "Claude Code".
  """
  @spec plan_label(map(), map() | nil) :: String.t()
  def plan_label(account, usage \\ nil)

  def plan_label(%{"subscriptionType" => plan}, _usage) when is_binary(plan) and plan != "",
    do: plan

  def plan_label(_account, usage),
    do: PlanUsage.plan_label(usage) || "Claude Code"

  defp await(session, timeout) do
    Session.await_ready(session, timeout)
  catch
    :exit, _reason -> {:error, :timeout}
  end

  defp stop(session) do
    GenServer.stop(session, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end
end
