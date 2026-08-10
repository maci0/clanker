#!/usr/bin/env bash
# clanker-improve.sh — run clanker and instruct it to improve itself.
#
# Usage:
#   ./clanker-improve.sh [instruction] [options]
#
# The instruction can be given positionally, via --instruction, or via
# --instruction-file (recommended for anything with quotes/backticks — shell
# quoting has bitten this script before).
#
# Options:
#   --instruction TEXT        the improvement instruction (overrides positional)
#   --instruction-file FILE   read the instruction from FILE ('-' = stdin)
#   --roadmap [N]             implement the Nth unchecked (planned) feature in
#                             docs/ROADMAP.md (default 1: the next planned one)
#   --iters N                 improvement iterations (default 2, must be >= 1)
#   --provider NAME           provider: deepseek | kimi-k3 | muse-spark | <any>
#   --model NAME              override the provider's configured model
#   --dry-run                 preview the proposal without promoting
#   --skip-build              don't rebuild clanker + tools first
#   --log FILE                append a copy of the run to FILE
#                             (default: state/improve-<timestamp>.log)
#   --no-log                  don't write a log file
#   -h, --help                show this help
#
# Modes (mutually exclusive):
#   review   (default)        the instruction below or --instruction(-file);
#                             improvements keep docs/README.md, docs/ROADMAP.md
#                             and AGENTS.md in sync with the code
#   roadmap                   --roadmap [N]: pick an unimplemented feature from
#                             docs/ROADMAP.md and have clanker build it, marking
#                             it done in the roadmap when finished
#
# API keys are resolved automatically when the provider is known:
#   deepseek    -> DEEPSEEK_API_KEY  <- env | ~/.secrets/deepseek.txt
#   kimi-k3     -> KIMI_API_KEY      <- env | ~/.secrets/kimi-api-key
#   muse-spark  -> META_AI_API_KEY   <- env | ~/.secrets/meta-llm-api
# For any other provider the harness reads the env var named in config, so
# just make sure it is exported.

set -euo pipefail
cd "$(dirname "$0")"

info() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,30p' "$0" | sed 's/^# \?//'; }

# ------------------------------------------------------------- defaults --
INSTRUCTION=""
INSTRUCTION_FILE=""
ROADMAP=0
ROADMAP_N=1
ITERS=2
PROVIDER=""
MODEL=""
DRY_RUN=0
SKIP_BUILD=0
LOG_FILE=""
WANT_LOG=1
POSITIONAL=()

# --------------------------------------------------------------- args --
while [ $# -gt 0 ]; do
  case "$1" in
    --instruction)       INSTRUCTION="${2:-}"; shift 2 ;;
    --instruction-file)  INSTRUCTION_FILE="${2:-}"; shift 2 ;;
    --roadmap)           ROADMAP=1; if [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; then ROADMAP_N="$2"; shift 2; else shift; fi ;;
    --iters)             ITERS="${2:-}"; shift 2 ;;
    --provider)          PROVIDER="${2:-}"; shift 2 ;;
    --model)             MODEL="${2:-}"; shift 2 ;;
    --dry-run)           DRY_RUN=1; shift ;;
    --skip-build)        SKIP_BUILD=1; shift ;;
    --log)               LOG_FILE="${2:-}"; WANT_LOG=1; shift 2 ;;
    --no-log)            WANT_LOG=0; shift ;;
    -h|--help)           usage; exit 0 ;;
    --)                  shift; POSITIONAL+=("$@"); break ;;
    -*)                  die "unknown argument '$1' (see --help)" ;;
    *)                   POSITIONAL+=("$1"); shift ;;
  esac
done

# --------------------------------------------------- resolve instruction --
if [ "$ROADMAP" -eq 1 ]; then
  if [ -n "$INSTRUCTION" ] || [ -n "$INSTRUCTION_FILE" ] || [ ${#POSITIONAL[@]} -gt 0 ]; then
    die "--roadmap is mutually exclusive with --instruction, --instruction-file, and a positional instruction"
  fi
  # Implement the Nth unchecked (planned) feature from docs/ROADMAP.md.
  [ -f docs/ROADMAP.md ] || die "docs/ROADMAP.md not found"
  mapfile -t ITEMS < <(grep -E '^\s*- \[ \]' docs/ROADMAP.md || true)
  if [ ${#ITEMS[@]} -eq 0 ]; then
    die "docs/ROADMAP.md has no unchecked (planned) items — nothing to implement"
  fi
  if [ "$ROADMAP_N" -gt "${#ITEMS[@]}" ]; then
    die "--roadmap $ROADMAP_N out of range: docs/ROADMAP.md has only ${#ITEMS[@]} planned item(s)"
  fi
  ITEM="${ITEMS[$((ROADMAP_N - 1))]}"
  INSTRUCTION="Implement the following planned feature for clanker (item $ROADMAP_N from docs/ROADMAP.md):

${ITEM}

Read the relevant source first, design the smallest correct implementation, then implement it completely. After the implementation works and all gates pass, update docs/ROADMAP.md: change this item's leading '- [ ]' to '- [x]' and append a short DONE note describing what was built and where. Do not touch unrelated code. Every change must pass the full gate (zig build, zig build test, zig build tools, zig fmt, lint)."
elif [ -n "$INSTRUCTION" ]; then
  :
elif [ -n "$INSTRUCTION_FILE" ]; then
  if [ "$INSTRUCTION_FILE" = "-" ]; then
    INSTRUCTION="$(cat)"
  else
    [ -f "$INSTRUCTION_FILE" ] || die "instruction file not found: $INSTRUCTION_FILE"
    INSTRUCTION="$(cat "$INSTRUCTION_FILE")"
  fi
elif [ ${#POSITIONAL[@]} -gt 0 ]; then
  INSTRUCTION="${POSITIONAL[0]}"
  if [ ${#POSITIONAL[@]} -gt 1 ]; then
    die "unexpected extra arguments: ${POSITIONAL[*]:1} (put the instruction in quotes, or use --instruction-file)"
  fi
else
  INSTRUCTION="Review the clanker codebase (src/, tool-src/, tools.d/, eval-tasks/, skills/) for bugs, dead code, and token-efficiency improvements. Use your search_code and git tools to investigate, then propose and implement the highest-impact fixes. Keep the docs in sync with the code: update docs/README.md, docs/ROADMAP.md, and AGENTS.md whenever a change affects behavior, commands, config, or architecture (mark roadmap items done, reflect new features). Every change must pass the full gate (zig build, zig build test, zig build tools, zig fmt, lint). Persist learnings with write_note."
fi
[ -n "$INSTRUCTION" ] || die "empty instruction"

case "$ITERS" in
  ''|*[!0-9]*) die "--iters must be a positive integer, got '$ITERS'" ;;
esac
[ "$ITERS" -ge 1 ] 2>/dev/null || die "--iters must be >= 1"

# ------------------------------------------------------------- build ---------
if [ "$SKIP_BUILD" -eq 0 ]; then
  info "building clanker + tools"
  zig build
  zig build tools
fi
[ -x zig-out/bin/clanker ] || die "zig-out/bin/clanker missing — run 'zig build' first (or use --skip-build)"

# ---------------------------------------------------------- api keys ---------
# Load the API key for a known provider from the environment or ~/.secrets.
# Resolve the effective provider: an explicit --provider wins; otherwise the
# default_provider from config.local.json (overrides) or config.json.
read_default_provider() {
  local f v
  for f in config.local.json config.json; do
    [ -f "$f" ] || continue
    v="$(sed -n 's/.*"default_provider"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1)"
    if [ -n "$v" ]; then printf '%s' "$v"; return; fi
  done
  printf '%s' ""
}

load_key() {
  local requested="${1:-}"
  local provider="$requested"
  if [ -z "$provider" ]; then
    provider="$(read_default_provider)"
    if [ -n "$provider" ]; then
      info "no --provider given; using default '$provider' from config"
    fi
  fi
  case "$provider" in
    ""|deepseek)
      if [ -z "${DEEPSEEK_API_KEY:-}" ] && [ -f "$HOME/.secrets/deepseek.txt" ]; then
        export DEEPSEEK_API_KEY="$(tr -d '\n' < "$HOME/.secrets/deepseek.txt")"
      fi
      [ -n "${DEEPSEEK_API_KEY:-}" ] || die "DEEPSEEK_API_KEY is not set (export it or add ~/.secrets/deepseek.txt)"
      ;;
    kimi-k3)
      if [ -z "${KIMI_API_KEY:-}" ] && [ -f "$HOME/.secrets/kimi-api-key" ]; then
        export KIMI_API_KEY="$(tr -d '\n' < "$HOME/.secrets/kimi-api-key")"
      fi
      [ -n "${KIMI_API_KEY:-}" ] || die "KIMI_API_KEY is not set (export it or add ~/.secrets/kimi-api-key)"
      ;;
    muse-spark)
      if [ -z "${META_AI_API_KEY:-}" ] && [ -f "$HOME/.secrets/meta-llm-api" ]; then
        export META_AI_API_KEY="$(tr -d '\n' < "$HOME/.secrets/meta-llm-api")"
      fi
      [ -n "${META_AI_API_KEY:-}" ] || die "META_AI_API_KEY is not set (export it or add ~/.secrets/meta-llm-api)"
      ;;
    *)
      info "provider '$provider' — assuming its API key env var is already set"
      ;;
  esac
}
load_key "$PROVIDER"

# --------------------------------------------------------------- run ---------
CLANKER_ARGS=(improve-self)
if [ -n "$PROVIDER" ]; then CLANKER_ARGS+=(--provider "$PROVIDER"); fi
if [ -n "$MODEL" ]; then CLANKER_ARGS+=(--model "$MODEL"); fi
CLANKER_ARGS+=(--iters "$ITERS")
if [ "$DRY_RUN" -eq 1 ]; then CLANKER_ARGS+=(--dry-run); fi

info "improve-self (iters=$ITERS provider=${PROVIDER:-$(read_default_provider)} model=${MODEL:-default}$( [ "$DRY_RUN" -eq 1 ] && echo ' dry-run'))"
info "instruction: $(printf '%s' "$INSTRUCTION" | head -c 150)$([ ${#INSTRUCTION} -gt 150 ] && echo '…')"

if [ "$WANT_LOG" -eq 1 ] && [ -z "$LOG_FILE" ]; then
  mkdir -p state
  LOG_FILE="state/improve-$(date +%Y%m%d-%H%M%S).log"
fi

if [ -n "$LOG_FILE" ]; then
  info "logging to $LOG_FILE"
  zig-out/bin/clanker "${CLANKER_ARGS[@]}" "$INSTRUCTION" 2>&1 | tee "$LOG_FILE"
else
  zig-out/bin/clanker "${CLANKER_ARGS[@]}" "$INSTRUCTION"
fi
