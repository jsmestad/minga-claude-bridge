defmodule MingaClaudeBridge.WireTest do
  use ExUnit.Case, async: true

  alias MingaClaudeBridge.Wire

  alias MingaClaudeBridge.Wire.{
    Assistant,
    ControlCancel,
    ControlRequest,
    ControlResponse,
    RateLimit,
    Result,
    StreamEvent,
    SystemInit,
    Unknown,
    Usage,
    User
  }

  @fixtures Path.expand("../fixtures", __DIR__)

  defp fixture_lines(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp decode_fixture(name) do
    Enum.map(fixture_lines(name), fn line ->
      assert {:ok, frame} = Wire.decode(line)
      frame
    end)
  end

  defp event(%StreamEvent{event: event}), do: event

  describe "decode/1 system init" do
    test "reads the startup facts the bridge checks before the first prompt" do
      [full, minimal, unexpected] = decode_fixture("system_init.jsonl")

      assert %SystemInit{
               session_id: "9b2c7f1e-6a41-4c55-9d1e-2f0a8c3b7e10",
               tools: ["mcp__minga__read_file", "mcp__minga__shell"],
               mcp_servers: [%{name: "minga", status: "connected"}],
               model: "claude-sonnet-4-6",
               claude_code_version: "2.1.150",
               permission_mode: :default,
               cwd: "/tmp/minga-claude-bridge/q1"
             } = full

      assert %SystemInit{
               session_id: "s-2",
               tools: [],
               mcp_servers: [],
               model: nil,
               claude_code_version: nil,
               permission_mode: :accept_edits
             } = minimal

      assert %SystemInit{
               tools: ["Bash"],
               mcp_servers: [%{name: "github", status: "failed"}],
               permission_mode: {:other, "someFutureMode"}
             } = unexpected
    end
  end

  describe "decode/1 stream events" do
    test "decodes every Messages API stream event into the tagged event sum" do
      frames = decode_fixture("stream_events.jsonl")

      expected = [
        {:message_start,
         %{
           id: "msg_01Abc",
           model: "claude-sonnet-4-6",
           usage: %Usage{
             input_tokens: 12,
             output_tokens: 1,
             cache_creation_input_tokens: 2048,
             cache_read_input_tokens: 0
           }
         }},
        {:content_block_start, 0, {:thinking, "", ""}},
        {:content_block_delta, 0, {:thinking_delta, "The user wants the file."}},
        {:content_block_delta, 0, {:signature_delta, "EqQBCkYIBxgCKkA"}},
        {:content_block_stop, 0},
        {:content_block_start, 1, {:text, ""}},
        {:content_block_delta, 1, {:text_delta, "Reading it now."}},
        {:content_block_start, 2, {:tool_use, "toolu_01XYZ", "mcp__minga__read_file", %{}}},
        {:content_block_delta, 2, {:input_json_delta, "{\"path\": \"lib/"}},
        {:message_delta,
         %{stop_reason: :tool_use, stop_sequence: nil, usage: %Usage{output_tokens: 87}}},
        :message_stop,
        :ping,
        {:stream_error, %{type: "overloaded_error", message: "Overloaded"}},
        {:content_block_delta, 1, {:unknown_delta, "future_delta"}},
        {:unknown_event, "future_event"},
        {:message_delta,
         %{
           stop_reason: {:other, "brand_new_reason"},
           stop_sequence: nil,
           usage: %Usage{output_tokens: 3}
         }}
      ]

      assert Enum.map(frames, &event/1) == expected
    end

    test "keeps the frame envelope" do
      [first | _] = decode_fixture("stream_events.jsonl")
      assert %StreamEvent{parent_tool_use_id: nil, session_id: "s-1", uuid: "u-1"} = first

      subagent = Enum.at(decode_fixture("stream_events.jsonl"), 13)
      assert subagent.parent_tool_use_id == "toolu_parent"
    end
  end

  describe "decode/1 messages" do
    test "decodes assistant and user messages into block lists" do
      [tool_use, synthetic, tool_result, prompt, image] = decode_fixture("messages.jsonl")

      assert %Assistant{
               id: "msg_01Abc",
               model: "claude-sonnet-4-6",
               content: [
                 {:tool_use, "toolu_01XYZ", "mcp__minga__read_file", %{"path" => "lib/minga.ex"}}
               ],
               stop_reason: nil,
               usage: %Usage{output_tokens: 87},
               error: nil,
               parent_tool_use_id: nil,
               session_id: "s-1",
               uuid: "a-1"
             } = tool_use

      assert %Assistant{
               model: "<synthetic>",
               stop_reason: :stop_sequence,
               error: :overloaded,
               usage: %Usage{input_tokens: 0, output_tokens: 0}
             } = synthetic

      assert %User{
               content: [
                 {:tool_result, "toolu_01XYZ", [{:text, "defmodule Minga do"}], false}
               ],
               synthetic: false,
               uuid: "m-1"
             } = tool_result

      assert %User{content: [{:text, "What does lib/minga.ex do?"}], synthetic: true} = prompt

      assert %User{content: [{:text, "See this"}, {:other, %{"type" => "image"}}]} = image
    end
  end

  describe "decode/1 results" do
    test "decodes success, error subtypes, and success-with-error" do
      [success, aborted, limited] = decode_fixture("results.jsonl")

      assert %Result{
               subtype: :success,
               is_error: false,
               result: "lib/minga.ex defines the application entry point.",
               errors: [],
               session_id: "s-1",
               total_cost_usd: 0.0123,
               num_turns: 2,
               duration_ms: 4211,
               stop_reason: :end_turn,
               usage: %Usage{
                 input_tokens: 24,
                 output_tokens: 312,
                 cache_creation_input_tokens: 2048,
                 cache_read_input_tokens: 4096
               }
             } = success

      assert %Result{
               subtype: :error_during_execution,
               is_error: true,
               result: nil,
               errors: ["Request was aborted."],
               total_cost_usd: 0
             } = aborted

      assert %Result{subtype: :success, is_error: true, result: "Claude AI usage limit" <> _} =
               limited
    end
  end

  describe "decode/1 rate limits" do
    test "decodes status, window, reset time, and utilization" do
      assert [
               %RateLimit{
                 status: :allowed_warning,
                 rate_limit_type: :five_hour,
                 resets_at: 1_767_225_600,
                 utilization: 0.82,
                 session_id: "s-1"
               },
               %RateLimit{status: :rejected, rate_limit_type: :seven_day, utilization: 1.0},
               %RateLimit{
                 status: :allowed,
                 rate_limit_type: {:other, "seven_day_fable"},
                 resets_at: nil,
                 utilization: nil
               }
             ] = decode_fixture("rate_limits.jsonl")
    end
  end

  describe "decode/1 control frames" do
    test "decodes requests, responses, and cancellations" do
      expected = [
        %ControlRequest{
          request_id: "req_1",
          request:
            {:mcp_message,
             %{
               server_name: "minga",
               message: %{
                 "jsonrpc" => "2.0",
                 "id" => 3,
                 "method" => "tools/call",
                 "params" => %{
                   "name" => "read_file",
                   "arguments" => %{"path" => "lib/minga.ex"},
                   "_meta" => %{"claudecode/toolUseId" => "toolu_01XYZ"}
                 }
               }
             }}
        },
        %ControlRequest{
          request_id: "req_2",
          request:
            {:mcp_message,
             %{
               server_name: "minga",
               message: %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
             }}
        },
        %ControlRequest{
          request_id: "req_3",
          request:
            {:can_use_tool,
             %{
               tool_name: "mcp__minga__shell",
               input: %{"command" => "ls"},
               tool_use_id: "toolu_02"
             }}
        },
        %ControlRequest{request_id: "req_4", request: {:unknown_request, "hook_callback"}},
        %ControlResponse{
          request_id: "init_1",
          outcome: {:ok, %{"commands" => [], "models" => [], "account" => %{}}}
        },
        %ControlResponse{request_id: "int_1", outcome: {:ok, %{}}},
        %ControlResponse{
          request_id: "init_2",
          outcome: {:error, "Unknown SDK MCP server: minga"}
        },
        %ControlCancel{request_id: "req_1"}
      ]

      assert decode_fixture("control.jsonl") == expected
    end
  end

  describe "decode/1 unknown frames" do
    test "wraps unmodeled types and non-init system frames in Unknown" do
      assert [
               %Unknown{type: "keep_alive", raw: %{"type" => "keep_alive"}},
               %Unknown{type: "system", raw: %{"subtype" => "api_retry"}},
               %Unknown{type: "system", raw: %{"subtype" => "compact_boundary"}},
               %Unknown{type: "tool_progress"}
             ] = decode_fixture("unknown.jsonl")
    end
  end

  describe "decode/1 errors" do
    test "rejects input without raising" do
      cases = [
        {"", {:invalid_json, {:unexpected_end, 0}}},
        {"{", {:invalid_json, {:unexpected_end, 1}}},
        {"{\"type\":\"user\"", {:invalid_json, {:unexpected_end, 14}}},
        {<<0xFF>>, {:invalid_json, {:invalid_byte, 0}}},
        {"[1,2]", :not_a_frame},
        {"\"user\"", :not_a_frame},
        {"{\"subtype\":\"init\"}", :not_a_frame},
        {"{\"type\":7}", :not_a_frame},
        {~s({"type":"system","subtype":"init","tools":[]}), {:invalid_frame, "system"}},
        {~s({"type":"system","subtype":"init","session_id":"s","tools":[1],"mcp_servers":[]}),
         {:invalid_frame, "system"}},
        {~s({"type":"stream_event"}), {:invalid_frame, "stream_event"}},
        {~s({"type":"stream_event","event":{"type":"content_block_delta","index":-1,"delta":{"type":"text_delta","text":"x"}}}),
         {:invalid_frame, "stream_event"}},
        {~s({"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta"}}}),
         {:invalid_frame, "stream_event"}},
        {~s({"type":"stream_event","event":{"type":"message_start","message":{"usage":{"input_tokens":"many"}}}}),
         {:invalid_frame, "stream_event"}},
        {~s({"type":"assistant","message":{"content":[{"type":"tool_use","id":"t"}]}}),
         {:invalid_frame, "assistant"}},
        {~s({"type":"user","message":{"content":7}}), {:invalid_frame, "user"}},
        {~s({"type":"result","subtype":"success"}), {:invalid_frame, "result"}},
        {~s({"type":"rate_limit_event","rate_limit_info":{}}),
         {:invalid_frame, "rate_limit_event"}},
        {~s({"type":"control_request","request_id":"r","request":{"subtype":"mcp_message","server_name":"minga"}}),
         {:invalid_frame, "control_request"}},
        {~s({"type":"control_request","request":{"subtype":"interrupt"}}),
         {:invalid_frame, "control_request"}},
        {~s({"type":"control_response","response":{"subtype":"maybe","request_id":"r"}}),
         {:invalid_frame, "control_response"}},
        {~s({"type":"control_cancel_request"}), {:invalid_frame, "control_cancel_request"}}
      ]

      for {line, reason} <- cases do
        assert Wire.decode(line) == {:error, reason}, "line: #{inspect(line)}"
      end
    end

    test "accepts a trailing newline" do
      assert {:ok, %ControlCancel{request_id: "r"}} =
               Wire.decode(~s({"type":"control_cancel_request","request_id":"r"}\n))
    end
  end

  describe "encoders" do
    test "user_message/2 writes the SDKUserMessage input shape" do
      line = Wire.user_message("hello", uuid: "c-1")

      assert String.ends_with?(line, "\n")

      assert JSON.decode!(line) == %{
               "type" => "user",
               "message" => %{
                 "role" => "user",
                 "content" => [%{"type" => "text", "text" => "hello"}]
               },
               "parent_tool_use_id" => nil,
               "uuid" => "c-1"
             }
    end

    test "initialize/2 omits unset options and sends the system prompt as a list" do
      assert JSON.decode!(Wire.initialize("init_1")) == %{
               "type" => "control_request",
               "request_id" => "init_1",
               "request" => %{"subtype" => "initialize"}
             }

      line =
        Wire.initialize("init_2",
          sdk_mcp_servers: ["minga"],
          system_prompt: "You are Minga.",
          append_system_prompt: "Be brief."
        )

      assert JSON.decode!(line)["request"] == %{
               "subtype" => "initialize",
               "sdkMcpServers" => ["minga"],
               "systemPrompt" => ["You are Minga."],
               "appendSystemPrompt" => "Be brief."
             }
    end

    test "interrupt/1 writes a bare interrupt request" do
      assert JSON.decode!(Wire.interrupt("int_1")) == %{
               "type" => "control_request",
               "request_id" => "int_1",
               "request" => %{"subtype" => "interrupt"}
             }
    end

    test "mcp_result/3 and mcp_error/4 wrap the JSON-RPC reply in mcp_response" do
      assert JSON.decode!(Wire.mcp_result("req_1", 3, %{"content" => []})) == %{
               "type" => "control_response",
               "response" => %{
                 "subtype" => "success",
                 "request_id" => "req_1",
                 "response" => %{
                   "mcp_response" => %{
                     "jsonrpc" => "2.0",
                     "id" => 3,
                     "result" => %{"content" => []}
                   }
                 }
               }
             }

      assert JSON.decode!(Wire.mcp_error("req_1", "a", -32_800, "Request cancelled"))["response"][
               "response"
             ] == %{
               "mcp_response" => %{
                 "jsonrpc" => "2.0",
                 "id" => "a",
                 "error" => %{"code" => -32_800, "message" => "Request cancelled"}
               }
             }
    end

    test "mcp_error/4 encodes an unreadable request id as null" do
      assert JSON.decode!(Wire.mcp_error("req_1", nil, -32_600, "Invalid Request"))["response"][
               "response"
             ]["mcp_response"]["id"] == nil
    end

    test "control_error/2 writes an error response" do
      assert JSON.decode!(Wire.control_error("req_4", "unsupported")) == %{
               "type" => "control_response",
               "response" => %{
                 "subtype" => "error",
                 "request_id" => "req_4",
                 "error" => "unsupported"
               }
             }
    end
  end
end
