defmodule MingaClaudeBridge.Route do
  @moduledoc """
  The `MingaAgent.InferenceRoute` that serves Claude models through the user's Claude Code login.

  Minga runs the agent: tools, approvals, retries, and history. This route only turns each Minga request into input for a long-lived Claude Code process (`MingaClaudeBridge.Session`) and turns the session's events back into Minga route events.

  ## Conversations

  Each Minga conversation (`ConversationRef.session_id`) has at most one live session, started under `MingaClaudeBridge.SessionSupervisor` and found through `MingaClaudeBridge.Registry`. Its working directory key is derived from the conversation id, so it is stable across restarts. The session stops when the Minga agent session that owns the conversation (`ConversationRef.owner`) exits.

  For a `:turn` request the route compares the request with what the session has seen (`MingaClaudeBridge.History`, built by `MingaClaudeBridge.Route.Mapping`):

    * The request adds only tool results, and the session waits for them: the results answer the held tool calls.
    * The request adds only user messages, and the session is idle: they are sent as the next prompt.
    * Anything else (a new conversation, an edit, branch, reset, compaction, a changed system prompt, tool set, model, or effort, a dead session, or a mix of tool results and user input): the old session stops and a fresh one starts. Earlier history is imported as one transcript text block in front of the newest input. This import is lossy; see `MingaClaudeBridge.Route.Mapping`. Importing a Claude Code session file for `--resume` is a follow-up.

  After a turn finishes without an error, the session records the request's history plus the reply in the same normalized form Minga sends next time. A turn that ends with Claude Code's `result` also refreshes plan usage with `get_usage` on the now idle session.

  `:summary` and `:title` requests, and turns without a conversation id, run in an isolated session with no tools and no session persistence. It stops when the stream ends, is cancelled, or its consumer exits.

  ## Streams

  `stream/1` sends the request to the session with the calling process as the subscriber and returns a lazy stream that drains the session's `{ref, event}` messages in that process. The session monitors the subscriber, so a consumer that exits aborts the turn. `cancel`, which Minga calls when the user stops a turn or the consumer exits early, stops the conversation's Claude Code process; the next request starts a fresh one.
  """

  @behaviour MingaAgent.InferenceRoute

  alias MingaAgent.InferenceRoute.{Credential, Request, Response}
  alias MingaClaudeBridge.{History, Launch, Session, Status}
  alias MingaClaudeBridge.Route.{Config, Mapping, Probe}
  alias MingaClaudeBridge.Session.Request, as: SessionRequest
  alias MingaClaudeBridge.Wire.RateLimit

  @install_remedy "Claude Code is not installed. Install it from https://claude.com/claude-code, then run `claude auth login`."
  @sign_in_remedy "Claude Code is not signed in. Run `claude auth login` in a terminal, then try again."

  # Callbacks

  @impl true
  def models(config) do
    config = Config.load(config)

    # Never start Claude Code here: Minga lists models during registration.
    # Availability probes record the real list.
    case Status.models(config.status) do
      [_ | _] = entries ->
        entries |> to_models(Status.context_windows(config.status)) |> with_fallback()

      _none ->
        Mapping.fallback_models()
    end
  end

  @impl true
  def availability(route_id, credential), do: availability(route_id, credential, Config.load())

  @impl true
  def stream(%Request{} = request), do: stream(request, Config.load())

  @impl true
  def classify_error({:session_dead, reason}), do: classify_error(reason)
  def classify_error({:transport_start_failed, reason}), do: classify_error(reason)

  def classify_error(:claude_not_found), do: {:unreachable, @install_remedy}

  def classify_error({:invalid_cli_override, _why}),
    do:
      {:unreachable,
       "CLAUDE_BRIDGE_CLI must be the absolute path of an executable `claude`. Fix or unset it."}

  def classify_error(:not_signed_in), do: {:auth_failed, @sign_in_remedy}

  def classify_error({:rate_limited, resets_at}),
    do: {:rate_limited, Status.limit_remedy(resets_at)}

  def classify_error({:claude_error, _subtype, text}) when is_binary(text) do
    if rate_limit_text?(text),
      do: {:rate_limited, Status.limit_remedy(nil)},
      else: {:provider_error, "Claude Code reported an error: #{text}"}
  end

  def classify_error({:claude_exited, status}),
    do:
      {:provider_error,
       "Claude Code stopped unexpectedly (#{inspect(status)}). Send the message again to retry with a new Claude Code process."}

  def classify_error({:unsupported_version, version}),
    do:
      {:provider_error,
       "Claude Code #{version || "(unknown version)"} is older than #{Launch.min_version()}, the oldest version the bridge supports. Run `claude update`."}

  def classify_error({:unexpected_tools, names}),
    do:
      {:provider_error,
       "Stopped for safety: Claude Code offered tools other than Minga's (#{Enum.join(names, ", ")}), so the bridge stopped it before the model could use them. Check for company-managed Claude Code settings."}

  def classify_error(:missing_system_init),
    do:
      {:provider_error,
       "Stopped for safety: Claude Code produced output before reporting its tools. Update Claude Code with `claude update` and try again."}

  def classify_error({:forbidden_env, keys}),
    do:
      {:auth_failed,
       "routes.claude_bridge.env in credentials.json cannot set #{Enum.join(keys, ", ")}. Remove them."}

  def classify_error({:invalid_env, keys}),
    do:
      {:auth_failed,
       "routes.claude_bridge.env in credentials.json has invalid variables: #{Enum.join(keys, ", ")}."}

  def classify_error(reason) when reason in [:startup_timeout, :timeout],
    do:
      {:unreachable,
       "Claude Code did not start in time. Run `claude` in a terminal to check that it works."}

  def classify_error({:initialize_failed, message}),
    do: {:provider_error, "Claude Code refused to start a bridge session: #{message}"}

  def classify_error({:protocol_error, _reason}),
    do:
      {:provider_error,
       "Claude Code sent output the bridge cannot read. Update Claude Code and the bridge, then try again."}

  def classify_error({:transport_error, _reason}),
    do:
      {:provider_error, "The connection to Claude Code failed. Send the message again to retry."}

  def classify_error(:interrupt_timeout),
    do:
      {:provider_error,
       "Claude Code did not stop when asked, so the bridge stopped it. Send the message again to retry."}

  def classify_error(:aborted), do: {:provider_error, "The Claude Code turn was stopped."}

  def classify_error({:invalid_tool_results, _detail}),
    do:
      {:internal_error,
       "The bridge could not match tool results to Claude Code's tool calls. Start a new message."}

  def classify_error({:invalid_phase, _tag}),
    do: {:internal_error, "Claude Code is still busy with the previous request. Try again."}

  def classify_error(_reason),
    do:
      {:unknown,
       "The Claude bridge failed. Open *Messages* for details, or set CLAUDE_BRIDGE_DEBUG=1 and try again."}

  # Entry points with an explicit config

  @doc "`availability/2` with an explicit config."
  @spec availability(String.t(), Credential.t() | nil, Config.t()) ::
          MingaAgent.InferenceRoute.availability()
  def availability(_route_id, credential, %Config{} = config) do
    env = credential_env(credential)
    key = :erlang.phash2(env)

    case limited(config) do
      {:unavailable, _kind, _remedy} = limited -> limited
      :not_limited -> cached_availability(config, env, key)
    end
  end

  # A plan limit Claude Code reported stays in force until its reset time, because a probe cannot see it.
  defp limited(config) do
    now = System.os_time(:second)

    case Status.latest_rate_limit(config.status) do
      %RateLimit{status: :rejected, resets_at: resets_at}
      when is_number(resets_at) and resets_at > now ->
        {:unavailable, :rate_limited, Status.limit_remedy(resets_at)}

      _not_limited ->
        :not_limited
    end
  end

  defp cached_availability(config, env, key) do
    case Status.cached(config.status, key, config.availability_ttl) do
      {:ok, availability} ->
        availability

      :miss ->
        availability = probe_availability(config, env)
        Status.put(config.status, key, availability)
        if match?({:ready, _label}, availability), do: start_measurement(config, env, key)
        availability
    end
  end

  # Plan usage and context windows are measured beside the availability check, never on it:
  # a background task with its own probe session, at most one per credential, under the bridge's
  # task supervisor. Windows already measured within the window TTL are not measured again.
  defp start_measurement(config, env, key) do
    Status.start_measurement(config.status, key, fn -> measure(config, env, key) end)
  end

  defp measure(config, env, key) do
    deadline = System.monotonic_time(:millisecond) + config.measure_deadline

    case Probe.start_ready(config, env, "measure-") do
      {:ok, session, info} ->
        model_ids = for %{"value" => id} <- info.models, is_binary(id), do: id
        # Usage first and reported at once: it changes between checks, the windows rarely do.
        usage = Probe.usage(session, deadline)
        if usage, do: Status.put_usage(config.status, usage)

        stale = Status.stale_models(config.status, key, model_ids, config.window_ttl)
        windows = Probe.context_windows(session, stale, deadline)
        Probe.stop(session)
        Status.put_context_windows(config.status, key, windows)

      {:error, _reason} ->
        :ok
    end
  end

  @doc "`stream/1` with an explicit config."
  @spec stream(Request.t(), Config.t()) :: {:ok, Response.t()}
  def stream(%Request{conversation: conversation} = request, %Config{} = config) do
    case conversation do
      %{purpose: :turn, session_id: id} when is_binary(id) and id != "" ->
        turn(request, id, config)

      _isolated ->
        isolated(request, config)
    end
  end

  # Availability

  defp probe_availability(config, env) do
    case Probe.run(config, env) do
      {:ok, %{account: account} = info} ->
        Status.put_models(config.status, info.models)

        if Probe.signed_in?(account),
          do: {:ready, Probe.plan_label(account, Status.usage_label(config.status))},
          else: {:unavailable, :not_signed_in, @sign_in_remedy}

      {:error, reason} ->
        unavailable(reason)
    end
  end

  defp unavailable(:claude_not_found), do: {:unavailable, :claude_not_found, @install_remedy}

  defp unavailable({:invalid_cli_override, _} = reason),
    do: {:unavailable, :claude_not_found, elem(classify_error(reason), 1)}

  defp unavailable({:unsupported_version, _} = reason),
    do: {:unavailable, :unsupported_version, elem(classify_error(reason), 1)}

  defp unavailable({kind, _keys} = reason) when kind in [:forbidden_env, :invalid_env],
    do: {:unavailable, :invalid_route_credential, elem(classify_error(reason), 1)}

  defp unavailable(reason) when reason in [:timeout, :startup_timeout],
    do: {:unavailable, :unreachable, elem(classify_error(reason), 1)}

  defp unavailable(reason),
    do:
      {:unavailable, :claude_failed,
       "Claude Code failed to start (#{failure_tag(reason)}). Run `claude` in a terminal to see why."}

  defp failure_tag({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp failure_tag(tag) when is_atom(tag), do: Atom.to_string(tag)
  defp failure_tag(_other), do: "error"

  # Turns

  defp turn(request, conversation_id, config) do
    effort = Mapping.effort(request)
    tools = Mapping.tools(request.tools)

    history_request = %{
      purpose: :turn,
      entries: Mapping.entries(request.messages),
      fingerprint: Mapping.fingerprint(request, effort)
    }

    # Claude Code keeps every prompt it received, even in a failed or stopped turn.
    # So anything but a success makes the next request start fresh.
    record = fn
      session, {:completed, text, calls} ->
        entries = history_request.entries ++ [Mapping.assistant_entry(text, calls)]

        history =
          History.record(History.new(), %{
            entries: entries,
            fingerprint: history_request.fingerprint
          })

        remember(session, history)

      session, :failed ->
        remember(session, History.new())
    end

    case plan(config, conversation_id, request, history_request, tools) do
      {:continue, session, session_request} ->
        send_request(config, session, session_request, record, fn -> :ok end)

      :fresh ->
        start_fresh(config, conversation_id, request, effort, tools, record)
    end
  end

  defp plan(config, conversation_id, request, history_request, tools) do
    with session when is_pid(session) <- lookup(config, conversation_id),
         {:continue, new} <- History.compare(Session.seen(session), history_request),
         {:ok, session_request} <-
           continue_request(
             Mapping.continuation(Enum.take(request.messages, -length(new))),
             Session.phase(session),
             tools
           ) do
      {:continue, session, session_request}
    else
      _fresh -> :fresh
    end
  catch
    :exit, _session_gone -> :fresh
  end

  defp continue_request({:tool_results, results}, :awaiting_tool_results, tools),
    do: {:ok, SessionRequest.tool_results(results, tools)}

  defp continue_request({:prompt, blocks}, :idle, tools),
    do: {:ok, SessionRequest.prompt(blocks, tools)}

  defp continue_request(_continuation, _phase, _tools), do: :fresh

  defp start_fresh(config, conversation_id, request, effort, tools, record) do
    stop_conversation(config, conversation_id)

    opts =
      session_opts(config, request, effort, tools,
        session_key: Mapping.workdir_key(conversation_id)
      ) ++
        [
          name: {:via, Registry, {config.registry, {:conversation, conversation_id, make_ref()}}},
          owner: conversation_owner(request)
        ]

    case DynamicSupervisor.start_child(config.supervisor, {Session, opts}) do
      {:ok, session} ->
        prompt = SessionRequest.prompt(Mapping.fresh_prompt(request.messages), tools)
        send_request(config, session, prompt, record, fn -> :ok end)

      {:error, reason} ->
        {:ok, failed(reason)}
    end
  end

  defp isolated(request, config) do
    effort = Mapping.effort(request)

    opts =
      session_opts(config, request, effort, [],
        session_key: "isolated-" <> MingaClaudeBridge.Workdir.random_key()
      ) ++
        [owner: self()]

    case Session.start(opts) do
      {:ok, session} ->
        prompt = SessionRequest.prompt(Mapping.fresh_prompt(request.messages), [])
        send_request(config, session, prompt, nil, fn -> stop_session(session) end)

      {:error, reason} ->
        {:ok, failed(reason)}
    end
  end

  defp session_opts(config, request, effort, tools, transport_extra) do
    {transport, transport_opts} = config.transport

    transport_opts =
      transport_opts
      |> Keyword.merge(transport_extra)
      |> Keyword.put(:credential_env, credential_env(request.credential))

    [
      transport: {transport, transport_opts},
      system_prompt: request.system,
      model: Mapping.cli_model(request),
      effort: effort,
      tools: tools,
      min_version: Launch.min_version(),
      persist_session: false,
      on_rate_limit: GenServer.whereis(config.status)
    ] ++ config.session_opts
  end

  defp send_request(config, session, session_request, record, cleanup) do
    case Session.request(session, session_request, self()) do
      {:ok, ref} ->
        {:ok, response(config, session, ref, record, cleanup)}

      {:error, reason} ->
        if record, do: record.(session, :failed)
        cleanup.()
        {:ok, failed(reason)}
    end
  catch
    :exit, _session_gone ->
      cleanup.()
      {:ok, failed({:claude_exited, :session_down})}
  end

  defp response(config, session, ref, record, cleanup) do
    events =
      Stream.resource(
        fn -> %{monitor: Process.monitor(session), text: [], calls: [], done: false} end,
        &next_event(&1, config, session, ref, record),
        fn acc ->
          Process.demonitor(acc.monitor, [:flush])
          cleanup.()
        end
      )

    # A stopped turn leaves no Claude Code process behind. The next request
    # starts fresh anyway, because Claude Code's transcript holds the stopped prompt.
    cancel = fn ->
      if record, do: record.(session, :failed)
      stop_session(session)
      cleanup.()
      :ok
    end

    %Response{events: events, cancel: cancel}
  end

  defp next_event(%{done: true} = acc, _config, _session, _ref, _record), do: {:halt, acc}

  defp next_event(acc, config, session, ref, record) do
    monitor = acc.monitor

    receive do
      {^ref, {:finish, reason}} ->
        reason = finish_reason(reason, config)

        if record, do: record.(session, outcome(reason, acc))
        if record && reason in [:stop, :length, :refusal], do: refresh_usage(config, session)

        {[{:finish, reason}], %{acc | done: true}}

      {^ref, {:text, text} = event} ->
        {[event], %{acc | text: [acc.text, text]}}

      {^ref, {:tool_call, call} = event} ->
        {[Mapping.event(event)], %{acc | calls: [call | acc.calls]}}

      {^ref, event} ->
        {[Mapping.event(event)], acc}

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        {[{:finish, {:error, {:claude_exited, :session_down}}}], %{acc | done: true}}
    end
  end

  defp outcome({:error, _reason}, _acc), do: :failed

  defp outcome(_reason, acc),
    do: {:completed, IO.iodata_to_binary(acc.text), Enum.reverse(acc.calls)}

  defp finish_reason({:error, {:claude_error, _subtype, text}} = error, config)
       when is_binary(text) do
    case Status.latest_rate_limit(config.status) do
      %RateLimit{status: :rejected, resets_at: resets_at} -> {:error, {:rate_limited, resets_at}}
      _other -> if rate_limit_text?(text), do: {:error, {:rate_limited, nil}}, else: error
    end
  end

  defp finish_reason(reason, _config), do: reason

  defp rate_limit_text?(text),
    do: text =~ ~r/(usage|rate|plan|weekly|session) limit|hit your limit/i

  defp failed(reason), do: %Response{events: [{:finish, {:error, reason}}], cancel: fn -> :ok end}

  # Sessions

  defp lookup(config, conversation_id) do
    config.registry
    |> Registry.select([{{{:conversation, conversation_id, :_}, :"$1", :_}, [], [:"$1"]}])
    |> Enum.find(&Process.alive?/1)
  end

  defp stop_conversation(config, conversation_id) do
    config.registry
    |> Registry.select([{{{:conversation, conversation_id, :_}, :"$1", :_}, [], [:"$1"]}])
    |> Enum.each(&DynamicSupervisor.terminate_child(config.supervisor, &1))
  end

  defp remember(session, history) do
    Session.remember(session, history)
  catch
    :exit, _session_gone -> :ok
  end

  defp stop_session(session) do
    GenServer.stop(session, :normal, 5_000)
  catch
    :exit, _already_stopped -> :ok
  end

  # The Minga agent session that owns the conversation. The Claude Code process stops when it exits.
  defp conversation_owner(%Request{conversation: %{owner: owner}}) when is_pid(owner), do: owner
  defp conversation_owner(_request), do: nil

  defp credential_env(%Credential{env: env}) when is_map(env), do: env
  defp credential_env(%{env: env}) when is_map(env), do: env
  defp credential_env(_none), do: %{}

  # A turn that reached Claude Code's `result` leaves the session idle, so it can answer `get_usage`.
  # The refresh runs beside the stream: a failure or a busy session only skips this update.
  defp refresh_usage(config, session) do
    Task.start(fn ->
      case Session.control(session, %{"subtype" => "get_usage", "skip_behaviors" => true}, 5_000) do
        {:ok, usage} -> Status.put_usage(config.status, usage)
        {:error, _reason} -> :ok
      end
    end)
  end

  defp to_models(entries, windows) do
    entries
    |> Enum.flat_map(fn entry ->
      case Mapping.model(entry, windows) do
        {:ok, model} -> [model]
        :error -> []
      end
    end)
    |> Enum.uniq_by(& &1.id)
  end

  defp with_fallback([]), do: Mapping.fallback_models()
  defp with_fallback(models), do: models
end
