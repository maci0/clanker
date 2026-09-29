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

# Apply order. Order matters:
# vaxis-winch-self-pipe also edits src/main.zig, which the sixel patch
# touches, so the README's listing order is the apply order. The zwasm
# patch is independent of the vaxis set (different package), so its place
# in the list is arbitrary.
# Kept as a list rather than a directory glob because a glob would sort
# lexically and apply the winch patch before the sixel one. The list is
# checked against patches/*.patch below, so a patch that lands without a
# line here fails loudly instead of being silently skipped.
order=(vaxis-sixel-graphics vaxis-ss3-keypad-enter vaxis-winch-self-pipe zwasm-lazy-mem-cksum)

# patches/<name>.patch -> the dependency it belongs to: everything before the
# first `-` in its name, the same rule the dep-patches gate applies
# (src/gate/checks.zig `depPackageOf`).
package_of() { printf '%s' "${1%%-*}"; }

# The directory a package is extracted into is named its build.zig.zon `.hash`
# value verbatim, so the pin is read from there rather than repeated here as a
# version literal. A bumped pin used to leave this script searching for a
# `vaxis-0.6.0-*` tree that no longer existed, and the run failed with "no
# tree under ..." naming a version the manifest no longer carried.
dep_hash() {
    sed -n 's/^[[:space:]]*\.hash[[:space:]]*=[[:space:]]*"\('"$1"'-[^"]*\)".*/\1/p' \
        build.zig.zon | head -1
}

# Every patch on disk is in the list, or say so and fail: the gate checks all of
# patches/*.patch, so a patch this script skips by omission is a build that
# passes here and fails the gate with nothing pointing at this file.
missing_from_order=0
for patch_file in patches/*.patch; do
    [ -e "$patch_file" ] || continue
    stem="${patch_file#patches/}"
    stem="${stem%.patch}"
    listed=0
    for known in "${order[@]}"; do
        if [ "$known" = "$stem" ]; then listed=1; break; fi
    done
    if [ "$listed" -eq 0 ]; then
        echo "apply-patches: $patch_file is not in the apply order in $0" >&2
        missing_from_order=$((missing_from_order + 1))
    fi
done

status=$missing_from_order
applied=0
up_to_date=0
skipped=0
for name in "${order[@]}"; do
    patch_file="$(pwd)/patches/$name.patch"
    [ -f "$patch_file" ] || continue

    hash=$(dep_hash "$(package_of "$name")")
    if [ -z "$hash" ]; then
        echo "apply-patches: $name: build.zig.zon pins no dependency named $(package_of "$name")" >&2
        status=1
        continue
    fi

    dir=""
    for root in "${roots[@]}"; do
        # A depth-2 glob, not `find -maxdepth 2`: `-maxdepth` is a GNU
        # extension, and macOS's BSD find answers "unknown primary or
        # operator" and prints nothing, so the search below found no tree on a
        # platform this script runs on (CI applies these patches on macOS too)
        # and every patch was reported as skipped. The project-local cache
        # spells a package directory `<name>-<hash>`; the Zig global cache
        # spells it `<name>/<hash>`. Both are the two globs here.
        for candidate in "$root"/"$hash" "$root"/*/"$hash"; do
            if [ -d "$candidate" ]; then
                dir="$candidate"
                break
            fi
        done
        [ -n "$dir" ] && break
    done

    # A missing tree is fatal, not a skip: the documented order is
    # 'zig build' first, so getting here early is an error worth failing
    # loudly, and a tree that never appears means the patch went stale
    # against build.zig.zon. Exiting 0 here made a run that applied nothing
    # indistinguishable from one where everything was already up to date,
    # so `apply-patches.sh && zig build test` proceeded unpatched (the bug
    # report in docs/reports/).
    if [ -z "$dir" ]; then
        echo "apply-patches: $name: no $hash tree under ${roots[*]}" >&2
        skipped=$((skipped + 1))
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

if [ "$skipped" -ne 0 ]; then
    echo "apply-patches: $skipped patch(es) found no dependency tree to apply to;" \
        "run 'zig build' first to extract dependencies" >&2
    status=1
fi
if [ "$status" -ne 0 ]; then
    echo "apply-patches: one or more patches could not be applied" >&2
    exit 1
fi
echo "apply-patches: $applied applied, $up_to_date already up to date"
