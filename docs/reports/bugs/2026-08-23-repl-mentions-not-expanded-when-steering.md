# Bug — The same @path line inlines a file when idle and reaches the model literally mid-run

## TL;DR

- **What failed:** mention_expand.expandAlloc has one call site in the tree, in submitTaskWithGoal. steerWhileRunning takes the same composer text through the same takeComposerText and dupes it straight into bridge_steer with no expansion, and the refuse rules (absolute paths, .., secret dotenv) are not consulted either. PRD 0058 says the composer itself is the steer box while a turn runs, so one widget and one key mean two different things depending on state the user has no reason to connect to @-expansion.
- **Impact:** `@path` silently means two different things depending on whether a turn is running.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

Idle, `look at @src/tui/repl.zig` inlines the file as a fenced block. Mid-run the identical line reaches the model as the literal string `@src/tui/repl.zig`, so it guesses or burns a `read_file` round trip.

## Reproduction

Start a turn, then type `@src/main.zig what is this` while it runs.

## Root cause

`mention_expand.expandAlloc` has exactly one call site in the tree, in `submitTaskWithGoal`. `steerWhileRunning` takes the same composer text through the same `takeComposerText` and dupes it straight into `bridge_steer`; `loop.zig` only applies `applySteerFraming`. The refuse rules (absolute paths, `..`, secret dotenv) are not consulted on that path either.

## Resolution

Open. Found by a read of the code against its own doc comments and the PRD it implements, not from a live incident.

## Verification

None yet: nothing is fixed. A fix needs a unit test at the named seam plus a live REPL turn.

## Follow-up

PRD 0058's design says the composer *is* the steer box while a turn runs, so the two paths should share one pre-send transform. PRD 0052's acceptance criterion 1 is written about the composer and reads as covering both.

## References

- Investigation: none yet
