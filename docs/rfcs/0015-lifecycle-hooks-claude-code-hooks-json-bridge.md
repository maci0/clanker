# RFC 0015 — Lifecycle hooks: Claude Code hooks.json bridge

## Status

Decided — 2026-08-17. ADR 0027

## Overview

Kimi harness parity's last open gap per docs/reviews/webui.md is lifecycle hooks (partial: confirm_writes/plan_mode exist, but no hooks.json bridge). Decide how clanker runs external policy scripts at PreToolUse/PostToolUse/UserPromptSubmit/Stop/SessionStart without forking a new runner or diverging from Claude Code's exit-code/stdout wire contract.

**Decision to make.** Which hook bridge should clanker adopt for Claude Code's `hooks.json` (which lifecycle points, matcher mode, wire decode, merge order) and where do those checks run in the agent loop?

**Why now.** ROADMAP Planned (Kimi harness parity) and `docs/reviews/webui.md` Left/next both list lifecycle hooks as the remaining Kimi gap after MCP client and ACP lands.

**Drivers.** Claude-compatible wire (matcher `A-Za-z0-9_|` = literal, else regex; JSON stdin/stdout via `host.execUnderPolicy`/`execDenial` gate; exit 2 = block; decision `additionalContext` merged; most-restrictive `deny>ask>allow`; single stdin transport DSH uses; gated by `[hooks] enabled=false`.

**Out of scope.** Codex dialect (always-regex), 23+ extra Claude events beyond the five in PRD 0028, `updatedInput` call-rewriting, live reload, non-command handler kinds.

## Current state

Today: `src/hooks/config.zig` + `src/hooks/runner.zig` exist as stubs with tests; `src/agent/loop.zig` `Agent.executeCalls` gates via `plan_mode` then `confirm_fn` (one site). `[hooks]` in `src/config.zig` is parsed but `[hooks] enabled=false` by default and no lifecycle point calls the runner. `confirm_writes` is the only pre-use gate.
Files touched by a full bridge: `src/hooks/*`, `src/config.zig:Hooks`, `src/agent/loop.zig` (5 hook sites), plus `host.execUnderPolicy` stdin/timeout plumbing already via `!cmd`.

## Options considered

### Option A — Claude-dialect bridge with DSH's dialect-neutral core (matcher, JSON decode, most-restrictive merge)

- **What it is:** Core owns matcher validation + JSON/stdout decode + merge (`deny>ask>allow`); Claude bridge owns payload shape/env substitution; exit 2 blocks, `additionalContext` is injected as synthetic context.
- **Maturity:** Claude `hooks.json` is shipped; DSH's `packages/hooks` proves the narrow core.
- **How it would fit:** `src/hooks/config.zig` validation + `src/hooks/runner.zig` decode/merge already exist; wire five points in `src/agent/loop.zig` (`PreToolUse` inside `executeCalls` between plan_mode and confirm_fn, `PostToolUse` after result, `UserPromptSubmit` before request assembly, `Stop` when run would end + one bounded extra step, `SessionStart` once at Agent construction) via `execUnderPolicy` stdin+timeout.
- **Pros:** Claude-compatible, small surface over existing gates.
- **Cons:** No Codex dialect yet; five extra points add loop surface.
- **Cost to adopt:** 1–2 weeks; narrow scope.
- **Cost to leave:** Remove the five sites + hook module.
- **Evidence:** PRD 0028 already describes the 5 points; DSH `packages/hooks` — verified tree.

### Option B — Reuse `confirm_fn` as the policy layer (no hooks.json)

- **What it is:** Keep `[hooks] enabled=false` and rely on `confirm_writes`/`plan_mode` for policy.
- **Maturity:** Already shipped.
- **How it would fit:** No code.
- **Pros:** Zero cost.
- **Cons:** Human-in-the-loop only; deterministic policy scripts (linters/notify/policy checks) still need rewriting as clanker-specific mechanisms; migration cost stays.
- **Cost to adopt:** Docs.
- **Cost to leave:** Docs.
- **Evidence:** `src/agent/loop.zig:confirm_fn` + `plan_mode` — verified.

### Option C — Status quo

## Implications by horizon

### Short term (this release / 0–3 months)

- **If A:** Existing Claude `hooks.json` linters/notify/policy carry over.
- **If B:** Users rewrite hooks as clanker-specific mechanisms.
- **If status quo:** Kimi parity gap stays open.

### Medium term (3–12 months)

- **If A:** Hooks compose with confirm/plan gates cleanly.
- **If B:** Ad-hoc rewrites multiply.
- **If status quo:** Parity debt remains.

### Long term (12+ months)

- **If A:** Stable minimal hook surface; easy to keep.
- **If B/C:** Growing migration friction.

## Recommendation

**Recommended option:** Adopt Option A — Claude-dialect bridge with dialect-neutral core (5 points, matcher/exit-code/JSON decode, most-restrictive merge)

**Confidence:** 8/10

**Why this confidence.** _State what evidence would raise it, and what finding would sink this recommendation._

**Rationale.** Lets existing Claude hooks.json linters/notify/policy transfer without rewriting, reusing DSH's narrow core and execUnderPolicy gate; B forces rewriting and C leaves parity open.

**Reversibility.** _How hard is this to undo, and where is the point of no return?_

## Open questions

- Whether Codex dialect support is needed next — defer until a user asks.

## Next steps / action items

- [ ] ADR 00XX; PRD 0028 checklist clear; wire 5 points and land `src/hooks/` behind `[hooks] enabled` (PRD 0028 Goals).
