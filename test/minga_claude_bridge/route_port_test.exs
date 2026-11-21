defmodule MingaClaudeBridge.RoutePortTest do
  # Serialized: these tests spawn real OS processes with Port.open, which hits the BEAM's erl_child_setup EPIPE race under concurrency.
  use ExUnit.Case, async: false

  alias MingaAgent.InferenceRoute.Credential
  alias MingaClaudeBridge.{Route, Status}
  alias MingaClaudeBridge.Route.Config
  alias MingaClaudeBridge.Transport.Port, as: PortTransport

  @moduletag :tmp_dir
  @moduletag timeout: 30_000

  @fake Path.expand("../support/fake_claude", __DIR__)

  setup %{tmp_dir: dir} do
    fake = Path.join(dir, "claude")
    File.cp!(@fake, fake)
    File.chmod!(fake, 0o755)
    test = self()
    tasks = start_supervised!({Task.Supervisor, []})

    status =
      start_supervised!(
        {Status,
         reporter: :reporter,
         tasks: tasks,
         notify: test,
         report: fn _reporter, _availability -> :ok end,
         report_usage: fn reporter, windows ->
           send(test, {:reported_usage, reporter, windows})
         end}
      )

    %{
      fake: fake,
      base: Path.join(dir, "base"),
      status: status,
      dir: dir,
      dump: Path.join(dir, "dump")
    }
  end

  defp config(ctx, fake_env, transport_opts \\ []) do
    opts =
      Keyword.merge(
        [
          executable: ctx.fake,
          parent_env: Map.merge(System.get_env(), fake_env),
          workdir_base: ctx.base,
          kill_grace_ms: 300
        ],
        transport_opts
      )

    Config.load(transport: {PortTransport, opts}, status: ctx.status, availability_ttl: 0)
  end

  describe "availability/3" do
    test "a signed-in Claude Code is ready with its plan label, never the email", ctx do
      assert {:ready, "Claude Pro"} = Route.availability("claude_bridge", nil, config(ctx, %{}))
    end

    test "a signed-out Claude Code asks for claude auth login", ctx do
      assert {:unavailable, :not_signed_in, remedy} =
               Route.availability(
                 "claude_bridge",
                 nil,
                 config(ctx, %{"FAKE_CLAUDE_SIGNED_OUT" => "1"})
               )

      assert remedy =~ "claude auth login"
    end

    test "an old Claude Code reports the required version", ctx do
      assert {:unavailable, :unsupported_version, remedy} =
               Route.availability(
                 "claude_bridge",
                 nil,
                 config(ctx, %{"FAKE_CLAUDE_VERSION" => "2.0.1"})
               )

      assert remedy =~ "2.0.1"
      assert remedy =~ MingaClaudeBridge.Launch.min_version()
    end

    test "a missing claude asks to install it", ctx do
      config =
        config(ctx, %{},
          executable: nil,
          binary: [find_executable: fn _name -> nil end, home: Path.join(ctx.dir, "empty-home")]
        )

      assert {:unavailable, :claude_not_found, remedy} =
               Route.availability("claude_bridge", nil, config)

      assert remedy =~ "Install"
    end

    test "a forbidden credential key is reported without starting Claude Code", ctx do
      credential = %Credential{env: %{"HOME" => "/elsewhere"}}

      assert {:unavailable, :invalid_route_credential, remedy} =
               Route.availability("claude_bridge", credential, config(ctx, %{}))

      assert remedy =~ "HOME"
    end

    test "results are cached per credential", ctx do
      config = %{config(ctx, %{}) | availability_ttl: 60_000}
      assert {:ready, _} = Route.availability("claude_bridge", nil, config)

      # A cached answer does not start Claude Code again, so a now-broken executable is not noticed.
      broken = %{config | transport: {PortTransport, executable: "/nonexistent/claude"}}
      assert {:ready, _} = Route.availability("claude_bridge", nil, broken)
    end
  end

  describe "background measurement" do
    defp await_measured do
      assert_receive {:claude_bridge_measurement, :started, key}, 5_000
      assert_receive {:claude_bridge_measurement, :finished, ^key}, 15_000
      key
    end

    test "fills context windows for models/1 after availability", ctx do
      assert {:ready, _label} = Route.availability("claude_bridge", nil, config(ctx, %{}))
      await_measured()

      assert [
               %{
                 id: "haiku",
                 display_name: "Haiku 5.5",
                 reasoning_levels: ["low", "medium", "high", "xhigh", "max"],
                 context_window: 1_000_000
               },
               %{id: "claude-haiku-4-5", reasoning_levels: ["default"], context_window: 200_000}
             ] = Route.models(status: ctx.status)
    end

    test "reports plan usage windows with their status", ctx do
      rate_limits =
        JSON.encode!(%{
          "five_hour" => %{
            "utilization" => 79,
            "resets_at" => "2026-11-21T20:00:00+00:00",
            "locked_reason" => nil
          },
          "seven_day" => %{"utilization" => 80, "resets_at" => nil, "locked_reason" => nil},
          "seven_day_sonnet" => %{
            "utilization" => 100,
            "resets_at" => nil,
            "locked_reason" => nil
          },
          "seven_day_opus" => %{
            "utilization" => 5,
            "resets_at" => nil,
            "locked_reason" => "org_limit"
          },
          "seven_day_oauth_apps" => nil
        })

      assert {:ready, "Claude Pro"} =
               Route.availability(
                 "claude_bridge",
                 nil,
                 config(ctx, %{"FAKE_CLAUDE_RATE_LIMITS" => rate_limits})
               )

      assert_receive {:reported_usage, :reporter, windows}, 10_000

      assert Enum.map(windows, &{&1.kind, &1.utilization, &1.status}) == [
               {"five_hour", 0.79, :allowed},
               {"seven_day", 0.8, :warning},
               {"seven_day_opus", 0.05, :rejected},
               {"seven_day_sonnet", 1.0, :rejected}
             ]
    end

    test "availability returns before a slow measurement finishes", ctx do
      started = System.monotonic_time(:millisecond)

      assert {:ready, "Claude Pro"} =
               Route.availability(
                 "claude_bridge",
                 nil,
                 config(ctx, %{"FAKE_CLAUDE_CONTROL_DELAY" => "2"})
               )

      elapsed = System.monotonic_time(:millisecond) - started
      assert_received {:claude_bridge_measurement, :started, key}
      refute_received {:claude_bridge_measurement, :finished, ^key}
      assert elapsed < 2_000, "availability took #{elapsed} ms"

      # Usage is read first, so it lands while the windows are still being measured.
      assert_receive {:reported_usage, :reporter, [_ | _]}, 5_000
      refute_received {:claude_bridge_measurement, :finished, ^key}
      assert_receive {:claude_bridge_measurement, :finished, ^key}, 15_000
      assert Enum.any?(Route.models(status: ctx.status), &(&1.context_window == 1_000_000))
    end

    test "two checks back to back start one measurement", ctx do
      config = config(ctx, %{"FAKE_CLAUDE_CONTROL_DELAY" => "1"})
      assert {:ready, _label} = Route.availability("claude_bridge", nil, config)
      assert {:ready, _label} = Route.availability("claude_bridge", nil, config)

      assert_received {:claude_bridge_measurement, :started, key}
      refute_received {:claude_bridge_measurement, :started, _second}
      assert_receive {:claude_bridge_measurement, :finished, ^key}, 15_000
    end

    test "fresh windows are not measured again", ctx do
      config = config(ctx, %{"FAKE_CLAUDE_DUMP" => ctx.dump})
      assert {:ready, _label} = Route.availability("claude_bridge", nil, config)
      key = await_measured()

      assert Status.stale_models(
               ctx.status,
               key,
               ["haiku", "claude-haiku-4-5"],
               config.window_ttl
             ) == []

      assert Status.stale_models(ctx.status, key, ["haiku"], 0) == ["haiku"]
    end

    test "stopping the task supervisor stops the measurement and its claude", ctx do
      config = config(ctx, %{"FAKE_CLAUDE_CONTROL_DELAY" => "3", "FAKE_CLAUDE_DUMP" => ctx.dump})
      assert {:ready, _label} = Route.availability("claude_bridge", nil, config)
      assert_received {:claude_bridge_measurement, :started, _key}

      # Wait until the measurement's own claude has started: the readiness probe wrote the first pid.
      pids = wait_for_pids(ctx.dump, 2)
      assert :ok = stop_supervised(Task.Supervisor)

      for pid <- pids,
          do:
            assert(
              MingaClaudeBridge.OsProcess.wait_gone(pid, 5_000),
              "claude #{pid} still running"
            )
    end

    test "a Claude Code that never answers keeps defaults and readiness", ctx do
      config = %{config(ctx, %{"FAKE_CLAUDE_CONTROL" => "ignore"}) | measure_deadline: 300}
      assert {:ready, "Claude Pro"} = Route.availability("claude_bridge", nil, config)
      await_measured()
      refute_received {:reported_usage, _reporter, _windows}
      assert Enum.all?(Route.models(status: ctx.status), &(&1.context_window == 200_000))
    end
  end

  defp wait_for_pids(dump, count) do
    Enum.find_value(1..250, fn _ ->
      pids =
        case File.read(dump <> ".pids") do
          {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&String.to_integer/1)
          {:error, _} -> []
        end

      if length(pids) >= count do
        pids
      else
        receive do
        after
          20 -> nil
        end
      end
    end) || flunk("fewer than #{count} claude processes started")
  end
end
