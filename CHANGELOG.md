# Changelog

This file records consumer-visible changes. It follows Keep a Changelog; version
numbers follow the policy in [RELEASES.md](RELEASES.md).

## [Unreleased]

### Added

- Initial CLI, REPL, HTTP, MCP, peer, and sandboxed WASM tool surfaces.
<<<<<<< HEAD
- Plugin manifest SDK: `manifest_version` in `*.tool.json`, a validator
  (`clanker plugins validate`), a scaffolder (`clanker plugins new <name>`), and
  a written field reference at [docs/manifest.md](docs/manifest.md). A manifest
  whose `wasm` is a bare filename now resolves beside its own manifest, so a
  `{name.tool.json, name.wasm}` directory is a portable plugin.
=======
- Optional per-provider `auth` key (`api_key` / `oauth_static` /
  `oauth_refresh`), selecting how a credential is acquired independently of the
  provider's `kind`. Unset keeps the existing auto-detection, so no existing
  config changes meaning.
>>>>>>> origin/main

### Compatibility notes

- There are no published releases or supported upgrade paths yet. Current
  configuration and persisted state may change before the first tagged release.
- `manifest_version` is optional and absence means version 1, so existing
  `*.tool.json` files load unchanged. A manifest declaring a version this build
  does not understand is refused rather than read under version 1 rules.

<!-- Release links are added when the first immutable version tag is created. -->
