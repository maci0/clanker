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

status=0
for f in *.ts; do
  [ -e "$f" ] || continue
  case "$f" in env.d.ts|lib.ts|json.ts) continue;; esac
  stem="${f%.ts}"
  ./node_modules/.bin/asc "$f" -o "$scratch/$stem.wasm" --optimize --bindings raw --noExportMemory
  # asc also emits a $stem.js binding and $stem.d.ts next to the wasm, and
  # all three are committed in dist/. Only diffing the wasm left a stale or
  # hand-edited .js/.d.ts to ship undetected, so compare the whole set.
  for ext in wasm js d.ts; do
    if ! cmp -s "$scratch/$stem.$ext" "dist/$stem.$ext"; then
      printf 'drift: dist/%s.%s does not match a clean rebuild of %s\n' "$stem" "$ext" "$f" >&2
      status=1
    fi
  done
done

if [ "$status" -eq 0 ]; then
  printf 'ok: tools/ts/dist/ matches a clean rebuild of tools/ts/*.ts\n'
else
  printf '  run: (cd tools/ts && bun run build:all) and commit the result\n' >&2
fi
exit "$status"
