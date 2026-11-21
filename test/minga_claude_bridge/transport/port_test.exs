defmodule MingaClaudeBridge.Transport.PortTest do
  # Serialized: these tests spawn real OS processes with Port.open, which hits the BEAM's erl_child_setup EPIPE race under concurrency.
  use ExUnit.Case, async: false

  alias MingaClaudeBridge.{Binary, OsProcess, Session}
  alias MingaClaudeBridge.Session.Request
  alias MingaClaudeBridge.Transport.Port, as: PortTransport

  @moduletag :tmp_dir
  @moduletag timeout: 30_000

  @fake Path.expand("../../support/fake_claude", __DIR__)
  @tools [%{name: "read_file", description: "Read", input_schema: %{"type" => "object"}}]
  @user_line JSON.encode!(%{
               "type" => "user",
               "message" => %{"role" => "user", "content" => "hi"}
             }) <> "\n"

  setup %{tmp_dir: dir} do
    # Build the fake: copy it into the test directory and make it executable.
    fake = Path.join(dir, "claude")
    File.cp!(@fake, fake)
    File.chmod!(fake, 0o755)
    %{fake: fake, base: Path.join(dir, "base"), dump: Path.join(dir, "dump")}
  end

  defp transport_opts(ctx, fake_env, opts) do
    [
      executable: ctx.fake,
      parent_env: Map.merge(System.get_env(), fake_env),
      workdir_base: ctx.base,
      kill_grace_ms: 300
    ]
    |> Keyword.merge(opts)
  end

  # Starts a transport owned by the test process.
  defp start_transport(ctx, fake_env \\ %{}, opts \\ []) do
    ref = make_ref()
    opts = transport_opts(ctx, fake_env, opts) ++ [owner: self(), ref: ref, launch: []]
    {:ok, pid} = PortTransport.start(opts)
    %{pid: pid, ref: ref, os_pid: PortTransport.os_pid(pid), workdir: PortTransport.workdir(pid)}
  end

  defp start_session(ctx, fake_env, opts \\ []) do
    {transport_extra, session_opts} = Keyword.split(opts, [:credential_env, :max_line_bytes])

    start_supervised!(
      {Session,
       [transport: {PortTransport, transport_opts(ctx, fake_env, transport_extra)}, tools: @tools] ++
         session_opts}
    )
  end

  defp await_idle(session) do
    Enum.find_value(1..250, fn _ ->
      case Session.phase(session) do
        :starting ->
          receive do
          after
            20 -> nil
          end

        phase ->
          phase
      end
    end)
  end

  defp gone?(os_pid), do: OsProcess.wait_gone(os_pid, 3_000)

  defp dumped_pid(dump) do
    Enum.find_value(1..250, fn _ ->
      case File.read(dump <> ".pid") do
        {:ok, text} ->
          text |> String.trim() |> String.to_integer()

        {:error, _} ->
          receive do
          after
            20 -> nil
          end
      end
    end)
  end

  describe "through a session" do
    test "a full turn: startup, MCP handshake, streamed text, usage, finish", ctx do
      session = start_session(ctx, %{}, on_rate_limit: self())
      assert await_idle(session) == :idle

      assert %{account: %{"subscriptionType" => "Claude Pro"}, claude_code_version: "2.1.330"} =
               Session.info(session)

      {:ok, ref} = Session.request(session, Request.prompt("hi", @tools), self())
      assert_receive {^ref, {:text, "Hello from fake claude"}}, 5_000
      assert_receive {^ref, {:usage, %{input_tokens: 12, output_tokens: 5}}}, 5_000
      assert_receive {^ref, {:finish, :stop}}, 5_000
      assert_receive {:claude_bridge_rate_limit, ^session, _rate_limit}, 5_000
      refute_received {^ref, {:text, _duplicate}}
    end

    test "a frame larger than 64 KiB arrives whole", ctx do
      session = start_session(ctx, %{"FAKE_CLAUDE_BIG" => "100000"})
      assert await_idle(session) == :idle
      {:ok, ref} = Session.request(session, Request.prompt("hi", @tools), self())
      assert_receive {^ref, {:text, text}}, 5_000
      assert byte_size(text) == 100_000
      assert_receive {^ref, {:finish, :stop}}, 5_000
    end

    test "an extra tool at the query's init stops the session and the child", ctx do
      env = %{
        "FAKE_CLAUDE_TOOLS" => ~s(["mcp__minga__read_file","Bash"]),
        "FAKE_CLAUDE_DUMP" => ctx.dump
      }

      session = start_session(ctx, env)
      assert await_idle(session) == :idle
      os_pid = dumped_pid(ctx.dump)

      {:ok, ref} = Session.request(session, Request.prompt("hi", @tools), self())
      assert_receive {^ref, {:finish, {:error, {:unexpected_tools, ["Bash"]}}}}, 5_000
      refute_received {^ref, {:text, _text}}
      assert gone?(os_pid)
      assert Session.phase(session) == :dead
    end

    test "a forbidden credential key fails the start before any spawn", ctx do
      assert {:error, {{:transport_start_failed, {:forbidden_env, ["HOME"]}}, _child}} =
               start_supervised(
                 {Session,
                  transport:
                    {PortTransport, transport_opts(ctx, %{}, credential_env: %{"HOME" => "/tmp"})}}
               )
    end
  end

  describe "the transport" do
    test "the environment and arguments follow the rules", ctx do
      fake_env = %{
        "FAKE_CLAUDE_DUMP" => ctx.dump,
        "ANTHROPIC_API_KEY" => "sk-parent",
        "AWS_REGION" => "us-east-1",
        "NODE_OPTIONS" => "--inspect",
        "CLAUDECODE" => "1",
        "OPENAI_API_KEY" => "sk-openai",
        "KEEP_ME" => "yes",
        "DROP_ME" => "x"
      }

      t =
        start_transport(ctx, fake_env,
          credential_env: %{"CLAUDE_CODE_OAUTH_TOKEN" => "oauth", "DROP_ME" => ""}
        )

      dumped_pid(ctx.dump)

      env =
        ctx.dump
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Map.new(fn line -> line |> String.split("=", parts: 2) |> List.to_tuple() end)

      for name <- ~w(ANTHROPIC_API_KEY AWS_REGION NODE_OPTIONS CLAUDECODE OPENAI_API_KEY DROP_ME),
          do: refute(Map.has_key?(env, name), name)

      assert env["KEEP_ME"] == "yes"
      assert env["CLAUDE_CODE_OAUTH_TOKEN"] == "oauth"
      assert env["DISABLE_AUTO_COMPACT"] == "1"
      assert env["ENABLE_CLAUDEAI_MCP_SERVERS"] == "0"
      assert env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1"
      assert env["CLAUDE_CODE_MAX_MCP_DESCRIPTION_LENGTH"] == "16384"
      assert env["ENABLE_TOOL_SEARCH"] == "false"
      assert env["MCP_TOOL_TIMEOUT"] == "86400000"

      argv = ctx.dump |> Kernel.<>(".argv") |> File.read!() |> String.split("\n") |> Enum.drop(-1)
      assert argv == MingaClaudeBridge.Launch.fixed_args()

      # `pwd -P` resolves symlinked parents such as /var -> /private/var, so compare the bridge-owned tail.
      cwd = ctx.dump |> Kernel.<>(".cwd") |> File.read!() |> String.trim()
      assert String.ends_with?(cwd, Path.join(["sessions", Path.basename(t.workdir)]))
      assert Bitwise.band(File.stat!(t.workdir).mode, 0o777) == 0o700

      PortTransport.stop(t.pid, :normal)
      assert gone?(t.os_pid)
      refute File.exists?(t.workdir)
    end

    test "stop closes stdin and the child exits; stop is idempotent", ctx do
      t = start_transport(ctx)
      monitor = Process.monitor(t.pid)
      assert :ok = PortTransport.stop(t.pid, :normal)
      assert_receive {:DOWN, ^monitor, :process, _pid, :normal}
      assert gone?(t.os_pid)
      assert :ok = PortTransport.stop(t.pid, :normal)
      assert {:error, :closed} = PortTransport.send_line(t.pid, @user_line)
    end

    test "the exit status reaches the owner", ctx do
      t = start_transport(ctx, %{"FAKE_CLAUDE_EXIT_ON_PROMPT" => "3"})
      :ok = PortTransport.send_line(t.pid, @user_line)
      ref = t.ref
      assert_receive {:transport, ^ref, {:exit, 3}}, 5_000
      assert gone?(t.os_pid)
    end

    test "a line over the cap reports :line_too_long and kills the child", ctx do
      t = start_transport(ctx, %{"FAKE_CLAUDE_BIG" => "100000"}, max_line_bytes: 50_000)
      :ok = PortTransport.send_line(t.pid, @user_line)
      ref = t.ref
      assert_receive {:transport, ^ref, {:error, :line_too_long}}, 5_000
      assert gone?(t.os_pid)
    end

    test "a child that ignores SIGTERM is killed with SIGKILL after the grace period", ctx do
      t = start_transport(ctx, %{"FAKE_CLAUDE_IGNORE_TERM" => "1"})
      # The first line is written after the fake installs its SIGTERM trap.
      ref = t.ref
      assert_receive {:transport, ^ref, {:line, _first}}, 5_000
      started = System.monotonic_time(:millisecond)
      :ok = PortTransport.stop(t.pid, :normal)
      elapsed = System.monotonic_time(:millisecond) - started

      assert elapsed >= 300
      assert elapsed < 3_000
      refute OsProcess.alive?(t.os_pid)
    end

    # The killed owner is the transport's parent, so OTP logs its exit as an error report.
    @tag capture_log: true
    test "the child dies with its owner", ctx do
      test = self()

      owner =
        spawn(fn ->
          t = start_transport(ctx)
          send(test, {:started, t})

          receive do
            :never -> :ok
          end
        end)

      assert_receive {:started, t}, 5_000
      monitor = Process.monitor(t.pid)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 5_000
      assert gone?(t.os_pid)
      refute File.exists?(t.workdir)
    end

    test "debug logs are 0600 files in a 0700 directory", ctx do
      t = start_transport(ctx, %{}, debug: true)
      :ok = PortTransport.send_line(t.pid, @user_line)
      ref = t.ref
      assert_receive {:transport, ^ref, {:line, _first}}, 5_000
      :ok = PortTransport.stop(t.pid, :normal)

      debug_dir = Path.join(ctx.base, "debug")
      assert Bitwise.band(File.stat!(debug_dir).mode, 0o777) == 0o700
      [file] = File.ls!(debug_dir)
      path = Path.join(debug_dir, file)
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      log = File.read!(path)
      assert log =~ ~r/^> .*"type":"user"/m
      assert log =~ ~r/^< .*"type":"control_request"/m
    end
  end

  describe "binary" do
    test "version reads the version line", ctx do
      assert {:ok, "2.1.330"} = Binary.version(ctx.fake)
    end
  end
end
