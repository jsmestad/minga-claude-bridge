defmodule MingaClaudeBridge.Wire.Unknown do
  @moduledoc """
  Any frame whose `type` the codec does not model, such as `keep_alive`, `system` frames other than `init`, or types added by a newer CLI.

  `raw` is the decoded JSON object. It can contain conversation content, so callers must not log or persist it.
  """

  @type t :: %__MODULE__{type: String.t(), raw: %{optional(String.t()) => term()}}

  @enforce_keys [:type, :raw]
  defstruct [:type, :raw]

  @doc "Wraps a frame of an unmodeled type."
  @spec new(String.t(), map()) :: t()
  def new(type, raw) when is_binary(type) and is_map(raw), do: %__MODULE__{type: type, raw: raw}
end
