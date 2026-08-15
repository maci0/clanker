# Changelog

This file records consumer-visible changes. It follows Keep a Changelog; version
numbers follow the policy in [RELEASES.md](RELEASES.md).

## [Unreleased]

### Fixed

- Isolated `clanker run` now provisions a checkout `state/` path that is a
  symlink to shared durable storage. Previously Zig reported `NotDir` before
  any shared paths were linked, leaving host-side state private to the
  worktree while sandboxed tools used the checkout state.

### Changed

- Web UI shell follows a session-first layout: conversations stay in the
  left rail, Watch and Set up fold away, and Chat is a header / transcript
  / docked-composer column. PatternFly page chrome and cabinet colors stay.

### Added

- `clanker add-goal` and `/add-goal` save a structured goal without starting
  work. The Goals board uses the same `add_goal` writer and tells the operator
  that a saved goal has not started.
- Persistent Python eval kernel (PRD 0016): a session-scoped `python3`
  supervisor keeps `__main__` across cells. `reset: true` restarts it;
  session end SIGTERMs via the shared subprocess registry. Still off
  unless `kernel.enabled = true`.
- DAP debug tool (PRD 0017): `debug` guest + `ck_debug` + `[debug]`
  adapters. Off unless `debug.enabled = true`. Host tests speak DAP
  to a stdio fake adapter (launch, breakpoints, continue, stack,
  variables, evaluate, disconnect).
- The `kernel` tool's Python path also has a WASI one-shot sandbox
  (`./scripts/setup-python-wasi.sh`) that is not the persist path.
- Fleet Mesh map: each clanker is a lamp on `/#fleet`. Wires appear
  after a talk; a live talk sends a directed glow along the wire.
  `GET /api/mesh/map` feeds it (even when `modules.mesh` is off).
- Web UI live bus: `GET /api/events` (SSE). Chat, mesh talk, and run
  working push to the page. HTTP `/api/*` stays the command API; polls
  are the fallback when the stream is down.
- Mesh chat pipe: `fanOut` writes a `CHAT` frame on a live mesh link
  when `modules.mesh` is on and the peer is connected, else HTTP. Serve
  listens when the module is on. `POST /api/mesh/join` dials.

## [0.1.0] - 2026-08-14

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
- `agent.fallback_provider` is now an ordered list (`fallback_providers`
  also accepted). After the selected provider exhausts its own retries with
  no content delivered, the next configured name is tried. A bare string
  still means one fallback. Vision routing stays pre-emptive and unchanged.
- The Models view can save a catalog snippet (or set the default
  provider/model) into `config.local.toml`. Writes are surgical table/key
  replacements and take effect on the next `clanker serve` restart.
- `read_file` accepts `hashes: true` (4-hex xxHash per line) and
  `edit_file` accepts `op: "hashline"` so an edit can target those hashes
  instead of reproducing the exact text. A mismatch rejects the whole
  patch; success returns the new hashes for a follow-up edit.
- Optional `[advisor]` second-model critique after each completed turn.
  Off by default; fail-open. A `blocker` asks proceed/abort when a human
  is present and otherwise injects as a one-turn concern.
- Turns with no configured `temperature`/`top_p` now pick a use-case
  default (chat 0.7, tool-use 0.0). Thinking models get
  `reasoning_effort` (`medium`/`high`) instead. An explicit config or
  per-run value still wins.
- Optional `agent.auto_thinking` classifies each user turn and selects a
  `reasoning_effort` row. Off by default; fail-open.
- `[ttsr]` stream rules can abort an in-flight completion on a
  literal/`*` match, inject a note into the system prompt, and retry
  the turn. Off unless rules are configured.
- Session-scoped subprocess registry (`src/agent/subprocess.zig`) plus a
  `kernel` guest that stays off unless `kernel.enabled = true`. Python/JS
  supervisors are still landing; DAP will reuse the same registry.
- `gh_read` fetches GitHub issues/PRs via `gh://` URLs with an
  allowlisted `GITHUB_TOKEN`. Repeat reads within 5 minutes hit
  `state/gh_cache/`. `read_file` stays network-free.
- `clanker commit` / `smart_commit` groups a staged diff into
  conventional commits. A dense import cycle becomes one commit with a
  note instead of looping.
- `write_goal` drafts a structured goal without persisting it.
  `proof` and `stop_rule` now appear in the active-goal run preamble.
- An opt-in REPL mascot (`--mascot`, `[tui] mascot`), off by default. Five
  modes: it can track what you type, loop across the screen, run on the
  spot above the composer, or run inside the composer, which grows to make
  room. `--mascot-size` picks a 6x1, 7x2, 8x4, 10x5, or 21x10 cell grid and
  `--mascot-facing` mirrors it. Drawn with kitty graphics where the
  terminal supports it and unicode half-blocks everywhere else.

### Changed

- `clanker goal`, `/goal`, and `clanker run "/goal …"` start the supplied goal
  loop. The loop keeps taking turns until it reaches the condition or reports a
  blocker; it does not require a `write_goal` draft or persisted record. Use
  `run --goal <id>` to start the loop from a saved goal.
- `serve --webui-port` is the documented spelling for the web UI listen port.
  A second surface (`--proxy-port`) now has a peer name instead of overloading
  a generic `--port`.

### Deprecated

- `serve --port` is deprecated in favor of `--webui-port`. The old flag still
  works and logs a warning; migrate service files and scripts before it is
  removed in a future minor release.

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

- This is the first tagged release. There is no prior version to be
  compatible with; the `0.MINOR.0` policy in [RELEASES.md](RELEASES.md)
  governs breaking changes from here on.
- `manifest_version` is optional and absence means version 1, so existing
  `*.tool.json` files load unchanged. A manifest declaring a version this build
  does not understand is refused rather than read under version 1 rules.

[0.1.0]: https://github.com/maci0/clanker/releases/tag/v0.1.0
