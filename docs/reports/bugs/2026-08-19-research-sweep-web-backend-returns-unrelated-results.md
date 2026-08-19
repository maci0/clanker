# Bug — research sweep's web backend returns only unrelated pages

## TL;DR

- **What failed:** Both 2026-08-19 sweeps (topics 'distributed ledger state store' and 'immutable ledger database', depth standard) returned exclusively off-topic pages — Chinese hardware-vendor sites, bird-forum threads, thesaurus entries — for every query angle, all tagged bing; the 2026-08-16 pass recorded the same backend answering an embedded-SQLite query with dictionary pages, so sweep web output is currently unusable as leads and research falls back to direct web search.
- **Impact:** sweep web output is unusable as research leads; passes fall back to direct web search and per-claim fetches.
- **Resolution:** Resolved on 2026-08-19. keepRelevant drops hits sharing under two query terms before any backend's results are collected (search_parse/research/web_search); verified by two host tests on the live junk shapes and an on-topic rerun of the sweep reproduction

## Status

Resolved on 2026-08-19. keepRelevant drops hits sharing under two query terms before any backend's results are collected (search_parse/research/web_search); verified by two host tests on the live junk shapes and an on-topic rerun of the sweep reproduction

## Symptom and impact

Every WEB result of both sweeps was unrelated to its query. The first sweep's
`baseline` angle returned ludashi.com hardware/game pages (Chinese), its
`options` angle birdforum.net threads, its `libraries` angle epsxe.com
emulator pages; the second sweep's angles returned nipponcat.co.jp
(Caterpillar Japan), microsoft.com sign-in pages, and thesaurus entries for
the word "hate". Not one hit named a database, a ledger, or a store. Every
hit was tagged `[<angle> · bing]`.

Impact: `research sweep`'s web output is unusable as leads, so any research
pass that trusts it starts from noise. The 2026-08-19 option-R/S/T research
for docs/research/decentralized-state-store.md fell back to direct web
search with per-claim fetches; the note's "Rejected leads, kept deliberately"
section records each occurrence (2026-08-16: dictionary pages for an
embedded-SQLite query; 2026-08-19: this instance).

## Reproduction

Run either sweep and read the WEB section:

```bash
clanker research sweep "distributed ledger state store" standard
```

```bash
clanker research sweep "immutable ledger database" standard
```

Observed 2026-08-19: 18 fetches each, every WEB hit off-topic, every hit
tagged `bing`. The GitHub/discussion sections were not the failing part.

## Root cause

Traced on 2026-08-19 by fetching the exact URLs the guest builds. Bing's
`format=rss` endpoint itself has decayed upstream: it answers a well-formed,
correctly percent-encoded multi-word query with an RSS document whose items
match at most one word of it, or nothing at all. Live probes from a plain
HTTP client reproduced the report's shapes exactly — `distributed ledger
state store` returned Vocabulary.com thesaurus entries for "distributed",
`immutable ledger database` returned Immutable-the-games-company pages and
dictionary entries, `zig programming language` returned ChatGPT pages. The
channel `<title>` echoes the full query, so the query reaches Bing intact;
the results are what changed. Neither the query encoding
(`parse.percentEncode` is correct, and `+` for spaces behaves the same) nor
`parseBing` is at fault: the parser faithfully extracts what Bing sent.

Two code-side factors turned an upstream decay into unusable sweeps:
DuckDuckGo Lite serves its anti-bot page from this network (200 status,
zero parsed results), so nearly every query fell through to Bing; and
nothing checked parsed hits against the query, so a page of well-formed
junk read as success and stopped the fallback chain before the keyed
backends and Marginalia.

Bing's HTML search page was probed as a replacement backend and is not one:
like Google, it answers a plain client with a JavaScript challenge carrying
no organic results.

## Resolution

Resolved on 2026-08-19. `search_parse.keepRelevant` drops hits sharing fewer
than two distinct query terms (one for one-word queries) across
title/snippet/URL, case-insensitively; `sweepWeb` applies it to every web
backend's parse, so an all-junk page compacts to zero and the sweep falls
through to Google/Brave/Marginalia instead of collecting noise, with a
once-per-sweep note naming what happened. The `web_search` tool shares the
same Bing RSS fallback and got the same filter. Upstream Bing cannot be
fixed from here; what the fix guarantees is that off-topic pages are never
again filed as leads.

## Verification

- Host tests `matchesQuery keeps two-term hits and drops one-word poisoning`
  and `keepRelevant compacts a poisoned page to zero and keeps order` in
  `tools/zig/search_parse.zig`, built from the live junk shapes above.
- Live rerun of the reproduction, 2026-08-19:
  `clanker research sweep "immutable ledger database" standard` now returns
  on-topic WEB hits (immudb, QLDB, Azure Confidential Ledger, ledger-table
  posts) via Marginalia after the poisoned Bing pages compact to zero; one
  borderline Bing hit (immutable.com/chain, two matched terms) survived,
  which is the heuristic working as specified rather than failing.
- Full gate green: `zig build`, `zig build tools`,
  `zig build test --summary all` — 320/320 steps, 1673/1684 passed,
  11 skipped, 0 failed.

## Follow-up

- The research note's method now records "sweep web backend failed, leads
  gathered by direct search" per pass; once this is fixed, that caveat can
  stop accumulating.

## References

- [docs/research/decentralized-state-store.md](../../research/decentralized-state-store.md)
  — "Rejected leads, kept deliberately" records the 2026-08-16 and
  2026-08-19 instances with the sample hits.
