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

**State databases.** Every SQLite database in the store is WAL-mode and stays
open for as long as a serve/repl runs, so a plain copy can catch a main db and
`-wal` sidecar that never existed together. That is one database per
conversation (`state/sessions/<id>.db`), one per replicated peer conversation
(`state/mesh/<owner>/sessions/<id>.db`, conversations this instance holds and
cannot re-sync from a live peer), and the derived cross-session search index
(`state/session_fts.db`). When the `sqlite3` CLI is available the script
checkpoints every one of them immediately before copying (committed turns move
into the main db file; no durability setting changes), then runs
`PRAGMA quick_check` against each staged database and refuses to promote a
snapshot whose copy does not load — `latest` keeps pointing at the last good
snapshot and the journal names the store at fault. The search index is the one
exception, and deliberately: it is derived from the session databases,
rebuilds as sessions are saved, and is read fail-open (a missing or corrupt
index costs a linear scan, `src/agent/session_fts.zig`), so it is reported as
a warning and the snapshot is kept — blocking every backup on a rebuildable
index would be an outage of the backup itself. Deleting `state/session_fts.db`
restores full search. Without `sqlite3` the run falls back to a
crash-consistent copy and says so. Text stores (`*.jsonl`) keep their known
torn-last-line tolerance either way.

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

**Local configuration.** `config.local.toml`, `config.local.json` and `.env`
are the one piece of machine state that lives in the checkout rather than in
`state/`, and they are gitignored, so a lost checkout or a lost volume takes
them with it and nothing else has a copy. They are copied verbatim into a
`config/` entry (a snapshot that has none of them carries no `config/`
directory), which the weekly drill restores and byte-compares like any other
entry. They carry API keys, so the backup root is created `chmod 700` and each
file keeps its own mode; a snapshot, and the off-site mirror that copies one,
is as sensitive as the keys it holds. `config.toml` is deliberately absent: it
is committed, and git is its backup.

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
single-failure-domain trade-off. To buy a second domain, set `CLANKER_BACKUP_OFFSITE_DEST` to an rsync
destination outside the storage root (another disk, or another machine:
`user@host:/vol/clanker-backups`); every successful run mirrors the whole
backup root there, and a failed mirror fails the run loudly rather than
leaving a silently stale second copy. It has to be a file: a timer-run
service starts with systemd's own environment, so exporting the variable in a
shell never reached the timer, and the second failure domain would have
silently not existed.
The mirror never gets `--delete`: local
retention prunes do not propagate, so one deletion path cannot destroy both
copies (reclaim mirror space with a deliberate manual `rsync -a --delete`).

The scheduled runs read that variable, and every other backup knob
(`CLANKER_BACKUP_RETENTION_DAYS`, `CLANKER_BACKUP_MAX_AGE_SECONDS`), from
`~/.config/clanker/backup.env` (`$XDG_CONFIG_HOME/clanker/backup.env`), which
`scripts/install-state-backup.sh` writes as a commented template on first run
and never rewrites. It is a systemd `EnvironmentFile`: `KEY=value`, one per
line, no `export`. A shell export is not enough and does not reach the timer,
because a user service inherits the user manager's environment, not the login
shell's; `clanker doctor` reads the same file, so a shell whose export
disagrees with it is reported rather than believed.

`backup.env` is the only file either unit reads (both name it in
`EnvironmentFile=-`). An earlier installer also wrote a sibling
`state-backup.env` and the docs pointed operators there, so a
`CLANKER_BACKUP_OFFSITE_DEST` set in it reached no timer and the second
failure domain did not exist while looking configured; the installer now
names the dead file and tells the operator to move its settings, and
`clanker doctor` reads `backup.env` only. A `state-backup.env` on an already
installed machine is left in place (it may hold the only copy of a
destination) and reported, never deleted.
`clanker doctor` reads a local mirror and reports how it compares with the
store's newest snapshot, so a destination that stopped being written shows up
without waiting for the next backup run to fail; a remote `user@host:/path`
destination has no local directory to read, so doctor says it is configured
rather than claiming it holds anything.

**Restore verification.** A backup that has never been restored is a
hypothesis. `scripts/verify-backup.sh` restores a snapshot's entries into a
scratch directory, compares them byte-for-byte against the snapshot, opens
every restored database with `PRAGMA quick_check` (the search index warned
about, never fatal, for the reason above), and prints the copy time. A
restore that copies faithfully but does not load is a failure, not a pass.
Both scripts are exercised by `scripts/test_backup_state.py` and
`scripts/test_verify_backup.py`, which CI runs: nothing else in the build
executes them, so a regression in either reaches a machine as the first sign
of an incident. The install wires the drill as
`clanker-state-verify.timer`, a weekly drill
(Saturdays 03:17, catch-up run after downtime) so restore verification does
not depend on anyone remembering; run it by hand before every incident-time
restore so RTO stops being an unknown:

```bash
./scripts/verify-backup.sh               # newest snapshot
./scripts/verify-backup.sh <snapshot>    # a specific one, before restoring it
```

Verifying the newest snapshot also asserts it is fresh: a perfect restore of a
three-month-old snapshot still means the RPO is three months. The bound is
`CLANKER_BACKUP_MAX_AGE_SECONDS`, default 7200 (four missed 30-minute timer
intervals); a drill of a snapshot you chose on purpose skips the age check.
When `CLANKER_BACKUP_OFFSITE_DEST` names a directory on this host, the drill
also warns if that mirror holds no `latest`, so a second failure domain that
stopped following the local root is not read as a healthy copy.

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

## Release artifact checksums

`scripts/release-checksum.sh` writes and verifies a `.sha256` sidecar per
release binary:

```bash
./scripts/release-checksum.sh create dist/clanker-v0.5.0-x86_64-linux-musl
./scripts/release-checksum.sh verify dist
```

The release matrix (`release-build` in `.github/workflows/ci.yml`) runs
`create` per target; the sidecar rides out with the binary because the upload
path is the same `clanker-*` glob. `release-publish` runs `verify` on the
merged artifact directory before `gh release create`, and both the binaries
and the sidecars are attached to the Release, so a consumer can check the
download:

```bash
sha256sum --check --strict clanker-v0.5.0-x86_64-linux-musl.sha256
```

`verify` fails on a checksum mismatch, on a directory with no sidecar at all,
and on a `clanker-*` binary that has no sidecar beside it: a matrix leg that
never uploaded would otherwise leave a release that verified clean and was
missing a target. macOS has no `sha256sum`, so the script uses `shasum -a 256`
there; both write the same sidecar format.
