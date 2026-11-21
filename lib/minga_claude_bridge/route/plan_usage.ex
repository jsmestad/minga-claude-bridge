defmodule MingaClaudeBridge.Route.PlanUsage do
  @moduledoc """
  Converts Claude Code's plan-usage data to Minga's `MingaAgent.InferenceRoute.PlanWindow` values.

  Two sources describe the same windows:

    * The `get_usage` control request answers with `rate_limits`, where each window (`five_hour`, `seven_day`, and `seven_day_*` variants such as `seven_day_opus`) is either `null` or an object with `utilization` as a percent from 0 to 100, `resets_at` as an ISO 8601 string, and `locked_reason`. `from_get_usage/1` reads every non-null window. Its status is `:rejected` when `locked_reason` is set or utilization reaches 100%, `:warning` from 80%, and `:allowed` below.
    * A `rate_limit_event` during a turn reports one window's status and reset time. `apply_rate_limit/2` updates that window's status and reset time and keeps its last known utilization.

  The latest source wins for the fields it carries. `get_usage` refreshes every window; a `rate_limit_event` refreshes one window's status. Account data never passes through this module.
  """

  alias MingaAgent.InferenceRoute.PlanWindow
  alias MingaClaudeBridge.Wire.RateLimit

  @warning_percent 80
  @kind_order ["five_hour", "seven_day"]

  @typedoc "Windows keyed by kind."
  @type windows :: %{String.t() => PlanWindow.t()}

  @doc "Reads the plan windows of a `get_usage` answer."
  @spec from_get_usage(map()) :: windows()
  def from_get_usage(%{"rate_limits" => %{} = rate_limits}) do
    for {kind, %{"utilization" => percent} = window} <- rate_limits,
        window_kind?(kind),
        is_number(percent),
        into: %{} do
      {kind,
       %PlanWindow{
         kind: kind,
         utilization: min(max(percent, 0), 100) / 100,
         resets_at: parse_time(Map.get(window, "resets_at")),
         status: usage_status(percent, Map.get(window, "locked_reason"))
       }}
    end
  end

  def from_get_usage(_answer), do: %{}

  @doc ~S(Returns the plan label of a `get_usage` answer, for example "Claude Max" for "max", or `nil`.)
  @spec plan_label(map() | nil) :: String.t() | nil
  def plan_label(%{"subscription_type" => type}) when is_binary(type) and type != "",
    do: "Claude " <> String.capitalize(type)

  def plan_label(_answer), do: nil

  @doc "Updates the window a `rate_limit_event` describes. Events without a window type change nothing."
  @spec apply_rate_limit(windows(), RateLimit.t()) :: windows()
  def apply_rate_limit(windows, %RateLimit{rate_limit_type: nil}), do: windows

  def apply_rate_limit(windows, %RateLimit{} = event) do
    kind = event_kind(event.rate_limit_type)
    previous = Map.get(windows, kind)
    status = event_status(event.status, previous)

    window = %PlanWindow{
      kind: kind,
      utilization: event_utilization(previous, status),
      resets_at: event_resets_at(event.resets_at, previous),
      status: status
    }

    Map.put(windows, kind, window)
  end

  @doc "Returns the windows in display order: five-hour, seven-day, then the others by kind."
  @spec to_list(windows()) :: [PlanWindow.t()]
  def to_list(windows) do
    windows
    |> Map.values()
    |> Enum.sort_by(fn %PlanWindow{kind: kind} ->
      {Enum.find_index(@kind_order, &(&1 == kind)) || length(@kind_order), kind}
    end)
  end

  defp window_kind?(kind) when kind in @kind_order, do: true
  defp window_kind?("seven_day_" <> _variant), do: true
  defp window_kind?(_other), do: false

  defp usage_status(_percent, locked) when is_binary(locked) and locked != "", do: :rejected
  defp usage_status(percent, _locked) when percent >= 100, do: :rejected
  defp usage_status(percent, _locked) when percent >= @warning_percent, do: :warning
  defp usage_status(_percent, _locked), do: :allowed

  defp parse_time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> nil
    end
  end

  defp parse_time(_none), do: nil

  defp event_kind({:other, kind}), do: kind
  defp event_kind(kind) when is_atom(kind), do: Atom.to_string(kind)

  defp event_status(:allowed, _previous), do: :allowed
  defp event_status(:allowed_warning, _previous), do: :warning
  defp event_status(:rejected, _previous), do: :rejected
  defp event_status({:other, _status}, %PlanWindow{status: status}), do: status
  defp event_status({:other, _status}, nil), do: :allowed

  defp event_utilization(%PlanWindow{utilization: utilization}, _status), do: utilization
  defp event_utilization(nil, :rejected), do: 1.0
  defp event_utilization(nil, _status), do: 0.0

  defp event_resets_at(seconds, _previous) when is_number(seconds) do
    case DateTime.from_unix(trunc(seconds)) do
      {:ok, at} -> at
      {:error, _reason} -> nil
    end
  end

  defp event_resets_at(nil, %PlanWindow{resets_at: resets_at}), do: resets_at
  defp event_resets_at(nil, nil), do: nil
end
