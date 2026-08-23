# Bug — A reports status note is written verbatim in two places, so the store's own update verb cannot edit it

## TL;DR

- **What failed:** clanker reports status writes the resolution note into both the TL;DR '**Resolution:**' bullet and the '## Status' section as identical text. reports update then refuses that text with 'old text appears more than once; include more surrounding text', so the note the store just wrote is the one piece of a record its own update verb cannot address by its own words. Hit while resolving three serve bugs; not fixed.
- **Impact:** Friction on the write path an agent is told to use for every fix it ships, not data loss. A resolution note cannot be corrected or extended through `update` by quoting itself, and the workaround people reach for -- editing the record by hand -- is what the store exists to prevent.
- **Resolution:** Open.

## Status

Open.

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

Open, and not implemented. Found while resolving three unrelated serve bugs
(#365, #368, #372); the record stores are not that change's surface and the
fix is a contract decision about two verbs, not a one-line correction.

## Verification

None -- nothing was changed. The reproduction above is what was observed.

## Follow-up

Whoever picks this up should decide the contract first, because a fix that
makes the note editable by dropping the TL;DR copy also changes what a reader
who stops at the TL;DR learns, and that copy was added on purpose (see
[reports status updates the Status section but not the TL;DR](2026-08-16-reports-status-leaves-the-tldr-saying-open.md)).

## References

- `docs/reports/bugs/2026-08-16-reports-status-leaves-the-tldr-saying-open.md`
  -- why the TL;DR copy exists at all.
- Investigation: none
