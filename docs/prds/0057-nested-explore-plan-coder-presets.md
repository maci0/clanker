# PRD — Nested explore/plan/coder presets

## Status

Draft — opened 2026-08-21. Name the source files that are the single source of truth, and the surfaces that expose it.

## Problem

ck_subagent is one generic nested Agent. explore is a polite request the model can ignore by writing files.

## Goals

1. Ship explore/plan/coder preset.toml.  2. subagent_type names one, default coder.  3. tools_deny is enforced.  4. Nested types do not recurse.  5. Tests refuse a write from explore.

## Design

**Presets.** Ship presets/explore.toml (deny writes and exec), plan.toml (deny exec), coder.toml (current default). subagent_type names one. Nested types do not recurse.

**Dependencies.** Hard: ADR 0046, ADR 0030, tools/zig/subagent.zig.

**Implementation.**
1. later: three preset files + subagent_type. Files: presets/explore.toml, presets/plan.toml, presets/coder.toml, tools/zig/subagent.zig, src/agent/loop.zig.

## Non-goals
Host enum of types. Prompt-only explore.

## Failure modes
| Condition | Behaviour |
|---|---|
| explore calls edit_file | refused |
| unknown type | fail the tool call |

## Acceptance criteria
1. [ ] explore denies writes (Goal 3)
2. [ ] default type is coder (Goal 2)

## Open questions / future work
Recurse allowlist later.
