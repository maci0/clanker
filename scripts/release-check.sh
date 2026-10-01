#!/usr/bin/env bash
# Validate the consumer-visible identity of a release. This is intentionally a
# small, dependency-free gate so the tag, changelog, manifest, and executable
# cannot describe four different releases.
#
# Usage:
#   scripts/release-check.sh vMAJOR.MINOR.PATCH PATH-TO-CLANKER   tag + binary
#   scripts/release-check.sh manifests vMAJOR.MINOR.PATCH         tag + tree
#
# The `manifests` form runs the half that needs no executable — tag shape,
# build.zig.zon, the secondary package manifests, and the dated CHANGELOG.md
# section — so a job that has no runnable binary for the target it published
# (a cross-compiled one) can still refuse to publish a release that describes
# a different version than the tag. `gh release create` is the last step of the
# pipeline, so a mismatch found there is the cheapest one to find; a re-run of
# the publish job after that failure is cheap too, since nothing has been
# created yet.
set -euo pipefail
set -f

usage() {
    echo "usage: $0 vMAJOR.MINOR.PATCH PATH-TO-CLANKER" >&2
    echo "       $0 manifests vMAJOR.MINOR.PATCH" >&2
    exit 2
}

# `manifests` is a mode, not a tag: a tag always starts with `v`, so the
# subcommand cannot be mistaken for one.
check_manifests=true
if [ "${1:-}" = manifests ]; then
    check_manifests=false
    shift
fi

[ "$#" -ge 1 ] || usage
release_tag=$1
release_binary=${2-}

if $check_manifests; then
    [ "$#" -eq 2 ] || usage
fi

release_version=${release_tag#v}
printf '%s\n' "$release_tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || {
    echo "release check: tag must be vMAJOR.MINOR.PATCH, got '$release_tag'" >&2
    exit 1
}

manifest_version=$(sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' build.zig.zon)
[ -n "$manifest_version" ] || {
    echo "release check: build.zig.zon has no .version" >&2
    exit 1
}
[ "$manifest_version" = "$release_version" ] || {
    echo "release check: tag $release_tag disagrees with build.zig.zon version $manifest_version" >&2
    exit 1
}

# Secondary version declarations. build.zig.zon is the single source of truth
# (RELEASES.md); these package manifests must repeat it, never diverge from it.
for pkg in package.json tools/ts/package.json; do
    [ -f "$pkg" ] || continue
    pkg_version=$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$pkg" | head -n1)
    [ -n "$pkg_version" ] || {
        echo "release check: $pkg has no \"version\" field" >&2
        exit 1
    }
    [ "$pkg_version" = "$release_version" ] || {
        echo "release check: $pkg version $pkg_version disagrees with build.zig.zon version $release_version" >&2
        exit 1
    }
done

heading_count=$(grep -Ec "^## \[$release_version\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" CHANGELOG.md || true)
[ "$heading_count" -eq 1 ] || {
    echo "release check: CHANGELOG.md needs exactly one '## [$release_version] - YYYY-MM-DD' heading" >&2
    exit 1
}

if $check_manifests; then
    [ -x "$release_binary" ] || {
        echo "release check: release binary '$release_binary' is missing or not executable" >&2
        exit 1
    }
    binary_version=$("$release_binary" --version)
    [ "$binary_version" = "clanker $release_version" ] || {
        echo "release check: binary reports '$binary_version', expected 'clanker $release_version'" >&2
        exit 1
    }
fi

echo "release contract verified for $release_tag"
