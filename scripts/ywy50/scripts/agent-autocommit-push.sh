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
		"  --agent NAME          Agent CLI to run: grok, codex, claude, clanker, or dsh." \
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
		"  AUTOCOMMIT_AGENT_MODEL      Optional model passed as --model (ignored by dsh;" \
		"                              the headless run uses the harness default model)." \
		"  AUTOCOMMIT_AGENT_PROVIDER   Optional provider passed as --provider (clanker)." \
		"  CLANKER_BIN                 Path to the clanker binary (clanker only). Defaults" \
		"                              to 'clanker' on PATH, then <root>/zig-out/bin/clanker." \
		"  DSH_BIN                     Path to the dsh launcher (dsh only). Defaults to" \
		"                              'dsh' on PATH." \
		"" \
		"EXAMPLES" \
		"  .local/scripts/agent-autocommit-push.sh --once" \
		"  .local/scripts/agent-autocommit-push.sh --agent grok" \
		"  .local/scripts/agent-autocommit-push.sh --agent claude" \
		"  .local/scripts/agent-autocommit-push.sh --agent clanker" \
		"  .local/scripts/agent-autocommit-push.sh --agent dsh" \
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
				printf 'ERROR: --agent requires grok, codex, claude, clanker, or dsh.\n' >&2
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
			"  4  clanker" \
			"  5  dsh"
		printf 'Agent [1-5]: '
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
			5|dsh)
				agent="dsh"
				return
				;;
			*)
				printf 'ERROR: enter 1-5, grok, codex, claude, clanker, or dsh.\n' >&2
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
	grok|codex|claude|clanker|dsh)
		;;
	*)
		printf 'ERROR: --agent must be grok, codex, claude, clanker, or dsh.\n' >&2
		exit 2
		;;
esac

# clanker's and dsh's launchers are resolved separately below (relative to the
# repo root, with env overrides). Other agents come off PATH.
if [[ "$agent" != "clanker" && "$agent" != "dsh" ]] && ! command -v "$agent" >/dev/null 2>&1; then
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

# Locate the dsh launcher: DSH_BIN, then 'dsh' on PATH.
resolve_dsh_bin() {
	local candidate
	if [[ -n "${DSH_BIN:-}" ]]; then
		candidate="$DSH_BIN"
		if [[ "$candidate" != /* && -x "$root/$candidate" ]]; then
			candidate="$root/$candidate"
		fi
		if [[ -x "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
		printf 'ERROR: DSH_BIN not executable: %s\n' "$DSH_BIN" >&2
		return 1
	fi
	if candidate="$(command -v dsh 2>/dev/null)" && [[ -n "$candidate" && -x "$candidate" ]]; then
		printf '%s\n' "$candidate"
		return 0
	fi
	printf 'ERROR: dsh not found on PATH.\n' >&2
	printf '       Or: DSH_BIN=/path/to/dsh %s\n' "$(basename "${BASH_SOURCE[0]}")" >&2
	return 1
}

dsh_bin=""
if [[ "$agent" == "dsh" ]]; then
	dsh_bin="$(resolve_dsh_bin)"
	if [[ -n "${AUTOCOMMIT_AGENT_MODEL:-}" ]]; then
		printf 'WARNING: AUTOCOMMIT_AGENT_MODEL is ignored by dsh; the headless run uses the harness default model.\n' >&2
	fi
fi

# Streaming claude's log needs jq to render the JSON events. Without jq, fall
# back to plain --print: buffered, but still readable when the pass ends.
claude_streaming=false
if [[ "$agent" == "claude" ]]; then
	if command -v jq >/dev/null 2>&1; then
		claude_streaming=true
	else
		printf 'WARNING: jq not found; claude output will only appear when the pass ends.\n' >&2
	fi
fi

log_dir="$root/.local/agent-autopush"
mkdir -p "$log_dir"

# claude only streams under --output-format stream-json, which is JSON lines.
# Render them back to readable prose as they arrive: assistant text verbatim,
# one line per tool call, and the final result block. Unparsable lines are
# dropped rather than killing the pipe.
render_claude_stream() {
	jq --unbuffered -Rr '
		(fromjson? // empty) as $e
		| if $e.type == "assistant" then
			($e.message.content[]? |
				if .type == "text" then
					(.text | select(. != ""))
				elif .type == "tool_use" then
					(((.input // {}) | tostring) as $i
					 | "→ " + .name + " "
					   + (if ($i | length) > 160 then $i[0:160] + "…" else $i end))
				else empty end)
		  elif $e.type == "result" then
			"\n── result: " + ($e.subtype // "?")
			+ " (" + ((($e.duration_ms // 0) / 1000) | floor | tostring) + "s) ──\n"
			+ ($e.result // "")
		  else empty end
	'
}

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
			# Plain --print buffers the whole run and writes it on exit, so
			# tail -f shows nothing until the pass ends. stream-json emits an
			# event per turn; render_claude_stream turns it back into prose.
			if [[ "$claude_streaming" == true ]]; then
				out+=(--verbose --output-format stream-json)
			fi
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
		dsh)
			# dsh headless is one-shot: the task is the positional argument,
			# the agent's workspace is the launch cwd (already $root), the
			# final assistant message goes to stdout, and the exit code is 0
			# when the turn completes, non-zero otherwise. The model comes
			# from the harness default (agent-default-model settings); the
			# headless app takes no --model/--provider flags.
			out=("$dsh_bin" --profile headless)
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
You are the repository's periodic commit-and-push agent. Do these four steps and
nothing else:

1. List what changed:
   git status --porcelain
   git ls-files --others --exclude-standard
   git diff --stat
2. Stage every non-ignored path from step 1 by explicit path: git add -- PATH ...
   Never git add -A, git add ., or git commit -a. Include modifications,
   deletions, and untracked files, whoever made them.
3. Commit once. Write the message by summarizing the file changes from step 1 --
   which files changed and what each change is about, judging from the paths and
   the diffstat. Describe only the change; no attribution or generated-by text.
4. Push the current branch to its upstream. Also push any earlier commits that
   were never pushed. If your git tool refuses push, say so and exit; the
   wrapper will push what you committed.

Do NOT do anything else. No builds, tests, linters, or gates. No reading,
reviewing, fixing, or improving code. No inspecting other agents. No branches,
no pull requests. Never revert, stash, or delete another agent's work.

If nothing is uncommitted and nothing is unpushed, say so and exit successfully.
Final message: a few lines at most -- what you committed, and whether it pushed.
PROMPT
)"

	local cmd
	build_agent_command cmd "$prompt"

	# pipefail is set, so the pipeline reports the agent's failure, not jq's.
	local status=0
	if [[ "$claude_streaming" == true ]]; then
		"${cmd[@]}" 2>>"$log_file" | render_claude_stream >>"$log_file" || status=$?
	else
		"${cmd[@]}" >>"$log_file" 2>&1 || status=$?
	fi

	if (( status == 0 )); then
		printf '[%s] agent pass completed: %s\n' "$(date -Is)" "$log_file"
		printf '[%s] final git status:\n' "$(date -Is)"
		git status --short --branch
	else
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
