# Runbook — A hand-made git worktree has no config.local.toml or .env

## TL;DR

- **Use when:** Link config.local.toml and .env from the main checkout into a worktree made with git worktree add before running any verb that calls a model; clanker doctor confirms the default provider is the one you configured.
- **Recover by:** Determine the current verified procedure.
- **Verify with:** The linked report's verification steps.

## Scope and preconditions

A linked worktree of this repository created by hand (`git worktree add`), which is what `.agents/agent-rules/repo-rules-merge-workflow.md` requires of every agent session. Worktrees clanker creates itself (`improve-self`, `--worktree` runs) link these files already (`src/improve/worktree.zig`) and do not need this. The main checkout must hold a working `config.local.toml` and `.env`.

## Diagnose

Run the doctor from inside the worktree:

```bash
clanker doctor
```

The signature is `config.local.toml absent; defaults from config.toml only` together with a `[FAIL]` on the committed default provider (`moonshotai`) for a key you never set. A `ToolWasmMissing` error from any verb is the same gap on the build side: `zig-out/tools/` is resolved against the cwd and a fresh worktree has none.

## Recover

From inside the worktree, locate the main checkout through git (the common git dir lives there) and link the two gitignored files:

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

If the doctor still names the committed default, check that `config.local.toml` in the main checkout sets `default_provider` at the top level and that `.env` holds that provider's key; this runbook only carries what the main checkout has. The durable fix is tracked in the linked report.

## References

- Report: [A hand-made git worktree loses config.local.toml and .env](../reports/bugs/2026-08-22-hand-made-worktree-falls-back-to-committed-provider.md)
