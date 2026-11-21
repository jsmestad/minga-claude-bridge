defmodule MingaClaudeBridge.Route.Config do
  @moduledoc """
  The processes and settings `MingaClaudeBridge.Route` uses.

  Minga calls the route callbacks without any bridge-specific argument, so `load/1` starts from the defaults below, applies the `:minga_claude_bridge, :route` application environment, then the given overrides. Tests pass a config directly to `MingaClaudeBridge.Route.stream/2` and `MingaClaudeBridge.Route.availability/3` to use the scripted transport and per-test processes.

    * `:transport` - `{module, opts}` for every session. Defaults to the real `claude` Port.
    * `:registry`, `:supervisor`, `:status` - the conversation registry, the session supervisor, and the status server started by `MingaClaudeBridge.Supervisor`.
    * `:session_opts` - extra `MingaClaudeBridge.Session` options, for example `:idle_timeout`.
    * `:probe_timeout` - milliseconds a probe waits for Claude Code's `initialize` answer.
    * `:measure_deadline` - milliseconds a background measurement (plan usage and context windows) may run, including its own Claude Code startup.
    * `:window_ttl` - milliseconds a measured context window stays fresh. Defaults to 24 hours.
    * `:availability_ttl` - milliseconds an availability result is reused.
  """

  @type t :: %__MODULE__{
          transport: {module(), keyword()},
          registry: atom(),
          supervisor: GenServer.server(),
          status: GenServer.server(),
          session_opts: keyword(),
          probe_timeout: pos_integer(),
          measure_deadline: pos_integer(),
          window_ttl: non_neg_integer(),
          availability_ttl: non_neg_integer()
        }

  defstruct transport: {MingaClaudeBridge.Transport.Port, []},
            registry: MingaClaudeBridge.Registry,
            supervisor: MingaClaudeBridge.SessionSupervisor,
            status: MingaClaudeBridge.Status,
            session_opts: [],
            probe_timeout: 4_000,
            measure_deadline: 10_000,
            window_ttl: 24 * 60 * 60 * 1000,
            availability_ttl: 30_000

  @doc "Builds the config from the defaults, the application environment, and `overrides`."
  @spec load(keyword()) :: t()
  def load(overrides \\ []) do
    struct!(
      __MODULE__,
      Keyword.merge(Application.get_env(:minga_claude_bridge, :route, []), overrides)
    )
  end
end
