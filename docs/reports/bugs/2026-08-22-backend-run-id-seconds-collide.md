# Bug — Two backend runs in the same second wrote one graph file

## TL;DR

- **What failed:** clanker run --backend grok twice in one second both used run-id run-<unix-seconds> and the second write replaced the first graph. The coding-agent driver now stamps run-<nanoseconds>. The in-process Agent.run still uses seconds.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-22. Driver uses nanoseconds; two live --backend grok runs wrote distinct graphs. Agent.run still seconds.

## Status

Resolved on 2026-08-22. Driver uses nanoseconds; two live --backend grok runs wrote distinct graphs. Agent.run still seconds.

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Symptom and impact

Two `clanker run --backend grok` launches in the same unix second produced one file `state/runs/run-1787371529.json`. The second persist replaced the first. Autolearn also wrote two run events with the same ts.

## Reproduction

1. Put a fake ACP agent named `grok` on PATH.
2. `clanker run --no-worktree --backend grok "a"` and immediately the same with `"b"`.
3. `ls state/runs` showed one `run-<seconds>.json` whose `task` was the second prompt.

## Root cause

`src/acp/driver.zig` minted `run-{started_at}` from unix seconds, the same shape `Agent.run` uses in `src/agent/loop.zig`. Two processes in one second share the name.

## Resolution

The coding-agent driver now stamps `run-{nanoseconds}` (still records `started_at` in seconds for listing). In-process `Agent.run` is unchanged.

## Verification

Two subsequent `--backend grok` launches wrote `run-1787371676502211794.json` and `run-1787371676630848521.json`, each with `output: "fake-acp-answer"`.

## Follow-up

`Agent.run` still uses seconds (`src/agent/loop.zig`). A pair of in-process `clanker run` in the same second would collide the same way; not fixed here.