# Bug — gh_read lists and diffs are silently cut to GitHub's default page of 30

## TL;DR

- **What failed:** `gh_url.apiPath` built `/issues`, `/issues?<query>` and `/pulls/<n>/files` with no `per_page`. GitHub then answers with its default page of 30 items and puts the rest behind a `Link: rel="next"` response header, which `ck_http` does not hand to the guest. So a repository with 200 open issues listed 30 of them, a 40-file PR diff came back ten files short, and neither output carried anything to distinguish it from a complete one.
- **Impact:** A model that asks for a repository's issues and reasons about "all" of them is reasoning about an arbitrary 30. A diff missing files silently is worse: the change the model was asked to review may be entirely in the part that was dropped, and nothing in the response says a part was dropped.
- **Resolution:** Resolved on 2026-08-24. Every list endpoint now states `per_page=100`, GitHub's maximum, and a response holding a full page gets `[truncated: only the first page was fetched; more items exist]`. A `per_page` the caller wrote into the URL is kept, so it is also the escape hatch for a response too large to fetch.

## Status

Resolved on 2026-08-24.

## Symptom and impact

Verified against the live API rather than inferred from the docs:

```bash
curl -s -D h -H "Authorization: Bearer $GITHUB_TOKEN" \
  https://api.github.com/repos/ziglang/zig/issues | python3 -c "import json,sys;print(len(json.load(sys.stdin)))"
# 30
grep -i '^link:' h
# link: <https://api.github.com/repositories/40276274/issues?after=...&per_page=30&page=2>; rel="next"
```

Thirty items and a `rel="next"` the guest never sees. `formatList` printed the 30
and returned, so `{"ok":true}` with a 30-line body was the tool's answer for a
repository with hundreds of issues. The same default applies to
`/pulls/<n>/files`.

The truncation was invisible from inside the guest by construction: the count is
not obviously wrong, the JSON is not obviously partial, and the one signal GitHub
does send is a header on a channel the sandbox does not expose.

## Reproduction

The API check above, or `gh_read {"url":"gh://issue/ziglang/zig?state=open"}`
before the fix -- 30 lines, no note, for a repository that has far more.

## Root cause

Trusting an API default. `apiPath` stated no page size, so the size was whatever
GitHub picked, and the guest had no way to learn what it had picked or whether
there was more.

## Resolution

`gh_url.page_size = 100` is sent on `/pulls/<n>/files` and on the issue list.
Asking for the maximum does not make a response complete -- it makes truncation
*visible*, because a response holding exactly one full page is the only
next-page signal available without the `Link` header. `gh_format.issueList` and
`gh_format.files` append the truncation note on that condition.

A `per_page` already present in the caller's query is not overridden and not
duplicated: GitHub takes the last value of a repeated parameter, so appending
ours would have quietly replaced theirs.

**The trade-off, stated rather than hidden.** 100 items is more bytes than 30,
and `max_http_bytes` is 1 MiB, so a repository with long issue bodies can now
exceed the ceiling where it previously fit. Measured: 100 `ziglang/zig` issues
are 540 KB, so there is real headroom, but not unlimited. When it is exceeded the
guest reports `the response is larger than one call allows; retry with a smaller
page, e.g. <url>?per_page=20` -- a loud failure naming its own fix, which is a
better answer than a quietly short list. A guest-side retry at a smaller page
would remove the trade-off and is not built.

## Verification

- `tools/zig/gh_url.zig`: `apiPath` is now pinned for all five ref kinds
  (previously untested -- PRD 0019 carried "no `apiPath` test exists" as an
  unchecked criterion), including that a page size is always stated, that a
  caller's own `per_page` survives, and that a parameter merely *starting* with
  `per_page` is not mistaken for it.
- `tools/zig/gh_format.zig`: a full page of results carries the note and a short
  page does not, built from `gh_url.page_size` rather than a literal so the two
  cannot drift.
- Live: `gh://pr/maci0/clanker/379/diff` (19 files, under one page) returns all
  19 with no truncation note, confirming the note is conditional and not
  unconditional.

## Follow-up

- Actually following `rel="next"` is unbuilt. It needs either a header channel
  from `ck_http` or a `page=` parameter loop, and a per-call byte budget to stop
  it; PRD 0019 records it under Known issues.
- `gh.max_list` / `gh.max_comments` / `gh.max_diff_files` config keys are still
  not shipped. The page size is a constant, not configuration.

## References

- Investigation: none. Two curl calls against the live API settled both the
  default page size and the hidden `Link` header.
- [PRD 0019](../../prds/0019-github-fs.md) — the failure-mode row that said
  there was no cap, and the two unchecked criteria this closes one of.
- `tools/zig/gh_url.zig`, `tools/zig/gh_format.zig`.
