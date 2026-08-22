# Runbook — A hand-made git worktree has no config.local.toml or .env

## TL;DR

- **Use when:** a clanker verb run inside a worktree you made with `git worktree add` names a provider you never configured (`no credential for provider 'moonshotai'`), `clanker commit` falls back to `chore: update working tree`, or every guest-backed verb fails with `ToolWasmMissing`.
- **Recover by:** running `clanker worktree prepare` in the worktree, then `zig build tools` there. Only a clanker older than the verb needs the two symlinks made by hand.
- **Verify with:** `clanker doctor` in the worktree reporting the main checkout's `default_provider` with its key set.

## Scope and preconditions

A linked worktree of this repository created by hand (`git worktree add`), which is what `.agents/agent-rules/repo-rules-merge-workflow.md` requires of every agent session. Worktrees clanker creates itself (`improve-self`, `--worktree` runs) link these files already (`src/improve/worktree.zig`) and do not need this. The main checkout must hold a working `config.local.toml` and `.env`.

## Diagnose

Run the doctor from inside the worktree:

```bash
clanker doctor
```

The signature is `config.local.toml absent; defaults from config.toml only` together with a `[FAIL]` on the committed default provider (`moonshotai`) for a key you never set. A `ToolWasmMissing` error from any verb is the same gap on the build side: `zig-out/tools/` is resolved against the cwd and a fresh worktree has none.

## Recover

From inside the worktree:

```bash
clanker worktree prepare
```

It reads the worktree's `.git` file to find the main checkout, links both
gitignored files from there, and prints what it did to each — including
whether `zig-out/tools` is built. `clanker worktree add <path>` does the same
for a worktree it creates, fetching `origin` first.

On a clanker older than that verb, do it by hand — the same two links, the
main checkout named by the common git dir:

```bash
MAIN=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
ln -s "$MAIN/config.local.toml" config.local.toml
ln -s "$MAIN/.env" .env
```

Build the guests the verbs load, and the binary if you want to run the worktree's own code:

```bash
zig build tools
zig build
```

Symlinks match what `worktree.zig` does for clanker's own worktrees, and a *leaf* link is safe for these two: both are read by the host, and `atomic_write.writeFile` resolves a leaf link before renaming, so an edit in the worktree lands in the main checkout's file rather than detaching it. Both names are gitignored, so the links never enter a commit.

## Verify

```bash
clanker doctor
```

`default_provider` must now read the main checkout's choice with its key `[ok]`, and `clanker commit --dry-run` must produce a grouped plan rather than `note: llm call failed; fell back to one generic commit`.

## Escalate or follow up

If the doctor still names the committed default, check that `config.local.toml` in the main checkout sets `default_provider` at the top level and that `.env` holds that provider's key; this runbook only carries what the main checkout has.

If `prepare` reports a name as `skipped`, the main checkout sets `[agent]
worktree_link_local_config = false`; that is an operator choice, and the
worktree needs its own credentials or none.

## References

- Report: [A hand-made git worktree loses config.local.toml and .env](../reports/bugs/2026-08-22-hand-made-worktree-falls-back-to-committed-provider.md)
