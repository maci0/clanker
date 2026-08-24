# RFC 0037 — How a sandboxed guest reads an HTTP response header

## Status

Decided — 2026-08-24. Decided as recommended: option A, an allowlisted envelope on ck_http_ex. Recorded in ADR 0049. One divergence from the recommendation, and it is the fallback the RFC named: ck_http was left on std.http.Client.fetch rather than sharing the head-retaining path, so the open question about existing guests' transport is not answered but is also no longer load-bearing.

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

`ck_http` returns the response body and nothing else, so no guest can read
`Link`, `ETag`, `X-RateLimit-Reset` or `Retry-After`. Pagination past the first
page, a rate-limit reset time and ETag revalidation are therefore *unbuildable*
rather than unbuilt — PRD 0019 lists all three as future work, which reads as
"not done yet" and is really "the transport does not carry it". The 2026-08-23
status envelope (`writeHttpFailure`) opened a channel for the *status* of a
failed response and deliberately stopped there, because the shape is an ABI
decision and not a bug fix.

**Decision to make.** Which ABI shape carries response headers from the host to
a sandboxed guest?

**Why now.** A guest is already inferring header facts from bodies. `gh_read`
requests the maximum page size and treats a full page as a truncation signal,
because it cannot read `Link: rel="next"`; that inference is shipped and
documented in its own `llm_description`. A paginating `web_fetch` would be the
second. Every additional inference is a caller to migrate later, and PRD 0019
has a criterion ("the rate-limit error includes a reset time") that cannot be
met at all until this is decided.

**New evidence that changes the costs.** The bug report says the head is in hand
when the status is read, so that everything except the status is merely dropped.
That is not so. `std.http.Client.fetch` returns

```zig
pub const FetchResult = struct {
    status: http.Status,
};
```

and consumes `response.head` internally. Reading a header requires abandoning
`fetch` for the lower-level `client.request` + `sendBodiless`/`sendBodyUnflushed`
+ `receiveHead` sequence and calling `Head.iterateHeaders()` — roughly the 60
lines `fetch` itself is, redirect policy and the four-way content-encoding
branch included. **This cost is identical for options A, B and D**, so it does
not discriminate between them; what it does is raise the floor under all three
and make the status quo and option E cheaper by comparison than the report
implies. It is also the main risk in the whole RFC: a hand-rolled body read is
where chunked transfer encoding and gzip go wrong.

**Drivers.**

1. **Allowlist, not passthrough.** Response headers are attacker-controlled text
   arriving on the exact path the sandbox exists to confine. The set of exposed
   names is fixed host-side. The report calls this the part that is not
   optional, and nothing here disputes it.
2. **The contract is a type, not a comment.** The status envelope's weakness is
   that "call `ck_result` immediately after the error" is a doc comment. A shape
   that repeats that mistake is worse than it looks on day one.
3. **No existing guest may break.** Every current caller reads raw body bytes
   out of the result slot. `web_fetch`, `web_search`, `gh_read` and the research
   sweep all do.
4. **ABI surface has recurring cost.** Every `pub fn ck…` must be registered
   with the zwasm linker (`sandbox-abi` in `clanker gate` pins this) and rots
   against zwasm API changes in silence if it is not.
5. **One transport.** Two HTTP implementations in `host.zig` would drift; the
   report names that as option 1's cost.

**Out of scope.** Whether the harness should *use* the headers it can now read —
pagination, an ETag cache and a `Retry-After` backoff are each their own change,
and PRD 0019 owns them. Also out of scope: request headers, which `ck_http`
already carries via `hdr_json`.

## Current state

`ck_http` is `(method, url, body, headers) -> rc`, exported at
`host.zig:1793` and registered as `env.ck_http` at `runtime.zig:47`. The
response reaches the guest through `h.writeResult(mem_bytes, resp_buf[0..n])` as
raw body bytes; `httpFetchTask` returns `HttpOutcome`, whose only non-body field
is `status.code`, and only for `>= 400`.

On a `>= 400` response, `writeHttpFailure` parks
`{"ck_http_status":<code>,"body":"<2 KiB>"}` in the result slot and the return
code stays `Err.network`. `tools/zig/lib.zig` exposes that as an optional read
after the error (`ck_http_status` is the marker key). On any `< 400` response
there is no envelope at all: the slot holds body bytes.

The workaround in place of a decision is inference from the body:

- `gh_read` asks for `per_page=100` and reports `[truncated: ...]` when it gets
  a full page. A full page is not the same fact as `Link: rel="next"` — the
  final page of exactly 100 items reports truncation that does not exist.
- The reset time and the `ETag` have no body-side proxy at all. They exist
  nowhere but the head, so no inference recovers them.

## Options considered

### Option A — allowlisted envelope on a second entry point

- **What it is:** a new `ck_http_ex` with the same argument list as `ck_http`,
  whose result slot always holds
  `{"status":N,"headers":{...},"body":"..."}`. The exposed header names are a
  fixed host-side list. `ck_http` keeps its current contract exactly.
- **Maturity:** n/a — in-tree change, no dependency.
- **How it would fit:** one new `pub fn ckHttpEx` in `host.zig`, one
  `defineFuncCtx` row in `runtime.zig`, one `extern fn` plus a wrapper in
  `tools/zig/lib.zig`. Driver 5 is satisfied by extracting the head-retaining
  fetch *once* and having both entry points call it, differing only in what they
  write to the result slot.
- **Pros:** one call for one logical operation, so driver 2 holds by
  construction — a guest that gets a reply gets the headers with it, and there
  is no ordering to forget. Self-describing: status, headers and body arrive in
  one object, which also closes the `< 400` status gap the 2026-08-23 change
  left open. Allowlist lives in one place. Existing guests untouched (driver 3).
- **Cons:** a second HTTP entry point in the catalog and in `lib.zig`, and the
  envelope costs a JSON parse in the guest even when it only wanted the body.
  Body bytes are JSON-escaped, so a large binary-ish response inflates.
- **Cost to adopt:** the head-retaining fetch (the shared floor above), plus
  the envelope writer, the allowlist and the guest binding.
- **Cost to leave:** low. Delete the entry point; `ck_http` never changed, so no
  caller of the old channel is affected.
- **Evidence:** `Head.iterateHeaders()` exists at `Client.zig:644` and yields a
  `http.HeaderIterator` — verified by reading the vendored std, not assumed.

### Option B — a separate `ck_http_headers` call

- **What it is:** `ck_http` unchanged; a new call returns the *last* response's
  head from host-side state.
- **Maturity:** n/a.
- **How it would fit:** one new `pub fn ck…`, one linker row, one binding, plus
  a per-`Host` slot holding the last head.
- **Pros:** smallest ABI delta in argument terms. A guest that does not care
  pays nothing — no envelope, no JSON parse, body bytes stay raw.
- **Cons:** makes two calls out of one logical operation, and the "call it
  immediately after" contract is a comment rather than a type — exactly the
  shape driver 2 exists to reject, and exactly the criticism the status envelope
  already attracts. Worse here than there: the status envelope is only written
  on a failure path a guest is already handling, whereas this would be the
  normal path. It also adds mutable per-host state whose lifetime is a second
  thing to get wrong (concurrent tool workers share a `Sandbox`).
- **Cost to adopt:** same head-retaining fetch, plus the state slot.
- **Cost to leave:** low, same as A.
- **Evidence:** the report's own assessment of this option, which this RFC
  agrees with.

### Option C — status quo, keep inferring from the body

- **What it is:** change nothing; `gh_read` keeps treating a full page as
  truncation.
- **Pros:** zero work, zero new ABI, zero new attack surface.
- **Cons:** pagination stays an inference that is wrong on the exact-multiple
  boundary. The reset time and the `ETag` stay unreachable, so PRD 0019's
  reset-time criterion is unshippable as designed and should be marked so rather
  than left as future work. And the pressure does not go away: the next guest
  that wants a header invents its own body-side proxy.
- **Cost to adopt:** zero now. Later: every inference built in the meantime is a
  caller to migrate, and one of them is already shipped.
- **Evidence:** `gh_read`'s `llm_description` documents the workaround to the
  model, which is how far it has already spread.

### Option D — a reserved key in the existing `hdr_json` parameter

- **What it is:** no new entry point at all. `ck_http`'s existing request-header
  JSON gains a reserved key (say `"__response_headers"`) naming which response
  headers the caller wants; when present, the result slot carries the envelope
  instead of raw body bytes.
- **Maturity:** n/a.
- **How it would fit:** no new `pub fn ck…`, so `sandbox-abi` has nothing new to
  register and driver 4 costs nothing.
- **Pros:** zero ABI surface added, which is a real saving. Opt-in, so driver 3
  holds. One call, so driver 2 holds.
- **Cons:** overloads a parameter that means "headers to send" with a control
  channel meaning "headers to receive", and makes one function's return *shape*
  depend on the content of an argument. That is precisely the accretion the bug
  report warns against ("it should not be grown into one by accretion"). A
  reserved key also collides, in principle, with a real header of that name;
  the collision is avoidable by spelling but the ambiguity is permanent.
- **Cost to adopt:** same head-retaining fetch; slightly less wiring than A.
- **Cost to leave:** worst of the four. The key is baked into a function every
  guest already calls, so removing it later means auditing all of them.
- **Evidence:** `parseCustomHeaders` (`host.zig:2938`) already silently skips
  malformed and non-string entries, so a reserved key would sit beside
  permissive parsing — a bad neighbourhood for a control channel.

### Option E — out-of-the-box: grant the guest `gh` and read headers via `gh api -i`

- **What it is:** no transport change whatsoever. `gh` is already an
  `exec_allow`-able command with pattern support (`util/glob.zig` mirrors
  `exec_pattern_allow` for `git`/`gh`), and `gh api --include` prints the
  response headers ahead of the body. Give `gh_read` an `exec_allow` entry and
  it can read `Link` and `X-RateLimit-Reset` today, using a capability the
  sandbox already has.
- **Maturity:** `gh` is a shipped, widely deployed CLI; the machine already
  authenticates with it.
- **How it would fit:** a manifest change to `gh_read.tool.json` and guest code
  to parse `gh`'s output. Nothing in `host.zig`, nothing in the ABI.
- **Pros:** genuinely zero ABI cost and available immediately. Verified to be
  reachable: `gh_read.tool.json` currently declares `network_allow`,
  `env_allow`, `fs_prefixes` and no `exec_allow`, so the grant is the only
  missing piece.
- **Cons:** solves GitHub and nothing else — `web_fetch` and any future API
  client are untouched, so the general problem stays open and this becomes a
  special case to maintain beside whatever eventually solves it. It also trades
  a confined HTTP call for a subprocess: the guest gains the ability to run a
  binary that holds the operator's GitHub credentials, which is a *larger*
  privilege than reading two header values, and `gh`'s output format is not a
  stable API.
- **Cost to adopt:** low.
- **Cost to leave:** low in code, but the capability grant is the hard part to
  walk back once a guest depends on it.
- **Evidence:** `gh_read.tool.json` read directly (no `exec_allow` key);
  `execDenial` tests at `host.zig:6673` confirm `gh` is allowlistable with
  argument patterns.

## Implications by horizon

### Short term (this release / 0–3 months)

- **If A:** `ETag`, `Link`, `Retry-After` and the rate-limit headers become
  readable by any guest that asks; PRD 0019's reset-time criterion becomes
  shippable. One new catalog entry to document.
- **If B:** same capability, one more chance for a guest to read a header
  belonging to a different request.
- **If D:** same capability, no new ABI, and a function whose return shape now
  depends on an argument's contents.
- **If E:** `gh_read` alone gets pagination and reset time; `web_fetch` does
  not.
- **If status quo:** `gh_read`'s truncation signal stays wrong on exact
  multiples of the page size.

### Medium term (3–12 months)

- **If A:** new API clients are written against one obvious channel. The two
  entry points must be kept in step, which driver 5's shared-fetch mitigation is
  there to handle.
- **If B:** the ordering contract is load-bearing and undocumented in the type
  system; the first bug is a guest reading a stale head after a cached or
  short-circuited call.
- **If D:** every guest calling `ck_http` is a potential caller of the reserved
  key, so the audit surface for changing it is the whole catalog.
- **If E:** a second consumer wants headers, cannot use `gh`, and this RFC is
  reopened having spent a capability grant in the meantime.
- **If status quo:** more body-side inferences, each one a migration.

### Long term (12+ months)

- **If A:** plausibly `ck_http` is retired in favour of the enveloped call and
  the two collapse into one. The envelope is the more general shape, so this
  direction is available; nothing forces it.
- **If B:** the two-call pattern is now idiomatic in this codebase and the next
  channel copies it.
- **If D:** the reserved key is permanent.
- **If E / status quo:** the transport gap is still open, with more callers
  routed around it.

## Recommendation

**Recommended option:** A — allowlisted envelope on a second entry point, with
the head-retaining fetch extracted once and shared with `ck_http`.

**Confidence:** 7/10

**Why this confidence.** The *shape* argument is strong and I would put it near
9: driver 2 is the lesson the status envelope already taught in this same file,
and A is the only option that satisfies it without the costs D and B carry. The
score is 7 because of the implementation risk, not the design: the head-retaining
fetch is a hand-rolled reimplementation of `std.http.Client.fetch`, and the
places such code fails — chunked transfer encoding, gzip and zstd
`content_encoding`, a redirect that must stay refused — are not exercised by a
loopback mock that returns a short identity-encoded body. What would raise it to
9: the new path verified against a real endpoint returning gzip and chunked
responses, plus the existing `ck_http` guests re-run through the shared fetch and
shown unchanged. What would sink the recommendation: if routing `ck_http`
through the new fetch changes any existing guest's behaviour, in which case the
right answer is a *separate* transport for the new entry point (accepting driver
5's drift) or option E as a stopgap.

**Rationale.** A and D buy the same capability; the trade accepted is one extra
ABI entry point (driver 4) in exchange for not making a function's return shape
depend on an argument's contents. That is worth it because the envelope is a
*type* the guest can validate, whereas D's reserved key and B's implicit
ordering are both conventions a caller can violate silently — and this codebase
has already been bitten by exactly that with the status envelope. Against E: E
is cheaper and available now, but it trades a confined HTTP call for a
subprocess holding the operator's credentials, which is a worse privilege trade
than the problem justifies, and it leaves the general gap open.

**Reversibility.** High. `ck_http` is unchanged, so the new entry point can be
deleted without touching an existing caller. The point of no return is a guest
shipping a dependency on the envelope's field names; until then this is
additive. The one genuinely shared piece is the head-retaining fetch, and if it
proves unsound the fallback is to point `ck_http` back at `std.http.Client.fetch`
and leave the new path on the new code.

## Open questions

- Does routing `ck_http` through the head-retaining fetch change any existing
  guest's observable behaviour? Answerable by running `web_fetch`/`web_search`
  before and after. **This is the question the confidence score is resting on.**
- What is the right initial allowlist? `ETag`, `Link`, `Retry-After`,
  `X-RateLimit-Reset`, `X-RateLimit-Remaining`, `Content-Type`,
  `Last-Modified` covers every use PRD 0019 names. Answerable by PRD 0019's
  criteria; cheap to widen later, and widening is the safe direction since
  omitting a name only blocks a feature while adding one exposes text.
- Should the envelope cap header *values*? A server can return a very long
  header. Not answered here; a per-value cap in the spirit of
  `http_failure_body_cap` is the obvious default.

## Next steps / action items

- [x] Write the ADR once the decision is made — [ADR 0049](../adrs/0049-a-guest-reads-response-headers-through-an-allowlisted.md).
- [x] Extract the head-retaining fetch. The first open question was **sidestepped
      rather than answered**: `ck_http` was left on `std.http.Client.fetch`, so no
      existing guest's transport changed and there was nothing to measure. That is
      the fallback named under Reversibility, and it trades driver 5 (one
      transport) for driver 3 (break nothing). Consolidating the two remains open.
- [x] Land the allowlist with a per-value cap (`max_exposed_header_value`, 1 KiB).
- [ ] Migrate `gh_read`'s truncation inference to `Link`, as PRD 0019 work. Its
      rate-limit *reset time* did land here, because that criterion was the one
      declared unmeetable and it is a two-line read of a header the envelope now
      carries; the pagination rewrite is a behaviour change to a shipped output
      and is not.

## References

- [Bug — ck_http hands guests no response headers](../reports/bugs/2026-08-23-ck-http-hands-guests-no-response-headers.md)
  — the report this RFC answers. Its claim that the head is in hand when the
  status is read is corrected above.
- [Bug — ck_http drops the status and body of every >= 400 response](../reports/bugs/2026-08-23-ck-http-drops-error-status-and-body.md)
  — the status half, fixed 2026-08-23, and the source of driver 2.
- [PRD 0019](../prds/0019-github-fs.md) — the three criteria this blocks.
- `src/sandbox/host.zig` — `ckHttp`, `httpImpl`, `httpFetchTask`,
  `writeHttpFailure`, `parseCustomHeaders`.
- `src/sandbox/runtime.zig:47` — the `env.ck_http` linker row every new
  `pub fn ck…` needs a sibling of.
- `tools/zig/lib.zig` — the guest-side bindings.
- Vendored `std/http/Client.zig`: `FetchResult` at 1787 (status only), `fetch`
  at 1801, `Response.Head` at 494, `Head.iterateHeaders` at 644.

## Appendix

`FetchResult`, quoted from the vendored standard library, as the whole of what
`fetch` hands back:

```zig
pub const FetchResult = struct {
    status: http.Status,
};
```

The sequence a header-reading implementation has to run instead, from `fetch`'s
own body — this is the code that would be reproduced, and the four-way
`content_encoding` branch is the part most likely to be got wrong:

```zig
var req = try request(client, method, uri, .{ ... });
if (options.payload) |payload| { ... } else try req.sendBodiless();
var response = try req.receiveHead(redirect_buffer);
const decompress_buffer: []u8 = switch (response.head.content_encoding) {
    .identity => &.{},
    .zstd => ...,
    .deflate, .gzip => ...,
    .compress => return error.UnsupportedCompressionMethod,
};
const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
_ = reader.streamRemaining(response_writer) catch ...;
```
