# Bug — A hand-made git worktree loses config.local.toml and .env, so clanker verbs fall back to the committed default provider

## TL;DR

- **What failed:** git worktree add checks out tracked files only; config.local.toml (default_provider = deepseek) and .env (the key) are gitignored, so inside the worktree every verb resolves config.toml's moonshotai with no key and clanker commit degrades to the fallback plan --yes refuses. clanker's own worktrees link both files (src/improve/worktree.zig); nothing does it for the worktree the repo rules make an agent create by hand. Reproduced 2026-08-22 with clanker doctor.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-22. clanker worktree prepare|add links .env and config.local.toml from the main checkout into a hand-made worktree, over the same name list src/improve/worktree.zig uses for clanker's own; ADR 0048 records why Config.load was not given a fallback instead. Verified live: clanker doctor in a fresh git worktree add reported moonshotai before and deepseek after. Gate 11/11.

## Status

Resolved on 2026-08-22. clanker worktree prepare|add links .env and config.local.toml from the main checkout into a hand-made worktree, over the same name list src/improve/worktree.zig uses for clanker's own; ADR 0048 records why Config.load was not given a fallback instead. Verified live: clanker doctor in a fresh git worktree add reported moonshotai before and deepseek after. Gate 11/11.

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

Fixed by the first candidate: `clanker worktree prepare [<path>]` links `.env` and
`config.local.toml` from the main checkout into a hand-made worktree, and
`clanker worktree add <path> [<base>]` fetches `origin`, creates the worktree and
a branch named after its directory, then prepares it. The linking is
`prepareLinked` in `src/improve/worktree.zig`, over `local_config_names` — the
same list `linkSharedState` walks for the worktrees clanker makes for itself, so
the two paths cannot drift into linking different names. The worktree's `.git`
file is what names the main checkout (`mainCheckoutFromGitFile`); no subprocess
is involved.

The second candidate was rejected and the reasoning is [ADR 0048](../../adrs/0048-preparing-a-hand-made-worktree-is-an-explicit-verb-not-a.md).
Three facts against it: it fixes one of the three faces (nothing for `.env`,
nothing for `zig-out/tools`); it makes config resolution depend implicitly on git
state, the kind of heuristic ADR 0017 refuses by name; and it gives the host and
the `config` guest two different answers for the same file, since the guest's
whole-file dump reads `config.local.toml` relative to its own root.

The verb is native rather than a WASM guest for one reason that survives the
everything-is-a-plugin question: the guest ABI has no symlink call — `ck_fs_*`
reads, writes, copies, renames and deletes, nothing links — and adding one would
let any tool plant a link inside its own granted prefix and reach past it.

`[agent] worktree_link_local_config = false` refuses the link for a checkout
whose worktrees must not reach the main tree's credentials; `prepare` then
reports both names as `skipped`. It is read from the **main checkout's** config,
since the worktree cannot see `config.local.toml` yet.

`zig-out` is deliberately still not linked — a build writes into it, so a shared
one would clobber the binaries the main tree is running — so the ToolWasmMissing
face is reported and explained rather than fixed: `prepare` prints whether
`zig-out/tools` is built and the `zig build tools` line to fix it.

## Verification

Done, live, on 2026-08-22 against a worktree cut from `origin/main` at 0ea0c3c8.
`git worktree add --detach <tmp> HEAD`, then `clanker doctor` in it:

```
  [warn] config.local.toml          absent; defaults from config.toml only
  [ok  ] default_provider           moonshotai (from config.toml)
  [FAIL] moonshotai (default)       KIMI_API_KEY is not set
```

`clanker worktree prepare` there, then the same `clanker doctor`:

```
  [ok  ] config.local.toml
  [ok  ] default_provider           deepseek (from config.local.toml)
  [ok  ] deepseek (default)         DEEPSEEK_API_KEY
```

Unit tests in `src/improve/worktree.zig` pin the same journey without git: a
`Config.load` in the worktree directory answers `moonshotai` before
`prepareLinked` and `deepseek` after, with the `.git` file the only thing
naming the main checkout. Three more cover the flag being off, an existing
file being left alone, and a `.git` that names no worktree. Reverting only
the implementation fails the first on `expected .linked, found .skipped`.
`clanker gate` 11/11 PASS.

## Follow-up

- Every agent session that works in a hand-made worktree still has to run
`clanker worktree prepare` (or `clanker worktree add`) before the first
model-calling verb. The verb makes recovery one command; it does not make the
trap impossible, because nothing prepares a worktree on its own.

## References

- Investigation: none yet
- Decision: [ADR 0048 — Preparing a hand-made worktree is an explicit verb, not a config-load fallback](../../adrs/0048-preparing-a-hand-made-worktree-is-an-explicit-verb-not-a.md)
- Runbook: [A hand-made git worktree has no config.local.toml or .env](../../runbooks/hand-made-worktree-has-no-local-config.md)
