# Bug — The fallback chain attempts providers that have no credentials

## TL;DR

- **What failed:** nextFallbackProvider skips unknown names but not a configured provider whose api_key_env is unset. A deepseek ReadFailed then tries openai, which fails MissingApiKey and exhausts the chain. TUI /model already uses unconfiguredReason; the chain does not.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Evidence

Escalation run `run-1787001820` log: DeepSeek stream `ReadFailed`, then `fallback: 'deepseek' failed (ReadFailed); trying 'openai'`, then `no credential for provider 'openai': set OPENAI_API_KEY`. `config.toml` has `fallback_providers = ["deepseek", "openai"]` and `[providers.openai] api_key_env = "OPENAI_API_KEY"`. `nextFallbackProvider` returned any configured row; TUI `/model` already filtered the same case with `unconfiguredReason`.
## Root cause

`nextFallbackProvider` returned any name that had a `providers` table row. TUI `/model` already filtered the same case with `providers.unconfiguredReason`. The chain did not.

## Resolution

`nextFallbackProvider` now takes the environ map and skips a row `unconfiguredReason` rejects, with a warning naming why. Unknown names were already skipped.

## Verification

Host test `nextFallbackProvider skips a configured provider that has no credential` in `src/agent/loop.zig`.