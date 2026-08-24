# Bug — The '## Blocked on' body became a fourth machine-read state signal with none of the invariants the other three have

## TL;DR

- **What failed:** A non-empty '## Blocked on' body now steers the improve loop's seeder, but nothing pins it against '## Status', the TL;DR '**Resolution:**' bullet or the inventory row, so a record can read Resolved and blocked at once. The related ambiguity — 'non-empty' not being measured against isPlaceholderBody — was fixed by PR #396; this half is not.
- **Impact:** A record can read Resolved and blocked at once with no check objecting, so it is either hidden from the improve loop forever while actually done, or advertised as done while still blocked. Report only; the check is unclaimed.
- **Resolution:** Open.

## Status

Open.

## Blocked on

## Symptom and impact

Two defects with one cause, both introduced when the `## Blocked on` convention
turned a prose section into a machine-read signal.

**1. Nothing pins a blocked body against the states that already exist.** A
record now declares its state in four places, not three: the TL;DR
`- **Resolution:**` bullet, the `## Status` section, its row in
`docs/reports/README.md`, and — since PR #395 — the body of `## Blocked on`,
which `src/improve/backlog.zig` reads to decide whether to seed the record to
the autonomous improve loop. The first three are kept in step by tooling and
convention; the fourth is checked by nothing. `Resolved` and "blocked" are
contradictory, and a record can hold both with no check objecting.

The consequence is not cosmetic, and it goes wrong in both directions:

- Resolved plus a stale blocked body: the fix landed, the record is done, and
  the seeder still skips it forever. Harmless for the loop, but the record is
  now permanently invisible to it, so a reopen would not be picked up either.
- A blocked body plus a `Resolved` that was written optimistically: the store
  advertises the work as finished while the blocker that actually prevents it
  is still stated two sections below. Anyone reading the inventory row or the
  TL;DR — which the store tells every reader to trust first — is told the
  wrong thing.

**2. "Non-empty body" was ambiguous against `isPlaceholderBody`.** Fixed by
PR #396 — see `## Follow-up`; described here as it stood when this record was
filed. For the skip predicate to be correct, "non-empty" has to mean non-empty
*after* `isPlaceholderBody` (`tools/zig/doc_scaffold.zig`), which since PR #388
counts a body made only of `- … none yet` list items as empty. `blockedOn` in
`src/improve/backlog.zig` did not: it returned the first non-blank line of the
section, whatever that line said.

That was latent rather than live, because `reports create` writes the section
truly empty. It would have become real the moment anyone tightened the scaffold
to seed a placeholder line there — and that is not hypothetical, it is precedent: the
same scaffold seeds `## References` with `- Investigation: none yet`, and that
exact pattern made `## References` structurally unfillable until PR #388 taught
`isPlaceholderBody` about it. Repeated under `## Blocked on`, every new report
would have read as blocked from birth, permanently hidden from the improve loop
with no operator ever having stated a blocker.

## Reproduction

Both are read off the tree at `58e65e22` (the PR #395 merge); neither needs a
live run.

**Finding 1 — no check exists.** Write a record whose `## Status` reads
`Resolved.`, whose TL;DR `- **Resolution:**` bullet says the same, and whose
`## Blocked on` body names a blocker. Then run the full gate:

```
zig build && zig build tools && ./zig-out/bin/clanker gate
```

All twelve checks pass. `src/gate/checks.zig` has no check that reads
`## Blocked on` at all, so there is nothing for the contradiction to trip.

**Finding 2 — the predicates disagreed.** As of `58e65e22`, `blockedOn` in
`src/improve/backlog.zig` was a plain line scan: it tracked whether the current
`## ` heading was `blocked on` and returned the first line with `line.len > 0`.
Given a body of `- Investigation: none yet` it returned that line, so its
caller skipped the record. Handed the same body, `isPlaceholderBody` in
`tools/zig/doc_scaffold.zig` returned true — the body is empty. Two predicates,
one question, opposite answers. PR #396 closed that gap.

Current state of the store, for the record: the convention is back-filled on
exactly two records, one `## Blocked on` heading each and no duplicates —
`docs/reports/bugs/2026-08-24-gemini-thinking-row-inert.md` and
`docs/reports/bugs/2026-08-23-anthropic-wire-gets-openai-reasoning-effort.md`.
Neither is Resolved, so nothing in the store is currently inconsistent. This
report is about the missing invariant, not a live contradiction.

## Root cause

The `## Blocked on` convention was added as prose and then given a consumer,
without the step in between of giving it the invariants its three siblings
already have.

The three existing state signals each earned their guardrails from a bug. The
docstring on `replaceTldrField` (`tools/zig/doc_scaffold.zig`) records why: a
status change used to write `## Status` and the inventory row but not the TL;DR
bullet, so a fixed bug still opened with `- **Resolution:** Open.` — the one
line every reader is told to trust first. The fix was to make one writer own
all three, and `clanker reports status` is now that writer.

`## Blocked on` skipped that whole arc. PR #395 added it in two places that
never meet:

- `tools/zig/reports.zig:575` scaffolds the empty heading from a hardcoded
  string literal in `create`. Note that `docs/reports/bugs/TEMPLATE.md` also
  documents the section, but `create` does not read TEMPLATE.md — the literal
  is the only thing that shapes a new record, and the template is
  documentation that happens to agree with it.
- `src/improve/backlog.zig` reads the body to decide seeding.

So the section is written by one component, interpreted by another, and owned
by neither. No writer sets it alongside the other three the way
`reports status` does; no reader cross-checks it against them. That is the
whole of finding 1.

Finding 2 is the same gap seen from the reader's side. `blockedOn` had to answer
"is this body empty?" and answered it locally with a line scan, because the
existing answer to that question lives in a different module —
`isPlaceholderBody` is a private fn in `tools/zig/doc_scaffold.zig`, on the
tooling side of the tree, not the `src/improve` side. Two independent notions
of "empty" for the same markdown is exactly the drift the missing invariant
would have caught.

## Resolution

Partial, and none of it from this record. Finding 2 was fixed by PR #396; this
change filed no code for it. Finding 1 — the consistency check — is still
unbuilt and unclaimed, so the record stays `Open.` until it exists. See
`## Follow-up` for the shape.

## Verification

Everything above was read off the tree at `58e65e22`, not inferred:

- `tools/zig/reports.zig` — `create` writes the `## Blocked on` heading from a
  hardcoded literal; `docs/reports/bugs/TEMPLATE.md` is not read by `create`.
- `src/improve/backlog.zig` — at `58e65e22`, `blockedOn` was a
  first-non-blank-line scan with no placeholder handling; its caller skips the
  record whenever it returns non-null. PR #396 added the placeholder skip; the
  caller behaviour is unchanged, so finding 1 is untouched by it.
- `tools/zig/doc_scaffold.zig` — `isPlaceholderBody` accepts a body of only
  `- … none yet` items as empty; it is private to that module.
- `src/gate/checks.zig` — no check mentions `Blocked on`. The twelve gate
  checks were run green on the branch carrying this record, which is itself the
  demonstration that nothing catches the contradiction.

Not verified here: no live model run, and PR #396 — the fix for finding 2 — was
read as a merged diff, not exercised by this session.

## Follow-up

Neither finding is implemented here. This record and a two-line cross-reference
added to the `replaceTldrField` docstring in `tools/zig/doc_scaffold.zig` are
the whole of this change. Stated plainly so nobody reads a filed report as a
shipped fix: **the consistency check of finding 1 is claimed by no one** —
not by this session, and not by the peer session that built the seeder in
PR #395.

**Finding 1 — the consistency check. Unclaimed; planned, not built.** The
natural shape is a `depPatchesGate`-shaped check
(`src/gate/checks.zig:1736` is the model: read the tree, compare two sources
that must agree, return a `GateResult` naming which record disagreed) living in
`tools/zig/doc_scaffold.zig` beside the other record-shape predicates, wired
into the gate as a thirteenth check. What it should pin, at minimum: a record
whose `## Blocked on` body is non-empty must not read `Resolved` in `## Status`,
in its TL;DR `- **Resolution:**` bullet, or in its `docs/reports/README.md`
inventory row. The detail string should name the offending path and which of
the four signals disagreed, the way the existing gates do, rather than a bare
count.

The `## Planned` item in `docs/ROADMAP.md` is where the loop can find it; it
names both candidate homes and records that neither session claimed the
implementation. Read the requirement off that item rather than this paragraph
if the two ever drift. It is a queued intention, not an implementation.

**Finding 2 — the placeholder ambiguity. Fixed by PR #396.** A peer session
landed `isNoneYetLine` in `src/improve/backlog.zig`, so `blockedOn` now skips
`- … none yet` items and a body of nothing but those reads as empty, mirroring
`isPlaceholderBody`. It carries a cross-reference comment recording that the
predicate is mirrored rather than imported because `tools/zig/doc_scaffold.zig`
is guest code, plus tests on both sides of the boundary — including that a real
line after a placeholder still blocks. Attributed, not independently verified
here: the change is that peer PR's, not this session's.

What remains is the `tools/zig` side. The scaffold in `tools/zig/reports.zig`
is still free to seed a placeholder line under `## Blocked on`, and the two
definitions of "empty" are two definitions in two modules that agree by hand
rather than by construction. The durable fix is one shared predicate; the
landed one is a deliberate faithful copy.

Whoever picks up finding 1 should consider folding the shared-predicate cleanup
into it, since a check that reads all four signals needs exactly that
predicate anyway.

## References

- Convention added: PR #395 — `## Blocked on` scaffolded by
  `tools/zig/reports.zig`, honoured by `src/improve/backlog.zig`, documented in
  `docs/reports/bugs/TEMPLATE.md`.
- Placeholder precedent: PR #388 — `isPlaceholderBody` in
  `tools/zig/doc_scaffold.zig` taught that `- … none yet` counts as empty,
  after `## References` proved unfillable.
- The three-signal rule: the `replaceTldrField` docstring in
  `tools/zig/doc_scaffold.zig`, extended alongside this record to name the
  blocked body as the fourth.
- Gate shape to copy: `depPatchesGate` in `src/gate/checks.zig`.
- Back-filled records carrying the convention:
  `docs/reports/bugs/2026-08-24-gemini-thinking-row-inert.md`,
  `docs/reports/bugs/2026-08-23-anthropic-wire-gets-openai-reasoning-effort.md`.
- Finding 1 as a planned item: the `## Planned` entry in `docs/ROADMAP.md`,
  added by PR #396.
- Finding 2 fix: PR #396 — `isNoneYetLine` in `src/improve/backlog.zig` makes
  `blockedOn` read a placeholder-only body as empty.
