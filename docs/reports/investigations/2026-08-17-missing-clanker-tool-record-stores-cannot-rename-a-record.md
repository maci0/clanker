# Missing clanker tool — Record stores have no rename or move action

## TL;DR

- **Missing tool:** A record created under the wrong name (wrong slug, wrong taxonomy marker) can only be renamed by hand: git mv plus a hand edit of the README inventory link, exactly the ad-hoc fallback the stores exist to remove. Every store verb addresses records by path, so a rename also breaks inbound references silently.
- **Finding:** Resolved on 2026-08-17. Resolved on 2026-08-17 for the reports store: clanker reports rename <path> <new-slug> moves the record in place, rewrites the inventory link under CAS, preserves the missing-clanker-tool- marker, and lists in-store references to the old name. The other four stores (rfc, adr, prd, research) still lack the action; tracked on the local board.
- **Resolution:** Resolved on 2026-08-17. Resolved on 2026-08-17 for the reports store: clanker reports rename <path> <new-slug> moves the record in place, rewrites the inventory link under CAS, preserves the missing-clanker-tool- marker, and lists in-store references to the old name. The other four stores (rfc, adr, prd, research) still lack the action; tracked on the local board.

## Status

Resolved on 2026-08-17. Resolved on 2026-08-17 for the reports store: clanker reports rename <path> <new-slug> moves the record in place, rewrites the inventory link under CAS, preserves the missing-clanker-tool- marker, and lists in-store references to the old name. The other four stores (rfc, adr, prd, research) still lack the action; tracked on the local board.

## What is missing

## Why it is basic

## Ad-hoc fallback used

## Proposed shape

## References

- Related record: none yet
## Ad-hoc fallback used

2026-08-17, renaming docs/reports/investigations/2026-08-17-no-verb-prints-a-runs-final-answer.md to carry the missing-clanker-tool- marker: `clanker git mv` for the file, then `sed` over docs/reports/README.md (the inventory link) and the local TODO board. Three writes for one rename, none of them compare-and-swap, and any reference this session did not grep for is now silently broken.

## Proposed shape

A `rename` (or `move`) action on each record tool: takes old path + new slug, moves the file, rewrites the inventory link under CAS, and reports every other reference it finds so the caller can fix them deliberately.
## Review

Second-opinion diff review via clanker run (deepseek-v4-pro) on the rename implementation. Its three findings, assessed:

- Reference-scan failures were silently indistinguishable from 'no references' — confirmed and fixed: a failed scan now flips the reply's references_note to say the list is incomplete, and an unparsable grep result is an error instead of an empty return.
- Global inventory replace touching another record's link — checked, not reachable: links are store-relative with one directory level and a .md suffix, so no link can be a substring of a different one (comment added at renameInventoryLink saying so).
- graph answer picking among several final nodes — a run's node list is appended chronologically and a run records one outcome, so the last final node is the answer by construction.