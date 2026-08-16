# Runbook — a run compacts on every iteration, or stops with `CompactionStalled`

## TL;DR

- **Use when:** a run logs `compacting conversation` on most or every iteration,
  logs `history threshold N is below the M tokens compaction cannot remove`, or
  ends with `run could not compact its history any further`.
- **Recover by:** giving compaction room — raise `agent.max_history_tokens` when
  the model has the window for it, otherwise trim what the system prompt carries
  or move to a model with a larger window.
- **Verify with:** a run of the same task that compacts occasionally instead of
  continuously, and no floor warning.

## Scope and preconditions

Applies to any agent run (`clanker run`, `improve-self`, a goal loop, the REPL,
a scheduled run). It is about the *history* budget, not the model's context
window being genuinely full: a run legitimately near the window compacts and
carries on, while this symptom is compaction that repeats without getting
anywhere.

Requires read access to the run's log and to the config the run used
(`config.toml` plus `config.local.toml`).

Established by
[the compaction livelock bug](../reports/bugs/2026-08-16-compaction-cannot-shrink-immovable-history.md)
and its
[investigation](../reports/investigations/2026-08-16-run-livelock-compaction-thrash.md).
Before `d2628464` this symptom had no defined end: the run compacted every
iteration until `agent.max_iterations`, which at a high setting is hours.

## Diagnose

Compaction preserves the system message and the last six messages and replaces
only the middle. When those alone exceed the threshold, there is nothing left to
free, and the same decision is taken again on the next iteration. Every check
below is about how much room is left between that immovable part and the cap.

Start with the run's own report of the floor. This line, once per run, is the
direct measurement and usually ends the diagnosis:

```bash
grep "compaction cannot remove" run.log
```

`history threshold 16000 is below the 20774 tokens compaction cannot remove`
means the configured cap is under the floor and the run lifted it to keep going.
That is the fix working, not a failure — but it is also the signal that the cap
is set wrong for this prompt and model.

Count how often compaction ran, against how many iterations the run took:

```bash
grep -c "compacting conversation" run.log
```

Occasional compaction in a long run is healthy. Compaction on nearly every
iteration means the history is pinned against a ceiling.

Read the two ceilings the run failed against, printed when a run stops:

```bash
grep -A 2 "could not compact its history" run.log
```

The `agent.max_history_tokens is N and this model gives compaction M tokens to
work in` line decides the recovery: when `N` is the smaller number, the cap
binds and raising it is the fix; when `M` is smaller, the model's window binds
and raising the cap will change nothing.

Measure what the system prompt itself costs, since it is the immovable part that
usually dominates:

```bash
wc -c AGENTS.md state/learnings.md skills/SYSTEM.md
```

Clanker estimates roughly four bytes per token, so 56,000 bytes of prompt inputs
is about 14,000 tokens of an unmodified 16,000-token cap.

## Recover

When the cap binds and the model has room, raise it in `config.local.toml` under
`[agent]`. Leave a clear margin above the floor the run reported — the run needs
the space between the floor and the cap to work in, not merely to fit:

```toml
[agent]
max_history_tokens = 100000
```

When the model's window binds, the cap cannot help. Either run the task on a
model with a larger window:

```bash
clanker run --model deepseek/deepseek-v4 "<task>"
```

or reduce the immovable part. `state/learnings.md` is the usual growth: it is
appended to over time and is carried in every request of every run. Review it and
keep what still earns its place:

```bash
clanker reports open state/learnings.md
```

`AGENTS.md` is the other large input. Both are read on every run, so a trim
applies immediately to the next one — no restart or cache clearing is involved.

## Verify

Re-run the task that failed and count compactions against iterations:

```bash
grep -c "compacting conversation" run.log
```

Expect a small number relative to the run's iteration count, and no
`compaction cannot remove` line. If the floor warning is still printed, the cap
is still below the floor — raise it further, or the model's window is the binding
ceiling and the recovery is the model or the prompt, not the cap.

A run that stops again with `CompactionStalled` after both recoveries is a new
condition: the task's own tool output is filling the window between iterations,
which no cap setting fixes.

## Escalate or follow up

Open a new investigation when compaction repeats on a run whose configured cap is
comfortably above the reported floor, or when `CompactionStalled` fires with the
model's window as the binding ceiling on a model that should be large enough.
Either case means the floor is being measured wrong rather than set wrong, and
the measurement lives in `immovableTokens` / `historyTokens` in
`src/agent/loop.zig`.

Known weakness, not yet addressed: `agent.max_history_tokens` still defaults to a
flat 16000 with no relation to any model's context window, so a large-window
model meets this runbook on its first long run.

## References

- Report: [Compaction repeats forever when the history it cannot move exceeds the threshold](../reports/bugs/2026-08-16-compaction-cannot-shrink-immovable-history.md)
- Investigation: [`clanker run` never finishes, compacting on every iteration](../reports/investigations/2026-08-16-run-livelock-compaction-thrash.md)
- Code or configuration: `src/agent/loop.zig` (`maybeCompactMessages`,
  `immovableTokens`, `raisedThreshold`, `historyTokens`), `src/cli.zig`
  (`reportUnfinishedRun`), `agent.max_history_tokens` in
  [configuration.md](../configuration.md)
- Last verified: 2026-08-16, `d2628464`
