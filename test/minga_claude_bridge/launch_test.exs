defmodule MingaClaudeBridge.LaunchTest do
  use ExUnit.Case, async: true

  alias MingaClaudeBridge.Launch

  test "every launch carries the hardening flags" do
    assert {:ok, argv} = Launch.argv([])
    assert argv == Launch.fixed_args()

    for {flag, value} <- [
          {"--output-format", "stream-json"},
          {"--input-format", "stream-json"},
          {"--tools", ""},
          {"--allowedTools", "mcp__minga__*"},
          {"--setting-sources", ""},
          {"--thinking-display", "summarized"}
        ] do
      index = Enum.find_index(argv, &(&1 == flag))
      assert Enum.at(argv, index + 1) == value, flag
    end

    for flag <-
          ~w(--verbose --include-partial-messages --strict-mcp-config --disable-slash-commands) do
      assert flag in argv
    end
  end

  test "adds model, effort, resume, and the persistence switch" do
    assert {:ok, argv} =
             Launch.argv(
               model: "sonnet",
               effort: "high",
               resume: "9b2c7f1e",
               persist_session: false
             )

    assert Enum.drop(argv, length(Launch.fixed_args())) ==
             [
               "--model",
               "sonnet",
               "--effort",
               "high",
               "--resume",
               "9b2c7f1e",
               "--no-session-persistence"
             ]
  end

  test "rejects values that would read as flags or are not valid" do
    for {key, value} <- [
          model: "--dangerously-skip-permissions",
          model: "",
          model: :sonnet,
          resume: "-x",
          effort: "extreme",
          persist_session: "no"
        ] do
      assert {:error, {:invalid_launch, ^key}} = Launch.argv([{key, value}])
    end
  end

  test "records the minimum supported version" do
    assert {:ok, _version} = Version.parse(Launch.min_version())
  end
end
