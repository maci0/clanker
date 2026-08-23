# Bug — unknown provider kind failed with no naming diagnostic

## TL;DR

- **What failed:** Config.load returned error.UnknownProviderKind with no log line naming the provider or the offending kind, while the generic failure line says to inspect the setting named by the preceding diagnostic. Observed as clanker reports list failing hard in a checkout whose zig-out binary predated the claude/codex/grok kinds in config.toml. Fixed: the parse site now logs the provider, the spelling, and every accepted kind before returning.
- **Impact:** Any command that loads config exits with an error that points at a diagnostic that does not exist. The operator is left diffing config.toml by eye. The likeliest audience is exactly the least equipped to guess: someone running a stale binary against a current config, where the config is correct and the binary is old.
- **Resolution:** Resolved on 2026-08-23. The parse site logs provider name, offending spelling, and the comptime-generated accepted-kind list before returning UnknownProviderKind. Pinned by the load test; verified live with a flux_capacitor kind and against the repo's real config.

## Status

Resolved on 2026-08-23. The parse site logs provider name, offending spelling, and the comptime-generated accepted-kind list before returning UnknownProviderKind. Pinned by the load test; verified live with a flux_capacitor kind and against the repo's real config.

## Symptom and impact

Observed in the main checkout: `./zig-out/bin/clanker reports list` failed
with

```
[ERROR] config.toml: configuration validation failed (UnknownProviderKind); inspect the setting named by the preceding diagnostic
error: configuration is invalid; correct the setting reported above
```

with no preceding diagnostic naming any setting — only unknown-key warnings
about different keys entirely (`worktree_link_local_config`,
`cli_plugins_dir`, `tui_plugins_dir`, `oauth_plugin`), which misdirect.

Two findings, one of which is the bug:

- The occurrence itself was a stale binary (zig-out from 2026-08-19)
  reading the current committed config.toml, which declares `kind =
  "claude"`, `"codex"`, and `"grok"` — all added after that binary was
  built. Current source accepts all three: not config drift, not a
  validation bug. Rebuilding fixes that machine.
- The real defect: the `UnknownProviderKind` return was the only provider
  parse error in `Config.load` with no named diagnostic. Neighbouring
  paths (`UnknownAuthStrategy`, `ProviderLegacyModelFields`,
  `ApiKeyEnvEmpty`) all log which provider and which value; this one
  returned bare, so the generic handler's promise of a "preceding
  diagnostic" was false for exactly this error.

## Reproduction

```
printf 'default_provider = "p"\nproviders = { p = { base_url = "https://example.test", kind = "flux_capacitor" } }\nmodels = { "p/m" = { provider = "p" } }\n' > config.toml
clanker reports list
```

Pre-fix: the two generic lines above, nothing naming `p` or
`flux_capacitor`.

## Root cause

`src/config.zig` (provider parse): `p.kind = ProviderKind.fromStr(...)
orelse return error.UnknownProviderKind;` — an early return with no
`log.log(.error_, ...)` first, unlike every sibling error path in the same
function.

## Resolution

The parse site now logs `provider '<name>': unknown kind "<spelling>"
(this binary accepts: <list>)` before returning. The accepted list is
`ProviderKind.known_names`, generated at comptime from the enum fields, so
it cannot drift from what `fromStr` accepts.

## Verification

- Unit: "an unknown provider kind is rejected at load" (src/config.zig)
  pins the error and that `known_names` carries real spellings.
- Live: a scratch config with `kind = "flux_capacitor"` run through the
  rebuilt binary prints the named diagnostic followed by the generic line,
  which now points at something that exists.
- Live: the same binary runs `clanker reports list` cleanly against the
  repo's real config.toml, confirming the original occurrence was the
  stale binary, not the config.

## Follow-up

## References

- docs/reports/bugs/2026-08-22-commit-all-omits-new-files.md — unrelated,
  but the same triage session; the stale-binary occurrence surfaced while
  evaluating open bug reports.
- src/config.zig — `ProviderKind`, `known_names`, the provider parse.
