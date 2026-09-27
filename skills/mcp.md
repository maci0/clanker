---
title: Adding an MCP server integration
description: When asked to add, connect, configure, inspect or remove an external MCP server (`mcp_servers`, github MCP): the table is operator-owned, so hand over the TOML instead of editing it.
enabled: true
---

# Adding an MCP server integration

`[mcp_servers.<name>]` is a table, and no tool an agent can call writes one:
`config set` refuses the section ("a table of dynamic keys; edit
config.local.toml by hand") and `edit_file` has no `fs_prefixes` grant on
either config file, so the call is refused as outside the sandbox. Do not
spend the turn trying. Hand the operator a block to paste into
`config.local.toml` (never `config.toml`, which is committed), and say which
file it goes in.

- stdio: `transport = "stdio"`, `command = "..."`, optional `args`, `env`
  (`"KEY=value"` strings), `cwd`
- http: `transport = "http"`, `url = "https://..."`, optional `headers`
  (`"Name: value"` strings; the value half carries a token, and the
  `config` tool / the web API list names only, never values)
- either: optional `tool_call_timeout_ms` (default 60000)

To remove, delete the table. The operator can also add, edit and remove
stanzas in System → MCP servers in the web UI.

A stanza that fails validation fails the whole config load, and the log
carries the one-line reason naming the server and the field
(`mcp_servers 'github': transport "stdio" requires "command"`). Fix that
field rather than rewriting the table.

Apply timing: a `serve` watches the config files, so a good edit lands on
its own and a bad one leaves the last good config serving; a `run` or the
REPL keeps the config it loaded, and a later start on a bad file refuses.
Check the table landed with the `config` tool
(`{"action":"get","key":"mcp_servers.<name>"}`), which reads the merged
config and answers `no key 'mcp_servers.<name>' in the merged config` for a
stanza that is not in it.

Tell the operator the client bridge that actually connects
(`modules.mcp_client`) is not live yet: configuration now, tools when it
lands.
