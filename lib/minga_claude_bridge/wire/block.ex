defmodule MingaClaudeBridge.Wire.Block do
  @moduledoc """
  Content blocks of Anthropic messages, as a tagged sum type.

  Blocks appear in `assistant` and `user` message content and in `content_block_start` stream events. Known block types decode to a tagged tuple. Any other block type, such as `image` or `server_tool_use`, decodes to `{:other, map}` and encodes back unchanged, so the bridge can pass blocks through without understanding them.

  In `content_block_start`, a `tool_use` block carries an empty `input`; the arguments follow as `input_json_delta` fragments. A `thinking` block there carries an empty `thinking` and the text follows as `thinking_delta` fragments.
  """

  alias MingaClaudeBridge.Wire.Field

  @typedoc "Content of a `tool_result` block: a string or nested content blocks."
  @type tool_result_content :: String.t() | [t()]

  @type t ::
          {:text, text :: String.t()}
          | {:thinking, thinking :: String.t(), signature :: String.t() | nil}
          | {:redacted_thinking, data :: String.t()}
          | {:tool_use, id :: String.t(), name :: String.t(), input :: map()}
          | {:tool_result, tool_use_id :: String.t(), content :: tool_result_content(),
             is_error :: boolean()}
          | {:other, Field.json_map()}

  @doc "Decodes one wire content block."
  @spec from_wire(term()) :: {:ok, t()} | :error
  def from_wire(%{"type" => "text"} = map) do
    with {:ok, text} <- Field.string(map, "text"), do: {:ok, {:text, text}}
  end

  def from_wire(%{"type" => "thinking"} = map) do
    with {:ok, thinking} <- Field.string(map, "thinking"),
         {:ok, signature} <- Field.optional_string(map, "signature") do
      {:ok, {:thinking, thinking, signature}}
    end
  end

  def from_wire(%{"type" => "redacted_thinking"} = map) do
    with {:ok, data} <- Field.string(map, "data"), do: {:ok, {:redacted_thinking, data}}
  end

  def from_wire(%{"type" => "tool_use"} = map) do
    with {:ok, id} <- Field.string(map, "id"),
         {:ok, name} <- Field.string(map, "name"),
         {:ok, input} <- Field.map(map, "input") do
      {:ok, {:tool_use, id, name, input}}
    end
  end

  def from_wire(%{"type" => "tool_result"} = map) do
    with {:ok, tool_use_id} <- Field.string(map, "tool_use_id"),
         {:ok, content} <- tool_result_content(Map.get(map, "content")),
         {:ok, is_error} <- Field.optional_boolean(map, "is_error", false) do
      {:ok, {:tool_result, tool_use_id, content, is_error}}
    end
  end

  def from_wire(%{"type" => type} = map) when is_binary(type), do: {:ok, {:other, map}}
  def from_wire(_other), do: :error

  @doc """
  Decodes message content. A string is shorthand for one text block, as in the Messages API.
  """
  @spec content_from_wire(term()) :: {:ok, [t()]} | :error
  def content_from_wire(text) when is_binary(text), do: {:ok, [{:text, text}]}
  def content_from_wire(blocks) when is_list(blocks), do: Field.each(blocks, &from_wire/1)
  def content_from_wire(_other), do: :error

  @doc "Encodes one content block as a JSON-ready map."
  @spec to_wire(t()) :: Field.json_map()
  def to_wire({:text, text}), do: %{"type" => "text", "text" => text}

  def to_wire({:thinking, thinking, nil}), do: %{"type" => "thinking", "thinking" => thinking}

  def to_wire({:thinking, thinking, signature}),
    do: %{"type" => "thinking", "thinking" => thinking, "signature" => signature}

  def to_wire({:redacted_thinking, data}), do: %{"type" => "redacted_thinking", "data" => data}

  def to_wire({:tool_use, id, name, input}),
    do: %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}

  def to_wire({:tool_result, tool_use_id, content, is_error}) do
    %{
      "type" => "tool_result",
      "tool_use_id" => tool_use_id,
      "content" => tool_result_content_to_wire(content),
      "is_error" => is_error
    }
  end

  def to_wire({:other, map}), do: map

  defp tool_result_content(nil), do: {:ok, ""}
  defp tool_result_content(text) when is_binary(text), do: {:ok, text}
  defp tool_result_content(blocks) when is_list(blocks), do: Field.each(blocks, &from_wire/1)
  defp tool_result_content(_other), do: :error

  defp tool_result_content_to_wire(text) when is_binary(text), do: text
  defp tool_result_content_to_wire(blocks) when is_list(blocks), do: Enum.map(blocks, &to_wire/1)
end
