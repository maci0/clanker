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
    rsync_args=(-a --exclude='*.lock')
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
