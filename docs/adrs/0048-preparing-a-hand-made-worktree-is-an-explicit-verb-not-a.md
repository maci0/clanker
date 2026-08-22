# ADR 0048 — Preparing a hand-made worktree is an explicit verb, not a config-load fallback

## Status

Accepted — 2026-08-22.

Accepted / Superseded by ADR-NNNN / Deprecated. One decision per ADR; if a
later decision reverses this one, mark this file Superseded and link
forward rather than editing history out of it.

## Context

`git worktree add` checks out tracked files only. `.env` and `config.local.toml` are gitignored, so a worktree made by hand has neither and `Config.load` there sees only the committed `config.toml` — whose `default_provider` is moonshotai, which nobody has a key for. Every model-calling verb fails inside such a worktree, and `clanker commit` in particular degrades to the one-commit fallback plan that `--yes` refuses. clanker's own worktrees never had this problem: `linkSharedState` in src/improve/worktree.zig links both files into each one. The worktree the repository rules require of every agent session went through no such step (docs/reports/bugs/2026-08-22-hand-made-worktree-falls-back-to-committed-provider.md). The report named two candidate fixes: a verb that prepares a hand-made worktree the way worktree.zig prepares clanker's own, or Config.load falling back to the main checkout's files when the cwd is a linked worktree.

The situation that forced a choice: the constraint, the competing option(s)
seriously considered, and why the status quo (or the obvious alternative)
didn't work. A reader five years from now should be able to tell whether
the constraint still holds without reading the whole codebase.

## Decision

A hand-made worktree is prepared by an explicit verb, `clanker worktree prepare|add`, over the same list of names `linkSharedState` uses. `Config.load` is unchanged: it never looks outside the directory it was given. Three facts decided it. (1) The fallback fixes one of the three faces of the defect — it does nothing for `.env`, which is loaded by dotenv and holds the key, and nothing at all for `zig-out/tools`, whose absence fails every guest-backed verb with ToolWasmMissing. (2) It would make config resolution depend implicitly on git state, the kind of heuristic ADR 0017 refuses by name ("nothing sets it implicitly — not a worktree run, not a first-run setup, not a heuristic about how state/ is laid out"). (3) It would give the host and the `config` guest two different answers for the same file: the guest's whole-file dump reads `config.local.toml` relative to its own root, so a host that had silently loaded another directory's copy would report config the guest cannot see. The verb is native rather than a WASM guest, against the everything-is-a-plugin rule, because the guest ABI has no symlink call — `ck_fs_*` reads, writes, copies, renames and deletes, nothing links — and adding one would let any tool plant a link inside its own granted prefix and reach past it, which is exactly the risk ADR 0017 keeps behind an opt-in flag. `[agent] worktree_link_local_config` (default true) lets an operator refuse the link; it is read from the main checkout's config, since the worktree cannot see `config.local.toml` yet.

The choice, stated plainly in one or two sentences. Not the implementation
detail — that lives in code and, if the decision is part of a larger
feature, in the relevant PRD (`docs/prds/`). Link it if so.

## Consequences

The repository rules' flow is one command (`clanker worktree add <path>`, which also fetches origin and branches from the remote tip) and the link policy lives in one file, so clanker's own worktrees and hand-made ones cannot drift into linking different names. The honest downsides: the fix is opt-in, so a worktree nobody prepares still falls back to the committed provider exactly as before — the verb makes recovery one command, it does not make the trap impossible. The links are leaf symlinks, and the sandbox's no-follow walk refuses a symlinked leaf, so the `config` guest's whole-file dump of `config.local.toml` fails inside a prepared worktree (the same consequence clanker's own worktrees already carry). `zig-out` is deliberately not linked because a build writes into it, so the ToolWasmMissing face is reported and explained rather than fixed: the operator still runs `zig build tools`. And this is a second worktree-creating path beside `run --worktree`, native code where the project's default is a guest.

What this makes easy, what it makes hard or forecloses, and what it costs
later if the context changes. Include the honest downside, not just the
justification — an ADR that only argues for the decision isn't useful when
someone is deciding whether to revisit it.
