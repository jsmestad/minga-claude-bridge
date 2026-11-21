defmodule MingaClaudeBridge.LineBuffer do
  @moduledoc """
  Joins Port line fragments into complete lines.

  A Port opened with `{:line, max}` delivers each output line as one or more `{:noeol, chunk}` fragments followed by one `{:eol, chunk}` fragment. `push/2` accepts one fragment at a time and returns a complete line when it receives `{:eol, chunk}`. Lines never include the newline.

  The buffer enforces a byte cap on a single line (default #{32 * 1024 * 1024} bytes, 32 MiB). When the bytes of the current line exceed the cap, `push/2` returns `{:error, :line_too_long, buffer}` once and drops the fragments it holds. The buffer then discards the remaining fragments of that line up to and including its `{:eol, chunk}`, and starts the next line clean. This keeps the tail of an oversized line from being reported as a separate, truncated line.

  The module is pure and holds no payload outside the returned struct.
  """

  @default_max_bytes 32 * 1024 * 1024

  @typedoc "One fragment as delivered by a `{:line, max}` Port."
  @type fragment :: {:eol | :noeol, binary()}

  @typedoc """
  Phase of the line in progress.

  `{:collecting, chunks, size}` holds the reversed fragments of the current line and their total byte size. `:discarding` drops fragments until the end of an oversized line.
  """
  @type phase :: {:collecting, [binary()], non_neg_integer()} | :discarding

  @type t :: %__MODULE__{max_bytes: pos_integer(), phase: phase()}

  @enforce_keys [:max_bytes]
  defstruct max_bytes: @default_max_bytes, phase: {:collecting, [], 0}

  @typedoc "Result of pushing one fragment."
  @type push_result :: {:line, binary(), t()} | {:more, t()} | {:error, :line_too_long, t()}

  @doc """
  Returns an empty buffer.

  Options:

    * `:max_bytes` - the largest line in bytes, excluding the newline. Defaults to 32 MiB.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    unless is_integer(max_bytes) and max_bytes > 0 do
      raise ArgumentError, ":max_bytes must be a positive integer, got: #{inspect(max_bytes)}"
    end

    %__MODULE__{max_bytes: max_bytes}
  end

  @doc """
  Adds one Port fragment to the buffer.

  Returns `{:line, line, buffer}` when the fragment completes a line, `{:more, buffer}` when the line continues, and `{:error, :line_too_long, buffer}` when the line exceeds the cap.
  """
  @spec push(t(), fragment()) :: push_result()
  def push(%__MODULE__{phase: :discarding} = buffer, {:noeol, chunk}) when is_binary(chunk),
    do: {:more, buffer}

  def push(%__MODULE__{phase: :discarding} = buffer, {:eol, chunk}) when is_binary(chunk),
    do: {:more, reset(buffer)}

  def push(%__MODULE__{phase: {:collecting, chunks, size}} = buffer, {kind, chunk})
      when kind in [:eol, :noeol] and is_binary(chunk) do
    new_size = size + byte_size(chunk)

    cond do
      new_size > buffer.max_bytes and kind == :eol ->
        {:error, :line_too_long, reset(buffer)}

      new_size > buffer.max_bytes ->
        {:error, :line_too_long, %{buffer | phase: :discarding}}

      kind == :eol ->
        line = [chunk | chunks] |> Enum.reverse() |> IO.iodata_to_binary()
        {:line, line, reset(buffer)}

      true ->
        {:more, %{buffer | phase: {:collecting, [chunk | chunks], new_size}}}
    end
  end

  @doc "Returns the number of bytes held for the line in progress."
  @spec buffered_bytes(t()) :: non_neg_integer()
  def buffered_bytes(%__MODULE__{phase: {:collecting, _chunks, size}}), do: size
  def buffered_bytes(%__MODULE__{phase: :discarding}), do: 0

  defp reset(buffer), do: %{buffer | phase: {:collecting, [], 0}}
end
