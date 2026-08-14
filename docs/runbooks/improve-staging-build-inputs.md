# Runbook — improve staging build inputs

## TL;DR

- **Use when:** An improve-self staging build reports a missing local source
  file, especially a `file_hash FileNotFound` error.
- **Recover by:** Add the source directory containing that build input to
  `staging_roots`, then preserve the requirement with a regression test.
- **Verify with:** Build an isolated copy of the staging roots and confirm the
  original missing path exists there.

## Scope and preconditions

Use this for compile-gate failures that occur before a proposal's own change is
compiled. It applies when `build.zig` references a repository-local module or
asset root that the improve staging copier did not include. It does not apply
to a missing dependency fetched through `build.zig.zon`, a malformed proposal,
or a compiler error inside a copied source file.

The underlying incident is [Improve staging misses UI build inputs](../reports/bugs/2026-08-14-improve-staging-misses-ui-build-inputs.md), resolved by
[`e10c868`](../src/improve/engine.zig).

## Diagnose

Read the failing path as a build input, not as a proposed edit: if unrelated
proposals report the identical missing path, the common staging tree is the
suspect. Then locate the corresponding local module declaration in `build.zig`
and compare its root directory with `staging_roots` in
`src/improve/engine.zig`.

If the root is already listed, follow the copy operation and investigate file
permissions or a path-specific copier failure. If it is absent, the staging
policy and build graph have diverged.

## Recover

Add the smallest directory root that contains the module source file to
`staging_roots`; do not copy a single generated or vendored leaf while omitting
the module's other inputs. Add a regression that asserts the root remains in
the list. Keep that test in the existing test section of `engine.zig`: several
source-shape tests deliberately define production source as everything before
the first test block.

## Verify

Copy the complete staging-root set to a fresh directory and run `zig build`
there. The prior missing path must be present and the build must finish. Then
run the normal project gate from a checkout without unrelated work in progress.

If either check still reports a missing local path, create or update an
investigation before changing additional roots.

## Escalate or follow up

Open a new investigation when the build input comes from a dependency rather
than the repository, when the copier logs a read/write failure, or when copying
the root creates a materially unsafe staging surface. Otherwise update the
linked bug report with the new root and verification evidence.

## References

- Report: [Improve staging misses UI build inputs](../reports/bugs/2026-08-14-improve-staging-misses-ui-build-inputs.md)
- Code: [`src/improve/engine.zig`](../src/improve/engine.zig), [`build.zig`](../build.zig)
- Last verified: 2026-08-14, `e10c868`
