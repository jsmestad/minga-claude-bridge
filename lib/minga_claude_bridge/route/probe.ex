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
  Runs one probe with the route credential's `env`. Returns `{:ok, info}` (see `MingaClaudeBridge.Session.info/1`) or `{:error, reason}`, where `reason` is the transport start error (for example `:claude_not_found`), the session's death reason (for example `{:unsupported_version, v}`), or `:timeout`.
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

    case Session.start(opts) do
      {:ok, session} ->
        result = await(session, config.probe_timeout + 1_000)
        stop(session)
        result

      {:error, {:transport_start_failed, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Returns true when Claude Code's `initialize` account reports a sign-in."
  @spec signed_in?(map() | nil) :: boolean()
  def signed_in?(%{"tokenSource" => "none"}), do: false
  def signed_in?(account) when is_map(account) and map_size(account) > 0, do: true
  def signed_in?(_none), do: false

  @doc "Returns the plan label for a signed-in account, never the email."
  @spec plan_label(map()) :: String.t()
  def plan_label(%{"subscriptionType" => plan}) when is_binary(plan) and plan != "", do: plan
  def plan_label(_account), do: "Claude Code"

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
