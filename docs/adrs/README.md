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
- Status is one of `Proposed`, `Accepted`, `Superseded`, `Deprecated`. Set it
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
