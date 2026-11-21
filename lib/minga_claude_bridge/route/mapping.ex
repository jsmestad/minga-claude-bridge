defmodule MingaClaudeBridge.Route.Mapping do
  @moduledoc """
  Pure conversions between Minga's route values (`MingaAgent.InferenceRoute.*`) and the bridge's session values.

  ## History entries

  `entries/1` turns `Request.messages` into `MingaClaudeBridge.History` entries. The `digest_input` of each entry keeps exactly what Claude Code saw of the message, in a form that does not depend on how Minga splits or stores it:

    * user and tool messages: their text, image, and tool-result parts in order; thinking parts are dropped.
    * assistant messages: `{:assistant, text, calls}` where `text` joins every text part and `calls` lists `{id, name, arguments}` in order; thinking parts are dropped.

  `assistant_entry/2` builds the same assistant form from the events the bridge streamed, so the entry recorded after a turn equals the one Minga sends back in the next request.

  The fingerprint covers the system prompt, the tool declarations, and the model and effort, because the model and effort are launch flags of the Claude Code process.

  ## Continuations

  `continuation/1` classifies the messages a request adds to a live session: only tool messages become tool results, only user messages become one prompt, and anything else needs a fresh session.

  ## Fresh sessions (lossy import)

  `fresh_prompt/1` imports earlier history as one structured transcript text block in front of the newest user input. The import is lossy: thinking and images of earlier messages are left out, and Claude Code sees earlier tool calls and results as text, not as its own tool use. Importing a session JSONL file for `--resume` would keep them; that is a follow-up.
  """

  alias MingaAgent.InferenceRoute.{Message, Model, Request, ToolCall, ToolDeclaration, Usage}
  alias MingaClaudeBridge.{History, ToolCalls}
  alias MingaClaudeBridge.Session.Event
  alias MingaClaudeBridge.Wire.Block

  @cli_efforts ~w(low medium high xhigh max)
  @default_context_window 200_000
  @default_max_output 32_000

  @type continuation ::
          {:tool_results, [MingaClaudeBridge.Session.Request.tool_result()]}
          | {:prompt, [Block.t()]}
          | :fresh

  @doc "Converts request messages to history entries."
  @spec entries([Message.t()]) :: [History.entry()]
  def entries(messages), do: Enum.map(messages, &entry/1)

  @doc "Converts one message to a history entry."
  @spec entry(Message.t()) :: History.entry()
  def entry(%Message{role: :assistant, content: parts}) do
    text = for {:text, text} <- parts, into: "", do: text
    calls = for {:tool_call, %ToolCall{} = call} <- parts, do: call_digest(call)
    %{role: :assistant, digest_input: {:assistant, text, calls}}
  end

  def entry(%Message{role: role, content: parts}),
    do: %{role: role, digest_input: Enum.flat_map(parts, &input_part/1)}

  @doc "Builds the assistant entry for a streamed reply: its joined text and its tool calls, in order."
  @spec assistant_entry(String.t(), [Event.tool_call()]) :: History.entry()
  def assistant_entry(text, calls) when is_binary(text),
    do: %{role: :assistant, digest_input: {:assistant, text, Enum.map(calls, &call_digest/1)}}

  @doc "Builds the history fingerprint for a request."
  @spec fingerprint(Request.t(), String.t() | nil) :: History.fingerprint()
  def fingerprint(%Request{} = request, effort) do
    %{
      system_prompt: request.system,
      tools: Enum.map(request.tools, &{&1.name, &1.description, &1.input_schema}),
      model: "#{request.model.id}|#{effort || "default"}"
    }
  end

  @doc "Returns the `--effort` level for a request, or `nil` when the selected level is not one the CLI accepts."
  @spec effort(Request.t()) :: String.t() | nil
  def effort(%Request{options: %{reasoning: reasoning}}) when reasoning in @cli_efforts,
    do: reasoning

  def effort(%Request{}), do: nil

  @doc "Returns the `--model` value: the model id, or `nil` for Claude Code's own default."
  @spec cli_model(Request.t()) :: String.t() | nil
  def cli_model(%Request{model: %Model{id: "default"}}), do: nil
  def cli_model(%Request{model: %Model{id: id}}), do: id

  @doc "Converts tool declarations to the session's `tools/list` set."
  @spec tools([ToolDeclaration.t()]) :: [MingaClaudeBridge.MCP.tool()]
  def tools(declarations) do
    Enum.map(declarations, fn declaration ->
      %{
        name: declaration.name,
        description: declaration.description || "",
        input_schema: declaration.input_schema
      }
    end)
  end

  @doc "Classifies the messages a request adds to a live session."
  @spec continuation([Message.t()]) :: continuation()
  def continuation([]), do: :fresh

  def continuation(messages) do
    cond do
      Enum.all?(messages, &(&1.role == :tool)) ->
        {:tool_results, Enum.flat_map(messages, &tool_results/1)}

      Enum.all?(messages, &(&1.role == :user)) ->
        {:prompt, Enum.flat_map(messages, &user_blocks/1)}

      true ->
        :fresh
    end
  end

  @doc """
  Builds the first prompt of a fresh session: the earlier history as one transcript block, then the newest user input. When the history ends with tool results instead of a user message, the transcript is followed by an instruction to continue.
  """
  @spec fresh_prompt([Message.t()]) :: [Block.t()]
  def fresh_prompt(messages) do
    case List.last(messages) do
      %Message{role: :user} = last ->
        transcript(Enum.drop(messages, -1)) ++ non_empty(user_blocks(last))

      _tool_or_assistant_or_none ->
        transcript(messages) ++
          [{:text, "Continue the conversation from where the transcript ends."}]
    end
  end

  @doc "Converts a session event to a route event."
  @spec event(Event.t()) :: MingaAgent.InferenceRoute.Event.t()
  def event({:tool_call, %{id: id, name: name, arguments: arguments}}),
    do: {:tool_call, %ToolCall{id: id, name: name, arguments: arguments}}

  def event({:usage, usage}), do: {:usage, struct(Usage, usage)}
  def event(other), do: other

  @doc "Converts a model entry of Claude Code's `initialize` answer to a route model."
  @spec model(map()) :: {:ok, Model.t()} | :error
  def model(entry), do: model(entry, %{})

  @doc """
  Converts a model entry using measured context windows (model id to tokens, see `MingaClaudeBridge.Route.Probe.measure/3`). A model without a measurement gets #{200_000} tokens.
  """
  @spec model(map(), %{String.t() => pos_integer()}) :: {:ok, Model.t()} | :error
  def model(%{"value" => id} = entry, windows) when is_binary(id) and id != "" do
    {:ok,
     %Model{
       id: id,
       display_name: display_name(entry, id),
       context_window: Map.get(windows, id, @default_context_window),
       max_output: @default_max_output,
       reasoning_levels: reasoning_levels(entry),
       tools?: true,
       images_in?: true,
       tool_result_images?: true,
       compaction: :native,
       usage: :tokens,
       cost: :subscription
     }}
  end

  def model(_entry, _windows), do: :error

  @doc "The model list shown when Claude Code cannot be probed."
  @spec fallback_models() :: [Model.t()]
  def fallback_models do
    for {id, name} <- [{"opus", "Opus"}, {"sonnet", "Sonnet"}, {"haiku", "Haiku"}] do
      {:ok, model} =
        model(%{"value" => id, "displayName" => name, "supportedEffortLevels" => @cli_efforts})

      model
    end
  end

  @doc "Returns a stable working-directory key for a conversation id."
  @spec workdir_key(String.t()) :: String.t()
  def workdir_key(conversation_id) do
    :crypto.hash(:sha256, conversation_id)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 32)
  end

  defp display_name(%{"displayName" => name}, _id) when is_binary(name) and name != "", do: name
  defp display_name(_entry, id), do: id

  defp reasoning_levels(%{"supportedEffortLevels" => [_ | _] = levels}) do
    case Enum.filter(levels, &is_binary/1) do
      [] -> ["default"]
      strings -> strings
    end
  end

  defp reasoning_levels(_entry), do: ["default"]

  defp call_digest(%{id: id, name: name, arguments: arguments}), do: {id, name, arguments}

  defp input_part({:text, text}), do: [{:text, text}]
  defp input_part({:image, media_type, data}), do: [{:image, media_type, data}]

  defp input_part({:tool_result, id, parts, is_error}),
    do: [{:tool_result, id, Enum.flat_map(parts, &input_part/1), is_error}]

  defp input_part({:tool_call, %ToolCall{} = call}), do: [{:tool_call, call_digest(call)}]
  defp input_part(_thinking_or_other), do: []

  defp tool_results(%Message{content: parts}) do
    for {:tool_result, id, content, is_error} <- parts do
      %{tool_use_id: id, content: tool_parts(content), is_error: is_error == true}
    end
  end

  @spec tool_parts([Message.part()]) :: [ToolCalls.part()]
  defp tool_parts(parts), do: Enum.flat_map(parts, &tool_part/1)

  defp tool_part({:text, text}), do: [{:text, text}]
  defp tool_part({:image, media_type, data}), do: [{:image, media_type, data}]
  defp tool_part(_other), do: []

  defp user_blocks(%Message{content: parts}), do: Enum.flat_map(parts, &user_block/1)

  defp user_block({:text, text}), do: [{:text, text}]

  defp user_block({:image, media_type, data}) do
    [
      {:other,
       %{
         "type" => "image",
         "source" => %{
           "type" => "base64",
           "media_type" => media_type,
           "data" => Base.encode64(data)
         }
       }}
    ]
  end

  defp user_block(_other), do: []

  defp non_empty([]), do: [{:text, ""}]
  defp non_empty(blocks), do: blocks

  defp transcript([]), do: []

  defp transcript(messages) do
    body = Enum.map_join(messages, "\n", &transcript_message/1)

    [
      {:text,
       "The conversation so far, carried over from an earlier session. Thinking and images are omitted.\n" <>
         "<transcript>\n" <> body <> "\n</transcript>"}
    ]
  end

  defp transcript_message(%Message{role: :tool, content: parts}) do
    Enum.map_join(parts, "\n", fn
      {:tool_result, id, content, is_error} ->
        ~s(<tool_result id="#{id}" error="#{is_error == true}">\n#{transcript_text(content)}\n</tool_result>)

      _other ->
        ""
    end)
  end

  defp transcript_message(%Message{role: role, content: parts}) do
    "<#{role}>\n" <> transcript_text(parts) <> "\n</#{role}>"
  end

  defp transcript_text(parts) do
    parts
    |> Enum.flat_map(fn
      {:text, text} ->
        [text]

      {:image, media_type, _data} ->
        ["[image #{media_type} omitted]"]

      {:tool_call, %ToolCall{} = call} ->
        [
          ~s(<tool_call id="#{call.id}" name="#{call.name}">#{JSON.encode!(call.arguments)}</tool_call>)
        ]

      _thinking ->
        []
    end)
    |> Enum.join("\n")
  end
end
