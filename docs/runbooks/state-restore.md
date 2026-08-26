# Runbook — Restore clanker state from a backup snapshot

## TL;DR

- **Use when:** `state/` (or `.local/`, `.agents/`) is lost, corrupted, or
  deleted, or bad code wrote bad data for a while and you want the store as it
  was before — and `<storage_root>/backups/` holds snapshots.
- **Recover by:** Pick a snapshot, stop clanker, copy its `state/` tree back
  over the live target, verify, restart.
- **Verify with:** `clanker sessions` lists the old sessions and spot-checked
  transcript files match the snapshot.

## Scope and preconditions

Applies wherever `scripts/backup-state.sh` is installed (user timer, every 30
minutes, `scripts/install-state-backup.sh`). `storage_root` is the parent of
whatever `state` resolves to; snapshots live in
`<storage_root>/backups/<YYYYmmddTHHMMSSZ>/`, each a complete tree with
`state/` and, when present, `local/` and `agents/`. `latest` symlinks the
newest snapshot. Restore is a copy-out of one snapshot — never an edit of
`backups/`.

**What a snapshot does and does not cover:**

- Covered: everything under `state/` — session transcripts (`sessions/`),
  spill and export text, run graphs (`runs/`, `history/`), the improve ledger
  (`improvements.jsonl`), stats (`token_stats.jsonl`, `reasoning.jsonl`,
  `autolearn.jsonl`), goals, board, plugins, chat history, logs — plus
  checkout-local `.local/` and `.agents/` when they exist. `*.lock` files are
  excluded by design; flock locks die with their process, so a restored tree
  never carries stale locks. `state/staging/` (the improve loop's checkout
  copies with build artifacts) is excluded too: regenerable, and it would
  dominate snapshot size and restore time.
- Not covered: the checkout itself (`docs/` records, source — they live in
  git), `config.local.toml`, `.env`, and provider credentials. Those are
  machine-local and are restore *inputs*, not outputs: recreate them from
  wherever the keys are kept, or the restored store will not run against the
  same providers.
- Not covered by design: `.clanker-worktrees/` (ephemeral improve staging;
  merged work lands in git and `state/improvements.jsonl`).
- Failure-domain boundary: snapshots live under the same storage root as
  `state` (a sibling `backups/`), so they die with that volume. This posture
  recovers a store that was deleted or corrupted while its volume survived; a
  loss of the storage-root volume itself takes the snapshots too and is not
  recoverable from these backups.

**RPO / RTO.** RPO is at most 30 minutes (timer interval), and `latest` is
never more than one interval behind a running backup. Because retention
(default `CLANKER_BACKUP_RETENTION_DAYS` = 30) keeps every snapshot, a
point-in-time restore can go back up to the retention window — the realistic
recovery for logical corruption, where the newest snapshot is the one you do
*not* want. RTO is measured by `scripts/verify-backup.sh`, which restores a
snapshot to a scratch dir and reports the copy time; the install wires that
as `clanker-state-verify.timer`, a weekly drill whose journal history keeps
the number current. Until a drill has covered the target size, treat RTO as
unmeasured.

Session databases are checkpointed before the copy and quick-checked after
(when the `sqlite3` CLI is present), so what lands in a snapshot loads; if
the checkpoint could not complete for a hot database the run says so in its
output. The text stores (`*.jsonl`) are still copied each file as it is read,
so a tail caught mid-append may carry a torn last line. Every later check
reads such files leniently, but verify after restore (below) rather than
assuming.

## Diagnose

Decide which disaster you are in, because it picks the snapshot:

1. **Instance/disk loss or deletion:** `state` is gone or empty. Use the
   newest snapshot. If the *volume* that held `state` is gone, the snapshots
   (a sibling `backups/` on the same volume) are gone too — nothing in this
   runbook can recover that; fall back to any copy you keep elsewhere.
2. **Logical corruption or bad deploy:** bad code wrote bad data for a while.
   Pick the newest snapshot *before* the corruption started. Snapshot names
   are UTC ISO timestamps and sort chronologically; `ls -lt
   <storage_root>/backups/` shows them newest-first, with the retained age on
   the `pruned` lines of recent runs.
3. **Wrong-version rollback:** a new version wrote formats an older one cannot
   read. Restore a snapshot from before the upgrade *and* reinstall the old
   binary — the data layer rolls back together, never one alone.

Then confirm the choice is actually restorable:

```bash
ls -lt <storage_root>/backups/ | head -5
readlink -f <storage_root>/backups/latest   # which snapshot is newest
ls <storage_root>/backups/<timestamp>/state | head   # has content?
```

If there is no snapshot at all (no `backups/` directory, or only `.incomplete`
staging dirs), the backup has never run or has been failing silently — follow
[state-backups-not-running.md](state-backups-not-running.md) first; nothing in
this runbook can manufacture a snapshot that does not exist.

## Recover

1. Stop everything that writes `state/` first: `clanker serve`, `clanker
   repl`, and any `clanker run`/goal loops. Restoring over a live tree mixes
   old and new writes and the next backup re-snapshots the mess.
   `systemctl --user stop clanker-state-backup.timer` if the timer is enabled,
   so a mid-restore run does not snapshot the half-restored tree (the weekly
   verify drill only reads snapshots, so it can keep running).
2. Restore into the *target* of the `state` link — the external storage root —
   not into the checkout, so the checkout's link keeps working. Anchor on the
   snapshot path you picked in Diagnose, not on `state`, which the incident
   may have destroyed:
   ```bash
   SNAP=<storage_root>/backups/<timestamp>    # the path you picked above
   storage_root=$(dirname "$(dirname "$(readlink -f "$SNAP")")")
   rsync -a --delete "$SNAP/state/" "$storage_root/state/"
   # only if the snapshot has them and the targets exist:
   rsync -a --delete "$SNAP/local/" "$storage_root/.local/" 2>/dev/null || true
   rsync -a --delete "$SNAP/agents/" "$storage_root/.agents/" 2>/dev/null || true
   ```
   `--delete` makes the target match the snapshot exactly, dropping files the
   corruption added. That also drops a live `state/staging/` if one exists —
   expected and harmless, since snapshots never carry it (regenerable improve
   staging). Skip `--delete` when the goal is to *recover* files into a
   store that was only partially lost — prefer keeping whatever survived.
   Run as the same user clanker runs as, so ownership and mode stay intact.
3. Recreate anything the snapshot does not carry: `config.local.toml`, `.env`
   (or re-export the provider keys), and re-link any `state`/`.local`/`.agents`
   symlinks the incident destroyed.
4. Restart the backup timer, then clanker:
   ```bash
   systemctl --user start clanker-state-backup.timer
   ./scripts/backup-state.sh   # prove the restored store snapshots cleanly
   ```

## Verify

- `clanker sessions` lists the sessions the snapshot contained (not just a
  fresh empty list).
- Spot-check transcripts against the snapshot:
  `cmp <storage_root>/state/sessions/<id>.db
  <SNAP>/state/sessions/<id>.db` for one pre-incident session id
  (each session is one SQLite database).
- If a torn tail is suspected (snapshots are crash-consistent), open the
  affected `*.jsonl`: a torn last line is normal and the file's reader
  tolerates it — do not "repair" the whole store for it.
- `readlink -f <storage_root>/backups/latest` points at a snapshot newer than
  the restore time, and neither `systemctl --user is-failed
  clanker-state-backup.service` nor `systemctl --user is-failed
  clanker-state-verify.service` prints `failed`.
- A restore is only proven by a drill. `scripts/verify-backup.sh` is the
  drill: it restores a snapshot into a scratch directory, compares every
  entry byte-for-byte, and reports the copy time. The install schedules it
  weekly (`clanker-state-verify.timer`, catch-up run after downtime), so the
  journal holds recent drill artifacts; run it once more before this
  procedure on the exact snapshot you picked.

## Escalate or follow up

- Restore surfaced missing data the snapshot should have had (a store the
  backup does not cover): extend `backup-state.sh`'s entry list and re-drill.
- The newest snapshot was already corrupt (bad code ran before the backup):
  tighten retention so a pre-incident point-in-time restore stays reachable,
  or restore from an older snapshot and accept the gap.
- A backup that never ran is the root cause: fix per
  [state-backups-not-running.md](state-backups-not-running.md) and open an
  investigation record for what deleted the data.

## References

- Code: `scripts/backup-state.sh`, `scripts/install-state-backup.sh`,
  `scripts/verify-backup.sh`,
  `scripts/systemd/clanker-state-backup.{service,timer}`,
  `scripts/systemd/clanker-state-verify.{service,timer}`
- Docs: `scripts/README.md` (State backup),
  [state-backups-not-running.md](state-backups-not-running.md)
- Layout: `state/` is one of the checkout-wide shared roots
  (`src/improve/worktree.zig`); stores under it are listed in
  `docs/README.md`
- Last verified: the weekly drill (`clanker-state-verify.timer`) restores a
  snapshot into a scratch dir on schedule; its journal entries are the
  standing drill artifacts. A full manual restore of this procedure has not
  been recorded yet — log one when it happens.
