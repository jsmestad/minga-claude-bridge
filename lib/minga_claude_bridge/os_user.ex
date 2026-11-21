defmodule MingaClaudeBridge.OsUser do
  @moduledoc """
  The login name of the operating-system user running the bridge.

  Claude Code looks up its stored login by user name, so a `claude` child without `USER` reports itself signed out even when the user is signed in. Some launchers drop `USER` and `LOGNAME`, so `MingaClaudeBridge.Env` fills them from this value when they are missing.

  The name comes from `id -un`, run once without a shell and cached for the life of the VM. When it cannot be read, `name/0` returns nil and the child environment is left as it was.
  """

  @cache_key {__MODULE__, :name}

  @doc "Returns the OS user's login name, or nil when it cannot be determined."
  @spec name() :: String.t() | nil
  def name do
    case :persistent_term.get(@cache_key, :unset) do
      :unset ->
        name = lookup()
        :persistent_term.put(@cache_key, name)
        name

      cached ->
        cached
    end
  end

  @spec lookup() :: String.t() | nil
  defp lookup do
    case System.find_executable("id") do
      nil -> nil
      id -> run(id)
    end
  end

  @spec run(String.t()) :: String.t() | nil
  defp run(id) do
    case System.cmd(id, ["-un"], stderr_to_stdout: false) do
      {output, 0} -> output |> String.trim() |> non_empty()
      {_output, _status} -> nil
    end
  rescue
    _error in [ErlangError, ArgumentError] -> nil
  end

  @spec non_empty(String.t()) :: String.t() | nil
  defp non_empty(""), do: nil
  defp non_empty(name), do: name
end
