# Missing clanker tool — No verb reads or sets a single config key

## TL;DR

- **Missing tool:** Pinning a setting persistently (hit while adding --reasoning-effort: the flag covers one invocation, the [agent] reasoning_effort key needs config.local.toml edited by hand) has no clanker verb. There is no 'clanker config get/set <key>'; --dump-config prints the merged config as a Zig struct debug dump, not TOML, so it cannot even be pasted back. Checked 2026-08-17: clanker --help lists no config verb and rg 'config get' over src/cli.zig has no hit.
- **Finding:** Investigating.
- **Resolution:** Pending.

## Status

Investigating.

## What is missing

A verb that reads or writes one config key: `clanker config get <key>` /
`clanker config set <key> <value>`, resolving against the merged
config.toml + config.local.toml the way the loader does.

## Why it is basic

Every setting introduced as a CLI flag (e.g. `--reasoning-effort`, added
2026-08-17) has a persistent twin in config; making the persistent choice
requires hand-editing `config.local.toml`. `--dump-config` exists but
prints the merged config as a Zig struct debug dump (`main.zig` prints
`{any}`), which cannot be pasted back as TOML, so there is no round trip
at all. Checked 2026-08-17 on 0f9e88a6: `clanker --help` lists no config
verb.

## Ad-hoc fallback used

Hand-editing `config.local.toml` in an editor, then re-running the
command; `--dump-config` to eyeball the merged result.

## Proposed shape

A `config` guest (fs-scoped to config.toml/config.local.toml, the same
files the `config` dump tool already reads) with `get`/`set` ops writing
config.local.toml only, plus a `clanker config` verb relaying it. `set`
validates the key against the loader's schema so a typo is refused, not
silently ignored the way an unknown TOML key is today.

## References

- Related record: none yet
