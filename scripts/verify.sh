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
#   Requires: zig, python3, shellcheck, ruff, bun. Every tool CI's verify job
#   uses is one this script now needs: a missing one used to print a
#   "skipping" line, leave status at 0, and end in
#   "verify: all CI-equivalent checks passed", so a machine without shellcheck
#   or ruff read as a green run the whole way to a red CI job. CI installs
#   each of them; install them here too, or set
#   CLANKER_VERIFY_ALLOW_SKIP=1 to accept a partial run knowingly (the summary
#   still names every check that did not run).
#   Runs from the repository root; pass the path if invoked elsewhere.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
skipped=0
skipped_list=""
step() { printf '\n== %s ==\n' "$*"; }

# A check this script could not run is not a passing check: CI runs every one
# of them, so a soft skip turns "my machine lacks ruff" into an after-push
# failure. Record the name, keep going so one missing tool does not hide the
# rest, and let the summary decide the exit status.
skip() {
    printf 'verify: SKIPPED: %s (CI runs it)\n' "$1" >&2
    skipped=$((skipped + 1))
    skipped_list="${skipped_list}${skipped_list:+, }$1"
}

step "shellcheck (CI: Check shell scripts)"
if command -v shellcheck >/dev/null 2>&1; then
    if [ -n "$(git ls-files -z '*.sh' '.githooks/pre-commit' | tr -d '\0')" ]; then
        git ls-files -z '*.sh' '.githooks/pre-commit' | xargs -0 shellcheck || status=1
    fi
else
    skip "shellcheck is not installed"
fi

step "YAML lint (CI: Check YAML)"
# Same gate, same .yamllint.yml and same index glob as CI's "Check YAML" step:
# a workflow that does not parse, or one carrying a duplicated key, is a
# finding here rather than a red X on someone else's PR.
if command -v yamllint >/dev/null 2>&1; then
    if [ -n "$(git ls-files -z '*.yml' '*.yaml' | tr -d '\0')" ]; then
        git ls-files -z '*.yml' '*.yaml' | xargs -0 yamllint -c .yamllint.yml || status=1
    fi
else
    skip "yamllint is not installed"
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
    skip "bun is not installed (JavaScript lint, type check, tools/ts and Tailwind CSS)"
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
    skip "python3 is not installed (SBOM check)"
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
    skip "python3 is not installed (state backup drills)"
fi

step "Python lint (CI: Lint Python)"
# ruff.toml carries `required-version`, so a ruff on PATH that is not the one CI
# installs refuses to load the config instead of quietly applying a different
# rule set. That is the local half of the same pin CI reads out of that file.
if command -v ruff >/dev/null 2>&1; then
    if [ -n "$(git ls-files -z '*.py' | tr -d '\0')" ]; then
        git ls-files -z '*.py' | xargs -0 ruff check || status=1
    fi
else
    skip "ruff is not installed"
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

if [ "$skipped" -ne 0 ]; then
    echo >&2
    echo "verify: $skipped check(s) did not run: $skipped_list" >&2
    if [ "${CLANKER_VERIFY_ALLOW_SKIP:-0}" != "1" ]; then
        # Not a failure of the tree, a failure to have verified it. The
        # checks that did run are still reported above, and the way to accept
        # a partial run is named rather than discovered by wondering which of
        # the lines above to believe.
        echo "verify: refusing to call this CI-equivalent. Install the tools named" >&2
        echo "verify: above, or set CLANKER_VERIFY_ALLOW_SKIP=1 to accept a" >&2
        echo "verify: partial run knowingly (CI will still run the rest)." >&2
        status=1
    fi
fi

if [ "$status" -ne 0 ]; then
    echo >&2
    echo "verify: one or more CI-equivalent checks did not pass" >&2
    exit 1
fi
echo
if [ "$skipped" -ne 0 ]; then
    echo "verify: every check that ran passed; $skipped did not run ($skipped_list)"
else
    echo "verify: all CI-equivalent checks passed"
fi
