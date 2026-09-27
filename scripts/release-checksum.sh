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
#
# Exit 0: every sidecar written, or every sidecar in DIR matches and every
# `clanker-*` binary in DIR has one. Exit 1 otherwise, naming what failed.
set -euo pipefail

usage() {
    echo "usage: $0 create FILE... | $0 verify DIR" >&2
    exit 2
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
    *)
        usage
        ;;
esac
