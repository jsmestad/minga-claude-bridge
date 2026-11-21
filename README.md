# minga-claude-bridge

Use the Claude models in your Claude subscription inside Minga's agent. The bridge drives the `claude` CLI you already have installed and signed in. Minga keeps running the agent: its tools, approvals, and transcript. Claude Code only writes the model's replies.

It is the Minga counterpart of [pi-claude-bridge](https://github.com/elidickinson/pi-claude-bridge).

## Install

You need Claude Code 2.1.330 or newer, and a Minga build with model routes (jsmestad/minga#3734).

1. Install Claude Code from <https://claude.com/claude-code> and sign in once in a terminal:

   ```sh
   claude auth login
   ```

2. Add the extension to your Minga config:

   ```elixir
   extension :claude_bridge, git: "https://github.com/jsmestad/minga-claude-bridge"
   ```

3. Restart Minga and open `/model`. The Claude models appear under **Claude (subscription)** with your plan, for example "Claude Pro". Select one, or use `/model claude_bridge:sonnet`.

If something is missing, the `/model` row says what to do: install Claude Code, run `claude auth login`, or update Claude Code with `claude update`.

## Models and effort

The model list comes from Claude Code itself, so it matches what your plan offers. Registering the route never waits for Claude Code: until the bridge has checked Claude Code once (when `/model` checks the route's readiness), and Minga refreshes the route's models, the list shows the `opus`, `sonnet`, and `haiku` aliases.

The thinking level you pick in Minga becomes Claude Code's `--effort`: `low`, `medium`, `high`, `xhigh`, or `max`. Models without effort support show a single `default` level.

## How a conversation maps to Claude Code

Each Minga conversation gets one long-running Claude Code process. Follow-up messages and tool results continue that process, so Claude keeps its prompt cache.

Sometimes Claude Code cannot follow a change: you edit or branch the history, reset or compact it, or change the model, effort, instructions, or tools. Then the bridge starts a fresh Claude Code process and carries the earlier conversation over as one transcript message. That import is lossy: earlier thinking and images are left out, and earlier tool calls appear as text. Summary and title requests run in a separate short-lived process with no tools.

Stopping a turn keeps the partial reply and ends that Claude Code process at once. The next message then starts a fresh process the same way, because the stopped prompt is already in the old process's history.

## Limits

Requests through the bridge count against your Claude plan, exactly like using Claude Code yourself. When you reach a plan limit, the turn fails with "Your Claude plan limit is reached. It resets at …", and `/model` shows the route as unavailable until that reset time.

## What the bridge turns off in Claude Code

During a bridge turn, Claude Code acts only as the model. The bridge starts it with:

- no built-in tools (`--tools ""`), and only Minga's tools allowed (`--allowedTools mcp__minga__*`);
- no MCP servers from `~/.claude.json` or `.mcp.json` (`--strict-mcp-config`);
- no settings files, so no hooks or plugins (`--setting-sources ""`);
- no skills or slash commands (`--disable-slash-commands`);
- no auto-compaction, no claude.ai MCP servers, no tool search, and no non-essential network traffic;
- an empty private working directory, so it finds no project `CLAUDE.md`.

If Claude Code reports any tool other than Minga's when a turn starts, the bridge stops it before the model's first output reaches Minga, and the turn fails with a safety message. Minga's approvals apply to every tool call, and a denied tool reaches Claude as an error.

## Credentials and environment

The bridge uses Claude Code's own login. It never reads or copies it.

The bridge removes variables that would send Claude Code somewhere else: everything starting with `ANTHROPIC_`, `AWS_`, or `NODE_`, the Bedrock, Vertex, and Foundry switches, a parent Claude Code session's variables, and Minga's own provider keys.

To give bridge requests their own environment, add a `routes.claude_bridge.env` entry to `~/.config/minga/credentials.json`. An empty value removes a variable.

```json
{
  "routes": {
    "claude_bridge": {
      "env": {
        "CLAUDE_CODE_OAUTH_TOKEN": "token from `claude setup-token`",
        "HTTPS_PROXY": "http://proxy.example.com:8080",
        "ANTHROPIC_API_KEY": ""
      }
    }
  }
}
```

- `CLAUDE_CODE_OAUTH_TOKEN` signs Claude Code in with a long-lived token from `claude setup-token`, for example where you cannot run `claude auth login`.
- A proxy variable applies only to bridge requests.
- An empty `ANTHROPIC_API_KEY` documents that an exported API key must never reach Claude Code. The bridge removes it anyway.

`HOME`, `CLAUDE_CONFIG_DIR`, and `USERPROFILE` cannot be set there, because Claude Code must keep using your own session files.

## Debug logging

Normally the bridge logs only the types of the messages it exchanges with Claude Code, never their content.

Start Minga with `CLAUDE_BRIDGE_DEBUG=1` to write the raw protocol of each Claude Code process to a private directory (mode 0700, files 0600) under your temporary directory, in `minga-claude-bridge-<uid>/debug/`. These files contain your conversation. Delete them when you are done.

## Known limits

- The bridge cannot turn off company-managed Claude Code settings or the hooks they define.
- Changing instructions or tools forces a fresh Claude Code process and a prompt-cache miss.
- Running the same conversation from two Minga processes at once is unsupported.
- A conversation carried over to a fresh process loses earlier thinking and images.

## Account terms

Anthropic's [Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview) says: "Unless previously approved, Anthropic does not allow third party developers to offer claude.ai login or rate limits for their products, including agents built on the Claude Agent SDK." Anthropic's support notes (June and October 2026) say Agent SDK and `claude -p` usage draws from subscription limits; see [Use the Claude Agent SDK with your Claude plan](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan).

The bridge never reads or copies your Claude login. You sign in to your own Claude Code, and the bridge runs that Claude Code on your machine. Decide whether this use fits your plan's terms.

## License

MIT
