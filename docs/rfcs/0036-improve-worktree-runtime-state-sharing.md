# RFC 0036 — Which of an improve-self worktree's runtime state should rejoin the checkout

## Status

Discussion — 2026-08-22. Options and recommendation written from the tree at 03a79fef; open for comment. Blocking question is 2 (does the learnings-must-not-escape rule still hold), which the operator answers.

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

An improve-self run works in a git worktree with its own private `state/`. Two entries (`state/improvements.jsonl`, `state/history/`) are symlinked back to the checkout, five are copied in one-way, and `state/runs/`+`state/sessions/` start empty; everything the run writes to the copies and the empty directories is deleted with the worktree. Decide whether that is still the policy, and if not, which entries rejoin the checkout and by what mechanism.

**Decision to make.** Which entries under an improve-self worktree's `state/`
rejoin the checkout, and by what mechanism?

**Why now.** Nothing is blocked. What forces the question is that the tree now
contains two written-down policies that contradict each other, and only one of
them was written recently:

* `Sharing.improve` (`src/improve/worktree.zig:368-380`) gives the worktree a
  private `state/` on the rule that "the copies are what keep a proposal's
  learnings from escaping before it is promoted".
* `Sharing.run` and `Sandbox.shared_root` (`src/sandbox/host.zig:228-234`) state
  the opposite rule for every other isolated run: "everything git does NOT track
  is one checkout-wide thing every run shares, and an isolated run must reach it
  exactly as it would without isolation."
* `linkCheckoutState`'s comment (`src/improve/worktree.zig:466-470`) names the
  exact symptom this RFC is about as a *defect* of the snapshot treatment: a run
  left with a snapshot has "its notes and token accounting written somewhere
  nobody reads".

The operator-visible consequence is that `clanker stats` — 18814 calls and
$42.24 in this checkout on 2026-08-22 — excludes whatever improve-self spends,
and `clanker graph` can draw no improve iteration, because `state/runs/` in the
worktree is deleted with it.

**Drivers.** Any acceptable option must satisfy all of these:

1. **The sandbox rule holds.** `safeJoinSecure` refuses a granted path whose
   stat is a symlink, leaf included (`src/sandbox/host.zig:5838-5850`), so a
   file named in any guest's `fs_prefixes` cannot become a symlink without
   `agent.sandbox_follow_symlinks` (ADR 0017), which this RFC does not propose.
2. **No lost appends.** `tokens.append` locks `<state_dir>/token_stats.lock`
   (`src/stats/tokens.zig:120-124`), and `state_dir` is the relative `"state"`
   (`src/config.zig:423`), so any option that puts two trees' writers on one
   inode must also put them on one lock — this checkout demonstrably runs
   several `clanker` processes at once.
3. **A rejected proposal's learnings still must not escape.** Whatever changes,
   the reason `learnings.md` and `autolearn.jsonl` are one-way copies has to
   survive or be explicitly overturned.
4. **Attribution, not just totals.** `stats.Record` has no run, session or
   source field (`src/stats/tokens.zig:33-60`), so merging usage lines back
   raises the totals without answering "what did improve cost". An option that
   only raises the totals answers half the question.

**Out of scope.** This RFC does not decide the *transport* for shared state —
RFC 0019 (Discussion) is that question, and its option A (`ck_state` over
loopback to `clanker serve`) would make the path-based mechanism here moot. It
does not propose changing the sandbox's no-follow rule. It does not cover
hand-made worktrees (`clanker worktree prepare`, ADR 0048), which are a separate
preparation path.

## Current state

`cmdImproveSelf` creates a worktree with `Sharing.improve` and chdirs into it
for the whole run (`std.process.setCurrentPath(io, created.path)`,
`src/cli.zig:6396`). It never sets `cfg.agent.shared_root` — the only two
assignments are `src/cli.zig:4155` and `15647`, both on the plain isolated-run
path. Because `agent.state_dir` is the relative `"state"`, every `state/...`
path the run touches is the worktree's own.

`linkSharedState` (`src/improve/worktree.zig:808-927`) then gives that private
`state/` three treatments, and which one an entry gets is decided by **who reads
the path**, not by what the data is:

| `state/` entry | Treatment | Read by | Survives the worktree |
|---|---|---|---|
| `improvements.jsonl` | symlink | host only (the `improve_history` guest reads it over `ck_improve_history`) | yes |
| `history/` | symlink | host (`History` revert snapshots) | yes |
| `learnings.md` | copied in, one-way | `learnings` guest | no |
| `autolearn.jsonl` | copied in, one-way | `autolearn` guest | no |
| `plugin_config.json` | copied in, one-way | `plugins` guest | no |
| `reasoning.jsonl` | copied in, one-way | `reasoning` guest | no |
| `token_stats.jsonl` | copied in, one-way | **host only** | no |
| `runs/` | created empty | `graph` guest | no |
| `sessions/` | created empty | `sessions`, `session_export` guests | no |
| `plugins.json` | nothing at all | `plugins` guest | no |

The last column is `Worktree.cleanup`: `git worktree remove` unless the branch
holds commits the base does not (`src/improve/worktree.zig:113-126`).

Two facts from that table do the work below.

**`token_stats.jsonl` is the only copied entry no guest is granted.**
`model_stats` has `fs_prefixes: []` and reads the host aggregate through
`ck_stats`; `learnings`, `autolearn`, `reasoning` and `plugins` each name their
file. So driver 1 disqualifies a symlink for four of the five copies and not for
the fifth.

**The copy of `token_stats.jsonl` is on a cap that will silently stop working.**
`linkSharedState` reads each copied file with `.limited(1 << 24)` — 16 MiB — and
its comment says that number was chosen against autolearn's 8 MiB
`max_log_bytes`. `token_stats.jsonl`'s own cap is `32 << 20`
(`src/stats/tokens.zig:24`), more than double the copy limit, and the read is a
`catch continue`: past 16 MiB the copy is skipped with no message. The file is
4.7 MB in this checkout on 2026-08-22, so this has not happened yet — but it is
the same silent-skip failure the 16 MiB was raised to prevent.

No other record of what an improve run cost exists. `state/improvements.jsonl`
carries `id`, `ts`, `status`, `instruction`, `summary`, `files`, `score_before`,
`score_after`, `detail`, `changes` — all 1485 records in this checkout have those
ten keys and no token or cost field.

## Options considered

Five options. A and B share the usage log by two different mechanisms, C
abolishes the second policy entirely, D is the status quo, and E is the
out-of-the-box one: stop trying to move a log at all.

### Option A — symlink `state/token_stats.jsonl` back to the checkout

**What it is.** Move `token_stats.jsonl` from the copied list to the symlinked
list in `linkSharedState`, so the improve run appends to the checkout's log the
way it already appends to `improvements.jsonl`.

**How it would fit.** One line moves between two loops
(`src/improve/worktree.zig:874` and `:911`). It is legal under driver 1 because
no guest names the file. Trimming is already safe: `trimLog` writes through
`atomic_write.writeFilePerms`, which `readLink`s the leaf and renames onto the
link's target rather than replacing the link
(`src/stats/tokens.zig:188`, `src/util/atomic_write.zig:35-59`).

**Pros:** smallest diff; `clanker stats` totals become true the moment it lands;
kills the 16 MiB copy-cap problem for this file, since nothing is copied.

**Cons:** it violates driver 2 unless the lock moves with it. `tokens.append`
locks `<state_dir>/token_stats.lock`, which stays worktree-local, so the
worktree and the checkout would append to one inode under two different locks —
the exact race the function's own comment says the lock exists to prevent
("two writers could read the same size and write to the same place, and one
record simply replaced the other. Nothing reported it"). It also does not
satisfy driver 4: the merged lines carry no source tag.

**Cost to adopt.** The one-line move is trivial; the lock is not. The in-tree
precedent is `casLockPath`, which hashes the *resolved* target and resolves the
lock directory against `shared_root` so one lock inode serves every tree. That
pattern has to be applied to `token_stats.lock`, and `tokens.append` currently
has no notion of a shared root — it takes `state_dir` from config.

**Cost to leave.** Low: move the line back. No data format changes.

**Evidence.** `src/improve/worktree.zig:874-926`, `src/stats/tokens.zig:107-188`,
`src/util/file_lock.zig:53-62`, `src/util/atomic_write.zig:35-59`, all read
2026-08-22.

### Option B — merge the run's new usage lines back at cleanup

**What it is.** Keep the copy. Record how many bytes were copied in at worktree
creation; after the run, from the checkout's cwd, read the worktree log past that
offset and append those lines to the checkout's log through the ordinary
`tokens.append` path before `cleanup` removes the worktree.

**How it would fit.** No symlink, no sandbox interaction, and no cross-tree lock:
the merge-back runs in the checkout as a single process and takes the same
`state/token_stats.lock` every other writer takes, which is driver 2 satisfied by
construction rather than by new locking code. The same shape would work for any
of the copied files if the policy later widened.

**Pros:** satisfies drivers 1 and 2 without touching `file_lock` or the sandbox;
the merge-back already has to count what the run produced, so stamping a
per-improvement total (option E) falls out of the same code; a failed merge-back
loses accounting, never a chat completion, matching how `tokens.append` already
treats its own failures.

**Cons:** the accounting lands at run end, not live — a killed improve run's
usage is still lost, and `clanker janitor` sweeping a killed run's staging
copies will not recover it. The byte offset is only valid if the worktree copy
was not trimmed mid-run; `trimLog` fires past 32 MiB, and the file is 4.7 MB
today, but the offset has to be validated rather than assumed (compare the prefix
or fall back to a timestamp watermark).

**Cost to adopt.** Moderate: a field on `Worktree` for the seeded size, a
merge-back call on the path that chdirs back, and a test that a killed run does
not double-count.

**Cost to leave.** Low; it is additive and deleting it restores today's
behaviour exactly.

**Evidence.** `src/improve/worktree.zig:103-126` (cleanup), `src/cli.zig:6388-6407`
(chdir in, and the `original_cwd` already captured for the way back),
`src/stats/tokens.zig:107-165`.

### Option C — give improve-self the same sharing as an isolated agent run

**What it is.** Set `cfg.agent.shared_root` on the improve-self path and call
`linkCheckoutState` instead of `linkSharedState`, so every
`host.shared_prefixes` entry resolves to the checkout for the host *and* for
guests. One policy instead of two.

**How it would fit.** The implementation already exists and ships:
`linkCheckoutStateAt` plus the `rootForPath` routing is what every
`clanker run --worktree` already does, and the two halves are what make the
links safe for guests as well (`src/improve/worktree.zig:463-520`,
`src/sandbox/host.zig:5878-5890`). It would also, as a side effect, fix the
`improve_history` refusal traced in
[the investigation](../reports/investigations/2026-08-22-improve-history-guest-in-an-improve-worktree.md).

**Pros:** deletes the contradiction outright; run graphs and sessions from
improve iterations become visible to `clanker graph` and `clanker sessions`; one
rule to explain instead of a per-file table.

**Cons:** it overturns driver 3 explicitly. A rejected proposal's `learnings.md`
and `autolearn.jsonl` writes would land in the checkout the moment they are
written, which is exactly what the one-way copy exists to prevent, and the
improve loop builds its next prompt from those files. It also shares
`state/staging/`, which the comment at `src/improve/worktree.zig:817-825` says
must be the run's own.

**Cost to adopt.** Small in code, large in blast radius: it changes what the
improve loop reads on its next iteration.

**Cost to leave.** High. Learnings that escaped cannot be un-escaped, and the
loop will have been steered by them.

**Evidence.** `src/improve/worktree.zig:368-380`, `:463-520`, `:817-825`;
`src/sandbox/host.zig:226-243`, `:5868-5890`.

### Option D — status quo

**What it is.** Keep the table in Current state exactly as it is.

**Pros:** zero risk; the isolation argument in driver 3 stays intact by
construction; the one file this RFC is about is the only thing anybody has
complained about.

**Cons:** `clanker stats` under-reports by whatever improve-self spends, with no
way to find out by how much; no improve iteration is ever drawable by
`clanker graph`; and the 16 MiB copy cap will, at some point, silently stop
copying `token_stats.jsonl` in without saying so.

**Cost to adopt.** Zero now. Later: the copy-cap gap becomes a real bug, and the
contradiction between the two comments stays for the next reader to rediscover
— which is how this RFC came to exist.

**Evidence.** The Current state table above.

### Option E — out-of-the-box: stamp the cost on the improve ledger, move no log

**What it is.** Do not share `token_stats.jsonl` at all. At the end of each
improve iteration, aggregate the worktree's own log and write the totals onto the
`improvements.jsonl` record the engine already appends — which is symlinked,
host-read, and already the per-iteration record with the improvement's id,
status, files and score.

**Why it is the out-of-the-box one.** Every other option treats this as a
file-sharing problem. It is an accounting problem, and the shared, host-read,
per-iteration ledger for improve runs already exists; it simply has no cost
column. It is the "already in the tree, used differently" answer.

**Pros:** the only option that satisfies driver 4 — the ledger row names the
improvement, so the cost is attributable to a specific proposal and its
accept/reject outcome, which a merged usage line never could without a schema
change to `stats.Record`. No sandbox change, no lock change, no symlink. It also
answers a question nobody can ask today: what do rejected proposals cost
relative to accepted ones.

**Cons:** `clanker stats` totals stay wrong. The operator would have to look at
`clanker improve-self` history, not `clanker stats`, so there are two places to
look instead of one. `improvements.jsonl` gains fields, and `improve_history`
plus the history block in the next prompt would want to render them.

**Cost to adopt.** Small and self-contained: three optional fields on the
improve record, one aggregation call, one renderer change.

**Cost to leave.** Low: optional fields, older rows stay readable.

**Evidence.** `state/improvements.jsonl` — 1485 records, ten keys, no cost field,
read 2026-08-22; `src/improve/worktree.zig:874-883` (already symlinked);
`tools/manifests/improve_history.tool.json`.

## Implications by horizon

The options do not differ much in the short term — every one of them is a small
diff. They differ in what they commit us to, and that shows in the medium and
long horizons.

### Short term (this release / 0–3 months)

* **If A:** totals become true immediately, and a concurrent-append race is
  introduced immediately unless the lock lands in the same change. The two halves
  must not ship separately.
* **If B:** totals become true at the end of each improve run. Nothing else in
  the tree changes; no sandbox or lock surface is touched.
* **If C:** `clanker graph` and `clanker sessions` start showing improve
  iterations, and the improve loop's next prompt starts reading learnings from
  proposals that were rejected.
* **If D:** nothing changes.
* **If E:** `clanker improve-self` history gains a cost column; `clanker stats`
  is unchanged.

### Medium term (3–12 months)

* **If A:** `token_stats.lock` has been generalised to a shared root, which is a
  reusable primitive the next shared file will want — the same generalisation
  `casLockPath` already made for `ck_fs_write_if`.
* **If B:** the merge-back is a place other worktree-local state can be merged
  from later without re-arguing the sandbox rule, but killed runs keep losing
  their accounting and someone eventually notices.
* **If C:** driver 3 has been overturned, and if that turns out to have been
  wrong the loop has already been trained on the escaped learnings.
* **If D:** `token_stats.jsonl` crosses 16 MiB and stops being copied into
  worktrees, silently. The improve run then starts from an empty usage log; today
  nothing reads it there, so the symptom would be invisible until something does.
* **If E:** the ledger has per-improvement cost, which makes
  `improve.max_consecutive_test_only`-style policy questions answerable with
  numbers instead of counts.

### Long term (12+ months)

* **If A or B:** if RFC 0019 is decided in favour of `ck_state` over loopback,
  both are superseded by it and the work is discarded — A's lock generalisation
  is the part that survives.
* **If C:** the second policy is gone and there is one rule for isolation, which
  is the outcome most likely to still be right in two years *if* driver 3 turns
  out not to matter.
* **If D:** the contradiction between the two comments is still in the tree, and
  the next person to read `linkSharedState` reopens exactly this question.
* **If E:** unaffected by RFC 0019 — it is a field on a record, not a path — so
  it is the only option here that survives the transport decision intact.

## Recommendation

**Recommended option:** E first, then B. Keep the isolation policy — reject C —
and answer the accounting question where the answer is attributable.

**Confidence:** 6/10

**Why this confidence.** It rests on four things read directly from the tree at
`03a79fef`: that `token_stats.jsonl` is the only copied entry no guest is
granted; that `stats.Record` has no source field; that
`state/improvements.jsonl` is already symlinked and already per-iteration; and
that `tokens.append`'s lock is `state_dir`-relative. Each is a line of code, not
an inference.

Three things hold it down from higher:

1. **The under-reporting was not measured.** The mechanism is certain — cwd is
   the worktree, `state_dir` is relative, the worktree is removed — but the
   magnitude is not. Correlating the 1485 improve ledger timestamps against
   `token_stats.jsonl` is inconclusive because other sessions write the same log
   concurrently: 828 improvement records have some usage line within ±60s, which
   proves nothing either way. Nobody knows whether improve-self is 2% or 40% of
   the $42.24.
2. **Nothing is blocked.** "Why now" is a contradiction in two comments and a
   missing number, not a failure. That is a real reason to write the question
   down and a weak reason to act on it this week.
3. **The recommendation is a sequence, and sequences drift.** E without B leaves
   `clanker stats` wrong, which is the complaint that started this.

What would raise it to 8+: a measurement of what one improve-self run actually
spends, taken by reading the worktree's `token_stats.jsonl` before `cleanup`
removes it. That is a single run's worth of work and it would settle both the
magnitude and B's offset-validity question at once. What would sink it: a guest
gaining `state/token_stats.jsonl` in its `fs_prefixes` — that removes the
asymmetry the whole analysis rests on and makes A illegal.

**Rationale.** The trade-off accepted is *two places to look instead of one*, in
exchange for keeping the isolation rule intact and getting attribution that the
alternatives cannot give at all.

A and B both raise a total that nobody can decompose. Driver 4 is the reason: a
merged usage line is indistinguishable from an ordinary agent turn, so after
either change `clanker stats` says a larger number and still cannot say what
improve cost. E is the only option that answers the question as asked, and it
answers it in the record that already knows which proposal was accepted. B then
makes the totals true as well, and B is preferred over A for that job because it
satisfies driver 2 by construction — one process, one lock, in the checkout —
rather than by generalising `file_lock` to a shared root, which is the part of A
that is neither small nor obviously correct.

C is rejected, not deferred. It is the tidiest outcome and it overturns driver 3
as a side effect rather than on its merits; if the "learnings must not escape
before promotion" rule is wrong, that deserves its own RFC and its own evidence,
not a paragraph inside an accounting question.

D is rejected because the 16 MiB copy cap against a 32 MiB log cap is a latent
silent failure with no owner, and leaving it means the decision gets made by
whoever hits it first.

**Reversibility.** E is three optional fields on a JSONL record; older rows stay
readable and deleting the fields costs nothing. B is additive and removing it
restores today's behaviour byte for byte. Neither has a point of no return. The
only irreversible option here is C, because escaped learnings are already in the
next prompt.

## Open questions

1. **What does one improve-self run actually cost?** Nobody knows, and the
   number decides whether any of this is worth doing. Answered by reading the
   worktree's `state/token_stats.jsonl` before `Worktree.cleanup` removes it, on
   one run. This is the question that would move the confidence most.
2. **Does the "learnings must not escape before promotion" rule still hold?**
   Driver 3 is taken as given here on the strength of the comment at
   `src/improve/worktree.zig:368-380`; it has not been re-argued. The operator
   answers this, and a "no" makes option C the right answer instead.
3. **Should `stats.Record` gain a source tag?** PRD 0026 already contemplated
   `source: "proxy"` for the same reason. If it lands, A and B start satisfying
   driver 4 on their own and E's advantage shrinks to the accept/reject
   correlation.
4. **Do `state/runs/` and `state/sessions/` matter for improve runs at all?**
   This RFC recommends nothing for them because nobody has asked to see an
   improve iteration's run graph. If someone does, only option C reaches them —
   both are guest-granted, so driver 1 rules out a symlink and B's merge-back
   would have to copy directories rather than append lines.
5. **Is `improve_history` actually refused inside an improve worktree?**
   Settled: yes, and it reported the refusal as an empty history. Reproduced by
   a unit test and fixed by moving the guest onto a host channel
   (`ck_improve_history`), so `improvements.jsonl` is host-read-only again and
   the row above is true rather than aspirational. See
   [the investigation](../reports/investigations/2026-08-22-improve-history-guest-in-an-improve-worktree.md).
   It does not change the recommendation, and it is evidence that the per-file
   table is harder to keep correct than it looks, which argues for C: the table
   was wrong for four months and nothing failed loudly.

## Next steps / action items

* [ ] Measure open question 1: one `clanker improve-self` run, read the
  worktree's `state/token_stats.jsonl` before cleanup, and record the totals.
  This is the spike, and it also validates option B's byte-offset assumption.
* [ ] Put open question 2 to the operator with `ask_user`. A "no" changes the
  recommendation from E+B to C and this RFC should be revised, not appended to.
* [ ] If E is accepted: add the optional token/cost fields to the improve record
  in `src/improve/history.zig`, aggregate at iteration end, and render them in
  `improve_history` and the history block of the next prompt.
* [ ] If B is accepted: add the seeded-size field to `Worktree`, merge back from
  the checkout's cwd before `cleanup`, and test that a killed run does not
  double-count.
* [ ] Fix the latent copy cap either way: `linkSharedState` reads with 16 MiB
  while `token_stats.jsonl`'s own cap is 32 MiB, and the read is a
  `catch continue`. Under E it is still copied in and still silently skippable.
* [ ] Write the ADR once the decision is made, and set this RFC to `decided`.

## References

**Research:**

* [What an improve-self worktree shares, copies and discards under state/](../research/improve-worktree-runtime-state-sharing.md)
  — the per-path survey these options are scored against, with the evidence log.

**Records:**

* [RFC 0019 — Shared state store for worktree-isolated runs and mesh peers](0019-shared-state-store.md)
  — the *mechanism* question for the same problem, in Discussion. Its option A
  (`ck_state` over loopback) would supersede A and B here.
* [RFC 0001 — Workspace, room, board hierarchy](0001-workspace-room-board-hierarchy.md)
  — worktree isolation as a workspace concern; its open questions 11 and 12 are
  the neighbouring ones.
* ADR 0017 — the sandbox's refusal to follow symlinks, and the
  `agent.sandbox_follow_symlinks` opt-in this RFC does not propose using.
* [ADR 0048 — Preparing a hand-made worktree is an explicit verb](../adrs/0048-preparing-a-hand-made-worktree-is-an-explicit-verb-not-a.md)
  — the other worktree preparation path, deliberately out of scope here.
* [PRD 0026 — LLM proxy](../prds/0026-llm-proxy.md) — where a `source` tag on
  `token_stats` records was last contemplated (driver 4, open question 3).
* [Investigation: improve_history is granted a path that is a symlink inside an improve-self worktree](../reports/investigations/2026-08-22-improve-history-guest-in-an-improve-worktree.md)
* [Bug: guest writes refused under symlinked state](../reports/bugs/2026-08-16-guest-writes-refused-under-symlinked-state.md)
  — the same refusal on a symlinked directory rather than a leaf.

**Tree, at `03a79fef`, read 2026-08-22:**

* `src/improve/worktree.zig` — `Sharing`, `createOn`, `linkCheckoutStateAt`, `linkSharedState`, `Worktree.cleanup`
* `src/sandbox/host.zig` — `safeJoinSecure`, `shared_prefixes`, `rootForPath`, `Sandbox.shared_root`
* `src/stats/tokens.zig` — `Record`, `append`, `trimLog`, `subPath`, `max_log_bytes`
* `src/util/file_lock.zig`, `src/util/atomic_write.zig`, `src/config.zig`, `src/cli.zig`

## Appendix

**The two comments that contradict each other**, quoted so a reader can see that
the disagreement is real and not a reading of it.

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
as a symptom of the snapshot treatment — of the thing `linkSharedState` calls
legitimate:

> A run that gets a snapshot instead is quietly crippled -- no goal to be steered
> by, no session to resume, its notes and token accounting written somewhere
> nobody reads -- and every symptom looks like a broken tool rather than a
> missing directory.

**The inconclusive correlation**, recorded so nobody repeats it. Parsing all
1485 records of `state/improvements.jsonl` (nanosecond `ts`) against all 18814
records of `state/token_stats.jsonl` (second `ts`) on 2026-08-22: 828
improvement records have at least one usage line within ±60s and 657 have none.
That is not evidence either way, because other `clanker` sessions append to the
same log throughout. The mechanism argument in Current state is what carries the
claim; this correlation does not.
