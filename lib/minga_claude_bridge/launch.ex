defmodule MingaClaudeBridge.Launch do
  @moduledoc """
  Builds the `claude` command-line arguments for one session.

  Every launch carries the fixed flags in `fixed_args/0`. They select the stream-json protocol on stdin and stdout with partial messages, and restrict what Claude Code loads: no built-in tools (`--tools ""`), only Minga's MCP tools allowed (`--allowedTools mcp__minga__*`), no MCP servers from `~/.claude.json` or `.mcp.json` (`--strict-mcp-config`), no settings files and so no hooks or plugins (`--setting-sources ""`), and no skills or slash commands (`--disable-slash-commands`).

  ## Verified CLI version

  Claude Code 2.1.330 accepts every flag here together and answers `initialize` with them. `-p` is not needed: with stdout not a TTY, Claude Code runs non-interactively. `--resume` with an id Claude Code does not know makes it exit with status 1 and the message "No conversation found with session ID". `@min_version` records 2.1.330 as the lowest supported version.

  ## Options

    * `:model` - a model alias or id, for example `"sonnet"`.
    * `:effort` - one of `"low"`, `"medium"`, `"high"`, `"xhigh"`, `"max"`.
    * `:resume` - a Claude Code session id to continue.
    * `:persist_session` - `false` adds `--no-session-persistence`, for isolated queries that must not leave a session behind. Defaults to `true`.

  No shell runs these arguments, but a value that starts with `-` would still be read as a flag. `argv/1` rejects such values and every value that is not a non-empty string.
  """

  @min_version "2.1.330"
  @efforts ~w(low medium high xhigh max)

  @fixed_args [
    "--output-format",
    "stream-json",
    "--input-format",
    "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--tools",
    "",
    "--allowedTools",
    "mcp__minga__*",
    "--strict-mcp-config",
    "--setting-sources",
    "",
    "--disable-slash-commands"
  ]

  @type opts :: [
          model: String.t() | nil,
          effort: String.t() | nil,
          resume: String.t() | nil,
          persist_session: boolean()
        ]

  @doc "The lowest Claude Code version the bridge supports."
  @spec min_version() :: String.t()
  def min_version, do: @min_version

  @doc "The flags every launch carries."
  @spec fixed_args() :: [String.t()]
  def fixed_args, do: @fixed_args

  @doc "Builds the argument list. Returns `{:error, {:invalid_launch, key}}` for an invalid option value."
  @spec argv(keyword()) :: {:ok, [String.t()]} | {:error, {:invalid_launch, atom()}}
  def argv(opts) when is_list(opts) do
    with {:ok, model} <- value(opts, :model, "--model"),
         {:ok, effort} <- effort(opts),
         {:ok, resume} <- value(opts, :resume, "--resume"),
         {:ok, persistence} <- persistence(opts) do
      {:ok, @fixed_args ++ model ++ effort ++ resume ++ persistence}
    end
  end

  defp value(opts, key, flag) do
    case Keyword.get(opts, key) do
      nil -> {:ok, []}
      value when is_binary(value) -> flag_value(flag, value, key)
      _other -> {:error, {:invalid_launch, key}}
    end
  end

  defp flag_value(_flag, "", key), do: {:error, {:invalid_launch, key}}
  defp flag_value(_flag, "-" <> _rest, key), do: {:error, {:invalid_launch, key}}
  defp flag_value(flag, value, _key), do: {:ok, [flag, value]}

  defp effort(opts) do
    case Keyword.get(opts, :effort) do
      nil -> {:ok, []}
      effort when effort in @efforts -> {:ok, ["--effort", effort]}
      _other -> {:error, {:invalid_launch, :effort}}
    end
  end

  defp persistence(opts) do
    case Keyword.get(opts, :persist_session, true) do
      true -> {:ok, []}
      false -> {:ok, ["--no-session-persistence"]}
      _other -> {:error, {:invalid_launch, :persist_session}}
    end
  end
end
