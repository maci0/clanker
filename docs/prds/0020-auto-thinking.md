# PRD — Auto thinking

## Status

Draft. No source files yet. Change is in `src/agent/loop.zig` (pre-turn
classifier call) and `src/llm/client.zig` (per-turn `reasoning_effort` override).
New config section `[agent.auto_thinking]`.

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
   `xhigh`. This overrides the main provider's `reasoning_effort` for that turn
   only.
3. The classifier model is configurable as `agent.thinking_classifier_model`
   (provider name and model name). Defaults to the cheapest/fastest configured
   provider if unset.
4. The classifier system prompt is built into the host and is not configurable
   per-run (to prevent the main agent from manipulating the effort it gets).
5. The classifier result is logged per turn in `state/token_stats.jsonl` under a
   `thinking_level` field alongside the existing token counts.
6. The feature is opt-in: `agent.auto_thinking = false` is the default. When
   disabled, `reasoning_effort` behaves as today.

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

## Design

**Config.**

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

**Effort level mapping.** Each provider's `reasoning_effort` field already
accepts a string. The per-turn override sets:

| Classifier result | `reasoning_effort` |
|---|---|
| `low` | `"low"` (or the provider's equivalent minimum) |
| `medium` | `"medium"` |
| `high` | `"high"` |
| `xhigh` | `"high"` (most providers cap here; if the provider has an `xhigh` tier, it is used) |

The override is applied only for the current turn's `buildRequest` call. It does
not mutate the provider config.

**Classifier call mechanics.** The classifier `ck_llm` call is made with:
- `system`: the hardcoded prompt above.
- `messages`: one user message containing the user's turn text (no history).
- `max_tokens = 5`, `temperature = 0`.
- No tools, no streaming.

It uses the configured classifier provider's auth, not the main provider's. The
call is billed to the classifier provider's account and tracked in
`token_stats.jsonl` under `source = "classifier"`.

**Timeout and failure.** If the classifier call exceeds
`thinking_classifier_timeout_ms` (default 3000 ms) or errors, the turn proceeds
with the main provider's default `reasoning_effort`. The failure is logged at
debug level; no error surfaces to the user.

**Logging.** Each `token_stats.jsonl` entry gains an optional `thinking_level`
field when `auto_thinking = true`:

```json
{"ts": 1234567890, "provider": "anthropic", ..., "thinking_level": "high",
 "thinking_classifier_ms": 450}
```

`thinking_classifier_ms` is the round-trip time for the classifier call.

**`clanker stats` integration.** `GET /api/stats` and `clanker stats` expose the
distribution of classifier results (how many turns at each level) as a
`thinking_distribution` field in the session summary.

## Failure modes

| Condition | Behaviour |
|---|---|
| Classifier provider not configured | `auto_thinking = true` is treated as `false`; startup warning logged |
| Classifier returns unexpected text | Treated as `medium`; logged at debug level |
| Classifier times out | Main turn proceeds with default `reasoning_effort` |
| Classifier provider rate-limited | Same as timeout; fallback to default |
| Main provider does not support `reasoning_effort` | Classifier result is logged but the override has no effect (the field is simply not sent) |
| User message is empty (e.g., a REPL submit with no text) | Classifier is skipped; default effort used |

## Acceptance criteria

- [ ] `agent.auto_thinking = false` (default): zero classifier calls; no behavior
      change on any existing test.
- [ ] `agent.auto_thinking = true`: a classifier `ck_llm` call is made before
      each main turn; the main turn's `reasoning_effort` matches the classifier
      result.
- [ ] A message classified as `low` sends `reasoning_effort = "low"` to the main
      provider; a message classified as `high` sends `"high"`.
- [ ] A classifier timeout (inject a fake 10s delay in tests) causes the turn to
      proceed with the default `reasoning_effort`, not hang.
- [ ] A classifier response that is not one of the four words results in `medium`.
- [ ] `token_stats.jsonl` entries include `thinking_level` and
      `thinking_classifier_ms` when `auto_thinking = true`.
- [ ] `clanker stats` shows a `thinking_distribution` breakdown.
- [ ] The classifier system prompt is not modifiable via config or tool calls
      (verify by checking no config key changes it).
- [ ] Unit tests cover: effort level mapping, fallback on timeout, fallback on
      unexpected response, empty-message skip.

## Open questions / future work

- **Message history context.** The classifier currently sees only the current
  user message, not the conversation history. A hard problem ("refactor this
  module") phrased as a short follow-up ("do it") would be misclassified as
  `low`. Whether to send a 2-3 message window to the classifier, at extra cost,
  is unresolved.
- **Calibration.** The four example descriptions in the system prompt are
  heuristic. Whether they produce well-calibrated classifications across different
  models (especially small/local models) is unknown. A calibration eval (N labeled
  tasks, measure agreement between classifier output and a human's ground-truth
  label) is worth running before recommending this as a default.
- **xhigh tier.** Anthropic's extended thinking and some providers' equivalent
  offer a budget beyond `high`. The mapping `xhigh -> "high"` is conservative.
  A `provider.max_reasoning_effort` config key that the `xhigh` level maps to
  would let users who have access to extended-budget tiers use them.
- **Session-level learning.** If the user overrides the effort level manually for
  several turns in a row (e.g., always bumps `low` to `medium`), the classifier
  could learn within the session. This would require storing the override history
  and prompting the classifier with it, adding complexity not justified for v1.
- **Cost accounting.** Classifier calls add a fixed per-turn cost. For a session
  with 50 turns and a `gpt-4o-mini`-class classifier at $0.15/1M tokens, the
  overhead is negligible. For a local on-device classifier (Ollama), it approaches
  zero. The cost is worth measuring and documenting per classifier model before
  recommending specific defaults.
