# PRD — Out-of-tree tools (`agent.tools_dir` as a list)

## Status

Draft. Nothing in this PRD is built yet. Named here as the open question
already on record in
[docs/prds/0010-plugin-manifest-sdk.md](0010-plugin-manifest-sdk.md#open-questions--future-work)
and in `docs/ROADMAP.md`'s plugin-manifest-SDK entry: "`agent.tools_dir` as a
list... is what still stands between the packaging slice and installing a
third-party plugin *alongside* the built-in ones rather than instead of them."
This PRD resolves that question with a concrete design. Sources of truth once
built: `src/tools/registry.zig` (`Registry.load`), `src/config.zig`
(`Agent.tools_dir`), `tools/zig/plugins.zig`.

Distribution (fetch/install/signing/a registry index) is not reopened here —
see [ADR 0007](../adrs/0007-plugin-manifests-are-declarative-and-unsigned.md).
This PRD is only about loading more than one already-trusted local directory.

## Problem

`agent.tools_dir` is one string (`src/config.zig:177`, default
`"tools/manifests"`), and `registry.Registry.load` takes exactly one directory
(`src/tools/registry.zig:167`). Nineteen non-test call sites across nine files
pass it straight through, ten of them in `src/cli.zig` alone:
`src/cli.zig`, `src/tui/repl_vaxis.zig`, `src/agent/subagent.zig`,
`src/peers/phonebook.zig`, `src/mcp/server.zig`, `src/research/autoresearch.zig`,
`src/doctor.zig`, `src/improve/engine.zig` (`:1230`, `:1467`, `:1725`: three
sites in the self-improve engine, the consumer most likely to break silently),
`src/gate/checks.zig` (`toolDescriptorGate`).

ADR 0007 already decided a plugin is "a directory holding a manifest and the
module it names", moved there by hand, and that `agent.tools_dir` can point at
it. That is true today only if the user is willing to point `tools_dir` at
*that* directory instead of `tools/manifests`, which means every built-in tool
disappears the moment a third-party one is added — or the user copies the
third-party manifest and wasm into `tools/manifests` by hand, which works
until the next `clanker` upgrade touches that same tree (a `git pull`, a
reinstall) and the hand-copied files either get overwritten or now look like
part of the harness's own checkout with no record of where they came from.

Neither option is "alongside". A user with one third-party plugin they trust
has no way to keep it in its own directory, separate from clanker's own tree,
and have both load.

Separately, `clanker plugins list` (and the REPL's `/plugins`, and
`GET /api/plugins`) goes through the `plugins` guest, which hardcodes its
own copy of the default — `const tools_dir = "tools/manifests";`
(`tools/zig/plugins.zig:13`) — rather than reading `agent.tools_dir` from
the harness at all. Today that is a latent bug only for the rare user who
already changed `tools_dir`; multi-directory support would make it wrong for
anyone using the feature this PRD adds, since the guest would never see the
second directory. This is called out in Known issues below because it has to
be fixed as part of this work, not filed separately.

## Goals

1. `agent.tools_dir` accepts more than one directory, each scanned
   independently, so a user can keep a third-party plugin in its own
   directory — untouched by clanker's own tree and unaffected by a clanker
   upgrade — while the built-in tools keep loading from `tools/manifests`.
2. A bare string `tools_dir` (today's only form, and what every existing
   `config.toml` has) keeps working with no change in behavior. This is
   additive, not a migration.
3. A tool `name` collision across two directories is a visible warning, not a
   silent shadow. (Same-directory collisions already silently shadow per
   `toolDescriptorGate`'s doc comment; that stays as-is — this only changes
   the cross-directory case, which a user did not author as one file tree and
   has no other way to notice.)
4. Every existing single-directory consumer keeps working with the same
   call-site shape, adjusted mechanically for the new type — no caller grows
   new branching logic to handle "one dir" vs "many".
5. `plugins` (`/plugins`, `/api/plugins`, `clanker plugins list`) reads the
   real configured directory list instead of its hardcoded default, so `list`
   shows tools from every configured directory, not just the first.
6. `clanker plugins new` and `clanker plugins validate` behave sensibly with
   more than one directory configured (see Design).

## Non-goals

- Fetching, installing, or signing a plugin. Still ADR 0007's call; this PRD
  changes nothing about *how a plugin arrives on disk*, only how many
  directories the harness is willing to look in once it's there.
- A registry index or any notion of "installed plugins" as a tracked list.
  The directories in `tools_dir` are the only bookkeeping.
- Per-directory sandboxing or trust levels (e.g. "the third directory is less
  trusted than the first"). The manifest's own grants are the only sandbox
  boundary (ADR 0007); which directory a manifest was read from does not
  change what it is allowed to declare.
- A `clanker plugins new --dir` flag on day one. Default behavior (see
  Design) covers the common cases; the flag is confirmed non-blocking for
  v1 (Open questions), not Goals.
- Making a loaded tool reachable as `clanker <name>`. Which directories the
  registry scans is this PRD; making a loaded tool invocable as a CLI
  subcommand is PRD 0012's CLI Tier 1. Non-goal here.
- Hot-reloading directories added to `tools_dir` mid-run. `agent.hot_tools`
  already governs re-scanning of *a* configured tree; multi-directory support
  rides that same mechanism unchanged rather than adding a second one.

## Design

**Config shape.** `Agent.tools_dir` changes from `[]const u8` to
`[]const []const u8`. Parsing accepts either a JSON string or a JSON array at
the `tools_dir` key: a string is normalized to a one-element slice at parse
time (`src/config.zig`'s `if (obj.get("tools_dir"))` branch), so every
downstream consumer only ever sees a slice — no dual-type field, no "is this
one or many" branch anywhere outside the parser. A bare string is therefore
still valid config and behaves identically to today, satisfying Goal 2.

```toml
# still valid, unchanged behavior
[agent]
tools_dir = "tools/manifests"

# new: built-ins plus a directory the user manages themselves
[agent]
tools_dir = ["tools/manifests", "/home/user/.config/clanker/plugins"]
```

**Registry.load.** Signature becomes
`load(io, arena, base, tools_dirs: []const []const u8) !Registry`. The body
loops the existing single-directory scan once per entry, in list order,
inserting into the same `HashMap` it already builds. Precedence: **last
directory in the list wins**, extending the existing documented
last-insert-wins behavior (`toolDescriptorGate`'s comment, `registry.zig`)
rather than introducing a second precedence rule for the multi-directory case.
This also reads naturally as "put your overrides last": `["tools/manifests",
"~/.clanker/plugins"]` lets a locally-managed plugin override a built-in of
the same name by design, not by accident.

When a later directory's manifest overwrites a `name` already inserted from an
earlier directory, log a warning naming both paths and the tool name (Goal 3).
A same-directory collision (two manifests in one dir declaring the same
`name`) stays silent, matching current behavior — it is one author's own
mistake in one tree, not two independently-authored directories colliding.

A missing directory in the list is not fatal: log the same warning
`Registry.load` already logs for a single missing directory
(`registry.zig:174`) and continue with the rest, so a stale or
not-yet-created entry in `tools_dir` degrades to "one plugin missing", not
"no tools at all".

`resolveWasmPath` is unaffected: a `wasm` value with a path separator still
resolves against the process cwd, and a bare `wasm` still resolves beside its
own manifest's directory (not "beside `tools_dirs[0]`"). Multi-directory
support changes *which directories get scanned for manifests*, not how a
found manifest's own `wasm` path is resolved — worth stating explicitly since
it is easy to assume otherwise.

**Call sites.** `src/cli.zig`, `src/tui/repl_vaxis.zig`,
`src/agent/subagent.zig`, `src/peers/phonebook.zig`, `src/mcp/server.zig`,
`src/research/autoresearch.zig`, `src/doctor.zig`, and `src/improve/engine.zig`
(three sites: `:1230`, `:1467`, `:1725`) all pass
`cfg.agent.tools_dir` straight to `Registry.load` today; each becomes a
mechanical no-op change once the type is a slice, since none of them branch on
it. `src/gate/checks.zig`'s `toolDescriptorGate` is called by the self-improve
engine against a staged worktree it controls; it takes the same slice and
loops the same way. It only ever sees directories that exist inside that
worktree — an out-of-tree directory named by an absolute path outside the repo
is invisible to it by construction, since the gate operates on the staged tree
a proposal touches. No special-casing needed there: a proposal cannot touch a
directory the gate never opens.

**`plugins` (Goal 5).** The guest's hardcoded
`const tools_dir = "tools/manifests"` (`tools/zig/plugins.zig:13`) is
replaced with the directory list read via `ck_harness_config` (the same
channel `Tool.config` already uses to hand a guest host-side data, per
`registry.zig`'s `config_json` field), listing every configured directory in
order and merging their manifest listings the same way `Registry.load` merges
tool entries — last directory wins on a `name` collision, same rule, so
`/plugins list` never disagrees with what the model's own tool catalog
contains.

**`clanker plugins new <name>`.** With one directory configured (the common
case, and every case before this PRD), behavior is unchanged: writes into that
directory. With more than one configured, writes into the **first** listed
directory by default — the built-in tree, in the common `["tools/manifests",
"~/.clanker/plugins"]` ordering — since scaffolding a new tool is usually
extending the project's own tree, not the user's separately-managed one. A
`--dir <path>` override is Open questions, not built here; until it exists,
a user who wants to scaffold directly into their own directory runs `plugins
new` and moves the two files, which is the same "user moves the bytes" model
ADR 0007 already settled on for plugins in general.

**`clanker plugins validate [path]`.** An explicit `path` argument is
unchanged: validates that one file or directory. With no argument, validates
every configured directory in `tools_dir` (today: just the one), and exits
non-zero if *any* directory has *any* error — matching today's single-directory
exit semantics, just applied per-directory then OR'd together.

**v1 scope pins (non-blocking OQs closed).** No `clanker plugins new --dir`
flag in v1 (scaffold into first-listed, move files if needed). No
`doctor.zig` warning for an empty-but-present configured directory (missing
path already warns; empty stays silent, matching today's single-directory
behavior). No per-directory `enabled` toggle (remove the entry from
`tools_dir` instead).

**Dependencies.**

- Hard: [ADR 0007](../adrs/0007-plugin-manifests-are-declarative-and-unsigned.md)
  (local trusted directories only; no fetch/signing). Existing
  `Registry.load` single-dir scan and `toolDescriptorGate` last-insert-wins
  semantics.
- Soft: [PRD 0010](0010-plugin-manifest-sdk.md) already named `tools_dir` as a
  list as the remaining packaging gap; this PRD is that resolution. PRD 0012
  (CLI Tier 1 / `clanker <name>`) stays out of scope.
- Existing: `src/config.zig` (`Agent.tools_dir`), `src/tools/registry.zig`,
  `tools/zig/plugins.zig` (hardcoded default to replace via
  `ck_harness_config`), the nine call-site files listed under Design.

**Implementation.**

1. Config parse: change `Agent.tools_dir` to `[]const []const u8` in
   `src/config.zig`; accept string or array; normalize a bare string to a
   one-element slice at parse time.
2. Registry load: update `Registry.load` to take `tools_dirs: []const []const u8`,
   scan each in order, last-listed wins on cross-directory `name` collision
   with a warning naming both paths; missing entry warns and continues.
3. Call sites: mechanical type adjustment across `src/cli.zig`,
   `src/tui/repl_vaxis.zig`, `src/agent/subagent.zig`, `src/peers/phonebook.zig`,
   `src/mcp/server.zig`, `src/research/autoresearch.zig`, `src/doctor.zig`,
   `src/improve/engine.zig` (three sites), `src/gate/checks.zig`: no new
   branching on directory count.
4. `plugins` harness_config: replace hardcoded
   `tools_dir = "tools/manifests"` in `tools/zig/plugins.zig` with the
   configured list via `ck_harness_config`; list/merge with the same
   last-wins rule as `Registry.load`.
5. `plugins new` / `validate`: multi-dir `new` writes into the first-listed
   directory; `validate` with no path validates every configured directory
   and OR's exit status.
6. Tests: bare-string config; two-entry list loads both; cross-directory
   same-name collision → later wins + warning; missing list entry does not
   empty the registry; `plugins` list reflects all configured dirs.

## Known issues

- `tools/zig/plugins.zig:13` hardcodes `tools_dir = "tools/manifests"`
  instead of reading `agent.tools_dir` from the harness at all. This predates
  this PRD (it is wrong today for anyone who already set a non-default
  `tools_dir`) but must be fixed as part of Goal 5, not filed as a separate
  follow-up, since multi-directory support is meaningless from the guest's
  point of view otherwise.

## Failure modes

| Condition | Behavior |
|---|---|
| `tools_dir` is a bare string (existing config) | One directory scanned, identical to today |
| One entry in the `tools_dir` list does not exist | Warning logged naming that path; the other directories still load |
| Every entry in the list is missing or the list is empty | Empty registry, same as today's single-missing-directory case (`registry.zig:174`) |
| Two directories both declare a tool `name` | Later-listed directory's descriptor wins; warning logged naming both paths and the name |
| Two manifests in the *same* directory declare the same `name` | Last-parsed wins, silent — unchanged from today |
| `clanker plugins new` with 2+ directories configured, no `--dir` | Writes into the first-listed directory |
| `clanker plugins validate` with no path, 2+ directories configured | Every directory validated; exits non-zero if any has an error |
| A `tools_dir` list entry is an absolute path outside the repo | Loads normally for the registry; invisible to `toolDescriptorGate` (staged-worktree gate never opens it) |

## Acceptance criteria

- [ ] `Agent.tools_dir` is `[]const []const u8`; a bare JSON string at the
      `tools_dir` key still parses (normalized to one entry).
- [ ] `Registry.load` accepts a directory list, scans each in order, and
      last-listed wins on a cross-directory `name` collision, with a warning
      logged naming both source paths.
- [ ] A missing directory in the list logs a warning and does not prevent the
      remaining directories from loading.
- [ ] Every existing call site (`cli.zig`, `repl_vaxis.zig`, `subagent.zig`,
      `phonebook.zig`, `mcp/server.zig`, `autoresearch.zig`, `doctor.zig`,
      `improve/engine.zig`, `gate/checks.zig`) compiles against the new
      signature with no added branching on directory count.
- [ ] `plugins` reads the configured directory list via
      `ck_harness_config` instead of its hardcoded default; `/plugins list`,
      `/api/plugins`, and `clanker plugins list` (which delegates to the same
      guest per PRD 0010) all show tools from every configured directory.
- [ ] `clanker plugins new` with 2+ configured directories writes into the
      first-listed one; with exactly one, behavior is unchanged.
- [ ] `clanker plugins validate` with no argument and 2+ configured
      directories validates all of them and exits non-zero on any error in
      any of them.
- [ ] A test exists exercising: bare-string config still works; a two-entry
      list loads tools from both; a same-name collision across two
      directories resolves to the later one with a warning; a missing entry
      in the list does not empty the whole registry.

## Open questions / future work

- **`clanker plugins new --dir <path>`.** Confirmed non-blocking for v1: no
  flag; scaffold into the first-listed directory and move the two files when
  targeting another. Add the flag when that workaround is hit often enough
  to ask for it.
- **Empty-directory doctor warning.** Confirmed non-blocking for v1: no
  warn when a configured directory exists but contains zero manifests.
  Missing paths already warn; empty stays silent (same as today's
  single-directory case). Revisit once real usage shows which mistake is
  common.
- **Per-directory `enabled` toggle.** Confirmed out of scope: removing the
  entry from `tools_dir` is already the off switch. No parallel mechanism.
