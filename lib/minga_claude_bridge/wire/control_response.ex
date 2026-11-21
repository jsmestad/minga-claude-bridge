defmodule MingaClaudeBridge.Wire.ControlResponse do
  @moduledoc """
  A `control_response` frame: the answer to a `control_request`, in either direction.

  `outcome` is `{:ok, response}` for subtype `success`, where `response` is the decoded `response` object (an empty map when absent), or `{:error, message}` for subtype `error`. An answer to an `mcp_message` request carries the JSON-RPC reply under `response["mcp_response"]`.
  """

  alias MingaClaudeBridge.Wire.Field

  @type outcome :: {:ok, Field.json_map()} | {:error, String.t()}

  @type t :: %__MODULE__{request_id: String.t(), outcome: outcome()}

  @enforce_keys [:request_id, :outcome]
  defstruct [:request_id, :outcome]

  @doc "Decodes a `control_response` frame."
  @spec from_wire(Field.json_map()) :: {:ok, t()} | :error
  def from_wire(map) do
    with {:ok, response} <- Field.map(map, "response"),
         {:ok, request_id} <- Field.string(response, "request_id"),
         {:ok, outcome} <- outcome(response) do
      {:ok, %__MODULE__{request_id: request_id, outcome: outcome}}
    end
  end

  defp outcome(%{"subtype" => "success"} = response) do
    case Field.optional_map(response, "response") do
      {:ok, payload} -> {:ok, {:ok, payload || %{}}}
      :error -> :error
    end
  end

  defp outcome(%{"subtype" => "error"} = response) do
    with {:ok, message} <- Field.string(response, "error"), do: {:ok, {:error, message}}
  end

  defp outcome(_other), do: :error
end
