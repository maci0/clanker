# Runbook — Restore clanker state from a backup snapshot

## TL;DR

- **Use when:** `state/` (or `.local/`, `.agents/`, the machine-local
  configuration) is lost, corrupted, or deleted, or bad code wrote bad data
  for a while and you want the store as it was before — and
  `<storage_root>/backups/` holds snapshots.
- **Recover by:** Pick a snapshot, stop clanker, copy its `state/` tree back
  over the live target, verify, restart.
- **Verify with:** `clanker sessions` lists the old sessions and spot-checked
  transcript files match the snapshot.

## Scope and preconditions

Applies wherever `scripts/backup-state.sh` is installed (user timer, every 30
minutes, `scripts/install-state-backup.sh`). `storage_root` is the parent of
whatever `state` resolves to; snapshots live in
`<storage_root>/backups/<YYYYmmddTHHMMSSZ>/`, each a complete tree with
`state/` and, when present, `local/`, `agents/` and `config/`. `latest`
symlinks the newest snapshot. Restore is a copy-out of one snapshot, never an
edit of `backups/`.

**What a snapshot does and does not cover:**

- Covered: everything under `state/` — session transcripts (`sessions/`),
  spill and export text, run graphs (`runs/`, `history/`), the improve ledger
  (`improvements.jsonl`), stats (`token_stats.jsonl`, `reasoning.jsonl`,
  `autolearn.jsonl`), goals, board, plugins, chat history, logs — plus
  checkout-local `.local/` and `.agents/` when they exist, plus a `config/`
  entry carrying `config.local.toml`, `config.local.json` and `.env` plus
  `config/profiles/*.local.toml` (the gitignored machine-local configuration,
  which exists nowhere else and without which a restored store has no provider
  to call), plus a `home-agents/` entry holding `~/.agents/AGENTS.md` (the
  device-global operator rules that open every system prompt; the checkout's
  `.agents` is a different, per-project directory), plus a `home-config/`
  entry holding the backup unit's own `EnvironmentFile=` (the off-site
  destination, the retention window, the drill's staleness bound, at
  `$HOME/.config/clanker/backup.env`). The installer writes that file once and
  never rewrites it, so a re-install on a replacement machine reproduces the
  commented template; without the entry a restored store comes back with its
  second failure domain silently unset, which nothing reports as missing), plus
  a `checkout-data/`
  entry holding the operator-created data that lives in the checkout and is
  written at runtime, at its checkout-relative path: `ui/plugins/` (the
  `webui_addon` views), `cli-plugins/`, `tui-plugins/`, `tools/manifests/`,
  `presets/`, `commands/`, `chains/`, `themes/`, `skills/`, `agency/` (the
  persona corpus `agency_sync` mirrors, gitignored as fetched data, so it is on
  no other disk), the gitignored
  `.claude/` and `.grok/` rule directories, and `docs/ROADMAP.md`. Git holds
  only the half of those trees a human committed, so this entry is what
  carries the addon or preset a run created. `*.lock` files are
  excluded by design; flock locks die with their process, so a restored tree
  never carries stale locks. `state/staging/` (the improve loop's checkout
  copies with build artifacts) is excluded too: regenerable, and it would
  dominate snapshot size and restore time.
- Not covered: the rest of the checkout (`docs/` records, source — they live in
  git, and the `checkout-data/` entry carries only the named trees) and any
  provider credentials held outside those files. A snapshot
  taken before a key was added to `.env` cannot carry that key, so where the
  keys are actually kept stays a restore *input* for credentials no file in
  the checkout holds.
- Not covered by design: `.clanker-worktrees/` (ephemeral improve staging;
  merged work lands in git and `state/improvements.jsonl`).
- Failure-domain boundary: snapshots live under the same storage root as
  `state` (a sibling `backups/`), so they die with that volume. This posture
  recovers a store that was deleted or corrupted while its volume survived; a
  loss of the storage-root volume itself takes the snapshots too and is not
  recoverable from these backups.

**RPO / RTO.** RPO is at most 30 minutes (timer interval), and `latest` is
never more than one interval behind a running backup. That claim only holds
while runs keep happening: the weekly drill refuses a `latest` older than
`CLANKER_BACKUP_MAX_AGE_SECONDS` (default 7200, four missed intervals), so a
backup that stopped is a failed verify unit rather than a quiet RPO nobody
recomputed. Because retention (default `CLANKER_BACKUP_RETENTION_DAYS` = 30)
keeps every snapshot, a point-in-time restore can go back up to the retention
window — the realistic recovery for logical corruption, where the newest
snapshot is the one you do *not* want. RTO is measured by
`scripts/verify-backup.sh`, which restores a snapshot to a scratch dir,
re-opens every restored session database, and reports the copy time; the
install wires that as `clanker-state-verify.timer`, a weekly drill whose
journal history keeps the number current. Until a drill has covered the
target size, treat RTO as unmeasured.

Session databases are checkpointed before the copy and quick-checked after
(when the `sqlite3` CLI is present), so what lands in a snapshot loads; if
the checkpoint could not complete for a hot database the run says so in its
output. The same holds for the replicated peer conversations under
`state/mesh/<owner>/sessions/`, which this instance may have no live peer to
re-sync from: a copy that does not load is as fatal to the snapshot as a local
one. The one database a failed check does not block the backup on is
`state/session_fts.db`, the derived search index: it rebuilds from the session
databases and is read fail-open, so the run reports it and keeps the snapshot.
Deleting that file restores full search; `clanker session search` falls back
to a linear scan until it rebuilds. The text stores (`*.jsonl`) are still copied
each file as it is read, so a tail caught mid-append may carry a torn last
line. Every later check reads such files leniently, but verify after restore
(below) rather than assuming.

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
# which snapshot is newest. Plain `readlink` resolves the `latest` link
# (its target is absolute, so no `-f` is needed to make it meaningful);
# add `-f` on GNU/Linux to canonicalize a path that is itself a chain.
readlink <storage_root>/backups/latest
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
   On a host with a systemd user manager (the arrangement
   `scripts/install-state-backup.sh` sets up, and the one it links units for),
   `systemctl --user stop clanker-state-backup.timer` so a mid-restore run does
   not snapshot the half-restored tree. The same installer deliberately
   supports a host with no systemd, and there the scheduling is whatever you
   set up yourself (cron, launchd): suspend that schedule instead, and the
   weekly verify drill only reads snapshots, so it can keep running.
2. Restore into the *target* of the `state` link — the external storage root —
   not into the checkout, so the checkout's link keeps working. Anchor on the
   snapshot path you picked in Diagnose, not on `state`, which the incident
   may have destroyed. `SNAP` is already absolute, so plain `readlink -f`
   above would only canonicalize it; keep it BSD/macOS-compatible with
   `readlink` alone (macOS ships a readlink with no `-f`):
   ```bash
   SNAP=<storage_root>/backups/<timestamp>    # the path you picked above
   storage_root=$(dirname "$(dirname "$SNAP")")
   rsync -a --delete "$SNAP/state/" "$storage_root/state/"
   # only if the snapshot has them and the targets exist:
   rsync -a --delete "$SNAP/local/" "$storage_root/.local/" 2>/dev/null || true
   rsync -a --delete "$SNAP/agents/" "$storage_root/.agents/" 2>/dev/null || true
   # the gitignored machine-local config, back into the checkout it came from
   # (config/profiles/*.local.toml lands back under profiles/ this way)
   rsync -a "$SNAP/config/" "$repo_root/" 2>/dev/null || true
   # the device-global operator rules, back into $HOME (never the storage root)
   rsync -a "$SNAP/home-agents/" "$HOME/.agents/" 2>/dev/null || true
   # the backup units' own configuration, back into $HOME: the off-site
   # destination, the retention window and the drill's staleness bound. Restore
   # this before reinstalling the timer, or the reinstall reproduces the
   # commented template and the machine comes back with one failure domain
   # and no notice. Owner-only, like the file it replaces.
   install -d -m 700 "$HOME/.config/clanker"
   install -m 600 "$SNAP/home-config/clanker/backup.env" \
     "$HOME/.config/clanker/backup.env" 2>/dev/null || true
   # the operator-created checkout data (addons, plugin manifests, presets,
   # slash commands, themes, skills, agency/, .claude/.grok, docs/ROADMAP.md), back
   # into the checkout. No --delete: a snapshot of tracked files is older
   # than the checkout by construction, and deleting what it no longer
   # carries would revert committed work. Copy the subtrees you need
   # (`ui/plugins/<addon>/`) rather than the whole entry.
   rsync -a "$SNAP/checkout-data/" "$repo_root/" 2>/dev/null || true
   ```
   `--delete` makes the target match the snapshot exactly, dropping files the
   corruption added. That also drops a live `state/staging/` if one exists —
   expected and harmless, since snapshots never carry it (regenerable improve
   staging). Skip `--delete` when the goal is to *recover* files into a
   store that was only partially lost — prefer keeping whatever survived.
   Run as the same user clanker runs as, so ownership and mode stay intact.
3. Recreate anything the snapshot does not carry: provider credentials held
   outside `config.local.*`/`.env`, and re-link any
   `state`/`.local`/`.agents` symlinks the incident destroyed.
4. Restart the backup schedule, then clanker. With systemd:
   ```bash
   systemctl --user start clanker-state-backup.timer
   ./scripts/backup-state.sh   # prove the restored store snapshots cleanly
   ```
   On a host with no systemd (macOS), re-enable whatever you scheduled in step
   1 and run the same `./scripts/backup-state.sh` line.

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
- `readlink <storage_root>/backups/latest` points at a snapshot newer than
  the restore time, and on a systemd host neither `systemctl --user is-failed
  clanker-state-backup.service` nor `systemctl --user is-failed
  clanker-state-verify.service` prints `failed` (on a host with no systemd,
  the equivalent is that the schedule you manage runs and the last run
  succeeded).
- A restore is only proven by a drill. `scripts/verify-backup.sh` is the
  drill: it restores a snapshot into a scratch directory, compares every
  entry byte-for-byte — every entry the snapshot holds, so an entry the backup
  started writing is drilled the day it starts, with no list here to keep in
  step — opens each restored database
  (`PRAGMA quick_check`), and reports the copy time. The scratch is
  `restore-verify/` beside the storage root (`CLANKER_VERIFY_SCRATCH_DIR`
  overrides it), never `$TMPDIR`, so a store-sized copy does not land in
  tmpfs; expect that directory to grow to roughly the snapshot's size during
  a run and to be empty after it. The install schedules it
  weekly (`clanker-state-verify.timer`, catch-up run after downtime), so the
  journal holds recent drill artifacts; run it once more before this
  procedure on the exact snapshot you picked. The drill's own tests
  (`scripts/test_verify_backup.py`, `scripts/test_backup_state.py`) run in CI,
  so the check you are relying on is one that still passes.

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
