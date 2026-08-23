# Bug — reports create writes the kind label into the title a second time

## TL;DR

- **What failed:** clanker reports create bug <slug> "Bug — <title>" ... rendered "# Bug — Bug — <title>" and an inventory line reading "[Bug — <title>]", because renderScaffold prefixes the label and addToInventory was handed the raw title. The only index entry in docs/reports/README.md carrying a label is the residue of exactly that, its H1 having been repaired by hand.
- **Impact:** Presentation, on the store the project is told to read first: the H1 that `reports open` prints and the index line that `reports list` renders. No code reads either, and nothing was lost -- but a store that misrenders its own writes is a store people stop trusting for the one thing it is for.
- **Resolution:** Resolved on 2026-08-23. create normalises the title through doc.stripLabelPrefix before the scaffold and the inventory entry are written; host test plus a live create/control pair

## Status

Resolved on 2026-08-23. create normalises the title through doc.stripLabelPrefix before the scaffold and the inventory entry are written; host test plus a live create/control pair

## Symptom and impact

`clanker reports create bug <slug> "Bug — a control probe" "..."` wrote

```
# Bug — Bug — a control probe
```

and added `- [Bug — a control probe](bugs/...md) — Open` to
`docs/reports/README.md`, where every other entry is the bare title. The title
cap (180 bytes) is checked against the string the caller sent, so the label is
also 6 bytes of a budget the caller never spent.

Impact is presentation, on the store the project reads first. The H1 is what
`clanker reports open` prints and what a reader skims; the inventory line is
what `clanker reports list` renders. Nothing in code reads either, so no
behaviour depends on it -- but it is the second time a record store has
mangled its own index (see the schedule-list row-2 record for the first), and
a store that misrenders its own writes stops being trusted for the thing it
exists to do.

## Reproduction

Measured at `origin/main` a13d58a5, aarch64-macos:

```bash
clanker reports create bug 2026-08-24-control-probe "Bug — a control probe" "Control."
head -1 docs/reports/bugs/2026-08-24-control-probe.md
grep control-probe docs/reports/README.md
```

The first prints `# Bug — Bug — a control probe`; the second prints an
inventory line carrying the label. Any of the four kinds reproduces it with its
own word: `Investigation`, `Missing clanker tool`, `Runbook`.

The residue is in the tree: of the 60-odd entries in
`docs/reports/README.md`, exactly one --
`2026-08-23-debug-tool-run-leaks-on-adapter-timeout.md` -- reads
`[Bug — a run using the debug tool...]`, and that record's own H1 has a single
`Bug — `. The H1 was repaired by hand and the index line was not, which is
what the defect looks like after someone notices half of it.

## Root cause

`renderScaffold` (tools/zig/reports.zig) writes `# {label} — {title}` and
`addToInventory` writes `- [{title}]({link}) — {status}`, both from the title
the caller sent, and neither had any opinion about a title that already began
with the label. The store enforces the analogous rule one function away:
`markMissingToolSlug` inserts the `missing-clanker-tool-` filename marker
"whether or not the caller wrote it", precisely so a record is findable by name
without trusting the caller. The title prefix was left trusted.

## Resolution

`create` normalises the title once, before either writer sees it:
`doc.stripLabelPrefix(kindLabel(kind), title)` drops a leading `<label>` and
its separator (an em dash, a hyphen or a colon), case-insensitively and
repeatedly, and a title that is nothing but the label is refused rather than
emptied. The scaffold and the inventory entry are both written from the
normalised string, so the two can no longer disagree.

The helper lives in `tools/zig/doc_scaffold.zig` rather than beside its caller
because that module imports nothing from the guest ABI and its `test` blocks
therefore run in `zig build test`. `kindLabel` was factored out of
`renderScaffold` at the same time so the prefix that is written and the prefix
that is stripped are one string, not two.

## Verification

- `test "stripLabelPrefix drops a label the caller wrote, however it was
  spelled"` (tools/zig/doc_scaffold.zig): the three separators, a doubled
  label, and five titles that must survive untouched -- no separator
  ("Bug fixes for the sweep"), a different label, the label alone, the label
  with a separator and nothing after it, and a title that merely starts with
  the label's letters ("Bugbear — x").
- Live, on the built tool: `clanker reports create bug <slug>
  "Bug — a scratch probe for the label prefix" "..."` wrote
  `# Bug — a scratch probe for the label prefix` and an inventory line with no
  label. Control, on the same tree with the guest changes stashed and
  `zig build tools` re-run: `# Bug — Bug — a control probe` and
  `- [Bug — a control probe](...)`. Both scratch records were deleted and the
  index restored.

## Follow-up

The other four record stores (`adr`, `prd`, `rfc`, `research`) do not write a
label into the `# ` line, so they have nothing to strip; `reports` is the only
store with a per-kind prefix.

Not fixed here: the one index line already carrying the label,
`2026-08-23-debug-tool-run-leaks-on-adapter-timeout.md`. It belongs to an open
bug in another territory and rewriting another session's record to tidy an
index entry is not worth the conflict; the next `reports status` on it will
leave the title as it is.

## References

- Investigation: none yet
