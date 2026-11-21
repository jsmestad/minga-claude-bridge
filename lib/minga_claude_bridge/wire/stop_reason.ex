defmodule MingaClaudeBridge.Wire.StopReason do
  @moduledoc """
  Anthropic `stop_reason` values.

  Known values decode to atoms. A value this module does not know decodes to `{:other, string}` instead of failing, because the API adds stop reasons over time.
  """

  alias MingaClaudeBridge.Wire.Field

  @type t ::
          :end_turn
          | :max_tokens
          | :stop_sequence
          | :tool_use
          | :pause_turn
          | :refusal
          | :model_context_window_exceeded
          | {:other, String.t()}

  @table %{
    "end_turn" => :end_turn,
    "max_tokens" => :max_tokens,
    "stop_sequence" => :stop_sequence,
    "tool_use" => :tool_use,
    "pause_turn" => :pause_turn,
    "refusal" => :refusal,
    "model_context_window_exceeded" => :model_context_window_exceeded
  }

  @doc "Reads an optional `stop_reason` field."
  @spec field(Field.json_map(), String.t()) :: {:ok, t() | nil} | :error
  def field(map, key), do: Field.optional_enum(map, key, @table)
end
