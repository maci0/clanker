# Bug — HEAD on any /api route answers 404 and closes, while the same path answers 200 to GET

## TL;DR

- **What failed:** Every /api route predicate in handleConnection compares the method to GET literally, and the keep-alive line uses isWebuiRead (GET or HEAD) for /webui but a bare GET compare for /api. So HEAD /api/status falls through to the terminal 404 and closes. Measured live: 404 with Connection: close, where GET is 200. PRD 0006 promises HEAD on any route answers the GET's status and headers with no body.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

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

## Verification

## Follow-up

## References

- Investigation: none yet
