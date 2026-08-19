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
