# PRD — Autoresearch (`/autoresearch` / `clanker autoresearch`)

## Status

Shipped. Sources of truth: `src/research/autoresearch.zig` + `src/research/ledger.zig` + `src/research/harness.zig`, `src/research/engine.zig`, `src/cli.zig` (`Command.autoresearch`). Surface: CLI `clanker autoresearch`, REPL `/autoresearch`, WASM tool `autoresearch`, web UI via ledger tool. Eval: `evals/autoresearch_*.task.json`. Inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch).

## Problem

Manual edit → run → measure → keep/discard loop costs a human per iteration and never runs overnight. With a first-class loop it is `12 experiments/hour` unattended with a ledger to read in the morning. Generic `command → scalar`, not just GPU kernels.

## Design

Harness contract: any shell command must (a) exit 0, (b) emit metric as `<pattern><number>` in stdout/stderr or `metric.json` `{"<name>": <number>}`, (c) respect `budget_seconds` wall-clock. Targets validated against `src/improve/proposal.zig` allowed surface. State: `state/autoresearch/<run-id>/` (`config.json` or `config.toml`, `ledger.jsonl`, `best/`, `staging/`). Loop: `src/research/autoresearch.zig` (`Loop`).

## Acceptance

- [x] `clanker autoresearch --help` + dry-run
- [x] Metric extraction + direction + ledger
- [x] WASM tool + skill + eval + REPL slash
- [x] `zig build` / `zig build tools` / `zig fmt --check` green
