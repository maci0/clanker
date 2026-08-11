# Autoresearch

Use `clanker autoresearch` (or the `autoresearch` loop) to autonomously search for a better version of any measurable target — a Zig micro-bench, a WASM tool's throughput, a prompt/skill's eval score, a `train.py`'s `val_bpb` — by repeatedly proposing patches and keeping the best result. Inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch): fixed time budget per experiment, one scalar metric, overnight-friendly.

```sh
clanker autoresearch --target <file> --harness "<cmd>" --metric <name> --direction min|max --pattern "<substring>" --budget <sec> --iters <n>
clanker autoresearch --help          # full flag docs
clanker autoresearch --target f --harness "echo score: 1.0" --dry-run  # validate without LLM
```

Harness contract: any shell command that (a) exits 0 on a real run, (b) prints the metric (`<pattern><number>` in stdout/stderr, or writes `metric.json` `{"<name>": <number>}`), (c) respects the wall-clock budget. Keep targets inside the allowed surface (`src/improve/proposal.zig`). See `docs/prds/autoresearch.md` and `docs/adrs/0003-autoresearch-is-a-generic-harness-loop.md`.
