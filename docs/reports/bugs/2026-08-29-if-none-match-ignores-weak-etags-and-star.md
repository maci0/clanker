# Bug — If-None-Match ignores weak ETags and `*`, so revalidation behind an ETag-weakening proxy never 304s

## TL;DR

- **What failed:** `ifNoneMatchHits` (src/cli.zig) compared the request's `If-None-Match` values to the computed ETag with an exact string compare. RFC 9110 13.1.2 requires weak comparison (`W/"x"` matches `"x"`) and the `*` form (matches any current representation); both fell through to "no match".
- **Impact:** Any client revalidating with a weak tag — which is what a client behind an intermediary that re-encodes responses holds, since e.g. nginx's gzip filter weakens ETags on the way through — gets a 200 with the full body on every revalidation, forever. The conditional-GET machinery all three webui asset responders share (first-party assets, plugin assets, the served page) silently degrades to unconditional full transfers. `If-None-Match: *` misbehaving is the same one-line cause.
- **Resolution:** Resolved on 2026-08-29, same change that found it. Weak comparison and `*` handled in `ifNoneMatchHits`; the tags this server hands out are content hashes (crc32 of the body), so weak comparison of them is exact in practice.

## Status

Resolved on 2026-08-29. Found by reading the revalidation path while verifying
the webui asset cache headers live; fixed in the same change.
## Symptom and impact

Direct-to-server clients never see it: the server hands out strong tags and
browsers echo them back verbatim, so the exact compare hits. The failure needs
an intermediary that weakens the tag — permitted and common (nginx `gzip on`
turns `"abc"` into `W/"abc"`) — after which the client's cache revalidates with
`W/"abc"` on every reload and the origin answers 200 + full body every time.
Nothing errors; the cost is every asset re-downloaded on every visit for every
client behind that proxy, which is precisely the transfer the ETag exists to
skip.

## Reproduction

Read from the source, then pinned by unit test:

```
If-None-Match: W/"a7bd72e2"   ->  200, full body (pre-fix); 304 (post-fix)
If-None-Match: *              ->  200, full body (pre-fix); 304 (post-fix)
```

## Root cause

`ifNoneMatchHits` tokenized the header value on spaces and commas and compared
each token to the ETag with `std.mem.eql`. A weak tag differs by its `W/`
prefix, so it never compared equal, and `*` is not an ETag at all. RFC 9110
13.1.2: "the comparison must use the weak comparison function", and `*` matches
any current representation.

## Resolution

`ifNoneMatchHits` strips a `W/` prefix from each candidate before comparing and
answers true for `*`. The prefix strip is anchored (a quoted tag whose *content*
begins `W/` still mismatches), covered by test. All three responders share the
helper, so one change covers the page, the first-party assets and the plugin
assets.

## Verification

`zig build test -Dtest-filter=ifNoneMatchHits`: 2/2 pass, including the new
"honors weak comparison and the * form" block (weak match, weak-in-list match,
`*`, anchored-prefix negative, quoted-content negative). Full `clanker gate`
green on the same tree.
## References

- Investigation: none; source-read finding on the conditional-GET path.
