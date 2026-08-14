# Bug — Worktree setup rejects a symlinked checkout state directory

## TL;DR

- **What failed:** `linkCheckoutState` uses `createDirPath` on `state` even when it is a symlink to a directory, yielding `NotDir` and aborting all shared-path links.
- **Impact:** Isolated runs can split host-side state from the checkout.
- **Resolution:** Resolved in the worktree provisioning path and covered by a
  regression test.

## Status

Resolved and verified.


## Symptom and impact

An isolated plain run warns `could not link the checkout's shared paths into the worktree: NotDir`. The run still proceeds, but it has a worktree-local `state/` and lacks checkout links for `.local`, `.agents`, `.env`, and `config.local.toml`. Host-side state writes can therefore diverge from the checkout-wide state the sandbox uses.

## Reproduction

1. Configure the checkout `state` path as a symlink to a directory.
2. Enable `agent.isolated_cli` and start a plain `clank run`.
3. Worktree provisioning reaches `linkCheckoutState`, calls `createDirPath("state")`, and returns `NotDir`.

## Root cause

`src/improve/worktree.zig` provisions every shared directory with `std.Io.Dir.cwd().createDirPath`. Zig rejects a final symlink even when it resolves to a directory. `src/util/ensure_dir.zig` exists specifically to turn that expected result into success by following the link, but `linkCheckoutState` does not use it.

## Resolution

`linkCheckoutState` now delegates directory creation to
`ensure_dir.ensureDir`, which follows a final symlink when it resolves to a
directory. The `linkCheckoutStateAt` regression test provisions a temporary
checkout whose `state/` is a symlink, then verifies that its worktree links
the shared directories and an optional local file.

## Verification

The regression test and the full unit suite pass with `zig build test`.
`zig build`, `zig build tools`, `zig build e2e`, and repository-wide
`zig fmt --check` also pass.

## Follow-up

- Investigation: `docs/reports/investigations/2026-08-14-isolated-cli-worktree-notdir.md`
