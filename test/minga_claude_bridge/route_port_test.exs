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
    status = start_supervised!({Status, reporter: nil})
    %{fake: fake, base: Path.join(dir, "base"), status: status, dir: dir}
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

  test "models/1 lists the models from the last availability probe", ctx do
    assert {:ready, _label} = Route.availability("claude_bridge", nil, config(ctx, %{}))
    models = Route.models(status: ctx.status)

    assert [
             %{
               id: "haiku",
               display_name: "Haiku 5.5",
               reasoning_levels: ["low", "medium", "high", "xhigh", "max"]
             },
             %{id: "claude-haiku-4-5", reasoning_levels: ["default"]}
           ] = models
  end
end
