# CLI plugins

Two tiers, both local, resolved in order after the built-in `clanker`
commands (a built-in Command is never shadowed). See PRD 0012 ("Surface
Plugins", CLI half).

## Tier 1 — manifest, tool-backed, no new trust

One JSON file per command in this directory (config `agent.cli_plugins_dir`):

```json
{
  "command": "myreport",
  "description": "Summarize the last N runs",
  "tool": "my_report_tool"
}
```

`clanker myreport --since 7d` invokes `my_report_tool` non-interactively with
the remaining argv passed as `{"args":["--since","7d"]}` — the same `{"args":
[...]}` shape `chain`/`gh`/`git` tools take. No new trust surface: the plugin
can only name a tool the sandboxed WASM registry already trusts, and the tool
is resolved against whatever `agent.tools_dir` names.

## Tier 2 — external binary, operator-trusted

If no Tier 1 manifest matches, `clanker` looks for `clanker-<name>` on `PATH`
and under `~/.clanker/plugins/` and execs it with the remaining argv,
inheriting stdio. This is real code execution with no sandbox — the same
trust an operator already extends to anything else they put on their own
PATH (git/cargo/kubectl-style external subcommands).

## Enabling

Presence on disk is not consent to run. A plugin must be enabled in the
`state/cli_plugins.json` enabled-list (default off):

```json
{ "enabled": ["myreport"] }
```

`clanker help` lists both tiers, marked external with their origin.
