# Bug — REPL slash commands typed mid-run are steered, not run

## TL;DR

- **What failed:** Model.submit branches to steerWhileRunning before parseCommand when a turn is streaming (src/tui/repl.zig), so a slash command typed while the agent runs (/help, /compact, /quit) is framed and queued as literal steering text for the model instead of executing. The user gets no command and the model reads '/help' as a course correction. Either parse commands before the steer branch or refuse them with a notice mid-run. Found 2026-08-22 while adding steering visibility.
- **Impact:** Any slash command or `!cmd` escape typed while a turn streams was lost as a command and delivered to the model as a course correction: `/help` printed nothing, `/quit` did not leave, and `/compact`'s own `wait until the turn is idle` guard in `runCommand` was unreachable.
- **Resolution:** Resolved on 2026-08-22. Resolved on 2026-08-22. steerWhileRunning classifies the line with classifyMidRunInput before the steer queue: /quit and /help run, every other command and a `!` escape is a wait notice, a typo'd /command the unknown-command diagnostic; none is queued. Pinned by the unit test 'classifyMidRunInput keeps commands and shell escapes out of the steer queue'; clanker gate 10/10 green in the fix worktree.

## Status

Resolved on 2026-08-22. Resolved on 2026-08-22. steerWhileRunning classifies the line with classifyMidRunInput before the steer queue: /quit and /help run, every other command and a `!` escape is a wait notice, a typo'd /command the unknown-command diagnostic; none is queued. Pinned by the unit test 'classifyMidRunInput keeps commands and shell escapes out of the steer queue'; clanker gate 10/10 green in the fix worktree.

## Symptom and impact

With a turn streaming, typing `/help` and Enter printed `steering queued (1 pending): /help` and no help; the next agent iteration received a `role=user` message reading `[The user interjected while this run was in progress; take the message into account and adjust course.]\n\n/help`. `!ls` went the same way, although `parseShellEscape`'s contract is that an escape never reaches the LLM.

## Reproduction

Start `clanker repl`, submit any task that takes a few seconds, and while the reply streams type `/help` (or `exit`, `/compact`, `!ls`) followed by Enter. Before the fix the transcript shows the `steering queued` echo and nothing else.

## Root cause

`Model.submit` (`src/tui/repl.zig`) reads `bridge_streaming` and branches to `steerWhileRunning` before `parseShellEscape`, `parseCommand` and `looksLikeSlashCommand` run, so the idle path's dispatch never saw a mid-run line; `steerWhileRunning` refused only blank lines, a turn that had already ended, and a full queue, and queued everything else verbatim behind the framing sentence.

## Resolution

`steerWhileRunning` now classifies the line with `classifyMidRunInput` (`src/tui/repl.zig`) before the queue, using the same parsers as the idle path. `runsWhileStreaming` allowlists what may execute beside the worker: `/quit` (sets `ctx.quit`; the exit path stops and joins the in-flight worker) and `/help` (a transcript append, run under `bridge_mutex`). Every other registry command gets `notice: <cmd> is a command, not steering; it runs once the turn is idle (Ctrl+C stops the turn); not queued: <line>`, a typo'd `/command` gets the idle path's unknown-command diagnostic, and a `!cmd` escape a wait notice. None of them reaches the steer queue.

## Verification

Unit test `classifyMidRunInput keeps commands and shell escapes out of the steer queue` (`zig build test -Dtest-filter="classifyMidRunInput"`): plain text classifies as `steer`, `/help` and bare `exit` as runnable commands, `/model kimi`, `/compact`, `/goal`, `/sessions` as deferred, `/hlep` as unknown, `!ls` as a shell escape. Mutation check: with `runsWhileStreaming` returning true for every action the deferred assertions fail (exit 1), so the test pins the allowlist and not just the parsers.

## Follow-up

- `/model`, `/theme`, `/effort` and `/preset` open pickers that are reachable mid-run through their key bindings, but their slash spellings are deferred: widening `runsWhileStreaming` to them needs the picker apply paths checked against what the run thread owns (`self.provider`, `self.cfg`).

## References

- Investigation: none yet
