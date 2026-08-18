#!/bin/bash
# Resolve the Clanker checkout and binary, ask which improve-self model, which
# escalation model and which repair harness to use, then run the loop.
set -euo pipefail

LOOP="$(dirname "$(readlink -f "$0")")/loop.py"

# Same knob as clank.sh, overridable from the environment.
CLANKER_DIR="${CLANKER_DIR:-/home/yannick/code/maci0/clanker}"

# Models for improve-self batches. The literal "default" passes no --model at
# all, so the model in Clanker's own configuration applies. Clanker repair runs
# always use the configured model.
MODELS=(
    default
    ollama/qwen3.6-27b-tuned
    deepseek/deepseek-v4-pro
)

# Models for the clanker escalation run — the second clanker run, which repairs
# a failed clanker repair run before the outside harness is reached. The literal
# "default" passes no --model, which is the same model the repair run just
# failed on, so name a stronger model here to actually escalate. Entries are
# <model> or <provider>/<model>.
ESCALATE_MODELS=(
    default
    ollama/qwen3.6-27b-tuned
    deepseek/deepseek-v4-pro
)

# Harnesses that repair a failed clanker escalation run. Repair runs fix
# improve-self, escalation runs fix them, and these fix the escalation runs. The
# literal "none" skips that level entirely.
#
# Each entry is a command that takes the prompt as its final argument and
# reports failure through its exit status, so the harness and its model are
# chosen together here.
FIXERS=(
    none
    "claude -p --permission-mode acceptEdits"
    "claude -p --permission-mode acceptEdits --model opus"
    "codex exec"
    "grok --always-approve -p"
    "dsh --profile headless"
)

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    cat <<'USAGE'
usage: run.sh [loop arguments...]

Starts menus for the improve-self model, the escalation model and the repair
harness, then execs loop.py with the checkout and binary already resolved.
Every argument is passed straight through to the loop, and passing --model,
--escalate-model or --fix-repairs-with yourself skips the matching menu.

REPAIR LEVELS
  1  clanker improve-self       a batch of iterations
  2  clanker repair run         fixes a failed batch, on the configured model
  3  clanker escalation run     fixes a failed repair run, on --escalate-model
  4  --fix-repairs-with CMD     fixes a failed escalation run

ENVIRONMENT
  CLANKER_DIR  Clanker checkout to improve  (default: /home/yannick/code/maci0/clanker)
  CLANKER_BIN  clanker executable           (default: clanker on PATH, falling
                                             back to $CLANKER_DIR/zig-out/bin/clanker)

EXAMPLES
  run.sh                                      start the menus, then the loop
  run.sh --iters 5 "improve the clanker tui"  pass options to the loop
  run.sh --escalate-model zai/glm-5.2         skip the escalation model menu
  run.sh --fix-repairs-with "codex exec"      skip the harness menu
  CLANKER_DIR=~/src/clanker run.sh            drive another checkout

Copy this file to run.local.sh and edit the MODELS, ESCALATE_MODELS and
FIXERS arrays there to change the menus. run.local.sh is gitignored.
Run loop.py --help for the loop's own options.
USAGE
    exit 0
fi

if [[ ! -d "$CLANKER_DIR" ]]; then
    echo "error: CLANKER_DIR is not a directory: $CLANKER_DIR" >&2
    exit 2
fi
CLANKER_DIR="$(readlink -f "$CLANKER_DIR")"

# CLANKER_BIN wins, then clanker on PATH, then the binary built in the checkout,
# so a checkout without a PATH entry still works.
if [[ -z "${CLANKER_BIN:-}" ]]; then
    CLANKER_BIN="$(command -v clanker || true)"
fi
if [[ -z "$CLANKER_BIN" && -x "$CLANKER_DIR/zig-out/bin/clanker" ]]; then
    CLANKER_BIN="$CLANKER_DIR/zig-out/bin/clanker"
fi
if [[ -z "$CLANKER_BIN" ]]; then
    echo "error: no clanker on PATH and none at $CLANKER_DIR/zig-out/bin/clanker" >&2
    echo "       build the checkout, or set CLANKER_BIN to the executable" >&2
    exit 2
fi
if [[ ! -x "$CLANKER_BIN" ]]; then
    echo "error: CLANKER_BIN is not executable: $CLANKER_BIN" >&2
    exit 2
fi

# Whether the caller already set a flag, so its menu can be skipped.
has_flag() {
    local needle="$1" arg
    shift
    for arg in "$@"; do
        [[ "$arg" == "$needle" || "$arg" == "$needle="* ]] && return 0
    done
    return 1
}

# pick TITLE DESCRIPTION SENTINEL NOTE ITEM... -> sets "choice"
# The menu is printed by hand rather than with `select`, which columnises into
# an unreadable grid and cannot take Enter as a default.
choice=""
pick() {
    local title="$1" description="$2" sentinel="$3" note="$4"
    shift 4
    local options=("$@") count=$# width=${##} index label reply

    echo "$title"
    printf '%s\n\n' "$description"
    for index in "${!options[@]}"; do
        label="${options[index]}"
        [[ "$label" == "$sentinel" ]] && label="$sentinel  ($note)"
        printf '  %*d) %s\n' "$width" "$((index + 1))" "$label"
    done
    echo

    while true; do
        # Bracketed value is what Enter selects, as pacman and yay prompt.
        printf 'Select %s [1]: ' "${title,,}"
        if ! read -r reply; then
            # stdin ended, so take the default rather than spinning here.
            echo
            choice="${options[0]}"
            return 0
        fi
        reply="${reply//[[:space:]]/}"
        [[ -z "$reply" ]] && reply=1
        if [[ "$reply" =~ ^[0-9]+$ ]] && ((reply >= 1 && reply <= count)); then
            choice="${options[reply - 1]}"
            echo
            return 0
        fi
        echo "Not a choice. Select 1-$count, or Ctrl-C to quit." >&2
    done
}

printf 'CHECKOUT  %s\n' "$CLANKER_DIR"
printf 'BINARY    %s\n' "$CLANKER_BIN"
echo

model=""
if ! has_flag --model "$@"; then
    pick "CLANKER MODEL" \
        "Model for improve-self batches.
The clanker runs that repair them use Clanker's configured model." \
        default "no --model; the model in Clanker's configuration" \
        "${MODELS[@]}"
    model="$choice"
fi

escalate_model=""
if ! has_flag --escalate-model "$@"; then
    pick "ESCALATION MODEL" \
        "Model for the clanker escalation run, the second clanker run that
repairs a failed clanker repair run before the harness below is reached." \
        default "no --model; the same model the repair run just failed on" \
        "${ESCALATE_MODELS[@]}"
    escalate_model="$choice"
fi

fixer=""
if ! has_flag --fix-repairs-with "$@"; then
    pick "REPAIR HARNESS" \
        "Repairs the clanker escalation run above, when it fails too." \
        none "leave it failed; the next improve-self batch resurfaces the problem" \
        "${FIXERS[@]}"
    fixer="$choice"
fi

# Catch a missing harness now rather than hours into an unattended loop.
if [[ -n "$fixer" && "$fixer" != none ]] && ! command -v "${fixer%% *}" >/dev/null; then
    echo "error: repair harness not on PATH: ${fixer%% *}" >&2
    exit 2
fi

loop_args=(--clanker-dir "$CLANKER_DIR" --clanker "$CLANKER_BIN")
if [[ -n "$model" && "$model" != default ]]; then
    loop_args+=(--model "$model")
fi
if [[ -n "$escalate_model" && "$escalate_model" != default ]]; then
    loop_args+=(--escalate-model "$escalate_model")
fi
if [[ -n "$fixer" && "$fixer" != none ]]; then
    loop_args+=(--fix-repairs-with "$fixer")
fi

# %q so a multi-word harness shows as the single argument it actually is.
printf '==> %s' "${LOOP##*/}"
printf ' %q' "${loop_args[@]}" "$@"
printf '\n'
exec "$LOOP" "${loop_args[@]}" "$@"
