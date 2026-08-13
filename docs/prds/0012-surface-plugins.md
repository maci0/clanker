# PRD — Surface Plugins (webui, TUI, CLI)

## Status

Partially shipped, never documented until now. **Web UI plugins already exist
and are live** — `tools/webui-plugins/<name>/` (`plugin.json` + `app.js` +
optional `app.css`), discovered by `handleWebuiPlugins`
(`src/cli.zig:7206-7299`), served same-origin from `/webui/plugins/<name>/*`
(`handleWebuiPluginAsset`, `src/cli.zig:7305-7355`), registered client-side
via `window.clanker.registerView()` (`tools/zig/webui/core/plugins.js:171-221`),
toggled in System → Web UI plugins, state in `state/webui_plugins.json`. Four
real plugins ship today: `activity`, `office`, `files`, `health`. No PRD or ADR
covered it before this one; its prior documentation was
`tools/webui-plugins/README.md` plus the review log
`docs/WEBUI_PLUGINS_REVIEW.md`, which is why its design decisions (CSP-only
trust, no declared-capability sandboxing) were never written down where a
future editor would find them.
This PRD is that missing writeup, plus the design for the two surfaces that
have nothing yet: **TUI plugins and CLI plugins do not exist** — confirmed by
grepping for any directory-scan, config-driven, or PATH-based extension point
feeding `command_registry` (`src/tui/repl_vaxis.zig:492-507`, a hardcoded
array) or the `Command` enum (`src/cli.zig:68-105`, a closed compile-time
set). Both are designed below and remain Draft until built.

## Problem

An operator or a clanker instance improving itself may want to add a view to
the web UI, a slash command to the TUI, or a subcommand to the CLI without
editing and recompiling clanker's own source. The web UI already solved this
for itself, organically, with no PRD to constrain or explain the choice — so
its capability model (same-origin JS trusted the same as the page's own code,
no `fs_prefixes`/`network_allow`-style grant) was never weighed against the
alternative the tool-calling system already uses (`docs/manifest.md`,
`src/tools/registry.zig`), and nothing stops the TUI and CLI from growing two
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
   (`CommandSpec.action = .{ .tool = ... }`, `repl_vaxis.zig:497-500`).
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

### Web UI plugins (documenting what is shipped)

**Layout.** `tools/webui-plugins/<name>/`: `plugin.json` (required),
`app.js` (required), `app.css` (optional). Four ship today: `activity`,
`office` (with `sprites.png`/`characters.png`), `files`, `health`.

**Manifest** (`WebuiPlugin`, `src/cli.zig:7126-7131`): `name`, `title`,
`description`, `group` — `group` must be `Work`, `Watch`, or `Set up`,
matching a real rail-nav heading. The manifest's own `name` is overwritten
by the directory name (`src/cli.zig:7275-7277`), so a plugin cannot lie about
its own identity.

**Discovery.** `GET /api/webui/plugins` scans `tools/webui-plugins/` fresh on
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
(`tools/zig/webui/core/plugins.js:171-221`) with `{id, title, group, mount,
refresh?}`. `registerView` inserts a real `.rail-tab` button under the
matching `.rail-group` heading, pushes the id into `VIEWS`, and wires it
through the same `wireTab`/`showView` machinery as a built-in view — a
plugin's tab is genuinely indistinguishable from a built-in one once
registered (`tools/zig/webui/app.js:4406-4429`).

**`api` surface handed to a plugin's `mount`/`refresh`**
(`tools/zig/webui/core/plugins.js`): `getJSON`, `el`, `status`, `fmt`
(`bytes`/`int`/`cost`/`time`), `showView`, `van` (tags/state/derive/add),
`preact`/`html` (vendored Preact + htm), `signals` (vendored
@preact/signals-core). All vendored and same-origin — no extra request, no
CSP exception.

**Trust model.** `script-src 'self'`, no `eval`/`new Function`
(`tools/webui-plugins/README.md:88-90`). No declared-reach sandboxing beyond
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
manifest to the in-memory table alongside the hardcoded
`command_registry` — same shape the hardcoded entries already use
(`.action = .{ .tool = .{ .name = m.tool, .args = m.args } }`,
`repl_vaxis.zig:492-507`), so `/help`, tab-complete, and dispatch all see a
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
remaining argv passed through as the tool's JSON input's `args` field (exact
argv→JSON mapping is an implementation detail for whoever builds this, not a
PRD-level decision). Same trust story as the TUI tier: the plugin can only
name a tool the sandbox already trusts. Tier 1 resolves tool names against
whatever directories `agent.tools_dir` names (PRD 0022 makes that a list);
this PRD adds no tool-discovery path of its own, and any new `*_plugins_dir`
key inherits 0022's string-or-array parse rather than introducing a second
convention.

**Tier 2 — external binary, `PATH`-based, operator-trusted.** If no Tier 1
manifest matches, and the name is not a built-in `Command`, `clanker` checks
`PATH` for `clanker-<name>` (git/cargo/kubectl's own convention) and execs
it with the remaining argv, inheriting stdio. This is real code execution
with no sandbox at all — the same trust an operator already extends to
anything else they put on their own `PATH`. `clanker help` lists discovered
Tier-2 plugins (scanning `PATH` for `clanker-*` once at startup, cached for
the process lifetime) alongside built-ins, clearly marked as external so a
reader can tell "ships with clanker" from "this machine's operator added
it."

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

## Known issues

- **State-file shape disagrees between the two mechanisms that exist
  today.** `state/webui_plugins.json` is an enabled-list
  (`{"enabled":[...]}`); the tool system's `state/plugins.json` is a
  disabled-list (`{"disabled":[...], "enabled":[...]}`, read at
  `src/tools/registry.zig:156,288`). Both are defensible defaults (off by
  default vs. on by default) for their own surface, but a reader has no way
  to guess which shape a new `state/tui_plugins.json` or
  `state/cli_plugins.json` should follow without this note. Recommend: new
  surfaces default off (matching web UI's stance, and matching Tier 1/2 CLI
  plugins being something an operator deliberately dropped a file for)
  unless a concrete reason argues otherwise when built.

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

## Acceptance criteria

- [x] A web UI plugin directory with a valid `plugin.json` and `app.js`
      appears as a real rail-nav tab once enabled, indistinguishable from a
      built-in view (already true today, `activity`/`office`/`files`/`health`).
- [x] A disabled web UI plugin's assets are unreachable by direct URL, not
      just absent from the nav (`src/cli.zig:7328-7331`).
- [ ] A TUI plugin manifest naming an existing tool becomes a working slash
      command with no code change to `repl_vaxis.zig`.
- [ ] A TUI plugin cannot name a command that collides with a built-in.
- [ ] `clanker <name>` resolves a Tier 1 manifest before falling through to
      a Tier 2 `PATH` binary, and never shadows a built-in `Command`.
- [ ] `clanker help` lists discovered Tier 2 external plugins, marked as
      external.

## Open questions / future work

- **Declared-capability sandboxing for web UI plugins.** Today's CSP-only
  trust model means an enabled plugin's JS can call any same-origin
  `fetch()` the browser session is authorized for, not just what its own
  `api` surface hands it deliberately. Worth a `fs_prefixes`/
  `network_allow`-style manifest field the page enforces before handing a
  plugin its `api` object? This is a real design change to something
  already shipped and in use, not a green-field decision — costs a breaking
  change to the three existing plugins if the answer is yes.
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
- **Argv-to-tool-input mapping for CLI Tier 1.** Sketched as "remaining argv
  passed as `args`" above but not fully specified — does a manifest declare
  named flags that map to specific JSON fields, or does the tool itself
  parse a raw string the way `chain`/`gh`/`git` tools already take
  `{"args":[...]}`? Whoever implements this should decide by matching
  whichever existing tool convention is closest, not inventing a third.
- **Should Tier 2 external CLI plugins get a namespace beyond bare
  `clanker-<name>` on `PATH`** — e.g. also checking
  `~/.clanker/plugins/<name>` — to avoid every plugin author needing global
  `PATH` placement? Git supports both; worth deciding before Tier 2 ships
  rather than after operators start depending on `PATH`-only discovery.
