# Scripts

## Quick start

After `state`, `.agents`, and `.local` point to sibling directories in one
external storage root, install the user-level backup timer:

```bash
./scripts/install-state-backup.sh
```

Run one backup immediately:

```bash
./scripts/backup-state.sh
```

## State backup

The repository holds only three symlinks. Their external targets hold the
runtime state, private agent instructions, and local machine data. The backup
script resolves those links from its own checkout, verifies that they share one
storage root, and writes snapshots under that root's `backups/` directory.

Each snapshot is timestamped. `rsync --link-dest` hard-links unchanged files
to the preceding snapshot, so snapshots are incremental while each one remains
a complete directory tree. Transient `*.lock` files are excluded, and so is
`state/staging/`: those `imp-*` directories are the improve loop's checkout
copies with their build artifacts (`zig-out`, `zig-pkg`), regenerable on the
next run — they dominate snapshot size (gigabytes vs. tens of megabytes of
real store) and would dominate restore time, so they stay out the same way
`.clanker-worktrees/` is not covered by design.

**Session databases.** Sessions are one WAL-mode SQLite database per
conversation (`state/sessions/<id>.db`) and stay open for as long as a
serve/repl runs, so a plain copy can catch a main db and `-wal` sidecar that
never existed together. When the `sqlite3` CLI is available the script
checkpoints every session database immediately before copying (committed
turns move into the main db file; no durability setting changes), then runs
`PRAGMA quick_check` against each staged database and refuses to promote a
snapshot whose copy does not load — `latest` keeps pointing at the last good
snapshot and the journal names the store at fault. Without `sqlite3` the run
falls back to a crash-consistent copy and says so. Text stores (`*.jsonl`)
keep their known torn-last-line tolerance either way.

`clanker-state-backup.timer` runs at `:00` and `:30`. Its persistent setting
runs one catch-up backup when the user systemd manager returns after downtime.
The installed launchers live at `~/.local/bin/clanker-state-backup` and
`~/.local/bin/clanker-state-verify`; they are local configuration and are not
committed. `clanker doctor` reads the same layout proactively: its `state
backups` section names a checkout-confined `state`, a backup root with no
snapshot, a newest snapshot over two hours old, and an unset off-site mirror,
so a missed schedule is not something only the journal knows.

Snapshots older than `CLANKER_BACKUP_RETENTION_DAYS` (default 30) are pruned
on each successful backup; set it to `0` to keep every snapshot. Staging
directories from runs that died mid-backup are always cleaned up, and a
snapshot whose entries did not materialize is refused rather than promoted.

`.agents` and `.local` are checkout-private and may be real directories inside
the checkout; when either is absent the backup skips it instead of aborting.
`state` must resolve into the shared storage root. A run whose resolved backup
root would land inside the checkout itself (state never pointed at an external
root) is refused: a snapshot next to the data it protects is on the same disk
and dies with it, so it would only fake a backup. Point the three links at
sibling directories under an external storage root first.

**Failure domain.** Snapshots live under the same storage root as `state`
(`<storage_root>/backups/`, a sibling of the store), so they share the
store's disk: this posture protects the store against checkout loss
(re-clone, `git clean`), accidental deletion, and logical corruption, but a
loss of the storage-root volume itself takes the snapshots with it. If that
volume dies, there is no recovery from these backups — that is the accepted
single-failure-domain trade-off. To buy a second domain, set
`CLANKER_BACKUP_OFFSITE_DEST` in the service environment to an rsync
destination outside the storage root (another disk, or another machine:
`user@host:/vol/clanker-backups`); every successful run mirrors the whole
backup root there, and a failed mirror fails the run loudly rather than
leaving a silently stale second copy. The mirror never gets `--delete`: local
retention prunes do not propagate, so one deletion path cannot destroy both
copies (reclaim mirror space with a deliberate manual `rsync -a --delete`).

**Restore verification.** A backup that has never been restored is a
hypothesis. `scripts/verify-backup.sh` restores a snapshot's entries into a
scratch directory, compares them byte-for-byte against the snapshot, and
prints the copy time. The install wires it as
`clanker-state-verify.timer`, a weekly drill (Saturdays 03:17, catch-up run
after downtime) so restore verification does not depend on anyone remembering;
run it by hand before every incident-time restore so RTO stops being an
unknown:

```bash
./scripts/verify-backup.sh               # newest snapshot
./scripts/verify-backup.sh <snapshot>    # a specific one, before restoring it
```

**RPO / RTO.** RPO is bounded by the timer interval: at most 30 minutes of
writes are lost, and `Persistent=true` runs a catch-up snapshot after downtime.
Retention (default 30 days) also bounds how far back a point-in-time restore
can go — restore any snapshot up to the retention window, not just the latest.
RTO is the time to copy a chosen snapshot back; `scripts/verify-backup.sh`
measures it on every drill (weekly via `clanker-state-verify.timer`; check
its last run before trusting an old number). Restore is a copy-out, never an
edit of `backups/`: see
[docs/runbooks/state-restore.md](../docs/runbooks/state-restore.md).

## Software bill of materials

`scripts/sbom.py` emits a CycloneDX 1.5 inventory of everything clanker ships
or builds against, read only from in-tree manifests (no network, no installs):
`build.zig.zon` (zwasm, vaxis), `vendor/toml/` (zig-toml),
`tools/ts/bun.lock` (assemblyscript + transitive deps),
`ui/vendor/README.md` (vendored web UI), and
`scripts/setup-python-wasi.sh` (optional kernel interpreter). Every component
carries the pin that actually fixes it — the zig content hash, the bun.lock
registry digest, or the committed vendored file path.

```bash
./scripts/sbom.py -o sbom.cdx.json
```

Output is deterministic (sorted components, stable serial number, no
timestamp unless `SOURCE_DATE_EPOCH` is set, which CI does), so the same tag
always produces the same document. CI smoke-tests generation on every run and
attaches `sbom.cdx.json` to each GitHub Release.
