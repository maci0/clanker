# ADR 0024 — Config profiles are a file overlay with --profile and --dump-config

## Status

Accepted — 2026-08-17. Records the decision opened in [RFC 0012 — Named config profiles (--profile and --dump-config)](../rfcs/0012-named-config-profiles-profile-and-dump-config.md).

## Context

Config is config.toml < config.local.toml < env < flags with no way to name a stack.

Options in RFC 0012: A overlay, B presets, C symlink, D status quo. ROADMAP Planned (Profiles) motivates naming a stack.

## Decision

Add profiles/<name>.toml as an extra overlay between config.local.toml and env/flags behind --profile <name> and add --dump-config that prints the merged config.

> The RFC recommended: **Recommended option:** Adopt Option A — profiles/<name>.toml overlay with --profile and --dump-config



## Consequences

Enables named stacks for plugin bundles with minimal code; one more TOML load per startup and name-typo errors.

