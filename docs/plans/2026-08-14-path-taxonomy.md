# Path Taxonomy Implementation Plan

> **For agentic workers:** Execute task-by-task. Prefer inline execution on `main` with commit + push after each batch. Hard cutover only (no shims). No AI attribution in commits.

**Goal:** Land the role-grouped path taxonomy from `docs/plans/2026-08-14-path-taxonomy-design.md` in seven hard-cutover batches.

**Architecture:** `git mv` first, rewrite every reference in the same commit, verify build/tests (and tools when guests move), push, merge remote if needed before the next batch.

**Tech Stack:** Zig 0.16 harness, WASM tools (`zig build tools`), optional AssemblyScript under `tools/ts/`, docs markdown.

**Spec:** `docs/plans/2026-08-14-path-taxonomy-design.md`

## Global Constraints

- Hard cutover per batch; no dual names / re-export shims
- No AI co-author / model names in git text
- Do not renumber PRDs; do not rename `src/improve/` or root `evals/` this pass
- Prefer `git mv` to preserve history
- After each batch: `HEAD` synced with `origin/main`
- Zig files stay `snake_case.zig`
- If `cmd_tools` → bare `tools` is ambiguous in docs/catalog, use `tool_catalog` and note it in the commit body

---

### Task 1: Docs shelf (`docs/reviews/`)

**Files:**
- Create: `docs/reviews/`
- Move: `docs/reviews/webui.md` → `docs/reviews/webui.md`
- Move: `docs/reviews/webui-plugins.md` → `docs/reviews/webui-plugins.md`
- Modify: every markdown/code comment referencing the old paths (`docs/ROADMAP.md`, `docs/prds/0006-webui.md`, `docs/prds/0012-surface-plugins.md`, `docs/prompts/delight-review.md`, design plan tables, etc.)
- Modify: `docs/README.md` if it indexes docs shelves

**Interfaces:**
- Consumes: design rename table (Docs / scripts / examples)
- Produces: stable `docs/reviews/*.md` paths for later batches

- [ ] **Step 1:** `mkdir -p docs/reviews && git mv docs/reviews/webui.md docs/reviews/webui.md && git mv docs/reviews/webui-plugins.md docs/reviews/webui-plugins.md`
- [ ] **Step 2:** Rewrite references (`rg WEBUI_REVIEW|WEBUI_PLUGINS_REVIEW`) to new paths; update relative links inside moved files
- [ ] **Step 3:** Verify `rg 'WEBUI_REVIEW|WEBUI_PLUGINS_REVIEW' --glob '!docs/plans/**'` is empty or only historical changelog if intentionally kept
- [ ] **Step 4:** Commit + push

```bash
git add -A
git commit -m "$(cat <<'EOF'
docs: move webui reviews under docs/reviews

group review writeups with the docs/reviews shelf the prompt
templates already expect.
EOF
)"
git push origin main
```

---

### Task 2: Scripts home

**Files:**
- Create: `scripts/`
- Move: `scripts/clanker-improve.sh`, `scripts/clanker-merge-worktree.sh`, `scripts/clanker-review.sh`, `release-check.sh` → `scripts/`
- Modify: `.github/workflows/*`, `README.md`, `AGENTS.md`, `RELEASES.md`, any docs citing root scripts

- [ ] **Step 1:** `mkdir -p scripts && git mv clanker-*.sh release-check.sh scripts/`
- [ ] **Step 2:** Update all references; fix any workflow `run:` paths
- [ ] **Step 3:** `rg 'clanker-improve\\.sh|release-check\\.sh' ` → only `scripts/` paths
- [ ] **Step 4:** Commit + push (`scripts: home operator shell scripts at scripts/`)

---

### Task 3: Tools examples + AS dist

**Files:**
- Move: `tools/examples/manifests/` → `tools/examples/manifests/`
- Move: `tools/ts/dist/` → `tools/ts/dist/`
- Modify: every `*.tool.json` `wasm` field pointing at `tools/ts/dist/`; `tools/ts/verify.sh`; build docs; `tools/py/opencv.py` → `tools/py/opencv.py` if safe

- [ ] **Step 1:** `git mv` examples and bin tree
- [ ] **Step 2:** Rewrite manifest wasm paths and verify script
- [ ] **Step 3:** Run `tools/ts/verify.sh` if node/bun available; else document skip and ensure path strings compile for consumers
- [ ] **Step 4:** Commit + push

---

### Task 4: Web UI hoist

**Files:**
- Move: `tools/zig/webui/` → `tools/webui/`
- Modify: embed/`@embedFile` paths, allow-lists, `src/cli.zig` source-tree tests walking webui, `AGENTS.md`, PRDs/ROADMAP mentioning `tools/zig/webui`
- Optional same batch: `src/webui_vendor/` → `tools/webui/vendor/` only if all consumers update cleanly; else leave and note in commit

- [ ] **Step 1:** `git mv tools/zig/webui tools/webui`
- [ ] **Step 2:** Rewrite references; `zig build` && `zig build tools` && `zig build test`
- [ ] **Step 3:** `rg 'tools/zig/webui'` → empty
- [ ] **Step 4:** Commit + push

---

### Task 5: Guest catalog clarity

**Files:**
- Rename each `tools/zig/cmd_*.zig` + matching `tools/manifests/cmd_*.tool.json` by dropping `cmd_`
- Rename `search_code` → `repo_search`, `code_search` → `sourcegraph_search` (zig + manifests + evals + skills + docs)
- Rename helpers: `compare_blind.zig` → `compare_logic.zig`, `alphaxiv_mcp.zig` → `alphaxiv_client.zig`
- If bare `tools` guest is too ambiguous, use `tool_catalog`

- [ ] **Step 1:** `git mv` stems; update `"name"` / `wasm` fields inside manifests
- [ ] **Step 2:** Rewrite evals, skills, autolearn, prompts, AGENTS references
- [ ] **Step 3:** `zig build tools` && `zig build test`
- [ ] **Step 4:** Commit + push

---

### Task 6: Util + TUI host names

**Files:**
- Rename smashed `src/util/*` per design table
- `src/tui/repl_vaxis.zig` → `repl.zig`
- `src/tui/stats.zig` → `turn_stats.zig`
- `src/agent/autolearn.zig` → `auto_learn.zig`
- `src/research/autoresearch.zig` → `auto_research.zig`
- `src/improve/inert.zig` → `inert_check.zig`
- Update `@import` sites, `src/main.zig` comptime test registry, `build.zig` module names (`rawhttp` → `raw_http` if present)

- [ ] **Step 1:** `git mv` files; update imports/module aliases
- [ ] **Step 2:** `zig build` && `zig build test`
- [ ] **Step 3:** Commit + push

---

### Task 7: Host role split

**Files:**
- Move: `src/tools/` → `src/toolhost/`
- Rename: `src/llm/providers.zig` → `src/llm/registry.zig` (keep `src/llm/providers/` directory)
- Modify: all imports, `AGENTS.md` architecture section, design/plan path citations as needed
- Keep `src/serve/`

- [ ] **Step 1:** `git mv` + import rewrites
- [ ] **Step 2:** `zig build` && `zig build test`
- [ ] **Step 3:** Final `rg` for old names from design tables
- [ ] **Step 4:** Commit + push; confirm `0 0` vs `origin/main`

---

## Done criteria

All seven batches on `origin/main`, verification green per batch, design rename tables satisfied (with any intentional deviation recorded in the batch commit body).
