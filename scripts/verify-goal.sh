#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
# A private global cache so the focused runs cannot disturb (or be disturbed by)
# a cache a build is currently writing. It holds the whole dependency tree and
# every build artifact, so it goes on disk: TMPDIR is a tmpfs on most Linux
# machines and on a laptop an in-RAM Zig cache is swapped out or OOMs.
export ZIG_GLOBAL_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/clanker-verify-zig-cache"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR"

# The focused names are also the machine-readable contract for this goal:
# every vendor must retain its API-key provider path and expose its OAuth
# subscription path through the native backend driver.
for vendor in codex grok claude; do
    rg -q "test \"${vendor} supports oauth backend and api key provider\"" src
    zig build test -Dtest-filter="${vendor} supports oauth backend and api key provider"
done

zig build test
