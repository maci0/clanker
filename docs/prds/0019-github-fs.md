# PRD — GitHub filesystem

## Status

Shipped. `gh_read` parses `gh://` / `github://`, calls `api.github.com`
with an allowlisted `GITHUB_TOKEN`, and caches responses under
`state/gh_cache/` for 300s. `read_file` is unchanged. sqlite/ETag
refresh is still open. Sources of truth: `tools/zig/gh_read.zig`,
`tools/zig/gh_url.zig`, `tools/manifests/gh_read.tool.json`.

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

For a PR diff file (the concatenated `patch` fields):
```
--- a/src/widget.zig
+++ b/src/widget.zig
@@ -85,7 +85,9 @@
...
```
(Raw unified diff, unchanged from the API response.)

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

**Rate limit handling.** On a response body containing `API rate limit exceeded`
or `"message":"You have exceeded a secondary rate limit`, return
`{"ok": false, "error": "GitHub rate limit exhausted"}`. No `X-RateLimit-*`
header parsing and no reset-time text; no automatic retry.

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
6. **Tests**: URL parsing (valid and malformed forms) in `gh_url.zig`. Token
   missing, rate-limit detection, endpoint mapping, and TTL logic have no
   dedicated unit tests yet.
7. **Deferred:** GraphQL endpoint; GitHub writes (separate future PRD, not
   0021); Enterprise `api_base_url`; sqlite/ETag/soft-hard-TTL cache (see Open
   questions).

## Failure modes

| Condition | Behaviour |
|---|---|
| `GITHUB_TOKEN` not set | `{"ok": false, "error": "GITHUB_TOKEN not set; export it or set gh.token in config"}` |
| Non-existent issue or PR (404) | `{"ok": false, "error": "not found: gh://issue/<owner>/<repo>/999"}` |
| Rate limit exceeded (body match) | `{"ok": false, "error": "GitHub rate limit exhausted"}` (no reset-time text) |
| Cache directory not writable | The call still returns the fetched result; caching is best-effort and the `fsMkdir`/`fsWrite` error is swallowed |
| Network failure on a stale (>300s) entry | `{"ok": false, "error": "<url>: <http error>"}` — the stale entry is not served |
| Diff for a PR with many files | The tool formats every `patch` the API returns, with no cap or truncation note (`gh.max_diff_files` is not shipped) |

## Acceptance criteria

- [x] `gh_read` with `gh://issue/<owner>/<repo>/<number>` returns a structured
      plain-text issue summary with title, state, labels, and body.
- [ ] The issue summary includes comments (paginated, `gh.max_comments`) — not
      shipped: the tool fetches only the issue object.
- [x] `gh_read` with `gh://pr/<owner>/<repo>/<number>/diff` returns the unified
      diff for the PR.
- [ ] `gh_read` with `gh://pr/<owner>/<repo>/<number>` includes a review summary
      (head/base, mergeable status) — not shipped.
- [x] `gh_read` with `gh://issue/<owner>/<repo>?state=open&label=bug` returns
      a list of matching issues (one per line).
- [ ] Issue lists and comments are capped by `gh.max_list` / `gh.max_comments` —
      not shipped: no such caps exist.
- [x] A second call to the same URL within 300s returns the cached `body` from
      `state/gh_cache/`.
- [x] A call after the 300s TTL makes a fresh network request.
- [ ] `gh.cache_ttl_soft_s` / `gh.cache_ttl_hard_s` config keys control
      soft/hard TTLs — not shipped: the TTL is a fixed 300s with no keys.
- [x] `GITHUB_TOKEN` absent produces a clear error, not a panic; token is read
      via `env_allow: ["GITHUB_TOKEN"]`.
- [x] A rate-limit-shaped body returns a rate-limit error, not a retry loop.
- [ ] The rate-limit error includes a reset time ("resets at <ISO8601>") — not
      shipped: the error is just "GitHub rate limit exhausted".
- [x] `read_file` remains network-free: no `network_allow`, no `gh://` dispatch.
- [x] Unit tests cover URL parsing (valid and malformed forms).
- [ ] Unit tests cover API endpoint mapping — not shipped: no `apiPath` test
      exists.

## Open questions / future work

- **sqlite / ETag / soft-hard TTL cache (not shipped).** The shipped cache is a
  `state/gh_cache/` directory of JSON files with a fixed 300s TTL. A sqlite
  `state/gh_cache.db` with ETag revalidation (`If-None-Match` / 304) and
  soft/hard TTLs via `gh.cache_ttl_soft_s` / `gh.cache_ttl_hard_s` is future
  work, not shipped.
- **GraphQL.** A `gh://graphql` passthrough remains future work.
- **Write support.** Dedicated write tool or gh-pattern writes remain future
  work after reads are stable.
- **Enterprise GitHub.** `gh.api_base_url` and matching `network_allow` remain
  future work.
