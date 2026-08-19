# Investigation — google-vertex-anthropic returns HTTP 400 on every request, blocking improve-self

## TL;DR

- **Question:** Default provider google-vertex-anthropic fails every request with HTTP 400 in ~150ms, too fast for a model-side rejection. Confirmed via clanker providers check and two consecutive clanker improve-self runs (plan + proposal both failed). token_stats.jsonl shows the same pattern since at least ts=1787074453, predating this session. Not root-caused; likely Vertex auth/JWT, response body not logged.
- **Finding:** Investigating.
- **Resolution:** Pending.

## Status

Investigating.

## Trigger and scope

## Evidence

## Hypotheses and tests

## Finding

## Resolution or handoff

## References

- Related bug: none yet
A third improve-self attempt (targeting tools/zig/) failed differently: both the plan and proposal calls to google-vertex-anthropic got WriteFailed after 3 retries each (network-level, never got a response to classify as HTTP 400), not the earlier fast ~150ms HTTP 400. Two distinct failure modes on the same provider in one session (HTTP 400 vs WriteFailed) points more toward an intermittent connectivity or token-refresh problem than a single fixed bad-request bug.
A fourth improve-self attempt (targeting src/gate/) reverted to the original fast HTTP 400 (~150-400ms), same as the first two occurrences. So far: run 1 HTTP 400, run 2 HTTP 400, run 3 WriteFailed, run 4 HTTP 400 -- google-vertex-anthropic has now failed every clanker improve-self attempt made this session, 4/4, with no successful call recorded in that window.

## Finding (2026-08-19, re-evaluation)

The reason this could not be root-caused is itself a code defect, now confirmed and fixed: the vertex kinds parsed error bodies with their publisher codec only, which cannot read Google's platform envelope in the array-wrapped form rawPredict answers with, and both HTTP error paths discarded any body no codec recognised. Every platform-side refusal therefore surfaced as a bare 'HTTP 400'. Filed and resolved as docs/reports/bugs/2026-08-19-vertex-error-bodies-discarded.md. The request encoder was checked and is not implicated (anthropic_version body, model addressed in the URL). The operator-side 400 cannot be reproduced from this environment; with the fix, the next occurrence prints Google's own status and message in err_detail, the error log line, and token_stats.jsonl, which is what this investigation was missing.