# Changelog

All notable changes to `minga_claude_bridge` are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- Claude Code no longer looks signed out when Minga starts without `USER` or `LOGNAME`. The bridge fills a missing value from the operating-system user; a value in `routes.claude_bridge.env` still wins.

## [0.1.0] - 2026-11-21

The first release. It runs the Claude models of your Claude subscription inside Minga's agent through the `claude` CLI you already have installed and signed in. Minga keeps running the agent: its tools, approvals, and transcript.

Requires Minga with model routes and plan usage (jsmestad/minga#3734 and #3756), and Claude Code 2.1.330 or newer.

### Added

- **Protocol codec** (#6): decodes and encodes Claude Code's stream-json frames: system init, stream events, assistant messages, results, rate-limit events, and control requests and responses. Unknown frame types decode to a value instead of failing.
- **Tool routing** (#7): serves Minga's tools to Claude Code as the in-process MCP server `minga`, pairs each tool call with its `tool_use` id, flattens schemas Claude Code would drop, and compares history to decide whether a conversation can continue its Claude Code session.
- **Session process** (#8): one process per conversation drives a pure state machine. It suspends a turn on tool calls, resumes with Minga's tool results, aborts within a bounded time, and stops Claude Code before the model's first output when it reports any tool other than Minga's.
- **Real `claude` process** (#9): starts the resolved `claude` binary without a shell, in an empty private working directory, with built-in tools, hooks, plugins, skills, slash commands, and other MCP servers turned off. Strips provider keys and parent-session variables from its environment, applies the `routes.claude_bridge.env` credential entry, and never leaves a `claude` process behind.
- **Minga model route** (#10): the extension registers the `claude_bridge` route. `/model` lists Claude's models with readiness ("Ready · Claude Pro") and actionable messages for a missing CLI, a signed-out CLI, an old CLI, and a reached plan limit. Follow-up turns continue the same Claude Code session; edits, branches, and model changes start a fresh one with the earlier history.
- **Context windows and plan usage** (#12): measures each model's real context window and reads plan usage from Claude Code in the background, reports five-hour and seven-day plan windows to Minga, and streams thinking with adaptive thinking.

### Fixed

- A `get_usage` answer without windows now reports an empty list, so Minga clears stale plan windows.
- A rate-limit event's utilization now updates its plan window.
- The usage refresh after a turn now runs under the bridge's task supervisor and stops with the extension.
- A plan label learned from usage now only updates the readiness of the credential it was read with.

[0.1.0]: https://hex.pm/packages/minga_claude_bridge/0.1.0
