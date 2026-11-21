defmodule MingaClaudeBridgeTest do
  # Serialized: init/1 reads the :model_routes application env and writes the reporter to :persistent_term.
  use ExUnit.Case, async: false

  defmodule FakeRoutes do
    @moduledoc false
    def register(attrs, _opts) do
      send(Application.get_env(:minga_claude_bridge, :fake_routes_observer), {:registered, attrs})
      {:ok, :fake_reporter}
    end

    def report_usage(_reporter, _windows, _opts \\ []), do: :ok
  end

  defmodule RoutesWithoutUsage do
    @moduledoc false
    # A Minga with model routes (#3734) but before plan usage (#3756).
    def register(_attrs, _opts), do: {:ok, :fake_reporter}
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:minga_claude_bridge, :model_routes)
      Application.delete_env(:minga_claude_bridge, :fake_routes_observer)
    end)
  end

  test "init registers the route and keeps the reporter" do
    Application.put_env(:minga_claude_bridge, :model_routes, FakeRoutes)
    Application.put_env(:minga_claude_bridge, :fake_routes_observer, self())

    assert {:ok, %{reporter: :fake_reporter}} = MingaClaudeBridge.init([])
    assert_received {:registered, attrs}
    assert attrs[:id] == "claude_bridge"
    assert attrs[:module] == MingaClaudeBridge.Route
    assert attrs[:display_name] == "Claude (subscription)"
    assert attrs[:short_name] == "Claude"

    assert attrs[:setup_action] == %{
             label: "Use Claude subscription (Claude Code)",
             description: "Sign in with the Claude Code CLI. Minga never sees your login."
           }

    assert :persistent_term.get({MingaClaudeBridge, :reporter}) == :fake_reporter
  end

  test "init fails with a clear message when Minga has no model routes" do
    Application.put_env(:minga_claude_bridge, :model_routes, Module.concat([NoSuch, ModelRoutes]))
    assert {:error, message} = MingaClaudeBridge.init([])

    assert message ==
             "minga_claude_bridge needs Minga with model routes and plan usage (jsmestad/minga#3734, #3756)"
  end

  test "init fails with the same message on a Minga with model routes but no plan usage" do
    Application.put_env(:minga_claude_bridge, :model_routes, RoutesWithoutUsage)
    assert {:error, message} = MingaClaudeBridge.init([])
    assert message =~ "#3756"
  end

  test "the child tree stops its sessions on shutdown" do
    {:ok, supervisor} =
      start_supervised(
        Supervisor.child_spec(
          {MingaClaudeBridge.Supervisor,
           name: :"bridge_sup_#{System.unique_integer([:positive])}"},
          id: :bridge
        )
      )

    assert [_status, _tasks, _sessions, _registry] = Supervisor.which_children(supervisor)

    {:ok, _session} =
      DynamicSupervisor.start_child(
        MingaClaudeBridge.SessionSupervisor,
        {MingaClaudeBridge.Session,
         transport: {MingaClaudeBridge.Transport.Scripted, controller: self()}}
      )

    assert_receive {:scripted_started, ref, _session_pid, _opts}
    assert :ok = stop_supervised(:bridge)
    assert_receive {:scripted_stopped, ^ref, _reason}
  end
end
