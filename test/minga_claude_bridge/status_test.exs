defmodule MingaClaudeBridge.StatusTest do
  use ExUnit.Case, async: true

  alias MingaClaudeBridge.Status

  setup do
    test = self()

    status =
      start_supervised!(
        {Status,
         reporter: :reporter,
         report: fn _reporter, availability -> send(test, {:reported, availability}) end,
         report_usage: fn _reporter, windows -> send(test, {:reported_usage, windows}) end}
      )

    %{status: status}
  end

  defp usage(rate_limits), do: %{"subscription_type" => "max", "rate_limits" => rate_limits}

  test "a get_usage answer without windows reports an empty list, so Minga clears old windows",
       %{status: status} do
    five_hour = %{"utilization" => 30, "resets_at" => nil, "locked_reason" => nil}
    :ok = Status.put_usage(status, :key, usage(%{"five_hour" => five_hour}))
    assert_receive {:reported_usage, [%{kind: "five_hour"}]}

    :ok = Status.put_usage(status, :key, usage(%{"five_hour" => nil}))
    assert_receive {:reported_usage, []}
    assert Status.plan_windows(status) == []
  end

  test "the plan named by usage becomes the ready label only for a credential that was ready",
       %{status: status} do
    :ok =
      Status.put(status, :signed_out, {:unavailable, :not_signed_in, "Run claude auth login."})

    :ok = Status.put_usage(status, :signed_out, usage(%{}))
    refute_received {:reported, {:ready, _label}}
    assert Status.usage_label(status, :signed_out) == "Claude Max"

    :ok = Status.put(status, :ready, {:ready, "Claude Code"})
    :ok = Status.put_usage(status, :ready, usage(%{}))
    assert_receive {:reported, {:ready, "Claude Max"}}

    # A ready credential whose account already named the plan keeps it.
    :ok = Status.put(status, :named, {:ready, "Claude Pro"})
    :ok = Status.put_usage(status, :named, usage(%{}))
    refute_received {:reported, {:ready, _label}}
  end
end
