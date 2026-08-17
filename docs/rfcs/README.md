# RFCs — requests for comment

An RFC presents a decision that has not been made yet: the options, what each
one implies over time, and a recommendation with a confidence score. It is the
step before an [ADR](../adrs/) — the ADR records what was chosen, this file
records why the alternatives lost. Not every ADR needs an RFC, and not every
RFC leads to one.

## Quick start

See what still needs deciding, and what was decided before:

```json
{"action":"list"}
```

Check what an RFC has to pin down before drafting one:

```json
{"action":"checklist","topic":"which HTTP client the proxy should use"}
```

Open a numbered scaffold, optionally seeded from a research note:

```json
{"action":"create","title":"HTTP client for the proxy","overview":"The proxy needs an HTTP client that works under the sandbox.","research":"docs/research/http-clients.md"}
```

Record the recommendation with its confidence:

```json
{"action":"recommend","path":"docs/rfcs/0007-http-client-for-the-proxy.md","recommendation":"Option A, std.http, with a review if the proxy ever needs HTTP/2.","confidence":7,"rationale":"No new dependency, and the missing features are not on the roadmap."}
```

All of these are actions of the `rfc` tool. Everything below is detail.

## What belongs here

- A choice between libraries, external tools, or services.
- An architectural decision with live alternatives — a boundary, a data format,
  an ownership split — where the reasoning has to survive the choice.
- A direction question with no technical dependency at all ("should clanker
  keep every tool sandboxed?"). These need less external search and more
  alternative perspectives; the options section still has to be real.

What does not belong: a decision already made (write the [ADR](../adrs/)),
a feature spec (a [PRD](../prds/)), or the evidence gathering itself (a
[research note](../research/)).

## Conventions

- Files are numbered: `NNNN-<short-title>.md`, allocated by the tool.
- Start from [TEMPLATE.md](TEMPLATE.md). The tool renders it, so template edits
  apply to every RFC created afterwards.
- Status is one of `draft`, `discussion`, `decided`, `deferred`, `withdrawn`,
  `superseded`. Set it with the tool's `status` action so the inventory below
  stays true.
- The options section must contain the status quo and at least one
  out-of-the-box candidate. Two obvious libraries is an unfinished search.
- The recommendation carries a confidence score from 0 to 10 and says what
  would move it. A recommendation with no stated confidence is an opinion.
- When an RFC is decided, write the ADR and link it under References. Leave the
  RFC in place; it is the record of the alternatives.

## Agent workflow

Search before drafting: `{"action":"search","query":"..."}` covers this
directory and the ADRs together, so a settled decision surfaces before it is
re-litigated. When the request is too vague to draft from, run `checklist` and
put its questions to the operator with `ask_user` rather than inventing a
scope.

An RFC is only as good as its options. When a [research note](../research/)
exists, pass it as `research` — the tool links it and lifts its option headings
in as stubs marked unverified. Those stubs are claims to check, not content:
re-verify each one against its source before it goes in the body, because the
note may be stale or may have been written for a different question.

Nothing links a note that was not passed. `create` therefore reports the notes
in [docs/research/](../research/) as `research_available` when it was given
none — every RFC in this directory was written that way, which is why none of
them link one. If a listed note covers the decision, recreate the RFC with
`research` set to its path rather than adding the reference by hand: the link
and the seeded option stubs come from the same read.

When there is no note, do the searching in this turn — the `research` tool's `sweep`, then
`fetch_web` on what looks promising. For a direction question with nothing to
search, look for alternative perspectives instead: prior art in comparable
projects, and the strongest case against the recommendation.

`append` and `update` are compare-and-swap; re-`open` after a conflict.

## Inventory

<!-- inventory:rfc:start -->
- [RFC 0013 — MCP client configuration: how clanker consumes external MCP servers](0013-mcp-client-configuration-how-clanker-consumes-external-mcp.md) — Decided
- [RFC 0012 — Named config profiles (--profile and --dump-config)](0012-named-config-profiles-profile-and-dump-config.md) — Decided
- [RFC 0011 — REPL image/multimodal input](0011-repl-image-multimodal-input.md) — Decided
- [RFC 0010 — REPL multi-line task input](0010-repl-multi-line-task-input.md) — Decided
- [RFC 0009 — REPL block-level markdown in the vaxis transcript](0009-repl-block-level-markdown-in-the-vaxis-transcript.md) — Decided
- [RFC 0009 — REPL block-level markdown rendering](0009-repl-block-level-markdown-rendering.md) — Draft
- [RFC 0008 — How an agent claims a shared resource before writing it](0008-claims-on-shared-resources.md) — Discussion
- [RFC 0007 — HTTP surface for the five record-store tools](0007-records-http-surface.md) — Decided
- [RFC 0006 — Where ck_cas lock sidecars live](0006-where-ck-cas-lock-sidecars-live.md) — Discussion
- [RFC 0001 — Workspace, room, board, and folder hierarchy](0001-workspace-room-board-hierarchy.md) — Decided
- [RFC 0002: Chat file upload into Knowledge / memory](0002-chat-upload-into-knowledge.md) — Decided (ADR 0014)
- [RFC 0003: Attachments on a goal card (files and links)](0003-goal-card-file-attachments.md) — Discussion
- [RFC 0004: Pipe LLM inputs and outputs into MuninnDB](0004-llm-io-into-muninndb.md) — Decided (ADR 0015)
- [RFC 0005: First-run onboarding](0005-first-run-onboarding.md) — Decided (ADR 0016)
<!-- inventory:rfc:end -->
