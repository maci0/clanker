#!/usr/bin/env bash
# scripts/clanker-review.sh — have clanker review its own source with the review
# prompts from ~/review-prompts/prompts.
#
# Usage:
#   ./scripts/clanker-review.sh [options] [prompt ...]
#
# Prompts are named without the -review.md suffix (see --list), e.g.
#   ./scripts/clanker-review.sh sec concurrency
#   ./scripts/clanker-review.sh --all --provider vertex-opus
#
# Options:
#   --provider NAME     provider to review with (default: config default)
#   --model NAME        override the provider's configured model
#   --prompts DIR       prompt directory (default: ~/review-prompts/prompts)
#   --out DIR           where reviews are written (default: state/reviews)
#   --all               run every prompt in the directory
#   --list              list available prompts and exit
#   --fix               after each review, hand its findings to
#                       scripts/clanker-improve.sh so clanker implements one of them
#   --iters N           iterations for --fix (default 1)
#   --skip-build        don't rebuild clanker + tools first
#   -h, --help          show this help
#
# Each review is written to <out>/<timestamp>-<prompt>.md. The agent reads the
# repository with its own tools; nothing is patched unless --fix is given.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { sed -En '2,/^$/{s/^# ?//p;}' "$0"; }

PROMPT_DIR="$HOME/review-prompts/prompts"
OUT_DIR="state/reviews"
PROVIDER=""
MODEL=""
ALL=0
LIST=0
FIX=0
ITERS=1
SKIP_BUILD=0
NAMES=()

need_arg() { [ $# -ge 2 ] || die "$1 requires a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --provider)   need_arg "$@"; PROVIDER="$2"; shift 2 ;;
    --model)      need_arg "$@"; MODEL="$2"; shift 2 ;;
    --prompts)    need_arg "$@"; PROMPT_DIR="$2"; shift 2 ;;
    --out)        need_arg "$@"; OUT_DIR="$2"; shift 2 ;;
    --all)        ALL=1; shift ;;
    --list)       LIST=1; shift ;;
    --fix)        FIX=1; shift ;;
    --iters)      need_arg "$@"; ITERS="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    -*)           die "unknown argument '$1' (see --help)" ;;
    *)            NAMES+=("$1"); shift ;;
  esac
done

[ -d "$PROMPT_DIR" ] || die "prompt directory not found: $PROMPT_DIR"

# Prompt files are "<name>-review.md"; the name alone is what users type.
AVAILABLE=()
while IFS= read -r name; do
  AVAILABLE+=("$name")
done < <(find "$PROMPT_DIR" -maxdepth 1 -name '*-review.md' -exec basename {} \; | sed 's/-review\.md$//' | sort)
[ ${#AVAILABLE[@]} -gt 0 ] || die "no *-review.md prompts in $PROMPT_DIR"

if [ "$LIST" -eq 1 ]; then
  printf '%s\n' "${AVAILABLE[@]}"
  exit 0
fi

if [ "$ALL" -eq 1 ] || [ ${#NAMES[@]} -eq 0 ]; then
  NAMES=("${AVAILABLE[@]}")
fi

for n in "${NAMES[@]}"; do
  [ -f "$PROMPT_DIR/$n-review.md" ] || die "no such prompt: $n (try --list)"
done

if [ "$SKIP_BUILD" -eq 0 ]; then
  info "building clanker + tools"
  zig build || die "build failed"
  zig build tools || die "tools build failed"
fi
[ -x zig-out/bin/clanker ] || die "zig-out/bin/clanker missing (run 'zig build', or pass --skip-build)"

mkdir -p "$OUT_DIR"

CLANKER_ARGS=()
[ -n "$PROVIDER" ] && CLANKER_ARGS+=(--provider "$PROVIDER")
[ -n "$MODEL" ] && CLANKER_ARGS+=(--model "$MODEL")

# The prompts are written for a tool that is handed the whole repository. The
# agent instead reads what it needs, so it is told where it is and what shape
# the answer should take.
FRAMING='You are reviewing the repository in your current working directory: clanker, a self-improving agent harness written in Zig 0.16. Use your tools (repo_search, read_file, roadmap, history) to read the actual source before judging it — do not review from memory or assume a file exists.

Report findings only, do not patch anything. For each finding give: the file and line, what is wrong, why it matters, and the smallest concrete fix. Order by impact, put the strongest finding first, and say plainly when a section of the review has nothing worth reporting rather than padding it.'

ts="$(date +%Y%m%d-%H%M%S)"
# `timeout` is GNU coreutils; macOS ships none. Without it a run that wedges
# wedges the loop too, so say so instead of failing silently.
TIMEOUT_CMD=()
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD=(timeout 1800)
else
  warn "no 'timeout' on this platform; each review run is unbounded"
fi
failed=0
for name in "${NAMES[@]}"; do
  out="$OUT_DIR/$ts-$name.md"
  info "review: $name -> $out"
  {
    # `date -Iseconds` is GNU-only; this UTC form reads the same on BSD date.
    printf '# %s review\n\n_provider: %s · %s_\n\n' "$name" "${PROVIDER:-default}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$out"

  # The prompt is passed as one task; the agent's answer is the review.
  task="$(cat "$PROMPT_DIR/$name-review.md")

---

$FRAMING"
  if ! ${TIMEOUT_CMD+"${TIMEOUT_CMD[@]}"} ./zig-out/bin/clanker "${CLANKER_ARGS[@]}" run "$task" >>"$out" 2>"$out.log"; then
    warn "$name: review run failed (see $out.log)"
    failed=$((failed + 1))
    continue
  fi

  words="$(wc -w <"$out")"
  # An agent run that ends at its iteration limit exits 0 with partial work in
  # the file, which reads as a short review rather than a failed one.
  if grep -q 'did not produce a final answer' "$out.log" 2>/dev/null; then
    warn "$name: hit the iteration limit without concluding; raise agent.max_iterations"
    failed=$((failed + 1))
    continue
  fi
  info "$name: $words words"

  if [ "$FIX" -eq 1 ]; then
    info "$name: implementing the top finding"
    {
      printf 'Implement the single highest-value fix from the review below. Pick one finding, make the smallest correct change, and add a test that fails without it. Ignore findings that are already fixed in the current source.\n\n'
      cat "$out"
    } >"$out.instr"
    IMPROVE_ARGS=(--iters "$ITERS" --instruction-file "$out.instr" --skip-build)
    # Passing --provider "" is not the same as passing nothing: clanker reads
    # the empty string as a provider name and fails with UnknownProvider, so
    # every fix run without an explicit --provider died here.
    [ -n "$PROVIDER" ] && IMPROVE_ARGS=(--provider "$PROVIDER" "${IMPROVE_ARGS[@]}")
    ./scripts/clanker-improve.sh "${IMPROVE_ARGS[@]}"
    rc=$?
    if [ "$rc" -eq 75 ]; then
      warn "$name: another improve-self holds the lock; the finding was not applied"
    elif [ "$rc" -ne 0 ]; then
      warn "$name: improve run failed (exit $rc)"
    fi
  fi
done

info "done: $(( ${#NAMES[@]} - failed ))/${#NAMES[@]} reviews written to $OUT_DIR"
[ "$failed" -eq 0 ] || exit 1
