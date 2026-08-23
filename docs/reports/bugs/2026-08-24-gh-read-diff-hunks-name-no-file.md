# Bug — A gh_read PR diff is a run of hunks that names no file

## TL;DR

- **What failed:** `gh://pr/o/r/n/diff` concatenated the `patch` field of every file the API returned. GitHub's `patch` starts at the first `@@` hunk and names no file anywhere, so the output was a run of hunks with nothing to attribute them to as soon as a PR touched more than one file. PRD 0019's own output shape documents `--- a/<file>` / `+++ b/<file>` above the hunks and calls the result "unchanged from the API response"; both halves of that sentence could not be true at once.
- **Impact:** A model reading a multi-file PR diff sees changes it cannot place in a file. On PR #379 (19 files) that is 19 patches run together with 18 unmarked boundaries. Files the API returns with no `patch` at all -- binary, or over GitHub's per-file diff limit -- were skipped silently, so a PR that only added an image read as an empty diff.
- **Resolution:** Resolved on 2026-08-24. `tools/zig/gh_format.zig` writes the `--- a/` / `+++ b/` pair per file and emits `[no patch: <status>]` for a file the API gives no patch for. A `gh://pr/.../diff/<path>` that matches nothing now says so instead of returning an empty success.

## Status

Resolved on 2026-08-24.

## Symptom and impact

`gh_read {"url":"gh://pr/maci0/clanker/379/diff"}` returned 84 KB of text whose
first line was `@@ -43,7 +43,7 @@ Write failing test first, ...`. Nothing in the
whole response named `AGENTS.md`, the file that hunk belongs to, and nothing
marked where its patch ended and `docs/prds/0006-webui.md`'s began.

Two smaller cases sat behind the same formatter:

- A file the API returns with no `patch` was skipped by `if (patch.len == 0)
  continue;`, so a binary file or one over GitHub's diff limit was absent from
  the output rather than reported as unshowable.
- `gh://pr/o/r/n/diff/<path>` with a path not in the PR filtered every entry out
  and returned `{"ok":true,"text":""}`. An empty success reads as "that file has
  no changes in this PR", which is a different fact from "that path is not in
  this PR" and leads to a different next step.

## Reproduction

Deterministic, needs only a token. The API side, with no clanker in the loop:

```bash
curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
  https://api.github.com/repos/maci0/clanker/pulls/379/files \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(repr(d[0]['patch'][:40]))"
```

prints `'@@ -43,7 +43,7 @@ Write failing test fir'` -- no `---`, no `+++`, no
filename. `formatFiles` in `tools/zig/gh_read.zig` appended exactly that, so the
guest's output inherited the omission.

## Root cause

One wrong assumption about the REST response, recorded in the PRD as fact: that
`patch` is a complete unified diff for the file. It is only the hunks. GitHub
puts the filename in the sibling `filename` field, which the formatter read
solely to filter on, never to print.

## Resolution

Formatting moved out of the wasm-only guest into `tools/zig/gh_format.zig`, a
host-tested helper, so the shapes the API returns can be pinned without a
network. `files()` writes the header pair from `filename` before each patch,
reports a patch-less entry with its `status`, and says `no file named '<path>'
in this pull request` when a subpath filter matches nothing.

## Verification

- Host test "every hunk in a multi-file diff names its file" pins the exact
  output for a two-file response, plus one test each for the patch-less and
  unmatched-path cases (`tools/zig/gh_format.zig`).
- Live, against the real API: `clanker run` with `gh://pr/maci0/clanker/379/diff`
  now returns output beginning

  ```
  --- a/AGENTS.md
  +++ b/AGENTS.md
  @@ -43,7 +43,7 @@ Write failing test first, ...
  ```

  which is the line the defect was measured on.

## Follow-up

- Pagination past the first page is still unbuilt; a PR over 100 files gets a
  truncation note rather than the rest of the diff. Tracked in PRD 0019's Known
  issues.

## References

- Investigation: none. The API response shape settled it in one call.
- [PRD 0019](../../prds/0019-github-fs.md) — the output shape this contradicted.
- `tools/zig/gh_format.zig`, `tools/zig/gh_read.zig`.
