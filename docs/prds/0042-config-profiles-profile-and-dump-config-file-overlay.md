# PRD — Config profiles: --profile and --dump-config (file overlay)

## Status

Shipped — 2026-08-17.

Single source `src/config.zig` + `src/cli.zig` (+ `profiles/*.toml`).

## Problem

Operators hand-swap config.local.toml to switch stacks; there is no way to name a curated config stack and no way to inspect the merged result.

Constraints: keep `config.toml < config.local.toml < profiles/<name>.toml < env < flags`; no schema change; reflectable schema already proven; composes with hot reload.

## Goals

1. `clanker --profile <name>` applies `profiles/<name>.toml` (plus `.local` variant when present) between `config.local.toml` and env
2. `clanker --dump-config` prints the effective merged config including the profile overlay
3. Existing layering (config.toml < config.local.toml < env < flags) remains respected; profiles compose without changing schema


## Non-goals

- No per-profile secrets vaulting (API keys stay env-based).
- No plugin-bundle patch layers in this slice — profile is a config overlay only.

## Design
**Dependencies.** ADR 0024, RFC 0012, `src/config.zig:Config.load/merge`, `src/cli.zig` flag parsing. Reflectable config-doc test already proves dump is cheap.

**Design.** `Config.load` gains an optional `profile` path overlay (`profiles/<name>.toml` plus optional `profiles/<name>.local.toml`) merged via the same `merge` logic between `config.local.toml` and env. CLI adds global `--profile <name>` and `--dump-config` (prints TOML/JSON of merged Config). Mirrors DSH's profile stack without plugin-bundle patches.

**Implementation.**
1. Add `--profile` and `--dump-config` flags — `src/cli.zig` (and `src/main.zig` if needed for global).
2. Extend `Config.load` to accept an optional profile overlay and merge it — `src/config.zig`.
3. Add `profiles/` directory with example (`profiles/web.toml`, `profiles/headless.toml` etc. optional) — `profiles/*.toml`.
4. `zig fmt` + `zig build test` + `zig build tools` green.

## Known issues


## Failure modes

| Condition | Behaviour |
|---|---|
| `--profile` name not found | Error naming the missing `profiles/<name>.toml`; no silent fallback |
| `--dump-config` without prior load | Prints merged config as it stands |

## Acceptance criteria

- [x] `--profile <name>` merges overlay
- [x] `--dump-config` prints merged result
- [x] `zig build test` + `zig build tools` green

## Open questions / future work

- Exact profile precedence with hot-reload — verify tick ordering.
