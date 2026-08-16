# Bug — State backups stopped for two days because .agents is a real directory

## TL;DR

- **What failed:** backup-state.sh required all three of state, .agents and .local to resolve into the shared storage root and exited 1 on the first mismatch, before any rsync. Once .agents became a checkout-local directory rather than a symlink into clanker-state/agents, every run aborted, so state and .local were never backed up either. The last snapshot was 2026-08-14T043008Z and the user timer had been failing every 30 minutes since.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-16. Location check narrowed to state and .local in scripts/backup-state.sh; verified by a fresh snapshot 20260816T105051Z and a successful systemd run.

## Status

Resolved on 2026-08-16. Location check narrowed to state and .local in scripts/backup-state.sh; verified by a fresh snapshot 20260816T105051Z and a successful systemd run.

## Symptom and impact

`clanker-state-backup.service` failed on every 30-minute firing with one line:

    .agents must resolve to /home/yannick/code/ywy50/clanker-state/agents

No snapshot had been written since `20260814T043008Z` (2026-08-14 12:30
local). Two days of `state/` — sessions, goals, learnings, token stats — and
of `.local/` were unprotected. systemd reported the failure, but a unit that
fails every half hour is easy to stop reading.

## Reproduction

Make `.agents` a real directory in the checkout rather than a symlink into
the storage root, then run the script:

    ./scripts/backup-state.sh

It exits 1 naming `.agents`, and `backups/` gains no new snapshot, even
though `state` and `.local` are both correctly configured.

## Root cause

`scripts/backup-state.sh` looped over `state:state agents:.agents
local:.local` and required each entry to `readlink -f` to
`$storage_root/$name`, exiting 1 on the first mismatch. The check ran
before any `rsync`, and `state` is the first entry only by ordering — the
loop aborts the entire run, so one misconfigured entry stops the other two
from ever being copied.

The layout assumption had gone stale. `.agents` is checkout-private and
gitignored (AGENTS.md), so a real directory inside the checkout is a
legitimate arrangement; `clanker-state/agents/` still held the older
arrangement (an `AGENTS.md` symlink into `agents-setup` plus a `.bak`).

## Resolution

The strict location check now applies to `state` and `.local` only. Backing
up some other directory under those names would silently restore the wrong
data, so they must be where they are declared. `.agents` is backed up from
wherever it resolves, because the point is to preserve its contents rather
than to enforce a layout, and an absent `.agents` is a soft skip — the same
way the agent rules themselves treat it.

## Verification

`./scripts/backup-state.sh` writes `20260816T105051Z` containing all three
of `agents/`, `local/` and `state/`, and `latest` advances to it.
`systemctl --user start clanker-state-backup.service` then logs "Finished"
rather than "Failed with result 'exit-code'", and
`systemctl --user is-failed` reports `inactive`.
`~/.local/bin/clanker-state-backup` is a symlink to the repo script, so the
timer picks the fix up with no reinstall.

## Follow-up

## References

- Investigation: none yet
