# Bug — Every completed GET /api/events is logged at ERROR and counted as a server error

## TL;DR

- **What failed:** live.serveSse writes its own 200 and returned void, so cli.zig's request_status stayed at its 0 reset: completionLogLevel logged each finished SSE subscription at ERROR and recordHttpRequest counted it into http_errors_total. The same handler also held its subscriber slot and connection thread until the 15s keepalive ping after a client hung up.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-16. serveSse returns its status and cli.zig stores it in request_status; the idle tick polls the socket for POLLRDHUP so a hung-up subscriber releases its slot at once. Two e2e cases in tests/e2e/live_sse_test.zig, gate green.

## Status

Resolved on 2026-08-16. serveSse returns its status and cli.zig stores it in request_status; the idle tick polls the socket for POLLRDHUP so a hung-up subscriber releases its slot at once. Two e2e cases in tests/e2e/live_sse_test.zig, gate green.

## Symptom and impact

`clanker serve` logs an ERROR for every `GET /api/events` subscription that
ends, however normally it ended:

```
[ERROR] ts_ms=1786920482458 request_id=http-1 http request complete method=GET path=/api/events status=0 duration_ms=8460
[ERROR] ts_ms=1786921906038 request_id=http-23 http request complete method=GET path=/api/events status=0 duration_ms=1424932
```

The same records land in `/api/metrics` as `http.errors_total`, so the one
number an operator would check to answer "is this instance healthy?" counts one
error per web UI page load — two, because the UI opens a probe stream and then
the real one.

Second, smaller impact: a subscriber whose client has gone keeps one of the 32
`max_subs` slots and one of the 64 connection threads until it next tries to
write, which on an idle bus is the 15s keepalive ping. Repeated reloads stack
those up, and the ceiling is a 503 `too many live subscribers` for a client
that should have been served.

## Reproduction

Start a serve, then open one `/api/events` socket and close it:

```bash
clanker serve --host 127.0.0.1 --webui-port 24777
```

```bash
python3 -c '
import socket, time, json, urllib.request
p = 24777
m = lambda: json.load(urllib.request.urlopen(f"http://127.0.0.1:{p}/api/metrics"))["http"]
print("before", m()["in_flight"], m()["errors_total"])
s = socket.create_connection(("127.0.0.1", p))
s.sendall(f"GET /api/events HTTP/1.1\r\nHost: 127.0.0.1:{p}\r\n\r\n".encode())
s.recv(200); s.close(); time.sleep(0.6)
print("after ", m()["in_flight"], m()["errors_total"])
'
```

Before the fix the second line reported an elevated `in_flight`, and
`errors_total` incremented once the subscriber was reaped. After it, both
return to their baseline.

## Root cause

`handleConnection` in `src/cli.zig` logs and meters each finished request off a
threadlocal `request_status` it resets to 0. `completionLogLevel` maps 0 to
`.error_` and `recordHttpRequest` counts it into `http_errors_total` — correct
for a request whose bytes arrived and then stopped.

A handler that writes its own response rather than calling `respond` therefore
has to set `request_status` itself. The `writeAllFd` sites for the plugin,
theme and command assets do. `is_events` did not: `live.serveSse` returned
`void`, wrote `HTTP/1.1 200 OK` itself, and streamed until hangup, so the
status stayed 0 for the whole subscription.

The slot-retention half is separate: the subscriber loop writes only when the
bus has an event, so it learns about a hangup from a failing write, and on an
idle bus the first of those is the 15s ping.

## Resolution

- `live.serveSse` returns `u16` — 200, or 503 when `max_subs` is full — and the
  `is_events` branch in `src/cli.zig` assigns it to `request_status`.
- Its idle tick is a 50ms `poll` on the socket instead of a 50ms `nanosleep`,
  returning as soon as the peer hangs up.

One trap in that second change: `@hasDecl(std.posix.POLL, "RDHUP")` is false on
`x86_64-linux-musl`. Zig carries `RDHUP` on `std.os.linux.EPOLL` but not on
`std.os.linux.POLL`, so the first attempt polled for no events at all and
detected nothing — POLLHUP does not substitute, because it wants both halves of
the socket shut and the server half is still open. The constant (`0x2000`) is
spelled out in `live.zig` with that note; off Linux it is 0 and the loop falls
back to noticing the hangup on its next write.

## Verification

`tests/e2e/live_sse_test.zig`, two cases, both failing first:

- a closed subscription leaves `http.errors_total` unchanged (`expected 0,
  found 1` before)
- a hung-up subscriber returns `http.in_flight` to baseline within 600ms with
  nothing writing to it (`expected 1, found 2` before)

`zig build e2e` is 17/17 and `clanker gate` passes (build, tests, tools, fmt,
lint, provider-kind, tools-ts-toolchain, release-contract). The reproduction
above was also run against a real `clanker serve` before and after.

## Follow-up

`ui/app/core/stream.js` opens two `/api/events` connections per page load: a
`fetch` probe whose body it cancels, and then the `EventSource`. The probe
exists to soft-fail when the endpoint is absent, but `EventSource` already
reports a non-200 as an `onerror` with `readyState === CLOSED`, which
`attachLive` handles. Dropping the probe would halve the connection cost per
load. Not attempted here: `ui/app/` is being edited by another session.

## References

- Investigation: [docs/reports/investigations/2026-08-17-sse-requests-logged-as-errors.md](../investigations/2026-08-17-sse-requests-logged-as-errors.md)
- `src/serve/live.zig`, `src/cli.zig` (`is_events` branch), `tests/e2e/live_sse_test.zig`
