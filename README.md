# clanker

clanker is a self-improving AI agent harness written in Zig 0.16. It runs its tools as sandboxed WebAssembly modules via zwasm, and improves its own source code through a gated loop: the agent proposes an exact-match patch, applies it to a staging copy, verifies it with `zig build`, `zig build test`, `zig build tools`, `zig fmt`, and lint, and promotes it to the live tree only if all gates pass.

## Quick start

```sh
zig build          # build the clanker binary
zig build tools    # build the WASM tools
zig build test     # run the test suite
```

## Features

- **WASM tools** – sandboxed tool execution via zwasm with an explicit ABI
- **MCP server** – stdio JSON-RPC server exposing tools to MCP clients
- **Peer notifications + phonebook** – send messages to other clanker instances and list agent cards
- **A2A agent cards** – `.well-known/agent.json` discovery
- **`/goal`** – persistent structured goals steering agent runs
- **REPL with streaming** – interactive session with live token output
- **Token budget** – `compact_threshold_bytes` and `max_total_tokens` controls
- **Web UI** – internal WASM tool served at `GET /`

For full documentation, see [docs/README.md](docs/README.md).
# clanker

clanker is a self-improving AI agent harness written in Zig 0.16. It runs its tools as sandboxed WebAssembly modules via zwasm and improves its own source through a gated loop.

## Quick start

```sh
zig build          # build the clanker binary
zig build tools    # build the WASM tools
zig build test     # run the test suite
```

## Features

- WASM tools executed in a sandboxed zwasm runtime
- MCP server (stdio JSON-RPC)
- Peer notifications + phonebook
- A2A agent cards
- `/goal` command
- REPL with streaming
- Token budget (compact_threshold_bytes + max_total_tokens)
- Web UI served at `GET /`

See [docs/README.md](docs/README.md) for full documentation.
