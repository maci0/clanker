# Bug — a missing profiles/<name>.toml is reported as config.toml not found, and the .local variant is never read

## TL;DR

- **What failed:** Config.load maps FileNotFound on the profile overlay to error.MissingConfig, the same error the base config uses, so clanker run --profile typo prints config.toml not found; run clanker setup to create one and never names profiles/typo.toml. PRD 0042's failure table requires naming it. --dump-config additionally catch nulls the real error and blames config.toml syntax. And profiles/<name>.local.toml, which Goal 1 marks shipped, is never loaded.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-24. Fixed in ac242be4, all three defects plus both follow-ups: error.MissingProfile with the path logged and its own hint row; profiles/<name>.local.toml loads .optional after the profile; --dump-config reports the real error via the shared hint table. Verified by clanker gate (11/11 PASS) and live -- serve --profile fix re-exec'd carrying --profile and booted on a config whose default_provider only the profile defines.

## Status

Resolved on 2026-08-24. Fixed in ac242be4, all three defects plus both follow-ups: error.MissingProfile with the path logged and its own hint row; profiles/<name>.local.toml loads .optional after the profile; --dump-config reports the real error via the shared hint table. Verified by clanker gate (11/11 PASS) and live -- serve --profile fix re-exec'd carrying --profile and booted on a config whose default_provider only the profile defines.

## Symptom and impact

Three separate defects on PRD 0042's `--profile` overlay. The layering slot
itself is correct — the overlay does merge after `config.local.toml` and before
anything env- or flag-derived — so this is about the edges, not the mechanism.

**1. A missing profile blames `config.toml`.** `Config.load`'s `FileNotFound`
arm maps both `.required` and `.overlay` to `error.MissingConfig`, and
`src/main.zig`'s hint table renders that as
"config.toml not found; run `clanker setup` to create one". So
`clanker run --profile typo "x"` points the operator at a file that exists and
is fine, never names `profiles/typo.toml`, and the remedy it prescribes will not
help. PRD 0042's failure table requires "Error naming the missing
`profiles/<name>.toml`; no silent fallback".

**2. `profiles/<name>.local.toml` is never read.** `Config.load` builds exactly
one path, `profiles/{s}.toml`; `grep -rn "profiles/" src/` returns only that
line. PRD 0042 Goal 1 says "applies `profiles/<name>.toml` (plus `.local`
variant when present)" and is marked shipped with the box checked.

**3. `--dump-config` swallows the real error.** `src/main.zig` does
`loadWithProfile(...) catch null` and then reports "could not load
configuration; check config.toml syntax or run `clanker setup`", erasing which
of `MissingConfig` / `DefaultProviderUnknown` / `FieldNotInt` /
`ProviderMissingModel` actually happened — while the normal path a few lines
below has a per-error hint table for the same set.

## Reproduction

```bash
clanker run --profile definitely-not-a-profile 'hi'
clanker --dump-config --profile definitely-not-a-profile
```

Both blame `config.toml`. And a `profiles/web.local.toml` beside a working
`profiles/web.toml` has no effect under `--profile web`.

## Root cause

`.overlay` reuses `.required`'s error value, so the error carries no
information about which layer failed; and `--dump-config`'s `catch null`
discards even that.

## Resolution

Open. A distinct `error.MissingProfile` (with the path in a diagnostic log line,
which the overlay arm has none of today) plus a hint row in `main.zig`;
`--dump-config` should surface the error the normal path surfaces; and the
`.local` overlay is one more `loadFile` call with `.optional`.

## Verification

Needs a test that `--profile <missing>` produces an error naming the profile
path, and one that a `profiles/<name>.local.toml` value wins over the
`profiles/<name>.toml` value.

## Follow-up

Two adjacent problems found in the same sweep, both worth their own fix:

- `--profile` is dropped on a `serve` hot-reload re-exec.
  `buildServeArgvTail`'s own docstring says every flag that shapes the listener
  has to be repeated there or a re-exec silently narrows the policy; `--profile`
  is not in it, so `clanker serve --profile web` reverts to base+local after the
  first rebuild or config-edit restart, with no log line saying so.
- the overlay name is held in a `threadlocal` armed on the main thread, so
  `ConfigWatch`'s spawned thread validates base+local only. If the profile is
  what makes the stack valid, every config edit logs "config changed but does
  not load … keeping the last known good config" and
  `GET /api/config/status` reports a working process as broken; if base+local is
  valid but base+local+profile is not, the watcher green-lights a restart into a
  config that cannot boot.

## References

- PRD: [0042-config-profiles-profile-and-dump-config-file-overlay.md](../../prds/0042-config-profiles-profile-and-dump-config-file-overlay.md)
- Code: `src/config.zig` (`load`/`loadWithProfile`, the `.overlay` FileNotFound
  arm, `overlay_profile`), `src/main.zig` (the hint table, `--dump-config`),
  `src/cli.zig` (`buildServeArgvTail`, `ConfigWatch`/`configLoads`)
