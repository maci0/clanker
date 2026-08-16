# PRD — Loop-hygiene guard (repeated tool-call reminder)

## Status

Shipped. Implemented as a pure module `src/agent/loop_guard.zig`
(canonicalization + chain tracking, no I/O, unit-tested directly) plus a small
call into `Agent.executeCalls`'s existing per-call loop in
`src/agent/loop.zig`. Inspired by
[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)'s
`packages/guard/repeat-tool-reminder/`, a zero-cost, deterministic pattern
detector clanker has no equivalent of.

## Problem

A model that gets stuck calling the same tool with the same arguments over
and over has no mechanical circuit-breaker in clanker today. `max_iterations`
eventually stops the run, but only after the whole budget is spent — it is a
backstop, not a nudge. Advisor (PRD 0015) is the closest existing mechanism
that *could* catch this, but it is a second LLM call reading every completed
turn, priced and latent, and reserved for judgment calls a script cannot make
("is this approach sound"). "The model just called `grep X` four times in a
row with byte-identical arguments" needs no judgment at all — it is a pure
string-equality check — and paying for an LLM call to notice it would be the
wrong tool for the job.

## Goals

1. Track, per agent run, a chain of `(tool name, canonicalized arguments)`
   for consecutive tool calls. Canonicalization is a deep key-sort of the
   arguments' JSON object plus serialization, so two calls that differ only
   in property order still count as identical (matching DSH's own rule).
2. At configurable consecutive-count thresholds (default `[3, 5, 8]`), inject
   one reminder into the transcript before the next request: a short generic
   nudge at the first threshold, a detailed one (tool name, run length,
   canonicalized arguments, capped preview) at every threshold after.
3. `agent.repeat_tool_thresholds` (default `[3, 5, 8]`) and
   `agent.repeat_tool_exclude` (tool-name patterns transparent to the chain —
   a call to an excluded tool neither increments nor resets the counter, so
   bookkeeping calls interleaved into a real loop cannot launder it; default
   `["todo_add", "todo_close", "todo_list"]`).
4. Advisory only. The call always proceeds; nothing in this PRD denies or
   blocks a tool call. The decision to retry differently, gather more
   evidence, or conclude stays with the model.
5. Zero cost until a threshold fires: no LLM call, no tokens spent, for every
   turn that never loops.

## Non-goals

- **Fuzzy or near-duplicate detection.** Exact canonical-match only. A
  tweaked path or a byte of extra whitespace inside a value evades the
  chain — the same trade-off DSH made, rejecting fuzzy matching "pending
  evidence of need."
- **Escalating to an actual block at a high threshold.** Advisory only in
  v1, even though the mechanism this rides on (`Agent.executeCalls`'s
  existing gate for `plan_mode`/`confirm_fn`) could technically deny a call —
  deliberately not exercised here.
- **Cross-agent or subagent chain-sharing.** Each `Agent` (a top-level run or
  a nested subagent) tracks its own chain; a parent and a subagent repeating
  the same call never combine into one detection.
- **Resetting the chain on compaction.** A chain spanning a compaction
  checkpoint keeps counting rather than being reset by it; matching DSH's own
  accepted cost, since compaction and loop-detection are unrelated concerns.

## Design

**Where it plugs in.** `Agent.executeCalls` (`src/agent/loop.zig`) already
loops over one batch of tool calls per step; the chain check runs there,
after each call's canonical key is known and before the batch's results are
folded into the transcript. A `LoopGuard` struct, one per `Agent`, holds the
last `(name, canonical_args)` key and a run-length counter; a call matching
the held key increments the counter, a different one resets it to 1. On
hitting a configured threshold, a synthetic reminder is appended to the
message list the same way injected context already lands elsewhere in the
loop (todos, and — if PRD 0028 lands first — hook-provided context); this
PRD does not require 0028 and can append directly if it ships first.

**Canonicalization is pure and separately testable.** A function over
`std.json.Value` that sorts object keys recursively and serializes —
`src/agent/loop_guard.zig`'s core, with no dependency on `Agent` or I/O, so
every case (nested objects, arrays, key-order permutations) is a unit test
over a literal.

**Denied calls still count.** The chain check runs on every dispatched call,
including one `plan_mode` or `confirm_fn` already refused — a model hammering
a call a human keeps declining is exactly the loop worth flagging, not a
case to special-case out.

**Config validation fails loud.** An empty threshold list, a non-integer, a
value below 2, or a duplicate is a config-load error naming the bad value,
never a silent fall-back to the default list — matching the fail-loud
convention the manifest validator (PRD 0010) already established for a
malformed `fuel` value.

**Dependencies.** None. Self-contained; does not require PRD 0028's hooks or
PRD 0015's Advisor, and does not conflict with either — a deployment can run
all three at once, each answering a different question (Advisor: is this
approach sound; hooks: does policy allow this; this guard: is the model
stuck).

**Implementation.**

1. `src/agent/loop_guard.zig`: canonicalization + chain struct, unit-tested
   in isolation.
2. `agent.repeat_tool_thresholds` / `agent.repeat_tool_exclude` config
   fields, with load-time validation.
3. Wiring into `Agent.executeCalls`: chain update per call, reminder
   injection on threshold.
4. A log line (`log.log(.info, ...)`) when a reminder fires, matching the
   existing style beside the `plan_mode`/`confirm_fn` gates, so a run's log
   says when the guard actually did something.

## Failure modes

| Condition | Behaviour |
|---|---|
| `repeat_tool_thresholds` invalid at config load (empty, non-integer, `<2`, duplicate) | Config load error naming the bad value; no silent default substitution |
| A tool call excluded by `repeat_tool_exclude` | Neither increments nor resets the chain; transparent |
| A denied call (plan mode / confirm_fn refused it) | Still counts toward the chain |
| Chain spans a compaction event | Not reset by compaction; counting continues |
| Past the highest configured threshold | No further reminders fire for that run of repeats; the chain keeps counting silently |
| No agent object available (a direct tool call outside a run) | Guard does not apply; nothing to key the chain on |

## Acceptance criteria

- [x] Canonicalization is pure, unit-tested, and treats property-order
      permutations as identical.
- [x] Three identical consecutive calls (default thresholds) inject the
      short reminder before the next request; five inject the detailed one.
- [x] A different call in between resets the counter to 1.
- [x] An excluded tool call interleaved between two matching calls does not
      reset the counter.
- [x] No reminder is injected, and no extra tokens spent, for a run that
      never repeats a call past the first threshold.
- [x] `repeat_tool_thresholds` validation rejects an empty list, a
      non-integer, a value below 2, and a duplicate at config load.
- [x] A denied call (plan mode or confirm decline) still advances the chain.
- [x] The guard is advisory only: hitting a threshold injects a reminder but
      never blocks, denies, or otherwise prevents the tool call from running.
      (Goal 4)

## Open questions / future work

- **Overlap with Advisor (PRD 0015).** Both inject text describing the
  model's own behavior back into context; this PRD argues they answer
  different questions (deterministic pattern vs. LLM judgment) and are worth
  shipping independently, but the overlap is real and worth a second look
  once both exist in a real deployment — do users find two separate nudge
  mechanisms confusing, or complementary?
- **Escalating to a block.** `PostToolDecision`-shaped blocking already
  exists as a *capability* in the gate this rides on; whether a very high
  threshold should ever deny rather than merely nudge is left for evidence
  from real usage, not decided here.
