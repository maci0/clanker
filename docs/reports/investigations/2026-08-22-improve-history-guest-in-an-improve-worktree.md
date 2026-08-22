# Investigation — improve_history is granted a path that is a symlink inside an improve-self worktree

## TL;DR

- **Question:** `improve_history` declares `fs_prefixes: ["state/improvements.jsonl"]`, and `linkSharedState` makes that exact path a leaf symlink in every improve-self worktree. `safeJoinSecure` stats the leaf as well as the directories above it and refuses a symlink, and `cmdImproveSelf` never sets `cfg.agent.shared_root`, so the guest's path resolves inside the worktree and meets the link. Traced from source at 03a79fef on 2026-08-22; not reproduced live.
- **Finding:** Investigating.
- **Resolution:** Pending.

## Status

Investigating.

## Trigger and scope

Surfaced while surveying what an improve-self worktree shares under `state/` for
[RFC 0036](../../rfcs/0036-improve-worktree-runtime-state-sharing.md) and
[the research note](../../research/improve-worktree-runtime-state-sharing.md).
It was not the object of that work and is not reproduced here; it is filed so
the trace is not lost.

Scope is one tool, `improve_history`, and one situation, a `clanker improve-self`
run, which is the only caller of `worktree.create` with `Sharing.improve`.

## Evidence

Every line below was read in the tree at `03a79fef` on 2026-08-22.

1. The manifest grants the file by name: `tools/manifests/improve_history.tool.json`
   has `"fs_prefixes": ["state/improvements.jsonl"]`.
2. `linkSharedState` makes that path a symlink in the worktree:
   `src/improve/worktree.zig:874-883` loops over
   `{"state/improvements.jsonl", "state/history"}` and calls
   `std.Io.Dir.cwd().symLink(io, target, link_path, .{})` for each.
3. `safeJoinSecure` refuses a symlinked **leaf**, not only a symlinked
   directory: `src/sandbox/host.zig:5838-5850` walks the resolved path and, on
   the final pass, `findScalarPos` returns null so `end = full.len` and the
   `statFile(..., .{ .follow_symlinks = false })` is taken on the whole path.
   `if (stat.kind == .sym_link) return error.PathOutsideSandbox;`
4. The improve-self run's sandbox has no `shared_root` to route around it:
   `cmdImproveSelf` (`src/cli.zig:6388-6407`) creates the worktree and calls
   `std.process.setCurrentPath(io, created.path)`, and never assigns
   `cfg.agent.shared_root`. The only two assignments in the tree are
   `src/cli.zig:4155` and `src/cli.zig:15647`, both on the plain isolated-run
   path (`Sharing.run`), not this one.

So the guest's `state/improvements.jsonl` resolves under the worktree root,
where step 2 put a symlink, and step 3 refuses it.

The existing bug report
[guest writes refused under symlinked state](../bugs/2026-08-16-guest-writes-refused-under-symlinked-state.md)
is the same refusal one level up (a symlinked `state/` **directory**); this is
the leaf case, which that report does not cover.

## Hypotheses and tests

**Not yet tested.** Two ways to settle it, either of which would turn this into
a bug report or close it:

1. Run `clanker improve-self` with an instruction whose task makes the agent
   call `improve_history`, and read whether the tool result is the history or a
   `PathOutsideSandbox` refusal.
2. Cheaper and deterministic: a unit test beside the two existing symlink tests
   in `src/sandbox/host.zig` (`secure filesystem paths refuse symlink escapes`
   at line 6036 and `safeJoinSecure refuses a symlinked component unless the
   sandbox opts in` at line 7591). Both existing tests link a **directory**;
   neither links the granted leaf, which is why the case is unpinned.

The counter-hypothesis worth checking first: `linkSharedState`'s own comment
(`src/improve/worktree.zig:857-872`) asserts the links are safe because they are
"leaves the sandboxed tools never traverse through". If that is right for
`improve_history` it can only be because the tool is not in the improve run's
registry, and the manifest gives no sign of that — it is `"category": "harness"`
with no `internal` flag.

## Finding

## Resolution or handoff

Handed to whoever picks up the sandbox surface. Nothing here was changed: this
investigation was opened from a docs-only branch whose scope was the decision
record, so the code was read and not touched.

If test 2 above confirms the refusal, the two candidate fixes are the same two
the research note lists for `token_stats.jsonl`: set `cfg.agent.shared_root` on
the improve-self path so `rootForPath` routes `state/` to the checkout the way
`Sharing.run` does, or drop the manifest grant and give the guest the data
through a host channel.

## References

- Research: [What an improve-self worktree shares, copies and discards under state/](../../research/improve-worktree-runtime-state-sharing.md)
- Decision: [RFC 0036 — improve worktree runtime state sharing](../../rfcs/0036-improve-worktree-runtime-state-sharing.md)
- Related bug: [guest writes refused under symlinked state](../bugs/2026-08-16-guest-writes-refused-under-symlinked-state.md) — the same refusal on a symlinked directory rather than a leaf
