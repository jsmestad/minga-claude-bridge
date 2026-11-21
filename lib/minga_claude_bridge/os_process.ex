defmodule MingaClaudeBridge.OsProcess do
  @moduledoc """
  Signals an operating-system process by pid and stops it within a bounded time.

  The pid is an integer the BEAM read from `Port.info(port, :os_pid)`. It is passed to `kill` as a separate argument with no shell, so nothing is interpolated into a command line.

  `terminate/2` sends SIGTERM, waits up to the grace period for the process to exit, then sends SIGKILL and waits up to the same period again. It polls with `kill -0` every #{20} ms. A process that already exited is not signalled.
  """

  @poll_ms 20

  @type signal :: :term | :kill

  @doc "Sends `signal` to `pid`. Returns `:ok` even when the process is gone."
  @spec signal(pos_integer(), signal()) :: :ok
  def signal(pid, signal) when is_integer(pid) and pid > 0 do
    _ = kill([signal_flag(signal), Integer.to_string(pid)])
    :ok
  end

  @doc "Returns true while `pid` exists (`kill -0` succeeds)."
  @spec alive?(pos_integer()) :: boolean()
  def alive?(pid) when is_integer(pid) and pid > 0, do: kill(["-0", Integer.to_string(pid)]) == 0

  @doc """
  Stops `pid`: SIGTERM, then SIGKILL after `grace_ms`. Returns `:exited` when the process exited after SIGTERM (or before it), `:killed` when SIGKILL ended it, and `:still_running` when it outlived both waits.
  """
  @spec terminate(pos_integer(), non_neg_integer()) :: :exited | :killed | :still_running
  def terminate(pid, grace_ms) when is_integer(pid) and pid > 0 do
    cond do
      not alive?(pid) ->
        :exited

      signal(pid, :term) == :ok and wait_gone(pid, grace_ms) ->
        :exited

      signal(pid, :kill) == :ok and wait_gone(pid, grace_ms) ->
        :killed

      true ->
        :still_running
    end
  end

  @doc "Waits up to `ms` milliseconds for `pid` to exit. Returns true when it is gone."
  @spec wait_gone(pos_integer(), non_neg_integer()) :: boolean()
  def wait_gone(pid, ms) do
    deadline = System.monotonic_time(:millisecond) + ms
    poll(pid, deadline)
  end

  defp poll(pid, deadline) do
    cond do
      not alive?(pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        # Waiting on an OS process: there is no BEAM message to wait for.
        receive do
        after
          @poll_ms -> poll(pid, deadline)
        end
    end
  end

  defp signal_flag(:term), do: "-TERM"
  defp signal_flag(:kill), do: "-KILL"

  defp kill(args) do
    case kill_path() do
      nil ->
        1

      path ->
        {_output, status} = System.cmd(path, args, stderr_to_stdout: true)
        status
    end
  end

  defp kill_path do
    Enum.find(["/bin/kill", "/usr/bin/kill"], &File.exists?/1) || System.find_executable("kill")
  end
end
