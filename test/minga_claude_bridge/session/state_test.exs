defmodule MingaClaudeBridge.Session.StateTest do
  use ExUnit.Case, async: true

  alias MingaClaudeBridge.Session.{Request, State}

  alias MingaClaudeBridge.Wire.{
    Assistant,
    ControlRequest,
    ControlResponse,
    Result,
    StreamEvent,
    SystemInit,
    Usage
  }

  @tools [%{name: "read_file", description: "Read", input_schema: %{"type" => "object"}}]
  @phases [:starting, :idle, :streaming, :awaiting_tool_results, :interrupting, :dead]

  defp init_frame(opts \\ []) do
    %SystemInit{
      session_id: "s",
      tools: Keyword.get(opts, :tools, ["mcp__minga__read_file"]),
      mcp_servers: Keyword.get(opts, :servers, [%{name: "minga", status: "connected"}])
    }
  end

  @account %{"email" => "a@example.com", "subscriptionType" => "Claude Pro"}
  @models [%{"value" => "sonnet", "displayName" => "Sonnet"}]

  defp init_ok(version \\ "2.1.330") do
    response = %{"account" => @account, "models" => @models, "claude_code_version" => version}
    %ControlResponse{request_id: "init", outcome: {:ok, response}}
  end

  defp event(event, parent \\ nil), do: %StreamEvent{event: event, parent_tool_use_id: parent}
  defp prompt, do: Request.prompt("hi", @tools)

  defp results(ids),
    do: Request.tool_results(Enum.map(ids, &result/1), @tools)

  defp result(id), do: %{tool_use_id: id, content: [{:text, "ok #{id}"}], is_error: false}

  defp tools_call(request_id, tool_use_id) do
    %ControlRequest{
      request_id: request_id,
      request:
        {:mcp_message,
         %{
           server_name: "minga",
           message: %{
             "jsonrpc" => "2.0",
             "id" => 7,
             "method" => "tools/call",
             "params" => %{
               "name" => "read_file",
               "arguments" => %{},
               "_meta" => %{"claudecode/toolUseId" => tool_use_id}
             }
           }
         }}
    }
  end

  defp tool_use_events(id, index) do
    [
      event({:content_block_start, index, {:tool_use, id, "mcp__minga__read_file", %{}}}),
      event({:content_block_delta, index, {:input_json_delta, ~s({"path":)}}),
      event({:content_block_delta, index, {:input_json_delta, ~s("a.txt"})}}),
      event({:content_block_stop, index})
    ]
  end

  defp ok!({:ok, state, _outcome}), do: state

  defp apply_events(state, events),
    do: Enum.reduce(events, state, &ok!(State.stream_event(&2, &1)))

  defp starting, do: State.new(initialize_id: "init", tools: @tools)

  defp idle, do: starting() |> State.control_response(init_ok()) |> ok!()

  defp unchecked, do: idle() |> State.request(prompt()) |> ok!()
  defp streaming, do: unchecked() |> State.system_init(init_frame()) |> ok!()

  defp awaiting(ids \\ ["t1"]) do
    events =
      ids
      |> Enum.with_index()
      |> Enum.flat_map(fn {id, index} -> tool_use_events(id, index) end)

    streaming()
    |> apply_events([event({:message_start, %{id: "m", model: "x", usage: nil}}) | events])
    |> State.stream_event(event(:message_stop))
    |> ok!()
  end

  defp interrupting, do: streaming() |> State.abort(:aborted) |> ok!()
  defp dead, do: idle() |> State.transport_down({:claude_exited, 1}) |> ok!()

  defp in_phase(:starting), do: starting()
  defp in_phase(:idle), do: idle()
  defp in_phase(:streaming), do: streaming()
  defp in_phase(:awaiting_tool_results), do: awaiting()
  defp in_phase(:interrupting), do: interrupting()
  defp in_phase(:dead), do: dead()

  defp outcome_tag(:ok), do: :ok
  defp outcome_tag({:ok, _state, outcome}) when is_atom(outcome), do: outcome
  defp outcome_tag({:ok, _state, outcome}) when is_tuple(outcome), do: elem(outcome, 0)
  defp outcome_tag({:error, {tag, _detail}}), do: {:error, tag}

  # Every transition in every phase: the expected outcome tag, or `{:error, tag}` for a rejection.
  @table [
    {"system_init", &__MODULE__.input_system_init/1,
     %{
       starting: {:error, :invalid_phase},
       idle: {:error, :invalid_phase},
       streaming: :checked,
       awaiting_tool_results: {:error, :invalid_phase},
       interrupting: {:error, :invalid_phase},
       dead: {:error, :invalid_phase}
     }},
    {"initialize response", &__MODULE__.input_initialize_response/1,
     %{
       starting: :ready,
       idle: :ignored,
       streaming: :ignored,
       awaiting_tool_results: :ignored,
       interrupting: :ignored,
       dead: {:error, :invalid_phase}
     }},
    {"prompt request", &__MODULE__.input_prompt/1,
     %{
       starting: :queued,
       idle: :prompt,
       streaming: {:error, :invalid_phase},
       awaiting_tool_results: {:error, :invalid_phase},
       interrupting: {:error, :invalid_phase},
       dead: {:error, :session_dead}
     }},
    {"tool results request", &__MODULE__.input_tool_results/1,
     %{
       starting: {:error, :invalid_phase},
       idle: {:error, :invalid_tool_results},
       streaming: {:error, :invalid_phase},
       awaiting_tool_results: :tool_results,
       interrupting: {:error, :invalid_phase},
       dead: {:error, :session_dead}
     }},
    {"stream event", &__MODULE__.input_stream_event/1,
     %{
       starting: {:error, :invalid_phase},
       idle: {:error, :invalid_phase},
       streaming: :emit,
       awaiting_tool_results: {:error, :invalid_phase},
       interrupting: :ignored,
       dead: {:error, :invalid_phase}
     }},
    {"assistant frame", &__MODULE__.input_assistant/1,
     %{
       starting: {:error, :invalid_phase},
       idle: {:error, :invalid_phase},
       streaming: :emit,
       awaiting_tool_results: {:error, :invalid_phase},
       interrupting: :ignored,
       dead: {:error, :invalid_phase}
     }},
    {"end fallback message", &State.end_fallback_message/1,
     %{
       starting: {:error, :invalid_phase},
       idle: {:error, :invalid_phase},
       streaming: :unchanged,
       awaiting_tool_results: {:error, :invalid_phase},
       interrupting: {:error, :invalid_phase},
       dead: {:error, :invalid_phase}
     }},
    {"tools/call", &__MODULE__.input_tools_call/1,
     %{
       starting: :reply,
       idle: :reply,
       streaming: :held,
       awaiting_tool_results: :held,
       interrupting: :reply,
       dead: {:error, :invalid_phase}
     }},
    {"can_use_tool", &__MODULE__.input_can_use_tool/1,
     %{
       starting: :reply,
       idle: :reply,
       streaming: :reply,
       awaiting_tool_results: :reply,
       interrupting: :reply,
       dead: {:error, :invalid_phase}
     }},
    {"result", &__MODULE__.input_result/1,
     %{
       starting: {:error, :invalid_phase},
       idle: {:error, :invalid_phase},
       streaming: :finish,
       awaiting_tool_results: :abandoned,
       interrupting: :interrupted,
       dead: {:error, :invalid_phase}
     }},
    {"abort", &__MODULE__.input_abort/1,
     %{
       starting: {:error, :invalid_phase},
       idle: {:error, :invalid_phase},
       streaming: :interrupt,
       awaiting_tool_results: :interrupt,
       interrupting: {:error, :invalid_phase},
       dead: {:error, :invalid_phase}
     }},
    {"interrupt timeout", &State.interrupt_timeout/1,
     %{
       starting: {:error, :invalid_phase},
       idle: {:error, :invalid_phase},
       streaming: {:error, :invalid_phase},
       awaiting_tool_results: {:error, :invalid_phase},
       interrupting: :dead,
       dead: {:error, :invalid_phase}
     }},
    {"startup timeout", &State.startup_timeout/1,
     %{
       starting: :dead,
       idle: {:error, :invalid_phase},
       streaming: {:error, :invalid_phase},
       awaiting_tool_results: {:error, :invalid_phase},
       interrupting: {:error, :invalid_phase},
       dead: {:error, :invalid_phase}
     }},
    {"idle timeout", &State.idle_timeout/1,
     %{
       starting: {:error, :invalid_phase},
       idle: :dead,
       streaming: {:error, :invalid_phase},
       awaiting_tool_results: {:error, :invalid_phase},
       interrupting: {:error, :invalid_phase},
       dead: {:error, :invalid_phase}
     }},
    {"client control request", &State.control/1,
     %{
       starting: {:error, :invalid_phase},
       idle: :ok,
       streaming: {:error, :invalid_phase},
       awaiting_tool_results: {:error, :invalid_phase},
       interrupting: {:error, :invalid_phase},
       dead: {:error, :invalid_phase}
     }},
    {"transport down", &__MODULE__.input_transport_down/1,
     %{
       starting: :dead,
       idle: :dead,
       streaming: :dead,
       awaiting_tool_results: :dead,
       interrupting: :dead,
       dead: {:error, :invalid_phase}
     }}
  ]

  def input_system_init(state), do: State.system_init(state, init_frame())
  def input_initialize_response(state), do: State.control_response(state, init_ok())
  def input_prompt(state), do: State.request(state, prompt())
  def input_tool_results(state), do: State.request(state, results(["t1"]))

  def input_stream_event(state),
    do: State.stream_event(state, event({:message_start, %{id: "m", model: "x", usage: nil}}))

  def input_assistant(state),
    do: State.assistant(state, %Assistant{id: "fb", content: [{:text, "x"}]})

  def input_tools_call(state), do: State.control_request(state, tools_call("c1", "t1"))

  def input_can_use_tool(state) do
    State.control_request(state, %ControlRequest{
      request_id: "c2",
      request: {:can_use_tool, %{tool_name: "Bash", input: %{}, tool_use_id: nil}}
    })
  end

  def input_result(state),
    do: State.result(state, %Result{subtype: :success, is_error: false, stop_reason: :end_turn})

  def input_abort(state), do: State.abort(state, :aborted)
  def input_transport_down(state), do: State.transport_down(state, {:claude_exited, 1})

  describe "transition table" do
    for {name, _fun, _expected} <- @table do
      test "#{name} covers every phase" do
        {_name, fun, expected} = List.keyfind(@table, unquote(name), 0)
        assert Map.keys(expected) |> Enum.sort() == Enum.sort(@phases)

        for phase <- @phases do
          result = fun.(in_phase(phase))

          assert outcome_tag(result) == Map.fetch!(expected, phase),
                 "#{unquote(name)} in #{phase}: #{inspect(outcome_tag(result))}"
        end
      end
    end

    test "a rejected input leaves the state unchanged" do
      state = idle()

      assert {:error, {:invalid_phase, :idle}} =
               State.result(state, %Result{subtype: :success, is_error: false})

      assert State.phase_tag(state) == :idle
    end
  end

  describe "startup" do
    test "a successful initialize answer completes startup and keeps the account and models" do
      assert State.info(starting()) == nil
      assert {:ok, state, :ready} = State.control_response(starting(), init_ok())
      assert State.phase_tag(state) == :idle

      assert State.info(state) == %{
               account: @account,
               models: @models,
               claude_code_version: "2.1.330"
             }
    end

    test "a queued prompt starts streaming when startup completes" do
      request = prompt()
      {:ok, state, :queued} = State.request(starting(), request)

      assert {:ok, state, {:ready, {:prompt, ^request}}} =
               State.control_response(state, init_ok())

      assert State.phase_tag(state) == :streaming
    end

    test "only one prompt can be queued" do
      {:ok, state, :queued} = State.request(starting(), prompt())
      assert {:error, {:invalid_phase, :starting}} = State.request(state, prompt())
    end

    test "aborting a queued prompt drops it" do
      {:ok, state, :queued} = State.request(starting(), prompt())
      assert {:ok, state, :dequeued} = State.abort(state, :aborted)
      assert {:ok, _state, :ready} = State.control_response(state, init_ok())
    end

    test "the MCP initialize request is answered while starting" do
      request = %ControlRequest{
        request_id: "m1",
        request:
          {:mcp_message,
           %{
             server_name: "minga",
             message: %{
               "jsonrpc" => "2.0",
               "id" => 0,
               "method" => "initialize",
               "params" => %{"protocolVersion" => "2025-11-25"}
             }
           }}
      }

      assert {:ok, _state, {:reply, line}} = State.control_request(starting(), request)

      assert JSON.decode!(line)["response"]["response"]["mcp_response"]["result"][
               "protocolVersion"
             ] == "2025-11-25"
    end

    test "a version below the minimum kills the session" do
      state = State.new(initialize_id: "init", min_version: "2.1.300")

      for version <- ["2.1.299", nil, "garbage"] do
        assert {:ok, dead, {:dead, {:unsupported_version, ^version}}} =
                 State.control_response(state, init_ok(version))

        assert State.phase_tag(dead) == :dead
      end

      assert {:ok, _state, :ready} = State.control_response(state, init_ok("2.1.300"))
    end

    test "an initialize error kills the session" do
      response = %ControlResponse{request_id: "init", outcome: {:error, "nope"}}

      assert {:ok, _state, {:dead, {:initialize_failed, "nope"}}} =
               State.control_response(starting(), response)
    end
  end

  describe "query tool check" do
    test "a built-in tool kills the session" do
      frame = init_frame(tools: ["mcp__minga__read_file", "Bash", "Read"])

      assert {:ok, state, {:dead, {:unexpected_tools, ["Bash", "Read"]}}} =
               State.system_init(unchecked(), frame)

      assert State.phase_tag(state) == :dead
    end

    test "another MCP server kills the session" do
      frame = init_frame(servers: [%{name: "minga", status: nil}, %{name: "github", status: nil}])

      assert {:ok, _state, {:dead, {:unexpected_tools, ["mcp_server:github"]}}} =
               State.system_init(unchecked(), frame)
    end

    test "model output before the query's system/init kills the session" do
      start = event({:message_start, %{id: "m", model: "x", usage: nil}})
      assert {:ok, _state, {:dead, :missing_system_init}} = State.stream_event(unchecked(), start)

      assert {:ok, _state, {:dead, :missing_system_init}} =
               State.assistant(unchecked(), %Assistant{id: "fb", content: [{:text, "x"}]})

      assert {:ok, _state, {:dead, :missing_system_init}} =
               State.control_request(unchecked(), tools_call("c1", "t1"))
    end

    test "tool results continue a checked query without a new system/init" do
      {:ok, state, {:tool_results, []}} = State.request(awaiting(["t1"]), results(["t1"]))
      start = event({:message_start, %{id: "m2", model: "x", usage: nil}})
      assert {:ok, _state, {:emit, []}} = State.stream_event(state, start)
    end

    test "each new prompt needs its own system/init" do
      {:ok, state, _finish} =
        State.result(streaming(), %Result{subtype: :success, is_error: false})

      {:ok, state, {:prompt, _request}} = State.request(state, prompt())
      start = event({:message_start, %{id: "m", model: "x", usage: nil}})
      assert {:ok, _state, {:dead, :missing_system_init}} = State.stream_event(state, start)
    end
  end

  describe "non-streaming fallback" do
    test "a fallback message with tool_use suspends when the fallback ends" do
      frames = [
        %Assistant{id: "fb", content: [{:text, "Let me look"}]},
        %Assistant{
          id: "fb",
          content: [{:tool_use, "t1", "mcp__minga__read_file", %{"path" => "a"}}]
        }
      ]

      {state, events} =
        Enum.reduce(frames, {streaming(), []}, fn frame, {state, acc} ->
          {:ok, state, {:emit, emitted}} = State.assistant(state, frame)
          {state, acc ++ emitted}
        end)

      assert events == [{:text, "Let me look"}]

      assert {:ok, state,
              {:suspend, [%{id: "t1", name: "read_file", arguments: %{"path" => "a"}}], nil}} =
               State.end_fallback_message(state)

      assert State.phase_tag(state) == :awaiting_tool_results
    end

    test "assistant frames of a streamed message yield nothing" do
      state =
        apply_events(streaming(), [event({:message_start, %{id: "m", model: "x", usage: nil}})])

      assert {:ok, _state, {:emit, []}} =
               State.assistant(state, %Assistant{id: "m", content: [{:text, "dup"}]})
    end
  end

  describe "tool calls" do
    test "message_stop suspends with every completed tool_use, in order" do
      state = apply_events(streaming(), tool_use_events("t1", 0) ++ tool_use_events("t2", 1))

      assert {:ok, state, {:suspend, calls, nil}} =
               State.stream_event(state, event(:message_stop))

      assert calls == [
               %{id: "t1", name: "read_file", arguments: %{"path" => "a.txt"}},
               %{id: "t2", name: "read_file", arguments: %{"path" => "a.txt"}}
             ]

      assert State.phase_tag(state) == :awaiting_tool_results
    end

    test "message_stop without tool_use keeps streaming" do
      assert {:ok, state, {:emit, []}} = State.stream_event(streaming(), event(:message_stop))
      assert State.phase_tag(state) == :streaming
    end

    test "subagent events are ignored" do
      sub = event({:content_block_start, 0, {:text, "x"}}, "toolu_parent")
      assert {:ok, _state, :ignored} = State.stream_event(streaming(), sub)
    end

    test "a call held before message_stop is answered by its result" do
      state = streaming() |> apply_events(tool_use_events("t1", 0))
      {:ok, state, :held} = State.control_request(state, tools_call("c1", "t1"))
      {:ok, state, {:suspend, _calls, _usage}} = State.stream_event(state, event(:message_stop))

      assert {:ok, state, {:tool_results, [line]}} = State.request(state, results(["t1"]))
      assert %{"request_id" => "c1", "subtype" => "success"} = JSON.decode!(line)["response"]
      assert State.phase_tag(state) == :streaming
    end

    test "a result delivered before its call answers the call when it arrives" do
      {:ok, state, {:tool_results, [line_a]}} =
        awaiting(["t1", "t2"])
        |> State.control_request(tools_call("c1", "t1"))
        |> ok!()
        |> State.request(results(["t1", "t2"]))

      assert JSON.decode!(line_a)["response"]["request_id"] == "c1"

      assert {:ok, state, {:reply, line_b}} = State.control_request(state, tools_call("c2", "t2"))
      response = JSON.decode!(line_b)["response"]
      assert response["request_id"] == "c2"

      assert response["response"]["mcp_response"]["result"]["content"] == [
               %{"type" => "text", "text" => "ok t2"}
             ]

      # A second call for the same id is held, not answered from the used result.
      assert {:ok, _state, :held} = State.control_request(state, tools_call("c3", "t2"))
    end

    test "duplicate, unknown, and missing result ids are rejected without changing the state" do
      state = awaiting(["t1", "t2"])

      assert {:error, {:invalid_tool_results, {:duplicate_tool_use, ["t1"]}}} =
               State.request(state, results(["t1", "t1", "t2"]))

      assert {:error, {:invalid_tool_results, {:unknown_tool_use, ["zz"]}}} =
               State.request(state, results(["t1", "t2", "zz"]))

      assert {:error, {:invalid_tool_results, {:missing_tool_results, ["t2"]}}} =
               State.request(state, results(["t1"]))

      assert State.phase_tag(state) == :awaiting_tool_results
      assert {:ok, _state, {:tool_results, []}} = State.request(state, results(["t2", "t1"]))
    end

    test "abort cancels held calls with -32800 and drops waiting results" do
      state = awaiting(["t1"]) |> State.control_request(tools_call("c1", "t1")) |> ok!()
      assert {:ok, state, {:interrupt, [line]}} = State.abort(state, :aborted)

      assert JSON.decode!(line)["response"]["response"]["mcp_response"]["error"]["code"] ==
               -32_800

      assert State.phase_tag(state) == :interrupting
    end

    for phase <- [:starting, :idle, :interrupting] do
      test "a tools/call while #{phase} is cancelled, not held" do
        state = in_phase(unquote(phase))
        assert {:ok, state, {:reply, line}} = State.control_request(state, tools_call("c9", "t9"))

        assert JSON.decode!(line)["response"]["response"]["mcp_response"]["error"]["code"] ==
                 -32_800

        # It was not held: aborting or resolving finds nothing.
        assert State.phase_tag(state) == unquote(phase)
      end
    end

    test "a tools/call after an aborted turn returned to idle is cancelled" do
      state = awaiting(["t1"]) |> State.abort(:aborted) |> ok!()
      state = state |> State.result(%Result{subtype: :success, is_error: false}) |> ok!()
      assert {:ok, _state, {:reply, line}} = State.control_request(state, tools_call("c1", "t1"))

      assert JSON.decode!(line)["response"]["response"]["mcp_response"]["error"]["code"] ==
               -32_800
    end

    test "a duplicate tools/call is answered with an error" do
      state = awaiting(["t1"]) |> State.control_request(tools_call("c1", "t1")) |> ok!()
      assert {:ok, _state, {:reply, line}} = State.control_request(state, tools_call("c2", "t1"))

      assert JSON.decode!(line)["response"]["response"]["mcp_response"]["error"]["code"] ==
               -32_602
    end

    test "requests for other MCP servers and unknown subtypes get a control error" do
      other = %ControlRequest{
        request_id: "c5",
        request:
          {:mcp_message,
           %{server_name: "github", message: %{"method" => "tools/list", "id" => 1}}}
      }

      assert {:ok, _state, {:reply, line}} = State.control_request(streaming(), other)
      assert %{"subtype" => "error", "request_id" => "c5"} = JSON.decode!(line)["response"]

      unknown = %ControlRequest{request_id: "c6", request: {:unknown_request, "hook_callback"}}
      assert {:ok, _state, {:reply, line}} = State.control_request(streaming(), unknown)
      assert %{"subtype" => "error"} = JSON.decode!(line)["response"]
    end

    test "tools/list uses the tools of the latest request" do
      list = %ControlRequest{
        request_id: "c7",
        request:
          {:mcp_message,
           %{
             server_name: "minga",
             message: %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}
           }}
      }

      tools = [%{name: "grep", description: "", input_schema: %{"type" => "object"}}]
      {:ok, state, _prompt} = State.request(idle(), Request.prompt("x", tools))
      {:ok, _state, {:reply, line}} = State.control_request(state, list)

      assert [%{"name" => "grep"}] =
               JSON.decode!(line)["response"]["response"]["mcp_response"]["result"]["tools"]
    end
  end

  describe "result" do
    defp finish(result, events \\ []) do
      {:ok, state, {:finish, usage, reason}} =
        streaming() |> apply_events(events) |> State.result(result)

      assert State.phase_tag(state) == :idle
      {usage, reason}
    end

    test "maps stop reasons" do
      for {stop, reason} <- [
            end_turn: :stop,
            stop_sequence: :stop,
            max_tokens: :length,
            model_context_window_exceeded: :length,
            refusal: :refusal,
            pause_turn: :stop
          ] do
        assert {_usage, ^reason} =
                 finish(%Result{subtype: :success, is_error: false, stop_reason: stop})
      end
    end

    test "the streamed stop reason wins over the result's" do
      events = [
        event({:message_delta, %{stop_reason: :max_tokens, stop_sequence: nil, usage: nil}})
      ]

      assert {_usage, :length} =
               finish(%Result{subtype: :success, is_error: false, stop_reason: :end_turn}, events)
    end

    test "an error result finishes with an error" do
      assert {_usage, {:error, {:claude_error, :success, "boom"}}} =
               finish(%Result{subtype: :success, is_error: true, result: "boom"})

      assert {_usage, {:error, {:claude_error, :error_max_turns, "a\nb"}}} =
               finish(%Result{subtype: :error_max_turns, is_error: true, errors: ["a", "b"]})
    end

    test "uses streamed usage and falls back to the result's usage" do
      usage = %Usage{
        input_tokens: 10,
        output_tokens: 1,
        cache_read_input_tokens: 3,
        cache_creation_input_tokens: 4
      }

      events = [
        event({:message_start, %{id: "m", model: "x", usage: usage}}),
        event(
          {:message_delta,
           %{stop_reason: :end_turn, stop_sequence: nil, usage: %Usage{output_tokens: 9}}}
        ),
        event(:message_stop)
      ]

      result = %Result{
        subtype: :success,
        is_error: false,
        usage: %Usage{input_tokens: 999, output_tokens: 999}
      }

      assert {%{input_tokens: 10, output_tokens: 9, cache_read_tokens: 3, cache_write_tokens: 4},
              :stop} =
               finish(result, events)

      assert {%{input_tokens: 999, output_tokens: 999}, :stop} = finish(result)
    end

    test "all-zero usage is ignored" do
      zero = %Usage{
        input_tokens: 0,
        output_tokens: 0,
        cache_read_input_tokens: 0,
        cache_creation_input_tokens: 0
      }

      assert {nil, :stop} = finish(%Result{subtype: :success, is_error: false, usage: zero})
    end
  end
end
