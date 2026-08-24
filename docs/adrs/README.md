# ADRs — architecture decision records

An ADR records a decision that **has been made**: the constraint that forced
it, the choice, and what that choice costs. The [RFC](../rfcs/) that may
precede it argues the alternatives; this record is the answer. Neither store
requires the other — a decision can be obvious enough to need no RFC, and an
RFC can be withdrawn without ever producing an ADR.

## Quick start

See every decision on record, and the next free number:

```bash
clanker adr
```

Check whether something is already settled before re-opening it:

```bash
clanker adr search "provider vtable"
```

Record a decision, optionally naming the RFC it came from:

```bash
clanker adr create "Providers are a native vtable" "Keys must not enter the sandbox" "Each provider is one vtable file" "Adding one is three edits; a provider cannot be swapped without a rebuild"
```

Read one in full:

```bash
clanker adr open docs/adrs/0004-providers-are-a-native-vtable-not-wasm.md
```

The same actions are the `adr` tool's, which is what the CLI calls.
Everything below is detail.

## What belongs here

- A decision with live alternatives that someone will later want to revisit:
  a boundary, an ownership split, a data format, a dependency.
- A decision that constrains future work — the thing a PRD has to design
  around, and the reason a reviewer says "no, we decided that".

What does not belong: an open question (write an [RFC](../rfcs/)), a feature
specification (a [PRD](../prds/)), or an operational failure and its recovery
(a [report or runbook](../reports/)).

## Conventions

- Files are numbered `NNNN-<short-title>.md`, allocated by the tool.
- The title is phrased as the **choice made**, not as the question: "Providers
  are a native vtable", not "How should providers be implemented?".
- Status is one of `Accepted`, `Superseded`, `Deprecated` — a decision still
  being made is an RFC, not a proposed ADR. Set it
  with `clanker adr status` so the inventory below stays true.
- One decision per ADR. A later decision that reverses this one **supersedes**
  it: mark this file Superseded, link forward, and leave the reasoning in
  place. Editing the history out of an ADR destroys the only record of why the
  original constraint looked binding.
- Consequences must name the honest downside. An ADR that only argues for its
  own decision is useless to whoever is deciding whether to revisit it, which
  is the one reader it is written for.

## Agent workflow

Search before deciding: `clanker adr search "<query>"` covers this directory,
the RFCs, and the PRDs together, so a settled decision surfaces before it is
re-litigated. `clanker rfc search` covers the RFCs and ADRs from the other
side.

When an RFC argued the decision, pass it to `create`: the ADR links it from
Status and lifts the RFC's recommendation in as a quoted line under the
Decision, so a divergence between what was recommended and what was chosen is
visible while it is still being written. Then close the RFC out with
`clanker rfc status <path> decided "<note naming this ADR>"`.

`append`, `update` and `status` are compare-and-swap writes: a concurrent edit
is refused rather than overwritten, so re-`open` the record and retry against
its current text.

## Inventory

<!-- inventory:adr:start -->
- [ADR 0049 — A guest reads response headers through an allowlisted envelope on a second HTTP entry point](0049-a-guest-reads-response-headers-through-an-allowlisted.md) — Accepted
- [ADR 0048 — Preparing a hand-made worktree is an explicit verb, not a config-load fallback](0048-preparing-a-hand-made-worktree-is-an-explicit-verb-not-a.md) — Accepted
- [ADR 0047 — REPL mid-stream inject is the existing steer queue](0047-repl-mid-stream-inject-is-the-existing-steer-queue.md) — Accepted
- [ADR 0046 — Nested explore/plan/coder types are shipped presets named by subagent_type](0046-nested-explore-plan-coder-types-are-shipped-presets-named.md) — Accepted
- [ADR 0045 — A goal queue starts the next objective only when the current goal completes](0045-a-goal-queue-starts-the-next-objective-only-when-the.md) — Accepted
- [ADR 0044 — Markdown session export is a second renderer in the session_export guest](0044-markdown-session-export-is-a-second-renderer-in-the.md) — Accepted
- [ADR 0043 — Operator /compact is the existing summarizer plus an optional hint](0043-operator-compact-is-the-existing-summarizer-plus-an.md) — Accepted
- [ADR 0042 — Session permission modes sit on confirm_writes; the sandbox always-denied tier never lifts](0042-session-permission-modes-sit-on-confirm-writes-the-sandbox.md) — Accepted
- [ADR 0041 — Composer @path mentions expand through a host-tested helper into the saved user message](0041-composer-path-mentions-expand-through-a-host-tested-helper.md) — Accepted
- [ADR 0040 — Browser is a first-class catalog tool; phase 1 is status and setup](0040-browser-is-a-first-class-catalog-tool-phase-1-is-status.md) — Accepted
- [ADR 0039 — Foreign transcripts import as new clanker sessions, Claude Code JSONL first](0039-foreign-transcripts-import-as-new-clanker-sessions-claude.md) — Accepted
- [ADR 0038 — Live sessions get advisory file-touch notify from a host read-set](0038-live-sessions-get-advisory-file-touch-notify-from-a-host.md) — Accepted
- [ADR 0037 — Every Agent.run turn injects memory hits through the existing guest](0037-every-agent-run-turn-injects-memory-hits-through-the.md) — Accepted
- [ADR 0036 — repo_search attaches enclosing symbols to grep hits](0036-repo-search-attaches-enclosing-symbols-to-grep-hits.md) — Accepted
- [ADR 0035 — Anthropic cache-cold is a timestamp compare at request time](0035-anthropic-cache-cold-is-a-timestamp-compare-at-request-time.md) — Accepted
- [ADR 0034 — openai_compat extra_body is a provider JSON object merged last](0034-openai-compat-extra-body-is-a-provider-json-object-merged.md) — Accepted
- [ADR 0033 — Sessions are per-session SQLite databases with an append-only event stream; mesh peers replicate streams at cursor+1](0033-sessions-are-per-session-sqlite-databases-with-an-append.md) — Accepted
- [ADR 0032 — External coding agents are driven by an ACP client first, with headless spawn as fallback](0032-external-coding-agents-are-driven-by-an-acp-client-first.md) — Accepted
- [ADR 0031 — Compare-and-swap locks live in state/locks, keyed by a hash of the target path](0031-compare-and-swap-locks-live-in-state-locks-keyed-by-a-hash.md) — Accepted
- [ADR 0030 — Agent presets are preset.toml multi-root with registry filter](0030-agent-presets-are-preset-toml-multi-root-with-registry.md) — Accepted
- [ADR 0029 — Tool-result pruning is deterministic head/marker/tail on the request copy](0029-tool-result-pruning-is-deterministic-head-marker-tail-on.md) — Accepted
- [ADR 0028 — Loop-hygiene guard is deterministic canonical chain with advisory reminders](0028-loop-hygiene-guard-is-deterministic-canonical-chain-with.md) — Accepted
- [ADR 0027 — Lifecycle hooks are a Claude-dialect bridge via execUnderPolicy](0027-lifecycle-hooks-are-a-claude-dialect-bridge-via.md) — Accepted
- [ADR 0026 — ACP server is minimal automation-only over stdio](0026-acp-server-is-minimal-automation-only-over-stdio.md) — Accepted
- [ADR 0025 — MCP client is a native bridge with qualified tool names and a registry dispatch kind](0025-mcp-client-is-a-native-bridge-with-qualified-tool-names.md) — Accepted
- [ADR 0024 — Config profiles are a file overlay with --profile and --dump-config](0024-config-profiles-are-a-file-overlay-with-profile-and-dump.md) — Accepted
- [ADR 0023 — REPL image/multimodal input via /attach and drag-drop to image_in](0023-repl-image-multimodal-input-via-attach-and-drag-drop-to.md) — Accepted
- [ADR 0022 — REPL multi-line input via Shift+Enter (Enter still submits)](0022-repl-multi-line-input-via-shift-enter-enter-still-submits.md) — Accepted
- [ADR 0021 — REPL block-level markdown renders in-place in repl.zig](0021-repl-block-level-markdown-renders-in-place-in-repl-zig.md) — Accepted
- [ADR 0020 — A workspace is a multi-root project whose board is its #general room](0020-a-workspace-is-a-multi-root-project-whose-board-is-its.md) — Accepted
- [ADR 0019 — Record stores are exposed over HTTP as one relay endpoint per tool](0019-record-stores-are-exposed-over-http-as-one-relay-endpoint.md) — Accepted
- [ADR 0018 — Each record store is its own guest over shared scaffolding](0018-each-record-store-is-its-own-guest-over-shared-scaffolding.md) — Accepted
- [ADR 0001 — The Kanban board is a chatroom, not a separate store](0001-board-is-a-chatroom.md) — Accepted
- [ADR 0002 — Private run todos and the shared board are separate mechanisms](0002-private-todos-vs-shared-board.md) — Accepted
- [ADR 0003 — Autoresearch is a generic harness loop](0003-autoresearch-is-a-generic-harness-loop.md) — Accepted
- [ADR 0004 — Providers are a native vtable, the pure codec is the only WASM-eligible slice](0004-providers-are-a-native-vtable-not-wasm.md) — Accepted
- [ADR 0005 — Auth is a strategy axis, separate from the wire kind](0005-auth-is-a-strategy-axis-separate-from-wire-kind.md) — Accepted
- [ADR 0006 — Fan-out concurrency belongs to the host, not to the guest](0006-fan-out-concurrency-belongs-to-the-host.md) — Accepted
- [ADR 0007 — Plugin manifests are declarative and unsigned; distribution is out of scope](0007-plugin-manifests-are-declarative-and-unsigned.md) — Accepted
- [ADR 0008 — The scheduler is driven by the system's cron, not by a clanker daemon](0008-the-scheduler-is-cron-driven-not-a-daemon.md) — Accepted
- [ADR 0009 — Scheduled entries fire on fixed UTC offsets, not on local time](0009-schedule-fires-on-fixed-utc-offsets.md) — Accepted
- [ADR 0010 — Eval kernels are opt-in, and sandboxed where a sandbox exists](0010-kernels-are-an-opt-in-unsandboxed-class.md) — Accepted
- [ADR 0011 — `ck_kernel` is a named host channel, not a `ck_exec` grant](0011-ck-kernel-is-a-named-host-channel.md) — Accepted
- [ADR 0012 — Goal draft, persistence, and execution are separate capabilities](0012-goal-draft-persistence-and-execution-are-separate.md) — Accepted
- [ADR 0013 — SIXEL precedes Unicode cells for mascot rendering](0013-sixel-precedes-unicode-mascot-fallback.md) — Accepted
- [ADR 0014 — Chat file uploads land in Knowledge through add_doc](0014-chat-uploads-land-in-knowledge.md) — Accepted
- [ADR 0015 — LLM I/O is journaled at the client tap, then optionally to Muninn](0015-llm-io-journal-to-muninn.md) — Accepted
- [ADR 0016 — First-run is one doctor verdict on existing empty surfaces](0016-first-run-readiness-verdict.md) — Accepted
- [ADR 0017 — Symlink traversal out of the sandbox root is an opt-in config flag](0017-sandbox-symlink-traversal-is-opt-in.md) — Accepted
<!-- inventory:adr:end -->
