# Bug — The /api/events cap refusal declares a Content-Length four bytes longer than its body

## TL;DR

- **What failed:** serveSse's 503 was one hand-written literal whose Content-Length said 52 for a 48-byte body, so a client that honors the header waited for four bytes that never arrived: Python's http.client raised IncompleteRead(48 bytes read, 4 more expected) against a real clanker serve with all 32 slots taken. The operator saw a transport error where the server had already named the cause. Only reachable at the subscriber cap, which the sibling slot-leak bug made far easier to hit.
- **Impact:** Bounded by reachability. It needs all 32 live-bus slots taken, and a client that treats the connection close as end-of-body (curl, the browser's EventSource) is unaffected -- which is why it went unnoticed. Where it does bite, the operator gets a transport error in place of the one refusal the server had already diagnosed by name. A grep for a literal `Content-Length` across `src/` finds this one occurrence in production code, so nothing else shares the defect.
- **Resolution:** Resolved on 2026-08-23. The response is now built at comptime from the body (comptimePrint over too_many_subs_body.len), so the declared length is derived from what is sent. Pinned by 'the subscriber-cap 503 declares the length of the body it actually sends', which parses the length back out with raw_http.parseContentLength and fails 'expected 48, found 52' against the old literal. The IncompleteRead was reproduced live against a real serve at the cap before the fix. Gate: all eleven PASS.

## Status

Resolved on 2026-08-23. The response is now built at comptime from the body (comptimePrint over too_many_subs_body.len), so the declared length is derived from what is sent. Pinned by 'the subscriber-cap 503 declares the length of the body it actually sends', which parses the length back out with raw_http.parseContentLength and fails 'expected 48, found 52' against the old literal. The IncompleteRead was reproduced live against a real serve at the cap before the fix. Gate: all eleven PASS.

## Symptom and impact

With every one of `live.max_subs` (32) slots taken, the 33rd
`GET /api/events` is answered:

```
HTTP/1.1 503 Service Unavailable
Content-Type: application/json
Connection: close
Content-Length: 52

{"ok":false,"error":"too many live subscribers"}
```

The body is 48 bytes. The header claims 52.

A client that stops at the close reads the JSON and is unaffected, which is
why this went unnoticed: `curl` and the browser's `EventSource` both do. A
client that honors `Content-Length` does not. Python's `http.client` against a
real `clanker serve`:

```
status 503
client raised: IncompleteRead IncompleteRead(48 bytes read, 4 more expected)
```

So the one endpoint state where the server has diagnosed itself precisely --
"too many live subscribers" -- is the one where a strict client reports a
truncated response instead. Impact is bounded by reachability: it needs the
cap, and nothing else on the surface shares the literal (a grep for
`Content-Length: <digits>` across `src/` finds only this one occurrence in
production code).

Worth naming the interaction: the sibling bug
[events-slot-not-released-on-hangup](2026-08-23-events-slot-not-released-on-hangup.md)
leaked one slot per abandoned subscriber on macOS, and the web UI opens two
streams per page load, so the cap was reachable by reloading a page rather
than by having 32 real watchers.

## Reproduction

Against a `clanker serve` on a loopback port, open 32 `/api/events`
subscriptions and hold them, then make a 33rd request with a client that
honors `Content-Length`. `/api/metrics` `live.subscribers` reads 32 first, so
the cap is confirmed rather than assumed. Verified on aarch64-macos at
`origin/main` ba7a4494.

## Root cause

`serveSse` in `src/serve/live.zig` wrote the whole response as one string
literal with the length spelled out by hand. Nothing tied the number to the
bytes, so the two could differ and did. It is not a parsing or framing bug --
the number was simply wrong, and had been since the literal was written.

## Resolution

Fixed. The response is built at comptime from the body
(`std.fmt.comptimePrint` over `too_many_subs_body.len`), so the declared
length is derived from what is sent and cannot drift again. No behaviour
changes beyond the four bytes: same status, same body text, same
`Connection: close`.

## Verification

- Unit, in `src/serve/live.zig`: `the subscriber-cap 503 declares the length of
  the body it actually sends` parses the declared length back out of the
  response with `raw_http.parseContentLength` and compares it to the body
  slice. Run against the old literal it fails `expected 48, found 52`; it
  passes after.
- The live reproduction above was run before the fix and produced the
  `IncompleteRead` quoted in Symptom.
- `clanker gate`: all eleven checks PASS.

Live again after the fix, same 32-subscriber setup, same client:

```
subscribers: 32
status 503 | Content-Length 48
read(): {"ok":false,"error":"too many live subscribers"}
```

So both directions of the client-visible behaviour were observed, not
inferred.

## Follow-up

None outstanding. The comptime construction is the guard; a second
hand-written `Content-Length` in this file would have to reintroduce the
literal to reintroduce the bug.

## References

- `docs/reports/bugs/2026-08-23-events-slot-not-released-on-hangup.md` -- the
  slot leak that made the cap reachable, found and fixed alongside this.
- Investigation: none
