# Bug — research status action never updates the README inventory entry

## TL;DR

- **What failed:** The research tool's `status` action rewrites a note's `## Status` line but not its `docs/research/README.md` inventory entry, which `create` hardcodes as `Draft`, so the index a reader skims permanently disagrees with every note it lists.
- **Impact:** Every research note is listed as `Draft` forever, including notes that are Current, Stale, or Superseded. A reader who trusts the index reads a finished note as a draft and a stale note as a live one.
- **Resolution:** Fixed on 2026-08-16 with a shared inventory-status helper used by research, rfc and reports.

## Status

Resolved on 2026-08-16. doc_scaffold.setInventoryStatus now carries the index on every status change in research, rfc and reports; verified end to end with a probe note and six unit tests.

## Symptom and impact

`docs/research/README.md` carries the inventory that `create` writes and that the
README presents as the list of notes. The status shown there is fixed at the
moment of creation and never changes again.

The failure is silent and one-directional: the note itself is correct, so nothing
looks broken when you open one. Only the index lies, and the index is what a
reader consults first — that is the whole reason it exists.

The `superseded` case is the damaging one. A note that has been replaced still
appears in the inventory as `Draft`, indistinguishable from work in progress, so
the reader has no signal that a newer note exists.

## Reproduction

Create a note and set it Current:

```sh
clanker run 'Call the research tool once with {"action":"create","title":"Repro","question":"Does the inventory follow?"} and print the output.'
clanker run 'Call the research tool once with {"action":"status","path":"docs/research/repro.md","status":"current"} and print the output.'
```

Both calls return `{"ok":true,...}`. The note's own header now reads
`Current — searched <date>.` while its inventory line in
`docs/research/README.md` still reads `— Draft`.

Observed on 2026-08-16 while writing
[decentralized-state-store.md](../../research/decentralized-state-store.md): the
`status` call reported success, the note header changed, and the inventory line
had to be corrected by hand.

## Root cause

Two independent sites, neither of which knows about the other.

`create` writes the inventory entry with a literal status
(`tools/zig/research.zig:723`):

```zig
.{ .name = "status", .value = "Draft" },
```

`status` (`tools/zig/research.zig:900-929`) reads the note, calls
`doc.replaceFirstLine(... "## Status", line)`, and writes the note back through
`lib.fsWriteIf`. It never opens `docs/research/README.md`, so there is no code
path from a status change to the inventory at all. `insertInventory`
(`:768`) is reachable only from `create`.

The tool is otherwise careful about this class of problem — `create` already
warns when the inventory cannot be updated and tells the caller to add the link
by hand (`:749`) — so the gap is a missing case rather than a missing concept.

## Resolution

Fixed on 2026-08-16, as a shared helper rather than one patched call site.

`doc_scaffold.setInventoryStatus` rewrites the status field of the inventory
entry whose link matches, splitting at the em dash *after* the link so a title
containing one survives. `research`'s `status` action now calls it and reports
`indexed`, warning rather than failing when the entry or the markers are
absent, matching `create`. The same helper closed the two other instances of
this class: the `rfc` tool, whose status action told the caller to update the
index by hand, and the `reports` tool, which had no status action at all and so
left every record's inventory line at its creation value.

The original shape of the fix, kept for the record: give `status` the same inventory pass
`create` has, replacing the status field of the entry whose link matches `path`,
and warn rather than fail when the entry or the markers are absent (matching
`create`'s existing behaviour at `:749`). Both writes are compare-and-swap, so a
concurrent edit to either file must re-read and retry rather than overwrite.

The same question should be asked of the `reports` tool, which maintains two
inventories of its own by the same pattern; it was not checked here.

## Verification

Verified end to end through `clanker research`, the CLI surface added in the
same change:

- `create probe-inventory-sync` wrote the note and a `— Draft` inventory line.
- `status ... current` left both the note header and the inventory line reading
  `Current`.
- `status ... superseded` moved both to `Superseded`.
- The probe note and its inventory line were then removed.

`doc_scaffold.zig` carries six unit tests for the helper: the matching entry
only, an em dash inside the title, an entry with no status field yet, missing
markers, a missing entry, and an entry past the end marker.

## Follow-up

- Checked: `docs/reports/README.md` had exactly the same desync, and worse —
  the `reports` tool had no status action, so three resolved bugs and one
  resolved investigation were still listed as Open/Investigating. The tool now
  has a `status` action (record and inventory in one call), it is on the CLI as
  `clanker reports status <path> <state> <note>`, and the stale lines were
  corrected. `docs/runbooks/README.md` is not affected: a runbook inventory
  line carries a summary rather than a status.
- A third copy of the status still lives in each record's TL;DR
  (`- **Resolution:** ...`). Nothing keeps it in step; it is hand-written prose
  today.
- The inventory status is derived data. A cheaper fix than keeping two copies in
  step is to have the listing read each note's `## Status` line at render time,
  which removes the class of bug rather than patching this instance.

## References

- Investigation: none; root cause was read directly from `tools/zig/research.zig`.
- Surfaced while writing [Decentralized state store for isolated worktrees and mesh peers](../../research/decentralized-state-store.md).
