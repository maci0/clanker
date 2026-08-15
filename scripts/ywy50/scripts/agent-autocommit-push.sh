#!/usr/bin/env bash
set -euo pipefail

# Default wait between passes (15 minutes). Overridable via --interval or
# AUTOCOMMIT_INTERVAL. Accepts human durations: 5s, 10m, 3h, 1d, or bare seconds.
DEFAULT_INTERVAL_SECONDS=900
DEFAULT_INTERVAL_DISPLAY="15m"

usage() {
	printf '%s\n' \
		"USAGE" \
		"  .local/scripts/agent-autocommit-push.sh [--once] [--interval DURATION] [--agent NAME]" \
		"" \
		"Run an agent every interval to commit and push all non-ignored work." \
		"" \
		"OPTIONS" \
		"  --agent NAME          Agent CLI to run: grok, codex, claude, or clanker." \
		"  --once                Run one agent pass and exit." \
		"  --interval DURATION   Wait time between passes. Default: ${DEFAULT_INTERVAL_DISPLAY} (${DEFAULT_INTERVAL_SECONDS}s)." \
		"                        Accepts Ns/Nm/Nh/Nd (e.g. 5s, 10m, 3h, 1d) or bare seconds." \
		"  -h, --help            Show this help." \
		"" \
		"WORKFLOW" \
		"  maci0/clanker is a direct-push repository: every agent commits" \
		"  path-scoped on the current branch and pushes it to origin. No" \
		"  branch, no pull request, no merge." \
		"  See .agents/agent-rules/maci0-clanker.md." \
		"" \
		"  Each pass mints a session id, claims it on the local board, runs the" \
		"  agent, then pushes anything the agent left unpushed." \
		"" \
		"ENVIRONMENT" \
		"  AUTOCOMMIT_AGENT            Same as --agent; skips the interactive prompt." \
		"  AUTOCOMMIT_INTERVAL         Same as --interval; skips the interactive prompt." \
		"  AUTOCOMMIT_AGENT_MODEL      Optional model passed as --model." \
		"  AUTOCOMMIT_AGENT_PROVIDER   Optional provider passed as --provider (clanker)." \
		"  CLANKER_BIN                 Path to the clanker binary (clanker only). Defaults" \
		"                              to 'clanker' on PATH, then <root>/zig-out/bin/clanker." \
		"" \
		"EXAMPLES" \
		"  .local/scripts/agent-autocommit-push.sh --once" \
		"  .local/scripts/agent-autocommit-push.sh --agent grok" \
		"  .local/scripts/agent-autocommit-push.sh --agent claude" \
		"  .local/scripts/agent-autocommit-push.sh --agent clanker" \
		"  .local/scripts/agent-autocommit-push.sh --interval 5m" \
		"  .local/scripts/agent-autocommit-push.sh --interval 300"
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

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	printf 'ERROR: %s is not inside a git work tree.\n' "$root" >&2
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
fi

log_dir="$root/.local/agent-autopush"
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
You are running as the repository's periodic commit-and-push agent.

This repository uses a direct-push workflow: work on the current branch, commit
path-scoped, and push to its upstream. Do not create a branch and do not open a
pull request.

Task:
1. Read the applicable AGENTS.md/CLAUDE.md instructions before acting.
2. Check for committed work that is not pushed and push it.
3. Check for uncommitted non-ignored work. If there is any, commit all of it as one commit:
   - Do not use git add -A, git add ., or git commit -a.
   - Stage explicit paths only, derived from git status --porcelain and git ls-files --others --exclude-standard.
   - Include tracked modifications and untracked non-ignored files.
   - Respect the repo's shared-agent rules. Treat TODO.md, docs/design.md, and docs/architecture.md as shared coordination files and stage the whole file when changed.
   - Do not revert, stash, delete, or rewrite another agent's changes.
   - Do not leave non-ignored work uncommitted just because it may be from another agent; this automation exists to preserve and publish shared work.
   - Ignore files that are ignored by Git, such as .local/ periodic-agent logs.
   - Use a commit message that describes only the change. Do not add attribution trailers or generated-by text.
4. Run a reasonable verification command when the changed files make one available and it is safe to run now. If verification is skipped, say why.
5. Push the committed work to the current branch's upstream. If your git tool refuses push, say so plainly and exit; the wrapper will push what you committed.

If there is nothing non-ignored to commit or push, report that plainly and exit successfully.
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

# Record this session on the hub task board (gitignored, never committed).
# Best-effort: create the board if absent, never duplicate the session line.
claim_on_board() {
	local session_id="$1"
	local board="$root/.local/TODO.md"
	mkdir -p "$root/.local"
	if [[ ! -f "$board" ]]; then
		cat >"$board" <<'EOF'
# Local agent task board (gitignored — do not commit)

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

# Every agent follows the maci0/clanker direct-push rule
# (.agents/agent-rules/maci0-clanker.md): new session id -> claim on hub board
# -> commit path-scoped on the current branch -> push it to origin. No branch,
# no PR, no merge. The agent pushes when its git tool allows it; the wrapper
# pushes whatever is left over.
run_pass() {
	local session_id branch rc ahead

	session_id="$("$root/.local/scripts/new-session-id.sh" "$agent")"
	printf '[%s] session: %s\n' "$(date -Is)" "$session_id"

	claim_on_board "$session_id"

	branch="$(git rev-parse --abbrev-ref HEAD)"
	if [[ "$branch" == "HEAD" ]]; then
		printf '[%s] ERROR: detached HEAD; refusing to run a direct-push pass.\n' "$(date -Is)" >&2
		return 1
	fi
	printf '[%s] committing directly on %s\n' "$(date -Is)" "$branch"

	rc=0
	run_agent_once || rc=$?

	if (( rc != 0 )); then
		printf '[%s] pass failed (exit %s); NOT pushing.\n' "$(date -Is)" "$rc" >&2
		return "$rc"
	fi

	if ! git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
		printf '[%s] %s has no upstream; pushing with -u to origin.\n' "$(date -Is)" "$branch"
		git push -u origin "$branch"
		return 0
	fi

	ahead="$(git rev-list --count '@{u}..HEAD')"
	if (( ahead == 0 )); then
		printf '[%s] nothing unpushed on %s.\n' "$(date -Is)" "$branch"
		return 0
	fi

	printf '[%s] pushing %s commit(s) from %s to origin\n' "$(date -Is)" "$ahead" "$branch"
	git push origin "$branch"
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
