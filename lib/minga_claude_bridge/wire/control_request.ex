defmodule MingaClaudeBridge.Wire.ControlRequest do
  @moduledoc """
  A `control_request` frame. Claude Code sends these to the bridge (for example `mcp_message` and `can_use_tool`), and the bridge sends them to Claude Code (`initialize` and `interrupt`). Both directions share this shape, so outbound frames decode back to this struct.

  `request` is a tagged sum over the request subtypes the bridge handles:

    * `{:mcp_message, %{server_name, message}}` where `message` is the raw JSON-RPC 2.0 map for the named SDK MCP server.
    * `{:can_use_tool, %{tool_name, input, tool_use_id}}`
    * `{:initialize, %{sdk_mcp_servers, system_prompt, append_system_prompt}}` where `system_prompt` is a list of strings or `nil`.
    * `:interrupt`
    * `{:unknown_request, subtype}` for any other subtype. The bridge must still answer it, usually with an error response, because Claude Code waits for a reply.

  `request_id` is chosen by the sender and echoed by the matching `control_response` and any `control_cancel_request`.
  """

  alias MingaClaudeBridge.Wire.Field

  @type mcp_message :: %{server_name: String.t(), message: Field.json_map()}

  @type can_use_tool :: %{
          tool_name: String.t(),
          input: Field.json_map(),
          tool_use_id: String.t() | nil
        }

  @type initialize :: %{
          sdk_mcp_servers: [String.t()] | nil,
          system_prompt: [String.t()] | nil,
          append_system_prompt: String.t() | nil
        }

  @type request ::
          {:mcp_message, mcp_message()}
          | {:can_use_tool, can_use_tool()}
          | {:initialize, initialize()}
          | :interrupt
          | {:unknown_request, subtype :: String.t()}

  @type t :: %__MODULE__{request_id: String.t(), request: request()}

  @enforce_keys [:request_id, :request]
  defstruct [:request_id, :request]

  @doc "Decodes a `control_request` frame."
  @spec from_wire(Field.json_map()) :: {:ok, t()} | :error
  def from_wire(map) do
    with {:ok, request_id} <- Field.string(map, "request_id"),
         {:ok, request} <- Field.map(map, "request"),
         {:ok, request} <- request(request) do
      {:ok, %__MODULE__{request_id: request_id, request: request}}
    end
  end

  defp request(%{"subtype" => "mcp_message"} = map) do
    with {:ok, server_name} <- Field.string(map, "server_name"),
         {:ok, message} <- Field.map(map, "message") do
      {:ok, {:mcp_message, %{server_name: server_name, message: message}}}
    end
  end

  defp request(%{"subtype" => "can_use_tool"} = map) do
    with {:ok, tool_name} <- Field.string(map, "tool_name"),
         {:ok, input} <- Field.map(map, "input"),
         {:ok, tool_use_id} <- Field.optional_string(map, "tool_use_id") do
      {:ok, {:can_use_tool, %{tool_name: tool_name, input: input, tool_use_id: tool_use_id}}}
    end
  end

  defp request(%{"subtype" => "initialize"} = map) do
    with {:ok, servers} <- Field.optional_string_list(map, "sdkMcpServers"),
         {:ok, system_prompt} <- Field.optional_string_list(map, "systemPrompt"),
         {:ok, append} <- Field.optional_string(map, "appendSystemPrompt") do
      {:ok,
       {:initialize,
        %{sdk_mcp_servers: servers, system_prompt: system_prompt, append_system_prompt: append}}}
    end
  end

  defp request(%{"subtype" => "interrupt"}), do: {:ok, :interrupt}

  defp request(%{"subtype" => subtype}) when is_binary(subtype),
    do: {:ok, {:unknown_request, subtype}}

  defp request(_other), do: :error
end
