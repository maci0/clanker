#!/usr/bin/env bash
set -euo pipefail

script_path=$(readlink -f -- "$0")
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
link_unit() {
    local unit="$1"
    local target
    target=$(readlink -f -- "$script_dir/systemd/$unit")
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
systemctl --user daemon-reload
systemctl --user enable --now clanker-state-backup.timer
systemctl --user enable --now clanker-state-verify.timer
