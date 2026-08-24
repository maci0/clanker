# ADR 0049 — A guest reads response headers through an allowlisted envelope on a second HTTP entry point

## Status

Accepted — 2026-08-24. Records the decision opened in [RFC 0037 — How a sandboxed guest reads an HTTP response header](../rfcs/0037-how-a-sandboxed-guest-reads-an-http-response-header.md).

Accepted / Superseded by ADR-NNNN / Deprecated. One decision per ADR; if a
later decision reverses this one, mark this file Superseded and link
forward rather than editing history out of it.

## Context

ck_http returned the response body and nothing else, so no guest could read Link, ETag, X-RateLimit-Reset or Retry-After. Pagination past the first page, ETag revalidation and a rate-limit reset time were unbuildable rather than unbuilt: PRD 0019 lists all three as future work, and its reset-time criterion could not be met at all. gh_read had already shipped an inference in place of a header, asking for the maximum page size and reading a full page as truncation. The 2026-08-23 status envelope opened a channel for the status of a failed response and deliberately stopped short of headers, because the shape is an ABI decision. std.http.Client.fetch cannot supply the head: it returns FetchResult{status} and consumes response.head internally, so this was never a matter of returning a value already in hand.

The situation that forced a choice: the constraint, the competing option(s)
seriously considered, and why the status quo (or the obvious alternative)
didn't work. A reader five years from now should be able to tell whether
the constraint still holds without reading the whole codebase.

## Decision

ck_http_ex takes the same arguments as ck_http and always parks {"status":N,"headers":{...},"body":"..."} in the result slot. The exposed header names are a fixed host-side allowlist (exposed_response_headers), lowercased, with each value capped at 1 KiB; everything else, Set-Cookie included, is dropped. Any status the server produced is a success, so the return code answers only whether the exchange happened. ck_http keeps its exact current contract and still goes through std.http.Client.fetch. gh_read is the first caller and now names the reset time PRD 0019 asked for.

> The RFC recommended: **Recommended option:** A — allowlisted envelope on a second entry point, with


The choice, stated plainly in one or two sentences. Not the implementation
detail — that lives in code and, if the decision is part of a larger
feature, in the relevant PRD (`docs/prds/`). Link it if so.

## Consequences

Two HTTP transports now exist in host.zig and can drift, which is the cost RFC 0037 named as this option's own downside. It was accepted rather than solved: routing ck_http through the new head-retaining fetch would put every existing guest's transport behind new code, and the measurement that would justify that is left as follow-up. The envelope also costs a guest a JSON parse and JSON-escapes body bytes, so a caller that only wants the body should stay on ck_http. Widening the allowlist is a code change and a release, not config, which is deliberate but means a guest needing a new header waits for one. And a guest cannot read Location: redirects are refused, so a 3xx arrives as a response whose redirect target is not exposed.

What this makes easy, what it makes hard or forecloses, and what it costs
later if the context changes. Include the honest downside, not just the
justification — an ADR that only argues for the decision isn't useful when
someone is deciding whether to revisit it.
