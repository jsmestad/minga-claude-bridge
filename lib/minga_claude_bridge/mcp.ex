defmodule MingaClaudeBridge.MCP do
  @moduledoc """
  Routes the JSON-RPC messages of the in-process MCP server named `"minga"`.

  Claude Code hosts the bridge's tools as an SDK MCP server. It sends each JSON-RPC message to the bridge inside an `mcp_message` control request (see `MingaClaudeBridge.Wire.ControlRequest`) and waits for a `control_response`. `route/2` decides what to do with one message, given the tool declarations of the current turn. It is pure: it performs no I/O and holds no state.

  ## Outcomes

    * `{:reply, jsonrpc_id, result}` - answer with a JSON-RPC result. Used for `initialize`, `ping`, and `tools/list`.
    * `:acknowledge` - the message is not a request (a notification such as `notifications/initialized`, or a JSON-RPC response). Claude Code still waits for the control response, so the session answers with the acknowledgement the Agent SDK sends: `{"jsonrpc": "2.0", "result": {}, "id": 0}`.
    * `{:tool_call, call}` - a valid `tools/call`. Minga runs the tool, so the session does not answer yet. It holds the control request in `MingaClaudeBridge.ToolCalls` until the next Minga request carries the result.
    * `{:reply_error, jsonrpc_id, code, message}` - answer with a JSON-RPC error. `jsonrpc_id` is `nil` when the request id is not a string or integer.

  `reply_line/2` encodes every outcome except `{:tool_call, _}` as the `control_response` line to write.

  ## Error codes

  Standard JSON-RPC 2.0 codes:

    * `-32600` (invalid request) - the message has an `id` and a `method`, but one of them has the wrong JSON type.
    * `-32601` (method not found) - any method other than `initialize`, `ping`, `tools/list`, and `tools/call`.
    * `-32602` (invalid params) - a `tools/call` for a tool not offered this turn, without `params._meta["claudecode/toolUseId"]`, or with arguments that fail the minimal schema check. The MCP specification uses this code for unknown tools.

  ## Classifying messages

  A message is a request when it has a `method` key and a non-null `id` key, which is the test the Agent SDK applies. Everything else is acknowledged.

  ## tools/list

  The list is built from the declarations passed to `route/2`, so it always matches the current turn and is never cached. Each schema goes through `MingaClaudeBridge.MCP.Schema.flatten/1`, and the constraint that flattening removes is prepended to the description.

  ## Argument check (limited)

  `tools/call` arguments must be a JSON object (an absent `arguments` counts as an empty object) and must contain every key in the flattened schema's top-level `required` list. Nothing else is checked: not property types, nested schemas, enums, formats, or the `anyOf`/`oneOf` constraints that flattening drops. The bridge does not include a JSON Schema validator. Minga validates the arguments against the full schema before it runs the tool, and reports a failure to the model as a tool error.

  ## Protocol version

  `initialize` answers with the client's requested `protocolVersion` when it is one the Agent SDK 0.3.330 supports, and otherwise with the latest one, `"2025-11-25"`. This matches the MCP TypeScript SDK server.

  Error messages name tools and argument keys but never contain argument values.
  """

  alias MingaClaudeBridge.MCP.{CallRequest, Schema}
  alias MingaClaudeBridge.Wire

  @latest_protocol_version "2025-11-25"
  @supported_protocol_versions [
    @latest_protocol_version,
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
    "2024-10-07"
  ]
  @server_name "minga"
  @tool_use_id_meta "claudecode/toolUseId"

  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602

  @typedoc "A tool Minga offers for the current turn. `input_schema` is a string-keyed JSON Schema."
  @type tool :: %{name: String.t(), description: String.t(), input_schema: map()}

  @typedoc "A decoded JSON-RPC 2.0 message from an `mcp_message` control request."
  @type message :: %{optional(String.t()) => term()}

  @type reply ::
          {:reply, Wire.jsonrpc_id(), map()}
          | :acknowledge
          | {:reply_error, Wire.error_id(), integer(), String.t()}

  @type outcome :: reply() | {:tool_call, CallRequest.t()}

  @doc "Returns the MCP server name the bridge registers with Claude Code."
  @spec server_name() :: String.t()
  def server_name, do: @server_name

  @doc "Routes one JSON-RPC message, given the tools offered for the current turn."
  @spec route(message(), [tool()]) :: outcome()
  def route(%{"method" => method, "id" => id} = message, tools) when not is_nil(id) do
    cond do
      not valid_id?(id) -> {:reply_error, nil, @invalid_request, "Invalid Request: id"}
      not is_binary(method) -> {:reply_error, id, @invalid_request, "Invalid Request: method"}
      true -> request(method, id, Map.get(message, "params"), tools)
    end
  end

  def route(message, _tools) when is_map(message), do: :acknowledge

  @doc """
  Encodes a reply outcome as the `control_response` line that answers control request `request_id`.
  """
  @spec reply_line(String.t(), reply()) :: Wire.line()
  def reply_line(request_id, {:reply, id, result}), do: Wire.mcp_result(request_id, id, result)
  def reply_line(request_id, :acknowledge), do: Wire.mcp_result(request_id, 0, %{})

  def reply_line(request_id, {:reply_error, id, code, message}),
    do: Wire.mcp_error(request_id, id, code, message)

  defp valid_id?(id), do: is_binary(id) or is_integer(id)

  defp request("initialize", id, params, _tools) do
    {:reply, id,
     %{
       "protocolVersion" => protocol_version(params),
       "capabilities" => %{"tools" => %{}},
       "serverInfo" => %{"name" => @server_name, "version" => MingaClaudeBridge.Version.version()}
     }}
  end

  defp request("ping", id, _params, _tools), do: {:reply, id, %{}}

  defp request("tools/list", id, _params, tools),
    do: {:reply, id, %{"tools" => Enum.map(tools, &list_entry/1)}}

  defp request("tools/call", id, params, tools), do: tool_call(id, params, tools)

  defp request(method, id, _params, _tools),
    do: {:reply_error, id, @method_not_found, "Method not found: #{method}"}

  defp protocol_version(%{"protocolVersion" => version})
       when version in @supported_protocol_versions,
       do: version

  defp protocol_version(_params), do: @latest_protocol_version

  defp list_entry(%{name: name, description: description, input_schema: schema}) do
    description =
      [Schema.constraint_note(schema), description]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    %{"name" => name, "description" => description, "inputSchema" => Schema.flatten(schema)}
  end

  defp tool_call(id, params, tools) do
    with {:ok, name} <- tool_name(params),
         {:ok, tool} <- offered_tool(tools, name),
         {:ok, tool_use_id} <- tool_use_id(params, name),
         {:ok, arguments} <- arguments(params, tool) do
      {:tool_call,
       %CallRequest{jsonrpc_id: id, tool_use_id: tool_use_id, name: name, arguments: arguments}}
    else
      {:error, message} -> {:reply_error, id, @invalid_params, message}
    end
  end

  defp tool_name(%{"name" => name}) when is_binary(name), do: {:ok, name}
  defp tool_name(_params), do: {:error, "Invalid params: tools/call requires a tool name"}

  defp offered_tool(tools, name) do
    case Enum.find(tools, &(&1.name == name)) do
      nil -> {:error, "Unknown tool: #{name}"}
      tool -> {:ok, tool}
    end
  end

  defp tool_use_id(%{"_meta" => %{@tool_use_id_meta => id}}, _name)
       when is_binary(id) and id != "",
       do: {:ok, id}

  defp tool_use_id(_params, name),
    do:
      {:error,
       "#{name}: tools/call is missing _meta[\"#{@tool_use_id_meta}\"]; the result cannot be paired with its tool call"}

  defp arguments(params, tool) do
    case Map.get(params, "arguments") do
      nil -> check_required(%{}, tool)
      arguments when is_map(arguments) -> check_required(arguments, tool)
      _other -> {:error, "Invalid arguments for #{tool.name}: arguments must be an object"}
    end
  end

  defp check_required(arguments, tool) do
    case tool.input_schema
         |> Schema.flatten()
         |> Schema.required()
         |> Enum.reject(&Map.has_key?(arguments, &1)) do
      [] ->
        {:ok, arguments}

      missing ->
        {:error,
         "Invalid arguments for #{tool.name}: missing required #{Enum.join(missing, ", ")}"}
    end
  end
end
