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
- `src/mcp/`, `src/peers/`, `src/util/` — MCP server, peer chatrooms/phonebook,
  logging and dotenv. Peer notify/phonebook and patch application moved to
  the sandboxed `peers` and `patch_apply` WASM tools (`tools/zig/`).
- Every `.zig` file lives under a subsystem directory; only `main.zig`,
  `cli.zig`, `config.zig`, `doctor.zig`, and `janitor.zig` sit directly in
  `src/`. A new module with tests must be added to the `comptime` block in
  `src/main.zig` or its tests never run.
- `src/evals/` + `src/gate/` — the eval harness and deterministic gates
  (build/test/tools/fmt/lint). These verify every promoted change.
- `src/improve/` — the self-improvement engine. It is deliberately protected:
  clanker cannot modify `src/improve/`, `src/evals/`, `src/tools/builder.zig`,
  or `evals/` in a single pass (anti-cheat boundary).
- `tools/zig/` — WASM tool sources (Zig); `tools/ts/` — AssemblyScript
  sources; `tools/manifests/` — descriptors; `tools/bin/` — committed AS build output
  (built via `npm run build:all` in `tools/ts/`; guest ABI: exports
  scratch/host_arena/run, imports env.ck_*); `zig-out/tools/` — Zig tool build
  output (`zig build tools`), gitignored.

## WASM by default

Anything that can be a WASM tool must be one. The harness is what cannot: the
sandbox, the provider adapters, the agent loop, the improve engine, config, and
the CLI's own argument handling. Everything else is a guest module.

This is not a preference. A guest runs under a descriptor that states exactly
which paths, commands, environment variables, and hosts it may touch, and the
host enforces it; native code in `src/` has the whole process. A guest is also
replaceable without rebuilding clanker, which is what lets the improve loop
change a tool's behaviour without changing the thing running the gate.

So, when adding a capability:

- Write it as a guest module with a descriptor in `tools/manifests/`. Native
  code in `src/` needs a reason that survives the questions above.
- Either language compiles to a guest, and the host cannot tell them apart:
  `tools/zig/<name>.zig`, built by `zig build tools` into `zig-out/tools/`
  (gitignored), or `tools/ts/<name>.ts` in AssemblyScript, built by
  `npm run build:all` in `tools/ts/` into `tools/bin/` (committed, since not
  everyone building clanker has a node toolchain). The descriptor's `wasm`
  field points at whichever path. Zig is the default because the harness is
  Zig and `lib.zig` carries the host bindings; reach for AssemblyScript when
  the logic is easier to express in TypeScript or already exists there.
  `clanker gate` never rebuilds `tools/ts/`, so a `.ts` edit not followed by
  `npm run build:all` ships a stale `tools/bin/*.wasm` silently; run
  `tools/ts/verify.sh` (rebuilds into a scratch dir and diffs against what is
  committed) before committing a `tools/ts/` change.
- Migrate what is already native when you touch it. `patch_apply`, `peers`, and
  `board` each began as `src/` code and moved out, deleting more from the
  harness than they added as guests.
- The CLI and the web UI call the tool rather than reimplementing it, so the
  tool stays the single implementation. `toolText` and `toolJson` in `cli.zig`
  are that call.
- A capability the web UI drives may want a second descriptor over the same
  wasm: one op per tool reads well in a model's catalog, one multiplexed entry
  point suits an HTTP endpoint. Mark that one `internal` so it stays out of the
  catalog.

## Tool ABI

Guest modules export `scratch(need) -> u32`, `host_arena() -> u32`,
`run(ptr, len) -> u64` (packed `(out_ptr << 32) | out_len`), and import the
`env.ck_*` host functions declared in `tools/zig/lib.zig`.

## Self-improvement loop

Every promoted change must pass: `zig build`, `zig build test`,
`zig build tools`, `zig fmt --check` (auto-formatted), and the source lint.
Promoted changes are committed as `clanker: <summary> [imp-<id>]`. Run the
whole gate manually with `clanker gate`.

## Local operator rules (optional)

Checkout-private additions (gitignored). Missing file is a soft skip for tools
that expand `@path` imports (clanker, Claude Code, etc.).

@.agents/AGENTS.md
