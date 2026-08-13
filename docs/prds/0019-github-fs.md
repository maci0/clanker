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
with TTLs and ETag revalidation, stable structured output shapes, and
availability in sandboxes where exec or the gh binary is absent. The feature is
the cache plus a uniform read path on `gh_read`; plain GitHub access already
exists via `gh`.

## Goals

1. A dedicated `gh_read` tool recognizes the `gh://` and `github://` URL schemes
   and routes them through the GitHub API (via `ck_http` with `GITHUB_TOKEN`).
   `read_file` is unchanged and remains network-free.
2. Supported resource types in the first version:
   - `gh://issue/<owner>/<repo>/<number>` : issue title, body, state, labels,
     comments (paginated, up to `gh.max_comments`, default 50).
   - `gh://pr/<owner>/<repo>/<number>` : PR title, body, state, head/base,
     mergeable status, review summary.
   - `gh://pr/<owner>/<repo>/<number>/diff` : unified diff of the entire PR.
   - `gh://pr/<owner>/<repo>/<number>/diff/<path>` : diff of a single file in
     the PR.
   - `gh://issue/<owner>/<repo>?state=open&label=bug` : list of matching issues
     (up to `gh.max_list`, default 30), one per line: `#<number> <state>
     <title>`.
3. Responses are cached in `state/gh_cache.db` via `ck_exec sqlite3` in v1, with
   a soft TTL (return cached + trigger background refresh) and a hard TTL
   (return error, force re-fetch).
4. `GITHUB_TOKEN` is read through an allowlisted env path (existing
   allowlisted `ck_env` / harness pattern), not a general `ck_env_get` that can
   read arbitrary variables. If absent, `gh_read` returns a clear error.
5. A `gh.cache_ttl_soft_s` (default 300) and `gh.cache_ttl_hard_s` (default
   3600) config knob. After the soft TTL, the cached value is returned
   immediately and a background `ck_http` refresh is queued. After the hard TTL,
   the cache entry is considered stale and the call blocks on a fresh fetch.

## Non-goals

- Not a write interface. `gh://` URLs are read-only. Creating issues, posting
  comments, and merging PRs are out of scope for this PRD (future / separate
  work). They are **not** PRD 0021: that PRD covers git commit creation, not
  GitHub write APIs.
- Not extending `read_file` with network. `network_allow` for GitHub lives only
  on `gh_read`'s manifest so `read_file` stays network-free.
- Not a general `ck_env_get` host function. Token access uses the allowlisted
  `ck_env` / harness path already established for sensitive env vars.
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
- Not a native Zig SQLite binding in v1. Cache I/O goes through `ck_exec
  sqlite3`; a native binding is future optimization.

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

**Cache (decided: `ck_exec sqlite3`).** Schema:

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

The cache database is created on first use via `ck_exec sqlite3
state/gh_cache.db`. Native Zig SQLite remains a later optimization if spawn cost
shows up in profiles.

**GitHub token (decided: allowlisted env, no general `ck_env_get`).** Read
`GITHUB_TOKEN` through the existing allowlisted `ck_env` / harness mechanism
(only named, approved keys). If empty, return:
`{"ok": false, "error": "GITHUB_TOKEN not set"}`. Do not add a general-purpose
env-read host function for this feature.

**Rate limit handling.** On a 403 or 429 response from GitHub, check the
`X-RateLimit-Remaining` header. If 0, return an error with the reset time from
`X-RateLimit-Reset`. No automatic retry; let the model decide.

**Manifest.** `gh_read.tool.json` carries `"network_allow":
["api.github.com"]`. `read_file`'s manifest is untouched.

**Dependencies.**

- New `gh_read` WASM tool + manifest (network grant isolated here).
- Existing `ck_http` for GitHub REST calls.
- Allowlisted `ck_env` / harness for `GITHUB_TOKEN` (no new general env ABI).
- `ck_exec` with `sqlite3` on PATH for `state/gh_cache.db` in v1.
- Coexists with the existing `gh` CLI tool; does not replace write-capable gh
  flows.
- Explicit non-dependency: PRD 0021 (smart commit) is git commit UX, not GitHub
  writes.

**Implementation.**

1. **`gh_read` tool skeleton**: URL parse, resource dispatch table, structured
   text formatters; leave `read_file` alone.
2. **Auth**: allowlisted env read for `GITHUB_TOKEN`; clear error if missing.
3. **`ck_http` mapping** for the five resource shapes; rate-limit error path.
4. **Cache module** (`src/gh/cache.zig`): soft/hard TTL + ETag refresh via
   `ck_exec sqlite3`.
5. **Manifest**: `network_allow: ["api.github.com"]` on `gh_read` only.
6. **Tests**: URL parsing, endpoint mapping, output format, TTL logic, token
   missing, 429 handling.
7. **Deferred:** GraphQL endpoint; GitHub writes (separate future PRD, not
   0021); Enterprise `api_base_url`; native SQLite binding.

## Failure modes

| Condition | Behaviour |
|---|---|
| `GITHUB_TOKEN` not set | `{"ok": false, "error": "GITHUB_TOKEN not set; export it or set gh.token in config"}` |
| Non-existent issue or PR (404) | `{"ok": false, "error": "not found: gh://issue/<owner>/<repo>/999"}` |
| Rate limit exhausted | `{"ok": false, "error": "GitHub rate limit exhausted; resets at <ISO8601>"}` |
| Cache database not writable / sqlite3 missing | `gh_read` calls succeed but without caching; a warning is logged once per session |
| Hard TTL expired and network unavailable | `{"ok": false, "error": "cache expired and GitHub unreachable: <http error>"}` |
| Diff for a PR with >300 files | Returns the first `gh.max_diff_files` (default 100) files' diffs and a note: `[truncated: 200 more files]` |

## Acceptance criteria

- [x] `gh_read` with `gh://issue/<owner>/<repo>/<number>` returns a structured
      plain-text issue summary including title, state, labels, and comments.
- [x] `gh_read` with `gh://pr/<owner>/<repo>/<number>/diff` returns the unified
      diff for the PR.
- [x] `gh_read` with `gh://issue/<owner>/<repo>?state=open&label=bug` returns
      a list of matching issues (one per line).
- [x] A second call to the same URL within 300s returns the cached file
      under `state/gh_cache/` (sqlite/ETag refresh still open).
- [x] A call after the 300s TTL makes a fresh network request.
- [x] `GITHUB_TOKEN` absent produces a clear error, not a panic; token is read
      via allowlisted `env_allow`, not a general `ck_env_get`.
- [x] A 429-shaped body returns a rate-limit error, not a retry loop.
- [x] `read_file` remains network-free: no `network_allow`, no `gh://` dispatch.
- [x] Unit tests cover: URL parsing (valid and malformed forms) and API
      endpoint mapping.

## Open questions / future work

- **Native SQLite cache.** Replace `ck_exec sqlite3` with native Zig SQLite as
  a later optimization.
- **GraphQL.** A `gh://graphql` passthrough remains future work.
- **Write support.** Dedicated write tool or gh-pattern writes remain future
  work after reads are stable.
- **Enterprise GitHub.** `gh.api_base_url` and matching `network_allow` remain
  future work.
