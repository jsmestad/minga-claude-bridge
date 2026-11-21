defmodule MingaClaudeBridge.Transport.Port do
  @moduledoc """
  The `MingaClaudeBridge.Transport` that runs the real `claude` executable through an Erlang Port.

  Each transport is a process linked to its owner (the session). It resolves the executable to an absolute path (`MingaClaudeBridge.Binary`), builds the arguments (`MingaClaudeBridge.Launch`) and the environment (`MingaClaudeBridge.Env`), creates an empty private working directory (`MingaClaudeBridge.Workdir`), and opens the Port with `:spawn_executable`, so no shell runs.

  ## Lines

  The Port delivers stdout in `{:line, 65_536}` fragments. `MingaClaudeBridge.LineBuffer` joins them into whole lines up to `:max_line_bytes` (32 MiB by default). A longer line sends `{:error, :line_too_long}` to the owner and stops the child.

  ## Stopping the child

  The child never outlives its transport. When the transport stops for any reason (`stop/2`, owner exit, a line that is too long, or a crash in this process), `terminate/2` closes the Port, which closes the child's stdin, then sends SIGTERM to the OS pid, waits up to `:kill_grace_ms` (500 ms by default), and sends SIGKILL if the process is still there. The working directory is then removed.

  ## Options

  Besides the `:owner`, `:ref`, and `:launch` options every transport gets:

    * `:executable` - an absolute path to run instead of resolving `claude`.
    * `:binary` - extra options for `MingaClaudeBridge.Binary.resolve/1`, for tests.
    * `:parent_env` - the environment to start from. Defaults to `System.get_env/0`.
    * `:credential_env` - the route credential's `env` map. Defaults to `%{}`.
    * `:os_user` - the login name used for a missing `USER` or `LOGNAME` (see `MingaClaudeBridge.Env`). Defaults to `MingaClaudeBridge.OsUser.name/0`.
    * `:session_key` - names the working directory; use a stable key per conversation so `--resume` finds its session. Defaults to a random key.
    * `:workdir_base` - the private base directory. Defaults to `MingaClaudeBridge.Workdir.base_path/0`.
    * `:max_line_bytes`, `:kill_grace_ms` - see above.
    * `:debug` - write raw line logs (`MingaClaudeBridge.DebugLog`). Defaults to `CLAUDE_BRIDGE_DEBUG=1` in the parent environment.
  """

  use GenServer

  @behaviour MingaClaudeBridge.Transport

  alias MingaClaudeBridge.{Binary, DebugLog, Env, Launch, LineBuffer, OsProcess, OsUser, Workdir}

  @port_line_bytes 65_536
  @default_kill_grace_ms 500
  @stop_timeout 10_000

  @type t :: %__MODULE__{
          owner: pid(),
          ref: reference(),
          port: port() | nil,
          os_pid: pos_integer() | nil,
          buffer: LineBuffer.t(),
          workdir: Path.t() | nil,
          kill_grace_ms: non_neg_integer(),
          debug: DebugLog.t()
        }

  @enforce_keys [:owner, :ref, :port, :os_pid, :buffer, :workdir, :kill_grace_ms, :debug]
  defstruct [:owner, :ref, :port, :os_pid, :buffer, :workdir, :kill_grace_ms, :debug]

  @impl MingaClaudeBridge.Transport
  def start(opts) do
    case GenServer.start_link(__MODULE__, opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl MingaClaudeBridge.Transport
  def send_line(pid, line) do
    GenServer.call(pid, {:send_line, line})
  catch
    :exit, _reason -> {:error, :closed}
  end

  @impl MingaClaudeBridge.Transport
  def stop(pid, _reason) do
    GenServer.stop(pid, :normal, @stop_timeout)
  catch
    :exit, _reason -> :ok
  end

  @doc "Returns the OS pid of the child, or `nil` after it exited. For diagnostics and tests."
  @spec os_pid(pid()) :: pos_integer() | nil
  def os_pid(pid), do: GenServer.call(pid, :os_pid)

  @doc "Returns the child's working directory. For diagnostics and tests."
  @spec workdir(pid()) :: Path.t() | nil
  def workdir(pid), do: GenServer.call(pid, :workdir)

  # Callbacks

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    Process.monitor(owner)
    parent_env = Keyword.get_lazy(opts, :parent_env, &System.get_env/0)
    base = Keyword.get_lazy(opts, :workdir_base, &Workdir.base_path/0)
    key = Keyword.get_lazy(opts, :session_key, &Workdir.random_key/0)

    with {:ok, path} <- executable(opts, parent_env),
         {:ok, argv} <- Launch.argv(Keyword.get(opts, :launch, [])),
         {:ok, env} <-
           Env.child_env(parent_env, Keyword.get(opts, :credential_env, %{}),
             os_user: Keyword.get_lazy(opts, :os_user, &OsUser.name/0)
           ),
         {:ok, workdir} <- Workdir.create(base, key),
         {:ok, port, os_pid} <- open(path, argv, env, workdir) do
      debug =
        if Keyword.get(opts, :debug, DebugLog.enabled?(parent_env)), do: DebugLog.open(base, key)

      {:ok,
       %__MODULE__{
         owner: owner,
         ref: Keyword.fetch!(opts, :ref),
         port: port,
         os_pid: os_pid,
         buffer: LineBuffer.new(max_bytes: Keyword.get(opts, :max_line_bytes, 32 * 1024 * 1024)),
         workdir: workdir,
         kill_grace_ms: Keyword.get(opts, :kill_grace_ms, @default_kill_grace_ms),
         debug: debug
       }}
    else
      {:error, {:spawn_failed, _reason} = reason} ->
        Workdir.remove(Path.join([base, "sessions", key]))
        {:stop, reason}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:send_line, _line}, _from, %__MODULE__{port: nil} = state),
    do: {:reply, {:error, :closed}, state}

  def handle_call({:send_line, line}, _from, %__MODULE__{port: port} = state) do
    DebugLog.write(state.debug, :out, line)
    Port.command(port, line)
    {:reply, :ok, state}
  rescue
    ArgumentError -> {:reply, {:error, :closed}, state}
  end

  def handle_call(:os_pid, _from, state), do: {:reply, state.os_pid, state}
  def handle_call(:workdir, _from, state), do: {:reply, state.workdir, state}

  @impl GenServer
  def handle_info({port, {:data, fragment}}, %__MODULE__{port: port} = state) do
    case LineBuffer.push(state.buffer, fragment) do
      {:line, line, buffer} ->
        DebugLog.write(state.debug, :in, line)
        notify(state, {:line, line})
        {:noreply, %{state | buffer: buffer}}

      {:more, buffer} ->
        {:noreply, %{state | buffer: buffer}}

      {:error, :line_too_long, buffer} ->
        notify(state, {:error, :line_too_long})
        {:stop, :normal, %{state | buffer: buffer}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %__MODULE__{port: port} = state) do
    notify(state, {:exit, status})
    {:stop, :normal, %{state | port: nil, os_pid: nil}}
  end

  def handle_info({:EXIT, port, reason}, %__MODULE__{port: port} = state) do
    notify(state, {:error, {:port_closed, reason}})
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({:DOWN, _monitor, :process, owner, _reason}, %__MODULE__{owner: owner} = state),
    do: {:stop, :normal, state}

  def handle_info({:EXIT, owner, _reason}, %__MODULE__{owner: owner} = state),
    do: {:stop, :normal, state}

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    stop_child(state)
    Workdir.remove(state.workdir)
    DebugLog.close(state.debug)
    :ok
  end

  # Internals

  defp executable(opts, parent_env) do
    case Keyword.get(opts, :executable) do
      nil ->
        Binary.resolve([env: parent_env] ++ Keyword.get(opts, :binary, []))

      path ->
        if Path.type(path) == :absolute,
          do: {:ok, path},
          else: {:error, {:invalid_cli_override, :not_absolute}}
    end
  end

  defp open(path, argv, env, workdir) do
    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :exit_status,
        {:line, @port_line_bytes},
        :use_stdio,
        :hide,
        args: argv,
        cd: workdir,
        env: env
      ])

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> {:ok, port, os_pid}
      nil -> {:error, {:spawn_failed, :no_os_pid}}
    end
  rescue
    error in ErlangError -> {:error, {:spawn_failed, error.original}}
  end

  defp notify(%__MODULE__{owner: owner, ref: ref}, event),
    do: send(owner, {:transport, ref, event})

  defp stop_child(%__MODULE__{port: port, os_pid: os_pid, kill_grace_ms: grace}) do
    close_port(port)
    if is_integer(os_pid), do: OsProcess.terminate(os_pid, grace)
    :ok
  end

  defp close_port(nil), do: :ok

  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
