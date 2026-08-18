# Investigation — improve-self staging compile errors and recent_commits test failed the gate

## TL;DR

- **Question:** The improve-self batch that the repair/escalation runs were sent to fix failed its staging build on year % 4 in schedule_cron.zig (need @rem/@mod), then staging tests on utf8Valid/InvalidUtf8 in schedule_logic, then zig build test on recent_commits expecting no literal backslash-n in git history. Tracing whether those live in HEAD or only in rejected staging patches.
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
## Finding

The `year % 4` and `utf8Valid` errors lived only in rejected improve-self staging patches (`.clanker-worktrees/1786997462725223143-main/state/staging/`). HEAD `schedule_cron.zig` / `schedule_logic.zig` do not contain those lines.

The `recent_commits` gate failure is real and is in HEAD: the test searched raw JSON for the two-byte sequence backslash-n, and commit `83784944`'s subject literally mentions `\n`. Filed as docs/reports/bugs/2026-08-18-recent-commits-test-false-positive-on-backslash-n.md.

The rest of the 540-line improve-self dump is expected ERROR/WARN output from other unit tests (config validation, mock providers) that the log filter kept because they are severity ERROR.
## Resolution or handoff

The `year % 4` and `utf8Valid` errors lived only in rejected improve-self staging patches. HEAD `schedule_cron.zig` / `schedule_logic.zig` do not contain those lines.

The `recent_commits` gate failure is real and is in HEAD: filed as docs/reports/bugs/2026-08-18-recent-commits-test-false-positive-on-backslash-n.md. The host test now parses the tool JSON and asserts the `text` field has no raw newline.