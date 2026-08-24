# Bug — The same @path line inlines a file when idle and reaches the model literally mid-run

## TL;DR

- **What failed:** mention_expand.expandAlloc has one call site in the tree, in submitTaskWithGoal. steerWhileRunning takes the same composer text through the same takeComposerText and dupes it straight into bridge_steer with no expansion, and the refuse rules (absolute paths, .., secret dotenv) are not consulted either. PRD 0058 says the composer itself is the steer box while a turn runs, so one widget and one key mean two different things depending on state the user has no reason to connect to @-expansion.
- **Impact:** `@path` silently means two different things depending on whether a turn is running.
- **Resolution:** Resolved on 2026-08-24. Both composer paths now go through one expandComposerMentions in src/tui/repl.zig, so a mid-run @path is inlined and the refuse rules (absolute, .., secret dotenv) apply there too. readMentionFile takes the root dir so the transform is testable against a tmpDir. Live over a pty, same script: origin/main answered 'There is no magic word in the text above', the fix answered the token from the file. Gate green on twelve.

## Status

Resolved on 2026-08-24. Both composer paths now go through one expandComposerMentions in src/tui/repl.zig, so a mid-run @path is inlined and the refuse rules (absolute, .., secret dotenv) apply there too. readMentionFile takes the root dir so the transform is testable against a tmpDir. Live over a pty, same script: origin/main answered 'There is no magic word in the text above', the fix answered the token from the file. Gate green on twelve.

## Symptom and impact

Idle, `look at @src/tui/repl.zig` inlines the file as a fenced block. Mid-run the identical line reaches the model as the literal string `@src/tui/repl.zig`, so it guesses or burns a `read_file` round trip.

## Reproduction

Start a turn, then type `@src/main.zig what is this` while it runs.

## Root cause

`mention_expand.expandAlloc` has exactly one call site in the tree, in `submitTaskWithGoal`. `steerWhileRunning` takes the same composer text through the same `takeComposerText` and dupes it straight into `bridge_steer`; `loop.zig` only applies `applySteerFraming`. The refuse rules (absolute paths, `..`, secret dotenv) are not consulted on that path either.

## Resolution

The expansion, its `Ctx` and its refuse rules moved out of `submitTaskWithGoal`
into `expandComposerMentions` (`src/tui/repl.zig`), documented as the single
pre-send transform for composer text. `steerWhileRunning` calls it too, on the
`.steer` arm only, after `classifyMidRunInput` has had its say (a command is
still a command in both states) and before the text is duped into
`bridge_steer`. The echo line deliberately keeps the *typed* text: an inlined
file is not something to paste into the transcript.

`readMentionFile` gained a `dir` parameter, `std.Io.Dir.cwd()` in the REPL.
That is the whole reason it exists: the refuse rules reject absolute paths, so
without an injectable root a test cannot reach a scratch file through the real
`Ctx` at all, and the transform's rules could only be asserted against a fake
one.

Expansion stays under `bridge_mutex`, which is where the idle path already did
it, so this adds no new lock-held I/O.

Nothing outside `src/tui/repl.zig` changed. The steering lockstep across
`src/cli.zig`, `src/tui/repl.zig` and `ui/app/core/steer.js` is about the
framing sentence `applySteerFraming` puts on the request copy, which this does
not touch. The web composer has no mention expansion on either of its paths,
so it is not made inconsistent with itself; wiring it up is PRD 0052's own
open web-composer phase, not this fix.

## Verification

Unit test `expandComposerMentions inlines a mention and honours every refuse
rule` (`src/tui/repl.zig`) drives the real `Ctx` against a tmpDir: a relative
mention is inlined as a fenced block with its contents, and the three refusals
(a dotenv, an absolute path, a `..` traversal) leave the token literal, emit
`[mention refused: …]` and read nothing. The dotenv arm is the one that
mattered: the mid-run path consulted no refuse rules at all, so that content
had a route to the provider it should never have had.

`clanker gate` green on all twelve checks.

Live, over a real pty (110x34, TIOCSWINSZ), one script run against two
binaries. `notes.txt` holds `The magic word is zarquon-7731.`; a five-tool-call
task is started so the turn takes several steps and the queued steer is
actually drained; mid-run the composer is sent `@notes.txt without using any
tools, what is the magic word in the text above? answer in one short line.`

- `origin/main` (ebac7fe5): `There is no magic word in the text above.`
- this fix: `zarquon-7731`

Both runs show `steering queued (1 pending): …` and both reach 3 steps, so the
steer was delivered either way. The only difference is whether the file came
with it.

A first attempt at this used a single-step counting task; the turn ended before
the steer was drained and both binaries looked identical. A steer that is never
consumed proves nothing, so check the step count.

## Follow-up

PRD 0052 gained acceptance criterion 7 for the idle/mid-run equivalence, and
its status line now names `expandComposerMentions` as the single transform.
Criterion 1 was written about the composer and had been read as covering this;
it did not.

## References

- Investigation: none yet
