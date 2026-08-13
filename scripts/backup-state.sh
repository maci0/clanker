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

mkdir -p "$backup_root"
mkdir "$staging"

for entry in state:state agents:.agents local:.local; do
    name=${entry%%:*}
    repo_name=${entry#*:}
    source=$(readlink -f -- "$repo_root/$repo_name")
    expected="$storage_root/$name"
    if [ "$source" != "$expected" ]; then
        printf '%s\n' "$repo_name must resolve to $expected" >&2
        exit 1
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
done
mv "$staging" "$snapshot"
ln -sfn "$timestamp" "$latest"
