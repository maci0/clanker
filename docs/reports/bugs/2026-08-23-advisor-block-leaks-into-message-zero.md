# Bug — the one-turn advisor block is removed only on the success path, so three exits leave it as message 0

## TL;DR

- **What failed:** The advisor note is inserted at messages index 0 and removed at the bottom of the success path. A provider error, a TTSR retry continue, and a mid-stream Ctrl-C all leave the loop in between, and index 0 is where the rest of the loop requires the system prompt: the TTSR arm appends its rule text to messages[0], compactMiddle preserves index 0 and replaces from index 1, and run's prepend-the-system-prompt check reads a leftover note as a system message.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-23. the removal is now a defer declared at the insert, so all three intervening exits undo it. Structural fix, not unit-covered: no harness drives Agent.run. See Verification.

## Status

Resolved on 2026-08-23. the removal is now a defer declared at the insert, so all three intervening exits undo it. Structural fix, not unit-covered: no harness drives Agent.run. See Verification.

## Symptom and impact

With `advisor.enabled = true`, the advisor's note for the previous tool batch is
injected as a one-turn `role = .system` message at `messages` index **0**, and
removed at the bottom of the iteration — on the success path only.

Three exits sit between the insert and the removal, and none of them undid it:

- `return err` on any non-`Interrupted` provider error,
- the TTSR retry `continue`,
- the mid-stream Ctrl-C `return`.

Index 0 is not an arbitrary slot. Three separate places in the same file
require it to hold the system prompt:

- the TTSR arm appends the fired rule's `inject` text to `messages.items[0]`.
  After the leak that text was concatenated onto the *advisor note*, so the rule
  silently stopped working while still counting its fire.
- `compactMiddle` does `replaceRange(arena, 1, keep_start - 1, …)`: index 0 is
  preserved and index 1 is inside the replaced range. So the next compaction
  kept the stale advisor note and **destroyed the real system prompt**; the rest
  of the session ran without one.
- `run`'s "prepend the system prompt when `messages[0]` is not a system message"
  check saw the leftover note as a system message and did not prepend. The next
  REPL turn on the same `Agent` therefore went out with the stale note first and
  the real system prompt at index 1 — a mid-conversation system message, which
  this same file elsewhere documents as something qwen2.5/qwen3 chat templates
  reject outright. If the prompt text had changed in between,
  `refreshSystemPrompt` overwrote `items[0]` instead, and the system prompt was
  double-included at 0 and 1.

So one failed provider call or one TTSR fire silently corrupted the message list
for the remainder of a REPL session.

## Reproduction

Not reproduced end to end. Establishing it needs an advisor note pending *and*
one of the three exits taken *and* a following turn on the same `Agent`, which
means a REPL session with a provider induced to fail mid-turn. The defect was
established by reading the three exits against the three index-0 readers, all in
`src/agent/loop.zig`; see Root cause.

## Root cause

`src/agent/loop.zig`, the iteration body: `messages.insert(self.arena, 0, …)`
paired with a plain `if (injected_advisor …) _ = messages.orderedRemove(0);`
placed near the bottom of the success path. The removal had additionally been
spliced into the *middle of an unrelated comment* ("…terminate a run that
still" / "wants to call tools."), which is its own evidence about how it got
there.

## Resolution

The conditional removal is now a `defer` declared immediately after the insert,
so every way out of the iteration — normal completion, `return err`, the TTSR
`continue`, the Ctrl-C `return` — undoes it. The split comment is rejoined.

Insert-at-index-1 was considered and rejected: a `.system` message at index 1 is
a mid-conversation system message, which is the shape the same file warns about
for qwen chat templates.

## Verification

- `clanker gate` green, and the advisor happy path is live-verified in
  [2026-08-23-advisor-model-never-read.md](2026-08-23-advisor-model-never-read.md)
  (two runs, the critique call visible in `state/token_stats.jsonl`, correct
  final answer).
- **Not unit-covered, and that is a real gap in this record.** Nothing in the
  tree drives `Agent.run`, so there is no harness that can take one of the three
  exits and then assert on `messages.items[0]`. The fix is structural (a `defer`
  cannot be skipped by a control-flow path) rather than test-pinned, and a
  regression would be reintroducing the conditional removal, which is visible in
  a diff. A test would need a fixture that drives the iteration loop against a
  mock provider and a mock advisor; that is worth building and is not built.

## Follow-up

Build the missing `Agent.run` fixture (mock provider + mock advisor + a stub
registry) and pin this exit-by-exit. It would also cover the TTSR retry path,
which has the same "assert on `messages[0]`" shape and the same absence of
coverage.

## References

- PRD: [0015-advisor.md](../../prds/0015-advisor.md)
- Code: `src/agent/loop.zig` (the advisor insert/`defer` pair, the TTSR arm,
  `compactMiddle`, `run`'s system-prompt prepend, `refreshSystemPrompt`)
