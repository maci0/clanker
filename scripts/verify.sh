#!/usr/bin/env bash
# Run everything CI's verify job runs, locally, in one command.
#
# CI (.github/workflows/ci.yml) checks more than `clanker gate` does:
# shell script linting (shellcheck), the AssemblyScript rebuild-and-diff, the
# SBOM generation, and a syntax check of every tracked .py. None of those
# are part of `clanker gate` (shellcheck and node are not guaranteed on a
# contributor machine), so a change that passes the gate locally can still
# fail on push. This script mirrors the CI steps so the full pre-push
# verification is one command instead of tribal knowledge.
#
# Usage: scripts/verify.sh
#   Requires: zig, python3. Node/npm only when the AssemblyScript tree
#   changed (CI runs those steps regardless; the script mirrors the
#   pre-commit hook's soft-skip for tools that are not installed).
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

step "JavaScript toolchains (CI: Audit JavaScript toolchains)"
if command -v npm >/dev/null 2>&1; then
    npm audit --audit-level=high || status=1
    (cd tools/ts && npm audit --audit-level=high) || status=1
    (cd tools/ts && ./verify.sh) || status=1
else
    echo "npm not installed; skipping tools/ts verification (CI will run it)"
fi

step "SBOM generation (CI: Check SBOM generation)"
if command -v python3 >/dev/null 2>&1; then
    python3 scripts/sbom.py -o "${TMPDIR:-/tmp}/sbom.cdx.json" || status=1
else
    echo "python3 not installed; skipping SBOM check (CI will run it)"
fi

step "Python syntax check (CI: Compile-check Python scripts)"
if command -v python3 >/dev/null 2>&1; then
    if [ -n "$(git ls-files -z '*.py' | tr -d '\0')" ]; then
        git ls-files -z '*.py' | xargs -0 python3 -c 'import ast,pathlib,sys; [ast.parse(pathlib.Path(p).read_bytes()) for p in sys.argv[1:]]' || status=1
    fi
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
