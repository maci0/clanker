# Investigation — <symptom or question>

## TL;DR

- **Question:** <what this investigation set out to explain>
- **Finding:** <confirmed cause, current best explanation, or not a bug>
- **Resolution:** <fixed by / handoff / not applicable>

## Status

Investigating / Resolved / Closed — not a bug. State what evidence would move
the investigation to the next status.

## Trigger and scope

Describe the observed symptom, environment, time range, and impact. Link the
source log, issue, or bug report without treating it as proof by itself.

## Evidence

Record observations with enough context to be checked later: error excerpts,
reproduction results, source paths, and relevant configuration. Mark each item
as observed, reproduced, or inferred.

## Hypotheses and tests

List the hypotheses considered, the test or source trace used for each, and the
result. Retain rejected hypotheses when they prevent a tempting repeat of work.

## Finding

Explain the causal mechanism supported by the evidence, including why the
failure repeats or why it is limited to a particular condition.

## Resolution or handoff

If fixed, link the bug report and change that resolved it. If work remains,
name the smallest next change, its regression test, and the verification needed
to close this investigation.

## References

- Related bug: <link or none>
- Code: <paths>
- Logs or run: <location or none>
