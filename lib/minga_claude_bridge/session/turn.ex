defmodule MingaClaudeBridge.Session.Turn do
  @moduledoc """
  Accumulates the assistant messages Claude Code streams for one request.

  `apply_event/2` takes one main-thread stream event (see `MingaClaudeBridge.Wire.StreamEvent`) and returns the `{:text, _}` and `{:thinking, _}` events to forward. `stop_message/1` handles `message_stop`.

  ## Blocks

  A block is tracked from `content_block_start` to `content_block_stop`. Text and thinking deltas are forwarded as they arrive. A `tool_use` block collects its `input_json_delta` fragments, and its arguments are decoded at `content_block_stop`. A tool_use block that never received `content_block_stop` is dropped at `message_stop` or at the next `message_start`: Claude Code drops such a block from its own conversation and never dispatches it, so it must not reach Minga either.

  ## Restreamed messages

  A `message_start` while a message is still open means Claude Code abandoned that stream and is retrying it. The open message's blocks and usage are dropped. Text already forwarded from it cannot be taken back.

  ## Non-streaming fallback

  When a stream stalls, Claude Code can ask again without streaming. The reply then arrives only as `assistant` frames (usually one per content block) under a message id that no `message_start` announced. `apply_assistant/2` forwards such frames: text and thinking become events, and `tool_use` blocks become tool calls. An open streamed message is dropped first, because Claude Code abandoned it. `assistant` frames of a message that was streamed, frames without an id, and `<synthetic>` frames (Claude Code's own error and notice reports) yield nothing. A fallback message has no `message_stop`; `end_fallback/1` ends it.

  ## Usage

  Usage is the sum over the messages that reached `message_stop`. Each message's counts come from `message_start`, and `message_delta` overrides the counts it carries (usually `output_tokens`). `usage/1` returns `nil` when every count is zero, which is what Claude Code's `<synthetic>` messages report.
  """

  alias MingaClaudeBridge.Session.Event
  alias MingaClaudeBridge.Wire.{Assistant, StopReason, Usage}

  @tool_prefix "mcp__minga__"

  @zero %{input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0}

  @typep block ::
           :text
           | :thinking
           | {:tool_use, id :: String.t(), name :: String.t(), start_input :: map(),
              json :: iodata()}

  @typedoc "Whether a message is streaming, with the usage counts read so far for it."
  @type message :: :closed | {:open, Event.usage()}

  @opaque t :: %__MODULE__{
            message: message(),
            blocks: %{non_neg_integer() => block()},
            tool_calls: [Event.tool_call()],
            stop_reason: StopReason.t() | nil,
            usage: Event.usage(),
            streamed: MapSet.t(String.t()),
            fallback: %{id: String.t(), usage: Event.usage()} | nil
          }

  defstruct message: :closed,
            blocks: %{},
            tool_calls: [],
            stop_reason: nil,
            usage: @zero,
            streamed: MapSet.new(),
            fallback: nil

  @doc "Returns an empty turn."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Applies one stream event other than `message_stop`. Returns the next turn and the events to forward, in order.
  """
  @spec apply_event(t(), term()) :: {t(), [Event.t()]}
  def apply_event(%__MODULE__{} = turn, {:message_start, %{id: id, usage: usage}}) do
    streamed = if is_binary(id), do: MapSet.put(turn.streamed, id), else: turn.streamed

    {%{
       turn
       | message: {:open, merge_usage(@zero, usage)},
         blocks: %{},
         tool_calls: [],
         streamed: streamed
     }, []}
  end

  def apply_event(%__MODULE__{} = turn, {:content_block_start, index, block}),
    do: start_block(turn, index, block)

  def apply_event(%__MODULE__{} = turn, {:content_block_delta, index, delta}),
    do: delta(turn, Map.get(turn.blocks, index), index, delta)

  def apply_event(%__MODULE__{} = turn, {:content_block_stop, index}) do
    case Map.pop(turn.blocks, index) do
      {{:tool_use, id, name, start_input, json}, blocks} ->
        call = %{id: id, name: minga_name(name), arguments: arguments(json, start_input)}
        {%{turn | blocks: blocks, tool_calls: [call | turn.tool_calls]}, []}

      {_other, blocks} ->
        {%{turn | blocks: blocks}, []}
    end
  end

  def apply_event(%__MODULE__{} = turn, {:message_delta, %{stop_reason: stop_reason} = delta}) do
    message =
      case turn.message do
        {:open, usage} -> {:open, merge_usage(usage, delta.usage)}
        :closed -> {:open, merge_usage(@zero, delta.usage)}
      end

    {%{turn | message: message, stop_reason: stop_reason || turn.stop_reason}, []}
  end

  def apply_event(%__MODULE__{} = turn, _ignored), do: {turn, []}

  @doc """
  Ends the current message.

  Returns `{:tool_calls, calls, turn}` when the message completed one or more `tool_use` blocks, with the calls in stream order, and `{:no_tool_calls, turn}` otherwise. Blocks that never stopped are dropped.
  """
  @spec stop_message(t()) :: {:tool_calls, [Event.tool_call()], t()} | {:no_tool_calls, t()}
  def stop_message(%__MODULE__{} = turn) do
    usage =
      case turn.message do
        {:open, message_usage} -> add_usage(turn.usage, message_usage)
        :closed -> turn.usage
      end

    stopped = %{turn | message: :closed, blocks: %{}, tool_calls: [], usage: usage}

    case turn.tool_calls do
      [] -> {:no_tool_calls, stopped}
      calls -> {:tool_calls, Enum.reverse(calls), stopped}
    end
  end

  @doc """
  Applies one main-thread `assistant` frame. Returns the next turn and the events to forward. Only frames of a non-streaming fallback message yield events; see the module documentation.
  """
  @spec apply_assistant(t(), Assistant.t()) :: {t(), [Event.t()]}
  def apply_assistant(%__MODULE__{} = turn, %Assistant{model: "<synthetic>"}), do: {turn, []}
  def apply_assistant(%__MODULE__{} = turn, %Assistant{id: nil}), do: {turn, []}

  def apply_assistant(%__MODULE__{} = turn, %Assistant{id: id} = frame) do
    if MapSet.member?(turn.streamed, id) do
      {turn, []}
    else
      turn
      |> continue_fallback(id)
      |> add_fallback_blocks(frame)
    end
  end

  @doc """
  Ends the open non-streaming fallback message, if any. Returns `{:tool_calls, calls, turn}` when it completed `tool_use` blocks and `{:no_tool_calls, turn}` otherwise. Its usage is added to the turn's usage.
  """
  @spec end_fallback(t()) :: {:tool_calls, [Event.tool_call()], t()} | {:no_tool_calls, t()}
  def end_fallback(%__MODULE__{fallback: nil} = turn), do: {:no_tool_calls, turn}

  def end_fallback(%__MODULE__{fallback: %{usage: usage}} = turn) do
    ended = %{turn | fallback: nil, tool_calls: [], usage: add_usage(turn.usage, usage)}

    case turn.tool_calls do
      [] -> {:no_tool_calls, ended}
      calls -> {:tool_calls, Enum.reverse(calls), ended}
    end
  end

  @doc "Returns the stop reason of the last message that reported one."
  @spec stop_reason(t()) :: StopReason.t() | nil
  def stop_reason(%__MODULE__{stop_reason: stop_reason}), do: stop_reason

  @doc "Returns the summed usage of the stopped messages, or `nil` when every count is zero."
  @spec usage(t()) :: Event.usage() | nil
  def usage(%__MODULE__{usage: @zero}), do: nil
  def usage(%__MODULE__{usage: usage}), do: usage

  @doc "Converts a wire usage object to event usage. Returns `nil` for `nil` and for all-zero counts."
  @spec event_usage(Usage.t() | nil) :: Event.usage() | nil
  def event_usage(usage) do
    case merge_usage(@zero, usage) do
      @zero -> nil
      converted -> converted
    end
  end

  defp continue_fallback(%__MODULE__{fallback: %{id: id}} = turn, id), do: turn

  defp continue_fallback(%__MODULE__{} = turn, id) do
    {_calls_or_not, turn} = ended_fallback(end_fallback(turn))
    %{turn | message: :closed, blocks: %{}, tool_calls: [], fallback: %{id: id, usage: @zero}}
  end

  # A new fallback message replaces an unfinished earlier one, whose calls never run.
  defp ended_fallback({:tool_calls, calls, turn}), do: {calls, turn}
  defp ended_fallback({:no_tool_calls, turn}), do: {[], turn}

  defp add_fallback_blocks(turn, %Assistant{content: content, usage: usage, stop_reason: stop}) do
    {calls, events} =
      Enum.reduce(content, {turn.tool_calls, []}, fn block, {calls, events} ->
        case block do
          {:text, text} ->
            {calls, [nonempty(:text, text) | events]}

          {:thinking, text, _signature} ->
            {calls, [nonempty(:thinking, text) | events]}

          {:tool_use, id, name, input} ->
            {[%{id: id, name: minga_name(name), arguments: input} | calls], events}

          _other ->
            {calls, events}
        end
      end)

    fallback = %{turn.fallback | usage: merge_usage(turn.fallback.usage, usage)}

    turn = %{
      turn
      | tool_calls: calls,
        fallback: fallback,
        stop_reason: stop || turn.stop_reason
    }

    {turn, events |> Enum.reverse() |> List.flatten()}
  end

  defp start_block(turn, index, {:text, text}),
    do: {put_block(turn, index, :text), nonempty(:text, text)}

  defp start_block(turn, index, {:thinking, text, _signature}),
    do: {put_block(turn, index, :thinking), nonempty(:thinking, text)}

  defp start_block(turn, index, {:tool_use, id, name, input}),
    do: {put_block(turn, index, {:tool_use, id, name, input, []}), []}

  defp start_block(turn, _index, _other), do: {turn, []}

  defp put_block(turn, index, block), do: %{turn | blocks: Map.put(turn.blocks, index, block)}

  defp delta(turn, :text, _index, {:text_delta, text}), do: {turn, nonempty(:text, text)}

  defp delta(turn, :thinking, _index, {:thinking_delta, text}),
    do: {turn, nonempty(:thinking, text)}

  defp delta(turn, {:tool_use, id, name, input, json}, index, {:input_json_delta, fragment}),
    do: {put_block(turn, index, {:tool_use, id, name, input, [json, fragment]}), []}

  defp delta(turn, _block, _index, _delta), do: {turn, []}

  defp nonempty(_tag, ""), do: []
  defp nonempty(tag, text), do: [{tag, text}]

  defp minga_name(@tool_prefix <> name), do: name
  defp minga_name(name), do: name

  defp arguments(json, start_input) do
    case IO.iodata_to_binary(json) do
      "" ->
        start_input

      text ->
        case JSON.decode(text) do
          {:ok, map} when is_map(map) -> map
          _invalid -> start_input
        end
    end
  end

  defp merge_usage(acc, nil), do: acc

  defp merge_usage(acc, %Usage{} = usage) do
    %{
      input_tokens: usage.input_tokens || acc.input_tokens,
      output_tokens: usage.output_tokens || acc.output_tokens,
      cache_read_tokens: usage.cache_read_input_tokens || acc.cache_read_tokens,
      cache_write_tokens: usage.cache_creation_input_tokens || acc.cache_write_tokens
    }
  end

  defp add_usage(a, b) do
    %{
      input_tokens: a.input_tokens + b.input_tokens,
      output_tokens: a.output_tokens + b.output_tokens,
      cache_read_tokens: a.cache_read_tokens + b.cache_read_tokens,
      cache_write_tokens: a.cache_write_tokens + b.cache_write_tokens
    }
  end
end
