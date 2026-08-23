# PRD — REPL mid-stream inject via steer

## Status

Shipped (differently than drafted) — updated 2026-08-22, opened 2026-08-21.

Source of truth: `src/tui/repl.zig` (`steerWhileRunning`, `tuiSteerPoll`,
`bridge_steer`, `steer_message_cap`) and the drain seam in
`src/agent/loop.zig` (`steer_fn`, polled between iterations). Surfaces: the
REPL composer while a turn runs; the web equivalent is `POST /api/steer`
(PRD 0006 8.6).

What shipped is not the drafted `/steer` command or Ctrl-S binding: while a
turn runs the composer itself is the steer box — plain Enter queues the
typed line as a mid-run course correction onto the same `Agent.steer_fn`
seam the web uses. There is no `/steer` command and no Ctrl-S binding in
the tree.

## Problem

Web can POST /api/steer. The vaxis REPL could not inject into a running
turn: typing mid-run was a no-op, so the only course correction was to
kill the turn or switch to the web UI.

## Goals

1. Mid-run composer input queues onto `Agent.steer_fn` — the same queue
   the web uses, not a second channel.
2. Queued steers are visible: an immediate transcript echo per message and
   a live queue count while any are waiting.
3. The queue is bounded the same way the server's is.
4. Tests exercise the queue, not a parallel implementation.

## Non-goals

- Abort-and-resubmit (drops in-flight tool work; RFC 0035 Option B, rejected).
- A second steer channel or protocol.
- A Ctrl-S binding — it can collide with XOFF under software flow control;
  revisit only with evidence terminals handle it (ADR 0047 caveat).

## Design

**Queue.** `steerWhileRunning` (render thread) frames the composer text
with the same interjection sentence `POST /api/steer` applies server-side
and appends it to `bridge_steer` under `bridge_mutex`; `tuiSteerPoll` (run
thread) drains it oldest-first as the run's `Agent.steer_fn` between agent
iterations. The queue is cleared at turn start and teardown, so a stale
steer never leaks into the next turn.

**Visibility (2026-08-22).** Each queued steer echoes
`steering queued (N pending): <text>` straight into the transcript from
`steerWhileRunning` — not via `bridge_tool_lines`, which is only drained
after the run returns and made the typed text vanish until the turn ended.
While `bridge_steer` is non-empty during a run, the status line shows
`N steer queued`, decrementing as the run drains the queue.

**Bound.** `steer_message_cap = 16`, the same ceiling `steerEnqueue`
enforces per run server-side. A steer over the cap is refused with a
transcript line that repeats the message (the composer was already reset,
so that line is where the text survives).

## Failure modes

| Condition | Behaviour |
|---|---|
| Enter while idle | submits a task, as always; steering needs a running turn |
| Enter in the race window after the turn ended | `notice: no run to steer; the turn already ended` |
| Queue at 16 | refusal line repeating the message; nothing queued |
| Slash command typed mid-run | classified before the steer queue: `/quit`/`/help` run, others get a wait notice, never steered as literal text — see Known issues |
| Run ends with steers still queued | queue is cleared at next turn start; the count disappears |

## Acceptance criteria

1. [x] Mid-run composer input reaches `Agent.steer_fn`'s queue (Goal 1).
2. [x] A queued steer is visible before the turn ends: transcript echo +
       status-line count (Goal 2).
3. [x] The TUI queue refuses message 17, like the server (Goal 3).
4. [ ] A test drives `steerWhileRunning`/`tuiSteerPoll` end to end (Goal 4)
       — the drain seam is covered server-side in `src/cli.zig` steer
       registry tests, but the TUI queue itself has no direct test; the
       shared blank-line rule is pinned by `isBlankSubmission` only.

## Known issues

- **(Fixed) Slash commands typed while a turn runs used to be steered, not
  parsed.** `steerWhileRunning` now classifies the line with
  `classifyMidRunInput` (src/tui/repl.zig) before the steer queue: `/quit`
  and `/help` run, every other command and a `!` escape gets a wait notice,
  a typo'd `/command` the unknown-command diagnostic; none reaches the
  model as steering text. Pinned by the unit test "classifyMidRunInput
  keeps commands and shell escapes out of the steer queue". Resolved in
  `docs/reports/bugs/2026-08-22-repl-slash-commands-swallowed-mid-run.md`.
- **(Fixed) The framing sentence used to be persisted verbatim as the
  user's message.** The framing moved out of both senders into
  `applySteerFraming` (src/agent/loop.zig), applied to the request copy
  only; the saved message keeps the user's own words plus
  `types.Message.steered`. Resolved in
  `docs/reports/bugs/2026-08-22-steer-framing-persisted-in-transcript.md`.

## Open questions / future work

- Ctrl-S as a kimi-style alias stays out until the XOFF question is
  settled (ADR 0047).
- Whether an explicit `/steer` spelling is still worth adding now that the
  composer steers implicitly — it would also reopen mid-run slash parsing
  (see Known issues).
