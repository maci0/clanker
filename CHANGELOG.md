# Changelog

This file records consumer-visible changes. It follows Keep a Changelog; version
numbers follow the policy in [RELEASES.md](RELEASES.md).

## [Unreleased]

### Added

- Initial CLI, REPL, HTTP, MCP, peer, and sandboxed WASM tool surfaces.
- Plugin manifest SDK: `manifest_version` in `*.tool.json`, a validator
  (`clanker plugins validate`), a scaffolder (`clanker plugins new <name>`), and
  a written field reference at [docs/manifest.md](docs/manifest.md). A manifest
  whose `wasm` is a bare filename now resolves beside its own manifest, so a
  `{name.tool.json, name.wasm}` directory is a portable plugin.
- Optional per-provider `auth` key (`api_key` / `oauth_static` /
  `oauth_refresh`), selecting how a credential is acquired independently of the
  provider's `kind`. Unset keeps the existing auto-detection, so no existing
  config changes meaning.
- `clanker serve`'s listener can now be set without flags, for a service file
  or a container: a `[serve]` table (`host`, `webui_port`, `serve_as`) and the
  `CLANKER_HOST` / `CLANKER_WEBUI_PORT` environment variables. Precedence is
  config < environment < flags.
- `agent.tools_dir` accepts a list of directories as well as a string, so a
  third-party plugin can live beside the built-in tools instead of replacing
  them. Later-listed wins on a name collision; a missing directory warns and
  continues. Existing `tools_dir = "tools/manifests"` configs are unchanged.

### Changed

- `serve --port` is now `serve --webui-port`, naming the surface it serves so
  that a second surface added later gets its own name instead of forcing a
  rename. `--port` is still accepted as an alias.

### Fixed

- `clanker serve` and the REPL exited immediately with signal 12 (`SIGSYS`) on
  macOS and any other non-Linux host whenever `modules.hot_reload` was on (the
  default). The hot-reload watcher issued raw Linux `inotify` syscalls
  unconditionally, which trapped before the fallback that was supposed to
  handle inotify being unavailable could run. The watcher now uses inotify only
  on Linux and polls the binary's mtime elsewhere.
- Hot reload never fired on macOS even once the watcher survived: a rebuild was
  only recognised by an ELF header, which a Mach-O binary never has. The check
  is now per-platform.

### Compatibility notes

- There are no published releases or supported upgrade paths yet. Current
  configuration and persisted state may change before the first tagged release.
- `manifest_version` is optional and absence means version 1, so existing
  `*.tool.json` files load unchanged. A manifest declaring a version this build
  does not understand is refused rather than read under version 1 rules.

<!-- Release links are added when the first immutable version tag is created. -->
