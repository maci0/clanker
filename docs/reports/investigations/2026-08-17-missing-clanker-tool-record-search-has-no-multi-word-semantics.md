# Missing clanker tool — Record search matches one exact substring, so multi-word queries miss existing records

## TL;DR

- **Missing tool:** reports search 'concurrent sessions' returns nothing while docs/runbooks/concurrent-agent-sessions-on-one-checkout.md exists: the query is one exact substring per line, so two words that never appear adjacent find no record. Missing: a search that ANDs terms per record. Workaround: single-word queries.
- **Finding:** Resolved on 2026-08-17. Implemented: search splits the query into terms every record must contain, quoted phrases stay exact; doc_scaffold.searchTerms/intersectHits with the guest half in tools/zig/records_grep.zig, shared by all five stores.
- **Resolution:** Resolved on 2026-08-17. Implemented: search splits the query into terms every record must contain, quoted phrases stay exact; doc_scaffold.searchTerms/intersectHits with the guest half in tools/zig/records_grep.zig, shared by all five stores.

## Status

Resolved on 2026-08-17. Implemented: search splits the query into terms every record must contain, quoted phrases stay exact; doc_scaffold.searchTerms/intersectHits with the guest half in tools/zig/records_grep.zig, shared by all five stores.

## What is missing

## Why it is basic

## Ad-hoc fallback used

## Proposed shape

## References

- Related record: none yet
## Evidence

Checked live on 2026-08-17, clanker 0.1.0, this checkout:

- `clanker reports search "concurrent sessions"` -> 'no report or runbook mentions "concurrent sessions"', while docs/runbooks/concurrent-agent-sessions-on-one-checkout.md exists (its title line is 'Several agent sessions share one checkout', so the two query words never appear adjacent anywhere in the stores).
- `clanker reports search "agent sessions"` -> 12 matching lines; `clanker reports search "concurrent"` -> 20 matching lines. Both reach the runbook's neighborhood, confirming the corpus is indexed and only the two-word phrase fails.

Surfaced live: a peer session searching for the concurrent-sessions runbook that CLAUDE.md and AGENTS.md point at concluded the runbook might be missing and was about to re-file it.

## Proposed shape

`search` (reports, and the same helper the other four stores share) splits the query on whitespace and requires every term to match the record (case-insensitive substring per term), reporting the lines where terms hit. An exact-phrase mode can stay behind quotes. No new verb needed — this is the existing `search` action's matching, so CLI, HTTP and agent surfaces all inherit it through the one guest.