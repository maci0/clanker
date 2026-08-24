# Bug — HEAD on any /api route answers 404 and closes, while the same path answers 200 to GET

## TL;DR

- **What failed:** Every /api route predicate in handleConnection compares the method to GET literally, and the keep-alive line uses isWebuiRead (GET or HEAD) for /webui but a bare GET compare for /api. So HEAD /api/status falls through to the terminal 404 and closes. Measured live: 404 with Connection: close, where GET is 200. PRD 0006 promises HEAD on any route answers the GET's status and headers with no body.
- **Impact:** Confirmed. Any non-browser client probing an /api route with HEAD was told the resource was absent, and paid a TCP handshake per probe on top. The shipped web UI issues no HEAD, so no user-visible breakage; the loss was the contract to anything else speaking to the server.
- **Resolution:** Resolved on 2026-08-24. Fixed: handleConnection now routes a HEAD as the GET it mirrors, once, ahead of the whole route chain (src/cli.zig), with GET /api/events excluded via streamingReadRoute. Verified live: HEAD /api/status is 200 + Content-Length 174 + keep-alive + no body, matching the GET byte for byte.

## Status

Resolved on 2026-08-24. Fixed: handleConnection now routes a HEAD as the GET it mirrors, once, ahead of the whole route chain (src/cli.zig), with GET /api/events excluded via streamingReadRoute. Verified live: HEAD /api/status is 200 + Content-Length 174 + keep-alive + no body, matching the GET byte for byte.

## Symptom and impact

A client that probes an API route with HEAD, which is the cheap way to ask
whether a resource is there and how big it is, is told it is not there. The
connection closes too, so a client sweeping several routes pays a handshake per
probe. Nothing in the shipped web UI issues a HEAD, so the browser is unaffected;
this is a contract to anything else that speaks to the server.

## Reproduction

Live, against `clanker serve` on loopback:

```
$ curl -sI http://127.0.0.1:8791/api/status | head -3
HTTP/1.1 404 Not Found
Content-Length: 32
$ curl -sI -X GET http://127.0.0.1:8791/api/status | head -1
HTTP/1.1 200 OK
```

The 404 also carries `Connection: close`.

## Root cause

`handleConnection` computes

```zig
const keep_alive_eligible = (is_webui and isWebuiRead(method) and cfg.modules.webui) or
    (std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, path, "/api/"));
```

`isWebuiRead` is GET or HEAD; the `/api/` half is a bare GET compare, and so is
every `/api/` route predicate below it (`is_status`, `is_stats`, `is_metrics`
and the rest). The asymmetry on two halves of one expression looks unintended.

Worth noting before anyone fixes it by rewriting the method: `GET /api/events`
is an SSE stream and `POST /api/run` streams too, so "treat HEAD as GET" at the
top of dispatch would open a stream for a HEAD. The routes that should answer a
HEAD are the ones that answer with a fixed body, and `respond` already suppresses
the body once one of them is reached, so the change is in the predicates.

## Resolution

Fixed in `handleConnection` (`src/cli.zig`). The method is rewritten once,
before the route chain, rather than in the predicates:

```zig
if (request_head and !streamingReadRoute(path)) method = "GET";
```

The report's advice was to change the predicates. The rewrite was chosen over
that for the reason the report itself gives: the bug *is* two spellings of the
same idea drifting apart, and thirty-odd predicates cannot drift from each
other if none of them knows about HEAD. It is safe for the same reason the
predicate change would have been — `respond`, `respondCompressible`,
`respondStatic`, `respondHtmlGz` and both asset responders already drop the
body when `request_head` is set, and every route reachable by a rewritten HEAD
goes through one of them.

The report's warning about streams is honored, narrowly:

- `GET /api/events` is excluded by `streamingReadRoute`, so a HEAD there is
  still unmatched and still 404s. Confirmed live: the 404 comes back at once
  and no `text/event-stream` header is written.
- `POST /api/run` needs no exclusion. The rewrite maps HEAD to GET, never to a
  write method, so a HEAD cannot reach a POST-only predicate. `HEAD /api/run`
  is a 404, and `handleRun`'s raw streaming header write is unreachable from
  it.

Placement is after the proxy dispatch and after the cross-origin check, so
`/proxy/v1` keeps its own method handling and the CSRF guard still reads the
real method. `request_method` is captured earlier, so the completion log line
still says `method=HEAD`.

One consequence beyond what the report asked for: the multi-method routes that
dispatch on `method` inside their handler (`/api/board`, `/api/sessions`,
`/api/records/*`, and the rest) now answer a HEAD from their read branch,
because they receive the rewritten `"GET"`. That is the RFC behavior and is
read-only, but it is a wider blast radius than "the predicates" and is called
out here rather than left to be discovered.

## Verification

Unit, in `src/cli.zig` — two tests on a new `routeCapture` helper that drives a
whole request through `handleConnection` over a socketpair, with no listener.
`respondCapture`, which already existed, sets the threadlocals by hand and
tests one responder; the route chain is a different claim and had no coverage.

Before-state confirmed to fail, not assumed: with the rewrite disabled the
first test fails at `HTTP/1.1 200 OK` with the report's exact symptom in the log
line — `method=HEAD path=/api/status status=404`. With it restored, 5/5 pass
under `-Dtest-filter="HEAD "`.

The second test is a guard rather than a reproduction, and passes in both
states: it pins that `HEAD /api/events` does not open a stream and that
`HEAD /api/run` does not reach the POST route.

`clanker gate`: all twelve checks PASS (build, test, tools, fmt, lint,
provider-kind, test-root-coverage, js-suite-coverage, sandbox-abi,
tools-ts-toolchain, release-contract, dep-patches).

Live, `clanker serve --webui-port 18791` on loopback. The reproduction above
now reads:

```
$ curl -sI http://127.0.0.1:18791/api/status | head -3
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 174
```

with `Connection: keep-alive` and an empty body, against `GET /api/status`
answering 174 body bytes — the same number the HEAD declared. Swept as HEAD:
`/api/status`, `/api/metrics`, `/api/providers`, `/api/board`, `/api/sessions`
and `/health/ready` all answer 200 with the GET's length and no body;
`/api/events` and `/api/run` answer 404. `GET /api/events` still streams
`text/event-stream`, and `GET /api/board`'s body is 253 bytes against the
HEAD's declared 253.

## Follow-up

- `HEAD /api/events` answers 404 where RFC 9110 would want 200 with the
  stream's headers and no body. That is a smaller wrong than opening a stream
  for it, and `respond` hardcodes `application/json`, so it would need a
  responder that can name another content type. Not worth a route today.
- `/health/*` and `/.well-known/agent.json` answer a HEAD but are not
  keep-alive eligible, since eligibility keys off the `/api/` prefix. Their
  GETs have always closed too, so this is pre-existing and not a regression.

## References

- Investigation: none needed; reproduced live and pinned by unit test.
- `src/cli.zig` — `handleConnection` (the rewrite), `streamingReadRoute`,
  `routeCapture` and the two tests.
