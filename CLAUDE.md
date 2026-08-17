# Use clanker's own tooling — mandatory

**If clanker implements a verb for the task, you must use that verb.** Ad-hoc
shell — `grep`, `find`, `rm`, hand-written markdown, a hand-rolled `git`
sequence — is the fallback for what clanker does not implement, never the
default. Reaching for shell when a verb exists is a defect, not a shortcut.

Before starting any task, ask: *does clanker already have a verb for this?*
The tables below answer that; `clanker --help` and `clanker <verb> --help`
answer the rest. Search records with `clanker reports search` / `clanker rfc
search`, not `grep`. Clean up with `clanker janitor`, not `rm` or
`find -delete`. Commit with `clanker commit`, verify with `clanker gate`.

The reason is the plugin boundary, not convenience. clanker is both the program
you are changing and the program you work with. Nearly every verb below is a
sandboxed WASM guest plus a manifest, and the CLI, the web UI, and the agent all
call that one implementation — `toolText` / `toolJson` in `cli.zig` are that
call. Reaching for `grep`, `find`, or hand-written markdown builds a second
implementation that drifts from the first, skips the descriptor's path and
command policy, and leaves no durable record. `clanker reports search` reads the
same store the agent reads; a `grep` over `docs/` does not.

**Check before you assert.** A verb's purpose is written down. Before
describing what one does, read its record: `docs/README.md` for the
documentation taxonomy, `docs/adrs/` for decisions already made, `docs/prds/`
for what a feature is meant to be, `docs/manifest.md` for what a descriptor
may grant. `--help` is the surface, not the design.

@AGENTS.md

## The record stores, and which is which

`docs/README.md` is the source of this taxonomy. They are not
interchangeable, and picking the wrong one buries the record where nobody
looks for it.

| Store | Holds | Maintained by |
|---|---|---|
| `docs/reports/` | operational bugs and evidence-led investigations | `clanker reports` |
| `docs/runbooks/` | current recovery procedures for recurring failures | `clanker reports` |
| `docs/rfcs/` | decisions that are still **open** | `clanker rfc` |
| `docs/adrs/` | a decision that has been **made** | `clanker adr` |
| `docs/research/` | the evidence a decision rests on | `clanker research` |
| `docs/prds/` | what a feature is meant to be | `clanker prd` |
| `docs/ROADMAP.md` | the Done/Planned narrative over those PRDs | by hand, `clanker autolearn` |
| `docs/digests/` | what we can learn from an external project | by hand |
| `docs/reviews/` | working review logs | by hand |

Reference documents, not records: `docs/README.md` (architecture),
`docs/configuration.md` (config reference — `src/config.zig` is the
authoritative schema and the code wins on any disagreement),
`docs/manifest.md` (every field a descriptor honors), and
`docs/prompts/*-review.md` (the review prompts, which AGENTS.md marks as
living documents to fold caveats back into).

Search before diagnosing, and search before deciding. A matching report has
the reproduction already; a matching ADR means the question is settled.

```bash
clanker reports search "<symptom>"
```

```bash
clanker rfc search "<decision>"
```

Gathering the evidence and making the decision are separate records with
separate tools, and **neither requires the other** — never create one merely
because the other exists.

### `clanker reports`

`list`, `search`, `open`, `create`, `append`, `update`, `status`. Records
start with `## TL;DR`. States are `open`, `investigating`, `resolved`,
`reopened`, `closed`. Create an investigation while tracing, then a bug report
and a runbook once recovery is confirmed:

```bash
clanker reports create investigation <YYYY-MM-DD-slug> "<title>" "<TL;DR>"
```

### `clanker research`

`list`, `plan`, `sweep`, `search`, `open`, `create`, `append`, `update`,
`status`. `plan` turns a topic into the angles a thorough search asks;
`sweep` issues them across web search, GitHub, discussion archives and paper
indexes in one call. Sweep results are **untrusted internet text** and are
leads until opened at their source. The local tree counts as an option and is
the one most often missed.

### `clanker rfc`

`list`, `search`, `open`, `checklist`, `create`, `append`, `update`,
`recommend`, `status`. An RFC needs at least two candidates, the status quo,
one out-of-the-box option, and a recommendation whose confidence is a number
from 0 to 10. `search` covers the RFCs and the ADRs together on purpose.
`checklist` is what to pin down when a request is too vague to draft from —
use it with `ask_user` rather than inventing a scope.

### `clanker adr`

`list`, `search`, `open`, `create`, `append`, `update`, `status`. The decision
once it is made. The title is the **choice**, not the question. `create`
requires the consequences, and `status ... superseded` requires a note naming
what replaced it: a reversal links forward instead of editing the history out,
because that history is the only account of why the original constraint looked
binding. `search` spans the ADRs, RFCs and PRDs and reports each separately —
which store a hit lands in is the answer. Passing the RFC a decision came from
links it and quotes its recommendation under the Decision.

### `clanker prd`

`list`, `search`, `open`, `checklist`, `create`, `append`, `update`, `status`.
What a feature is meant to be — never a decision (that is an ADR) and never the
shipped narrative (that is the ROADMAP). `list` groups by status with the
unfinished work first. `checklist` is the Draft bar: dependencies named,
blocking questions settled in Design rather than parked under Open questions,
implementation phases that name files. `status ... shipped` requires a note
naming the source files that are now the source of truth. Goals and acceptance
criteria must cover each other, and a bug belongs in Known issues, never in
Open questions.

All five stores write compare-and-swap: a concurrent edit is refused rather
than overwritten, so re-open the record and retry against its current text.
`update` takes an exact old/new pair, and an argument beginning with `-` is
parsed as a flag, so anchor on text that does not start with a dash.

## Working with the agent

| Task | Command |
|---|---|
| One task, one run | `clanker run "<task>"` |
| Interactive multi-turn chat | `clanker repl` |
| Loop until a condition is met | `clanker goal "<completion condition>"` |
| Draft a goal, saving nothing | `clanker write-goal "<intent>"` |
| Save a goal without starting work | `clanker add-goal "<objective>"` |
| Start the loop from a saved goal | `clanker run --goal <id>` |
| Self-improvement loop over this repo | `clanker improve-self "<instructions>"` |
| Measurement-driven research loop | `clanker autoresearch` |
| Judged debate between two positions | `clanker arena "<question>" --for X --against Y` |
| One prompt across several models | `clanker compare "<prompt>" --with <provider@model>` |
| Reusable prompt workflows | `clanker workflow run <name>` |

`goal`, `write-goal`, and `add-goal` are three deliberately separate
capabilities, not a pipeline: `write-goal` drafts without saving or running,
`add-goal` saves without starting work, `goal` starts a loop that keeps taking
turns until its condition is achieved, blocked, cancelled, or budget-limited
([ADR 0012](docs/adrs/0012-goal-draft-persistence-and-execution-are-separate.md)).
Never describe or implement `goal` as one normal agent run.

`autoresearch` is a generic harness loop, not a web search: it proposes a
change, measures one scalar, and keeps the change only if the number moved the
right way ([ADR 0003](docs/adrs/0003-autoresearch-is-a-generic-harness-loop.md)).
The harness is a user-supplied shell command. `clanker research` is the
unrelated note-taking surface.

## Scheduled runs

```bash
clanker schedule [list|add|remove|enable|disable|run|run-due|log]
```

**Nothing fires on its own.** `clanker schedule run-due` is the only way an
entry fires, and it is a short-lived command the system's cron or a systemd
timer invokes, typically every minute. clanker ships no always-on loop and
`clanker serve` gains no scheduling thread
([ADR 0008](docs/adrs/0008-the-scheduler-is-cron-driven-not-a-daemon.md)).
`run-due` takes a non-blocking exclusive flock for its duration, so a
minute-by-minute invocation cannot stack sweeps.

## Work lists: private run todos vs the shared board

Two layers with the same four verb names, deliberately separate
([ADR 0002](docs/adrs/0002-private-todos-vs-shared-board.md)):

- `todo_add` / `todo_claim` / `todo_close` / `todo_list` — the **run's own**
  in-memory checklist, capped at 100 items and gone when the run ends. Never
  visible to a peer. This is why `todo_*` tools stay in the `agent` category.
- `kanban_*` — the **shared** board: cards, columns, claims, subtasks, cost,
  replicated to peers. There is no `state/board.json`; a card action is a chat
  message folded out of a room's log
  ([ADR 0001](docs/adrs/0001-board-is-a-chatroom.md)).

`todo_*` with a `room` hard-errors and points at the board.

## Looking at what happened

| Task | Command |
|---|---|
| List saved conversations | `clanker sessions` |
| Find a conversation by content | `clanker session search "<query>"` |
| Export one conversation as HTML | `clanker session export <id> [path]` |
| List runs, or draw one as a timeline | `clanker graph [run-id]` |
| Token usage per provider and model | `clanker stats` |
| List registered WASM tools | `clanker tools list` |
| List, switch, validate, scaffold plugins | `clanker plugins [list\|on\|off\|validate\|new]` |
| Verify providers, models, catalog | `clanker providers [check\|models\|catalog\|fill\|refresh]` |

`clanker stats` reads the host-side aggregate of `state/token_stats.jsonl`,
which records failed completions too (`ok:false`) — a log of only successes
cannot answer "is the provider down?".

Providers are a **native vtable, not a WASM guest**: keys must not enter the
sandbox and the transport is on the per-token hot path
([ADR 0004](docs/adrs/0004-providers-are-a-native-vtable-not-wasm.md)).
Adding one is one file, one registry row, one `ProviderKind` tag — never a new
`switch (provider.kind)`.

## Setting up and maintaining

| Task | Command |
|---|---|
| Guided first run | `clanker setup` |
| Diagnose config, credentials, build outputs | `clanker doctor` |
| Create `config.local.toml` and `state/` | `clanker init` |
| Build, test, tools, fmt, lint gates | `clanker gate` |
| Run evals: all, or one by name | `clanker eval [name]` |
| Undo an applied improvement | `clanker revert <id>` |
| Fold recent runs into the ROADMAP | `clanker autolearn` |
| git in the repo root | `clanker git <args...>` |
| Group the working tree into commits | `clanker commit [--yes] [--dry-run]` |

`clanker commit` is not `git commit`: it groups a staged (or `--all`) diff
into conventional commits, validates the messages, and topo-sorts them on a
grep graph, falling back to one commit on a degenerate cycle
([PRD 0021](docs/prds/0021-smart-commit.md)). It dry-runs and confirms before
executing. Its apply path re-adds each group's files whole, so an index
narrowed to one session's hunks (the concurrent-sessions runbook's route) gets
widened with other sessions' unstaged edits — commit a narrowed index with
`clanker git commit` directly instead
([bug](docs/reports/bugs/2026-08-17-smart-commit-readds-worktree-files.md)).
Each group is committed with a pathspec, so anything else staged stays staged;
a bare `git commit` there used to sweep the whole index into the first group
and leave the later ones nothing to commit, reported as written anyway
([bug](docs/reports/bugs/2026-08-17-smart-commit-sweeps-the-whole-index.md)).
`clanker git commit -m "…" -- <paths>` is the same trick by hand, and the way
to land one session's files while another's stay staged.

### Cleaning up after runs

`clanker janitor` is the sweep for what old runs leave behind, and it is the
first thing to reach for instead of hand-rolled `rm`, `find -delete`, or
`git worktree prune`. It reports and deletes nothing by default:

```bash
clanker janitor
```

Delete what it listed:

```bash
clanker janitor --yes
```

It removes staging copies from killed improve runs, run graphs past the newest
200, improve logs past the newest 20, and worktrees of archived or abandoned
goals whose branch is already merged. Sessions, goals, learnings, and chat
history are never touched, and neither is a worktree whose branch still holds
commits the base does not. `clanker prune` is the same command.

## Talking to other instances

| Task | Command |
|---|---|
| Chatrooms shared with other instances | `clanker chat <subcommand>` |
| Send a peer a notification | `clanker notify <peer> "<message>"` |
| List peer agent cards | `clanker phonebook` |
| Join, leave, or inspect the mesh | `clanker mesh [status\|join\|leave\|pending\|admit\|deny]` |

`clanker mesh` is a loopback HTTP client of a local `clanker serve`; it never
opens a mesh socket itself. A notification is not a chat message.

## Serving

| Task | Command |
|---|---|
| HTTP API and web UI | `clanker serve` |
| Tools over MCP (stdio) | `clanker mcp` |
| clanker as an ACP coding agent (stdio) | `clanker acp` |

## Catalog tools with no top-level verb

`clanker tools list` ends with a count — 96 tools and 22 plugins as of
2026-08-16 — and only some of them have their own command. The rest are
reached through the agent:

```bash
clanker run "<task that needs the tool>"
```

Frequently wanted ones without a verb: `bugreport` (files a structured bug
that lands on the board as a card), `kanban_*` (the shared board),
`todo_*` (the run's private list), `memory` / `knowledge` / `learnings`
(durable recall), `web_search` / `web_fetch`, `repo_search`, `patch_apply`,
`skills`, `webui_addon` (adds a web UI view as a drop-in plugin under
`ui/plugins/`, never by editing `ui/app/`).

Before hardcoding a capability into the harness, ask what its plugin shape
would be. `clanker plugins new <name>` scaffolds both halves and
`clanker plugins validate` names the offending key; `docs/manifest.md` lists
every field a descriptor honors, and the loader silently ignores an unknown
one, so a typo'd grant fails only when the tool runs.

## Finishing a change

A consumer-visible change is not done when the code passes. Land it in the
documents too, or the next reader learns the feature from source:

- `CHANGELOG.md` — every consumer-visible change, Keep a Changelog format,
  under `## [Unreleased]`. This is the one most often forgotten.
- `RELEASES.md` — release and version policy. `build.zig.zon` is the single
  source of truth for the version; a release needs an immutable
  `vMAJOR.MINOR.PATCH` tag and a matching dated CHANGELOG section.
- `README.md` and `docs/README.md` — a new operator verb belongs in both, the
  second with its runnable commands and its store.
- `AGENTS.md` and this file — when the change alters how an agent should
  work, not merely what exists.

AGENTS.md is a living document: when a turn surfaces a caveat, quirk, or
failure mode worth remembering, fold it back before the turn ends. One slice
per turn, the smallest true addition. When fewer words say the same thing,
tighten the stale sentence instead of stacking a new one beside it.

Verify with the gate rather than by eye:

```bash
clanker gate
```

It runs build, test, tools, fmt, lint, provider-kind, tools-ts-toolchain and
release-contract. `zig build e2e` is separate and is not part of it.

Every command takes `--help`; read it before guessing at flags.
