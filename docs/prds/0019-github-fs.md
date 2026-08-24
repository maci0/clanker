# PRD — GitHub filesystem

## Status

Shipped. `gh_read` parses `gh://` / `github://`, calls `api.github.com`
with an allowlisted `GITHUB_TOKEN`, and caches responses under
`state/gh_cache/` for 300s. `read_file` is unchanged. sqlite/ETag
refresh is still open. Sources of truth: `tools/zig/gh_read.zig`,
`tools/zig/gh_url.zig`, `tools/zig/gh_format.zig`,
`tools/manifests/gh_read.tool.json`.

## Problem

GitHub reads already have a shipped path: the `gh` tool
(`tools/manifests/gh.tool.json`, `tools/zig/gh.zig`) runs the GitHub CLI
through the sandbox (`exec_allow: ["gh"]`, gated by `exec_pattern_allow`), and
`gh issue view`, `gh pr view`, `gh pr diff`, and `gh issue list` cover the
resource list this PRD targets, with gh handling auth, URL construction, and
pagination itself. The gaps this PRD addresses are narrower than "no GitHub
access":

1. Every gh invocation is uncached. Re-reading the same issue or PR diff in a
   long research task costs N CLI spawns, N API roundtrips, and N sets of
   output tokens.
2. gh requires the binary on the host and a matching `exec_pattern_allow`
   grant. Environments with no exec surface (or no gh installed) have no read
   path short of hand-rolling `ck_http` calls against `api.github.com`.
3. gh's output is formatted for humans and varies by subcommand and flags, so
   the model re-derives the structure on every call.

omp's github-fs addresses this by extending the `read` tool to accept URL
schemes: `issue://`, `pr://`, `pr://<owner>/<repo>/<number>/diff/<file>`. The
model uses the same tool for local files and GitHub resources, with transparent
caching. Clanker deliberately does **not** extend `read_file` that way: network
on the most-called tool is too wide a grant. This PRD uses a dedicated
`gh_read` tool instead.

### Why not just the gh tool

The gh tool remains the full-surface escape hatch (including writes, gated by
pattern). This PRD earns its place only on what gh does not give: a read cache
with a fixed 300s TTL, stable structured output shapes, and
availability in sandboxes where exec or the gh binary is absent. The feature is
the cache plus a uniform read path on `gh_read`; plain GitHub access already
exists via `gh`.

## Goals

1. A dedicated `gh_read` tool recognizes the `gh://` and `github://` URL schemes
   and routes them through the GitHub API (via `ck_http` with `GITHUB_TOKEN`).
   `read_file` is unchanged and remains network-free.
2. Supported resource types in the first version:
   - `gh://issue/<owner>/<repo>/<number>` : issue title, body, state, labels.
     *(Not shipped: comments pagination — the tool fetches only the issue
     object, not `/comments`, and there is no `gh.max_comments` cap.)*
   - `gh://pr/<owner>/<repo>/<number>` : PR title, body, state. *(Not shipped:
     head/base, mergeable status, review summary.)*
   - `gh://pr/<owner>/<repo>/<number>/diff` : unified diff of the entire PR
     (the `patch` field of every file returned by `/pulls/{n}/files`).
   - `gh://pr/<owner>/<repo>/<number>/diff/<path>` : diff of a single file in
     the PR.
   - `gh://issue/<owner>/<repo>?state=open&label=bug` : list of matching issues,
     one per line: `#<number> <state> <title>`. *(Not shipped: `gh.max_list`
     cap — the tool formats every item the API returns.)*
3. Responses are cached on disk in `state/gh_cache/` as `<hex>.json` files,
   where `<hex>` is the lowercase-hex Wyhash of the request URL. Each file
   holds `{"url", "fetched", "body"}` and is re-fetched when
   `now - fetched > 300` (a fixed 300s TTL). *(Not shipped: a sqlite
   `state/gh_cache.db`, a soft/hard TTL split, and ETag revalidation — see Open
   questions.)*
4. `GITHUB_TOKEN` is read through the allowlisted `env_allow: ["GITHUB_TOKEN"]`
   grant (`ck_getenv`), not a general env read that can reach arbitrary
   variables. If absent, `gh_read` returns a clear error.
5. *(Not shipped.)* A `gh.cache_ttl_soft_s` (default 300) and
   `gh.cache_ttl_hard_s` (default 3600) config knob with soft/hard TTL
   semantics. The shipped cache has a single fixed 300s TTL and no such config
   keys.

## Non-goals

- Not a write interface. `gh://` URLs are read-only. Creating issues, posting
  comments, and merging PRs are out of scope for this PRD (future / separate
  work). They are **not** PRD 0021: that PRD covers git commit creation, not
  GitHub write APIs.
- Not extending `read_file` with network. `network_allow` for GitHub lives only
  on `gh_read`'s manifest so `read_file` stays network-free.
- Not a general env-read host function. Token access uses `ck_getenv`, already
  allowlisted by the manifest's `env_allow: ["GITHUB_TOKEN"]` for sensitive env
  vars.
- Not a full GitHub API client. Only the resource types listed in Goals are
  supported. GraphQL, Actions, releases, and repository metadata are out of scope.
- Not `git clone` or raw file access via the GitHub API (`GET /repos/.../
  contents/`). Local files are served by the existing `read_file` path. The `gh`
  scheme is for GitHub objects (issues, PRs), not source files.
- Not persistent background refresh. There is no background refresh at all: a
  cache miss or a >300s-old entry re-fetches synchronously inside the `gh_read`
  call, and no daemon keeps the cache warm between sessions.
- Not a GitHub App. Authentication is a personal access token or a fine-grained
  token in `GITHUB_TOKEN`.
- Not sqlite-backed. The shipped cache is a plain directory of JSON files under
  `state/gh_cache/`; a sqlite `state/gh_cache.db` with ETag/soft-hard TTL is
  explicitly future work (see Open questions).

## Design

**Dedicated tool (decided).** `gh_read` owns URL-scheme dispatch and the
`network_allow: ["api.github.com"]` manifest grant. `read_file` never sees
`gh://` paths and never gains network.

**URL scheme dispatch.** The `gh_read` WASM guest parses the `path` (or
dedicated `url`) argument for a `gh://` or `github://` prefix, parses into
`{resource_type, owner, repo, number, subpath, query}`, and calls `ck_http` to
reach the GitHub API.

**URL parsing.** A pure-Zig URL parser in the guest handles the small subset of
GitHub URL shapes. Malformed URLs (missing `owner`, non-numeric `number`) return
a parse error before any network call.

**API mapping.**

| URL | GitHub API endpoint |
|---|---|
| `gh://issue/<o>/<r>/<n>` | `GET /repos/{o}/{r}/issues/{n}` (no `/comments` fetch) |
| `gh://pr/<o>/<r>/<n>` | `GET /repos/{o}/{r}/pulls/{n}` |
| `gh://pr/<o>/<r>/<n>/diff` | `GET /repos/{o}/{r}/pulls/{n}/files` (all files) |
| `gh://pr/<o>/<r>/<n>/diff/<path>` | `GET /repos/{o}/{r}/pulls/{n}/files`, filtered in-guest to `<path>` |
| `gh://issue/<o>/<r>?...` | `GET /repos/{o}/{r}/issues?<query>` |

All calls use `Authorization: Bearer <GITHUB_TOKEN>`, `Accept:
application/vnd.github+json`, and `User-Agent: clanker`.

**Output format.** Structured plain text, not raw JSON, to minimize output
tokens. Every success is wrapped in the standard `{"ok":true,"text":...}` reply.

For an issue:
```
Issue #42: Fix the widget (open)
Labels: bug, priority:high

<issue body>
```

For a PR:
```
PR #7: Fix the widget (open)

<PR body>
```

For an issue list, one line per item: `#<number> <state> <title>`.

For a PR diff file:
```
--- a/src/widget.zig
+++ b/src/widget.zig
@@ -85,7 +85,9 @@
...
```
The hunks are the API's `patch` field verbatim; the `--- a/` / `+++ b/` pair is
added by the guest. GitHub's `patch` starts at the first `@@` and names no file,
so concatenating patches straight from the response -- what shipped until
2026-08-23 -- gave a run of hunks that could not be attributed to any file the
moment a PR touched more than one. A file the API returns with no `patch` at all
(binary, or over GitHub's per-file diff limit) gets the header pair and a
`[no patch: <status>]` line rather than being dropped.

**Cache (shipped).** On a cache miss, `gh_read` fetches via `ck_http` and writes
the raw response body to `state/gh_cache/<hex>.json`, where `<hex>` is the
lowercase-hex Wyhash of the request URL. The JSON object is
`{"url", "fetched", "body"}` with `fetched` as Unix seconds. On a later call the
guest reads that file and returns the cached `body` while `now - fetched <= 300`;
after that it re-fetches and overwrites the file. There is no sqlite, no ETag,
and no soft/hard TTL split — the TTL is a fixed 300s. The sqlite/ETag/soft-hard
idea is future work (see Open questions).

**GitHub token (decided: allowlisted env).** Read `GITHUB_TOKEN` through
`ck_getenv`, allowlisted by the manifest's `env_allow: ["GITHUB_TOKEN"]`. If
empty, return:
`{"ok": false, "error": "GITHUB_TOKEN not set; export it or set gh.token in config"}`.
No new general-purpose env-read host function is added.

**Rate limit handling.** A 429, or a body containing `API rate limit exceeded`
or `secondary rate limit`, returns
`{"ok": false, "error": "GitHub rate limit exhausted"}`. No `X-RateLimit-*`
header parsing and no reset-time text; no automatic retry. A 403 that is *not*
rate-limit-shaped is reported as a permission answer instead, because a private
repository and an exhausted quota need different fixes.

**Reading a >= 400 answer at all.** `ck_http` reports every error status as
`error.NetworkError` -- the same error a DNS failure gives -- and used to free
the response body, so the two messages above were scans over bytes that had
already been dropped and neither could ever fire. `httpImpl`
(`src/sandbox/host.zig`) now parks `{"ck_http_status":<code>,"body":"..."}` (body
capped at 2 KiB) in the guest's result slot on the status path only; the return
code is unchanged, so no other guest sees a difference. `lib.httpLastFailure`
reads it and `gh_format.statusMessage` turns it into the message. Anything
without an envelope -- a timeout, a refused connection -- still falls back to the
generic transport error.

**Page size.** Every list endpoint is requested with `per_page=100`, GitHub's
maximum. Sending no `per_page` gets 30 items with the rest behind a
`Link: rel="next"` header the guest never sees, so a 40-file PR diff came back
ten files short and a busy repository listed 30 issues, both with nothing to
distinguish the result from a complete one. A response holding a full page was
the only truncation signal `ck_http` left, and it appends
`[truncated: only the first page was fetched; more items exist]`. A `per_page`
the caller wrote into the URL themselves is kept, which is also the way out of
the trade-off this makes: 100 long issue bodies can exceed `max_http_bytes`
(1 MiB) where 30 fit, and the tool then says so and names `?per_page=` rather
than silently returning less than was asked for.

**Manifest.** `gh_read.tool.json` carries `"network_allow": ["api.github.com"]`,
`"env_allow": ["GITHUB_TOKEN"]`, and `"fs_prefixes": ["state/gh_cache/"]`.
`read_file`'s manifest is untouched.

**Dependencies.**

- New `gh_read` WASM tool + manifest (network + env + cache grants isolated
  here).
- Existing `ck_http` for GitHub REST calls.
- `ck_getenv` for `GITHUB_TOKEN`, allowlisted by `env_allow` (no new general env
  ABI).
- The guest's sandboxed file I/O (`ck_fs_read` / `ck_fs_write` / `ck_fs_mkdir`)
  for `state/gh_cache/`, granted via `fs_prefixes`.
- Coexists with the existing `gh` CLI tool; does not replace write-capable gh
  flows.
- Explicit non-dependency: PRD 0021 (smart commit) is git commit UX, not GitHub
  writes.

**Implementation.**

1. **`gh_read` tool skeleton**: URL parse, resource dispatch table, structured
   text formatters; leave `read_file` alone.
2. **Auth**: allowlisted `ck_getenv` for `GITHUB_TOKEN`; clear error if missing.
3. **`ck_http` mapping** for the five resource shapes; rate-limit error path.
4. **Cache**: fixed-300s on-disk cache in `tools/zig/gh_read.zig`
   (`cacheGet` / `cachePut` writing `state/gh_cache/<hex>.json`).
5. **Manifest**: `network_allow: ["api.github.com"]`, `env_allow:
   ["GITHUB_TOKEN"]`, `fs_prefixes: ["state/gh_cache/"]` on `gh_read` only.
6. **Tests**: URL parsing and endpoint mapping in `gh_url.zig`; rendering and
   status classification in `gh_format.zig` (a host-tested helper, so the
   response shapes the API really returns are pinned without a network); the
   status envelope in `src/sandbox/host.zig`, against a loopback server that
   answers 404 with a body. Token-missing and TTL logic still have no dedicated
   unit tests.
7. **Deferred:** GraphQL endpoint; GitHub writes (separate future PRD, not
   0021); Enterprise `api_base_url`; sqlite/ETag/soft-hard-TTL cache (see Open
   questions).

## Known issues

- **(Fixed) A diff was a run of hunks with no file attached.** GitHub's `patch`
  field starts at the first `@@`, so concatenating patches produced output no
  reader could map back to a file once a PR touched more than one. The guest now
  writes the `--- a/` / `+++ b/` pair itself.
  Live-checked against `gh://pr/maci0/clanker/379/diff` (19 files).
- **(Fixed) Two documented failure modes could never fire.** `ck_http` collapsed
  every >= 400 answer into `error.NetworkError` and freed the body, so
  `looksLikeNotFound` and `looksLikeRateLimit` were scanning bytes that had
  already been dropped: a missing issue reported "the request did not complete",
  and a rate-limit refusal was indistinguishable from a DNS failure. The host
  now parks the status and a 2 KiB slice of the body in the guest's result slot
  on the status path, and the guest classifies from it.
  Live-checked: `gh://issue/maci0/clanker/999999` returns
  `not found: gh://issue/maci0/clanker/999999`.
- **(Fixed) Lists and diffs were silently cut at 30 items.** No `per_page` was
  sent, so GitHub answered with its default page and hid the rest behind a
  `Link` header `ck_http` does not expose. Requests now state `per_page=100` and
  a full page carries a truncation note.
- **(Fixed) The cache never checked which URL a record was for.** The record
  wrote a `url` field that nothing read, so a Wyhash filename collision served
  one URL's response for another.
- **A response over `max_http_bytes` (1 MiB) is a hard failure, not a partial
  answer.** Asking for 100 items instead of 30 makes this reachable for a
  repository with long issue bodies where it was not before. The failure is loud
  and names `?per_page=`, which is the deliberate trade: a stated page size that
  can be too big beats an unstated one that is quietly too small. A guest-side
  fallback that retried at a smaller page would remove the trade-off entirely
  and is not built.
- **Still not shipped, unchanged by the above:** issue comments (the tool
  fetches only the issue object), `gh.max_list` / `gh.max_comments` /
  `gh.max_diff_files` config keys, pagination past page one, GraphQL, writes,
  and Enterprise `api_base_url`.
- **The reset time now ships.** It was listed here as unreachable because
  `ck_http` handed the guest no response headers. That was a transport gap, not
  a missing feature, and it is closed: `ck_http_ex` carries an allowlisted set
  of response headers including `X-RateLimit-Reset` (RFC 0037, ADR 0049), and
  `gh_read` moved onto it. Two of the three things this PRD parked behind that
  gap -- pagination via `Link`, and `ETag` revalidation -- are now *buildable*
  and remain unbuilt; they are future work in the ordinary sense rather than
  blocked.

## Failure modes

| Condition | Behaviour |
|---|---|
| `GITHUB_TOKEN` not set | `{"ok": false, "error": "GITHUB_TOKEN not set; export it or set gh.token in config"}` |
| Non-existent issue or PR (404) | `{"ok": false, "error": "not found: gh://issue/<owner>/<repo>/999"}` |
| Rate limit exceeded (429, or a rate-limit body on a 403) | `{"ok": false, "error": "GitHub rate limit exhausted"}` (no reset-time text) |
| 401 (token invalid or expired) | `{"ok": false, "error": "GITHUB_TOKEN rejected by GitHub (401); the token is invalid or expired"}` |
| 403 that is not rate-limit-shaped | `forbidden: <url> (token lacks access, or SSO is not authorized)` |
| Any other >= 400 | `<url>: HTTP <code>[: <the API's own message>]` |
| Cache directory not writable | The call still returns the fetched result; caching is best-effort and the `fsMkdir`/`fsWrite` error is swallowed |
| Network failure on a stale (>300s) entry | `{"ok": false, "error": "<url>: <http error>"}` — the stale entry is not served |
| Diff for a PR with more than 100 files | The first 100 files are formatted and the output ends in `[truncated: only the first page was fetched; more items exist]`. There is still no `gh.max_diff_files` config key |
| A list or diff larger than `max_http_bytes` (1 MiB) | `<url>: the response is larger than one call allows; retry with a smaller page, e.g. <url>?per_page=20` |
| `gh://pr/o/r/n/diff/<path>` naming a file not in the PR | `no file named '<path>' in this pull request` -- not an empty success, which read as "this file has no changes" |
| A file in the diff the API returns with no `patch` | Header pair plus `[no patch: <status>]`; binary and over-limit files are named rather than dropped |
| Two URLs whose Wyhash cache filenames collide | The record's `url` field is compared before its `body` is served, so the second URL misses instead of being served the first one's response |

## Acceptance criteria

- [x] `gh_read` with `gh://issue/<owner>/<repo>/<number>` returns a structured
      plain-text issue summary with title, state, labels, and body.
- [ ] The issue summary includes comments (paginated, `gh.max_comments`) — not
      shipped: the tool fetches only the issue object.
- [x] `gh_read` with `gh://pr/<owner>/<repo>/<number>/diff` returns the unified
      diff for the PR.
- [x] `gh_read` with `gh://pr/<owner>/<repo>/<number>` includes a review summary:
      `head -> base`, `Mergeable: yes|no|unknown (<mergeable_state>)`, draft and
      merged flags, and `Files: N (+a -d)`. `mergeable` is null while GitHub
      computes it, and that reads `unknown` rather than `no`.
- [x] `gh_read` with `gh://issue/<owner>/<repo>?state=open&label=bug` returns
      a list of matching issues (one per line).
- [ ] Issue lists and comments are capped by `gh.max_list` / `gh.max_comments` —
      not shipped: no such config keys exist. What *is* shipped is a stated page
      size (`per_page=100`) and a truncation note when a full page comes back,
      so a short list is no longer indistinguishable from a complete one.
- [x] A second call to the same URL within 300s returns the cached `body` from
      `state/gh_cache/`.
- [x] A call after the 300s TTL makes a fresh network request.
- [ ] `gh.cache_ttl_soft_s` / `gh.cache_ttl_hard_s` config keys control
      soft/hard TTLs — not shipped: the TTL is a fixed 300s with no keys.
- [x] `GITHUB_TOKEN` absent produces a clear error, not a panic; token is read
      via `env_allow: ["GITHUB_TOKEN"]`.
- [x] A rate-limit-shaped body returns a rate-limit error, not a retry loop.
- [x] A >= 400 response is classified by its status, not guessed at: 404, 401,
      403-with-rate-limit, 403-without, and everything else each get their own
      message. Pinned in `gh_format.zig`, and in `src/sandbox/host.zig` by a
      loopback server that answers 404 with a body.
- [x] Every hunk in a multi-file PR diff names its file.
- [x] A list or diff that comes back holding a full page says so.
- [x] The rate-limit error includes a reset time ("resets at <ISO8601>").
      `X-RateLimit-Reset` was out of reach until `ck_http_ex` gave a guest a
      channel for a response header (ADR 0049); `gh_read` reads it and
      `gh_format.statusMessage` renders it as UTC ISO 8601. Pinned in
      `gh_format.zig`, including that an unparseable or absent header falls back
      to the bare message rather than inventing a date in 1970.
- [x] `read_file` remains network-free: no `network_allow`, no `gh://` dispatch.
- [x] Unit tests cover URL parsing (valid and malformed forms).
- [x] Unit tests cover API endpoint mapping: `apiPath` is pinned for all five
      ref kinds in `tools/zig/gh_url.zig`, including that a page size is always
      stated and never stated twice.

## Open questions / future work

- **sqlite / ETag / soft-hard TTL cache (not shipped).** The shipped cache is a
  `state/gh_cache/` directory of JSON files with a fixed 300s TTL. A sqlite
  `state/gh_cache.db` with ETag revalidation (`If-None-Match` / 304) and
  soft/hard TTLs via `gh.cache_ttl_soft_s` / `gh.cache_ttl_hard_s` is future
  work, not shipped. The `ETag` it needs is reachable since ADR 0049; before
  that this entry read as "not done yet" when it was really "the transport does
  not carry it".
- **GraphQL.** A `gh://graphql` passthrough remains future work.
- **Write support.** Dedicated write tool or gh-pattern writes remain future
  work after reads are stable.
- **Enterprise GitHub.** `gh.api_base_url` and matching `network_allow` remain
  future work.
