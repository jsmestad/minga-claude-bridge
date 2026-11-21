defmodule MingaClaudeBridge.Binary do
  @moduledoc """
  Finds the `claude` executable and reads its version.

  `resolve/1` returns an absolute path, so the transport starts that exact file and never searches `PATH` again. It checks, in order:

    1. `CLAUDE_BRIDGE_CLI`, which must be an absolute path to an executable file.
    2. `claude` on `PATH`.
    3. `~/.local/bin/claude`, then `~/.claude/local/claude`, where the Claude Code installers put it.

  `version/2` runs `claude --version` with a timeout. It is for diagnostics only; the session checks the version Claude Code reports in its `initialize` answer.
  """

  @override "CLAUDE_BRIDGE_CLI"
  @default_version_timeout 5_000

  @type error ::
          :claude_not_found
          | {:invalid_cli_override, :not_absolute | :not_executable}

  @doc """
  Resolves the `claude` executable.

  Options, for tests:

    * `:env` - the environment map to read `CLAUDE_BRIDGE_CLI` from. Defaults to `System.get_env/0`.
    * `:find_executable` - a function that searches `PATH`. Defaults to `System.find_executable/1`.
    * `:home` - the home directory. Defaults to `System.user_home/0`.
  """
  @spec resolve(keyword()) :: {:ok, Path.t()} | {:error, error()}
  def resolve(opts \\ []) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)

    case Map.get(env, @override) do
      nil -> search(opts)
      "" -> search(opts)
      path -> override(path)
    end
  end

  defp override(path) do
    cond do
      Path.type(path) != :absolute -> {:error, {:invalid_cli_override, :not_absolute}}
      executable?(path) -> {:ok, path}
      true -> {:error, {:invalid_cli_override, :not_executable}}
    end
  end

  defp search(opts) do
    find = Keyword.get(opts, :find_executable, &System.find_executable/1)
    home = Keyword.get_lazy(opts, :home, &System.user_home/0)

    on_path =
      case find.("claude") do
        path when is_binary(path) -> [Path.expand(path)]
        nil -> []
      end

    fallbacks =
      if is_binary(home),
        do: [
          Path.join([home, ".local", "bin", "claude"]),
          Path.join([home, ".claude", "local", "claude"])
        ],
        else: []

    case Enum.find(on_path ++ fallbacks, &executable?/1) do
      nil -> {:error, :claude_not_found}
      path -> {:ok, path}
    end
  end

  @doc "Returns true when `path` is a regular file (or a link to one) with an execute bit set."
  @spec executable?(Path.t()) :: boolean()
  def executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _other -> false
    end
  end

  @doc """
  Runs `path --version` and returns the version number from its first line, for example `"2.1.330"`. Kills the process after `timeout` milliseconds.
  """
  @spec version(Path.t(), timeout()) ::
          {:ok, String.t()} | {:error, :timeout | {:exit_status, integer()} | :unparsable}
  def version(path, timeout \\ @default_version_timeout) do
    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: ["--version"]
      ])

    deadline = System.monotonic_time(:millisecond) + timeout
    collect(port, [], deadline)
  end

  defp collect(port, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, [acc, data], deadline)

      {^port, {:exit_status, 0}} ->
        parse_version(IO.iodata_to_binary(acc))

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status}}
    after
      remaining ->
        os_pid = Port.info(port, :os_pid)
        Port.close(port)
        kill_os_pid(os_pid)
        {:error, :timeout}
    end
  end

  defp kill_os_pid({:os_pid, pid}) when is_integer(pid),
    do: MingaClaudeBridge.OsProcess.signal(pid, :kill)

  defp kill_os_pid(_none), do: :ok

  defp parse_version(output) do
    case Regex.run(~r/\d+\.\d+\.\d+/, output) do
      [version] -> {:ok, version}
      nil -> {:error, :unparsable}
    end
  end
end
