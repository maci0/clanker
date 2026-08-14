# Bug — improve staging omits release-contract files

## TL;DR

- **What failed:** Every improve-self proposal reached the staging test gate
  but failed the same release-contract test before its own change was judged.
- **Impact:** Unrelated proposals were retried and rejected for a shared
  baseline failure.
- **Resolution:** Improve-readable roots are now the source of the staging
  tree, with `vendor/` retained as the one build-only dependency.

## Status

Resolved on 2026-08-14.

## Symptom and impact

The supplied run repeatedly failed `releaseContractGate accepts the live
release files`. The gate reads `CHANGELOG.md` and `RELEASES.md`, but neither
file existed in staged proposal directories. Attempts three through five in the
log demonstrate the failure is independent of the proposed change.

## Reproduction

Copy the former hand-maintained staging roots into a fresh directory, omitting
`CHANGELOG.md` and `RELEASES.md`, then run `zig build test`. The release-contract
test reads those files relative to the staged current directory and fails before
any proposal-specific behavior can be assessed.

## Root cause

The staging and improve-readable surfaces were separate hand-maintained lists.
The readable surface already admitted both release files, while the staging
allowlist omitted them. The earlier UI omission showed the same class of drift:
one policy changed without updating the other.

## Resolution

`src/improve/proposal.zig` now exports `readable_roots`; the engine derives
`staging_roots` from it and adds only `vendor/`, which is a local build
dependency deliberately withheld from model context. Tests assert that the
release files remain readable and that every readable root is staged.

## Verification

- `zig build test` passed in the isolated fix worktree.
- Two independently created staging trees each completed `zig build`, `zig
  build tools`, and `zig build test` successfully.
- Both runs exercised the release-contract test without the former missing-file
  failure.

## Follow-up

Use the [improve staging build inputs runbook](../../runbooks/improve-staging-build-inputs.md) when a future gate reads a root that is intentionally excluded
from model context.

## References

- Earlier incident: [Improve staging misses UI build inputs](2026-08-14-improve-staging-misses-ui-build-inputs.md)
- Runbook: [Improve staging build inputs](../../runbooks/improve-staging-build-inputs.md)
- Code: [`src/improve/proposal.zig`](../../../src/improve/proposal.zig), [`src/improve/engine.zig`](../../../src/improve/engine.zig)
