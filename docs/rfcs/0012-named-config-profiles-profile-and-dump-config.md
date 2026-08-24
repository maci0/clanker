# RFC 0012 — Named config profiles (--profile and --dump-config)

## Status

Decided — 2026-08-17. ADR 0024

## Overview

Config layering is config.toml < config.local.toml < env < flags with no way to NAME a stack; the candidate shape per ROADMAP is profiles/<name>.toml as an overlay between config.local.toml and env plus --dump-config that prints the merged result.

**Decision to make.** Which mechanism to name and compose config stacks (profiles) and how to surface the merged result (--dump-config).

**Why now.** ROADMAP Planned (Profiles from DSH) needs a named-stack alternative to hand-swapping config.local.toml; live surfaces (plugins) want curated bundles.

**Drivers.** Keep existing layering `config.toml < config.local.toml < env < flags`; profiles compose via overlay without changing sandbox or adding deps; hot-reload friendly; reflectable schema already proven.

**Out of scope.** Changing the underlying config schema; adding per-profile secrets vaulting; webhook distribution.

## Current state

Today: `Config.load` merges `config.toml` and `config.local.toml` then env/flags. `profiles/` directory does not exist. Tooling `clanker --profile/--dump-config` flags do not exist; the config-doc test already proves the schema is reflectable. Candidate code change: `src/config.zig` add `profiles/<name>.toml` as an extra overlay between `config.local.toml` and env; `src/cli.zig` add `--profile` and `--dump-config` handling; mirror in `src/serve/*` hot-reload path if needed.

## Options considered

### Option A — File-based overlay: `profiles/<name>.toml` between config.local.toml and env + `--dump-config`

- **What it is:** `--profile <name>` reads `profiles/<name>.toml` (plus optional `profiles/<name>.local.toml`) as an extra TOML overlay merged with the same `merge` logic.
- **Maturity:** Follows the existing `load`/`merge` pattern already used for config.local.toml.
- **How it would fit:** `src/config.zig:Config.load` adds one more `loadFile`/`merge` step when `--profile` is set; `src/cli.zig` parses `--profile`/`--dump-config` and prints the merged `Config` via a TOML/reflect writer; README updated.
- **Pros:** Minimal diff; composes with env/flags and hot-reload; no new storage.
- **Cons:** File I/O for each profile; name typos are user-visible load errors.
- **Cost to adopt:** A few dozen lines plus a flag.
- **Cost to leave:** Remove the extra overlay step and flags.
- **Evidence:** `src/config.zig` already exposes `load`/`merge` and reflectable schema — verified.

### Option B — Flags-only preset bundles (hard-coded presets)

- **What it is:** Ship a small set of hard-coded preset names that toggle known keys via flags alone.
- **Maturity:** No file I/O; easy to explain.
- **How it would fit:** `src/cli.zig` maps preset names to flag sets.
- **Pros:** No filesystem search.
- **Cons:** Not extensible without code change; bundles hard to share.
- **Cost to adopt:** Small, but not extensible.
- **Cost to leave:** Remove preset table.
- **Evidence:** Presets not in tree; flag layer already exists — verified.

### Option C — Symlink/alias to config.local.toml (status quo workaround)

- **What it is:** Instruct operators to symlink `config.local.toml` to `profiles/<name>.toml` per task.
- **Maturity:** Uses OS primitives; already possible.
- **How it would fit:** Docs only; no code.
- **Pros:** Zero code.
- **Cons:** Single active profile, error-prone, does not compose with env/flags; hot-reload racy.
- **Cost to adopt:** Docs.
- **Cost to leave:** Remove docs.
- **Evidence:** Operators hand-swap `config.local.toml` today — ROADMAP says so.

### Option D — Status quo

## Implications by horizon

### Short term (this release / 0–3 months)

- **If A:** Named stacks land; plugin surfaces can ship curated bundles; `--dump-config` helps debugging.
- **If B:** Few presets land but can't be extended without releases.
- **If C:** Docs workaround only; footgun remains.
- **If status quo:** Keep hand-swapping config.local.toml.

### Medium term (3–12 months)

- **If A:** Hot-reload picks up profile changes; env still wins over file.
- **If B:** Pressure grows to convert presets to files — migration later.
- **If D:** Same friction.

### Long term (12+ months)

- **If A:** Stable, composable; easy to keep.
- **If B:** Tech debt of baked-in presets.
- **If D:** Persistent ergonomics debt.

## Recommendation

**Recommended option:** Adopt Option A — profiles/<name>.toml overlay with --profile and --dump-config

**Confidence:** 7/10

**Why this confidence.** _State what evidence would raise it, and what finding would sink this recommendation._

**Rationale.** File-based overlay composes cleanly between config.local.toml and env, reuses existing merge logic, and gives plugin surfaces a way to ship curated bundles without hard-coding presets.

**Reversibility.** _How hard is this to undo, and where is the point of no return?_

## Open questions

- Exact profile precedence relative to env/flags — confirm ordering.

## Next steps / action items

- [ ] ADR 00XX; PRD for profiles; thin impl in `src/config.zig` + CLI flags.
