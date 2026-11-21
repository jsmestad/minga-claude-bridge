defmodule MingaClaudeBridge.OsUserTest do
  # Runs `id` through System.cmd, which spawns an OS process (erl_child_setup EPIPE race under async tests).
  use ExUnit.Case, async: false

  alias MingaClaudeBridge.OsUser

  test "returns the login name of the user running the VM" do
    {expected, 0} = System.cmd("id", ["-un"])
    assert OsUser.name() == String.trim(expected)
  end

  test "caches the name after the first call" do
    name = OsUser.name()
    assert :persistent_term.get({OsUser, :name}) == name
  end
end
