# Bug — ck_http hands guests no response headers, so header-only facts are unreachable

## TL;DR

- **What failed:** Every `ck_http` variant returns the response body and nothing else. A guest can never read `Link`, `X-RateLimit-Reset`, `ETag`, `Retry-After` or `Content-Type`. Anything GitHub (or any API) states only in a header is therefore unreachable from a guest no matter how the guest is written.
- **Impact:** Four things are unbuildable rather than unbuilt. PRD 0019 wants a reset time on its rate-limit error (`X-RateLimit-Reset`), pagination past the first page (`Link: rel="next"`), and ETag revalidation for its cache (`ETag` / `If-None-Match`); a polite retry after a secondary rate limit wants `Retry-After`. Each is filed as future work, which reads as "not done yet" and is really "the transport does not carry it".
- **Resolution:** Open. The 2026-08-23 status-envelope change (`writeHttpFailure`) added a channel for the *status* of a failed response and deliberately did not widen it to headers, because that is an ABI shape decision and not a bug fix.

## Status

Open.

## Symptom and impact

`ck_http` is `(method, url, body, headers) -> rc`, with the response delivered
through `writeResult` as raw body bytes (`httpImpl`, `src/sandbox/host.zig`).
`std.http.Client` has the response head in hand at that point --
`result.status` is read for the >= 400 check -- and everything except the status
is dropped when `httpFetchTask` returns.

Concretely, from work on `gh_read` the same day:

- GitHub's issue list answers 30 items and puts the next page in
  `Link: <...&page=2>; rel="next"`. The guest sees the 30 and cannot learn there
  is a page 2. The workaround shipped is to request the maximum page size and
  treat a full page as a truncation signal, which is an inference from the body
  because the header is not available.
- A primary rate limit carries `X-RateLimit-Reset` as a Unix timestamp. PRD
  0019's criterion "the rate-limit error includes a reset time (resets at
  <ISO8601>)" cannot be met; the guest can say the quota is gone but not when it
  returns.
- The PRD's own future-work entry for an ETag cache ("sqlite / ETag / soft-hard
  TTL") needs the `ETag` of the response it is caching. The guest writes a cache
  record with no way to obtain one.

## Reproduction

Read `httpImpl` and `httpFetchTask` in `src/sandbox/host.zig`: the only fields of
`std.http.Client.FetchResult` that leave the function are the status (as a `u16`,
and only since 2026-08-23) and the body bytes. There is no header parameter on
any `ck_http` signature in `tools/zig/lib.zig`, so no guest can be written that
reads one.

## Root cause

Not a defect in the implementation of anything -- a boundary drawn narrower than
what callers need. `ck_http` was shaped for "fetch a page", where the body is the
whole answer. An API client is a different caller: for it, part of the answer is
routinely in the head.

## Resolution

**Open. Not fixed.** What landed on 2026-08-23 is a status channel only: on a
>= 400 response `writeHttpFailure` parks
`{"ck_http_status":<code>,"body":"<2 KiB>"}` in the result slot. That closes
"which error was it" and closes nothing else. It is deliberately not a header
channel, and it should not be grown into one by accretion.

Options, none chosen:

1. **An allowlisted header map in the result envelope.** Return
   `{"status":N,"headers":{...},"body":"..."}` from a new `ck_http2`, with the
   set of exposed header names fixed host-side. Bounded and auditable; a second
   HTTP entry point to keep in step with the first.
2. **A separate `ck_http_headers` call** reading the last response's head.
   Smallest ABI delta, but it makes two calls one logical operation and the
   second can be forgotten -- the same shape as the status envelope, whose
   "call it immediately after" contract is a comment rather than a type.
3. **Leave it closed and keep inferring from the body.** What `gh_read` does
   now. Works for pagination (a full page means more), does not work for a reset
   time or an ETag, both of which exist nowhere but the head.

Whichever way it goes, response headers are attacker-controlled text on a path
the sandbox exists to confine, so an allowlist rather than a passthrough is the
part that is not optional.

## Verification

Nothing to verify: no fix is claimed. What is verified is the absence -- read
from the two functions named above and from every `ck_http` signature in
`tools/zig/lib.zig`, not inferred from a failing call.

## Follow-up

- Decide between options 1 and 2 before a second guest starts inferring
  header facts from bodies; `gh_read` is one, and a paginating `web_fetch` would
  be the second.
- If it stays closed, PRD 0019's reset-time criterion should be marked
  unshippable-as-designed rather than left as future work.

## References

- Investigation: none needed; the gap is visible in the ABI signatures.
- [PRD 0019](../../prds/0019-github-fs.md) — the criteria this blocks.
- [ck_http drops the status and body of every >= 400 response](2026-08-23-ck-http-drops-error-status-and-body.md)
  — the status half, fixed; this is the header half, not fixed.
- `src/sandbox/host.zig` (`httpImpl`, `httpFetchTask`), `tools/zig/lib.zig`.
