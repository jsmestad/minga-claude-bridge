defmodule MingaClaudeBridge.HistoryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MingaClaudeBridge.History

  @fingerprint %{system_prompt: "be brief", tools: [%{name: "read"}], model: "claude-opus"}

  defp user(text), do: %{role: :user, digest_input: {:text, text}}
  defp assistant(text), do: %{role: :assistant, digest_input: {:text, text}}
  defp tool(id), do: %{role: :tool, digest_input: {:result, id, "ok"}}

  @seen_entries [
    %{role: :user, digest_input: {:text, "hi"}},
    %{role: :assistant, digest_input: {:text, "hello"}}
  ]

  defp seen(entries \\ @seen_entries, fingerprint \\ @fingerprint),
    do: History.record(History.new(), %{entries: entries, fingerprint: fingerprint})

  defp turn(entries, fingerprint \\ @fingerprint),
    do: %{purpose: :turn, entries: entries, fingerprint: fingerprint}

  describe "compare/2" do
    cases = [
      {"a new user message continues", quote(do: @seen_entries ++ [user("next")]),
       quote(do: {:continue, [user("next")]})},
      {"tool results continue", quote(do: @seen_entries ++ [tool("a"), tool("b")]),
       quote(do: {:continue, [tool("a"), tool("b")]})},
      {"an edited earlier message diverges",
       quote(do: [user("edited"), assistant("hello"), user("next")]),
       quote(do: {:fresh, :diverged})},
      {"a shorter history diverges", quote(do: [user("hi")]), quote(do: {:fresh, :diverged})},
      {"an empty history diverges", quote(do: []), quote(do: {:fresh, :diverged})},
      {"a role change at the same content diverges",
       quote(do: [user("hi"), user("hello"), user("next")]), quote(do: {:fresh, :diverged})},
      {"an identical history has nothing to answer", quote(do: @seen_entries),
       quote(do: {:fresh, :no_new_entries})},
      {"an appended assistant message is not ours",
       quote(do: @seen_entries ++ [assistant("injected"), user("next")]),
       quote(do: {:fresh, :assistant_appended})},
      {"an assistant message after tool results is not ours",
       quote(do: @seen_entries ++ [tool("a"), assistant("x")]),
       quote(do: {:fresh, :assistant_appended})}
    ]

    for {label, entries, expected} <- cases do
      test label do
        assert History.compare(seen(), turn(unquote(entries))) == unquote(expected)
      end
    end

    for {field, value} <- [system_prompt: "be verbose", tools: [], model: "claude-sonnet"] do
      test "a changed #{field} changes the fingerprint" do
        fingerprint = Map.put(@fingerprint, unquote(field), unquote(Macro.escape(value)))

        assert History.compare(seen(), turn(@seen_entries ++ [user("next")], fingerprint)) ==
                 {:fresh, :fingerprint_changed}
      end
    end

    test "a session that has seen nothing starts fresh" do
      assert History.compare(History.new(), turn([user("hi")])) == {:fresh, :empty_session}
      assert History.compare(seen([]), turn([user("hi")])) == {:fresh, :empty_session}
    end

    for purpose <- [:summary, :title] do
      test "#{purpose} requests are isolated in every state" do
        request = %{purpose: unquote(purpose), entries: [user("x")], fingerprint: @fingerprint}
        assert History.compare(History.new(), request) == :isolated
        assert History.compare(seen(), request) == :isolated
      end
    end
  end

  describe "record/2" do
    test "advances the seen history so the next turn continues from it" do
      after_tools = @seen_entries ++ [user("run it"), assistant("calling tool")]
      state = seen(after_tools)

      assert History.seen_count(state) == 4

      assert History.compare(state, turn(after_tools ++ [tool("t1")])) ==
               {:continue, [tool("t1")]}

      assert History.compare(state, turn(@seen_entries ++ [user("next")])) == {:fresh, :diverged}
    end

    test "installs the new fingerprint" do
      changed = %{@fingerprint | model: "claude-sonnet"}
      state = seen(@seen_entries, changed)

      assert History.compare(state, turn(@seen_entries ++ [user("x")], changed)) ==
               {:continue, [user("x")]}
    end

    test "stores digests, not content" do
      secret = "secret-content-#{System.unique_integer()}"
      state = seen([user(secret)], %{@fingerprint | system_prompt: secret})
      refute :erlang.term_to_binary(state) =~ secret
    end
  end

  defp content, do: one_of([string(:printable, max_length: 12), integer()])

  defp entry(roles) do
    gen all(role <- member_of(roles), input <- content()) do
      %{role: role, digest_input: input}
    end
  end

  property "a prefix extension made only of user and tool entries continues" do
    check all(
            prior <- list_of(entry([:user, :assistant, :tool]), min_length: 1, max_length: 8),
            added <- list_of(entry([:user, :tool]), min_length: 1, max_length: 5)
          ) do
      assert History.compare(seen(prior), turn(prior ++ added)) == {:continue, added}
    end
  end

  property "changing any earlier entry diverges" do
    check all(
            prior <- list_of(entry([:user, :assistant, :tool]), min_length: 1, max_length: 8),
            index <- integer(0..(length(prior) - 1)),
            added <- list_of(entry([:user, :tool]), max_length: 3)
          ) do
      mutated =
        List.update_at(prior, index, fn entry ->
          %{entry | digest_input: {:mutated, entry.digest_input}}
        end)

      assert History.compare(seen(prior), turn(mutated ++ added)) == {:fresh, :diverged}
    end
  end
end
