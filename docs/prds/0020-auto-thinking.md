# PRD — Auto thinking

## Status

Shipped, opt-in. `agent.auto_thinking = false` by default. When on, a
fail-open classifier in `src/agent/thinking.zig` picks a 0024
`reasoning_effort` row for the current turn. Sources of truth:
`src/agent/thinking.zig`, `src/agent/loop.zig` (`classifyEffort`),
`src/config.zig` (`Agent.auto_thinking`).

## Problem

`reasoning_effort` is static per provider config. Every turn uses the same effort
level whether the user asks "what time is it?" or "redesign this module's
concurrency model." Overprovisioning (always `high`) is expensive; underprovisioning
(always `low`) misses quality on hard tasks. The user has to manually override the
setting per session, which they do not do.

omp's auto thinking uses a small per-turn classifier to resolve the effort level.
Cheap turns stay cheap; complex turns get the budget they need. The classifier is
a separate, small model call — fast and inexpensive.

## Goals

1. When `agent.auto_thinking = true`, the agent loop makes one additional
   `ck_llm` call before each main turn, sending the user's message text to a
   small classifier model.
2. The classifier returns one of four effort levels: `low`, `medium`, `high`,
   `xhigh`. This selects which sampling-profile row (PRD 0024) applies for
   that turn's `reasoning_effort`.
3. The classifier model is configurable as `agent.thinking_classifier_model`
   (provider name and model name). Defaults to the cheapest configured
   provider if unset.
4. The classifier system prompt is built into the host and is not configurable
   per-run (to prevent the main agent from manipulating the effort it gets).
5. The classifier result is logged per turn in `state/token_stats.jsonl` under
   a new optional `thinking_level` field added to the record schema
   (`src/stats/tokens.zig`) alongside the existing token counts.
6. The feature is opt-in: `agent.auto_thinking = false` is the default. When
   disabled, `reasoning_effort` behaves as today. It stays opt-in until a
   calibration eval justifies recommending it as a default.

## Non-goals

- Not per-tool effort. The effort level applies to the main think call, not to
  individual tool calls or subagent calls. Tool calls use whatever their own
  provider config specifies.
- Not a feedback loop. The classifier does not see the previous turn's result and
  does not learn from it. Each turn is classified independently.
- Not user-visible. The chosen effort level is logged but not shown in the REPL
  or web UI turn card. It is an implementation detail, not a feature the model
  should be able to discuss or manipulate.
- Not a cost optimizer. The goal is quality-appropriate reasoning, not minimum
  cost. If the classifier always returns `high`, that is a valid (if expensive)
  outcome.
- Not changing provider routing. The same provider is used for the main turn
  regardless of effort level. Effort routing to a different model is out of scope.
- Not writing `reasoning_effort` onto the wire. PRD 0024's capability-keyed
  profile table owns that write; this PRD only selects which profile row
  applies.

## Design

**Config.** Keys live flat under `[agent]`:

```toml
[agent]
auto_thinking = true
thinking_classifier_model = "openai_compat/gpt-4o-mini"
                            # "provider_name/model_name" or just "provider_name"
                            # (uses that provider's default_model)
thinking_classifier_timeout_ms = 3000
```

If `thinking_classifier_model` is not set, the host picks the provider with the
lowest `cost_per_1m_input` in config. If no cost is configured, the first
provider alphabetically is used.

**Classifier system prompt (hardcoded in the host).**

```
Classify the complexity of this user message for an AI coding agent.
Reply with exactly one word: low, medium, high, or xhigh.

low:   Lookup, clarification, simple file read, "what is X?"
medium: Standard coding task, single file edit, known pattern
high:  Multi-file refactor, design decision, debugging complex issue
xhigh: Architecture redesign, cross-system analysis, novel problem

Message:
```

The user's message text is appended verbatim after "Message:". The classifier
call has `max_tokens = 5` and `temperature = 0`. A response that is not one of
the four words is treated as `medium`.

**History window (v1).** The classifier sees the current user message only.
Short follow-ups that depend on prior context ("do it") can be misclassified;
a 2-3 message window is deferred until calibration data shows that cost is
worth paying. v1 deliberately keeps the classifier input small and independent.

**Effort level mapping.** Classifier results map to profile-row selectors, not
to a second writer of `reasoning_effort`:

| Classifier result | Profile / effort selection |
|---|---|
| `low` | select the table's low-effort row (or provider minimum) |
| `medium` | select the medium row |
| `high` | select the high row |
| `xhigh` | select `high` |

The selection applies only for the current turn. It does not mutate the
provider config.

Wiring note: `reasoning_effort` is not written by the shared
`writeSamplingParams` (`src/llm/providers/common.zig`), which emits only
`temperature` and `top_p`; each provider file serializes it in its own
vendor-specific shape. PRD 0024 extends the shared sampling path to own
writing the field; this PRD's classifier only chooses which 0024 profile
row the turn uses.

**Precedence vs. sampling profiles (PRD 0024).** PRD 0024 owns writing
`reasoning_effort`; this PRD's classifier selects WHICH row of that table
applies to the turn. It is not a second independent writer of the field.

**Classifier call mechanics.** The classifier `ck_llm` call is made with:
- `system`: the hardcoded prompt above.
- `messages`: one user message containing the user's turn text (no history).
- `max_tokens = 5`, `temperature = 0`.
- No tools, no streaming.

It uses the configured classifier provider's auth, not the main provider's. The
call is billed to the classifier provider's account. Tracking it distinctly in
`token_stats.jsonl` depends on the schema change described under Logging; the
record format has no source or event discriminator today.

**Timeout and failure.** If the classifier call exceeds
`thinking_classifier_timeout_ms` (default 3000 ms) or errors, the turn proceeds
with the main provider's default `reasoning_effort` (0024's normal row
selection without a classifier override). The failure is logged at debug
level; no error surfaces to the user.

**Opt-in until calibrated.** Default remains `auto_thinking = false`. Shipping
as a recommended default requires a calibration eval (N labeled tasks,
agreement between classifier output and human ground truth) across the
classifier models people actually use. Until that lands, the feature stays
opt-in.

**Logging.** `token_stats.jsonl` records are the closed `Record` struct in
`src/stats/tokens.zig` (ts, provider, model, token counts, cache hit/miss,
cost, duration); none of the fields below exist yet. This PRD adds two optional
fields to that struct: `thinking_level` (the classifier result, written on the
main turn's record) and `thinking_classifier_ms` (round-trip time of the
classifier call). Both are omitted when unset, so existing records and readers
are unaffected:

```json
{"ts": 1234567890, "provider": "anthropic", ..., "thinking_level": "high",
 "thinking_classifier_ms": 450}
```

**`clanker stats` integration.** `GET /api/stats` today serves aggregated
per-(provider, model) usage, not per-turn events, so a distribution of
classifier results has nothing to read until the `thinking_level` field from
the Logging schema change lands in `Record`. With that in place, the endpoint
and `clanker stats` expose the distribution (how many turns at each level) as
a `totals.thinking_distribution` field in the `/api/stats` response.

**Dependencies.**

- Hard: [PRD 0024 (sampling profiles)](0024-sampling-profiles.md) owns writing
  `reasoning_effort`. This PRD selects the profile row; build 0024's table and
  write path first (or in lockstep), or the classifier has nowhere to put its
  result.
- Soft: [PRD 0015 (advisor)](0015-advisor.md) also needs a fail-open, budgeted,
  per-turn side-channel model call. Extract a shared wrapper once either
  feature is built rather than duplicating the pattern.
- Existing: `src/agent/loop.zig` (turn dispatch), `src/llm/client.zig` (request
  path), `src/stats/tokens.zig` (`Record`), provider request builders that
  already serialize `reasoning_effort` in vendor-specific shapes.

**Implementation.**

1. Config keys under `[agent]` in `src/config.zig`: `auto_thinking` (default
   false), `thinking_classifier_model`, `thinking_classifier_timeout_ms`
   (default 3000). No nested `[agent.auto_thinking]` table.
2. Classifier call helper (host-side): hardcoded system prompt, current-message
   only, `max_tokens = 5`, `temperature = 0`, timeout, fail-open to default
   effort. Prefer extracting a shared side-channel wrapper if 0015 lands
   nearby.
3. Wire into `src/agent/loop.zig` pre-turn: when `auto_thinking`, run
   classifier, map result to a 0024 profile-row selector (`xhigh` → `high`), pass that into the
   sampling-profile lookup. Do not write `reasoning_effort` here.
4. Extend `src/stats/tokens.zig` `Record` with optional `thinking_level` and
   `thinking_classifier_ms`; surface `totals.thinking_distribution` in
   `GET /api/stats` / `clanker stats`.
5. Tests: effort mapping, timeout fallback, unexpected-response → `medium`,
   empty-message skip, opt-in default (zero classifier calls when disabled).
   The empty-message skip and the one-call-per-turn bound are covered by
   `auto-thinking classifies once per turn and skips a blank submit` in
   `src/agent/loop.zig`, which counts requests off a loopback mock server
   rather than reading the call chain
   ([bug](../reports/bugs/2026-08-24-auto-thinking-classifies-every-iteration.md)).

## Failure modes

| Condition | Behaviour |
|---|---|
| Classifier provider not configured | `auto_thinking = true` is treated as `false`; startup warning logged |
| Classifier returns unexpected text | Treated as `medium`; logged at debug level |
| Classifier times out | Main turn proceeds with default `reasoning_effort` |
| Classifier provider rate-limited | Same as timeout; fallback to default |
| Main provider does not support `reasoning_effort` | Classifier result is logged but the override has no effect (the field is simply not sent) |
| User message is empty (e.g., a REPL submit with no text) | Classifier is skipped; default effort used. Whitespace-only counts as empty. Skipping is the load-bearing part rather than the saved call: `parseLevel("")` answers `medium`, so classifying blank text would not fall back to the default, it would pin the turn to `medium` |
| Same turn, later iteration | No second call. The verdict is memoised against the exact user-message text for the run, so a turn that takes N iterations still costs one classifier call. A mid-run steer appends a new `.user` message and is therefore classified again |

## Known issues

1. **The "no classifier provider" path logs at debug, per turn, not as a
   startup warning.** The failure-modes row above asks for a startup warning;
   `thinking.classify` logs `auto-thinking skipped: no classifier provider` at
   `.debug` and does it on every turn instead. A typo'd
   `thinking_classifier_model` therefore disables the feature invisibly at the
   default log level. Not fixed.

2. **`xhigh` never selects a distinct row.** `effortFor` collapses
   `.high, .xhigh => "high"`, so `config.ReasoningEffort`'s `max` row is
   unreachable from the classifier. This is per spec (the mapping table above
   says `xhigh` -> `high`) and the `xhigh` label does survive in
   `ctx.thinking_level` and `token_stats.jsonl`; recorded here so a reader does
   not re-diagnose it as drift.

## Acceptance criteria

- [x] `agent.auto_thinking = false` (default): zero classifier calls; no behavior
      change on any existing test.
- [x] `agent.auto_thinking = true`: a classifier `ck_llm` call is made before
      each main turn; the main turn's profile row / `reasoning_effort` matches
      the classifier result via PRD 0024's writer.
- [x] A message classified as `low` selects the low-effort profile row; a
      message classified as `high` selects `"high"`.
- [x] `xhigh` selects `"high"`.
- [x] `agent.thinking_classifier_model` accepts a bare provider name or a
      `provider/model` pair and selects the classifier provider/model; when
      unset, the cheapest configured provider (by `cost_per_1m_input`, ties and
      missing cost falling back to the first provider alphabetically) is used.
      (Goal 3)
- [x] A classifier timeout aborts the armed HTTP connection through
      `client.chatWithTimeout`; the turn proceeds with the default
      `reasoning_effort` and no error surfaced to the user.
- [x] A classifier response that is not one of the four words results in `medium`.
- [x] Classifier input is the current user message only (no history).
- [x] `token_stats.jsonl` `Record` has optional `thinking_level` /
      `thinking_classifier_ms` fields (omitted when unset).
- [x] `clanker stats` shows a `thinking` breakdown and `GET /api/stats`
      exposes `totals.thinking_distribution` for low/medium/high/xhigh.
- [x] The classifier system prompt is not modifiable via config or tool calls
      (verify by checking no config key changes it).
- [x] Unit tests cover: effort level mapping, unexpected-response fallback,
      opt-in default.

## Open questions / future work

- **Wider history window.** v1 is current-message only. Revisit a 2-3 message
  window after calibration if short follow-ups are a real misclassification
  source.
- **Calibration eval.** Required before recommending `auto_thinking = true` as
  a default. Not a build blocker for the opt-in path.
- **Session-level learning.** If the user overrides the effort level manually for
  several turns in a row (e.g., always bumps `low` to `medium`), the classifier
  could learn within the session. This would require storing the override history
  and prompting the classifier with it, adding complexity not justified for v1.
- **Shared plumbing with the advisor (PRD 0015).** Both features add a
  fail-open, budgeted, per-turn side-channel model call; that wrapper should be
  extracted once and shared rather than built twice.
- **Cost accounting.** Classifier calls add a fixed per-turn cost. For a session
  with 50 turns and a `gpt-4o-mini`-class classifier at $0.15/1M tokens, the
  overhead is negligible. For a local on-device classifier (Ollama), it approaches
  zero. Measure and document per classifier model before recommending specific
  defaults.
