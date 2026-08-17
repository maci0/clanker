# Bug — session_search and spill list broke their JSON shape on empty stores, failing improve-self capability evals

## TL;DR

- **What failed:** On a fresh checkout (state/ is gitignored, so state/sessions and state/spills do not exist), session_search returned plain text "no saved conversations" and spill list returned "no spilled tool results" instead of the documented structured JSON. The improve-self capability gate runs these as evals; both scored 0.00 FAIL, so every staged tree was rejected with "staged tree failed its own capability evals" and the improve batch stopped after iterations 1 and 2.
- **Impact:** improve-self stopped the batch after iterations 1 and 2 because every staged tree failed its own capability evals, so no improvement could land.
- **Resolution:** Resolved on 2026-08-17. session_search and spill list now return structured JSON on empty stores; both capability evals pass (exit 0) and the full gate is green. Committed 7bcfddea and pushed to main.

## Status

Resolved on 2026-08-17. session_search and spill list now return structured JSON on empty stores; both capability evals pass (exit 0) and the full gate is green. Committed 7bcfddea and pushed to main.

## Symptom and impact

From a failed improve-self batch (ts_ms=1786943...):

```
[WARN] request_id=improve capability evals: 3 case(s) failed; retrying only those
[ERROR] request_id=improve staged tree failed its own capability evals:
[ERROR] request_id=improve session_search: 0.00 FAIL
[ERROR] request_id=improve spill: 0.00 FAIL
[WARN] request_id=improve iteration 1: all attempts failed
[WARN] request_id=improve iteration 2: all attempts failed
```

The two failing evals (session_search, spill) both scored 0.00 because each tool returned a plain-text message instead of structured JSON. The third failed eval, `reasoning: 0.50 FAIL`, was a model-compliance flake (see below). A third symptom — `staging build failed: src/tui/turn_stats.zig:145:14 error: member function expected 2 argument(s)` — was in the improve loop's own staged intermediate and is not present in committed code.

## Reproduction

On a checkout with no `state/` (state/ is gitignored; created lazily on first write):

- `session_search {"q":"the"}` returned `{"ok":true,"text":"no saved conversations"}` (via `lib.okText`), not `{"ok":true,"hits":[...]}`.
- `spill {"list":true}` returned `{"ok":true,"text":"no spilled tool results"}`, not `{"ok":true,"spills":[...]}`.

The evals `evals/session_search.task.json` and `evals/spill.task.json` assert exactly the structured shape; plain text with no `"ok"`/`"hits"`/`"spills"` field fails both criteria → 0.00.

## Root cause

In `tools/zig/sessions.zig` `searchSessions` and `tools/zig/spill.zig` `listSpills`, the `error.NotFound` path (store directory absent) returned a human-oriented plain-text `okText` message, breaking the documented JSON output shape that machine callers — the capability evals and the HTTP relays — depend on.

## Resolution

`tools/zig/sessions.zig` and `tools/zig/spill.zig` now always return structured JSON. An empty store is a valid empty list, not a failure: `searchSessions` returns `{"ok":true,"query":...,"hits":[]}` and `listSpills` returns `{"ok":true,"spills":[]}`.

The `reasoning: 0.50` eval was not a defect: `tools/zig/reasoning.zig` already returns the documented shapes (`ok:true` with traces, or `ok:false` error "no reasoning traces yet" when the file is absent). The 0.50 is `scoreAnswer` returning the satisfied-fraction when the model answered something containing neither `SHAPE_OK` nor `SHAPE_BAD`; a re-run passed. `turn_stats.zig:145` in committed code already passes the multi-arg `w.print`, so the staging compile error was an artifact of the loop's intermediate tree, not a code defect.

## Verification

- `zig build tools` and the full gate (`zig build`, `zig build test`, `zig build tools`) are green.
- `clanker eval session_search --tasks --provider deepseek --model deepseek-v4-flash` → exit 0.
- `clanker eval spill --tasks --provider deepseek --model deepseek-v4-flash` → exit 0.
- `clanker eval reasoning --tasks --provider deepseek --model deepseek-v4-flash` → exit 0.
- Committed `7bcfddea` on `main` and pushed to origin/main.

## Follow-up

## References

- Investigation: none yet
