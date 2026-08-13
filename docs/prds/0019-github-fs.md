# PRD — GitHub filesystem

## Status

Draft. No source files yet. Affects `tools/zig/read_file.zig` and its manifest
`tools/manifests/read_file.tool.json`. New cache module in `src/gh/cache.zig`.
Requires `GITHUB_TOKEN` in the environment.

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
caching.

### Why not just the gh tool

The gh tool remains the full-surface escape hatch (including writes, gated by
pattern). This PRD earns its place only on what gh does not give: a read cache
with TTLs and ETag revalidation, stable structured output shapes, and
availability in sandboxes where exec or the gh binary is absent. If review
finds those three insufficient to justify a parallel API client, the honest
narrowing is to scope this PRD down to the caching layer alone and keep gh as
the fetch mechanism. Either way, the feature is the cache plus a uniform read
path; plain GitHub access already exists.

## Goals

1. `read_file` recognizes the `gh://` and `github://` URL schemes and routes them
   through the GitHub API (via `ck_http` with `GITHUB_TOKEN`).
2. Supported resource types in the first version:
   - `gh://issue/<owner>/<repo>/<number>` — issue title, body, state, labels,
     comments (paginated, up to `gh.max_comments`, default 50).
   - `gh://pr/<owner>/<repo>/<number>` — PR title, body, state, head/base,
     mergeable status, review summary.
   - `gh://pr/<owner>/<repo>/<number>/diff` — unified diff of the entire PR.
   - `gh://pr/<owner>/<repo>/<number>/diff/<path>` — diff of a single file in
     the PR.
   - `gh://issue/<owner>/<repo>?state=open&label=bug` — list of matching issues
     (up to `gh.max_list`, default 30), one per line: `#<number> <state>
     <title>`.
3. Responses are cached in `state/gh_cache.db` (SQLite via `ck_exec sqlite3` or
   a native Zig SQLite binding) with a soft TTL (return cached + trigger
   background refresh) and a hard TTL (return error, force re-fetch).
4. `GITHUB_TOKEN` is read from the environment (same as the existing `ck_http`
   pattern for authenticated calls). If absent, `gh://` calls return a clear
   error.
5. A `gh.cache_ttl_soft_s` (default 300) and `gh.cache_ttl_hard_s` (default
   3600) config knob. After the soft TTL, the cached value is returned
   immediately and a background `ck_http` refresh is queued. After the hard TTL,
   the cache entry is considered stale and the call blocks on a fresh fetch.

## Non-goals

- Not a write interface. `gh://` URLs are read-only. Creating issues, posting
  comments, and merging PRs belong to a separate write tool (or the existing
  `git` + `ck_http` combination). Commit creation and any GitHub write path is
  PRD 0021's territory; this PRD stays read-only.
- Not a full GitHub API client. Only the resource types listed in Goals are
  supported. GraphQL, Actions, releases, and repository metadata are out of scope.
- Not `git clone` or raw file access via the GitHub API (`GET /repos/.../
  contents/`). Local files are served by the existing `read_file` path. The `gh`
  scheme is for GitHub objects (issues, PRs), not source files.
- Not persistent background refresh. The soft-TTL background refresh fires once
  per soft-TTL expiry within the same clanker session. There is no daemon that
  keeps the cache warm between sessions.
- Not a GitHub App. Authentication is a personal access token or a fine-grained
  token in `GITHUB_TOKEN`.

## Design

**URL scheme dispatch.** `read_file`'s WASM guest inspects the `path` argument
for a `gh://` or `github://` prefix before any filesystem access. If matched, it
parses the URL into `{resource_type, owner, repo, number, subpath, query}` and
calls `ck_http` to reach the GitHub API.

**URL parsing.** A pure-Zig URL parser in the guest handles the small subset of
GitHub URL shapes. Malformed URLs (missing `owner`, non-numeric `number`) return
a parse error before any network call.

**API mapping.**

| URL | GitHub API endpoint |
|---|---|
| `gh://issue/<o>/<r>/<n>` | `GET /repos/{o}/{r}/issues/{n}` + `GET /repos/{o}/{r}/issues/{n}/comments` |
| `gh://pr/<o>/<r>/<n>` | `GET /repos/{o}/{r}/pulls/{n}` |
| `gh://pr/<o>/<r>/<n>/diff` | `GET /repos/{o}/{r}/pulls/{n}/files` (all files) |
| `gh://pr/<o>/<r>/<n>/diff/<path>` | `GET /repos/{o}/{r}/pulls/{n}/files`, filtered to `<path>` |
| `gh://issue/<o>/<r>?...` | `GET /repos/{o}/{r}/issues?state=...&labels=...` |

All calls use `Accept: application/vnd.github+json` and `Authorization: Bearer
<GITHUB_TOKEN>`.

**Output format.** Structured plain text, not raw JSON, to minimize output
tokens:

For an issue:
```
Issue #42: Fix the widget (open)
Labels: bug, priority:high
Created: 2026-01-15  Updated: 2026-08-10

Alice: We need to address the widget behavior when...
--- comment by Bob (2026-01-16) ---
Agreed. The root cause is in src/widget.zig line 88.
```

For a PR diff file:
```
--- a/src/widget.zig
+++ b/src/widget.zig
@@ -85,7 +85,9 @@
...
```
(Raw unified diff, unchanged from the API response.)

**Cache (SQLite).** Schema:

```sql
CREATE TABLE gh_cache (
  url     TEXT PRIMARY KEY,
  body    BLOB NOT NULL,
  fetched INTEGER NOT NULL,  -- Unix seconds
  etag    TEXT               -- GitHub ETag for conditional fetch
);
```

On a soft-TTL hit: return `body`, trigger a background `ck_http` GET with
`If-None-Match: <etag>`. On a 304 response, update `fetched`; on a 200, update
both. On a hard-TTL hit: fetch synchronously (block the tool call).

The cache database is created on first use. `ck_exec sqlite3 state/gh_cache.db`
or a native binding (prefer native if Zig's sqlite3 bindings are available as a
build dep without adding a new library; otherwise `ck_exec`).

**GitHub token.** `ck_http` already supports `Authorization` headers. The guest
reads `GITHUB_TOKEN` via a new `ck_env_get` host function (minimal: reads one
named environment variable, returns empty string if absent, added alongside this
feature). If empty, return: `{"ok": false, "error": "GITHUB_TOKEN not set"}`.

**Rate limit handling.** On a 403 or 429 response from GitHub, check the
`X-RateLimit-Remaining` header. If 0, return an error with the reset time from
`X-RateLimit-Reset`. No automatic retry; let the model decide.

**Manifest.** `read_file`'s manifest gains `"network_allow": ["api.github.com"]`
for `gh://` calls. Local filesystem access is unchanged; the existing `fs_prefixes`
remain in effect for non-gh paths.

That one manifest line deserves more weight than one sentence. `read_file` is
the single most-called tool in the system and today has no network surface at
all; adding `network_allow` makes every invocation of it a potential network
actor from the sandbox's point of view, and any future bug in the URL-scheme
dispatch becomes an exfiltration path from the most-trusted tool. The grant
must be its own decision: a separate manifest change, flagged explicitly in
review, not a rider on the feature commit. If reviewers reject it, the
fallback is a dedicated `gh_read` tool carrying the same URL scheme and its
own manifest, leaving `read_file` network-free.

## Failure modes

| Condition | Behaviour |
|---|---|
| `GITHUB_TOKEN` not set | `{"ok": false, "error": "GITHUB_TOKEN not set; export it or set gh.token in config"}` |
| Non-existent issue or PR (404) | `{"ok": false, "error": "not found: gh://issue/<owner>/<repo>/999"}` |
| Rate limit exhausted | `{"ok": false, "error": "GitHub rate limit exhausted; resets at <ISO8601>"}` |
| Cache database not writable | `gh://` calls succeed but without caching; a warning is logged once per session |
| Hard TTL expired and network unavailable | `{"ok": false, "error": "cache expired and GitHub unreachable: <http error>"}` |
| Diff for a PR with >300 files | Returns the first `gh.max_diff_files` (default 100) files' diffs and a note: `[truncated: 200 more files]` |

## Acceptance criteria

- [ ] `read_file` with `gh://issue/<owner>/<repo>/<number>` returns a structured
      plain-text issue summary including title, state, labels, and comments.
- [ ] `read_file` with `gh://pr/<owner>/<repo>/<number>/diff` returns the unified
      diff for the PR.
- [ ] `read_file` with `gh://issue/<owner>/<repo>?state=open&label=bug` returns
      a list of matching issues (one per line).
- [ ] A second call to the same URL within `gh.cache_ttl_soft_s` returns the
      cached response without a network call (verify via a test that counts
      `ck_http` invocations).
- [ ] A call after `gh.cache_ttl_hard_s` makes a fresh network request.
- [ ] `GITHUB_TOKEN` absent produces a clear error, not a panic.
- [ ] A 429 rate-limit response returns an error with the reset time, not a retry
      loop.
- [ ] Non-gh paths (`read_file` with a local path) are unaffected.
- [ ] Unit tests cover: URL parsing (valid and malformed forms), API endpoint
      mapping, output formatting, cache TTL logic.

## Open questions / future work

- **`ck_env_get` design.** This PRD introduces a new host function for reading
  environment variables. Whether to expose this generally (any env var by name)
  or restrict it to a config allowlist (`gh.allowed_env = ["GITHUB_TOKEN"]`) is
  a security tradeoff worth resolving in an ADR before implementation.
- **GraphQL.** The REST API has pagination limits and missing fields for some
  resources. A `gh://graphql` endpoint that accepts a query string and returns
  the raw JSON would cover the gap, but adds GraphQL-specific complexity.
- **Write support.** `gh://issue/<o>/<r>?op=comment&body=...` or a dedicated
  `gh_write` tool for creating comments, labels, and reviews. Natural follow-on
  once reads are stable.
- **Enterprise GitHub.** `api.github.com` is the assumed endpoint.
  `gh.api_base_url = "https://github.example.com/api/v3"` would cover GitHub
  Enterprise users, but changes the `network_allow` manifest entry at deploy time.
- **SQLite binding vs. ck_exec.** Using `ck_exec sqlite3` for cache access adds
  a process spawn per read (or per cache miss). A native Zig SQLite binding
  (e.g., `nektro/zig-sqlite`) would eliminate this cost but adds a build
  dependency. The right call depends on whether zig-sqlite can be vendored cleanly
  without touching the existing `build.zig`.
