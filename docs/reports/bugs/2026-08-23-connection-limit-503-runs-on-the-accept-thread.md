# Bug — The saturation 503 is never counted or logged, and can inherit stale HEAD and keep-alive flags

## TL;DR

- **What failed:** serveConnection answers the max_connection_threads 503 outside handleConnection, where the metric and completion-log defers live. So saturation 503s never increment http_requests_total or http_client_errors_total and emit no log line. respond also reads request_head and request_keep_alive, reset only inside handleConnection, which the accept thread does run on the two spawn-failure fallbacks. Read from the source.
- **Impact:** Confirmed for the invisibility half, live: saturation refusals incremented no counter and wrote no log line at all, so the load condition an operator greps `/api/metrics` for was the one the server did not record. The stale-flag half is confirmed by test rather than live -- it needs a thread-spawn failure, which could not be forced here.
- **Resolution:** Resolved on 2026-08-24. Fixed in respondSaturated (src/cli.zig): resets request_head/request_keep_alive, takes a fresh request id, responds, calls recordHttpRequest, logs a warn line. The two spawn-failure fallbacks now serve one request inline, not up to 100 (inline_keep_alive_requests). Saturation reproduced live with 70 idle sockets: before, 0 metrics and 0 log lines; after, requests_total and errors_total each +7, client_errors_total unchanged. The stale-flag half is pinned by unit test, not live.

## Status

Resolved on 2026-08-24. Fixed in respondSaturated (src/cli.zig): resets request_head/request_keep_alive, takes a fresh request id, responds, calls recordHttpRequest, logs a warn line. The two spawn-failure fallbacks now serve one request inline, not up to 100 (inline_keep_alive_requests). Saturation reproduced live with 70 idle sockets: before, 0 metrics and 0 log lines; after, requests_total and errors_total each +7, client_errors_total unchanged. The stale-flag half is pinned by unit test, not live.

## Symptom and impact

Two effects, and the second is the reason the first matters. Saturation refusals
are invisible: `/api/metrics` shows no request and no client error for them, and
no log line is written, so the load condition an operator would go looking for
is the one the server does not record. And `respond` reads two threadlocals the
accept thread only ever sets on its spawn-failure fallbacks, so after one HEAD
served inline a later 503 can declare a `Content-Length` it does not send, or
promise keep-alive on a socket closed on the next line. Thread-spawn failure and
connection saturation are the same overload event, which is what makes the
combination reachable rather than theoretical.

## Reproduction

Not reproduced: it needs 64 concurrent connections plus a thread-spawn failure.
Read from the source.

## Root cause

`serveConnection` calls `respond` directly for the over-limit case. The metric
and completion-log work lives in `handleConnection`s `defer`, and
`request_head`/`request_keep_alive` are reset at the top of `handleConnection`,
so a `respond` outside it is outside both. There is also a second thing on that
path worth a look: `handleConnectionGuarded` is now the keep-alive loop, so
serving inline on the accept thread can hold the listener for up to
`max_keep_alive_requests` requests rather than the single one its comment
assumes.

## Resolution

Fixed in `src/cli.zig`. Two changes, for the two halves of the report.

**The refusal became its own function, `respondSaturated`.** Both over-limit
branches in `serveConnection` call it instead of `respond` directly. It does
four things a bare `respond` on the accept thread could not:

- resets `request_head` and `request_keep_alive`, the two per-request
  threadlocals `respond` reads and only `handleConnection` was resetting;
- takes a fresh id from `request_sequence` and sets the log context, so
  `X-Request-ID` is this refusal's and not whatever the accept thread last
  served inline (a third instance of the same root cause, not in the report);
- calls `recordHttpRequest(io, 503, 0)`. The duration is 0 rather than measured
  and honestly so: nothing was read and nothing was dispatched;
- logs a `warn` line naming the limit.

503 is a 5xx, so `recordHttpRequest` books it under `errors_total`, not
`client_errors_total`. The report's TL;DR says `http_client_errors_total`; that
is the report being loose, and the correct counter is the one that moves.

**The inline fallback serves one request, not a hundred.** The report's closing
note was right. `handleConnectionGuarded` became the keep-alive loop after the
two spawn-failure fallbacks were written, so they silently went from holding the
listener for one request to holding it for up to `max_keep_alive_requests` -- at
the discretion of a client that arrived *during an overload*, which is the only
time that path runs. `keepAliveBudgetLeft` now takes the bound as a parameter
and `handleConnectionGuarded` takes a `max_requests`; the fallbacks pass
`inline_keep_alive_requests` (1) and `connectionThread` passes
`max_keep_alive_requests` as before. The single response says
`Connection: close`, because `keepAliveBudgetLeft(0, 1)` is false.

## Verification

The report says "Not reproduced: it needs 64 concurrent connections plus a
thread-spawn failure." The first half turned out to be reachable and was
reproduced; the second was not, and the two are verified differently. Stated
separately on purpose.

**Live, for the metric and the log line.** 70 sockets that connect and send
nothing hold a connection thread each for the 5s read timeout, taking the
process past the 64-connection bound; a further connection sends a real request
and is refused. Against the pre-fix binary: `requests_total` 0 -> 1 (the
baseline `/api/metrics` read itself), `errors_total` 0, and zero occurrences of
any refusal line in the serve log. Against the fixed binary, same procedure:
`requests_total` +7 (one per refusal, plus the read), `errors_total` +7,
`client_errors_total` unchanged at 0, and seven

```
[WARN] request_id=http-66 serve: connection refused at the 64-connection limit
```

lines with distinct ids.

**Unit, for the stale flags.** A thread-spawn failure could not be forced, so
the flag inheritance is pinned by test rather than measured: a socketpair test
calls `respondSaturated` with `request_head` and `request_keep_alive` both set,
the way an inline HEAD would leave them, and asserts the 503 carries its full
body, says `Connection: close`, and stamps a fresh `X-Request-ID`. Both halves
confirmed failing first, separately: with the flag resets removed the response
is a 503 declaring `Content-Length: 54` and sending zero body bytes; with only
`recordHttpRequest` removed the counter assertion fails `expected 1, found 0`.
A control run with the flags already clear produces byte-identical output, so
the reset is what makes the two cases agree rather than a coincidence of
framing.

**The inline bound** is covered by an added case in the existing keep-alive
budget test. It is arithmetic, not concurrency: the test says a one-request
connection's first response promises no second one. That the *listener* is
released sooner follows from the loop bound and is not separately measured.

`clanker gate`: all twelve checks PASS.

### What this does not prove

This is a concurrency path and the honest boundary matters:

- No test here exercises a real thread-spawn failure, so the combination the
  report describes -- an inline request followed by a saturation 503 on the same
  accept thread -- has never been run end to end. What is proven is that
  `respondSaturated` is correct *given* stale flags, and that the flags are the
  only per-request state `respond` reads.
- The live run shows counters moving by the number of refusals observed; it does
  not prove the accounting is exact under contention, since the refusals and the
  metric read race each other by construction.
- Found while verifying this, and filed separately rather than folded in: the
  saturation path never reads the request, so `stream.close` sends RST and the
  RST can discard the response body. The body arriving in the live run above is
  a timing artifact of the work this fix added between `respond` and the close,
  **not** something this change guarantees. See the reference below.

## Follow-up

- `docs/prds/0006-webui.md`'s Known-issues entry for this is flipped to
  `(Fixed)`, with the counter correction noted.
- The RST defect below should be decided before anything relies on reading a
  saturation refusal's body.

## References

- Investigation: none; the metric and log halves were reproduced live.
- [The saturation 503 closes a socket with the request still unread](2026-08-24-saturation-503-is-reset-before-the-client-reads-it.md)
  -- found while verifying this fix, on the same two lines, and deliberately not
  fixed here.
- `src/cli.zig` -- `serveConnection`, `respondSaturated`,
  `handleConnectionGuarded`, `keepAliveBudgetLeft`, `inline_keep_alive_requests`.
