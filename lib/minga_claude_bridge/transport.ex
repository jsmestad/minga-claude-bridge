defmodule MingaClaudeBridge.Transport do
  @moduledoc """
  The byte channel between a `MingaClaudeBridge.Session` and one Claude Code process.

  A transport starts the process, writes stdin lines, and reports stdout lines and exit to its owner. It knows nothing about the stream-json protocol beyond line framing. The session owns all protocol decisions.

  ## Starting

  `c:start/1` receives a keyword list. The session always passes:

    * `:owner` - the pid that receives transport messages.
    * `:ref` - a reference the transport puts in every message, so the owner can ignore messages from a transport it already replaced.
    * `:launch` - a keyword list with the session's launch settings (`:model`, `:effort`, `:resume`). The transport turns them into CLI arguments.

  The session also passes the transport options it was started with, unchanged.

  ## Messages to the owner

  The transport sends `{:transport, ref, event}` where `event` is one of:

    * `{:line, binary}` - one complete stdout line without its newline. Framing (joining `{:noeol, _}` fragments, the line size cap) happens inside the transport, for example with `MingaClaudeBridge.LineBuffer`.
    * `{:exit, status}` - the process exited. `status` is the exit status, or another term when the status is not known. No message follows it.
    * `{:error, reason}` - the transport failed and the process cannot be used anymore, for example `:line_too_long`. The transport stops the process itself. No message follows it.

  Lines carry conversation content. A transport must not log them.

  ## Stopping

  `c:stop/2` stops the process and releases its resources. It must be safe to call after the process exited, and it must return within a bounded time. After `c:stop/2` returns, the transport sends no more messages.

  ## Linked processes

  A transport may link a helper process to the owner. The session traps exits, and it treats an `:EXIT` with a reason other than `:normal` from any linked process as a transport failure.
  """

  @typedoc "An opaque value the transport returns from `c:start/1` and receives back in its other callbacks."
  @type handle :: term()

  @type event :: {:line, binary()} | {:exit, term()} | {:error, term()}

  @typedoc "The message the owner receives."
  @type message :: {:transport, reference(), event()}

  @doc "Starts the Claude Code process. See the module documentation for the options."
  @callback start(opts :: keyword()) :: {:ok, handle()} | {:error, term()}

  @doc "Writes one line to stdin. `line` must end with a newline."
  @callback send_line(handle(), line :: iodata()) :: :ok | {:error, term()}

  @doc "Stops the process. Safe to call more than once and after the process exited."
  @callback stop(handle(), reason :: term()) :: :ok
end
