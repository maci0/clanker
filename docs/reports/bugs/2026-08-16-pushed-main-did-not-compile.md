# Bug — A commit on origin/main did not compile, and the break surfaced in an unrelated session's push

## TL;DR

- **What failed:** `abcc85ba` ("cli refactor", a human-authored intermediate commit) reached origin/main in a state that fails `zig build` with two errors in `src/cli.zig` workspace code. An agent session rebasing onto it saw the failure inside its own cherry-pick, in a file it had edited, at line numbers its own additions had shifted.
- **Impact:** Attribution, not breakage. The base was fixed within minutes by `7e66a9bd`; the cost is that the failure reads as the rebasing session's own, and acting on that reading means editing working code.
- **Resolution:** Resolved on 2026-08-16. Fixed on origin by 7e66a9bd, which reconciled the call sites; verified by clanker gate and zig build e2e green at 6d068d19, and by reproducing the base failure alone at abcc85ba in a clean worktree. The attribution procedure is docs/runbooks/build-failure-not-yours.md.

## Status

Resolved on 2026-08-16. Fixed on origin by 7e66a9bd, which reconciled the call sites; verified by clanker gate and zig build e2e green at 6d068d19, and by reproducing the base failure alone at abcc85ba in a clean worktree. The attribution procedure is docs/runbooks/build-failure-not-yours.md.

## Symptom and impact

A session finishing unrelated work (the record-store HTTP endpoints, ADR 0019)
cherry-picked its own commit onto `origin/main` in a throwaway worktree, per
[the concurrent-sessions runbook](../../runbooks/concurrent-agent-sessions-on-one-checkout.md),
and gated it there. The gate failed at the build step with two errors in
`src/cli.zig`, neither in code that commit touched:

```
src/cli.zig:12309:5: error: expected 7 argument(s), found 8
    writeWorkspaceJson(&s, "", cwd_name, cwd_abs, null, true, false, countChats(sessions, "")) catch return;
src/cli.zig:12380:15: error: no field named 'path' in struct 'agent.workspace.Workspace'
    s.write(w.path) catch return;
```

The impact is not the broken build itself, which was fixed on origin within
minutes. It is the attribution cost: the failing file was `src/cli.zig`, which
the pushing session *had* modified, and the reported line numbers were shifted
by its own additions. The default reading of that output — "my change broke the
build" — is wrong, and acting on it means editing working code. Every session
that rebases onto a broken base pays this cost again, and pays it in the one
place it is most expensive: after the work is done and the gate was already
green on its own base.

## Reproduction

Build the suspect commit with none of your own work present. A detached
worktree is the cheapest way to get a tree that contains only it:

```bash
git worktree add --detach /tmp/check-origin origin/main
```

```bash
cd /tmp/check-origin && zig build
```

At abcc85ba this failed with the same two errors, at line numbers 11962 and
12033 — the same errors, unshifted. Identical errors at *lower* line numbers is
the tell: the base is broken and your additions only moved the reported lines
down.

## Root cause

`abcc85ba` changed `writeWorkspaceJson`'s signature and the `Workspace` struct
and left two call sites in `src/cli.zig` unreconciled. It is an intermediate
commit in a refactor the same author finished in the next push (`7e66a9bd`),
both authored by Marcel W. Wysocki — a human working on the repository, not an
agent session. Verified with `git log -1 --format='%an <%ae>' abcc85ba`.

That matters for what this record is *for*. An author pushing a work-in-progress
commit to their own main is ordinary, and this report does not propose changing
it. The defect being recorded is downstream: an agent session that rebases onto
such a commit reads the failure as its own, because the compiler names a file
that session edited and reports line numbers its additions shifted.

A contributing factor is a known reporting trap, already noted in AGENTS.md: a
`zig build` log ends with `failed command: ./.zig-cache/o/<hash>/test`, which is
the improve/gate staging tests' nested build, and piping that log through `tail`
or `head` reports the pipe's exit code rather than zig's. A session that checks
its build that way can believe a red build was green.

## Resolution

Fixed on origin by `7e66a9bd` ("workspace, cli updates"), which reconciled the
call sites with the new signature and struct. No change was needed in the
session that hit it: after rebasing onto `7e66a9bd`, the full gate and
`zig build e2e` both passed, and its commit went out as `6d068d19`.

## Verification

- `zig build` at `abcc85ba` in a worktree containing nothing else: fails, two
  errors (this is the attribution proof).
- `clanker gate` at `6d068d19` (the record-store endpoints rebased onto
  `7e66a9bd`): build, test, tools, fmt, lint, provider-kind,
  tools-ts-toolchain, release-contract all PASS.
- `zig build e2e` at the same commit: exit 0.

## Follow-up

- The general procedure — prove a build failure belongs to the base before
  touching your own change — is broader than this incident and is written up in
  [docs/runbooks/build-failure-not-yours.md](../../runbooks/build-failure-not-yours.md).
- Nothing is proposed against the pushing side. A human author landing an
  intermediate commit on their own main is normal, and a rule that agent
  sessions may not rebase onto one would be a worse cure than the disease.
  The whole cost here is attribution, and the runbook is the fix.

## References

- Investigation: none — the cause was visible in the first build.
- [Runbook — a build failure that is not yours](../../runbooks/build-failure-not-yours.md)
- [Runbook — several agent sessions share one checkout](../../runbooks/concurrent-agent-sessions-on-one-checkout.md):
  the throwaway-worktree push this surfaced during.
- Commits: `abcc85ba` (broke), `7e66a9bd` (fixed), `6d068d19` (the unrelated
  work that hit it).

