# Bug — the record stores accept a date-prefixed slug that contradicts the UTC date they stamp, with no warning

## TL;DR

- **What failed:** Every store stamps dates in UTC by design (doc_scaffold.civilFromUnix: 'a document dated by whichever machine wrote it is worse than one dated consistently'), but the caller supplies the slug, and create accepts a date-prefixed slug contradicting the stamp without a word. Local here is +08, so for about eight hours a day a hand-typed slug is off by one. Verified 2026-08-23 UTC: date -u +%F gives 2026-08-23 while date +%F gives 2026-08-24.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

Two clocks decide one record. `doc_scaffold.civilFromUnix` stamps every date the
store writes in UTC, deliberately, and says why in its own comment. The slug is
not stamped — the caller types it, and `create` takes it verbatim.

So a record filed while local and UTC dates differ is internally inconsistent:
`docs/reports/bugs/2026-08-24-foo.md` whose Status reads `Resolved on
2026-08-23`. Local here is `+08`, so the window is every evening — a third of
each day.

The impact is on retrieval, not correctness of the fix. Records are found by
listing a store and reading dates, and the two orderings disagree: filename
sort puts an evening record a day ahead of morning records it actually follows.
`clanker reports list` shows the stamped date, so a record can appear in the
list under a date its own filename contradicts.

It also propagates: a record cited by filename in a PRD or another record
carries the wrong date into prose that no filename scan can later correct.

## Reproduction

First-hand, 2026-08-23 UTC:

```
$ date -u +%F
2026-08-23
$ date +%F
2026-08-24
```

Filing anything with the local date then produces the split. At the time this
was found, `origin/main` (`b1bd7a6a`) carried four records slugged `2026-08-24-`
whose own Status lines read `Resolved on 2026-08-23` — renamed since, in PR
#386.

Also first-hand, the mirror image, which a filename sweep does not catch:
`docs/reports/bugs/2026-08-23-repl-composer-latches-into-paste-mode.md` had a
correct UTC slug and `Resolved on 2026-08-24` in both its TL;DR and its Status
section, because those lines were hand-written rather than stamped. Corrected in
the same change as this record.

Second-hand, from the reports of four parallel sessions working this repo on
2026-08-23/24 — not verified line by line here: 25 records were filed with
local-dated slugs and 21 renamed across two of those sessions before the
remaining four were caught. What is verified is that the class recurred
independently in every session that filed records that day.

## Root cause

`create` knows both values and compares neither. It has the caller slug in hand
and computes the UTC date to stamp the body, so the disagreement is available at
the moment it is introduced — nothing looks.

## Resolution

Open. Filed rather than fixed: the fix is a guest change across five stores and
this was a docs pass.

There is a real design question ahead of the code, and it should be settled
first. One prior session declined to file this at all, reasoning that since the
tool does not generate slugs, a mismatched date is a caller convention rather
than a tool defect. That is a fair reading of the current contract. The counter,
and the reason this is filed: the tool holds both values and the class recurred
in four independent sessions on one day, which is the point at which "the caller
should know better" stops being a workable contract.

Three shapes, cheapest first:

- **Warn.** `create` notices a leading `YYYY-MM-DD-` that is not the UTC date it
  is about to stamp and says so on stderr, creating the record anyway. Cheapest,
  and preserves the deliberate freedom to backdate a record about an older
  event.
- **Default it.** Accept a slug with no date prefix and stamp one, so
  `create bug gate-passes-on-unpatched-deps ...` becomes correct by
  construction. Removes the class instead of reporting it; needs a decision
  about what an explicitly-dated slug then means.
- **Refuse a mismatch.** Cleanest invariant, wrong for backdating, and the most
  likely to be worked around by callers who have a legitimate reason.

Whichever lands, the *body* half needs covering too: the paste-mode record above
had a correct slug and hand-written local dates inside, so a slug-only check
would have passed it. The durable fix for that half is for status notes never to
carry a hand-typed date, since `status` already stamps one.

## Verification

Whatever lands needs a control on both sides, or it can ship without ever
running: file a record with a slug matching the UTC date and confirm silence,
then file one deliberately off by a day and confirm the warning or refusal. A
check that fires on neither looks identical to one that fires on both until you
try the matching case.

Timezone is the awkward part to test. The bug only manifests where local and UTC
differ, so a test that reads the machine clock passes vacuously in UTC+0 —
which is what CI is. The date comparison wants to be a pure function of
(slug, stamped date) in `tools/zig/doc_scaffold.zig`, tested with both values
supplied, not derived.

## Follow-up

Applies to all five stores, not just reports: `research`, `rfc`, `adr` and `prd`
share `doc_scaffold` and the same split between a caller-supplied name and a
stamped body. The numbered three are partly shielded — their filenames lead with
an allocated number rather than a date — so reports and runbooks carry almost
all the exposure.

## References

- Related, same store, found the same day: [2026-08-23-reports-create-doubles-the-kind-label.md](2026-08-23-reports-create-doubles-the-kind-label.md), [2026-08-23-reports-rename-doubles-the-store-prefix.md](2026-08-23-reports-rename-doubles-the-store-prefix.md)
- Body-date instance corrected alongside this record: [2026-08-23-repl-composer-latches-into-paste-mode.md](2026-08-23-repl-composer-latches-into-paste-mode.md)
- Code: `tools/zig/doc_scaffold.zig` (`civilFromUnix`), `tools/zig/reports.zig`
- Slugs renamed for this class in PR #386
