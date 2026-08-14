# Investigation — improve staging omits `ui/`

## TL;DR

- **Question:** Why does every improve-self proposal fail its staging build
  before its own change is evaluated?
- **Finding:** The staging copier excludes the repository's `ui/` directory,
  but `build.zig` unconditionally creates a module rooted at `ui/vendor.zig`.
  Every staged `zig build` therefore fails before it can assess a proposal.
- **Resolution:** Pending. Copy `ui/` into staging and add a regression that
  proves a staged build has the build inputs it requires.

## Status

Cause identified from the supplied run log and source trace. The fix and its
regression verification are still required before this investigation is
resolved.

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

## Resolution or handoff

1. Add `ui` to `staging_roots` in `src/improve/engine.zig`; do not add
   `ui/vendor/` as a separately mutable surface, since it is vendored content.
2. Add a regression at the staging boundary: it must fail if a staged tree
   lacks `ui/vendor.zig` and prove that the staging build can reach the proposal
   gate once the source tree is complete.
3. Run the normal gate, plus a direct improve-self or focused staging-build
   reproduction that demonstrates the prior `file_hash FileNotFound` error is
   gone.
4. Create the linked bug report from
   [`../bugs/TEMPLATE.md`](../bugs/TEMPLATE.md) if the final resolution needs a
   user-facing defect record; update this report with the commit, checks, and
   final status.
5. If the resolution exposes a repeatable staging diagnosis, add its current
   recovery procedure to [`docs/runbooks/`](../../runbooks/) and link it here.

## References

- Report index: [Operational reports](../README.md)
- Build input: [`build.zig`](../../../build.zig)
- Staging copy: [`src/improve/engine.zig`](../../../src/improve/engine.zig)
- Supplied run log: attached prompt, 2026-08-14
