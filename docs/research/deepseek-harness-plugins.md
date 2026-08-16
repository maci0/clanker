# Research — DeepSeek Harness plugin inventory

## Status

Current — searched 2026-08-16.

Research is evidence, not a decision: it records what exists, how good it is,
and how confident the finding is. The decision that follows belongs in an
[RFC](../rfcs/) and, once made, an [ADR](../adrs/).

## Question

Which DeepSeek Harness official packages and community plugins implement a
capability clanker does not already ship or already plan, and which of those
are high value against clanker's constraints (local-first, WASM guests, no
paid remote sandbox, no live self-modification of the running process)?

"Should we become DSH" is not the question. DSH is a TypeScript/Cordis
monorepo; clanker is a Zig harness with sandboxed WASM tools. The useful
comparison is capability-by-capability.

## TL;DR

- **Official DSH is 47 package groups, not a plugin store.** Most groups are
  a different name for something clanker already ships (sessions, tools,
  compaction, goals, schedule, skills, subagents, web search, LSP, todos,
  plan mode, hooks, ACP). — `high` —
  [packages/README.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/README.md)
- **The 2026-08-14 audit already PRD'd the six that were missing then.**
  Hooks (0028), loop hygiene (0029), ACP (0030), tool-result prune (0031),
  MCP client (0032), agent presets (0033). Four of those have since shipped.
  This note does not reopen them. — `high` — [ROADMAP](../ROADMAP.md)
- **Five official families are still genuine gaps and high value here:**
  tool-result *spill* (persist + retrieve, not just prune), model-facing
  session-query, Code Mode, persistent PTY/`job_*`, and a human-feedback
  sidecar that never enters the prompt. — `high` on the gap, `medium` on
  implementation cost —
  [spill](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/spill/README.md),
  [session-query](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/session-query/README.md),
  [code-runtime](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/code-runtime/README.md),
  [jobs](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/jobs/README.md) /
  [terminal](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/terminal/README.md),
  [feedback](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/feedback/README.md)
- **The public `dsh-plugin` topic is not a catalog.** GitHub lists 4,214
  matching repos on 2026-08-16; day-one independent registries already
  discarded most of 411 as opportunistic tags. High-value community ideas
  that survive a primary-source read are `@file` mentions, turn-complete
  OS notifications, and git-first checkpoint rewind. — `high` on the spam,
  `medium` on those three —
  [topic](https://github.com/topics/dsh-plugin),
  [dshplugin.world](https://dshplugin.world/)
- **Still reject E2B, live self-mod (Creator / `extensions/`), Ralph as a
  named tool, and out-of-process Claude Code / Codex children.** Those
  answers from 2026-08-14 still hold. Continuable background subagents were
  set aside then; they remain high value and are listed below rather than
  left as a parenthetical. — `high`

## Scope and method

- **Searched:** official site [deepseek.com/harness/en](https://deepseek.com/harness/en/);
  `packages/README.md`, `docs/architecture.md`, and the group READMEs for
  session-query, spill, jobs, terminal, code-runtime, feedback, plan,
  workflow, subagent, extensions, attachment, sdk, guard, interaction;
  `docs/subsystems/session-query.md`; GitHub topic `dsh-plugin`;
  [dshplugin.world](https://dshplugin.world/) (29 inspected, snapshot
  2026-08-13); [awesome-dsh-plugin](https://github.com/awesome-dsh-plugin/awesome-dsh-plugin)
  README (Memory / Tools / Workflow sections); local tree (manifests,
  `src/agent/session.zig` `searchSessions`, `/api/sessions/search`, PRDs
  0007/0016/0028–0034, ROADMAP 2026-08-14 audit).
- **Not searched:** a live `npx @deepseek-ai/dsh` install; every community
  README (thousands of topic hits); Cordis paper internals; Chinese
  mirrors of the same lists. Sweep snippets were leads only.
- **Freshness:** 2026-08-16. DSH last tagged `0.1.0-rc.5` on 2026-08-13
  (developer preview). Official package list ages with the next rc.
  Community topic counts age in hours.

## What DSH is

DeepSeek Harness (`dsh`) is DeepSeek AI's MIT TypeScript monorepo
([deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)).
Everything is a Cordis plugin: the model adapter, the tool registry, the
session log, and the agent loop itself. A running process is a *profile*
that stacks *bundles* (`dsh-base`, `dsh-web-app`, `dsh-headless`) plus
user `cordis.patch.yml`. Modes on the official site:

| Mode | What it is | Clanker analog |
|---|---|---|
| Standard | Full coding agent | Default catalog |
| Code | Standard tools exposed as a TypeScript SDK the model programs against | Missing (see Code Mode below) |
| Minimal | Persistent bash + `str_replace_editor` | Closest: a tight `tool_allow` / future 0033 preset |
| Creator | Standard plus live plugin inspect/mount | Rejected (live self-mod) |

The 2026-08-14 ROADMAP audit used
[deepseek-code.com](https://deepseek-code.com) as the entry point and
then reviewed the real repo. This note starts from the official site and
the group READMEs.

## Options found

### Official package groups — inventory vs this tree

Each row is one group from
[packages/README.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/README.md)
(read 2026-08-16). "Clanker" is the closest shipped or planned surface,
not a claim of feature parity.

| DSH group | What it owns | Clanker today | Verdict |
|---|---|---|---|
| `core/` | Session log, system prompt, tools, agent loop | `src/agent/`, `src/toolhost/` (native on purpose) | Have |
| `api/`, `typert/` | Remote BFF + type-graph RPC | No equivalent; not needed without Cordis | Ignore |
| `goal/` | Same-session goal lifecycle | 0027/0035 shipped | Have |
| `schedule/` | Session-local follow-ups | `clanker schedule` + schedule guest | Have |
| `feedback/` | Log-only remark + per-message rating sidecar; neither enters the model | No sidecar. Autolearn is usage, not explicit ratings | **High gap** |
| `identity/` | Shared anonymous identity | Serve binds loopback; no multi-user id | Ignore |
| `llm/` | Adapter seam + providers | Native vtable (ADR 0004) | Have (different shape) |
| `e2b/` | Remote sandbox (POC) | Local WASM + `ck_*` | Reject (2026-08-14) |
| `subprocess/` | Process-tree seam | 0016 registry (in progress) | Partial |
| `shell/` | One-shot bash tool | `ck_exec` + per-manifest `exec_allow` | Have |
| `terminal/` | Persistent owner-scoped PTY + six model tools | No PTY. REPL `!cmd` is one-shot | **High gap** |
| `code-runtime/` | Worker-thread runtime + Code Mode `run_code` | No. Tools are one JSON call each | **High gap** |
| `sandbox/` | bwrap / Landlock / Seatbelt | zwasm + descriptor policy | Have (different shape) |
| `fs/` | File tools + bash-backed discovery | `read_file` / `edit_file` / `find_files` / hashline | Have |
| `lsp/` | LSP seam + `lsp` tool | `lsp` guest (zls) | Have |
| `skill/` | Skill catalog + loader | `skills` guest + prompt injection | Have (disclosure still open) |
| `compaction/` | Compaction + tool-result pruner | LLM compact + 0031 prune (shipped) | Have prune; missing spill |
| `context/` | Workspace instructions + time | `AGENTS.md` + system prompt sections | Have |
| `subagent/` | In-process, fork, ACP, Codex, Claude Code, SDK + continuable children | `subagent` / `swarm` (blocking join) | Partial; continuable still open |
| `jobs/` | Background-job registry + `job_*` | 0034 draft lists 0016 rows; no model `job_*` | **High gap** |
| `workflow/` | Model-authored orchestration + Ralph | Markdown `workflows/` + `chain`; not a worker engine | Partial; Ralph rejected |
| `web/` | Search / fetch seam | `web_search` / `fetch_web` | Have |
| `attachment/` | Content-addressed durable binaries | Web UI image/video attach; not CAS | Medium |
| `spill/` | Persist oversized tool output; inline preview + locator | 0031 rewrites to head/tail and *drops* the middle | **High gap** |
| `todo/` | `todo_write` | `todo_*` private run list | Have |
| `plan/` | Logged plan state + reviewed exit | `Agent.plan_mode` (web toggle; REPL still open) | Partial |
| `preset/` | Per-session tool allowlist + persona | 0033 draft | Planned |
| `guard/` | Repeat-call reminder + execute deadline | 0029 shipped; no per-call deadline policy | Partial |
| `bundle/` | `dsh --profile` patch layers | Profiles note already on ROADMAP (2026-08-16) | Planned |
| `extensions/` | Live plugin mount/unmount (Creator) | AOT WASM + `zig build tools` | Reject |
| `hooks/` | Claude Code / Codex hook bridge | 0028 shipped | Have |
| `session/` | JSONL / SQLite persistence, titles | JSONL under `state/sessions/` | Have |
| `session-query/` | FTS, lineage, event traces, *model tool* | `searchSessions` + `GET /api/sessions/search`; no model tool, no FTS index, no lineage | **High gap** |
| `settings/` | File-backed user settings | `config.toml` / `config.local.toml` | Have |
| `credentials/` | Env-over-`.env` | `auth.zig` + dotenv | Have |
| `storage/` | Non-session storage hub | `state/` files | Have |
| `workspace/` | Workspace entity | `src/agent/workspace.zig` | Have |
| `sdk/` | Out-of-process JSON-RPC to drive a runtime | `clanker mcp` / `clanker acp` (0030) | Partial |
| `acp/` | Automation-only ACP server | 0030 in progress | Planned |
| `interaction/` | Approvals, permission presets, ask-user, commands | `ask_user`, `confirm_writes`; no named permission presets | Partial |
| `boot/`, `host/`, `client/` | App boot + web GUI halves | `clanker serve` + `webui.wasm` + `ui/plugins/` | Have |
| `examples/`, `test-support/`, `util/` | Support | n/a | Ignore |

### Official high-value gaps (detail)

#### Spill — persist the bytes 0031 throws away

DSH `spill` writes oversized tool output to session-scoped files and
leaves the model a bounded preview plus a locator it can read back.
0031's pruner does the cheap half (head/marker/tail, no LLM) and
discards the middle. A later turn that needed the omitted lines has to
re-run the tool. Community `dsh-funnel` is the same idea with
error-line preference.

Fit: a guest over `state/spills/<session>/` plus a host hook next to
`prune.zig`. No new sandbox channel. Complements 0031 rather than
replacing it.

#### Session-query — the model can search history

DSH exposes authorized FTS over live + durable logs, session lineage
(fork parents/children), and bounded event windows as a *model-facing*
tool. Clanker already has the cheap human half: `session.searchSessions`
and `GET /api/sessions/search?q=` (min 3 chars, newest-first, cap 50).
The Feynman ROADMAP item that said "`state/sessions/` has no search"
is stale on the HTTP path. Still missing: `clanker session search`, a
REPL resume-from-hit, and a `sessions` (or dedicated) guest the model
can call. DSH's SQLite FTS and replacement-chain traces are extra; the
linear scan is enough until the store is large.

Fit: extend the existing `sessions` guest. Do not stand up SQLite for
this unless the linear scan is measured slow.

#### Code Mode — one program, many tool calls

Official site: Code mode exposes Standard tools through a Code Mode SDK
so the model writes one TypeScript program that combines multi-step
operations. DSH runs that program in a worker thread (`code-runtime`),
which their own README says is isolation from the event loop, *not* a
security boundary.

Fit: high token-savings idea, awkward in this tree. A guest that
interprets a tiny call-script (JSON pipeline / WASM guest-authored
program) could get the orchestration win without a Node worker. A raw
TypeScript worker would sit outside `ck_*`. Design pin: the program
must call existing tools by name, never host APIs.

#### Persistent PTY and `job_*`

`terminal/` is owner-scoped PTY sessions (state across tool calls,
interactive stdin). `jobs/` is a generic background-job protocol
(observe, cancel, wait, completion notice) with model-facing `job_*`.
Clanker tools are request/response; a long `zig build` either blocks
the turn or is lost. 0016's kernel and 0034's inspector cover
*host-owned* long-lived children (Python kernel, DAP), not a
model-started build the parent can poll.

Fit: model-facing jobs can reuse the 0016 registry (new `kind` values)
so 0034 lists them. A full PTY is a larger trust question (`ck_exec`
has no interactive stdin today). Jobs first, PTY second.

#### Feedback sidecar

DSH splits an immutable `/feedback` remark in the session log from an
editable per-message rating in a storage sidecar. **Neither form enters
the model conversation.** That is the useful part: an explicit quality
signal for autolearn / compare / advisor without polluting the next
prompt.

Fit: `state/feedback.jsonl` plus a web thumbs control and a guest the
improve loop can read. Cheap.

#### Continuable background subagents

`packages/subagent/` documents start-one, keep-working, poll-later
children, plus control/report tools. Clanker's `ck_subagent` joins the
nested thread; the parent is parked. The 2026-08-14 audit set this
aside for lack of a concrete user need. The need is the same as jobs:
a long research or review child should not freeze the parent turn.

Fit: host-side, not a guest. Soft-depends on the job registry so a
background child is one more `kind`.

### Community plugins — what is real

The official discovery line is "add the `dsh-plugin` topic". On
2026-08-16 that topic listed 4,214 public repos; the official harness
itself is the top hit (~117k stars). Independent registries exist
because the topic filled with unrelated agent-skills and products that
only added the tag. [dshplugin.world](https://dshplugin.world/)
inspected 29 of 411 day-one repos. [awesome-dsh-plugin](https://github.com/awesome-dsh-plugin/awesome-dsh-plugin)
is a curated installable-bundle list and is the better primary source
for community capabilities.

Most of that list is DSH-Web-UI skins, pets, DeepSeek-balance chips,
and mobile/LAN gates. Those do not transfer (clanker already has
themes, `model_stats`, and a plugin view surface). The community
capabilities that survive a "would we want this as a WASM guest or a
webui plugin" filter:

| Plugin | Idea | Clanker | Verdict |
|---|---|---|---|
| [omdsh-dev/dsh-at-file](https://github.com/omdsh-dev/dsh-at-file) | `@file` mentions attach workspace contents in the composer | Images/video only; no path chip | **High** (cheap UX) |
| [omdsh-dev/dsh-notification](https://github.com/omdsh-dev/dsh-notification) | OS notification when a turn finishes | Nothing when the tab is in the background | **High** (cheap UX) |
| [PerryLink/dsh-checkpoint-rewind](https://github.com/PerryLink/dsh-checkpoint-rewind) / [Anionex/dsh-turn-rewind](https://github.com/Anionex/dsh-turn-rewind) | Snapshot workspace before mutating tools; rewind files + fork session | `session.branchSession` forks text only | **High** |
| [YuanyuanMa03/dsh-funnel](https://github.com/YuanyuanMa03/dsh-funnel) | Keep errors + head/tail; spill full text | 0031 prune only | Same as official spill |
| [truelove-dreamer/dsh-plugin-recall](https://github.com/truelove-dreamer/dsh-plugin-recall) | Model FTS over past sessions | HTTP search only | Same as official session-query |
| [Drifter-yh/dsh-tool-policy](https://github.com/Drifter-yh/dsh-tool-policy) | Deny-by-default `tools/pre-execute` rules | `confirm_writes` + plan_mode | Medium (0033 / permission presets cover most) |
| [Lum1104/dsh-browser](https://github.com/Lum1104/dsh-browser) and many Playwright/CDP clones | Drive a real browser | `fetch_web` only | Medium; sandbox pin is large |
| [liustack/modlens](https://github.com/liustack/modlens) + vision toolkit family | Vision sidecar for text-only models | Native `image_in` + `opencv` | Low (we already send images) |
| [Jesse-njx/dsh-memory](https://github.com/Jesse-njx/dsh-memory) and ~30 memory plugins | Cross-session memory with citations | 0007 in progress | Already planned |
| [btspoony/dsh-advisor](https://github.com/btspoony/dsh-advisor) | Second-model turn critique | 0015 shipped | Have |
| [Letter2025/dsh-model-failover](https://github.com/Letter2025/dsh-model-failover) | Circuit breaker | `fallback_providers` (reactive) | See [omniroute-adoption](omniroute-adoption.md) |
| Computer-use / ADB / email / calendar / stocks | Workspace-app surface | Out of scope (same as Odysseus) | Reject |
| Markets / find-plugin / starter packs | Discover Cordis plugins | `clanker plugins` + ADR 0007 (no registry) | Reject |

## Out-of-the-box options

- **Already in the tree:** 0031 prune, `searchSessions`, plan mode,
  `subagent`, `schedule`, goals, skills, LSP, hooks, advisor, memory
  (0007), MCP *server*, ACP stub, hashline, workflows-as-markdown,
  image attach, `model_stats`. Several "community plugins" are ports of
  these.
- **Standard library / OS primitive:** `notify-send` / `osascript` /
  Windows toast for turn-complete notifications; `git stash` /
  `git worktree` for checkpoint rewind. Prefer those over a new format.
- **Do nothing:** keep paying for re-running discarded tool output,
  keep the model blind to other sessions unless the operator pastes an
  id, keep long jobs on the parent turn. Cost is tokens and operator
  attention, not correctness.
- **Adjacent domain:** OmniRoute's RTK (command-aware tool-result
  filters) is a better *filter* than DSH spill's naive head/tail; the
  two compose (filter, then spill what remains). See
  [omniroute-adoption](omniroute-adoption.md).
- **Buy, host, or delegate:** E2B and hosted memory (OpenViking,
  Honcho, Mnemon) are the opposite of local-first. Pointing an
  `openai_compat` provider at a local DSH is possible and is
  delegation, not adoption.

## Comparison

| Option | Maturity | Licence | Fit | Main risk |
|---|---|---|---|---|
| Official DSH families (spill, session-query, code-runtime, jobs/PTY, feedback) | Product packages in a 3-day-old developer preview (`0.1.0-rc.5`) | MIT | High as *ideas*; low as code to vendor | Preview APIs will move |
| Community `@file` / notify / rewind | Many overlapping repos, days old | Mixed MIT / unmarked | High as UX slices | Quality and maintenance unknown |
| Vendor DSH or run it beside clanker | 117k GitHub stars (2026-08-16 topic page) | MIT | Wrong product | Two harnesses, two sandboxes |
| Do nothing on the five official gaps | n/a | n/a | Fine short-term | Re-run cost and frozen parent turns |

## Evidence log

| Claim | Source | Read on | Confidence |
|---|---|---|---|
| 47 official package groups, roles as tabled | [packages/README.md](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/master/packages/README.md) | 2026-08-16 | high |
| Modes: Standard / Code / Minimal / Creator | [deepseek.com/harness/en](https://deepseek.com/harness/en/) | 2026-08-16 | high |
| Session-query is FTS + lineage + model tool | [session-query README](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/master/packages/session-query/README.md) + [subsystem](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/master/docs/subsystems/session-query.md) | 2026-08-16 | high |
| Spill persists output and leaves a locator | [spill README](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/master/packages/spill/README.md) | 2026-08-16 | high |
| Code Mode runs model-written programs in a worker; not a security boundary | [code-runtime README](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/master/packages/code-runtime/README.md) | 2026-08-16 | high |
| Feedback never enters model context | [feedback README](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/master/packages/feedback/README.md) | 2026-08-16 | high |
| Continuable background subagents are first-class | [subagent README](https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/master/packages/subagent/README.md) | 2026-08-16 | high |
| `dsh-plugin` topic: 4,214 repos | [github.com/topics/dsh-plugin](https://github.com/topics/dsh-plugin) | 2026-08-16 | high |
| Day-one topic was 411; 29 inspected as real plugins | [dshplugin.world](https://dshplugin.world/) | 2026-08-16 | high (their snapshot 2026-08-13) |
| Clanker HTTP session search exists | `src/cli.zig` `handleSessionSearch`, `src/agent/session.zig` `searchSessions` | 2026-08-16 | high |
| 0031 prune does not persist the omitted middle | [PRD 0031](../prds/0031-tool-result-pruning.md) | 2026-08-16 | high |
| 0028–0033 already exist from the 2026-08-14 audit | [ROADMAP](../ROADMAP.md), [PRDs README](../prds/README.md) | 2026-08-16 | high |

## Open questions

- **Code Mode language.** A JSON call-script the host interprets vs a
  guest-side interpreter vs rejecting TypeScript workers. Spike: one
  `run_plan` guest that executes an array of `{tool, args}` and returns
  the last result plus a bound log. That is enough to measure token
  savings before designing a language.
- **PTY vs jobs.** Does any current operator task need interactive
  stdin, or only "start `zig build` and poll"? If only the latter, skip
  PTY.
- **Session-query index.** Measure `searchSessions` on a machine with
  a few hundred transcripts before adding SQLite FTS.
- **Browser control.** In-scope only if it is a guest with a tight
  `network_allow` and no access to the operator's logged-in daily
  browser. Not settled here.

## What would change the answer

- DSH leaving developer preview with a stable plugin ABI (we still
  would not vendor TypeScript, but package semantics would age slower).
- A licence change away from MIT.
- Clanker growing a session store large enough that linear search is
  the bottleneck.
- An operator need that only a real PTY or a real browser satisfies.

## References

Official:

- https://deepseek.com/harness/en/
- https://github.com/deepseek-ai/deepseek-harness
- https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/master/packages/README.md
- https://raw.githubusercontent.com/deepseek-ai/deepseek-harness/master/docs/architecture.md
- Group READMEs linked in the inventory table

Community / discovery:

- https://github.com/topics/dsh-plugin
- https://dshplugin.world/
- https://github.com/awesome-dsh-plugin/awesome-dsh-plugin
- https://github.com/Drifter-yh/dsh-tool-policy
- https://github.com/omdsh-dev/dsh-at-file
- https://github.com/omdsh-dev/dsh-notification
- https://github.com/PerryLink/dsh-checkpoint-rewind

Local:

- [ROADMAP 2026-08-14 DSH audit](../ROADMAP.md)
- [PRDs 0028–0034](../prds/README.md)
- [omniroute-adoption.md](omniroute-adoption.md) (related request-path ideas)

## Appendix

### High-value shortlist (for the roadmap)

Ranked by impact on clanker, not by DSH marketing weight. Each is an
idea to specify, not a package to vendor.

1. **Tool-result spill** — persist what 0031 omits; locator the model can
   read. Official `spill` + community `dsh-funnel`.
2. **Model-facing session query** — guest + CLI over the existing
   `searchSessions` scan; FTS later if measured. Official `session-query`.
3. **Background jobs** (then PTY) — start / poll / cancel long tools
   without parking the parent. Official `jobs` / `terminal`; reuse 0016.
4. **Continuable background subagents** — same job registry, nested
   agent as a `kind`. Official `subagent` continuable children.
5. **Code Mode v1** — bounded tool-call script, not a TypeScript worker.
   Official `code-runtime` idea only.
6. **Human feedback sidecar** — thumbs that never enter the prompt.
   Official `feedback`.
7. **Composer `@file` mentions** — attach workspace paths as chips.
   Community `dsh-at-file`.
8. **Turn-complete OS notifications** — tab-in-background case.
   Community `dsh-notification`.
9. **Checkpoint rewind** — git-first snapshot before mutating tools;
   rewind files *and* fork the session. Community `dsh-checkpoint-rewind`.

Already planned, not re-listed: 0030 ACP, 0032 MCP client, 0033
presets, 0034 subprocess inspector, named `--profile` overlays, skill
progressive disclosure (everything-is-a-plugin audit).

### Queries used

- official site and `packages/README.md` / `docs/architecture.md`
- group READMEs for the five official gaps
- `site:github.com/deepseek-ai/deepseek-harness packages`
- GitHub topic `dsh-plugin`
- `dshplugin.world`, `awesome-dsh-plugin` README
- local `rg` for `searchSessions`, `spill`, `pty`, session search CLI
