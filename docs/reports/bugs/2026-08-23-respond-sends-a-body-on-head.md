# Bug — cli.zig respond() sends a full body on HEAD, against RFC 9110 and its own stated invariant

## TL;DR

- **What failed:** AGENTS.md records that every body-writing responder guards HEAD with 'if (!request_head)', and the asset, JSON and plugin responders do. respond() does not: it writes the body unconditionally and compensates by forcing the connection closed. Measured live, HEAD /api/does-not-exist returns 404 plus all 32 body bytes. Harmless because the close ends the message, but it is content RFC 9110 9.3.2 forbids and it costs keep-alive on every HEAD. Open, not fixed.
- **Impact:** Nothing was observed to break: `respond` forces `Connection: close` on HEAD, so the extra bytes are discarded with the connection. The costs are non-conformance with RFC 9110 9.3.2, the loss of keep-alive on every HEAD including web UI assets, and an `AGENTS.md` invariant that reads as true when one responder does not hold it.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

Measured against a real `clanker serve` on loopback, reading the raw bytes off
the socket rather than through a client that might hide them:

```
HEAD /api/does-not-exist: status=HTTP/1.1 404 Not Found | body bytes after headers = 32 b'{"ok":false,"error":"not found"}'
HEAD /health/live:        status=HTTP/1.1 404 Not Found | body bytes after headers = 32 b'{"ok":false,"error":"not found"}'
GET  /api/does-not-exist: status=HTTP/1.1 404 Not Found | body bytes after headers = 32 b'{"ok":false,"error":"not found"}'
```

The HEAD responses carry the whole body. RFC 9110 section 9.3.2 forbids content
on a HEAD response.

Two costs, both small:

- Non-conformance. A client that reads exactly `Content-Length` bytes and then
  reuses the connection would read those bytes as the head of the next
  response. `respond` prevents that by forcing `Connection: close`, so no
  observed client is corrupted -- but the guard is a workaround for the
  violation, not conformance.
- Every HEAD gives up keep-alive, including HEAD on a web UI asset, which is
  the case keep-alive was introduced for.

Worth stating plainly: nothing was observed to break. This is filed because
`AGENTS.md` asserts the opposite as an invariant -- "Every body-writing
responder guards HEAD with `if (!request_head)`" -- and a reader trusting that
line would conclude the surface is conformant when one responder is not.

Incidental, and *not* the defect: `HEAD /health/live` is a 404 rather than a
200, because the health routes match `GET` only. Whether the liveness probe
should answer HEAD is a product question, not this bug.

## Reproduction

Start `clanker serve` on a loopback port and send a raw
`HEAD /api/does-not-exist HTTP/1.1` with a matching `Host`, then count the
bytes after the header terminator. Verified on aarch64-macos at `origin/main`
cfb28bee.

## Root cause

`respond` in `src/cli.zig` writes header then body unconditionally:

```zig
if (request_head) request_keep_alive = false;
...
raw_http.writeAllFd(stream.socket.handle, hdr);
raw_http.writeAllFd(stream.socket.handle, body);
```

Its own comment records the choice -- "A HEAD answer still writes the body
below; on a kept-alive connection those bytes would be read as the next
response, so HEAD closes" -- so this is a known trade rather than an oversight.
The asset, JSON and plugin responders took the other route and guard the write.
The inconsistency is what makes the invariant in `AGENTS.md` false.

Which routes are reachable by HEAD matters for scope: most `/api/*` arms match
`GET` explicitly, so in practice HEAD lands on the generic 404, on the
`webui` module-disabled 404, and on the `isWebuiRead` asset routes (which
already guard). So the body-on-HEAD is mostly on error responses.

## Resolution

Open, not fixed. The one-line change (`if (!request_head)` around the body
write, and dropping the keep-alive kill) is a behaviour change on every HEAD
the surface answers, and the keep-alive half of it interacts with framing that
already caused one regression (the asset responders' kept-alive HEAD, noted in
`AGENTS.md`). It deserves its own change with its own test, not a rider on an
unrelated fix.

Found while fixing three serve bugs (#365, #368, #372); reading `respond` was
incidental to that work.

## Verification

None -- nothing was changed. The measurements in Symptom are what was observed.

## Follow-up

A fix should also decide what the invariant sentence in `AGENTS.md` says
afterwards, since today it describes an intent rather than the code.

## References

- `AGENTS.md`, `src/serve/` bullet -- the invariant this contradicts.
- Investigation: none
