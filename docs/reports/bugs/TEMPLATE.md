# Bug — <short, user-visible failure>

## TL;DR

- **What failed:** <one sentence>
- **Impact:** <who or what was affected>
- **Resolution:** <fixed by / still open / not yet known>

## Status

Open / Resolved / Reopened. Link the investigation that established the cause,
if one exists.

## Blocked on

Leave empty unless the fix needs something this machine does not have — a
credential, a live endpoint, an external reference that could not be
established. Name the concrete missing thing. While this body is non-empty the
improve backlog (`src/improve/backlog.zig`) will not seed the report to an
autonomous run: a loop that cannot obtain the missing thing can only guess,
and a test asserting the guess passes for the same reason the guess is wrong.
**Clear the body when the blocker lifts** — the empty section means "not
blocked" and puts the report back in the backlog.

## Symptom and impact

Describe the externally observable failure, its scope, and when it first
appeared. Keep raw logs or large traces in a linked artifact; quote only the
lines needed to identify the failure here.

## Reproduction

State the preconditions, the smallest reliable action sequence, and the
expected versus actual result. Say explicitly when reproduction is not yet
reliable.

## Root cause

Explain the mechanism that made the failure possible. Link the relevant source
paths, commits, and the investigation record; distinguish confirmed facts from
remaining hypotheses.

## Resolution

State the behavioral change, why it addresses the root cause, and any migration
or operational action required. Link the resolving commit or PR once available.

## Verification

List the checks that prove the fix covers the reproduction, plus their actual
result. Include tests, build gates, or production observations as appropriate.

## Follow-up

Record remaining risks, prevention work, or "none" with a short reason.

## References

- Investigation: <link or none>
- Code: <paths>
- Fix: <commit or PR>
