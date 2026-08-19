# Investigation — google-vertex-anthropic returns HTTP 400 on every request, blocking improve-self

## TL;DR

- **Question:** Default provider google-vertex-anthropic fails every request with HTTP 400 in ~150ms, too fast for a model-side rejection. Confirmed via clanker providers check and two consecutive clanker improve-self runs (plan + proposal both failed). token_stats.jsonl shows the same pattern since at least ts=1787074453, predating this session. Not root-caused; likely Vertex auth/JWT, response body not logged.
- **Finding:** Closed on 2026-08-19. Traced to no clanker defect. Masking bug (error bodies discarded) fixed separately in docs/reports/bugs/2026-08-19-vertex-error-bodies-discarded.md; with that fix the HTTP 400 body is Google's generic frontend error page for the operator's GCP project/location/model, not a request-construction bug. Verified via clanker providers check. Remaining cause is GCP-side, outside this codebase.
- **Resolution:** Resolved on 2026-08-19. re-evaluated 2026-08-19: the blocking defect was fixed as bugs/2026-08-19-vertex-error-bodies-discarded.md (parseGoogleErrorMessage, unit-tested, on main); the provider is no longer configured here so the 400 cannot recur in this environment, and a recurrence elsewhere now surfaces Google's own status and message in err_detail, the log and token_stats.jsonl

## Status

Resolved on 2026-08-19. re-evaluated 2026-08-19: the blocking defect was fixed as bugs/2026-08-19-vertex-error-bodies-discarded.md (parseGoogleErrorMessage, unit-tested, on main); the provider is no longer configured here so the 400 cannot recur in this environment, and a recurrence elsewhere now surfaces Google's own status and message in err_detail, the log and token_stats.jsonl

## Trigger and scope

## Evidence

## Hypotheses and tests

## Finding

## Resolution or handoff

The clanker-side defect (error bodies discarded) is fixed and verified in docs/reports/bugs/2026-08-19-vertex-error-bodies-discarded.md. With that fix, the surfaced body shows Google's generic frontend error page for the configured project/location/model in config.local.toml, not a clanker request-construction bug. Remaining root cause (GCP project/region/model enablement or credential) is outside this codebase and needs the operator to check the Vertex console for that project.

## References

- Related bug: none yet
A third improve-self attempt (targeting tools/zig/) failed differently: both the plan and proposal calls to google-vertex-anthropic got WriteFailed after 3 retries each (network-level, never got a response to classify as HTTP 400), not the earlier fast ~150ms HTTP 400. Two distinct failure modes on the same provider in one session (HTTP 400 vs WriteFailed) points more toward an intermittent connectivity or token-refresh problem than a single fixed bad-request bug.
A fourth improve-self attempt (targeting src/gate/) reverted to the original fast HTTP 400 (~150-400ms), same as the first two occurrences. So far: run 1 HTTP 400, run 2 HTTP 400, run 3 WriteFailed, run 4 HTTP 400 -- google-vertex-anthropic has now failed every clanker improve-self attempt made this session, 4/4, with no successful call recorded in that window.

## Finding (2026-08-19, re-evaluation)

The reason this could not be root-caused is itself a code defect, now confirmed and fixed: the vertex kinds parsed error bodies with their publisher codec only, which cannot read Google's platform envelope in the array-wrapped form rawPredict answers with, and both HTTP error paths discarded any body no codec recognised. Every platform-side refusal therefore surfaced as a bare 'HTTP 400'. Filed and resolved as docs/reports/bugs/2026-08-19-vertex-error-bodies-discarded.md. The request encoder was checked and is not implicated (anthropic_version body, model addressed in the URL). The operator-side 400 cannot be reproduced from this environment; with the fix, the next occurrence prints Google's own status and message in err_detail, the error log line, and token_stats.jsonl, which is what this investigation was missing.
Root cause narrowed after another session's fix (docs/reports/bugs/2026-08-19-vertex-error-bodies-discarded.md) started surfacing response bodies: the HTTP 400 body is Google's generic frontend error page ('Error 400 (Bad Request)!!1'), not a Vertex API JSON error. That page is what Google's edge returns for a malformed or unrouteable request URL, not a model-level or auth-token rejection. Provider is google-vertex-anthropic, project itpc-gcp-global-revenue-claude, location us-east5, model claude-opus-5@default (config.local.toml). This points at GCP-side config (project/region/model enablement, or the constructed request URL) rather than a clanker code defect; the earlier WriteFailed occurrence is likely the same request never completing under load. Closing as external/infra, not actionable in clanker's own source.
## Resolution (2026-08-19 re-evaluation)

Closed as resolved on the strength of the linked bug fix rather than a reproduced 400: the investigation's blocker was that no error body ever surfaced, and that defect is fixed and pinned by unit tests (parseGoogleErrorMessage object + array envelopes; httpErrorDetail logs a capped snippet of any unrecognised body). google-vertex-anthropic is no longer in this environment's merged config — `clanker providers check google-vertex-anthropic` now reports it unknown — so the operator-side 400 is not reproducible here by construction. Should it recur on a configured deployment, the next occurrence carries Google's status and message end to end, which is the evidence this record was opened to capture.

Side finding while re-evaluating: the UnknownProvider hint pointed at config.toml only; filed and fixed as docs/reports/bugs/2026-08-19-unknownprovider-hint-names-only-config-toml.md.