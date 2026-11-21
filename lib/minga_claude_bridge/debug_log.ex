defmodule MingaClaudeBridge.DebugLog do
  @moduledoc """
  Raw protocol logs for debugging, written only when `CLAUDE_BRIDGE_DEBUG=1`.

  Each transport writes one file, `<base>/debug/<key>-<timestamp>.log`, with every line it writes to stdin (prefixed `> `) and every line it reads from stdout (prefixed `< `). The directory has mode 0700 and each file 0600, because the lines hold conversation content.

  Without the variable nothing is written; the session logs frame types only.
  """

  alias MingaClaudeBridge.Workdir

  @type t :: File.io_device() | nil

  @doc "Returns true when `env` enables debug logs."
  @spec enabled?(%{optional(String.t()) => String.t()}) :: boolean()
  def enabled?(env), do: Map.get(env, "CLAUDE_BRIDGE_DEBUG") == "1"

  @doc "Opens a new log file for session `key` under `base`. Returns `nil` when the file cannot be created."
  @spec open(Path.t(), String.t()) :: t()
  def open(base, key) do
    with {:ok, dir} <- Workdir.ensure_private_dir(base),
         {:ok, dir} <- Workdir.ensure_private_dir(Path.join(dir, "debug")),
         path = Path.join(dir, "#{key}-#{System.os_time(:millisecond)}.log"),
         {:ok, device} <- File.open(path, [:write, :exclusive, :binary]),
         :ok <- File.chmod(path, 0o600) do
      device
    else
      _error -> nil
    end
  end

  @doc "Appends one line. `direction` is `:in` for stdout lines and `:out` for stdin lines."
  @spec write(t(), :in | :out, iodata()) :: :ok
  def write(nil, _direction, _line), do: :ok

  def write(device, direction, line) do
    prefix = if direction == :in, do: "< ", else: "> "
    _ = IO.binwrite(device, [prefix, line, trailing_newline(line)])
    :ok
  end

  @doc "Closes the log file."
  @spec close(t()) :: :ok
  def close(nil), do: :ok

  def close(device) do
    _ = File.close(device)
    :ok
  end

  defp trailing_newline(line) do
    binary = IO.iodata_to_binary(line)
    if String.ends_with?(binary, "\n"), do: "", else: "\n"
  end
end
