#!/usr/bin/env bash
set -euo pipefail

# Portable stand-in for `readlink -f`: macOS ships a BSD readlink with no
# `-f`, and every `readlink -f` here died under `set -euo pipefail` on a
# Mac. The target need not exist (state/ is created on first run), so an
# unresolvable path falls back to the spelling it was given.
resolve_path() {
    local p="$1" depth=0 link dir base phys
    # Follow a symlinked final component, which is the whole point. `state`,
    # `.local` and `.agents` are symlinks into the storage root: resolving only
    # the directory part left the link in place, the parent of an unresolved
    # `state` is the checkout, and every run was then refused as a backup root
    # inside the checkout -- the one arrangement the script exists to support
    # was the one it could not see. The same held for the installed
    # `~/.local/bin/clanker-state-backup` launcher, a link to this script, so
    # the checkout it derives came out as the bin directory. Relative targets
    # compose against the link's directory, as the kernel resolves them.
    while [ -L "$p" ] && [ "$depth" -lt 32 ]; do
        link=$(readlink -- "$p")
        if [ "${link#/}" = "$link" ]; then
            p="$(dirname -- "$p")/$link"
        else
            p="$link"
        fi
        depth=$((depth + 1))
    done
    # Then the directory part goes physical (macOS spells /tmp as a link, a
    # mounted volume has a device-real path), and a directory target is
    # entered so the answer is that directory's own physical path. A path that
    # does not exist yet keeps the spelling it was given, since a store is
    # created on first run and there is nothing to resolve.
    dir=$(dirname -- "$p")
    base=$(basename -- "$p")
    if [ ! -d "$dir" ]; then
        printf '%s\n' "$p"
        return 0
    fi
    phys=$(cd -- "$dir" && pwd -P)
    if [ -d "$phys/$base" ]; then
        (cd -- "$phys/$base" && pwd -P) 2>/dev/null ||
            printf '%s/%s\n' "$phys" "$base"
        return 0
    fi
    printf '%s/%s\n' "$phys" "$base"
}

script_path=$(resolve_path "$0")
script_dir=$(dirname -- "$script_path")
repo_root=$(dirname -- "$script_dir")
state_root=$(resolve_path "$repo_root/state")
storage_root=$(dirname -- "$state_root")
backup_root="$storage_root/backups"
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
# The staging name carries a per-run random tail. It used to be exactly
# `.${timestamp}.incomplete`, and a second run starting in the same second
# (a manual run while the 30-minute timer fires, a retry of a wrapper script,
# two checkouts sharing one storage root) named the same directory: its `mkdir`
# failed under `set -e` as intended, but the EXIT trap fired first and
# `rm -rf`'d the tree the first run was still rsyncing into. That run then
# promoted a half-copied snapshot, which every later restore reports as
# healthy. `mktemp -d` fails rather than colliding, so a second run can no
# longer touch a live staging directory at all.
snapshot="$backup_root/$timestamp"
latest="$backup_root/latest"
copied=""

# How old a leftover staging directory must be before a run is allowed to
# delete it. See `prune_old_snapshots`.
staging_stale_minutes=60

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
# Owner-only: a snapshot can carry `.env` and `config.local.*` (see
# copy_local_config below), so the root that holds every snapshot is not
# world-readable even when the operator's umask said otherwise.
chmod 700 "$backup_root"
# If the script dies mid-backup, the incomplete staging directory is garbage
# (the `latest` symlink still points at the last good snapshot). Remove it so
# failed runs do not accumulate; after a successful `mv` the path no longer
# exists and this is a no-op. The name is per-run, so this trap can only ever
# remove the directory this run created.
staging=$(mktemp -d "$backup_root/.${timestamp}.incomplete.XXXXXXXXXX")
# EXIT alone never fires on the signal this run is most likely to be killed
# with: `clanker-state-backup.service` sets TimeoutStartSec=1h precisely for a
# wedged off-site destination, and systemd answers a run that exceeds it with
# SIGTERM. The staging tree is a full copy of the store, and until the next
# run's stale sweep reached it (an hour later) it sat beside every good
# snapshot, doubling the volume the backup lives on. `exit` from the handler
# rather than a re-raise, because re-raising the signal the shell is already
# handling does not terminate it. The status is the signal's own, 128+signal
# for the two systemd sends (SIGTERM 143, SIGINT 130); SIGHUP would read as the
# 126 that is `command not found`, so it carries 129 instead.
cleanup_staging() { rm -rf -- "$staging"; }
trap cleanup_staging EXIT
trap 'cleanup_staging; exit 143' TERM
trap 'cleanup_staging; exit 130' INT
trap 'cleanup_staging; exit 129' HUP

# Every SQLite database in the store is WAL-mode (`src/util/sqlite.zig` sets
# journal_mode=WAL on open) and stays open for the life of a serve/repl: one
# per conversation under `state/sessions/<id>.db`, the replicated
# conversations of every peer under `state/mesh/<owner>/sessions/<id>.db`
# (`src/peers/session_sync.zig`), and the derived cross-session search index
# at `state/session_fts.db`. A plain rsync of a hot WAL pair can capture a
# main db plus sidecar that never existed together on disk: committed turns
# live in `<id>.db-wal`, and a torn or mismatched pair does not load on
# restore. Checkpointing each database immediately before the copy moves
# every committed transaction into the main db file, so the snapshot is a
# consistent single file even though writers continue afterwards (their later
# commits land in a fresh wal the next run checkpoints). This is
# maintenance, not a durability change: nothing about how clanker writes is
# altered. Without the sqlite3 CLI the copy falls back to today's
# crash-consistent behavior and says so instead of pretending.
state_databases() {
    find "$state_root" -type f -name '*.db' 2>/dev/null | sort
}
checkpoint_state_wal() {
    command -v sqlite3 >/dev/null 2>&1 || {
        printf 'note: sqlite3 not found; state snapshots stay crash-consistent (wal not checkpointed)\n' >&2
        return 0
    }
    # Read through a while-read loop, not `for db in $(...)`: a storage root
    # with a space in it (a mounted volume, a macOS volume name) is one
    # word-split path per database otherwise.
    local db
    while IFS= read -r db; do
        [ -n "$db" ] || continue
        sqlite3 -- "$db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 ||
            printf 'warning: wal checkpoint on %s did not complete; its snapshot stays crash-consistent\n' \
                "${db#"$state_root"/}" >&2
    done < <(state_databases)
}
checkpoint_state_wal

for entry in state:state agents:.agents local:.local; do
    name=${entry%%:*}
    repo_name=${entry#*:}
    source=$(resolve_path "$repo_root/$repo_name")
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

# Local configuration and credentials are the one piece of machine state that
# lives in the checkout rather than in `state/`: `config.local.toml`,
# `config.local.json` and `.env` are gitignored, so they exist nowhere else.
# A checkout loss or a lost storage root takes them with it, and no amount of
# restored transcripts tells a restored clanker which provider to call, so the
# restored store would come back unable to run at all. They are three small
# files, copied verbatim, and `verify-backup.sh` drills them like every other
# entry.
#
# They carry API keys, so the snapshot root is owner-only (see the chmod on
# `$backup_root` above) and each file keeps its own mode. `config.toml` is
# deliberately absent: it is committed, and git is its backup.
copy_local_config() {
    local file copied_any=0
    mkdir -p -- "$staging/config"
    # The three files the loop names, plus every `profiles/<name>.local.toml`:
    # the checkout-private half of a named profile (machine-local endpoints,
    # same relationship `config.local.toml` has to `config.toml`), gitignored
    # and therefore as absent from a re-clone as the three beside it.
    for file in config.local.toml config.local.json .env; do
        [ -f "$repo_root/$file" ] || continue
        cp -p -- "$repo_root/$file" "$staging/config/$file"
        copied_any=1
    done
    local profile
    for profile in "$repo_root"/profiles/*.local.toml; do
        [ -f "$profile" ] || continue
        mkdir -p -- "$staging/config/profiles"
        cp -p -- "$profile" "$staging/config/profiles/${profile##*/}"
        copied_any=1
    done
    if [ "$copied_any" = 1 ]; then
        chmod 700 "$staging/config"
        copied="$copied config"
    else
        rmdir -- "$staging/config" 2>/dev/null || true
    fi
}
copy_local_config

# Device-global operator instructions. `~/.agents/AGENTS.md` is the first
# instruction layer of every system prompt (`resolveGlobalInstructionsPath` in
# `src/agent/system_prompt.zig`), and it is not the checkout's `.agents`: that
# one is a per-project directory under the storage root, this one is per-device
# and lives in `$HOME`. It is in no repository, so a re-clone cannot bring it
# back and a lost storage root takes it with the store. Copied as its own
# entry, because a restore has to put it back at `$HOME/.agents` rather than
# anywhere in the storage root. A missing `$HOME` (a service started without
# one) or an absent directory is a soft skip, like `.agents`/`.local` above.
copy_home_agents() {
    [ -n "${HOME:-}" ] || return 0
    [ -d "$HOME/.agents" ] || return 0
    mkdir -p -- "$staging/home-agents"
    rsync -a --exclude='*.lock' "$HOME/.agents/" "$staging/home-agents/"
    copied="$copied home-agents"
}
copy_home_agents

# Operator data that lives in the checkout and is written at runtime, by the
# agent's own tools and by config loaders: the web UI addons `webui_addon`
# creates under `ui/plugins/`, CLI/TUI plugin manifests, presets, slash
# commands, chains, themes, skills, tool manifests, the per-project `.claude`
# and `.grok` rule directories, and the ROADMAP `autolearn` rewrites. None of
# them is under `state/`, and git only holds the half a human committed, so a
# lost checkout (the disaster the restore runbook opens with) brings the store
# back and leaves every addon, preset and rule file the operator built behind
# it. A lost volume does not reach them either, since they are in the checkout
# rather than the storage root.
#
# Copied as one `checkout-data` entry that preserves the checkout-relative
# layout, so a restore is one rsync back into the checkout and a drill can
# compare it like any other. The committed half rides along, which is the
# point: the snapshot is what has the uncommitted files git has not. The entry
# is restored without `--delete` (see docs/runbooks/state-restore.md), since a
# snapshot of tracked source is older than the checkout by construction and
# deleting what it no longer carries would revert committed work.
checkout_data_dirs=(
    ui/plugins
    cli-plugins
    tui-plugins
    tools/manifests
    presets
    commands
    chains
    themes
    skills
    .claude
    .grok
)
checkout_data_files=(docs/ROADMAP.md)
copy_checkout_data() {
    local rel copied_any=0
    mkdir -p -- "$staging/checkout-data"
    for rel in "${checkout_data_dirs[@]}"; do
        [ -d "$repo_root/$rel" ] || continue
        mkdir -p -- "$staging/checkout-data/$(dirname -- "$rel")"
        # `--link-dest` needs an absolute path, and `$latest` is one; without
        # it every 30-minute run would store a fresh copy of an unchanged tree
        # instead of hard-linking it to the last snapshot.
        rsync -a --exclude='*.lock' --exclude='.git' \
            --link-dest="$latest/checkout-data/$rel" \
            "$repo_root/$rel/" "$staging/checkout-data/$rel/"
        copied_any=1
    done
    for rel in "${checkout_data_files[@]}"; do
        [ -f "$repo_root/$rel" ] || continue
        mkdir -p -- "$staging/checkout-data/$(dirname -- "$rel")"
        cp -p -- "$repo_root/$rel" "$staging/checkout-data/$rel"
        copied_any=1
    done
    if [ "$copied_any" = 1 ]; then
        copied="$copied checkout-data"
    else
        rmdir -- "$staging/checkout-data" 2>/dev/null || true
    fi
}
copy_checkout_data

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
# pair) fails this run instead of surfacing during the incident. Every
# database in the snapshot is checked, the replicated peer conversations
# (`state/mesh/<owner>/sessions/`) included: they are conversations this
# instance holds and no longer has a live peer to re-sync from.
#
# A failing conversation database refuses promotion: `latest` keeps pointing
# at the last good snapshot, and the journal shows which store to look at. The
# search index is the one exception, and deliberately so: it is derived from
# the session databases, rebuilt as sessions are saved, and read fail-open
# (a missing or corrupt index costs a linear scan, `src/agent/session_fts.zig`).
# Blocking every backup on it would turn a rebuildable index into an outage
# of the backup itself, so it is reported and the run continues. Deleting the
# file restores full search.
verify_snapshot_dbs() {
    command -v sqlite3 >/dev/null 2>&1 || return 0
    local db rel result
    while IFS= read -r db; do
        [ -n "$db" ] || continue
        rel=${db#"$staging/"}
        if result=$(sqlite3 -- "$db" "PRAGMA quick_check;" 2>&1) && [ "$result" = "ok" ]; then
            continue
        fi
        case "$rel" in
            state/session_fts.db)
                printf 'warning: staged %s failed integrity check (%s); the search index is derived and rebuilds itself, snapshot kept\n' \
                    "$rel" "${result:-sqlite3 failed}" >&2
                ;;
            *)
                printf 'error: staged %s failed integrity check (%s); refusing to promote a corrupt snapshot\n' \
                    "$rel" "${result:-sqlite3 failed}" >&2
                return 1
                ;;
        esac
    done < <(find "$staging/state" -type f -name '*.db' 2>/dev/null | sort)
}
if ! verify_snapshot_dbs; then
    exit 1
fi
# A snapshot promoted earlier in this same second already owns the plain
# timestamp name, and `mv` into an existing directory moves the staging tree
# *inside* it rather than replacing it. The second run then reports success
# while its own copy is unreachable and the first run's snapshot carries a
# stray `.incomplete.XXXX` directory. Disambiguate with the same random tail
# the staging name used; `latest` follows the name, not the timestamp.
if [ -e "$snapshot" ]; then
    snapshot="$backup_root/${timestamp}.${staging##*.}"
fi
mv "$staging" "$snapshot"
ln -sfn "${snapshot##*/}" "$latest"

# Prune old snapshots and stale staging dirs. Snapshots are named as ISO-8601
# timestamps, which sort lexicographically in chronological order, so a string
# comparison against the cutoff is correct. Only snapshot-shaped directory
# names under the backup root are ever removed; `latest` and anything else are
# left alone. Runs last on purpose: a failed backup must not be made worse by
# a failed prune. CLANKER_BACKUP_RETENTION_DAYS (default 30) is the age after
# which a snapshot is deleted; 0 keeps every snapshot.
prune_old_snapshots() {
    # Depth-1 directories under the backup root matching a glob pattern. This
    # is the portable spelling of `find -maxdepth 1`: `-maxdepth` is a GNU
    # extension, and macOS's BSD find rejects it and prints nothing, so both
    # sweeps below silently found no candidates on a platform this script runs
    # on, leaving stale staging dirs and expired snapshots forever.
    depth1_dirs() {
        local pattern=$1 entry
        for entry in "$backup_root"/$pattern; do
            [ -d "$entry" ] || continue
            printf '%s\n' "$entry"
        done
    }

    # Seconds since the epoch for a path's mtime, or nothing when neither stat
    # spelling answers. `stat -c` is GNU, `stat -f` is BSD; one of the two is
    # present on every platform this runs on, and an unknown age leaves the
    # candidate alone rather than deleting a tree it cannot date.
    mtime_epoch() {
        stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1" 2>/dev/null || true
    }

    # Stale staging dirs first: they are the remains of runs that died before
    # the EXIT trap existed, so nothing else reclaims them, and each carries a
    # full copy of the store. This used to sit below the retention guards, so
    # `CLANKER_BACKUP_RETENTION_DAYS=0` (and an unparseable value) skipped it
    # and the garbage grew without bound, which is the opposite of what "0
    # keeps every snapshot" means: it keeps every *snapshot*, not every failed
    # attempt. The current run's own staging was already renamed away, so what
    # is left is another run's, and it may still be in flight: the removal used
    # to be unconditional, which deleted a concurrent run's half-copied tree
    # out from under it and let that run promote the wreckage. A staging
    # directory older than `staging_stale_minutes` cannot belong to a live run
    # (a backup of this store takes minutes, not an hour), so the age bound
    # separates garbage from work in progress instead of guessing from the
    # name.
    local stale stale_cutoff stale_mtime
    stale_cutoff=$(( $(date +%s) - staging_stale_minutes * 60 ))
    while IFS= read -r stale; do
        stale_mtime=$(mtime_epoch "$stale")
        case "$stale_mtime" in
            ''|*[!0-9]*) continue ;;
        esac
        [ "$stale_mtime" -lt "$stale_cutoff" ] || continue
        rm -rf -- "$stale"
    done < <(depth1_dirs '.*.incomplete.*')

    local keep_days=${CLANKER_BACKUP_RETENTION_DAYS:-30}
    case "$keep_days" in
        ''|0) return 0 ;;
        *[!0-9]*)
            printf 'warning: CLANKER_BACKUP_RETENTION_DAYS=%s is not a day count; keeping all snapshots\n' "$keep_days" >&2
            return 0 ;;
    esac

    local cutoff epoch
    # `date -d` is GNU-only (BSD/macOS date has no `-d STRING`), so compute
    # the cutoff from epoch arithmetic instead: `date +%s` and one of the
    # two epoch-to-UTC forms exist everywhere this runs. If neither answers,
    # keep every snapshot, exactly as before.
    epoch=$(( $(date +%s) - keep_days * 86400 ))
    cutoff=$(date -u -d "@$epoch" +%Y%m%dT%H%M%SZ 2>/dev/null) ||
        cutoff=$(date -u -r "$epoch" +%Y%m%dT%H%M%SZ 2>/dev/null)
    if [ -z "$cutoff" ]; then
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
    done < <(depth1_dirs '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z' | sort)
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
