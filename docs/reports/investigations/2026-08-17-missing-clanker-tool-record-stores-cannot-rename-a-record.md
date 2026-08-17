# Missing clanker tool — Record stores have no rename or move action

## TL;DR

- **Missing tool:** A record created under the wrong name (wrong slug, wrong taxonomy marker) can only be renamed by hand: git mv plus a hand edit of the README inventory link, exactly the ad-hoc fallback the stores exist to remove. Every store verb addresses records by path, so a rename also breaks inbound references silently.
- **Finding:** Investigating.
- **Resolution:** Pending.

## Status

Investigating.

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