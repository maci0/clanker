# Bug — A status change keeps the old text of a multi-line TL;DR bullet

## TL;DR

- **What failed:** findTldrField returns the end of the bullet's first physical line, so replaceTldrField writes the new value and then re-emits every continuation line of the old one. A record whose TL;DR Resolution bullet wraps ends a status change with two contradictory accounts stacked under one bullet, and nothing reports it.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Symptom

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

Note the second line begins mid-sentence — `link target and renames onto
*that*` — because its subject was on the line the rewrite replaced. The tool
reported success and the store's inventory was updated correctly; nothing
indicated the bullet had been damaged.

## Root cause

`findTldrField` in `tools/zig/doc_scaffold.zig` locates the bullet by scanning
for the `- **<Field>:**` marker and returns `line_end` set to the next `\n`:

```
const line_end = @min(std.mem.findPos(u8, text, scan, "\n") orelse sec.body_end, sec.body_end);
```

`replaceTldrField` then writes `text[0..value_start]`, the new value, and
`text[line_end..]`. For a single-line bullet that is exactly right. For a
markdown list item with continuation lines — which are part of the item, not
separate paragraphs — `line_end` stops at the end of the *first physical
line*, so every continuation line is re-emitted after the replacement.

The scaffold's own writers make this reachable rather than exotic. A bullet is
written on one line at `create`, but `update` is the documented way to revise
a record, and prose that long wraps: the sibling `- **Impact:**` bullet in the
same record was already multi-line before any status change.

`replaceFirstLine`, used for the `## Status` section, is not affected and is
deliberately first-line-only — there the prose underneath explains what the
state means and must survive. The two cases look alike and are not: a section
has following paragraphs, a list item has continuation lines that belong to
it.

## Reproduction

Give a record a TL;DR bullet that wraps, then move its status:

```
clanker reports update <record> "<old single-line resolution>" "<a resolution long enough to wrap over several indented lines>"
```

```
clanker reports status <record> resolved "<note>"
```

The bullet now holds the note followed by the old text's second line onward.

## Suggested fix

Extend `findTldrField`'s `line_end` over the bullet's continuation lines
before returning: from the end of the first line, keep consuming lines while a
line is blank-free, indented, and does not itself start a new `- ` item or a
heading. `tldrField` reads the same struct and would then return the whole
bullet, which is what its "is it still the placeholder" caller wants anyway —
a placeholder is one line, so a multi-line value is by definition not one.

The helper is pure and lives in `tools/zig/doc_scaffold.zig`, which is in
`host_tested_helpers`, so this is unit-testable without the guest ABI.

## Impact

Silent damage to the store the project treats as its record of fact. The
truncation is not reported, the surviving tail reads as deliberate prose, and
the two accounts it produces are contradictory precisely when they matter —
the moment a bug is marked resolved.

It is not a one-off. Scanning both stores for the signature — a
`- **Resolution:** <State> on <date>.` line followed by an indented
continuation line — found two more records already carrying it, from status
changes made before this was noticed:

| Record | Orphaned tail |
|---|---|
| `2026-08-17-ck-llm-grant-spent-on-reasoning.md` | three lines restating the grant raise |
| `2026-08-17-config-hunk-deleted-as-collateral-reverts-silently.md` | `and the two method traps below, are from session clanker-d7.` |

Both were repaired by hand on 2026-08-17, after checking that neither tail
carried anything the record does not say elsewhere — the clanker-d7 credit
survives at two other points in that record, and the grant raise is in the new
Resolution value. The scan is now clean apart from this record, which quotes
the damage inside a fenced block.