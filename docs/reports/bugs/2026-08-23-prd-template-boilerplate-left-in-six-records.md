# Bug — PRDs 0052 through 0057 each carry a second, unfilled copy of four template sections

## TL;DR

- **What failed:** Each of docs/prds/0052..0057 has two '## Failure modes', two '## Acceptance criteria' and two '## Open questions / future work' headings; the second copy of each is TEMPLATE.md's instruction prose verbatim. In 0052 the '## Known issues' body was the template's instructions too. 0058 and everything below 0052 are clean, so the affected set is exactly six consecutive records. What produced it is not established.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-23. The six records are cleaned and a live-checkout test pins the store; prd create was re-run and renders the template exactly once, so the tool was not the cause.

## Status

Resolved on 2026-08-23. The six records are cleaned and a live-checkout test pins the store; prd create was re-run and renders the template exactly once, so the tool was not the cause.

## Symptom and impact

## Reproduction

## Root cause

Reproduce:

```bash
for f in docs/prds/00*.md; do
  n=$(grep -c '^## Failure modes' "$f")
  [ "$n" -gt 1 ] && echo "$f dup=$n"
done
```

Answers exactly `0052` through `0057`. In each, the *second* `## Failure
modes`, `## Acceptance criteria` and `## Open questions / future work` bodies
are `docs/prds/TEMPLATE.md`'s instruction prose verbatim ("A table: condition
-> behaviour. Every 'what happens when X goes wrong' answer a caller would
otherwise have to read the source to find out."), and several of the *first*
sections in the same files also still hold template prose under real content
(0052's `## Problem` and `## Goals` do).

Impact is on reading, not on code: `clanker prd open` prints the instructions
as if they were the record, and a reader diffing doc against code has two
Failure modes tables to choose from.

`0052`'s `## Known issues` was the template's instruction paragraph, which is
why a real entry replaced it as part of
[the mention-cap bug](2026-08-23-mention-over-cap-file-dropped.md).

**Not established:** whether `clanker prd create` appended `TEMPLATE.md`
after model-written content, or the authoring session pasted both. 0058 and
everything below 0052 are clean, which is weak evidence for a batch of
authoring rather than a standing tool defect, but nobody has re-run
`prd create` to check. Do that before changing `src/records/prd.zig` or
`tools/zig/doc_scaffold.zig`.

## Resolution

Two parts.

**The records.** The template-verbatim sections are gone from all six. In each
one that was the tail `## Failure modes`, `## Acceptance criteria` and
`## Open questions / future work`, the `## Non-goals` placeholder near the top
(the real Non-goals was written in below Design), and in 0053 through 0057 a
`## Known issues` that was the template's instruction paragraph as well --
TEMPLATE.md says to omit that section outright when there is no drift to
record. 0052's `## Known issues` is real content and stayed.

The second half of Symptom is fixed too: the template's instruction paragraphs
that sat *under* the real content in `## Status`, `## Problem` and `## Goals`
are gone from these six as well. 327 lines removed across the six, all of them
deletions, no real content touched and no section reflowed. Section *order* was left as authored: Non-goals now
reads after Design in these six rather than before it, which is cosmetic and
not worth a reflow of six files other sessions are also editing.

**The cause, which was open.** `clanker prd create` was re-run at
`origin/main` 52bfc739 and the record it produced has exactly one of every
section. So this is not a standing tool defect and `src/records/prd.zig` and
`tools/zig/doc_scaffold.zig` needed no change. The shape of the damage says
what did it: in all six, the real Design/Non-goals/Failure modes/Acceptance/
Open questions were spliced in *between* the template's `## Design` and its
`## Known issues`, and the template's own copies were left below. That is one
`prd update` replacing the Design placeholder with a block that carried extra
`## ` headings -- not `append`, which writes at the end.

Because nothing in the tool can tell a real section from a pasted one, the
guard is a test rather than a refusal: `templateDrift` plus `test "no PRD in
the live checkout carries template boilerplate"` in `src/records/prd.zig`.

## Verification

`zig build test` on the six cleaned records passes; run against them as they
were, the live-checkout test fails naming the first offender
(`0053...: '## Non-goals' is still the template's instruction prose`).
`templateDrift` itself has a unit test over synthetic input for both verdicts,
duplicate heading and unfilled prose.

## Follow-up

The residue reaches further than the six: PRDs 0045 through 0051 and 0037 still
carry template instruction paragraphs under their real content, though none of
them has a duplicated section. That is why `templateDrift` matches a whole
section body rather than a paragraph -- tightening it to paragraphs is the
right end state and is a few lines, but it has to follow the sweep, not lead
it. The same authoring accident is in the RFC store and, in a different shape,
in the reports store; both filed separately as
[template boilerplate in the RFC store](2026-08-23-template-boilerplate-across-rfcs-and-reports.md).
That is why the pin walks `docs/prds` only for now: the other stores would fail
it today.

## References

- Investigation: none yet
