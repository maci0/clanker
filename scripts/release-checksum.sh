#!/usr/bin/env bash
# Write and verify SHA-256 sidecar files for release binaries.
#
# The release matrix builds one binary per target and uploads each as its own
# artifact; release-publish merges them into one directory and attaches
# everything in it to the GitHub Release. Nothing recorded what those bytes
# were, so a consumer had no way to tell an intact download from a truncated
# or substituted one, and a matrix leg whose upload arrived short or empty
# published a release with fewer binaries than the workflow claimed to build.
# This writes one `.sha256` sidecar per binary at build time and makes the
# publish job prove, from those sidecars, that every binary it is about to
# release is present and matches.
#
# Usage:
#   scripts/release-checksum.sh create FILE...   # write FILE.sha256 beside each FILE
#   scripts/release-checksum.sh verify DIR       # check every sidecar in DIR
#   scripts/release-checksum.sh targets          # print the targets verify requires
#
# Exit 0: every sidecar written, or every sidecar in DIR matches, every
# `clanker-*` binary in DIR has one, and every target the release matrix
# builds is present. Exit 1 otherwise, naming what failed.
set -euo pipefail

usage() {
    echo "usage: $0 create FILE... | $0 verify DIR | $0 targets" >&2
    exit 2
}

# The targets a release must carry, read out of the release-build matrix in
# the workflow rather than restated here.
#
# The sidecar check answers "are the bytes I have intact, and does every
# binary here have a sidecar?" It does not answer "did every target the matrix
# builds arrive?", so a dist holding two of the four shipped targets -- a
# matrix leg that uploaded nothing, or an artifact that merged empty -- verified
# clean and published as a healthy release missing an architecture. The matrix is
# the one place that says what a release is made of, so that is where the list is
# read from; a target added there and not published is refused here rather than
# noticed by whoever later tries to install it.
#
# The sed range starts at the release-build job and ends at the next 2-space
# job key, so a `target:` key in any other job cannot widen the list. A matrix
# that cannot be read is a hard failure rather than an empty list, which would
# otherwise make every target optional exactly when the file moved.
#
# The matrix spells an entry `- os: ...` followed by `  target: ...` on the next
# line, not `- target: ...`, so the value is matched as a bare `target:` key.
shipped_targets() {
    # The repo root from this script's own path, not $PWD: `verify DIR` is
    # documented as runnable by hand against a downloaded release, so the
    # caller is very often standing somewhere that is not the checkout. A
    # $PWD-relative lookup then found no workflow, and because the call sat in
    # a command substitution inside a `for` list its failure was swallowed —
    # verify reported success with the check silently not run. Same resolution
    # apply-patches.sh and the other scripts/ entry points use.
    local repo
    repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
    local workflow="$repo/.github/workflows/ci.yml"
    [ -f "$workflow" ] || {
        echo "release-checksum: no $workflow; cannot tell what a release must carry" >&2
        return 1
    }
    local targets
    targets=$(sed -n '/^  release-build:/,/^  [a-z][a-z-]*:$/p' "$workflow" |
        sed -n 's/^ *target: *//p')
    if [ -z "$targets" ]; then
        echo "release-checksum: release-build in $workflow declares no matrix targets" >&2
        return 1
    fi
    printf '%s\n' "$targets"
}

# macOS ships perl's shasum and no coreutils sha256sum; the runner matrix
# builds from both. Both spell the sidecar format identically
# (`<hex>  filename`), so the two tools are interchangeable and only the
# command differs. Pick once, at the top, so create and verify cannot disagree
# about which tool wrote the file. Kept as an array: shasum needs the `-a 256`
# argument, and a command held in a string is word-split back into it.
if command -v sha256sum >/dev/null 2>&1; then
    hash_tool=(sha256sum)
    # `--strict` makes a malformed sidecar a failure instead of a warning, so a
    # truncated or hand-edited line cannot pass as "no properly formatted
    # checksum lines found" with a zero exit.
    hash_check=(--check --strict)
elif command -v shasum >/dev/null 2>&1; then
    hash_tool=(shasum -a 256)
    # perl's shasum takes no --strict; its check mode still fails on a
    # mismatch, which is the half that matters here.
    hash_check=(--check)
else
    echo "release-checksum: no sha256sum or shasum on PATH" >&2
    exit 1
fi

# The sidecar records the basename, not the path it was written from, so
# verification is runnable from the directory holding the files and the same
# line verifies a downloaded release.
write_sidecar() {
    local file=$1
    [ -f "$file" ] || {
        echo "release-checksum: $file is not a file" >&2
        exit 1
    }
    # Checksum the basename: a sidecar carrying the build path is useless to
    # the consumer, who unpacks the release into a directory of their own.
    ( cd -- "$(dirname -- "$file")" && "${hash_tool[@]}" "$(basename -- "$file")" ) >"$file.sha256"
}

verify_dir() {
    local dir=$1 file failures=0 checked=0
    if [ ! -d "$dir" ]; then
        echo "release-checksum: $dir is not a directory" >&2
        exit 1
    fi
    shopt -s nullglob
    local sidecars=("$dir"/*.sha256)
    shopt -u nullglob
    if [ "${#sidecars[@]}" -eq 0 ]; then
        echo "release-checksum: $dir holds no .sha256 sidecar; nothing to verify" >&2
        exit 1
    fi
    for file in "${sidecars[@]}"; do
        if ! ( cd -- "$dir" && "${hash_tool[@]}" "${hash_check[@]}" "$(basename -- "$file")" ); then
            failures=$((failures + 1))
        fi
        checked=$((checked + 1))
    done
    # A sidecar verifies the bytes it names; it does not say whether every
    # binary in the directory has one. A matrix leg that never uploaded (or an
    # artifact that merged empty) would otherwise leave a release that looks
    # verified and is missing a target.
    local binaries=()
    shopt -s nullglob
    binaries=("$dir"/clanker-*)
    shopt -u nullglob
    for file in "${binaries[@]}"; do
        case "$file" in
            *.sha256) continue ;;
        esac
        if [ ! -f "$file.sha256" ]; then
            echo "release-checksum: $(basename -- "$file") has no .sha256 sidecar" >&2
            failures=$((failures + 1))
        fi
    done
    # Both loops above are per-file, so both pass vacuously on a directory
    # holding fewer binaries than a release is made of: two of the four shipped
    # targets verified clean. Name every target the matrix builds and require
    # one to be here, so a leg that uploaded nothing is a refusal rather than a
    # release quietly missing an architecture.
    #
    # Read the list into a variable and check it is non-empty before looping.
    # `for target in $(shipped_targets)` cannot report the function's failure:
    # a command substitution that fails inside a `for` list leaves the list
    # empty and the loop simply does not run, so an unreadable matrix made
    # this check pass vacuously instead of refusing to publish.
    local base target found missing_targets=0
    local required
    if ! required=$(shipped_targets) || [ -z "$required" ]; then
        echo "release-checksum: cannot read the release matrix; refusing to publish" >&2
        exit 1
    fi
    # `clanker-*-$target` rather than an exact name, because the tag in front of
    # the target contains dashes too (v0.11.1-x86_64-linux-musl) and the file
    # name carries whichever tag built it. Matching the tail is also what lets
    # `verify DIR` be run by hand against a downloaded release.
    for target in $required; do
        found=""
        for file in "${binaries[@]}"; do
            case "$file" in *.sha256) continue ;; esac
            base=$(basename -- "$file")
            case "$base" in
                clanker-*-"$target") found=1; break ;;
            esac
        done
        if [ -z "$found" ]; then
            echo "release-checksum: $dir holds no binary for target $target, which the release matrix builds" >&2
            missing_targets=$((missing_targets + 1))
        fi
    done
    failures=$((failures + missing_targets))
    if [ "$failures" -ne 0 ]; then
        echo "release-checksum: $failures problem(s) in $dir; refusing to publish" >&2
        exit 1
    fi
    echo "release-checksum: $checked checksum(s) verified in $dir"
}

[ "$#" -ge 1 ] || usage
mode=$1
shift
case "$mode" in
    create)
        [ "$#" -ge 1 ] || usage
        for file in "$@"; do
            write_sidecar "$file"
        done
        ;;
    verify)
        [ "$#" -eq 1 ] || usage
        verify_dir "$1"
        ;;
    targets)
        [ "$#" -eq 0 ] || usage
        shipped_targets
        ;;
    *)
        usage
        ;;
esac
