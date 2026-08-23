# Bug — A reports status note is written verbatim in two places, so the store's own update verb cannot edit it

## TL;DR

- **What failed:** clanker reports status writes the resolution note into both the TL;DR '**Resolution:**' bullet and the '## Status' section as identical text. reports update then refuses that text with 'old text appears more than once; include more surrounding text', so the note the store just wrote is the one piece of a record its own update verb cannot address by its own words. Hit while resolving three serve bugs.
- **Impact:** Friction on the write path an agent is told to use for every fix it ships, not data loss. A resolution note cannot be corrected or extended through `update` by quoting itself, and the workaround people reach for -- editing the record by hand -- is what the store exists to prevent.
- **Resolution:** Resolved on 2026-08-23. update takes all/--replace-all and rewrites every copy, so a status note is editable by its own words; the refusal names the opt-out

## Status

Resolved on 2026-08-23. update takes all/--replace-all and rewrites every copy, so a status note is editable by its own words; the refusal names the opt-out

## Symptom and impact

`clanker reports status <path> <state> <note>` writes `<note>` into two places
in the record, byte-identical: the TL;DR bullet
(`- **Resolution:** Resolved on <date>. <note>`) and the `## Status` section
(`Resolved on <date>. <note>`). That duplication is deliberate -- the README
inventory keeps a third copy of the state, and a reader who stops at the TL;DR
should still learn the outcome.

The consequence is not deliberate. `clanker reports update` takes an exact
`old`/`new` pair and refuses a non-unique match:

```
error: reports: old text appears more than once; include more surrounding text
so the update is unambiguous
```

So a sentence `status` has just written is, by construction, the one piece of
prose in the record that `update` cannot address by its own words. Correcting
or extending a resolution note means either quoting enough neighbouring text to
disambiguate one copy (and then the two copies disagree), or running `status`
again with a rewritten note.

Impact is friction, not damage: nothing is lost and nothing is silently wrong.
It is worth a record because the workaround people will reach for -- editing the
file by hand -- is the thing the store exists to prevent, and because it lands
on the write path an agent is told to use for every fix it ships.

## Reproduction

Observed on `origin/main` b4f17a75, aarch64-macos, three times in one session:

```bash
clanker reports status docs/reports/bugs/<slug>.md resolved "<sentence>"
clanker reports update docs/reports/bugs/<slug>.md "<sentence>" "<other>"
```

The second command refuses. Any substring of the note that does not extend past
the two copies reproduces it.

## Root cause

Not investigated beyond the observable behaviour above. The uniqueness rule in
`update` and the two-copy write in `status` are each defensible on their own;
the defect is the interaction, and which of the two should give is a design
question, not a bug this record settles. Candidate shapes, none chosen:

- `status` could write a shorter derived line in the TL;DR rather than the note
  verbatim, leaving one editable copy.
- `update` could take an occurrence selector, or a section anchor.
- `status` could accept a note that replaces only the section, with the TL;DR
  line following mechanically.

## Resolution

The contract went to `update`, and it is now written down: the two copies are
one fact recorded twice, so an edit whose `old` matches both is meant for both.
`update` takes `"all":true` (`--replace-all` from the CLI) and rewrites every
occurrence, reporting how many it changed; without it the uniqueness refusal is
unchanged, and its message now names the opt-out instead of only asking for
more surrounding text.

Neither of the other two candidates was taken. Shortening the TL;DR line would
have cost a reader who stops there the sentence that says what the fix was,
which is the reason that copy exists at all; an occurrence selector or a section
anchor would have made every caller of `update` carry an index into a document
that the next append renumbers.

`status` is unchanged: it still writes the note into the TL;DR `Resolution`
bullet and the `## Status` section, and re-running it with a rewritten note
remains the shortest way to correct one that was simply wrong.

## Verification

- `test "spliceReplaceAll changes every copy and still refuses a missing
  target"` (tools/zig/doc_scaffold.zig) runs the two-copy record above through
  the new splice and reads both copies back rewritten, and still refuses a
  target that is not there at all.
- `test "update sends all only with --replace-all, and says how many copies
  changed"` (src/records/common.zig) pins the wire: no `all` field without the
  flag, `"all":true` with it, and a reply without `replaced` reading as one
  rather than zero.
- Live, on the built tool: a scratch bug report was resolved with a note,
  `clanker reports update <path> "<note>" "<edited>"` refused it with the new
  message, the same command with `--replace-all` answered
  `updated <path> (2 copies)`, and both the TL;DR bullet and the Status section
  read back edited. The scratch record was deleted.

## Follow-up

None. The TL;DR copy stays, for the reason it was added
([reports status updates the Status section but not the TL;DR](2026-08-16-reports-status-leaves-the-tldr-saying-open.md)),
and is now editable through the verb that wrote it.

The same `--replace-all` reaches the other four record stores, since they share
`updateRecord` and one flag. None of them writes a sentence twice today, so
there it is a capability rather than a fix.

## References

- `docs/reports/bugs/2026-08-16-reports-status-leaves-the-tldr-saying-open.md`
  -- why the TL;DR copy exists at all.
- Investigation: none
