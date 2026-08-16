# Runbook — improve-self staging tests blocked by cwd-dependent and Io.Io mismatches

## TL;DR

- **Use when:** Improve-self iterations fail their staging `zig build test` for two reasons: (1) the `fsWriteIfImpl creates missing parent directories` test used a `state/` sub_path, but every improve staging worktree has `state/` as a symlink (linkSharedState), so safeJoinSecure reports it as an escape and the test fails every run; (2) a test in src/cli.zig passed `std.Io.Threaded` where `Io` was required (fixed with `io.io()`). Both are fixed so the improve loop can land changes again.
- **Recover by:** Determine the current verified procedure.
- **Verify with:** The linked report's verification steps.

## Scope and preconditions

## Diagnose

## Recover

## Verify

## Escalate or follow up

## References

- Report: none yet
## Diagnose

- The improve-self run ends each iteration with `iteration N: all attempts failed`, and the staging log shows `staging tests failed` plus `run test` / `run node failure` lines and a Zig compile error.
- Zig compile error pattern: `error: expected type 'Io', found 'Io.Threaded'` at a `std.Io.Dir.*` call site. The test built a `std.Io.Threaded` and passed it where the std `Io` interface is required.
- Node `node --test` failures on `ui/app/core/*.test.mjs` are usually a consequence of the same broken staged tree (the worktree was snapshotted before the fix), not independent defects — re-run them against the fixed tree before chasing them.
- The `fsWriteIfImpl creates missing parent directories` test fails with `expected 0, found 1` at `expectEqual(Err.ok, rc)` only when the cwd has `state/` as a symlink — i.e. in every improve staging worktree (linkSharedState) and in any checkout that symlinks `state`. safeJoinSecure resolves `./state` as an escape (`Err.denied`).

## Recover

1. Fix `Io` vs `Io.Threaded`: call `.io()` on the threaded instance before passing it to `std.Io.Dir.*` functions. Example: `std.Io.Dir.cwd().writeFile(io.io(), ...)`.
2. Make cwd-dependent sandbox tests hermetic: do not use `state/...` (or any shared/symlinked prefix) as a sub_path against the process cwd. Use a throwaway nested path such as `sub/dir/schedule.json` — no `sub` component exists in the checkout root, so safeJoinSecure does not resolve a cwd symlink. The test still exercises missing-parent-directory creation.

## Verify

- In the main checkout: `zig build test --summary all` passes (the `clanker gate` test phase).
- In an improve staging worktree (a fresh `imp-*` under `state/staging/` with `state` symlinked): the same test passes, so a real improve-self iteration can land.

## Escalate or follow up

- If a *new* `state/...` sub_path is introduced into a test that hits the disk via the sandbox, the staging worktree will fail again for the same reason. Prefer tmp-dir-relative or non-shared paths in tests.
