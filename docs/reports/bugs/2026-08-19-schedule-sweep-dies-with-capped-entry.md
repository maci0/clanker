# Bug — A capped scheduled run takes the whole run-due sweep down with it

## TL;DR

- **What failed:** cmdRun called std.process.exit(1) on MaxIterationsExceeded/SessionTokenBudgetExceeded/CompactionStalled and on every other run error, so one failing entry killed the sweep: its outcome never reached the ledger and later due entries never fired. Fixed by Options.nested_run: ScheduleFire sets it and cmdRun returns the error instead of exiting, so the runner records ok:false and continues.
- **Impact:** One broken schedule entry silently starved every entry behind it in the same sweep, and the ledger showed nothing for the entry that failed.
- **Resolution:** Resolved on 2026-08-19. Options.nested_run: ScheduleFire sets it, cmdRun returns errors instead of exiting; verified live — capped entry recorded ok:false, next entry fired, run-due exited non-zero

## Status

Resolved on 2026-08-19. Options.nested_run: ScheduleFire sets it, cmdRun returns errors instead of exiting; verified live — capped entry recorded ok:false, next entry fired, run-due exited non-zero

## Symptom and impact

`clanker schedule run-due` with two due entries, the first of which hits a
token/iteration cap, fires the first entry and then the process exits 1:

- the first entry's outcome is never appended to `state/schedule/log.jsonl`
  (its window stays claimed, `last_status` is left at `"running"`),
- the second due entry never fires in that sweep.

PRD 0009 documented this in Known issues and carried an unchecked acceptance
box for it. The failure-mode table's promise — "a failing entry does not stop
the other entries in the sweep" — was proven only through the test-only `Fire`
callback; the real callback (`ScheduleFire.call` → `cmdRun`) exited before the
runner's catch could run.

## Reproduction

In a worktree with a live provider (DeepSeek), `agent.max_total_tokens = 1`
and `goal_worktree = "no"` in config.local.toml:

1. `clanker schedule add "* * * * *" "Use the list_files tool …"` (forces a
   tool call, so the budget check fires) and a second entry
   `"Reply with exactly the word OK …"`.
2. Wait for the minute window, run `clanker schedule run-due` on an unfixed
   build (677722dc).

Observed (control): `token budget reached` → process exit 1, no ledger file
written at all, entry 2 unfired.

## Root cause

`cmdRun` (src/cli.zig) treats every run error as end-of-process: the capped
outcomes call `reportUnfinishedRun` then `std.process.exit(1)`, and the
generic path prints the enriched detail then exits too. That is right when
`clanker run` is the whole invocation and wrong when cmdRun is one entry in a
`schedule run-due` sweep: the exit skips `fireOne`'s catch in
src/schedule/runner.zig, which is where ok:false, the error name, and the
ledger line come from.

## Resolution

`Options.nested_run` (src/cli.zig), set only by `ScheduleFire.call`. When set,
all three cmdRun error paths (goal-loop catch, capped-outcome switch arm,
generic run error) return the error to the caller instead of exiting. The
outermost `clanker run` / `goal` / `workflow run` invocations keep the exit
and the human-facing enriched detail unchanged.

## Verification

Same setup as the reproduction, fixed build, both entries due in one window:

```
sch-1: SessionTokenBudgetExceeded in 2249ms
sch-2: ok in 2181ms
error: ScheduledRunFailed
```

Ledger got both lines — `"id":"sch-1","ok":false,"err":"SessionTokenBudgetExceeded"`
then `"id":"sch-2","ok":true` — and run-due still exited non-zero so the
invoking cron notices, matching the failure-mode table. The unfinished-run
report is still printed before the error is handed back.

## Follow-up

- `schedule list` renders its second row garbled (header fragments plus a
  spurious `(bad spec)`) while `state/schedule.json` is valid — found while
  reproducing this, tracked separately in
  docs/reports/investigations/2026-08-19-schedule-list-second-row-garbled.md.

## References

- PRD: docs/prds/0009-schedule.md (Known issues, failure modes, acceptance)
- Investigation: none — straight from the PRD's Known issues entry
