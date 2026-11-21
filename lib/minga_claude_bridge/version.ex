defmodule MingaClaudeBridge.Version do
  @moduledoc """
  The bridge's version.

  Minga compiles extensions in a standalone BEAM where Mix is not running, so library code must not read the Mix project configuration. `mix.exs` repeats the version; a test checks that both agree and that no library module references Mix.
  """

  @version "0.1.0"

  @doc "The bridge's version string."
  @spec version() :: String.t()
  def version, do: @version
end
