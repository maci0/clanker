# PRD — Surface Plugins (webui, TUI, CLI)

## Status

**Web UI plugins: Shipped.** `ui/plugins/<name>/` (`plugin.json` +
`app.js` + optional `app.css`), created from chat by the `webui_addon`
tool, discovered by `handleWebuiPlugins`
(`src/cli.zig:7206-7299`), served same-origin from `/webui/plugins/<name>/*`
(`handleWebuiPluginAsset`, `src/cli.zig:7305-7355`), registered client-side
via `window.clanker.registerView()` (`ui/app/core/plugins.js:171-221`),
toggled in System → Web UI plugins, state in `state/webui_plugins.json`. Four
real plugins ship today: `activity`, `office`, `files`, `health`. No PRD or ADR
covered the web UI half before this one; its prior documentation was
`ui/plugins/README.md` plus the review log
`docs/reviews/webui-plugins.md`, which is why its design decisions (CSP-only
trust, no declared-capability sandboxing) were never written down where a
future editor would find them.

**TUI plugins / CLI plugins: Draft.** Confirmed absent by grepping for any
directory-scan, config-driven, or PATH-based extension point feeding
`command_registry` (`src/tui/repl.zig:492-507`, a hardcoded array) or
the `Command` enum (`src/cli.zig:68-105`, a closed compile-time set). Designed
below; do not treat TUI/CLI acceptance criteria as shipped.

## Problem

An operator or a clanker instance improving itself may want to add a view to
the web UI, a slash command to the TUI, or a subcommand to the CLI without
editing and recompiling clanker's own source. The web UI already solved this
for itself, organically, with no PRD to constrain or explain the choice — so
its capability model (same-origin JS trusted the same as the page's own code,
no `fs_prefixes`/`network_allow`-style grant) was never weighed against the
alternative the tool-calling system already uses (`docs/manifest.md`,
`src/toolhost/registry.zig`), and nothing stops the TUI and CLI from growing two
more, mutually incompatible, ad hoc mechanisms the next time someone needs
one.

## Goals

1. Document the existing web UI plugin mechanism as shipped design, not
   README-only tribal knowledge — so removing or changing it is a deliberate
   PRD edit, not an accidental regression nobody notices broke a contract
   that was never written down.
2. Give the TUI a way to register a new slash command from a directory scan,
   with no new trust surface: a TUI plugin can only dispatch to a tool the
   sandboxed WASM tool system already trusts, the same one `/sessions`,
   `/graph`, `/status`, and `/plugins` already dispatch through
   (`CommandSpec.action = .{ .tool = ... }`, `repl.zig:497-500`).
3. Give the CLI a way to add a subcommand two ways, tiered by trust: (a) a
   manifest that passes `clanker <name> [args]` straight to an existing
   sandboxed tool — no new trust, just a shorter invocation — and (b) an
   external `clanker-<name>` binary on `PATH`, git/cargo/kubectl-style, for
   anything a sandboxed tool call cannot express, trusted the same way any
   program an operator put on their own `PATH` already is.
4. Every surface's plugin is discovered by scanning a directory at request/
   startup time, not baked in at compile time, matching how the tool system
   and the existing web UI plugin mechanism already do it.

## Non-goals

- One plugin format that works identically across all three surfaces. A web
  UI plugin is JavaScript in a browser DOM; a TUI plugin is a manifest
  dispatching to a sandboxed tool; a CLI plugin is either the same manifest
  shape or a real executable. Forcing one shape onto three different runtimes
  would fit none of them well — each surface's plugin is native to that
  surface's actual technology, the way the web UI plugin already is native to
  the browser rather than, say, WASM-in-the-browser to match the tool system.
- A capability-sandboxed runtime for TUI or CLI plugins in v1. The tiering in
  Goal 3 gets there for the safe case (manifest → existing sandboxed tool)
  without building a new sandbox; an external `clanker-<name>` binary is
  trusted like any other program on `PATH`, which is the same trust boundary
  `git`/`cargo`/`kubectl` accept for their own external-subcommand plugins.
- Retrofitting `fs_prefixes`/`network_allow`/`exec_allow`-style declared
  reach onto web UI plugins in this revision. Real gap (see Open questions),
  but changing an already-shipped, already-used mechanism's trust model is
  its own decision, not a side effect of writing down what it already does.
- A plugin marketplace, remote install, or update mechanism for any surface.
  Every plugin here is a local directory (or local `PATH` entry) the operator
  already put there — same posture `docs/adrs/0007-plugin-manifests-are-declarative-and-unsigned.md`
  already took for the tool system.
- Custom interactive TUI UI from a plugin (something shaped like `/model`'s
  fuzzy picker, not just a dispatch-and-print command). That needs a real
  plugin-driven rendering surface in the TUI, which does not exist and is
  future work (see Open questions), not this revision's job.

## Design

**Design decisions (locked for TUI/CLI).**

- **CLI argv→JSON.** Tier 1 passes remaining argv as
  `{"args":[...]}`, a raw argv string array, unless the manifest declares
  typed flags (future; not in v1). Matches how `chain`/`gh`/`git` tools
  already take `{"args":[...]}`; no third mapping invented here.
- **Tier-2 discovery.** External `clanker-<name>` binaries are found on
  `PATH` **and** under `~/.clanker/plugins/` (git-style local plugin dir).
  `clanker help` lists both sources, marked external, with the directory of
  origin so an operator can tell PATH from home-dir installs.
- **State files for TUI/CLI.** `state/tui_plugins.json` and
  `state/cli_plugins.json` are enabled-lists (`{"enabled":[...]}`), default
  off — same stance as `state/webui_plugins.json`. Presence of a manifest or
  PATH binary is not consent to run it; the operator enables each name
  explicitly. (Promoted from the Known issues recommendation below.)

### Web UI plugins (documenting what is shipped)

**Layout.** `ui/plugins/<name>/`: `plugin.json` (required),
`app.js` (required), `app.css` (optional). Four ship today: `activity`,
`office` (with `sprites.png`/`characters.png`), `files`, `health`.

**Manifest** (`WebuiPlugin`, `src/cli.zig:7126-7131`): `name`, `title`,
`description`, `group` — `group` must be `Work`, `Watch`, or `Set up`,
matching a real rail-nav heading. The manifest's own `name` is overwritten
by the directory name (`src/cli.zig:7275-7277`), so a plugin cannot lie about
its own identity.

**Discovery.** `GET /api/webui/plugins` scans `ui/plugins/` fresh on
every call (`handleWebuiPlugins`, `src/cli.zig:7206-7299`) — no rebuild
needed to add, remove, or edit a plugin. Off by default; enabling one is
recorded in `state/webui_plugins.json` (`{"enabled": [...]}`,
`WebuiPluginState`, `src/cli.zig:7133-7135`) — presence on disk is not
consent to run it (`src/cli.zig:7203-7205`).

**Asset serving.** `GET /webui/plugins/<name>/<file>`
(`handleWebuiPluginAsset`, `src/cli.zig:7305-7355`), same-origin, read fresh
from disk. `pluginAssetType` (`src/cli.zig:7172-7181`) allow-lists exactly
`app.js`/`app.css`/`sprites.png`/`characters.png`; anything else 404s, and a
disabled plugin's assets 404 too — toggling off actually stops the code from
reaching the browser, not just from being invoked. Names pass `isSlug`/
`validPluginName` (`src/cli.zig:7145-7155`) against path traversal
(tested `src/cli.zig:7157-7165`).

**Registration API.** `app.js` calls `window.clanker.registerView(spec)`
(`ui/app/core/plugins.js:171-221`) with `{id, title, group, mount,
refresh?}`. `registerView` inserts a real `.rail-tab` button under the
matching `.rail-group` heading, pushes the id into `VIEWS`, and wires it
through the same `wireTab`/`showView` machinery as a built-in view — a
plugin's tab is genuinely indistinguishable from a built-in one once
registered (`ui/app/app.js:4406-4429`).

**`api` surface handed to a plugin's `mount`/`refresh`**
(`ui/app/core/plugins.js`): `getJSON`, `el`, `status`, `fmt`
(`bytes`/`int`/`cost`/`time`), `showView`, `van` (tags/state/derive/add),
`preact`/`html` (vendored Preact + htm), `signals` (vendored
@preact/signals-core). All vendored and same-origin — no extra request, no
CSP exception.

**Trust model.** `script-src 'self'`, no `eval`/`new Function`
(`ui/plugins/README.md:88-90`). No declared-reach sandboxing beyond
that — a web UI plugin's JS runs in the same page and DOM as the rest of the
app, with whatever `api` exposes, constrained by browser CSP rather than a
capability grant. This is a real gap relative to the tool system's model
(see Open questions), not an oversight this PRD is fixing now.

### TUI plugins (new)

**Layout.** `tui-plugins/<name>.json` (or a directory — see Open questions),
one manifest per file, no code:

```json
{
  "command": "myreport",
  "help": "Summarize the last N runs",
  "tool": "my_report_tool",
  "args": ""
}
```

**Discovery.** On REPL start, scan `tui-plugins/` (config key
`agent.tui_plugins_dir`, default `"tui-plugins"`, mirroring
`agent.workflows_dir`/`agent.skills_dir`) and append one `CommandSpec` per
**enabled** manifest (see Design decisions: `state/tui_plugins.json`
enabled-list, default off) to the in-memory table alongside the hardcoded
`command_registry` — same shape the hardcoded entries already use
(`.action = .{ .tool = .{ .name = m.tool, .args = m.args } }`,
`repl.zig:492-507`), so `/help`, tab-complete, and dispatch all see a
plugin command exactly like a built-in one, no separate code path.

**Trust model.** No new trust surface at all: a TUI plugin can only name a
`tool` the sandboxed WASM tool registry already trusts and already declared
reach for. The manifest cannot embed code, exec anything itself, or grant
itself filesystem/network access beyond what the named tool's own descriptor
already grants. A plugin naming a tool that does not exist, or is disabled,
fails the same way typing `/nonexistent` does today.

**Collision.** A plugin manifest naming an existing built-in command (`help`,
`model`, ...) is refused at scan time and logged, not silently shadowed —
matching how a tool manifest with a name collision is refused today
(`docs/manifest.md`).

### CLI plugins (new)

**Tier 1 — manifest, tool-backed, no new trust.** `cli-plugins/<name>.json`:

```json
{
  "command": "myreport",
  "description": "Summarize the last N runs",
  "tool": "my_report_tool"
}
```

`clanker myreport --since 7d` resolves to a manifest in `cli-plugins/`
(config `agent.cli_plugins_dir`, default `"cli-plugins"`) before falling
through to Tier 2, and invokes `my_report_tool` non-interactively with the
remaining argv passed as `{"args":["--since","7d"]}` (see Design decisions).
Same trust story as the TUI tier: the plugin can only name a tool the
sandbox already trusts. Tier 1 resolves tool names against whatever
directories `agent.tools_dir` names (PRD 0022 makes that a list); this PRD
adds no tool-discovery path of its own, and any new `*_plugins_dir` key
inherits 0022's string-or-array parse rather than introducing a second
convention.

**Tier 2 — external binary, operator-trusted.** If no Tier 1 manifest
matches, and the name is not a built-in `Command`, `clanker` checks `PATH`
and `~/.clanker/plugins/` for `clanker-<name>` (see Design decisions) and
execs it with the remaining argv, inheriting stdio. This is real code
execution with no sandbox at all — the same trust an operator already
extends to anything else they put on their own `PATH`. `clanker help` lists
discovered Tier-2 plugins (scanned once at startup, cached for the process
lifetime) alongside built-ins, clearly marked as external, with origin
(`PATH` vs `~/.clanker/plugins/`) so a reader can tell "ships with clanker"
from "this machine's operator added it."

**Order.** Built-in `Command` enum first (never shadowable by a plugin, so a
plugin cannot silently redefine `clanker run`), then Tier 1 (sandboxed,
declarative), then Tier 2 (external, operator-trusted) — narrowest trust
wins ties.

### Cross-surface consistency

All three surfaces share the same shape of answer to "how does a plugin get
found and does it get to do anything on its own": a directory scanned fresh
(not compiled in), a small declarative manifest, and — critically — neither
new mechanism (TUI, CLI Tier 1) introduces a capability the sandboxed tool
system did not already grant. Only web UI plugins (already shipped) and CLI
Tier 2 (deliberately, for parity with the tools this pattern is borrowed
from) carry unsandboxed trust, and both are opt-in and locally sourced, never
fetched.

**Dependencies.** (TUI/CLI half)

- Web UI plugin enabled-list pattern (`state/webui_plugins.json`,
  `handleWebuiPlugins`) as the state-file precedent.
- TUI `command_registry` / `CommandSpec` (`src/tui/repl.zig`) for
  slash-command registration shape.
- CLI `Command` enum + dispatch (`src/cli.zig`) for built-in-first ordering.
- Tool registry + sandbox (`src/toolhost/registry.zig`, PRD 0010 / 0022) for
  Tier 1 / TUI tool-backed plugins.
- [PRD 0022](0022-out-of-tree-tools.md) for `agent.tools_dir` as a list (Tier 1
  name resolution) and string-or-array parse inherited by `*_plugins_dir`.

**Implementation.** (TUI/CLI half, phased)

1. **TUI plugins.** Config `agent.tui_plugins_dir`; scan + validate
   manifests; `state/tui_plugins.json` enabled-list; append enabled entries
   to `command_registry` at REPL start; refuse built-in collisions; wire
   enable/disable (REPL command or config-adjacent CLI later).
2. **CLI Tier 1.** Config `agent.cli_plugins_dir`; resolve unknown
   subcommands against enabled manifests before Tier 2; invoke named tool
   with `{"args":[...]}`; `state/cli_plugins.json` enabled-list; never
   shadow `Command`.
3. **CLI Tier 2.** Discover `clanker-*` on `PATH` and
   `~/.clanker/plugins/`; exec with remaining argv; list in `clanker help`
   as external with origin; Tier 1 still wins on name ties.

Web UI half is already shipped (see Status); no implementation work there
except failure-mode polish called out above (corrupt state warn, mount
throw → tab error) if not already true in code.

## Known issues

- **State-file shape disagrees between the tool system and surface plugins.**
  `state/webui_plugins.json` is an enabled-list (`{"enabled":[...]}`); the
  tool system's `state/plugins.json` is a disabled-list
  (`{"disabled":[...], "enabled":[...]}`, read at
  `src/toolhost/registry.zig:156,288`). For TUI/CLI the choice is now locked in
  Design decisions: enabled-list, default off, matching web UI. The tool
  system's on-by-default shape stays as-is for WASM tools; do not "unify"
  them without a separate PRD.
- **Corrupt `state/webui_plugins.json` currently stays silent.**
  `handleWebuiPlugins` already falls back to an empty enabled-list on parse
  failure (`catch WebuiPluginState{}`), matching Failure modes, but it does
  not warn. Failure modes require a warn once on load; fix belongs beside
  that catch in `src/cli.zig`.
- **Plugin `mount` throw is uncaught.** `registerView`'s view loader calls
  `spec.mount` with no try/catch (`ui/app/core/plugins.js`), so a
  throwing mount can break the tab switch rather than show the tab error
  Failure modes describe. Fix belongs in the view loader: catch, render an
  error into the panel, keep the rest of the page alive.

## Failure modes

| Condition | Behaviour |
|---|---|
| Web UI plugin directory missing `plugin.json` | Skipped, not listed, no error surfaced to the browser |
| Web UI plugin asset request for a non-allow-listed filename | 404, same as if the plugin did not exist |
| Web UI plugin disabled | Its assets 404 even if requested directly by URL |
| TUI plugin manifest names a tool that does not exist or is disabled | Command registers, dispatch fails with the same "no such tool" error a direct tool call would give |
| TUI plugin manifest's `command` collides with a built-in | Refused at scan time, logged, built-in wins |
| CLI Tier 1 manifest names a nonexistent tool | `clanker <name>` fails the same way, told which tool was missing |
| CLI Tier 2 binary not executable / not found after passing the `PATH` scan (removed mid-session) | Reported as a normal exec failure, not a crash |
| CLI Tier 1 and Tier 2 both could resolve the same name | Tier 1 wins (sandboxed beats unsandboxed) |
| Built-in command name requested as a plugin (any tier, any surface) | Refused; built-ins are never shadowable |
| Corrupt / unparseable `state/webui_plugins.json` | Treated as empty enabled-list; warn once on load (server log / System status). Next successful toggle rewrites a clean file |
| Web UI plugin `mount` throws | Tab still appears; the view panel shows a tab error naming the plugin and the exception message, instead of a blank panel or a broken page |
| Corrupt `state/tui_plugins.json` / `state/cli_plugins.json` (once built) | Same as web UI: empty enabled-list + warn; no plugin commands dispatched until re-enabled |

## Acceptance criteria

- [x] A web UI plugin directory with a valid `plugin.json` and `app.js`
      appears as a real rail-nav tab once enabled, indistinguishable from a
      built-in view (already true today, `activity`/`office`/`files`/`health`).
- [x] A disabled web UI plugin's assets are unreachable by direct URL, not
      just absent from the nav (`src/cli.zig:7328-7331`).
- [ ] A TUI plugin manifest naming an existing tool becomes a working slash
      command with no code change to `repl.zig`.
- [ ] A TUI plugin cannot name a command that collides with a built-in.
- [ ] `clanker <name>` resolves a Tier 1 manifest before falling through to
      a Tier 2 `PATH` binary, and never shadows a built-in `Command`.
- [ ] `clanker help` lists discovered Tier 2 external plugins, marked as
      external.

## Open questions / future work


- **Declared-capability sandboxing for web UI plugins (future breaking
  change).** Today's CSP-only trust model means an enabled plugin's JS can
  call any same-origin `fetch()` the browser session is authorized for, not
  just what its own `api` surface hands it deliberately. A `fs_prefixes`/
  `network_allow`-style manifest field the page enforces before handing a
  plugin its `api` object would be a real design change to something already
  shipped and in use: labeled here as a future breaking change, not a v1
  task for this PRD. Still open as product scope; do not silently tighten.
- **TUI plugin directory vs. single-file manifests.** Sketched above as
  `tui-plugins/<name>.json` for simplicity (no code alongside the manifest,
  unlike web UI's directory-per-plugin). If a future TUI plugin needs more
  than a name/help/tool triple (e.g. its own keybinding, its own picker UI),
  the single-file shape stops being enough and the design should move to
  directories — deferred until a real use case asks for it.
- **A real plugin-driven TUI rendering surface**, for something shaped like
  `/model`'s fuzzy picker rather than dispatch-and-print. Explicitly out of
  scope above; would need the TUI to expose a drawing/input API to a plugin
  the way the web UI's `api.van`/`api.preact` does, which the TUI has no
  analog of today.
