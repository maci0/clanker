#!/usr/bin/env bash
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

# The unit files read their tunables (`CLANKER_BACKUP_OFFSITE_DEST`,
# `CLANKER_BACKUP_RETENTION_DAYS`, `CLANKER_BACKUP_MAX_AGE_SECONDS`) from this
# env file. A timer-run service inherits systemd's environment, not the
# operator's shell, so without it those settings are unreachable from the
# timer -- which is the same as having no second failure domain. Creating the
# directory here is what makes the path in the unit resolve.
backup_env_dir="${XDG_CONFIG_HOME:-$HOME/.config}/clanker"
mkdir -p "$backup_env_dir"
if [ ! -e "$backup_env_dir/state-backup.env" ]; then
    cat >"$backup_env_dir/state-backup.env" <<'ENV'
# Read by clanker-state-backup.service and clanker-state-verify.service.
# KEY=VALUE lines; comments and blank lines are ignored.
#
# Second failure domain. Unset, snapshots stay on the storage root's own
# disk and a loss of that volume takes them with the store.
# CLANKER_BACKUP_OFFSITE_DEST=/mnt/offsite/clanker-backups
#
# Age after which a snapshot is deleted (0 keeps every one, and so keeps the
# whole point-in-time restore window). Default 30.
# CLANKER_BACKUP_RETENTION_DAYS=30
#
# How old the newest snapshot may be before the weekly drill fails. Four
# missed 30-minute intervals. Default 7200.
# CLANKER_BACKUP_MAX_AGE_SECONDS=7200
ENV
    printf 'wrote %s/state-backup.env (set CLANKER_BACKUP_OFFSITE_DEST there for a second failure domain)\n' \
        "$backup_env_dir"
fi
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
EOF
    printf 'wrote %s\n' "$backup_env"
fi
systemctl --user daemon-reload
systemctl --user enable --now clanker-state-backup.timer
systemctl --user enable --now clanker-state-verify.timer
