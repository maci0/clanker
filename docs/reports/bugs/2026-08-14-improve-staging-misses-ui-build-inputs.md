# Bug — improve staging misses UI build inputs

## TL;DR

- **What failed:** Every improve-self proposal failed its staged `zig build`
  before the proposal could be evaluated.
- **Impact:** The self-improvement loop retried unrelated proposals without a
  chance of promotion.
- **Resolution:** [`e10c868`](../../../src/improve/engine.zig) copies `ui/`
  into each staging tree, including the `ui/vendor.zig` module required by the
  build graph.

## Status

Resolved on 2026-08-14. Investigation:
[Improve staging omits `ui/`](../investigations/2026-08-14-improve-staging-omits-ui.md).

## Symptom and impact

The improve gate logged `failed to check cache: 'ui/vendor.zig' file_hash
FileNotFound` for each staging directory. Because the compiler constructs the
UI vendor module before it evaluates the proposal, every retry failed in the
same way.

## Reproduction

Start from a repository where `build.zig` creates the vendor module from
`ui/vendor.zig`, then copy only the former staging roots into a clean directory
and run `zig build` there. Without `ui/`, Zig cannot hash the module's root
file. This was the state of improve-self staging before the fix.

## Root cause

The staging copier deliberately uses an allowlist rather than cloning the
whole repository. That allowlist already included `vendor/` for the TOML module
but omitted the separate `ui/` root used by the UI vendor module. The build
description and the staging policy therefore disagreed about required inputs.

## Resolution

The fix adds `ui` to `staging_roots` in
[`src/improve/engine.zig`](../../../src/improve/engine.zig). `prepareStaging`
copies each root recursively, so the UI module and the files it embeds now
arrive in the staged build. A unit test asserts that `ui` remains in the list.

## Verification

- An isolated copy of the exact staging roots, now including `ui/`, completed
  `zig build` successfully and contained `ui/vendor.zig`.
- `zig build test` executed the new regression. The suite's final failure was
  an unrelated graph-WASM runtime test from separate uncommitted work in the
  shared checkout, not this staging path.

## Follow-up

Before adding another local module to `build.zig`, compare its root source file
with `staging_roots`. The companion runbook makes that check repeatable.

## References

- Investigation: [Improve staging omits `ui/`](../investigations/2026-08-14-improve-staging-omits-ui.md)
- Runbook: [Improve staging build inputs](../../runbooks/improve-staging-build-inputs.md)
- Fix: [`e10c868`](../../../src/improve/engine.zig)
