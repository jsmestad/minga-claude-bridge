defmodule MingaClaudeBridge.Supervisor do
  @moduledoc """
  The bridge's process tree, started as the extension's child.

    * `MingaClaudeBridge.Registry` - finds a conversation's session.
    * `MingaClaudeBridge.SessionSupervisor` - a `DynamicSupervisor` for conversation sessions. Sessions are `:temporary`: a session that dies is replaced by the next request for its conversation.
    * `MingaClaudeBridge.TaskSupervisor` - background measurements of plan usage and context windows. Each owns a probe session that stops with it.
    * `MingaClaudeBridge.Status` - cached availability, plan usage, and context windows.

  Stopping the extension stops this tree. Each session's `terminate/2` stops its transport, which ends the `claude` process.
  """

  use Supervisor

  @doc "Starts the tree. Options: `:name` and `:status` (options for `MingaClaudeBridge.Status`)."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    children = [
      {Registry, keys: :unique, name: MingaClaudeBridge.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: MingaClaudeBridge.SessionSupervisor},
      {Task.Supervisor, name: MingaClaudeBridge.TaskSupervisor},
      {MingaClaudeBridge.Status,
       [name: MingaClaudeBridge.Status, tasks: MingaClaudeBridge.TaskSupervisor] ++
         Keyword.get(opts, :status, [])}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
