# TUI slash-command plugins

One JSON file per command. The REPL scans this directory (config
`agent.tui_plugins_dir`) at startup and appends one slash command per
**enabled** manifest to the built-in command set — so /help, Tab-complete,
Ctrl-P and dispatch all see a plugin command exactly like a built-in one.
See PRD 0012 ("Surface Plugins", TUI half).

## Manifest

```json
{
  "command": "myreport",
  "help": "Summarize the last N runs",
  "tool": "my_report_tool",
  "args": ""
}
```

- `command` — the slash command, without the leading slash ("myreport" → /myreport).
- `help` — one line shown in /help.
- `tool` — the sandboxed WASM tool the command dispatches to.
- `args` (optional) — fixed arguments passed when the user types none; the
  user's own arguments are forwarded when typed.

## Trust model

No new trust surface: a plugin can only name a tool the sandboxed WASM tool
registry already trusts. The manifest cannot embed code, exec anything, or
grant itself filesystem/network access beyond what the named tool's own
descriptor already grants.

## Enabling

Presence on disk is not consent to run. Toggle a plugin in the REPL:

```
/tui-plugins            list plugins with their on/off state
/tui-plugins on <name>  enable
/tui-plugins off <name> disable
```

State lives in `state/tui_plugins.json` (`{"enabled": [...]}`, default off),
the same enabled-list shape as `state/webui_plugins.json`.
