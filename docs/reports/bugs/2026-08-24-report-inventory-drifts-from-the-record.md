# Bug — two resolved records still read Open in the reports inventory, so reports list offers finished work

## TL;DR

- **What failed:** docs/reports/README.md is the third place a record states its state and the one reports list reads; two records resolved on 2026-08-23 still had Open inventory rows, and a five-agent fan-out partitioned off that listing assigned an already-fixed bug as live work
- **Impact:** Work that is already done is offered as open. A five-agent fan-out partitioned off `reports list` and assigned one already-fixed bug as live work; the agent was stopped before it wrote a redundant patch. Reproduced.
- **Resolution:** Open.

## Status

Open.

## Blocked on

## Symptom and impact

A record states its state in three places: the TL;DR `**Resolution:**` bullet,
the `## Status` section, and its row in the `docs/reports/README.md` inventory.
`reports status` writes all three in one call, which is exactly why the
workflow section of that README says to use it rather than editing the Status
line by hand.

Two records had drifted anyway — resolved in the record, `Open` in the
inventory:

| Record | `## Status` | Inventory row |
|---|---|---|
| `2026-08-23-repl-markdown-eats-snake-case-underscores.md` | Resolved on 2026-08-23 | Open |
| `2026-08-23-repl-composer-latches-into-paste-mode.md` | Resolved on 2026-08-23 | Open |

Both were fixed by `b9e108b1` ("repl: unlatch the composer, keep snake_case,
cap mention expansion").

The inventory is the half that gets read. `clanker reports list` renders it,
not the record bodies, so a drifted row is invisible until someone opens the
record — and the two commands an agent is told to start from (`reports list`,
`reports search`) both go through it. The failure is therefore not cosmetic:
**it hands out finished work as a task.** On 2026-08-24 a five-agent fan-out
partitioned its assignments off this listing and gave an agent
`repl-composer-latches-into-paste-mode` as one of three live bugs. That agent
was stopped by hand, mid-run, after the drift was found; without that it would
have re-fixed a fixed bug, and the wasted cycle would have looked like its own
fault rather than the store's.

## Reproduction

Compare each record's `## Status` against its inventory row:

```bash
clanker reports list --kind report | grep -c "^  Open"   # 14
grep -n "repl-markdown-eats-snake-case" docs/reports/README.md
#   ... — Open
sed -n '/^## Status/,+2p' docs/reports/bugs/2026-08-23-repl-markdown-eats-snake-case-underscores.md
#   Resolved on 2026-08-23. ...
```

Confirmed at `1da580fc`.

## Root cause

Not established, and deliberately not guessed. The record write and the
inventory write are separate steps, and `setInventoryStatus` returns a boolean
the caller can report as "the inventory was not updated" — so a partial
success is a shape the tool already knows about. Which of these produced these
two rows is not recoverable from the tree:

- a `status` call whose inventory half failed and whose warning was not acted
  on,
- a hand-edited `## Status` line, which the workflow section warns against
  precisely because it skips the inventory,
- or a concurrent-merge resolution that kept the record side and dropped the
  inventory side. Both records were resolved on 2026-08-23, a day when several
  sessions were merging in parallel, and the same file has needed a
  blank-line repair after a merge before (`fb4d1df0`).

Establishing it needs the tool's own logs from that day, which are not kept.

## Resolution

The two rows corrected to `Resolved`, by editing the inventory only. Not by
re-running `reports status`: the records already carry the correct state and
the original 2026-08-23 resolution text, and a fresh `status` call would
overwrite that with today's date and a weaker note — losing evidence to fix a
bookkeeping error.

Nothing is fixed about the drift *mechanism*, which is why this record stays
open rather than resolved.

## Verification

A scripted comparison of `## Status` against the inventory row for all 199
indexed records: two mismatches before, zero after.

The sweep needed two corrections of its own, both worth recording because they
are the trap this bug sets for anyone auditing it:

- The first parser looked for the `reports list` **output** format (status
  word, then path on the next line) instead of the README's row format
  (`- [Title](path) — Status`). It reported **zero** mismatches — a clean bill
  of health that directly contradicted a `grep` of the same file. A tool that
  disagrees with a direct observation is wrong, not reassuring.
- The corrected parser then reported a third record as having **no inventory
  row at all**. It has one, and it is correct; the title contains `[ERROR]`,
  and the nested brackets broke the row regex. Verified by grep before it went
  in this record.

## Follow-up

The general shape, third instance in two days: **a rule that is enforced by
convention rather than mechanism drifts, and the drift is invisible where it
matters most.** The other two are the `release-contract` gate
([investigation](../investigations/2026-08-24-release-contract-never-reads-the-diff.md))
and the `## Blocked on` body
([bug](2026-08-24-blocked-on-body-is-an-ungated-fourth-state-signal.md)), which
proposes a consistency check for exactly this class. This record is a fourth
argument for building it, and the check should compare the inventory row too,
not only the two in-record signals.

A cheap mechanical guard, unclaimed: a gate check that walks every record and
fails when its `## Status` disagrees with its inventory row. It is a pure
text comparison over files already in the tree, it would have caught both of
these the day they drifted, and it needs no new state.

Also unfixed and visible in the same file: the blank line between inventory
entries is missing in at least one place after a concurrent merge (around the
`advisor-model-never-read` and `connection-limit-503` rows). Cosmetic, left
alone here to keep this change to the two status words.

## References

- Code: `tools/zig/reports.zig` (`status`, `setInventoryStatus`),
  `docs/reports/README.md` (the inventory and its workflow section)
- Fix commit for both drifted records: `b9e108b1`
- Related bug: [the '## Blocked on' body is an ungated fourth state signal](2026-08-24-blocked-on-body-is-an-ungated-fourth-state-signal.md)
- Investigation: [release-contract never reads the diff](../investigations/2026-08-24-release-contract-never-reads-the-diff.md)
