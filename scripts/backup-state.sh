#!/usr/bin/env bash
set -euo pipefail

script_path=$(readlink -f -- "$0")
script_dir=$(dirname -- "$script_path")
repo_root=$(dirname -- "$script_dir")
state_root=$(readlink -f -- "$repo_root/state")
storage_root=$(dirname -- "$state_root")
backup_root="$storage_root/backups"
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
staging="$backup_root/.${timestamp}.incomplete"
snapshot="$backup_root/$timestamp"
latest="$backup_root/latest"
copied=""

# The snapshot root is derived from wherever `state` resolves to. When that
# is a real directory inside the checkout (state was never pointed at an
# external storage root), the "backups" land in the same tree on the same
# disk as the data they protect: a disk or checkout loss takes both, and a
# re-clone or `git clean` deletes the snapshots outright. Refusing here turns
# that silent false backup into an explicit failure instead of blessing it
# with a success exit code twice an hour.
case "$backup_root" in
    "$repo_root"/*)
        printf '%s\n' \
            "backup root $backup_root is inside the checkout: state is not a symlink" \
            "to an external storage root, so a snapshot there would protect nothing" \
            "(same disk; a re-clone or git clean deletes it). Point state (and .local," \
            ".agents) at sibling directories under an external storage root, then re-run." \
            "See scripts/README.md and docs/runbooks/state-backups-not-running.md." >&2
        exit 1
        ;;
esac

mkdir -p "$backup_root"
# If the script dies mid-backup, the incomplete staging directory is garbage
# (the `latest` symlink still points at the last good snapshot). Remove it so
# failed runs do not accumulate; after a successful `mv` the path no longer
# exists and this is a no-op.
trap 'rm -rf -- "$staging"' EXIT
mkdir "$staging"

# Session databases are WAL-mode SQLite (`src/util/sqlite.zig` sets
# journal_mode=WAL; one db per conversation under `state/sessions/<id>.db`)
# and stay open for the life of a serve/repl. A plain rsync of a hot WAL pair
# can capture a main db plus sidecar that never existed together on disk:
# committed turns live in `<id>.db-wal`, and a torn or mismatched pair does
# not load on restore. Checkpointing each database immediately before the
# copy moves every committed transaction into the main db file, so the
# snapshot is a consistent single file even though writers continue
# afterwards (their later commits land in a fresh wal the next run
# checkpoints). This is maintenance, not a durability change: nothing about
# how clanker writes is altered. Without the sqlite3 CLI the copy falls back
# to today's crash-consistent behavior and says so instead of pretending.
checkpoint_session_wal() {
    command -v sqlite3 >/dev/null 2>&1 || {
        printf 'note: sqlite3 not found; session snapshots stay crash-consistent (wal not checkpointed)\n' >&2
        return 0
    }
    local db
    for db in "$state_root"/sessions/*.db; do
        [ -e "$db" ] || return 0
        sqlite3 -- "$db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 ||
            printf 'warning: wal checkpoint on %s did not complete; its snapshot stays crash-consistent\n' \
                "$(basename -- "$db")" >&2
    done
}
checkpoint_session_wal

for entry in state:state agents:.agents local:.local; do
    name=${entry%%:*}
    repo_name=${entry#*:}
    source=$(readlink -f -- "$repo_root/$repo_name")
    expected="$storage_root/$name"
    # `state` is the shared store and must be where it is declared: backing up
    # some other directory under its name would produce a snapshot that
    # silently restores the wrong data. `.agents` (checkout-private agent
    # rules) and `.local` (checkout-private coordination state) are different:
    # a real directory inside the checkout is a legitimate arrangement for
    # either, and its contents are worth keeping wherever they live -- the
    # point is to preserve them, not to enforce a layout. Requiring them to
    # resolve into the shared storage aborted the whole run on the first
    # entry, so a checkout-local or absent `.agents`/`.local` stopped `state`
    # from being backed up at all.
    if [ "$source" != "$expected" ] && [ "$repo_name" != ".agents" ] && [ "$repo_name" != ".local" ]; then
        printf '%s\n' "$repo_name must resolve to $expected" >&2
        exit 1
    fi
    # A missing `.agents` or `.local` is a soft skip, the same way the agent
    # rules treat `.agents`: a coordination directory that does not exist must
    # not block the store that actually holds the transcripts. A missing
    # `state` stays a failure.
    if [ ! -d "$source" ] && { [ "$repo_name" = ".agents" ] || [ "$repo_name" = ".local" ]; }; then
        printf '%s\n' "note: $repo_name is absent; skipping it (backed up once it exists)" >&2
        continue
    fi
    [ -d "$source" ] || {
        printf '%s\n' "$source is not a directory" >&2
        exit 1
    }
    # Exclude transient locks (they die with their process; a restored tree
    # must not carry stale ones) and the improve loop's staging copies under
    # `state/staging/`: each `imp-*` dir is a checkout copy with its build
    # artifacts (zig-out, zig-pkg), regenerable on the next improve run and
    # useless in a snapshot. They dominate the snapshot size (gigabytes vs.
    # tens of megabytes of real store) and inflate restore time, so they are
    # excluded the same way `.clanker-worktrees/` is by design. The pattern is
    # anchored at the transfer root so only the top-level `staging/` matches.
    rsync_args=(-a --exclude='*.lock' --exclude='/staging/')
    if [ -d "$latest/$name" ]; then
        rsync_args+=(--link-dest="$latest/$name")
    fi
    rsync "${rsync_args[@]}" "$source/" "$staging/$name/"
    copied="$copied $name"
done

# rsync's exit code is the only success signal so far; a run that copied
# nothing would still rotate `latest` onto a hollow snapshot and read as
# healthy in every later check. Refuse to promote a staging dir whose
# entries did not materialize.
for name in $copied; do
    [ -d "$staging/$name" ] || {
        printf 'error: snapshot entry %s/ did not materialize; refusing to promote an empty backup\n' "$name" >&2
        exit 1
    }
done

# A snapshot is only a backup if the current system can load it. quick_check
# runs against the *staged copy* -- what a restore would actually read -- so
# corruption introduced by the copy itself (or by an uncheckpointable hot wal
# pair) fails this run instead of surfacing during the incident. A failing
# database refuses promotion: `latest` keeps pointing at the last good
# snapshot, and the journal shows which store to look at.
verify_snapshot_dbs() {
    command -v sqlite3 >/dev/null 2>&1 || return 0
    local db result
    for db in "$staging"/state/sessions/*.db; do
        [ -e "$db" ] || return 0
        if ! result=$(sqlite3 -- "$db" "PRAGMA quick_check;" 2>&1) || [ "$result" != "ok" ]; then
            printf 'error: staged %s failed integrity check (%s); refusing to promote a corrupt snapshot\n' \
                "$(basename -- "$db")" "${result:-sqlite3 failed}" >&2
            return 1
        fi
    done
}
if ! verify_snapshot_dbs; then
    exit 1
fi
mv "$staging" "$snapshot"
ln -sfn "$timestamp" "$latest"

# Prune old snapshots and stale staging dirs. Snapshots are named as ISO-8601
# timestamps, which sort lexicographically in chronological order, so a string
# comparison against the cutoff is correct. Only snapshot-shaped directory
# names under the backup root are ever removed; `latest` and anything else are
# left alone. Runs last on purpose: a failed backup must not be made worse by
# a failed prune. CLANKER_BACKUP_RETENTION_DAYS (default 30) is the age after
# which a snapshot is deleted; 0 keeps every snapshot.
prune_old_snapshots() {
    local keep_days=${CLANKER_BACKUP_RETENTION_DAYS:-30}
    case "$keep_days" in
        ''|0) return 0 ;;
        *[!0-9]*)
            printf 'warning: CLANKER_BACKUP_RETENTION_DAYS=%s is not a day count; keeping all snapshots\n' "$keep_days" >&2
            return 0 ;;
    esac

    # Stale staging dirs predate the EXIT trap; the current run's own staging
    # has already been renamed away at this point, so nothing live matches.
    local stale
    while IFS= read -r stale; do
        rm -rf -- "$stale"
    done < <(find "$backup_root" -maxdepth 1 -type d -name '.*.incomplete' 2>/dev/null)

    local cutoff
    if ! cutoff=$(date -u -d "-$keep_days days" +%Y%m%dT%H%M%SZ 2>/dev/null); then
        printf 'warning: cannot compute the retention cutoff; keeping all snapshots\n' >&2
        return 0
    fi

    local snapshot name
    while IFS= read -r snapshot; do
        name=${snapshot##*/}
        if [[ "$name" < "$cutoff" ]]; then
            rm -rf -- "$snapshot"
            printf 'pruned %s (older than %s days)\n' "$name" "$keep_days" >&2
        fi
    done < <(find "$backup_root" -maxdepth 1 -type d -name '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z' 2>/dev/null | sort)
}

prune_old_snapshots || printf 'warning: snapshot pruning failed; backups are intact\n' >&2

# Second failure domain. Snapshots under `<storage_root>/backups/` share the
# store's disk (the accepted posture above); when that volume dies they die
# too. CLANKER_BACKUP_OFFSITE_DEST names an rsync destination outside that
# domain -- another disk, another machine (`user@host:/vol/clanker-backups`)
# -- and every successful run mirrors the whole backup root there. The mirror
# deliberately never gets --delete: local retention prunes must not propagate,
# or one fat finger (or one ransomware process) deletes both copies through
# the same run. Reclaiming mirror space is a manual, deliberate
# `rsync -a --delete` from an operator who has checked what is being removed.
# A failed mirror fails the run loudly (systemd marks the service failed) even
# though the local snapshot just taken is complete: a silently stale second
# copy is worse than a visible failure.
offsite_dest=${CLANKER_BACKUP_OFFSITE_DEST:-}
if [ -n "$offsite_dest" ]; then
    case "$offsite_dest" in
        "$repo_root"/*|"$backup_root"|"$backup_root"/*)
            printf 'error: CLANKER_BACKUP_OFFSITE_DEST=%s is inside the checkout or the backup root itself; it protects nothing\n' "$offsite_dest" >&2
            exit 1
            ;;
    esac
    if rsync -a "$backup_root/" "$offsite_dest/"; then
        printf 'mirrored backup root to %s\n' "$offsite_dest" >&2
    else
        printf 'error: mirroring to %s failed; the local snapshot is complete but the off-site copy did not update\n' "$offsite_dest" >&2
        exit 1
    fi
fi
