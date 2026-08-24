# Bug — ck_http hands guests no response headers, so header-only facts are unreachable

## TL;DR

- **What failed:** Every `ck_http` variant returns the response body and nothing else. A guest can never read `Link`, `X-RateLimit-Reset`, `ETag`, `Retry-After` or `Content-Type`. Anything GitHub (or any API) states only in a header is therefore unreachable from a guest no matter how the guest is written.
- **Impact:** Was: four things unbuildable rather than unbuilt. Now: the transport carries the headers, one of the four (the rate-limit reset time) ships, and the other three are ordinary unbuilt work. PRD 0019 wants a reset time on its rate-limit error (`X-RateLimit-Reset`), pagination past the first page (`Link: rel="next"`), and ETag revalidation for its cache (`ETag` / `If-None-Match`); a polite retry after a secondary rate limit wants `Retry-After`. Each is filed as future work, which reads as "not done yet" and is really "the transport does not carry it".
- **Resolution:** Resolved on 2026-08-24. Option 1 chosen and built: ck_http_ex parks {status,headers,body} with a fixed host-side header allowlist (RFC 0037, ADR 0049). gh_read moved onto it and now names the rate-limit reset time, closing PRD 0019's criterion. Two corrections to this report: std.http.Client.fetch does NOT have the head in hand (FetchResult carries only status), and ck_http was deliberately left on fetch, so two transports now exist. Link-based pagination and ETag revalidation are now buildable but still unbuilt.

## Status

Resolved on 2026-08-24. Option 1 chosen and built: ck_http_ex parks {status,headers,body} with a fixed host-side header allowlist (RFC 0037, ADR 0049). gh_read moved onto it and now names the rate-limit reset time, closing PRD 0019's criterion. Two corrections to this report: std.http.Client.fetch does NOT have the head in hand (FetchResult carries only status), and ck_http was deliberately left on fetch, so two transports now exist. Link-based pagination and ETag revalidation are now buildable but still unbuilt.

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

**Fixed.** Option 1 below was chosen, argued in
[RFC 0037](../../rfcs/0037-how-a-sandboxed-guest-reads-an-http-response-header.md)
and recorded in
[ADR 0049](../../adrs/0049-a-guest-reads-response-headers-through-an-allowlisted.md).
`ck_http_ex` takes the same arguments as `ck_http` and always parks
`{"status":N,"headers":{...},"body":"..."}` in the result slot; the exposed
header names are the fixed host-side `exposed_response_headers` allowlist,
lowercased, each value capped at 1 KiB. Any status the server produced is a
success there, so the return code answers only whether the exchange happened --
the report's own warning about the status envelope ("the contract is a comment
rather than a type") is the reason one call carries all three parts.
`ck_http` is untouched. `gh_read` is the first caller and now names the
rate-limit reset time, which was PRD 0019's unmeetable criterion.

Option 2 was rejected for exactly the reason this report gives against it.
Option 3 was rejected because `gh_read` had already shipped one inference and a
second consumer was foreseeable. A fourth and a fifth option that this report
did not raise are in the RFC: a reserved key inside the existing request-header
parameter, and granting `gh_read` `exec_allow: ["gh"]` so it could read headers
from `gh api --include` without any ABI change at all. The second of those is
genuinely cheaper and was rejected on privilege grounds, not cost.

### One correction to this report

> `std.http.Client` has the response head in hand at that point --
> `result.status` is read for the >= 400 check -- and everything except the
> status is dropped when `httpFetchTask` returns.

Not so, and it changed the cost of every option. `std.http.Client.fetch`
returns `FetchResult { status: http.Status }` and consumes `response.head`
internally; the head is gone before `httpFetchTask` sees anything. Reading a
header meant abandoning `fetch` for `request` + `sendBodiless`/`sendBodyUnflushed`
+ `receiveHead` and calling `Head.iterateHeaders()` -- reproducing `fetch`'s
body, four-way content-encoding branch included. That reimplementation, not the
ABI shape, was the risk in this change.

Options as originally framed:

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

The absence was verified by reading the ABI, and that still stands. The fix is
verified as follows.

**Host-side, against a loopback server** (`src/sandbox/host.zig`), because a
mock is the only way to control the framing:

- Allowlisted names arrive (`etag`, `link`, `x-ratelimit-reset`,
  `x-ratelimit-remaining`, `content-type`), lowercased. `Set-Cookie` in the same
  response does **not** arrive -- the allowlist is asserted by a negative, not
  assumed from the list's existence.
- A chunked body reads back whole, and a 429 arrives as a *response* carrying
  `Retry-After` rather than as an error.
- A genuinely gzip-compressed body is decompressed. This one matters: it is the
  branch RFC 0037 named as the main risk, and the live check below did **not**
  cover it.
- An over-long header value is capped rather than refusing the whole response.
- `writeHttpEnvelope`'s exact bytes, because splicing pre-rendered JSON needs
  `beginWriteRaw` and getting that wrong yields an envelope the guest cannot
  parse.

**Live, against `https://api.github.com/rate_limit`**, real TLS: status 200 and
the envelope
`{"content-type":"application/json; charset=utf-8","x-ratelimit-limit":"60","x-ratelimit-remaining":"54","x-ratelimit-reset":"1787571816"}`.
That reset value is the one the ISO-8601 test pins as `2026-08-24T11:43:36Z`, so
the number in the unit test came from the wire rather than from imagination.

**End to end through the wasm boundary**, which neither of the above crosses: a
sandbox runtime test loads the real `gh_read.wasm` with a deliberately invalid
`GITHUB_TOKEN` and gets
`{"ok":false,"error":"GITHUB_TOKEN rejected by GitHub (401); the token is
invalid or expired"}` -- guest calls `ck_http_ex`, host fetches and envelopes,
guest parses the status and renders the message. A 401 is a *response* on this
channel, where `ck_http` would have produced a bare `error.NetworkError`.

`clanker gate`: all twelve checks PASS, `sandbox-abi` included -- which is what
pins the new `pub fn ckHttpEx` as actually registered with the zwasm linker
rather than being a dead channel.

### What is not covered

- **`zstd` is untested.** The branch exists and is `fetch`'s own, but nothing
  here serves a zstd body.
- **The live check did not exercise compression.** `Accept-Encoding: gzip` was
  sent and GitHub answered `content_encoding=identity` -- measured, not assumed
  -- so TLS and real headers are proven live and gzip only against the mock.
- **`ck_http` was not re-routed** through the head-retaining fetch, so no
  existing guest's transport changed and nothing about them needed re-verifying.
  The flip side is two transports in `host.zig`; ADR 0049's Consequences names
  it and RFC 0037 leaves consolidation as follow-up.
- **The reset time was not observed live on a real rate-limit response.**
  Exhausting the quota to see it was not worth doing; the header is proven to
  arrive live, and that it becomes "resets at <ISO8601>" is proven by unit test.
- **`Link`-based pagination and `ETag` revalidation are not built.** They are
  now buildable, which is the whole point of this change, and they are PRD 0019
  work.

## Follow-up

- Consolidate the two transports: point `ck_http` at the head-retaining fetch
  once a measurement shows no existing guest's behaviour changes. RFC 0037's
  open question, unanswered rather than settled.
- `gh_read`'s truncation inference should move to `Link: rel="next"`. It is now
  buildable, and the inference is wrong on a final page of exactly `page_size`
  items. PRD 0019 work: it changes a shipped output the tool's own
  `llm_description` describes.
- `ETag` revalidation for the `gh_cache`, likewise now buildable.
- `zstd` has a branch and no test. Serve one, or narrow the branch.
- PRD 0019's reset-time criterion is now met rather than unshippable, and its
  Open-questions section is updated to say which of its parked items were
  transport-blocked and which were merely unbuilt.

## References

- Investigation: none needed; the gap is visible in the ABI signatures.
- [PRD 0019](../../prds/0019-github-fs.md) — the criteria this blocks.
- [ck_http drops the status and body of every >= 400 response](2026-08-23-ck-http-drops-error-status-and-body.md)
  — the status half, fixed; this is the header half, not fixed.
- `src/sandbox/host.zig` (`httpImpl`, `httpFetchTask`), `tools/zig/lib.zig`.
