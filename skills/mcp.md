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
  (`"Name: value"` strings; the value half carries a token, and the
  `config` tool / the web API list names only, never values)
- either: optional `tool_call_timeout_ms` (default 60000)

To remove, delete the table. Config hot-reloads: a valid edit applies
itself, an invalid one is refused while the last good config keeps
running. So check the edit landed with the `config` tool
(`{"action":"get","key":"mcp_servers.<name>"}`), which reads the merged
config: a refused table answers `no key 'mcp_servers.<name>' in the
merged config`. The server log carries the one-line reason, naming the
server and the field (`mcp_servers 'github': transport "stdio" requires
"command"`). Fix that field rather than rewriting the table.

Tell the operator the client bridge that actually connects
(`modules.mcp_client`) is not live yet: configuration now, tools when it
lands. Their own UI for this is System → MCP servers.
