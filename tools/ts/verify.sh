#!/usr/bin/env bash
# Verify tools/ts/dist/*.wasm matches a clean rebuild of tools/ts/*.ts.
#
# tools/ts/dist/ is committed (see AGENTS.md: not every clanker checkout has a
# node toolchain), which means nothing else catches a source edit that was
# not followed by `npm run build:all` before commit. This rebuilds into a
# scratch directory and diffs it against what is committed, so drift is
# caught here instead of shipping a stale artifact.
#
# Usage: tools/ts/verify.sh
set -euo pipefail
cd "$(dirname "$0")"

command -v npm >/dev/null || { printf 'error: npm is required to verify AssemblyScript build output\n' >&2; exit 1; }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# The compiler has no required lifecycle scripts. Keep verification installs
# inert so a compromised transitive package cannot execute code on the runner.
npm ci --silent --ignore-scripts

status=0
for f in *.ts; do
  [ -e "$f" ] || continue
  case "$f" in env.d.ts|lib.ts|json.ts) continue;; esac
  stem="${f%.ts}"
  npx --no-install asc "$f" -o "$scratch/$stem.wasm" --optimize --bindings raw --noExportMemory
  if ! cmp -s "$scratch/$stem.wasm" "../dist/$stem.wasm"; then
    printf 'drift: ../dist/%s.wasm does not match a clean rebuild of %s\n' "$stem" "$f" >&2
    status=1
  fi
done

if [ "$status" -eq 0 ]; then
  printf 'ok: tools/ts/dist/*.wasm matches tools/ts/*.ts\n'
else
  printf '  run: (cd tools/ts && npm run build:all) and commit the result\n' >&2
fi
exit "$status"
