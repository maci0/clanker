# PRD — Agent presets (named tool + prompt bundles)

## Status

Draft. No source files yet. Proposed: a `preset.toml` file per preset under
a configured set of directories (mirroring `agent.tools_dir`'s list-of-roots
precedent from PRD 0022), a `clanker preset list|show|new` subcommand
(mirroring `clanker plugins list|validate|new`'s shape), a `--preset <name>`
flag on `clanker run`/`clanker repl`, and a `/preset <name>` REPL command.
Inspired by
[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)'s
`packages/preset/agent-presets/` and `packages/preset/persona/`, scoped
down substantially — DSH's version is a Cordis-specific standing-mount
mechanism with generations, file-change watchers, and re-composition
machinery that has no equivalent need in clanker's static, WASM-manifest
tool model; this PRD keeps only the product shape (a named bundle of tools +
persona text, selectable per session), not that implementation.

## Problem

Every clanker session gets the same tool set — whatever `agent.tools_dir`
resolves to — and the same system prompt. There is no way to hand one
session a restricted, named bundle ("research-only, no writes", "the ops
runbook persona with only exec and github tools") without editing
`config.toml`'s global tool/prompt configuration for every session that
follows. `docs/ROADMAP.md`'s Feynman audit already names a narrower version
of this gap and proposes a cheap fix: "role prompt files under
`docs/prompts/`... referenced by name from the `subagent` tool's free-text
task field." That is worth keeping as the free option it is, but it only
ever changes what the model is *told* — never what it can *call*. A
"research-only" persona described in prose is not read-only; it is a
polite request a model can still ignore by calling a write tool anyway.
DSH's `agent-presets`/`persona` packages show the fuller shape worth
adopting: a preset that names both a persona and an actual tool
allow/deny list, so "research-only" is enforced, not just suggested.

## Goals

1. A preset is one `preset.toml`: `description` (shown in `clanker preset
   list`), `system_prompt_append` (text appended after clanker's own system
   prompt — not a replacement, see Non-goals), `tools_allow`/`tools_deny`
   (tool-name patterns, see Design for why these are named differently from
   the manifest's unrelated `tool_allow` field), and optional
   `default_provider`/`default_model` (overridable as usual by
   `--provider`/`--model`).
2. `clanker preset list` shows every preset found under the configured
   roots (a shipped set plus a user directory, mirroring PRD 0022's
   multi-root precedent); `clanker preset new <name>` scaffolds a
   `preset.toml`, refusing to overwrite an existing one (mirrors `plugins
   new`'s discipline).
3. `--preset <name>` on `clanker run`/`clanker repl` filters the
   already-loaded `Registry`'s tool-definition list before the first
   request — no separate tool-loading pass, no WASM recompilation, just a
   filter over what startup already loaded.
4. `/preset <name>` in the REPL switches presets for the next task only,
   and only while the session has produced nothing yet (no tool call, no
   assistant message) — swapping tools mid-conversation would leave logged
   tool calls a narrower preset cannot explain.
5. Ship two example presets: `research` (fs read + `web_search`/`fetch_web`
   only; every write-capable tool denied via the same predicate plan
   mode/confirm-writes already use) and `full` (no filtering — the default,
   a no-op preset so `--preset` is genuinely optional).

## Non-goals

- **A full system-prompt replacement.** v1 only appends
  `system_prompt_append`; clanker's system prompt already carries safety and
  tool-usage framing a careless preset could otherwise drop entirely by
  replacing it wholesale. DSH's `persona.complete` mode (replace everything)
  is deliberately not adopted.
- **Live filesystem watching or hot-reload of a preset while sessions are
  using it.** Read once per `--preset`/`/preset` invocation. DSH's
  watcher-based hot-reload exists to serve its own standing-mount
  architecture; clanker has no equivalent standing state to keep in sync.
- **Per-preset sampling knobs (temperature, reasoning effort, etc.).** That
  is PRD 0024's axis. Presets and sampling profiles are orthogonal and
  compose — a preset names *what a session can do*, a sampling profile
  names *how the model should think* — not merged into one mechanism.
- **A settings-page or web UI authoring flow.** CLI and hand-edited TOML
  only in v1, matching most of clanker's other config surfaces.
- **A preset naming a different `agent.tools_dir` entirely (a separate
  WASM-loading root, not just a filter).** Real design work, deferred — see
  Open questions.

## Design

**A filter, not a second registry.** `Registry.load` already loads every
WASM tool once at startup (`src/toolhost/registry.zig`); a preset changes
nothing about that. `--preset research` computes an allow/deny mask applied
where `Agent` builds the tool-definition list offered to the model — the
same place `catalog_mode`'s `revealed` set already filters which schemas go
out (`loop.zig`'s `rebuildToolDefs`). A tool a preset denies is simply never
offered to the model. Defense in depth: a denied tool named by a stale or
misbehaving client call anyway is refused the same way `plan_mode` already
refuses a write-capable call outright — reusing that exact gate rather than
adding a third enforcement point that could drift from it.

**`tools_allow`/`tools_deny`, deliberately not `tool_allow`.** The manifest
schema already has a field named `tool_allow` (`src/toolhost/registry.zig`,
`src/sandbox/host.zig`) — it restricts which *chat/tool-call ops* a WASM
guest may itself invoke as a caller, an unrelated, sandbox-internal
mechanism. Naming this PRD's session-level tool filter identically would
read as the same feature when it is not. `tools_allow`/`tools_deny` (plural)
is the deliberately different name.

**Deny wins on conflict; empty allow means "everything except deny."** An
empty `tools_allow` means every registered tool except what `tools_deny`
names, so `research`'s preset only has to name what it forbids rather than
enumerate the roughly ninety tools it should keep. A name in both lists is
denied — the same "allowlist reads as an allowlist, not a best-effort
merge" convention `exec_allow`/`fs_prefixes` already use in a manifest.

**`system_prompt_append`.** Appended after clanker's own assembled system
prompt (`src/agent/system_prompt.zig`'s `build`, which already layers
global/project/personal instruction files) as one more layer — exact
threading through `build`'s existing parameters is Implementation work, not
resolved here, since this PRD has not read `build`'s full signature closely
enough to commit to one without risking a stale claim.

**Dependencies.** None hard. Soft: shares the `needsConfirm` predicate
(`src/toolhost/registry.zig`) with plan mode and confirm-writes, both
already shipped. Benefits from, but does not require, PRD 0032's MCP client
bridge — a preset naming `mcp__github__*` in `tools_allow` is a natural
follow-on once MCP-sourced tools exist in the registry, not a v1
requirement.

**Implementation.**

1. `preset.toml` schema + loader (`src/preset/preset.zig`), unit-tested
   including the two shipped examples (`research`, `full`).
2. `clanker preset list|show|new`.
3. `--preset` flag threading into `Agent` construction: tool-definition
   filter at `rebuildToolDefs`, plus the defense-in-depth dispatch-time
   refusal alongside `plan_mode`'s existing check.
4. `system_prompt_append` wiring into `system_prompt.zig`'s assembly.
5. `/preset` REPL command (blank-session-only guard), added to
   `command_registry` in `src/tui/repl.zig` following its existing
   `CommandSpec` shape.
6. Docs + the two shipped example presets.

## Failure modes

| Condition | Behaviour |
|---|---|
| `--preset` names an unknown preset | Usage error listing available names |
| `preset.toml` fails to parse | Load error naming the file and the bad key; run does not silently fall back to unrestricted tools |
| `/preset` called after the session has produced a tool call or assistant message | Refused; current preset unchanged |
| `tools_allow`/`tools_deny` names a tool absent from the loaded registry | Not an error — a pattern matching nothing stays valid, so a preset authored against a superset of installed tools is not broken by a leaner install |
| A denied tool is called anyway (stale client, misbehaving model) | Refused at dispatch by the same gate `plan_mode` uses, independent of whether it was offered in the schema |
| `clanker preset new <name>` on an existing name | Refused; nothing overwritten |

## Acceptance criteria

- [ ] `preset.toml` carries `description`, `system_prompt_append`,
      `tools_allow`/`tools_deny`, and optional
      `default_provider`/`default_model` (Goal 1).
- [ ] `--preset research` offers the model only read/search tools; a
      write-capable tool is neither offered nor callable.
- [ ] `--preset full` (or no `--preset`) is a no-op: identical tool set to
      today's default.
- [ ] `clanker preset list` enumerates every preset under the configured
      roots, including the two shipped examples.
- [ ] `clanker preset new <name>` scaffolds a valid `preset.toml` and
      refuses to overwrite an existing one.
- [ ] `/preset <name>` switches presets before any tool call or assistant
      message in the session, and is refused afterward.
- [ ] A denied tool named directly in a tool call (bypassing the offered
      schema) is still refused at dispatch.
- [ ] `system_prompt_append` text appears in the assembled system prompt for
      a session using that preset, after clanker's own sections.
- [ ] An empty `tools_allow` with a non-empty `tools_deny` allows everything
      except the denied patterns.

## Open questions / future work

- **A preset naming a distinct `tools_dir`, not just a filter.** Would mean
  per-preset WASM loading — a materially bigger change than a filter over
  an already-loaded registry, deferred until a filter proves insufficient.
- **Per-session MCP-server scoping**, once PRD 0032 exists.
- **`clanker arena`/`compare` combatants selectable by preset** instead of
  by a free-text system-prompt override — a natural extension, noted here,
  not required for v1.
