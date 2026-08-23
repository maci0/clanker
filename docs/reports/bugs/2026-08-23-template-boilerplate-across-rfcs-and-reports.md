# Bug — Template boilerplate and duplicated sections are in the RFC and report stores too, not just the six PRDs

## TL;DR

- **What failed:** 27 of the 36 numbered RFCs carry at least one section whose body is docs/rfcs/TEMPLATE.md's instruction prose verbatim, 7 of them also carrying two '## Next steps / action items'. 17 bug reports, 15 investigations and 1 runbook carry a duplicated heading, which has a different cause: reports create scaffolds empty '## Resolution' and '## Verification' headings and a later reports append writes a second copy rather than filling the first. Eight PRDs (0037, 0045-0051) also still carry template instruction paragraphs under their real content, without a duplicated section. Found while fixing the same defect in PRDs 0052-0057.
- **Impact:** Reading only, and the same cost the PRD bug had: `clanker rfc open` and `clanker reports open` print instructions or an empty scaffold as if they were the record, and a reader has two same-named sections to choose between. No code reads these files. Not fixed here: the RFC half needs a decision about `## Appendix`, and the reports half has a different cause worth fixing at the tool rather than by sweeping 33 records.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

Same reading cost as the PRD case: `clanker rfc open` and `clanker reports
open` print instructions, or an empty scaffold, as if they were the record, and
a reader has two sections of the same name to choose between. Nothing in code
reads these files, so there is no runtime impact.

Three populations, with two distinct causes.

**PRDs, the residue.** The six records the PRD bug named are clean. PRDs 0045
through 0051 and 0037 still carry the template's instruction paragraphs *under*
their real content in `## Status`, `## Problem`, `## Goals` and (0037)
`## Design` -- no duplicated section, so `templateDrift` in
`src/records/prd.zig` passes them today. Fourteen files were in that state
before the six were cleaned; eight are left.

**RFCs.** 27 of the 36 numbered records have at least one section whose body is
`docs/rfcs/TEMPLATE.md`'s prose for that same heading, verbatim. `## Appendix`
accounts for most of it (27 records), which may well be deliberate -- the
template's Appendix prose reads as an invitation and nobody deleted it. The
part that is not arguable is 0018 and 0022 through 0035: `## Open questions` and
`## Next steps / action items` are unfilled instruction prose, and in 0029
through 0035 there are two `## Next steps / action items` headings. Those seven
are the same authoring batch as PRDs 0052-0057 (RFC 0029 file-mentions pairs
with PRD 0052 composer-path-mention-expander), so it is one session's habit
showing up in both stores.

**Reports.** 17 records under `docs/reports/bugs/`, 15 under
`docs/reports/investigations/` and 1 runbook carry a duplicated heading. No
template prose is involved -- the scaffold writes those headings empty.

## Reproduction

```bash
for f in docs/rfcs/00*.md docs/reports/bugs/*.md docs/reports/investigations/*.md; do
  d=$(grep '^## ' "$f" | sort | uniq -d | tr '\n' ' ')
  [ -n "$d" ] && echo "$f :: $d"
done
```

For the RFC prose, split each record on `^## ` and compare each body against
`docs/rfcs/TEMPLATE.md`'s body for the same heading.

Measured at `origin/main` 52bfc739.

## Root cause

Different from the PRD case, and different between the two stores.

**Reports.** `tools/zig/reports.zig:536` scaffolds the record with every
section heading present and empty:

```
"\n## Status\n\nOpen.\n\n## Symptom and impact\n\n## Reproduction\n\n## Root cause\n\n## Resolution\n\n## Verification\n\n## Follow-up\n\n## References\n\n- Investigation: none yet\n"
```

`reports append` writes at the end of the file. So an author who investigates,
then appends what they found under `## Root cause`, gets a second `## Root
cause` at the bottom and leaves the scaffolded one empty above it. Every
affected record has that shape:
`2026-08-17-activity-view-shows-only-log-actions.md` has six empty scaffold
sections followed by a filled `## Evidence`, `## Resolution` and
`## Verification`. `update` is the verb that would have filled them, but an
empty section has no `old` text to match, which is what makes `append` the
path of least resistance.

**RFCs.** Not established, and not the same thing -- the prose is the
template's, so it is the PRD failure again: a section spliced in above the
copies the template already wrote, or simply never deleted.

## Resolution

Open. Deliberately not fixed alongside the PRD cleanup: 28 RFCs and 33 reports
are a much wider edit than the six records that bug named, several are actively
being edited by other sessions, and the `## Appendix` question needs a decision
(is the template's Appendix prose a placeholder or the intended default?)
rather than a sweep.

The pin that now guards the PRD store, `templateDrift` and `test "no PRD in the
live checkout carries template boilerplate"` in `src/records/prd.zig`, is
written against one store's directory and template on purpose. Pointing it at
`docs/rfcs` and `docs/reports` is a two-line change once those stores are
clean, and is the natural close for this report.

The reports half suggests one product change worth considering separately: a
scaffold that writes only the headings the author has content for, or an
`append` that fills a matching empty section instead of adding a second one.
Neither is obviously right; both are cheaper than re-cleaning this store a
third time.

## Verification

None -- nothing was changed. The counts above are what was measured.

## Follow-up

See Resolution. The PRD half of this is fixed and closed:
[PRD template boilerplate](2026-08-23-prd-template-boilerplate-left-in-six-records.md).

## References

- Investigation: none yet
