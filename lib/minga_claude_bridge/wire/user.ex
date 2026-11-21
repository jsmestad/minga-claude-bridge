defmodule MingaClaudeBridge.Wire.User do
  @moduledoc """
  A `user` frame: a user message, either one Claude Code echoes or replays, or one the bridge sends.

  String content decodes to a single `{:text, text}` block, so callers always see a block list.
  """

  alias MingaClaudeBridge.Wire.{Block, Field}

  @type t :: %__MODULE__{
          content: [Block.t()],
          parent_tool_use_id: String.t() | nil,
          session_id: String.t() | nil,
          uuid: String.t() | nil,
          synthetic: boolean()
        }

  @enforce_keys [:content]
  defstruct [:content, :parent_tool_use_id, :session_id, :uuid, synthetic: false]

  @doc "Decodes a `user` frame."
  @spec from_wire(Field.json_map()) :: {:ok, t()} | :error
  def from_wire(map) do
    with {:ok, message} <- Field.map(map, "message"),
         {:ok, content} <- Block.content_from_wire(Map.get(message, "content")),
         {:ok, parent} <- Field.optional_string(map, "parent_tool_use_id"),
         {:ok, session_id} <- Field.optional_string(map, "session_id"),
         {:ok, uuid} <- Field.optional_string(map, "uuid"),
         {:ok, synthetic} <- Field.optional_boolean(map, "isSynthetic", false) do
      {:ok,
       %__MODULE__{
         content: content,
         parent_tool_use_id: parent,
         session_id: session_id,
         uuid: uuid,
         synthetic: synthetic
       }}
    end
  end
end
