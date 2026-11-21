defmodule MingaClaudeBridge.Session.Request do
  @moduledoc """
  One input to a `MingaClaudeBridge.Session`: a new prompt, or the results of the tool calls the previous request ended with.

    * `ref` - identifies the request. The session tags every event for this request with it.
    * `kind` - `{:prompt, content}` where `content` is a string or a list of `MingaClaudeBridge.Wire.Block` values, or `{:tool_results, results}`.
    * `tools` - the tools Minga offers for this request. The session answers `tools/list` and validates `tools/call` against them until the next request.

  A tool result is `%{tool_use_id: id, content: [part], is_error: boolean}`, where a part is a `t:MingaClaudeBridge.ToolCalls.part/0`. The request must carry one result for every tool call the previous request ended with.

  Content and results are conversation content. Do not log them.
  """

  alias MingaClaudeBridge.{MCP, ToolCalls}
  alias MingaClaudeBridge.Wire.Block

  @type tool_result :: %{
          tool_use_id: String.t(),
          content: [ToolCalls.part()],
          is_error: boolean()
        }

  @type kind :: {:prompt, String.t() | [Block.t()]} | {:tool_results, [tool_result()]}

  @type t :: %__MODULE__{ref: reference(), kind: kind(), tools: [MCP.tool()]}

  @enforce_keys [:ref, :kind, :tools]
  defstruct [:ref, :kind, :tools]

  @doc "Builds a prompt request with a new ref."
  @spec prompt(String.t() | [Block.t()], [MCP.tool()]) :: t()
  def prompt(content, tools) when (is_binary(content) or is_list(content)) and is_list(tools),
    do: %__MODULE__{ref: make_ref(), kind: {:prompt, content}, tools: tools}

  @doc "Builds a tool-results request with a new ref."
  @spec tool_results([tool_result()], [MCP.tool()]) :: t()
  def tool_results(results, tools) when is_list(results) and is_list(tools),
    do: %__MODULE__{ref: make_ref(), kind: {:tool_results, results}, tools: tools}
end
