defmodule MingaClaudeBridge.Session.TurnTest do
  use ExUnit.Case, async: true

  alias MingaClaudeBridge.Session.Turn
  alias MingaClaudeBridge.Wire.{Assistant, Usage}

  defp run(events, turn \\ Turn.new()) do
    Enum.reduce(events, {turn, []}, fn event, {turn, acc} ->
      {turn, emitted} = Turn.apply_event(turn, event)
      {turn, acc ++ emitted}
    end)
  end

  defp start(usage \\ nil), do: {:message_start, %{id: "m", model: "x", usage: usage}}

  defp tool_use(id, index, json) do
    [
      {:content_block_start, index, {:tool_use, id, "mcp__minga__edit", %{}}}
      | Enum.map(json, &{:content_block_delta, index, {:input_json_delta, &1}})
    ] ++ [{:content_block_stop, index}]
  end

  test "forwards text and thinking deltas in order" do
    {_turn, emitted} =
      run([
        start(),
        {:content_block_start, 0, {:thinking, "", nil}},
        {:content_block_delta, 0, {:thinking_delta, "hmm"}},
        {:content_block_delta, 0, {:signature_delta, "sig"}},
        {:content_block_stop, 0},
        {:content_block_start, 1, {:text, ""}},
        {:content_block_delta, 1, {:text_delta, "Hel"}},
        {:content_block_delta, 1, {:text_delta, ""}},
        {:content_block_delta, 1, {:text_delta, "lo"}},
        {:content_block_stop, 1}
      ])

    assert emitted == [{:thinking, "hmm"}, {:text, "Hel"}, {:text, "lo"}]
  end

  test "deltas for an unknown block index are ignored" do
    assert {_turn, []} = run([start(), {:content_block_delta, 4, {:text_delta, "x"}}])
  end

  test "decodes tool arguments from fragments and strips the Minga prefix" do
    {turn, []} = run([start() | tool_use("t1", 0, [~s({"a":), ~s([1,2]})])])
    assert {:tool_calls, [call], _turn} = Turn.stop_message(turn)
    assert call == %{id: "t1", name: "edit", arguments: %{"a" => [1, 2]}}
  end

  test "a tool_use without fragments keeps its start input" do
    events = [
      start(),
      {:content_block_start, 0, {:tool_use, "t1", "mcp__minga__ls", %{"p" => "."}}},
      {:content_block_stop, 0}
    ]

    {turn, []} = run(events)
    assert {:tool_calls, [%{arguments: %{"p" => "."}}], _turn} = Turn.stop_message(turn)
  end

  test "a tool_use that never stopped is dropped at message_stop" do
    {turn, []} =
      run(
        [start() | tool_use("t1", 0, ["{}"])] ++
          [{:content_block_start, 1, {:tool_use, "t2", "x", %{}}}]
      )

    assert {:tool_calls, [%{id: "t1"}], _turn} = Turn.stop_message(turn)
  end

  test "a restreamed message drops the abandoned message's tool calls and usage" do
    {turn, []} =
      run(
        [start(%Usage{input_tokens: 50}) | tool_use("t1", 0, ["{}"])] ++
          [start(%Usage{input_tokens: 5, output_tokens: 1})]
      )

    assert {:no_tool_calls, turn} = Turn.stop_message(turn)

    assert Turn.usage(turn) == %{
             input_tokens: 5,
             output_tokens: 1,
             cache_read_tokens: 0,
             cache_write_tokens: 0
           }
  end

  test "sums usage over stopped messages; message_delta overrides counts it carries" do
    delta =
      {:message_delta,
       %{stop_reason: :end_turn, stop_sequence: nil, usage: %Usage{output_tokens: 7}}}

    {turn, []} =
      run([start(%Usage{input_tokens: 3, output_tokens: 1, cache_read_input_tokens: 2}), delta])

    {:no_tool_calls, turn} = Turn.stop_message(turn)
    {turn, []} = run([start(%Usage{input_tokens: 4, cache_creation_input_tokens: 1})], turn)
    {:no_tool_calls, turn} = Turn.stop_message(turn)

    assert Turn.usage(turn) == %{
             input_tokens: 7,
             output_tokens: 7,
             cache_read_tokens: 2,
             cache_write_tokens: 1
           }

    assert Turn.stop_reason(turn) == :end_turn
  end

  test "all-zero usage reads as nil" do
    zero = %Usage{input_tokens: 0, output_tokens: 0}
    {turn, []} = run([start(zero)])
    {:no_tool_calls, turn} = Turn.stop_message(turn)
    assert Turn.usage(turn) == nil
    assert Turn.event_usage(zero) == nil
    assert Turn.event_usage(nil) == nil
  end

  describe "non-streaming fallback" do
    test "synthetic frames and frames without an id yield nothing" do
      synthetic = %Assistant{id: "x", model: "<synthetic>", content: [{:text, "API Error"}]}
      assert {turn, []} = Turn.apply_assistant(Turn.new(), synthetic)
      assert {turn, []} = Turn.apply_assistant(turn, %Assistant{id: nil, content: [{:text, "x"}]})
      assert {:no_tool_calls, _turn} = Turn.end_fallback(turn)
    end

    test "counts the fallback message's usage once" do
      usage = %Usage{input_tokens: 8, output_tokens: 2}
      frame = fn content -> %Assistant{id: "fb", content: content, usage: usage} end
      {turn, [{:text, "a"}]} = Turn.apply_assistant(Turn.new(), frame.([{:text, "a"}]))
      {turn, []} = Turn.apply_assistant(turn, frame.([{:tool_use, "t1", "mcp__minga__x", %{}}]))

      assert {:tool_calls, [%{id: "t1", name: "x", arguments: %{}}], turn} =
               Turn.end_fallback(turn)

      assert %{input_tokens: 8, output_tokens: 2} = Turn.usage(turn)
    end
  end
end
