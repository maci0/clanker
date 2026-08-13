# ADR 0008 — The scheduler is driven by the system's cron, not by a clanker daemon

## Status

Accepted. Part of [PRD 0009 — Scheduled runs](../prds/0009-schedule.md).

## Context

`docs/ROADMAP.md` sketched two ways to check a `state/schedule.json` of
cron-like entries: "a lightweight always-on `serve` loop, or a
`clanker schedule run-due` invoked by the system's own cron". They are not
variations on a theme — they are different products.

The daemon version needs clanker to be running. `clanker serve` exists, but
nothing in the project expects a user to keep it up: it is how you open the web
UI, not a service with a unit file. A schedule that only fires while a browser
tab's backend happens to be alive is worse than no schedule, because it looks
like it works.

It also needs a concurrency story clanker does not currently have on that path.
A fired entry is a full agent run — minutes, a provider bill, tool calls,
writes to `state/` — started from a background thread inside a process whose
main job is answering HTTP. Everything the run touches would be reachable from
a request handler at the same time. The pieces to do that safely exist
(`ck_swarm` and `ck_llm_many` both fan out under the host's control), but
wiring them up is a real design, not a detail.

And it is hard to test. A background poller is tested by standing the server
up, waiting real seconds and asserting a side effect, in a project where
`clanker serve` already dies at `accept` under some sandboxed environments.
`AGENTS.md` requires new logic to be covered by `zig build test`, and a timing
test against a live listener is the kind of coverage that gets disabled.

Against that, the system's cron is: already running on every machine this
targets, already restarted after a reboot without anyone's help, already the
mechanism `scripts/clanker-improve.sh` and `scripts/clanker-review.sh` are driven by today, and
it turns "did it fire?" into "did this process exit 0?", which is a subprocess
test.

## Decision

`clanker schedule run-due` is the only way an entry fires. It is a short-lived
command the system's cron (or a systemd timer, or a launchd job) invokes,
typically every minute. clanker ships no always-on loop, and `clanker serve`
gains no scheduling thread.

`run-due` is built to be called that way: it takes a non-blocking exclusive
flock for its whole duration, so a minute-by-minute invocation cannot start a
second sweep on top of one still waiting on a model, and it reports that as a
normal exit rather than an error.

## Consequences

Makes easy: the whole firing path is a function of a clock value and a
directory, so `runner.zig`'s tests drive the real due/claim/ledger logic with a
stub callback and an injected `now` — no server, no sleeping, no wall-clock
flake. Reliability is inherited from a scheduler that has been running on unix
machines for forty years. And clanker stays a CLI, which is the shape
everything else in it already assumes.

Makes hard: installation is now a step the user takes, and one they can get
wrong or forget. Nothing fires until a crontab line exists, so
`clanker schedule add` has to say so on every add and `--help` has to print the
line — and a user who adds three entries and never installs the cron gets a
schedule that lists cheerfully and does nothing. Sub-minute granularity is also
off the table, though nothing here wants it.

Forecloses, honestly: this is not a decision that is hard to reverse. A future
`serve` loop would call the same `runner.runDue` with the same lock, and the
lock is what would keep it from colliding with a crontab entry someone left
behind. What this decision actually rules out is *only* having the daemon — the
cron path is the one that has to keep working, because it is the one that works
when clanker is not running.
