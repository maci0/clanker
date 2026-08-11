# Project-local operator instructions (maci0/clanker)

These rules apply to this checkout of **maci0/clanker**. They are adapted from
the GitHub operations workflow used for `maci0/7dtd-*` repositories.

## Multiple agents work in this repository at the same time

Assume you are not alone. Other agents edit this working tree concurrently,
in the same session you are running in.

**Finding files modified that you did not touch is normal.** A `git status`
that was clean when you started and is dirty ten minutes later means another
agent is working, not that something is wrong. Do not halt, do not treat it
as suspicious, and do not investigate it as an anomaly — carry on with your
own task.

The rules below are what make this safe.

## Stage commits by explicit path

**Never `git add -A`, `git add .`, or `git commit -a`.** Another agent's
half-finished edits are almost certainly in the working tree, and those
commands sweep them into your commit — capturing a broken intermediate state
under a message that does not describe it, and stealing work whose author is
still mid-edit.

Stage the specific files your own task changed, by path:

```bash
git add path/to/file-you-changed.zig path/to/other-file-you-changed.md
```

Leave every other modified file exactly as you found it. Do not stash it, do
not revert it, do not mention it in your commit message. If you genuinely
cannot tell whether a file is yours, it is not — you edited it this session
or you did not.

### When another agent edited the same file you did

Path scoping is file-granular: `git add path/to/shared.md` stages every
change in that file, including hunks you did not write. That is fine —
**commit it.**

Shared coordination files (for example `TODO.md`, design docs) are useless
to the other agent until they are committed. Do not inspect foreign hunks,
do not judge whether they look finished, and do not try to split the file —
interactive staging is unavailable here and patch surgery risks mangling
someone's work to solve a problem that does not exist. Stage the whole file
and move on.

## GitHub operations workflow (maci0/clanker)

This repository is **maci0/clanker**, not a monorepo that may push straight
to the default branch.

For **every** finished unit of work, agents **always** complete the full
lifecycle **autonomously** without waiting for user confirmation when
unblocked:

**new branch → commit → push → open PR → merge**

Rules:

- Never commit or push directly to the default branch (`main`).
- Merge is the default after the PR is open.
- Leave a PR unmerged only for review blockers, failing checks, conflicts,
  or explicit user direction — and report the reason.
- Stage by explicit path only (see above).
- The same lifecycle applies when a change is reusable upstream in another
  maci0 repo (separate branch/PR there); that is the same rule, not a
  narrower special case.

## Commit and pull-request messages

Never add `Co-Authored-By` trailers or similar attribution/tool-generated
fluff (for example, “Generated with …” links or badges) to commit messages or
pull-request descriptions. Write them as if authored solely by the user.
