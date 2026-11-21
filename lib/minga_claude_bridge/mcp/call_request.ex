defmodule MingaClaudeBridge.MCP.CallRequest do
  @moduledoc """
  A validated MCP `tools/call` request that Minga must run.

    * `jsonrpc_id` - the JSON-RPC request id. The reply to the call must carry it.
    * `tool_use_id` - the id of the `tool_use` block in the assistant message, read from `params._meta["claudecode/toolUseId"]`. Minga uses it as the tool-call id, and `MingaClaudeBridge.ToolCalls` uses it to pair the result with the held control request.
    * `name` - a tool name offered for the current turn.
    * `arguments` - the call arguments as a string-keyed JSON object. They passed the minimal check in `MingaClaudeBridge.MCP`; Minga validates them fully.

  The arguments are conversation content. Do not log them.
  """

  alias MingaClaudeBridge.Wire

  @type t :: %__MODULE__{
          jsonrpc_id: Wire.jsonrpc_id(),
          tool_use_id: String.t(),
          name: String.t(),
          arguments: %{optional(String.t()) => term()}
        }

  @enforce_keys [:jsonrpc_id, :tool_use_id, :name, :arguments]
  defstruct [:jsonrpc_id, :tool_use_id, :name, :arguments]
end
