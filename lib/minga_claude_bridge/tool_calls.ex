defmodule MingaClaudeBridge.ToolCalls do
  @moduledoc """
  Pairs held MCP `tools/call` control requests with the tool results Minga sends later.

  When Claude Code calls a Minga tool, the bridge does not answer the control request. It holds the request here, keyed by the `tool_use` id from `params._meta["claudecode/toolUseId"]`, and ends the Minga turn with the tool calls. The next Minga request carries the results; `resolve/3` turns each result into the reply line for its held request.

  The correlator is a pure value: `tool_use_id => {control_request_id, jsonrpc_id}`.

    * `hold/2` rejects a `tool_use_id` that is already held.
    * `resolve/3` removes the id, so each held id resolves at most once. A second resolve, an id that was never held, and a resolve after `abort_all/1` return `{:error, :unknown_tool_use}`. Resolve order does not matter.
    * `abort_all/1` answers every held call with JSON-RPC error `-32800` (request cancelled) and returns an empty correlator.

  The correlator does not remember resolved ids. A later `hold/2` of an id that was resolved before is accepted; Claude Code assigns a new `tool_use` id to every call, so this does not happen in a valid session.

  ## Tool results

  A result is `%{content: [part], is_error: boolean}` where a part is `{:text, text}` or `{:image, media_type, data}` with `data` as raw bytes. It becomes the MCP `CallToolResult`: text parts become `{"type": "text", "text": ...}`, image parts become `{"type": "image", "data": base64, "mimeType": ...}`, and `isError` is set from `is_error`. Results are conversation content; do not log them.
  """

  alias MingaClaudeBridge.Wire

  @request_cancelled -32_800

  @typedoc "One call to hold: the ids needed to answer its control request later."
  @type held :: %{
          tool_use_id: String.t(),
          control_request_id: String.t(),
          jsonrpc_id: Wire.jsonrpc_id()
        }

  @type part :: {:text, String.t()} | {:image, media_type :: String.t(), data :: binary()}

  @type result :: %{content: [part()], is_error: boolean()}

  @opaque t :: %__MODULE__{pending: %{String.t() => {String.t(), Wire.jsonrpc_id()}}}

  @enforce_keys [:pending]
  defstruct [:pending]

  @doc "Returns an empty correlator."
  @spec new() :: t()
  def new, do: %__MODULE__{pending: %{}}

  @doc "Holds a call until its result arrives. Rejects a `tool_use_id` that is already held."
  @spec hold(t(), held()) :: {:ok, t()} | {:error, :duplicate_tool_use}
  def hold(%__MODULE__{pending: pending} = calls, %{
        tool_use_id: tool_use_id,
        control_request_id: control_request_id,
        jsonrpc_id: jsonrpc_id
      })
      when is_binary(tool_use_id) and is_binary(control_request_id) do
    case pending do
      %{^tool_use_id => _held} ->
        {:error, :duplicate_tool_use}

      _other ->
        {:ok, %{calls | pending: Map.put(pending, tool_use_id, {control_request_id, jsonrpc_id})}}
    end
  end

  @doc """
  Answers the held call `tool_use_id` with `result`. Returns the `control_response` line to write and the correlator without that call.
  """
  @spec resolve(t(), String.t(), result()) ::
          {:ok, Wire.line(), t()} | {:error, :unknown_tool_use}
  def resolve(%__MODULE__{pending: pending} = calls, tool_use_id, result) do
    case Map.pop(pending, tool_use_id) do
      {nil, _pending} ->
        {:error, :unknown_tool_use}

      {{control_request_id, jsonrpc_id}, rest} ->
        line = Wire.mcp_result(control_request_id, jsonrpc_id, call_tool_result(result))
        {:ok, line, %{calls | pending: rest}}
    end
  end

  @doc """
  Answers every held call with JSON-RPC error `-32800` and returns an empty correlator. Lines are ordered by `tool_use_id`.
  """
  @spec abort_all(t()) :: {[Wire.line()], t()}
  def abort_all(%__MODULE__{pending: pending}) do
    lines =
      pending
      |> Enum.sort()
      |> Enum.map(fn {_tool_use_id, {control_request_id, jsonrpc_id}} ->
        Wire.mcp_error(control_request_id, jsonrpc_id, @request_cancelled, "Request cancelled")
      end)

    {lines, new()}
  end

  @doc "Returns the held `tool_use` ids in sorted order."
  @spec pending_ids(t()) :: [String.t()]
  def pending_ids(%__MODULE__{pending: pending}), do: pending |> Map.keys() |> Enum.sort()

  @doc "Converts a tool result to an MCP `CallToolResult` map."
  @spec call_tool_result(result()) :: map()
  def call_tool_result(%{content: parts, is_error: is_error}) when is_boolean(is_error) do
    %{"content" => Enum.map(parts, &content_part/1), "isError" => is_error}
  end

  defp content_part({:text, text}) when is_binary(text), do: %{"type" => "text", "text" => text}

  defp content_part({:image, media_type, data}) when is_binary(media_type) and is_binary(data),
    do: %{"type" => "image", "data" => Base.encode64(data), "mimeType" => media_type}
end
