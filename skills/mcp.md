---
title: Adding an MCP server integration
description: When asked to add, configure, or remove an external MCP server (`mcp_servers`, github MCP): edit `[mcp_servers.<name>]` in `config.local.toml`, never `config.toml`.
enabled: true
---

# Adding an MCP server integration

Edit `config.local.toml` (never `config.toml`) with `edit_file`: append or
update an `[mcp_servers.<name>]` table.

- stdio: `transport = "stdio"`, `command = "..."`, optional `args`, `env`
  (`"KEY=value"` strings), `cwd`
- http: `transport = "http"`, `url = "https://..."`, optional `headers`
  (`"Name: value"` strings; the value half carries a token, and
  `config_view` / the web API list names only, never values)
- either: optional `tool_call_timeout_ms` (default 60000)

To remove, delete the table. Config hot-reloads: a valid edit applies
itself, an invalid one is refused with the reason in the server log while
the last good config keeps running, so read that log before re-editing.

Tell the operator the client bridge that actually connects
(`modules.mcp_client`) is not live yet: configuration now, tools when it
lands. Their own UI for this is System → MCP servers.
