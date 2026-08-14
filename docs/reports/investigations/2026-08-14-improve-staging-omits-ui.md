# Investigation — improve staging omits `ui/`

## TL;DR

- **Question:** Why does every improve-self proposal fail its staging build
  before its own change is evaluated?
- **Finding:** The staging copier excludes the repository's `ui/` directory,
  but `build.zig` unconditionally creates a module rooted at `ui/vendor.zig`.
  Every staged `zig build` therefore fails before it can assess a proposal.
- **Resolution:** [`e10c868`](../../../src/improve/engine.zig) adds `ui` to
  the staging roots and a regression that prevents it from being removed.

## Status

Resolved. The supplied run log and source trace identified the missing root;
the staged-tree build now succeeds with `ui/` copied into the compile gate.

## Trigger and scope

The improve-self run repeatedly logged `failed to check cache: 'ui/vendor.zig'
file_hash FileNotFound` while building separate directories below
`state/staging/imp-*`. The failure recurred across unrelated proposals, so it
blocks the loop rather than indicating a defect in any one proposal.

## Evidence

- **Observed:** The supplied log records the same missing `ui/vendor.zig` error
  for consecutive staging builds, including attempts 83 through 88.
- **Observed:** [`build.zig`](../../../build.zig) creates the `vendor` module
  from `ui/vendor.zig` for both the executable and test build graphs.
- **Observed:** [`src/improve/engine.zig`](../../../src/improve/engine.zig)
  defines `staging_roots` as `src`, `tools`, `tests`, `docs`, `evals`, `vendor`,
  and top-level build files, but not `ui`.
- **Observed:** `prepareStaging` copies only `staging_roots` into
  `state/staging/<id>` before it calls the build gate.

## Hypotheses and tests

| Hypothesis | Check | Result |
|---|---|---|
| A proposal removed `ui/vendor.zig` | The failure occurs for unrelated proposals before promotion; staging begins from a copied tree. | Rejected |
| The build does not require `ui/vendor.zig` | `build.zig` unconditionally constructs a module rooted at that file. | Rejected |
| The staging copy is incomplete | `ui` is absent from `staging_roots`, while the build requires a file below it. | Confirmed |

## Finding

The gate builds a deliberately reduced staging tree. Its root allowlist was
updated for local `vendor/` dependencies but not for the separate `ui/` build
input. The missing directory means Zig cannot hash the root source file for the
`vendor` module, so compilation stops before a proposal's code can be judged.
The retry loop then asks for another proposal, which cannot change that shared
failure condition.

## Resolution

[`e10c868`](../../../src/improve/engine.zig) adds `ui` to `staging_roots`.
`prepareStaging` already copies every root in that list recursively, so this
carries `ui/vendor.zig` and the vendored assets it embeds into every proposed
change's build tree. The regression test asserts that `ui` remains a staging
root.

The normal test suite executed that new regression. Its final process status
was non-zero because separately uncommitted graph-tool work in the shared
checkout failed its own runtime test; the staging fix itself was independently
verified by building an isolated copy of exactly the staging roots.

The confirmed defect is recorded in the linked [bug report](../bugs/2026-08-14-improve-staging-misses-ui-build-inputs.md). The current recovery procedure
is in the [runbook](../../runbooks/improve-staging-build-inputs.md).

## References

- Report index: [Operational reports](../README.md)
- Build input: [`build.zig`](../../../build.zig)
- Staging copy: [`src/improve/engine.zig`](../../../src/improve/engine.zig)
- Fix: [`e10c868`](../../../src/improve/engine.zig)
- Bug: [Improve staging misses UI build inputs](../bugs/2026-08-14-improve-staging-misses-ui-build-inputs.md)
- Runbook: [Improve staging build inputs](../../runbooks/improve-staging-build-inputs.md)
- Supplied run log: attached prompt, 2026-08-14
