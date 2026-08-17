# Missing clanker tool — No verb reads or sets a single config key

## TL;DR

- **Missing tool:** Pinning a setting persistently (hit while adding --reasoning-effort: the flag covers one invocation, the [agent] reasoning_effort key needs config.local.toml edited by hand) has no clanker verb. There is no 'clanker config get/set <key>'; --dump-config prints the merged config as a Zig struct debug dump, not TOML, so it cannot even be pasted back. Checked 2026-08-17: clanker --help lists no config verb and rg 'config get' over src/cli.zig has no hit.
- **Finding:** Investigating.
- **Resolution:** Pending.

## Status

Investigating.

## What is missing

## Why it is basic

## Ad-hoc fallback used

## Proposed shape

## References

- Related record: none yet
