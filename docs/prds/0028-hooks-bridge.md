# PRD — Lifecycle hooks (Claude Code `hooks.json` bridge)

## Status

Implemented. `src/hooks/` owns config loading, matching and hook execution;
the agent loop wires all five lifecycle points, and a bounded stdin process
primitive now lives in
`src/sandbox/host.zig` beside `execUnderPolicy`. Gated by `[hooks]` in
`config.toml`, `enabled = false` by default. Surfaced by researching
[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)'s
`packages/hooks/` family (`dsh-hook-protocol`, `dsh-hooks-claude-code`,
`dsh-hooks-codex`), whose exit-code/JSON-stdout wire contract this PRD adopts
rather than inventing a new one.

## Problem

Clanker has no way for a user to hook into the agent loop from outside the
binary. `docs/reviews/webui.md`'s Kimi Code harness parity table already
names the gap in writing: "lifecycle hooks (partial)" — partial only in the
sense that `confirm_writes`/`plan_mode` cover *ask a human*, never *run a
deterministic check*. A user coming from Claude Code or Codex commonly has an
existing `hooks.json`: a linter that runs before every write, a notification
script, a policy check that blocks a dangerous command. None of that
transfers to clanker today; adopting it means rewriting every hook as a
clanker-specific mechanism, which is exactly the migration cost a bridge
exists to avoid.

DSH's `packages/hooks/` is a clean reference for the wire contract: a
dialect-neutral core (`dsh-hook-protocol`) that owns matcher validation, the
exit-code/stdout decode, and most-restrictive merging across several hooks on
one point, with a per-dialect bridge (`dsh-hooks-claude-code`,
`dsh-hooks-codex`) owning only the event-payload shape and env-variable
substitution that differ between the two. That split — most of the work is
dialect-neutral, only payload shape and a couple of env vars differ — is
worth copying even though clanker's v1 supports only the Claude Code dialect.

## Goals

1. `[hooks]` config: `enabled = false` (default), `config_path` naming a
   `hooks.json` file (or a settings file with a `hooks` key), loaded once at
   agent construction — not watched, not hot-reloaded.
2. Support four extension points in v1, each mapped onto an existing point in
   `Agent`'s loop:
   - `PreToolUse` — before a tool call dispatches; can deny.
   - `PostToolUse` — after a tool call returns; can inject context or block
     with feedback.
   - `UserPromptSubmit` — before a turn's first model request; can inject
     context or reject the turn outright.
   - `Stop` — at the point a turn would otherwise end; a blocking hook forces
     one more step, capped by the run's existing `max_iterations`.
   - `SessionStart` — once, when the agent is constructed; can inject initial
     context.
3. `matcher` on `PreToolUse`/`PostToolUse` selects tool names: a pure
   `[A-Za-z0-9_|]+` pattern is a literal-or-pipe-alternation match, anything
   else is a regex — the same two-mode contract Claude Code's own hooks use,
   so an imported `hooks.json` keeps its existing meaning.
4. A hook command runs through `host.execUnderPolicy` — the same argv-level
   gate (`execDenial`) the REPL's `!cmd` escape and `ck_exec` already share —
   with the event's JSON payload on stdin and a wall-clock timeout
   (`hooks.default_timeout_ms`, default 60000, or a per-hook `timeout`
   field in the hooks.json entry, in seconds).
5. Exit code 2 blocks and treats stderr as the reason; JSON on stdout with a
   `decision` field and/or `additionalContext` is parsed per Claude Code's
   existing output contract, so a hook script written for Claude Code needs
   no changes to run under clanker.
6. Multiple hooks matching one point run serially, in `hooks.json` config
   order, and fold most-restrictively: `deny` beats `ask` beats `allow`.

## Non-goals

- **The Codex dialect.** `config_path` names one file in the Claude Code
  shape. Codex's matcher-is-always-regex variant and its separate config
  format are real, documented differences (DSH ships both as separate
  bridge packages precisely because they differ) and are out of scope until
  there is a concrete user asking for it.
- **The other ~23 Claude Code hook events** (`Setup`, `Notification`,
  `PreCompact`, `SessionEnd`, and the rest). DSH's own Claude Code bridge
  does not support them either as of this writing; this PRD covers the five
  points named in Goals #2, which are the ones with a clear, already-existing
  extension point in clanker's loop.
- **`updatedInput` (tool-call argument rewriting from a hook).** DSH parses
  and warns on this field rather than honoring it, calling it a deferred
  consistency-design problem. Clanker inherits that judgment rather than
  re-deriving it: rewriting a tool call's arguments from a hook raises the
  same "what does the session log now mean" question DSH left open.
- **Live reload of `hooks.json`.** Loaded once at agent construction, same
  simplification DSH's own bridge makes ("process-level, parsed once").
- **`http`/`mcp_tool`/`prompt`/`agent` handler kinds.** Only shell-form
  `type: "command"` hooks run; other handler kinds are parsed and skipped
  with a warning, matching DSH.

## Design

**Where it plugs into the loop.** `Agent.executeCalls` (`src/agent/loop.zig`,
~2298–2328) already gates every tool call through `plan_mode` (unconditional
refusal of write-capable tools) and then `confirm_fn` (human allow/deny) at
one call site, in that order, with a comment explaining why: "the same
predicate as the confirm gate, so what a viewer is asked about and what plan
mode refuses can never drift apart." A `PreToolUse` hook check is a third
gate at the same site, and the order matters: **plan mode, then hooks, then
`confirm_fn`.** Plan mode is an unconditional product rule that must not be
second-guessed by a hook; a hook is a deterministic policy check that should
run before bothering a human, since asking a person to approve something a
script would have refused anyway wastes their attention. `PostToolUse` hooks
run immediately after a call's result is computed, contributing
`additionalContext`-shaped text the same way todos/`on_tool_result` already
append synthetic content into the transcript. `UserPromptSubmit` hooks run
where the loop claims the next turn's queued input, before the request is
assembled. `Stop` hooks run at the point `Agent.run` would otherwise end a
turn (no more tools owed, no queued input); a blocking `Stop` hook injects
its reason and forces one more step, bounded by the existing
`agent.max_iterations` so a hook that always blocks cannot loop the run
forever — the cap that already exists is the backstop, not a new one.

**Payload and environment.** JSON stdin carries `session_id`, `cwd`,
`tool_name` + `tool_input` (`PreToolUse`), `tool_response` flattened to text
(`PostToolUse`), and `prompt` (`UserPromptSubmit`). The child process gets
the same filtered/scrubbed environment `execEnvironment` already builds for
`!cmd`-escape and `ck_exec` calls (so a hook cannot read `*_API_KEY` values
the exec gate would not otherwise expose), plus `CLAUDE_PROJECT_DIR` set to
the session's working directory for compatibility with existing scripts that
read it.

**A hook runs no more permissively than clanker's exec gate already allows.**
Reusing `execUnderPolicy`/`execDenial` (the same functions the REPL's `!cmd`
and `ck_exec` already flow through, per the shared test at
`src/sandbox/host.zig:4673`) means a hook command is bounded by the same
allowlist derivation `!cmd` already uses: the union of every registered
tool's manifest `exec_allow`, widened only by `agent.repl_exec_allow`. A
`hooks.json` that shells out to something outside that set fails the same
way an unrecognized `!cmd` invocation does today — loudly, not silently.

**Timeout is new plumbing, named up front.** Nothing in `host.zig` enforces
a wall-clock deadline on a spawned child today; `child.wait(sb.io)` blocks
until the process exits. A hook needs one (an unbounded lint script must not
hang the turn), so this PRD adds a small wait-with-timeout: a watchdog that
kills the child's process group after the configured deadline if `wait` has
not returned. This is genuinely new code, not a reuse of something that
already exists, and is called out as the one non-trivial primitive this PRD
requires.

**Failure containment.** An unreadable or unparsable `config_path` (bad
JSON, an invalid matcher regex) logs a warning naming the file and the
offending pattern, and hooks are disabled for the run — never a boot
failure. A typo'd hooks path must not take the agent down, the same
principle the plugin manifest validator already applies to a malformed
`*.tool.json`.

**Dependencies.** None hard-blocking: rides `execUnderPolicy`/`execDenial`
(shipped), `confirm_fn`'s call site pattern (shipped), and `max_iterations`
(shipped). No other Draft PRD blocks starting.

**Implementation.**

1. `src/hooks/config.zig` — `hooks.json` schema parsing and matcher engine
   (literal/pipe/regex), unit-tested against literal cases pulled from real
   Claude Code hook configs.
2. Wait-with-timeout primitive in `src/sandbox/host.zig`, beside
   `execUnderPolicy`, unit-tested against a deliberately slow test binary.
3. `PreToolUse`/`PostToolUse` wiring at the `Agent.executeCalls` gate.
4. `UserPromptSubmit`, `SessionStart`, `Stop` wiring.
5. End-to-end smoke test: a real `hooks.json` fixture exercising deny,
   allow-with-context, and a blocking `Stop` hook, run through `clanker run`.

## Failure modes

| Condition | Behaviour |
|---|---|
| `hooks.enabled = false` (default) | No-op; no config read |
| `config_path` missing or unreadable | Warn naming the path; hooks disabled for the run |
| Invalid JSON or an invalid matcher regex | Warn naming the file and pattern; hooks disabled for the run |
| Hook exits 2 | `PreToolUse` denies the call (stderr is the reason); `PostToolUse` blocks with feedback |
| Hook exceeds its timeout | Killed; treated as a non-blocking error, the call/turn proceeds |
| Hook writes non-JSON stdout | Ignored — no context, no decision, exit code alone still applies |
| A blocking `Stop` hook never stops blocking | Capped by `agent.max_iterations`; forced continuation stops once the run's existing budget is spent |
| A command outside the derived `exec_allow` union | Refused by `execDenial`, same error shape `!cmd` already gives |

## Acceptance criteria

- [x] `hooks.enabled = false` by default; no behavior change with it off.
- [x] A `PreToolUse` hook exiting 2 denies the matched tool call before
      dispatch, with the hook's stderr as the model-visible reason.
- [x] A `PostToolUse` hook's `additionalContext` appears as injected context
      in the next request.
- [x] A blocking `UserPromptSubmit` hook rejects a turn before any model
      request is sent for it.
- [x] A blocking `Stop` hook forces at least one more step, and stops firing
      once `max_iterations` is reached.
- [x] `SessionStart` context is injected exactly once per agent construction.
- [x] Matcher literal/pipe/regex modes are unit-tested against real Claude
      Code hook config examples.
- [x] Hook commands are refused by the same `execDenial` gate `!cmd` uses;
      a unit test pins that a hook cannot run a command outside the derived
      allowlist.
- [x] A malformed `hooks.json` disables hooks for the run and logs a warning
      naming the file; the agent still runs.

## Open questions / future work

- **Codex dialect.** Real future work, not started here; needs its own
  matcher-mode and payload-shape research once a concrete user asks for it.
- **`updatedInput`.** Left unresolved on purpose, following DSH's own
  judgment that it is a cross-cutting design problem, not a small addition.
- **Per-session hook config.** `config_path` is process-level in v1 (one
  file for every session in one `clanker` invocation), the same limitation
  DSH's own Claude Code bridge carries and has not yet resolved
  (`TODO(per-session-hook-config)` in its own source). Worth revisiting if
  clanker's session model ever wants per-project hook files resolved from a
  session's own `cwd`.
