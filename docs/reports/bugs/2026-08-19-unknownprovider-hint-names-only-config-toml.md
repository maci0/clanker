# Bug — The UnknownProvider hint pointed at config.toml although providers merge from config.toml + config.local.toml

## TL;DR

- **What failed:** clanker providers check <name> for an unknown name answered 'no provider by that name in config.toml' even in a checkout whose entire provider list lives in config.local.toml, sending the operator to a file that does not define providers at all. Hit while re-evaluating the vertex-anthropic-400 investigation. Fixed: the hint names the merged config.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-19. hint now names the merged config (config.toml + config.local.toml); verified live: providers check with an unknown name prints the new wording

## Status

Resolved on 2026-08-19. hint now names the merged config (config.toml + config.local.toml); verified live: providers check with an unknown name prints the new wording

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Evidence

In a checkout whose provider list lives in config.local.toml (the operator's main checkout: default provider deepseek, from config.local.toml), `clanker providers check google-vertex-anthropic` answered:

    error: no provider by that name in config.toml; run `clanker providers check` for the list

config.toml there defines no providers at all, so the hint named the one file that could not contain the answer. Hit 2026-08-19 while re-evaluating docs/reports/investigations/2026-08-19-vertex-anthropic-400.md, whose subject provider had been removed from the local config: the hint suggested checking config.toml for it.

## Root cause

The hint is the static string mapped to `error.UnknownProvider` in src/main.zig's error boundary. The lookup it reports on (`config.zig` providers.getPtr) runs over the merged config; the message predates config.local.toml carrying whole provider entries.

## Resolution

The hint names the merged config: 'no provider by that name in the merged config (config.toml + config.local.toml); run `clanker providers check` for the list'. Verified live from this branch: `clanker providers check google-vertex-anthropic` in a worktree prints the new wording.