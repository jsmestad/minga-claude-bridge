defmodule MingaClaudeBridge.Wire.ControlCancel do
  @moduledoc """
  A `control_cancel_request` frame: the sender withdraws the `control_request` with the same `request_id`. The receiver should stop work on that request and must not answer it.
  """

  alias MingaClaudeBridge.Wire.Field

  @type t :: %__MODULE__{request_id: String.t()}

  @enforce_keys [:request_id]
  defstruct [:request_id]

  @doc "Decodes a `control_cancel_request` frame."
  @spec from_wire(Field.json_map()) :: {:ok, t()} | :error
  def from_wire(map) do
    with {:ok, request_id} <- Field.string(map, "request_id"),
         do: {:ok, %__MODULE__{request_id: request_id}}
  end
end
