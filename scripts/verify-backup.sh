#!/usr/bin/env bash
# Restore verification drill for clanker state backups.
#
# A backup that has never been restored is a hypothesis, not a backup. This
# script proves a snapshot can actually be copied back out: it restores one
# snapshot's entries into a scratch directory (never touching the live store
# or the snapshot itself), compares the copies byte-for-byte against the
# snapshot, and reports how long the restore took. Run it as a periodic drill
# and before every incident-time restore.
#
# Usage:
#   ./scripts/verify-backup.sh                # verify the newest snapshot
#   ./scripts/verify-backup.sh <snapshot_dir> # verify a specific snapshot
#
# Exit 0: every entry restored and matches the snapshot.
# Exit 1: no snapshot to verify, or a restore/compare mismatch.
#
# Restore time is measured so RTO stops being an unknown: a snapshot that
# takes N seconds to copy out is the lower bound on a real restore of the
# same size. The drill copies the same entry set the backup captures
# (state/, plus local/ and agents/ when the snapshot holds them); `staging/`
# and `*.lock` are absent by design (see backup-state.sh).
set -euo pipefail

script_path=$(readlink -f -- "$0")
script_dir=$(dirname -- "$script_path")
repo_root=$(dirname -- "$script_dir")
state_root=$(readlink -f -- "$repo_root/state")
backup_root="${CLANKER_BACKUP_ROOT:-$(dirname -- "$state_root")/backups}"

snapshot="${1:-}"
if [ -z "$snapshot" ]; then
    snapshot="$backup_root/latest"
    if [ ! -e "$snapshot" ]; then
        printf 'error: no %s/latest: no snapshot has ever been promoted\n' "$backup_root" >&2
        printf 'the backup has not run (or has always failed) -- see docs/runbooks/state-backups-not-running.md\n' >&2
        exit 1
    fi
fi

[ -d "$snapshot" ] || {
    printf 'error: %s is not a snapshot directory\n' "$snapshot" >&2
    exit 1
}
snapshot=$(readlink -f -- "$snapshot")

entries="state"
for extra in local agents; do
    [ -d "$snapshot/$extra" ] && entries="$entries $extra"
done

scratch=$(mktemp -d "${TMPDIR:-/tmp}/clanker-restore-verify.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

start=$(date +%s)
bytes=0
for entry in $entries; do
    mkdir -p "$scratch"
    rsync -a "$snapshot/$entry/" "$scratch/$entry/"
done
elapsed=$(($(date +%s) - start))

for entry in $entries; do
    if ! diff -rq "$snapshot/$entry" "$scratch/$entry" >/dev/null; then
        printf 'FAIL: restored %s/ differs from the snapshot -- do not restore from %s\n' "$entry" "$snapshot" >&2
        exit 1
    fi
    size=$(du -sb "$snapshot/$entry" 2>/dev/null | cut -f1)
    [ -n "$size" ] && bytes=$((bytes + size))
done

printf 'ok: %s restored %s entries (%s bytes) in %ss and matches the snapshot\n' \
    "$(basename -- "$snapshot")" "${entries// /,}" "$bytes" "$elapsed"
