# Bug — The saturation 503 closes a socket with the request still unread, so the RST can discard the response body

## TL;DR

- **What failed:** serveConnection never reads the request on the over-limit path, then calls stream.close. Closing a socket with unread received data sends RST, not FIN, and the RST discards the server's unsent send buffer. Measured live on a virgin server: the client gets the 503 header, Content-Length: 54, zero body bytes, and ConnectionResetError. Present before and after the 2026-08-24 metrics fix; that fix only changed the timing.
- **Impact:** A client refused for saturation cannot reliably read *why*. It gets a TCP reset, which most HTTP clients surface as a transport error rather than as the 503 that was actually sent, so the one refusal that should say "come back later" is indistinguishable from the server having died. The status line usually does arrive, so a client reading headers only may still see the 503; a client reading to the declared `Content-Length` gets a reset instead.
- **Resolution:** Resolved on 2026-08-29.

## Status

Resolved on 2026-08-29. Option 2 from the list below: `drainThenClose`
(src/cli.zig) replaces the bare `stream.close` on both saturation sites. It
shuts down the send side (the client sees FIN and knows nothing more follows),
then drains the unread request -- bounded twice over, by a 1s receive timeout
and a 64 KiB byte cap, since this runs on the accept thread the connection
bound protects -- and closes a socket whose receive buffer is empty, which
makes the close a FIN and lets the 503 body arrive by specification rather
than by winning a race. Pinned by a socketpair unit test: request bytes sent
and never read by the server, response written, drainThenClose, and the client
reads the full response then a clean EOF rather than a reset.

## Blocked on

## Symptom and impact

Two things ride on the same cause. The refusal's body is lost, so the JSON that
names the reason (`too many concurrent connections`) does not arrive even though
the header block advertises its 54 bytes. And the connection ends in RST rather
than FIN, which a client library reports as a broken connection, not as a
served response. Under saturation -- exactly when an operator is trying to find
out what the server is doing -- the answer reads as a crash.

Not a regression. Measured on both sides of the 2026-08-24 fix to
[the saturation 503's metrics](2026-08-23-connection-limit-503-runs-on-the-accept-thread.md),
which touched what the path *records*, not how it closes.

## Reproduction

Live, on a virgin `clanker serve` with no prior traffic. 70 sockets that connect
and send nothing hold a connection thread each for the 5s read timeout, which
takes the process past `max_connection_threads` (64); a 71st connection then
sends a real request and is refused.

```python
idle = [socket.create_connection(("127.0.0.1", PORT)) for _ in range(70)]
time.sleep(0.4)
p = socket.create_connection(("127.0.0.1", PORT))
p.sendall(b"GET /api/status HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n" % PORT)
# read until EOF, and do not swallow the exception
```

Against the pre-fix binary:

```
bytes=140 exception=ConnectionResetError(54, 'Connection reset by peer')
'HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\n
 Content-Length: 54\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n'
```

140 bytes: the header block and nothing else, against a declared 54-byte body.

Note the shape of the mistake that hides this. A `try/except Exception: pass`
around the read loop reports the same run as a clean 140-byte response with no
body, and that is how it was first measured -- the reset is the finding, and a
bare catch deletes it.

## Root cause

`serveConnection` answers the over-limit case without ever reading the request:

```zig
const in_flight = connection_threads.fetchAdd(1, .acq_rel);
if (in_flight >= max_connection_threads) {
    _ = connection_threads.fetchSub(1, .acq_rel);
    respondSaturated(io, stream);
    stream.close(io);
    return;
}
```

That is deliberate and is the point of the bound -- reading costs the thread the
refusal exists to save. But the client has already sent its request bytes, and
they sit unread in the socket's receive buffer. Closing a socket that still holds
received data is specified to send RST rather than FIN, and an RST discards
whatever is still queued in the *send* buffer. So the response races the reset,
and on loopback the body usually loses.

Which is also why the post-fix binary looks better without being fixed: adding
`recordHttpRequest` and a log line between `respond` and `stream.close` puts
real work between the two, and the body wins the race. Measured three times on
the fixed binary: 217, 218, 218 bytes -- body present -- and
`ConnectionResetError` every time. **The body arriving there is a timing
artifact, not a guarantee**, and nothing in that change makes it one.

## Resolution

Resolved on 2026-08-29. Option 2 (which subsumes option 1): `drainThenClose`
(src/cli.zig) replaces the bare `stream.close` on both saturation sites. It
shuts down the send side (the client sees FIN and knows nothing more follows),
then drains the unread request -- bounded twice over, by a 1s receive timeout
and a 64 KiB byte cap, since this runs on the accept thread the connection
bound protects -- and only then closes, on a socket whose receive buffer is
empty, which makes the close a FIN and lets the 503 body arrive by
specification rather than by winning a race.

The options as they stood, with the tension named -- every one of them spends
something on a connection the server is refusing precisely because it has
nothing to spend:

1. **Drain before closing.** Read and discard the pending request (bounded: one
   buffer, one non-blocking read) so the close is a FIN. Cheapest correct thing,
   and it is a read on the accept thread, which is the thread the bound is
   protecting.
2. **`shutdown(SHUT_WR)` then a bounded drain, then close.** The orderly-release
   shape. Same cost as 1 plus a syscall, and it also tells the client no more is
   coming.
3. **`SO_LINGER` off with a timeout, or rely on the client.** Does not help: the
   RST here is caused by unread receive data, not by lingering unsent data.
4. **Leave it and document that a saturation refusal may arrive as a reset.**
   Defensible if the header reliably lands, but that is the part not established
   -- see below.

## Verification

The fix is pinned by a socketpair unit test ("drainThenClose empties the
receive buffer so the close is a FIN the client can read through", src/cli.zig):
request bytes sent and never read by the server, response written,
drainThenClose, and the client reads the full response and then a clean EOF
rather than a reset.

What is verified is the defect, live, on both binaries, with the exception
surfaced rather than swallowed. What is **not** established:

- Whether the *header* always lands. It did in every run here (4 pre-fix,
  3 post-fix, loopback, macOS), but that is the same race the body loses, so a
  slower path or a busier machine could lose the status line too. Nothing here
  supports promising the client gets the 503 at all.
- Whether this reproduces off loopback or off macOS. Not tried.
- The `proxy.webui_reserved_slots` branch a few lines below takes the same
  `respondSaturated` + `close` shape and should behave identically, but it was
  not separately exercised.

## Follow-up

- Decide between options 1 and 2 before anything is written that depends on
  reading the refusal's body -- a client that retries on 503 but not on a
  transport error will behave differently under load than its author expects.
- Whichever way it goes, the claim "the client is told it was refused" needs a
  test that reads to `Content-Length`, not one that reads a header block.

## References

- Investigation: none; reproduced live on both sides of the metrics fix.
- [The saturation 503 is never counted or logged](2026-08-23-connection-limit-503-runs-on-the-accept-thread.md)
  -- the same code path, fixed for what it records; this is how it closes, and
  is untouched by that change.
- `src/cli.zig` -- `serveConnection` (both over-limit branches),
  `respondSaturated`.
