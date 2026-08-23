# Bug — PRDs 0052 through 0057 each carry a second, unfilled copy of four template sections

## TL;DR

- **What failed:** Each of docs/prds/0052..0057 has two '## Failure modes', two '## Acceptance criteria' and two '## Open questions / future work' headings; the second copy of each is TEMPLATE.md's instruction prose verbatim. In 0052 the '## Known issues' body was the template's instructions too. 0058 and everything below 0052 are clean, so the affected set is exactly six consecutive records. What produced it is not established.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

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

## Verification

## Follow-up

## References

- Investigation: none yet
