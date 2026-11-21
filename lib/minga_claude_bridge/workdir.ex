defmodule MingaClaudeBridge.Workdir do
  @moduledoc """
  Private directories the bridge owns: the empty working directory of each `claude` process, and the debug log directory.

  Everything lives under one base directory, `<tmp>/minga-claude-bridge-<home uid>`, created with mode 0700. Before it uses any of these directories, `ensure_private_dir/1` checks that it is a real directory (not a symlink) owned by the current user, then sets its mode to 0700. A base that fails the check is an error, never repaired, because another user may control it.

  A session directory is `<base>/sessions/<key>`. `create/2` removes a stale directory with the same key first, so the child always starts in an empty directory. Claude Code stores sessions under `~/.claude/projects`, keyed by the working directory path, so a stable `key` per conversation keeps `--resume` working across restarts.
  """

  @type error :: {:workdir, atom() | {atom(), term()}}

  @doc "Returns the base directory path for `tmp_dir`. Does not create it."
  @spec base_path(Path.t()) :: Path.t()
  def base_path(tmp_dir \\ System.tmp_dir!()) do
    uid =
      case File.stat(System.user_home!()) do
        {:ok, %File.Stat{uid: uid}} -> uid
        {:error, _reason} -> "user"
      end

    Path.join(tmp_dir, "minga-claude-bridge-#{uid}")
  end

  @doc "Creates (if needed) and checks a 0700 directory owned by the current user."
  @spec ensure_private_dir(Path.t()) :: {:ok, Path.t()} | {:error, error()}
  def ensure_private_dir(path) do
    with :ok <- mkdir(path),
         {:ok, stat} <- lstat(path),
         :ok <- check_dir(stat),
         {:ok, uid} <- current_uid(path),
         :ok <- check_owner(stat, uid),
         :ok <- chmod(path) do
      {:ok, path}
    end
  end

  @doc """
  Creates the empty working directory for session `key` under `base` and returns its path. `key` may hold only letters, digits, `-`, and `_`.
  """
  @spec create(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, error()}
  def create(base, key) when is_binary(key) do
    with :ok <- check_key(key),
         {:ok, base} <- ensure_private_dir(base),
         {:ok, sessions} <- ensure_private_dir(Path.join(base, "sessions")) do
      dir = Path.join(sessions, key)
      File.rm_rf(dir)

      case File.mkdir(dir) do
        :ok -> ensure_private_dir(dir)
        {:error, reason} -> {:error, {:workdir, {:mkdir, reason}}}
      end
    end
  end

  @doc "Removes a session directory. Safe to call more than once."
  @spec remove(Path.t() | nil) :: :ok
  def remove(nil), do: :ok

  def remove(dir) do
    File.rm_rf(dir)
    :ok
  end

  @doc "Returns a random session key."
  @spec random_key() :: String.t()
  def random_key, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp check_key(key) do
    if key =~ ~r/\A[A-Za-z0-9_-]{1,128}\z/,
      do: :ok,
      else: {:error, {:workdir, :invalid_key}}
  end

  defp mkdir(path) do
    case File.mkdir(path) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, {:workdir, {:mkdir, reason}}}
    end
  end

  defp lstat(path) do
    case File.lstat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, reason} -> {:error, {:workdir, {:stat, reason}}}
    end
  end

  defp check_dir(%File.Stat{type: :directory}), do: :ok
  defp check_dir(%File.Stat{}), do: {:error, {:workdir, :not_a_directory}}

  # The owner of a file this process just created is the current user.
  defp current_uid(dir) do
    probe = Path.join(dir, ".owner-#{System.unique_integer([:positive])}")

    with :ok <- File.write(probe, "", [:exclusive]),
         {:ok, %File.Stat{uid: uid}} <- File.lstat(probe) do
      File.rm(probe)
      {:ok, uid}
    else
      {:error, reason} ->
        File.rm(probe)
        {:error, {:workdir, {:owner_probe, reason}}}
    end
  end

  defp check_owner(%File.Stat{uid: uid}, uid), do: :ok
  defp check_owner(%File.Stat{}, _uid), do: {:error, {:workdir, :not_owner}}

  defp chmod(path) do
    case File.chmod(path, 0o700) do
      :ok -> :ok
      {:error, reason} -> {:error, {:workdir, {:chmod, reason}}}
    end
  end
end
