# Investigation — improve-self gate tool build failure (appendWriteFn) and follow-up

## TL;DR

- **Question:** improve-self iterated on tools/zig/gate.zig and produced a build error: `use of undeclared identifier 'appendWriteFn'` at gate.zig:136. Zig 0.16 removed std.Io.Writer's writeFn init in favor of std.Io.Writer.Allocating. Fixed in commit 4ecf02bc by using std.Io.Writer.Allocating. Follow-up (uncommitted): src/config.zig doc-coverage test switch from runtime cwd readFileAlloc to @embedFile("config_toml") so the improve staging worktree no longer needs config.toml on disk for the test to pass.
- **Finding:** Investigating.
- **Resolution:** Pending.

## Status

Investigating.

## Trigger and scope

## Evidence

## Hypotheses and tests

## Finding

## Resolution or handoff

## References

- Related bug: none yet
