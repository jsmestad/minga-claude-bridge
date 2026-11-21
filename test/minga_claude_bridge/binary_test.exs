defmodule MingaClaudeBridge.BinaryTest do
  use ExUnit.Case, async: true

  alias MingaClaudeBridge.Binary

  @moduletag :tmp_dir

  defp executable!(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\n")
    File.chmod!(path, 0o755)
    path
  end

  defp no_path(_name), do: nil

  test "an absolute CLAUDE_BRIDGE_CLI wins", %{tmp_dir: dir} do
    override = executable!(Path.join(dir, "my-claude"))
    on_path = executable!(Path.join(dir, "bin/claude"))

    assert {:ok, ^override} =
             Binary.resolve(
               env: %{"CLAUDE_BRIDGE_CLI" => override},
               find_executable: fn _ -> on_path end
             )
  end

  test "a relative or non-executable override is an error", %{tmp_dir: dir} do
    assert {:error, {:invalid_cli_override, :not_absolute}} =
             Binary.resolve(env: %{"CLAUDE_BRIDGE_CLI" => "bin/claude"})

    plain = Path.join(dir, "plain")
    File.write!(plain, "")

    assert {:error, {:invalid_cli_override, :not_executable}} =
             Binary.resolve(env: %{"CLAUDE_BRIDGE_CLI" => plain})
  end

  test "PATH comes before the installer locations", %{tmp_dir: dir} do
    on_path = executable!(Path.join(dir, "bin/claude"))
    executable!(Path.join(dir, "home/.local/bin/claude"))

    assert {:ok, ^on_path} =
             Binary.resolve(
               env: %{},
               find_executable: fn "claude" -> on_path end,
               home: Path.join(dir, "home")
             )
  end

  test "falls back to ~/.local/bin, then ~/.claude/local", %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    second = executable!(Path.join(home, ".claude/local/claude"))
    assert {:ok, ^second} = Binary.resolve(env: %{}, find_executable: &no_path/1, home: home)

    first = executable!(Path.join(home, ".local/bin/claude"))
    assert {:ok, ^first} = Binary.resolve(env: %{}, find_executable: &no_path/1, home: home)
  end

  test "nothing found is :claude_not_found", %{tmp_dir: dir} do
    assert {:error, :claude_not_found} =
             Binary.resolve(env: %{}, find_executable: &no_path/1, home: Path.join(dir, "empty"))
  end
end
