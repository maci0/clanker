---
title: Autoresearch
description: When asked to run autoresearch, benchmark or optimize a scalar metric, or drive `/autoresearch` from the REPL: the measurement loop runs only through the host CLI, not WASM tools.
enabled: true
---

# Autoresearch

Run it with `clanker autoresearch` to search for a better version of any measurable
target (a Zig micro-bench, a WASM tool's throughput, a prompt's eval score).
Inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch):
fixed time budget per experiment, one scalar metric. From an agent turn you cannot
invoke this CLI from a tool sandbox; tell the operator to run it, or use REPL `!`
only when clanker is listed in `agent.repl_exec_allow`. The `autoresearch` WASM
tool lists prior runs and tails `ledger.jsonl`; it cannot start a run.

The harness is executed as a local command for every experiment, and
`--harness` is split on spaces (quoted words stay one argument) rather than
handed to a shell, so a pipeline or a `&&` needs `sh -c "..."`.

Where the number comes from, in order: a `metric.json` in the harness's working
directory holding `{"<--metric>": <number>}`; else the first number after
`--pattern` in stdout, then the same in stderr; else, with no `--pattern`, the
first number anywhere in stdout. A harness whose output carries other digits
(a build log, a line count) is measured on the wrong number unless it writes
`metric.json` or the run names `--pattern`.

`--dry-run` prints the resolved targets, harness, metric and iteration count
and runs nothing, so it checks no dependency and extracts no metric. Run that
same harness command once by hand before the real loop: that is the only way
to see it exits on its own, finds its dependencies, and emits a number the
extractor reads.

A real run writes each new best result back to the target files; use only
targets the user has authorized the agent to modify. A harness that exits
nonzero or runs past `--budget` produces no promotion: its number is recorded
in the ledger but never written back.

```sh
clanker autoresearch --target <file> --harness "<cmd>" --metric <name> --direction min|max --pattern "<substring>" --budget <sec> --iters <n>
clanker autoresearch --target tools/zig/calculator.zig --harness "sh -c 'echo score: 1.0'" --dry-run
```
