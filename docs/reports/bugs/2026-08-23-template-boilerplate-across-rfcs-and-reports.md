# Bug — Template boilerplate and duplicated sections are in the RFC and report stores too, not just the six PRDs

## TL;DR

- **What failed:** 27 of the 36 numbered RFCs carry at least one section whose body is docs/rfcs/TEMPLATE.md's instruction prose verbatim, 7 of them also carrying two '## Next steps / action items'. 17 bug reports, 15 investigations and 1 runbook carry a duplicated heading, which has a different cause: reports create scaffolds empty '## Resolution' and '## Verification' headings and a later reports append writes a second copy rather than filling the first. Eight PRDs (0037, 0045-0051) also still carry template instruction paragraphs under their real content, without a duplicated section. Found while fixing the same defect in PRDs 0052-0057.
- **Impact:** Reading only, and the same cost the PRD bug had: `clanker rfc open` and `clanker reports open` print instructions or an empty scaffold as if they were the record, and a reader has two same-named sections to choose between. No code reads these files. The reports cause is fixed (append now fills a matching empty section); the RFC half needs a decision about `## Appendix`, and the residue in 33 reports, 27 RFCs and 8 PRDs is still a sweep nobody has taken.
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

The reports half of the *cause* is fixed, 2026-08-23. Of the two product changes
this record floated, the second was taken: `append` now fills a matching empty
section instead of adding a second copy of its heading. `doc.appendOrFill`
(tools/zig/doc_scaffold.zig) splices a block whose first line is a heading the
record already carries **empty** into that section, and falls back to appending
at the end when the section has any body at all, is not there, or the block does
not open with a heading -- moving an author's paragraph under someone else's
text would be a worse failure than the duplicate heading. All five record stores
share it, so the RFC store cannot re-acquire the shape either, and the reply
says `filled <heading>` rather than `appended to <path>` so a caller can tell
which happened.

The first change -- a scaffold that writes only the headings the author has
content for -- was not taken. The empty headings are what tells an author which
questions the record has to answer, which is most of what the scaffold is for.

Still open, and what keeps this record open: the 33 records already carrying a
duplicated heading, the RFC template prose in 27 records, the `## Appendix`
decision, and the eight PRDs with instruction paragraphs under real content.
None of those is a cause; they are residue, and the sweep is still the wide edit
this record declined.

## Verification

The counts above are what was measured, and nothing was swept.

What the `append` fix is verified by:

- Four `appendOrFill` tests in tools/zig/doc_scaffold.zig: filling a scaffold
  section (asserting one heading, not two, and the blank lines around it),
  filling a trailing section without growing a blank line, and the three
  fall-through cases (section with a body, section absent, block with no
  heading) plus the two near-misses that must not match -- a `###` block
  against a `##` section, and `## Root` against `## Root cause`.
- Live, on the built tool: this fix's own record,
  `2026-08-23-reports-create-doubles-the-kind-label.md`, was written entirely
  through `clanker reports append`, one section at a time, each answering
  `filled ## <section> in <path>`; it carries nine headings and no duplicates.
  Control, on the same tree with the guest changes stashed and
  `zig build tools` re-run: the same append against a scratch record left two
  `## Root cause` headings, the filled one dangling below `## References`.

## Follow-up

See Resolution. The PRD half of this is fixed and closed:
[PRD template boilerplate](2026-08-23-prd-template-boilerplate-left-in-six-records.md).
The reports half of the *cause* is fixed as of 2026-08-23; the residue in the
three stores is not, and that is what keeps this record open.

## References

- Investigation: none yet
## Note — `## References` can never be filled, only appended (2026-08-23)

Observed twice while filing two new reports with the post-fix binary, so it is a
standing hole in `appendOrFill` rather than a one-off.

`appendOrFill` splices a block into a section the record carries **empty**.
`create` seeds `## References` with `- Investigation: none yet`, so that section
is never empty, and a `## References` block therefore always lands at the end of
the document as a second heading:

```
appended to docs/reports/bugs/2026-08-23-record-slug-date-contradicts-the-stamped-date.md
```

against `filled ## Verification` and `filled ## Follow-up` on the same record
moments earlier. Both new records needed a hand `update` to collapse the
duplicate.

So of the scaffolded sections, `## References` is the one the fix structurally
cannot reach. Two candidate fixes, neither taken here: scaffold the section
empty and let the first append fill it, or teach `appendOrFill` to treat a
section whose entire body is the scaffolded placeholder as empty. The second
generalises — `- Impact: To be confirmed.` in `## TL;DR` has the same shape.

## Note — the `## References` hole is closed (2026-08-24)

Fixed, in `doc_scaffold.appendOrFill`: the second of the two candidates the note
above floated was taken. A section whose entire body is the scaffold's own
placeholder now counts as empty, so `## References` fills like every other
scaffolded section instead of landing at the end as a second heading.

`isPlaceholderBody` is the test, and it is narrow on purpose: every non-blank
line in the body has to be a list item ending in "none yet". That covers all
four wordings `create` writes (`- Investigation:`, `- Related bug:`,
`- Related record:`, `- Report:`) and nothing else. One authored reference in
the section and it has a real body again, so the block goes to the end and no
author's line is displaced — which is the same bar the original fill set.

The generalisation the note suggested was deliberately *not* taken: `- Impact:
To be confirmed.` in `## TL;DR` has the same shape, but `## TL;DR` also carries
the caller's summary, so its body is never only placeholder and treating a
mixed body as fillable would be the "move someone else's paragraph" failure the
original fix refused. The rule as written declines that case by construction.

Verified both ways on the built binary, not only in unit tests: an append of a
`## References` block to a freshly created record answered `filled ##
References in <path>`, the record carries one `## References` heading, and the
`none yet` line is gone. Two new tests pin it — the fill against the scaffold
body, and eleven cases on `isPlaceholderBody` including the two that must *not*
match (a real reference beside a placeholder, and prose rather than a list
item).

What still keeps this record open is unchanged: the 33 records already carrying
a duplicated heading, the RFC template prose in 27 records, the `## Appendix`
decision, and the eight PRDs with instruction paragraphs under real content.
None of those is a cause, and the sweep is still the wide edit this record
declined.
## Partial sweep, 2026-08-24 — the complete trailing scaffold blocks

Eleven report records carried a **complete** `reports create` bug scaffold
appended at end of file — all six of `## Reproduction`, `## Root cause`,
`## Resolution`, `## Verification`, `## Follow-up`, `## References` present,
every one of them empty (or holding only the `- Investigation: none yet`
placeholder), while the same headings above carried the real content. Removed.

Detection criterion, deliberately strict so the edit is reviewable: the trailing
run must be exactly that six-heading set, every body empty by the same rule
`isPlaceholderBody` uses, and at least one of those headings must already carry
content earlier in the record. `## Blocked on` is never removed — an empty body
there is the store's own convention for 'not blocked'.

Files: advisor-block-leaks-into-message-zero, advisor-model-never-read,
auto-thinking-classifies-every-iteration, dump-config-header-redaction-cuts-on-equals,
hook-command-trim-set-is-mis-escaped, improve-history-read-failure-reads-as-empty,
improve-merge-pin-advances-before-the-resync, learnings-prompt-keeps-the-oldest-notes,
preset-tool-filter-is-inert, profile-overlay-errors-name-the-wrong-file,
gemini-thinking-row-inert.

Verified by auditing every removed line rather than trusting the script: the
whole diff is 77 blank lines, 66 `## ` headings (11 x 6), and 11
`- Investigation: none yet` placeholders. **No prose line was removed.**

## What is left, measured

**83 empty duplicate headings across 34 records** still remain in
`docs/reports/` and `docs/runbooks/`. These are *partial* runs, not whole
scaffold blocks, and they were left alone on purpose: two defensible algorithms
for grouping a partial run disagreed on where its boundary falls (one reported
31 files / 128 headings, another 11 / 61, and one record's count moved between
them). A boundary that shifts with the algorithm is a per-record judgement, not
a mechanical sweep, and mass-editing on the looser rule would have produced a
diff nobody could review.

A first attempt was looser still and would have touched 72 files: it stripped
any trailing empty section, which also deletes a legitimately unfilled final
`## Follow-up` or `## References`. That is scaffold structure, not residue.
Recording the wrong version here because the difference is the whole lesson —
'empty at the end' and 'a duplicate that was never authored' are not the same
predicate.

The RFC half of this record is untouched: it needs the `## Appendix` decision
this record already calls for, which is a judgement about intent rather than a
sweep. The eight PRDs carrying instruction prose under real content are also
untouched.

This record therefore stays **Open**.
