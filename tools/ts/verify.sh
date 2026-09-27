#!/usr/bin/env bash
# Verify tools/ts/dist/* (wasm, js, d.ts) matches a clean rebuild of tools/ts/*.ts.
#
# tools/ts/dist/ is committed (see AGENTS.md: not every clanker checkout has a
# bun toolchain), which means nothing else catches a source edit that was
# not followed by `bun run build:all` before commit. This rebuilds into a
# scratch directory and diffs it against what is committed, so drift is
# caught here instead of shipping a stale artifact.
#
# Usage: tools/ts/verify.sh
set -euo pipefail
cd "$(dirname "$0")"

command -v bun >/dev/null || { printf 'error: bun is required to verify AssemblyScript build output\n' >&2; exit 1; }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# The compiler has no required lifecycle scripts, and bun only runs them for
# packages listed in trustedDependencies, so a compromised transitive package
# cannot execute code on the runner.
bun install --frozen-lockfile --silent

# The project's own build script, with its output directory pointed at the
# scratch tree: the flags and the skip list live in package.json's build:all
# and nowhere else, so this check cannot verify against a compiler
# invocation the committed dist/ was not built with. DIST_OUT is the same
# redirect ui/app/verify-css.sh uses over CSS_OUT.
#
# The comparison is the two whole directories rather than a hand-listed set
# of extensions: asc emits a .js binding and a .d.ts beside every .wasm and
# all three are committed, so a stale or hand-edited binding is drift too.
DIST_OUT="$scratch" bun run build:all

status=0
if ! drift="$(diff -r dist "$scratch")"; then
  printf '%s\n' "$drift" >&2
  printf 'drift: dist/ does not match a clean rebuild of tools/ts/*.ts\n' >&2
  status=1
fi

if [ "$status" -eq 0 ]; then
  printf 'ok: tools/ts/dist/ matches a clean rebuild of tools/ts/*.ts\n'
else
  printf '  run: (cd tools/ts && bun run build:all) and commit the result\n' >&2
fi
exit "$status"
