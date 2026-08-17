# PRDs

Product requirement docs for clanker. Schema and quality bar:
[`TEMPLATE.md`](TEMPLATE.md). Roadmap narrative and Done/Planned index:
[`../ROADMAP.md`](../ROADMAP.md). Architecture decisions that constrain
PRDs: [`../adrs/`](../adrs/).

## Quick start

See every PRD, with the unfinished work first:

```bash
clanker prd
```

Check what a Draft has to pin down before it counts as planned:

```bash
clanker prd checklist
```

Find out whether a feature is already specified, and what decision constrains
it:

```bash
clanker prd search "kanban board"
```

Open a numbered scaffold:

```bash
clanker prd create "Scheduled runs" "Nothing fires unless something outside clanker invokes it" "1. Fire due entries on a cron spec"
```

Read one in full:

```bash
clanker prd open docs/prds/0009-schedule.md
```

The same actions are the `prd` tool's, which is what the CLI calls.
Everything below is detail.

## How to read Status

| Status | Meaning |
|---|---|
| **Shipped** | Code is the source of truth; PRD tracks behavior + known drift |
| **In progress** | Partially built; Status names what is live vs open |
| **Draft** | Not built; Design must settle blockers + Implementation phases |

A Draft is not "planned properly" until: Dependencies are named, blocking
open questions are decided in Design (not parked under Open questions),
and Implementation lists checkable file-level phases.

## Inventory

| PRD | Title | Status | Notes |
|---|---|---|---|
<!-- inventory:prd:start -->
| [0001](0001-chatrooms.md) | Chatrooms & peer messaging | Shipped | Transport may become historical if 0011 ships |
| [0002](0002-kanban-board.md) | Shared kanban board | Shipped | |
| [0003](0003-run-todos.md) | Run todo checklists | Shipped | Private vs shared; room todos removed |
| [0004](0004-autoresearch.md) | Autoresearch | Shipped | |
| [0005](0005-repl-tui.md) | REPL / TUI | Shipped (gaps) | Ask/confirm shipped; multi-line input etc. still open |
| [0006](0006-webui.md) | Web UI | Shipped | |
| [0007](0007-memory.md) | Memory layer | In progress | Builtin path shipped; pluggable config remains open |
| [0008](0008-arena.md) | Arena | In progress | Phase 3 (multi-instance) open |
| [0009](0009-schedule.md) | Scheduled runs | Shipped | Sweep-exit Known issue |
| [0010](0010-plugin-manifest-sdk.md) | Plugin manifest SDK | Shipped | Out-of-tree list → 0022 |
| [0011](0011-clanker-mesh.md) | Clanker mesh | In progress | Serve listener + `clanker mesh` + HTTP join/leave/status/pending in; `ck_mesh` guests and Phase 3 share open |
| [0012](0012-surface-plugins.md) | Surface plugins | Partial | Web UI shipped; TUI/CLI draft |
| [0013](0013-ttsr.md) | TTSR | Shipped | Substring/`*` abort-and-retry |
| [0014](0014-hashline.md) | Hashline edit format | Shipped | `hashes:true` + `op:hashline` |
| [0015](0015-advisor.md) | Advisor | Shipped | Off by default; fail-open |
| [0016](0016-eval-kernel.md) | Eval kernel | In progress | Persist/reset/SIGTERM shipped; JS, bridge, venv open |
| [0017](0017-dap.md) | DAP | In progress | Framing + debug tool + fake-adapter tests; live lldb optional |
| [0018](0018-snapcompact.md) | Snapcompact | Draft | Opt-in; default stays LLM compact |
| [0019](0019-github-fs.md) | GitHub filesystem | Shipped | `gh_read` + file cache; sqlite still open |
| [0020](0020-auto-thinking.md) | Auto thinking | Shipped | Opt-in classifier; selects a 0024 row |
| [0021](0021-smart-commit.md) | Smart commit | Shipped | `clanker commit` + guest grouping |
| [0022](0022-out-of-tree-tools.md) | Out-of-tree tools | Shipped | `tools_dir` is a list; last-listed wins |
| [0023](0023-webui-model-config.md) | Web UI model config | Shipped | Writes `config.local.toml` only |
| [0024](0024-sampling-profiles.md) | Sampling profiles | Shipped | Use-case table fills empty knobs |
| [0025](0025-fallback-provider-chain.md) | Fallback provider chain | Shipped | Reactive list; vision path unchanged |
| [0026](0026-llm-proxy.md) | LLM compatibility proxy | In progress | Serve surface landed, off by default; e2e not wired |
| [0027](0027-write-goal.md) | write-goal drafting | Shipped | Draft-only; persistence and execution live in 0035 |
| [0028](0028-hooks-bridge.md) | Lifecycle hooks (Claude Code bridge) | Shipped | Five events, bounded policy runner, black-box fixture |
| [0029](0029-loop-hygiene-guard.md) | Loop-hygiene guard | Shipped | Consecutive canonical-call reminders; configurable thresholds/exclusions |
| [0030](0030-acp-server.md) | ACP server (`clanker acp`) | In progress | stdio stub + initialize live; session methods open |
| [0031](0031-tool-result-pruning.md) | Deterministic tool-result pruning | Shipped | Request-only head/tail pruning; saved transcripts stay exact |
| [0032](0032-mcp-client-bridge.md) | MCP client bridge | Draft | deepseek-code.com audit; needs a new registry dispatch kind |
| [0033](0033-agent-presets.md) | Agent presets | Draft | deepseek-code.com audit; supersedes the Feynman "role prompt files" note |
| [0034](0034-session-subprocs.md) | Session subprocess inspector | Draft | Lists/kills 0016 registry rows from doctor + a guest |
| [0035](0035-goal-lifecycle.md) | Goal lifecycle capabilities | Shipped | Draft, persist, and execute are independent |
| [0036](0036-sixel-mascot-rendering.md) | SIXEL mascot rendering | In progress | Kitty → SIXEL → Unicode cells implemented; manual terminal matrix open |
| [0037](0037-decision-and-spec-stores-on-the-cli.md) | Decision and spec stores on the CLI | Shipped |  |
| [0038](0038-http-endpoints-for-the-record-stores.md) | HTTP endpoints for the record stores | Shipped |  |
| [0039](0039-repl-block-level-markdown-tables-block-quotes-nested-lists.md) | REPL block-level markdown: tables, block quotes, nested lists | Shipped |  |
<!-- inventory:prd:end -->

## Recommended build order (Drafts)

Packaging and reliability first, then agent-loop quality, then heavy
optional subsystems:

1. **0016** supervisors / **0017** DAP
2. **0018** / **0021** / **0011** / **0012 TUI+CLI** — opt-in or larger surface work
3. **0030** — ACP server (mirrors the already-shipped `clanker mcp` shape)
4. **0033** — agent presets (filter-only v1; independent of 0032)
5. **0032** — MCP client bridge (largest: needs a new registry dispatch kind; soft-depends on 0016 for a long-lived subprocess handle)

## Editing rules (short)

1. Goals ↔ Acceptance must cover each other.
2. Never leave empty Known issues.
3. Bugs go in Known issues; unresolved product choices go in Open questions
   only when they do **not** block starting Implementation.
4. When code drifts, fix the PRD the same day (Status + Design + Acceptance).
