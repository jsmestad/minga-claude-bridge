defmodule MingaClaudeBridge.RouteTest do
  use ExUnit.Case, async: true

  alias MingaAgent.InferenceRoute.{ConversationRef, Message, Model, Options, Request, Response}
  alias MingaAgent.InferenceRoute.{ToolCall, ToolDeclaration, Usage}
  alias MingaClaudeBridge.{Route, Status}
  alias MingaClaudeBridge.Route.{Config, Mapping}
  alias MingaClaudeBridge.Transport.Scripted

  @tool %ToolDeclaration{
    name: "read_file",
    description: "Read a file",
    input_schema: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}}
  }

  setup do
    test = self()
    registry = :"route_test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    status =
      start_supervised!(
        {Status,
         reporter: :reporter,
         report: fn reporter, availability -> send(test, {:reported, reporter, availability}) end}
      )

    config =
      Config.load(
        transport: {Scripted, controller: test},
        registry: registry,
        supervisor: supervisor,
        status: status
      )

    %{config: config}
  end

  # Values

  defp model(id \\ "sonnet") do
    %Model{
      id: id,
      display_name: id,
      context_window: 200_000,
      max_output: 32_000,
      reasoning_levels: ["low", "high"],
      tools?: true,
      images_in?: true,
      tool_result_images?: true,
      compaction: :native,
      usage: :tokens,
      cost: :subscription
    }
  end

  defp request(messages, opts \\ []) do
    %Request{
      model: Keyword.get(opts, :model, model()),
      system: Keyword.get(opts, :system, "You are helpful."),
      messages: messages,
      tools: Keyword.get(opts, :tools, [@tool]),
      options: %Options{
        max_output_tokens: 32_000,
        reasoning: Keyword.get(opts, :reasoning, "high")
      },
      conversation: %ConversationRef{
        session_id: Keyword.get(opts, :conversation, "conv-1"),
        owner: self(),
        epoch_id: "epoch-1",
        conversation_revision: 1,
        request_id: 1,
        purpose: Keyword.get(opts, :purpose, :turn)
      },
      credential: nil
    }
  end

  defp user(text), do: %Message{role: :user, content: [{:text, text}]}
  defp assistant(parts), do: %Message{role: :assistant, content: parts}

  defp tool_result(id, text),
    do: %Message{role: :tool, content: [{:tool_result, id, [{:text, text}], false}]}

  # Claude Code frames

  defp init_response do
    %{
      "type" => "control_response",
      "response" => %{
        "subtype" => "success",
        "request_id" => "minga_init",
        "response" => %{
          "account" => %{"subscriptionType" => "Claude Pro"},
          "models" => [],
          "claude_code_version" => "2.1.330"
        }
      }
    }
  end

  defp system_init do
    %{
      "type" => "system",
      "subtype" => "init",
      "session_id" => "cc",
      "tools" => ["mcp__minga__read_file"],
      "mcp_servers" => [%{"name" => "minga", "status" => "connected"}]
    }
  end

  defp stream(event), do: %{"type" => "stream_event", "event" => event}

  defp text_reply(text) do
    [
      stream(%{
        "type" => "message_start",
        "message" => %{"id" => "m", "usage" => %{"input_tokens" => 7}}
      }),
      stream(%{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      }),
      stream(%{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => text}
      }),
      stream(%{"type" => "content_block_stop", "index" => 0}),
      stream(%{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{"output_tokens" => 3}
      }),
      stream(%{"type" => "message_stop"}),
      %{
        "type" => "result",
        "subtype" => "success",
        "is_error" => false,
        "stop_reason" => "end_turn"
      }
    ]
  end

  defp tool_reply(id) do
    [
      stream(%{
        "type" => "message_start",
        "message" => %{"id" => "m", "usage" => %{"input_tokens" => 7}}
      }),
      stream(%{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{
          "type" => "tool_use",
          "id" => id,
          "name" => "mcp__minga__read_file",
          "input" => %{}
        }
      }),
      stream(%{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"path":"a.txt"})}
      }),
      stream(%{"type" => "content_block_stop", "index" => 0}),
      tools_call("c-" <> id, id),
      stream(%{"type" => "message_stop"})
    ]
  end

  defp tools_call(request_id, tool_use_id) do
    %{
      "type" => "control_request",
      "request_id" => request_id,
      "request" => %{
        "subtype" => "mcp_message",
        "server_name" => "minga",
        "message" => %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "read_file",
            "arguments" => %{"path" => "a.txt"},
            "_meta" => %{"claudecode/toolUseId" => tool_use_id}
          }
        }
      }
    }
  end

  # Harness

  defp started do
    assert_receive {:scripted_started, ref, session, opts}
    assert_receive {:scripted_line, ^ref, initialize}
    assert %{"request" => %{"subtype" => "initialize"}} = JSON.decode!(initialize)
    push(%{ref: ref, session: session}, init_response())
    %{ref: ref, session: session, opts: opts}
  end

  defp push(%{ref: ref, session: session}, frames),
    do: Enum.each(List.wrap(frames), &Scripted.push(session, ref, &1))

  defp written(%{ref: ref}) do
    assert_receive {:scripted_line, ^ref, line}
    JSON.decode!(line)
  end

  defp user_text(line), do: line["message"]["content"] |> Enum.map_join(& &1["text"])

  defp events!({:ok, %Response{events: events}}), do: Enum.to_list(events)

  # Runs the first turn of a conversation: the session starts, Claude Code answers with `reply`.
  defp first_turn(config, messages, reply, opts \\ []) do
    response = Route.stream(request(messages, opts), config)
    cc = started()
    line = written(cc)
    push(cc, [system_init() | reply])
    {events!(response), cc, line}
  end

  describe "turns" do
    test "a text turn streams Minga events and launches the selected model and effort", %{
      config: config
    } do
      {events, cc, line} = first_turn(config, [user("hello")], text_reply("Hi there"))

      assert events == [
               {:text, "Hi there"},
               {:usage,
                %Usage{
                  input_tokens: 7,
                  output_tokens: 3,
                  cache_read_tokens: 0,
                  cache_write_tokens: 0
                }},
               {:finish, :stop}
             ]

      assert user_text(line) == "hello"
      assert cc.opts[:launch][:model] == "sonnet"
      assert cc.opts[:launch][:effort] == "high"
      assert cc.opts[:launch][:persist_session] == false
      assert cc.opts[:session_key] == Mapping.workdir_key("conv-1")
    end

    test "a tool turn ends with the tool call and :tool_calls", %{config: config} do
      {events, _cc, _line} = first_turn(config, [user("read it")], tool_reply("t1"))

      assert [
               {:tool_call,
                %ToolCall{id: "t1", name: "read_file", arguments: %{"path" => "a.txt"}}},
               {:usage, %Usage{}},
               {:finish, :tool_calls}
             ] = events
    end

    test "tool results continue the same session instead of a new prompt", %{config: config} do
      {_events, cc, _line} = first_turn(config, [user("read it")], tool_reply("t1"))

      call = %ToolCall{id: "t1", name: "read_file", arguments: %{"path" => "a.txt"}}
      messages = [user("read it"), assistant([{:tool_call, call}]), tool_result("t1", "contents")]
      response = Route.stream(request(messages), config)

      refute_received {:scripted_started, _ref, _session, _opts}
      answer = written(cc)
      assert answer["type"] == "control_response"
      assert answer["response"]["request_id"] == "c-t1"

      assert [%{"text" => "contents"}] =
               answer["response"]["response"]["mcp_response"]["result"]["content"]

      push(cc, text_reply("Done"))
      assert [{:text, "Done"}, {:usage, _}, {:finish, :stop}] = events!(response)
    end

    test "a new user message continues an idle session as a prompt", %{config: config} do
      {_events, cc, _line} = first_turn(config, [user("hello")], text_reply("Hi there"))

      messages = [user("hello"), assistant([{:text, "Hi there"}]), user("and now?")]
      response = Route.stream(request(messages), config)

      refute_received {:scripted_started, _ref, _session, _opts}
      assert user_text(written(cc)) == "and now?"
      push(cc, [system_init() | text_reply("Now this")])
      assert [{:text, "Now this"}, {:usage, _}, {:finish, :stop}] = events!(response)
    end

    test "diverged history starts a fresh session with a transcript", %{config: config} do
      {_events, old, _line} = first_turn(config, [user("hello")], text_reply("Hi there"))

      # Minga edited the earlier reply, so Claude Code's session no longer matches.
      messages = [user("hello"), assistant([{:text, "Edited reply"}]), user("next")]
      response = Route.stream(request(messages), config)

      old_ref = old.ref
      assert_receive {:scripted_stopped, ^old_ref, _reason}
      fresh = started()
      prompt = user_text(written(fresh))
      assert prompt =~ "<transcript>"
      assert prompt =~ "Edited reply"
      assert String.ends_with?(prompt, "next")

      push(fresh, [system_init() | text_reply("ok")])
      assert [{:text, "ok"}, {:usage, _}, {:finish, :stop}] = events!(response)
    end

    test "a changed effort starts a fresh session", %{config: config} do
      {_events, old, _line} = first_turn(config, [user("hello")], text_reply("Hi"))
      messages = [user("hello"), assistant([{:text, "Hi"}]), user("more")]
      _response = Route.stream(request(messages, reasoning: "low"), config)

      old_ref = old.ref
      assert_receive {:scripted_stopped, ^old_ref, _reason}
      assert started().opts[:launch][:effort] == "low"
    end

    test "cancel aborts the turn", %{config: config} do
      {:ok, %Response{cancel: cancel}} = Route.stream(request([user("hello")]), config)
      cc = started()
      _prompt = written(cc)
      push(cc, system_init())

      assert :ok = cancel.()
      assert %{"request" => %{"subtype" => "interrupt"}} = written(cc)
      assert :ok = cancel.()
    end

    test "a summary request runs isolated: no tools, no persistence, stopped after use", %{
      config: config
    } do
      messages = [user("hello"), assistant([{:text, "Hi"}]), user("Summarize.")]
      response = Route.stream(request(messages, purpose: :summary, tools: []), config)

      cc = started()
      assert cc.opts[:launch][:persist_session] == false
      assert cc.opts[:session_key] =~ "isolated-"
      assert user_text(written(cc)) =~ "<transcript>"

      push(cc, [system_init() | text_reply("Summary")])
      assert [{:text, "Summary"}, {:usage, _}, {:finish, :stop}] = events!(response)

      ref = cc.ref
      assert_receive {:scripted_stopped, ^ref, _reason}
      assert Registry.select(config.registry, [{{:_, :"$1", :_}, [], [:"$1"]}]) == []
    end

    test "after a cancelled turn the next request starts fresh", %{config: config} do
      {_events, first, _line} = first_turn(config, [user("hello")], text_reply("Hi"))

      messages = [user("hello"), assistant([{:text, "Hi"}]), user("long task")]
      {:ok, %Response{cancel: cancel}} = Route.stream(request(messages), config)
      assert user_text(written(first)) == "long task"
      push(first, system_init())
      assert :ok = cancel.()
      assert %{"request" => %{"subtype" => "interrupt"}} = written(first)

      # Claude Code ends the interrupted turn, so the session is idle again and could be continued.
      push(first, %{"type" => "result", "subtype" => "success", "is_error" => false})
      assert MingaClaudeBridge.Session.phase(first.session) == :idle

      # Minga keeps the stopped prompt without a reply and adds the next one.
      retry = messages ++ [user("try again")]
      _response = Route.stream(request(retry), config)

      first_ref = first.ref
      assert_receive {:scripted_stopped, ^first_ref, _reason}
      fresh = started()
      prompt = user_text(written(fresh))
      assert prompt =~ "<transcript>"
      assert prompt =~ "long task"
      assert String.ends_with?(prompt, "try again")
    end

    test "after an error finish a retry of the same messages starts fresh", %{config: config} do
      {_events, first, _line} = first_turn(config, [user("hello")], text_reply("Hi"))

      messages = [user("hello"), assistant([{:text, "Hi"}]), user("again")]
      response = Route.stream(request(messages), config)
      _prompt = written(first)

      push(first, [
        system_init(),
        %{
          "type" => "result",
          "subtype" => "success",
          "is_error" => true,
          "result" => "Overloaded"
        }
      ])

      assert [{:finish, {:error, {:claude_error, :success, "Overloaded"}}}] = events!(response)

      _retry = Route.stream(request(messages), config)
      first_ref = first.ref
      assert_receive {:scripted_stopped, ^first_ref, _reason}
      fresh = started()
      assert user_text(written(fresh)) =~ "<transcript>"
    end

    test "a dead session is replaced by the next request", %{config: config} do
      {_events, old, _line} = first_turn(config, [user("hello")], text_reply("Hi"))
      Scripted.exit(old.session, old.ref, 1)

      messages = [user("hello"), assistant([{:text, "Hi"}]), user("again")]
      _response = Route.stream(request(messages), config)
      fresh = started()
      assert fresh.session != old.session
    end
  end

  describe "rate limits" do
    test "a rejected limit reports the route unavailable, an allowed one ready again", %{
      config: config
    } do
      response = Route.stream(request([user("hello")]), config)
      cc = started()
      _prompt = written(cc)

      rejected = %{
        "type" => "rate_limit_event",
        "rate_limit_info" => %{
          "status" => "rejected",
          "resetsAt" => 1_900_000_000,
          "rateLimitType" => "five_hour"
        }
      }

      limit_result = %{
        "type" => "result",
        "subtype" => "success",
        "is_error" => true,
        "result" => "Claude AI usage limit reached"
      }

      push(cc, [system_init(), rejected, limit_result])
      assert [{:finish, {:error, {:rate_limited, 1_900_000_000}} = finish}] = events!(response)
      assert_receive {:reported, :reporter, {:unavailable, :rate_limited, remedy}}
      assert remedy =~ "2030-03-17"

      {:error, reason} = finish
      assert {:rate_limited, _message} = Route.classify_error(reason)

      push(cc, %{"type" => "rate_limit_event", "rate_limit_info" => %{"status" => "allowed"}})
      assert_receive {:reported, :reporter, {:ready, _label}}
    end
  end

  describe "availability/3" do
    test "an active plan limit keeps the route unavailable until its reset time", %{
      config: config
    } do
      resets_at = System.os_time(:second) + 3_600

      Status.rate_limit(config.status, %MingaClaudeBridge.Wire.RateLimit{
        status: :rejected,
        resets_at: resets_at
      })

      assert {:unavailable, :rate_limited, remedy} =
               Route.availability("claude_bridge", nil, config)

      assert remedy =~ "resets at"
      refute_received {:scripted_started, _ref, _session, _opts}
    end
  end

  describe "classify_error/1" do
    test "every failure has its own kind and actionable message" do
      table = [
        {:claude_not_found, :unreachable, "Install it"},
        {{:transport_start_failed, :claude_not_found}, :unreachable, "Install it"},
        {:not_signed_in, :auth_failed, "claude auth login"},
        {{:rate_limited, nil}, :rate_limited, "Wait for it to reset"},
        {{:rate_limited, 1_900_000_000}, :rate_limited, "resets at 2030-03-17"},
        {{:claude_error, :success, "Claude AI usage limit reached"}, :rate_limited, "plan limit"},
        {{:claude_error, :success, "Overloaded"}, :provider_error, "Overloaded"},
        {{:claude_exited, 1}, :provider_error, "Send the message again"},
        {{:session_dead, {:claude_exited, 1}}, :provider_error, "Send the message again"},
        {{:unsupported_version, "2.0.0"}, :provider_error, "claude update"},
        {{:unexpected_tools, ["Bash"]}, :provider_error, "Stopped for safety"},
        {:missing_system_init, :provider_error, "Stopped for safety"},
        {{:forbidden_env, ["HOME"]}, :auth_failed, "HOME"},
        {:startup_timeout, :unreachable, "did not start in time"},
        {:interrupt_timeout, :provider_error, "did not stop"},
        {:something_else, :unknown, "CLAUDE_BRIDGE_DEBUG=1"}
      ]

      for {reason, kind, text} <- table do
        assert {^kind, message} = Route.classify_error(reason)
        assert message =~ text, "#{inspect(reason)}: #{message}"
      end

      messages =
        Enum.map(table, fn {reason, _kind, _text} -> elem(Route.classify_error(reason), 1) end)

      assert length(Enum.uniq(messages)) >= 12
    end
  end

  describe "models/1" do
    test "lists the aliases without starting Claude Code before any probe", %{config: config} do
      models = Route.models(transport: {Scripted, controller: self()}, status: config.status)

      assert Enum.map(models, & &1.id) == ["opus", "sonnet", "haiku"]
      assert Enum.all?(models, &(&1.cost == :subscription and &1.tools?))
      refute_received {:scripted_started, _ref, _session, _opts}
    end

    test "lists the models of the last probe", %{config: config} do
      Status.put_models(config.status, [%{"value" => "haiku", "displayName" => "Haiku 5.5"}])
      assert [%{id: "haiku", display_name: "Haiku 5.5"}] = Route.models(status: config.status)
    end
  end
end
