# Bug — auto-thinking runs the classifier once per iteration instead of once per turn, and classifies a blank submit

## TL;DR

- **What failed:** classifyEffort sits inside the agent loop's per-iteration body and reads only the last user message, which does not change while the model works a tool batch. An 11-iteration turn bought 11 identical classifier round trips for one verdict, against PRD 0020 Goal 1 (one call before each main turn). A blank message was classified rather than skipped, and parseLevel answers medium for a blank reply, so it pinned the turn to medium.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-23. classifyEffort memoises the verdict against the user-message text and returns null for a blank submit; pinned by a mock-server call-count test with both controls, and a live 11-iteration run made exactly one classifier call.

## Status

Resolved on 2026-08-23. classifyEffort memoises the verdict against the user-message text and returns null for a blank submit; pinned by a mock-server call-count test with both controls, and a live 11-iteration run made exactly one classifier call.

## Symptom and impact

PRD 0020 Goal 1: "the agent loop makes **one** additional `ck_llm` call before
each main turn". `classifyEffort` is called from inside the
`while (iteration < self.max_iterations)` body, and its input is the last
`.user` message and nothing else — which does not change while the model works
through a tool batch. With `temperature = 0` every one of those calls is an
identical request answered identically.

So a turn that took N iterations paid for N classifier calls, each also
serialised in front of the main request on
`thinking_classifier_timeout_ms` (default 3000 ms). `max_iterations` defaults
to 50.

The same function also had no emptiness check, which contradicts PRD 0020's own
failure table:

> User message is empty (e.g., a REPL submit with no text) | Classifier is
> skipped; default effort used.

Worse than the wasted call: `parseLevel("")` answers `medium`
(`tools/zig/thinking_logic.zig`), so classifying blank text did not fall back
to the configured default — it *pinned* the turn to `medium`, overriding the
per-model config and the PRD 0024 profile row.

PRD 0020's Implementation step 5 lists "empty-message skip" among the required
tests. It was never written.

## Reproduction

```toml
[agent]
auto_thinking = true
thinking_classifier_model = "deepseek/deepseek-v4-flash"
```

```bash
rm -f state/token_stats.jsonl
clanker run 'Work strictly one tool call per turn, never two in the same turn.
Step 1: read_file build.zig.zon. Step 2: read_file README.md. Step 3: read_file
LICENSE. Step 4: report the byte size of each of the three files you read.'
```

Count `deepseek-v4-flash` records in `state/token_stats.jsonl`: before the fix
there is one per main-model iteration.

## Root cause

`src/agent/loop.zig` `classifyEffort` had no memo and no emptiness guard: it
walked back to the last `.user` message and called `thinking.classify`
unconditionally, once per iteration.

## Resolution

`src/agent/loop.zig`:

1. A blank (whitespace-only) last user message returns null before any call, so
   the configured default effort stays in charge — what the failure table says.
2. A new `Agent.thinking_cache` (`{key, level, effort}`) memoises the verdict
   against the exact user-message text. Same text, same verdict, no call. The
   key is the text rather than a turn counter on purpose: a mid-run steer
   appends a *new* `.user` message, so it is classified again, which is what
   PRD 0020's "each turn is classified independently" asks for.
3. On a cache hit `ctx.thinking_level` is replayed (the level really is in
   effect for that iteration) but `ctx.thinking_classifier_ms` is left null,
   because no round trip happened on that iteration. The turn's first record
   carries the timing.

## Verification

- New unit test `auto-thinking classifies once per turn and skips a blank
  submit` in `src/agent/loop.zig`, counted off a loopback mock server's capture
  log rather than the call chain. It pins all four behaviours and both controls:
  three calls with the same last user message hit the server once; a new user
  message makes it two; a blank submit makes no call and pins no effort; and the
  replayed record carries the level but not the timing.
- `clanker gate` green.
- Live, deepseek-v4-pro main model, deepseek-v4-flash classifier, the
  reproduction task above — 11 main-model iterations, one classifier call:

  ```
  deepseek-v4-flash  compl=5    thinking_level=None    clsms=None
  deepseek-v4-pro    compl=73   thinking_level=medium  clsms=892
  deepseek-v4-pro    compl=45   thinking_level=medium  clsms=None
  ... (nine more deepseek-v4-pro iterations, all medium, all clsms=None)
  main-model iterations: 11   classifier calls: 1
  ```

  Before the fix that column reads 11 and 11.

## Follow-up

`thinking.classify`'s "no classifier provider" skip logs at `debug` and does so
once per turn, where PRD 0020's failure table asks for a **startup warning**. A
typo'd `thinking_classifier_model` therefore disables the feature invisibly at
the default log level. Not fixed here; filed separately.

## References

- PRD: [0020-auto-thinking.md](../../prds/0020-auto-thinking.md) (Goal 1,
  failure table, Implementation step 5)
- Code: `src/agent/loop.zig` (`classifyEffort`, `ThinkingCache`),
  `src/agent/thinking.zig` (`classify`), `tools/zig/thinking_logic.zig`
  (`parseLevel`)

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
