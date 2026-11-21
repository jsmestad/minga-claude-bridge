defmodule MingaClaudeBridge do
  @moduledoc """
  Minga extension that serves the Claude models of the user's Claude subscription through the `claude` CLI.

  `init/1` registers `MingaClaudeBridge.Route` as the model route `"claude_bridge"` ("Claude (subscription)") and keeps the returned reporter for `MingaClaudeBridge.Status`. The extension's child is `MingaClaudeBridge.Supervisor`.

  The route needs Minga's model-route API (jsmestad/minga#3734). On a Minga without it, `init/1` returns an error instead of crashing the editor.
  """

  use Minga.Extension

  load_policy(:deferred)

  @route_id "claude_bridge"
  @display_name "Claude (subscription)"
  @needs_routes "minga_claude_bridge needs Minga with model routes (jsmestad/minga#3734)"

  @impl true
  def name, do: :claude_bridge

  @impl true
  def description, do: "Claude models from your Claude subscription, through the claude CLI"

  @impl true
  def version, do: unquote(Mix.Project.config()[:version])

  @impl true
  def init(_config) do
    routes = Application.get_env(:minga_claude_bridge, :model_routes, Minga.Extension.ModelRoutes)

    if Code.ensure_loaded?(routes) and function_exported?(routes, :register, 2) do
      register(routes)
    else
      {:error, @needs_routes}
    end
  end

  @impl true
  def child_spec(_config) do
    %{
      id: MingaClaudeBridge.Supervisor,
      start: {MingaClaudeBridge.Supervisor, :start_link, [[]]},
      type: :supervisor,
      restart: :permanent
    }
  end

  @doc "The route id, also the key of the `routes.<id>.env` credential entry."
  @spec route_id() :: String.t()
  def route_id, do: @route_id

  defp register(routes) do
    case routes.register(
           [id: @route_id, module: MingaClaudeBridge.Route, display_name: @display_name],
           []
         ) do
      {:ok, reporter} ->
        MingaClaudeBridge.Status.put_reporter(reporter)
        {:ok, %{reporter: reporter}}

      {:error, reason} ->
        {:error, "minga_claude_bridge could not register its model route: #{inspect(reason)}"}
    end
  end
end
