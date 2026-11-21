defmodule MingaClaudeBridge.Wire.RateLimit do
  @moduledoc """
  A `rate_limit_event` frame: plan usage for Claude subscription accounts.

  Fields come from the SDK's `SDKRateLimitInfo`, read from `rate_limit_info`:

    * `status` (`status`): `:allowed`, `:allowed_warning`, `:rejected`, or `{:other, string}`.
    * `resets_at` (`resetsAt`): when the window resets, in Unix seconds.
    * `rate_limit_type` (`rateLimitType`): `:five_hour`, `:seven_day`, `:seven_day_opus`, `:seven_day_sonnet`, `:seven_day_overage_included`, `:overage`, or `{:other, string}`.
    * `utilization` (`utilization`): the used fraction of the window.

  ## Unverified

  The SDK types do not state the unit of `resetsAt`. pi-claude-bridge treats it as Unix seconds based on observed CLI output, and this module documents it the same way. The SDK types also do not state whether `utilization` is a 0..1 fraction or a percentage; the value is passed through as a number.
  """

  alias MingaClaudeBridge.Wire.Field

  @type status :: :allowed | :allowed_warning | :rejected | {:other, String.t()}

  @type rate_limit_type ::
          :five_hour
          | :seven_day
          | :seven_day_opus
          | :seven_day_sonnet
          | :seven_day_overage_included
          | :overage
          | {:other, String.t()}

  @type t :: %__MODULE__{
          status: status(),
          resets_at: number() | nil,
          rate_limit_type: rate_limit_type() | nil,
          utilization: number() | nil,
          session_id: String.t() | nil
        }

  @enforce_keys [:status]
  defstruct [:status, :resets_at, :rate_limit_type, :utilization, :session_id]

  @statuses %{
    "allowed" => :allowed,
    "allowed_warning" => :allowed_warning,
    "rejected" => :rejected
  }

  @types %{
    "five_hour" => :five_hour,
    "seven_day" => :seven_day,
    "seven_day_opus" => :seven_day_opus,
    "seven_day_sonnet" => :seven_day_sonnet,
    "seven_day_overage_included" => :seven_day_overage_included,
    "overage" => :overage
  }

  @doc "Decodes a `rate_limit_event` frame."
  @spec from_wire(Field.json_map()) :: {:ok, t()} | :error
  def from_wire(map) do
    with {:ok, info} <- Field.map(map, "rate_limit_info"),
         {:ok, status} <- Field.enum(info, "status", @statuses),
         {:ok, resets_at} <- Field.optional_number(info, "resetsAt"),
         {:ok, type} <- Field.optional_enum(info, "rateLimitType", @types),
         {:ok, utilization} <- Field.optional_number(info, "utilization"),
         {:ok, session_id} <- Field.optional_string(map, "session_id") do
      {:ok,
       %__MODULE__{
         status: status,
         resets_at: resets_at,
         rate_limit_type: type,
         utilization: utilization,
         session_id: session_id
       }}
    end
  end
end
