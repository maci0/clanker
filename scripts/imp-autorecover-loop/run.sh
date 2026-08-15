#!/bin/bash
# Select the improve-self model and the harness that repairs a failed clanker
# repair run, resolve the Clanker checkout and binary, then run the loop.
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
)

# Harnesses that repair a failed clanker repair run. Clanker repair runs fix
# improve-self; these fix the clanker repair runs. The literal "none" skips that
# level entirely.
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

Select the model improve-self batches run on, and the harness that repairs a
failed clanker repair run, then exec loop.py with the checkout and
binary already resolved. Every argument is passed straight through to the loop,
and passing --model or --fix-repairs-with yourself skips the matching menu.

ENVIRONMENT
  CLANKER_DIR  Clanker checkout to improve  (default: /home/yannick/code/maci0/clanker)
  CLANKER_BIN  clanker executable           (default: clanker on PATH, falling
                                             back to $CLANKER_DIR/zig-out/bin/clanker)

EXAMPLES
  run.sh                                      select from both menus, then run
  run.sh --iters 5 "improve the clanker tui"  pass options to the loop
  run.sh --fix-repairs-with "codex exec"      skip the harness menu
  CLANKER_DIR=~/src/clanker run.sh            drive another checkout

Edit the MODELS and FIXERS arrays at the top of this file to change the menus.
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

fixer=""
if ! has_flag --fix-repairs-with "$@"; then
    pick "REPAIR HARNESS" \
        "Repairs the clanker run that repairs improve-self, when it fails." \
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
if [[ -n "$fixer" && "$fixer" != none ]]; then
    loop_args+=(--fix-repairs-with "$fixer")
fi

# %q so a multi-word harness shows as the single argument it actually is.
printf '==> %s' "${LOOP##*/}"
printf ' %q' "${loop_args[@]}" "$@"
printf '\n'
exec "$LOOP" "${loop_args[@]}" "$@"
