defmodule MingaClaudeBridge.Status do
  @moduledoc """
  Holds the route's last known readiness and plan limits, and reports changes to Minga.

    * Availability results are cached per credential for a short time, so opening `/model` repeatedly does not start Claude Code every time.
    * Sessions send their `rate_limit_event`s here. A `rejected` status reports the route as `{:unavailable, :rate_limited, remedy}` with the reset time; the next allowed status reports it ready again with the last plan label.
    * Plan windows (`MingaAgent.InferenceRoute.PlanWindow`) come from `get_usage` answers (`put_usage/2`) and rate-limit events, merged by `MingaClaudeBridge.Route.PlanUsage`. Every change is reported with `Minga.Extension.ModelRoutes.report_usage/2`.
    * The models of the last probe and the measured context windows feed `MingaClaudeBridge.Route.models/1`. Windows are cached per credential and model with their measurement time.
    * Background measurements run under a `Task.Supervisor`, at most one per credential at a time (`start_measurement/3`).

  Reports go through the reporter `MingaClaudeBridge` received when it registered the route. The reporter and both report functions are options so tests can observe reports.
  """

  use GenServer

  alias MingaClaudeBridge.Route.PlanUsage
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

  Options: `:name`, `:reporter` (defaults to the stored reporter), `:report` (a two-argument function, defaults to `Minga.Extension.ModelRoutes.report_status/2`), `:report_usage` (a two-argument function, defaults to `Minga.Extension.ModelRoutes.report_usage/2`), `:tasks` (the `Task.Supervisor` for measurements; without it no measurement starts), and `:notify` (a pid that receives `{:claude_bridge_measurement, :started | :finished, key}`, for tests).
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

  @doc "Returns the model entries of Claude Code's last `initialize` answer, or `nil` before the first probe or when the server is not running."
  @spec models(GenServer.server()) :: [map()] | nil
  def models(server), do: call(server, :models, nil)

  @doc "Records the model entries of a probe."
  @spec put_models(GenServer.server(), [map()]) :: :ok
  def put_models(server, models) when is_list(models),
    do: call(server, {:put_models, models}, :ok)

  @doc "Returns the most recently measured context window in tokens per model id, across credentials. Empty before the first measurement."
  @spec context_windows(GenServer.server()) :: %{String.t() => pos_integer()}
  def context_windows(server), do: call(server, :context_windows, %{})

  @doc "Records the context windows measured for credential `key`. Models it could not measure keep their earlier value."
  @spec put_context_windows(GenServer.server(), term(), %{String.t() => pos_integer()}) :: :ok
  def put_context_windows(server, key, windows) when is_map(windows),
    do: call(server, {:put_context_windows, key, windows}, :ok)

  @doc "Returns the ids among `model_ids` whose window for credential `key` is missing or older than `ttl` milliseconds."
  @spec stale_models(GenServer.server(), term(), [String.t()], non_neg_integer()) :: [String.t()]
  def stale_models(server, key, model_ids, ttl),
    do: call(server, {:stale_models, key, model_ids, ttl}, model_ids)

  @doc """
  Starts `fun` as the background measurement for credential `key` under the task supervisor. Returns `:busy` while a measurement for `key` runs and `:unavailable` without a task supervisor.
  """
  @spec start_measurement(GenServer.server(), term(), (-> term())) :: :ok | :busy | :unavailable
  def start_measurement(server, key, fun) when is_function(fun, 0),
    do: call(server, {:start_measurement, key, fun}, :unavailable)

  @doc "Returns the plan label of the last `get_usage` answer, for example \"Claude Max\", or `nil`."
  @spec usage_label(GenServer.server()) :: String.t() | nil
  def usage_label(server), do: call(server, :usage_label, nil)

  @doc "Records a `get_usage` answer: refreshes every plan window and reports them."
  @spec put_usage(GenServer.server(), map()) :: :ok
  def put_usage(server, answer) when is_map(answer), do: call(server, {:put_usage, answer}, :ok)

  @doc "Returns the current plan windows in display order."
  @spec plan_windows(GenServer.server()) :: [MingaAgent.InferenceRoute.PlanWindow.t()]
  def plan_windows(server), do: call(server, :plan_windows, [])

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
       rate_limit: nil,
       models: nil,
       context_windows: %{},
       windows: %{},
       usage_label: nil,
       measuring: %{},
       tasks: Keyword.get(opts, :tasks),
       notify: Keyword.get(opts, :notify),
       report_usage: Keyword.get(opts, :report_usage, &default_report_usage/2)
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
  def handle_call(:models, _from, state), do: {:reply, state.models, state}

  def handle_call({:put_models, models}, _from, state),
    do: {:reply, :ok, %{state | models: models}}

  def handle_call(:context_windows, _from, state) do
    latest =
      state.context_windows
      |> Enum.sort_by(fn {_key_and_model, {_tokens, at}} -> at end)
      |> Map.new(fn {{_key, model}, {tokens, _at}} -> {model, tokens} end)

    {:reply, latest, state}
  end

  def handle_call({:put_context_windows, key, windows}, _from, state) do
    now = System.monotonic_time(:millisecond)
    measured = Map.new(windows, fn {model, tokens} -> {{key, model}, {tokens, now}} end)
    {:reply, :ok, %{state | context_windows: Map.merge(state.context_windows, measured)}}
  end

  def handle_call({:stale_models, key, model_ids, ttl}, _from, state) do
    now = System.monotonic_time(:millisecond)

    stale =
      Enum.reject(model_ids, fn model ->
        case Map.get(state.context_windows, {key, model}) do
          {_tokens, at} -> now - at < ttl
          nil -> false
        end
      end)

    {:reply, stale, state}
  end

  def handle_call({:start_measurement, _key, _fun}, _from, %{tasks: nil} = state),
    do: {:reply, :unavailable, state}

  def handle_call({:start_measurement, key, fun}, _from, state) do
    if Map.has_key?(state.measuring, key) do
      {:reply, :busy, state}
    else
      {:ok, pid} = Task.Supervisor.start_child(state.tasks, fun)
      monitor = Process.monitor(pid)
      notify(state, {:claude_bridge_measurement, :started, key})
      {:reply, :ok, %{state | measuring: Map.put(state.measuring, key, monitor)}}
    end
  end

  def handle_call(:usage_label, _from, state), do: {:reply, state.usage_label, state}

  def handle_call({:put_usage, answer}, _from, state) do
    state = %{state | windows: PlanUsage.from_get_usage(answer)}
    report_windows(state)
    {:reply, :ok, adopt_usage_label(state, PlanUsage.plan_label(answer))}
  end

  def handle_call(:plan_windows, _from, state),
    do: {:reply, PlanUsage.to_list(state.windows), state}

  @impl true
  def handle_cast({:rate_limit, rate_limit}, state), do: {:noreply, record(state, rate_limit)}

  @impl true
  def handle_info({:claude_bridge_rate_limit, _session, %RateLimit{} = rate_limit}, state),
    do: {:noreply, record(state, rate_limit)}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.measuring, fn {_key, ref} -> ref == monitor end) do
      {key, _ref} ->
        notify(state, {:claude_bridge_measurement, :finished, key})
        {:noreply, %{state | measuring: Map.delete(state.measuring, key)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp notify(%{notify: pid}, message) when is_pid(pid), do: send(pid, message)
  defp notify(_state, _message), do: :ok

  # The account answer may lack a plan name. When usage names the plan, a ready route reports it.
  defp adopt_usage_label(state, nil), do: state

  defp adopt_usage_label(%{label: label, limited: false} = state, usage_label)
       when label in [nil, "Claude Code"] do
    report(state, {:ready, usage_label})
    %{state | usage_label: usage_label, label: usage_label, cache: %{}}
  end

  defp adopt_usage_label(state, usage_label), do: %{state | usage_label: usage_label}

  defp record(state, %RateLimit{} = rate_limit) do
    state = %{
      state
      | rate_limit: rate_limit,
        windows: PlanUsage.apply_rate_limit(state.windows, rate_limit)
    }

    if rate_limit.rate_limit_type != nil, do: report_windows(state)
    availability(state, rate_limit)
  end

  defp availability(state, %RateLimit{status: :rejected} = rate_limit) do
    if state.limited do
      state
    else
      report(state, {:unavailable, :rate_limited, limit_remedy(rate_limit.resets_at)})
      %{state | limited: true, cache: %{}}
    end
  end

  defp availability(state, %RateLimit{}) do
    if state.limited do
      report(state, {:ready, state.label || "Claude Code"})
      %{state | limited: false, cache: %{}}
    else
      state
    end
  end

  defp report_windows(%{reporter: nil}), do: :ok
  defp report_windows(%{windows: windows}) when map_size(windows) == 0, do: :ok

  defp report_windows(%{reporter: reporter, report_usage: report_usage, windows: windows}) do
    report_usage.(reporter, PlanUsage.to_list(windows))
  rescue
    _error -> :ok
  end

  defp default_report_usage(reporter, windows) do
    module = Minga.Extension.ModelRoutes

    if Code.ensure_loaded?(module) and function_exported?(module, :report_usage, 2),
      do: module.report_usage(reporter, windows)
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
