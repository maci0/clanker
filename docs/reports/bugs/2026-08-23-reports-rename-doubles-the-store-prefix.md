# Bug — reports rename prints leftover-reference paths with the store prefix twice

## TL;DR

- **What failed:** `collectReferences` (`tools/zig/reports.zig:464`) joins the store root onto every grep hit unconditionally, but `ck_fs_grep` already returns paths rooted at the repository. So a record that still names the renamed one is reported as `docs/reports/docs/reports/bugs/<name>.md` -- a path that does not exist and cannot be opened or pasted into a `read_file` call.
- **Impact:** The one output `rename` exists to produce is the list of inbound references a caller must fix by hand, and every entry on it is wrong. Anyone trusting it either edits nothing (the path 404s) or hunts for the real file. `reports` is the only record store whose records sit a level below the store root (`docs/reports/bugs/`, `docs/reports/investigations/`), which is why the four flat stores never showed this.
- **Resolution:** Resolved on 2026-08-24. Fixed in cb7020b6; one shared walk (records_grep.collectRenameReferences) behind the nesting-tolerant doc_scaffold.isUnder, so reports rename prints repo-rooted paths that open. Verified by clanker gate (eleven checks), a new sandbox-runtime test that stats every path the reply lists, and a live rename.

## Status

Resolved on 2026-08-24. Fixed in cb7020b6; one shared walk (records_grep.collectRenameReferences) behind the nesting-tolerant doc_scaffold.isUnder, so reports rename prints repo-rooted paths that open. Verified by clanker gate (eleven checks), a new sandbox-runtime test that stats every path the reply lists, and a live rename.

## Symptom and impact

Renaming `docs/reports/bugs/2026-08-24-ck-http-drops-error-status-and-body.md`
to a UTC-dated slug printed:

```
renamed docs/reports/bugs/2026-08-24-ck-http-drops-error-status-and-body.md
     -> docs/reports/bugs/2026-08-23-ck-http-drops-error-status-and-body.md

Still naming the old record:
  docs/reports/docs/reports/bugs/2026-08-24-ck-http-hands-guests-no-response-headers.md
```

The reference itself is real and was worth reporting -- that record did carry a
markdown link to the old filename. Only the path is wrong: the file is at
`docs/reports/bugs/2026-08-24-ck-http-hands-guests-no-response-headers.md`, with
`docs/reports/` once.

The rename, the inventory rewrite and the leftover *detection* are all correct.
It is only the rendering of the path that is broken, which is the worst place
for it: the output looks authoritative and is the only reason to run the verb
rather than `git mv`.

## Reproduction

Deterministic, no model, no network. Any reports record that links to a sibling:

```bash
clanker reports rename docs/reports/bugs/<a>.md <new-slug>
```

If some `docs/reports/bugs/<b>.md` names `<a>`, the "Still naming the old
record" line prints `docs/reports/docs/reports/bugs/<b>.md`.

## Root cause

`tools/zig/reports.zig`:

```zig
const full = try std.fmt.allocPrint(lib.alloc, "{s}/{s}", .{ root, file.string });
```

`root` is `docs/reports`; `file.string` from `ck_fs_grep` is already
`docs/reports/bugs/<b>.md`. The doc comment above the function says the hits are
joined to produce "store-rooted paths", so the join encodes an assumption about
`ck_fs_grep` that does not hold.

What makes this more than a typo is that the same walk exists twice. The shared
half used by the four numbered stores,
`records_grep.collectRenameReferences`, guards the join:

```zig
const full = if (doc.isPathIn(dir, file.string))
    try lib.alloc.dupe(u8, file.string)
else
    try std.fmt.allocPrint(lib.alloc, "{s}/{s}", .{ dir, file.string });
```

with the comment "Defensive: take the path as given when it is already
store-rooted". That guard is the right idea and still would not save this store:
`doc_scaffold.isPathIn` requires the remainder after `dir/` to contain no `/`
(`doc_scaffold.zig:187`), so a nested `bugs/<b>.md` fails the test and falls into
the joining branch anyway. The reports store is the only one that nests, so the
only store the guard cannot recognise is the only store that needs it.

Two copies of one walk, and the defence in the copy that has one is aimed at the
wrong condition.

## Resolution

**Fixed 2026-08-24 in cb7020b6, by route (2).** The change that surfaced it renames four records and edits
prose only, and quietly folding a guest fix into a docs-only PR is how a code
change ships unreviewed.

The fix is small and should be one change covering both copies:

1. Drop the join in `reports.zig` and take `ck_fs_grep`'s path as given, or
2. give `records_grep` a nesting-tolerant "is this path inside this store"
   predicate and route both call sites through it, so the two spellings cannot
   disagree again.

(2) is the better shape: the duplication is the reason one copy has a guard and
the other does not. Either way the assumption about what `ck_fs_grep` returns
should become a test rather than a comment -- there is currently no test on
either function's path arithmetic, which is why a wrong path shipped looking
right.

## Verification

Nothing to verify: no fix is claimed. What is verified, and how:

- That the printed path does not exist: read from the rename output above and
  checked against `ls`, not inferred.
- That the detection is nonetheless correct: the named record really did contain
  the old filename, and a tree-wide grep after the manual fix is clean.
- That `isPathIn` rejects a nested path: read at `doc_scaffold.zig:181-190`, not
  assumed from its name.

## Follow-up

- Whoever fixes it should check the other `lib.fsGrep` callers in `tools/zig/`
  for the same join, since the assumption is about the host function's contract
  and not about renaming.

## References

- Investigation: none. The join and `isPathIn`'s bounds are both one read.
- `tools/zig/reports.zig` (`collectReferences`),
  `tools/zig/records_grep.zig` (`collectRenameReferences`),
  `tools/zig/doc_scaffold.zig` (`isPathIn`).
- [Record stores have no rename or move action](../investigations/2026-08-17-missing-clanker-tool-record-stores-cannot-rename-a-record.md)
  — the investigation the rename verb came from.

## Note — how it was fixed, and the test the comment became (2026-08-24)

Route (2), as this record recommended: one walk, one predicate.

`reports.collectReferences` is gone. Both stores now go through
`records_grep.collectRenameReferences`, and its containment test is a new
`doc_scaffold.isUnder` -- `isPathIn` without the single-directory-level rule.
The two are kept separate rather than merged: `isPathIn` gates *writes*, where
refusing a nested path is the store's conventions being enforced, while
`isUnder` only answers "is this path already rooted at the store", which a hit
under `docs/reports/bugs/` has to answer yes to.

Each store's index is now skipped by comparing its path, which is what the old
`std.mem.eql(u8, file.string, "README.md")` line only looked like it did: the
host reports repo-rooted paths, so that comparison never matched anything.

The assumption became a test, as this record asked. Two of them:

- `isUnder accepts a nested path where isPathIn does not` in
  `tools/zig/doc_scaffold.zig`, which asserts both predicates on the same
  nested path so the difference between them is pinned rather than described.
- `reports wasm tool rename lists leftover references at paths that exist` in
  `src/sandbox/runtime.zig`, which drives the real guest through a rename in a
  tmp sandbox and `statFile`s every path the reply lists. It also carries a
  prose mention of the old stem in the index, outside the inventory markers, so
  the index survives the link rewrite as a grep hit and the skip is exercised
  rather than assumed.

Live, on the built binary: renaming a scratch record that a sibling still cited
printed `docs/reports/bugs/2026-08-24-live-check-alpha.md`, with
`docs/reports/` once, and that file existed. Both scratch records were deleted
afterwards.

The Follow-up asked for the other `lib.fsGrep` callers in `tools/zig/` to be
checked for the same join. They were: `records_grep.grepAll` and the search
paths take the host's path as given and never join, so `collectReferences` was
the only instance.
