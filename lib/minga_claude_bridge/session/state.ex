defmodule MingaClaudeBridge.Session.State do
  @moduledoc """
  The pure state machine of one `MingaClaudeBridge.Session`.

  Each transition takes the state and one input, matches the phases where that input is valid, and returns `{:ok, state, outcome}` with a named outcome the session acts on. An input in any other phase returns `{:error, {:invalid_phase, tag}}` and leaves the state unchanged. Transitions perform no I/O: they return the lines to write, and the session writes them.

  ## Phases

    * `{:starting, queued}` - the process is starting and the session waits for the answer to its `initialize` control request. `queued` is a prompt request that arrived before that answer, or `nil`; it is written when startup completes. Claude Code sends the MCP `initialize` and `tools/list` requests in this phase, and they are answered.
    * `:idle` - no request is running.
    * `{:streaming, turn}` - a request is running, and `turn` accumulates its reply.
    * `{:awaiting_tool_results, calls}` - the previous request ended with tool calls. `calls` maps each `tool_use` id Minga must answer to its tool name.
    * `{:interrupting, reason}` - the session sent `interrupt` and waits for Claude Code to end the turn.
    * `{:dead, reason}` - the process is gone or must not be used. Every later request fails with `{:session_dead, reason}`.

  ## Tool calls and results

  Claude Code may send an MCP `tools/call` before or after the `message_stop` of the message that requested it, and it may dispatch the calls of one message one at a time, sending the next call only after the previous one is answered. The state therefore keeps two values next to the phase:

    * `calls` - held `tools/call` control requests (`MingaClaudeBridge.ToolCalls`), whatever the phase they arrived in.
    * `results` - tool results Minga already delivered for calls Claude Code has not sent yet, keyed by `tool_use` id.

  At `message_stop`, a message with `tool_use` blocks ends the request with those calls; the state does not wait for the MCP calls to arrive. A tool-results request must answer exactly the calls of the previous request. Each result answers its held call at once, or waits in `results` until Claude Code sends that call. A `tools/call` that arrives while no request is running or after an abort is answered with JSON-RPC error `-32800` and never held.

  ## Startup

  Claude Code 2.1.330 answers `initialize` without waiting for a prompt, and it sends `system`/`init` only when a user message starts a query. Startup therefore completes on a successful `initialize` answer. That answer's `account`, `models`, and `claude_code_version` are kept and returned by `info/1`. When a minimum version is configured, a `claude_code_version` that is missing, unparsable, or lower kills the session with `{:unsupported_version, version}`.

  ## Tool check (fail closed)

  Every query must start with a `system`/`init` frame that passes the tool check before any model output is accepted. `query` is `:unchecked` from the moment a prompt is written until that frame arrives. Tool results continue the same query, so they keep it `:checked`.

    * `system_init/2` kills the session with `{:unexpected_tools, names}` when `tools` contains a name without the `mcp__minga__` prefix or `mcp_servers` names a server other than `minga`.
    * A stream event, `assistant` frame, or `tools/call` while the query is `:unchecked` kills the session with `:missing_system_init`.

  Claude Code is therefore stopped before the model's first output reaches Minga, so no tool can run.

  ## Non-streaming fallback

  When a stream stalls, Claude Code can ask again without streaming and deliver the reply only as `assistant` frames under a new message id. `assistant/2` forwards those frames through `MingaClaudeBridge.Session.Turn`. Such a message has no `message_stop`, so the session calls `end_fallback_message/1` before it handles any frame other than `assistant`; when the fallback message holds `tool_use` blocks, that call suspends the request exactly as `message_stop` does.
  """

  alias MingaClaudeBridge.{MCP, ToolCalls}
  alias MingaClaudeBridge.Session.{Event, Request, Turn}
  alias MingaClaudeBridge.Wire

  alias MingaClaudeBridge.Wire.{
    Assistant,
    ControlRequest,
    ControlResponse,
    Result,
    StreamEvent,
    SystemInit
  }

  @tool_prefix "mcp__minga__"
  @request_cancelled -32_800
  @invalid_params -32_602

  @type phase ::
          {:starting, Request.t() | nil}
          | :idle
          | {:streaming, Turn.t()}
          | {:awaiting_tool_results, %{String.t() => String.t()}}
          | {:interrupting, term()}
          | {:dead, term()}

  @type phase_tag ::
          :starting | :idle | :streaming | :awaiting_tool_results | :interrupting | :dead

  @typedoc "Whether the running Claude Code query passed the tool check of its `system`/`init` frame."
  @type query :: :unchecked | :checked

  @typedoc """
  What Claude Code reported in its `initialize` answer. `account` and `models` are the raw JSON values. `account` holds the account email: never log it.
  """
  @type info :: %{
          account: map() | nil,
          models: [map()],
          claude_code_version: String.t() | nil
        }

  @type t :: %__MODULE__{
          phase: phase(),
          query: query(),
          info: info() | nil,
          tools: [MCP.tool()],
          initialize_id: String.t(),
          min_version: Version.t() | nil,
          calls: ToolCalls.t(),
          results: %{String.t() => ToolCalls.result()}
        }

  @enforce_keys [:phase, :query, :info, :tools, :initialize_id, :min_version, :calls, :results]
  defstruct [:phase, :query, :info, :tools, :initialize_id, :min_version, :calls, :results]

  @type invalid_phase :: {:invalid_phase, phase_tag()}

  @type invalid_tool_results ::
          {:duplicate_tool_use, [String.t()]}
          | {:unknown_tool_use, [String.t()]}
          | {:missing_tool_results, [String.t()]}

  @type request_error ::
          invalid_phase()
          | {:session_dead, term()}
          | {:invalid_tool_results, invalid_tool_results()}

  @type startup_outcome :: :ready | {:ready, {:prompt, Request.t()}} | {:dead, term()}

  @type suspend :: {:suspend, [Event.tool_call()], Event.usage() | nil}

  @type finish :: {:finish, Event.usage() | nil, Event.finish_reason()}

  @doc """
  Returns a starting state.

  Options:

    * `:initialize_id` (required) - the request id of the `initialize` control request the session sends.
    * `:tools` - the tools for `tools/list` until the first request. Defaults to `[]`.
    * `:min_version` - the lowest supported `claude_code_version`, as a string. `nil` (the default) skips the check.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      phase: {:starting, nil},
      query: :unchecked,
      info: nil,
      tools: Keyword.get(opts, :tools, []),
      initialize_id: Keyword.fetch!(opts, :initialize_id),
      min_version: parse_min_version(Keyword.get(opts, :min_version)),
      calls: ToolCalls.new(),
      results: %{}
    }
  end

  @doc "Returns the tag of the current phase."
  @spec phase_tag(t()) :: phase_tag()
  def phase_tag(%__MODULE__{phase: phase}), do: tag(phase)

  @doc "Returns what Claude Code reported at startup, or `nil` before startup completed."
  @spec info(t()) :: info() | nil
  def info(%__MODULE__{info: info}), do: info

  @doc """
  Applies the `system`/`init` frame that starts a query. Valid while streaming. A frame that passes the tool check marks the query `:checked`; any other kills the session with `{:unexpected_tools, names}`.
  """
  @spec system_init(t(), SystemInit.t()) ::
          {:ok, t(), :checked | {:dead, term()}} | {:error, invalid_phase()}
  def system_init(%__MODULE__{phase: {:streaming, _turn}} = state, %SystemInit{} = init) do
    case check_tools(init) do
      :ok -> {:ok, %{state | query: :checked}, :checked}
      {:error, reason} -> die(state, reason)
    end
  end

  def system_init(%__MODULE__{phase: phase}, %SystemInit{}), do: invalid(phase)

  @doc """
  Applies a `control_response`. A successful answer to the `initialize` request completes startup after the version check; an error answer kills the session with `{:initialize_failed, message}`. Other answers (for example to `interrupt`) are ignored.
  """
  @spec control_response(t(), ControlResponse.t()) ::
          {:ok, t(), startup_outcome() | :ignored} | {:error, invalid_phase()}
  def control_response(
        %__MODULE__{phase: {:starting, queued}, initialize_id: id} = state,
        %ControlResponse{request_id: id, outcome: outcome}
      ) do
    with {:ok, response} <- initialize_outcome(outcome),
         info = startup_info(response),
         :ok <- check_version(state.min_version, info.claude_code_version) do
      finish_startup(%{state | phase: :idle, info: info}, queued)
    else
      {:error, reason} -> die(state, reason)
    end
  end

  def control_response(%__MODULE__{phase: {:dead, _reason} = phase}, %ControlResponse{}),
    do: invalid(phase)

  def control_response(%__MODULE__{} = state, %ControlResponse{}), do: {:ok, state, :ignored}

  @doc """
  Accepts a request.

    * A prompt while idle starts streaming; the outcome `{:prompt, request}` tells the session to write it. A prompt while starting is queued (`:queued`) when no other request is queued.
    * Tool results while awaiting them answer the held calls; the outcome `{:tool_results, lines}` holds the reply lines to write. The results must name every awaited call exactly once, or the request is rejected with `{:invalid_tool_results, detail}` and the state does not change.
  """
  @spec request(t(), Request.t()) ::
          {:ok, t(), :queued | {:prompt, Request.t()} | {:tool_results, [Wire.line()]}}
          | {:error, request_error()}
  def request(
        %__MODULE__{phase: {:starting, nil}} = state,
        %Request{kind: {:prompt, _content}} = request
      ) do
    {:ok, %{state | phase: {:starting, request}, tools: request.tools}, :queued}
  end

  def request(%__MODULE__{phase: :idle} = state, %Request{kind: {:prompt, _content}} = request),
    do: start_prompt(state, request)

  def request(%__MODULE__{phase: :idle}, %Request{kind: {:tool_results, results}}),
    do: {:error, {:invalid_tool_results, {:unknown_tool_use, ids(results)}}}

  def request(
        %__MODULE__{phase: {:awaiting_tool_results, awaited}} = state,
        %Request{kind: {:tool_results, results}} = request
      ) do
    case check_results(awaited, results) do
      :ok -> answer_results(state, request, results)
      {:error, detail} -> {:error, {:invalid_tool_results, detail}}
    end
  end

  def request(%__MODULE__{phase: {:dead, reason}}, %Request{}),
    do: {:error, {:session_dead, reason}}

  def request(%__MODULE__{phase: phase}, %Request{}), do: invalid(phase)

  @doc """
  Applies a stream event while streaming.

  Returns `{:emit, events}` with the text and thinking events to forward, or, at the `message_stop` of a message with `tool_use` blocks, `{:suspend, tool_calls, usage}` and the `:awaiting_tool_results` phase. Subagent events (a non-nil `parent_tool_use_id`) and events while interrupting are `:ignored`. Any event before the query's `system`/`init` kills the session with `:missing_system_init`.
  """
  @spec stream_event(t(), StreamEvent.t()) ::
          {:ok, t(), {:emit, [Event.t()]} | suspend() | :ignored | {:dead, term()}}
          | {:error, invalid_phase()}
  def stream_event(
        %__MODULE__{phase: {:streaming, _turn}, query: :unchecked} = state,
        %StreamEvent{}
      ),
      do: die(state, :missing_system_init)

  def stream_event(%__MODULE__{phase: {:streaming, _turn}} = state, %StreamEvent{
        parent_tool_use_id: parent
      })
      when is_binary(parent),
      do: {:ok, state, :ignored}

  def stream_event(%__MODULE__{phase: {:streaming, turn}} = state, %StreamEvent{
        event: :message_stop
      }) do
    case Turn.stop_message(turn) do
      {:tool_calls, calls, turn} -> suspend(state, calls, turn)
      {:no_tool_calls, turn} -> {:ok, %{state | phase: {:streaming, turn}}, {:emit, []}}
    end
  end

  def stream_event(%__MODULE__{phase: {:streaming, turn}} = state, %StreamEvent{event: event}) do
    {turn, events} = Turn.apply_event(turn, event)
    {:ok, %{state | phase: {:streaming, turn}}, {:emit, events}}
  end

  def stream_event(%__MODULE__{phase: {:interrupting, _reason}} = state, %StreamEvent{}),
    do: {:ok, state, :ignored}

  def stream_event(%__MODULE__{phase: phase}, %StreamEvent{}), do: invalid(phase)

  @doc """
  Applies an `assistant` frame while streaming. Frames of messages that were streamed are ignored by the turn; frames of a non-streaming fallback message yield their text and thinking as `{:emit, events}` (see `MingaClaudeBridge.Session.Turn.apply_assistant/2`). Subagent frames and frames while interrupting are `:ignored`. A frame before the query's `system`/`init` kills the session with `:missing_system_init`.
  """
  @spec assistant(t(), Assistant.t()) ::
          {:ok, t(), {:emit, [Event.t()]} | :ignored | {:dead, term()}}
          | {:error, invalid_phase()}
  def assistant(%__MODULE__{phase: {:streaming, _turn}, query: :unchecked} = state, %Assistant{}),
    do: die(state, :missing_system_init)

  def assistant(%__MODULE__{phase: {:streaming, _turn}} = state, %Assistant{
        parent_tool_use_id: parent
      })
      when is_binary(parent),
      do: {:ok, state, :ignored}

  def assistant(%__MODULE__{phase: {:streaming, turn}} = state, %Assistant{} = frame) do
    {turn, events} = Turn.apply_assistant(turn, frame)
    {:ok, %{state | phase: {:streaming, turn}}, {:emit, events}}
  end

  def assistant(%__MODULE__{phase: {:interrupting, _reason}} = state, %Assistant{}),
    do: {:ok, state, :ignored}

  def assistant(%__MODULE__{phase: phase}, %Assistant{}), do: invalid(phase)

  @doc """
  Ends a non-streaming fallback message, which has no `message_stop`. The session calls it before every frame other than `assistant`. While streaming, a fallback message with `tool_use` blocks suspends the request (`{:suspend, tool_calls, usage}`); otherwise the outcome is `:unchanged`.
  """
  @spec end_fallback_message(t()) ::
          {:ok, t(), suspend() | :unchanged} | {:error, invalid_phase()}
  def end_fallback_message(%__MODULE__{phase: {:streaming, turn}} = state) do
    case Turn.end_fallback(turn) do
      {:tool_calls, calls, turn} -> suspend(state, calls, turn)
      {:no_tool_calls, _turn} -> {:ok, state, :unchanged}
    end
  end

  def end_fallback_message(%__MODULE__{phase: phase}), do: invalid(phase)

  @doc """
  Applies a `control_request` from Claude Code. Returns `{:reply, line}` with the answer to write, or `:held` when a `tools/call` waits for its result. A `tools/call` while streaming a query that has not passed its `system`/`init` check kills the session with `:missing_system_init`.

  Only `mcp_message` requests for the `minga` server are served. Every other request (`can_use_tool`, another MCP server, an unknown subtype) is answered with a control error: the bridge never grants Claude Code permissions.
  """
  @spec control_request(t(), ControlRequest.t()) ::
          {:ok, t(), {:reply, Wire.line()} | :held | {:dead, term()}} | {:error, invalid_phase()}
  def control_request(%__MODULE__{phase: {:dead, _reason} = phase}, %ControlRequest{}),
    do: invalid(phase)

  def control_request(%__MODULE__{} = state, %ControlRequest{
        request_id: id,
        request: {:mcp_message, %{server_name: server, message: message}}
      }) do
    if server == MCP.server_name() do
      mcp_message(state, id, message)
    else
      {:ok, state, {:reply, Wire.control_error(id, "Unknown MCP server")}}
    end
  end

  def control_request(%__MODULE__{} = state, %ControlRequest{request_id: id}),
    do: {:ok, state, {:reply, Wire.control_error(id, "Not supported by the Minga bridge")}}

  @doc """
  Applies the `result` frame that ends a Claude Code turn.

    * While streaming: returns to `:idle` with `{:finish, usage, reason}`.
    * While interrupting: returns to `:idle` with `:interrupted`.
    * While awaiting tool results: Claude Code ended the turn without the results. Returns to `:idle` with `:abandoned`; the awaited calls are dropped.
  """
  @spec result(t(), Result.t()) ::
          {:ok, t(), finish() | :interrupted | :abandoned} | {:error, invalid_phase()}
  def result(%__MODULE__{phase: {:streaming, turn}} = state, %Result{} = result) do
    turn = without_fallback(Turn.end_fallback(turn))
    usage = Turn.usage(turn) || Turn.event_usage(result.usage)
    {:ok, become_idle(state), {:finish, usage, finish_reason(turn, result)}}
  end

  def result(%__MODULE__{phase: {:interrupting, _reason}} = state, %Result{}),
    do: {:ok, become_idle(state), :interrupted}

  def result(%__MODULE__{phase: {:awaiting_tool_results, _awaited}} = state, %Result{}),
    do: {:ok, become_idle(state), :abandoned}

  def result(%__MODULE__{phase: phase}, %Result{}), do: invalid(phase)

  @doc """
  Aborts the running request.

  While streaming or awaiting tool results, moves to `{:interrupting, reason}` and returns `{:interrupt, cancel_lines}`: every held call is answered with JSON-RPC error `-32800`, and results waiting for their call are dropped. While starting with a queued prompt, drops the prompt (`:dequeued`).
  """
  @spec abort(t(), term()) ::
          {:ok, t(), {:interrupt, [Wire.line()]} | :dequeued} | {:error, invalid_phase()}
  def abort(%__MODULE__{phase: {:streaming, _turn}} = state, reason), do: interrupt(state, reason)

  def abort(%__MODULE__{phase: {:awaiting_tool_results, _awaited}} = state, reason),
    do: interrupt(state, reason)

  def abort(%__MODULE__{phase: {:starting, %Request{}}} = state, _reason),
    do: {:ok, %{state | phase: {:starting, nil}}, :dequeued}

  def abort(%__MODULE__{phase: phase}, _reason), do: invalid(phase)

  @doc "Claude Code did not end the turn in time after `interrupt`. Kills the session with `:interrupt_timeout`."
  @spec interrupt_timeout(t()) ::
          {:ok, t(), {:dead, :interrupt_timeout}} | {:error, invalid_phase()}
  def interrupt_timeout(%__MODULE__{phase: {:interrupting, _reason}} = state),
    do: die(state, :interrupt_timeout)

  def interrupt_timeout(%__MODULE__{phase: phase}), do: invalid(phase)

  @doc "Startup did not finish in time. Kills the session with `:startup_timeout`."
  @spec startup_timeout(t()) :: {:ok, t(), {:dead, :startup_timeout}} | {:error, invalid_phase()}
  def startup_timeout(%__MODULE__{phase: {:starting, _queued}} = state),
    do: die(state, :startup_timeout)

  def startup_timeout(%__MODULE__{phase: phase}), do: invalid(phase)

  @doc """
  Accepts a client-initiated control request, such as `get_usage` or `get_context_usage`, while no request is running. Returns `{:error, {:invalid_phase, tag}}` in every other phase, so a control request never interleaves with a turn.
  """
  @spec control(t()) :: :ok | {:error, invalid_phase()}
  def control(%__MODULE__{phase: :idle}), do: :ok
  def control(%__MODULE__{phase: phase}), do: invalid(phase)

  @doc "The session stayed idle for the idle timeout. Ends it with `:idle_timeout`."
  @spec idle_timeout(t()) :: {:ok, t(), {:dead, :idle_timeout}} | {:error, invalid_phase()}
  def idle_timeout(%__MODULE__{phase: :idle} = state), do: die(state, :idle_timeout)
  def idle_timeout(%__MODULE__{phase: phase}), do: invalid(phase)

  @doc """
  The transport exited or failed, or a line could not be decoded. Kills the session with `reason` from any live phase.
  """
  @spec transport_down(t(), term()) :: {:ok, t(), {:dead, term()}} | {:error, invalid_phase()}
  def transport_down(%__MODULE__{phase: {:dead, _reason} = phase}, _reason_now),
    do: invalid(phase)

  def transport_down(%__MODULE__{} = state, reason), do: die(state, reason)

  # Startup

  defp initialize_outcome({:ok, response}), do: {:ok, response}
  defp initialize_outcome({:error, message}), do: {:error, {:initialize_failed, message}}

  defp startup_info(response) do
    %{
      account: map_or_nil(Map.get(response, "account")),
      models: list_or_empty(Map.get(response, "models")),
      claude_code_version: string_or_nil(Map.get(response, "claude_code_version"))
    }
  end

  defp map_or_nil(value) when is_map(value), do: value
  defp map_or_nil(_value), do: nil
  defp list_or_empty(value) when is_list(value), do: Enum.filter(value, &is_map/1)
  defp list_or_empty(_value), do: []
  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp check_tools(%SystemInit{tools: tools, mcp_servers: servers}) do
    server_name = MCP.server_name()

    unexpected =
      Enum.reject(tools, &String.starts_with?(&1, @tool_prefix)) ++
        for(%{name: name} <- servers, name != server_name, do: "mcp_server:" <> name)

    case unexpected do
      [] -> :ok
      names -> {:error, {:unexpected_tools, names}}
    end
  end

  defp check_version(nil, _version), do: :ok

  defp check_version(%Version{} = minimum, version) do
    with {:ok, parsed} <- parse_version(version),
         :ok <- at_least(parsed, minimum) do
      :ok
    else
      :error -> {:error, {:unsupported_version, version}}
    end
  end

  defp parse_version(version) when is_binary(version), do: Version.parse(version)
  defp parse_version(nil), do: :error

  defp at_least(version, minimum) do
    case Version.compare(version, minimum) do
      :lt -> :error
      _eq_or_gt -> :ok
    end
  end

  defp parse_min_version(nil), do: nil
  defp parse_min_version(version) when is_binary(version), do: Version.parse!(version)

  defp finish_startup(state, nil), do: {:ok, state, :ready}

  defp finish_startup(state, %Request{} = request) do
    {:ok, state, prompt} = start_prompt(state, request)
    {:ok, state, {:ready, prompt}}
  end

  # Requests

  defp start_prompt(state, %Request{} = request) do
    state = %{state | phase: {:streaming, Turn.new()}, query: :unchecked, tools: request.tools}
    {:ok, state, {:prompt, request}}
  end

  defp ids(results), do: Enum.map(results, & &1.tool_use_id)

  defp check_results(awaited, results) do
    ids = ids(results)
    duplicates = Enum.uniq(ids -- Enum.uniq(ids))
    unknown = ids |> Enum.reject(&Map.has_key?(awaited, &1)) |> Enum.uniq()
    missing = awaited |> Map.keys() |> Enum.reject(&(&1 in ids)) |> Enum.sort()

    cond do
      duplicates != [] -> {:error, {:duplicate_tool_use, duplicates}}
      unknown != [] -> {:error, {:unknown_tool_use, unknown}}
      missing != [] -> {:error, {:missing_tool_results, missing}}
      true -> :ok
    end
  end

  defp answer_results(state, request, results) do
    {lines, calls, waiting} =
      Enum.reduce(results, {[], state.calls, state.results}, fn result, {lines, calls, waiting} ->
        call_result = %{content: result.content, is_error: result.is_error}

        case ToolCalls.resolve(calls, result.tool_use_id, call_result) do
          {:ok, line, calls} ->
            {[line | lines], calls, waiting}

          {:error, :unknown_tool_use} ->
            {lines, calls, Map.put(waiting, result.tool_use_id, call_result)}
        end
      end)

    state = %{
      state
      | phase: {:streaming, Turn.new()},
        tools: request.tools,
        calls: calls,
        results: waiting
    }

    {:ok, state, {:tool_results, Enum.reverse(lines)}}
  end

  # MCP

  defp mcp_message(state, request_id, message) do
    case MCP.route(message, state.tools) do
      {:tool_call, call} -> tool_call(state, request_id, call)
      reply -> {:ok, state, {:reply, MCP.reply_line(request_id, reply)}}
    end
  end

  defp tool_call(%__MODULE__{phase: {:streaming, _turn}, query: :unchecked} = state, _id, _call),
    do: die(state, :missing_system_init)

  defp tool_call(%__MODULE__{phase: {:streaming, _turn}} = state, request_id, call),
    do: accept_call(state, request_id, call)

  defp tool_call(
         %__MODULE__{phase: {:awaiting_tool_results, _awaited}} = state,
         request_id,
         call
       ),
       do: accept_call(state, request_id, call)

  defp tool_call(%__MODULE__{} = state, request_id, call) do
    line = Wire.mcp_error(request_id, call.jsonrpc_id, @request_cancelled, "Request cancelled")
    {:ok, state, {:reply, line}}
  end

  defp accept_call(state, request_id, call) do
    case Map.pop(state.results, call.tool_use_id) do
      {nil, _results} ->
        hold_call(state, request_id, call)

      {result, results} ->
        line = Wire.mcp_result(request_id, call.jsonrpc_id, ToolCalls.call_tool_result(result))
        {:ok, %{state | results: results}, {:reply, line}}
    end
  end

  defp hold_call(state, request_id, call) do
    held = %{
      tool_use_id: call.tool_use_id,
      control_request_id: request_id,
      jsonrpc_id: call.jsonrpc_id
    }

    case ToolCalls.hold(state.calls, held) do
      {:ok, calls} ->
        {:ok, %{state | calls: calls}, :held}

      {:error, :duplicate_tool_use} ->
        line =
          Wire.mcp_error(request_id, call.jsonrpc_id, @invalid_params, "Duplicate tool call")

        {:ok, state, {:reply, line}}
    end
  end

  # Turn end

  defp finish_reason(_turn, %Result{is_error: true} = result), do: {:error, claude_error(result)}

  defp finish_reason(_turn, %Result{subtype: subtype} = result) when subtype != :success,
    do: {:error, claude_error(result)}

  defp finish_reason(turn, %Result{stop_reason: stop_reason}),
    do: stop_finish(Turn.stop_reason(turn) || stop_reason)

  defp claude_error(%Result{subtype: subtype, result: text, errors: errors}),
    do: {:claude_error, subtype, text || Enum.join(errors, "\n")}

  defp stop_finish(reason) when reason in [:max_tokens, :model_context_window_exceeded],
    do: :length

  defp stop_finish(:refusal), do: :refusal
  defp stop_finish(_end_turn_or_other), do: :stop

  defp suspend(state, calls, turn) do
    awaited = Map.new(calls, &{&1.id, &1.name})

    {:ok, %{state | phase: {:awaiting_tool_results, awaited}},
     {:suspend, calls, Turn.usage(turn)}}
  end

  # Claude Code ended the turn, so tool calls of an unfinished fallback message will never run.
  defp without_fallback({:tool_calls, _calls, turn}), do: turn
  defp without_fallback({:no_tool_calls, turn}), do: turn

  defp interrupt(state, reason) do
    {lines, calls} = ToolCalls.abort_all(state.calls)

    {:ok, %{state | phase: {:interrupting, reason}, calls: calls, results: %{}},
     {:interrupt, lines}}
  end

  defp become_idle(state), do: %{state | phase: :idle, calls: ToolCalls.new(), results: %{}}

  defp die(state, reason) do
    {:ok, %{state | phase: {:dead, reason}, calls: ToolCalls.new(), results: %{}},
     {:dead, reason}}
  end

  defp invalid(phase), do: {:error, {:invalid_phase, tag(phase)}}

  defp tag({:starting, _queued}), do: :starting
  defp tag(:idle), do: :idle
  defp tag({:streaming, _turn}), do: :streaming
  defp tag({:awaiting_tool_results, _awaited}), do: :awaiting_tool_results
  defp tag({:interrupting, _reason}), do: :interrupting
  defp tag({:dead, _reason}), do: :dead
end
