# Bug — A status change keeps the old text of a multi-line TL;DR bullet

## TL;DR

- **What failed:** findTldrField returns the end of the bullet's first physical line, so replaceTldrField writes the new value and then re-emits every continuation line of the old one. A record whose TL;DR Resolution bullet wraps ends a status change with two contradictory accounts stacked under one bullet, and nothing reports it.
- **Impact:** silent damage to the record store, at the moment a reader is most likely to trust the summary and stop there — the tool reports success and the two accounts read as deliberate prose. Two other records were found already carrying it and have been repaired.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

A status change on a record whose TL;DR `- **Resolution:**` bullet spans more
than one line leaves the record saying two different things in one bullet: the
new status on the first line, then the whole of the old text underneath it,
still indented as part of the same bullet.

Hit live on
[the improve-ledger record](2026-08-17-improve-ledger-written-to-a-worktree-copy.md)
on 2026-08-17. Its Resolution bullet had been rewritten to eight lines
describing the fix; `clanker reports status ... resolved` then produced this,
where everything from the second line on is the previous bullet's tail:

```
- **Resolution:** Resolved on 2026-08-17. atomic_write.writeFile renames onto a symlinked destination's target instead of onto the link, ... clanker gate 8/8.
  link target and renames onto *that*, so a linked path keeps its link and the
  write lands where every reader looks. Three unit tests cover the
  same-directory, relative-subdirectory and absolute link-target spellings; the
  first fails with `NotLink` on the old code. The surviving worktree ledgers
  were drained into the shared one before the fix landed (1130 → 1139 lines,
  exactly the ten worktrees' combined delta), so the do-not-clean-up hazard
  below is retired.
```

The second line begins mid-sentence — `link target and renames onto *that*` —
because its subject was on the line the rewrite replaced. The tool reported
success and the store's inventory was updated correctly; nothing indicated the
bullet had been damaged.

The impact is silent damage to the store this project treats as its record of
fact. The truncation is not reported, the surviving tail reads as deliberate
prose, and the two accounts it produces are contradictory precisely when they
matter most — the moment a bug is marked resolved and a reader is most likely
to trust the summary and stop there.

It is not a one-off. Two other records were already carrying the same damage
from earlier status changes:

| Record | Orphaned tail |
|---|---|
| `2026-08-17-ck-llm-grant-spent-on-reasoning.md` | three lines restating the grant raise |
| `2026-08-17-config-hunk-deleted-as-collateral-reverts-silently.md` | `and the two method traps below, are from session clanker-d7.` |

## Reproduction

Give a record a TL;DR Resolution bullet that wraps, then move its status. Any
record and any state reproduce it; the bullet only has to be longer than one
line.

```
clanker reports update <record> "<old single-line resolution>" "<a resolution long enough to wrap over several indented lines>"
```

```
clanker reports status <record> resolved "<note>"
```

The bullet then holds the note followed by the old text from its second line
onward, and the command exits successfully.

## Root cause

`findTldrField` in `tools/zig/doc_scaffold.zig` locates the bullet by scanning
for the `- **<Field>:**` marker and returns `line_end` set to the next `\n`:

```
const line_end = @min(std.mem.findPos(u8, text, scan, "\n") orelse sec.body_end, sec.body_end);
```

`replaceTldrField` then writes `text[0..value_start]`, the new value, and
`text[line_end..]`. For a single-line bullet that is exactly right. For a
markdown list item with continuation lines — which belong to the item, not to
a separate paragraph — `line_end` stops at the end of the *first physical
line*, so every continuation line survives the replacement.

This is reachable rather than exotic. `create` writes each bullet on one line,
but `update` is the documented way to revise a record and long prose wraps: in
the record where this was found, the sibling `- **Impact:**` bullet was
already multi-line before any status change.

`replaceFirstLine`, which handles the `## Status` section, is *not* affected
and is deliberately first-line-only — there the prose underneath explains what
the state means and must survive. The two cases look alike and are not: a
section has following paragraphs, a list item has continuation lines that are
part of it.

## Resolution

Open. The mechanism is established and one fix is suggested; no code has
changed.

Extend `findTldrField`'s `line_end` over the bullet's continuation lines
before returning: from the end of the first line, keep consuming lines while a
line is non-blank, indented, and does not itself start a new `- ` item or a
heading. `tldrField` reads the same struct and would then return the whole
bullet, which suits its caller too — that caller asks "is this still the
scaffold's placeholder", and a placeholder is one line, so a multi-line value
is by definition not one.

The helper is pure and lives in `tools/zig/doc_scaffold.zig`, which `build.zig`
lists in `host_tested_helpers`, so a failing test can be written against it
without the guest ABI.

Note for whoever resolves this record: its own TL;DR bullets are deliberately
kept to one line each, so closing it does not reproduce the defect.

## Verification

Run in this checkout on 2026-08-17.

The mechanism was read from `tools/zig/doc_scaffold.zig` at the lines quoted
under Root cause, not inferred from the output.

The scan for other affected records looked for the signature — a
`- **Resolution:** <State> on <date>.` line followed by an indented
continuation line — across `docs/reports/bugs/` and
`docs/reports/investigations/`. It returned the two records tabled above, plus
this one, which matches only because it quotes the damage inside a fenced
block.

Both were repaired by hand in `b8b1f44e`, after checking that neither
orphaned tail carried anything its record does not say elsewhere: the
clanker-d7 credit survives at two other points in the config-hunk record
(the restore attribution and the method-traps section), and the ck-llm tail
only restated the grant raise that the new Resolution value already gives.
Re-running the scan afterwards leaves this record as the only hit.

## Follow-up

- The other four record stores (`rfc`, `adr`, `prd`, `research`) share
  `doc_scaffold.zig`. Whether their status paths reach `replaceTldrField` with
  a multi-line bullet has not been checked here.
- Nothing detects the damage after the fact. The scan above is a shell one-off;
  if this proves to have happened more widely, it belongs in a gate or in
  `clanker doctor` rather than in a session's notes.

## References

- Found while resolving:
  [`2026-08-17-improve-ledger-written-to-a-worktree-copy.md`](2026-08-17-improve-ledger-written-to-a-worktree-copy.md)
- Repaired by the same session:
  [`2026-08-17-ck-llm-grant-spent-on-reasoning.md`](2026-08-17-ck-llm-grant-spent-on-reasoning.md),
  [`2026-08-17-config-hunk-deleted-as-collateral-reverts-silently.md`](2026-08-17-config-hunk-deleted-as-collateral-reverts-silently.md)
- Code: `tools/zig/doc_scaffold.zig` (`findTldrField`, `replaceTldrField`,
  `tldrField`, `replaceFirstLine`), `tools/zig/reports.zig`