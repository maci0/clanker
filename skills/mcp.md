# Adding an MCP server integration

When asked to add/configure/remove an external MCP server ("add the
github MCP server"), edit `config.local.toml` (never `config.toml`) with
`edit_file`: append or update an `[mcp_servers.<name>]` table. stdio
shape: `transport = "stdio"`, `command = "..."`, optional `args`/`env`
(`"KEY=value"` strings)/`cwd`. http shape: `transport = "http"`,
`url = "https://..."`, optional `headers` (`"Name: value"` strings).
Optional `tool_call_timeout_ms` (default 60000). To remove, delete the
table. Config hot-reloads: a valid edit applies itself, an invalid one
is refused with the reason in the server log while the last good config
keeps running. Tell the operator the client bridge that actually
connects (`modules.mcp_client`) is not live yet — configuration now,
tools when it lands. The operator's own UI for this is System → MCP
servers.
