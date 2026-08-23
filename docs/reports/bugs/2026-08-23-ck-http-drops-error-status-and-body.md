# Bug — ck_http drops the status and body of every >= 400 response, so two documented gh_read errors could never fire

## TL;DR

- **What failed:** `httpImpl` (`src/sandbox/host.zig`) mapped every response with a status >= 400 to `Err.network` and freed the response body with the rest of `resp_buf`. A guest therefore got `error.NetworkError` -- the same error a DNS failure, a refused connection and a timeout give -- with no status and no body. `gh_read`'s `looksLikeNotFound` and `looksLikeRateLimit` were scans over that body, so both were dead code: the two failure modes PRD 0019 documents, `not found: <url>` and `GitHub rate limit exhausted`, could not fire on any real GitHub answer.
- **Impact:** A missing issue reported `gh://issue/o/r/999: the request did not complete`. An exhausted rate limit, an expired token and an unreachable host were one indistinguishable error. The two dead scans read as working code and had a green build behind them, so the gap was invisible from the source.
- **Resolution:** Resolved on 2026-08-23. The host parks `{"ck_http_status":<code>,"body":"<first 2 KiB>"}` in the guest's result slot on the status path only; the return code stays `Err.network`, so no other guest changes behaviour. `lib.httpLastFailure` reads it and `gh_format.statusMessage` classifies 404 / 401 / 403-rate-limit / 403-other / everything else.

## Status

Resolved on 2026-08-23.

## Symptom and impact

`gh_read {"url":"gh://issue/maci0/clanker/999999"}` against a real token, before
the fix, took this path:

- GitHub answers `404` with `{"message":"Not Found", ...}`.
- `httpFetchTask` returns `.{ .status = 404 }`, discarding `w.end` -- the body
  length -- and `httpImpl`'s `defer` frees `resp_buf`.
- `httpImpl` returns `Err.network`; `lib.hostResult` maps 4 to
  `error.NetworkError`.
- `gh_read` reaches `lib.failErr(out, err, url)` and reports
  `gh://issue/maci0/clanker/999999: the request did not complete`.

`looksLikeNotFound(body)` and `looksLikeRateLimit(body)` sat between those last
two steps and were never reached with a 4xx body, because there was no 4xx body.
They ran only on a 200 response, where neither string appears.

This is the "a threshold that never ran" shape: code whose condition cannot be
satisfied looks identical to code whose condition is rarely satisfied, and no
test failed because no test put a 404 through the host.

## Reproduction

Before the fix, from a built tree with `GITHUB_TOKEN` set:

```bash
clanker run "Call gh_read once with url gh://issue/maci0/clanker/999999 and report the exact error"
```

The operator log shows the host knew the status --
`[sandbox] http request to '...' failed with status 404` -- while the guest
reported only that the request did not complete. The host log and the guest
message disagreeing about the same request is the whole bug in two lines.

## Root cause

`HttpOutcome.status` carried a `u16` and nothing else. The body length was
available at exactly one point, `w.end` inside `httpFetchTask`, and was not put
in the union, so by the time `httpImpl` decided what to return the only surviving
fact about the response was its status code -- which then also went unused
except in a log line.

The reason it stayed that way is that widening the *return code* is the obvious
fix and the wrong one: every guest that calls `ck_http` would start seeing a new
error for 4xx, and the ABI's error space is shared by ten host functions.

## Resolution

The return code is untouched. The status path additionally writes an envelope
into the result slot the guest already reads with `ck_result`:

- `writeHttpFailure` (`src/sandbox/host.zig`) stringifies
  `{"ck_http_status":<code>,"body":"..."}` with the body capped at 2 KiB, and is
  best-effort: a full arena or a stringify failure leaves no envelope and the
  guest falls back to the message that shipped before.
- The `ck_http_status` key is a marker. The result slot is shared and never
  cleared, so a guest reading it needs to know it is looking at this envelope
  and not at whatever an earlier host call left there. A transport failure or a
  timeout writes no envelope at all.
- `lib.httpLastFailure` (`tools/zig/lib.zig`) parses it, documented as valid
  only immediately after the `error.NetworkError` it explains.
- `gh_format.statusMessage` turns status plus body into the message: 404 to
  `not found: <url>`, 429 or a rate-limit body to `GitHub rate limit exhausted`,
  401 to a token-rejected message, a 403 without a rate-limit body to a
  permission message, anything else to `<url>: HTTP <code>: <the API's own
  message>`.

The two body scans are live for the first time, and now genuinely need to be
scans: GitHub reports both the primary and the secondary rate limit as 403, so
the status alone cannot separate a quota from a permission answer.

## Verification

- `src/sandbox/host.zig`, "a >= 400 response keeps its status and body for the
  guest": a loopback one-shot server answers 404 with a JSON body; the test
  asserts the outcome is `.status`, the code is 404, and the bytes in the
  caller's buffer are the body byte for byte. This test fails on the parent
  commit -- `outcome.?.status` was a `u16` with no length to check.
- `src/sandbox/host.zig`, "writeHttpFailure parks a marked status envelope in
  the result slot": pins the exact envelope, the marker, and that a body four
  times the cap is truncated rather than refused.
- `tools/zig/gh_format.zig`: 404, primary rate limit (403), secondary rate limit
  (403), 429, a 403 that is *not* a rate limit, a 422 carrying the API's message,
  and a 502 whose body is HTML rather than the JSON the API promises.
- Live: `gh://issue/maci0/clanker/999999` now returns
  `not found: gh://issue/maci0/clanker/999999`.

## Follow-up

- `X-RateLimit-Reset` is still out of reach: `ck_http` hands the guest no
  response headers, so PRD 0019's "resets at <ISO8601>" criterion stays
  unshipped. A header channel would be a separate ABI decision, not an extension
  of this envelope.
- Other guests that call `ck_http` could use the same channel to stop reporting
  a 4xx as a transport failure. None were changed here.

## References

- Investigation: none. `httpFetchTask` to `httpImpl` is one call graph and the
  discard is on one line.
- [PRD 0019](../../prds/0019-github-fs.md) — the two failure modes that could
  not fire.
- `src/sandbox/host.zig`, `tools/zig/lib.zig`, `tools/zig/gh_format.zig`.
