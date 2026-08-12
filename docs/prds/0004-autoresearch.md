# PRD — Autoresearch (`/autoresearch` / `clanker autoresearch`)

## Status

Shipped. Sources of truth: `src/research/autoresearch.zig` (`Loop`) +
`src/research/ledger.zig` + `src/research/harness.zig`, and `src/cli.zig`'s
`cmdAutoresearch` (`Command.autoresearch`). Surface: CLI `clanker
autoresearch` (runs the loop directly), REPL `/autoresearch` (re-submits the
line as an agent chat message, see Design), WASM tool `autoresearch`
(list/tail a run's ledger only, does not drive the loop). Eval:
`evals/autoresearch_*.task.json`. Inspired by
[karpathy/autoresearch](https://github.com/karpathy/autoresearch).

`src/research/engine.zig` is an unrelated placeholder for the self-improve
loop's future research capabilities (pulled in only by a test-only import in
`main.zig`); the autoresearch loop never imports it and it is not part of
this surface, despite the similar name.

Two things this doc used to claim that the code does not do: `--budget`
is accepted but never enforced as a wall-clock cutoff, and the `best/`
directory the loop creates is never written to. Both are in Known issues.

## Problem

Manual edit -> run -> measure -> keep/discard costs a human every iteration
and never runs overnight. A first-class loop targets `12 experiments/hour`
unattended (one per default 300s budget) with a ledger to read in the
morning. The contract is generic `command -> scalar`, not just GPU kernels.

## Goals

1. Given a shell harness that emits one scalar metric, run N proposal/patch/
   measure iterations unattended and keep only improvements.
2. Restrict what an iteration can touch to explicit `--target` files inside
   the self-improve allowed surface (`src/improve/proposal.zig`).
3. Record every iteration, pass or fail, in an append-only ledger a human
   can read after the fact.
4. Make the loop reachable from the CLI and, via the agent, from the REPL;
   make results (not the loop itself) readable from any agent conversation,
   including one running in the web UI.

## Non-goals

- Multi-metric or Pareto optimization: the harness contract is exactly one
  scalar per run.
- A dedicated web UI page: only ledger inspection (list/tail) is exposed,
  as a tool any agent conversation can call.
- Concurrent experiments: iterations run strictly sequentially in one
  process.

## Design

**Harness contract.** Any shell command must (a) exit 0, (b) emit the
metric as `<pattern><number>` in stdout/stderr, or as `metric.json`
`{"<name>": <number>}` (checked first), both implemented in
`harness.zig`'s `extractMetric`. A `--budget` is accepted and logged but not
enforced (see Known issues).

**Loop.** `Loop.run` creates `state/autoresearch/<run-id>/`, writes
`config.json`, then for `--iters` iterations calls `iterOnce`: read target
file contents into the LLM prompt, parse the JSON proposal
(`src/improve/proposal.zig`'s `parseProposal`), reject any change whose file
is outside `--target` or fails `validatePath`, stage a pristine copy of each
target under `staging/`, apply the proposal through the sandboxed
`patch_apply` WASM tool, run the harness against the staged tree, and record
the result to `ledger.jsonl` regardless of outcome. An improvement
(`ledger.isBetter`) overwrites the live target files in place with the
staged content.

**Surfaces.** `clanker autoresearch` runs the loop directly. REPL
`/autoresearch <args>` with no args or `--help` prints usage; with real
arguments it re-submits the raw line as a normal chat message (`submitTask`)
rather than calling `Loop` directly: `skills/autoresearch.md` is what tells
the agent to exec `clanker autoresearch` itself. The WASM tool `autoresearch`
(`tools/zig/autoresearch_tool.zig`, `fs_prefixes: ["state/autoresearch/"]`)
only lists run directories or tails a run's `ledger.jsonl`; it cannot start
or stop a run. It is what any agent conversation, including one in the web
UI, uses to read results; there is no dedicated web UI page for this
surface.

## Known issues

- `--budget`/`budget_seconds` is parsed, stored on `Options`, and logged,
  but never enforced: `harness.zig`'s `runHarness` calls `std.process.run`
  with no timeout, so a hung or slow harness command runs to completion (or
  forever) instead of being cut off at the advertised wall-clock budget.
  Fix belongs in `src/research/harness.zig`'s `runHarness`.
- `Loop.iterOnce` creates `state/autoresearch/<run-id>/best/` but never
  writes to it; an improved iteration overwrites the original target files
  at their real repo path instead. `best/` is a directory with nothing in
  it. Fix belongs in `src/research/autoresearch.zig`'s `iterOnce`: either
  populate it or stop creating it.

## Failure modes

| Condition | Behaviour |
|---|---|
| `--target`/`--harness` missing (non dry-run) | `error.MissingArg`, logged, command aborts |
| `--dry-run` | Logs target/harness/metric/direction/budget/iters and returns; no LLM call, no harness run |
| LLM chat call fails | Iteration warning-logged, treated as no improvement, loop continues |
| Proposal JSON fails to parse | Iteration warning-logged, treated as no improvement |
| Proposed change targets a file outside `--target`, or fails `validatePath` | Iteration rejected before patching, treated as no improvement |
| `patch_apply` WASM tool fails | Iteration warning-logged, treated as no improvement |
| Harness exits non-zero | `ok=false` in the ledger entry, not an improvement |
| Harness produces no parseable metric | `metric=null` in the ledger entry, `isBetter` treats it as not an improvement |
| Harness runs long past `--budget` | Not cut off (see Known issues); runs until it exits on its own |
| `ledger.jsonl` already over 10 MiB | `appendEntry` returns `error.StreamTooLong`, existing file left untouched (test-covered) |

## Acceptance criteria

- [x] `clanker autoresearch --help` and `--dry-run` validate without an LLM call
- [x] Loop runs targets/harness/metric/direction/iters end to end, logging each iteration
- [x] Change validation rejects out-of-target and disallowed paths before patching
- [x] Metric extraction from `metric.json` or `<pattern><number>` in stdout/stderr
- [x] Append-only ledger (`ledger.jsonl`), including the oversized-file edge case
- [x] WASM tool `autoresearch` lists runs and tails a ledger, reachable from any agent conversation
- [x] Skill (`skills/autoresearch.md`) + REPL `/autoresearch` + eval coverage (`evals/autoresearch_*.task.json`)
- [ ] `--budget` enforced as a wall-clock cutoff on the harness subprocess (accepted, not enforced; see Known issues)
- [x] `zig build` / `zig build tools` / `zig fmt --check` green

## Open questions / future work

- Whether `best/` should hold real snapshots of the best-known target files,
  independent of the working tree, or whether the directory should simply
  not be created until it does something.
- Whether the budget should become a real subprocess timeout (kill after N
  seconds) or the harness contract should instead just document "the
  harness is responsible for its own budget."
