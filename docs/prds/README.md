# PRDs

Product requirement docs for clanker. Schema and quality bar:
[`TEMPLATE.md`](TEMPLATE.md). Roadmap narrative and Done/Planned index:
[`../ROADMAP.md`](../ROADMAP.md). Architecture decisions that constrain
PRDs: [`../adrs/`](../adrs/).

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
| [0011](0011-clanker-mesh.md) | Clanker mesh | Draft | Serve owns sockets; leave≠drop; home-instance; Design locked |
| [0012](0012-surface-plugins.md) | Surface plugins | Partial | Web UI shipped; TUI/CLI draft |
| [0013](0013-ttsr.md) | TTSR | Shipped | Substring/`*` abort-and-retry |
| [0014](0014-hashline.md) | Hashline edit format | Shipped | `hashes:true` + `op:hashline` |
| [0015](0015-advisor.md) | Advisor | Shipped | Off by default; fail-open |
| [0016](0016-eval-kernel.md) | Eval kernel | Partial | Registry + disabled guest; supervisors open |
| [0017](0017-dap.md) | DAP | Draft | Needs 0016 subprocess registry |
| [0018](0018-snapcompact.md) | Snapcompact | Draft | Opt-in; default stays LLM compact |
| [0019](0019-github-fs.md) | GitHub filesystem | Shipped | `gh_read` + file cache; sqlite still open |
| [0020](0020-auto-thinking.md) | Auto thinking | Shipped | Opt-in classifier; selects a 0024 row |
| [0021](0021-smart-commit.md) | Smart commit | Shipped | `clanker commit` + guest grouping |
| [0022](0022-out-of-tree-tools.md) | Out-of-tree tools | Shipped | `tools_dir` is a list; last-listed wins |
| [0023](0023-webui-model-config.md) | Web UI model config | Shipped | Writes `config.local.toml` only |
| [0024](0024-sampling-profiles.md) | Sampling profiles | Shipped | Use-case table fills empty knobs |
| [0025](0025-fallback-provider-chain.md) | Fallback provider chain | Shipped | Reactive list; vision path unchanged |
| [0026](0026-llm-proxy.md) | LLM compatibility proxy | Draft | Independent of agent-loop drafts; four-PR plan |
| [0027](0027-write-goal.md) | write-goal drafting | Shipped | Field list settled (shipped five); proof/stop_rule read |
| [0028](0028-hooks-bridge.md) | Lifecycle hooks (Claude Code bridge) | Shipped | Five events, bounded policy runner, black-box fixture |
| [0029](0029-loop-hygiene-guard.md) | Loop-hygiene guard | Shipped | Consecutive canonical-call reminders; configurable thresholds/exclusions |
| [0030](0030-acp-server.md) | ACP server (`clanker acp`) | Draft | deepseek-code.com audit; mirrors `clanker mcp`'s shape |
| [0031](0031-tool-result-pruning.md) | Deterministic tool-result pruning | Shipped | Request-only head/tail pruning; saved transcripts stay exact |
| [0032](0032-mcp-client-bridge.md) | MCP client bridge | Draft | deepseek-code.com audit; needs a new registry dispatch kind |
| [0033](0033-agent-presets.md) | Agent presets | Draft | deepseek-code.com audit; supersedes the Feynman "role prompt files" note |

## Recommended build order (Drafts)

Packaging and reliability first, then agent-loop quality, then heavy
optional subsystems:

1. **0016** supervisors / **0017** DAP
2. **0018** / **0021** / **0011** / **0012 TUI+CLI** — opt-in or larger surface work
3. **0026** — LLM compatibility proxy (parallelizable; four incremental PRs)
4. **0030** — ACP server (mirrors the already-shipped `clanker mcp` shape)
5. **0033** — agent presets (filter-only v1; independent of 0032)
6. **0032** — MCP client bridge (largest: needs a new registry dispatch kind; soft-depends on 0016 for a long-lived subprocess handle)

## Editing rules (short)

1. Goals ↔ Acceptance must cover each other.
2. Never leave empty Known issues.
3. Bugs go in Known issues; unresolved product choices go in Open questions
   only when they do **not** block starting Implementation.
4. When code drifts, fix the PRD the same day (Status + Design + Acceptance).
