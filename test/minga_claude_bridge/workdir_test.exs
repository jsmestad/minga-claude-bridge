defmodule MingaClaudeBridge.WorkdirTest do
  use ExUnit.Case, async: true

  alias MingaClaudeBridge.Workdir

  @moduletag :tmp_dir

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  test "creates an empty 0700 session directory under a 0700 base", %{tmp_dir: dir} do
    base = Path.join(dir, "base")
    assert {:ok, workdir} = Workdir.create(base, "conv-1")
    assert File.ls!(workdir) == []
    assert mode(base) == 0o700
    assert mode(Path.join(base, "sessions")) == 0o700
    assert mode(workdir) == 0o700
  end

  test "replaces a stale directory with the same key", %{tmp_dir: dir} do
    base = Path.join(dir, "base")
    {:ok, workdir} = Workdir.create(base, "conv-1")
    File.write!(Path.join(workdir, "leftover"), "x")
    assert {:ok, ^workdir} = Workdir.create(base, "conv-1")
    assert File.ls!(workdir) == []
  end

  test "remove is idempotent", %{tmp_dir: dir} do
    {:ok, workdir} = Workdir.create(Path.join(dir, "base"), "k")
    assert :ok = Workdir.remove(workdir)
    assert :ok = Workdir.remove(workdir)
    refute File.exists?(workdir)
  end

  test "rejects keys that could escape the base", %{tmp_dir: dir} do
    for key <- ["../x", "a/b", "", ".hidden"] do
      assert {:error, {:workdir, :invalid_key}} = Workdir.create(Path.join(dir, "base"), key)
    end
  end

  test "refuses a base that is a symlink", %{tmp_dir: dir} do
    target = Path.join(dir, "target")
    File.mkdir_p!(target)
    link = Path.join(dir, "link")
    File.ln_s!(target, link)
    assert {:error, {:workdir, :not_a_directory}} = Workdir.create(link, "k")
  end

  test "random keys are valid and distinct" do
    keys = for _ <- 1..20, do: Workdir.random_key()
    assert keys == Enum.uniq(keys)
    assert Enum.all?(keys, &(&1 =~ ~r/\A[A-Za-z0-9_-]+\z/))
  end
end
