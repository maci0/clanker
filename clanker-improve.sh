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
#   --note TEXT               extra constraints appended to the instruction
#                             (repeatable; e.g. local API idioms, "don't touch X")
#   --note-file FILE          same, read from a file
#   --roadmap [N]             implement the Nth unchecked (planned) feature in
#                             docs/ROADMAP.md (default 1: the next planned one)
#   --iters N                 improvement iterations (default 2, must be >= 1)
#   --provider NAME           provider: deepseek | kimi-k3 | muse-spark | <any>
#   --model NAME              override the provider's configured model
#   --dry-run                 preview the proposal without promoting
#   --skip-build              don't rebuild clanker + tools first
#   --log FILE                append a copy of the run to FILE
#                             (default: state/logs/improve-<timestamp>.log)
#   --no-log                  don't write a log file
#   -h, --help                show this help
#
# Exit status: clanker's own, except 75 when another improve-self already holds
# the lock on this working tree and this run did nothing.
#
# Modes (mutually exclusive):
#   review   (default)        the instruction below or --instruction(-file)
#   roadmap                   --roadmap [N]: pick an unimplemented feature from
#                             docs/ROADMAP.md and have clanker build it
#
# improve-self is a single-shot patch loop, not the agent tool loop: the model
# is shown source files and answers with a patch, with no tools. What it sees is
# chosen per instruction and bounded by a byte budget, so it is a selection of
# src/, tools/, tests/, evals/, tools/manifests/, build.zig* and
# config.toml/config.json, not all of them; whatever did not fit is listed by
# name in the prompt so nothing is patched blind. Files the instruction names by
# path are always included whole.
#
# The one lookup it has is to ask: a response of {"need": [...paths]} with no
# "changes" gets the run asked again with those files pinned in, up to
# improve.max_context_requests (config, default 3) times per run. That is how it
# reaches docs/ROADMAP.md, which is otherwise never in context and is why the
# planned items below are pasted into the instruction by hand.
#
# API keys are resolved automatically when the provider is known:
#   deepseek    -> DEEPSEEK_API_KEY  <- env | ~/.secrets/deepseek.txt
#   kimi-k3     -> KIMI_API_KEY      <- env | ~/.secrets/kimi-api-key
#   muse-spark  -> META_AI_API_KEY   <- env | ~/.secrets/meta-llm-api
# For any other provider the harness reads the env var named in config, so
# just make sure it is exported.

set -euo pipefail
cd "$(dirname "$0")"

[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || { printf 'error: bash 4+ required\n' >&2; exit 1; }

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
# Print the header comment block, however long it grows.
usage() { sed -n '2,/^$/!d; s/^# \?//p' "$0"; }

# Flip the first '- [ ] ...' line matching $1 to '- [x]'. Compared as whole
# lines, so item text containing regex or glob characters is safe.
mark_roadmap_done() {
  local target="$1" line tmp found=0
  tmp="$(mktemp)"
  while IFS= read -r line; do
    if [ "$found" -eq 0 ] && [ "$line" = "$target" ]; then
      printf '%s\n' "${line/- \[ \]/- [x]}"
      found=1
    else
      printf '%s\n' "$line"
    fi
  done < docs/ROADMAP.md > "$tmp"
  if [ "$found" -eq 1 ]; then
    mv "$tmp" docs/ROADMAP.md
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Known provider -> env var + secrets file. Add a row to support a provider.
declare -A KEY_ENV=(
  [deepseek]=DEEPSEEK_API_KEY
  [kimi-k3]=KIMI_API_KEY
  [muse-spark]=META_AI_API_KEY
)
declare -A KEY_FILE=(
  [deepseek]="$HOME/.secrets/deepseek.txt"
  [kimi-k3]="$HOME/.secrets/kimi-api-key"
  [muse-spark]="$HOME/.secrets/meta-llm-api"
)

# ------------------------------------------------------------- defaults --
INSTRUCTION=""
NOTES=()
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
# `shift 2` on a flag whose value is missing exits via set -e with no message,
# so every value-taking flag is checked here instead.
need_arg() { [ $# -ge 2 ] || die "$1 requires a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --instruction)       need_arg "$@"; INSTRUCTION="$2"; shift 2 ;;
    --instruction-file)  need_arg "$@"; INSTRUCTION_FILE="$2"; shift 2 ;;
    --note)              need_arg "$@"; NOTES+=("$2"); shift 2 ;;
    --note-file)         need_arg "$@"; [ -f "$2" ] || die "note file not found: $2"; NOTES+=("$(cat "$2")"); shift 2 ;;
    --roadmap)           ROADMAP=1; if [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; then ROADMAP_N="$2"; shift 2; else shift; fi ;;
    --iters)             need_arg "$@"; ITERS="$2"; shift 2 ;;
    --provider)          need_arg "$@"; PROVIDER="$2"; shift 2 ;;
    --model)             need_arg "$@"; MODEL="$2"; shift 2 ;;
    --dry-run)           DRY_RUN=1; shift ;;
    --skip-build)        SKIP_BUILD=1; shift ;;
    --log)               need_arg "$@"; LOG_FILE="$2"; WANT_LOG=1; shift 2 ;;
    --no-log)            WANT_LOG=0; LOG_FILE=""; shift ;;
    -h|--help)           usage; exit 0 ;;
    --)                  shift; POSITIONAL+=("$@"); break ;;
    -*)                  die "unknown argument '$1' (see --help)" ;;
    *)                   POSITIONAL+=("$1"); shift ;;
  esac
done

# --------------------------------------------------- resolve instruction --
# The engine never puts docs/ROADMAP.md in the model's context, so the planned
# items are passed in here as direction instead.
ROADMAP_HINT=""
if [ -f docs/ROADMAP.md ]; then
  PLANNED="$(sed -n 's/^[[:space:]]*- \[ \] //p' docs/ROADMAP.md | head -8)"
  if [ -n "$PLANNED" ]; then
    ROADMAP_HINT="Planned features, as direction (docs/ROADMAP.md is not in your context and you cannot edit it):
${PLANNED}

"
  fi
fi

# Shared tail: what the model may touch and what it must not invent. Kept short
# because every token here competes with source context for the same budget.
GUARDRAILS="Build it wired in and usable, not stubbed: reachable from the CLI, the agent loop, or the REPL that it belongs to, handling the empty, zero, and malformed cases. Extend the module that already owns the concern instead of starting a parallel one, and add a test in the same file when the logic branches.

Do not add third-party dependencies. Do not touch state/, config.local.json, config.local.toml, or .env, and never move a secret into a tracked file.

In \"rationale\", say what clanker can do after this patch that it could not do before."

if [ "$ROADMAP" -eq 1 ]; then
  if [ -n "$INSTRUCTION" ] || [ -n "$INSTRUCTION_FILE" ] || [ ${#POSITIONAL[@]} -gt 0 ]; then
    die "--roadmap is mutually exclusive with --instruction, --instruction-file, and a positional instruction"
  fi
  [ -f docs/ROADMAP.md ] || die "docs/ROADMAP.md not found"
  mapfile -t ITEMS < <(grep -E '^\s*- \[ \]' docs/ROADMAP.md || true)
  if [ ${#ITEMS[@]} -eq 0 ]; then
    die "docs/ROADMAP.md has no unchecked (planned) items — nothing to implement"
  fi
  if [ "$ROADMAP_N" -gt "${#ITEMS[@]}" ]; then
    die "--roadmap $ROADMAP_N out of range: docs/ROADMAP.md has only ${#ITEMS[@]} planned item(s)"
  fi
  ITEM="${ITEMS[$((ROADMAP_N - 1))]}"
  INSTRUCTION="Implement this planned clanker feature (item $ROADMAP_N of docs/ROADMAP.md):

${ITEM}

Read the files in the context before deciding where it belongs, then build the smallest version that is genuinely usable.

${GUARDRAILS}"
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
  INSTRUCTION="Make clanker more capable. Pick the single change that most increases what this agent can do, and implement it completely.

Hunt for capability gaps first, in roughly this order:
1. A feature that is half there: a command, flag, or config field the code reads but nothing acts on, a code path that handles one case and gives up on the rest.
2. The obvious next feature for a subsystem that already exists: another provider capability, another tool the sandbox could expose, another surface for something the harness already computes.
3. A capability clanker plainly lacks and would use on its own next run.

Fix a defect instead only when it blocks that work: a crash, wrong output, a leaked allocation, or an error path reported as success.

${ROADMAP_HINT}${GUARDRAILS}"
fi
[ -n "$INSTRUCTION" ] || die "empty instruction"

# Notes ride along with every instruction: constraints the model cannot infer
# from the source alone (local API idioms, guards it must not weaken) belong
# with the task, not in a wrapper that has to re-derive them.
for note in ${NOTES+"${NOTES[@]}"}; do
  INSTRUCTION="$INSTRUCTION

$note"
done

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

# A promoted improvement is written straight into the live tree, so anything
# uncommitted here ends up tangled with it.
if [ "$DRY_RUN" -eq 0 ] && command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    warn "working tree has uncommitted changes; a promoted patch will mix into them"
  fi
fi

# ---------------------------------------------------------- api keys ---------
# Resolve the effective provider: an explicit --provider wins; otherwise the
# default_provider from config.local.toml/config.local.json (overrides) or
# config.toml/config.json. TOML takes precedence over JSON, matching
# src/config.zig's own load order.
read_default_provider() {
  local f v
  for f in config.local.toml config.local.json config.toml config.json; do
    [ -f "$f" ] || continue
    case "$f" in
      *.toml) v="$(sed -n 's/^default_provider[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1)" ;;
      *.json) v="$(sed -n 's/.*"default_provider"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1)" ;;
    esac
    if [ -n "$v" ]; then printf '%s' "$v"; return; fi
  done
  printf '%s' ""
}

load_key() {
  local provider="${1:-}"
  if [ -z "$provider" ]; then
    provider="$(read_default_provider)"
    [ -n "$provider" ] || die "no --provider given and no default_provider in config.json"
    info "no --provider given; using default '$provider' from config"
  fi

  local var="${KEY_ENV[$provider]:-}"
  if [ -z "$var" ]; then
    info "provider '$provider' — assuming its API key env var is already set"
    return
  fi

  local file="${KEY_FILE[$provider]:-}"
  if [ -z "${!var:-}" ] && [ -n "$file" ] && [ -f "$file" ]; then
    export "$var=$(tr -d '\r\n' < "$file")"
  fi
  # clanker reads .env itself at startup, so a key that lives only there is
  # perfectly usable and this script has no business refusing the run.
  if [ -z "${!var:-}" ] && [ -f .env ] && grep -q "^${var}=" .env; then
    info "$var comes from .env"
    return
  fi
  [ -n "${!var:-}" ] || die "$var is not set (export it, add $file, or put it in .env)"
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

# Logs live in their own directory: state/ already holds structured data
# (history/, runs/, sessions/, staging/) and loose logs bury it.
mkdir -p state/logs
if [ "$WANT_LOG" -eq 1 ] && [ -z "$LOG_FILE" ]; then
  LOG_FILE="state/logs/improve-$(date +%Y%m%d-%H%M%S).log"
fi

RUN_LOG="$LOG_FILE"
if [ -z "$RUN_LOG" ]; then
  RUN_LOG="$(mktemp state/logs/improve-run.XXXXXX.log)"
  trap 'rm -f "$RUN_LOG"' EXIT
fi
if [ -n "$LOG_FILE" ]; then info "logging to $LOG_FILE"; fi
zig-out/bin/clanker "${CLANKER_ARGS[@]}" "$INSTRUCTION" 2>&1 | tee "$RUN_LOG"
CLANKER_RC=${PIPESTATUS[0]}

# One machine-readable line at the end: a loop driving this script should not
# have to grep the whole log to find out whether anything landed.
# Only one improve-self may touch a working tree at a time. Hitting that is a
# "come back later", not a result: a loop that reads it as promoted=0 concludes
# the model had nothing to say and moves on to the next instruction.
if grep -q 'another improve-self is already running' "$RUN_LOG"; then
  info "summary: skipped=locked exit=75"
  warn "another improve-self holds the lock; nothing was attempted"
  exit 75
fi

PROMOTED=$(grep -c 'promoted improvement' "$RUN_LOG" || true)
GATE=$(grep -o 'final gate: [0-9.]*/[0-9]*' "$RUN_LOG" | tail -1)
info "summary: promoted=$PROMOTED exit=$CLANKER_RC ${GATE:-gate=unknown}"

# The model cannot edit docs/ROADMAP.md (the engine never puts it in context),
# so ticking the item is done here, and only when something was really promoted.
if [ "$ROADMAP" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  if grep -q 'promoted improvement' "$RUN_LOG"; then
    if mark_roadmap_done "$ITEM"; then
      info "marked done in docs/ROADMAP.md: $(printf '%s' "$ITEM" | head -c 70)"
    else
      warn "could not find the item in docs/ROADMAP.md; tick it by hand"
    fi
  else
    info "nothing was promoted; docs/ROADMAP.md left unchanged"
  fi
fi

exit "${CLANKER_RC:-0}"
