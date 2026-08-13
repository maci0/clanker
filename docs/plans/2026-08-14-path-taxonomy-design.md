# Path taxonomy redesign

**Status:** Draft design (approved in chat: approach B, hard cutover, no sacred cows, role-grouped layout)

**Date:** 2026-08-14

**Goal:** Rename and regroup folders/files so roles are obvious, names are consistent, and the tree stays maintainable. Land as small hard-cutover batches with commit + push each time.

## Decisions locked

- Scope: full tree + semantic regrouping
- Philosophy: role-grouped layout (not surface-first mega-move)
- Cutover: hard cutover per batch (no shims)
- Sacred cows: none for clarity (still avoid renumbering PRDs and renaming `src/improve/` / root `evals/` in this pass)
- Public tool IDs may change (`cmd_*` prefix dropped; search tool near-anagrams renamed)

## Naming rules

1. Zig sources: `snake_case.zig` only. No smashed compounds (`ensuredir` → `ensure_dir`).
2. Top-level `src/` dirs stay single-token nouns when possible. Keep `improve/` (verb outlier) and root `evals/` this pass.
3. Guest sources stay under `tools/`; host tool infrastructure is `src/toolhost/` (today `src/tools/`).
4. Operator scripts live under `scripts/`, not the repo root.
5. Docs shelves: `docs/{prds,adrs,reviews,prompts,digests,assets,plans}/`. Review writeups are not loose `docs/WEBUI_*.md`.
6. Web UI app sources hoist to `tools/webui/`; plugins stay `tools/webui-plugins/`; vendored JS colocate under `tools/webui/vendor/` when practical.
7. AssemblyScript build output: `tools/ts/dist/` (not `tools/ts/dist/`).
8. Example manifests: `tools/examples/manifests/` (out of the live load path).
9. Tool identity: manifest stem == wasm stem == catalog name. Drop the `cmd_` prefix; internal harness guests keep `"internal": true`.
10. Do not renumber PRDs. ROADMAP may cite PRD ids; build order stays in `docs/prds/README.md`.

## Target tree (deltas only)

```
scripts/
  scripts/clanker-improve.sh
  scripts/clanker-merge-worktree.sh
  scripts/clanker-review.sh
  scripts/release-check.sh

docs/
  reviews/
    webui.md
    webui-plugins.md
  plans/
    2026-08-14-path-taxonomy-design.md
    …

tools/
  webui/                 # was tools/zig/webui/
  webui-plugins/         # unchanged home
  examples/manifests/    # was tools/examples/manifests/
  ts/dist/               # was tools/ts/dist/
  zig/                   # guest Zig; no nested webui app
  manifests/             # live *.tool.json only

src/
  toolhost/              # was src/tools/
  tui/repl.zig           # was repl_vaxis.zig
  tui/turn_stats.zig     # was stats.zig
  util/ensure_dir.zig    # + disk_cap, run_lock, file_lock, tool_out, raw_http
  llm/registry.zig       # was providers.zig (dir llm/providers/ unchanged)
```

## Rename tables

### Docs / scripts / examples

| From | To |
|------|----|
| `docs/WEBUI_REVIEW.md` | `docs/reviews/webui.md` |
| `docs/WEBUI_PLUGINS_REVIEW.md` | `docs/reviews/webui-plugins.md` |
| `clanker-improve.sh` | `scripts/clanker-improve.sh` |
| `clanker-merge-worktree.sh` | `scripts/clanker-merge-worktree.sh` |
| `clanker-review.sh` | `scripts/clanker-review.sh` |
| `release-check.sh` | `scripts/release-check.sh` |
| `tools/manifests/examples/` | `tools/examples/manifests/` |
| `tools/bin/` | `tools/ts/dist/` |
| `tools/py/opencv_tool.py` | `tools/py/opencv.py` (if present and unused as import id) |

### Web UI layout

| From | To |
|------|----|
| `tools/zig/webui/` | `tools/webui/` |
| `src/webui_vendor/` | `tools/webui/vendor/` (only if embed/build paths update cleanly; else keep and document) |

### Public tools (hard cutover)

| From (stem) | To (stem) | Notes |
|-------------|-----------|-------|
| `cmd_autolearn` | `autolearn` | keep `internal: true` |
| `cmd_graph` | `graph` | |
| `cmd_janitor` | `janitor` | |
| `cmd_plugins` | `plugins` | |
| `cmd_sessions` | `sessions` | |
| `cmd_status` | `status` | |
| `cmd_tools` | `tools` | watch collision with generic word "tools" in docs |
| `search_code` | `repo_search` | local project search |
| `code_search` | `sourcegraph_search` | public Sourcegraph |
| `compare_blind.zig` | `compare_logic.zig` | helper only, no tool.json |
| `alphaxiv_mcp.zig` | `alphaxiv_client.zig` | helper only |

If `tools` as a guest name is too ambiguous beside `tools/` the directory, prefer `tool_catalog` instead of bare `tools` during batch 5 and record the choice in the commit message.

### Host Zig

| From | To |
|------|----|
| `src/util/ensuredir.zig` | `src/util/ensure_dir.zig` |
| `src/util/diskcap.zig` | `src/util/disk_cap.zig` |
| `src/util/runlock.zig` | `src/util/run_lock.zig` |
| `src/util/filelock.zig` | `src/util/file_lock.zig` |
| `src/util/toolout.zig` | `src/util/tool_out.zig` |
| `src/util/rawhttp.zig` | `src/util/raw_http.zig` |
| `src/tui/repl_vaxis.zig` | `src/tui/repl.zig` |
| `src/tui/stats.zig` | `src/tui/turn_stats.zig` |
| `src/tools/` | `src/toolhost/` |
| `src/llm/providers.zig` | `src/llm/registry.zig` |
| `src/agent/autolearn.zig` | `src/agent/auto_learn.zig` |
| `src/research/autoresearch.zig` | `src/research/auto_research.zig` |
| `src/improve/inert.zig` | `src/improve/inert_check.zig` |
| `src/serve/` | keep (proxy surface landed; do not treat as drift) |

## Commit batches

1. **Docs shelf** — create `docs/reviews/`, move WEBUI reviews, fix links, optional ROADMAP PRD-id citations.
2. **Scripts home** — create `scripts/`, move root shell scripts, fix CI/docs references.
3. **Tools examples + AS dist** — move examples and `tools/ts/dist` → `tools/ts/dist`; update manifests/`wasm` fields and AS verify scripts; opencv path tidy.
4. **Web UI hoist** — `tools/zig/webui` → `tools/webui`; update embed/allow-list/build; vendor move only if clean.
5. **Guest catalog clarity** — drop `cmd_` stems; rename search tools; rewrite evals/skills/autolearn/docs refs; `zig build tools`.
6. **Util + TUI names** — snake_case util + `repl` + `turn_stats` + smashed auto_* host modules; update imports and `main.zig` test registry.
7. **Host role split** — `src/tools` → `src/toolhost`; `providers.zig` → `registry.zig`; AGENTS.md architecture pass. Leave `src/serve/` in place.

Each batch: hard cutover, `git mv` preferred, rewrite every reference, verify, commit, merge remote if needed, push. No AI attribution.

## Verification (per batch)

- `rg` / search for old path and old tool stem → zero hits (except changelog historical notes if intentionally kept).
- `zig build`
- `zig build test`
- When guests/webui/AS paths change: `zig build tools` (and AS verify when `tools/ts` outputs move)
- Spot-check `AGENTS.md`, `README.md`, touched PRDs/ADRs
- `git status` clean; `HEAD` == `origin/main` after push

## Out of scope (this design)

- Renumbering `docs/prds/0001–0026`
- Renaming `src/improve/` or root `evals/`
- Surface-first `surfaces/{tui,webui,cli}` layout
- Temporary shims / dual tool names
- Behavior changes unrelated to paths

## Success

Batches 1–7 on `origin/main`, naming rules above hold for touched paths, builds/tests green, no leftover intentional names from the rename tables.
