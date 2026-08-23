# PRD — Surface Plugins (webui, TUI, CLI)

## Status

**Web UI plugins: Shipped.** `ui/plugins/<name>/` (`plugin.json` +
`app.js` + optional `app.css`), created from chat by the `webui_addon`
tool, discovered by the `webui_addon` guest (`list` scans `ui/plugins/`
fresh; `handleWebuiPlugins`, `src/cli.zig:9994-10042`, only relays to it),
served same-origin from `/webui/plugins/<name>/*`
(`handleWebuiPluginAsset`, `src/cli.zig:10048-10103`), registered client-side
via `window.clanker.registerView()` (`ui/app/core/plugins.js:171-221`),
toggled in System → Web UI plugins, state in `state/webui_plugins.json`.
Nine plugin directories ship on disk today (`activity`, `files`, `health`,
`mesh`, `music`, `office`, `schedule`, `search`, `compare`); a fresh checkout
seeds `files`, `music`, `schedule`, `search`, `compare`, `mesh` on. No PRD or ADR
covered the web UI half before this one; its prior documentation was
`ui/plugins/README.md` plus the review log
`docs/reviews/webui-plugins.md`, which is why its design decisions (CSP-only
trust, no declared-capability sandboxing) were never written down where a
future editor would find them.

**TUI plugins / CLI plugins: Shipped — 2026-08-20.** TUI: a directory scan
(`agent.tui_plugins_dir`, default `tui-plugins/`) feeds the command set at
REPL start (`src/tui/slash_plugins.zig` + `repl.zig`'s
`reloadTuiPlugins`/`runTuiPlugins`), each enabled manifest appending one
`CommandSpec` that dispatches to a sandboxed tool; `/tui-plugins` lists and
toggles. CLI: `clanker <name>` resolves an enabled Tier 1 manifest
(`agent.cli_plugins_dir`, default `cli-plugins/`, tool invoked with the
remaining argv as `{"args":[...]}`), then a Tier 2 `clanker-<name>` binary
on PATH or `~/.clanker/plugins/`, never shadowing a built-in `Command`
(`src/cli/cli_plugins.zig` + `cmdPlugin`); `clanker help` lists both tiers
marked external. Enable via `state/tui_plugins.json` / `state/cli_plugins.json`
enabled-lists, default off. Both follow the Design below; acceptance criteria
are checked.

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
`app.js` (required), `app.css` (optional). Nine directories ship on disk:
`activity`, `files`, `health`, `mesh`, `music`, `office`, `schedule`,
`search`, `compare`. A fresh checkout seeds `files`, `music`, `schedule`,
`search`, `compare`, `mesh` on (`webui_addon_logic.default_enabled`); the
`schedule`/`search`/`compare`/`mesh` set also inherits on from an older
state file that listed only `files`+`music` (`inherit_on`), so migrating the
built-in views does not silently turn them off.

**Manifest** (`plugin.json`, parsed by the `webui_addon` guest,
`tools/zig/webui_addon.zig:125-131`): `name`, `title`, `description`, `group`
(default `Watch`), `capabilities` (default empty). `group` must be `Work`,
`Watch`, or `Set up`, matching a real rail-nav heading
(`webui_addon_logic.validGroup`). Identity is the **directory name**, not the
manifest's `name` field: the guest's `list` walks `ui/plugins/` and keys
everything off the directory name, so a plugin cannot lie about its own
identity. `capabilities` is checked against a closed list
(`webui_addon_logic.capabilities`) — an unknown name is a typo, not a grant.

**Discovery and toggle — one owner.** The `webui_addon` guest owns the whole
registry: `list` scans `ui/plugins/` fresh on every call, `create`/`put`
write `plugin.json` + `app.js` (+ optional `app.css`), `enable`/`disable`
toggle the name in `state/webui_plugins.json` (`{"enabled": [...],
"disabled": [...]}`), and a missing state file seeds `default_enabled`. The
host does **not** keep a second copy: `handleWebuiPlugins`
(`src/cli.zig:9994-10042`) only relays `GET`/`POST /api/webui/plugins` to the
guest, and `listedEnabled` (`src/cli.zig:9950-9971`) reads the guest's `list`
answer to decide a name's on/off. The only native struct left is
`WebuiPluginPost` (`{name, enabled}`, `src/cli.zig:9897-9900`) — the POST
body shape; the old `WebuiPlugin` (manifest) and `WebuiPluginState`
(enabled-list) structs are gone. A plugin is off until turned on — presence
on disk is not consent to run it.

**Asset serving.** `GET /webui/plugins/<name>/<file>`
(`handleWebuiPluginAsset`, `src/cli.zig:10048-10103`), same-origin, read
fresh from disk every request. `pluginAssetType` (`src/cli.zig:9921-9930`)
allow-lists exactly `app.js`/`app.css`/`sprites.png`/`characters.png`;
anything else 404s, and a disabled plugin's assets 404 too — toggling off
actually stops the code from reaching the browser, not just from being
invoked. Names pass `validPluginName` (`src/cli.zig:9902-9904`, which
delegates to `session.validSessionId`) against path traversal (tested
`src/cli.zig:9906-9914`).

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

- **(Fixed) A Tier 2 `clanker-<name>` binary used to run with no entry in
  the enabled-list.** Design decision "State files for TUI/CLI" says
  "Presence of a manifest or PATH binary is not consent to run it; the
  operator enables each name explicitly", and the failure-mode table says
  Tier 1 wins ties because sandboxed beats unsandboxed. `cmdPlugin`
  (`src/cli.zig`) dispatched Tier 2 through `cli_plugins.findTier2`, which
  is bare discovery with no `enabled` parameter, so any executable
  `clanker-<word>` on `PATH` or under `~/.clanker/plugins/` ran unsandboxed
  from a plain `clanker <word>`; and because `resolveTier1` returns null for
  a matching-but-*disabled* manifest, turning a sandboxed Tier 1 plugin off
  promoted the unsandboxed binary of the same name into its place. Dispatch
  now goes through `cli_plugins.resolveTier2`, which checks the enabled-list
  before the PATH walk. `findTier2` stays ungated so `clanker help` can
  still list an installed-but-off plugin.
- **(Fixed) `clanker help` listed Tier 2 from `PATH` only, unmarked.**
  Design says both sources are listed "with the directory of origin so an
  operator can tell PATH from home-dir installs", and `findTier2` runs
  binaries from `~/.clanker/plugins/` too. `printTier2Dir` (`src/cli.zig`)
  now walks both, names the source, and carries the same `[on]`/`[off]` mark
  the Tier 1 rows do.
- **State-file shape disagrees between the tool system and surface plugins.**
  `state/webui_plugins.json` is an enabled-list (`{"enabled":[...]}`); the
  tool system's `state/plugins.json` is a disabled-list
  (`{"disabled":[...], "enabled":[...]}`, read at
  `src/toolhost/registry.zig:156,288`). For TUI/CLI the choice is now locked in
  Design decisions: enabled-list, default off, matching web UI. The tool
  system's on-by-default shape stays as-is for WASM tools; do not "unify"
  them without a separate PRD. (Evaluated 2026-08-23: both shipped loaders
  — `src/tui/slash_plugins.zig` and `src/cli/cli_plugins.zig` — implement
  the locked enabled-list, default off. The divergence from the tool
  system's disabled-list is design, not a defect.)
- **(Fixed) Corrupt `state/tui_plugins.json` / `state/cli_plugins.json`
  used to stay silent.** Both `loadEnabled`s swallowed a parse failure and
  a non-NotFound read error into an empty enabled-list with no trace,
  while the Failure modes table below promises "empty enabled-list +
  warn" — the same defect fixed for `state/webui_plugins.json` in the
  next bullet. They now warn through the host log naming the file and
  what failed, keeping the empty-list fallback; a missing file stays
  silent because off-by-default is the normal state, and the next
  successful toggle rewrites a clean file.
- **(Fixed) Corrupt `state/webui_plugins.json` used to stay silent.** The
  read moved from `handleWebuiPlugins` into the `webui_addon` guest, and its
  `loadState` swallowed both a parse failure and a non-NotFound read error
  into an empty state with no trace. It now warns through `ck_log` (a `[tool]`
  warn line in the server log) naming the file, what failed, and the error,
  while keeping the empty-enabled-list fallback the Failure modes require.
- **(Fixed) Plugin `mount` throw used to be uncaught.** Both view loaders in
  `ui/app/core/plugins.js` called `spec.mount` (and `spec.refresh`) bare, so
  a throwing mount broke the tab switch rather than showing the tab error
  Failure modes describe. `runPluginHook` now contains the throw to the
  plugin's own panel — named plugin, exception message, Retry that re-runs
  the loader — and the rest of the page stays alive. Pinned by
  `ui/app/webui-load.test.mjs`.
- **(Fixed) Mesh's "idle while hidden" guard read an attribute nobody sets.**
  `mount` is handed the inner `<section>`; the host toggles `hidden` on the
  enclosing `.view` panel. `container.hidden` in `ui/plugins/mesh/app.js` was
  therefore `false` for the life of the tab, so the 4s `/api/mesh/*` poll, the
  1s pending redraw and the live-bus handler were all guarded by nothing and
  opening Mesh once left it polling a view nobody could see, taking a connection
  from every other poll each time. It reads `container.closest(".view")` now, the
  way `health` and `office` do. The comment above the timers claimed this had
  already been fixed; the test that replaces it reads both halves of the
  contract, so the claim cannot go stale again.
- **(Fixed) Music's playlist Remove button drew nothing.** `btn("×", …)` asked
  `api.icon` for a character rather than a name, and `icon()` returns an empty
  `<span>` for anything not in `ICON_PATHS`, so every Remove was a blank button.
  The name is `close` now, and a cross-file test parses the host's icon grid and
  checks every glyph name the plugin asks for. Note for future harnesses: a stub
  that omits `api.icon` takes `setGlyph`'s `else b.textContent = name` branch and
  renders a convincing `×`, so stubbing it would hide this class of defect rather
  than catch it.
- **(Fixed) Office's `mount` threw where site data is blocked.** The
  pre-migration alarm key was read with a bare `localStorage.getItem` on the
  first line of `mount`. `api.storage` swallows a blocked store; a bare read does
  not, and it is the property access that raises `SecurityError`, so an optional
  preference read replaced the whole view with the plugin error panel. It is
  inside a `try` now, matching how music does the same migration read.
- **A plugin's `refresh` hook is unreachable.** The loader calls `spec.mount`
  once and `spec.refresh` on every later call, but `showView` only invokes a
  view loader under `if (!viewLoaded[name])` and never resets that flag, so
  `refresh` runs only from `runPluginHook`'s Retry path. This PRD documents
  `refresh?` as part of the registration API without saying so, `mesh`'s own
  comment claims it covers re-entry, and `health` and `office` each bolt on a
  `MutationObserver` on the panel's `hidden` attribute instead. Filed as
  [plugin refresh hook is unreachable](../reports/bugs/2026-08-23-plugin-refresh-hook-is-unreachable.md).
- **A plugin tab's arrow-key neighbours are its registration neighbours.** The
  loader inserts the tab inside its group heading and then indexes it at the end
  of `VIEWS`; `wireTab` moves focus purely by that index. For the eleven
  built-ins `VIEWS` is exactly the rail's DOM order, so a plugin is the first
  thing to break the invariant, against this PRD's "indistinguishable from a
  built-in view". Filed as
  [plugin tab arrow keys follow registration order](../reports/bugs/2026-08-23-plugin-tab-arrow-keys-follow-registration-order.md).
- **`api.status` is one shared live region.** Every plugin and the loader's own
  five messages write `#webui-plugins-status`; Health writes it about once a
  second from its 1 Hz sample, so an enable confirmation is overwritten inside a
  second and a screen reader hears the same metrics line forever. Same shape as
  the `#models-status` defect already fixed in `docs/reviews/webui.md`, with N
  producers instead of three. Filed as
  [plugin status line is one shared live region](../reports/bugs/2026-08-23-plugin-status-line-is-one-shared-live-region.md).
- **`actionList` drops a slightly-wrong manifest with no diagnostic.** It goes
  out of its way to list an unparseable `plugin.json` with a diagnostic
  description, then silently `continue`s past `capabilitiesRejected`; and
  `validGroup` is enforced in `create`/`put` but never in `list`, so a manifest
  with a group that is not `Work`/`Watch`/`Set up` is listed verbatim and its tab
  lands outside the rail's nav list. Filed as
  [webui addon list drops a bad manifest with no diagnostic](../reports/bugs/2026-08-23-webui-addon-list-drops-a-bad-manifest-with-no-diagnostic.md).

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
      built-in view (already true today). (G1)
- [x] A disabled web UI plugin's assets are unreachable by direct URL, not
      just absent from the nav (`src/cli.zig:10076-10078`). (G1)
- [x] Web UI plugins are discovered by scanning `ui/plugins/` at request
      time (the `webui_addon` guest's `list`), not compiled in. (G4)
- [x] A TUI plugin manifest naming an existing tool becomes a working slash
      command with no code change to `repl.zig` beyond the loader itself
      (a plugin author only drops a manifest in `tui-plugins/`). (G2, G4)
- [x] A TUI plugin cannot name a command that collides with a built-in;
      the scan refuses and logs it (`slash_plugins.zig`). (G2)
- [x] `clanker <name>` resolves a Tier 1 manifest before falling through to
      a Tier 2 `PATH` binary, and never shadows a built-in `Command`
      (parse sets `.plugin` only for a short word no built-in matches;
      `cmdPlugin` tries Tier 1 then Tier 2). (G3)
- [x] `clanker help` lists discovered Tier 2 external plugins (and Tier 1
      manifests), marked as external with their origin. (G3, G4)

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
