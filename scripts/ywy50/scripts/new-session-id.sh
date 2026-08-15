#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'HELP'
Generate a unique ID for one agent session.

USAGE
  new-session-id.sh PREFIX

PREFIX
  Lowercase agent-family name, such as codex, claude, grok, or clanker.

OUTPUT
  PREFIX-UTC_TIMESTAMP-RANDOM_SUFFIX

The ID identifies an execution session. It does not claim a TODO item; the
TODO item's [-] marker remains the ownership signal.
HELP
}

if (($# != 1)); then
	usage >&2
	exit 2
fi

prefix="$1"
if [[ ! "$prefix" =~ ^[a-z][a-z0-9]*$ ]]; then
	printf 'ERROR: PREFIX must start with a lowercase letter and contain only lowercase letters and digits.\n' >&2
	exit 2
fi

timestamp="$(date -u +%Y%m%d-%H%M%S)"
suffix="$(od -vAn -N6 -tx1 /dev/urandom | tr -d '[:space:]')"
printf '%s-%s-%s\n' "$prefix" "$timestamp" "$suffix"
