#!/usr/bin/env bash
set -euo pipefail

# usage: ./ping-claude.sh HH:MM      (24-hour local time)
target="$1"

now=$(date +%s)
target_ts=$(date -d "$target" +%s)
if (( target_ts <= now )); then
    target_ts=$(( target_ts + 86400 ))
fi

sleep_sec=$(( target_ts - now ))
echo "scheduled for $(date -d "@$target_ts" '+%F %H:%M %Z') (in ${sleep_sec}s)"
sleep "$sleep_sec"

claude -p "Reply to 'ping' with the single word pong and nothing else. ping" \
    | tee "$HOME/ping-claude.out"
