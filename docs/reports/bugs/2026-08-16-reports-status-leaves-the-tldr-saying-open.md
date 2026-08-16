# Bug — reports status updates the Status section but not the TL;DR

## TL;DR

- **What failed:** clanker reports status <path> resolved rewrites the record's ## Status section and its inventory row, but leaves the TL;DR line '- **Resolution:** Open.' untouched. Three bug reports currently say Resolved in Status and Open in the TL;DR, which is the first thing CLAUDE.md tells an agent to read, so a fixed bug reads as unfixed.
- **Impact:** Three of fourteen bug reports currently contradict themselves. An agent that reads the TL;DR — which is what CLAUDE.md instructs — sees `Open` on a bug that was fixed and verified hours earlier, and the cost of that is re-diagnosing finished work, which is the exact failure the status action was added to prevent.
- **Resolution:** Resolved on 2026-08-16. status now writes all three copies via doc_scaffold.replaceTldrField, and an investigation's Finding bullet too while it still holds the scaffold placeholder; verified by re-stating the three contradictory records and by a throwaway investigation, with 41/41 doc_scaffold tests and zig build test green

## Status

Resolved on 2026-08-16. status now writes all three copies via doc_scaffold.replaceTldrField, and an investigation's Finding bullet too while it still holds the scaffold placeholder; verified by re-stating the three contradictory records and by a throwaway investigation, with 41/41 doc_scaffold tests and zig build test green

## Symptom and impact

A record carries its state in three places: the TL;DR `Resolution` bullet, the
`## Status` section, and the inventory line in `docs/reports/README.md`.
`clanker reports status` writes the second and the third. The first keeps
whatever `create` put there, which for a bug is `Open.` and for an
investigation is `Pending.`

Three records are in that state right now:

```bash
grep -l "Resolution:\*\* Open." docs/reports/bugs/*.md
```

- `2026-08-16-clanker-commit-tool-output-has-no-text-field.md`
- `2026-08-16-guest-writes-refused-under-symlinked-state.md`
- `2026-08-16-state-backup-aborts-on-checkout-local-agents.md`

All three say `Resolved on 2026-08-16` under `## Status` and `Open.` in the
TL;DR. The records that read correctly were edited by hand.

## Reproduction

```bash
clanker reports create bug 2026-08-16-example "Example" "Something failed."
clanker reports status docs/reports/bugs/2026-08-16-example.md resolved "fixed in abc1234; the suite passes"
clanker reports open docs/reports/bugs/2026-08-16-example.md
```

`## Status` reads `Resolved on 2026-08-16. fixed in abc1234; the suite
passes`, the inventory line reads `Resolved`, and the TL;DR still reads
`- **Resolution:** Open.`

## Root cause

`status` in `tools/zig/reports.zig:243` rewrites exactly one section:

```zig
if (!try doc.replaceFirstLine(&updated.writer, text, "## Status", line))
    return lib.fail(out, "the record has no '## Status' section; add one or edit it with update");
```

and then calls `setInventoryStatus` for the index. Nothing touches the TL;DR.

The comment above that function already names the failure mode it was written
to fix — "those are two copies of one fact, and before this action only
`create` ever wrote the index one" — and the fix stopped one copy short.
`create` writes all three (`tools/zig/reports.zig:395`), so the third copy
exists from the moment the record does.

## Resolution

`status` now writes all three copies. `doc_scaffold.replaceTldrField` rewrites
one `- **Field:** ...` bullet, scoped to the `## TL;DR` section so a long
record that quotes its own bullets while explaining them is not rewritten
lower down. `reports.zig` calls it with the same line it puts under
`## Status`, so the two cannot drift.

An investigation carries a second state bullet. Its TL;DR is `Question` /
`Finding` / `Resolution`, and `Finding` starts as the scaffold placeholder
`Investigating.` — so resolving one used to leave the record saying
`Investigating.` one bullet above `Resolved`. It is rewritten only while it
still holds that exact placeholder: once someone has written the actual
finding, a status change must not overwrite the answer the record exists for.
`doc_scaffold.tldrField` is the reader that makes that distinction possible.

A record with no TL;DR bullet is not an error. One whose summary was reshaped
by hand still deserves a status change, so the write falls back to the
Status-only text rather than refusing.

The field name is a parameter rather than a constant so one helper covers
both bullets of both scaffolds.

## Verification

Three host tests in `doc_scaffold.zig` — the bullet is rewritten and its
neighbours are not, a missing bullet and a missing TL;DR are both reported
false, and a matching bullet outside the TL;DR is left alone. Written before
the function existed and confirmed failing with "use of undeclared identifier
replaceTldrField", then passing: `zig test tools/zig/doc_scaffold.zig` is
40/40.

The real check is the three records that exposed this. With the rebuilt guest,
each was re-stated with the note it already carried:

```bash
clanker reports status <path> resolved "<the note already in ## Status>"
```

All three now read `Resolved on 2026-08-16` in both the TL;DR and `## Status`,
and no bug report is left saying Open in one place and Resolved in the other.

`zig build tools` and the full `zig build test` both exit 0 after the change.

## Follow-up

The other two stores were checked and need nothing, so the class is closed
rather than one instance of it: RFCs have no `## TL;DR` section at all
(neither `docs/rfcs/TEMPLATE.md` nor RFC 0001 defines one), and a research
note has one whose bullets are bolded claims ending in a period rather than
`- **Field:** value` pairs — its status lives only in `## Status` and the
inventory row, both of which that action already writes.

The general shape is worth naming: three copies of one fact, added one at a
time, each fix stopping at the copy the author was looking at. A record has
one state, and a single writer should set every place it appears.

## References

- `tools/zig/reports.zig` `status` — the action, and the comment above it that
  names the two-copies problem this one extends to three.
- `tools/zig/doc_scaffold.zig` `replaceTldrField` — the helper and its tests.
- `tools/zig/reports.zig:395` `create` — writes all three copies, which is why
  the third exists from the moment the record does.
- Investigation: none; the trace is in this record.
