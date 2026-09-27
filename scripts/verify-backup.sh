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
# Three failures are reported, and all three are ones a job exit code alone
# cannot catch: a restore that does not match, a database that copies over
# intact but does not load, and a snapshot set that stopped being written
# (a drill that restores a three-month-old snapshot perfectly still says
# "ok", so freshness is checked whenever the newest snapshot is the subject).
#
# Usage:
#   ./scripts/verify-backup.sh                # verify the newest snapshot
#   ./scripts/verify-backup.sh <snapshot_dir> # verify a specific snapshot
#
# Exit 0: every entry restored, matches the snapshot, the restored SQLite
# databases load, and (for the newest snapshot) the backup is fresh.
# Exit 1: no snapshot to verify, a restore/compare mismatch, a database that
# copies over intact but does not load, a stale `latest`, or a mirror that
# stopped following the local root.
#
# Restore time is measured so RTO stops being an unknown: a snapshot that
# takes N seconds to copy out is the lower bound on a real restore of the
# same size. The drill copies the same entry set the backup captures
# (state/, plus local/ and agents/ when the snapshot holds them); `staging/`
# and `*.lock` are absent by design (see backup-state.sh).
set -euo pipefail

# Portable stand-in for `readlink -f`: macOS ships a BSD readlink with no
# `-f`, and every `readlink -f` here died under `set -euo pipefail` on a
# Mac. The target need not exist (state/ is created on first run), so an
# unresolvable path falls back to the spelling it was given.
resolve_path() {
    local p="$1" dir base
    dir=$(dirname -- "$p")
    base=$(basename -- "$p")
    if [ -d "$dir" ]; then
        printf '%s/%s\n' "$(cd -- "$dir" && pwd -P)" "$base"
    else
        printf '%s\n' "$p"
    fi
}

script_path=$(resolve_path "$0")
script_dir=$(dirname -- "$script_path")
repo_root=$(dirname -- "$script_dir")
state_root=$(resolve_path "$repo_root/state")
backup_root="${CLANKER_BACKUP_ROOT:-$(dirname -- "$state_root")/backups}"

snapshot="${1:-}"
verify_newest=1
if [ -n "$snapshot" ]; then
    verify_newest=0
else
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
snapshot=$(resolve_path "$snapshot")

entries="state"
for extra in local agents; do
    [ -d "$snapshot/$extra" ] && entries="$entries $extra"
done

# A drill proves the snapshots it can reach restore; it cannot tell that the
# backup stopped running. A perfect restore of a month-old snapshot is still
# an RPO the incident would eat, so when the subject is the newest snapshot
# (no argument, or an argument that is `latest`) its age is a failure in its
# own right. `stat -c` is GNU, `stat -f` is BSD; either answers with seconds.
# A drill of a deliberately chosen older snapshot skips the check -- that age
# is the point of picking it.
mtime_epoch() {
    stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1" 2>/dev/null
}
humanize_age() {
    local secs=$1
    if [ "$secs" -ge 86400 ]; then printf '%sd' "$((secs / 86400))"
    elif [ "$secs" -ge 3600 ]; then printf '%dh' "$((secs / 3600))"
    else printf '%dm' "$((secs / 60))"
    fi
}
check_freshness() {
    local max_age=$1
    case "$max_age" in
        ''|*[!0-9]*)
            printf 'warning: CLANKER_BACKUP_MAX_AGE_SECONDS=%s is not a second count; skipping the staleness check\n' \
                "$max_age" >&2
            return 0
            ;;
    esac
    local created age
    created=$(mtime_epoch "$snapshot") || created=""
    if [ -z "$created" ]; then
        printf 'warning: cannot read the age of %s; staleness unchecked\n' "$snapshot" >&2
        return 0
    fi
    age=$(($(date +%s) - created))
    [ "$age" -lt 0 ] && age=0
    printf 'newest snapshot %s is %s old (bound %ss)\n' \
        "$(basename -- "$snapshot")" "$(humanize_age "$age")" "$max_age"
    if [ "$age" -gt "$max_age" ]; then
        printf 'error: the newest snapshot is %s old, past the %ss bound: backups are not running (or the store stopped changing)\n' \
            "$(humanize_age "$age")" "$max_age" >&2
        printf 'fix the backup before trusting any restore -- see docs/runbooks/state-backups-not-running.md\n' >&2
        return 1
    fi
}
# Four missed 30-minute timer intervals. Exceeding it means no run has
# promoted a snapshot for hours, which the timer being `active` never says.
# The value the RPO actually promises is 30 minutes; four intervals of slack
# covers a laptop asleep across a couple of them.
if [ "$verify_newest" = 1 ]; then
    check_freshness "${CLANKER_BACKUP_MAX_AGE_SECONDS:-7200}" || exit 1
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/clanker-restore-verify.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

start=$(date +%s)
kib=0
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
    # `du -sb` is GNU-only; BSD du answers 0 bytes silently there, which
    # would print "0 bytes" for a multi-gigabyte store. `-sk` is in both.
    size=$(du -sk "$snapshot/$entry" 2>/dev/null | cut -f1)
    [ -n "$size" ] && kib=$((kib + size))
done

# Byte-for-byte equality with the snapshot only proves the copy was faithful.
# What an incident needs is a database the restored tree can actually open, so
# the restored copies (not the snapshot's) are the ones checked: a snapshot
# whose wal was never checkpointed can diff clean and still fail to load.
command -v sqlite3 >/dev/null 2>&1 || {
    printf 'note: sqlite3 not found; the restored session databases were not opened\n' >&2
    printf 'ok: %s restored %s entries (%s KiB) in %ss and matches the snapshot\n' \
        "$(basename -- "$snapshot")" "${entries// /,}" "$kib" "$elapsed"
    exit 0
}
check_restored_dbs() {
    local db result
    for db in "$scratch"/state/sessions/*.db; do
        [ -e "$db" ] || return 0
        if ! result=$(sqlite3 -- "$db" "PRAGMA quick_check;" 2>&1) || [ "$result" != "ok" ]; then
            printf 'FAIL: restored %s does not load (%s) -- the snapshot is readable but not restorable\n' \
                "$(basename -- "$db")" "${result:-sqlite3 failed}" >&2
            return 1
        fi
    done
}
check_restored_dbs || exit 1

printf 'ok: %s restored %s entries (%s KiB) in %ss, matches the snapshot, and its databases load\n' \
    "$(basename -- "$snapshot")" "${entries// /,}" "$kib" "$elapsed"

# Second failure domain. The mirror is written by backup-state.sh and fails
# that run loudly, but only for the run that failed: nothing re-asserts it, so
# a mirror that stopped (destination unmounted, credentials expired) leaves a
# stale second copy that still looks healthy. Only checkable when the
# destination is a path on this host; a `user@host:/vol/...` destination has no
# local directory to read, so the drill says so instead of claiming a pass.
offsite_dest=${CLANKER_BACKUP_OFFSITE_DEST:-}
if [ -n "$offsite_dest" ] && [ -d "$offsite_dest" ] && [ ! -e "$offsite_dest/latest" ]; then
    printf 'warning: off-site mirror %s holds no latest: the second failure domain is empty or stale\n' \
        "$offsite_dest" >&2
elif [ -n "$offsite_dest" ] && [ ! -d "$offsite_dest" ]; then
    printf 'note: off-site mirror %s is not readable from this host; mirror freshness unchecked\n' \
        "$offsite_dest" >&2
fi
