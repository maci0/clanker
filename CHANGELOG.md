# Changelog

This file records consumer-visible changes. It follows Keep a Changelog; version
numbers follow the policy in [RELEASES.md](RELEASES.md).

## [Unreleased]

### Added

- `improve-self` seeds its plan phase from the repository's own records
  before spending a model call on ideas: open or reopened bug reports under
  `docs/reports/`, PRD known issues and unchecked requirements, and planned
  `docs/ROADMAP.md` items, scored in that order (a reopened report — a fix
  that did not hold — outranks an open one). Seeded ideas pass the same
  already-tried and writable-target dedup as model-proposed ones, records
  marked `Investigating` are left to whoever is on them, ROADMAP items whose
  named files no longer exist are skipped, and the planning call remains the
  fallback once the backlog runs dry. Off via `improve.backlog = false`.

- `clanker gate` has a twelfth check, `dep-patches`: every `patches/*.patch`
  must be applied to the dependency tree its `build.zig.zon` `.hash` pin
  names, under `zig-pkg/`. That directory is gitignored and therefore
  per-worktree, `zig build` extracts pristine upstream tarballs into it, and
  `scripts/apply-patches.sh` was called by nothing, so a fresh worktree built,
  tested and gated green against pristine vaxis and zwasm. It only reports:
  `zig build` first (nothing exists to patch before the trees are extracted),
  then `scripts/apply-patches.sh`, which is the ordering the failure names.

### Changed

- `thinking_schema` gained an `anthropic_thinking` value, and its unset
  default is now the wire kind's own shape rather than one global
  `reasoning_effort`. The Anthropic Messages body carries
  `"thinking":{"type":"adaptive"}` with the level in
  `"output_config":{"effort":...}`, and sends no `temperature`/`top_p`:
  current Claude models removed all three of `temperature`/`top_p`/`top_k`
  and answer 400 on any value. Set `thinking_schema = "reasoning_effort"`
  explicitly to run an older Claude SKU that still takes the flat field.
  The endpoint's answer to the new body was **not** verified live — no
  Anthropic credential was available — so this is a body-shape change
  grounded in the API reference, with unit coverage on the emitted JSON.

- `plugin.json` capabilities can name the whole `pluginApi()` surface. The
  known-name list stopped at 13 names while the page's API kept growing, so a
  view that formats bytes, switches views, or opens another conversation could
  not declare what it used; nine of the ten shipped plugins shipped with
  declarations that understated their own calls. The new names are
  `foldFind`, `boardTimeline`, `el`, `status`, `fmt`, `showView`, `van`,
  `preact`, `html`, and `signals`. The field is still a declaration, not a
  grant.

- `-Dtest-filter` now reaches `zig build e2e` as well as `zig build test`.
  The e2e step set no filters, so the flag was accepted and silently ignored
  and the only way to re-run one journey was the whole suite; the pty resize
  journey alone floods 4000 resizes.

- Removed the deprecated `serve --port` alias; use `--webui-port`.

### Fixed

- An unreadable or oversize `state/improvements.jsonl` no longer reads as no
  history. Both read paths ended in `catch return &.{}`, which is
  indistinguishable from a first run, so the improve loop's dedup and revert
  gates silently answered "not accepted, not reverted" and it re-promoted work
  already merged and re-proposed work a human had reverted. Only a MISSING log
  is empty now; anything else is reported, and `improve-self` refuses to start
  rather than run with those gates off. The log is also bounded for the first
  time, trimmed to its newest records well before it can reach the size at
  which a reader gives up.

- `improve-self` no longer advances a merge-back's pinned merge base past a
  branch resync that did not happen. `created_from` is what the next promotion
  hands `git merge-tree`, and it was advanced before the `git reset --hard`
  that moves the branch ref, whose failure was only a warning. A failed reset
  therefore left the pin claiming a position the ref never reached, and the
  next merge read the branch side as a deletion of everything the previous
  merge folded in.

- An agent preset's denied tools are no longer offered to the model. The mask
  was applied at one call site in `clanker run`, and `Agent.init` then rebuilt
  the tool list from the registry whenever the tool catalog was on (the
  default), throwing that filtered list away; the preset itself was assigned
  onto the agent only after `init` returned, so the system prompt's tool
  catalog enumerated every denied tool too. `load_tools` could re-reveal a
  denied tool with its full schema, and a mid-run `rebuildToolDefs` un-masked
  the list again. Only the dispatch gate refused, so a `--preset research` run
  degraded into the model repeatedly reaching for `edit_file` and being told
  no. The preset is now a parameter of `Agent.init`, the registry's tool-list
  and catalog-text builders take it, `load_tools` reports a denied name as
  `denied` rather than revealing it, and `load_tools` itself stays offered so a
  preset with a `tools_allow` list keeps the catalog's only door.

- `clanker repl --preset <name>` does something. The flag was accepted,
  documented in `repl --help`, and listed as valid for `repl`, but nothing
  passed it through: the session opened with no preset, no status pill and no
  `system_prompt_append`. It now seeds the same session preset `/preset <name>`
  sets, and a preset that does not exist or does not parse refuses to open the
  session instead of starting one silently unfiltered.

- A preset's `system_prompt_append` survives the first turn. It was appended to
  the agent's prompt once, after construction, and the per-turn prompt refresh
  then rebuilt the prompt from scratch without it, so the preset persona was
  present for exactly as long as it took to send the first request.

- A whitespace-only hook command in `hooks.json` no longer panics the agent.
  The command validator's trim set was written as a plain string literal with
  unescaped backslashes, so it trimmed the bytes `\`, `t`, `r` and `n` instead
  of whitespace: a command that was a bare tab passed validation, split to a
  zero-length argv, and the runner's warning then indexed `argv[0]` on the
  empty slice. The same literal rejected a whole hooks file for a command
  spelled `nrt`, which disabled every hook for the run. The trim set is
  `std.ascii.whitespace` and the runner's three warning lines no longer index
  an argv they did not check.

- A hook with `"timeout": 0` is refused instead of running without a deadline.
  It passed validation and the host reads a zero timeout as *no* timeout, so
  such a hook could block the turn forever.

- `auto_thinking` with an unresolvable classifier says so. A typo'd
  `agent.thinking_classifier_model` disabled the feature invisibly: the "no
  classifier provider" path logged at debug level, on every turn. It now warns
  once per process, names the spelling that resolved to nothing, and says the
  turn falls back to the configured `reasoning_effort`.

- `kind = "grok"` no longer discards a configured per-model `temperature` and
  `top_p`. The Responses codec read only `RequestParams.temperature`/`top_p`,
  which the agent loop never sets and the web UI's per-run override writes
  past, so a `[models."grok/…"] temperature = 0.2` was dropped on every turn
  along with the PRD 0024 use-case default. It now resolves the same
  three-tier chain the chat-completions wire does, and its
  `max_output_tokens` goes through `clampedMaxTokens`, so the
  half-the-context-window clamp applies there too. Codex's deliberate opt-out
  is unchanged.

- `gemini` no longer keeps its own copy of the sampling precedence chain. It
  spells `topP` inside `generationConfig` itself, but the three tiers are now
  resolved once in `common.resolveSampling`. (The Gemini thinking row is still
  inert: `generationConfig` has no equivalent field and the correct
  `thinkingConfig` shape is not established — see the report.)

- `--dump-config` no longer prints the secret half of an `mcp_servers` header
  whose value contains `=`. The redaction helper served both `env`
  (`NAME=value`) and `headers` (`Name: value`) and preferred `=`
  unconditionally, so a base64-padded credential such as
  `Authorization: Basic dXNlcjpwYXNzd29yZA==` was cut at the padding and
  dumped one character short of whole, onto stdout. The separator now comes
  from the caller, which knows which field it is dumping.

- A `--profile` name with no `profiles/<name>.toml` is now reported as itself.
  The overlay reused the base config's `error.MissingConfig`, so
  `clanker run --profile typo` printed "config.toml not found; run
  `clanker setup` to create one" — naming a file that exists and prescribing a
  remedy that cannot help. The error is now `MissingProfile`, with a log line
  naming the path it looked for.

- `profiles/<name>.local.toml` is now loaded. It is the checkout-private half
  of a named profile, exactly as `config.local.toml` is of the base file, and
  merges last; only `profiles/<name>.toml` was ever built as a path, so the
  file beside it had no effect at all.

- `--dump-config` reports the load error it hit instead of erasing it. It did
  `catch null` and printed one "check config.toml syntax" line for every
  failure, so a missing profile, an unknown `default_provider` and a
  non-integer field were indistinguishable — and the two that have nothing to
  do with `config.toml` still blamed it. It now uses the same per-error hint
  table the normal command path uses.

- `clanker serve --profile <name>` keeps its profile across a hot-reload
  re-exec. `buildServeArgvTail` did not repeat `--profile`, so the rebuilt or
  config-edit-restarted process reverted to base+local with no log line saying
  so. The watcher also validates the profile stack now: the overlay name was
  `threadlocal` and armed on the main thread, so `ConfigWatch`'s spawned
  thread read null and judged a config the process was not running — logging
  "config changed but does not load … keeping the last known good config"
  against a process that was fine, or green-lighting a restart into a config
  that cannot boot. An edit to either half of the named profile is watched too.

- `reports rename` now prints leftover-reference paths that open. The store
  root was joined onto every `ck_fs_grep` hit, but the host already reports
  each hit rooted at the repository, so the one output the verb exists to
  produce named `docs/reports/docs/reports/bugs/<name>.md` for every entry --
  a path that cannot be read or pasted anywhere. The walk existed twice; the
  copy the four numbered stores use had a guard against exactly this, aimed at
  `isPathIn`, which requires a single directory level and so said no for
  `docs/reports/bugs/` -- the only store that nests was the only one the guard
  could not recognise. There is now one walk (`records_grep.collectRenameReferences`)
  behind a nesting-tolerant predicate (`doc_scaffold.isUnder`), and a
  sandbox-runtime test asserts every path the verb prints can be opened.

- `create` on all five record stores now warns when a caller's
  `YYYY-MM-DD-` slug disagrees with the UTC date the store stamps. The stores
  date records in UTC deliberately and the caller types the slug, so east of
  Greenwich a hand-typed slug is off by one for a third of every day; `create`
  held both values and compared neither. The record is still created -- a
  record about an older event is legitimately backdated -- and the reply
  carries `date_warning`, printed by the CLI. The comparison is a pure
  function of (slug, stamped date), so it is tested on both sides rather than
  passing vacuously wherever local time is already UTC.

- `reports append` can now fill `## References`. `appendOrFill` fills a
  section the record carries empty, and `create` seeds that one section with
  `- Investigation: none yet`, so it was the single scaffolded section the
  fill structurally could never reach: a `## References` block always landed
  at the end as a second copy of the heading. A body that is nothing but the
  scaffold's own "none yet" line now counts as empty; one authored reference
  in the section and it is left alone as before.

- `GET /api/events` at the 32-subscriber cap now sends a `503` a strict client
  can actually read. The refusal was one hand-written literal whose
  `Content-Length` said 52 for a 48-byte body, so a client honoring the header
  waited for four bytes that never came and reported a truncated response
  instead of `too many live subscribers` — Python's `http.client` raised
  `IncompleteRead(48 bytes read, 4 more expected)`. `curl` and the browser's
  `EventSource` take the connection close as end-of-body and were unaffected,
  which is why it went unnoticed. The response is now framed from the body at
  comptime, so the declared length cannot drift from it again.
- The web UI Arena view follows a running match again. Its poll tick skipped
  the fetch whenever the `/api/events` stream was up, but nothing publishes a
  `t:"arena"` event, so stage, combatant chips, HP graph and transcript froze
  on the first fetch until the page was refreshed by hand and the elimination
  sequence never played.

- A `kernel` cell now sees the environment the `kernel` tool's `env_allow`
  grants it, built by the same filter `ck_exec` and `ck_job` use. The
  supervisor was spawned with no environment named at all, which left it to the
  `Io` implementation: cells got two platform-injected variables and no `HOME`
  or `PATH`, and on an `Io` that inherits they would have carried every key the
  harness loaded, including API keys the guest is denied through `ck_env`.
  Naming variables in `env_allow` replaces the default set (`PWD`, `HOME`,
  `PATH`, `LANG`, `LC_ALL`, `TERM`, `TZ`, `USER`) rather than adding to them,
  so re-list what a cell still needs. A cell has no `TMPDIR`.
- The `kernel` tool's description, `config.toml` and `docs/configuration.md` no
  longer claim Python cells run under a WASI sandbox. They do not: `ck_kernel`
  reaches an unsandboxed host `python3` supervisor, and the WASI-confined
  function ADR 0010 describes has no production caller, so
  `scripts/setup-python-wasi.sh` does not change what a `kernel` call does.
  The `llm_description` said it too, so the model was being told it as well.
- A `GET /api/events` subscriber that hangs up now releases its live-bus slot
  and its connection thread within one 50ms tick on macOS, instead of holding
  both until the 15s keepalive ping failed to write. The idle tick polled for
  `POLLRDHUP` alone, and macOS has no such constant — so `events` was 0 and the
  poll requested nothing, degrading the tick into a sleep that always answered
  "still there". It now also asks for `POLLIN` and tells EOF from inbound bytes
  with a zero-length `MSG_PEEK`, which additionally catches a peer that shut
  only its write half (a case `POLLHUP` does not report, since the server's own
  half stays open). A page reload opens two streams, so the leak accumulated
  toward the 32-subscriber cap.
- A `clanker-<name>` binary on `PATH` (or under `~/.clanker/plugins/`) is no
  longer exec'd unsandboxed unless `state/cli_plugins.json` names it. The
  Tier 2 dispatcher went through bare discovery with no enabled-list check, so
  a plain `clanker <word>` ran any executable `clanker-<word>` on PATH with no
  opt-in, and *disabling* a sandboxed Tier 1 plugin promoted an unsandboxed
  binary of the same name into its place. `clanker help` now also lists
  `~/.clanker/plugins/` alongside PATH, names the source of each row, and
  marks each one on or off.

- A REPL composer `@path` mention of a file over the 32 KiB cap is truncated
  with a `[truncated]` notice instead of being dropped. The read was
  `readFileAlloc(.limited(per_file_cap + 1))`, and that limit answers
  `error.StreamTooLong` when it is reached or exceeded, so every file at or
  over the cap read as unreadable and the mention was sent to the model as a
  bare `@path` token with no fenced block and no notice. The truncation also
  lands on a UTF-8 codepoint boundary now, so a cut inside a multi-byte
  character no longer puts invalid UTF-8 in the request body and the saved
  session.
- A panic now always terminates the process instead of sometimes turning into
  a silent, unkillable hang. The panic reporter went through `std.debug.print`,
  whose stderr flush re-enters `std.Io.Threaded`; when the panic came from that
  dispatcher (`Syscall.start`'s `.blocked => unreachable`, which a signal
  landing on a pool thread mid-syscall reaches) the flush raised the same panic
  again, with no re-entry guard to stop it — nothing printed, no exit status,
  and nothing for a supervisor to reap, so a crashed `clanker repl` wedged
  instead of dying. The panic line is now written with a raw `write(2)` that
  touches no `std.Io`, and `handlePanic` latches per thread and `abort()`s on
  re-entry the way Zig's own default handler does.
- A `kernel` cell now returns as soon as it finishes instead of being held for
  the whole of `timeout_ms`. The timeout watchdog slept the entire budget and
  only then checked whether it was still needed, and the round trip joins that
  thread before returning, so a cell the supervisor reported at 5 ms took the
  full 10 second default. The watchdog now waits on an event the reader sets
  when the round trip ends; the timeout itself and its SIGTERM are unchanged.
- A `kernel` cell that writes to file descriptor 1 no longer breaks the reply.
  `subprocess.run(...)` without `capture_output`, or a bare `os.write(1, ...)`,
  put its bytes in front of the supervisor's JSON line and the host returned a
  parse error for a correct cell; `run_cell`'s `sys.stdout` swap is
  Python-level and never covered the descriptor. The supervisor now keeps the
  line protocol on a descriptor of its own and repoints fd 1 and fd 2 at
  capture files, so descriptor-level writes are returned as the cell's
  `stdout`/`stderr` instead. A child's `stderr` used to go to `/dev/null` and
  is now reported too.
- `clanker schedule` read stepped day fields (`*/2`) as if they were bare
  stars in the day-of-month/day-of-week rule: `0 0 */2 * 5` fired every
  Friday instead of Fridays on an odd date, and two stepped day fields
  (`0 0 */2 * */3`) fired every day. The star flag is now Vixie's — set
  whenever the field starts with `*` (including star-led lists like `*,5`)
  and a starred field ANDs with the other one — so these specs fire on the
  intersection crontab(5) means.
- Image attachments now reach a coding-agent backend (`--backend` /
  `[agent] backend`) over HTTP. `session/prompt` carries one ACP `image`
  ContentBlock per attachment after the text block, `POST /api/run` no longer
  refuses a backend run because the configured *LLM* model lacks the `image_in`
  capability, and it no longer swaps in a vision LLM provider that is not going
  to be called. A headless fallback with images refuses with a named error
  rather than spawning the child text-only, since no vendor's headless image
  argv is pinned yet. The TUI and the web UI model picker are unchanged, so
  PRD 0043's Goal 6 is not complete; see its Known issues.
- The two `zig build e2e` pty journeys no longer need a locally patched
  dependency to complete their terminal-capability handshake. `answerQueries`
  waited for the XTSMGRAPHICS sixel geometry query and gated its DA1 answer
  behind having answered it; upstream vaxis 0.6.0 declares that query and never
  sends it (only `patches/vaxis-sixel-graphics.patch` does), so DA1 went
  unanswered even though it had arrived, and both journeys failed in any tree
  where `scripts/apply-patches.sh` had not run — every fresh worktree, since
  `zig-pkg/` is gitignored. The geometry query is now answered when present and
  skipped when absent, and the handshake's 60-iteration budget is a 5s
  wall-clock deadline (`pump` returns the moment bytes are available, so an
  iteration count is not a timeout).

- Hitting `agent.max_iterations` in the REPL now lands the turn on the
  model's partial work instead of rendering `[error: ...]` and discarding
  every tool round: the last prose the model produced renders as the partial
  answer, followed by a note naming the limit and offering to continue with
  "keep going" (the transcript persists across turns, so the follow-up
  resumes where the run stopped). The turn receipt still prints. Other limit
  errors (token budget, compaction stall) keep the error path.
- DAP stop events are attached to the request that caused them. Event
  buffering used to decode only bytes a previous blocking read had
  over-read, so a `stopped` event sitting unread in the OS pipe was
  invisible until the next request's response wait swallowed it — `continue`
  to a breakpoint essentially never reported its own stop, which surfaced on
  whatever tool call came next. Draining now polls the pipe without
  blocking, and resuming ops (`continue`, `step_*`, `next`, `pause`) wait up
  to `HandleOpts.stop_wait_ms` (default 1000ms, 0 disables) for a
  stop-shaped event; expiry is not an error and never kills the adapter.
- Arena Battle Royale no longer pays the weak-confidence floor for an
  untargeted `concede` or `final_stand`. The move prompt requires `target`
  only for attack, block and counter, and scoring ignores the target of the
  other two — yet a protocol-following untargeted concession was recorded
  `weak` at confidence 0.15 and misrepresented in the verdict. Untargeted
  offensive moves keep the documented default-aim-plus-floor behaviour.
- A corrupt or unreadable `state/tui_plugins.json` / `state/cli_plugins.json`
  now logs a warning naming the file and what failed instead of silently
  treating every TUI/CLI plugin as disabled. The empty enabled-list fallback
  is unchanged, a missing file stays silent (off-by-default is the normal
  state), and the next successful toggle rewrites a clean file — the
  behaviour PRD 0012's failure modes promise, already delivered for
  `state/webui_plugins.json`.

- `zig build e2e` builds and runs on macOS. `tests/e2e/pty.zig` allocated its
  pty with `/dev/ptmx` plus the Linux-only `TIOCSPTLCK`/`TIOCGPTN` ioctls and
  sized it with `posix.T.IOCSWINSZ`, which the Darwin branch of `std.c.T` does
  not declare, so the file failed to compile and took all 38 e2e journeys with
  it. It now allocates the pty through POSIX `posix_openpt`/`grantpt`/
  `unlockpt`/`ptsname` and holds one slave fd open on non-Linux targets, where
  a master is not a terminal until a slave has been opened and a released
  slave leaves the master hung up. The master is also non-blocking now, with a
  bounded `POLLOUT` wait: both sides of the resize journey write more than they
  drain, and a blocking master deadlocked the two of them against each other
  with no timeout to end it. Teardown drains the pty while reaping and gives up
  rather than blocking, and a repl that stops reading its tty now fails the
  resize journey with a diagnostic instead of hanging it: a wedged child used
  to hang the suite rather than fail it, in two separate unbounded waits.
- An unknown provider `kind` in `config.toml` now fails with a diagnostic
  naming the provider, the offending spelling, and every kind the binary
  accepts. It used to emit only the generic "configuration validation failed
  (UnknownProviderKind); inspect the setting named by the preceding
  diagnostic" line, with no preceding diagnostic to inspect — most
  misleading when a stale binary reads a config written for a newer one.
- `improve_history` reads the improve ledger over a new `ck_improve_history`
  host channel instead of through the sandbox filesystem, and its
  `fs_prefixes` grant is gone. Inside a `clanker improve-self` worktree that
  path is a symlink to the checkout's file, which the sandbox's no-follow walk
  refuses even for a granted leaf; the guest reported the refusal as
  "no history yet", so every improve run was told it had never attempted
  anything. An unreadable ledger is now a named read error rather than an
  empty history.
- `clanker`'s eval kernel no longer claims a confinement it does not have.
  Every `kernel` reply carries `"sandboxed": false` with the reason, and
  starting a kernel supervisor logs the exposure. ADR 0010 described a
  WASI-sandboxed Python kernel, but the confined code path has no production
  caller: cells run in a host `python3` process with the harness's full
  filesystem and network access, and `exec_allow` applies to neither `%%bash`
  nor `subprocess`. This is a reporting fix and adds no sandbox; the gap is
  tracked in
  `docs/reports/bugs/2026-08-23-kernel-persist-path-is-unsandboxed.md`.
- The improve loop's tool-descriptor gate now covers every configured
  in-tree `tools_dir` entry instead of only the hardcoded `tools/manifests`.
  A descriptor staged in a second in-tree directory used to reach a promoted
  checkout without the duplicate-name/missing-wasm check; out-of-tree
  entries (absolute, or escaping with `..`) remain outside the
  staged-worktree gate by design.
- `preset.toml` files are parsed by the same TOML parser as `config.toml`
  (`util/toml_bridge.zig`) instead of a line-based approximation. The
  approximation silently read a `tools_allow`/`tools_deny` written across
  multiple lines as empty, which flipped a preset's access posture (an empty
  deny list exposes every write-capable tool), truncated strings at the first
  escaped quote, and mistook any key starting with a known key's name for that
  key. An array field holding the wrong shape now fails the load loudly rather
  than reading as empty.
- `clanker auth login` now streams and flushes its authorization URL and
  device code before entering the polling loop. It previously buffered all
  login output until authorization completed, leaving the terminal apparently
  blank while waiting for a code the operator had never been shown.
- The shipped Codex OAuth provider now defaults to the subscription-supported
  `gpt-5.6-sol` SKU instead of the API-only `gpt-5.6` alias, which the Codex
  backend rejects after an otherwise successful ChatGPT login.

- ACP hang handling actually unblocks a silent child: `ChildTransport.readLine`
  used to wait forever on `readStreaming`, so `timeout_ms` between reads never
  fired and hang → cancel → failed ACP node → headless could not run. A watchdog
  now SIGTERMs the child when the budget elapses.
- `clanker goal --backend`, TUI `/goal`, and a goal-loop `POST /api/run` used
  to parse or persist the backend then still call `Agent.run` for each work
  turn. Work turns now go through `runIfBackend`.

- A non-streaming `POST /api/run` never claimed a steer slot, so every
  `POST /api/steer` naming that run answered 404 `no_run` while the run was
  still going — the same answer a finished run gives, so a caller could not
  tell "already over" from "never steerable". Only the streaming branch called
  `runRegister`; both branches do now.

  `runRegister` also returned a bare `bool`, collapsing three unrelated
  outcomes into one answer: no key to register under, every one of the 64 slots
  taken, and a key over the length cap. It returns a `SteerRegister` enum
  (`ok`, `unkeyed`, `key_too_long`, `table_full`) instead, so an unsteerable run
  can be explained rather than merely observed. None of them stops the run: an
  unkeyed one-shot has nothing to address it by and is the ordinary case.
  Covered by `tests/e2e/steer_nonstreaming_test.zig`, which holds the mock
  provider's answer open so the steer lands while the run is provably alive.

### Added

- A bundled `Ponytail` skill brings the minimal-code ladder and its review,
  audit, debt, gain, and help commands into clanker's native skill system. A
  matching `SessionStart` hook activates it for clanker agents without a
  separate plugin runtime.

- The Web UI Models page now has an enable checkbox for every configured
  model. Disabled models keep their full configuration in `config.local.toml`
  but disappear from the chat model selectors until they are enabled again.
  The shared Web UI type scale is also more legible, and redundant/generated
  helper copy was removed from the empty chat and Models surfaces.

- Native Codex, Grok, and Claude provider plugins now support clanker-owned
  OAuth alongside their usual API-key environment variables. `clanker auth
  login|status|logout` runs device authorization for Codex/Grok and PKCE for
  Claude, stores refreshable tokens as owner-only files under
  `agent.state_dir/oauth`, rotates refresh tokens in process, and sends model
  traffic directly through the Responses or Anthropic Messages transports.
  An available API key wins, making the same provider usable interactively
  with OAuth and in CI with a key. This path does not use ACP, launch a vendor
  CLI, or import another application's credentials.

- `--backend` / `[agent] backend` on `run`, `repl`, and `goal` (and the
  same field on `POST /api/run`) drives a local coding-agent CLI — `grok`,
  `claude`, or `codex` — instead of the in-process LLM loop. clanker is the
  ACP *client* (initialize, authenticate when required, session/new,
  session/prompt, session/update, session/request_permission); first-party
  headless spawn (`grok -p`, `claude -p`, `codex exec`) is the fallback when
  ACP is missing, hangs, or a vendor update breaks it. The vendor credential
  never enters clanker. The web UI model picker and TUI `/model` list
  installed CLIs (PATH / configured command) in a "Local coding-agent
  backend" group. Unset keeps today's in-process loop. ADR 0032 / PRD 0043.

- The streaming `POST /api/run` response emits an `llm_start` control
  frame at the top of each agent iteration, carrying `served_by`, `model`
  and the zero-based `iteration`. The web UI's live run graph has always
  had a handler for that event and no server path emitted one, so
  iterations were drawn without the model that served them. `served_by`
  is who the turn started on; the `done` trailer stays the record of who
  finished it, since the fallback chain can repoint the provider
  mid-turn.

- `clanker worktree prepare [<path>]` and `clanker worktree add <path>
  [<base>]` give a worktree made by hand with `git worktree add` the two
  gitignored files it does not inherit: `.env` and `config.local.toml`.
  Without them every verb inside that worktree resolved the committed
  `config.toml` `default_provider` with no key behind it, so `clanker commit`
  fell back to the degraded one-commit plan that `--yes` refuses and every
  other model-calling verb failed the same way. The worktrees clanker makes
  for itself already linked both files (`src/improve/worktree.zig`); the
  worktree the repository rules require of every agent session had no such
  step. `add` also fetches `origin` and branches from the remote tip, which
  is what those rules ask for. The new `[agent]
  worktree_link_local_config = false` refuses the link for a checkout whose
  worktrees must not reach the main tree's credentials; it is read from the
  main checkout's config, since the worktree cannot see `config.local.toml`
  yet. Guest wasm is deliberately not linked — a build writes into
  `zig-out` — so `prepare` reports whether `zig-out/tools` is built and
  prints the `zig build tools` line instead.

- `clanker gate` runs a `js-suite-coverage` gate: every `ui/**/*.test.mjs`
  on disk is registered in `build.zig` as a `node --test` step. The web UI
  suites are named there one by one — node has no working directory mode
  (`node --test ui/app/` resolves the positional as a module path and fails
  on the directory itself) — so a suite nobody adds a line for is never run,
  and a green `zig build test` cannot show it. Sweeping the suites by hand
  is `node --test 'ui/**/*.test.mjs'`.

- The web UI composer's Advanced fold gains a per-chat reasoning-effort
  select (`none`/`low`/`medium`/`high`/`max`, default leaves the
  classifier, per-model setting and sampling profile in charge). It rides
  `POST /api/run` as `reasoning_effort` — the request-shaped
  `--reasoning-effort` / TUI `/effort` pin — persists in the browser, and
  a pinned value stays visible on the fold's summary while it is closed.
  An unknown value is refused with a 400.

- Composer `@rel/path` mentions expand into fenced file bytes on REPL
  submit (dotenv, `..`, and absolute paths are refused; files over 32 KiB
  truncate). Markdown `clanker session export` when the destination ends
  in `.md`. `/compact [hint]` schedules a history compact on the next
  turn and can tell the summarizer what to keep.

- `providers.<name>.extra_body`: a JSON object merged last into
  `openai_compat` and `azure_openai` chat bodies so gateways that need
  non-standard fields (NVIDIA NIM `chat_template_kwargs`) can enable
  thinking. Refused at config load if it is not an object. Same-name keys
  overwrite generated fields.

- Prompt-cache idle warning: after a cache-accounted completion, a pause
  longer than five minutes on *that* provider/model logs that Anthropic's
  prompt cache is likely cold before the next send, and an unexpected
  miss (warm expected, `cache_hit` 0) is logged after. The stamp is
  independent of `modules.token_stats`.

- `repo_search` rg, ast-grep, and host-fallback (`ck_fs_grep` when rg is
  missing) hits include `symbol` / `symbol_kind` / `symbol_line` for the
  enclosing declaration (Zig first, with a `def`/`function`/`class`
  fallback) so the model can see file shape without a follow-up read.

- `clanker rfc create` now passes a fourth positional as the research
  note path, so `create` can link `docs/research/` the way the `rfc` tool
  already did.

- `clanker doctor` gains a `worktree links` section when it runs inside a
  linked git worktree: it names the main checkout and asserts that each
  gitignored entry the worktree is given as a symlink back to that checkout
  is still a symlink. `state/improvements.jsonl` and `state/history` fail
  when they are a private copy — that is the improve ledger silently
  detaching, where a run's writes are thrown away with the worktree — and
  `.env` / `config.local.toml` warn, since a worktree may hold its own on
  purpose. Every line prints the path it should point at. Nothing asserted
  this before: `atomic_write.writeFile`'s unit tests pin the one writer the
  defect lived in, not the invariant that the links survive.

- `rename` on the four record stores that lacked it: `clanker rfc rename`,
  `clanker adr rename`, `clanker prd rename` and `clanker research rename`,
  matching `clanker reports rename`. Each moves a record inside its own store
  and rewrites its inventory link in the same call, then lists the in-store
  files still naming the old record; mentions elsewhere in the tree are
  outside the tool's grants and are called out as such rather than missed
  silently. Renaming by hand with `git mv` leaves the inventory link dangling,
  which is why this is a verb.

  For the three numbered stores the record keeps its **number**. RFCs, ADRs
  and PRDs are cited by number in prose across `CLAUDE.md`, `AGENTS.md` and
  source comments, and a scan of filenames cannot see those citations — so
  moving a number would break exactly the references `rename` exists to
  protect, and an ADR's `superseded` forward link is only as stable as the
  number it names. The slug is a name, the number is identity. A new slug
  carrying a *different* number is refused by name rather than silently
  ignored, since a caller who typed one meant to renumber and needs telling
  that is not a thing. The unnumbered `research` store has no such rule.

### Fixed

- `clanker reports --help` states the byte caps the tool enforces, in their
  own LIMITS section: title 180, summary 500, status note 500, search query
  240. They were discoverable only by exceeding one and reading the refusal.
  A test pins the numbers against `tools/zig/reports.zig`, so a cap that
  moves in the guest cannot leave the help quoting the old one.

- `POST /api/steer` reaches every run the keys it names address, not the
  first slot found: two concurrent runs registered under one goal id — a
  goal resumed at serve startup while a browser streams the same goal —
  left one of them silently unsteerable behind a 200. A body naming both
  `goal` and `session` is now an AND, so a pair belonging to no single run
  addresses nothing instead of steering whichever run matched one half,
  and a body naming neither key cannot broadcast. The success body carries
  how many runs took the message: `{"ok":true,"delivered":N}`.

- `improve-self` survives a reasoning model that answers entirely in
  `reasoning_content` with empty `content` (`finish_reason: stop`). The
  engine used to re-ask the identical question (reasoning still on), the
  model re-buried its answer in chain-of-thought, and every attempt of an
  iteration failed the same way. A response with empty content now pins the
  next proposal/plan call to `reasoning_effort: "none"` — forcing the JSON
  answer into `content` — and the pin clears as soon as content comes back.
  Plan and proposal both honor it.

- REPL slash commands and `!` shell escapes typed while a turn streams are
  no longer queued as steering text. `/help` and `/quit` run at once (the
  exit path stops and joins the in-flight worker); every other command
  is answered with a notice that it runs once the turn is idle (Ctrl+C
  stops it) and the line is repeated so it can be re-sent; a typo'd
  `/command` gets the same unknown-command diagnostic as at the idle
  prompt. Before, the model read `/help` as a course correction and the
  user got no command.

- The web UI conversation rail states a failed load instead of showing the
  empty state. `loadSessions()` caught every fetch and JSON failure and
  rendered an empty list, so a stopped server, an auth failure and a
  genuinely empty history were indistinguishable. The rail now shows
  "Could not load conversations: <reason>" with a Try again button, and
  says so in the live region too; `modules.sessions = false` is reported
  separately as a switched-off module, with no retry, because retrying it
  answers the same thing forever. `readJson` carries the HTTP status onto
  the error it throws, which is what tells those two apart.

- A mid-run steering message is no longer saved as the user having typed
  the harness's framing sentence. `POST /api/steer` and the REPL composer
  each prefixed the message with "[The user interjected while this run was
  in progress...]" and the run stored that text verbatim as a `role=user`
  message, so every transcript reader — the web UI, exports, search — read
  the harness's words as the user's. Senders now queue the user's words
  alone; the agent loop applies the framing to the *request* copy only, and
  the saved message carries a `steered` marker instead (persisted in the
  session store, emitted by `GET /api/sessions/<id>`, rendered by the web
  UI as the interjection it was). The bytes the model receives are
  unchanged, on the steering turn and on every later one. Transcripts saved
  before this change still render correctly: the web UI falls back to
  detecting the framing sentence in the text.

- The web UI composer's model and reasoning-effort choices are pinned per
  conversation instead of per browser. Both were single `localStorage` keys,
  so changing the model while reading one chat silently changed what every
  other chat and every other tab sent next. A conversation is pinned when a
  select is changed while it is open, or by its first turn, to whatever it
  ran on; switching conversation puts its own values back. The two old keys
  stay as the default a *new* chat starts from, a fork or import carries the
  pin onto the new id, and deleting a conversation drops it. The effort
  fold's summary and the composer hint say "pinned for this conversation"
  again, which is true once more.

- The web UI chat's Archive, Delete and Rename buttons work again and say
  what they did. Their feedback went only to a visually hidden live region,
  so every outcome — including the silent refusal when the conversation was
  missing from the picker's stale list — looked like the button doing
  nothing; outcomes now also toast. The handlers refresh the conversation
  list and retry once before refusing, and the list itself refreshes after
  every run outcome instead of only fully finished ones, so a stopped or
  half-streamed first turn no longer strands the page with dead session
  actions.

- Archiving or renaming a conversation that was never saved answers 404
  again. The SQLite session-store port opened metadata edits with
  `SQLITE_OPEN_CREATE`, so an unknown id "succeeded", changed nothing
  visible, and left a junk titleless `<id>.db` behind that the listing then
  filtered out.

- Deleting a conversation now also removes its rows from the cross-session
  search index (`state/session_fts.db`). Before, the full text of a deleted
  transcript stayed findable there indefinitely.

- A steering message typed into the REPL composer mid-run is now visible
  the moment it is queued: the transcript echoes
  `steering queued (N pending): <text>` immediately, and the status line
  shows `N steer queued` while any are waiting, counting down as the run
  drains them. Previously the echo went through a buffer only flushed
  after the turn ended, so the typed text vanished with no feedback until
  then. The queue also gains the server's 16-message ceiling; a steer over
  the cap is refused with a line that repeats the message text.

- A `POST /api/run` carrying a `temperature` or `top_p` override no longer
  corrupts the serve-lifetime provider config. The handler's provider struct
  copy still shared the models map's entries with the config, so one
  override wrote through as the model's new default for every later run —
  and a map growth left the config pointing into the request's arena, after
  which every run naming a model of that provider got 400 `no such model
  for that provider` and the next `GET /api/providers` crashed the server.
  The override is now cloned request-local.

- The web UI chat now names who answered each turn: the turn footer shows
  the provider and model from the run's `done` event (plus the pinned
  reasoning effort when one was set). Before, nothing in the chat reflected
  a mid-conversation model or effort switch, so a switch that applied
  correctly still looked like it had been ignored.

- Post-launch debug ops (`continue`, `stackTrace`, `variables`, ...) no
  longer block a run forever when the adapter goes silent: every request
  runs under the new `debug.request_timeout_ms` (default 15000 ms, `0`
  disables), with the same kill-and-reap expiry as the launch bound.
  `disconnect`/`terminate` treat the timeout as success with a note —
  teardown wanted the adapter gone and the expiry killed it.

- The chat composer's steer row now keeps a visible ledger of every
  steering message sent for the running turn (sending / queued / applied /
  failed per entry), so a second message no longer looks like it replaced
  the first — the server always queued them all (FIFO, 16 per run); the
  client just kept no record. The `[ steering applied ]` transcript line
  now echoes which message landed, messages still queued when the run ends
  are called out as never applied, a reloaded transcript renders a steered
  message as `[ steered mid-run: … ]` inside the turn it steered instead
  of impersonating a typed user turn (and no longer marks the real
  question unanswered), Ctrl+Enter can no longer double-send the same
  text, and the steer box gets the same 8000-character cap the goals
  view already had.

- `debug.launch_timeout_ms` actually bounds a debug launch. The whole
  launch handshake (initialize + launch/attach) runs under the configured
  cap; a silent or wedged adapter is terminated (SIGTERM, then SIGKILL
  after a short grace), reaped, and the tool returns a timeout error
  instead of blocking the run forever. `launch_timeout_ms = 0` disables
  the bound (PRD 0017 known issue).

- The REPL no longer dies with `panic: Invalid free` on the first `[ERROR]`
  log record of a session (a failed provider request, a sandbox refusal).
  The transcript log sink stored `sanitizeAlloc`'s no-copy alias of the
  logger's stack buffer and the draw loop then freed that stack address;
  the sink now owns a copy of every record it buffers.

- Chat tools answer a denial and a bad argument with actionable text:
  `rooms` and `todo_*` name their fields (the todo messages point at the
  run's private list and at `kanban_*` for shared work), chatrooms-off
  names `modules.chatrooms` / `chatrooms.on` and the restart the way the
  board already did, and a chat-access denial names the rebuild instead
  of a bare `SandboxDenied` (PRD 0001 known issue).

- Session end deletes `state/kernels/<session-id>/` once the session's
  processes are reaped, and sweeps orphan kernel directories older than
  `kernel.cleanup_delay_ms` whose session has no live process. Directories
  used to pile up forever; the knob was parsed and never read (PRD 0016
  known issue).

- DAP `disconnect` honors `debug.disconnect_timeout_ms`: the adapter gets
  that window to exit on its own after the disconnect response before the
  registry SIGTERMs it. It used to be killed immediately, making the
  config knob a no-op (PRD 0017 known issue).

- `clanker improve-self` no longer dies with `ProposalRequestFailed` when the
  primary provider goes down or goes quiet: its proposal and plan LLM calls
  now route through the same `chatWithFallbackChain` the agent loop uses, so a
  down primary falls back to a configured `agent.fallback_providers` provider
  instead of aborting the whole improve run after the deadline. The
  caller-thread `chatWithDeadline` ceiling (`agent.request_timeout_ms`) is
  preserved, so a provider that accepts and goes silent still aborts rather
  than hanging
  ([bug](docs/reports/bugs/2026-08-18-improve-engine-llm-calls-have-no-deadline.md)).

- The `UnknownProvider` hint no longer claims the name is missing from
  `config.toml`: providers merge from `config.toml` + `config.local.toml`,
  so a provider defined only locally made the old wording a false lead —
  it sent the vertex HTTP 400 re-evaluation to the wrong file. The hint
  now names the merged config.

- The parallel tool worker builds its sandbox through `host.sandboxFor`
  instead of a hand-rolled `Sandbox` literal, which had drifted to omit the
  descriptor's `session` grant. Session tools (`sessions`, `session_search`,
  `session_export`) running in parallel were denied `ck_session`, so the
  `session_search` capability eval failed and improve-self rejected every
  staged tree. Delegating to the single source of truth also restored
  `network_from_config` and the research `web.allow` hosts on the parallel
  path.

- `DELETE /api/sessions/<id>` now deletes the conversation's spills and its
  exported transcript, not only `state/sessions/<id>.json`.

  Both stores hold the same conversation text under the session's own name:
  `state/spills/<session>/` keeps the verbatim middles of tool results the
  request pruner dropped, and `state/exports/<id>.html` is the whole
  transcript rendered for sharing. Deleting a session left both on disk, so
  a deletion did not delete the content it was asked to. `janitor` ages
  spills out but deletes nothing on its own (ADR 0008) and never looked at
  exports. The deletes go through the guests that own those paths, as new
  host-internal ops (`spill` `forget`, `session_export` `forget`).

- Two log lines stopped echoing payloads onto stderr: a malformed `ck_docker`
  tool call logged the whole guest input (container names, mounted host
  paths, exec argv) and a failed synchronous subagent logged the operator's
  task prose. Both now log the byte count beside the error, as `ck_chat`
  already did.

- The TUI no longer leaks CSI escape-sequence parameter bytes as visible
  text. `sanitize.zig` (`writeSanitized`, `sanitizeAlloc`) and the
  transcript's `cardPreview` consumed OSC sequences whole but stripped only
  the ESC byte of a CSI sequence (`ESC [ params final`), so `\x1b[31mred`
  rendered as `[31mred`. Both now consume CSI whole, and `syntax.zig`
  strips the whole line before tokenizing (the Zig tokenizer splits a lone
  ESC from the `[2J` that follows, which would otherwise still leak the
  parameters). This is the improvement the improve-self loop tried five
  times to land and failed because each patch only touched `sanitize.zig`.

- `clanker reports status` no longer keeps the old text of a multi-line
  TL;DR bullet. `findTldrField` in `tools/zig/doc_scaffold.zig` returned
  `line_end` at the bullet's first `\n`, so `replaceTldrField` wrote the new
  value and then re-emitted every continuation line of the old one, leaving
  two contradictory accounts stacked under one bullet with nothing reported.
  A markdown list item's indented continuation lines belong to the item, so
  `findTldrField` now extends over them — non-blank, indented deeper than the
  marker, stopping at the next bullet, a blank line, or the section end — and
  `tldrField` reads the bullet whole. `replaceFirstLine`, which handles the
  `## Status` section, stays deliberately first-line-only: there the prose
  underneath explains what the state means and must survive.

- `clanker rfc checklist` prints the `rfc` tool's own next steps, which the
  CLI renderer dropped: the questions came out and none of the guidance that
  turns the answers into an RFC. That guidance now also states what the
  option set has to contain (two real candidates, the status quo among them,
  one out-of-the-box possibility), that the record closes with a `recommend`
  carrying a confidence from 0 to 10, and that a claim taken from a
  `docs/research/` note is unverified until its own cited source is reopened.
  Long sentences wrap between words instead of at the terminal margin, sharing
  one wrap helper with `clanker prd checklist`. Two `rfc` fixes ride along:
  `create`'s seeded "Seeded from" link was written as `research/x.md`, which
  resolves to `docs/rfcs/research/x.md` and is dead, and `clanker rfc --help`
  never named the fourth `create` positional that takes the research note.

### Added

- **Sessions moved to SQLite**: one database per conversation
  (`state/sessions/<id>.db`) holds the session record, the transcript and an
  **append-only event stream** (system prompt, task, assistant replies, tool
  calls/results, LLM calls, reasoning, compaction), INSERT-only by trigger.
  The JSON transcript format is gone. Sandboxed tools read sessions through a
  new host channel (`ck_session`, `session: true` descriptor key); the
  sessions/search/export tools keep their interfaces. Mesh peers replicate a
  session's event stream over HTTP (`GET|POST /api/sessions/<id>/events`) with
  dense per-stream seq cursors: appends accepted at cursor+1, duplicates
  dropped, gaps reported for backfill ([ADR 0033](docs/adrs/0033-sessions-are-per-session-sqlite-databases-with-an-append.md),
  [PRD 0044](docs/prds/0044-per-session-sqlite-store-with-an-append-only-event-stream.md)).
  **The four open items shipped** (2026-08-20): automatic fan-out
  (`session_sync.pushTail` runs after every session save), serve-start
  backfill (`session_sync.backfill` at serve start, gap resend on 409), a
  cross-session FTS5 trigram index (`session_fts.zig`, maintained on save,
  linear-scan fallback), and replica transcript projection
  (`session_sync.pullTranscript`, so a peer resumes a session rather than
  only auditing its events).

- Sessions record the **system prompt snapshot** the model was running
  against (`system_prompt` on the stored session, saved from the agent's
  built prompt on every save path: REPL, `run --session`, serve). Session
  export renders it as a System prompt section, so an exported transcript
  shows what the model saw, not just the visible chat. Old sessions decode
  unchanged (the field is absent).

- **TUI slash-command plugins** (PRD 0012): one `{command, help, tool,
  args}.json` in `tui-plugins/` (config `agent.tui_plugins_dir`) becomes a
  `/command` that dispatches to a sandboxed tool, listed in `/help` and the
  palette like a built-in. Enabled via `state/tui_plugins.json` (default
  off); `/tui-plugins` lists and toggles.

- **CLI plugins** (PRD 0012): `clanker <name> [args...]` for a short word
  that is not a built-in command resolves an enabled Tier 1 manifest in
  `cli-plugins/` (config `agent.cli_plugins_dir`; the named sandboxed tool
  receives the remaining argv as `{"args":[...]}`), then a Tier 2
  `clanker-<name>` binary on PATH or `~/.clanker/plugins/` (exec'd, stdio
  inherited). A built-in `Command` is never shadowed; `clanker help` lists
  both tiers marked external.

- **`presets/minimal.toml`** ships the DeepSeek Harness Minimal-mode shape:
  an allowlist of shell + file tools only (`exec`, `read_file`,
  `edit_file`, `list_files`, `find_files`, `file_ops`, `text_diff`,
  `spill`), runnable with `clanker run --preset minimal`.

- `clanker config get <key>` / `clanker config set <key> <value>` read and
  pin one dotted key of the merged config; bare `clanker config` dumps
  config.toml + config.local.toml raw. The `config` tool gains the same
  `get`/`set` actions, so the agent can pin a setting too.

  Every flag with a persistent twin in config (say `--reasoning-effort` and
  `[agent] reasoning_effort`) previously needed config.local.toml edited by
  hand, and `--dump-config` could show the merged result but not write
  anything back. `set` writes config.local.toml only — never config.toml —
  replacing one line and leaving the rest of the file byte-identical,
  comments included. It refuses a key the loader's schema does not know
  (where a typo'd TOML key is silently ignored), refuses a value that does
  not parse as the key's type, and refuses the quoted-key table sections
  (`providers`, `models`, `mcp_servers`). The CLI verb additionally reloads
  the config after the write and restores the file when the loader's
  semantic validation refuses the value (an enum spelling the type check
  cannot catch would otherwise fail every next invocation at load time).
  Closes the missing-tool report
  `docs/reports/investigations/2026-08-17-missing-clanker-tool-no-verb-reads-or-sets-a-config-key.md`.

- `GET /api/metrics` reports background jobs and LLM latency. Two blind
  spots on the serving path close with it.

  `jobs` (`starts_total`, `completions_total`, `errors_total`, `active`)
  covers `ck_job` exec children and background subagents, which had no
  counter and no log line of any kind. `ck_job` is start-and-forget, so
  nothing is obliged to call `wait`, and a completed row is dropped once it
  ages past `max_retained_done` — a background job that failed left no
  trace anywhere. `active` is a gauge, so a job that starts and never
  finishes is visible as drift rather than only as a missing completion.

  `llm` gains `timeouts_total` and a seconds-scale latency histogram
  (`latency_ms_sum` plus `le_1000`/`le_5000`/`le_15000`/`le_60000`). The
  per-call duration already reached `state/token_stats.jsonl`, but no
  aggregate reached the endpoint, so "is the provider slow or down?" could
  only be answered by parsing a log file. Timeouts are counted apart from
  errors because a lapsed deadline is the one provider failure retrying the
  same endpoint cannot fix. Both are recorded ahead of the
  `modules.token_stats` guard: turning that module off no longer also turns
  off the latency signal.

- Background job state transitions are logged: start (`info`, with the
  session and `argv[0]`), clean exit (`debug`), and non-zero exit, signal,
  failed reap, or subagent error (`warn`). Each line carries the log
  context of whoever started the job, captured at start — the correlation
  id is threadlocal and does not survive `std.Thread.spawn`, so a waiter
  thread reading it live would report nothing. A reap failure used to
  return silently, leaving `wait` to answer a bare "wait failed" with the
  reason recorded nowhere.

### Changed

- A panic writes one structured `[ERROR] ts_ms=… request_id=… panic: …`
  line before the usual trace. Zig's default panic output has no level, no
  timestamp and no correlation id, and spans many lines, so a `clanker
  serve` crash was unparseable by the collector that would raise the alert.
  The request id is threadlocal, so a panic on a connection thread names
  the request that caused it. The line is written without `log_mutex`
  (`log.logPanic`): a panic can land on a thread already holding it, and
  deadlocking there would turn a crash into a hang.

- `clanker gate` runs a `sandbox-abi` gate: every `pub fn ck…` in
  `src/sandbox/host.zig` must be registered with the zwasm linker in
  `src/sandbox/runtime.zig`. An unregistered host function is not a
  capability waiting to be granted, it is unreachable: no guest can import
  it, no descriptor can name it, and nothing compiles it, so it rots against
  zwasm API changes while still reading like a live part of the ABI.
  `zig build` stays green either way, which is why this is a gate.

- `gauntlet` tool: cycles through review prompts from two sources —
  this project's own `docs/prompts/*-review.md`, and a local mirror of
  github.com/maci0/gauntlet's `prompts/*-review.md` — entirely
  inside clanker, replacing that repo's `review-loop.py` as the driver.
  `{"action":"sync"}` mirrors the external repo; `{"action":"list"}`
  returns the merged, deduplicated rotation; `{"action":"next"}` advances
  `state/gauntlet_state.json` and returns the next prompt's text (a
  project-specific review always wins the resolve over a same-named
  generic one); `{"action":"current"}` reads the same without advancing.
  The tool only picks; running the returned prompt is a plain `clanker
  run`, and repetition comes from `clanker schedule`, not a loop inside
  the tool.

- `agency_sync` tool: mirrors persona files from
  github.com/msitarzewski/agency-agents into `agency/<division>/<file>.md`
  (verbatim) plus a catalog at `agency/index.json` (division, path, name,
  description per persona). These are not clanker skills and nothing here
  is ever injected into a system prompt — the corpus is ~150 personas
  across 17 divisions, and always-loading that would bloat every turn.
  `{}` syncs every division; `{"division": "..."}` scopes to one and
  merges into the existing catalog rather than replacing it.

- The web UI's theme picker is keyboard-operable and shows each palette's
  colour. ArrowUp/ArrowDown walk the option list and wrap at both ends (the
  modulo walk `core/modelpicker.js` already used), closing the picker hands
  focus back to the theme toggle instead of dropping it to `<body>`, and every
  row carries a dot filled with that theme's `--bg` (`system` keeps an empty
  ring, so labels stay aligned). Enter and Space activate a row through the
  option's own `<button>`, not a hand-rolled key handler.

- Tool descriptors may declare `prompt_guidance`: binding usage rules the
  harness injects into the system prompt's new `## Tool guidance` section
  (ahead of the catalog, for every enabled non-internal tool that declares
  one) and echoes as `guidance` in the `load_tools` reply, so the rules are
  read again at the moment the tool is loaded. The `rfc` tool is the first
  user: its guidance states that a claim is verified only by opening the
  original source it cites — a `docs/research/` note is a summary, not a
  source — after a live run interpreted "check against its own source" as
  re-reading the note. The rfc tool's own create/seed messages were
  tightened the same way.

### Changed

- `POST /api/plugins/config` now relays to the `plugins` guest instead of
  writing `state/plugin_config.json` itself. The guest already read every
  descriptor and that file to answer `GET /api/plugins`, so the native writer
  was a second opinion about which keys `config_editable` opens; a refusal is
  now the guest's, and the merge is host-tested in
  `tools/zig/plugin_config_logic.zig`. The `plugins` tool takes
  `{"name":…,"config":{…}}`, so an agent can change a plugin's settings too,
  not just the web UI.

- `clanker doctor`'s header line now carries the clanker version and target
  platform (`clanker doctor 0.x.y (linux/x86_64)`), so its output is usable as
  a bug-report attachment without asking for those separately, and its
  manifests check FAILs when zero tools are registered instead of reporting
  OK with a count of 0 — an empty registry means the tool build or manifest
  directory is broken, not healthy.

- Catalog specs are applied from the models.dev snapshot without parsing the
  matched provider. `Config.load` used to build a `std.json.Value` tree of the
  whole provider member -- for an aggregator that is hundreds of models and the
  bulk of the 4 MB snapshot -- to read the specs of the two or three models a
  config actually names; only the named models' spans reach `std.json` now.
  Every config-loading command pays this on startup.

- A REPL turn no longer copies the whole system prompt into the run arena when
  the prompt has not changed. `refreshSystemPrompt` runs once per turn and
  built the prompt (plus every skill file, the learnings file and the workflow
  catalog it reads) straight into the arena that lives for the session, so a
  long conversation accumulated one full copy of all of it per turn even though
  the text was almost always identical. It builds in scratch and copies only on
  a real change.

- Image attachments no longer keep their raw bytes for the rest of the REPL
  session: only the base64 the request carries is retained, instead of that
  plus a second full copy of every attachment (up to 4 MiB apiece).

- `clanker --dump-config` prints the merged config as JSON. It printed Zig's
  struct-literal debug form, in which a string is a list of byte integers, a
  provider map is its internal `.bytes = u8@7fdfe1466150` buffer pointer, and
  the whole config is one unbroken line: neither readable by a person nor
  parsable by a script, and host addresses on stdout at that. The dump now
  pipes into `jq`, omits the `*_present`/`*_fields` parse bookkeeping that is
  not configuration, and holds no credentials (only the `api_key_env` name a
  provider reads its key from).

- `clanker research --help` and `clanker rfc --help` name `append` and
  `update` in their usage line. Both accepted the subcommands and documented
  them in the help body, but the usage line kept naming the older, shorter
  set, so the one place an operator sees the whole surface disagreed with the
  parser. The five record stores now declare their subcommand list once, and
  a test pins each usage line to it. A usage line too long for 80 columns
  (`rfc` accepts nine subcommands) wraps rather than being trimmed back.

- `bugreport` truncates an over-length title instead of letting it through whole. The `[BUG] ` prefix was budgeted as five bytes rather than six, so a title long enough to need trimming produced a formatted line one byte over the 600-byte buffer, and the fallback on that failure was the untruncated title. Titles now trim to fit the prefix, and shorter ones are unchanged.

- `clanker <command> --help` names the record-store subcommands the parser
  actually accepts. `adr` and `prd` omitted `append` and `update` from their
  usage line, and `research` omitted `create`, while each command's own error
  message listed them, so the usage line was the narrower of two disagreeing
  lists. `clanker session --help` and the bare-`clanker session` usage error
  now name `search <query>` beside `export <id>`: `session` resolves to the
  export help, so the other half of the command was reachable only from the
  top-level list.

- The web UI's chat model picker and fallback-provider select only offer
  providers this serve process can actually call, judged by the same gate the
  TUI `/model` picker applies (`providers.unusableReason`: the offline
  credential check plus a TCP probe for explicit loopback endpoints). Each
  row of `GET /api/providers` now carries `usable` and, when false, `reason`;
  the row itself stays in the payload, so the Models view still lists a
  configured-but-unkeyed provider as inventory, dimmed and named "not
  callable" with the server's reason. A stale `localStorage` selection
  naming a now-uncallable provider/model falls back to the configured
  default instead of staying selected. `POST /api/run` refuses (400, with
  the reason) a request that explicitly names a provider the process cannot
  call, rather than starting a run the fallback chain would serve under a
  different name.

- A recorded run's graph names the provider that actually served it. The
  provider was stamped at run start and never rewritten when the fallback
  chain switched providers mid-run, so a run served entirely by a fallback
  finished looking like the requested provider while `state/token_stats.jsonl`
  named the real one. The `/api/run` reply (and the stream's `done` event)
  also carry `served_by`, and a streaming run that switched providers says so
  in a status line.

- Every `clanker` invocation no longer forks `zig env` at startup. The Zig standard-library path it resolves is read by exactly two cold paths (the `zig_std` tool, and the improve engine's std-symbol help for a patch that failed to compile), so `sandbox/host.zig` resolves it on first use and caches it in a static buffer instead. `--help`, `mcp`, `acp` and every CLI verb were each paying a fork+exec of the compiler for a path they never read. `clanker sessions` drops from 10.1 ms to 7.9 ms and `clanker stats` from 12.0 ms to 9.5 ms (ReleaseFast, hyperfine, 30 runs), with system time roughly halved.

- Completed background jobs (`ck_job`, so `jobs` start-and-forget execs and background subagents) are dropped once 64 finished ones are retained. The two tables were process-global and never trimmed, so a long-lived `clanker serve` held every background subagent's task and result text for the life of the process, and every `wait`/`kill`/`list` scanned the whole accumulation. `list` and `wait` still answer for anything running and for the newest 64 completed jobs; older completed ids now read as not-found. A job a `wait` is currently holding is never reaped out from under it.

- Every `clanker` invocation loaded its configuration twice. The startup dotenv probe wants one flag, `[modules] dotenv`, but `Config.loadQuiet` ran the same load as the command behind it, including `applyCatalogSpecs`: a 3.8 MB read of `state/models-dev.json` and a byte walk of the whole thing to find the spans of configured providers. The catalog fills nothing outside `[models]`, so the probe skips it now and the snapshot is read and walked once per process instead of twice. `clanker sessions` drops from 66.9 ms to 45.9 ms (Debug build, hyperfine, 20 runs).

- `findProviderSpan` no longer re-derives each catalog member's `api` URL and `env` array on every call. It is called once per configured provider, and each call sub-scanned every member of the snapshot for those two fields and re-parsed each `env` array, so a config naming providers models.dev does not know by id walked the snapshot once per provider. `models_dev.indexProviders` extracts them once for the whole provider loop; the match rule and its answer are unchanged.

- The web UI's Runs view — the recorded-run picker, its execution graph, the node detail panel and the A/B run diff — loads on first open, not on every page load. It was ~64 KB raw inline in `app.js`, so a visit that only used Chat downloaded and parsed the whole graph renderer to never draw one; it is `ui/app/features/runs.js` now, dynamically imported by the `runs` view loader with the same retryable-rejection rule as every other feature view. `lib/runs-list.js` goes with it, since nothing outside that view read it. Eager JS on a chat-only visit drops from 147.7 KB to 128.2 KB gzipped (`app.js` itself from 291.3 KB to 229.9 KB raw) and one request disappears; opening Runs costs the same two lazy hops it already cost for `lib/graph.js`.

- The web UI's System view loads its config editor and MCP server list on first open, not on every page load. Both were top-level IIFEs at the bottom of `app.js` that bound *and* called `load()` at startup, so a visit that only used Chat downloaded 12.5 KB of raw JS it never ran and paid for a `GET /api/config/raw` and a `GET /api/mcp/servers` it never read. They are `ui/app/features/system.js` now, dynamically imported by the `system` view loader with the same retryable-rejection rule as every other feature view. Eager JS on a chat-only visit drops from 149.0 KB to 146.2 KB gzipped and two boot-time API round trips disappear.

- Web UI plugins load their code when their tab is first opened, not on every page load. An enabled addon's tab, title and group come from its `plugin.json` (already answered by `/api/webui/plugins`), so the page can offer it without downloading a byte of it; `app.js` and `app.css` arrive on first open, the same deferral the built-in feature views already had. Across the nine shipped addons that is 53.3 KB gzipped and 16 requests off every visit, chat-only ones included. An addon that does work outside its own view sets `"eager": true` in its `plugin.json` and keeps loading at startup; the music dock is the shipped case. A deferred script that fails to arrive leaves its tab in place showing the failure with a Retry, rather than an empty panel.

- `GET /api/workspaces` counts a workspace's chats in one pass over the session listing instead of one pass per workspace. It re-scanned every session for each registered workspace, then again for each label-only orphan, with a linear `seen` list on top, so a store that only grows made the handler quadratic. The rows and their order are unchanged.

- `GET /api/catalog` releases the models.dev snapshot lock before it answers. The lock guards the cached 3.8 MB body and the parsed tree, but it was held by `defer` across gzip and the socket write as well, so one slow reader serialized every other catalog search in the process for the length of its own transfer. It now covers the parse and the search only; the response body is already copied out of the tree by then.

- `--profile <name>` reads its `[models."<provider>/<model>"]` table against
  the merged config, like `config.local.toml` already did. The profile was
  loaded in the mode that distributes models against the *file's own*
  providers, so a profile adding a model to a provider only `config.toml`
  declares was rejected with `ModelUnknownProvider` and the only way to add
  one was to repeat the whole `[providers.<name>]` stanza. A profile that
  names `default_provider` is now also credited as its source by
  `clanker providers check`.

- `ck_harness_config` no longer hands a guest the values inside
  `[mcp_servers.<name>]`'s `env` and `headers`. Those two are the one part of
  the config schema that carries a credential inline (`GITHUB_TOKEN=...`,
  `Authorization: Bearer ...`), and the full access level (the `config` tool)
  serialized them verbatim into guest memory and from there into the model
  transcript. Names are kept, values read `<redacted>`; `api_key_env` and
  `service_account_file` were already excluded from every level.

- Tool descriptors are loaded once per process instead of once per call: `toolJson` (every CLI tool invocation and every HTTP API route under `clanker serve`) re-read and re-parsed all 118 `*.tool.json` manifests, ~180 KB of JSON and ~260 `openat` per request. A cache validated by a stat sweep serves them instead, so an added, removed, edited, or toggled plugin is still picked up without a restart.

### Added

- `clanker commit --all` groups every tracked change instead of only what is
  staged. The `smart_commit` guest has always taken both scopes and the two
  commit different copies of a file (`staged` builds each group in the index,
  so a hunk-narrowed index lands exactly as staged; `all` commits by pathspec
  and so takes the worktree copy), but the CLI hardcoded `staged` while its
  own `--help` said it grouped "staged (or all) files". The preview and the
  write are given the same scope, so the plan that is confirmed is the plan
  that lands.


- `clanker goal --help`, `clanker autoresearch --help` and `clanker repl
  --help` name every flag their command accepts. `goal` took `--provider`,
  `--model` and `--reasoning-effort` and documented none of them,
  `autoresearch` took `--provider`/`--model`, and `repl` took `--preset` and
  `--mascot-speed`; the parser reads a spec's `flags` list while `--help`
  prints its hand-written `detail`, so the two drifted with nothing comparing
  them. A test now fails on any flag a command accepts without documenting.

- `clanker-proxy` exits 2 on a bad invocation instead of 0. A missing `--host`
  value, an unparseable `--port`, and an unrecognized flag all printed the
  usage line and returned normally from `main`, so `clanker-proxy --prot 9000
  && curl ...` read a refused invocation as a started proxy. Each now names the
  offending argument on stderr and exits 2, the same usage-error code `clanker`
  itself uses. `clanker-proxy --help` / `-h` is a real flag now (previously it
  fell through to the unknown-argument branch) and prints the option reference
  on stdout, exit 0.
- The URL a starting listener prints goes to stdout, not stderr. `clanker
  serve` with stdout piped promised "the original bare `http://host:port/webui`
  line", and `clanker-proxy` its `http://host:port/v1` line, but both went
  through `std.debug.print`, which writes to stderr: `clanker serve | grep -m1
  webui` blocked forever while the URL scrolled past on the terminal.
- `clanker --help` and every `clanker <command> --help` name `--profile
  <name>` and `--dump-config`. Both are accepted on every command and their own
  `clanker --profile -h` said "Available on every command", but neither help
  footer listed them, so nothing an operator could read said they existed. A
  test now pins every flag the parser treats as global to both footers.

- `clanker git <args...>` is a transparent passthrough again. It captured both
  of git's streams and replayed them after git had finished, so `clanker git
  log` never reached a pager, `| head` could not stop it early, and a large
  `diff` was held whole in memory; every nonzero status was then flattened to
  1 with a "git exited with an error" line printed under git's own message.
  Stdio is inherited and git's own exit status is the command's, so
  `clanker git diff --quiet` is 1 for "there are changes" and 128 for "not a
  repository", the way the callers of those codes expect.
- `clanker commit` with stdin redirected (a script, CI, `clanker commit
  </dev/null`) read the unanswerable `Proceed? [y/N]` prompt as a no: it
  printed "aborted" and exited 0, so an automated caller was told it had
  succeeded at committing nothing. It now refuses with a diagnostic naming
  `--yes`, and exits 1.
- The five record stores (`reports`, `research`, `rfc`, `adr`, `prd`) reported
  a refused request as a timestamped `[ERROR] ts_ms=...` log record, so
  `clanker adr open <missing>` read like a subsystem fault while
  `clanker workflow show <missing>` — the same mistake — answered with a plain
  `error: ...` line. Both are diagnostics now. An answer that is not readable
  JSON stays a log record: that one really is a broken build, not a bad
  argument.
- `clanker mesh` printed two error lines for one failure, the second vaguer
  than the first: the specific "clanker serve is not reachable at <url>" was
  followed by a generic "clanker serve is not running". Only the line naming
  the URL it dialled survives, which is what identifies the serve on a host
  running several.
- `clanker --continue -h` and the other aliased or value-taking options headed
  their help with a usage line that does not run — `usage: clanker --continue,
  -c -h`, `usage: clanker --mascot-size <size> -h`. The usage line carries the
  primary spelling; the aliases stay in the heading below it.
- `clanker stats --model x` reported the rejected flag as `--model, -m`, which
  reads as two arguments. It names the spelling on its own now.
- `clanker sessions` listed nothing and exited 1 with "query must be at least 3
  characters". The listing reaches the `sessions` guest through the CLI's
  generic passthrough, which always sends `{"args":"<argv tail>"}` — empty for
  a bare `clanker sessions` — and the guest read that empty string as a search
  query. A blank `q`/`args` is no query now; the three-character floor still
  applies to a query the caller actually typed.

- `clanker session search <2-char query>` printed its complaint on stdout and
  exited 0, so a script could not tell a rejected query from a search that
  matched nothing, and read the diagnostic as a result row. It is a usage error
  on stderr with exit 2, like every other rejected invocation.

- Every `clanker preset` failure exited 0: an unknown subcommand, a missing
  name, an invalid name, a preset that does not exist and one that already
  exists all printed `error: ...` and then reported success. Usage mistakes
  exit 2 and the two not-found cases exit 1, matching `clanker workflow`.

- `clanker help --help` wrote the command list to stderr while every other
  spelling of `--help` writes it to stdout, so that one form could not be
  piped into a pager.

- `NO_COLOR=` (present but empty) suppressed colour in `clanker run` output and
  the `clanker serve` banner while the REPL kept its theme. https://no-color.org
  says present *and non-empty*; one predicate (`src/util/no_color.zig`) now
  answers for all three.

- The five record stores (`reports`, `research`, `rfc`, `adr`, `prd`) reported
  usage mistakes as timestamped `[ERROR] ts_ms=... ` log records rather than the
  `error: ...` diagnostic every other command prints, so `clanker reports bogus`
  and `clanker preset bogus` — the same mistake — came back in two formats.
  Tool failures stay log records; they are runtime events, not usage.

- The web UI's elevation is a token again. Three rungs of shadow existed but
  only two had names, so a plate seated on the backplane was retyped as a
  literal at sixteen sites in five recipes (`0 1px 2px`/`3px`/`4px` between
  0.04 and 0.12 alpha), the chat composer among them, where it had grown the
  full rounded-card pair of a hairline plus a soft 24px bloom that raised on
  focus. A literal shadow is invisible to a theme: `:root`, the system-dark
  block and all ten `themes/*.json` retune `--lift` and `--lift-high`, so
  those sixteen kept casting a light-theme black smudge on graphite and under
  hackerman's green-on-black. The seated rung is `--lift-low` now, declared
  beside the other two in every theme, and `ui/app/design-tokens.test.mjs`
  fails on any offset shadow that is not a rung. The mobile chat drawer keeps
  its sideways cast, which no vertical rung says, and names `--scrim` for it.
- The music dock's controls are drawn from the web UI's icon grid instead of
  typed. Its transport pulled glyphs from three Unicode blocks at once (bars
  from U+23xx, a triangle from U+25B6, speakers from U+1F50A) and the last of
  those are emoji, so a browser painted the mute and volume buttons in its own
  colours next to monochrome siblings whatever the theme said. `ICON_PATHS`
  gains `play`, `pause`, `prev`, `next`, `volume`, `mute` and `note` on the
  same 24-grid and 1.75 stroke as every other icon, and the dock reaches for
  them through `api.icon`. Emoji stay where they are content -- reactions,
  room avatars, `:shortcode:` -- and a test now pins that they are never
  chrome.
- The web UI's indicator lamps are one recipe again. The dome the sheet's
  header calls "one boldness, spent in one place" had been retyped by hand at
  five call sites and had drifted to two highlight opacities, three glow
  radii, and a Health-plugin variant that mixed against `--paper` with no glow
  at all; the Arena's lamp had given up and become a flat dot in an amber
  (`#e5b54a`) that belonged to no palette. The dome is now `--lamp-dome` /
  `--lamp-ring` / `--lamp-glow`, coloured by `color:` at the element, and
  every lamp reads it. `ui/app/design-tokens.test.mjs` fails on a retype.
- Spacing in the web UI names its token. 155 declarations across `app.css`,
  `views.css` and the Health plugin spelled a rung of the scale as its number
  (`gap: 0.4rem` for `var(--space-2)`), so a change to the scale would have
  reached only two thirds of the places that meant it. Rendering is
  unchanged; the values are identical. Optical values between rungs stay
  literals, and `ui/app/design-tokens.test.mjs` pins the difference.
- The favicon is painted from the cabinet palette. The mark draws the
  identity's own shapes (panel plate, machined bezel, lit lamp, legend plate)
  but did it in GitHub-dark's chrome: a `#0d1117` plate and a `#555c67` slate
  bezel, both cool against the warm RAL greys, beside a lamp green that was
  already the `--ok` token. `ui/app/core/layout.test.mjs` now checks every
  colour in the mark against the palette the sheet declares, the same guard
  that purged the borrowed palette from the code wells.
- The web UI's Models view announces each panel's outcome on its own status
  line (`#models-status`, `#models-live-status`, `#models-catalog-status`)
  and writes failures too. One shared `aria-live` line was only ever written
  on success, so after a failed live listing a screen reader kept hearing a
  stale "12 catalog matches." from the Discover panel.

### Fixed

- Two `clanker commit` invocations on one checkout no longer interleave
  their index writes: the writing form takes a non-blocking exclusive flock
  on `state/commit.lock` for the whole plan → confirm → write window (the
  same kernel-held lock `clanker schedule run-due` uses, released whenever
  the holder dies, so it is never stale), and a second writer is refused
  with a message naming the lock instead of silently racing the first. A
  dry run reads only and takes no lock. This is the enforcement half of
  docs/reports/bugs/2026-08-16-concurrent-sessions-commit-each-others-work.md;
  sessions that bypass clanker with raw `git` remain covered only by the
  concurrent-sessions runbook, since nothing in this process can lock them.

- A failing Vertex provider now says why. The vertex kinds parsed error
  bodies with their model publisher's codec only, which cannot read Google's
  platform envelope in the array-wrapped form `rawPredict` answers with, and
  a body no codec recognised was discarded outright — so every
  platform-side refusal (quota, IAM, addressing) reached the operator as a
  bare "HTTP 400" and google-vertex-anthropic's every-request failure could
  not be root-caused. Both vertex kinds now read Google's
  `{"error":{"message","status"}}` envelope (object and array forms, with
  the status label kept), and an HTTP error body no codec recognises is
  logged capped at warn instead of vanishing; caller-facing error strings
  still never carry raw body bytes
  (docs/reports/bugs/2026-08-19-vertex-error-bodies-discarded.md).

- A lapsed LLM deadline can no longer wedge the caller forever. The abort
  that unblocks a stalled provider read fired exactly once, so a deadline
  that lapsed before the request had armed it (or pooled its connection)
  shut down nothing, and the follow-up cancel parked the caller at 0% CPU
  alongside the stuck read — `zig build test` hung indefinitely in the
  never-answering-provider tests, and every production
  `request_timeout_ms` / `stream_idle_timeout_ms` deadline carried the same
  race. The abort now latches, retries are refused after a deliberate
  abort, and the deadline side retriggers every 250ms until the request
  thread actually returns
  (docs/reports/bugs/2026-08-19-bounded-chat-one-shot-abort-wedges.md).

- The web UI's Goal activity, Tools and Usage panels have working Refresh
  buttons. All three shipped with an id and a slot in the element map but no
  listener anywhere behind them, so a press did nothing and looked exactly
  like a press on one of the fifteen that worked. Every Refresh button in the
  page now goes through one `wireRefresh` helper in `ui/app/core/utils.js`
  that disables the button for as long as the load takes and restores it on
  success or failure, replacing a dozen hand-rolled wirings of which half
  gave no busy feedback at all. `ui/app/core/refresh.test.mjs` walks the
  shipped HTML for every Refresh control and the shipped JS for how it is
  wired, so a new view cannot add a fourth dead button.

- After `clanker improve-self` promotes a change, the checkout the command
  was invoked from no longer sits on the promotion's inverse diff.
  `mergeBack` fast-forwards the shared branch ref and used to resync only
  its own throwaway worktree, so the invoking checkout's index and files
  stayed at pre-promotion content — presented by git as a staged change
  whose commit deletes the promotion (how 124d592e removed two verified
  improvements from origin/main). The merge-back now finds the checkout
  holding the base branch and, when its index and files are byte-identical
  to the pre-merge base, resyncs it with a bare `reset --hard`; a checkout
  with its own work in progress is left alone with a warning naming the
  danger and the manual sync
  (docs/reports/bugs/2026-08-19-improve-self-merge-leaves-worktree-reverted.md).
- `clanker research sweep` and the `web_search` tool no longer return pages
  unrelated to the query. Bing's RSS endpoint has decayed upstream and answers
  a multi-word query with items matching at most one of its words (thesaurus
  entries, hardware-vendor sites); parsed hits are now checked against the
  query's vocabulary (`search_parse.keepRelevant`), an all-junk page reads as
  empty so the sweep falls through to the keyed backends and Marginalia, and
  the sweep notes once when that happened
  (docs/reports/bugs/2026-08-19-research-sweep-web-backend-returns-unrelated-results.md).
- `clanker rfc recommend` (and the `rfc` tool's `recommend` action) keeps an
  RFC's existing **Why this confidence** and **Reversibility** paragraphs when
  the caller does not pass `moves_confidence`/`reversibility`, instead of
  overwriting them with the template placeholders. The CLI verb passes
  neither, so every CLI recommend on a filled-in RFC silently destroyed
  operator-written reasoning
  (docs/reports/bugs/2026-08-19-rfc-recommend-replaces-fields-it-was-not-given.md).
- The web UI's Skills list (under Tools and Prompts) renders again when at
  least one skill exists. The row-building callback in
  `core/tools.js: loadSkills` shadowed the `#skills` container variable with
  the row's own checkbox, so every card was appended into its checkbox — a
  DOM hierarchy cycle the browser refuses — and the whole panel fell into its
  error branch, showing "Could not load skills." with a Try again that reran
  the same failure. Only an empty skills list ever displayed.
- `clanker write-goal` (and the TUI `/write-goal` and the `goal_write` tool)
  no longer pastes the whole intent into every field its keywords cover: a
  rich intent used to come back with the objective, criterion, proof and
  boundaries all holding the same blob. Each field now holds only the
  sentence(s) — or, for a one-sentence intent, the clause — of the intent
  that answer that fork, a fork the intent left open still gets its stated
  default under Assumed / Still open, and a fork whose only matching text is
  already claimed by another field defaults rather than duplicating it. The
  raw intent survives once, as the record's `intent`. The draft logic moved
  to `tools/zig/write_goal_logic.zig` and is host-tested, so its tests now
  actually run (`test` blocks in a wasm guest never did).

### Changed

- The web UI's tools catalogue (`ui/app/core/tools.js`) and run-graph layout
  (`ui/app/lib/graph.js`) now load on first use instead of on every visit.
  Neither is reachable from Chat: the first only renders the Tools and
  Prompts views, the second only ever runs through `drawRun`. They were
  eager `<script type="module">` tags and static imports of `app.js`, so a
  visit that checked a streamed answer and left still downloaded and parsed
  both. What a chat-only visit fetches drops from 153.7 KB gzipped over 31
  requests to 143.3 KB over 29, measured by `ui/app/weight-budget.test.mjs`,
  which is also the budget that keeps it there. A failed chunk shows the
  view's Try again rather than an empty panel, and the run graph says
  "Could not load the run graph." in place of drawing nothing.
- `clanker rfc search` no longer answers with hits from `docs/rfcs/README.md`
  and `docs/rfcs/TEMPLATE.md`. The inventory lists every RFC by title, so a
  real match came back with an index line stapled to it; `adr search` and
  `prd search` already dropped those and the three now share one filter.
- The web UI's corner radii and type sizes now all come from the design
  tokens `app.css` declares, so the Control Cabinet's machined edges hold
  across every view. The chat composer (24px) and your own chat bubbles
  (18px) were rounded like a generic messenger, and the Kanban board was a
  12px/8px island with its own look; all three now use the 2/3/4px plate
  radii the rest of the panel uses. Font sizes collapse onto the step scale,
  which gains a `--step--2` (10px) rung for the dense badge and graph-node
  readouts that previously used off-scale 9px and 10px literals. Touch
  fields keep their 16px, which is an iOS zoom guard rather than a
  typographic choice.
- The Kanban card cover and label colours are now tokens in the same
  vocabulary as the rest of the cabinet. They were a borrowed web palette
  spelled out as raw hex in four separate rule blocks, which had already
  drifted apart: cover green was `#0a7a2e` while label green was `#22a24a`,
  two greens for one card colour. Each hue is now a single `--card-*` token
  drawn from RAL Classic enamels (signal red, traffic blue, signal violet)
  beside the RAL panel greys, with a paired ink token chosen by measured
  contrast rather than per rule. The hues stay theme-constant, so a card's
  colour still means the same thing in either theme, and every label pair
  clears 5.5:1 (the palette it replaced bottomed out at 5.48:1).
- A dragged Kanban card lifts straight off the backplane instead of tilting
  3° and scaling up behind a hand-rolled shadow, and the card's hover
  overlays (quick actions, quick-edit, member avatars) throw the declared
  `--lift` rather than four separately invented ones.
- `clanker serve` honors HTTP keep-alive on `GET /api/*` responses, the way
  it already did for the web UI's assets. Every JSON fetch the page makes
  (status, sessions, board, mesh map) used to close the connection and pay a
  fresh TCP handshake on the next one; POSTs still close (the `/api/run`
  stream ends by close), and `GET /api/events` still holds its own SSE
  connection.
- The web UI's Fleet mesh poll now stops when the view is left and re-arms
  when it is reopened, matching the Rooms and Arena polls; the Mesh and
  Office plugins' polls idle while their view is hidden instead of fetching
  every few seconds for the life of the tab.

### Added

- `--quiet`/`-q`, accepted on every command, drops logging to errors only. It
  is the missing counterpart to `--verbose`: progress logging runs at `info`
  by default, so a scripted `clanker run` collected `[INFO] ... [exec]`
  tracing on stderr that only the `CLANKER_LOG_LEVEL` environment variable
  could turn off. Precedence is file, then environment, then flags, with
  `--verbose` beating `--quiet` when both are given.
- `zig build test` runs `ui/app/design-tokens.test.mjs`, which fails when a
  stylesheet under `ui/app/` or `ui/plugins/` sets a `border-radius` or
  `font-size` that is not one of the declared tokens. An off-scale literal
  reads as no bug at all, so nothing used to catch the sheets drifting back
  toward the rounded-card default one declaration at a time.
- `ui/app/design-tokens.test.mjs` also pins the card colour palette: a rule
  keyed on `[data-color="…"]` must reach for a `--card-*` token, each hue
  must be declared exactly once (they are theme-constant by design), and
  each must pair with an ink token it clears 5.5:1 against. Radius and type
  were already pinned; colour was the axis with nothing watching it.
- `clanker gate` runs a `test-root-coverage` gate: every file under `src/`
  with a top-level `test` block must be referenced from the comptime import
  block in `src/main.zig`. Zig 0.16 runs test blocks only in the root file,
  so a module missing from that list compiles and its tests never run while
  `zig build test` stays green.

### Fixed

- `zig build` failed at HEAD: the `an unreadable log is an error, not an empty one` test in `src/peers/notifications.zig` mixed `expectError` with a `catch` block and did not parse, so no build mode could compile the tree.

- The web UI's tool settings panel types each field from the descriptor's
  declared default (`config_types` in `GET /api/plugins`, read off the
  manifest's `config`) instead of `typeof` on the current value. A
  `config_editable` key with no saved value yet was typed `"undefined"` and
  saved back as a string — a numeric setting silently became a string the
  first time it was set from the page — and an override hand-edited to the
  wrong type kept that wrong type on every later save.

### Breaking

- The committed `config.toml` renames the Moonshot provider table
  `[providers.kimi-k3]` → `[providers.moonshotai]`, and the shipped
  `default_provider` value changes from `"kimi-k3"` to `"moonshotai"`.
  A `default_provider = "kimi-k3"` pinned in `config.local.toml` stops
  resolving after upgrade (`UnknownProvider`) unless a
  `[providers.kimi-k3]` table is still defined there. Migration: rename
  the pin to `"moonshotai"`; the `kimi-k3` model is unchanged.
- Provider default models move to the newest general-purpose catalog
  models: DeepSeek `deepseek-v4-flash` → `deepseek-v4-pro`, OpenAI
  `gpt-4o-mini` → `gpt-5.6`, Anthropic `claude-sonnet-5` →
  `claude-opus-5`, Muse Spark `muse-spark-1.2-contributor` →
  `muse-spark-1.2`. Local ollama/vLLM ids are unchanged. An upgrade that
  did not pin a model now talks to a different model, with different
  behavior and cost. Migration: pin the previous default in
  `config.local.toml` before upgrading, e.g.

  ```toml
  [providers.deepseek]
  default_model = "deepseek-v4-flash"

  [models."deepseek/deepseek-v4-flash"]
  provider = "deepseek"
  ```

  One `default_model` + `[models."<provider>/<old-model>"]` pair per
  provider reproduces the 0.1.0 behavior exactly. Specs (context, cost,
  capabilities) come from the models.dev snapshot.
- `[memory.chunk]`, `[memory.embedding]` and `[memory.vector] backend` are
  gone: nothing reads them since the native `src/memory/` layer was replaced
  by the sandboxed `memory` tool, and the reference documented them as
  settings. `[memory]` now carries `backend`, `vector.top_k` and
  `vector.threshold`, all three read; setting one of the removed keys is
  reported as an unknown key instead of being silently ignored. Migration:
  delete the removed tables and pass chunk size, overlap, strategy and the
  embedder to the `memory` tool call instead:

  ```toml
  # before — delete these tables
  [memory.chunk]
  size = 800
  overlap = 120
  strategy = "markdown"

  [memory.embedding]
  provider = ""
  model = ""

  [memory.vector]
  backend = "builtin"

  # after — only the read keys remain
  [memory]
  backend = "hybrid"

  [memory.vector]
  top_k = 5
  threshold = 0.35
  ```

### Changed

- `clanker adr list` and `clanker rfc list` read only each record's header
  instead of the whole document. Both listings show a title and a status,
  which live in the first few lines, but each row cost a whole-file read into
  the guest's shared 1 MiB host arena plus a copy in the guest arena, so the
  cost grew with how long the records happened to be and a store of long
  records ran the arena out and dropped its later rows. The read is now capped
  at 4 KiB per record (`doc_scaffold.header_read_bytes`, what `clanker prd
  list` already used), which bounds a listing at the row cap regardless of
  document size: on this repository's `docs/rfcs/` that is 272 KB of reads
  down to 74 KB.

- Every command that loads config starts about 280 ms faster. `Config.load`
  filled unset model specs by parsing the whole ~4 MB `state/models-dev.json`
  snapshot into a `std.json.Value` tree, on every invocation, for the few
  kilobytes of it a configured provider reads. The snapshot is now split into
  raw top-level spans in one byte pass and only the spans matching a
  configured provider are parsed. Measured on `clanker phonebook`: 357 ms ->
  78 ms; `clanker stats` 365 ms -> 85 ms. Specs, and the name/api/host/env
  matching order that picks a catalog provider, are unchanged.
- `ck_fs_grep` skips a file's line loop when the pattern appears nowhere in
  its bytes, instead of paying a substring search per line to discover that.
  Most files in a project-root walk hold no hit at all.

- `clanker tools list` runs about twice as fast (842 ms -> 421 ms on the
  in-tree 118 manifests). The `tools` guest asked `manifest_scan` for
  `description`, `internal`, `category` and `transform` one key at a time,
  and the last three sit after `input_schema`, so each call walked the whole
  schema tree again. `manifest_scan.topLevelValues` answers all four in one
  pass and stops as soon as the last one is filled. The listing is unchanged.
- Syncing a knowledge collection from a folder
  (`POST /api/knowledge/<id>/sync`) loads the tool registry and compiles the
  `knowledge` guest once for the whole request instead of once per call. It
  made up to two calls per file for up to 200 files plus one per pruned
  document, and each of those re-read and re-parsed every `*.tool.json`
  descriptor (~500 KB) and recompiled the guest.

- `GET /webui/plugins/<name>/app.js|app.css` now sends an `ETag` and
  `Cache-Control: no-cache` instead of `no-store`. The bytes are still read
  from disk on every request, so an edited plugin is picked up as immediately
  as before, but an unchanged one is answered with a `304 Not Modified`
  instead of its whole body. Every page load used to re-download and
  re-gzip each enabled plugin's assets in full (~200 KB across the shipped
  set of ten).

- `clanker serve` compiles the `webui` WASM guest once per process instead of
  once per asset path. Every static asset used to load the whole tool registry
  (~96 `*.tool.json` parses), read the ~1 MiB guest off disk and compile it
  again; with 41 asset paths plus the index page, a first visit paid that ~42
  times over as the browser followed `app.js`'s dynamic imports. Rendered
  bodies were already cached, so a warm server is unaffected.
- `clanker stats` and `GET /api/stats` fold `state/token_stats.jsonl` line by
  line instead of materializing every record first. The log is capped at
  32 MiB (~150k records) and the answer is a handful of rows, so the
  intermediate array and its per-record group key were tens of megabytes of
  arena held for the length of the request.
- The improve loop's prompt blocks (`recentSummary`, `recentSummaries`,
  `recentlyTouched`) parse only the tail of `state/improvements.jsonl` they
  read. They went through a whole-file parse (16 MiB cap) into the run arena,
  three times an iteration, and never freed a copy.

### Fixed

- The `memory` tool's `search` no longer collapses under a large knowledge
  store. It duped every chunk scoring above the threshold into the guest's
  1 MiB arena and sorted at the end, although only `top_k` of them can ever
  be returned; once the arena ran out, the remaining hits were dropped
  through a bare `catch` with nothing said. It now keeps only the best
  `top_k` and copies a chunk's text only when it makes the cut. Scoring one
  chunk no longer allocates and frees an embedding buffer per record, and
  the similarity is a plain dot product (`hashEmbedInto` L2-normalizes every
  vector it writes, so the two norms it recomputed per chunk were both 1).
- `memory` `search` rejects a negative `top_k` or `dim` instead of taking the
  guest down: both were converted from the request's float straight to a
  `usize`, which is illegal behaviour on a negative value, and `top_k` was
  clamped nowhere at all so it also sized an unbounded allocation.
- `GET /api/files` caps a directory listing at 2000 entries and reports
  `truncated`. It statted, copied and serialized every name a directory held,
  so browsing to `.zig-cache/o` or `node_modules` in the Files view spent
  thousands of syscalls building a response no one could read; the view now
  says the folder holds more instead of presenting the first page as all of
  it.

- A goal loop resumed by `clanker serve` at startup now claims a steer slot,
  so it appears in `GET /api/goals`' `running` list and accepts steering.
  It previously ran invisibly: the board drew the goal as idle while the
  server spent its whole turn budget on it, and there was no way to steer it.
- A goal loop's terminal outcome now clears its in-flight marker in a write
  of its own, separate from the `active` compare-and-swap that moves the
  status. Bundled together, a goal moved off `active` by hand mid-loop had
  the whole patch refused and kept its in-flight marker forever, which would
  silently auto-resume a loop nobody started once the goal was `active` again.

- Each record store (`reports`, `research`, `rfc`, `adr`, `prd`) now states
  its status vocabulary once instead of twice. `prd` had already drifted:
  its listing recognised `Implemented` and `Partial`, which `prd status`
  refused to set. A listing also reads the Status line against that
  vocabulary in every store, so a decorated line (`**Decided.**`) no longer
  lists as `**Decided`.

### Added

- `/rfc` in the REPL: the RFC store, with the same subcommands, records and
  rendering as `clanker rfc` (`list`, `search`, `open`, `checklist`,
  `create`, `append`, `update`, `recommend`, `status`), folded into the
  transcript. Both surfaces call the same `rfc` tool through one
  implementation, so what `/rfc` writes is what `clanker rfc` reads.
- The TUI composer previews slash commands as they are typed: a draft
  starting with `/` lists the matching commands above the input box —
  spelling, argument hint, and help — so `/go` shows `/goal` and what it
  does before Tab or Enter is pressed. A bare `/` opens the discovery
  list (first commands plus a pointer at the Ctrl-P palette), and once a
  command's arguments are being typed its row stays on screen as a
  signature hint. Preview rows are reserved from the transcript, never
  drawn over it.
- Deadlines on the agent's own model call, so a provider that accepts the
  connection and then goes quiet fails the turn instead of hanging the run
  forever. `agent.request_timeout_ms` bounds one non-streaming completion
  end to end and the wait for a streaming one's first bytes;
  `agent.stream_idle_timeout_ms` bounds the gap between reads once a
  stream is flowing. Both are bounded by default (900000 and 120000, the
  values the shipped `config.toml` restates), because a config that omits
  them is the case with no error to recover from; `0` on either is the
  explicit opt-out that leaves the clock unbounded. A lapsed
  deadline surfaces as `Timeout` and goes straight to
  `agent.fallback_providers` rather than being retried against the same
  silent endpoint. Set both: a streaming read completes only on a full
  8 KiB buffer or end of stream, so a stream that dies after a few
  hundred bytes is the first-byte clock's case, not the idle clock's.
- `agent.repeat_tool_abort_threshold` fails a turn with `RepeatedToolCalls`
  after that many consecutive canonical-equivalent tool calls, the
  terminal counterpart to the advisory `agent.repeat_tool_thresholds`
  reminders. Defaults to `0` (off).
- `clanker janitor` sweeps spilled tool results under `state/spills/`
  older than 12h. A spill is run-scoped — its locator lives only on the
  request copy of a message, never in a saved transcript — so once the run
  ends nothing can ask for the file again. Nothing had ever removed them,
  and because every non-repl run shares the `default` bucket they
  accumulated there indefinitely.
- `ck_fs_stat` reports `mtime_ms`. Spill ids are content hashes, so their
  file names carry no order for a newest-N rule to sort by; the timestamp
  is what lets the sweep tell a live run's spill from a dead one's.

- The REPL's `/effort`, `/model` and `/preset` all open the shared modal
  picker from the bare command. `/effort` lists none/low/medium/high/max
  plus `default`, one-line description per row, marks the currently
  effective level and shows where it comes from (pin, `auto_thinking`
  classifier, per-model config, or sampling profile); Enter pins
  `agent.reasoning_effort` for the session and `default` clears the pin.
  `/model` marks the active provider/model, carries each row's spec
  inline (context window, cost per 1M in/out, category), and
  lists only models whose provider passes the offline credential gate
  `providers check` uses — an entry whose `api_key_env` is unset no longer
  appears. A keyless loopback provider (vllm, ollama) is additionally
  probed with one local TCP connect: a stopped local server's models no
  longer list either, while nothing is ever pinged over a network. `/preset` lists `presets/` with each preset's `description` as
  its preview line and the active preset marked; in a non-blank session it
  explains the blank-session rule instead of opening a dead picker.
- `--reasoning-effort <none|low|medium|high|max>` on `clanker` (the bare
  REPL), `run`, and `goal` pins every turn's reasoning effort for that
  invocation, and a new `[agent] reasoning_effort` config key pins it
  persistently. The pin beats the `auto_thinking` classifier, the
  per-model `reasoning_effort`, and the sampling-profile default; a bad
  value is a usage error at parse time.
- `clanker graph answer [run-id]` prints the final answer a recorded run
  produced — the latest run's, or the named run's. The graph was already
  the only durable copy of an answer once the terminal scrolls
  (`clanker run` saves no session), but nothing could read it back and it
  kept only a 4000-byte preview; the final node now retains up to 64 KiB,
  and an older or longer record says how much of the answer it holds
  (docs/reports/investigations/2026-08-17-missing-clanker-tool-no-verb-prints-a-runs-final-answer.md).
- `clanker reports rename <path> <new-slug>` (and a `rename` action on the
  `reports` tool and `POST /api/reports`) moves a record to a new filename
  inside its own store, rewrites its inventory link under compare-and-swap,
  and lists every file in the two stores still naming the old record. A
  `missing-clanker-tool-` filename marker survives the rename whether or
  not the new slug carries it — enforced by the tool, like `create`
  (docs/reports/investigations/2026-08-17-missing-clanker-tool-record-stores-cannot-rename-a-record.md).
- A `missing-tool` record kind on `clanker reports create` (and the
  `reports` tool), for documenting a basic verb clanker lacks. The record
  lands in the investigations store with the tool inserting
  `missing-clanker-tool-` into the filename after the date — enforced by
  the tool itself rather than trusted from the caller — so absent tooling
  is findable by name; the scaffold asks for the ad-hoc fallback used and
  the proposed verb, and the normal `status` lifecycle applies.
- A browsable run list in the web UI's Runs view. The view had only a
  `<select>`, which can show one run at a time, so a page of recorded runs
  could not be read without opening the dropdown and none of it was dated —
  a listing that had gone stale looked exactly like a current one. Rows now
  sit under Today / Yesterday / a date, each carrying its relative time, run
  id, provider, step count, duration and token total. A nested run is
  indented and names the run it belongs to. Clicking a row selects it through
  the same `<select>`, so there is still one selection and the graph below is
  unchanged. The filter box drives the list and the dropdown together.
- `failed` on each entry of `GET /api/runs`, and `failed` in a recorded
  graph. A run is failed when a check on it returned a failing verdict — the
  agent loop records one per tool declared `check: true` — so a run with no
  check node is unjudged rather than failed. The flag is stamped at write
  time and stored with the other listing scalars, ahead of `task`, so a
  picker reading the 4 KiB prefix can see it. Graphs recorded before this
  read `false`.
- HTTP endpoints for the five record stores on `clanker serve`:
  `GET|POST /api/reports`, `/api/rfc`, `/api/adr`, `/api/prd` and
  `/api/research`. Each relays the tool of the same name, so the CLI, the
  agent and HTTP share one implementation and one set of field names — the
  request fields are the tool's own `input_schema`. `GET` serves the reads
  (`list`, `search`, `open`, plus `checklist` on `rfc`/`prd` and `plan` on
  `research`), taking its fields from the query string and defaulting
  `action` to `list`; `POST` serves the writes (`create`, `append`,
  `update`, `status`, plus `recommend` on `rfc`), taking the guest's input
  object as its JSON body. One endpoint per *tool*, not per store: `reports`
  covers `docs/reports/` and `docs/runbooks/` both.
  - A write action named on `GET`, a read action named on `POST`, and a
    `POST` with no `action` are refused with 400 before the guest runs, so no
    safe method can change a record; any other method is 405.
  - Refusals keep the neighbouring endpoints' mapping: a missing record is
    404 and every other refusal is 400. A write against text the record no
    longer has comes back as the guest's own "open it again and retry"
    refusal, never a silent overwrite and never a 500.
  - `research sweep` is not exposed: it performs network egress and can run
    for tens of seconds. It stays on `clanker research sweep` and the agent.
  - No new `modules.*` flag, matching the ungated `/api/skills`,
    `/api/logs`, `/api/knowledge` and `/api/prompts`. The web UI view over
    these endpoints is a separate follow-up.
- `clanker adr` and `clanker prd`, plus the `adr` and `prd` tools behind them:
  the two record stores that had no verb and were maintained by hand. `adr`
  covers `list`, `search`, `open`, `create`, `append`, `update` and `status`
  over `docs/adrs/`; `prd` adds `checklist` over `docs/prds/`. Both allocate
  the next number, render the store's `TEMPLATE.md` and maintain its index, so
  the CLI, the web UI and the agent share one implementation. `adr search`
  spans the ADRs, RFCs and PRDs together and `prd search` the PRDs and ADRs,
  because which store a hit lands in is the answer: an ADR means the question
  is settled, an RFC means it is still open, a PRD means a feature already
  specifies around it.
  - `adr create` requires consequences, and `adr status ... superseded`
    requires a note naming the replacement — a decision record that only
    argues for itself, or that is reversed by editing its history out, is
    worthless to whoever later asks whether to revisit it.
  - `prd status ... shipped` requires a note naming the source files that are
    now the single source of truth, and `prd list` groups by status with the
    unfinished work first.
  - New: `docs/adrs/README.md` (the store had no index), inventory markers in
    `docs/prds/README.md`, and `{{placeholder}}`s in both `TEMPLATE.md` files
    so the tools can render them.
- `clanker research`: the `research` tool on the CLI, with `list`, `plan`,
  `sweep`, `search`, `open`, `create`, `append`, `update` and `status`. It
  calls the same sandboxed tool the agent uses, so the notes in
  `docs/research/`, their inventory and the compare-and-swap writes are shared
  rather than reimplemented.
- Brave Search and Marginalia as the research sweep's fourth and fifth web
  backends. Brave is keyed on `BRAVE_SEARCH_KEY` (sent as a header, so it stays
  out of any log that records the URL) and runs its own crawl rather than
  reselling another index. Marginalia is the public API, needs no key at all,
  and is last so a sweep always has one more thing to try however little is
  configured; its index is independent and biased towards small non-commercial
  pages, so it surfaces what the mainstream engines rank away.
- Scraped titles and snippets have their internal whitespace collapsed. A
  title laid out for a browser arrives carrying newlines — Marginalia returns
  ziglang.org as "Home\n  ⚡\n  Zig Programming Language" — which printed as
  three ragged lines in the middle of a result list.
- Google as the research sweep's third web backend, after DuckDuckGo Lite and
  Bing, reached through the Programmable Search JSON API and enabled by setting
  both `GOOGLE_SEARCH_KEY` and `GOOGLE_SEARCH_CX`. With either unset the
  backend is skipped and the sweep says so once. It is the API rather than a
  scraper because `www.google.com/search` answers a plain HTTP client with a
  "turn on JavaScript" page carrying no result links, whatever user agent it is
  asked with, including the legacy `gbv=1` no-JavaScript parameter. The same
  holds for Baidu (百度安全验证, its security-verification page, with a browser
  user agent and Chinese `Accept-Language` alike), Ecosia, Startpage, Mojeek
  and the public searx instances, none of which publish a usable web search
  API either — which is why the mainstream backends are keyed APIs.
- `clanker reports status <path> <state> <note>` and a matching `status` action
  on the `reports` tool: `open`, `investigating`, `resolved`, `reopened` or
  `closed` on a bug report or investigation. It rewrites the record's `## Status`
  section and its `docs/reports/README.md` inventory line in one call.
  `resolved` requires a note naming the fix and what verified it.
- A bare `--` ends flag parsing on every command; everything after it is a
  positional. Markdown content routinely begins with `-`, which previously made
  `clanker reports append <path> "- new evidence"` a parse error rather than an
  append.
- `rfc create` reports the research notes it could have linked, as
  `research_available`, when it was given no `research` path.
- `agent.sandbox_follow_symlinks` (default `false`): allow a component of an
  already-granted sandbox path to be a symlink. Following a link out of the
  sandbox root is a known security risk, so it stays off unless the operator
  asks for it, and it never widens which prefixes a tool is granted. Without
  it, a checkout whose `state/` is a symlink into external storage had every
  guest read and write under `state/` refused — `clanker schedule` failed and
  run graphs were never persisted. See
  [ADR 0017](docs/adrs/0017-sandbox-symlink-traversal-is-opt-in.md).
- `clanker rfc [list|search|open|checklist|create|append|update|recommend|status]`:
  the requests for comment under `docs/rfcs/` from a terminal, over the same
  sandboxed `rfc` tool the agent calls. `list` reads each status from the
  document rather than the index and prints the next free number; `search`
  covers the RFCs and the ADRs together, so a decision already recorded
  surfaces before it is re-litigated; `recommend` takes a confidence from 0
  to 10. Previously the store was reachable only through the agent.
- `symbolic_regression` compute tool: search a closed-form expression that
  fits numeric data and return a Pareto front of `{expr, complexity, mse}`.
  For discovering a formula. `calculator` still evaluates a known one.
- Mesh web UI plugin (`ui/plugins/mesh/`): identity (id, listen, admission),
  copyable listen address, join, leave, members, and pending admit/deny.
  On by default. Fleet's map shows listen/admission, a pending-join
  banner that opens Mesh, and a Manage mesh control. Membership and
  pending JOINs publish `t:mesh` on `GET /api/events`.
- `zig build e2e` covers two-process loopback join/leave, prompt
  admit and deny, the CLI when serve is down or mesh is off, plus
  operator journeys `add-goal` (persist without running) and
  `schedule add` then list.
- `ck_fs_write_if` creates missing parent directories before the
  compare-and-swap lock, so `clanker schedule add` works in a fresh
  checkout that has no `state/` yet.
- `clanker mesh` talks to local serve over loopback HTTP: `status`,
  `join <host:port>`, `leave [<peer-id>]`, `pending`, `admit <id>`,
  `deny <id>`. `--webui-port` selects which serve when several run on
  one host. Serve grows matching `/api/mesh/leave` and
  `/api/mesh/pending`. The CLI never opens a mesh socket.
  `mesh.admission = "prompt"` is accepted: unknown JOINs wait for
  `admit`/`deny` or time out. Reference, config, PRD 0011, and the
  roadmap describe the shipped control plane.
- Tool-result spill: when the request pruner omits a tool middle, the
  original is stored under `state/spills/<session>/` and the request
  carries `[spill id=........]`. The `spill` guest reads it back. The
  saved transcript is unchanged.
- `session_search` guest, `clanker session search <query>`, and REPL
  `/search`. Linear scan of saved conversations (min 3 characters).
- Background `jobs` guest (`start`/`list`/`wait`/`kill`) plus
  `subagent {"background":true}` so a long child does not park the
  parent turn.
- `run_plan`: Code Mode v1, a bounded list of existing tool calls in
  one turn (max 12, cannot nest run_plan/chain).
- Human feedback sidecar (`state/feedback.jsonl`, `POST /api/feedback`,
  Up/Down on a turn). Never injected into the model.
- Composer `@file` mentions attach workspace paths as chips
  (`[File: path]` on submit).
- Desktop notification when a turn finishes and the tab is hidden.
- Checkpoint rewind: a `git stash create` snapshot before a mutating
  tool, listed/restored by the `rewind` guest.

### Changed

- Preset `tools_allow` / `tools_deny` patterns now match with the same glob
  the sandbox uses everywhere else (`src/util/glob.zig`). The preset filter
  carried its own approximation that honored only the first `*` and let the
  prefix and suffix overlap, so `a*b*c` matched nothing and `ab*bc` matched
  `abc`. Single-`*` patterns such as `kanban_*` are unaffected.

- `clanker adr search`, `clanker prd search`, `clanker rfc search` and
  `clanker research search` now cap each record at 50 printed matching
  lines and name how many they hid (`… N more matching line(s) in
  <path>`), the way `clanker reports search` already did. A record that
  matched a query in hundreds of places used to push every other hit
  below the fold in those four stores. The five stores' commands now
  share one renderer (`src/records/common.zig`) rather than five copies
  of it, along with the tool seam and the JSON field readers.

- The reply fold header in `clanker repl` is now hard to overlook: bold,
  underlined, and worded as the control it is — `▸ reply, N more lines
  (click to expand)` / `▾ reply (click to fold)`. It is the fold's only
  toggle and used to draw in the dim tool tint, vanishing into the tool
  lines around it; a bold-accent attempt was no better on themes whose
  accent sits near the body-text color, so the prominence now comes from
  the underline and the wording, which hold in every theme.
- Compare-and-swap locks moved out of the source tree. `ck_fs_write_if`
  now locks on `state/locks/<sha256-of-target-path>.lock` instead of a
  `<target>.ck_cas.lock` sidecar beside the file it guards (ADR 0031,
  from RFC 0006). A lock file is permanent by design — unlinking one
  that is held breaks mutual exclusion — so every record ever written
  through a record store left a zero-byte file next to it, and every
  improve worktree inherited a copy. Existing sidecars are inert and can
  be deleted; nothing creates them now.
- A compare-and-swap lock file carries a fixed-width holder record
  (`pid`, `acquired_ms`, `tool`, `target`), so a write that hangs names
  the run and the moment instead of being a zero-byte name. It records
  the last acquisition, not a live hold: whether a lock is held right
  now is answered by `flock -n state/locks/<name>.lock true`.
- `clanker janitor` sweeps compare-and-swap lock files whose recorded
  acquisition is more than 12 hours old. This is a retention window for
  the lock *file*, not a liveness timeout — an `flock` is released by
  the kernel when the holding descriptor closes, crash included, so a
  lock is never stale. A lock whose target recurs keeps re-acquiring and
  never ages out; only one for a target that will not be written again
  (a test tmp tree, an improve staging copy) does.
- `GET /api/stats` relays the `model_stats` guest. The CLI table stays
  native (`src/stats` cannot be imported from WASM).
- `GET /api/catalog` and `clanker providers catalog` share one search
  (`catalog.collectHits`).
- Web UI plugin assets honor `inherit_on`: an older
  `state/webui_plugins.json` that only listed files+music no longer
  404s Schedule, Search, or Compare.
- `GET /api/providers` relays the `providers` guest list. A live
  `/models` fill for a provider with no static models stays native.
- Advisor parse/summarize/inject is a host-tested helper
  (`advisor_logic`); the `advisor` guest runs the same review via
  `ck_llm`. The auto-thinking classifier has the same split:
  `thinking_logic` plus a `thinking` guest via `ck_llm`.
- The Schedule, Search, and Compare web views are disk plugins
  (`ui/plugins/schedule/`, `ui/plugins/search/`, `ui/plugins/compare/`),
  not part of `app.wasm`. They stay on after a pre-migration
  `state/webui_plugins.json` that only listed files+music.
- Web UI themes are data files under `themes/*.json`. Drop one in and
  `GET /webui/themes/catalog.json` lists it; the page applies the tokens
  instead of shipping a `:root[data-theme]` block per palette.
- Composer slash commands are `commands/slash.json`. Adding one is a
  data edit; the page loads `/webui/commands/slash.json`.

- Guests and web UI plugins can emit onto the serve live bus. A descriptor
  with `"live_publish": true` may call `ck_publish`; a view may call
  `api.emit(data)` (`POST /api/live`). Both land on the `plugin` topic
  as `{"t":"plugin","from":...,"data":...}` and cannot pick chat, run,
  or metrics.

- Fenced code in chat bubbles follows the active theme. The well used
  to stay GitHub-dark (`#0d1117`) while highlight tokens used the page
  palette, so light / Latte / Tokyo Night Day painted dark-on-dark.
  Each theme now sets `--code-bg` / `--code-fg`, and the inline-code
  pill no longer paints over a fenced `pre`.
- The web UI view formerly labelled Board is Kanban: rail tab, page
  heading, Tools category, and `#kanban` / `#kanban/<card>`. `#board`
  and `#goals` still open it.

- Opening the web UI starts a new conversation instead of replaying the
  last session. The old chats stay in the sidebar. A `#chat?session=`
  link still opens that conversation.

- User chat bubbles render the prompt as markdown (lists, bold, fences)
  instead of dumping the raw marks as a single pre-wrap text node. The
  source stays on the bubble so Edit, Copy and export are unchanged.
  Rooms messages sit under the name row, not beside it, so a heading or
  list is not crushed into the leftover width.

- Chat fills the main column instead of a 46rem stripe: header,
  transcript and composer share that width, and rendered markdown
  (lists, tables, code) is no longer re-capped at 70ch. Rooms uses the
  same markdown renderer as the agent transcript (`**bold**`, fences,
  lists) and the message log fills the pane instead of a leftover 24rem
  box.

- Tool categories are a closed vocabulary (`agent`, `chat`, `code`,
  `compute`, `harness`, `kanban`, `knowledge`, `media`, `transform`,
  `web`, `other`). The Tools view groups in that work-first order
  (Kanban for `kanban`) and no longer repeats the group name in the
  detail header. `knowledge` holds notes, memory, research, rfc,
  reports, and roadmap. `peers` sits with the harness (phonebook and
  machine notifications, not chat), `todo_*` with the agent (private
  run lists, not the board), `jobs` with the agent, `patch_apply` with
  code. `clanker plugins validate` warns on an unknown category and on
  a prefix in the wrong group (`chat_*` must be `chat`).
- Tool names: the multiplexed Kanban guest is `kanban` (was `board`);
  JSON pretty/validate is `json` (was `json_tool`); self-improve
  history is `improve_history` (was `history`, which collided with
  `clanker history` / `/history` for conversations). `/api/board`
  still calls the multiplexed guest. Zig helpers are one family:
  `zig_check`, `zig_std` (was `std_api`), `zig_test` (was `test_file`).
  Identifier generation is `ids` (was `id_gen`). Multi-op families are
  `noun_verb`: `web_fetch` (was `fetch_web`, pair with `web_search`),
  `goal_write` / `goal_add` / `goal_update` (were `write_goal` /
  `add_goal` / `update_goal`; CLI stays `write-goal` / `add-goal`),
  `skill_edit` (was `edit_skill`), `config` (was `config_view`).
  `note_write` / `note_forget` (were `write_note` / `forget_note`).
  `clanker plugins validate` also expects `goal_*`/`skill_*` in agent,
  `note_*` in knowledge, and `web_*` in web (`webui*` is harness).

### Added

- `GET /api/sessions` relays to the `sessions` guest (`format=json`).
  The picker and the agent catalog share one 4 KiB header walk
  (`sessions_logic.zig`). Mutations and a full transcript stay native.

- The OpenAI/Anthropic proxy reads route/protocol policy from each
  provider's vtable (`Provider.proxy`) instead of switching on
  `provider.kind`. Vertex quota project is `auth.Spec.quota_from_project`.

- A `schedule` guest lists and edits recurring agent runs
  (`state/schedule.json`). `GET /api/schedule` and
  `POST /api/schedule/<id>` relay to it, so the Schedule view and the
  agent catalog share one store. Cron arithmetic lives in
  `schedule_cron.zig` (host-tested) and is the same dialect
  `clanker schedule run-due` uses. Firing stays native.

- A `skills` guest lists, shows, searches, and enables/disables the
  markdown files under `agent.skills_dir`. `GET /api/skills` and
  `POST /api/skills` relay to it. Optional YAML frontmatter
  (`title`, `description`, `enabled`) plus `state/skills.json` is the
  enable/disable store. The system prompt inlines title and description
  only; the `skills` tool reads a full body. Discovery filters live in
  `skills_logic.zig`.

- The Health view subscribes to a `metrics` live-bus topic instead of
  polling `GET /api/metrics` on a timer. The endpoint still answers a
  snapshot (and Refresh still uses it). Snapshots are published at most
  once per second.

- Web UI plugins can POST, subscribe to the live bus, open the page's
  dialogs, read the current workspace, use the page icons, and store
  namespaced `localStorage` through `pluginApi()`. `plugin.json` now
  declares a `capabilities` list against that surface.

- `chat_dm` is the catalog tool for talking to another clanker instance
  (`{"to":"<name>","text":"..."}`). It is another descriptor over
  `chat.wasm` (same `ck_chat` send as `chat_send` with `to`), so the
  message lands in the canonical `dm:<you>|<to>` room and fans out like
  any other chat. The `peers` tool's `notify` action stays the machine
  notification ledger (`POST /api/notify` → `state/notifications.jsonl`);
  its description no longer teaches that path as "post a message".

- `clanker reports` puts the operational reports and runbooks on the CLI:
  `list` (the default) prints the whole index with each record's status and
  path, `search <query>` runs one literal search across `docs/reports/` and
  `docs/runbooks/` with `--kind` to narrow it to one store, `open <path>`
  prints a record, and `create`, `append` and `update` write one. It calls the
  same sandboxed `reports` tool the agent uses, so there is one store, one
  inventory and one set of compare-and-swap writes rather than a second
  implementation beside them — a refused write exits 1 and says which record to
  reopen. Until now the records were reachable only from inside an agent run.

- Two tools for the work that precedes a decision, independent of each other.
  `research` plans a search (the angles a single query misses: alternatives,
  failure reports, production experience, standards, and the out-of-the-box
  candidates nobody advertises), sweeps web search, GitHub repositories,
  Hacker News, and arXiv in one deduplicated call, and keeps what survives as
  a note under `docs/research/`. `rfc` opens a numbered request for comment
  under `docs/rfcs/`: options with short, medium, and long term implications,
  a recommendation whose confidence is a bounded 0–10 score, open questions,
  next steps, references, and an appendix. Both render a committed template
  (`docs/research/TEMPLATE.md`, `docs/rfcs/TEMPLATE.md`), keep their index
  current, and write compare-and-swap. `rfc create` optionally links a
  research note and lifts its option headings in as stubs marked unverified;
  nothing else couples the two, and neither is required for the other.
  Hosts named in `web.allow` extend the research sweep as they already do
  `fetch_web` and `web_search`.

- The REPL mascot renders as a SIXEL raster on terminals that support SIXEL
  but not kitty graphics, at the same cell footprint and in every existing
  mode, size, facing and speed. The renderer is chosen automatically from the
  terminal's own capability answer — kitty graphics, then SIXEL, then unicode
  half-blocks — never from `$TERM` or a terminal name, and a SIXEL failure
  falls back to half-blocks for the rest of the session. Requires
  `patches/vaxis-sixel-graphics.patch`; an unpatched build keeps the previous
  two renderers.

- MCP integrations are configurable: `[mcp_servers.<name>]` stanzas
  (stdio: command/args/env/cwd; http: url/headers; timeout) parse and
  validate at load, System -> MCP servers in the web UI adds, edits,
  and removes them through the validated config pipeline (secret env
  and header values never round-trip to the page), and the `mcp` skill
  teaches the agent to manage them by editing `config.local.toml`. The
  client bridge that actually connects is PRD 0032 and stays behind
  `modules.mcp_client`. `POST /api/config/table/remove` deletes any
  table from `config.local.toml` with the same refuse-or-write
  validation as every other config write.

- Hitting the iteration budget lands the run instead of erroring it: a
  wrap-up warning is injected three iterations out, and the final
  iteration goes to the model with tools disabled so it must answer in
  text — the result, or a handoff summary of what was done and what
  remains. A goal loop then continues on its next turn with a fresh
  budget rather than dying as `MaxIterationsExceeded` (which stays only
  as a backstop).
- Ad-hoc web UI addons from chat. Ask for a view ("build me a music
  player") and the `webui_addon` tool writes `ui/plugins/<name>/` and
  can enable it. System → Web UI plugins is the on/off switch. A
  shipped Music addon plays local files or URLs, with a dock that stays
  up while the addon is on. `registerView` now has an optional `boot`
  hook for that kind of persistent chrome.
- The Office whiteboard shows goal work at a glance: each line carries
  an IEC status lamp (green working — breathing while a clanker is on
  it, amber in review, red blocked), working goals lead the board with
  a live count, and review/blocked goals appear greyed instead of
  vanishing. Reduced motion stills the breath.
- Config hot reload: `clanker serve` watches `config.toml` /
  `config.local.toml`. A change that loads cleanly restarts the server
  into it (the same idle-aware exec a binary rebuild uses); a broken
  edit logs a warning and the server keeps running on its last known
  good config. `GET /api/config/status` reports the last verdict.
- The System view gains a raw config editor with TOML syntax
  highlighting for both files. Saving validates first via
  `POST /api/config/raw`: a config that does not load is refused with
  the reason and nothing is written, so a save can never take the
  server from good to broken.
- The Models edit panel gains a TOML mode (the OpenShift-console
  YAML-tab pattern): the same model, editable as its raw
  `[models."..."]` table with highlighting. `POST /api/config/table/set`
  splices the block into `config.local.toml` and validates the whole
  candidate before writing, through the same refuse-or-write pipeline
  as the raw editor.
- Workspaces are first-class: create any number of them, each a folder on
  disk with its own chat history. The rail picker switches folder and
  conversation list; New chat and `/api/run` inherit the current workspace;
  the files browser and the agent sandbox root at that folder. Registry is
  `state/workspaces.json`. The serve cwd remains the default workspace.
- `reasoning_format` on a provider or model overrides how reasoning is
  read out of a response: `auto` (the kind's native field), `think_tag`
  (pull a leading `<think>...</think>` out of the content — the local
  vLLM DeepSeek shape, vs the API's `reasoning_content` field), or
  `none` (discard). An unclosed tag leaves the content untouched.
- A model entry can override its endpoint: `base_url` and `path` on a
  `[models."..."]` table point that one model at a different host or
  route (a local vLLM beside the hosted API on the same provider entry).
  URL only; auth still comes from the provider.
- `tool_schema` and `thinking_schema` on a provider or model override the
  wire encoding for endpoints that deviate from the flat OpenAI shape:
  tools can be the standard array or omitted entirely (`"none"`), and the
  reasoning knob can go out as `reasoning_effort` (default), the
  OpenRouter `"reasoning": {"effort": ...}` nest, the GLM
  `"thinking": {"type": "enabled"}` toggle, or nothing. A model's setting
  wins over its provider's.
- A `[models."<provider>/<name>"]` entry can set `id` to the wire SKU so
  the table key is a local alias. Two names can share one SKU with
  different temperature (or other) settings:
  `grok4.6-coding` and `grok4.6-general` both `id = "grok-4.6"`.
- Omitted `context_window`, `max_tokens`, cost, display, and capabilities
  are filled from the models.dev snapshot at load. A written value always
  wins. Load does not download the snapshot.
- `rpm` on a `[providers.*]` or `[models."..."]` table is a self-imposed
  requests-per-minute cap. Clanker waits before sending so it does not
  exceed the window. A model cap and a provider cap both apply when set.
- `zig build proxy` builds `clanker-proxy`, the OpenAI/Anthropic
  compatibility proxy as a standalone binary: same `config.toml` /
  `config.local.toml`, `/v1` at the root, `[serve] proxy_token_env`
  auth, `--host` / `--port` flags with `CLANKER_HOST` /
  `CLANKER_PROXY_PORT` fallbacks (default 127.0.0.1:17922). No web UI,
  agent, TUI, or tool host is compiled in.
- Vertex (`vertex` and `vertex_anthropic`) accepts Application Default
  Credentials from `gcloud auth application-default login` or
  `GOOGLE_APPLICATION_CREDENTIALS`, in addition to a service-account JSON
  or a pasted access token. The refresh token is exchanged in-process;
  there is still no gcloud subprocess. User ADC sends
  `x-goog-user-project` from the provider's `project`.
- A run-metrics line under the composer, DeepSeek-harness style: turns,
  steps, LLM time vs tool-call time, average time-to-first-token,
  completion tok/s, cache hit rate, and input/output token counts. The
  strip ticks every animation frame while a turn is running (wall clock,
  steps, live tokens from mid-run `usage` events plus a chars/4 estimate
  until the next official snapshot) and accumulates across turns until
  New chat, a session switch, or reload. The vaxis REPL paints the same
  strip on its last row, under the composer, and redraws it on the
  stream tick (~33ms). TTFT is also measured server-side
  (`types.ChatResponse.ttft_ms`, streaming only) and folded into
  `RunStats` when that event arrives.
- The Models view can add, edit, and remove a configured model, not only
  save a catalog snippet: `POST /api/config/model/set` table-replaces a
  full field set (temperature, cost overrides, capabilities, etc.) into
  `config.local.toml`, and `POST /api/config/model/remove` deletes a
  model's table there. Both are surgical `config.local.toml` edits, same
  as the existing catalog-save path; a model only declared in the shared
  `config.toml` cannot be removed from the page. A catalog entry that
  supports a temperature parameter (models.dev only signals the
  capability, not a value) now fills in clanker's own chat default
  (0.7) instead of leaving the field for the provider's own default.
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

### Changed

- The REPL's `/research` now means what `clanker research` means: the
  research note store, same subcommands (`list`, `search`, `open`,
  `plan`, `sweep`, `create`, `append`, `update`, `status`), same
  rendering, folded into the transcript. The old `/research` was an
  unrelated web-preference toggle squatting on the name; that toggle is
  now `/websearch [on|off]`. Multi-word arguments take double quotes:
  `/research create embedded-kv "Embedded KV stores" "Which one fits?"`.

### Fixed

- An empty string in a descriptor's `fs_prefixes` no longer grants a tool
  every file under the sandbox root. `fsPrefixAllows` matched `""` against
  every path and its `p.len == 0` boundary arm returned "allowed", so one
  stray entry was the whole root — the same defect an empty *list* was fixed
  for. Empty entries are now skipped (no authority), and
  `clanker plugins validate` reports one as an error instead of silently
  passing over it; write `"."` to ask for the whole root.
- A config file that exists and cannot be read is no longer an empty one.
  `GET /api/config/raw` returned an empty editor with `ok:true`, and
  `POST /api/config/table/set` / `.../remove` spliced their table into `""`
  and wrote that back, so one unreadable read replaced the operator's whole
  `config.local.toml` with a single table while reporting success. Only a
  genuinely absent file reads as empty now; every other failure answers 500
  and names the cause in the server log.
- `state/notifications.jsonl` likewise: the append is a read-modify-write of
  the whole log, and a read that failed for any reason other than the file
  being absent rewrote the ledger down to the one record being stored,
  dropping the delivery-id dedupe history with it. `POST /api/notify` now
  answers 500 instead.
- `clanker autoresearch` no longer overwrites a target file with just the
  patch fragment. A file that exists but cannot be read (past the 1 MiB cap,
  permissions, I/O) was staged as absent, so an append-shaped change built
  the staged copy from the fragment alone and a run that improved the metric
  wrote that fragment back over the real file. The proposal is refused
  instead.
- `clanker serve --proxy` no longer ends a truncated stream with a terminal
  event. A mid-stream read failure was silently swallowed and the synthetic
  `data: [DONE]` (or Anthropic terminal event) still went out, so the client
  read a cut-off answer as a complete one. Mid-stream failures are now logged
  with the provider and byte count, and the terminal event is withheld.

- `state/goals.json` joins the stores above: a file that exists and cannot be
  read back is no longer an empty goal list. `clanker run --goal <id>` used to
  report the goal not found (and `POST /api/run` answered 404) when the store
  was unreadable rather than the goal absent, and an auto-steered run silently
  dropped its steering. The read now names which of the two it was: the
  explicit form refuses, the HTTP form answers 500, and auto-steering still
  degrades to an unsteered run but says so.
- The REPL no longer loses a conversation without saying anything. Every
  failure on the exit-path save (a session id that will not mint, an invalid
  id, a failed write) was logged at `warn`, below the `error` threshold the
  REPL raises before taking the alt screen, so nothing reached the operator.
  A transcript that could not be fully assembled also used to be written
  anyway, overwriting the saved session with a shorter one; it now refuses
  rather than truncating.
- `/goal` in the REPL reports what it could not record. A failed `goal_add`
  or Kanban card creation was swallowed at every step, so the goal loop
  started with nothing on the board and no explanation. The run still starts;
  the transcript now carries the warning.
- `clanker mesh` gives up on a local `clanker serve` that accepts the
  connection and never answers. `std.http.Client` has no read timeout, so the
  command blocked forever with nothing printed; each call now runs under a 15s
  ceiling and reports the stall.
- Chat fan-out names an encode failure instead of returning quietly, and a
  staging copy that cannot list a directory says the staged tree is
  incomplete rather than letting the staged build fail as a missing file.
- A `state/` file that exists but cannot be read back is no longer treated as
  an empty one. `state/schedule.json`, `state/workspaces.json` and
  `state/room_meta.json` are each read-modify-write: every mutation loads the
  whole file, edits one record, and writes all of it back. Answering an I/O
  error or unparseable JSON with an empty list therefore did not degrade the
  next `clanker schedule add`, workspace `add`, or `clanker chat topic`/`pin`
  — it made that command persist the empty list, silently deleting every
  other entry and reporting success. Only a missing file now means empty;
  anything else refuses the write and names the file to fix. `clanker
  schedule list` likewise reports the unreadable store instead of printing an
  empty schedule.
- Room topics and pins no longer stop saving once `state/room_meta.json`
  outgrows 64 KiB. The whole file was serialised into a fixed stack frame, so
  past that every `clanker chat topic` and `clanker chat pin` failed
  `TooLarge` for good; the buffer is now sized by the content. Pins are also
  capped at 200 per room, oldest dropped first — they were the one chatroom
  structure with no bound, inside the file every metadata write rewrites
  whole.
- A chatroom log larger than 1 MiB no longer reads as an empty room. The
  writer trims the log to `chatrooms.max_history` entries and sizes its own
  read to that window, but the readers kept a fixed 1 MiB cap;
  `readFileAlloc` answers `error.StreamTooLong` rather than a short read,
  and each reader turned that into an empty result. Past roughly 250
  messages at the 4 KiB send cap — well inside the default 500-entry
  history — the agent inbox stopped surfacing peer messages, `clanker chat
  history` and `GET /api/chat/messages` returned nothing, `clanker chat
  rooms` and `GET /api/chat/rooms` listed no rooms, and the board's forward
  fold saw an empty log. All of them now read under the same cap the writer
  trims to, computed in one place.

- `POST /api/run` no longer replaces a session's whole history when it
  cannot read it. The handler loads the stored messages, appends the turn,
  and rewrites the file from that list, but every load failure was
  swallowed: an unreadable-but-present session file (permissions, a
  truncated write, an I/O error) started the request from an empty list and
  the save then deleted the conversation and reported success. Only
  `FileNotFound` now means "first turn"; any other read failure answers 500
  and leaves the file untouched, and an invalid session id answers 400.
  `clanker run --session` already drew that line.
- `POST /api/plugins/<name>/config` no longer wipes every other plugin's
  overrides when it cannot read `state/plugin_config.json`. The edit is a
  read-modify-write of the whole document, and an unreadable or unparseable
  file was treated as "no overrides yet", so the write replaced it with just
  the plugin being edited. A missing file still starts from empty; a read or
  parse failure answers 500 and changes nothing.
- `clanker janitor` no longer de-registers a live worktree when it runs out
  of memory mid-pass. `reconcile` rebuilds `state/worktrees.json` from the
  rows it decided to keep, and an allocation failure while collecting one
  dropped it silently, stranding the commits that worktree holds. A failed
  collection now leaves the registry exactly as it was, and says so.
- Session compaction no longer strands a tool result with no `tool_calls` to
  answer, which providers reject outright (OpenAI 400s on a `tool` message not
  preceded by `tool_calls`; Anthropic rejects an unmatched `tool_result`).
  `session.compactMessages` drops a prefix of the non-system messages, so the
  budget cutoff could land between an assistant message carrying the calls and
  the results answering it; the surviving results then led the history. It hit
  a resumed session on the turn it was compacted for (`clanker run --continue`,
  `--session`) and a REPL session on the launch after the one that saved it,
  and nothing downstream repaired it — `dropDanglingToolExchange` only cleans
  the *tail*. Leading tool results now go with the prefix that orphaned them,
  the invariant the agent loop's own compactor already guarded.
- The agent loop's compaction now declines when the walk back past tool results
  reaches the system prompt without finding a safe split, instead of *inserting*
  a summary at index 1: `replaceRange` with a zero-length range grew the history
  the pass was called to shrink, and left the tool result behind a synthetic
  user message that had issued no calls.
- The Vertex access-token exchange now runs under a wall-clock ceiling (10s).
  `std.http.Client` has no read timeout of its own, so a token endpoint that
  resolved, accepted the connection and then said nothing blocked forever, and
  this call is made *holding* the token cache's mutex via `lockUncancelable`:
  one wedged connection parked every Vertex caller in the process behind it,
  uncancellably. The chat call's own `request_timeout_ms` never got a chance to
  fire, because minting happens before the request it guards.
- `clanker schedule` no longer replaces the whole run ledger with a single
  record when it cannot read the existing one. `state/schedule/log.jsonl` was
  read with a limit equal to its own trim cap and every read error was treated
  as "no ledger yet", so a ledger that had grown past the cap was refused on
  read and then overwritten with the one new line, silently discarding the
  entire audit trail and reporting success. The read now allows headroom so the
  trim can bring an over-cap file back under it, and only `FileNotFound` counts
  as empty: any other error costs that one record, never the file.
- Workspace mutations (`add`, `remove`, root changes) no longer wipe the
  registry when `state/workspaces.json` is present but unreadable. Every read
  error read as an empty list, and those calls load, mutate and save the whole
  list, so the next mutation wrote a one-entry file over every registered
  workspace. Only `FileNotFound` is empty now; anything else is logged and
  surfaced, so the mutation refuses instead.
- Every HTTP fetch of a models listing now runs under a wall-clock ceiling, so
  a host that resolves, accepts the connection and then says nothing can no
  longer wedge the caller forever. `std.http.Client` has no read timeout of its
  own, and three call sites still went out unbounded: the models.dev catalog
  fetch (`clanker providers refresh`, `POST /api/catalog/refresh`, and the
  first-populate path of `GET /api/catalog`, which reached it *holding*
  `catalog_cache_mutex` and so took the catalog away from every later request
  in the process, not just its own) and `GET /api/providers/models`. The
  catalog fetch gets 30s; `GET /api/providers/models` gets the same
  `check_timeout_seconds` / `agent.provider_check_timeout_seconds` budget the
  Models view's live listing already used. Failures now name their cause
  (`Timeout` rather than a collapsed "did not answer"), so
  `clanker providers refresh` and the serve log say which one it was.
- Record search matches every word of a multi-word query instead of the query
  as one exact substring, so `clanker reports search "concurrent sessions"`
  now finds
  `docs/runbooks/concurrent-agent-sessions-on-one-checkout.md`, which says both
  words on different lines and which the old matching answered "no report or
  runbook mentions it" for. A `"quoted phrase"` still asks for the adjacent
  form, and a one-word query is unchanged. Shared by all five stores
  (`reports`, `rfc`, `adr`, `prd`, `research`), so the CLI, the HTTP endpoints
  and the agent tools all inherit it.
- A `[[peers]]` entry that does not answer no longer ends an ordinary command
  in a memory leak trace, and the backoff it records is no longer read back out
  of a freed arena. The per-peer chat cooldown table is process-lifetime state
  with one slot per peer, so it is a fixed-size table that copies the peer name
  rather than a heap list borrowing the name out of the request that filled it.
- `clanker commit` no longer reports success when it could not put the index
  back. The restoring `git read-tree` discarded the error from the call itself
  and only inspected the stderr it wrote, so a read-tree that never ran left
  the half-built index the routine exists to avoid and said nothing. The
  restore failure is now reported whether or not the commits went through.
- `state/autolearn.jsonl` and `state/reasoning.jsonl` say so when a record is
  dropped. Both append paths logged a failed open and then discarded every
  error after it, so a full disk or a revoked permission lost records while the
  run looked healthy. All three state logs now share one appender
  (`src/util/append_line.zig`) that returns its error.
- `clanker mesh join` no longer leaks a socket per failed handshake. Only the
  longhand failure branches closed the connection; a short allocation or a peer
  frame that was malformed or over `mesh.max_frame` returned past them. A peer
  is also registered only once its reader thread owns the descriptor.
- `clanker serve` and the mesh listener log when a socket read timeout could
  not be set, instead of falling back to unbounded reads silently: 64 such
  connections exhaust the connection threads and stop the server accepting.

- `clanker stats` and `GET /api/stats` no longer stop working once enough
  models have been used. The response was assembled in a fixed 64 KiB buffer
  while the list it holds has one row per (provider, model) pair ever
  recorded, so past roughly 150 pairs the write overflowed and `ck_stats`
  answered `too_large` -- the whole surface went from working to erroring on
  a threshold nothing announced. The body now grows to fit.
- `clanker stats` no longer reports zero usage when the log is over its cap.
  The cap is enforced by the *next* append, so `state/token_stats.jsonl`
  legitimately sits above it between the write that crosses it and the write
  that trims it; the reader allowed no such headroom, failed on that file,
  and answered "no records", which reads as a fresh install. Readers now
  allow the same slack the trimmer already did, and a read that fails for any
  reason other than a missing file is logged instead of being reported as no
  usage.
- A sandboxed tool's HTTP request (`ck_http`, so `web_fetch` and every other
  network-granted tool) now runs under a 60s wall-clock ceiling instead of
  waiting forever. `std.http.Client` has no read timeout, so an allowlisted
  host that completed the TCP handshake and then sent nothing blocked the
  agent's turn indefinitely, with no error for the run to classify and
  nothing in the log; the connection is now shut down the way the LLM client
  already rescues a wedged completion, and the timeout is logged with the URL.
- A sandboxed tool's failed HTTP request now says why. Every failure --
  DNS, TLS, refused connection, a body past `max_http_bytes` -- collapsed
  into the same unlogged `network` code, so an on-call operator saw one
  indistinguishable error for four different causes. The transport failure
  is now logged with its cause and an oversized response reports `too_large`
  rather than `network`.
- `clanker stats`' log trim no longer fails silently. Every other failure on
  the token-stats append path was logged; a trim that kept failing left
  `state/token_stats.jsonl` growing past its cap with nothing reporting it.
- Each agent turn now sends the model's configured `max_tokens` as the
  completion grant. `llmChat` and the streaming path used to send
  `agent.max_tokens_per_turn` (default 4096), which is the per-turn
  input/compaction floor. On a reasoning model those 4096 tokens were
  spent on `reasoning_content`, the final reply arrived
  `finish_reason: length` with empty content, and the run died
  `AnswerTruncatedToEmpty` (escalation `run-1787011404`,
  `deepseek-v4-pro` configured at 32768).
- A `ck_exec` result whose stdout or stderr exceeds the keep budget
  (`56 KiB` / `8 KiB`) now carries its truncation `note` as a JSON
  string. `Stringify.print` was writing the sentence as raw text, so the
  object did not parse; `repo_search` then handed the blob back and the
  agent warned that the tool returned malformed JSON (escalation
  `run-1787001820`, query `repair`, 65148 bytes).
- The provider fallback chain skips a configured name whose credentials
  are missing, the same `unconfiguredReason` gate TUI `/model` already
  uses. A DeepSeek stream `ReadFailed` used to then try `openai` and die
  `MissingApiKey` even though `OPENAI_API_KEY` was unset.
- The `recent_commits` host test parses the tool's JSON and asserts the
  `text` field has no raw newline. Searching the serialized JSON for the
  two-byte sequence backslash-n also matched a subject that literally
  mentioned `\n` (improve-self commit `83784944`), so `zig build test`
  failed on a healthy tool.

- An atomic write to a symlinked path no longer replaces the symlink with a
  private regular file. The write is a temp file plus a rename, and a rename
  lands on the *link itself*, so every later write went somewhere no other
  reader looks; the destination's link target is now resolved first and the
  rename lands on that. This is what detached each `clanker improve-self`
  worktree's `state/improvements.jsonl` from the checkout's ledger: the link
  was made correctly, the first whole-file rewrite replaced it, and the
  improvements recorded afterwards were discarded with the worktree, so the
  loop could re-propose ideas it had already rejected. The same worktree's
  `config.local.toml` is linked the same way and had the same defect.
  Directory symlinks were never affected, which is why a `state -> …` link to
  durable storage kept working.
- `clanker commit --yes` no longer auto-applies the guest's fallback plan.
  When the grouping call fails or its reply is unusable (a reasoning model
  can spend the whole `max_tokens` grant on its trace and truncate the plan
  JSON), smart_commit falls back to one generic `chore: update working
  tree` commit; that fallback is now marked `degraded` in the reply, and
  `--yes` refuses it with a nonzero exit and the diff still staged instead
  of writing a commit nobody approved. Interactive confirmation can still
  accept it, with the note on screen. The smart_commit grant also rises
  8192 → 16384 so the ceiling is harder to hit in the first place.
- A compare-and-swap lock is now named for the target *file* rather than
  for the text that named it, so two writers to one file cannot each take
  a lock of their own. `ck_fs_write_if` hashed the joined path string, and
  one file is spelled several ways: `./state/goals.json` under the default
  `agent.sandbox_root`, `/abs/checkout/state/goals.json` under an isolated
  run's `shared_root`, and the guest's own path under an absolute
  `fs_prefixes` grant. Each spelling got its own lock inode, so an
  isolated run and the checkout both passed the hash compare and both
  wrote, losing the earlier write — the outcome the compare-and-swap
  exists to refuse. The name now hashes the target with its directory part
  resolved, which is also what makes two checkouts sharing one `state/`
  independent rather than merely uncollided. The sidecar this replaced
  could not split that way: every spelling named one file on disk.
- Compare-and-swap lock files no longer accumulate in a state directory
  they have nothing to do with. The lock directory resolved against the
  process cwd while the target resolved against the sandbox root, so a
  sandbox rooted in a test's tmp tree wrote a permanent lock file into the
  operator's real `state/locks` — 328 of the 387 files there on
  2026-08-17 named a `.zig-cache/tmp` target. It now resolves against the
  run's own root (the checkout's `shared_root` when there is one, since
  that is the tree an isolated run shares `state/` with) and honours
  `state_base_dir`, so a throwaway tree's locks die with it. What remains
  in a real `state/locks` is one file per document ever CAS-written, which
  is re-acquired rather than added to.
- The 12h lock sweep now happens on its own. ADR 0031 said `state/locks`
  was swept, but the only sweeper was `clanker janitor`, which reports by
  default and deletes with `--yes` — and nothing in clanker fires on its
  own (ADR 0008), so on a host with no cron entry for
  `clanker schedule run-due` the directory grew forever. `ck_fs_write_if`
  now sweeps it: the code that creates lock files removes the ones nothing
  will reuse, which adds no daemon and no scheduling thread. A pass runs at
  most hourly, paced by the mtime of a `.swept` marker in the directory so
  every write does not walk it, and it deletes at most 512 files per pass.
  A candidate is opened with `lock_nonblocking` first and skipped if
  `error.WouldBlock` says someone holds it — the record dates the last
  acquisition, not a live hold, so age alone must never license the delete
  — and the unlink happens while holding the lock so nothing can take it in
  between. The window lives in one place, `cas_lock_record.keep_ms`, read
  by this pass and by the `janitor` guest. Lock files written under the old
  name are orphans from this release and age out through the same sweep.
- A lock file carrying no record at all is swept too, on its mtime, once it
  has gone untouched for longer than the sweep interval. Retention reads the
  timestamp out of the holder record and treats one it cannot parse as
  unknown rather than old — right for a garbage record, which must not date
  to 1970 and take live locks with it, but it left a file with *no* record
  invisible to every sweeper and accumulating without limit. Zero length is
  the discriminator and is deliberately narrower than "unparseable": a live
  acquisition is zero-byte only between creating its lock file and writing
  the record, and it holds the lock across both, so the `lock_nonblocking`
  probe already refuses that case.
- A goal loop no longer dies on a single failed turn. A turn that errors
  (for example a completion whose whole token grant is spent on
  reasoning, `AnswerTruncatedToEmpty`) used to terminate the loop and
  discard the run's context; it now counts as a failed turn — the next
  turn is told the error and to re-check state before redoing work — and
  only three consecutive failures block the goal. An evaluator error is
  treated as a conservative continue, matching how unreadable evaluator
  output was already handled.
- Tool-result spilling no longer reloads the `spill` WASM guest and
  rewrites the same file on every agent iteration. Pruning is
  request-only, so the pruned copy carrying the locator is discarded
  after each request and the same oversized result is re-pruned from the
  pristine history next iteration; the spill id is a content hash, so
  every one of those writes wrote bytes already on disk. Ids written in a
  run are now remembered, and the guest is loaded only when there is
  something new to write. Locators are still applied every iteration —
  they are what the request copy carries.

- Resizing the terminal during `clanker repl` no longer aborts the
  process and wrecks the terminal. vaxis ran its winsize callbacks
  inside the SIGWINCH handler, and those callbacks use `std.Io`; a
  `std.Io` call from a signal that interrupted an `Io.Threaded` pool
  thread mid-syscall hits `.blocked => unreachable`, and the read thread
  sits in `readv` on the tty for the whole run, so it is the thread the
  signal lands on. SIGWINCH now writes one byte to a self-pipe and a
  plain thread runs the callbacks in normal context. Measured on a pty
  harness: the old build aborted between 246 and 1594 resizes, the new
  one survives 5000, and resizes are still applied (the app redraws at
  each new geometry — bursts coalesce, none are lost).
  ([bug](docs/reports/bugs/2026-08-17-tui-resize-crash-sigwinch-in-signal-handler.md))
- A panic anywhere in `clanker repl` now leaves the terminal usable.
  `vaxis.recover()` wrote the reset through a buffered `std.Io` writer,
  so a panic raised *by* `std.Io` was raised again by the recovery
  itself, from inside the panic handler, recursing until the stack
  overflowed — 2 MB of trace, 3336 repeated frames, and not one of the
  four reset sequences delivered, leaving raw mode, the alt-screen and
  mouse tracking all still on with the panic message invisible inside
  the alt-screen. `recover()` now uses raw `write(2)` plus `tcsetattr`,
  and `handlePanic` claims the reset once so a panic during recovery
  falls through to `std.debug.defaultPanic`. Same crash now prints three
  frames and hands the terminal back.
- `clanker autolearn --model <reasoning model>` no longer fails with
  "synthesizer returned an empty section". `max_tokens` bounds output,
  and on a reasoning model reasoning *is* output, so the 2500-token grant
  sized for the section was spent entirely on `reasoning_content`: the
  provider answered 200 with empty `content` and `finish_reason: length`.
  The grant is now 16000, and `ck_llm` logs why any completion came back
  empty — a truncated reasoning spend, a truncation with no reasoning, or
  a model that simply answered nothing — instead of handing every guest
  an indistinguishable empty string. The deterministic Autolearn section
  was always written before the synthesis pass ran, so a failing run
  still updated `docs/ROADMAP.md`.
- Every other tool that reaches a model through `ck_llm` is now budgeted
  for a reasoning model too, not just `autolearn`. `thinking`, `advisor`,
  `compare`, `arena`, `chain`, `mutate`, `translate` and `smart_commit`
  each granted what their answer needed and nothing for the reasoning
  that precedes it, so on a thinking model each returned empty content.
  The two fail-open ones failed silently: the effort classifier asked for
  5 tokens — one word — and got `''` back on every call, so `auto_thinking`
  had been resolving to `medium` for every turn of every run, and the
  post-turn advisor's 256 never parsed as a note. Each grant is now its
  content budget plus a 4096-token reasoning headroom
  (`tools/zig/llm_budget.zig`), and `toolDescriptorGate` fails any
  `"llm": true` descriptor granting less, so a new tool cannot
  reintroduce it. Measured on `deepseek-v4-pro`: the classifier prompt
  returns `''` at the old grant and `xhigh` at the new one, spending 95
  tokens of it — the grant is a ceiling, not a spend, so this does not
  make a non-reasoning model cost more.
  `providers` is deliberately unchanged: its liveness ping asks for one
  token and never reads the completion. `rlm`, `subagent` and `swarm`
  reach a model through `ck_subagent`/`ck_swarm`, which the harness
  budgets, not through this grant
  (docs/reports/bugs/2026-08-17-ck-llm-grant-spent-on-reasoning.md).
- Scrolling in `clanker repl` can now reach the messages above an expanded
  reply. The scroll guards, the anchor floor, the search jump, and the
  scrollbar all measured the transcript in *lines* against a screen
  measured in *rows*; an expanded fold's header row and any wrapped line
  broke that equivalence, so a reply taller than the screen either
  disabled scrolling entirely (tall terminal: overflow in rows, "fits" in
  lines) or stranded the window partway with the earliest lines
  unreachable. Every scroll bound now comes from a wrap- and fold-aware
  row walk
  (docs/reports/bugs/2026-08-17-scroll-cannot-reach-above-expanded-reply.md).
  Found alongside: the width used to judge whether a reply folds was never
  recorded, so foldability had always been judged at an 80-column
  fallback; it now follows the drawn width.
- `clanker run` no longer exits 0 with nothing on stdout when the final
  reply is cut at the completion-token cap before any text arrives: the
  run now fails with an error naming the limit, and a truncated but
  non-empty final answer is returned with a loud warning
  (docs/reports/bugs/2026-08-17-run-reports-success-on-empty-length-stop.md).
- An expanded reply fold in `clanker repl` no longer shows a stray `›` on
  its first body line. The turn arrow marks where a reply's prose begins,
  but a folded reply's `▾ reply` header already does that, so the arrow
  under it read as a prompt marker; a reply now drops the arrow when it
  folds and keeps it when it stays unfolded
  (docs/reports/bugs/2026-08-17-fold-first-line-keeps-turn-arrow.md).
- Scrolling in `clanker repl` now advances through a fully expanded fold.
  The layout treated a fold as an atomic block in every state, so with the
  anchor anywhere inside an expanded reply taller than the screen, every
  wheel notch or PgDn re-rendered the same frame (pinned at the header)
  until the anchor passed the whole reply, then jumped past it. An open
  fold is now measured per-line, exactly as it is drawn; the block remains
  atomic only while collapsed or animating
  (docs/reports/bugs/2026-08-17-expanded-fold-cannot-be-scrolled-through.md).
- `ck_fs_write_if` no longer creates the target's parent directories on a
  hash mismatch. The lock used to live inside that directory, so the
  directories had to exist before the compare; an ordinary contention
  refusal therefore left a directory tree behind for a file it never
  wrote. Parents are now created after the compare.
- A long reply in `clanker repl` can be folded back in after being expanded.
  The `▸ reply, N more lines` header is the fold's only toggle, and the draw
  loop stopped drawing it (and registering its click target) once the reply
  was fully open, so expansion was a one-way door. The header now persists as
  `▾ reply` while open and clicking it collapses the reply again; this also
  removes a one-row bottom-alignment error on expanded replies, whose header
  row the layout counted but the draw never drew
  (docs/reports/bugs/2026-08-17-fold-header-vanishes-when-expanded.md).
- `clanker commit` now writes the plan it previewed. It called `smart_commit`
  twice — a dry run for the preview, then an independent apply — and each call
  asked the model to group the diff again, so the messages and the grouping
  that landed could differ from the ones just confirmed. Observed on a ten-file
  diff whose second reply was truncated at the tool's token grant: an approved
  `fix(smart_commit): …` plan was committed as one
  `chore: update working tree`. The confirmed plan is now handed to the write
  through a new `commits` input on `smart_commit`, which writes it as given and
  refuses any file the current diff does not hold. One grouping call per
  `clanker commit` instead of two, so runs are also cheaper.
- `clanker commit` in the default `staged` scope now commits the staged
  content, not the working-tree copy. It staged each group's files with
  `git add` and then committed them by pathspec, and both of those take the
  working-tree copy — so an index narrowed to one session's hunks (what
  `docs/runbooks/concurrent-agent-sessions-on-one-checkout.md` tells a session
  to do on a shared file) was silently widened with the rest of the file,
  including another session's half-finished edits, and what landed was not
  what the dry run previewed. Each group's commit is now built in the index
  from the staged state, so unstaged edits stay unstaged; the index is put
  back afterwards, including after a failure. `clanker commit --all` is
  unchanged, since taking the working tree is the point of that scope.
  each group's files and then ran a bare `git commit`, which commits the whole
  index — so anything staged before the verb ran was swept into the first
  group's commit and every later group found nothing left to commit. Each
  group is now committed with a pathspec, leaving the rest of the index alone.
  The condition needed something staged up front, which is what the
  concurrent-sessions runbook asks a session to do; `clanker commit --all` on
  a clean index was unaffected.
- A `git` command that `clanker commit` runs and that fails is now a refusal
  naming git's stderr. The exit status arrives inside the sandbox's exec
  reply rather than as an error, and the result was discarded, so a
  `git commit` with nothing to commit was still counted in the
  "committed N commit(s)" line.
- `clanker serve` no longer logs every completed `GET /api/events` at ERROR,
  nor counts it as a server error. The SSE handler writes its own `200 OK`
  rather than going through the shared responder, and it did not report that
  status back, so each finished subscription was logged with `status=0` and
  added to `http.errors_total` in `GET /api/metrics` — two per web UI page
  load, which made the instance's own health number unusable.
- A `GET /api/events` subscriber whose client has gone now releases its
  subscriber slot and connection thread immediately instead of at the next
  write. On an idle bus the first write is the 15-second keepalive ping, so
  dead subscriptions accumulated over that window against the 32-subscriber
  and 64-connection ceilings; a browser that reloads often could be answered
  `503 too many live subscribers`.

- The web UI's Activity view shows every action the board recorded, not only
  the `log` ones. A card's `log` array is written by exactly one action —
  `log` — so adding, moving, claiming, closing or archiving a card produced
  no row, and a board being actively worked on read as idle; the view's own
  empty state told the reader to move a card, which was one of the actions it
  could not show. The timeline is now merged from the card logs and the board
  room's action messages, because neither feed is complete alone: the logs
  outlive the room's history window, and the room is the only record of every
  other action. On one board this went from 23 entries ending 2026-08-14 to
  65 ending 2026-08-16
  (docs/reports/bugs/2026-08-17-activity-view-shows-only-log-actions.md).
- `clanker janitor` now sweeps the graphs of nested runs. Its predicate
  matched only `run-*.json`, while a sub-agent run writes
  `sub-<unix nanoseconds>.json` to the same directory, so those graphs were
  outside both the newest-200 retention and the check made before deleting —
  they accumulated for good and could not be removed even when named. A
  directory of 208 graphs reported nothing to reclaim because only 187 of
  them were `run-`; it now reports the 8 beyond the newest 200. The predicate
  also now requires a parsable timestamp, so a hand-made `run-notes.json` is
  left alone
  (docs/reports/bugs/2026-08-17-janitor-never-prunes-sub-run-graphs.md).
- Typing `failed` in the web UI's Runs filter no longer throws. The filter's
  failure test read `nodes` as the node array of a whole graph, but the run
  listing sends `nodes` as a count, so it threw a `TypeError` on the first
  run with any steps. It could never have matched either, because the listing
  carried no failure signal at all; it now does (see Added)
  (docs/reports/bugs/2026-08-17-runs-filter-failed-keyword-throws.md).
- Shift+Enter in `clanker repl` inserts a line break instead of spraying
  `warning(vaxis_parser): unhandled ss3: 4d` over the screen. Konsole's
  default keytab sends Shift+Return as `ESC O M`, which the vendored vaxis
  parser dropped (now mapped to keypad Enter by
  `patches/vaxis-ss3-keypad-enter.patch`); terminals speaking the kitty
  keyboard protocol report the chord as Enter+Shift and land in the same
  handler. The composer grows one row per line, each line renders on its own
  row, and the submitted task carries real newlines, echoed into the
  transcript as one row per line. Up/Down move the cursor between draft
  lines — which also scrolls a draft taller than the box, since the box
  follows the cursor's line — and fall through to history recall at the
  first/last line; the mouse wheel does the same when the pointer is over
  the input box. Mouse drag now selects inside the input box too (it was
  transcript-only, and Konsole intercepts the Ctrl+Shift+C fallback), with
  the same copy-on-release. Multi-line pastes (bracketed and Ctrl+Shift+V)
  keep their line structure instead of being folded to spaces, and history
  recall restores it. Documented in the repl keys help
  (docs/reports/investigations/2026-08-17-tui-shift-enter-ss3-unhandled.md).
- `std.log` output from vendored dependencies (vaxis included) is routed
  through clanker's leveled logger instead of std's raw stderr handler, so
  it can no longer paint over the repl's alt-screen and follows the same
  one-line format and runtime threshold everywhere else.
- The web UI's run history and `clanker graph` no longer show months-old
  sub-agent runs as the newest ones. `state/runs/` holds top-level runs as
  `run-<unix seconds>` and nested ones as `sub-<unix nanoseconds>`, and both
  listings ordered the raw filenames, where every `sub-` sorts after every
  `run-`. The newest-50 page was therefore filled with the oldest sub-runs, so
  the System view's history panel and the Runs picker's default selection both
  opened on a run from days earlier. Listings now order by the timestamp in the
  id, so the two id shapes interleave chronologically; `clanker janitor`'s
  newest-200 retention uses the same order
  (docs/reports/investigations/2026-08-17-web-ui-run-history-stale.md).
- `clanker commit` no longer collapses a describable staged diff into one
  generic `chore: update working tree` commit: the `smart_commit` descriptor
  now grants `ck_llm` 4096 completion tokens (the 1024 default truncated the
  grouping reply mid-JSON), and when the guest does fall back it says why in
  the plan's note instead of failing silently
  (docs/reports/bugs/2026-08-16-smart-commit-generic-message.md).
- The `zig_std` tool's host call (`ck_std_api`) no longer leaks the
  PATH-resolved `rg` path on every symbol lookup; debug builds printed one
  DebugAllocator leak trace per lookup at shutdown
  (docs/reports/bugs/2026-08-17-resolveexecpath-candidate-leak.md).
- `clanker repl` copy (mouse-drag release and Ctrl-Shift-C) now also pipes
  the text into the host clipboard tool (`wl-copy`, `xclip`, `xsel`, or
  `pbcopy`, chosen from the desktop session) as a fallback to OSC 52, so a
  terminal that ignores OSC 52 clipboard writes still receives the copy.
  The keys help documents that Shift+drag uses the terminal's own selection
  and that the hosting terminal may intercept Ctrl-Shift-C.
- `agent.sandbox_follow_symlinks` now also applies when a turn issues two or
  more tool calls. The parallel tool path builds its own sandbox and omitted
  the flag, so symlinked granted paths (`state/`, `.local`) were still
  refused there while single-call turns worked.
- The `file_ops` tool can now reach `zig-out/gate-failure.txt`, so a model
  can inspect why a gate run failed instead of being refused by sandbox
  policy.
- `clanker autolearn` no longer fails with "no observations to synthesize"
  (with `--model`) or silently aggregates nothing (without) once
  `state/autolearn.jsonl` exceeds 1 MiB. The guest read the whole log with a
  single `ck_fs_read`, which returns TooLarge past the 1 MiB host arena, and
  a `catch null` turned that into an empty log. It now tails the newest
  256 KiB via `ck_fs_read_range`, like the `reasoning` and `improve_history`
  guests.
- TUI: Ctrl+C is no longer swallowed while the model/theme picker, command
  palette (Ctrl+P), or transcript search (Ctrl+R) is open. It now closes the
  modal like Escape, and with a turn streaming it also interrupts the turn —
  previously those two modals consumed every unmatched key, so a streaming
  turn could not be stopped until the modal was dismissed by hand. The ask
  modal already handled this.
- `clanker commit` works again. It called the `smart_commit` guest through a
  helper that wraps its argument as `{"args": "<string>"}` and requires a
  `text` field in the reply; the guest emits neither, so the verb always
  failed with "the internal tool returned unreadable output" — after paying
  for the grouping model call — and never received `dry_run` or `scope`, which
  made the post-confirmation write a second dry run that reported success.
  The command now sends a structured body and renders the reply host-side
  through `commit_logic.renderPlan`, with different wording for a proposal and
  an applied commit so it cannot claim a write it did not make.
- `improve-self` reclaims its own worktree when a run promotes nothing.
  `cleanup` used to keep every unmerged worktree "for manual recovery",
  but the `merged` flag is only ever set by the promotion path, so a run
  that promoted nothing left behind a worktree whose branch was
  byte-identical to its base. Those accumulated indefinitely and
  `clanker janitor` will not remove them. `cleanup` now asks git whether
  the branch holds commits the base lacks, and keeps the worktree only
  when it does.
- `improve-self` folds commits made inside its worktree outside the
  promotion path back into the base branch at the end of a run, instead
  of stranding them on an abandoned branch. Conditioned on a fully
  passing final gate — the same bar a promotion clears — and on
  `agent.git_commit`; a run that ends on a failing gate still keeps its
  worktree for manual recovery.
- Lifecycle hooks that never read stdin (`printf`, `echo`) no longer fail
  the hook when the child exits before the payload write finishes. The
  decision on stdout still applies.
- `GET /api/goals` no longer 500s on a valid store. The list guest wrote
  `"goals"` then the array without a colon (`{"ok":true,"goals"[...]}`),
  so the HTTP handler rejected it as bad JSON.
- Plugin `app.js` / `app.css` responses are logged as 200. The handler
  already sent 200 but never set `request_status`, so every load looked
  like a status-0 error.
- `GET /webui/core/slash.js` no longer serves `app.js`. The slash module
  was on the asset list but reused `app.js`'s render/gzip slot, so a
  gzip client executed `app.js` at the slash URL and then requested
  `/webui/core/core/*.js`. Each first-party module now has its own
  cache kind; the default slot is only `app.js`.
- A run can no longer spend itself compacting a history it cannot shrink.
  Compaction preserves the system message and the last six messages, so when
  those alone exceeded `agent.max_history_tokens` it was asked to compact on
  every iteration and freed nothing on any of them — a run seen doing this past
  iteration 173, printing throughout, was making no progress at all. The
  threshold is now lifted for the run when it falls below what compaction cannot
  remove (with headroom, never past what the model's window allows) and says so
  once; a run that still needs to compact five iterations in a row ends with
  `CompactionStalled`, reported as an outcome with partial work rather than a
  crash, naming both the configured cap and what the model's window leaves
  compaction, since raising the cap only helps when the model has room. The
  16000 default is unchanged and is still small for a large-window model —
  `docs/configuration.md` and a new
  `docs/runbooks/agent-run-compaction-thrash.md` cover setting it.

- The compaction summary no longer fails on every compaction on a thinking
  model. Its 512-token budget was the combined allowance for reasoning and
  answer, and reasoning runs first, so a real transcript spent the whole budget
  before a single content token: the LLM summary was replaced by the extractive
  fallback every time, at the price of a round trip each. The call now asks for
  a budget that fits both and the least reasoning the model will do, uses the
  model's own reasoning text when content comes back empty, distinguishes a
  summary truncated at the budget from an empty one, and stops asking after two
  failures in a run rather than paying for the same failure per compaction.

- HTTP API status codes now distinguish client mistakes from missing
  resources. Tool-backed routes (`/api/board`, `/api/knowledge`,
  `/api/prompts`, `/api/compare`, `/api/arena`) map `no such …` / `not
  found` refusals to 404 instead of 400. `POST /api/notify` with unreadable
  JSON is 400, not 500. `POST /api/sessions` without `import_chat` is 400
  instead of listing chats; `DELETE /api/sessions` is 405. A query string
  is no longer treated as part of a session, run, log, or knowledge id.
  Chat edit/delete/react answer 404 for a missing message and 403 when
  the caller is not the sender (reacting to a missing message used to
  look like a successful un-react). `GET /api/files` on a missing
  directory is 404 instead of silently listing the workspace root. A
  malformed body on `POST /api/compare/<id>` or `POST /api/prompts` is
  400, not 405.
- Web UI ES modules no longer 404 as `/webui/~tag/core/core/…`. Two
  stacked bugs: `run-metrics.js` reused `app.js`'s gzip slot, so a gzip
  client received `app.js` at the run-metrics URL and then resolved
  `./core/utils.js` under `/core/`; and the import map prefix `/webui/`
  also matched already-tagged URLs. `app.js` never ran, so the page was
  a rail with an empty main column.
- The model picker sat under PatternFly's main column (`z-index: 100`)
  so clicking the model chip opened a panel nobody could see.
- `GET /webui/` (trailing slash) serves the same HTML as `/webui`.
- Opening the phone rail no longer focus-scrolls Work (Chat/Board) off
  the top of the drawer. Picking a section closes the drawer.
- Rooms `#chat-log` is no longer a live region. New messages are
  announced once through `#chat-status`. Theme is a picker, not an
  11-click cycle. Channel list first paint says Loading channels.
- Phone suggestions and attachment remove are 44px. Fleet/Arena canvas
  and mesh lamps read computed theme tokens only. `HEAD /webui` returns
  the same headers as GET with an empty body. Health tiles use a lamp
  dome instead of a left-edge tab.
- System `#progress-log` is no longer a live region (status goes through
  `#progress-status`). The header model chip is not live either. The
  Runs graph flushes layout once, then reads node heights.
- Chat run metrics tick every frame and update tokens, cache and tok/s
  mid-turn from stream `usage` events plus a live output estimate.
- Isolated `clanker run` now provisions a checkout `state/` path that is a
  symlink to shared durable storage. Previously Zig reported `NotDir` before
  any shared paths were linked, leaving host-side state private to the
  worktree while sandboxed tools used the checkout state.
- Board no longer paints the leftover `#card-form` Add control. PatternFly
  `display: grid` on `.pf-v6-c-form` was beating the UA `[hidden]` rule;
  the form stays in the tree for the board module but stays hidden.
- Unmarked buttons (plugin filenames, crumbs, `#card-add`) are no longer
  styled as the accent Run pill. That look is `button.primary` and `#submit`
  only.
- Empty Chat hides Fork/Rename/Archive/Delete and find until a turn exists.
  Plan, Research, Long run, and Isolated worktree sit in one Run shape
  control. Submit is labeled Run.
- Board filters fold behind “Filter cards”; Only mine is a single checkbox.
  Creating a goal says it saves a Backlog card and does not start a run.
- Rooms’ selected channel is a cabinet lamp on surface-2, not a Slack
  accent slab. Board header is a plate, not a tinted Trello bar.
- Files ships on when `state/webui_plugins.json` is missing, and its
  toolbar uses Hidden / Refresh / Close.

### Changed

- The committed `config.toml` ships one default model per provider, not
  a catalog. Extra SKUs belong in `config.local.toml` or Discover.
- `clanker serve` greets a terminal with a startup card: robot badge,
  version, clickable Local URL, whether the network can reach it, the
  proxy mount when enabled, and how to stop. A piped stdout still gets
  the original bare `http://host:port/webui` line, so scripts that
  parsed it keep working; colors honor NO_COLOR.
- The models.dev catalog is a local snapshot (`state/models-dev.json`),
  not a 24-hour cache. Serve start and catalog search do not hit the
  network when that file exists. First use (or a missing file) downloads
  it once; `clanker providers refresh` and Refresh catalog on the Models
  view replace it. An older `state/cache/models-dev.json` is still read
  so an existing download is kept on upgrade.
- Discover and `providers catalog` only list models.dev providers
  clanker can run. Support is the catalog `npm` package plus a base URL,
  mapped in `src/llm/catalog.zig` to `openai_compat` (Bearer API key),
  `anthropic` (API key or OAuth by token shape), `vertex_anthropic`
  (GCP `oauth_refresh`), `gemini` (`x-goog-api-key`), or `azure_openai`
  (`api-key` plus a resource host). Vertex Gemini and Bedrock stay out.
  A missing `[providers.*]` table in a snippet is now filled from that
  mapping (kind, base_url, api_key_env) instead of a comment.
- `kind = "gemini"` talks to Google Gemini generateContent (AI Studio).
  `kind = "azure_openai"` talks to Azure OpenAI chat completions
  (deployment in the URL, optional `api_version`).
- `kind = "vertex"` is Google Vertex AI: Gemini generateContent by
  default, Anthropic `:rawPredict` when the model id is Claude. Same GCP
  project/location/ADC auth as `vertex_anthropic`, which stays the
  Anthropic-only kind.
- Web UI shell follows a session-first layout: conversations stay in the
  left rail, Watch and Set up fold away, and Chat is a header / transcript
  / docked-composer column. PatternFly page chrome and cabinet colors stay.
- Phone Chat header keeps More only so empty-state suggestions sit above
  the docked composer instead of under it. More holds the same Fork/Rename/
  Delete nodes and find-in-transcript on a phone.
- Operator web UI pages (Runs, Fleet, Models, Board, Rooms, and the rest)
  fill the main column instead of sitting in Chat's ~46rem centered
  measure. Chat keeps that reading width.
- Files view uses the full main column when no preview is open, and
  filename / crumb / sort controls are no longer painted as 40px accent
  pills by the host button rule.
- Muted text meets 4.5:1 contrast on every theme's raised surface: Latte,
  Frappé, and Tokyo Night Day each read under the WCAG AA floor on
  surface-2 and got a palette-native `--fg-muted` step.
- Touch targets grow to a 44px minimum on coarse-pointer (touch) devices;
  desktop keeps the 40px density.
- Vendored PatternFly CSS is subset to the twelve components the UI
  actually uses (1.8MB to 625KB); `scripts/subset-patternfly.py`
  regenerates it from a stock release file after an upgrade.
- The composer's Run and Stop controls are one circular icon spot, the
  send arrow / stop square convention of mainstream chat UIs. The
  keyboard-shortcut hint moved into the tooltip and accessible name, and
  the two buttons still hand focus to each other across a run.
- An empty conversation centers a greeting and the composer mid-screen
  with the suggestions underneath, the mainstream chat empty state; the
  first turn docks the composer back to the bottom. Turn actions (Copy
  answer, Run again, Edit & resend, Branch, Apply plan) already matched
  the convention and are unchanged.

### Fixed

- A status change now carries the store's README inventory with it, in the
  `research`, `rfc` and `reports` tools alike. Previously only `create` ever
  wrote the inventory's copy of the status, so every research note stayed
  `Draft` and every RFC stayed `Draft` however often its own status moved, and
  the reports inventory listed resolved bugs as `Open` indefinitely. All three
  now share one helper, and each reports whether the index write landed.

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
