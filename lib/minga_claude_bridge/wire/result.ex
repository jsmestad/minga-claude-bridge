defmodule MingaClaudeBridge.Wire.Result do
  @moduledoc """
  The `result` frame that ends each Claude Code turn.

  `subtype` decodes to `:success`, `:error_during_execution`, `:error_max_turns`, `:error_max_budget_usd`, `:error_max_structured_output_retries`, or `{:other, string}`. A `:success` result can still have `is_error: true`; in that case `result` holds the error text. The error subtypes carry their messages in `errors` instead of `result`.

  `usage` holds the token totals for the turn.
  """

  alias MingaClaudeBridge.Wire.{Field, StopReason, Usage}

  @type subtype ::
          :success
          | :error_during_execution
          | :error_max_turns
          | :error_max_budget_usd
          | :error_max_structured_output_retries
          | {:other, String.t()}

  @type t :: %__MODULE__{
          subtype: subtype(),
          is_error: boolean(),
          result: String.t() | nil,
          errors: [String.t()],
          usage: Usage.t() | nil,
          total_cost_usd: number() | nil,
          session_id: String.t() | nil,
          num_turns: non_neg_integer() | nil,
          duration_ms: non_neg_integer() | nil,
          stop_reason: StopReason.t() | nil
        }

  @enforce_keys [:subtype, :is_error]
  defstruct [
    :subtype,
    :is_error,
    :result,
    :usage,
    :total_cost_usd,
    :session_id,
    :num_turns,
    :duration_ms,
    :stop_reason,
    errors: []
  ]

  @subtypes %{
    "success" => :success,
    "error_during_execution" => :error_during_execution,
    "error_max_turns" => :error_max_turns,
    "error_max_budget_usd" => :error_max_budget_usd,
    "error_max_structured_output_retries" => :error_max_structured_output_retries
  }

  @doc "Decodes a `result` frame."
  @spec from_wire(Field.json_map()) :: {:ok, t()} | :error
  def from_wire(map) do
    with {:ok, subtype} <- Field.enum(map, "subtype", @subtypes),
         {:ok, is_error} <- Field.boolean(map, "is_error"),
         {:ok, result} <- Field.optional_string(map, "result"),
         {:ok, errors} <- Field.optional_string_list(map, "errors"),
         {:ok, usage} <- Usage.field(map, "usage"),
         {:ok, cost} <- Field.optional_number(map, "total_cost_usd"),
         {:ok, session_id} <- Field.optional_string(map, "session_id"),
         {:ok, num_turns} <- Field.optional_non_neg_integer(map, "num_turns"),
         {:ok, duration_ms} <- Field.optional_non_neg_integer(map, "duration_ms"),
         {:ok, stop_reason} <- StopReason.field(map, "stop_reason") do
      {:ok,
       %__MODULE__{
         subtype: subtype,
         is_error: is_error,
         result: result,
         errors: errors || [],
         usage: usage,
         total_cost_usd: cost,
         session_id: session_id,
         num_turns: num_turns,
         duration_ms: duration_ms,
         stop_reason: stop_reason
       }}
    end
  end
end
