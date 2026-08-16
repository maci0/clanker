# Bug — clanker commit generates a generic 'chore: update working tree' message for a clearly scoped diff

## TL;DR

- **What failed:** On 2026-08-16 clanker commit proposed the message 'chore: update working tree' for a 4-file diff with one clear scope, instead of describing the change; the smart_commit guest's message generation fell back to its generic label despite a describable diff.
- **Impact:** Degraded commit history; no data loss. Unverified beyond the one observed occurrence.
- **Resolution:** Resolved on 2026-08-16. Raised the smart_commit ck_llm grant to 4096 (default 1024 truncated the grouping reply, completion_tokens hit exactly 1024) and made the guest's generic-commit fallback carry a note naming the cause; verified by re-running clanker commit --dry-run on the same staged diff and getting two descriptive conventional commits.

## Status

Resolved on 2026-08-16. Raised the smart_commit ck_llm grant to 4096 (default 1024 truncated the grouping reply, completion_tokens hit exactly 1024) and made the guest's generic-commit fallback carry a note naming the cause; verified by re-running clanker commit --dry-run on the same staged diff and getting two descriptive conventional commits.

## Symptom and impact

The commit history loses the description of the change: a reader of `git log` sees "chore: update working tree" where a conventional scoped message was derivable from the diff. Evidence is the operator's note of 2026-08-16 on the local task board (this record was filed from that note; the original run output was not retained). Unverified: whether the fallback was the guest's degenerate-cycle single-commit path or the message generation itself.

## Reproduction

Reproduced 2026-08-17: a staged 5-file diff (one src fix + its records) ran `clanker commit --dry-run` and got one commit titled "chore: update working tree". state/token_stats.jsonl for that call shows completion_tokens exactly 1024 — the ck_llm reply hit the default grant and was truncated mid-JSON, so parseGroups failed and groupViaLlm silently fell back to oneGroup with the generic message (tools/zig/smart_commit.zig:176-177 before the fix).

## Root cause

Two stacked defects:

1. The smart_commit descriptor granted no `config.max_tokens`, so `ck_llm` replies were capped at the host default of 1024 completion tokens (src/sandbox/host.zig, `max_tokens: u32 = 1024`). The grouping model (deepseek-v4-flash) spends well over 1024 completion tokens on a modest diff (2908 on the 5-file reproduction once uncapped), so the JSON reply was truncated and unparsable.
2. `groupViaLlm` swallowed both failure modes (`lib.llm` error and `parseGroups` error) into a silent `oneGroup(files, "chore: update working tree")`, so the output gave no hint that anything had failed.

## Resolution

- `tools/manifests/smart_commit.tool.json`: added `"config": {"max_tokens": 4096}`.
- `tools/zig/smart_commit.zig`: `groupViaLlm` now returns a `GroupPlan` carrying a note naming the fallback cause ("llm call failed" vs "llm reply held no usable grouping (possibly truncated by the max_tokens grant)"); the note lands in the tool's `note` output field, which `commit_logic.renderPlan` already prints on every surface.

## Verification

Same staged 5-file diff, `clanker commit --dry-run` after `zig build tools`: two conventional commits with descriptive scoped messages ("docs: add bug report for smart commit generic message", "fix: free resolved rg path in ckStdApi to avoid leak on symbol lookup"); token stats show completion_tokens 2908 < 4096. `clanker plugins validate`: 118 manifests, 0 errors. `zig fmt --check` clean on the guest.

## Follow-up

A very large diff could still exceed 4096 completion tokens; the fallback note now names the grant when that happens, so the operator sees the cause instead of a bare generic commit.

## References

- Investigation: none yet
