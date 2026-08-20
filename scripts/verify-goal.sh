#!/usr/bin/env bash
# Verify the goal "Fix the clanker build": `zig build && zig build tools`
# must both complete with exit code 0 and no compilation errors.
#
# Exits 0 only when the criterion is met; any failing build step exits
# non-zero via `set -e`.
#
# Usage: scripts/verify-goal.sh
set -euo pipefail
cd "$(dirname "$0")/.."

zig build
zig build tools

echo "verify-goal: OK — zig build && zig build tools passed"
