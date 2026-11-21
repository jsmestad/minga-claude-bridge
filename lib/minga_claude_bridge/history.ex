defmodule MingaClaudeBridge.History do
  @moduledoc """
  Decides whether a Minga request continues the live Claude Code session or must start a fresh one.

  A Claude Code session has already seen part of the conversation. A follow-up request can continue it only when the request's history starts with exactly what the session saw and adds only input Claude Code has not seen yet: tool results or new user messages. Anything else (an edit, a branch, a reset, a compaction, a changed system prompt, tool set, or model) needs a fresh session that imports the request's history.

  ## Inputs

  The route layer normalizes a Minga request into a `t:request/0`:

    * `purpose` - `:turn` for a normal agent turn. `:summary` and `:title` requests are side queries; `compare/2` returns `:isolated` for them and they never touch the session.
    * `entries` - the conversation as a list of `t:entry/0`, oldest first, without the system prompt. Each entry is `%{role: :user | :assistant | :tool, digest_input: term()}`. `digest_input` is any term that holds everything about the message that Claude Code would see: text, images, tool calls with ids and arguments, tool results with ids, content and error flag. Metadata that Claude Code does not see (timestamps, usage, local ids) must be left out, or equal messages will not compare equal. The same message must produce the same `digest_input` every time, including the assistant messages the bridge itself built from a streamed reply.
    * `fingerprint` - `%{system_prompt: term(), tools: term(), model: String.t()}`. `tools` holds the tool declarations with their schemas.

  ## State

  `t:t/0` holds only SHA-256 digests: one per entry the session has seen, in order, and one for the fingerprint. Each digest is `:crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))`. No message content is stored.

  ## Rules

  `compare/2` checks, in this order:

    1. `purpose` is not `:turn`: `:isolated`.
    2. The session has seen no entries: `{:fresh, :empty_session}`.
    3. The fingerprint digest differs: `{:fresh, :fingerprint_changed}`.
    4. The request has fewer entries than the session saw, or any seen position has a different digest: `{:fresh, :diverged}`.
    5. The request adds no entries: `{:fresh, :no_new_entries}`. Claude Code cannot produce another reply to input it already answered, so a regenerate starts fresh.
    6. An added entry has role `:assistant`: `{:fresh, :assistant_appended}`. The session did not produce that reply, so Claude Code's transcript would not contain it.
    7. Otherwise: `{:continue, new_entries}`, where `new_entries` are the added user and tool entries, in order.

  `record/2` installs the conversation a completed turn leaves behind: the request's entries followed by the assistant entries the session produced, and the request's fingerprint. Record after every completed turn, including a turn that stopped for tool calls, and after a fresh session imports history. Do not record isolated requests.
  """

  @type role :: :user | :assistant | :tool

  @typedoc "One normalized conversation message. See the module documentation for what `digest_input` must hold."
  @type entry :: %{role: role(), digest_input: term()}

  @type fingerprint :: %{system_prompt: term(), tools: term(), model: String.t()}

  @type purpose :: :turn | :summary | :title

  @type request :: %{purpose: purpose(), entries: [entry()], fingerprint: fingerprint()}

  @type fresh_reason ::
          :empty_session
          | :fingerprint_changed
          | :diverged
          | :no_new_entries
          | :assistant_appended

  @type comparison :: {:continue, [entry()]} | {:fresh, fresh_reason()} | :isolated

  @typedoc "A SHA-256 digest."
  @type digest :: <<_::256>>

  @opaque t :: %__MODULE__{digests: [digest()], fingerprint: digest() | nil}

  @enforce_keys [:digests, :fingerprint]
  defstruct [:digests, :fingerprint]

  @doc "Returns the state of a session that has seen nothing."
  @spec new() :: t()
  def new, do: %__MODULE__{digests: [], fingerprint: nil}

  @doc "Compares a request against what the session has seen. See the module documentation for the rules."
  @spec compare(t(), request()) :: comparison()
  def compare(_seen, %{purpose: purpose}) when purpose in [:summary, :title], do: :isolated

  def compare(%__MODULE__{digests: []}, %{purpose: :turn}), do: {:fresh, :empty_session}

  def compare(%__MODULE__{} = seen, %{purpose: :turn, entries: entries, fingerprint: fingerprint}) do
    if fingerprint_digest(fingerprint) == seen.fingerprint do
      compare_entries(seen.digests, entries)
    else
      {:fresh, :fingerprint_changed}
    end
  end

  @doc "Returns the state after a completed turn left `conversation` behind."
  @spec record(t(), %{entries: [entry()], fingerprint: fingerprint()}) :: t()
  def record(%__MODULE__{}, %{entries: entries, fingerprint: fingerprint}) do
    %__MODULE__{
      digests: Enum.map(entries, &digest/1),
      fingerprint: fingerprint_digest(fingerprint)
    }
  end

  @doc "Returns the number of entries the session has seen."
  @spec seen_count(t()) :: non_neg_integer()
  def seen_count(%__MODULE__{digests: digests}), do: length(digests)

  defp compare_entries([], []), do: {:fresh, :no_new_entries}
  defp compare_entries([], added), do: classify_added(added)
  defp compare_entries([_seen | _rest], []), do: {:fresh, :diverged}

  defp compare_entries([seen | seen_rest], [entry | rest]) do
    if digest(entry) == seen, do: compare_entries(seen_rest, rest), else: {:fresh, :diverged}
  end

  defp classify_added(added) do
    if Enum.any?(added, &(&1.role == :assistant)) do
      {:fresh, :assistant_appended}
    else
      {:continue, added}
    end
  end

  defp digest(%{role: role, digest_input: input}) when role in [:user, :assistant, :tool],
    do: hash({role, input})

  defp fingerprint_digest(%{system_prompt: system_prompt, tools: tools, model: model}),
    do: hash({:fingerprint, system_prompt, tools, model})

  defp hash(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
end
