# Runbook — State backups are not running

## TL;DR

- **Use when:** How to tell whether clanker state backups are actually being written, and what to do when the timer reports success but no snapshot appears (or reports failure every 30 minutes).
- **Recover by:** Determine the current verified procedure.
- **Verify with:** The linked report's verification steps.

## Scope and preconditions

Applies where `scripts/backup-state.sh` is installed behind a user timer
(`scripts/install-state-backup.sh` links it to
`~/.local/bin/clanker-state-backup` and installs
`clanker-state-backup.timer`, every 30 minutes). The backup root is
`<storage_root>/backups/`, where `storage_root` is the parent of whatever
`state` resolves to.

## Diagnose

The age of the newest snapshot is the only fact that matters; a timer that is
`active` says nothing about whether it succeeded.

    ls -lt <storage_root>/backups/ | head -3

If the newest snapshot is older than the timer interval, read why:

    systemctl --user status clanker-state-backup.service
    journalctl --user -u clanker-state-backup.service -n 20 --no-pager

The script's own diagnostics are one line each and name the entry at fault:

- `<name> must resolve to <path>` — `state` or `.local` is not the shared
  store the snapshot expects.
- `<path> is not a directory` — the resolved target is missing or is a file.

Reproduce outside systemd, which prints the same line without the journal:

    ./scripts/backup-state.sh

## Recover

Point the offending entry back at the shared store. `state` and `.local`
are normally symlinks into `storage_root`; recreate the symlink rather than
copying, so one directory does not become two diverging ones.

`.agents` is deliberately exempt: it is checkout-private, may be a real
directory in the checkout, and is skipped when absent, so it never blocks a
backup.

Run the backup by hand once the layout is right, then let the timer resume:

    ./scripts/backup-state.sh
    systemctl --user start clanker-state-backup.service

A backup is never restored by editing `backups/`. Copy out of a snapshot:

    rsync -a <storage_root>/backups/<timestamp>/state/ <storage_root>/state/

## Verify

    ls -l <storage_root>/backups/latest/
    systemctl --user is-failed clanker-state-backup.service

`latest` must point at a snapshot containing `state/` and `local/` (and
`agents/` when present), and `is-failed` must not print `failed`.
`~/.local/bin/clanker-state-backup` is a symlink to the repo script, so a
fix in the checkout needs no reinstall.

## Escalate or follow up

## References

- Report: none yet
