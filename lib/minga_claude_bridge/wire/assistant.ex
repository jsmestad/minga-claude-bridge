defmodule MingaClaudeBridge.Wire.Assistant do
  @moduledoc """
  An `assistant` frame: a complete or partial assistant message.

  With `--include-partial-messages`, Claude Code emits an `assistant` frame per content block after the matching stream events, so `content` usually holds one block and `stop_reason` is often `nil`. A `model` of `"<synthetic>"` marks a message Claude Code made itself, for example after an API error; its usage counts are zero.

  `error` decodes the SDK's `SDKAssistantMessageError` values to atoms. An unknown value decodes to `{:other, string}`.
  """

  alias MingaClaudeBridge.Wire.{Block, Field, StopReason, Usage}

  @type error ::
          :authentication_failed
          | :oauth_org_not_allowed
          | :account_on_hold
          | :verification_required
          | :billing_error
          | :rate_limit
          | :overloaded
          | :invalid_request
          | :model_not_found
          | :server_error
          | :unknown
          | :max_output_tokens
          | :cloud_credential_error
          | {:other, String.t()}

  @type t :: %__MODULE__{
          content: [Block.t()],
          id: String.t() | nil,
          model: String.t() | nil,
          stop_reason: StopReason.t() | nil,
          usage: Usage.t() | nil,
          error: error() | nil,
          parent_tool_use_id: String.t() | nil,
          session_id: String.t() | nil,
          uuid: String.t() | nil
        }

  @enforce_keys [:content]
  defstruct [
    :content,
    :id,
    :model,
    :stop_reason,
    :usage,
    :error,
    :parent_tool_use_id,
    :session_id,
    :uuid
  ]

  @errors %{
    "authentication_failed" => :authentication_failed,
    "oauth_org_not_allowed" => :oauth_org_not_allowed,
    "account_on_hold" => :account_on_hold,
    "verification_required" => :verification_required,
    "billing_error" => :billing_error,
    "rate_limit" => :rate_limit,
    "overloaded" => :overloaded,
    "invalid_request" => :invalid_request,
    "model_not_found" => :model_not_found,
    "server_error" => :server_error,
    "unknown" => :unknown,
    "max_output_tokens" => :max_output_tokens,
    "cloud_credential_error" => :cloud_credential_error
  }

  @doc "Decodes an `assistant` frame."
  @spec from_wire(Field.json_map()) :: {:ok, t()} | :error
  def from_wire(map) do
    with {:ok, message} <- Field.map(map, "message"),
         {:ok, content} <- Block.content_from_wire(Map.get(message, "content")),
         {:ok, id} <- Field.optional_string(message, "id"),
         {:ok, model} <- Field.optional_string(message, "model"),
         {:ok, stop_reason} <- StopReason.field(message, "stop_reason"),
         {:ok, usage} <- Usage.field(message, "usage"),
         {:ok, error} <- Field.optional_enum(map, "error", @errors),
         {:ok, parent} <- Field.optional_string(map, "parent_tool_use_id"),
         {:ok, session_id} <- Field.optional_string(map, "session_id"),
         {:ok, uuid} <- Field.optional_string(map, "uuid") do
      {:ok,
       %__MODULE__{
         content: content,
         id: id,
         model: model,
         stop_reason: stop_reason,
         usage: usage,
         error: error,
         parent_tool_use_id: parent,
         session_id: session_id,
         uuid: uuid
       }}
    end
  end
end
