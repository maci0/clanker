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
user_bin="${HOME:?}/.local/bin"

mkdir -p "$user_bin"
ln -sfn "$script_dir/backup-state.sh" "$user_bin/clanker-state-backup"
# The weekly restore drill is part of the same install: a backup that has
# never been restored is a hypothesis, and nothing else runs
# verify-backup.sh on its own (ADR 0008: nothing fires alone).
ln -sfn "$script_dir/verify-backup.sh" "$user_bin/clanker-state-verify"

# `systemctl link` fails with "File exists" when the unit is already linked,
# so a plain second run of this script exits 1 instead of converging. Link
# only when the unit is missing from the user unit dir or points at a
# different checkout, and replace a stale link (the checkout moved) first.
user_units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$user_units"

backup_env_dir="${XDG_CONFIG_HOME:-$HOME/.config}/clanker"
mkdir -p "$backup_env_dir"
link_unit() {
    local unit="$1"
    local target
    target=$(resolve_path "$script_dir/systemd/$unit")
    local link_path="$user_units/$unit"
    if [ "$(readlink -- "$link_path" 2>/dev/null || true)" = "$target" ]; then
        return 0
    fi
    rm -f -- "$link_path"
    systemctl --user link "$script_dir/systemd/$unit"
}
link_unit clanker-state-backup.service
link_unit clanker-state-backup.timer
link_unit clanker-state-verify.service
link_unit clanker-state-verify.timer

# Both units read their configuration from here (EnvironmentFile=). A user
# service does not inherit the login shell's environment, so an export in a
# profile never reaches the timer; writing the file is the only way to set
# CLANKER_BACKUP_OFFSITE_DEST or CLANKER_BACKUP_RETENTION_DAYS for a scheduled
# run. Written once, never overwritten: this is the operator's file, and a
# reinstall must not drop a destination they set.
backup_env_dir="${XDG_CONFIG_HOME:-$HOME/.config}/clanker"
backup_env="$backup_env_dir/backup.env"
mkdir -p "$backup_env_dir"
if [ ! -e "$backup_env" ]; then
    cat >"$backup_env" <<'EOF'
# Configuration for clanker-state-backup.service / clanker-state-verify.service.
# Read by systemd (EnvironmentFile=); a shell export does NOT reach the timer.
# KEY=value, one per line, no `export`. See scripts/README.md.

# Second failure domain: an rsync destination outside the storage root, e.g.
# /mnt/second-disk/clanker-backups or user@host:/vol/clanker-backups. Unset
# means every copy shares the store's disk.
#CLANKER_BACKUP_OFFSITE_DEST=

# Delete snapshots older than this many days. 0 keeps every snapshot.
#CLANKER_BACKUP_RETENTION_DAYS=30

# How old the newest snapshot may be before the weekly restore drill fails.
# Four missed 30-minute intervals. Default 7200.
#CLANKER_BACKUP_MAX_AGE_SECONDS=7200
EOF
    printf 'wrote %s\n' "$backup_env"
fi

# An earlier installer also wrote a `state-backup.env` and pointed the docs
# there, while the units only ever read `backup.env`: a destination set in that
# file was never read by the timer, so the second failure domain silently did
# not exist. Say so rather than deleting it -- it may hold the only copy of a
# destination the operator thought they had configured.
if [ -e "$backup_env_dir/state-backup.env" ]; then
    printf 'warning: %s/state-backup.env is not read by any unit; move any setting from it into %s\n' \
        "$backup_env_dir" "$backup_env" >&2
fi
systemctl --user daemon-reload
systemctl --user enable --now clanker-state-backup.timer
systemctl --user enable --now clanker-state-verify.timer
