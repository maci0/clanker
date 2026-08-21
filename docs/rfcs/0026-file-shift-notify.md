# RFC 0026 — How live sessions are notified when a file they read is edited

## Status

Decided — 2026-08-21. ADR 0038

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

jcode notifies agent B when agent A edits a file B has read. ck_swarm members cannot see each other; the concurrent-sessions runbook is recovery after damage. Decide whether live sessions get a typed file-touch notify.

**Decision to make.** How are live sessions notified when a file they have read is edited by another session on the same checkout?

**Why now.** Five sessions on one checkout corrupted each other's work (2026-08-16). The runbook is recovery. RFC 0008 is git claims, not a read-set. jcode notifies on file-shift. Inventory: docs/research/jcode-features.md.

**Drivers.** No locks (jcode and RFC 0008 both optimistic). Notify is advisory, not a block. ck_swarm members cannot see each other; this is not a ck_swarm rewrite. Same-checkout sessions, not mesh-wide (PRD 0011 file share is Phase 3).

**Out of scope.** Git index claims (RFC 0008). Mesh file replication (PRD 0011). Making ck_swarm members share a transcript.

## Current state

Concurrent sessions share a checkout. File writes go through guests (ck_fs_write / edit_file). Nothing records which session last read a path. The runbook tells humans to talk. chat_dm exists if they think to use it. Files: a host read-set in sandbox/host.zig or agent session, notify via existing ck_chat or a tool result injection at a safe point.

## Options considered

One subsection per option. Include the status quo ("do nothing / keep the
workaround") and at least one *out-of-the-box* option — something already in
the tree, a standard-library or OS primitive, an existing tool used differently,
or buying instead of building. An RFC with only the two obvious libraries has
not finished looking.

### Option A — Host read-set per session; on write, notify other live sessions that read the path

What it is: sandbox records paths a session successfully read. A write to one of those paths injects a short advisory (path + writer session id) into the other session's next tool-result or turn, fail-open. Pure function whoToNotify(read_sets, path, writer) is host-tested. No lock.

Maturity: jcode file-touch; we have the incident as proof of need.

How it would fit: src/sandbox/host.zig or agent session table; not ck_swarm. Phase 1 is the helper + unit tests; phase 2 wires writes.

Pros: optimistic; uses existing sessions; advisory.

Cons: false positives on every write; in-process only unless serve mediates.

Cost to adopt: helper then wiring. Cost to leave: stop recording reads.

Evidence: SWARM_ARCHITECTURE.md File Touch; 2026-08-16 bug report.

### Option B — Require RFC 0008 claims before any write

What it is: wait for the claims RFC instead of notify.

How it would fit: that RFC is still discussion.

Pros: stronger than notify.

Cons: different question (who may write) and still open. Notify is complementary.

Cost to adopt: blocked on RFC 0008. Cost to leave: n/a.

Evidence: docs/rfcs/0008-claims-on-shared-resources.md.

### Option C — status quo

What it is: runbook plus hope agents DM.

Pros: no false notify noise.

Cons: damage first, talk second. The incident already happened.

Cost to adopt: zero; keep the runbook.

Evidence: docs/runbooks/concurrent-agent-sessions-on-one-checkout.md.

### Option D — out of the box: one-worktree-per-writer (RFC 0008 option already named)

What it is: isolation instead of notify.

How it would fit: improve-self already uses worktrees; interactive sessions do not.

Pros: no overlapping writes.

Cons: does not help two sessions that must share a tree; git worktrees are heavy for REPL.

Cost to adopt: operator convention. Cost to leave: n/a.

Evidence: RFC 0008 worktree option; src/improve/worktree.zig.

## Implications by horizon

What following each candidate means over time. Where the options differ only in
one horizon, say so — that is usually the deciding fact.

### Short term (this release / 0–3 months)

If A: whoToNotify is testable immediately; wiring can follow. If B: wait on claims. If status quo: next collision is the runbook again. If D: REPL sessions still share a tree.

### Medium term (3–12 months)

If A: serve can fan the same event to another process on the same checkout. If B: claims may land independently.

### Long term (12+ months)

If A: notify stays even after claims exist (read-set is not a lock). If C: we keep documenting recovery.

## Recommendation

**Recommended option:** Option A: host read-set plus advisory file-touch notify; not a lock and not a ck_swarm rewrite

**Confidence:** 7/10

**Why this confidence.** What the score is resting on, and what would move it:
the specific evidence that would raise it, and the finding that would sink the
recommendation entirely.

**Rationale.** The incident is real and claims (RFC 0008) are a different question still open. Worktrees do not help two interactive sessions on one tree. Phase 1 is the pure whoToNotify helper so this is reversible.

**Reversibility.** How hard it is to undo, and the point of no return (a
migrated data format, a public API, a dependency baked into the build).

## Open questions

Questions whose answers could change the recommendation, each with who or what
can answer it. Keep them here until they are answered; do not silently drop the
ones that turned out to be inconvenient.

## Next steps / action items

- [ ] What happens if this recommendation is accepted, in order.
- [ ] The experiment or spike that would settle an open question above.
- [ ] Who is being asked for comment, and by when.
- [ ] Write the ADR once the decision is made.

## References



- Research: [jcode feature inventory](../research/jcode-features.md).
- RFC 0008, PRD 0008, ADR 0006. Bug 2026-08-16 concurrent sessions. jcode SWARM_ARCHITECTURE.md.

## Appendix

Optional: benchmark output, diagrams, licence texts, transcript excerpts, and
anything else too long for the body but needed to re-check the reasoning.
