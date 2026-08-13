# PRD — Smart commit

## Status

Draft. No source files yet. New WASM tool at `tools/zig/smart_commit.zig` with
manifest `tools/manifests/smart_commit.tool.json`. CLI subcommand `clanker
commit` in `src/cli.zig`. All logic lives in the guest; no host module.

## Problem

`git commit` on a working tree with unrelated changes produces a catch-all commit
that conflates unrelated concerns. The developer (or agent) must manually decide
which hunks belong together, stage them with `git add -p`, and write one commit
per group. This is tedious for humans and error-prone for the agent, which today
uses the `git` tool to stage files coarsely and typically produces one commit per
session regardless of how many logical changes are present.

omp's `omp commit` reads the working tree, groups unrelated hunks into atomic
commits, orders them by dependency, and places source files above tests, docs,
and config files. The model does the grouping; deterministic code enforces
ordering. On this Zig codebase, dense `@import` graphs make a full-graph cycle
the common case, so a single-commit fallback with a clear `note` is the expected
primary path when the heuristic collapses, not a rare error.

## Goals

1. A `smart_commit` WASM tool that reads the full working tree diff (staged and
   unstaged, excluding lock files) and calls `ck_llm` to group hunks into atomic
   logical changes.
2. The LLM grouping returns an ordered list of proposed commits, each with a list
   of file paths and a conventional commit message.
3. The guest builds a dependency graph from the groupings (group A depends on
   group B if A's files import or reference B's files, determined by a simple
   static grep) and performs a topological sort. A partial cycle (some groups
   remain orderable) is rejected with an error naming the cycle. A degenerate
   cycle that spans every group falls back to a single commit with a `note`
   naming the merged groups (expected primary path on dense-import Zig trees).
4. Source files are ordered before tests, docs, and config files within each
   topological level (same convention as omp's ordering heuristic).
5. Commit messages are validated against the 11 conventional commit types
   (`feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`,
   `chore`, `revert`). A message that does not start with a valid type prefix is
   rejected and the tool returns an error asking the model to revise.
6. Lock files (`*.lock`, `package-lock.json`, `yarn.lock`, `Cargo.lock`,
   `go.sum`, `zig.lock`) are excluded from grouping and not committed.
7. `clanker commit` is a CLI subcommand that calls the `smart_commit` tool
   non-interactively, prints the proposed commits, and asks for confirmation
   before executing.

## Non-goals

- Not a replacement for `git`. The tool calls `git add -p` equivalents via
  `ck_exec`; it does not implement a git library. All git operations are `git`
  subprocess calls.
- Not automatic merging of partial hunks. Grouping is at file granularity, not
  hunk granularity. If two unrelated changes are in the same file, they land in
  the same commit. Hunk-level splitting (partial staging) is future work.
- Not a push step. The tool commits locally. Pushing to a remote is a separate
  `git push` call the user or agent makes explicitly.
- Not enforcing commit message subject length or body wrapping. The 11-type
  validation is the only message gate. Style preferences beyond that are the
  caller's concern.
- Not interactive rebase. The tool creates new commits in order; it does not
  amend, squash, or reorder existing commits.

## Design

**Placement.** All logic lives in the WASM guest. Every step below needs only
what the guest already has: `ck_exec` for git, `ck_llm` for grouping, and
string matching over the diff text for dependency edges. Per PRD 0001's
convention of keeping a tool's logic on one side and saying which, this is a
fully-guest tool; there is no host module.

**`smart_commit` tool input schema.**

```json
{
  "dry_run": false,
  "max_commits": 10,
  "scope": "staged"
}
```

`scope` is `"staged"` (only staged changes, default) or `"all"` (staged +
unstaged tracked files). `dry_run = true` returns the proposed groupings without
executing any `git` commands. `max_commits` caps how many commits the LLM may
propose; excess groups are merged into the last one.

**Optional `commit.model`.** Grouping may use a provider/model distinct from the
main agent via an optional config key (e.g. `[commit] model =
"provider/model"` or a tool-level override). When unset, grouping uses the main
provider. Large diffs can be cheaper on a small model; quality-sensitive
repos can pin a stronger one.

**Step 1: diff collection.** The guest calls `ck_exec` with:

```
git diff --staged --unified=3 --name-status
git diff --staged --unified=3
```

(Repeated for unstaged if `scope = "all"`.) Lock files are filtered out by the
guest before sending the diff to the LLM.

**Step 2: LLM grouping.** The guest calls `ck_llm` with:

System:
```
You are grouping a git diff into atomic commits. Group files by logical concern.
Each group should be one coherent change. Reply with JSON only:
{"commits": [{"message": "<conventional commit message>", "files": ["path", ...]}]}
Use conventional commit types: feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert
```

User: the filtered diff text.

The LLM returns a JSON array of `{message, files}` objects. The guest parses
this and validates the message types before proceeding.

**Step 3: dependency graph.** The guest builds a directed graph where an edge
`A -> B` means "commit A depends on commit B" (B must come first). Edges are
added for:
- A file in group A has a `import`, `const`, `use`, `require`, `from`, or `#include`
  line referencing a file in group B (simple grep, not a full parser).
- A test file (path contains `test_`, `_test.`, `.test.`, `tests/`) is always
  placed after the non-test file it shares a basename with, if that file is in
  a different group.

**Step 4: topological sort and cycle handling.** Kahn's algorithm on the
dependency graph.

- **Partial cycle:** if some groups remain orderable but a cycle among a
  subset blocks the rest, the tool returns an error naming the cycle and
  makes no commits. The model must revise the grouping.
  ```
  {"ok": false, "error": "dependency cycle: group 0 (feat: add cache) -> group 2 (refactor: restructure module) -> group 0"}
  ```
- **Degenerate cycle (expected primary path on Zig):** when the graph
  collapses into one cyclic cluster spanning all groups (common here because
  `const x = @import("y.zig")` appears in nearly every source file, so the
  grep gives almost every pair of src groups an edge), repeatedly asking the
  model to revise cannot converge. The tool falls back to a **single commit**
  containing every group's files, with a `note` field naming the merged
  groups, instead of error-looping. This is the expected primary path for
  dense-import Zig trees in v1, not an exceptional failure.

A smarter boundary for edges (per-directory, or per-manifest for `tools/`) is
the likely v2 of the graph step.

**Step 5: source-before-tests ordering within levels.** Within each topological
level (nodes with the same depth), source files (`src/`, `lib/`, non-test files)
sort before test files, doc files (`*.md`, `docs/`), and config files
(`*.toml`, `*.json`, `*.yaml` at the repo root).

**Step 6: execution.** For each ordered group:
1. `git add -- <files>` (stage only the group's files).
2. `git commit -m "<message>"`.

If any `git commit` fails (pre-commit hook, empty staging area, etc.),
`smart_commit` stops and returns the error with the partial list of commits
already made. No rollback is attempted; the user is left with a partially
committed working tree.

**Conventional commit validation.** A valid message starts with one of the 11
types, optionally followed by a scope in parentheses and a colon:
`feat(parser): add hashline support`. The regex:
`^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]+\))?: .+`
A message that does not match causes the tool to return an error naming the
offending message and asking the model to revise. This happens before any git
operation.

**`clanker commit` CLI.** Calls `smart_commit` with `dry_run = true` first,
prints the proposed commits as a numbered list, then prompts:

```
Proposed 3 commits:
  1. feat: add hashline edit format
  2. test: add hashline unit tests
  3. docs: update README for hashline

Proceed? [y/N]
```

If confirmed, calls `smart_commit` with `dry_run = false`. In a terminal the
prompt is a plain stdin read; under a browser session the confirmation goes
through `serveConfirm` (`src/cli.zig`), the same path the `agent.confirm_writes`
config uses to confirm tool writes. When the degenerate single-commit fallback
fired, the printed proposal includes the `note` so the user sees why groups
were merged before confirming.

**Dependencies.**

- Hard: guest `ck_exec` / `ck_llm` surface (existing WASM host ABI); conventional
  commit validation is guest-local string work.
- Soft: [PRD 0010 (plugin manifest SDK)](0010-plugin-manifest-sdk.md) for
  packaging the new tool manifest; [PRD 0022](0022-out-of-tree-tools.md) only
  if the tool is installed out-of-tree rather than under `tools/manifests`.
- Existing: `src/cli.zig` (`serveConfirm`, subcommand registration),
  `tools/zig/` guest build pattern.

**Implementation.**

1. Scaffold `tools/zig/smart_commit.zig` + `tools/manifests/smart_commit.tool.json`
   (input schema: `dry_run`, `max_commits`, `scope`).
2. Diff collection + lock-file filter via `ck_exec`.
3. LLM grouping via `ck_llm`, optional `commit.model` resolution, conventional
   commit regex validation before any git write.
4. Dependency graph (grep heuristic) + Kahn topo sort; partial-cycle error;
   degenerate all-groups cycle → single-commit fallback with `note`.
5. Source-before-tests ordering within levels; execute `git add` / `git commit`
   per group; stop on first failure with partial list.
6. `clanker commit` CLI: dry-run print, confirm (`serveConfirm` when browser),
   then execute; surface fallback `note` in the proposal list.
7. Tests: lock-file filtering, conventional commit regex, topo sort, partial
   cycle error, degenerate-cycle single-commit fallback + `note`,
   source-before-tests, `max_commits` merge, pre-commit hook failure stop.

## Failure modes

| Condition | Behaviour |
|---|---|
| LLM returns malformed JSON | Tool returns the raw LLM output as an error; no commits made |
| LLM proposes a file not in the diff | That file is silently removed from the group; if the group becomes empty, it is dropped |
| Partial dependency cycle detected | Tool returns a cycle error naming the cycle; no commits made |
| Cycle spans all groups (degenerate graph) | Single-commit fallback: all files in one commit, `note` names the merged groups (expected primary path on dense-import Zig trees) |
| `git add` fails (e.g., a file was deleted since the diff was collected) | Tool stops and reports the error; lists which commits succeeded before the failure |
| Pre-commit hook fails | Tool stops and reports the hook's output; no rollback |
| `max_commits` exceeded | Groups beyond the cap are merged into the last group |
| Working tree has no changes | Tool returns `{"ok": true, "commits": [], "message": "nothing to commit"}` |
| Lock file in staged files | Removed from grouping silently; a `note` field lists the excluded files |

## Acceptance criteria

- [ ] `smart_commit` with `dry_run = true` returns a list of proposed commits
      without executing any git commands.
- [ ] Lock files (`*.lock`, `go.sum`) are excluded from the diff sent to the LLM
      and never appear in a commit group.
- [ ] A commit message not matching the conventional commit regex causes an error
      before any git operation; the error names the offending message.
- [ ] The dependency graph is built and topological sort produces a valid order;
      verify with a two-group test where group A imports a file from group B.
- [ ] A partial dependency cycle returns a clear error naming the cycle; no
      commits are made.
- [ ] A degenerate cycle spanning all groups falls back to a single commit with
      a `note` naming the merged groups; no error loop; dry-run and CLI proposal
      both surface the `note`.
- [ ] Source files appear before test files within the same topological level.
- [ ] `clanker commit` prints the proposed list, asks for confirmation, and
      executes only on `y`.
- [ ] A pre-commit hook failure is reported and the partial commit list is
      returned; subsequent groups are not attempted.
- [ ] `max_commits` cap merges excess groups into the last one.
- [ ] Optional `commit.model` is honored when set; unset uses the main provider.
- [ ] Unit tests cover: lock-file filtering, conventional commit regex, topological
      sort, partial cycle detection, degenerate-cycle fallback, source-before-tests
      ordering.

## Open questions / future work

- **Hunk-level splitting.** The current design groups at file granularity. Two
  unrelated changes in the same file land in the same commit. `git add -p`-style
  hunk selection would solve this but requires parsing the diff into hunks and
  staging them individually via `git apply --cached`. The complexity is
  significant; file-level grouping is the right starting point.
- **Smarter edge boundaries.** Per-directory or per-manifest edges would reduce
  how often the degenerate fallback fires. v2 of the graph step.
- **Amendment mode.** If the last commit needs an additional related change,
  `smart_commit` could detect that and offer `--amend` instead of a new commit.
  Risky (amend rewrites history); out of scope for v1.
- **Push gate.** After committing, a post-commit hook or an explicit `--push`
  flag could trigger `git push`. Deliberately excluded: mixing local history
  operations with remote operations in one command is error-prone.
- **Cycle resolution suggestions.** When a partial cycle is detected, the tool
  currently just names it. A follow-on improvement would suggest which group
  boundary to move to break the cycle (e.g., "move file X from group A to
  group B").
