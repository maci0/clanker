# ADR 0007 — Scheduled entries fire on fixed UTC offsets, not on local time

## Status

Accepted. Part of [PRD 0009 — Scheduled runs](../prds/0009-schedule.md).

## Context

`clanker schedule` interprets a crontab-style spec — `0 9 * * 1-5` — as a wall
clock. Something has to say *whose* wall clock.

A crontab fires on the machine's local time, DST and all. Matching that needs a
time zone database: the rules are political, they change several times a year
somewhere in the world, and getting them right means either shipping the IANA
data or reading the host's. Zig's standard library has no tz support, so both
options are real work — vendoring and updating `tzdata`, or parsing
`/etc/localtime` and `TZ` and then handling the platforms where neither is what
you think it is.

And getting it *nearly* right is worse than not doing it. A DST transition is
where a scheduler either fires an entry twice (the hour that repeats) or skips
it (the hour that does not exist), and both failures are invisible until
someone reconciles a ledger months later. This is the part of a cron
implementation that is famously subtly wrong.

Three options were on the table:

1. **Read the host's local time.** What a crontab does, so it matches the
   thing being replaced. Requires the tz database, and puts the two DST edge
   cases squarely in the hot path with no way to unit-test them without
   fixtures for zones the test machine is not in.
2. **UTC only.** Zero ambiguity, zero dependency, trivially testable. Also
   means a person in Berlin who wants a 09:00 job writes `0 7 * * *` half the
   year and `0 8 * * *` the other half, or accepts that "morning" drifts.
3. **A fixed per-entry offset.** `tz_offset_minutes`, defaulting to 0. Pure
   arithmetic — shift the instant, decompose, match, shift back — so every
   case is a unit test with two integers in it. Says "09:00 at UTC+2" exactly,
   forever, and never guesses about a transition because it has no concept of
   one.

## Decision

Option 3. Each entry carries `tz_offset_minutes`, set by `--tz-offset`
(`+02:00`, `-05:00`, `UTC`, or a plain minute count) and defaulting to UTC. The
cron fields are read at that fixed offset. There is no DST handling, because
there is no time zone — only an offset.

## Consequences

Makes easy: `src/schedule/cron.zig` stays pure. No allocator, no clock, no
`std.Io`, no data files, and the awkward parts — leap years, month lengths, the
day-of-month/day-of-week rule, an offset that pushes a fire across a UTC date
boundary — are all functions of their arguments and all covered by tests that
run anywhere. The binary gains no dependency and no data to keep current.

Makes hard: an entry written for a zone that observes DST is wrong for half the
year in wall-clock terms. `0 9 * * 1-5 --tz-offset +01:00` is 09:00 in Berlin
in winter and 10:00 in summer. For "run the nightly review at some point in the
small hours" nobody notices; for anything that has to land at a particular
local hour, the operator edits the offset twice a year, which is a chore this
decision hands them.

Costs later, honestly: if real zones are ever wanted, the entry field has to
change from an offset to a zone name, which is a state-file migration, and
`nextAfter` grows a dependency it currently does not have. The signature would
survive — an offset is a degenerate zone — but the purity would not, and the
brute-force agreement test that currently validates the stepping search would
need zone fixtures to stay meaningful. Nothing about this decision blocks that
change; it just does not pay for it up front.
