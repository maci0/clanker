# Investigation — improve_history is granted a path that is a symlink inside an improve-self worktree

## TL;DR

- **Question:** `improve_history` declares `fs_prefixes: ["state/improvements.jsonl"]`, and `linkSharedState` makes that exact path a leaf symlink in every improve-self worktree. `safeJoinSecure` stats the leaf as well as the directories above it and refuses a symlink, and `cmdImproveSelf` never sets `cfg.agent.shared_root`, so the guest's path resolves inside the worktree and meets the link. Traced from source at 03a79fef on 2026-08-22; not reproduced live.
- **Finding:** Confirmed, and worse than traced: the refusal is not reported as an error. The guest maps every read failure to "no history yet", so an improve-self run is told it has never attempted anything.
- **Resolution:** Resolved on 2026-08-23. Reproduced by a unit test, then fixed: improve_history takes the ledger over the new ck_improve_history host channel and its fs_prefixes grant is gone. Checked by sandbox.runtime test (fails with a dangling link, and would fail again if the read went back through the sandbox fs) plus a live before/after in an improve-worktree-shaped dir: pre-fix 37 bytes and the model said NO-HISTORY, post-fix 163 bytes and both records.

## Status

Resolved on 2026-08-23. Reproduced by a unit test, then fixed: improve_history takes the ledger over the new ck_improve_history host channel and its fs_prefixes grant is gone. Checked by sandbox.runtime test (fails with a dangling link, and would fail again if the read went back through the sandbox fs) plus a live before/after in an improve-worktree-shaped dir: pre-fix 37 bytes and the model said NO-HISTORY, post-fix 163 bytes and both records.

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

Test 2 was the route taken, and it confirmed the trace. A sandbox rooted at a
worktree whose granted leaf `state/improvements.jsonl` is an absolute symlink to
a sibling checkout's real file does not return the history.

The part the trace did not predict is the shape of the failure. It is not an
error the model can see. `tools/zig/history.zig` wrapped the read in
`catch return lib.fail(out, "no history yet")`, so `PathOutsideSandbox` came back
as a 37-byte `{"ok":false,"error":"no history yet"}`. An improve-self run asking
what it had already tried was told it had never tried anything, which is the one
answer that makes the loop repeat its own failures. The counter-hypothesis in
"Hypotheses and tests" is settled too: the tool IS in the improve run's
registry, so `linkSharedState`'s comment was simply wrong.

Live, in an improve-worktree-shaped directory with the same prompt and provider:
the pre-fix binary returned 37 bytes and the model answered `NO-HISTORY`; the
fixed binary returned 163 bytes and the model read back both records.

## Resolution or handoff

Fixed by the second of the two candidates: the manifest grant is gone and the
guest takes the ledger over a host channel.

The first candidate (`cfg.agent.shared_root` on the improve-self path) was
considered and rejected. `rootForPath` routes every entry in `shared_prefixes`,
not just this one, so it would also send `state/learnings.md` to the checkout and
break the one-way promotion an improve worktree is built around. Setting
`agent.sandbox_follow_symlinks` was rejected outright: ADR 0017 says nothing may
set it implicitly.

The channel is `ck_improve_history` (`ckImproveHistory` in
`src/sandbox/host.zig`), name-gated to `improve_history` the way `ck_stats` is
gated to `model_stats`, capped at 256 KiB on a line boundary via
`src/util/tail.zig`. `fs_prefixes` on the manifest is now empty, so the tool has
no filesystem reach at all. An absent ledger is returned as an empty reply and
rendered as "(no improvements recorded yet)"; every other failure is reported as
a read error, so a refusal can never again be rendered as an empty history.

This also makes `linkSharedState`'s stated rule true rather than aspirational:
a symlink under `state/` is now genuinely only read by the host. A comment there
says so and says not to add a guest grant for anything in that list.

## References

- Research: [What an improve-self worktree shares, copies and discards under state/](../../research/improve-worktree-runtime-state-sharing.md)
- Decision: [RFC 0036 — improve worktree runtime state sharing](../../rfcs/0036-improve-worktree-runtime-state-sharing.md)
- Related bug: [guest writes refused under symlinked state](../bugs/2026-08-16-guest-writes-refused-under-symlinked-state.md) — the same refusal on a symlinked directory rather than a leaf
