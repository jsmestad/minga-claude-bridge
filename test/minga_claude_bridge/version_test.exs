defmodule MingaClaudeBridge.VersionTest do
  use ExUnit.Case, async: true

  @lib Path.expand("../../lib", __DIR__)

  test "matches the version in mix.exs" do
    assert MingaClaudeBridge.Version.version() == Mix.Project.config()[:version]
    assert MingaClaudeBridge.version() == MingaClaudeBridge.Version.version()
  end

  # Minga compiles extensions in a standalone BEAM without Mix, where any Mix call fails the whole extension.
  test "library code never references Mix" do
    offenders =
      for file <- Path.wildcard(Path.join(@lib, "**/*.ex")),
          File.read!(file) =~ ~r/\bMix\.[A-Z]/,
          do: Path.relative_to(file, @lib)

    assert offenders == []
  end
end
