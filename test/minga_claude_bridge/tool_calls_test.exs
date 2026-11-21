defmodule MingaClaudeBridge.ToolCallsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MingaClaudeBridge.ToolCalls

  @ok_result %{content: [{:text, "done"}], is_error: false}

  defp held(tool_use_id, control_request_id \\ "req", jsonrpc_id \\ 1),
    do: %{
      tool_use_id: tool_use_id,
      control_request_id: control_request_id,
      jsonrpc_id: jsonrpc_id
    }

  defp hold!(calls, held) do
    {:ok, calls} = ToolCalls.hold(calls, held)
    calls
  end

  defp response(line), do: JSON.decode!(line)["response"]

  describe "hold/2" do
    test "holds distinct ids" do
      calls = ToolCalls.new() |> hold!(held("b")) |> hold!(held("a"))
      assert ToolCalls.pending_ids(calls) == ["a", "b"]
    end

    test "rejects a duplicate tool_use_id" do
      calls = hold!(ToolCalls.new(), held("a", "req_1"))
      assert ToolCalls.hold(calls, held("a", "req_2")) == {:error, :duplicate_tool_use}
    end
  end

  describe "resolve/3" do
    test "answers the held control request with the JSON-RPC id" do
      calls = hold!(ToolCalls.new(), held("toolu_1", "req_9", "rpc_3"))

      assert {:ok, line, calls} = ToolCalls.resolve(calls, "toolu_1", @ok_result)
      assert ToolCalls.pending_ids(calls) == []

      assert response(line) == %{
               "subtype" => "success",
               "request_id" => "req_9",
               "response" => %{
                 "mcp_response" => %{
                   "jsonrpc" => "2.0",
                   "id" => "rpc_3",
                   "result" => %{
                     "content" => [%{"type" => "text", "text" => "done"}],
                     "isError" => false
                   }
                 }
               }
             }
    end

    for {label, setup} <- [
          {"an id never held", []},
          {"an id already resolved", [:hold, :resolve]},
          {"an id after abort_all", [:hold, :abort]}
        ] do
      test "rejects #{label}" do
        calls =
          Enum.reduce(unquote(setup), ToolCalls.new(), fn
            :hold, calls -> hold!(calls, held("toolu_1"))
            :resolve, calls -> elem(ToolCalls.resolve(calls, "toolu_1", @ok_result), 2)
            :abort, calls -> elem(ToolCalls.abort_all(calls), 1)
          end)

        assert ToolCalls.resolve(calls, "toolu_1", @ok_result) == {:error, :unknown_tool_use}
      end
    end
  end

  describe "abort_all/1" do
    test "answers every held call with -32800 and empties the correlator" do
      calls =
        ToolCalls.new() |> hold!(held("b", "req_b", 2)) |> hold!(held("a", "req_a", "x"))

      assert {[line_a, line_b], calls} = ToolCalls.abort_all(calls)
      assert ToolCalls.pending_ids(calls) == []

      assert response(line_a)["request_id"] == "req_a"

      assert response(line_a)["response"]["mcp_response"] == %{
               "jsonrpc" => "2.0",
               "id" => "x",
               "error" => %{"code" => -32_800, "message" => "Request cancelled"}
             }

      assert response(line_b)["response"]["mcp_response"]["id"] == 2
    end

    test "returns no lines for an empty correlator" do
      assert {[], calls} = ToolCalls.abort_all(ToolCalls.new())
      assert ToolCalls.pending_ids(calls) == []
    end
  end

  describe "call_tool_result/1" do
    for {label, result, expected} <- [
          {"text", %{content: [{:text, "a"}, {:text, "b"}], is_error: false},
           %{
             "content" => [%{"type" => "text", "text" => "a"}, %{"type" => "text", "text" => "b"}],
             "isError" => false
           }},
          {"an image as base64",
           %{content: [{:image, "image/png", <<0, 1, 2>>}], is_error: false},
           %{
             "content" => [%{"type" => "image", "data" => "AAEC", "mimeType" => "image/png"}],
             "isError" => false
           }},
          {"an error", %{content: [{:text, "denied"}], is_error: true},
           %{"content" => [%{"type" => "text", "text" => "denied"}], "isError" => true}},
          {"empty content", %{content: [], is_error: false},
           %{"content" => [], "isError" => false}}
        ] do
      test "maps #{label}" do
        assert ToolCalls.call_tool_result(unquote(Macro.escape(result))) ==
                 unquote(Macro.escape(expected))
      end
    end
  end

  defp ids, do: uniq_list_of(string(:alphanumeric, min_length: 1, max_length: 8), max_length: 8)

  defp hold_all(ids) do
    Enum.reduce(ids, ToolCalls.new(), fn id, calls -> hold!(calls, held(id, "req_" <> id)) end)
  end

  property "every held id resolves once, in any order, to its own control request" do
    check all(
            ids <- ids(),
            keys <- list_of(integer(), length: length(ids))
          ) do
      order = ids |> Enum.zip(keys) |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

      {lines, calls} =
        Enum.map_reduce(order, hold_all(ids), fn id, calls ->
          assert {:ok, line, calls} = ToolCalls.resolve(calls, id, @ok_result)
          assert response(line)["request_id"] == "req_" <> id
          assert ToolCalls.resolve(calls, id, @ok_result) == {:error, :unknown_tool_use}
          {line, calls}
        end)

      assert length(lines) == length(ids)
      assert ToolCalls.pending_ids(calls) == []
    end
  end

  property "resolving after abort_all is rejected for every id" do
    check all(ids <- ids()) do
      {lines, calls} = ToolCalls.abort_all(hold_all(ids))
      assert length(lines) == length(ids)

      for id <- ids do
        assert ToolCalls.resolve(calls, id, @ok_result) == {:error, :unknown_tool_use}
      end
    end
  end

  property "a duplicate hold is rejected whatever else is held" do
    check all(ids <- ids(), ids != [], duplicate <- member_of(ids)) do
      calls = hold_all(ids)
      assert ToolCalls.hold(calls, held(duplicate)) == {:error, :duplicate_tool_use}
    end
  end
end
