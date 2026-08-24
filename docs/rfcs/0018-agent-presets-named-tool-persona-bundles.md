# RFC 0018 — Agent presets: named tool + persona bundles

## Status

Decided — 2026-08-17. Decided as ADR 0030

## Overview

Every session gets the same tools and prompt today; there is no way to hand one session a restricted, enforceable bundle (research-only with no writes, ops runbook with only exec+gh) without editing global config. Feynman audit proposes role files that only change what the model is told, never what it can call; DSH agent-presets combine persona + actual tool allow/deny. Need to choose preset storage, selection, and enforcement.

**Decision to make.** Which preset mechanism do we adopt so a session can be started with a named, enforceable tool + persona bundle without editing global config?

**Why now.** PRD 0033 is still Draft with no files; ROADMAP Planned (DeepSeek follow-ups) lists agent presets as open while loop-guard/pruning/hooks already shipped — the queue head is this preset.

**Drivers.** WASM-by-default (preset filters WASM registry, does not spawn outside sandbox), static tool manifest model (no Cordis standing mounts), list-of-roots precedent from PRD 0022, `plan_mode`/`confirm_writes` predicate reuse for write-capable filtering, no new hard dependency.

**Out of scope.** Per-preset sampling knobs (PRD 0024), live watcher/hot-reload, web UI authoring flow, per-preset secrets vaulting.

## Current state

Today: every `Agent` gets the same `Registry` tool set from `agent.tools_dir` plus the same system prompt; `subagent`'s free-text task is the only per-session steering, and it is advisory only. `docs/prompts/` has persona markdown but no registry filter; `config.toml` has no per-session override. Workaround is editing `config.toml` or hand-writing a task that says "don't use writes" — not enforceable.

## Options considered

### Option A — preset.toml multi-root with registry filter (PRD 0033 shape)

- **What it is:** One `preset.toml` per preset under a list of roots (shipped + user dir, like `tools_dir`), with `description`, `system_prompt_append`, `tools_allow`/`tools_deny` patterns, optional `default_provider`/`model`; `--preset <name>` / `/preset <name>` filters the already-loaded Registry before the first request.
- **Maturity:** PRD 0033 Draft; DSH `agent-presets`/`persona` as product-shape precedent (Cordis standing-mount/watcher machinery intentionally not copied).
- **How it would fit:** New `presets/` dir or `agent.preset_dirs` config, `src/agent/presets.zig` + `src/cli.zig` flag/parsing + REPL `/preset` command; filter in `Agent` init; `research`/`full` examples.
- **Pros:** Enforceable (deny via same predicate plan_mode uses), selectable per session, ships examples.
- **Cons:** New dirs + CLI surface to maintain.
- **Cost to adopt:** ~1 week; no new dep.
- **Cost to leave:** Delete presets/ + flag; no migration.
- **Evidence:** `docs/prds/0033-agent-presets.md` — verified; `docs/research/deepseek-harness-plugins.md` — unverified.

### Option B — Config-only tool filter (no preset files)

- **What it is:** `agent.preset_tools_allow` style config knob that filters the registry, without per-preset files or persona text.
- **Maturity:** Hypothetical; prior art is `config.toml` filtering.
- **How it would fit:** `src/config.zig` + `src/agent/loop.zig` filter only.
- **Pros:** Smallest code.
- **Cons:** No persona bundling, no multi-preset inventory, no `preset new` scaffolding.
- **Cost to adopt:** Days.
- **Cost to leave:** Revert config field.
- **Evidence:** `config.toml` `agent.tools_dir` — verified.

### Option C — Role prompt files under docs/prompts (out-of-the-box)

- **What it is:** Ship `docs/prompts/research.md` style persona files and reference them by name in the `subagent` task, no registry filter — already in tree, zero code.
- **Maturity:** Existing `docs/prompts/` + `subagent` free-text task — verified in tree.
- **How it would fit:** Add markdown files only; no code change.
- **Pros:** Zero code, reuses existing surface.
- **Cons:** Advisory only — model can still call a write tool despite persona; not enforceable.
- **Cost to adopt:** Hours.
- **Cost to leave:** Delete files.
- **Evidence:** `docs/prompts/` — verified; Feynman audit note — verified.

### Option D — Status quo

- **What it is:** Keep one global tool set and prompt for every session; steer per task with free-text instructions.
- **Pros:** No work.
- **Cons:** No enforceable research-only or runbook bundles; queue item stays open.
- **Cost to adopt:** Zero now; parity gap remains.
- **Evidence:** Current `src/agent/loop.zig` + `Registry` — verified.

## Implications by horizon

### Short term (this release / 0–3 months)

- **If A:** Enforceable per-session bundles land; `research` preset proves read-only is enforceable not just suggested.
- **If B:** Filter but no persona/example inventory; still better than advisory.
- **If C:** Persona only, gap remains for enforceability.
- **If D:** No change; queue stays blocked.

### Medium term (3–12 months)

- **If A:** Presets compose with future per-session MCP server scoping (PRD 0032 follow-on).
- **If B/C/D:** Still no bundled allow/deny surface to compose.

### Long term (12+ months)

- **If A:** Sustainable preset catalog alongside sampling profiles (orthogonal axes).
- **If B/C/D:** Same ceiling as today.

## Recommendation

**Recommended option:** Adopt Option A — preset.toml multi-root with registry filter

**Confidence:** 7/10

**Why this confidence.** _State what evidence would raise it, and what finding would sink this recommendation._

**Rationale.** Only Option A gives enforceable allow/deny plus persona in a named bundle per session; out-of-box role files are advisory only and config-only filter has no inventory.

**Reversibility.** _How hard is this to undo, and where is the point of no return?_
