# Investigation — GET /api/events logs as ERROR status=0 and counts as an http error

## TL;DR

- **Question:** The SSE handler writes its own 200 to the socket and never sets cli.zig's threadlocal request_status, so every finished /api/events subscription is logged at ERROR with status=0 and increments http_errors_total in /api/metrics.
- **Finding:** Resolved on 2026-08-16. Both defects fixed and covered by e2e; the /api/graph 404s in the same log are an unrouted path, not a clanker defect.
- **Resolution:** Resolved on 2026-08-16. Both defects fixed and covered by e2e; the /api/graph 404s in the same log are an unrouted path, not a clanker defect.

## Status

Resolved on 2026-08-16. Both defects fixed and covered by e2e; the /api/graph 404s in the same log are an unrouted path, not a clanker defect.

## Trigger and scope

Reported from a `clanker serve` log: every `GET /api/events` line was ERROR,
including ones that had plainly worked.

```
[ERROR] ts_ms=1786920482458 request_id=http-1 http request complete method=GET path=/api/events status=0 duration_ms=8460
[ERROR] ts_ms=1786921906038 request_id=http-23 http request complete method=GET path=/api/events status=0 duration_ms=1424932
```

The two `[WARN] ... path=/api/graph status=404` lines in the same log are not
part of this: `rg -n "api/graph"` over the tree (excluding `zig-out`,
`zig-pkg`, `.git`) has no hit, so nothing clanker serves or requests uses that
path. A 404 for an unrouted path is the router working.

## Evidence

`handleConnection` in `src/cli.zig` logs and meters each finished request from
a threadlocal `request_status`, reset to 0 per request:

- `completionLogLevel(path, status)` maps `status == 0` to `.error_`
- `recordHttpRequest(status, ms)` counts `status == 0` into `http_errors_total`

Both are correct for a truncated request. Handlers set `request_status`
themselves when they write the response without going through `respond`
(`writeAllFd` sites at `src/cli.zig:14479`, `:14539`, `:14872` all do).

`is_events` did not. It called `live.serveSse`, which returned `void`, wrote
its own `HTTP/1.1 200 OK` header at `src/serve/live.zig:219`, and streamed
until the client hung up — leaving `request_status` at its 0 reset for the
entire life of the subscription.

Grepping the other direct-write sites found no second handler with the same
gap.

## Hypotheses and tests

The status is observable without reading the log: `recordHttpRequest` feeds
`GET /api/metrics`, so `http.errors_total` is the same signal. An e2e case
(`tests/e2e/live_sse_test.zig`) reads `errors_total`, opens one raw `/api/events`
socket, checks the `200 OK` status line, closes it, publishes three times
through `POST /api/live` so the subscriber notices the hangup, and reads
`errors_total` again. Before the fix: `expected 0, found 1`.

A second run of that harness against a real serve exposed a separate defect.
With the publishes removed, `http.in_flight` stayed at 2 for a full second
after the client had gone: the subscriber loop only writes when the bus has an
event, so it learns about a hangup at its next write, and on an idle bus that
is the 15s keepalive ping. Each such connection holds one of the 32 `max_subs`
slots and one of the 64 connection threads for that whole window. The web UI
opens two streams per page load (`ensureLive` in `ui/app/core/stream.js` probes
with `fetch`, cancels the body, then opens the `EventSource`), so reloads stack
them up.

Waiting the idle tick out on the socket rather than on the clock fixes that,
but the first attempt still failed. A debug print showed why:

```
DBG poll ready=0 revents=0x0 want=0x0 dead=0x38
```

`want=0x0` — `@hasDecl(std.posix.POLL, "RDHUP")` is false on the
`x86_64-linux-musl` target. Zig carries `RDHUP` on `std.os.linux.EPOLL`, not on
`std.os.linux.POLL`. Polling for nothing leaves only the always-reported set,
and POLLHUP is not it: POLLHUP wants both halves of the socket shut, and the
server half is still open.

## Finding

Two defects, both in the `/api/events` path:

1. `live.serveSse` returned `void`, so the one place that knew this request had
   answered 200 told nobody. Every completed subscription was logged at ERROR
   and counted as a server error in `/api/metrics`.
2. The subscriber only detected a client hangup on its next write, holding a
   subscriber slot and a connection thread for up to 15s after the client left.

## Resolution or handoff

`serveSse` now returns the status it wrote (200, or 503 when `max_subs` is
full) and `src/cli.zig` stores it in `request_status`. Its idle tick is now a
50ms `poll` on the socket for POLLRDHUP/POLLHUP/POLLERR/POLLNVAL instead of a
50ms `nanosleep`, with POLLRDHUP spelled out as `0x2000` because Zig does not
carry it on `POLL`; on a non-Linux target it degrades to the old
notice-on-next-write behaviour rather than breaking.

Verified against a real `clanker serve`: opening one `/api/events` socket and
closing it now leaves `http.errors_total` at 0 and returns `http.in_flight` to
its baseline within 600ms (it stayed elevated before). `clanker gate` passes;
`zig build e2e` is 17/17.

## References

- Related bug: [docs/reports/bugs/2026-08-17-sse-subscriptions-logged-as-server-errors.md](../bugs/2026-08-17-sse-subscriptions-logged-as-server-errors.md)
- `src/serve/live.zig`, `src/cli.zig` (`is_events` branch), `tests/e2e/live_sse_test.zig`
