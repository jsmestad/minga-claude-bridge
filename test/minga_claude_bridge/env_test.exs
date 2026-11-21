defmodule MingaClaudeBridge.EnvTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MingaClaudeBridge.Env

  @parent %{
    "PATH" => "/usr/bin",
    "HOME" => "/Users/me",
    "LANG" => "en_US.UTF-8",
    "ANTHROPIC_API_KEY" => "sk-parent",
    "ANTHROPIC_BASE_URL" => "https://proxy",
    "AWS_PROFILE" => "work",
    "NODE_OPTIONS" => "--inspect",
    "CLAUDE_CODE_USE_BEDROCK" => "1",
    "CLAUDE_CODE_USE_VERTEX" => "1",
    "CLAUDE_CODE_USE_FOUNDRY" => "1",
    "CLAUDECODE" => "1",
    "CLAUDE_CODE_SESSION_ID" => "parent-session",
    "CLAUDE_CODE_ENTRYPOINT" => "cli",
    "CLAUDE_ENV_FILE" => "/tmp/env.sh",
    "TRACEPARENT" => "00-abc",
    "OPENAI_API_KEY" => "sk-openai",
    "GOOGLE_API_KEY" => "g",
    "OPENROUTER_API_KEY" => "o",
    "GROQ_API_KEY" => "q",
    "MISTRAL_API_KEY" => "m",
    "DEEPSEEK_API_KEY" => "d",
    "MINGA_GATEWAY_TOKEN" => "t",
    "DISABLE_AUTO_COMPACT" => "0"
  }

  defp final(credential \\ %{}), do: Env.final_env(@parent, credential)

  describe "step 1: inherited variables" do
    test "keeps ordinary variables" do
      env = final()
      assert env["PATH"] == "/usr/bin"
      assert env["HOME"] == "/Users/me"
      assert env["LANG"] == "en_US.UTF-8"
    end

    for name <-
          ~w(ANTHROPIC_API_KEY ANTHROPIC_BASE_URL AWS_PROFILE NODE_OPTIONS CLAUDE_CODE_USE_BEDROCK
                   CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDECODE CLAUDE_CODE_SESSION_ID
                   CLAUDE_CODE_ENTRYPOINT CLAUDE_ENV_FILE TRACEPARENT OPENAI_API_KEY GOOGLE_API_KEY
                   OPENROUTER_API_KEY GROQ_API_KEY MISTRAL_API_KEY DEEPSEEK_API_KEY MINGA_GATEWAY_TOKEN) do
      test "removes #{name}" do
        refute Map.has_key?(final(), unquote(name))
      end
    end
  end

  describe "step 2: credential env" do
    test "sets variables, including stripped ones" do
      env = final(%{"CLAUDE_CODE_OAUTH_TOKEN" => "oauth", "ANTHROPIC_BASE_URL" => "https://mine"})
      assert env["CLAUDE_CODE_OAUTH_TOKEN"] == "oauth"
      assert env["ANTHROPIC_BASE_URL"] == "https://mine"
    end

    test "an empty value removes the variable" do
      refute Map.has_key?(final(%{"LANG" => ""}), "LANG")
    end

    test "rejects HOME, CLAUDE_CONFIG_DIR, and USERPROFILE without naming values" do
      for key <- ~w(HOME CLAUDE_CONFIG_DIR USERPROFILE) do
        assert {:error, {:forbidden_env, [^key]}} = Env.child_env(@parent, %{key => "/elsewhere"})
      end
    end

    test "rejects malformed keys and values" do
      assert {:error, {:invalid_env, ["A=B"]}} = Env.child_env(@parent, %{"A=B" => "1"})
      assert {:error, {:invalid_env, [""]}} = Env.child_env(@parent, %{"" => "1"})
      assert {:error, {:invalid_env, ["X"]}} = Env.child_env(@parent, %{"X" => <<"a", 0>>})
    end
  end

  describe "step 3: forced variables" do
    test "override the parent and the credential" do
      env = final(%{"MCP_TOOL_TIMEOUT" => "5", "ENABLE_TOOL_SEARCH" => "true"})

      for {name, value} <- Env.forced(), do: assert(env[name] == value)
      assert env["DISABLE_AUTO_COMPACT"] == "1"
    end
  end

  describe "port env" do
    test "is charlist pairs with false for every removed inherited variable" do
      {:ok, port_env} = Env.child_env(@parent, %{"LANG" => ""})

      assert {~c"ANTHROPIC_API_KEY", false} in port_env
      assert {~c"LANG", false} in port_env
      assert {~c"PATH", ~c"/usr/bin"} in port_env
      assert {~c"MCP_TOOL_TIMEOUT", ~c"86400000"} in port_env
      assert Enum.all?(port_env, fn {k, v} -> is_list(k) and (v == false or is_list(v)) end)
    end
  end

  property "no ANTHROPIC_* variable survives unless the credential sets it" do
    name = string(?A..?Z, min_length: 1, max_length: 12)

    check all(
            suffixes <- list_of(name, max_length: 5),
            value <- string(:alphanumeric, min_length: 1),
            credential_suffixes <- list_of(name, max_length: 2)
          ) do
      parent = Map.new(suffixes, &{"ANTHROPIC_" <> &1, value})
      credential = Map.new(credential_suffixes, &{"ANTHROPIC_" <> &1, "mine"})
      {:ok, port_env} = Env.child_env(Map.put(parent, "PATH", "/bin"), credential)

      surviving =
        for {name, value} <- port_env,
            value != false,
            String.starts_with?(to_string(name), "ANTHROPIC_"),
            do: to_string(name)

      assert Enum.sort(surviving) == credential |> Map.keys() |> Enum.sort()
    end
  end
end
