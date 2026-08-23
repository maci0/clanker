# Research — What an improve-self worktree shares, copies and discards under state/

## Status

Current — searched 2026-08-22. Every claim read from the tree at 03a79fef on 2026-08-22. No external sources; no improve-self run was started, so nothing here is a reproduction.

Research is evidence, not a decision: it records what exists, how good it is,
and how confident the finding is. The decision that follows belongs in an
[RFC](../rfcs/) and, once made, an [ADR](../adrs/).

## Question

Which entries under state/ does an improve-self worktree link, copy or leave empty, who reads each one, and what would it cost to share a discarded one back?

Raised by, but separate from, the `state/improvements.jsonl` leaf-symlink
ledger bug: that was a defect in a path that is *meant* to be shared. This note
asks whether the paths that are *meant* not to be shared should still not be.

## TL;DR

All line numbers below were read in the tree at `03a79fef` on 2026-08-22.

- **The two isolation modes disagree, and each states its rule in a comment.** `Sharing.run` symlinks every untracked checkout path into the worktree so an isolated agent run reads and writes the checkout's own `state/`; `Sharing.improve` gives the worktree a real private `state/` and links or copies six entries back — `high` confidence — `src/improve/worktree.zig:368-380`, `485-520`, `808-927`.
- **The improve worktree is not empty, it is seeded and then discarded.** `state/learnings.md`, `state/autolearn.jsonl`, `state/plugin_config.json`, `state/token_stats.jsonl` and `state/reasoning.jsonl` are *copied in* (one-way, 16 MiB read cap) at worktree creation; `state/runs/` and `state/sessions/` are created empty; `state/improvements.jsonl` and `state/history/` are symlinks and are the only two that flow back — `high` confidence — `src/improve/worktree.zig:846-926`.
- **The dividing line the module uses is who reads the path, not what the data is.** A symlink is safe only for a path the host reads, because `safeJoinSecure` refuses any granted path — including its leaf — whose stat is a symlink — `high` confidence — `src/improve/worktree.zig:857-872`, `src/sandbox/host.zig:5826-5852`.
- **`state/token_stats.jsonl` is the one copied entry no guest is granted.** `model_stats` has `fs_prefixes: []` and reads the host aggregate through `ck_stats`; `learnings`, `autolearn`, `reasoning` and `plugins` each name their file in `fs_prefixes` — `high` confidence — `tools/manifests/*.tool.json`, read 2026-08-22.
- **Nothing else records what an improve run cost.** `state/improvements.jsonl` records `id`, `ts`, `status`, `instruction`, `summary`, `files`, `score_before`, `score_after`, `detail`, `changes` and no token or cost field; `stats.Record` carries no run, session or source tag, so even a merged-back log could not be attributed to improve — `high` confidence — `state/improvements.jsonl` (1485 records, read 2026-08-22), `src/stats/tokens.zig:33-60`.
- **A symlinked `token_stats.jsonl` needs its lock moved as well as the link made.** `tokens.append` takes the lock at `<state_dir>/token_stats.lock`, which stays worktree-local, so two processes would append to one file under two different locks — the exact race the function's own comment says the lock exists to prevent — `high` confidence — `src/stats/tokens.zig:107-165`, `src/util/file_lock.zig:53-62`.

## Scope and method

**Searched.** The local tree only, at `03a79fef` on 2026-08-22:
`src/improve/worktree.zig`, `src/sandbox/host.zig`, `src/stats/tokens.zig`,
`src/util/file_lock.zig`, `src/util/atomic_write.zig`, `src/cli.zig`
(`cmdImproveSelf`), every `tools/manifests/*.tool.json`, and the live
`state/improvements.jsonl` and `state/token_stats.jsonl` in the main checkout.
`clanker rfc search` and `clanker adr search` were run over the record stores
for `linkSharedState`, `token_stats`, `state_dir isolation`, `improvements.jsonl`
and `run graphs discarded`.

**Not searched.** No external sources: this is a question about one module's
policy, and nothing outside the tree can answer it. No live improve-self run was
started, so every claim here is read from source or from the checkout's own
state files, never from a reproduction.

**Freshness.** The tree moves daily; anything here is a claim about `03a79fef`.
The per-manifest `fs_prefixes` table ages the fastest — a new grant on
`state/token_stats.jsonl` would invalidate the central finding.

## Options found

This is a survey of what the tree already does, so the "options" are the three
treatments `linkSharedState` applies and what each one costs.

### Symlink the leaf back to the checkout — what `improvements.jsonl` and `history/` get

**What it is.** `std.Io.Dir.cwd().symLink` from `<worktree>/state/<name>` to
`<checkout>/state/<name>`, made only when the checkout already has the entry
(`src/improve/worktree.zig:874-883`). Native I/O follows the link, so the ~44
hardcoded cwd-relative `state/...` paths in `src/` reach the checkout with no
call site changed.

**Fit.** Only for a path no sandboxed guest is granted. `safeJoinSecure` walks
the resolved path component by component with `follow_symlinks = false` and
returns `error.PathOutsideSandbox` on the first `.sym_link` stat
(`src/sandbox/host.zig:5838-5850`). The loop's final iteration stats
`full[0..full.len]`, so the **leaf** is checked too, not only the directories
above it.

**Unknown.** `improve_history` is granted `fs_prefixes:
["state/improvements.jsonl"]` and that file is a leaf symlink inside an
improve-self worktree, where `cmdImproveSelf` never sets
`cfg.agent.shared_root` (`src/cli.zig:6388-6407`) — so the guest's path
resolves under the worktree and meets the link. Traced from source; **not
reproduced live**. Filed as
[an investigation](../reports/investigations/2026-08-22-improve-history-guest-in-an-improve-worktree.md).

**Cost of extending it to a file that is appended concurrently.** The link is
not sufficient on its own: `tokens.append` locks
`<state_dir>/token_stats.lock`, and `state_dir` stays worktree-local, so the
worktree and the checkout would hold two different locks over one inode
(`src/stats/tokens.zig:120-124`, `src/util/file_lock.zig:53-62`). The
in-tree precedent for fixing that is `casLockPath`, which hashes the *resolved*
target and resolves the lock directory against `shared_root`. Trimming is
already safe: `trimLog` writes through `atomic_write.writeFilePerms`, which
`readLink`s the leaf and renames onto the link's target rather than replacing
the link (`src/stats/tokens.zig:188`, `src/util/atomic_write.zig:35-59`).

### Copy the file in once, one-way — what `learnings.md`, `autolearn.jsonl`, `plugin_config.json`, `token_stats.jsonl` and `reasoning.jsonl` get

**What it is.** `readFileAlloc` capped at 16 MiB, then `writeFile` with
`atomic_write.private_file` permissions into the worktree
(`src/improve/worktree.zig:911-926`). The run reads the checkout's history and
writes only its own copy.

**Why it is a copy and not a link.** Each of those five except
`token_stats.jsonl` is named in a guest's `fs_prefixes`, so a link would be
refused by the walk above. The stated intent is also semantic: the comment at
`src/improve/worktree.zig:891-896` says runtime state is "deliberately neither
linked nor copied: a fresh worktree legitimately starts empty", and the
`Sharing.improve` doc comment says "the copies are what keep a proposal's
learnings from escaping before it is promoted".

**Consequence.** Everything the run appends to its copy dies with the worktree,
because `Worktree.cleanup` runs `git worktree remove` unless the branch holds
commits the base does not (`src/improve/worktree.zig:113-126`).

### Create the directory and leave it empty — what `runs/` and `sessions/` get

**What it is.** `createDirPath` for `state/runs` and `state/sessions` and
nothing more (`src/improve/worktree.zig:846-852`). The comment records why the
directories must exist even though they start empty: their writers create a file
inside them, not the path to them, so an absent `state/runs` produced "graph
write failed: FileNotFound" once per isolated run.

**Fit.** Both are guest-granted (`graph` → `state/runs/`, `sessions` and
`session_export` → `state/sessions/`), so neither can be a symlink under the
current sandbox rule.

## Out-of-the-box options

**Already in the tree.** `Sharing.run` is a complete, shipped implementation of
the opposite policy: `linkCheckoutStateAt` links every `host.shared_prefixes`
entry and `cli.zig:4155` sets `cfg.agent.shared_root` so the sandbox routes the
same prefixes to the checkout, which is what makes the links safe for guests as
well as the host. Nothing new would have to be designed to give improve-self the
same treatment; only the decision about whether it should have it.

**Standard library / OS primitive.** A symlink plus a shared `flock` is the
whole mechanism; no dependency is involved either way.

**Do nothing.** Costs exactly what the question names: `clanker stats` under-reports
by whatever improve-self spends, and no run graph or session survives an improve
iteration for `clanker graph` to draw.

**Adjacent domain.** `casLockPath` already solves the "one lock inode per target
across trees" problem for `ck_fs_write_if` by hashing the resolved target and
resolving the lock directory against `shared_root`; the same shape applies to
`token_stats.lock`.

**Buy, host, or delegate.** RFC 0019 option A (`ck_state` over loopback to
`clanker serve`) would make the question moot by removing the path from the
problem entirely, at the cost of making every run depend on serve being up. That
RFC is in Discussion and is the mechanism question; this note is the policy one.

## Comparison

| `state/` entry | Improve worktree gets | Read by | Symlinkable today | Survives the worktree |
|---|---|---|---|---|
| `improvements.jsonl` | symlink | host only (the `improve_history` guest now reads it over `ck_improve_history`) | yes for the host; the guest grant was the open question and is gone | yes |
| `history/` | symlink | host (`History` revert snapshots) | yes | yes |
| `learnings.md` | copy in | `learnings` guest | no | no |
| `autolearn.jsonl` | copy in | `autolearn` guest | no | no |
| `plugin_config.json` | copy in | `plugins` guest | no | no |
| `reasoning.jsonl` | copy in | `reasoning` guest | no | no |
| `token_stats.jsonl` | copy in | host only (`ck_stats` aggregates natively) | **yes** | no |
| `runs/` | empty directory | `graph` guest | no | no |
| `sessions/` | empty directory | `sessions`, `session_export` guests | no | no |
| `plugins.json` | nothing at all | `plugins` guest | no | no |
| `chains/`, `workflows/` | symlink (tracked, usually already present) | guests, read-only | n/a | n/a |

## Evidence log

Every claim above traces to a row here. Sources are files in this tree at
`03a79fef`; "read on" is the date the line was opened.

| Claim | Source | Read on | Confidence |
|---|---|---|---|
| Improve-self chdirs into the worktree for the whole run | `src/cli.zig:6396` (`std.process.setCurrentPath(io, created.path)`) | 2026-08-22 | high |
| `cmdImproveSelf` never sets `cfg.agent.shared_root` | `src/cli.zig:6388-6407`, and the only assignments are at `src/cli.zig:4155` and `15647` | 2026-08-22 | high |
| `state_dir` defaults to the relative `"state"` | `src/config.zig:423` | 2026-08-22 | high |
| Five files are copied one-way into the worktree | `src/improve/worktree.zig:911-926` | 2026-08-22 | high |
| `runs/` and `sessions/` are created empty | `src/improve/worktree.zig:846-852` | 2026-08-22 | high |
| `safeJoinSecure` refuses a symlinked leaf, not only a symlinked directory | `src/sandbox/host.zig:5838-5850` — the loop's last pass stats `full[0..full.len]` | 2026-08-22 | high |
| `model_stats` has no `fs_prefixes`; `learnings`/`autolearn`/`reasoning`/`plugins` each name their file | `tools/manifests/*.tool.json` | 2026-08-22 | high |
| `stats.Record` has no run/session/source field | `src/stats/tokens.zig:33-60` | 2026-08-22 | high |
| The improve ledger records no cost | `state/improvements.jsonl`, all 1485 records carry the same 10 keys | 2026-08-22 | high |
| `tokens.append` locks `<state_dir>/token_stats.lock` | `src/stats/tokens.zig:120-124`, `src/util/file_lock.zig:53-62` | 2026-08-22 | high |
| `trimLog` writes through a leaf symlink rather than replacing it | `src/stats/tokens.zig:188` → `src/util/atomic_write.zig:35-59` (`readLink` on `sub_path`) | 2026-08-22 | high |
| `clanker stats` in the main checkout totals 18814 calls / $42.24 | `clanker stats`, run 2026-08-22 | high | high |
| Correlating improve ledger timestamps against `token_stats.jsonl` does **not** settle whether improve calls are missing | 828 of 1485 improvement records have some `token_stats` line within ±60s, but other sessions write the same log concurrently, so the window proves nothing either way | 2026-08-22 | high (that it is inconclusive) |
| `improve_history` is refused inside an improve worktree, and reports the refusal as an empty history | traced through the three rows above, then **reproduced** by a unit test and fixed by moving the guest onto `ck_improve_history` | 2026-08-23 | high |

## Open questions

1. **Does `improve_history` actually fail inside an improve-self worktree?**
   Settled 2026-08-23: yes. The unit test route was the one taken -- a sandbox
   rooted at a worktree whose granted leaf is a symlink to a sibling checkout's
   file. It did not error; it answered "no history yet". Fixed by giving the
   guest a host channel (`ck_improve_history`) and dropping its fs grant.
2. **Would a shared `token_stats.jsonl` be attributable?** The record has no
   run, session or source field, so merged-back lines would raise the totals
   without answering "what did improve cost". Settling this means deciding
   whether `Record` gains a tag, which is a schema change PRD 0026 already
   contemplated (`source: "proxy"`).
3. **Does the isolation argument survive being stated per-file?** "A proposal's
   learnings must not escape before promotion" is a claim about content the next
   prompt is built from. Whether it also covers a count of tokens spent is the
   product question this note deliberately does not answer.

## What would change the answer

Three things would invalidate this note:

* A guest gaining `state/token_stats.jsonl` in its `fs_prefixes` would remove the
  one asymmetry this note rests on, and the symlink option with it.
* `agent.sandbox_follow_symlinks` (ADR 0017) becoming the default would make
  every entry symlinkable and collapse the table above to one row.
* RFC 0019 being decided in favour of option A (`ck_state` over loopback) would
  replace the path-based mechanism entirely; this note's per-path table would
  then describe a mechanism nothing uses.

## References

**Tree, at `03a79fef`:**

* `src/improve/worktree.zig` — `Sharing`, `createOn`, `linkCheckoutStateAt`, `linkSharedState`, `Worktree.cleanup`
* `src/sandbox/host.zig` — `safeJoinSecure`, `shared_prefixes`, `rootForPath`
* `src/stats/tokens.zig` — `Record`, `append`, `trimLog`, `subPath`
* `src/util/file_lock.zig`, `src/util/atomic_write.zig`, `src/config.zig`, `src/cli.zig`
* `tools/manifests/{model_stats,learnings,autolearn,reasoning,plugins,graph,sessions,improve_history}.tool.json`

**Records:**

* [RFC 0019 — Shared state store for worktree-isolated runs and mesh peers](../rfcs/0019-shared-state-store.md) — the mechanism question, in Discussion
* ADR 0017 — the sandbox's no-follow rule and its opt-out
* [RFC 0001 — workspace/room/board hierarchy](../rfcs/0001-workspace-room-board-hierarchy.md) — worktree isolation as a workspace concern

## Appendix

The two comments that state the opposing rules, quoted in full because the whole
question is that they disagree.

`Sandbox.shared_root`, `src/sandbox/host.zig:228-234`:

> The rule this implements: git-tracked source belongs to the run's own tree,
> because editing it in isolation is the whole point; everything git does NOT
> track is one checkout-wide thing every run shares, and an isolated run must
> reach it exactly as it would without isolation. Left as a snapshot instead, a
> run reads stale state and its writes go nowhere: the goal it was steered by,
> the session it should resume, the notes it just took are all invisible to the
> next run.

`linkSharedState`, `src/improve/worktree.zig:891-896`:

> Runtime state (runs, sessions, stats, reasoning traces, plugin toggles) is
> deliberately neither linked nor copied: a fresh worktree legitimately starts
> empty and every tool already answers "(nothing yet)" for that case.

`linkCheckoutState`, `src/improve/worktree.zig:466-470`, names token accounting
specifically as a symptom of the snapshot treatment:

> A run that gets a snapshot instead is quietly crippled -- no goal to be steered
> by, no session to resume, its notes and token accounting written somewhere
> nobody reads -- and every symptom looks like a broken tool rather than a
> missing directory.
