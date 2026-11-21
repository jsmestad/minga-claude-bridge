defmodule MingaClaudeBridge.Session.Event do
  @moduledoc """
  The events a `MingaClaudeBridge.Session` sends for one request, as `{ref, event}` messages.

    * `{:text, text}` and `{:thinking, text}` - streamed reply fragments, in order.
    * `{:tool_call, %{id, name, arguments}}` - a call Minga must run. `id` is the `tool_use` id, `name` is the Minga tool name (without the `mcp__minga__` prefix), and `arguments` is a string-keyed map.
    * `{:usage, usage}` - token counts for the request. Sent at most once, before the finish.
    * `{:finish, reason}` - the last event of every request, sent exactly once.

  The shapes match the events of Minga's inference route, so the route maps them one to one. Text, thinking, and arguments are conversation content. Do not log them.
  """

  @type usage :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          cache_write_tokens: non_neg_integer()
        }

  @type tool_call :: %{id: String.t(), name: String.t(), arguments: map()}

  @type finish_reason :: :stop | :tool_calls | :length | :refusal | {:error, term()}

  @type t ::
          {:text, String.t()}
          | {:thinking, String.t()}
          | {:tool_call, tool_call()}
          | {:usage, usage()}
          | {:finish, finish_reason()}
end
