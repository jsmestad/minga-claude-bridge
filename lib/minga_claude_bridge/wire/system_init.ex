defmodule MingaClaudeBridge.Wire.SystemInit do
  @moduledoc """
  The `system` frame with subtype `init`, which Claude Code emits when a session starts.

  The bridge reads `tools` and `mcp_servers` for its startup check, so both are required for the frame to decode. The other fields are optional because the bridge does not depend on them; a CLI that omits one still decodes.

  `permission_mode` decodes the SDK's `PermissionMode` values to atoms (`acceptEdits` becomes `:accept_edits`, and so on). An unknown mode decodes to `{:other, string}`.
  """

  alias MingaClaudeBridge.Wire.Field

  @type mcp_server :: %{name: String.t(), status: String.t() | nil}

  @type permission_mode ::
          :default
          | :accept_edits
          | :bypass_permissions
          | :plan
          | :dont_ask
          | :auto
          | {:other, String.t()}

  @type t :: %__MODULE__{
          session_id: String.t(),
          tools: [String.t()],
          mcp_servers: [mcp_server()],
          model: String.t() | nil,
          claude_code_version: String.t() | nil,
          permission_mode: permission_mode() | nil,
          cwd: String.t() | nil
        }

  @enforce_keys [:session_id, :tools, :mcp_servers]
  defstruct [
    :session_id,
    :tools,
    :mcp_servers,
    :model,
    :claude_code_version,
    :permission_mode,
    :cwd
  ]

  @permission_modes %{
    "default" => :default,
    "acceptEdits" => :accept_edits,
    "bypassPermissions" => :bypass_permissions,
    "plan" => :plan,
    "dontAsk" => :dont_ask,
    "auto" => :auto
  }

  @doc "Decodes a `system`/`init` frame."
  @spec from_wire(Field.json_map()) :: {:ok, t()} | :error
  def from_wire(map) do
    with {:ok, session_id} <- Field.string(map, "session_id"),
         {:ok, tools} <- Field.string_list(map, "tools"),
         {:ok, servers} <- Field.list(map, "mcp_servers"),
         {:ok, servers} <- Field.each(servers, &mcp_server/1),
         {:ok, model} <- Field.optional_string(map, "model"),
         {:ok, version} <- Field.optional_string(map, "claude_code_version"),
         {:ok, mode} <- Field.optional_enum(map, "permissionMode", @permission_modes),
         {:ok, cwd} <- Field.optional_string(map, "cwd") do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         tools: tools,
         mcp_servers: servers,
         model: model,
         claude_code_version: version,
         permission_mode: mode,
         cwd: cwd
       }}
    end
  end

  defp mcp_server(%{} = map) do
    with {:ok, name} <- Field.string(map, "name"),
         {:ok, status} <- Field.optional_string(map, "status") do
      {:ok, %{name: name, status: status}}
    end
  end

  defp mcp_server(_other), do: :error
end
