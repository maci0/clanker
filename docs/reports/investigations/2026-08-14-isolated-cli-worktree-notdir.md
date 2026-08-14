# Investigation — Unexpected worktree from isolated_cli and NotDir shared-state warning

## TL;DR

- **Question:** A plain clank run unexpectedly entered a worktree and emitted NotDir while linking shared paths.
- **Finding:** `isolated_cli` enabled the worktree; a symlinked `state` exposed a provisioning defect.
- **Resolution:** The configured isolation behavior was retained; the
  symlink-safe provisioning defect was fixed and tested.

## Status

Resolved.

## Trigger and scope

The affected command was a plain `clank run` in this checkout.


## Evidence

- `config.local.toml` sets `isolated_cli = true`; `shouldIsolate` returns true for a plain run when that setting is true. This is independent of `agent.worktree`, so the worktree was configured, not spontaneous.
- The checkout `state` entry is a symlink to `/home/yannick/code/ywy50/clanker-state/state`. `linkCheckoutState` calls `createDirPath("state")`; `src/util/ensure_dir.zig` documents and tests that this exact operation returns `NotDir` for a symlink to a directory.
- The error occurs before the loop creates any links, which matches the affected run: its worktree has a private `state/` directory and no `.local`, `.agents`, `.env`, or `config.local.toml` links.

## Finding

Two independent causes were confirmed. `isolated_cli = true` deliberately turns on worktree isolation for every plain `clank run`. The `NotDir` warning is a defect in `src/improve/worktree.zig`: it uses `createDirPath` where the project utility `ensureDir` is required for the symlinked `state/` configuration.

## Resolution or handoff

- To run in the checkout now, pass `--no-worktree` or set `isolated_cli = false`.
- `linkCheckoutState` now uses `ensure_dir.ensureDir` for shared runtime
  directories and has a regression test that provisions a symlinked checkout
  `state/` and verifies its worktree links.

## References

- Related bug: `docs/reports/bugs/2026-08-14-worktree-state-symlink-notdir.md`
