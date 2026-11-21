defmodule MingaClaudeBridge.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jsmestad/minga-claude-bridge"

  def project do
    [
      app: :minga_claude_bridge,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Run the Claude models in your Claude subscription inside Minga's agent through the claude CLI",
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp deps do
    [
      # Minga provides these modules at runtime. The SDK holds compile-time stubs only, so it must
      # stay out of the package's runtime dependencies: with it, Mix.install in the editor would
      # compile stubs that shadow Minga's real modules. Hex leaves `only: [:dev, :test]` deps out
      # of the package metadata.
      #
      # TODO(release): minga_sdk 0.1.0 is not on Hex yet. Before `mix hex.publish`, replace the git
      # dependency below with exactly:
      #
      #     {:minga_sdk, "~> 0.1", only: [:dev, :test], runtime: false},
      #
      {:minga_sdk,
       git: "https://github.com/jsmestad/minga",
       branch: "main",
       sparse: "sdk",
       only: [:dev, :test],
       runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
