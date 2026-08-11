# clanker — project conventions

clanker is a self-improving AI agent harness written in **Zig 0.16.0**. It runs
its tools as sandboxed WebAssembly modules (zwasm) and improves its own source
through a gated loop. Follow these conventions when changing this codebase.

## Build & test

- `zig build` — build the `clanker` harness for the host (musl ABI on linux).
  Cross-compile with `-Dtarget=`, e.g. `-Dtarget=x86_64-linux-musl`.
- `zig build tools` — compile `tools/zig/*.zig` to `zig-out/tools/*.wasm`.
- `zig build test` — run unit + integration tests. All tests must pass before
  any change is accepted. Tests live in `test` blocks inside the source files;
  new files must be referenced from the `comptime` block in `src/main.zig`.

## Zig style

- Target Zig 0.16 APIs: `std.Io` (Dir/File/Threaded), `std.process.Init`,
  `std.json.Stringify` + `parseFromSliceLeaky`, `std.ArrayList` with
  `.empty` + `append(alloc, ...)`.
- No libc-dependent code in the harness beyond what the build links.
- Allocators are explicit; arena for run-scoped data, gpa for ownership.
- New code must be `zig fmt` clean (the improve gate auto-formats and checks).

## Architecture

- `src/llm/` — provider adapters (openai_compat, anthropic) + HTTP client.
- `src/sandbox/` — zwasm runtime wrapper + `ck_*` host functions + policy.
- `src/agent/` — the agent loop, system prompt assembly, session store,
  execution graphs, sub-agents, autolearn.
- `src/mcp/`, `src/peers/`, `src/util/` — MCP server, peer chatrooms/todos,
  logging and dotenv. Peer notify/phonebook and patch application moved to
  the sandboxed `peers` and `patch_apply` WASM tools (`tools/zig/`).
- Every `.zig` file lives under a subsystem directory; only `main.zig`,
  `cli.zig`, and `config.zig` sit directly in `src/`. A new module with tests
  must be added to the `comptime` block in `src/main.zig` or its tests never
  run.
- `src/evals/` + `src/gate/` — the eval harness and deterministic gates
  (build/test/tools/fmt/lint). These verify every promoted change.
- `src/improve/` — the self-improvement engine. It is deliberately protected:
  clanker cannot modify `src/improve/`, `src/evals/`, `src/tools/builder.zig`,
  or `evals/` in a single pass (anti-cheat boundary).
- `tools/zig/` — WASM tool sources (Zig); `tools/ts/` — AssemblyScript
  sources; `tools/manifests/` — descriptors; `tools/bin/` — committed AS build output
  (built via `npm run build` in `tools/ts/`; guest ABI: exports
  scratch/host_arena/run, imports env.ck_*); `zig-out/tools/` — Zig tool build
  output (`zig build tools`), gitignored. Prefer implementing functionality as
  WASM tools.

## Tool ABI

Guest modules export `scratch(need) -> u32`, `host_arena() -> u32`,
`run(ptr, len) -> u64` (packed `(out_ptr << 32) | out_len`), and import the
`env.ck_*` host functions declared in `tools/zig/lib.zig`.

## Self-improvement loop

Every promoted change must pass: `zig build`, `zig build test`,
`zig build tools`, `zig fmt --check` (auto-formatted), and the source lint.
Promoted changes are committed as `clanker: <summary> [imp-<id>]`. Run the
whole gate manually with `clanker gate`.
