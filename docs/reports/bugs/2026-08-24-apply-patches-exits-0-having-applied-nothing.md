# Bug — scripts/apply-patches.sh exits 0 after applying nothing, so a caller checking the exit status proceeds on an unpatched tree

## TL;DR

- **What failed:** With the dependency trees not yet extracted, scripts/apply-patches.sh printed a skip line per patch, left status at 0, and exited 0 under the summary "apply-patches: 0 applied, 0 already up to date" - the same final line shape and the same exit code as a run where all four were already applied. Observed at d4d8b9fe in a fresh worktree. README and CONTRIBUTING tell callers to run it and scripts/verify.sh:60 checks its status, so the false clean was trusted.
- **Impact:** A caller that trusted the exit status - `scripts/verify.sh:60`, a setup script, or `scripts/apply-patches.sh && zig build test` - proceeded on a tree where none of the four patches was applied. `clanker repl` then aborts on terminal resize and the e2e pty journeys fail, and `clanker gate`'s `dep-patches` was the only thing that noticed, after a full build.
- **Resolution:** Resolved on 2026-08-24. Fixed in PR #400, commit c0f2ddd2, merged as 48bccee1, by a parallel session. A missing dependency tree is now always fatal: the message moves to stderr, a skipped counter drives its own summary line naming the 'zig build' remedy, and status flips to 1. Verified first-hand at 48bccee1: fresh worktree pre-build exits 1 with the remedy line; an already-patched tree still reports '0 applied, 4 already up to date' at exit 0.

## Status

Resolved on 2026-08-24. Fixed in PR #400, commit c0f2ddd2, merged as 48bccee1, by a parallel session. A missing dependency tree is now always fatal: the message moves to stderr, a skipped counter drives its own summary line naming the 'zig build' remedy, and status flips to 1. Verified first-hand at 48bccee1: fresh worktree pre-build exits 1 with the remedy line; an already-patched tree still reports '0 applied, 4 already up to date' at exit 0.

## Blocked on

## Symptom and impact

Line numbers in this record are as of `d4d8b9fe`, the last commit carrying the
defect. `48bccee1` moved them; see Resolution.

`scripts/apply-patches.sh` re-applies the four `patches/*.patch` trees to the
extracted dependency packages. For each patch it searches its candidate roots
(`zig-pkg/`, the two `ZIG_*_CACHE_DIR` overrides, `~/.cache/zig`) for a
`vaxis-0.6.0-*` or `zwasm-2.5.0-*` directory, at `:53-60`. When no root held
one it printed, on **stdout**,

```
apply-patches: <name>: no <prefix>* tree under <roots>;  skipping (a 'zig build' must extract dependencies first)
```

and `continue`d at `:62-66` **without touching `status`**. `status` stayed 0, so
the `if [ "$status" -ne 0 ]` block at `:82-85` was skipped and the script fell
through to its success-shaped summary at `:86`:

```
apply-patches: 0 applied, 0 already up to date
```

then exited 0. That summary counts applied and already-up-to-date and mentioned
skips nowhere, so a run that applied nothing was indistinguishable from a run
where all four patches were already in place: same exit code, and the only
difference in the final line was a count that reads as "nothing needed doing".

Why that mattered rather than being cosmetic:

- **Callers are told to run it, and at least one checks the status.**
  `README.md:63` puts it in the quick start; `CONTRIBUTING.md:9`, `:36` and
  `:52` repeat it, the last as "once per worktree". `scripts/verify.sh:60` is
  an in-tree caller of exactly the shape the defect defeated:
  `./scripts/apply-patches.sh || status=1`. Any
  `scripts/apply-patches.sh && zig build test`, setup script or CI step has
  the same shape and had the same blind spot.
- **What the unpatched state costs is in the script's own header comment**
  (`:9-12`): without `patches/vaxis-winch-self-pipe.patch`, resizing the
  terminal in `clanker repl` aborts the process; without
  `patches/vaxis-sixel-graphics.patch` the e2e pty journeys fail, because the
  repl never sends the sixel geometry query they answer.
- **The gate was the only backstop, and it is downstream of a full build.**
  Observed on 2026-08-24 in another session: a fresh worktree's first
  `apply-patches.sh` skipped all four with "no vaxis-0.6.0-* tree", and
  `dep-patches` then failed. The gate caught it, but only after `zig build`
  and `zig build tools`. Anyone running the script outside `clanker gate` had
  no such check.
- **Same false-clean family as two other findings here.** The first version of
  `depPatchesGate` reported a patch applied on a pristine tree, because its
  longest added line already existed in the file. `releaseContractGate`
  (`src/gate/checks.zig:1306`) is four static substring checks that never read
  the diff. A check or step that is structurally incapable of reporting failure
  cannot be used as evidence that the thing it checks is true.

**The ordering was not the gap.** That `zig build` must run first is documented
in `README.md:63`, `CONTRIBUTING.md:9`, `:36` and `:52`, `AGENTS.md:13`
("Ordering matters and the message says so") and `CLAUDE.md:421`, and the
script's own skip line said it too. The documentation was adequate; the defect
was the exit status. A sixth doc mention would have fixed nothing, and adding
one is still not the fix.

## Reproduction

Reproduced first-hand on 2026-08-24 UTC, in a fresh worktree at **`d4d8b9fe`**
(`origin/main` at the time, the last commit before the fix), with
`ZIG_GLOBAL_CACHE_DIR` and `ZIG_LOCAL_CACHE_DIR` both unset, no `zig-pkg/`
present, and **no `zig build` run yet**:

```sh
git worktree add -b <slug> <worktree> d4d8b9fe
cd <worktree>
scripts/apply-patches.sh; echo "exit=$?"
```

Actual output, verbatim except that the worktree path is abbreviated (the roots
line is identical in all four skips):

```
apply-patches: vaxis-sixel-graphics: no vaxis-0.6.0-* tree under <worktree>/zig-pkg /Users/<user>/.cache/zig;  skipping (a 'zig build' must extract dependencies first)
apply-patches: vaxis-ss3-keypad-enter: no vaxis-0.6.0-* tree under <worktree>/zig-pkg /Users/<user>/.cache/zig;  skipping (a 'zig build' must extract dependencies first)
apply-patches: vaxis-winch-self-pipe: no vaxis-0.6.0-* tree under <worktree>/zig-pkg /Users/<user>/.cache/zig;  skipping (a 'zig build' must extract dependencies first)
apply-patches: zwasm-lazy-mem-cksum: no zwasm-2.5.0-* tree under <worktree>/zig-pkg /Users/<user>/.cache/zig;  skipping (a 'zig build' must extract dependencies first)
apply-patches: 0 applied, 0 already up to date
exit=0
```

**Actual final line: `apply-patches: 0 applied, 0 already up to date`. Actual
exit code: `0`.** Four patches were needed, none was applied, and neither
signal said so.

Control, same worktree and same commit, immediately after `zig build` (exit 0)
extracted the trees into `zig-pkg/`:

```
== vaxis-sixel-graphics -> zig-pkg/vaxis-0.6.0-BWNV_KwYCgB-L5MNRY8I8HGbKDE6KOxDPAVSaZ8-3lJ8 ==
... 8 files patched ...
applied
== vaxis-ss3-keypad-enter -> zig-pkg/vaxis-0.6.0-BWNV_KwYCgB-L5MNRY8I8HGbKDE6KOxDPAVSaZ8-3lJ8 ==
applied
== vaxis-winch-self-pipe -> zig-pkg/vaxis-0.6.0-BWNV_KwYCgB-L5MNRY8I8HGbKDE6KOxDPAVSaZ8-3lJ8 ==
applied
== zwasm-lazy-mem-cksum -> zig-pkg/zwasm-2.5.0-FT1Fv4KPkgCaKsDmsn05BTYsoEhH7RCUreSX8a3mwFha ==
applied
apply-patches: 4 applied, 0 already up to date
exit=0
```

The two runs differed in the per-patch lines and in one integer. They did not
differ in exit code, and they did not differ in the *shape* of the last line,
which is the line a human skims and the only thing a log tail keeps.

One transcription note for anyone grepping the old skip string: it carried a
**double space** before `skipping`, because the `echo` at `:63-64` was split
across two arguments and shell word-joining inserted one.

## Root cause

`scripts/apply-patches.sh:62-66` at `d4d8b9fe`, the absent-tree branch:

```sh
if [ -z "$dir" ]; then
    echo "apply-patches: $name: no ${targets[$name]}* tree under ${roots[*]}; " \
        "skipping (a 'zig build' must extract dependencies first)"
    continue
fi
```

It was the only failure mode in the script that did not set `status=1`. The
other one did: the "patch neither applies nor reverse-applies" branch at
`:76-79` sets `status=1`, and the block at `:82-85` turns that into `exit 1`
with a summary line on stderr. So the absent-tree case took the success path
through a script that already had a failure path.

`set -euo pipefail` at `:20` did not help, because nothing failed: `continue`
is ordinary control flow, and the `echo` succeeds.

The reporting half was the same omission one line lower. The summary at `:86`
interpolates `$applied` and `$up_to_date`, and there was no `skipped` counter
to interpolate, so even a caller reading the text rather than the status could
not distinguish "nothing to do" from "nothing done".

## Resolution

Fixed by **PR #400** — commit `c0f2ddd2` ("fix: make apply-patches.sh fail when
a dependency tree is missing"), merged as `48bccee1`. Landed by a parallel
session, not by the session that filed this record; the diff and its CHANGELOG
entry are the account of intent, and both were read at `48bccee1`.

The shape, from the diff:

- A missing tree is **always fatal**. The reasoning recorded in the new comment
  at the branch is that the documented order is `zig build` first, so arriving
  early is an error worth failing loudly, and a tree that never appears means
  the patch went stale against the `build.zig.zon` pin. No opt-out flag; the
  open question of whether one was needed was settled against it.
- The per-patch message moves to **stderr** and loses its "skipping" wording.
- A new `skipped` counter drives its own summary line on stderr,
  `apply-patches: <n> patch(es) found no dependency tree to apply to; run 'zig
  build' first to extract dependencies`, and sets `status=1`, which the existing
  terminal block turns into `exit 1`.
- The success line's shape is deliberately preserved. `tests/e2e/pty_resize_test.zig:150`
  tells a reader to run `scripts/apply-patches.sh` "(it reports how many it
  applied)", so the `<n> applied, <n> already up to date` wording is referenced
  advice text, not free to reword.

The skip count landing on its own line rather than inside the success summary is
the one place the fix diverges from what this record proposed, and it is the
better answer: the success line stays quotable for the test's advice text while
the failure path gets a message of its own.

## Verification

Ran first-hand at `48bccee1`, in a **fresh detached worktree with no
`zig-pkg/`** and no `zig build`:

```
apply-patches: vaxis-sixel-graphics: no vaxis-0.6.0-* tree under <worktree>/zig-pkg /Users/<user>/.cache/zig
apply-patches: vaxis-ss3-keypad-enter: no vaxis-0.6.0-* tree under <worktree>/zig-pkg /Users/<user>/.cache/zig
apply-patches: vaxis-winch-self-pipe: no vaxis-0.6.0-* tree under <worktree>/zig-pkg /Users/<user>/.cache/zig
apply-patches: zwasm-lazy-mem-cksum: no zwasm-2.5.0-* tree under <worktree>/zig-pkg /Users/<user>/.cache/zig
apply-patches: 4 patch(es) found no dependency tree to apply to; run 'zig build' first to extract dependencies
apply-patches: one or more patches could not be applied
exit=1
```

That is the case this record is about, and it now fails. Also ran first-hand at
`48bccee1`, on an already-patched `zig-pkg/`: `apply-patches: 0 applied, 4
already up to date`, exit **0** — the idempotent rerun still succeeds, so the
fix did not turn every re-run into a failure.

Not run by this session, taken from PR #400: the post-`zig build` path on
post-fix code reporting `4 applied` at exit 0. The `4 applied` transcript under
Reproduction is from `d4d8b9fe`, and the diff leaves that branch untouched, but
that is an argument from reading the diff rather than an observation on the
fixed script.

Everything else checked first-hand for this record, at `d4d8b9fe` unless noted:

- The pre-fix exit code and final line, and the post-`zig build` control on the
  same worktree and commit. Both transcripts are under Reproduction.
- Every document citation was read at the line given, not inferred:
  `README.md:63`, `CONTRIBUTING.md:9`, `:36`, `:52`, `AGENTS.md:13`,
  `CLAUDE.md:421`, and `scripts/verify.sh:60`.
- `releaseContractGate` at `src/gate/checks.zig:1306`, cited as the third
  member of the false-clean family.
- `tests/e2e/pty_resize_test.zig:150`, at `48bccee1`, for the claim that the
  success line's wording is referenced advice text.
- `clanker gate` at `48bccee1` plus this record: twelve checks PASS.

One thing deliberately **not** claimed: `scripts/verify.sh` was never executed.
It is cited as the caller shape that exists in the tree, read from source. Its
own ordering happens to be safe on this point, since `zig build` runs at `:56`
before the `apply-patches.sh` call at `:60`, so the trees exist by then.
Separately visible in the same file and not run either: the gate call at `:57`
precedes the `apply-patches.sh` call at `:60`, so on a fresh worktree
`verify.sh` would fail `dep-patches` on the step before the one that would have
fixed it. That is an ordering observation from reading the file, not a
reproduction, and it is a different defect from this one — still unaddressed by
PR #400, which changed only the script and `CHANGELOG.md`.

## Follow-up

Nothing outstanding on the exit status itself: PR #400 settled every open
question this record raised, including the one it flagged as a judgement call
(a missing tree is always fatal, no opt-out flag).

Still open, and noted here only because it surfaced while reading the callers:
`scripts/verify.sh` runs `clanker gate` at `:57` **before**
`scripts/apply-patches.sh` at `:60`, so on a fresh worktree its gate step fails
`dep-patches` on the step immediately preceding the one that would have made it
pass. Read from the file, not reproduced. A different defect from this one, and
untouched by PR #400.

No `CHANGELOG.md` entry accompanies this record: it is records-only, and the
convention at `CONTRIBUTING.md:67` is for consumer-visible changes. The fix
itself carries one, added by PR #400. Worth knowing either way:
`releaseContractGate` (`src/gate/checks.zig:1306`) would not have caught a
missing entry, since it never reads the diff.

## References

- Fix: PR #400 — commit `c0f2ddd2`, merged as `48bccee1`. Touches
  `scripts/apply-patches.sh` and `CHANGELOG.md` only.
- Defect, at `d4d8b9fe`: `scripts/apply-patches.sh` — `:20`
  (`set -euo pipefail`), `:53-60` (root search), `:62-66` (the skipping
  `continue`, no `status=1`), `:76-79` (the branch that did set `status=1`),
  `:82-85` (terminal failure block), `:86` (the summary line), and the header
  comment at `:9-12` for what the unpatched state costs.
- In-tree caller that checks the status: `scripts/verify.sh:60`.
- Callers documented for humans and agents: `README.md:63`,
  `CONTRIBUTING.md:9`, `:36`, `:52`.
- Ordering already documented, so never the gap: `AGENTS.md:13`,
  `CLAUDE.md:421`.
- Why the success line's wording is not free to change:
  `tests/e2e/pty_resize_test.zig:150`.
- The gate that caught this downstream, and the only backstop before the fix:
  [2026-08-23-gate-passes-on-unpatched-dependencies.md](2026-08-23-gate-passes-on-unpatched-dependencies.md)
  (`depPatchesGate` in `src/gate/checks.zig`). That record is Resolved, and
  what it resolved is the *gate's* blindness. Its Reproduction at lines 43-45
  already noted in passing that the script "exits reporting success" on an
  unbuilt worktree; it was evidence for the gate argument there, and the script
  itself was left unfixed until PR #400. This record is that half.
- Same false-clean family, third member:
  [2026-08-24-blocked-on-body-is-an-ungated-fourth-state-signal.md](2026-08-24-blocked-on-body-is-an-ungated-fourth-state-signal.md),
  and `releaseContractGate` at `src/gate/checks.zig:1306`.
- Patches themselves: `patches/README.md`, `patches/vaxis-winch-self-pipe.patch`,
  `patches/vaxis-sixel-graphics.patch`.
