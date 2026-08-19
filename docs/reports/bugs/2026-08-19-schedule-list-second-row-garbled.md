# Bug — schedule list rendered rows after the first as garbage from a freed buffer

## TL;DR

- **What failed:** parseEntries/parseLog stringified each row into an arena buffer, parsed Entry/Record leaky (string fields alias the buffer), then deinit'd the buffer; the next allocation overwrote the bytes, so schedule list printed header fragments and a spurious (bad spec) for valid rows while state/schedule.json was intact. Fixed by keeping the buffer alive for the arena's lifetime; regression test churns the arena and re-reads the strings.
- **Impact:** Any schedule of two or more entries looked corrupted from the CLI: later rows showed a wrong id, '(bad spec)' for a valid cron, and header fragments, sending the operator to debug a state file that was fine.
- **Resolution:** Resolved on 2026-08-19. kept the stringify buffer alive for the arena's lifetime in parseEntries/parseLog; regression test churns the arena, live list renders clean rows

## Status

Resolved on 2026-08-19. kept the stringify buffer alive for the arena's lifetime in parseEntries/parseLog; regression test churns the arena, live list renders clean rows

## Symptom and impact

`clanker schedule list` with two valid entries printed the first row
correctly and the second as:

```
 STAT   on            N       (bad spec)        -            0      LAST         RUNS   TASK
```

while `state/schedule.json` held two perfectly valid entries. Found
2026-08-19 while reproducing the run-due sweep bug
(docs/reports/bugs/2026-08-19-schedule-sweep-dies-with-capped-entry.md).

## Reproduction

Add any two entries, then `clanker schedule list` on a pre-fix build
(f47a6e7b or earlier). Row 2 renders garbage; `cat state/schedule.json`
shows intact data.

## Root cause

`parseEntries` and `parseLog` (src/schedule/command.zig) stringify each JSON
row into an `std.Io.Writer.Allocating` arena buffer, parse with
`std.json.parseFromSliceLeaky` — whose string fields alias the input bytes
for anything that needs no unescaping — and then `defer buf.deinit()`. The
arena reclaims the tail, the next allocation (the next row's buffer,
renderList's writer) overwrites it, and the parsed entry's id/cron/task now
point into whatever landed there. Row 1 often survives by allocation-order
luck, which misdirects suspicion at the data rather than the parse.

## Resolution

Drop the two `deinit`s: the parse result borrows the buffer, so the buffer
must live as long as the entries — which is exactly the arena's lifetime.
Comments on both sites state the aliasing contract.

## Verification

- Regression test "parsed entries survive later arena allocations": parse two
  entries, deliberately churn the arena (4 KiB splat, then renderList), then
  assert every string field reads back intact and the table has no
  "(bad spec)". 
- Live: two entries added on the fixed build render two clean rows.
  Control: the garbled row above, observed twice on the unfixed build.

## Follow-up

None.

## References

- Found while verifying docs/reports/bugs/2026-08-19-schedule-sweep-dies-with-capped-entry.md
- Investigation: none needed; root cause fell out of reading parseEntries
