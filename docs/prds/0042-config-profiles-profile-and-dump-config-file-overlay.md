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

The layering slot is correct: the overlay does merge after `config.local.toml`
and before anything env- or flag-derived. The edges are not.

1. **A missing `profiles/<name>.toml` is reported as
   "config.toml not found; run `clanker setup`".** The `.overlay` FileNotFound
   arm reuses `.required`'s `error.MissingConfig`, so the error carries nothing
   about which layer failed and `main.zig`'s hint table blames the base config —
   pointing at a file that exists and prescribing a remedy that cannot help.
   Contradicts the failure-modes table below.
   [Bug](../reports/bugs/2026-08-23-profile-overlay-errors-name-the-wrong-file.md).

2. **`profiles/<name>.local.toml` is never read**, though Goal 1 names it and
   is marked shipped. `Config.load` builds exactly one path. Same bug record.

3. **`--dump-config` erases the real load error.** It does
   `loadWithProfile(...) catch null` and then reports a `config.toml` syntax
   problem regardless of which error occurred, while the normal path a few
   lines below has a per-error hint table. Same bug record.

4. **`--dump-config` leaks the secret half of a header whose value contains
   `=`.** The redaction helper serves both `env` (`NAME=value`) and `headers`
   (`Name: value`) and prefers `=` unconditionally, so a base64-padded `Basic`
   credential is printed one character short of whole. The existing test uses a
   value with no `=`.
   [Bug](../reports/bugs/2026-08-23-dump-config-header-redaction-cuts-on-equals.md).

5. **`--profile` is dropped on a `serve` hot-reload re-exec.**
   `buildServeArgvTail` does not repeat it, so `clanker serve --profile web`
   reverts to base+local after the first rebuild or config-edit restart, with no
   log line saying so — the exact failure its own docstring warns about.

6. **The overlay name is `threadlocal`**, armed on the main thread, so
   `ConfigWatch`'s spawned thread validates base+local only. A profile that is
   what makes the stack valid makes every config edit log "config changed but
   does not load … keeping the last known good config" against a process that is
   running fine; the reverse case green-lights a restart into a config that
   cannot boot.

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
