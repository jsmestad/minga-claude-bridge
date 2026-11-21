defmodule MingaClaudeBridge.MCPTest do
  use ExUnit.Case, async: true

  alias MingaClaudeBridge.MCP
  alias MingaClaudeBridge.MCP.CallRequest

  @read %{
    name: "read_file",
    description: "Read a file",
    input_schema: %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}, "limit" => %{"type" => "integer"}},
      "required" => ["path"]
    }
  }

  @search %{
    name: "search",
    description: "Search",
    input_schema: %{
      "anyOf" => [
        %{"properties" => %{"query" => %{"type" => "string"}}, "required" => ["query"]},
        %{"properties" => %{"regex" => %{"type" => "string"}}, "required" => ["regex"]}
      ]
    }
  }

  @tools [@read, @search]

  defp request(method, params \\ nil, id \\ 7) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method}
    |> then(&if(params, do: Map.put(&1, "params", params), else: &1))
  end

  defp call(name, arguments, meta \\ %{"claudecode/toolUseId" => "toolu_1"}) do
    params = %{"name" => name, "_meta" => meta}
    params = if arguments == :absent, do: params, else: Map.put(params, "arguments", arguments)
    request("tools/call", params)
  end

  describe "route/2 initialize" do
    test "echoes a supported protocol version and declares the tools capability" do
      assert {:reply, 7, result} =
               MCP.route(request("initialize", %{"protocolVersion" => "2025-06-18"}), @tools)

      assert result["protocolVersion"] == "2025-06-18"
      assert result["capabilities"] == %{"tools" => %{}}
      assert %{"name" => "minga", "version" => version} = result["serverInfo"]
      assert is_binary(version)
    end

    for params <- [nil, %{}, %{"protocolVersion" => "1999-01-01"}, %{"protocolVersion" => 3}] do
      test "answers the latest version for params #{inspect(params)}" do
        assert {:reply, 7, %{"protocolVersion" => "2025-11-25"}} =
                 MCP.route(request("initialize", unquote(Macro.escape(params))), @tools)
      end
    end
  end

  describe "route/2 tools/list" do
    test "lists exactly the declared tools with flattened schemas" do
      assert {:reply, "a", %{"tools" => [read, search]}} =
               MCP.route(request("tools/list", nil, "a"), @tools)

      assert read == %{
               "name" => "read_file",
               "description" => "Read a file",
               "inputSchema" => @read.input_schema
             }

      assert search["name"] == "search"
      assert search["inputSchema"]["type"] == "object"
      refute Map.has_key?(search["inputSchema"], "anyOf")
      assert Map.keys(search["inputSchema"]["properties"]) |> Enum.sort() == ["query", "regex"]

      assert search["description"] ==
               "Input constraint: Provide parameters for at least one of: (query) or (regex).\n\nSearch"
    end

    test "reflects the declarations passed with each request" do
      assert {:reply, 7, %{"tools" => [_one]}} = MCP.route(request("tools/list"), [@read])
      assert {:reply, 7, %{"tools" => []}} = MCP.route(request("tools/list"), [])
    end
  end

  describe "route/2 tools/call" do
    test "returns a call request for an offered tool" do
      assert MCP.route(call("read_file", %{"path" => "a.ex"}), @tools) ==
               {:tool_call,
                %CallRequest{
                  jsonrpc_id: 7,
                  tool_use_id: "toolu_1",
                  name: "read_file",
                  arguments: %{"path" => "a.ex"}
                }}
    end

    test "treats absent arguments as an empty object" do
      tool = %{@read | input_schema: %{"type" => "object"}}

      assert {:tool_call, %CallRequest{arguments: %{}}} =
               MCP.route(call("read_file", :absent), [tool])
    end

    test "checks required keys against the flattened schema" do
      # Each anyOf branch requires a different key, so the flat schema requires neither.
      assert {:tool_call, %CallRequest{name: "search"}} =
               MCP.route(call("search", %{"regex" => "x"}), @tools)
    end

    rejections = [
      {"a tool not offered this turn", "write_file", %{"path" => "a"}, :default,
       "Unknown tool: write_file"},
      {"a missing toolUseId", "read_file", %{"path" => "a"}, %{},
       ~s(read_file: tools/call is missing _meta["claudecode/toolUseId"])},
      {"an empty toolUseId", "read_file", %{"path" => "a"}, %{"claudecode/toolUseId" => ""},
       "claudecode/toolUseId"},
      {"a missing required argument", "read_file", %{"limit" => 3}, :default,
       "Invalid arguments for read_file: missing required path"},
      {"non-object arguments", "read_file", ["a"], :default,
       "Invalid arguments for read_file: arguments must be an object"}
    ]

    for {label, name, arguments, meta, message} <- rejections do
      test "rejects #{label} with -32602" do
        meta =
          case unquote(Macro.escape(meta)) do
            :default -> %{"claudecode/toolUseId" => "toolu_1"}
            meta -> meta
          end

        assert {:reply_error, 7, -32_602, message} =
                 MCP.route(call(unquote(name), unquote(Macro.escape(arguments)), meta), @tools)

        assert message =~ unquote(message)
      end
    end

    test "rejects a call without a tool name" do
      assert {:reply_error, 7, -32_602, _message} =
               MCP.route(request("tools/call", %{"_meta" => %{}}), @tools)

      assert {:reply_error, 7, -32_602, _message} = MCP.route(request("tools/call"), @tools)
    end

    test "error messages never contain argument values" do
      tool = %{@read | input_schema: Map.put(@read.input_schema, "required", ["path", "other"])}

      assert {:reply_error, _id, _code, message} =
               MCP.route(call("read_file", %{"path" => "secret-value"}), [tool])

      refute message =~ "secret-value"
    end
  end

  describe "route/2 message classification" do
    test "answers ping with an empty result" do
      assert MCP.route(request("ping"), @tools) == {:reply, 7, %{}}
    end

    test "rejects an unknown method with -32601" do
      assert {:reply_error, 7, -32_601, "Method not found: resources/list"} =
               MCP.route(request("resources/list"), @tools)
    end

    acknowledged = [
      {"an initialized notification",
       %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}},
      {"a cancelled notification",
       %{"jsonrpc" => "2.0", "method" => "notifications/cancelled", "params" => %{}}},
      {"a request with a null id", %{"jsonrpc" => "2.0", "id" => nil, "method" => "tools/list"}},
      {"a JSON-RPC response", %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}},
      {"an empty object", %{}}
    ]

    for {label, message} <- acknowledged do
      test "acknowledges #{label}" do
        assert MCP.route(unquote(Macro.escape(message)), @tools) == :acknowledge
      end
    end

    test "rejects an id of the wrong type with a null-id -32600" do
      assert {:reply_error, nil, -32_600, _message} =
               MCP.route(%{"id" => 1.5, "method" => "tools/list"}, @tools)

      assert {:reply_error, nil, -32_600, _message} =
               MCP.route(%{"id" => %{}, "method" => "tools/list"}, @tools)
    end

    test "rejects a method of the wrong type with -32600" do
      assert {:reply_error, 3, -32_600, _message} = MCP.route(%{"id" => 3, "method" => 1}, @tools)
    end
  end

  describe "reply_line/2" do
    defp mcp_response(line), do: JSON.decode!(line)["response"]["response"]["mcp_response"]

    test "encodes a result reply" do
      line = MCP.reply_line("req_1", {:reply, 7, %{"tools" => []}})

      assert JSON.decode!(line)["response"]["request_id"] == "req_1"
      assert mcp_response(line) == %{"jsonrpc" => "2.0", "id" => 7, "result" => %{"tools" => []}}
    end

    test "encodes an acknowledgement the way the Agent SDK does" do
      assert mcp_response(MCP.reply_line("req_2", :acknowledge)) ==
               %{"jsonrpc" => "2.0", "id" => 0, "result" => %{}}
    end

    test "encodes an error reply, including a null id" do
      assert mcp_response(MCP.reply_line("req_3", {:reply_error, nil, -32_600, "bad"})) ==
               %{
                 "jsonrpc" => "2.0",
                 "id" => nil,
                 "error" => %{"code" => -32_600, "message" => "bad"}
               }
    end
  end
end
