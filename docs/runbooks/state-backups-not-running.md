# Runbook — State backups are not running

## TL;DR

- **Use when:** How to tell whether clanker state backups are actually being written, and what to do when the timer reports success but no snapshot appears (or reports failure every 30 minutes).
- **Recover by:** Determine the current verified procedure.
- **Verify with:** The linked report's verification steps.

## Scope and preconditions

Applies where `scripts/backup-state.sh` is installed behind a user timer
(`scripts/install-state-backup.sh` links it to
`~/.local/bin/clanker-state-backup` and installs
`clanker-state-backup.timer`, every 30 minutes). The same install adds
`clanker-state-verify.timer`, a weekly restore drill over
`~/.local/bin/clanker-state-verify`; a failed drill is this runbook's subject
too, since it means the newest snapshots cannot be restored. The backup root
is `<storage_root>/backups/`, where `storage_root` is the parent of whatever
`state` resolves to.

## Diagnose

The age of the newest snapshot is the only fact that matters; a timer that is
`active` says nothing about whether it succeeded.

    ls -lt <storage_root>/backups/ | head -3

If the newest snapshot is older than the timer interval, read why:

    systemctl --user status clanker-state-backup.service
    journalctl --user -u clanker-state-backup.service -n 20 --no-pager

The script's own diagnostics are one line each and name the entry at fault:

- `<name> must resolve to <path>` — `state` is not the shared store the
  snapshot expects. `.agents` and `.local` are exempt from this check: either
  may be a real directory inside the checkout, and a missing one is skipped,
  not a failure.
- `<path> is not a directory` — the resolved target is missing or is a file.
  Applies to `state` always, and to `.local`/`.agents` only when they exist.
- `backup root <path> is inside the checkout: state is not a symlink to an
  external storage root` — `state` was never pointed at a sibling directory
  under an external storage root, so the snapshot would land next to the data
  it protects (same disk; a re-clone or `git clean` deletes it). The run
  refuses rather than fake a backup.
- `snapshot entry <name>/ did not materialize` — rsync copied nothing usable;
  the run refuses to promote an empty snapshot over `latest`.
- `staged <db> failed integrity check` — a copied session database does not
  pass `PRAGMA quick_check`; the run refuses to promote it and `latest`
  keeps pointing at the last good snapshot. Expect this after disk trouble
  or when `sqlite3` was missing for a stretch (unccheckpointed hot wal pairs
  can copy torn); re-run once `sqlite3` is present.
- `error: mirroring to <dest> failed` — the off-site mirror named by
  `CLANKER_BACKUP_OFFSITE_DEST` did not update. The local snapshot just
  taken is complete; fix the destination and re-run so the second failure
  domain stops lagging.

Reproduce outside systemd, which prints the same line without the journal:

    ./scripts/backup-state.sh

## Recover

Point the offending entry back at the shared store. `state` and `.local`
are normally symlinks into `storage_root`; recreate the symlink rather than
copying, so one directory does not become two diverging ones. When the refusal
says the backup root is inside the checkout, `state` is a real directory in
the checkout (or points at one): create the external storage root, move the
store there, and symlink `state` (and `.local`, `.agents`) to it.

`.agents` and `.local` are deliberately exempt: they are checkout-private, may
be real directories in the checkout, and are skipped when absent, so neither
ever blocks a backup.

Run the backup by hand once the layout is right, then let the timer resume:

    ./scripts/backup-state.sh
    systemctl --user start clanker-state-backup.service

A backup is never restored by editing `backups/`. Copy out of a snapshot:

    rsync -a <storage_root>/backups/<timestamp>/state/ <storage_root>/state/

## Verify

    ls -l <storage_root>/backups/latest/
    systemctl --user is-failed clanker-state-backup.service
    systemctl --user is-failed clanker-state-verify.service

`latest` must point at a snapshot containing `state/` and `local/` (and
`agents/` when present), and neither service may print `failed`. A green
backup service with a failed verify service means snapshots are being
written that may not restore — treat the newest snapshots as unproven until a
verify run passes. `~/.local/bin/clanker-state-backup` and
`~/.local/bin/clanker-state-verify` are symlinks to the repo scripts, so a
fix in the checkout needs no reinstall.

## Escalate or follow up

## References

- Report: none yet
