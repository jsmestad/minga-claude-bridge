defmodule MingaClaudeBridge.LineBufferTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MingaClaudeBridge.LineBuffer

  # Feeds fragments and collects every non-`:more` result in order.
  defp feed(buffer, fragments) do
    {outputs, buffer} =
      Enum.reduce(fragments, {[], buffer}, fn fragment, {acc, buffer} ->
        case LineBuffer.push(buffer, fragment) do
          {:line, line, buffer} -> {[{:line, line} | acc], buffer}
          {:more, buffer} -> {acc, buffer}
          {:error, :line_too_long, buffer} -> {[:line_too_long | acc], buffer}
        end
      end)

    {Enum.reverse(outputs), buffer}
  end

  # Splits `line` at random byte offsets into Port fragments: every piece but the last is `:noeol`.
  defp fragments_gen(line) do
    gen all(cuts <- list_of(integer(0..byte_size(line)), max_length: 8)) do
      offsets = Enum.uniq(Enum.sort([0 | cuts] ++ [byte_size(line)]))

      pieces =
        offsets
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [from, to] -> binary_part(line, from, to - from) end)

      pieces = if pieces == [], do: [""], else: pieces
      {init, [last]} = Enum.split(pieces, -1)
      Enum.map(init, &{:noeol, &1}) ++ [{:eol, last}]
    end
  end

  defp line_gen(max_length), do: binary(max_length: max_length)

  property "any split of a sequence of lines reassembles to the same lines" do
    check all(
            lines <- list_of(line_gen(200), max_length: 10),
            fragments <- fixed_list(Enum.map(lines, &fragments_gen/1))
          ) do
      {outputs, buffer} = feed(LineBuffer.new(), List.flatten(fragments))

      assert outputs == Enum.map(lines, &{:line, &1})
      assert LineBuffer.buffered_bytes(buffer) == 0
    end
  end

  property "a line over the cap fails once and the next line still decodes" do
    check all(
            max <- integer(1..64),
            extra <- integer(1..64),
            long <- binary(length: max + extra),
            short <- binary(max_length: max),
            long_fragments <- fragments_gen(long),
            short_fragments <- fragments_gen(short)
          ) do
      {outputs, buffer} = feed(LineBuffer.new(max_bytes: max), long_fragments ++ short_fragments)

      assert outputs == [:line_too_long, {:line, short}]
      assert LineBuffer.buffered_bytes(buffer) == 0
    end
  end

  test "the cap counts line bytes, excluding the newline" do
    cases = [
      {[{:eol, "abcd"}], [{:line, "abcd"}]},
      {[{:noeol, "ab"}, {:eol, "cd"}], [{:line, "abcd"}]},
      {[{:eol, "abcde"}], [:line_too_long]},
      {[{:noeol, "abc"}, {:noeol, "de"}, {:eol, "f"}], [:line_too_long]},
      {[{:noeol, "abcde"}, {:eol, ""}, {:eol, "ok"}], [:line_too_long, {:line, "ok"}]}
    ]

    for {fragments, expected} <- cases do
      assert {^expected, _buffer} = feed(LineBuffer.new(max_bytes: 4), fragments)
    end
  end

  test "an empty line is a line" do
    assert {:line, "", _buffer} = LineBuffer.push(LineBuffer.new(), {:eol, ""})
  end

  test "buffered_bytes reports the partial line" do
    {:more, buffer} = LineBuffer.push(LineBuffer.new(), {:noeol, "abc"})
    {:more, buffer} = LineBuffer.push(buffer, {:noeol, "de"})
    assert LineBuffer.buffered_bytes(buffer) == 5
  end

  test "new/1 rejects a non-positive cap" do
    assert_raise ArgumentError, fn -> LineBuffer.new(max_bytes: 0) end
  end
end
