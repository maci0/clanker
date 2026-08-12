# Autoresearch

Use `clanker autoresearch` to autonomously search for a better version of any measurable target — a Zig micro-bench, a WASM tool's throughput, a prompt's eval score. Inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch): fixed time budget per experiment, one scalar metric.

The harness is executed as a local command for every experiment. Verify that
its dependencies are available, that it exits on its own, and that the metric
appears in its output. Start with `--dry-run`. A real run writes each new best
result back to the target files; use only targets the user has authorized the
agent to modify.

```sh
clanker autoresearch --target <file> --harness "<cmd>" --metric <name> --direction min|max --pattern "<substring>" --budget <sec> --iters <n>
clanker autoresearch --target f --harness "echo score: 1.0" --dry-run
```
