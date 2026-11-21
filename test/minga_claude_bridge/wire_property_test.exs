defmodule MingaClaudeBridge.WirePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MingaClaudeBridge.Wire
  alias MingaClaudeBridge.Wire.{ControlRequest, ControlResponse, User}

  defp text, do: string(:utf8, max_length: 40)
  defp id, do: string(:alphanumeric, min_length: 1, max_length: 24)

  defp json_scalar, do: one_of([text(), integer(), boolean(), constant(nil)])

  defp json_object do
    map_of(text(), one_of([json_scalar(), list_of(json_scalar(), max_length: 3)]), max_length: 4)
  end

  defp jsonrpc_id, do: one_of([id(), integer()])

  defp block do
    one_of([
      map(text(), &{:text, &1}),
      map({text(), one_of([constant(nil), text()])}, fn {thinking, signature} ->
        {:thinking, thinking, signature}
      end),
      map(text(), &{:redacted_thinking, &1}),
      map({id(), id(), json_object()}, fn {id, name, input} -> {:tool_use, id, name, input} end),
      map(
        {id(), one_of([text(), list_of(map(text(), &{:text, &1}), max_length: 3)]), boolean()},
        fn {id, content, is_error} -> {:tool_result, id, content, is_error} end
      )
    ])
  end

  defp optional(gen), do: one_of([constant(nil), gen])

  property "user_message/2 decodes back to the same content and envelope" do
    check all(
            blocks <- list_of(block(), max_length: 5),
            session_id <- optional(id()),
            uuid <- optional(id())
          ) do
      line = Wire.user_message(blocks, session_id: session_id, uuid: uuid)

      assert {:ok,
              %User{
                content: ^blocks,
                session_id: ^session_id,
                uuid: ^uuid,
                parent_tool_use_id: nil,
                synthetic: false
              }} = Wire.decode(line)
    end
  end

  property "initialize/2 decodes back to the same request" do
    check all(
            request_id <- id(),
            servers <- optional(list_of(id(), max_length: 3)),
            system_prompt <- optional(one_of([text(), list_of(text(), max_length: 3)])),
            append <- optional(text())
          ) do
      line =
        Wire.initialize(request_id,
          sdk_mcp_servers: servers,
          system_prompt: system_prompt,
          append_system_prompt: append
        )

      expected_prompt = if is_binary(system_prompt), do: [system_prompt], else: system_prompt

      assert Wire.decode(line) ==
               {:ok,
                %ControlRequest{
                  request_id: request_id,
                  request:
                    {:initialize,
                     %{
                       sdk_mcp_servers: servers,
                       system_prompt: expected_prompt,
                       append_system_prompt: append
                     }}
                }}
    end
  end

  property "interrupt/1 decodes back to an interrupt request" do
    check all(request_id <- id()) do
      assert Wire.decode(Wire.interrupt(request_id)) ==
               {:ok, %ControlRequest{request_id: request_id, request: :interrupt}}
    end
  end

  property "control responses decode back to the same outcome" do
    check all(
            request_id <- id(),
            rpc_id <- jsonrpc_id(),
            result <- json_object(),
            code <- integer(-32_800..-32_000),
            message <- text()
          ) do
      assert Wire.decode(Wire.mcp_result(request_id, rpc_id, result)) ==
               {:ok,
                %ControlResponse{
                  request_id: request_id,
                  outcome:
                    {:ok,
                     %{
                       "mcp_response" => %{"jsonrpc" => "2.0", "id" => rpc_id, "result" => result}
                     }}
                }}

      assert Wire.decode(Wire.mcp_error(request_id, rpc_id, code, message)) ==
               {:ok,
                %ControlResponse{
                  request_id: request_id,
                  outcome:
                    {:ok,
                     %{
                       "mcp_response" => %{
                         "jsonrpc" => "2.0",
                         "id" => rpc_id,
                         "error" => %{"code" => code, "message" => message}
                       }
                     }}
                }}

      assert Wire.decode(Wire.control_error(request_id, message)) ==
               {:ok, %ControlResponse{request_id: request_id, outcome: {:error, message}}}
    end
  end

  property "every encoded frame is exactly one newline-terminated line" do
    check all(blocks <- list_of(block(), max_length: 3), request_id <- id()) do
      for line <- [
            Wire.user_message(blocks),
            Wire.initialize(request_id, system_prompt: "a\nb"),
            Wire.interrupt(request_id),
            Wire.control_error(request_id, "x\ny")
          ] do
        assert [_json, ""] = String.split(line, "\n")
      end
    end
  end

  property "decode/1 never raises on arbitrary bytes" do
    check all(bytes <- binary(max_length: 200)) do
      assert {tag, _value} = Wire.decode(bytes)
      assert tag in [:ok, :error]
    end
  end

  @frame_types ~w(system stream_event assistant user result rate_limit_event control_request control_response control_cancel_request keep_alive)
  @field_names ~w(subtype session_id tools mcp_servers event message request request_id response rate_limit_info is_error usage content index delta type)

  @vocabulary ~w(init success error mcp_message can_use_tool initialize interrupt message_start content_block_start content_block_delta message_delta text_delta thinking_delta input_json_delta text thinking tool_use tool_result)

  defp fuzz_scalar, do: one_of([json_scalar(), member_of(@vocabulary)])

  defp json_value(depth) when depth <= 0, do: fuzz_scalar()

  defp json_value(depth) do
    one_of([
      fuzz_scalar(),
      list_of(json_value(depth - 1), max_length: 3),
      map_of(member_of(@field_names), json_value(depth - 1), max_length: 4)
    ])
  end

  property "decode/1 never raises on well-formed JSON with malformed frame fields" do
    check all(
            type <- member_of(@frame_types),
            fields <- map_of(member_of(@field_names), json_value(3), max_length: 6)
          ) do
      line = JSON.encode!(Map.put(fields, "type", type))
      assert {tag, _value} = Wire.decode(line)
      assert tag in [:ok, :error]
    end
  end
end
