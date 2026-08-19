# Research — Stage-1 spike — replicating one owner stream between two instances

## Status

Draft — searched 2026-08-19.

Research is evidence, not a decision: it records what exists, how good it is,
and how confident the finding is. The decision that follows belongs in an
[RFC](../rfcs/) and, once made, an [ADR](../adrs/).

## Question

Does fan-out plus id-dedup, extended with a per-stream sequence cursor, replicate one owner's append-only stream (the improvements ledger's shape) between two clanker instances with no loss, no duplicates and order preserved — including backfill after downtime — and what does delivery cost?

## TL;DR

This note is the protocol for RFC 0019's stage-1 spike (option T), and the
place its results land. It is a research note, not a PRD, on purpose: the
spike produces *evidence* for a decision RFC 0019 has not made — a PRD is
what stage 1 becomes if the spike is green.

- **What is being tested:** that fan-out plus id-dedup — the mechanism
  `src/peers/chatrooms.zig:990` `fanOut` already uses for chat — extends to
  an owner's append-only state stream once a **per-stream sequence cursor**
  is added. The cursor is the whole design delta: chat tolerates gaps, a
  state stream must detect and fill them.
- **The three journeys:** burst convergence (1,000 records, zero loss, zero
  duplicates, order preserved), backfill after downtime (replica down for 200
  appends, catches up unaided on restart), and hostile wire input (duplicates
  and out-of-order deliveries held off by the cursor).
- **Correctness gates the spike; performance is reported, not gated.**
  Append-to-visible latency (p50/p99) and time-to-converged are measured and
  recorded here for the RFC.
- **Timebox: three days.** Phases 3 (the `ck_state` seam) and 4 (the
  open-question-14 hash chain) are cut first; the spike's answer stands on
  phases 0–2.

## Design

**Stream namespace.** A stream is `(owner instance id, stream name)`. The
owner is the only writer — the home-instance rule (PRD 0011) — and assigns a
dense per-stream sequence number at append. A replica stores the stream under
`state/mesh/<owner-id>/<stream>`, the layout PRD 0011 already gives session
replicas. The pooled fleet view is the union of all owners' streams; nothing
ever merges.

**Record shape** (fixed header + payload, the option-S/TigerBeetle discipline
without the double-entry framing):

| Field | Meaning |
|---|---|
| `owner` | owning instance id |
| `stream` | stream name, e.g. `improvements` |
| `seq` | dense per-(owner,stream) sequence, assigned by the owner |
| `id` | the record's own id when it has one (`imp-<id>`), else derived |
| `ts_ms` | owner's append time |
| `payload` | the JSONL line, verbatim |
| `prev_hash` | phase 4 only — hash of the previous record's header+payload |

**Delivery.** Owner appends locally, then fans out to each `[[peers]]` entry
via the sandboxed `peers` guest — a new `state_fanout` action beside
`chat_fanout` (`tools/zig/peers.zig:74`), delivering to `POST
/api/state/append`, under the same `network_from_config` gate and host-side
per-peer backoff. The replica accepts a record only at `cursor + 1`; anything
ahead of that triggers a backfill pull, anything at or behind the cursor is a
duplicate and dropped.

**Backfill.** `GET /api/state/since?owner=&stream=&after=<seq>` serves a
page-capped slice of the owner's stream. A replica pulls on serve start and
on gap detection. This is the piece chat does over the mesh wire
(`CHAT_SYNC`) and the fan-out path currently lacks — the spike builds it
HTTP-only, so no mesh socket is required.

**Known size constraint.** Guest arenas and `max_fs_bytes`
(`src/sandbox/host.zig:257`) are 1 MiB, so fan-out and backfill batches must
stay under that; improvements records are ~1–2 KB, so pages of a few hundred
records fit. The spike asserts the page cap rather than discovering it.

## Plan — phases that name files

**Phase 0 — pure logic, failing tests first (½ day).**
`tools/zig/statestream_logic.zig`, registered in `host_tested_helpers` in
`build.zig` (the `schedule_cron` pattern): record encode/decode, contiguous
cursor computation, dedup and gap classification (behind / next / ahead),
page slicing, and the phase-4 `prev_hash` verify. Unit tests written first
and confirmed to fail for the intended reason.

**Phase 1 — host-side replication between two serves (1 day).**
`src/peers/statestream.zig` (must not import `sandbox/` — the chatrooms
rule): owner append (assign seq, append to the local stream file, hand to
fan-out), replica receive (cursor check, append or trigger backfill),
backfill client. `tools/zig/peers.zig` gains `state_fanout`. `src/cli.zig`
gains the two routes: `POST /api/state/append`, `GET /api/state/since`
(page-capped; refusals via `toolRefusalStatus` conventions).

**Phase 2 — the two-instance e2e and the measurements (1 day).**
`tests/e2e/statestream_spike_test.zig`, registered in `tests/e2e/main.zig`:
two serves on loopback with distinct `instance.id`, web UI port and
`agent.state_dir`, `[[peers]]` pointing at each other (the documented
two-instances-on-one-host setup; no mesh socket). Three journeys:

1. **Burst:** 1,000 appends on A; assert B's replica is record-for-record
   equal, zero duplicates, order preserved. Record p50/p99 append-to-visible
   latency.
2. **Backfill:** stop B; 200 appends on A; restart B; assert 200/200 arrive
   with no manual step. Record time-to-converged.
3. **Hostile wire:** inject duplicates and an out-of-order delivery at
   `/api/state/append`; assert the cursor holds and the file never gains a
   gap or a duplicate.

Payload corpus: a fixture copy of the real shared improvements ledger
(1,139 lines as of 2026-08-18), so record sizes are realistic.

**Phase 3 — the `ck_state` seam (½ day, cut first).**
A privileged channel in `src/sandbox/host.zig` gated on `tool_self_name`
(the `ck_chat` precedent; the sandbox host may import peers code — chatrooms
already crosses that way), spike ops `append` and `read_since`. Proves a
guest reaches the stream with no filesystem path and no `safeJoinSecure`
involvement — the RFC's "behind `ck_state`". The measurements do not depend
on this phase; if the timebox runs out, the spike's answer stands without it
and the seam becomes part of stage-1-proper.

**Phase 4 — optional, open question 14 (½ day, cut second).**
`prev_hash` in the header, verified by the replica on append and by backfill
pages; measure the per-record cost. One field and one check — the cheap form
of the ledger family's tamper evidence.

**Explicit non-goals.** Wiring the real improve-ledger append sites
(`src/improve/history.zig`, `reverts.zig`) — the synthetic driver plus the
real-ledger fixture answer the question without touching the improve engine.
No retention or trim policy, no multi-writer, no contended documents (that is
stage 2), no CRDT, no merge, no change to chat behavior.

## How to run

The e2e is the primary runner:

```bash
zig build e2e
```

Manual two-instance runs use the documented one-host setup — two serves with
distinct `instance.id`, web UI port and `agent.state_dir`, each listed in the
other's `[[peers]]`; key names per `docs/configuration.md` with
`src/config.zig` authoritative. To hand the implementation to the agent
instead of doing it by hand, save it as a goal and start the loop:

```bash
clanker add-goal "T stage-1 spike per docs/research/t-stage1-stream-replication-spike.md: phases 0-2 green, measurements appended to the note"
```

```bash
clanker run --goal <id>
```

## Success and failure criteria

**Green (all three journeys):** zero lost records, zero duplicates, order
preserved; backfill completes unaided. Latency and catch-up numbers are
whatever they are — recorded, not gated.

**What a red result means for RFC 0019:** a correctness failure the cursor
design cannot fix inside the timebox, backfill needing manual repair, or the
fan-out path proving unfit for non-chat payloads pushes tier 2 back toward
option J — the RFC's Why-this-confidence names exactly this spike as its
first raise/sink.

**Where results go:** appended to this note under Results, with the commands
that produced each number; then RFC 0019's recommendation section is
revisited. A green spike makes stage 1 a feature: write its PRD then, not
before. Per the operator's packaging direction (2026-08-19), the productized
spine is founded as a standalone, publicly released Zig project offering
clanker an embeddable library and/or a service API — see option T's Packaging
paragraph in [the state-store note](decentralized-state-store.md); the spike
code itself stays throwaway in clanker's tree either way.

## Results

Open — the spike has not been run.

## Open questions

- Should the replica buffer ahead-of-cursor records or drop them and rely on
  backfill? The spike starts with drop-and-backfill (simpler, idempotent);
  the buffer is an optimization to measure only if latency demands it.
- Does `state_fanout` share the peers guest's backoff bookkeeping with chat,
  or keep its own? Spike shares it; stage 1 proper should decide.

## References

- [RFC 0019 — Shared state store](../rfcs/0019-shared-state-store.md) — the
  decision this spike feeds; its next-steps item names this note.
- [Research — Decentralized state store](decentralized-state-store.md) —
  option T (the staged spine) and option S (the record-header discipline).
- [PRD 0011 — clanker mesh](../prds/0011-clanker-mesh.md) — home-instance
  rule, `state/mesh/<home-id>/` replica layout, `[[peers]]`.
- `src/peers/chatrooms.zig:990` (`fanOut`), `tools/zig/peers.zig:74`
  (`chat_fanout`), `src/sandbox/host.zig:257` (`max_fs_bytes`) — read
  2026-08-19 in this checkout.
