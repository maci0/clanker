# Bug — research sweep's web backend returns only unrelated pages

## TL;DR

- **What failed:** Both 2026-08-19 sweeps (topics 'distributed ledger state store' and 'immutable ledger database', depth standard) returned exclusively off-topic pages — Chinese hardware-vendor sites, bird-forum threads, thesaurus entries — for every query angle, all tagged bing; the 2026-08-16 pass recorded the same backend answering an embedded-SQLite query with dictionary pages, so sweep web output is currently unusable as leads and research falls back to direct web search.
- **Impact:** sweep web output is unusable as research leads; passes fall back to direct web search and per-claim fetches.
- **Resolution:** Open.

## Status

Open.

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

Not traced. What is checked: the failing hits are all tagged `bing`, and the
same backend produced the 2026-08-16 dictionary-page failure, so the defect
sits in or behind the Bing scrape path rather than in one topic's phrasing.
Whether Bing is serving a bot-detection or geo-redirected page that the
scraper then parses as results, or the scraper parses an unrelated block of
the page, is unverified — the sweep guest's fetch path was not opened in
this pass.

## Resolution

Open.

## Verification

Open — a fixed backend should return database/ledger-related hits for the two
reproduction commands above.

## Follow-up

- The research note's method now records "sweep web backend failed, leads
  gathered by direct search" per pass; once this is fixed, that caveat can
  stop accumulating.

## References

- [docs/research/decentralized-state-store.md](../../research/decentralized-state-store.md)
  — "Rejected leads, kept deliberately" records the 2026-08-16 and
  2026-08-19 instances with the sample hits.
