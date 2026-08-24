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

None open. The layering slot was always correct -- the overlay merges after
`config.local.toml` and before anything env- or flag-derived -- and the six
edge defects below were fixed on 2026-08-24.

1. ~~**A missing `profiles/<name>.toml` is reported as "config.toml not
   found; run `clanker setup`".**~~ Fixed: `.overlay` returns
   `error.MissingProfile`, not `.required`'s `error.MissingConfig`, and logs
   the path it looked for. `main.zig`'s hint table has its own row.
   [Bug](../reports/bugs/2026-08-23-profile-overlay-errors-name-the-wrong-file.md).

2. ~~**`profiles/<name>.local.toml` is never read.**~~ Fixed: `loadInner`
   loads it `.optional` after `profiles/<name>.toml`, so it merges last, the
   way `config.local.toml` does over the base file. Same bug record.

3. ~~**`--dump-config` swallows the real error.**~~ Fixed: the `catch null` is
   gone and the load error is reported through `recoveryHint`, the same table
   the normal command path uses. Same bug record.

4. ~~**`--dump-config` leaks the secret half of a header whose value contains
   `=`.**~~ Fixed: `writeKvNames` takes the separator from the caller -- `'='`
   for `env`, `':'` for `headers` -- and the test carries a base64-padded
   `Basic` credential on both sides.
   [Bug](../reports/bugs/2026-08-23-dump-config-header-redaction-cuts-on-equals.md).

5. ~~**`--profile` is dropped on a `serve` hot-reload re-exec.**~~ Fixed:
   `buildServeArgvTail` repeats it, and the round trip through `parse` is
   pinned by a test.

6. ~~**The overlay name is `threadlocal`.**~~ Fixed: it is a process-global
   written once on the main thread, so `ConfigWatch`'s spawned thread
   validates the stack the process is actually running. The watcher also stats
   both halves of the named profile, so an edit to a profile is a config
   change like any other.

Verified end to end, not only by unit test: with a `config.local.toml` whose
`default_provider` only the profile defines, `clanker serve --profile fix`
re-exec'd on a config edit as
`serve --profile fix --host 127.0.0.1 --webui-port 17944 --no-proxy` and the
child booted. The same edit would have logged "config changed but does not
load" and then died on `DefaultProviderUnknown` before the fix.
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
