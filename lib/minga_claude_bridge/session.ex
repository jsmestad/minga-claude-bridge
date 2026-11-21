defmodule MingaClaudeBridge.Session do
  @moduledoc """
  One Claude Code process serving one Minga conversation.

  The session owns a `MingaClaudeBridge.Transport` and a pure `MingaClaudeBridge.Session.State`. It decodes each line from the transport, applies it to the state, and performs the effects the state asks for: writing lines, sending events to the subscriber, and starting or stopping timers.

  ## Lifecycle

  `start_link/1` starts the transport, writes the `initialize` control request, and waits for its answer (see `MingaClaudeBridge.Session.State`). A prompt that arrives during startup is written once startup completes. If the answer does not arrive within `:startup_timeout`, is an error, or reports an unsupported version, the transport is stopped before any prompt is written. `info/1` returns the account and models from the answer.

  Each query's `system`/`init` frame must pass the tool check before any model output is accepted. On failure the session stops the transport, dies, and finishes the request with `{:error, {:unexpected_tools, names}}` before it forwards any event of that query.

  Every failure leaves the session in `{:dead, reason}`: the transport is stopped, the running request (if any) finishes with `{:error, reason}`, and every later `request/3` returns `{:error, {:session_dead, reason}}`. The session process stays alive so callers can read that reason; the owner of the session replaces it. In `:idle` only, the session stops normally after `:idle_timeout`.

  The session is `restart: :temporary` and traps exits; `terminate/2` stops the transport.

  ## Requests and events

  `request/3` starts a request and returns its ref. The subscriber then receives `{ref, event}` messages (see `MingaClaudeBridge.Session.Event`), ending with exactly one `{ref, {:finish, reason}}`. A tool-results request whose ids do not match the awaited calls is accepted, and its subscriber receives only `{:finish, {:error, {:invalid_tool_results, detail}}}`; nothing is written for it.

  The session monitors the subscriber of the running request. If the subscriber exits before the finish, the session aborts the request.

  ## Abort

  `abort/2` writes `interrupt`, answers every held tool call with JSON-RPC error `-32800`, and sends the subscriber `{:finish, {:error, :aborted}}` at once. Events already sent stay valid. Claude Code then has `:interrupt_timeout` milliseconds to end the turn with a `result` frame, after which the session is idle again. Otherwise the session stops the transport and dies with `:interrupt_timeout`.

  ## Rate limits

  Each `rate_limit_event` is forwarded to the `:on_rate_limit` target without waiting: a pid receives `{:claude_bridge_rate_limit, session_pid, %MingaClaudeBridge.Wire.RateLimit{}}`, and a one-argument function runs in a separate unlinked task.

  ## Logging

  The session logs frame types and lifecycle changes only, never payloads.
  """

  use GenServer, restart: :temporary

  require Logger

  alias MingaClaudeBridge.History
  alias MingaClaudeBridge.Session.{Event, Request, State}
  alias MingaClaudeBridge.Wire

  alias MingaClaudeBridge.Wire.{
    Assistant,
    ControlRequest,
    ControlResponse,
    RateLimit,
    Result,
    StreamEvent,
    SystemInit
  }

  @default_idle_timeout 15 * 60 * 1000
  @default_interrupt_timeout 1000
  @default_startup_timeout 30_000
  @initialize_id "minga_init"

  @typedoc "Where rate-limit events go."
  @type rate_limit_target :: pid() | (RateLimit.t() -> term()) | nil

  @typedoc "The subscriber of the request that has not finished yet."
  @type active :: %{ref: reference(), subscriber: pid(), monitor: reference()}

  @type timeout_ms :: non_neg_integer() | :infinity

  @type t :: %__MODULE__{
          transport: module(),
          handle: MingaClaudeBridge.Transport.handle() | nil,
          transport_ref: reference(),
          state: State.t(),
          active: active() | nil,
          last_ref: reference() | nil,
          on_rate_limit: rate_limit_target(),
          idle_timeout: timeout_ms(),
          interrupt_timeout: non_neg_integer(),
          timer: {atom(), reference()} | nil,
          next_id: pos_integer(),
          owner_monitor: reference() | nil,
          ready_waiters: [GenServer.from()],
          seen: History.t(),
          launch: keyword()
        }

  @enforce_keys [
    :transport,
    :transport_ref,
    :state,
    :on_rate_limit,
    :idle_timeout,
    :interrupt_timeout
  ]
  defstruct [
    :transport,
    :handle,
    :transport_ref,
    :state,
    :active,
    :last_ref,
    :on_rate_limit,
    :idle_timeout,
    :interrupt_timeout,
    :timer,
    :owner_monitor,
    :seen,
    :launch,
    next_id: 1,
    ready_waiters: []
  ]

  @doc """
  Starts a session.

  Options:

    * `:transport` (required) - `{module, opts}` where `module` implements `MingaClaudeBridge.Transport`.
    * `:system_prompt` - sent with `initialize`.
    * `:model`, `:effort`, `:resume`, `:persist_session` - passed to the transport as `:launch` settings (see `MingaClaudeBridge.Launch`). `:resume` is a Claude Code session id or `nil`.
    * `:tools` - the tool declarations for `tools/list` until the first request.
    * `:min_version` - the lowest supported `claude_code_version`, or `nil` to skip the check.
    * `:on_rate_limit` - a pid or a one-argument function. See the module documentation.
    * `:idle_timeout` - milliseconds in `:idle` before the session stops, or `:infinity`. Defaults to 15 minutes.
    * `:interrupt_timeout` - milliseconds Claude Code has to end a turn after `interrupt`. Defaults to #{@default_interrupt_timeout}.
    * `:startup_timeout` - milliseconds to finish startup. Defaults to #{@default_startup_timeout}.
    * `:owner` - a pid. When it exits, the session stops normally, which stops Claude Code. Use it with `start/1` for a session that must not outlive the process that uses it.
    * `:name` - a GenServer name.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, name_opts)
  end

  @doc """
  Starts a session without linking it to the caller. A failed start returns `{:error, reason}` instead of exiting the caller. Pass `:owner` so the session stops when the caller exits.
  """
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    {name_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start(__MODULE__, opts, name_opts)
  end

  @doc """
  Waits until startup completes. Returns `{:ok, info}` (see `info/1`) once Claude Code answered `initialize`, or `{:error, reason}` when the session died first. Exits when `timeout` passes, like `GenServer.call/3`.
  """
  @spec await_ready(GenServer.server(), timeout()) :: {:ok, State.info()} | {:error, term()}
  def await_ready(session, timeout \\ 30_000), do: GenServer.call(session, :await_ready, timeout)

  @doc """
  Returns the history digests this Claude Code process has seen (see `MingaClaudeBridge.History`). A new session has seen nothing.
  """
  @spec seen(GenServer.server()) :: History.t()
  def seen(session), do: GenServer.call(session, :seen)

  @doc """
  Records what this Claude Code process has seen after a completed request. The caller builds `history` with `MingaClaudeBridge.History.record/2`.
  """
  @spec remember(GenServer.server(), History.t()) :: :ok
  def remember(session, history), do: GenServer.call(session, {:remember, history})

  @doc "Returns the launch settings the process was started with (`:model`, `:effort`, `:resume`, `:persist_session`)."
  @spec launch(GenServer.server()) :: keyword()
  def launch(session), do: GenServer.call(session, :launch)

  @doc """
  Starts a request. `subscriber` receives the request's events as `{ref, event}` messages, where `ref` is `request.ref`.

  Returns `{:error, {:session_dead, reason}}` on a dead session and `{:error, {:invalid_phase, tag}}` when the session cannot take this kind of request now, for example while another request runs.
  """
  @spec request(GenServer.server(), Request.t(), pid()) ::
          {:ok, reference()} | {:error, State.request_error()}
  def request(session, %Request{} = request, subscriber) when is_pid(subscriber),
    do: GenServer.call(session, {:request, request, subscriber})

  @doc """
  Aborts the request `ref`: the running request, or the last one when it ended with tool calls. Returns `{:error, :unknown_request}` for any other ref and `{:error, {:invalid_phase, tag}}` when nothing can be aborted.
  """
  @spec abort(GenServer.server(), reference()) ::
          :ok | {:error, :unknown_request | State.invalid_phase()}
  def abort(session, ref) when is_reference(ref), do: GenServer.call(session, {:abort, ref})

  @doc """
  Returns what Claude Code reported in its `initialize` answer: `%{account, models, claude_code_version}`, or `nil` before startup completed. `account` holds the account email; never log it.
  """
  @spec info(GenServer.server()) :: State.info() | nil
  def info(session), do: GenServer.call(session, :info)

  @doc "Returns the current phase tag, for diagnostics."
  @spec phase(GenServer.server()) :: State.phase_tag()
  def phase(session), do: GenServer.call(session, :phase)

  # Callbacks

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    {transport, transport_opts} = Keyword.fetch!(opts, :transport)
    transport_ref = make_ref()

    start_opts =
      Keyword.merge(transport_opts,
        owner: self(),
        ref: transport_ref,
        launch: Keyword.take(opts, [:model, :effort, :resume, :persist_session])
      )

    case transport.start(start_opts) do
      {:ok, handle} ->
        session = %__MODULE__{
          transport: transport,
          handle: handle,
          transport_ref: transport_ref,
          state:
            State.new(
              initialize_id: @initialize_id,
              tools: Keyword.get(opts, :tools, []),
              min_version: Keyword.get(opts, :min_version)
            ),
          on_rate_limit: Keyword.get(opts, :on_rate_limit),
          owner_monitor: monitor_owner(Keyword.get(opts, :owner)),
          seen: History.new(),
          launch: Keyword.take(opts, [:model, :effort, :resume, :persist_session]),
          idle_timeout: Keyword.get(opts, :idle_timeout, @default_idle_timeout),
          interrupt_timeout: Keyword.get(opts, :interrupt_timeout, @default_interrupt_timeout)
        }

        initialize =
          Wire.initialize(@initialize_id,
            sdk_mcp_servers: [MingaClaudeBridge.MCP.server_name()],
            system_prompt: Keyword.get(opts, :system_prompt)
          )

        session =
          start_timer(
            session,
            :startup_timeout,
            Keyword.get(opts, :startup_timeout, @default_startup_timeout)
          )

        case write(session, [initialize]) do
          :ok -> {:ok, session}
          {:error, reason} -> {:ok, kill(session, {:transport_error, reason})}
        end

      {:error, reason} ->
        {:stop, {:transport_start_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call({:request, %Request{} = request, subscriber}, _from, session) do
    case State.request(session.state, request) do
      {:ok, state, outcome} ->
        session =
          %{session | state: state} |> cancel_idle_timer() |> activate(request.ref, subscriber)

        {:reply, {:ok, request.ref}, perform_request(session, outcome)}

      {:error, {:invalid_tool_results, _detail} = reason} ->
        send(subscriber, {request.ref, {:finish, {:error, reason}}})
        {:reply, {:ok, request.ref}, session}

      {:error, reason} ->
        {:reply, {:error, reason}, session}
    end
  end

  def handle_call({:abort, ref}, _from, %__MODULE__{last_ref: ref} = session)
      when is_reference(ref) do
    case abort_request(session, :aborted) do
      {:ok, session} -> {:reply, :ok, session}
      {:error, reason} -> {:reply, {:error, reason}, session}
    end
  end

  def handle_call({:abort, _ref}, _from, session),
    do: {:reply, {:error, :unknown_request}, session}

  def handle_call(:phase, _from, session), do: {:reply, State.phase_tag(session.state), session}
  def handle_call(:info, _from, session), do: {:reply, State.info(session.state), session}
  def handle_call(:seen, _from, session), do: {:reply, session.seen, session}

  def handle_call({:remember, history}, _from, session),
    do: {:reply, :ok, %{session | seen: history}}

  def handle_call(:launch, _from, session), do: {:reply, session.launch, session}

  def handle_call(:await_ready, from, session) do
    case session.state.phase do
      {:starting, _queued} ->
        {:noreply, %{session | ready_waiters: [from | session.ready_waiters]}}

      {:dead, reason} ->
        {:reply, {:error, reason}, session}

      _ready ->
        {:reply, {:ok, State.info(session.state)}, session}
    end
  end

  @impl GenServer
  def handle_info({:transport, ref, event}, %__MODULE__{transport_ref: ref} = session),
    do: {:noreply, transport_event(session, event)}

  def handle_info({:transport, _stale_ref, _event}, session), do: {:noreply, session}

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %__MODULE__{active: %{monitor: monitor}} = session
      ) do
    Logger.debug("claude_bridge: subscriber down, aborting request")
    session = %{session | active: nil}

    case abort_request(session, :subscriber_down) do
      {:ok, session} -> {:noreply, session}
      {:error, _reason} -> {:noreply, session}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %__MODULE__{owner_monitor: monitor} = session
      ) do
    Logger.debug("claude_bridge: owner down, stopping session")
    {:stop, :normal, session}
  end

  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, session), do: {:noreply, session}

  def handle_info({:timeout, name}, %__MODULE__{timer: {name, _ref}} = session) do
    session = %{session | timer: nil}

    case name do
      :idle_timeout ->
        idle_expired(session)

      :interrupt_timeout ->
        {:noreply, apply_dead(session, State.interrupt_timeout(session.state))}

      :startup_timeout ->
        {:noreply, apply_dead(session, State.startup_timeout(session.state))}
    end
  end

  def handle_info({:timeout, _stale}, session), do: {:noreply, session}

  def handle_info({:EXIT, _pid, :normal}, session), do: {:noreply, session}

  def handle_info({:EXIT, _pid, reason}, session) do
    {:noreply,
     apply_dead(session, State.transport_down(session.state, {:transport_error, reason}))}
  end

  def handle_info(_other, session), do: {:noreply, session}

  @impl GenServer
  def terminate(_reason, session) do
    finish_active(session, {:error, :session_stopped})
    stop_transport(session, :shutdown)
    :ok
  end

  # Transport events

  defp transport_event(session, {:line, line}) do
    case Wire.decode(line) do
      {:ok, %Assistant{} = frame} ->
        frame(session, frame)

      {:ok, frame} ->
        session |> end_fallback_message() |> frame(frame)

      {:error, reason} ->
        apply_dead(session, State.transport_down(session.state, {:protocol_error, reason}))
    end
  end

  defp transport_event(session, {:exit, status}) do
    apply_dead(session, State.transport_down(session.state, {:claude_exited, status}))
  end

  defp transport_event(session, {:error, reason}),
    do: apply_dead(session, State.transport_down(session.state, {:transport_error, reason}))

  defp frame(session, %SystemInit{} = init) do
    log_frame("system/init")

    case State.system_init(session.state, init) do
      {:ok, state, :checked} -> %{session | state: state}
      {:ok, state, {:dead, reason}} -> die(%{session | state: state}, reason)
      {:error, reason} -> ignore(session, "system/init", reason)
    end
  end

  defp frame(session, %ControlResponse{} = response) do
    log_frame("control_response")
    startup(session, State.control_response(session.state, response))
  end

  defp frame(session, %StreamEvent{} = event), do: stream_event(session, event)

  defp frame(session, %ControlRequest{} = request) do
    log_frame("control_request")

    case State.control_request(session.state, request) do
      {:ok, state, {:reply, line}} -> write_or_die(%{session | state: state}, [line])
      {:ok, state, :held} -> %{session | state: state}
      {:ok, state, {:dead, reason}} -> die(%{session | state: state}, reason)
      {:error, reason} -> ignore(session, "control_request", reason)
    end
  end

  defp frame(session, %Result{} = result) do
    log_frame("result")

    case State.result(session.state, result) do
      {:ok, state, {:finish, usage, reason}} ->
        session = %{session | state: state}
        emit_usage(session, usage)
        session |> finish_active(reason) |> enter_idle()

      {:ok, state, :interrupted} ->
        %{session | state: state} |> cancel_timer() |> enter_idle()

      {:ok, state, :abandoned} ->
        %{session | state: state} |> enter_idle()

      {:error, reason} ->
        ignore(session, "result", reason)
    end
  end

  defp frame(session, %Assistant{} = assistant) do
    log_frame("assistant")

    case State.assistant(session.state, assistant) do
      {:ok, state, {:emit, events}} -> emit_all(%{session | state: state}, events)
      {:ok, state, :ignored} -> %{session | state: state}
      {:ok, state, {:dead, reason}} -> die(%{session | state: state}, reason)
      {:error, reason} -> ignore(session, "assistant", reason)
    end
  end

  defp frame(session, %RateLimit{} = rate_limit) do
    log_frame("rate_limit_event")
    forward_rate_limit(session.on_rate_limit, rate_limit)
    session
  end

  defp frame(session, %{__struct__: module}) do
    log_frame(module |> Module.split() |> List.last())
    session
  end

  defp stream_event(session, %StreamEvent{} = event) do
    case State.stream_event(session.state, event) do
      {:ok, state, {:emit, events}} ->
        emit_all(%{session | state: state}, events)

      {:ok, state, {:suspend, calls, usage}} ->
        suspend(%{session | state: state}, calls, usage)

      {:ok, state, :ignored} ->
        %{session | state: state}

      {:ok, state, {:dead, reason}} ->
        die(%{session | state: state}, reason)

      {:error, reason} ->
        ignore(session, "stream_event", reason)
    end
  end

  defp end_fallback_message(session) do
    case State.end_fallback_message(session.state) do
      {:ok, state, {:suspend, calls, usage}} -> suspend(%{session | state: state}, calls, usage)
      {:ok, _state, :unchanged} -> session
      {:error, {:invalid_phase, _tag}} -> session
    end
  end

  defp suspend(session, calls, usage) do
    Logger.debug("claude_bridge: suspending for tool calls")
    Enum.each(calls, &emit(session, {:tool_call, &1}))
    emit_usage(session, usage)
    finish_active(session, :tool_calls)
  end

  defp emit_all(session, events) do
    Enum.each(events, &emit(session, &1))
    session
  end

  # Startup

  defp startup(session, {:ok, state, outcome}) do
    session = %{session | state: state}

    case outcome do
      :ignored -> session
      :ready -> session |> cancel_timer() |> reply_ready() |> enter_idle()
      {:ready, prompt} -> session |> cancel_timer() |> reply_ready() |> perform_request(prompt)
      {:dead, reason} -> die(session, reason)
    end
  end

  defp startup(session, {:error, reason}), do: ignore(session, "startup frame", reason)

  # Requests

  defp perform_request(session, :queued), do: session

  defp perform_request(session, {:prompt, %Request{kind: {:prompt, content}}}),
    do: write_or_die(session, [Wire.user_message(content)])

  defp perform_request(session, {:tool_results, lines}), do: write_or_die(session, lines)

  defp activate(session, ref, subscriber) do
    %{
      session
      | active: %{ref: ref, subscriber: subscriber, monitor: Process.monitor(subscriber)},
        last_ref: ref
    }
  end

  defp abort_request(session, reason) do
    case State.abort(session.state, reason) do
      {:ok, state, {:interrupt, cancel_lines}} ->
        Logger.debug("claude_bridge: interrupting turn")
        {id, session} = next_request_id(%{session | state: state})
        session = finish_active(session, {:error, :aborted})

        case write(session, [Wire.interrupt(id) | cancel_lines]) do
          :ok -> {:ok, start_timer(session, :interrupt_timeout, session.interrupt_timeout)}
          {:error, write_error} -> {:ok, kill(session, {:transport_error, write_error})}
        end

      {:ok, state, :dequeued} ->
        {:ok, finish_active(%{session | state: state}, {:error, :aborted})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Events

  defp emit(%__MODULE__{active: %{ref: ref, subscriber: pid}}, event), do: send(pid, {ref, event})
  defp emit(%__MODULE__{active: nil}, _event), do: :ok

  defp emit_usage(_session, nil), do: :ok
  defp emit_usage(session, usage), do: emit(session, {:usage, usage})

  @spec finish_active(t(), Event.finish_reason()) :: t()
  defp finish_active(
         %__MODULE__{active: %{ref: ref, subscriber: pid, monitor: monitor}} = session,
         reason
       ) do
    Process.demonitor(monitor, [:flush])
    send(pid, {ref, {:finish, reason}})
    %{session | active: nil}
  end

  defp finish_active(%__MODULE__{active: nil} = session, _reason), do: session

  defp forward_rate_limit(nil, _rate_limit), do: :ok

  defp forward_rate_limit(pid, rate_limit) when is_pid(pid),
    do: send(pid, {:claude_bridge_rate_limit, self(), rate_limit})

  defp forward_rate_limit(fun, rate_limit) when is_function(fun, 1) do
    Task.start(fn -> fun.(rate_limit) end)
    :ok
  end

  # Idle

  defp enter_idle(session), do: start_timer(session, :idle_timeout, session.idle_timeout)

  defp idle_expired(session) do
    case State.idle_timeout(session.state) do
      {:ok, state, {:dead, :idle_timeout}} ->
        Logger.debug("claude_bridge: idle timeout")
        session = %{session | state: state}
        stop_transport(session, :normal)
        {:stop, :normal, %{session | handle: nil}}

      {:error, _reason} ->
        {:noreply, session}
    end
  end

  # Death

  defp apply_dead(session, {:ok, state, {:dead, reason}}),
    do: die(%{session | state: state}, reason)

  defp apply_dead(session, {:error, reason}), do: ignore(session, "failure", reason)

  defp kill(session, reason), do: apply_dead(session, State.transport_down(session.state, reason))

  defp reply_ready(session) do
    Enum.each(session.ready_waiters, &GenServer.reply(&1, {:ok, State.info(session.state)}))
    %{session | ready_waiters: []}
  end

  defp monitor_owner(nil), do: nil
  defp monitor_owner(pid) when is_pid(pid), do: Process.monitor(pid)

  defp die(session, reason) do
    Enum.each(session.ready_waiters, &GenServer.reply(&1, {:error, reason}))
    session = %{session | ready_waiters: []}
    Logger.warning("claude_bridge: session dead (#{dead_tag(reason)})")
    session = session |> cancel_timer() |> finish_active({:error, reason})
    stop_transport(session, :shutdown)
    %{session | handle: nil}
  end

  defp dead_tag(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp dead_tag(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: Atom.to_string(elem(reason, 0))

  defp dead_tag(_reason), do: "other"

  # Transport

  defp write(%__MODULE__{handle: nil}, _lines), do: {:error, :closed}

  defp write(%__MODULE__{transport: transport, handle: handle}, lines) do
    Enum.reduce_while(lines, :ok, fn line, :ok ->
      case transport.send_line(handle, line) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp write_or_die(session, lines) do
    case write(session, lines) do
      :ok -> session
      {:error, reason} -> kill(session, {:transport_error, reason})
    end
  end

  defp stop_transport(%__MODULE__{handle: nil}, _reason), do: :ok

  defp stop_transport(%__MODULE__{transport: transport, handle: handle}, reason),
    do: transport.stop(handle, reason)

  defp next_request_id(%__MODULE__{next_id: n} = session),
    do: {"minga_#{n}", %{session | next_id: n + 1}}

  # Timers. One timer runs at a time; each phase that needs one replaces the previous.

  defp start_timer(session, _name, :infinity), do: cancel_timer(session)

  defp start_timer(session, name, ms) do
    session = cancel_timer(session)
    %{session | timer: {name, Process.send_after(self(), {:timeout, name}, ms)}}
  end

  defp cancel_timer(%__MODULE__{timer: nil} = session), do: session

  defp cancel_timer(%__MODULE__{timer: {name, ref}} = session) do
    # A timer that already fired left its message in the mailbox; drop that stale message.
    if Process.cancel_timer(ref) == false do
      receive do
        {:timeout, ^name} -> :ok
      after
        0 -> :ok
      end
    end

    %{session | timer: nil}
  end

  defp cancel_idle_timer(%__MODULE__{timer: {:idle_timeout, _ref}} = session),
    do: cancel_timer(session)

  defp cancel_idle_timer(session), do: session

  defp ignore(session, what, {:invalid_phase, tag}) do
    Logger.debug("claude_bridge: ignored #{what} in phase #{tag}")
    session
  end

  defp log_frame(type), do: Logger.debug("claude_bridge: frame #{type}")
end
