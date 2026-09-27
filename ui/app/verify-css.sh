#!/usr/bin/env bash
# Verify ui/app/tailwind.css matches a clean rebuild of ui/app/tailwind.src.css.
#
# ui/app/tailwind.css is committed (see AGENTS.md: not every clanker checkout
# has a bun toolchain), and the host embeds it into ui/app/app.wasm, so a source
# edit that was not followed by `bun run css:build` before commit ships a
# stylesheet that styles nothing. tools/ts/verify.sh already does this for the
# AssemblyScript output; this is the same check for the other committed build
# artifact, in the same place (beside the artifact it verifies).
#
# Usage: ui/app/verify-css.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

command -v bun >/dev/null || { printf 'error: bun is required to verify the Tailwind CSS build output\n' >&2; exit 1; }

# The compiler has no required lifecycle scripts, and bun only runs them for
# packages listed in trustedDependencies, so a compromised transitive package
# cannot execute code on the runner.
bun install --frozen-lockfile --silent

# Not `mktemp -d`: that lands in $TMPDIR, a tmpfs on a stock Linux box, so the
# compiled stylesheet is written to RAM and vanishes on reboot. The project's
# own rule (AGENTS.md, and the same reason scripts/verify-backup.sh stages
# beside the store rather than in /tmp) puts scratch in the gitignored
# .scratch/ at the project root, which this script's `cd` above already put us
# in. CLANKER_SCRATCH_DIR overrides it.
scratch_root="${CLANKER_SCRATCH_DIR:-.scratch}"
mkdir -p "$scratch_root"
scratch="$(mktemp -d "$scratch_root/ui-verify-css.XXXXXXXXXX")"
trap 'rm -rf "$scratch"' EXIT

# The npm script owns the input/output pair (CSS_OUT redirects the destination
# so this check cannot drift from what `bun run css:build` really compiles).
CSS_OUT="$scratch/tailwind.css" bun run css:build

if cmp -s "$scratch/tailwind.css" ui/app/tailwind.css; then
    printf 'ok: ui/app/tailwind.css matches a clean rebuild of ui/app/tailwind.src.css\n'
else
    printf 'drift: ui/app/tailwind.css does not match a clean rebuild of ui/app/tailwind.src.css\n' >&2
    printf '  run: bun run css:build and commit the result\n' >&2
    exit 1
fi
