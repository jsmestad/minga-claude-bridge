defmodule MingaClaudeBridge.Status do
  @moduledoc """
  Holds the route's last known readiness and plan limits, and reports changes to Minga.

    * Availability results are cached per credential for a short time, so opening `/model` repeatedly does not start Claude Code every time.
    * Sessions send their `rate_limit_event`s here. A `rejected` status reports the route as `{:unavailable, :rate_limited, remedy}` with the reset time; the next allowed status reports it ready again with the last plan label. Minga's `Status` has no plan-usage field yet (jsmestad/minga-claude-bridge#4), so utilization stays here, available through `latest_rate_limit/1`.

  Reports go through the reporter `MingaClaudeBridge` received when it registered the route, using `Minga.Extension.ModelRoutes.report_status/2`. Both are options so tests can observe reports.
  """

  use GenServer

  alias MingaClaudeBridge.Wire.RateLimit

  @reporter_key {MingaClaudeBridge, :reporter}

  @type availability ::
          {:ready, String.t()} | {:unavailable, atom(), String.t()}

  @type report_fun :: (term(), availability() -> term())

  @doc "Stores the reporter from route registration for every later status server."
  @spec put_reporter(term()) :: :ok
  def put_reporter(reporter), do: :persistent_term.put(@reporter_key, reporter)

  @doc """
  Starts the status server.

  Options: `:name`, `:reporter` (defaults to the stored reporter), and `:report` (a two-argument function, defaults to `Minga.Extension.ModelRoutes.report_status/2`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, name_opts)
  end

  @doc "Returns a cached availability for `key` when it is younger than `ttl` milliseconds."
  @spec cached(GenServer.server(), term(), non_neg_integer()) :: {:ok, availability()} | :miss
  def cached(server, key, ttl), do: call(server, {:cached, key, ttl}, :miss)

  @doc "Caches an availability result for `key`."
  @spec put(GenServer.server(), term(), availability()) :: :ok
  def put(server, key, availability), do: call(server, {:put, key, availability}, :ok)

  @doc "Returns the latest rate-limit event, or `nil`."
  @spec latest_rate_limit(GenServer.server()) :: RateLimit.t() | nil
  def latest_rate_limit(server), do: call(server, :latest_rate_limit, nil)

  @doc "Records a rate-limit event, as sessions do with their `:on_rate_limit` pid."
  @spec rate_limit(GenServer.server(), RateLimit.t()) :: :ok
  def rate_limit(server, %RateLimit{} = rate_limit) do
    GenServer.cast(server, {:rate_limit, rate_limit})
  end

  @doc "Returns the remedy text for a reached plan limit."
  @spec limit_remedy(number() | nil) :: String.t()
  def limit_remedy(nil),
    do: "Your Claude plan limit is reached. Wait for it to reset, then try again."

  def limit_remedy(resets_at) when is_number(resets_at) do
    at = resets_at |> trunc() |> DateTime.from_unix!() |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
    "Your Claude plan limit is reached. It resets at #{at}."
  end

  defp call(server, message, fallback) do
    GenServer.call(server, message)
  catch
    :exit, _reason -> fallback
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       reporter:
         Keyword.get_lazy(opts, :reporter, fn -> :persistent_term.get(@reporter_key, nil) end),
       report: Keyword.get(opts, :report, &default_report/2),
       cache: %{},
       label: nil,
       limited: false,
       rate_limit: nil
     }}
  end

  @impl true
  def handle_call({:cached, key, ttl}, _from, state) do
    now = System.monotonic_time(:millisecond)

    reply =
      case Map.get(state.cache, key) do
        {availability, at} when now - at <= ttl -> {:ok, availability}
        _missing_or_old -> :miss
      end

    {:reply, reply, state}
  end

  def handle_call({:put, key, availability}, _from, state) do
    cache = Map.put(state.cache, key, {availability, System.monotonic_time(:millisecond)})

    label =
      case availability do
        {:ready, label} -> label
        _unavailable -> state.label
      end

    {:reply, :ok, %{state | cache: cache, label: label}}
  end

  def handle_call(:latest_rate_limit, _from, state), do: {:reply, state.rate_limit, state}

  @impl true
  def handle_cast({:rate_limit, rate_limit}, state), do: {:noreply, record(state, rate_limit)}

  @impl true
  def handle_info({:claude_bridge_rate_limit, _session, %RateLimit{} = rate_limit}, state),
    do: {:noreply, record(state, rate_limit)}

  def handle_info(_other, state), do: {:noreply, state}

  defp record(state, %RateLimit{status: :rejected} = rate_limit) do
    state = %{state | rate_limit: rate_limit}

    if state.limited do
      state
    else
      report(state, {:unavailable, :rate_limited, limit_remedy(rate_limit.resets_at)})
      %{state | limited: true, cache: %{}}
    end
  end

  defp record(state, %RateLimit{} = rate_limit) do
    state = %{state | rate_limit: rate_limit}

    if state.limited do
      report(state, {:ready, state.label || "Claude Code"})
      %{state | limited: false, cache: %{}}
    else
      state
    end
  end

  defp report(%{reporter: nil}, _availability), do: :ok

  defp report(%{reporter: reporter, report: report}, availability) do
    report.(reporter, availability)
  rescue
    _error -> :ok
  end

  defp default_report(reporter, availability) do
    module = Minga.Extension.ModelRoutes
    if Code.ensure_loaded?(module), do: module.report_status(reporter, availability)
  end
end
