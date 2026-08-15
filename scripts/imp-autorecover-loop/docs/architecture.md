# Architecture

Two files. `run.sh` is a launcher that resolves things and asks
questions; `loop.py` is the loop that never ends. The launcher
holds no logic the loop depends on — anything it decides is passed down as an
explicit flag, and the loop re-derives the same answers when run directly.

## The loop

```
                    ┌──────────────────┐
                    │  improve-self    │◄────────────────┐
                    │  (--iters N)     │                 │
                    └────────┬─────────┘                 │
                             │                           │
            ┌────────────────┴────────────────┐          │
            │                                 │          │
      exit 0, no stop                   failed batch      │
            │                                 │          │
            └──► next goal ───►┐              ▼          │
                               │      ┌──────────────┐   │
                               │      │ clanker run  │   │
                               │      │ --no-worktree│   │
                               │      └──────┬───────┘   │
                               │             │           │
                               │      ┌──────┴───────┐   │
                               │   exit 0        non-zero│
                               │      │             │    │
                               ├──────┘             ▼    │
                               │        ┌────────────────┴───┐
                               │        │ clanker run        │
                               │        │ --no-worktree      │
                               │        │ --model <escalate> │
                               │        └──────┬─────────────┘
                               │               │
                               │       ┌───────┴──────┐
                               │    exit 0       non-zero
                               │       │              │
                               └───────┘              ▼
                                            ┌─────────────────┐
                                            │ --fix-repairs-  │
                                            │ with harness    │
                                            │ (optional)      │
                                            └────────┬────────┘
                                                     │
                                                     ▼
                                              back to improve-self
```

The boxes are the commands the loop actually runs, so `<escalate>` is the value
of the loop's own `--escalate-model`, handed to Clanker as its `--model`. When
that value is empty the flag is left off and the escalation run is a plain
`clanker run --no-worktree`, exactly like the repair run above it.

A batch is "failed" when either of two things happens:

- the loop sees two **adjacent** iterations log `all attempts failed`, and kills
  the batch rather than letting it burn the remaining iterations
- `improve-self` exits non-zero

Both are exit-status or explicit-marker signals. The log text is never scanned
to decide whether to repair — see [decisions.md](decisions.md#error-text-never-decides-whether-to-repair).

Every arrow eventually returns to `improve-self`. There is no terminal state
except `--max-repairs` being exceeded, or the operator interrupting.

## Where the prompt comes from

A repair prompt always describes the **most recent** failed run, never an
accumulated history:

| repair of | run by | prompt built from |
|---|---|---|
| a failed `improve-self` batch | clanker repair run | that batch's log |
| a failed clanker repair run | clanker escalation run | that repair run's log |
| a failed clanker escalation run | `--fix-repairs-with` harness | that escalation run's log |

Earlier attempts survive only as one sentence of context each (`A clanker repair
run already tried to fix this and exited with status 1.`), not as embedded log
text.

A log becomes prompt text through three steps, in `loop.py`:

1. `read_log` — decode bytes, replace NUL (illegal in argv), keep everything else
2. `error_report` — keep error lines, drop routine progress, fold repeats
3. `fit_to_argv` — trim to the tail that fits in one argv string

Step 3 is a backstop. Step 2 normally brings a log far under the limit on its
own, but a log made entirely of unrecognised output falls through `error_report`
unchanged, and that path still has to be safe.

### What `error_report` keeps

- `[ERROR]`, `[WARN]`, `[WARNING]`, `[FATAL]` — Clanker's structured levels
- lines starting `error`, `fatal`, `panic`, `failed`
- `Traceback (most recent call last):` and the indented frames beneath it
- the line that ends a traceback, e.g. `OSError: [Errno 7] ...`
- `==>` markers, which are this tool's own progress output

Indented lines are kept only when they follow a kept line, which is what holds a
traceback together as a block. Consecutive duplicates are folded into one line
plus `(repeated N times)`, after `ts_ms=` / `request_id=` and similar per-line
fields are normalised away, so a retry storm across 200 iterations collapses.

If nothing matches, the whole log is passed through rather than an empty
prompt — an unrecognised failure must not be silently swallowed.

## Process handling

Both runners stream the child's combined output to the terminal and to a
temporary log at once, so a long run is watchable and still capturable.

Children are started with `start_new_session=True`, which puts each in its own
process group. That is what makes `stop_process_group` able to kill
`improve-self` *and* the model and gate processes it spawned — killing only the
direct child would leave those orphaned and still holding the run lock.

Temporary logs are unlinked on every path, including the exception path.

## Binary resolution

Both files implement the same order:

1. explicit (`--clanker`, or `CLANKER_BIN` in the launcher)
2. `clanker` on `PATH`
3. `<clanker-dir>/zig-out/bin/clanker`

The launcher resolves it, prints it, and passes it down as `--clanker`, so the
loop's own copy never runs in that path. The loop's copy exists for direct
invocation. Both harnesses — the clanker binary and any `--fix-repairs-with`
command — are resolved before the first batch starts.

## Which model each level runs on

| level | model |
|---|---|
| improve-self batch | `--model`, or Clanker's configured model when it is empty |
| clanker repair run | Clanker's configured model, always |
| clanker escalation run | `--escalate-model`, or Clanker's configured model when it is empty |
| repair harness | whatever the harness command itself selects |

`--escalate-model` is passed through as `clanker run --model`, so it accepts a
model name or `<provider>/<model>` and switches provider with it. Left empty,
the escalation run is a second attempt on the model that just failed, which is
still worth having — the two runs see different prompts.

## What the loop assumes about a harness

`--fix-repairs-with` accepts any command that meets a two-part contract:

- the prompt is accepted as the **final positional argument**
- failure is reported through a **non-zero exit status**

That is why the flag takes a whole command string rather than a binary name: the
harness and its model and its permission flags are all one decision. `shlex`
splits it, and the prompt is appended.

Verified against this contract:

| harness | invocation | note |
|---|---|---|
| Claude Code | `claude -p --permission-mode acceptEdits` | plain `-p` stalls on permission prompts |
| Codex | `codex exec` | |
| Grok | `grok --always-approve -p` | `-p` is `--single <PROMPT>`, so the prompt is its value |
| DeepSeek Harness | `dsh --profile headless` | `dsh run` was superseded by the profile form |
