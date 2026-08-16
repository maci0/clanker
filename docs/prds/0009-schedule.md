# PRD — Scheduled runs (`clanker schedule`)

## Status

Shipped. Sources of truth: `tools/zig/schedule_cron.zig` (the dialect and the
next-fire arithmetic, pure, host-tested), `src/schedule/store.zig`
(`state/schedule.json` + `state/schedule/log.jsonl`),
`src/schedule/runner.zig` (due selection, claiming, firing, the ledger),
`src/schedule/command.zig` (the operator surface), and the `schedule` guest
(`tools/zig/schedule.zig`) which owns list/toggle/add/remove. Surface: CLI
`clanker schedule [list|add|remove|enable|disable|run|run-due|log]`
(`Command.schedule` in `src/cli.zig`, which contributes the flag table, one
dispatch arm, and the callback that turns an entry into a `cmdRun`), plus a
web UI Schedule view (`ui/plugins/schedule/`) over
`GET /api/schedule` (entries with next-fire times and a ledger tail) and
`POST /api/schedule/<id>` `{"enabled": bool}`, both relayed to the guest.
The browser reads the schedule and can enable/disable an entry; nothing in
the browser fires one.

There is no always-on loop and no WASM tool over this state. Both are
deliberate; see Non-goals.

## Problem

Everything recurring about clanker today happens outside clanker. `docs/
ROADMAP.md`'s Pi/Odysseus audit put it plainly: recurring runs depend entirely
on an external cron calling `clanker run`, `scripts/clanker-improve.sh` or
`scripts/clanker-review.sh`, so the harness has no idea any of it exists. Three
concrete costs:

- **Nothing is recorded.** A crontab line that fires at 03:00 and fails leaves
  nothing in `state/`. `clanker graph` shows the run if it got far enough to
  make one; nothing anywhere says a schedule exists, when it last fired, or
  whether it has been failing for a week.
- **The schedule is not portable and not introspectable.** It lives in a user's
  crontab. Another clanker instance, the web UI, and the agent itself cannot
  see it, and a fresh checkout starts with none of it.
- **A sleeping machine is a silent hole.** `cron` on a laptop that was closed
  overnight simply skips the windows. `anacron`-style catch-up is the usual
  fix, and it is the wrong one here: an agent run costs money, and 288
  backfilled runs of a `*/5` job is a bill, not a recovery.

The constraint that shapes the design: clanker is a CLI process, not a daemon.
`clanker serve` exists but is not something a user is expected to keep running,
and an agent run takes minutes and holds real state, so a background thread
inside `serve` would need its own concurrency story before it could fire
anything. The thing that already runs reliably on every machine is the
system's own cron.

## Goals

1. A schedule that lives in `state/`, is readable and hand-editable, and
   survives restarts — so "what does this instance do on a timer" is a
   question with an answer.
2. A cron dialect that means what a crontab means, parsed and evaluated by
   pure code that is unit-tested on the host, including the parts that are
   easy to get subtly wrong (month lengths, leap years, day-of-month versus
   day-of-week).
3. An explicit, documented, tested answer to "what happens after downtime",
   chosen so that a machine waking from a long sleep cannot produce a burst of
   agent runs.
4. A ledger: every fire, successful or not, leaves a record a human can read
   after the fact.
5. `run-due` safe to call from a per-minute cron: no double-firing, no
   pile-up, no re-firing a window a killed run already claimed.

## Non-goals

- **An always-on loop.** No thread inside `clanker serve` polls the schedule.
  A `run-due` the system cron calls is the whole delivery mechanism. Adding a
  loop would mean a second, concurrent path into the agent that only exists
  while a server the user may never start is running, and it would be
  untestable without standing that server up. See ADR 0008.
- **Arbitrary shell commands.** An entry carries a *task*, which is the prompt
  `clanker run` would take, and nothing else. `clanker schedule` schedules
  agent work; it is not a general-purpose cron replacement, and a state file
  that can name any argv is a much larger thing to secure than one that names
  a prompt.
- **Time zones with DST.** Fields are read at a fixed UTC offset the entry
  carries. There is no tz database in the binary. See ADR 0009.
- **Backfill / catch-up.** Missed windows are counted and dropped, never
  replayed. This is Goal 3, stated as a non-goal too because it is the thing a
  future reader is most likely to "fix".
- **A WASM tool over the schedule.** The store and the ledger are plain JSON
  in `state/`; no guest tool reads them yet, so an agent conversation cannot
  see what is scheduled. Listed as future work rather than shipped, since it
  is not needed to remove the outside dependency this PRD is about. (The web
  UI half of what this non-goal originally covered has since shipped, see
  Status; the browser reads and toggles entries but still fires nothing.)
- **Cron nicknames (`@daily`), names (`MON`, `JAN`), seconds, `L`/`W`/`#`.**
  Every one of them is a dialect this parser would have to speak *exactly*
  right or silently mis-fire. Rejecting them is a documented refusal, not a
  gap.

## Design

**Store.** `state/schedule.json` is an array of entries, written pretty-printed
so it can be read and edited by hand. Every read-modify-write goes through
`store.Session`: it takes `util/file_lock.zig` on `state/schedule.lock` — a lock
file of its own, never the file being rewritten — and writes back through
`util/atomic_write.zig`, exactly as `state/goals.json` and
`state/notifications.jsonl` do. A concurrency test in `store.zig` spawns four
threads doing ten read-modify-writes each and asserts all forty entries
survive; without the lock this is the silent lost-update that motivated
`file_lock.zig` in the first place. `schedule list` reads without the lock, so
printing a table cannot block behind a run that takes minutes.

| Field | Meaning |
|---|---|
| `id` | `sch-N`, sequential, never reused (a removed id is not handed out again, so the ledger's history keeps meaning one job) |
| `cron` | the 5-field spec, stored as written |
| `task` | the prompt, 1–4000 bytes; what `clanker run` would take |
| `provider` / `model` | optional overrides, absent when unset (no `null` keys in the file) |
| `goal` | optional goal id (string) or `null`/absent. When set to an id, that goal steers the fired run. When unset/`null`, inherit active-goal steering identical to `clanker run` (see Design decisions) |
| `tz_offset_minutes` | minutes east of UTC the fields are read at |
| `enabled` | a disabled entry is never due |
| `created` | when it was added; the first window is computed from here |
| `last_run` | the moment of the last fire, scheduled or manual |
| `last_status` | `""`, `"running"`, `"ok"` or `"error"` |
| `runs` / `failures` | counters, for `schedule list` |

**Dialect.** Five fields — `minute hour day-of-month month day-of-week` — each
`*`, a number, `a-b`, `*/n`, `a-b/n`, or a comma-separated list of those.
Sunday is `0` or `7`. Deliberate refusals, each because guessing would be
worse than an error at the point the mistake was made:

| Written | Result |
|---|---|
| `5/10` | `BadStep`. Quartz reads it as `5-59/10`, Vixie rejects it; write `5-59/10` or `*/10` |
| `55-5` | `BadRange`. A wrapping range is a typo far more often than an intent |
| `MON`, `JAN` | `BadNumber` |
| `@hourly` | `WrongFieldCount` |
| `*/0` | `BadStep` |
| `0 0 30 2 *` | parses, but `schedule add` refuses it: `nextAfter` finds no fire within eight years, so it is rejected at the add rather than at the fire that never comes |

**Day-of-month versus day-of-week.** Vixie's rule: when both fields are
restricted, an entry fires when *either* matches. `0 0 13 * 5` is "the 13th,
and every Friday", not "Friday the 13th". When one is a star, the other alone
decides. A field counts as a star when it is written `*` or `*/n` over the
whole range — `*/2,15` is a set the writer chose and is treated as the
restriction it is.

**Next-fire arithmetic.** `cron.zig` has no allocator, no clock and no
`std.Io`: `Spec.nextAfter(after, tz_offset_minutes)` is a function of its
arguments. It steps by field (skip to the next month, the next day, the next
hour, the next minute) over Howard Hinnant's `days_from_civil` /
`civil_from_days`, so month lengths and leap years fall out of the arithmetic
instead of a table. It searches eight years ahead — enough for `0 0 29 2 *`
even across the century rule that makes 2100 not a leap year — and returns
null past that, which is how a never-firing spec is detected rather than spun
on. A test walks a fortnight of minutes brute-force and asserts the stepping
search agrees with it, for five specs, so a skip landing one slot early or
late is caught by an independent implementation rather than by a hand-written
expectation.

**Due, and the missed-run policy.** An entry is due when
`nextAfter(last_run or created) <= now`. The answer is one window, not a
backlog. On firing, `last_run` becomes *now* — the moment it ran, not the slot
it ran for — so the next window is computed from wake time and the schedule
realigns to the normal grid. A machine that slept through a day of a `*/5`
entry therefore fires it **exactly once** and resumes; the 286 windows in
between are counted into the ledger's `skipped` and dropped. Storing the slot
instead would advance `last_run` by five minutes per invocation and turn the
backlog into a slow-motion replay, which is the same 288 runs spread out.

**Claim before run.** `run-due` writes the claim (`last_run = now`,
`last_status = "running"`, `runs += 1`) and releases the store lock *before*
the first model call, then re-opens the store afterwards to record the
outcome. Two consequences, both intended: a run killed halfway leaves the
entry looking fired, so at-most-once rather than a crash loop that bills per
iteration; and an `enable`/`disable` that landed while the model was working
survives, because phase two re-reads rather than writing back the copy phase
one took.

**One sweep at a time.** `run-due` holds a non-blocking exclusive advisory
lock on `state/schedule/run-due.lock` for its whole duration. A second
invocation prints `another 'schedule run-due' is still working` and exits 0 —
not an error, because a per-minute cron overlapping a run that takes longer
than a minute is the expected shape, and exiting non-zero would mail the
operator about it every time. Deliberately not `util/run_lock.zig`: that one
decides staleness by looking the owning pid up in `/proc`, which does not
exist on macOS, so every lock there reads as abandoned and is taken over. A
kernel-held flock needs no liveness check.

**Ledger.** `state/schedule/log.jsonl`, one JSON object per line, the shape
`state/arena/log.jsonl` and `state/compare/log.jsonl` already use:
`{ts, id, cron, task, trigger, due_at, skipped, ok, duration_ms, err}`.
`trigger` is `"due"` or `"manual"`. `due_at` is the window that made it due,
distinct from `ts` because cron granularity is a minute and `run-due` may be
seconds late. Appends are serialised by the same `file_lock` discipline and
trimmed oldest-first, on a line boundary, at 4 MiB. A removed entry's history
stays: what ran is a fact about the past.

**Firing.** `runner.zig` takes a `Fire` callback rather than knowing what a run
is, which is what lets its tests drive the real due/claim/ledger path with a
stub that records what it was asked to run. `src/cli.zig` supplies the real
one: it copies the parsed options, sets `command = .run` and the entry's task,
applies the entry's provider/model over the invocation's, clears any session
(a scheduled run is a fresh conversation every time — resuming would grow one
transcript forever on a timer) and calls `cmdRun`. A scheduled run is
otherwise an ordinary run, including goal steering (see Design decisions).

**Design decisions.**

- **Goal steering (operator-visible).** Scheduled runs are goal-steered the
  same way `clanker run` is when an active goal exists. That is deliberate,
  not an accident of going through `cmdRun`: a timer that advances the
  instance's active goal is useful, and inventing a second "unsteered run"
  kind would diverge from every other entry point. The inherit-active path
  is already live today. Per-entry control is the optional `goal` field
  (locked schema above): a string id pins that goal for the fire; omit the
  field (or set it `null`) to inherit whatever is active at fire time,
  identical to CLI. Operators see the binding: `schedule list` shows the
  entry's `goal` (or `(active)` when unset), `schedule add` accepts
  `--goal <id>` / `--goal none`, and the web UI Schedule view surfaces the
  same value beside the task. An entry that names a goal id that no longer
  exists falls back to unsteered for that fire and records the miss in the
  ledger `err`, rather than inventing a goal. Landing the field in
  `store.Entry` / CLI / web UI is follow-through against this locked
  decision (see Acceptance).

**Subcommands.**

| Subcommand | Behaviour |
|---|---|
| `list` (default) | every entry with its next fire time, or `(disabled)`, `(bad spec)`, `(never)`, `due now` |
| `add "<cron>" "<task>"` | validates spec and task, assigns the next `sch-N`. Optional `--goal <id>` pins steering; omit to inherit active-goal behavior. The first window is the first one *after* the add, so adding at 12:03 does not fire immediately |
| `remove <id>` | drops the entry; its ledger history stays |
| `enable <id>` / `disable <id>` | re-enabling sets `last_run = now`, so an entry parked for a month does not come back owing a run |
| `run <id>` | fires one entry immediately whatever its schedule says. Counts as a real run: it advances the window and lands in the ledger as `"manual"`. A disabled entry still runs — the operator asked for it by id |
| `run-due` | the cron entry point |
| `log` | the last 20 ledger records, newest first |

Flags: `--provider`, `--model` (recorded on the entry by `add`, an override
for everything else), `--goal` (recorded on the entry by `add`; see Design
decisions), and `--tz-offset` (`+02:00`, `-05:00`, `UTC`, or a plain minute
count).

**Installation is the user's.** Nothing fires on its own. `schedule add` says
so on every add, and `schedule --help` gives the crontab line:

```
* * * * * cd /path/to/clanker && ./zig-out/bin/clanker schedule run-due
```

## Failure modes

| Condition | Behaviour |
|---|---|
| `state/schedule.json` missing | Empty schedule; `run-due` reports `nothing due (0 entries scheduled)` and exits 0 |
| `state/schedule.json` unparseable | Warned once, treated as empty. The next write replaces it — hand-edit with that in mind |
| An entry's `cron` is unparseable (hand-edited in) | Warned on every sweep, never due. `schedule list` shows `(bad spec)` |
| An entry's spec can never match | `schedule add` refuses it; one already in the file shows `(never)` and is never due |
| `schedule add` with a bad spec / empty task / too-long task | Refused before anything is written, with the reason |
| A fired entry's run errors | Recorded `ok:false` with the error name, `failures += 1`, the sweep continues to the next entry, and `run-due` exits non-zero so the invoking cron notices |
| `run-due` while another is still working | Prints that it is busy, starts nothing, exits 0 |
| `run-due` killed mid-run | The window stays claimed and is not re-fired. `last_status` is left at `"running"`, which is how that shows up in `schedule list` |
| Machine asleep across many windows | One fire, `skipped` counted in the ledger (capped at 500), schedule resumes on the normal grid |
| Ledger over 4 MiB | Trimmed oldest-first on a line boundary |
| An entry disabled while its run is in flight | The disable survives; the outcome is still recorded |
| The run hits `MaxIterationsExceeded` | `cmdRun` exits the process, which ends the sweep. Later entries in that sweep are not fired and will be picked up next invocation — see Known issues |
| Web UI `POST /api/schedule/<id>` for an unknown id | `404` with `{"ok":false,"error":"no such entry"}` |
| Web UI enable/disable of a non-slug id | `400` with `{"ok":false,"error":"bad entry id"}` |

## Known issues

- A run that ends in `error.MaxIterationsExceeded` or
  `error.SessionTokenBudgetExceeded` calls `std.process.exit(1)` inside
  `cmdRun` (`src/cli.zig`), so it takes the whole sweep down with it: the
  outcome of the entry that hit the cap is never recorded, and entries after
  it in the same sweep never run. Their windows are not lost — nothing claimed
  them — so the next `run-due` picks them up. The fix belongs in `cmdRun`,
  which should return the error rather than exiting when it is not the
  outermost command.

## Acceptance criteria

- [x] `state/schedule.json` persists entries across processes, locked and
  written atomically, with a concurrency test proving no lost updates
- [x] Cron parsing and next-fire computation are pure, in their own file, with
  no I/O, and tested against a brute-force minute scan
- [x] Month lengths, leap years, the century rule and the Vixie dom/dow rule
  are each covered by a named test
- [x] Fixed UTC offsets shift the fields, including across a UTC date boundary
- [x] A day of downtime fires a `*/5` entry once, not 288 times, and says how
  many windows were skipped
- [x] A punctual sweep reports zero skipped windows
- [x] `run-due` twice in a row fires once
- [x] A second concurrent `run-due` reports busy and starts nothing
- [x] Every fire, pass or fail, leaves one ledger line
- [x] A failing entry does not stop the other entries in the sweep
- [x] `add`/`remove`/`enable`/`disable`/`run`/`run-due`/`list`/`log` all work
  against a live provider (verified end to end against DeepSeek: added,
  fired manually, fired by `run-due`, confirmed no re-fire, confirmed the
  ledger)
- [x] `zig build`, `zig build tools`, `zig build test` green
- [ ] A `MaxIterationsExceeded` run does not end the sweep (see Known issues)
- [ ] Optional per-entry `goal` field (string id or null) in `state/schedule.json`,
  with `--goal` on `add`, visible in `schedule list` and the Schedule web UI
  (see Design decisions)

## Open questions / future work


- **A read-only WASM tool over the schedule**, in the shape of the
  `autoresearch` tool (list entries, tail the ledger), so an agent
  conversation can see what is scheduled. The web UI already can
  (`GET /api/schedule`, see Status); the agent-facing guest tool is the
  remaining gap. `AGENTS.md`'s "WASM by default" says a capability that can
  be a guest should be one; the firing side cannot (ADR 0008), but the
  reading side plainly can, and not building it yet is a scope call rather
  than a design one.
- **Whether `skipped` should be able to trigger a notify / doctor signal.**
  An entry that has slept through 500 windows is a fact worth surfacing more
  loudly than a number in a JSONL file — a peer notification, or a line in
  `clanker doctor`. Still open.
- **Overlap / concurrent fires between entries.** One sweep runs its due
  entries strictly sequentially, so a slow entry delays the ones behind it
  in the same sweep. Running them concurrently is possible (`ck_llm_many`
  and `ck_swarm` both establish that the host does fan-out) but would need a
  per-entry budget first, and the sequential version has not been a problem
  at the scale this is used at. Still open.
