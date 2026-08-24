# Investigation — The release-contract gate does not require a CHANGELOG entry per change

## TL;DR

- **Question:** Does the `release-contract` gate require a CHANGELOG entry for every change, as two sessions' agents were briefed on 2026-08-24?
- **Finding:** Resolved on 2026-08-24. The gate is four structural checks and never reads the diff; the per-change entry is CONTRIBUTING.md convention for consumer-visible changes, now stated at both convention sites
- **Resolution:** Resolved on 2026-08-24. The gate is four structural checks and never reads the diff; the per-change entry is CONTRIBUTING.md convention for consumer-visible changes, now stated at both convention sites

## Status

Resolved on 2026-08-24. The gate is four structural checks and never reads the diff; the per-change entry is CONTRIBUTING.md convention for consumer-visible changes, now stated at both convention sites

## Trigger and scope

On 2026-08-24 one session briefed five parallel agents that "CHANGELOG.md is
required by the release-contract gate". All five added entries to their PRs,
and several then resolved avoidable merge conflicts in `CHANGELOG.md` against
each other. A second session inherited the claim through peer coordination
and repeated it in two more PRs the same day. The outcome was harmless —
every one of those changes was consumer-visible and warranted an entry by
convention — but the stated mechanism was never checked against the gate's
source, and it shaped how seven PRs were sequenced.

Scope: what `releaseContractGate` actually enforces, where the per-change
entry requirement really comes from, and what that means for records-only
and docs-only PRs.

## Evidence

`releaseContractGate` (`src/gate/checks.zig:1306` as of `b230b1c7`) performs
exactly four checks, in order:

1. `build_options.version` parses as SemVer.
2. `CHANGELOG.md` is readable and contains the literal `## [Unreleased]`.
3. `README.md` contains both the strings `CHANGELOG.md` and `RELEASES.md`.
4. `RELEASES.md` contains the string `build.zig.zon`.

It never opens a diff, never shells out to git, and takes no changed-file
list as a parameter. Verified independently by both sessions, reading the
function rather than each other's summaries.

Why the belief never self-corrected: the gate's own unit test,
`releaseContractGate accepts the live release files`, asserts that the
repository's current files pass. A check that is structurally always green
on a healthy tree cannot contradict a false belief about what it enforces —
no PR ever failed it for lacking an entry, so "it requires an entry" was
never falsified by a run.

## Hypotheses and tests

- *"The gate requires a per-change CHANGELOG entry"* — *refuted* by the
  function body above: there is no diff input for such a check to read.
- *"Some other gate enforces the entry"* — *refuted* for the `gate` verb's
  twelve checks: `CHANGELOG.md` appears in gate code only inside
  `releaseContractGate`, and no gate inspects `CONTRIBUTING.md` or
  `CLAUDE.md` prose either.

## Finding

The per-change entry is an obligation of **convention, not mechanism**. It is
stated in `CONTRIBUTING.md` and `CLAUDE.md` ("every consumer-visible change",
Keep a Changelog format), and it matters because release notes are extracted
from the changelog — a shipped consumer-visible change without an entry never
appears in them. The `release-contract` gate does not enforce it, so a
missing entry ships green; the obligation binds authors and reviewers, not
the gate.

Consequences:

- A consumer-visible change still requires an entry. Nothing here loosens
  that; the gate simply is not what makes it true.
- Records-only, docstring-only, and internal-docs-only changes are not
  consumer-visible and need no entry — and skipping the entry also removes
  the one file where parallel sessions' PRs habitually conflicted.

## Resolution or handoff

The two places the convention is stated now also say the gate does not
enforce it (same change as this record), so the next reader cannot re-derive
the false mechanism from silence. No code change: making the gate diff-aware
was considered and not proposed — "consumer-visible" is a judgement the
structural gate cannot make, and a mechanical "diff touches CHANGELOG.md"
rule would misfire on exactly the records-only PRs this finding exempts.

## References

- Code: `src/gate/checks.zig` (`releaseContractGate`)
- Convention: `CONTRIBUTING.md` (release notes paragraph), `CLAUDE.md`
  (repository layout, `CHANGELOG.md` bullet)
- Related bug: [2026-08-24-blocked-on-body-is-an-ungated-fourth-state-signal](../bugs/2026-08-24-blocked-on-body-is-an-ungated-fourth-state-signal.md)
  — same day, same shape: a machine-honoured rule whose enforcement story
  had never been checked against the code.
