defmodule MingaClaudeBridge.SessionTest do
  use ExUnit.Case, async: true

  alias MingaClaudeBridge.Session
  alias MingaClaudeBridge.Session.Request
  alias MingaClaudeBridge.Transport.Scripted
  alias MingaClaudeBridge.Wire.RateLimit

  @tools [
    %{
      name: "read_file",
      description: "Read a file",
      input_schema: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}}
    }
  ]

  # Frames Claude Code would write.

  defp init_frame(opts \\ []) do
    %{
      "type" => "system",
      "subtype" => "init",
      "session_id" => "cc-1",
      "tools" => Keyword.get(opts, :tools, ["mcp__minga__read_file"]),
      "mcp_servers" => [%{"name" => "minga", "status" => "connected"}]
    }
  end

  @account %{"email" => "user@example.com", "subscriptionType" => "Claude Pro"}
  @models [%{"value" => "sonnet", "displayName" => "Sonnet", "supportsEffort" => true}]

  defp init_response(version \\ "2.1.330") do
    %{
      "type" => "control_response",
      "response" => %{
        "subtype" => "success",
        "request_id" => "minga_init",
        "response" => %{
          "account" => @account,
          "models" => @models,
          "claude_code_version" => version,
          "pid" => 4242
        }
      }
    }
  end

  defp assistant_frame(id, content) do
    %{
      "type" => "assistant",
      "message" => %{"id" => id, "model" => "claude-sonnet", "content" => content},
      "parent_tool_use_id" => nil
    }
  end

  defp stream(event), do: %{"type" => "stream_event", "event" => event}

  defp message_start(input \\ 10),
    do:
      stream(%{
        "type" => "message_start",
        "message" => %{"id" => "msg", "usage" => %{"input_tokens" => input}}
      })

  defp block_start(index, block),
    do: stream(%{"type" => "content_block_start", "index" => index, "content_block" => block})

  defp delta(index, delta),
    do: stream(%{"type" => "content_block_delta", "index" => index, "delta" => delta})

  defp block_stop(index), do: stream(%{"type" => "content_block_stop", "index" => index})

  defp message_delta(stop_reason, output),
    do:
      stream(%{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => stop_reason},
        "usage" => %{"output_tokens" => output}
      })

  defp message_stop, do: stream(%{"type" => "message_stop"})

  defp text_block(index, chunks) do
    [block_start(index, %{"type" => "text", "text" => ""})] ++
      Enum.map(chunks, &delta(index, %{"type" => "text_delta", "text" => &1})) ++
      [block_stop(index)]
  end

  defp tool_use_block(index, id) do
    [
      block_start(index, %{
        "type" => "tool_use",
        "id" => id,
        "name" => "mcp__minga__read_file",
        "input" => %{}
      }),
      delta(index, %{"type" => "input_json_delta", "partial_json" => ~s({"path":"#{id}.txt"})}),
      block_stop(index)
    ]
  end

  defp result_frame(opts \\ []) do
    %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => Keyword.get(opts, :is_error, false),
      "result" => Keyword.get(opts, :result, "done"),
      "stop_reason" => "end_turn"
    }
  end

  defp tools_call(request_id, tool_use_id) do
    %{
      "type" => "control_request",
      "request_id" => request_id,
      "request" => %{
        "subtype" => "mcp_message",
        "server_name" => "minga",
        "message" => %{
          "jsonrpc" => "2.0",
          "id" => request_id,
          "method" => "tools/call",
          "params" => %{
            "name" => "read_file",
            "arguments" => %{"path" => "x"},
            "_meta" => %{"claudecode/toolUseId" => tool_use_id}
          }
        }
      }
    }
  end

  # Harness

  defp start_session(opts \\ []) do
    {transport_opts, opts} = Keyword.pop(opts, :transport_opts, [])
    test = self()

    session =
      start_supervised!(
        {Session,
         [transport: {Scripted, [controller: test] ++ transport_opts}, tools: @tools] ++ opts}
      )

    assert_receive {:scripted_started, ref, ^session, start_opts}
    assert start_opts[:launch] |> is_list()
    assert_receive {:scripted_line, ^ref, initialize}

    assert %{"request" => %{"subtype" => "initialize", "sdkMcpServers" => ["minga"]}} =
             JSON.decode!(initialize)

    %{session: session, ref: ref}
  end

  defp ready(opts \\ []) do
    ctx = start_session(opts)
    push(ctx, init_response())
    assert Session.phase(ctx.session) == :idle
    ctx
  end

  defp push(%{session: session, ref: ref}, frames),
    do: Enum.each(List.wrap(frames), &Scripted.push(session, ref, &1))

  defp written(%{ref: ref}) do
    assert_receive {:scripted_line, ^ref, line}
    JSON.decode!(line)
  end

  # A call to the session is processed after every message the test sent it before.
  defp sync(%{session: session}), do: Session.phase(session)

  defp refute_written(%{ref: ref} = ctx) do
    sync(ctx)
    refute_received {:scripted_line, ^ref, _line}
  end

  # Writes a prompt; Claude Code then starts the query with a passing system/init.
  defp prompt!(ctx, text \\ "hello") do
    {:ok, rref} = Session.request(ctx.session, Request.prompt(text, @tools), self())
    assert %{"type" => "user", "message" => %{"content" => [%{"text" => ^text}]}} = written(ctx)
    push(ctx, init_frame())
    rref
  end

  defp results(ids),
    do:
      Request.tool_results(
        Enum.map(ids, &%{tool_use_id: &1, content: [{:text, "r" <> &1}], is_error: false}),
        @tools
      )

  defp mcp_response(line), do: line["response"]["response"]["mcp_response"]

  defp assert_finish_once(rref, reason) do
    assert_receive {^rref, {:finish, ^reason}}
    refute_received {^rref, {:finish, _other}}
  end

  describe "text turns" do
    test "a prompt streams text, usage, and one finish" do
      ctx = ready()
      rref = prompt!(ctx)

      push(
        ctx,
        [message_start(12)] ++
          text_block(0, ["Hel", "lo"]) ++
          [message_delta("end_turn", 5), message_stop(), result_frame()]
      )

      assert_receive {^rref, {:text, "Hel"}}
      assert_receive {^rref, {:text, "lo"}}

      assert_receive {^rref,
                      {:usage,
                       %{
                         input_tokens: 12,
                         output_tokens: 5,
                         cache_read_tokens: 0,
                         cache_write_tokens: 0
                       }}}

      assert_finish_once(rref, :stop)
      assert Session.phase(ctx.session) == :idle
    end

    test "thinking deltas are forwarded before text" do
      ctx = ready()
      rref = prompt!(ctx)

      push(
        ctx,
        [
          message_start(),
          block_start(0, %{"type" => "thinking", "thinking" => ""}),
          delta(0, %{"type" => "thinking_delta", "thinking" => "let me see"}),
          block_stop(0)
          | text_block(1, ["ok"])
        ] ++ [message_stop(), result_frame()]
      )

      assert_receive {^rref, {:thinking, "let me see"}}
      assert_receive {^rref, {:text, "ok"}}
      assert_finish_once(rref, :stop)
    end

    test "max_tokens finishes with :length and an error result with an error" do
      ctx = ready()
      rref = prompt!(ctx)
      push(ctx, [message_start(), message_delta("max_tokens", 1), message_stop(), result_frame()])
      assert_finish_once(rref, :length)

      rref = prompt!(ctx)
      push(ctx, result_frame(is_error: true, result: "API Error"))
      assert_finish_once(rref, {:error, {:claude_error, :success, "API Error"}})
    end

    test "a prompt during startup is written once startup completes" do
      ctx = start_session()
      {:ok, rref} = Session.request(ctx.session, Request.prompt("early", @tools), self())
      refute_written(ctx)

      push(ctx, init_response())
      assert %{"type" => "user"} = written(ctx)
      push(ctx, [init_frame(), message_start(), message_stop(), result_frame()])
      assert_finish_once(rref, :stop)
    end

    test "info returns the account, models, and version from the initialize answer" do
      ctx = start_session()
      assert Session.info(ctx.session) == nil
      push(ctx, init_response())

      assert Session.info(ctx.session) == %{
               account: @account,
               models: @models,
               claude_code_version: "2.1.330"
             }
    end

    test "a non-streaming fallback reply is taken from assistant frames" do
      ctx = ready()
      rref = prompt!(ctx)

      # A stalled stream, then the fallback reply under a new message id.
      push(ctx, [message_start(), block_start(0, %{"type" => "text", "text" => ""})])

      push(ctx, [
        assistant_frame("fb", [%{"type" => "thinking", "thinking" => "hm"}]),
        assistant_frame("fb", [%{"type" => "text", "text" => "Looking"}]),
        assistant_frame("fb", [
          %{
            "type" => "tool_use",
            "id" => "t1",
            "name" => "mcp__minga__read_file",
            "input" => %{"path" => "a"}
          }
        ]),
        tools_call("c1", "t1")
      ])

      assert_receive {^rref, {:thinking, "hm"}}
      assert_receive {^rref, {:text, "Looking"}}

      assert_receive {^rref,
                      {:tool_call, %{id: "t1", name: "read_file", arguments: %{"path" => "a"}}}}

      assert_finish_once(rref, :tool_calls)

      # The call that ended the fallback message is held, not lost.
      {:ok, _rref2} = Session.request(ctx.session, results(["t1"]), self())
      assert written(ctx)["response"]["request_id"] == "c1"
    end

    test "assistant frames of a streamed message are not forwarded twice" do
      ctx = ready()
      rref = prompt!(ctx)

      push(
        ctx,
        [message_start()] ++
          text_block(0, ["once"]) ++
          [
            assistant_frame("msg", [%{"type" => "text", "text" => "once"}]),
            message_stop(),
            result_frame()
          ]
      )

      assert_receive {^rref, {:text, "once"}}
      assert_finish_once(rref, :stop)
      refute_received {^rref, {:text, _again}}
    end

    test "a second request while streaming is rejected" do
      ctx = ready()
      _rref = prompt!(ctx)

      assert {:error, {:invalid_phase, :streaming}} =
               Session.request(ctx.session, Request.prompt("x", @tools), self())
    end
  end

  describe "tool suspension" do
    test "one tool_use whose MCP call arrives before message_stop" do
      ctx = ready()
      rref = prompt!(ctx)

      push(
        ctx,
        [message_start() | tool_use_block(0, "t1")] ++
          [tools_call("c1", "t1"), message_delta("tool_use", 3), message_stop()]
      )

      assert_receive {^rref,
                      {:tool_call,
                       %{id: "t1", name: "read_file", arguments: %{"path" => "t1.txt"}}}}

      assert_receive {^rref, {:usage, %{output_tokens: 3}}}
      assert_finish_once(rref, :tool_calls)
      assert Session.phase(ctx.session) == :awaiting_tool_results
      refute_written(ctx)

      {:ok, rref2} = Session.request(ctx.session, results(["t1"]), self())
      line = written(ctx)
      assert line["response"]["request_id"] == "c1"

      assert mcp_response(line)["result"] == %{
               "content" => [%{"type" => "text", "text" => "rt1"}],
               "isError" => false
             }

      push(
        ctx,
        [message_start()] ++ text_block(0, ["read it"]) ++ [message_stop(), result_frame()]
      )

      assert_receive {^rref2, {:text, "read it"}}
      assert_finish_once(rref2, :stop)
    end

    test "three tool_use blocks with calls before, after, and after the results" do
      ctx = ready()
      rref = prompt!(ctx)

      push(
        ctx,
        [message_start()] ++
          tool_use_block(0, "t1") ++
          [tools_call("c1", "t1")] ++
          tool_use_block(1, "t2") ++
          tool_use_block(2, "t3") ++ [message_stop(), tools_call("c2", "t2")]
      )

      for id <- ["t1", "t2", "t3"], do: assert_receive({^rref, {:tool_call, %{id: ^id}}})
      assert_finish_once(rref, :tool_calls)
      refute_written(ctx)

      # Results arrive before Claude Code sends the call for t3 (serial dispatch).
      {:ok, _rref2} = Session.request(ctx.session, results(["t3", "t2", "t1"]), self())
      answered = for _ <- 1..2, do: written(ctx)["response"]["request_id"]
      assert Enum.sort(answered) == ["c1", "c2"]
      refute_written(ctx)

      push(ctx, tools_call("c3", "t3"))
      line = written(ctx)
      assert line["response"]["request_id"] == "c3"
      assert [%{"text" => "rt3"}] = mcp_response(line)["result"]["content"]
    end

    test "an MCP call that arrives after the suspension is held until the results" do
      ctx = ready()
      rref = prompt!(ctx)
      push(ctx, [message_start() | tool_use_block(0, "t1")] ++ [message_stop()])
      assert_finish_once(rref, :tool_calls)

      push(ctx, tools_call("c1", "t1"))
      refute_written(ctx)
      {:ok, _rref2} = Session.request(ctx.session, results(["t1"]), self())
      assert written(ctx)["response"]["request_id"] == "c1"
    end

    test "duplicate and unknown result ids finish with an error and write nothing" do
      ctx = ready()
      rref = prompt!(ctx)

      push(
        ctx,
        [message_start() | tool_use_block(0, "t1")] ++ [tools_call("c1", "t1"), message_stop()]
      )

      assert_finish_once(rref, :tool_calls)

      {:ok, bad} = Session.request(ctx.session, results(["t1", "t1"]), self())
      assert_finish_once(bad, {:error, {:invalid_tool_results, {:duplicate_tool_use, ["t1"]}}})

      {:ok, bad} = Session.request(ctx.session, results(["t1", "nope"]), self())
      assert_finish_once(bad, {:error, {:invalid_tool_results, {:unknown_tool_use, ["nope"]}}})
      refute_written(ctx)

      {:ok, _good} = Session.request(ctx.session, results(["t1"]), self())
      assert written(ctx)["response"]["request_id"] == "c1"

      # The id was used once; repeating it after resume is no longer awaited.
      assert {:error, {:invalid_phase, :streaming}} =
               Session.request(ctx.session, results(["t1"]), self())
    end
  end

  describe "control requests" do
    test "can_use_tool and other MCP servers get a control error" do
      ctx = ready()
      _rref = prompt!(ctx)

      push(ctx, %{
        "type" => "control_request",
        "request_id" => "p1",
        "request" => %{"subtype" => "can_use_tool", "tool_name" => "Bash", "input" => %{}}
      })

      assert %{"response" => %{"subtype" => "error", "request_id" => "p1"}} = written(ctx)

      push(ctx, %{
        "type" => "control_request",
        "request_id" => "p2",
        "request" => %{
          "subtype" => "mcp_message",
          "server_name" => "other",
          "message" => %{"method" => "tools/list", "id" => 1}
        }
      })

      assert %{"response" => %{"subtype" => "error", "request_id" => "p2"}} = written(ctx)
    end

    test "MCP initialize during startup is answered" do
      ctx = start_session()

      push(ctx, %{
        "type" => "control_request",
        "request_id" => "i1",
        "request" => %{
          "subtype" => "mcp_message",
          "server_name" => "minga",
          "message" => %{
            "jsonrpc" => "2.0",
            "id" => 0,
            "method" => "initialize",
            "params" => %{"protocolVersion" => "2025-11-25"}
          }
        }
      })

      line = written(ctx)
      assert line["response"]["request_id"] == "i1"
      assert mcp_response(line)["result"]["protocolVersion"] == "2025-11-25"
      assert Session.phase(ctx.session) == :starting
    end

    test "tools/list during startup answers with the start tools" do
      ctx = start_session()

      push(ctx, %{
        "type" => "control_request",
        "request_id" => "l1",
        "request" => %{
          "subtype" => "mcp_message",
          "server_name" => "minga",
          "message" => %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}
        }
      })

      assert [%{"name" => "read_file"}] = mcp_response(written(ctx))["result"]["tools"]
    end
  end

  describe "abort" do
    test "while streaming: interrupt, one aborted finish, partial text kept, then idle" do
      ctx = ready()
      rref = prompt!(ctx)
      push(ctx, [message_start() | text_block(0, ["partial"])])
      assert_receive {^rref, {:text, "partial"}}

      assert :ok = Session.abort(ctx.session, rref)

      assert %{"type" => "control_request", "request" => %{"subtype" => "interrupt"}} =
               written(ctx)

      assert_finish_once(rref, {:error, :aborted})
      assert Session.phase(ctx.session) == :interrupting

      # A call that arrives after the abort is cancelled, not held.
      push(ctx, tools_call("late", "t9"))
      assert mcp_response(written(ctx))["error"]["code"] == -32_800

      push(ctx, result_frame())
      assert Session.phase(ctx.session) == :idle
      refute_received {^rref, _event}

      # Still cancelled once idle again.
      push(ctx, tools_call("later", "t9"))
      assert mcp_response(written(ctx))["error"]["code"] == -32_800
    end

    test "while awaiting tools: held calls get -32800 and the transport stops after the bound" do
      ctx = ready()
      rref = prompt!(ctx)

      push(
        ctx,
        [message_start()] ++
          tool_use_block(0, "t1") ++
          tool_use_block(1, "t2") ++ [tools_call("c1", "t1"), message_stop()]
      )

      assert_finish_once(rref, :tool_calls)

      assert :ok = Session.abort(ctx.session, rref)
      assert %{"request" => %{"subtype" => "interrupt"}} = written(ctx)
      cancel = written(ctx)
      assert cancel["response"]["request_id"] == "c1"
      assert mcp_response(cancel)["error"]["code"] == -32_800
      sync(ctx)
      refute_received {^rref, {:finish, _reason}}

      ref = ctx.ref
      send(ctx.session, {:timeout, :interrupt_timeout})
      assert_receive {:scripted_stopped, ^ref, _reason}

      assert {:error, {:session_dead, :interrupt_timeout}} =
               Session.request(ctx.session, Request.prompt("again", @tools), self())
    end

    test "the interrupt bound fires on its own" do
      ctx = ready(interrupt_timeout: 5)
      rref = prompt!(ctx)
      :ok = Session.abort(ctx.session, rref)
      ref = ctx.ref
      assert_receive {:scripted_stopped, ^ref, _reason}, 1000
      assert Session.phase(ctx.session) == :dead
    end

    test "an unknown ref is rejected" do
      ctx = ready()
      _rref = prompt!(ctx)
      assert {:error, :unknown_request} = Session.abort(ctx.session, make_ref())
    end

    test "a subscriber that exits mid-turn aborts the request" do
      ctx = ready()
      subscriber = spawn(fn -> receive do: (:never -> :ok) end)
      monitor = Process.monitor(subscriber)
      {:ok, _rref} = Session.request(ctx.session, Request.prompt("hi", @tools), subscriber)
      assert %{"type" => "user"} = written(ctx)

      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^subscriber, :killed}
      assert %{"request" => %{"subtype" => "interrupt"}} = written(ctx)
    end
  end

  describe "failures" do
    test "transport exit mid-turn finishes with an error and kills the session" do
      ctx = ready()
      rref = prompt!(ctx)
      push(ctx, [message_start() | text_block(0, ["par"])])
      Scripted.exit(ctx.session, ctx.ref, 1)

      assert_receive {^rref, {:text, "par"}}
      assert_finish_once(rref, {:error, {:claude_exited, 1}})
      ref = ctx.ref
      assert_receive {:scripted_stopped, ^ref, _reason}

      assert {:error, {:session_dead, {:claude_exited, 1}}} =
               Session.request(ctx.session, Request.prompt("x", @tools), self())
    end

    test "an undecodable line kills the session" do
      ctx = ready()
      rref = prompt!(ctx)
      push(ctx, "not json")
      assert_finish_once(rref, {:error, {:protocol_error, {:invalid_json, {:invalid_byte, 1}}}})
    end

    test "a transport error kills the session" do
      ctx = ready()
      rref = prompt!(ctx)
      Scripted.fail(ctx.session, ctx.ref, :line_too_long)
      assert_finish_once(rref, {:error, {:transport_error, :line_too_long}})
    end

    test "an extra tool at the query's init stops Claude Code before any model output is forwarded" do
      ctx = ready()
      {:ok, rref} = Session.request(ctx.session, Request.prompt("hi", @tools), self())
      assert %{"type" => "user"} = written(ctx)

      push(
        ctx,
        [init_frame(tools: ["mcp__minga__read_file", "Bash"]), message_start()] ++
          text_block(0, ["leak"]) ++
          tool_use_block(1, "t1") ++ [tools_call("c1", "t1"), message_stop()]
      )

      ref = ctx.ref
      assert_receive {:scripted_stopped, ^ref, _reason}
      assert_finish_once(rref, {:error, {:unexpected_tools, ["Bash"]}})
      refute_written(ctx)
      refute_received {^rref, {:text, _text}}
      refute_received {^rref, {:tool_call, _call}}
      assert Session.phase(ctx.session) == :dead
    end

    test "model output before the query's init kills the session" do
      ctx = ready()
      {:ok, rref} = Session.request(ctx.session, Request.prompt("hi", @tools), self())
      assert %{"type" => "user"} = written(ctx)
      push(ctx, [message_start() | text_block(0, ["early"])])

      assert_finish_once(rref, {:error, :missing_system_init})
      refute_received {^rref, {:text, _text}}
    end

    test "an unsupported version kills the session at startup" do
      ctx = start_session(min_version: "2.2.0")
      {:ok, rref} = Session.request(ctx.session, Request.prompt("early", @tools), self())
      push(ctx, init_response("2.1.330"))
      ref = ctx.ref
      assert_receive {:scripted_stopped, ^ref, _reason}
      assert_finish_once(rref, {:error, {:unsupported_version, "2.1.330"}})
      refute_written(ctx)

      assert {:error, {:session_dead, {:unsupported_version, "2.1.330"}}} =
               Session.request(ctx.session, Request.prompt("x", @tools), self())
    end

    test "startup that never completes times out" do
      ctx = start_session()
      send(ctx.session, {:timeout, :startup_timeout})
      ref = ctx.ref
      assert_receive {:scripted_stopped, ^ref, _reason}
      assert Session.phase(ctx.session) == :dead
    end

    test "a failed transport start fails start_link" do
      assert {:error, {{:transport_start_failed, :enoent}, _child}} =
               start_supervised(
                 {Session, transport: {Scripted, controller: self(), fail_start: :enoent}}
               )
    end

    test "a failed write kills the session" do
      assert {:ok, session} =
               start_supervised(
                 {Session, transport: {Scripted, controller: self(), fail_send: :epipe}}
               )

      assert Session.phase(session) == :dead
    end
  end

  describe "rate limits" do
    defp rate_limit_frame do
      %{
        "type" => "rate_limit_event",
        "rate_limit_info" => %{
          "status" => "allowed_warning",
          "rateLimitType" => "five_hour",
          "utilization" => 0.9
        }
      }
    end

    test "are sent to a pid" do
      ctx = ready(on_rate_limit: self())
      push(ctx, rate_limit_frame())
      session = ctx.session

      assert_receive {:claude_bridge_rate_limit, ^session,
                      %RateLimit{status: :allowed_warning, rate_limit_type: :five_hour}}
    end

    test "are passed to a function without blocking the session" do
      test = self()

      ctx =
        ready(
          on_rate_limit: fn rate_limit -> send(test, {:rate_limited, rate_limit.utilization}) end
        )

      push(ctx, rate_limit_frame())
      assert_receive {:rate_limited, 0.9}
    end
  end

  describe "lifecycle" do
    test "await_ready answers when startup completes" do
      ctx = start_session()
      task = Task.async(fn -> Session.await_ready(ctx.session, 5_000) end)
      push(ctx, init_response())
      assert {:ok, %{claude_code_version: "2.1.330"}} = Task.await(task)
    end

    test "await_ready answers with the reason when startup fails" do
      dead = start_session(min_version: "9.0.0")
      task = Task.async(fn -> Session.await_ready(dead.session, 5_000) end)
      push(dead, init_response())
      assert {:error, {:unsupported_version, "2.1.330"}} = Task.await(task)
    end

    test "an unlinked session with an owner stops when the owner exits" do
      test = self()

      owner =
        spawn(fn ->
          {:ok, session} =
            Session.start(transport: {Scripted, controller: test}, owner: self())

          send(test, {:session, session})
          receive do: (:never -> :ok)
        end)

      assert_receive {:session, session}
      assert_receive {:scripted_started, ref, ^session, _opts}
      monitor = Process.monitor(session)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^session, :normal}
      assert_receive {:scripted_stopped, ^ref, _reason}
    end

    test "seen and remember hold the history a session has seen" do
      ctx = ready()
      assert MingaClaudeBridge.History.seen_count(Session.seen(ctx.session)) == 0

      history =
        MingaClaudeBridge.History.record(MingaClaudeBridge.History.new(), %{
          entries: [%{role: :user, digest_input: "hi"}],
          fingerprint: %{system_prompt: nil, tools: [], model: "m"}
        })

      assert :ok = Session.remember(ctx.session, history)
      assert Session.seen(ctx.session) == history
      assert Keyword.keyword?(Session.launch(ctx.session))
    end

    test "the idle timeout stops the transport and the session" do
      ctx = ready()
      monitor = Process.monitor(ctx.session)
      send(ctx.session, {:timeout, :idle_timeout})
      ref = ctx.ref
      assert_receive {:scripted_stopped, ^ref, :normal}
      assert_receive {:DOWN, ^monitor, :process, _pid, :normal}
    end

    test "the idle timeout does not apply while streaming" do
      ctx = ready()
      _rref = prompt!(ctx)
      send(ctx.session, {:timeout, :idle_timeout})
      assert Session.phase(ctx.session) == :streaming
    end

    test "terminate stops the transport and finishes the running request" do
      ctx = ready()
      rref = prompt!(ctx)
      stop_supervised!(Session)
      ref = ctx.ref
      assert_receive {:scripted_stopped, ^ref, :shutdown}
      assert_finish_once(rref, {:error, :session_stopped})
    end
  end
end
