defmodule MingaClaudeBridge.Wire.Usage do
  @moduledoc """
  Token counts from an Anthropic `usage` object.

  Claude Code reports usage on `message_start`, `message_delta`, `assistant` messages, and `result`. A count the frame does not carry is `nil`, not zero: a `message_delta` often carries only `output_tokens`, and a missing count is unknown rather than zero.
  """

  alias MingaClaudeBridge.Wire.Field

  @type count :: non_neg_integer() | nil

  @type t :: %__MODULE__{
          input_tokens: count(),
          output_tokens: count(),
          cache_creation_input_tokens: count(),
          cache_read_input_tokens: count()
        }

  defstruct input_tokens: nil,
            output_tokens: nil,
            cache_creation_input_tokens: nil,
            cache_read_input_tokens: nil

  @doc "Decodes a wire `usage` object. `nil` decodes to `nil`."
  @spec from_wire(Field.json_map() | nil) :: {:ok, t() | nil} | :error
  def from_wire(nil), do: {:ok, nil}

  def from_wire(%{} = map) do
    with {:ok, input} <- Field.optional_non_neg_integer(map, "input_tokens"),
         {:ok, output} <- Field.optional_non_neg_integer(map, "output_tokens"),
         {:ok, cache_creation} <-
           Field.optional_non_neg_integer(map, "cache_creation_input_tokens"),
         {:ok, cache_read} <- Field.optional_non_neg_integer(map, "cache_read_input_tokens") do
      {:ok,
       %__MODULE__{
         input_tokens: input,
         output_tokens: output,
         cache_creation_input_tokens: cache_creation,
         cache_read_input_tokens: cache_read
       }}
    end
  end

  def from_wire(_other), do: :error

  @doc "Reads an optional `usage` field from a wire map."
  @spec field(Field.json_map(), String.t()) :: {:ok, t() | nil} | :error
  def field(map, key) do
    case Field.optional_map(map, key) do
      {:ok, usage} -> from_wire(usage)
      :error -> :error
    end
  end
end
