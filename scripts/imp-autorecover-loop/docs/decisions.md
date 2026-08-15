# Decisions

Why the tool is built the way it is. Each entry states the decision, what
forced it, and what was rejected. Most exist because something failed in a real
run, not because of a design preference.

## A prompt must fit in one argv string

**Decision.** A run log is filtered and trimmed before it becomes a prompt, to
a budget of `32 * PAGE_SIZE - 8192` bytes.

**Why.** Passing a full log as the prompt crashed a run:

```
OSError: [Errno 7] Argument list too long: 'clank'
```

`execve` enforces two independent limits. `ARG_MAX` (2 MiB here) caps the
*total* argv+envp block and is the one `getconf` reports. `MAX_ARG_STRLEN` —
`32 * PAGE_SIZE`, 128 KiB, a kernel constant that is not tunable and not
reported by `getconf` — caps any *single* argument. A prompt is one argument, so
it hits the second limit while the total is nowhere near the first.

**Rejected.** Passing the log on stdin: `clanker run` takes the prompt only as
an argv string. Writing it to a file and passing the path: the harness contract
(final positional argument) would no longer be uniform across harnesses.

**Consequence.** The budget is computed from `os.sysconf("SC_PAGE_SIZE")` rather
than hardcoded at 131072, so it stays correct on a kernel with different pages.

## Trim the tail, and measure encoded bytes

**Decision.** When trimming, keep the **end** of the log, and measure length
after encoding to UTF-8 and after sanitising.

**Why.** The failure that triggered the repair is at the end. Measuring before
sanitising undercounts: `errors="replace"` turns each bad byte into U+FFFD,
which is 3 bytes encoded, and `\0` becomes two characters — a log with binary
noise could pass a pre-sanitise check and still blow the limit. Cuts land on a
newline, which is always a codepoint boundary.

## Every repair uses the latest log, never a chain

**Decision.** A failed repair is not retried against the log that triggered it.
The loop returns to `improve-self`, and the next repair works from the new
batch's log.

**Why.** The original code assigned the repair run's log back over the
improve-self log and retried. Each attempt's prompt was therefore built from the
previous attempt's log, which itself contained the prompt it had been given. The
input grew monotonically with no bound, and `--max-repairs` defaulted to
unlimited, so it was guaranteed to cross the argv limit eventually — attempt 1
succeeded, attempt 2 could not exec.

Size was the visible symptom; relevance was the deeper problem. After a few
rounds the prompt is a log of an agent reading a log, and the original failure
has been pushed out of the window. The agent ends up debugging its own previous
debugging session.

**Rejected.** Keeping the original improve-self log pinned as fixed context and
splitting the budget with the newest repair log. Implemented first, then
replaced: pinning the *original* is wrong for the same reason chaining is, since
the interesting failure is whatever is happening now.

## Error text never decides whether to repair

**Decision.** Repairs are triggered by exit status, or by the explicit
`all attempts failed` marker on two adjacent iterations. The error filter only
chooses what a prompt *contains*, once a repair is already triggered.

**Why.** Clanker's passing tests intentionally emit `[ERROR]` diagnostics while
validating bad configuration. Scanning output for that label would fire repairs
on a healthy run.

This is easy to "simplify" away later by someone who sees an error filter and an
error-triggered loop and assumes they should be the same thing. Both call sites
carry a comment saying so.

## Send error lines, not whole logs

**Decision.** A prompt carries the run's error lines, with routine progress
dropped and consecutive duplicates folded into a count.

**Why.** A 274-iteration log is mostly `[INFO]` progress. Filtering makes the
failure legible to the agent and, as a side effect, brings almost every log
under the argv budget before trimming is needed.

**Rejected.** Deduplicating non-adjacent repeats too. Folding only *consecutive*
duplicates is enough in practice, because once routine lines are dropped the
repeats of a retry storm become adjacent.

**Safety valve.** If no line matches the filter, the whole log is sent. A
failure this tool cannot label must not become an empty prompt.

## One clanker binary, no `clank` shim

**Decision.** `--clank` was removed. One `--clanker` flag serves both
`improve-self` and the repair runs.

**Why.** `clank` was a personal symlink to `clank.sh`, which is
`env -C $CLANKER_DIR clanker "$@"` — that is, "run clanker with the checkout as
cwd". The loop already passes `cwd=clanker_dir` to every subprocess, so
`clanker run --no-worktree` in that cwd is exactly `clank run --no-worktree`.
The flag was a dependency on one machine's setup for no behavioural gain.

## PATH before the checkout build

**Decision.** Resolution order is explicit flag, then `PATH`, then
`<clanker-dir>/zig-out/bin/clanker`.

**Why.** `clanker` must not be *required* on `PATH`, since not everyone has the
symlink — hence the checkout fallback. Order between the two is an operator
preference, and PATH-first was chosen deliberately.

**Consequence, accepted.** Pointing `--clanker-dir` at a second checkout without
also passing `--clanker` drives that checkout with the `PATH` binary, not the
one built inside it. The launcher prints the resolved `BINARY` line before
starting so the mismatch is visible.

## Resolve every harness before the first batch

**Decision.** The clanker binary and any `--fix-repairs-with` command are
resolved at startup, not at first use.

**Why.** The repair harness is not needed until something fails, which can be
hours into an unattended run. Discovering it is missing only then wastes the
whole run.

## The launcher decides nothing the loop cannot

**Decision.** `run.sh` resolves and asks, then passes explicit flags.
The loop re-derives the same answers when run directly.

**Why.** An earlier version put binary resolution only in the launcher, so
running the loop directly still demanded `clanker` on `PATH` — the exact problem
the resolution was added to solve. Anything the launcher knows, the loop must
also be able to work out for itself.

## Menus are printed by hand, not with `select`

**Decision.** The bash `select` builtin is not used.

**Why.** It columnises a list into a grid once the entries fit side by side,
which is unreadable for entries that are whole command lines, and it treats a
bare Enter as "reprint the menu", so it cannot offer a default. Both limits are
in the builtin.

Printing the menu manually and reading with `read` gives one entry per line, a
`[1]` default in the pacman/yay style, input validation that re-prompts, and an
EOF path that takes the default instead of spinning forever.

## An empty --model omits the flag entirely

**Decision.** `--model` defaults to empty, and when it is empty the flag is left
off the `improve-self` command rather than being passed with some default value.

**Why.** "Whatever Clanker is configured for" cannot be written as a model
string. Any default value would have to name a specific model, which would then
silently override the configuration of whatever checkout `--clanker-dir` points
at. Omitting the flag hands that choice back to Clanker, which is the only place
that knows the answer.

**Rejected.** A second entry point that hardcoded the model choice. Two files
differing in one argument have to be edited in lockstep forever, and the
duplication buys nothing a flag cannot express.
