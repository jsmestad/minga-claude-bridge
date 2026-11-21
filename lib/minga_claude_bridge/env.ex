defmodule MingaClaudeBridge.Env do
  @moduledoc """
  Computes the environment of a Claude Code child process.

  The child must use Claude Code's own login and settings, never Minga's provider keys or the configuration of a parent Claude Code session. `child_env/2` builds the environment in three steps:

    1. Start from the parent environment and remove every variable in `stripped?/1`: `ANTHROPIC_*`, `AWS_*`, `NODE_*`, the Bedrock, Vertex, and Foundry switches, the variables a parent Claude Code session sets on its children, and Minga's provider key variables.
    2. Apply the route credential's `env` entry. An empty value removes the variable. `HOME`, `CLAUDE_CONFIG_DIR`, and `USERPROFILE` are rejected, because the bridge reads Claude Code's session files through the parent's values. Then, when `USER` or `LOGNAME` is still missing and the credential does not mention it, set it to the `:os_user` option: Claude Code looks up its login by user name and reports itself signed out without one.
    3. Force the variables in `forced/0`, which keep Claude Code from compacting on its own, loading claude.ai MCP servers, sending non-essential traffic, cutting MCP tool descriptions, deferring tools behind tool search, or timing out a tool call Minga is still running.

  The result is in the format of the `:env` option of `Port.open/2`: charlist pairs, with `false` for a variable to remove. A Port applies `:env` on top of the inherited environment, so every removal is explicit.

  Values are secrets. This module never logs them, and callers must not log the result.
  """

  @stripped_prefixes ["ANTHROPIC_", "AWS_", "NODE_"]

  # A parent Claude Code session sets these; they describe it, not our child (pi-claude-bridge list).
  @parent_session_vars ~w(
    CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_CODE_SESSION_ATTENDED
    CLAUDE_PID CLAUDE_EFFORT TRACEPARENT CLAUDE_CODE_INVOKED_SKILLS CLAUDE_ENV_FILE
    CLAUDE_CODE_ENTRYPOINT CLAUDE_AGENT_SDK_VERSION CLAUDE_CODE_EXECPATH
    CLAUDE_CODE_SSE_PORT CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN
  )

  @provider_switches ~w(CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY)

  # Secrets Minga reads: MingaAgent.Credentials @env_vars and MingaAgent.Gateway.Server.
  @minga_secret_vars ~w(
    OPENAI_API_KEY GOOGLE_API_KEY OPENROUTER_API_KEY GROQ_API_KEY MISTRAL_API_KEY
    DEEPSEEK_API_KEY MINGA_GATEWAY_TOKEN
  )

  @stripped_names MapSet.new(@parent_session_vars ++ @provider_switches ++ @minga_secret_vars)

  @rejected_credential_keys ~w(HOME CLAUDE_CONFIG_DIR USERPROFILE)

  @forced %{
    "DISABLE_AUTO_COMPACT" => "1",
    "ENABLE_CLAUDEAI_MCP_SERVERS" => "0",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1",
    "CLAUDE_CODE_MAX_MCP_DESCRIPTION_LENGTH" => "16384",
    "ENABLE_TOOL_SEARCH" => "false",
    "MCP_TOOL_TIMEOUT" => "86400000"
  }

  @typedoc "An environment as a map of variable names to values."
  @type env_map :: %{optional(String.t()) => String.t()}

  @typedoc "The `:env` option of `Port.open/2`."
  @type port_env :: [{charlist(), charlist() | false}]

  @type error :: {:forbidden_env, [String.t()]} | {:invalid_env, [String.t()]}

  @typedoc "`:os_user` is the login name used for a missing `USER` or `LOGNAME`, or nil to leave them missing."
  @type option :: {:os_user, String.t() | nil}

  @user_vars ~w(USER LOGNAME)

  @doc """
  Builds the child environment from the parent environment and the credential's `env` entry.

  Returns `{:error, {:forbidden_env, keys}}` when the credential sets `HOME`, `CLAUDE_CONFIG_DIR`, or `USERPROFILE`, and `{:error, {:invalid_env, keys}}` for a credential key that is empty or contains `=` or a NUL byte, or a value that contains a NUL byte. Error reasons name keys, never values.
  """
  @spec child_env(env_map(), env_map(), [option()]) :: {:ok, port_env()} | {:error, error()}
  def child_env(parent, credential, opts \\ [])
      when is_map(parent) and is_map(credential) and is_list(opts) do
    with :ok <- check_credential(credential) do
      final = final_env(parent, credential, opts)
      {:ok, to_port_env(parent, final)}
    end
  end

  @doc "Returns the final environment as a map, after the same three steps as `child_env/2`."
  @spec final_env(env_map(), env_map(), [option()]) :: env_map()
  def final_env(parent, credential, opts \\ [])
      when is_map(parent) and is_map(credential) and is_list(opts) do
    parent
    |> Map.reject(fn {name, _value} -> stripped?(name) end)
    |> apply_credential(credential)
    |> fill_user(credential, Keyword.get(opts, :os_user))
    |> Map.merge(@forced)
  end

  @doc "Returns true when step 1 removes the inherited variable `name`."
  @spec stripped?(String.t()) :: boolean()
  def stripped?(name) when is_binary(name) do
    MapSet.member?(@stripped_names, name) or String.starts_with?(name, @stripped_prefixes)
  end

  @doc "The variables step 3 forces."
  @spec forced() :: env_map()
  def forced, do: @forced

  @doc "The credential keys the bridge rejects."
  @spec rejected_credential_keys() :: [String.t()]
  def rejected_credential_keys, do: @rejected_credential_keys

  defp check_credential(credential) do
    keys = Map.keys(credential)

    case Enum.filter(keys, &(&1 in @rejected_credential_keys)) do
      [] -> check_names(credential)
      forbidden -> {:error, {:forbidden_env, Enum.sort(forbidden)}}
    end
  end

  defp check_names(credential) do
    invalid =
      for {name, value} <- credential, not valid_pair?(name, value), do: to_string(name)

    case invalid do
      [] -> :ok
      names -> {:error, {:invalid_env, Enum.sort(names)}}
    end
  end

  defp valid_pair?(name, value) when is_binary(name) and is_binary(value) do
    name != "" and not String.contains?(name, ["=", <<0>>]) and not String.contains?(value, <<0>>)
  end

  defp valid_pair?(_name, _value), do: false

  defp apply_credential(env, credential) do
    Enum.reduce(credential, env, fn
      {name, ""}, env -> Map.delete(env, name)
      {name, value}, env -> Map.put(env, name, value)
    end)
  end

  defp fill_user(env, _credential, nil), do: env

  defp fill_user(env, credential, os_user) when is_binary(os_user) do
    Enum.reduce(@user_vars, env, fn name, env ->
      if Map.has_key?(env, name) or Map.has_key?(credential, name),
        do: env,
        else: Map.put(env, name, os_user)
    end)
  end

  defp to_port_env(parent, final) do
    removals =
      for name <- Map.keys(parent), not Map.has_key?(final, name), do: {to_charlist(name), false}

    settings = for {name, value} <- final, do: {to_charlist(name), to_charlist(value)}

    Enum.sort(removals ++ settings)
  end
end
