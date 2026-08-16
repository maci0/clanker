# Bug — research status action never updates the README inventory entry

## TL;DR

- **What failed:** The research tool's `status` action rewrites a note's `## Status` line but not its `docs/research/README.md` inventory entry, which `create` hardcodes as `Draft`, so the index a reader skims permanently disagrees with every note it lists.
- **Impact:** Every research note is listed as `Draft` forever, including notes that are Current, Stale, or Superseded. A reader who trusts the index reads a finished note as a draft and a stale note as a live one.
- **Resolution:** Open.

## Status

Open.

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

Not yet fixed. The shape of the fix: give `status` the same inventory pass
`create` has, replacing the status field of the entry whose link matches `path`,
and warn rather than fail when the entry or the markers are absent (matching
`create`'s existing behaviour at `:749`). Both writes are compare-and-swap, so a
concurrent edit to either file must re-read and retry rather than overwrite.

The same question should be asked of the `reports` tool, which maintains two
inventories of its own by the same pattern; it was not checked here.

## Verification

None yet. A fix is verified when `create` followed by `status current` leaves the
note header and its inventory line reading the same word, and when `status
superseded` on a note whose inventory entry has been hand-edited still lands on
the right row.

## Follow-up

- Check whether `docs/reports/README.md` and `docs/runbooks/README.md` have the
  same desync through the `reports` tool.
- The inventory status is derived data. A cheaper fix than keeping two copies in
  step is to have the listing read each note's `## Status` line at render time,
  which removes the class of bug rather than patching this instance.

## References

- Investigation: none; root cause was read directly from `tools/zig/research.zig`.
- Surfaced while writing [Decentralized state store for isolated worktrees and mesh peers](../../research/decentralized-state-store.md).
