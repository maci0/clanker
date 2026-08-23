#!/usr/bin/env bash
# Apply the local dependency patches (patches/*.patch) to the extracted
# dependency trees, so a fresh checkout runs with the same fixes the
# maintainer's machine has.
#
# patches/README.md documents patches applied BY HAND to packages under the
# dependency cache (zig-pkg/, gitignored). A fresh `zig build` fetches
# pristine upstream tarballs, so none of the patches are active until this
# script re-applies them: without the vaxis SIGWINCH self-pipe patch,
# resizing the terminal in `clanker repl` aborts the process (the bug report
# in docs/reports/), and without the sixel patch the e2e pty journeys fail
# because the repl never sends the sixel geometry query they answer.
#
# Idempotent: a patch that is already applied is detected (reverse dry-run)
# and skipped, so re-running after a `zig build` re-extracted a pristine
# package applies only what is missing.
#
# Usage: scripts/apply-patches.sh
#   Requires: patch. Runs from the repository root.
set -euo pipefail
cd "$(dirname "$0")/.."

# Candidate roots where `zig build` may have extracted dependencies, first
# match wins. zig-pkg/ is this checkout's project-local dependency cache
# (what the maintainer's machine uses); the Zig global cache is where a
# plain `zig build` extracts them on a machine that does not redirect it.
roots=("$PWD/zig-pkg")
if [ -n "${ZIG_GLOBAL_CACHE_DIR:-}" ]; then roots+=("$ZIG_GLOBAL_CACHE_DIR"); fi
if [ -n "${ZIG_LOCAL_CACHE_DIR:-}" ]; then roots+=("$ZIG_LOCAL_CACHE_DIR"); fi
if [ -d "$HOME/.cache/zig" ]; then roots+=("$HOME/.cache/zig"); fi

# patches/<name>.patch -> directory prefix to search for. Order matters:
# vaxis-winch-self-pipe also edits src/main.zig, which the sixel patch
# touches, so the README's listing order is the apply order. The zwasm
# patch is independent of the vaxis set (different package), so its place
# in the list is arbitrary; it was re-derived against zwasm 2.5.0 when the
# build.zig.zon pin moved from 2.4.1.
order=(vaxis-sixel-graphics vaxis-ss3-keypad-enter vaxis-winch-self-pipe zwasm-lazy-mem-cksum)
declare -A targets=(
  [vaxis-sixel-graphics]=vaxis-0.6.0-
  [vaxis-ss3-keypad-enter]=vaxis-0.6.0-
  [vaxis-winch-self-pipe]=vaxis-0.6.0-
  [zwasm-lazy-mem-cksum]=zwasm-2.5.0-
)

status=0
applied=0
up_to_date=0
for name in "${order[@]}"; do
    patch_file="$(pwd)/patches/$name.patch"
    [ -f "$patch_file" ] || continue

    dir=""
    for root in "${roots[@]}"; do
        found="$(find "$root" -maxdepth 2 -type d -name "${targets[$name]}*" 2>/dev/null | head -1 || true)"
        if [ -n "$found" ]; then
            dir="$found"
            break
        fi
    done

    if [ -z "$dir" ]; then
        echo "apply-patches: $name: no ${targets[$name]}* tree under ${roots[*]}; " \
            "skipping (a 'zig build' must extract dependencies first)"
        continue
    fi
    printf '== %s -> %s ==\n' "$name" "${dir#"$PWD"/}"

    if patch -p1 --dry-run -f -d "$dir" < "$patch_file" >/dev/null 2>&1; then
        patch -p1 -f -d "$dir" < "$patch_file"
        echo "applied"
        applied=$((applied + 1))
    elif patch -p1 --dry-run -f -R -d "$dir" < "$patch_file" >/dev/null 2>&1; then
        echo "already applied"
        up_to_date=$((up_to_date + 1))
    else
        echo "apply-patches: $name: patch neither applies nor reverse-applies to $dir" >&2
        status=1
    fi
done

if [ "$status" -ne 0 ]; then
    echo "apply-patches: one or more patches could not be applied" >&2
    exit 1
fi
echo "apply-patches: $applied applied, $up_to_date already up to date"
