defmodule MingaClaudeBridge.Route.MappingTest do
  use ExUnit.Case, async: true

  alias MingaAgent.InferenceRoute.{Message, ToolCall}
  alias MingaClaudeBridge.Route.Mapping

  defp call(id), do: %ToolCall{id: id, name: "read_file", arguments: %{"path" => id}}

  describe "history entries" do
    test "the recorded reply equals the message Minga sends back, however Minga splits it" do
      recorded =
        Mapping.assistant_entry("Hello world", [
          %{id: "t1", name: "read_file", arguments: %{"path" => "t1"}}
        ])

      minga =
        Mapping.entry(%Message{
          role: :assistant,
          content: [
            {:thinking, "let me think", "sig"},
            {:text, "Hello "},
            {:text, "world"},
            {:tool_call, call("t1")}
          ]
        })

      assert recorded == minga
    end

    test "thinking does not change a user or tool entry; text, images, and results do" do
      base = %Message{role: :user, content: [{:text, "hi"}, {:image, "image/png", <<1, 2>>}]}
      with_thinking = %Message{base | content: [{:thinking, "x", nil} | base.content]}
      assert Mapping.entry(base) == Mapping.entry(with_thinking)
      refute Mapping.entry(base) == Mapping.entry(%Message{base | content: [{:text, "hi"}]})

      ok = %Message{role: :tool, content: [{:tool_result, "t1", [{:text, "a"}], false}]}
      failed = %Message{role: :tool, content: [{:tool_result, "t1", [{:text, "a"}], true}]}
      refute Mapping.entry(ok) == Mapping.entry(failed)
    end
  end

  describe "continuation/1" do
    test "only tool messages become tool results" do
      messages = [
        %Message{
          role: :tool,
          content: [{:tool_result, "t1", [{:text, "a"}, {:image, "image/png", "x"}], false}]
        },
        %Message{role: :tool, content: [{:tool_result, "t2", [{:text, "denied"}], true}]}
      ]

      assert {:tool_results,
              [
                %{
                  tool_use_id: "t1",
                  content: [{:text, "a"}, {:image, "image/png", "x"}],
                  is_error: false
                },
                %{tool_use_id: "t2", content: [{:text, "denied"}], is_error: true}
              ]} = Mapping.continuation(messages)
    end

    test "only user messages become one prompt, with images as base64 blocks" do
      messages = [
        %Message{role: :user, content: [{:text, "look"}, {:image, "image/png", <<1>>}]},
        %Message{role: :user, content: [{:text, "again"}]}
      ]

      assert {:prompt,
              [
                {:text, "look"},
                {:other,
                 %{
                   "type" => "image",
                   "source" => %{"data" => "AQ==", "media_type" => "image/png"}
                 }},
                {:text, "again"}
              ]} = Mapping.continuation(messages)
    end

    test "mixed or empty additions need a fresh session" do
      mixed = [
        %Message{role: :tool, content: [{:tool_result, "t1", [], false}]},
        %Message{role: :user, content: [{:text, "x"}]}
      ]

      assert Mapping.continuation(mixed) == :fresh
      assert Mapping.continuation([]) == :fresh
    end
  end

  describe "fresh_prompt/1" do
    test "puts earlier history in a transcript before the newest user input" do
      messages = [
        %Message{role: :user, content: [{:text, "first"}, {:image, "image/png", "x"}]},
        %Message{
          role: :assistant,
          content: [{:thinking, "secret", nil}, {:text, "reply"}, {:tool_call, call("t1")}]
        },
        %Message{role: :tool, content: [{:tool_result, "t1", [{:text, "file body"}], false}]},
        %Message{role: :user, content: [{:text, "second"}]}
      ]

      assert [{:text, transcript}, {:text, "second"}] = Mapping.fresh_prompt(messages)
      assert transcript =~ "<user>\nfirst\n[image image/png omitted]\n</user>"
      assert transcript =~ ~s(<tool_call id="t1" name="read_file">{"path":"t1"}</tool_call>)
      assert transcript =~ ~s(<tool_result id="t1" error="false">\nfile body\n</tool_result>)
      refute transcript =~ "secret"
    end

    test "a single user message is sent as is" do
      assert Mapping.fresh_prompt([%Message{role: :user, content: [{:text, "hi"}]}]) == [
               {:text, "hi"}
             ]
    end

    test "history that ends with tool results asks Claude to continue" do
      messages = [
        %Message{role: :user, content: [{:text, "go"}]},
        %Message{role: :tool, content: [{:tool_result, "t1", [{:text, "done"}], false}]}
      ]

      assert [{:text, _transcript}, {:text, "Continue" <> _}] = Mapping.fresh_prompt(messages)
    end
  end

  describe "models" do
    test "maps Claude Code's model entries, with a default level when effort is unsupported" do
      assert {:ok, model} =
               Mapping.model(%{
                 "value" => "opus",
                 "displayName" => "Opus 5.5",
                 "supportedEffortLevels" => ["low", "max"]
               })

      assert {model.id, model.display_name, model.reasoning_levels} ==
               {"opus", "Opus 5.5", ["low", "max"]}

      assert {model.tools?, model.cost} == {true, :subscription}

      assert {:ok, %{reasoning_levels: ["default"], display_name: "x"}} =
               Mapping.model(%{"value" => "x", "supportedEffortLevels" => nil})

      assert Mapping.model(%{"displayName" => "no id"}) == :error
    end

    test "workdir keys are stable, distinct, and valid" do
      assert Mapping.workdir_key("a") == Mapping.workdir_key("a")
      refute Mapping.workdir_key("a") == Mapping.workdir_key("b")
      assert Mapping.workdir_key("../../etc") =~ ~r/\A[A-Za-z0-9_-]{32}\z/
    end
  end
end
