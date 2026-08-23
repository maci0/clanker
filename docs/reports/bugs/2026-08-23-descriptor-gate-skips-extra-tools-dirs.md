# Bug — improve gate skipped extra in-tree tools_dir entries

## TL;DR

- **What failed:** The improve engine ran toolDescriptorGate only on the hardcoded tools/manifests, so a descriptor staged in a second in-tree tools_dir entry reached a promoted checkout with no duplicate-name or missing-wasm check. PRD 0022's anti-cheat rationale only covers out-of-tree entries. Fixed by gating every configured in-tree entry; out-of-tree entries stay ungated by design.
- **Impact:** A self-improve proposal could ship a tool descriptor that shadows an existing tool name or points at a wasm that was never built, provided it staged the file in a configured `tools_dir` entry other than `tools/manifests`. The promoted checkout then loads it with none of the checks every `tools/manifests` descriptor passes.
- **Resolution:** Resolved on 2026-08-23. The improve engine gates every configured in-tree tools_dir entry (src/improve/engine.zig), skipping absolute and ..-escaping entries by design. Verified by the inTreeToolsDir unit test and the full local gate; PRD 0022 Known issues updated.

## Status

Resolved on 2026-08-23. The improve engine gates every configured in-tree tools_dir entry (src/improve/engine.zig), skipping absolute and ..-escaping entries by design. Verified by the inTreeToolsDir unit test and the full local gate; PRD 0022 Known issues updated.

## Symptom and impact

PRD 0022 made `agent.tools_dir` a list, and `Registry.load` scans every
entry. The improve engine's descriptor gate did not follow: it called
`gate_checks.toolDescriptorGate` exactly once, on the string literal
`"tools/manifests"` (src/improve/engine.zig:1056). A descriptor placed in a
second configured directory was loaded by every promoted run but was never
checked for duplicate names or missing wasm — the two defects the gate
exists to catch, one of which (`.wasm` missing) is the breakage
`clanker doctor` calls the most common in this repo.

The PRD's Known issues bullet declared the single walk intentional — "an
out-of-tree plugin is not part of a promoted checkout" — which is true for
absolute paths and `..`-escaping entries, and says nothing about a second
*in-tree* entry, which is part of the promoted checkout.

## Reproduction

Configuration-level, no model needed: set
`tools_dir = ["tools/manifests", "third-party/manifests"]`, stage a
descriptor under `third-party/manifests/` whose `name` duplicates an
existing tool (or whose wasm path does not exist), and run the improve
gates. Before the fix the descriptor gate reported ok because it never
opened the second directory.

## Root cause

`src/improve/engine.zig:1056` hardcoded the gated directory instead of
iterating `self.cfg.agent.tools_dir`. The gate function itself takes any
directory; only the call site was narrow.

## Resolution

The engine now iterates every configured `tools_dir` entry (falling back to
`tools/manifests` when the list is empty) and runs `toolDescriptorGate` on
each in-tree entry against the staged worktree. Entries that are absolute
or escape with `..` are skipped: they are not part of the promoted
checkout, so the staged-worktree gate cannot and should not open them (the
anti-cheat boundary the PRD describes, now scoped to the case it actually
covers). Gate failures name the directory in the detail so a multi-dir
config points at the right file.

## Verification

- `inTreeToolsDir` is unit-tested (in-tree kept, absolute / `..` /
  `tools/../../outside` / empty skipped) in src/improve/engine.zig.
- The default single-directory configuration exercises the same loop with
  one entry, covered by the full test suite and the improve engine's gate
  invariants (`gate_checks.toolDescriptorGate(` is a pinned needle).
- PRD 0022's Known issues bullet updated to record the fix and the
  now-scoped boundary.

## Follow-up

## References

- PRD 0022 (docs/prds/0022-out-of-tree-tools.md) — Known issues, Failure modes.
- src/improve/engine.zig — the gate loop and `inTreeToolsDir`.
- src/gate/checks.zig — `toolDescriptorGate` itself, unchanged.
