# Bug — A hand-made git worktree loses config.local.toml and .env, so clanker verbs fall back to the committed default provider

## TL;DR

- **What failed:** git worktree add checks out tracked files only; config.local.toml (default_provider = deepseek) and .env (the key) are gitignored, so inside the worktree every verb resolves config.toml's moonshotai with no key and clanker commit degrades to the fallback plan --yes refuses. clanker's own worktrees link both files (src/improve/worktree.zig); nothing does it for the worktree the repo rules make an agent create by hand. Reproduced 2026-08-22 with clanker doctor.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

`clanker commit --dry-run` inside a worktree made with `git worktree add` printed:

```
[ERROR] no credential for provider 'moonshotai': set KIMI_API_KEY, service_account_file, or gcloud ADC
[WARN] [llm] ✗ ck_llm … 0ms: MissingApiKey ()
would write 1 commit(s):
  chore: update working tree
note: llm call failed; fell back to one generic commit
```

The main checkout is configured for DeepSeek and works. The degraded plan is refused by `--yes` on purpose (see the 2026-08-17 `commit-yes-applies-a-degraded-fallback-plan` bug), so in a worktree `clanker commit` cannot write a commit at all, and the operator who reads the error is told to set a Kimi key they never chose. The same fallback hits every verb that calls a model from a hand-made worktree (`run`, `goal`, `research sweep`, `improve-self`), not only `commit`.

A second face of the same gap: the worktree has no `zig-out/` either, and a `clanker` binary run from it resolves `zig-out/tools/*.wasm` against the cwd, so every guest-backed verb (`clanker reports create` included) fails with `ToolWasmMissing` until `zig build tools` has run there.

## Reproduction

From a checkout whose `config.local.toml` sets `default_provider = "deepseek"` and whose `.env` holds `DEEPSEEK_API_KEY`:

```
git worktree add --detach /tmp/wt-probe origin/main
cd /tmp/wt-probe
clanker doctor
```

Output on 2026-08-22 (main at 3d409a98):

```
  [warn] config.local.toml          absent; defaults from config.toml only
  [ok  ] default_provider           moonshotai (from config.toml)
  [FAIL] moonshotai (default)       KIMI_API_KEY is not set
  [warn] deepseek                   DEEPSEEK_API_KEY is not set
```

`ls config.local.toml .env` in the worktree: both absent.

## Root cause

`config.toml` is committed and carries `default_provider = "moonshotai"`; the operator's choice lives in `config.local.toml` and the key in `.env`, and `.gitignore` lists both (lines 28 and 52). `git worktree add` checks out tracked files only, so a hand-made worktree has neither, and `Config.load` (`config.toml` then `config.local.toml`) sees only the committed defaults. clanker's own worktrees do not have this problem because `src/improve/worktree.zig` links `.env` and `config.local.toml` into every worktree it creates (the doc comment above that loop names exactly this gap: *they're gitignored, so `git worktree add` never populates them*). The worktree the repository rules require an agent to create by hand (`.agents/agent-rules/repo-rules-merge-workflow.md`) goes through no such step, and no clanker verb offers it.

## Resolution

Open. Recovery is the runbook `docs/runbooks/hand-made-worktree-has-no-local-config.md` (link the two files in by hand). Candidate fixes, not yet decided:

- a verb that prepares a hand-made worktree the way `worktree.zig` prepares clanker's own (link `.env`, `config.local.toml`, and the shared `state/` pieces), so the rule-mandated flow has a clanker verb;
- or `Config.load` falling back to the main checkout's `config.local.toml`/`.env` when the cwd is a linked worktree (`git rev-parse --git-common-dir` names the main checkout) — weigh against ADR 0017's symlink stance and the sandbox `fs_prefixes` that must keep both names.

## Verification

Pending a fix: `clanker doctor` inside a fresh `git worktree add` should report the same `default_provider` as the main checkout.

## Follow-up

- Until then, every agent session that works in a hand-made worktree must apply the runbook before the first model-calling verb, or `clanker commit` is unusable there.

## References

- Investigation: none yet
