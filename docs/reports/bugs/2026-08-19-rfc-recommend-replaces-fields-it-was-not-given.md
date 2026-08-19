# Bug — rfc recommend replaces existing Why-this-confidence and Reversibility text with template placeholders

## TL;DR

- **What failed:** clanker rfc recommend on RFC 0019 (2026-08-19) landed the recommendation, confidence and rationale but replaced the existing Why-this-confidence and Reversibility paragraphs with TEMPLATE.md placeholders: the guest accepts optional moves_confidence/reversibility inputs and writes placeholders when absent (tools/zig/rfc.zig:500,:506), and the CLI verb offers no way to pass either field. Restored via rfc update in the same pass.
- **Impact:** operator-written Recommendation paragraphs are silently discarded by every CLI recommend; recoverable here only because the edit ran in a git worktree.
- **Resolution:** Resolved on 2026-08-19. recommend keeps existing Why-this-confidence/Reversibility paragraphs when the inputs are absent (doc_scaffold.fieldParagraph); verified live on RFC 0019 byte-identical, plus guest and host tests

## Status

Resolved on 2026-08-19. recommend keeps existing Why-this-confidence/Reversibility paragraphs when the inputs are absent (doc_scaffold.fieldParagraph); verified live on RFC 0019 byte-identical, plus guest and host tests

## Symptom and impact

`clanker rfc recommend docs/rfcs/0019-shared-state-store.md "<rec>" 7 "<rationale>"`
reported success, and the diff showed the whole `## Recommendation` section
rebuilt: the three given fields written, and the two not given — the RFC's
existing **Why this confidence** and **Reversibility** paragraphs — replaced
by the TEMPLATE.md placeholder lines (`_State what evidence would raise
it..._`, `_How hard is this to undo..._`).

Impact: any CLI `recommend` on an RFC whose Recommendation section already
carries those two paragraphs silently discards them. On a plain checkout with
no concurrent git safety net, that is unrecoverable data loss of
operator-written reasoning. RFC 0019's paragraphs were restored in the same
pass via `rfc update`, so nothing was lost this time.

## Reproduction

On any RFC whose Recommendation section has filled-in Why-this-confidence and
Reversibility paragraphs:

```bash
clanker rfc recommend docs/rfcs/<rfc>.md "some recommendation" 7 "some rationale"
```

Open the RFC: both paragraphs now hold the template placeholders.

## Root cause

Read at source, `tools/zig/rfc.zig` `recommend` (line 474):

- The guest accepts **optional** `moves_confidence` and `reversibility`
  inputs (`:487-488`) and, when they are absent, writes the template
  placeholder lines instead (`:500`, `:506`).
- The section is written with `doc.replaceSection` over the whole
  `## Recommendation` block (`:511`), so whatever the section held before is
  gone.
- The CLI verb (`recommend <path> <recommendation> <confidence> [rationale]`,
  `src/records/rfc.zig`) exposes no way to pass either optional field, so
  from the CLI the absent-field branch always runs.

Two candidate fixes, not decided here: teach the guest to preserve the
existing text of a field it was not given (keep-existing instead of
write-placeholder), and/or add the two optional arguments to the CLI verb.
Keep-existing is the safer default — it makes the destructive path
unreachable rather than avoidable.

## Resolution

Resolved on 2026-08-19 with the keep-existing default the Root cause names as
the safer fix: `recommend` in `tools/zig/rfc.zig` now reads the section's
current **Why this confidence** and **Reversibility** paragraphs
(`doc_scaffold.fieldParagraph`, a new pure helper) and re-emits them whenever
the matching input is absent, so the placeholder branch runs only when the
section holds no such paragraph at all. The destructive path is unreachable
rather than avoidable: a caller that cannot pass the fields — the CLI verb
still passes neither — can no longer erase them. Passing either input still
replaces that field, unchanged.

## Verification

- The reproduction above, run live on RFC 0019 (2026-08-19): a CLI-shaped
  `recommend` given only path/recommendation/confidence/rationale left both
  paragraphs byte-identical (`diff` of the extracted field lines before and
  after), which is exactly the bar this section set when the report was
  opened.
- Guest test in `src/sandbox/runtime.zig` (`rfc wasm tool ...`): recommend
  with both fields, then recommend without them, asserting both survive and
  no template placeholder is present.
- Host tests for the extraction helper:
  `fieldParagraph reads a wrapped bold-led paragraph and reports an absent one`
  in `tools/zig/doc_scaffold.zig`.
- Full gate green in the fix worktree: `zig build`, `zig build tools`,
  `zig build test --summary all` — 320/320 steps, 1672/1683 passed,
  11 skipped, 0 failed. `zig fmt --check` clean on the three touched files.

## Follow-up

- The CLI verb still offers no way to pass `moves_confidence`/`reversibility`;
  with keep-existing in place that is an ergonomic gap, not a data-loss one.
  Adding two optional arguments (or flags) to `clanker rfc recommend` remains
  open.
- A template-fresh RFC's guidance paragraphs are now preserved verbatim by a
  field-less recommend instead of being swapped for the one-line underscore
  placeholders; both are filler awaiting a real answer, so nothing is lost,
  but the two spellings of "not written yet" now coexist.

## References

- `tools/zig/rfc.zig:474-516` — the recommend action.
- [docs/rfcs/0019-shared-state-store.md](../../rfcs/0019-shared-state-store.md)
  — the RFC it fired on; paragraphs restored via `rfc update` 2026-08-19.
