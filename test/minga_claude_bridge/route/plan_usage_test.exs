defmodule MingaClaudeBridge.Route.PlanUsageTest do
  use ExUnit.Case, async: true

  alias MingaAgent.InferenceRoute.PlanWindow
  alias MingaClaudeBridge.Route.PlanUsage
  alias MingaClaudeBridge.Wire.RateLimit

  defp window(percent, locked \\ nil, resets_at \\ "2026-11-21T20:00:00.123456+00:00"),
    do: %{"utilization" => percent, "resets_at" => resets_at, "locked_reason" => locked}

  defp answer(rate_limits), do: %{"subscription_type" => "max", "rate_limits" => rate_limits}

  test "maps percent utilization, reset times, and status" do
    windows =
      PlanUsage.from_get_usage(
        answer(%{
          "five_hour" => window(79),
          "seven_day" => window(80),
          "seven_day_sonnet" => window(100, nil, nil),
          "seven_day_opus" => window(10, "spend_limit"),
          "seven_day_oauth_apps" => nil,
          "seven_day_breakdown" => %{"as_of" => "x", "rows" => []},
          "extra_usage" => %{"utilization" => nil},
          "tangelo" => window(50)
        })
      )

    assert Enum.map(PlanUsage.to_list(windows), &{&1.kind, &1.utilization, &1.status}) == [
             {"five_hour", 0.79, :allowed},
             {"seven_day", 0.8, :warning},
             {"seven_day_opus", 0.1, :rejected},
             {"seven_day_sonnet", 1.0, :rejected}
           ]

    assert %PlanWindow{resets_at: %DateTime{year: 2026, month: 11, day: 21, hour: 20}} =
             windows["five_hour"]

    assert windows["seven_day_sonnet"].resets_at == nil
  end

  test "clamps utilization above 100 percent and ignores answers without rate limits" do
    assert %{"five_hour" => %PlanWindow{utilization: 1.0, status: :rejected}} =
             PlanUsage.from_get_usage(answer(%{"five_hour" => window(104)}))

    assert PlanUsage.from_get_usage(%{"rate_limits_available" => false}) == %{}
  end

  test "reads the plan label from subscription_type" do
    assert PlanUsage.plan_label(answer(%{})) == "Claude Max"
    assert PlanUsage.plan_label(%{}) == nil
  end

  test "a rate-limit event sets status and reset time and keeps utilization" do
    windows = PlanUsage.from_get_usage(answer(%{"five_hour" => window(85)}))
    event = %RateLimit{status: :rejected, rate_limit_type: :five_hour, resets_at: 1_900_000_000}

    assert %{
             "five_hour" => %PlanWindow{
               utilization: 0.85,
               status: :rejected,
               resets_at: resets_at
             }
           } =
             PlanUsage.apply_rate_limit(windows, event)

    assert DateTime.to_unix(resets_at) == 1_900_000_000

    assert %{"seven_day" => %PlanWindow{utilization: 0.0, status: :warning}} =
             PlanUsage.apply_rate_limit(%{}, %RateLimit{
               status: :allowed_warning,
               rate_limit_type: :seven_day
             })

    assert PlanUsage.apply_rate_limit(windows, %RateLimit{status: :allowed}) == windows
  end
end
