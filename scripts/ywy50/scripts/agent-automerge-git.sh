#!/usr/bin/env bash
set -euo pipefail

# Default wait between passes (15 minutes). Overridable via --interval or
# AUTOCOMMIT_INTERVAL. Accepts human durations: 5s, 10m, 3h, 1d, or bare seconds.
DEFAULT_INTERVAL_SECONDS=900
DEFAULT_INTERVAL_DISPLAY="15m"

# Paths the pass depends on. A relative value is resolved against the repo
# root; an absolute value is used as given. Override with the matching flag
# or environment variable.
DEFAULT_BOARD="scripts/ywy50/TODO.md"
DEFAULT_SESSION_ID_SCRIPT="scripts/ywy50/scripts/new-session-id.sh"
DEFAULT_LOG_DIR=".local/agent-automerge"

usage() {
	printf '%s\n' \
		"USAGE" \
		"  .local/scripts/agent-automerge-git.sh [--once] [--interval DURATION] [--agent NAME]" \
		"" \
		"Run an agent every interval to commit and publish all non-ignored work." \
		"" \
		"OPTIONS" \
		"  --agent NAME          Agent CLI to run: grok, codex, claude, or clanker." \
		"  --once                Run one agent pass and exit." \
		"  --interval DURATION   Wait time between passes. Default: ${DEFAULT_INTERVAL_DISPLAY} (${DEFAULT_INTERVAL_SECONDS}s)." \
		"                        Accepts Ns/Nm/Nh/Nd (e.g. 5s, 10m, 3h, 1d) or bare seconds." \
		"  --board PATH          Task board to claim the session on." \
		"  --session-id-script PATH" \
		"                        Script that mints the session id." \
		"  --log-dir PATH        Directory for per-pass agent logs." \
		"  -h, --help            Show this help." \
		"" \
		"PATHS" \
		"  A relative path is resolved against the repo root." \
		"" \
		"  board               ${DEFAULT_BOARD}" \
		"  session id script   ${DEFAULT_SESSION_ID_SCRIPT}" \
		"  log dir             ${DEFAULT_LOG_DIR}" \
		"" \
		"WORKFLOW (maci0/clanker)" \
		"  Every agent follows the .agents/AGENTS.md lifecycle. Nothing is ever" \
		"  pushed to a default branch directly. Each pass:" \
		"    new session id -> claim on hub board -> branch off HEAD ->" \
		"    agent commits path-scoped -> push branch -> open PR against the base" \
		"    branch -> merge -> return to base and drop the branch." \
		"  The agent only commits; the wrapper owns push, PR, and merge. Requires" \
		"  the 'gh' CLI, and for --agent clanker the clanker binary (CLANKER_BIN)." \
		"  Existing dirty work cannot move into a fresh origin/main worktree (it is" \
		"  not there), so the sweep branches in place; that is the one deviation," \
		"  and it still never publishes the default branch directly." \
		"" \
		"ENVIRONMENT" \
		"  AUTOCOMMIT_AGENT            Same as --agent; skips the interactive prompt." \
		"  AUTOCOMMIT_INTERVAL         Same as --interval; skips the interactive prompt." \
		"  AUTOCOMMIT_BOARD            Same as --board." \
		"  AUTOCOMMIT_SESSION_ID_SCRIPT" \
		"                              Same as --session-id-script." \
		"  AUTOCOMMIT_LOG_DIR          Same as --log-dir." \
		"  AUTOCOMMIT_AGENT_MODEL      Optional model passed as --model." \
		"  AUTOCOMMIT_AGENT_PROVIDER   Optional provider passed as --provider (clanker)." \
		"  CLANKER_BIN                 Path to the clanker binary (clanker only). Defaults" \
		"                              to 'clanker' on PATH, then <root>/zig-out/bin/clanker." \
		"" \
		"EXAMPLES" \
		"  .local/scripts/agent-automerge-git.sh --once" \
		"  .local/scripts/agent-automerge-git.sh --agent grok" \
		"  .local/scripts/agent-automerge-git.sh --agent claude" \
		"  .local/scripts/agent-automerge-git.sh --agent clanker" \
		"  .local/scripts/agent-automerge-git.sh --interval 5m" \
		"  .local/scripts/agent-automerge-git.sh --interval 300"
}

# Parse a duration string into whole seconds.
# Accepts: bare positive integers (seconds), or integer + unit: s/m/h/d
# (case-insensitive). Examples: 90, 5s, 10m, 3h, 1d.
# Prints seconds on stdout; returns non-zero on invalid input.
parse_duration() {
	local raw="$1"
	local value unit seconds

	if [[ -z "$raw" ]]; then
		return 1
	fi

	if [[ "$raw" =~ ^([0-9]+)$ ]]; then
		seconds="${BASH_REMATCH[1]}"
	elif [[ "$raw" =~ ^([0-9]+)([smhdSMHD])$ ]]; then
		value="${BASH_REMATCH[1]}"
		unit="${BASH_REMATCH[2],,}"
		case "$unit" in
			s) seconds="$value" ;;
			m) seconds=$((value * 60)) ;;
			h) seconds=$((value * 3600)) ;;
			d) seconds=$((value * 86400)) ;;
			*) return 1 ;;
		esac
	else
		return 1
	fi

	if [[ "$seconds" -lt 1 ]]; then
		return 1
	fi

	printf '%s\n' "$seconds"
}

# Prefer a compact human unit when the value divides evenly; else Ns.
format_duration() {
	local seconds="$1"
	if (( seconds % 86400 == 0 )); then
		printf '%sd\n' "$((seconds / 86400))"
	elif (( seconds % 3600 == 0 )); then
		printf '%sh\n' "$((seconds / 3600))"
	elif (( seconds % 60 == 0 )); then
		printf '%sm\n' "$((seconds / 60))"
	else
		printf '%ss\n' "$seconds"
	fi
}

interval="$DEFAULT_INTERVAL_SECONDS"
interval_set=false
once=false
agent="${AUTOCOMMIT_AGENT:-}"
board="${AUTOCOMMIT_BOARD:-$DEFAULT_BOARD}"
session_id_script="${AUTOCOMMIT_SESSION_ID_SCRIPT:-$DEFAULT_SESSION_ID_SCRIPT}"
log_dir="${AUTOCOMMIT_LOG_DIR:-$DEFAULT_LOG_DIR}"

if [[ -n "${AUTOCOMMIT_INTERVAL:-}" ]]; then
	if ! interval="$(parse_duration "$AUTOCOMMIT_INTERVAL")"; then
		printf 'ERROR: AUTOCOMMIT_INTERVAL must be a positive duration (e.g. 5s, 10m, 3h, 1d, or bare seconds).\n' >&2
		exit 2
	fi
	interval_set=true
fi

while [[ $# -gt 0 ]]; do
	case "$1" in
		--agent)
			if [[ $# -lt 2 ]]; then
				printf 'ERROR: --agent requires grok, codex, claude, or clanker.\n' >&2
				exit 2
			fi
			agent="$2"
			shift 2
			;;
		--once)
			once=true
			shift
			;;
		--interval)
			if [[ $# -lt 2 ]]; then
				printf 'ERROR: --interval requires a duration (e.g. 5s, 10m, 3h, 1d, or bare seconds).\n' >&2
				exit 2
			fi
			if ! interval="$(parse_duration "$2")"; then
				printf 'ERROR: --interval requires a positive duration (e.g. 5s, 10m, 3h, 1d, or bare seconds).\n' >&2
				exit 2
			fi
			interval_set=true
			shift 2
			;;
		--board)
			if [[ $# -lt 2 ]]; then
				printf 'ERROR: --board requires a path.\n' >&2
				exit 2
			fi
			board="$2"
			shift 2
			;;
		--session-id-script)
			if [[ $# -lt 2 ]]; then
				printf 'ERROR: --session-id-script requires a path.\n' >&2
				exit 2
			fi
			session_id_script="$2"
			shift 2
			;;
		--log-dir)
			if [[ $# -lt 2 ]]; then
				printf 'ERROR: --log-dir requires a path.\n' >&2
				exit 2
			fi
			log_dir="$2"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			printf 'ERROR: unknown argument: %s\n\n' "$1" >&2
			usage >&2
			exit 2
			;;
	esac
done

ask_for_agent() {
	if [[ ! -t 0 ]]; then
		printf 'ERROR: choose an agent with --agent or AUTOCOMMIT_AGENT when stdin is not interactive.\n' >&2
		exit 2
	fi

	local choice
	while true; do
		printf '%s\n' \
			"Select agent:" \
			"  1  grok" \
			"  2  codex" \
			"  3  claude" \
			"  4  clanker"
		printf 'Agent [1-4]: '
		read -r choice
		case "$choice" in
			1|grok)
				agent="grok"
				return
				;;
			2|codex)
				agent="codex"
				return
				;;
			3|claude)
				agent="claude"
				return
				;;
			4|clanker)
				agent="clanker"
				return
				;;
			*)
				printf 'ERROR: enter 1, 2, 3, 4, grok, codex, claude, or clanker.\n' >&2
				;;
		esac
	done
}

ask_for_interval() {
	if [[ ! -t 0 ]]; then
		# Non-interactive: keep the configured/default interval.
		return
	fi

	local default_display reply parsed
	default_display="$(format_duration "$interval")"

	while true; do
		printf 'Interval [%s]: ' "$default_display"
		read -r reply
		if [[ -z "$reply" ]]; then
			return
		fi
		if parsed="$(parse_duration "$reply")"; then
			interval="$parsed"
			return
		fi
		printf 'ERROR: enter a positive duration (e.g. 5s, 10m, 3h, 1d, or bare seconds).\n' >&2
	done
}

if [[ -z "$agent" ]]; then
	ask_for_agent
fi

# Interval only matters for the loop; skip the prompt for one-shot runs.
if [[ "$once" != true && "$interval_set" != true ]]; then
	ask_for_interval
fi

case "$agent" in
	grok|codex|claude|clanker)
		;;
	*)
		printf 'ERROR: --agent must be grok, codex, claude, or clanker.\n' >&2
		exit 2
		;;
esac

# clanker's binary is resolved relative to the repo root (zig-out/bin), so
# check it after root is known, below. Non-clanker agents come off PATH.
if [[ "$agent" != "clanker" ]] && ! command -v "$agent" >/dev/null 2>&1; then
	printf 'ERROR: selected agent CLI not found on PATH: %s\n' "$agent" >&2
	exit 1
fi

# The repo root is the work tree holding this script, not a fixed number of
# parent directories: the script is reachable both at its real path and
# through the .local/scripts symlink, which sit at different depths.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! root="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)" || [[ -z "$root" ]]; then
	printf 'ERROR: %s is not inside a git work tree.\n' "$script_dir" >&2
	exit 1
fi
cd "$root"

# Relative path -> repo root; absolute path -> as given.
resolve_path() {
	case "$1" in
		/*) printf '%s\n' "$1" ;;
		*) printf '%s\n' "$root/$1" ;;
	esac
}

board="$(resolve_path "$board")"
session_id_script="$(resolve_path "$session_id_script")"
log_dir="$(resolve_path "$log_dir")"

if [[ ! -x "$session_id_script" ]]; then
	printf 'ERROR: session id script not executable: %s\n' "$session_id_script" >&2
	exit 1
fi

# Locate the clanker binary: CLANKER_BIN, then 'clanker' on PATH, then a local build.
resolve_clanker_bin() {
	local candidate
	if [[ -n "${CLANKER_BIN:-}" ]]; then
		candidate="$CLANKER_BIN"
		if [[ "$candidate" != /* && -x "$root/$candidate" ]]; then
			candidate="$root/$candidate"
		fi
		if [[ -x "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
		printf 'ERROR: CLANKER_BIN not executable: %s\n' "$CLANKER_BIN" >&2
		return 1
	fi
	if candidate="$(command -v clanker 2>/dev/null)" && [[ -n "$candidate" && -x "$candidate" ]]; then
		printf '%s\n' "$candidate"
		return 0
	fi
	if [[ -x "$root/zig-out/bin/clanker" ]]; then
		printf '%s\n' "$root/zig-out/bin/clanker"
		return 0
	fi
	printf 'ERROR: clanker not found on PATH and %s/zig-out/bin/clanker is missing.\n' "$root" >&2
	printf '       Build with: zig build\n' >&2
	printf '       Or: CLANKER_BIN=/path/to/clanker %s\n' "$(basename "${BASH_SOURCE[0]}")" >&2
	return 1
}

clanker_bin=""
if [[ "$agent" == "clanker" ]]; then
	clanker_bin="$(resolve_clanker_bin)"
	if ! command -v gh >/dev/null 2>&1; then
		printf 'ERROR: --agent clanker requires the GitHub CLI (gh) to open and merge pull requests.\n' >&2
		exit 1
	fi
fi

# Every agent publishes via PR, so the GitHub CLI is required for all of them.
if ! command -v gh >/dev/null 2>&1; then
	printf 'ERROR: the GitHub CLI (gh) is required to open and merge pull requests for any agent.\n' >&2
	exit 1
fi

mkdir -p "$log_dir"

build_agent_command() {
	local -n out=$1
	local prompt=$2

	case "$agent" in
		grok)
			out=(grok --cwd "$root" --permission-mode bypassPermissions -p)
			if [[ -n "${AUTOCOMMIT_AGENT_MODEL:-}" ]]; then
				out+=(--model "$AUTOCOMMIT_AGENT_MODEL")
			fi
			out+=("$prompt")
			;;
		codex)
			out=(codex exec --cd "$root" --dangerously-bypass-approvals-and-sandbox --ignore-rules)
			if [[ -n "${AUTOCOMMIT_AGENT_MODEL:-}" ]]; then
				out+=(--model "$AUTOCOMMIT_AGENT_MODEL")
			fi
			out+=("$prompt")
			;;
		claude)
			out=(claude --print --permission-mode bypassPermissions)
			if [[ -n "${AUTOCOMMIT_AGENT_MODEL:-}" ]]; then
				out+=(--model "$AUTOCOMMIT_AGENT_MODEL")
			fi
			out+=("$prompt")
			;;
		clanker)
			out=("$clanker_bin" run)
			if [[ -n "${AUTOCOMMIT_AGENT_MODEL:-}" ]]; then
				out+=(--model "$AUTOCOMMIT_AGENT_MODEL")
			fi
			if [[ -n "${AUTOCOMMIT_AGENT_PROVIDER:-}" ]]; then
				out+=(--provider "$AUTOCOMMIT_AGENT_PROVIDER")
			fi
			out+=("$prompt")
			;;
	esac
}

run_agent_once() {
	local started log_file
	started="$(date +%Y%m%d-%H%M%S)"
	log_file="$log_dir/$started.log"

	{
		printf '== %s ==\n' "$(date -Is)"
		printf 'repo: %s\n' "$root"
		printf 'agent: %s\n\n' "$agent"
	} >>"$log_file"

	printf '[%s] starting %s agent pass\n' "$(date -Is)" "$agent"
	printf '[%s] log: %s\n' "$(date -Is)" "$log_file"
	printf '[%s] watch: tail -f %q\n' "$(date -Is)" "$log_file"

	local prompt
	prompt="$(cat <<PROMPT
You are running as the repository's periodic commit-and-publish agent.

Task:
1. Read the applicable AGENTS.md/CLAUDE.md instructions before acting.
2. Check for uncommitted non-ignored work. If there is any, commit all of it:
   - Do not use git add -A, git add ., or git commit -a.
   - Stage explicit paths only, derived from git status --porcelain and git ls-files --others --exclude-standard.
   - Include tracked modifications and untracked non-ignored files.
   - Respect the repo's shared-agent rules. Treat TODO.md, docs/design.md, and docs/architecture.md as shared coordination files and stage the whole file when changed.
   - Do not revert, stash, delete, or rewrite another agent's changes.
   - Do not leave non-ignored work uncommitted just because it may be from another agent; this automation exists to preserve and publish shared work.
   - Ignore files that are ignored by Git, such as .local/ periodic-agent logs.
   - Use a commit message that describes only the change. Do not add attribution trailers or generated-by text.
3. Run a reasonable verification command when the changed files make one available and it is safe to run now. If verification is skipped, say why.
4. Do NOT push. This repository's workflow publishes every change through a pull request (branch -> push -> PR -> merge), and the wrapper handles push, PR, and merge for you. Commit path-scoped and exit; do not push, and do not touch the default branch.

If there is nothing non-ignored to commit, report that plainly and exit successfully.
PROMPT
)"

	local cmd
	build_agent_command cmd "$prompt"

	if "${cmd[@]}" >>"$log_file" 2>&1; then
		printf '[%s] agent pass completed: %s\n' "$(date -Is)" "$log_file"
		printf '[%s] final git status:\n' "$(date -Is)"
		git status --short --branch
	else
		local status=$?
		printf '[%s] agent pass failed with exit %s: %s\n' "$(date -Is)" "$status" "$log_file" >&2
		printf '[%s] final git status:\n' "$(date -Is)" >&2
		git status --short --branch >&2
		return "$status"
	fi
}

# Record this session on the hub task board ($board).
# Best-effort: create the board if absent, never duplicate the session line.
claim_on_board() {
	local session_id="$1"
	mkdir -p "$(dirname "$board")"
	if [[ ! -f "$board" ]]; then
		cat >"$board" <<'EOF'
# Local agent task board

Markers: `[ ]` open · `[-]` in progress · `[x]` done

## Active

## Backlog

## Done
EOF
	fi
	if grep -qF "session: ${session_id}" "$board" 2>/dev/null; then
		return 0
	fi
	printf '%s\n' "[-] Auto-commit-and-push pass — in progress — ${agent}, $(date -u +%Y-%m-%d); session: ${session_id}" >>"$board"
}

# Every agent follows the maci0/clanker AGENTS.md lifecycle: new session id
# -> claim on hub board -> branch off HEAD -> agent commits path-scoped ->
# push the branch -> open a PR against the base branch -> merge -> return to
# the base and drop the branch. The agent never pushes (its own sandbox, and
# the repo rule, forbid direct default-branch pushes); the wrapper owns
# push/PR/merge. The default branch is never published directly.
run_publish_pass() {
	local session_id base_branch branch rc ahead pr_title pr_url

	session_id="$("$session_id_script" "$agent")"
	printf '[%s] session: %s\n' "$(date -Is)" "$session_id"

	claim_on_board "$session_id"

	base_branch="$(git rev-parse --abbrev-ref HEAD)"
	branch="agent/${session_id}/autopush"
	printf '[%s] branching off %s -> %s\n' "$(date -Is)" "$base_branch" "$branch"
	git checkout -b "$branch"

	rc=0
	run_agent_once || rc=$?

	if (( rc != 0 )); then
		printf '[%s] pass failed (exit %s); keeping local branch %s for inspection, NOT publishing.\n' "$(date -Is)" "$rc" "$branch" >&2
		git checkout "$base_branch"
		return "$rc"
	fi

	ahead="$(git rev-list --count "$base_branch..$branch")"
	if (( ahead == 0 )); then
		printf '[%s] no new commits on %s; nothing to publish. Dropping branch.\n' "$(date -Is)" "$branch"
		git checkout "$base_branch"
		git branch -d "$branch"
		return 0
	fi

	printf '[%s] publishing %s via PR against %s\n' "$(date -Is)" "$branch" "$base_branch"
	git push -u origin "$branch"

	pr_title="autopush: $(git log --reverse --format=%s "$base_branch..$branch" | head -n1)"
	pr_title="${pr_title:-autopush: ${session_id}}"

	pr_url="$(gh pr create \
		--base "$base_branch" \
		--head "$branch" \
		--title "$pr_title" \
		--body "Automated commit-and-push pass for session ${session_id} against ${base_branch}.")"
	printf '[%s] PR: %s\n' "$(date -Is)" "$pr_url"

	gh pr merge "$branch" --merge --delete-branch=false

	printf '[%s] PR merged; returning to %s\n' "$(date -Is)" "$base_branch"
	git checkout "$base_branch"
	git branch -d "$branch"
}

run_pass() {
	run_publish_pass
}

run_with_lock() {
	local lock_dir="$log_dir/run.lock"
	if mkdir "$lock_dir" 2>/dev/null; then
		trap 'rmdir "$lock_dir"' RETURN
		run_pass
		trap - RETURN
		rmdir "$lock_dir"
	else
		printf '[%s] previous agent pass is still running; skipping this interval.\n' "$(date -Is)" >&2
	fi
}

if [[ "$once" == true ]]; then
	printf '[%s] mode: once (agent=%s)\n' "$(date -Is)" "$agent"
else
	printf '[%s] mode: loop every %s (%ss) (agent=%s)\n' \
		"$(date -Is)" "$(format_duration "$interval")" "$interval" "$agent"
fi

while true; do
	run_with_lock || true
	if [[ "$once" == true ]]; then
		break
	fi
	printf '[%s] sleeping %s until next pass\n' "$(date -Is)" "$(format_duration "$interval")"
	sleep "$interval"
done
