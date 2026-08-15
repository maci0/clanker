# imp-autorecover-loop

Keeps `clanker improve-self` running, and repairs it with Clanker whenever it
fails.

## Quick start

Select the improve-self model and the repair harness from menus, then run:

```bash
./run.sh
```

Skip the menus and run the loop directly:

```bash
./loop.py
```

Everything below is detail. For how the pieces fit together see
[docs/architecture.md](docs/architecture.md); for why they are built that way
see [docs/decisions.md](docs/decisions.md).

## What it does

`loop.py` runs three `clanker improve-self` iterations at a time.
Before each batch it randomly selects an improvement goal, without immediately
repeating the previous one. A successful batch starts the next randomly
selected goal, and the loop never ends on its own.

Two levels of repair sit under that loop, and the rest of this file uses these
names for them:

| term | what it is |
|---|---|
| improve-self batch | `clanker improve-self --iters N <goal>` |
| clanker repair run | `clanker run`, which repairs a failed batch |
| repair harness | `--fix-repairs-with`, which repairs a failed clanker repair run |

When a batch fails, a clanker repair run fixes it from that batch's error
lines. When that repair run fails too, the repair harness fixes it — if one is
configured. Then the loop returns to `improve-self` and keeps going.

`run.sh` resolves the checkout and the `clanker` binary, asks which
model and repair harness to use, and hands everything to the loop.

## Choosing a model

Without `--model`, `improve-self` is invoked without the flag at all, so the
active Clanker configuration chooses the provider and model. Name a model to
override that:

```bash
./loop.py --model ollama/qwen3.6-27b-tuned
```

The model reaches `improve-self` batches only. Clanker repair runs are
`clanker run` with no `--model`, so they always use Clanker's configured model.

Add entries to the menu by editing the `MODELS` array at the top of
`run.sh`. The literal entry `default` passes no `--model` at all.

## Choosing goals

The goal list covers Clanker, TUI, CLI, web UI, error handling,
`improve-self`, documentation, diagnostics and bug reports, automatic bug
fixing, tools, configuration diagnostics, provider recovery, gates, sandbox
safety, and scheduling/state handling. Supply a fixed goal to disable random
selection:

```bash
./loop.py "improve the clanker tui"
```

Use another batch size when needed:

```bash
./loop.py --iters 5
```

## When a repair starts

`improve-self` does not stop at an unsuccessful iteration: it consumes the
whole `--iters` batch first. The loop watches its live output instead. Once two
adjacent iterations each log `all attempts failed`, it terminates that batch
and starts a repair. A non-adjacent failed iteration does not trigger one; the
successful or no-change iteration between them breaks the streak. An unexpected
non-zero `improve-self` exit also starts a repair.

The repair is `clanker run --no-worktree` with the Clanker checkout as its
working directory, so its changes are made directly on Clanker's `main`
checkout rather than on an automatic goal worktree.

Every clanker repair run works from the **latest** `improve-self` log. A failed
repair run is never retried against the log that triggered it: the loop returns
to `improve-self`, and if the batch fails again, the next repair run works from
that new batch's errors. The previous run's exit status is carried into the next
prompt as a sentence, so Clanker knows an attempt was already made.

## Repairing a failed clanker repair run

This level is off unless you ask for it. Hand the failed clanker repair run to
a harness, ideally a different one from the harness that just failed:

```bash
./loop.py --fix-repairs-with "claude -p --permission-mode acceptEdits"
```

The argument is a command; the prompt is appended to it as one final argument,
and failure is read from its exit status. Harness and model are therefore both
chosen here:

```bash
./loop.py --fix-repairs-with "grok --always-approve -p"
```

```bash
./loop.py --fix-repairs-with "dsh --profile headless"
```

Without this flag a failed clanker repair run is simply dropped and the next
`improve-self` batch resurfaces the problem. With it, the named harness gets
the clanker repair run's error lines and fixes it. Either way the loop then
returns to `improve-self` and continues indefinitely. It triggers only on a
non-zero exit from the clanker repair run.

Both harnesses are resolved before the first `improve-self` batch, so a missing
one fails immediately rather than hours later when a repair finally needs it.

Use a finite repair limit when supervising an experiment. It counts
*consecutive* failed clanker repair runs, and resets whenever a repair run or an
`improve-self` batch succeeds. `0` is the default and never gives up:

```bash
./loop.py --max-repairs 3
```

## Finding the clanker binary

The binary is resolved in this order, so `clanker` does not have to be on
`PATH` at all:

1. `--clanker`, when given
2. `clanker` on `PATH`
3. `<clanker-dir>/zig-out/bin/clanker`, the binary built in the checkout

Nothing resolving means it stops before the first batch:

```
error: no clanker executable for /path/to/clanker
       looked on PATH and in /path/to/clanker/zig-out/bin/clanker
       build the checkout, or pass --clanker
```

Name a checkout and binary directly:

```bash
./loop.py --clanker-dir /path/to/clanker --clanker /path/to/clanker
```

`run.sh` applies the same order — `CLANKER_BIN`, then `PATH`, then the
checkout build — and passes the result down explicitly, so the resolved path is
printed before anything runs:

```bash
CLANKER_DIR=~/src/clanker ./run.sh
```

```bash
CLANKER_BIN=/opt/clanker/bin/clanker ./run.sh
```

There is no dependency on a personal `clank` shim. `clank.sh` is
`env -C $CLANKER_DIR clanker "$@"`, and the loop already runs every subprocess
with the checkout as its working directory, so one `clanker` binary covers both
`improve-self` batches and clanker repair runs.

## The menus

`CLANKER MODEL` is the model `improve-self` batches run on; `REPAIR HARNESS` is
what repairs a failed clanker repair run. They are the `MODELS` and `FIXERS`
arrays at the top of `run.sh`. The sentinel entries `default` and `none`
mean "pass no flag", and Enter selects the first entry. Passing `--model` or
`--fix-repairs-with` yourself skips the matching menu:

```bash
./run.sh --fix-repairs-with "codex exec"
```
