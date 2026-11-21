defmodule MingaClaudeBridge.Transport.Scripted do
  @moduledoc """
  A `MingaClaudeBridge.Transport` for tests. The test process plays Claude Code.

  Start the session with `transport: {Scripted, controller: self()}`. The transport sends the controller:

    * `{:scripted_started, ref, owner, opts}` when the session starts it.
    * `{:scripted_line, ref, line}` for every line the session writes.
    * `{:scripted_stopped, ref, reason}` when the session stops it.

  The test drives the session with `push/3`, `exit/3`, and `fail/3`, which send the messages a real transport would. Set `fail_start: reason` to make `start/1` fail, and `fail_send: reason` to make every write fail.
  """

  @behaviour MingaClaudeBridge.Transport

  @enforce_keys [:controller, :owner, :ref, :fail_send]
  defstruct [:controller, :owner, :ref, :fail_send]

  @type t :: %__MODULE__{controller: pid(), owner: pid(), ref: reference(), fail_send: term()}

  @impl true
  def start(opts) do
    controller = Keyword.fetch!(opts, :controller)
    owner = Keyword.fetch!(opts, :owner)
    ref = Keyword.fetch!(opts, :ref)

    case Keyword.get(opts, :fail_start) do
      nil ->
        send(controller, {:scripted_started, ref, owner, opts})

        {:ok,
         %__MODULE__{
           controller: controller,
           owner: owner,
           ref: ref,
           fail_send: Keyword.get(opts, :fail_send)
         }}

      reason ->
        {:error, reason}
    end
  end

  @impl true
  def send_line(%__MODULE__{fail_send: nil} = handle, line) do
    send(handle.controller, {:scripted_line, handle.ref, IO.iodata_to_binary(line)})
    :ok
  end

  def send_line(%__MODULE__{fail_send: reason}, _line), do: {:error, reason}

  @impl true
  def stop(%__MODULE__{} = handle, reason) do
    send(handle.controller, {:scripted_stopped, handle.ref, reason})
    :ok
  end

  @doc "Delivers one stdout line to the session. `frame` is a map encoded as JSON, or a raw binary."
  @spec push(pid(), reference(), map() | binary()) :: :ok
  def push(owner, ref, frame) when is_map(frame), do: push(owner, ref, JSON.encode!(frame))

  def push(owner, ref, line) when is_binary(line) do
    send(owner, {:transport, ref, {:line, line}})
    :ok
  end

  @doc "Reports that the process exited with `status`."
  @spec exit(pid(), reference(), term()) :: :ok
  def exit(owner, ref, status) do
    send(owner, {:transport, ref, {:exit, status}})
    :ok
  end

  @doc "Reports a transport failure."
  @spec fail(pid(), reference(), term()) :: :ok
  def fail(owner, ref, reason) do
    send(owner, {:transport, ref, {:error, reason}})
    :ok
  end
end
