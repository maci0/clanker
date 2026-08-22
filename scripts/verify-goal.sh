#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
export ZIG_GLOBAL_CACHE_DIR="${TMPDIR:-/tmp}/clanker-verify-zig-cache"

# The focused names are also the machine-readable contract for this goal:
# every vendor must retain its API-key provider path and expose its OAuth
# subscription path through the native backend driver.
for vendor in codex grok claude; do
    rg -q "test \"${vendor} supports oauth backend and api key provider\"" src
    zig build test -Dtest-filter="${vendor} supports oauth backend and api key provider"
done

zig build test
