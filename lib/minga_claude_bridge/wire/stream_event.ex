defmodule MingaClaudeBridge.Wire.StreamEvent do
  @moduledoc """
  A `stream_event` frame: one Anthropic streaming event, emitted when Claude Code runs with `--include-partial-messages`.

  `event` is a tagged sum over the Messages API stream events:

    * `{:message_start, %{id, model, usage}}`
    * `{:content_block_start, index, block}` where `block` is a `MingaClaudeBridge.Wire.Block.t()`
    * `{:content_block_delta, index, delta}` where `delta` is one of `{:text_delta, text}`, `{:thinking_delta, thinking}`, `{:input_json_delta, partial_json}`, `{:signature_delta, signature}`, `{:citations_delta, citation}`, or `{:unknown_delta, type}`
    * `{:content_block_stop, index}`
    * `{:message_delta, %{stop_reason, stop_sequence, usage}}`
    * `:message_stop`
    * `:ping`
    * `{:stream_error, %{type, message}}` for an API `error` event
    * `{:unknown_event, type}` for any other event type

  `parent_tool_use_id` is `nil` for the main conversation. A non-nil value marks a subagent stream.
  """

  alias MingaClaudeBridge.Wire.{Block, Field, StopReason, Usage}

  @type delta ::
          {:text_delta, String.t()}
          | {:thinking_delta, String.t()}
          | {:input_json_delta, String.t()}
          | {:signature_delta, String.t()}
          | {:citations_delta, Field.json_map()}
          | {:unknown_delta, String.t()}

  @type message_start :: %{id: String.t() | nil, model: String.t() | nil, usage: Usage.t() | nil}

  @type message_delta :: %{
          stop_reason: StopReason.t() | nil,
          stop_sequence: String.t() | nil,
          usage: Usage.t() | nil
        }

  @type event ::
          {:message_start, message_start()}
          | {:content_block_start, index :: non_neg_integer(), Block.t()}
          | {:content_block_delta, index :: non_neg_integer(), delta()}
          | {:content_block_stop, index :: non_neg_integer()}
          | {:message_delta, message_delta()}
          | :message_stop
          | :ping
          | {:stream_error, %{type: String.t() | nil, message: String.t() | nil}}
          | {:unknown_event, String.t()}

  @type t :: %__MODULE__{
          event: event(),
          parent_tool_use_id: String.t() | nil,
          session_id: String.t() | nil,
          uuid: String.t() | nil
        }

  @enforce_keys [:event]
  defstruct [:event, :parent_tool_use_id, :session_id, :uuid]

  @doc "Decodes a `stream_event` frame."
  @spec from_wire(Field.json_map()) :: {:ok, t()} | :error
  def from_wire(map) do
    with {:ok, event_map} <- Field.map(map, "event"),
         {:ok, event} <- event(event_map),
         {:ok, parent} <- Field.optional_string(map, "parent_tool_use_id"),
         {:ok, session_id} <- Field.optional_string(map, "session_id"),
         {:ok, uuid} <- Field.optional_string(map, "uuid") do
      {:ok,
       %__MODULE__{event: event, parent_tool_use_id: parent, session_id: session_id, uuid: uuid}}
    end
  end

  defp event(%{"type" => "message_start"} = map) do
    with {:ok, message} <- Field.map(map, "message"),
         {:ok, id} <- Field.optional_string(message, "id"),
         {:ok, model} <- Field.optional_string(message, "model"),
         {:ok, usage} <- Usage.field(message, "usage") do
      {:ok, {:message_start, %{id: id, model: model, usage: usage}}}
    end
  end

  defp event(%{"type" => "content_block_start"} = map) do
    with {:ok, index} <- Field.non_neg_integer(map, "index"),
         {:ok, block} <- Field.map(map, "content_block"),
         {:ok, block} <- Block.from_wire(block) do
      {:ok, {:content_block_start, index, block}}
    end
  end

  defp event(%{"type" => "content_block_delta"} = map) do
    with {:ok, index} <- Field.non_neg_integer(map, "index"),
         {:ok, delta} <- Field.map(map, "delta"),
         {:ok, delta} <- delta(delta) do
      {:ok, {:content_block_delta, index, delta}}
    end
  end

  defp event(%{"type" => "content_block_stop"} = map) do
    with {:ok, index} <- Field.non_neg_integer(map, "index"),
         do: {:ok, {:content_block_stop, index}}
  end

  defp event(%{"type" => "message_delta"} = map) do
    with {:ok, delta} <- Field.map(map, "delta"),
         {:ok, stop_reason} <- StopReason.field(delta, "stop_reason"),
         {:ok, stop_sequence} <- Field.optional_string(delta, "stop_sequence"),
         {:ok, usage} <- Usage.field(map, "usage") do
      {:ok,
       {:message_delta, %{stop_reason: stop_reason, stop_sequence: stop_sequence, usage: usage}}}
    end
  end

  defp event(%{"type" => "message_stop"}), do: {:ok, :message_stop}
  defp event(%{"type" => "ping"}), do: {:ok, :ping}

  defp event(%{"type" => "error"} = map) do
    with {:ok, error} <- Field.map(map, "error"),
         {:ok, type} <- Field.optional_string(error, "type"),
         {:ok, message} <- Field.optional_string(error, "message") do
      {:ok, {:stream_error, %{type: type, message: message}}}
    end
  end

  defp event(%{"type" => type}) when is_binary(type), do: {:ok, {:unknown_event, type}}
  defp event(_other), do: :error

  defp delta(%{"type" => "text_delta"} = map), do: tagged(map, "text", :text_delta)
  defp delta(%{"type" => "thinking_delta"} = map), do: tagged(map, "thinking", :thinking_delta)

  defp delta(%{"type" => "input_json_delta"} = map),
    do: tagged(map, "partial_json", :input_json_delta)

  defp delta(%{"type" => "signature_delta"} = map),
    do: tagged(map, "signature", :signature_delta)

  defp delta(%{"type" => "citations_delta"} = map) do
    with {:ok, citation} <- Field.map(map, "citation"), do: {:ok, {:citations_delta, citation}}
  end

  defp delta(%{"type" => type}) when is_binary(type), do: {:ok, {:unknown_delta, type}}
  defp delta(_other), do: :error

  defp tagged(map, key, tag) do
    with {:ok, value} <- Field.string(map, key), do: {:ok, {tag, value}}
  end
end
