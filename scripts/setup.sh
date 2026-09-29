#!/usr/bin/env bash
# Bootstrap a fresh clone to a runnable build, in one command.
#
# The order below is load-bearing and was tribal knowledge until now:
# `zig build --fetch=all` extracts the pinned vaxis/zwasm trees WITHOUT
# configuring or compiling, `scripts/apply-patches.sh` re-applies
# patches/*.patch to them, and only then does any compile succeed. Run the
# two the other way round and apply-patches.sh refuses with "no <hash> tree
# under ..."; skip them and `zig build` refuses at configure time naming the
# missing patch. Both failure messages are loud, but a first-time
# contributor has to have read two sections of prose to know which of six
# commands to type.
#
# Usage: scripts/setup.sh
#   Requires: zig, git, patch. Bun and python3 are checked too and reported
#   as missing rather than fatal: `zig build` and `zig build tools` need
#   neither, but `zig build test` drives the JS suites with bun.
#   Runs from the repository root; pass the path if invoked elsewhere.
set -euo pipefail
cd "$(dirname "$0")/.."

missing=0
need() {
    if command -v "$1" >/dev/null 2>&1; then
        printf '  ok   %s (%s)\n' "$1" "$(command -v "$1")"
    else
        printf '  MISS %s\n' "$1" >&2
        missing=1
    fi
}

echo "== toolchain =="
need zig
need git
need patch
# python3 and bun do not gate the build, so they are reported without being
# counted against `missing`; the test step is what needs them.
for tool in python3 bun; do
    if command -v "$tool" >/dev/null 2>&1; then
        printf '  ok   %s (%s)\n' "$tool" "$(command -v "$tool")"
    else
        printf '  --   %s not found: needed by the test step, not by the build\n' "$tool" >&2
    fi
done
if [ "$missing" -ne 0 ]; then
    echo >&2
    echo "setup: install the missing tools above, then run this again" >&2
    echo "setup: requirements are listed in CONTRIBUTING.md" >&2
    exit 1
fi

# Same pin the CI workflow and the pre-commit hook read (CONTRIBUTING.md
# spells it 0.16.x; the hook refuses a `zig fmt` from any other major/minor
# because it would rewrite files to that version's canonical form). Report a
# mismatch rather than exiting: build.zig has its own configure-time check
# and prints the authoritative message, and 0.16.1 against a 0.16.0 pin is a
# warning worth reading, not a reason to refuse to bootstrap.
required_zig=$(sed -n 's/^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' build.zig.zon | head -n1)
have_zig=$(zig version)
case "$have_zig" in
    "$required_zig"*) ;;
    *)
        echo "setup: warning: zig on PATH is $have_zig, build.zig.zon pins $required_zig" >&2
        echo "setup: CI installs exactly $required_zig, so a different patch release" >&2
        echo "setup: can compile the same tree differently" >&2
        ;;
esac

echo
echo "== fetch dependencies =="
# --fetch=all extracts without compiling. build.zig's configure-time patch
# gate and apply-patches.sh both need the trees on disk first, so this has
# to precede the patch step and any compile.
zig build --fetch=all

echo
echo "== apply patches/*.patch =="
./scripts/apply-patches.sh

echo
echo "== build =="
zig build
zig build tools

# The build and the test suite need none of these, but the JavaScript half of
# the contributor loop does: `bun run lint`, `bun run css:build` and the
# pre-commit hook's JS check all resolve packages out of node_modules, and a
# fresh clone has none, so each of them fails with a bare "Cannot find package"
# several steps into a loop nobody had been told was incomplete. A failure
# here is reported rather than fatal: the build above is already usable, and a
# machine without the registry should still end up with a working binary.
echo
echo "== JavaScript dev dependencies =="
if command -v bun >/dev/null 2>&1; then
    if ! bun install --frozen-lockfile; then
        echo "setup: warning: bun install failed; 'bun run lint' and the pre-commit" >&2
        echo "setup: hook's JS check need 'bun install --frozen-lockfile' to have run" >&2
    fi
else
    echo "setup: bun not found; skipping. 'bun run lint', 'bun run css:build' and" >&2
    echo "setup: the pre-commit hook's JS check need it (see CONTRIBUTING.md)" >&2
fi

cat <<'EOF'

setup: a runnable build is in place.

Next:
  zig build test              full suite (Zig + JS), minutes
  zig build test -Dtest-filter="<substring>"   one test, seconds
  zig build quick-check       fmt check + host compile, no tests
  scripts/verify.sh           everything CI checks, before a push
  ./zig-out/bin/clanker init  create local state/
  ./zig-out/bin/clanker setup guided first run: config, keys, tools

Enable the pre-commit hooks once per clone:
  git config core.hooksPath .githooks
EOF
