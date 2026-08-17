# Bug — clanker commit --yes auto-applies the degraded fallback plan

## TL;DR

- **What failed:** When the grouping call fails or answers unusably, smart_commit falls back to one 'chore: update working tree' commit, and --yes wrote it with no human seeing the note. Hit live: a reasoning model spent the whole 8192-token grant, truncating the plan JSON. Fixed: the guest marks the fallback degraded, cmdCommit refuses --yes on it, grant raised to 16384.
- **Impact:** A staged multi-concern diff lands as one commit with a message that documents nothing; under agent-driven --yes runs, nobody reads the note that would have flagged it.
- **Resolution:** Resolved on 2026-08-17. Guest marks fallbacks degraded, cmdCommit refuses --yes on them (e2e case proves refusal + nothing written), grant 8192 to 16384; gate 8/8 in isolated worktree

## Status

Resolved on 2026-08-17. Guest marks fallbacks degraded, cmdCommit refuses --yes on them (e2e case proves refusal + nothing written), grant 8192 to 16384; gate 8/8 in isolated worktree

## Symptom and impact

`clanker commit --yes` on a 9-file staged diff (TUI slash-command preview work, 2026-08-17) printed the plan preview with the guest's own note — "llm reply held no usable grouping (possibly truncated by the max_tokens grant); fell back to one generic commit" — and then wrote that fallback anyway: one `chore: update working tree` commit spanning all nine files. The message was amended by hand afterward; nothing was lost, but only because the operator was watching.

## Reproduction

`tests/e2e/commit_apply_test.zig`, "clanker commit --yes refuses to auto-apply a degraded fallback plan": the mock LLM answers the grouping call with JSON cut off mid-string (what a reply truncated at the token ceiling looks like), and before the fix the verb committed the fallback plan and exited 0. In the live hit, `state/token_stats.jsonl` shows the grouping call ended with completion_tokens exactly 8192 — the descriptor grant — so the reply was truncated by the ceiling, and deepseek-v4-pro's reasoning trace counts against that same grant.

## Root cause

Two prior fixes made the fallback visible (a note in the reply) and stopped the plan from being recomputed between preview and write, but nothing distinguished "the model grouped this" from "the guest gave up": `groupViaLlm`'s two fallback paths returned a plan shaped exactly like a real one, and `cmdCommit` under `--yes` wrote whatever plan the preview produced. The 8192 grant (4096 content + 4096 reasoning headroom, sized 2026-08-17) is also simply reachable by a reasoning model on a 12KB-capped diff.

## Resolution

`tools/zig/smart_commit.zig` marks both `groupViaLlm` fallbacks `degraded: true` in the reply (the degenerate-cycle merge is not degraded — its messages are still the model's). `cmdCommit` refuses `--yes` on a degraded plan: prints a line naming the cause and exits with `error.DegradedCommitPlan`, leaving the index staged; interactive confirmation still may apply it, note on screen. `tools/manifests/smart_commit.tool.json` grant 8192 → 16384.

## Verification

The e2e case fails on the unfixed build (fallback committed, exit 0) and passes fixed: exit nonzero, `refusing --yes` and `degraded` in stdout, git log unchanged, alpha.md still staged. Full `zig build e2e` exit 0 (27 tests); `clanker gate` 8/8 in an isolated worktree at 738d4d7f plus exactly these four files (the checkout's own unit gate was red at the time from an unrelated, uncommitted `src/util/atomic_write.zig` edit by a peer session).

## Follow-up

None open. If 16384 ever truncates again the refusal now makes it loud instead of silent.

## References

- Investigation: none yet
