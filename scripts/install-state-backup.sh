#!/usr/bin/env bash
set -euo pipefail

script_path=$(readlink -f -- "$0")
script_dir=$(dirname -- "$script_path")
user_bin="${HOME:?}/.local/bin"

mkdir -p "$user_bin"
ln -sfn "$script_dir/backup-state.sh" "$user_bin/clanker-state-backup"
systemctl --user link "$script_dir/systemd/clanker-state-backup.service"
systemctl --user link "$script_dir/systemd/clanker-state-backup.timer"
systemctl --user daemon-reload
systemctl --user enable --now clanker-state-backup.timer
