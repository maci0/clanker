#!/usr/bin/env bash
# Run everything CI's verify job runs, locally, in one command.
#
# CI (.github/workflows/ci.yml) checks more than `clanker gate` does:
# shell script linting (shellcheck), oxlint over ui/ and tools/ts, the
# `tsc --noEmit` type check over tsconfig.json's program, the
# AssemblyScript rebuild-and-diff, the SBOM generation, and ruff over every
# tracked .py. None of those are part of `clanker gate` (shellcheck, bun and
# ruff are not guaranteed on a contributor machine), so a change that
# passes the gate locally can still fail on push. This script mirrors the CI
# steps so the full pre-push verification is one command instead of tribal
# knowledge.
#
# Usage: scripts/verify.sh
#   Requires: zig, python3. Bun only for oxlint, the JavaScript-toolchain
#   audits, and the AssemblyScript rebuild-and-diff (CI runs those steps
#   regardless; the script mirrors the pre-commit hook's soft-skip for
#   tools that are not installed).
#   Runs from the repository root; pass the path if invoked elsewhere.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
step() { printf '\n== %s ==\n' "$*"; }

step "shellcheck (CI: Check shell scripts)"
if command -v shellcheck >/dev/null 2>&1; then
    if [ -n "$(git ls-files -z '*.sh' '.githooks/pre-commit' | tr -d '\0')" ]; then
        git ls-files -z '*.sh' '.githooks/pre-commit' | xargs -0 shellcheck || status=1
    fi
else
    echo "shellcheck not installed; skipping (CI will run it)"
fi

if command -v bun >/dev/null 2>&1; then
    step "JavaScript lint (CI: Lint JavaScript)"
    bun install --frozen-lockfile || status=1
    bun test tools/oxlint || status=1
    bun run lint || status=1
    bun run typecheck || status=1
    bun scripts/brand.ts --check || status=1

    step "JavaScript toolchains (CI: Audit JavaScript toolchains)"
    bun audit --audit-level=high || status=1
    (cd tools/ts && bun audit --audit-level=high) || status=1
    (cd tools/ts && ./verify.sh) || status=1
    ./ui/app/verify-css.sh || status=1
else
    echo "bun not installed; skipping JavaScript lint, type check, tools/ts and Tailwind CSS verification (CI will run them)"
fi

step "SBOM generation (CI: Check SBOM generation)"
if command -v python3 >/dev/null 2>&1; then
    # The document goes to the gitignored .scratch/ rather than $TMPDIR: /tmp
    # is a tmpfs on a stock Linux box, so the write lands in RAM and a reboot
    # takes it. Same rule (and same reason) as the scratch dirs in
    # tools/ts/verify.sh, ui/app/verify-css.sh and scripts/verify-backup.sh.
    sbom_scratch="${CLANKER_SCRATCH_DIR:-.scratch}"
    mkdir -p "$sbom_scratch"
    python3 -B -m unittest scripts.test_sbom || status=1
    python3 scripts/sbom.py -o "$sbom_scratch/sbom.cdx.json" || status=1
    rm -f "$sbom_scratch/sbom.cdx.json"
else
    echo "python3 not installed; skipping SBOM check (CI will run it)"
fi

# The backup and restore-drill scripts are the only thing standing between
# `state/` and an incident, and nothing else executes their tests, so a change
# to either that stops checkpointing, refusing a corrupt store, or restoring
# cleanly would otherwise merge unseen. The installer is covered for the same
# reason: it decides where both units read their settings from.
step "State backup and restore drills (CI: Check state backup drills)"
if command -v python3 >/dev/null 2>&1; then
    python3 -B -m unittest scripts.test_backup_state scripts.test_verify_backup \
        scripts.test_install_state_backup || status=1
else
    echo "python3 not installed; skipping state backup drills (CI will run them)"
fi

step "Python lint (CI: Lint Python)"
# ruff.toml's `required-version` is the single pin: CI installs that release
# and this runs whatever is on PATH, so a mismatch refuses to check rather
# than reporting a result CI will not reproduce.
if command -v ruff >/dev/null 2>&1; then
    if [ -n "$(git ls-files -z '*.py' | tr -d '\0')" ]; then
        git ls-files -z '*.py' | xargs -0 ruff check || status=1
    fi
else
    echo "ruff not installed; skipping Python lint (CI will run it)"
fi

step "dependency patches (patches/*.patch)"
# Before any compile: --fetch=all extracts the pinned trees without
# configuring, and both build.zig (configure-time patch gate) and the gate's
# own dep-patches check refuse a pristine dependency tree. Ordered the other
# way round, a fresh worktree dies on the line immediately before the one
# that would have fixed it. Idempotent; no-op when already applied.
if command -v zig >/dev/null 2>&1; then
    zig build --fetch=all || status=1
fi
./scripts/apply-patches.sh || status=1

step "zig formatting (CI: Check Zig formatting)"
# The gate's fmt check covers only the files a proposal touched, so the
# repo-wide check needs its own invocation to match CI.
zig build fmt || status=1

step "zig build + clanker gate (CI: Run deterministic gate)"
zig build || status=1
./zig-out/bin/clanker gate || status=1

step "end-to-end tests (CI: Run end-to-end tests)"
zig build e2e || status=1

if [ "$status" -ne 0 ]; then
    echo >&2
    echo "verify: one or more CI-equivalent checks failed" >&2
    exit 1
fi
echo
echo "verify: all CI-equivalent checks passed"
