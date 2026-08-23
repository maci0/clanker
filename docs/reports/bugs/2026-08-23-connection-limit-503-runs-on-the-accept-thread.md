# Bug — The saturation 503 is never counted or logged, and can inherit stale HEAD and keep-alive flags

## TL;DR

- **What failed:** serveConnection answers the max_connection_threads 503 outside handleConnection, where the metric and completion-log defers live. So saturation 503s never increment http_requests_total or http_client_errors_total and emit no log line. respond also reads request_head and request_keep_alive, reset only inside handleConnection, which the accept thread does run on the two spawn-failure fallbacks. Read from the source.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

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

## Verification

## Follow-up

## References

- Investigation: none yet
