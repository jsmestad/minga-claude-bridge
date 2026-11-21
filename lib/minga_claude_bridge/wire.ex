defmodule MingaClaudeBridge.Wire do
  @moduledoc """
  Codec for Claude Code's stream-json protocol.

  Claude Code started with `--input-format stream-json --output-format stream-json --verbose --include-partial-messages` reads and writes newline-delimited JSON (one JSON object per line) on stdin and stdout. This module decodes one output line into a typed frame and encodes the frames the bridge writes to stdin.

  ## Decoding

  `decode/1` never raises. It returns:

    * `{:ok, frame}` where `frame` is one of the structs in `t:frame/0`. A frame with a `type` this module does not model, or a `system` frame other than `init`, decodes to `MingaClaudeBridge.Wire.Unknown`.
    * `{:error, {:invalid_json, {kind, offset}}}` when the line is not valid JSON. The reason holds only the error kind and byte offset, never line content.
    * `{:error, :not_a_frame}` when the JSON value is not an object with a string `type`.
    * `{:error, {:invalid_frame, type}}` when a modeled frame lacks a required field or has a field of the wrong JSON type.

  Enumerated strings (stop reasons, result subtypes, rate-limit status) decode to atoms from closed tables. Unknown values decode to `{:other, string}`; the codec never creates atoms from input.

  ## Encoding

  Each encoder returns one complete line, newline included, ready to write to the Port. Optional fields that are `nil` are omitted from the JSON.

  ## Payloads

  Decoded frames hold conversation content. This module does not log or store anything, and callers must not log frame contents or `Unknown.raw`.

  ## Field-name sources

  Field names were checked against `@anthropic-ai/claude-agent-sdk` 0.3.330 (`sdk.d.ts` types and the `sdk.mjs` control-protocol implementation): `SDKSystemMessage`, `SDKPartialAssistantMessage`, `SDKAssistantMessage`, `SDKUserMessage`, `SDKResultSuccess`/`SDKResultError`, `SDKRateLimitEvent`/`SDKRateLimitInfo`, `SDKControlRequest`, `SDKControlResponse` (`ControlResponse`/`ControlErrorResponse`), `SDKControlCancelRequest`, `SDKControlInitializeRequest`, `SDKControlInterruptRequest`, `SDKControlMcpMessageRequest`, and `SDKControlPermissionRequest`. Stream events follow the Anthropic Messages API streaming events, which the SDK embeds as `BetaRawMessageStreamEvent`.

  ### Unverified

    * `resetsAt` units: Unix seconds per pi-claude-bridge observation, not stated in the SDK types. See `MingaClaudeBridge.Wire.RateLimit`.
    * The `user` input frame: the SDK type marks `session_id` and `uuid` optional, and pi-claude-bridge sends neither. Whether a given CLI version requires them on stdin is not confirmed; `user_message/2` omits them unless given.
    * The success reply to an `mcp_message` request wraps the JSON-RPC reply as `response.mcp_response`. This is confirmed from `sdk.mjs` but not from a typed declaration.
  """

  alias MingaClaudeBridge.Wire.{
    Assistant,
    Block,
    ControlCancel,
    ControlRequest,
    ControlResponse,
    RateLimit,
    Result,
    StreamEvent,
    SystemInit,
    Unknown,
    User
  }

  @type frame ::
          SystemInit.t()
          | StreamEvent.t()
          | Assistant.t()
          | User.t()
          | Result.t()
          | RateLimit.t()
          | ControlRequest.t()
          | ControlResponse.t()
          | ControlCancel.t()
          | Unknown.t()

  @type decode_error ::
          {:invalid_json, {kind :: atom(), offset :: non_neg_integer()}}
          | :not_a_frame
          | {:invalid_frame, type :: String.t()}

  @typedoc "One encoded frame: a JSON object followed by a newline."
  @type line :: String.t()

  @typedoc "A JSON-RPC 2.0 request id."
  @type jsonrpc_id :: String.t() | integer()

  @doc "Decodes one stream-json line. A trailing newline is allowed."
  @spec decode(binary()) :: {:ok, frame()} | {:error, decode_error()}
  def decode(line) when is_binary(line) do
    case JSON.decode(line) do
      {:ok, %{"type" => type} = map} when is_binary(type) -> decode_frame(type, map)
      {:ok, _other} -> {:error, :not_a_frame}
      {:error, reason} -> {:error, {:invalid_json, json_error(reason)}}
    end
  end

  defp decode_frame("system", %{"subtype" => "init"} = map),
    do: typed("system", SystemInit.from_wire(map))

  defp decode_frame("stream_event", map), do: typed("stream_event", StreamEvent.from_wire(map))
  defp decode_frame("assistant", map), do: typed("assistant", Assistant.from_wire(map))
  defp decode_frame("user", map), do: typed("user", User.from_wire(map))
  defp decode_frame("result", map), do: typed("result", Result.from_wire(map))

  defp decode_frame("rate_limit_event", map),
    do: typed("rate_limit_event", RateLimit.from_wire(map))

  defp decode_frame("control_request", map),
    do: typed("control_request", ControlRequest.from_wire(map))

  defp decode_frame("control_response", map),
    do: typed("control_response", ControlResponse.from_wire(map))

  defp decode_frame("control_cancel_request", map),
    do: typed("control_cancel_request", ControlCancel.from_wire(map))

  defp decode_frame(type, map), do: {:ok, Unknown.new(type, map)}

  defp typed(_type, {:ok, frame}), do: {:ok, frame}
  defp typed(type, :error), do: {:error, {:invalid_frame, type}}

  defp json_error({kind, offset}) when is_atom(kind), do: {kind, offset}
  defp json_error({kind, offset, _detail}) when is_atom(kind), do: {kind, offset}

  @doc """
  Encodes a `user` frame that sends a prompt or tool results to Claude Code.

  `content` is a string or a list of `MingaClaudeBridge.Wire.Block` values. A string is sent as one text block.

  Options:

    * `:session_id` - the Claude Code session id. Omitted when absent.
    * `:uuid` - a client message uuid that Claude Code echoes back on the reply. Omitted when absent.
  """
  @spec user_message(String.t() | [Block.t()], keyword()) :: line()
  def user_message(content, opts \\ [])

  def user_message(text, opts) when is_binary(text), do: user_message([{:text, text}], opts)

  def user_message(blocks, opts) when is_list(blocks) do
    %{
      "type" => "user",
      "message" => %{"role" => "user", "content" => Enum.map(blocks, &Block.to_wire/1)},
      "parent_tool_use_id" => nil
    }
    |> put_present("session_id", Keyword.get(opts, :session_id))
    |> put_present("uuid", Keyword.get(opts, :uuid))
    |> encode()
  end

  @doc """
  Encodes the `initialize` control request, which the bridge sends before the first prompt.

  Options:

    * `:sdk_mcp_servers` - names of the MCP servers the bridge hosts over the control channel, for example `["minga"]`.
    * `:system_prompt` - the system prompt, as a string or a list of strings. The wire field is a list; a string is sent as a one-element list.
    * `:append_system_prompt` - text appended to the system prompt.
  """
  @spec initialize(String.t(), keyword()) :: line()
  def initialize(request_id, opts \\ []) when is_binary(request_id) do
    request =
      %{"subtype" => "initialize"}
      |> put_present("sdkMcpServers", Keyword.get(opts, :sdk_mcp_servers))
      |> put_present("systemPrompt", system_prompt(Keyword.get(opts, :system_prompt)))
      |> put_present("appendSystemPrompt", Keyword.get(opts, :append_system_prompt))

    control_request(request_id, request)
  end

  @doc "Encodes the `interrupt` control request, which stops the current turn."
  @spec interrupt(String.t()) :: line()
  def interrupt(request_id) when is_binary(request_id),
    do: control_request(request_id, %{"subtype" => "interrupt"})

  @doc """
  Encodes a successful answer to an `mcp_message` control request whose JSON-RPC reply is a result.

  `jsonrpc_id` is the `id` of the JSON-RPC request inside the `mcp_message`. `request_id` is the control request's id.
  """
  @spec mcp_result(String.t(), jsonrpc_id(), map()) :: line()
  def mcp_result(request_id, jsonrpc_id, result) when is_binary(request_id) and is_map(result) do
    control_success(request_id, %{
      "mcp_response" => %{"jsonrpc" => "2.0", "id" => jsonrpc_id, "result" => result}
    })
  end

  @doc """
  Encodes a successful answer to an `mcp_message` control request whose JSON-RPC reply is an error, for example code `-32800` for a cancelled request.

  The control request itself succeeds; the JSON-RPC error tells the MCP client that the call failed.
  """
  @spec mcp_error(String.t(), jsonrpc_id(), integer(), String.t()) :: line()
  def mcp_error(request_id, jsonrpc_id, code, message)
      when is_binary(request_id) and is_integer(code) and is_binary(message) do
    control_success(request_id, %{
      "mcp_response" => %{
        "jsonrpc" => "2.0",
        "id" => jsonrpc_id,
        "error" => %{"code" => code, "message" => message}
      }
    })
  end

  @doc "Encodes a `control_response` that rejects a control request with an error message."
  @spec control_error(String.t(), String.t()) :: line()
  def control_error(request_id, message) when is_binary(request_id) and is_binary(message) do
    encode(%{
      "type" => "control_response",
      "response" => %{"subtype" => "error", "request_id" => request_id, "error" => message}
    })
  end

  defp control_request(request_id, request) do
    encode(%{"type" => "control_request", "request_id" => request_id, "request" => request})
  end

  defp control_success(request_id, response) do
    encode(%{
      "type" => "control_response",
      "response" => %{"subtype" => "success", "request_id" => request_id, "response" => response}
    })
  end

  defp system_prompt(nil), do: nil
  defp system_prompt(text) when is_binary(text), do: [text]
  defp system_prompt(parts) when is_list(parts), do: parts

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp encode(map), do: JSON.encode!(map) <> "\n"
end
