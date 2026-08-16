# Runbook — A build failure that is not yours

## TL;DR

- **Use when:** A build or gate fails in a file you edited, and you are about to
  go fix it — especially after a rebase, a cherry-pick, or a pull.
- **Recover by:** Building the base alone in a detached worktree. If it fails
  the same way, rebase onto the fix; change nothing of your own.
- **Verify with:** A green `clanker gate` on your work rebased onto a base that
  builds, and the base's own failure reproduced with none of your code present.

## Scope and preconditions

Applies whenever your tree is your work *plus* someone else's — a shared
checkout with several agent sessions, a rebase onto a moved `origin/main`, a
cherry-pick onto a base you did not build. It does not apply to a failure in a
tree only you have touched: there, the failure is yours.

The trap is specific. Your change and the break are in the same file, and your
additions shift the compiler's line numbers, so the error looks like it points
at code you just wrote. `src/cli.zig` is where this bites hardest, because it
is 17k lines and nearly every session touches it.

You need to be able to make a worktree. If `git worktree add` is unavailable,
this procedure does not work and you are back to reading the diff by hand.

## Diagnose

Read the error for *what it names*, not for which file it is in. A signature
mismatch (`expected 7 argument(s), found 8`) or a missing struct field in code
your diff does not contain is the first signal.

Confirm your diff does not touch it:

```bash
git diff origin/main -- <file> | grep -n "<symbol from the error>"
```

Then build the base with none of your work present. A detached worktree is the
cheapest tree that contains only it:

```bash
git worktree add --detach /tmp/check-base origin/main
```

```bash
cd /tmp/check-base && zig build
```

Read the result:

- **Same errors, lower line numbers** — the base is broken. Your additions
  moved the reported lines down; nothing of yours is implicated.
- **Same errors, same line numbers** — the base is broken and your change did
  not shift that file at all.
- **Base builds clean** — the failure is yours. Stop here and fix your change.

Do not skip this because the error "obviously" belongs to your change. The
whole point is that it does not look like it belongs to the base.

**Read the exit code, not the tail.** A `zig build` log ends with
`failed command: ./.zig-cache/o/<hash>/test`, which is the improve/gate staging
tests' nested build, not your suite. Piping through `tail` or `head` reports the
*pipe's* exit code, which is always 0:

```bash
zig build test > /tmp/build.log 2>&1; echo "EXIT=$?"
```

## Recover

When the base is broken, do not fix it inside your own change: a commit that
carries both your feature and someone else's repair is unreviewable, and you
will be guessing at intent in code you do not own.

Wait for the fix to land, then rebase onto it:

```bash
git fetch origin
```

```bash
git -C /tmp/push-<name> rebase origin/main
```

If nobody is fixing it and you are blocked, say so to whoever pushed it before
touching their file — check with `git log -1 --format='%an <%ae>' <sha>`, since
the author may be a person mid-refactor rather than another agent session. In
this checkout, agent sessions are reachable by message and `.local/TODO.md`
names who owns what.

Remove the diagnostic worktree once it has answered the question:

```bash
git worktree remove --force /tmp/check-base
```

## Verify

Gate your work on the fixed base, in the worktree you will push from, and read
the exit code:

```bash
clanker gate
```

```bash
zig build e2e
```

Both green means the failure was never yours and your change is clean against
the current base. A gate that was green on your old base proves nothing about
the new one — re-run it after every rebase.

## Escalate or follow up

Escalate when the base stays broken long enough to block you and no fix is in
flight. Say what you measured — the commit, the errors, and that they reproduce
with none of your work present — and let the author decide. A base that is
briefly unbuildable mid-refactor is not itself a defect to be reported; only
your inability to proceed is.

## References

- Report: [A commit on origin/main did not compile](../reports/bugs/2026-08-16-pushed-main-did-not-compile.md)
- [Runbook — several agent sessions share one checkout](concurrent-agent-sessions-on-one-checkout.md):
  the throwaway-worktree push where this most often surfaces.

