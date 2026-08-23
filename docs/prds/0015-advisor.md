# PRD — Advisor

## Status

Shipped. Off by default (`advisor.enabled = false`). After a completed
tool batch the loop calls `advisor.review`, which fail-opens on any
error. A `note`/`concern` is injected as a one-turn system block;
`blocker` asks via `ask_fn` (proceed/abort) and otherwise injects as a
concern. Sources of truth: `src/agent/advisor.zig`, `src/agent/loop.zig`
(`reviewTurn`), `src/config.zig` (`Advisor`).

`advisor.model` is honored since 2026-08-24: `review` shallow-copies the
resolved provider and reassigns `default_model`, the same shape
`thinking.resolveClassifier` uses. Before that the key parsed, validated and
documented cleanly while nothing read it, so every enabled-advisor turn billed
the provider's `default_model`
([bug](../reports/bugs/2026-08-23-advisor-model-never-read.md)). The one-turn
injection is also removed with a `defer` now, so a provider error, a TTSR retry
or a mid-stream Ctrl-C cannot leave the note sitting where the loop requires the
system prompt
([bug](../reports/bugs/2026-08-23-advisor-block-leaks-into-message-zero.md)).

## Problem

The main agent loop runs a single model's think-act-observe cycle with no
external check on the direction of reasoning. When the model pursues a flawed
approach (wrong tool, bad assumption, risky command), the only correction
mechanism is a human reading the REPL or web UI and intervening manually.
Neither the loop nor any host function currently sends a turn's output to a
second model for review before the next turn starts.

omp's advisor pairs a second model to the main agent in a read-only role. After
each turn it reads the transcript and emits a severity-tagged note that the main
agent sees at the top of its next turn. The main agent can course-correct before
taking an action, not after.

## Goals

1. After each main-agent turn completes (after `on_tool_result` fires), launch a
   concurrent `client.chatWithTimeout` call on a configurable provider/model with the turn
   transcript and a fixed advisor system prompt.
2. The advisor returns a structured JSON response: `{"severity": "note" |
   "concern" | "blocker", "text": "..."}`.
3. At `severity = "blocker"`, the agent loop pauses before the next turn and
   presents the blocker text via the existing `ask_fn` path. The human can
   proceed or abort. Without a channel (headless run), the blocker is
   downgraded to a `concern` and the turn proceeds, with the blocker injected
   into context.
4. At `severity = "note"` or `"concern"`, the advisor text is injected into the
   system context for the next think call only (one turn), as a fenced block
   (`[advisor: concern] ...`). It is not added to the user message or to
   `session.messages`. After that think call, the injection is removed.
5. Advisor is disabled by default. Enabled via `advisor.enabled = true` in
   `config.toml`. Fails open (disabled) if the advisor model call errors.
6. Advisor runs on its own context (no tool access, no shared session history
   with the main agent). It receives only the text of the last completed turn:
   the user message, the assistant's response, any tool results, and the tool
   calls made — with fs/exec tool arguments redacted to `<redacted>` (to avoid
   leaking sensitive fs paths to a different provider).

## Non-goals

- Not a gate. The advisor cannot prevent a tool call from executing; it can only
  inform the next turn. A blocker is a request for human confirmation, not a
  hard refusal at the tool boundary. Hard refusals belong to `confirm_writes` and
  the sandbox descriptor.
- Not a second agent with tools. The advisor makes one bounded completion
  (`client.chatWithTimeout`), not a `ck_subagent` call. It cannot read files, run commands, or issue
  corrections as tool calls.
- Not always-on telemetry. The advisor is session-scoped. Advisory notes are
  only visible in the current run's transcript. Token accounting may record an
  optional `advisor_tokens` field on the stats `Record`; there is no dedicated
  `GET /api/advisor` endpoint in v1.
- Not a code reviewer. The advisor sees the turn summary, not the full file
  contents of every read. Deep code review belongs in Arena (PRD 0008) or a
  dedicated subagent.
- Not a mid-stream interceptor. The advisor fires after a completed turn and
  only annotates the next one; TTSR (PRD 0013) fires during a stream and aborts
  it. Different interception points, deliberately.
- Not `advisor.skip_tools` in v1. Skipping the advisor when a turn only used
  read-only tools is deferred.
- Not a dedicated web UI advisor event in v1. Surfacing an amber `[advisor]`
  badge on the `/api/run` stream is deferred.

## Design

**Config.**

```toml
[advisor]
enabled  = true
provider = "openai_compat"   # any configured provider name
model    = "gpt-4o-mini"     # cheap fast model; billing separate from main agent
scope    = "turn"            # "turn" (default) or "session" (full history)
```

`scope = "turn"` sends only the last turn's messages; `scope = "session"` sends
the last N turns (configurable as `advisor.context_turns`, default 3). Session
scope costs more but gives the advisor enough history to notice drift across
turns, not just within one.

When `scope = "session"`, prior advisor injection blocks are stripped from the
history before the advisor call (decided). The advisor evaluates the agent's
work, not its own previous notes.

The `[advisor]` section is distinct from the shipped `improve.arena_advisory`
flag (`src/config.zig`, `src/improve/engine.zig`): `arena_advisory` is a
per-proposal Arena verdict inside the improve engine, while `[advisor]` is a
per-turn critique in the main agent loop. A config reader should not conflate
the two.

**Advisor system prompt (built into the host, not configurable per-run).**

```
You are a silent advisor reviewing an AI agent's last turn.
Your role: flag mistakes before they compound.
Reply with JSON only: {"severity": "note"|"concern"|"blocker", "text": "..."}
- note: informational, something the agent might want to consider
- concern: a likely mistake or suboptimal approach worth correcting
- blocker: a dangerous or destructive action the human should confirm before continuing
Keep text under 150 words. Do not repeat what the agent said; say what it missed.
```

**Concurrency.** The advisor call starts after `on_tool_result`, before the
next think phase. `client.chatWithTimeout` owns a concurrent chat task while
the loop waits on a monotonic deadline. If `advisor.timeout_ms` (default 5000)
expires, it shuts down the task's armed HTTP sockets before cancellation and
drops the result. Auto-thinking uses the same wrapper; neither side channel
can inherit an unbounded provider read.

**Severity handling.**

`note`: The advisor text is formatted as:

```
[advisor: note]
<text>
[/advisor]
```

and prepended to the assistant's system context for the next think call, not
added to the conversation history or the user message. It disappears after one
turn.

`concern`: Same format but with `concern` in the tag. Web UI highlighting of
the tag is deferred (see Non-goals); the injection still happens in system
context.

`blocker`: The advisor text is presented via the `ask_fn` path with two
options: `proceed` and `abort`. If `proceed` is chosen (or if there is no channel
to ask), the text is injected as a concern-level note for the next turn. If
`abort` is chosen, the run stops and the advisor text is the final message.

**Tool argument redaction.** When building the advisor's input, tool call
arguments are replaced with `<redacted>` for any tool whose manifest has
`"fs_prefixes"` or `"exec_allow"` non-empty (the redaction list is built in
`reviewTurn`). Tool names are included unredacted. Message content — including
tool-result text — is included capped at 400 bytes; tool arguments for
non-redacted tools are capped at 200 bytes (`tools/zig/advisor_logic.zig`).

**Stats (decided).** Add an optional `advisor_tokens` field on the closed
`Record` struct in `src/stats/tokens.zig`. Omitted when unset so existing
records and readers are unaffected. `clanker stats` may show the column when
present.

**Failure isolation.** Any error in the advisor call (provider error, timeout,
JSON parse failure) is caught, logged at debug level, and produces no injection.
The main agent loop never sees an exception from the advisor path.

**Dependencies.**

- Hard boundary with PRD 0013 (TTSR): advisor is post-turn annotation; TTSR is
  mid-stream abort. Do not merge the interception points.
- Soft dependency on PRD 0020 (auto-thinking): shared fail-open, budgeted,
  per-turn side-channel call to a secondary model. Whichever ships first should
  extract the timeout/budget wrapper; the other reuses it.
- `src/agent/loop.zig` think/join points; existing `ask_fn` path for blockers.
- Stats `Record` schema (`src/stats/tokens.zig`) for optional `advisor_tokens`.
- Distinct from `improve.arena_advisory` / Arena (PRD 0008).

**Implementation.**

1. **`src/agent/advisor.zig`**: build advisor input (with redaction), call
   secondary model, parse severity JSON, format injection blocks, strip prior
   advisor notes under `scope = "session"`.
2. **Config**: parse `[advisor]`; treat missing provider/key as disabled with a
   startup warning.
3. **Loop integration**: spawn after completed turn; join with
   `advisor.timeout_ms` before next think; inject into system context for one
   turn only (not user message / not `session.messages`).
4. **Blocker path**: wire `ask_fn` proceed/abort; headless falls through as
   concern.
5. **Stats**: optional `advisor_tokens` on `Record`.
6. **Shared side-channel (with 0020)**: extract or adopt the timeout/budget
   wrapper once either PRD lands the helper.
7. **Deferred**: `advisor.skip_tools`; web UI `/api/run` advisor event.

## Failure modes

| Condition | Behaviour |
|---|---|
| Advisor provider not configured or key missing | `advisor.enabled = true` is treated as `false`; log a startup warning; main loop unaffected |
| Advisor call times out | Result dropped; loop proceeds; logged at debug level |
| Advisor returns malformed JSON | Dropped; logged at debug level; loop proceeds with no injection |
| Advisor returns `blocker` in a headless run | The `ask_fn` branch is skipped (no channel); the blocker is downgraded to a `concern` note and injected for the next turn; the loop proceeds. No log line is emitted for the downgrade |
| Main agent's turn itself errors | Advisor is not called; it reviews only completed turns |
| Advisor call itself calls a tool (not possible by design, but malformed JSON could claim one) | Ignored; the advisor completion is a non-tool `client.chatWithTimeout` call, which returns text only |

## Known issues

1. **The one-turn injection has no test.** Nothing in the tree drives
   `Agent.run`, so the pairing of the index-0 insert with its removal is
   structural (a `defer`) rather than test-pinned, and the three exits that used
   to leak it — a provider error, the TTSR retry `continue`, a mid-stream
   Ctrl-C — are not exercised by anything. A fixture that drives the iteration
   loop against a mock provider and a mock advisor would cover this and the TTSR
   arm, which has the same "assert on `messages[0]`" shape and the same absence
   of coverage. See
   [the bug](../reports/bugs/2026-08-23-advisor-block-leaks-into-message-zero.md).

2. **`scope` and `context_turns` were not audited** when `model` was fixed. The
   `model` defect was "declared, parsed, allowlisted in `warnUnknownKeys`, and
   unread"; the same shape has not been ruled out for these two.

## Acceptance criteria

- [x] `[advisor]` section parsed from `config.toml`; missing or invalid fields
      produce a clear startup error.
- [x] With `advisor.enabled = true`, an advisor `client.chatWithTimeout` call is made after
      each completed turn; the provider and model match config.
- [x] A `note` or `concern` response is visible in the next turn's system
      context injection and absent from the user message and from
      `session.messages`; cleared after that one think call.
- [x] Under `scope = "session"`, prior `[advisor: ...]` blocks are stripped
      from history before the advisor call.
- [x] A `blocker` response triggers the `ask_fn` path with `proceed`/`abort`
      options in an interactive session.
- [x] A `blocker` in a headless run is downgraded to a `concern` (loop does
      not hang); no log line is emitted.
- [x] Advisor timeout (`advisor.timeout_ms`) aborts the armed HTTP connection
      through `client.chatWithTimeout`; the loop continues without injection.
- [x] Tool arguments for tools with `fs_prefixes` or `exec_allow` are redacted
      in the advisor input; tool names and result prefixes are not.
- [x] Advisor errors (provider down, malformed JSON) do not propagate to the
      main loop.
- [x] `advisor.enabled = false` (default) causes zero advisor calls; no
      performance impact on the main loop.
- [x] Goal 1's advisor completion may be recorded as an optional
      `advisor_tokens` field on the stats `Record`.
- [x] Unit tests in `src/agent/advisor.zig` cover: severity parsing, argument
      redaction, injection formatting, prior-note stripping.

## Open questions / future work

- **`skip_tools`.** `advisor.skip_tools = [...]` remains future work.
- **Web UI event.** Amber `[advisor]` badge on `/api/run` remains future work.
- **Shared plumbing with PRD 0020.** Extract the fail-open side-channel wrapper
  when either feature lands; track as a hard shared dependency, not an open
  product question.
- **Advisor as Arena combatant.** Whether the advisor's system prompt and
  severity schema should unify with Arena's judge protocol remains open before
  either is changed.
