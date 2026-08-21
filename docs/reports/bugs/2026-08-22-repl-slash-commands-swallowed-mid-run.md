# Bug — REPL slash commands typed mid-run are steered, not run

## TL;DR

- **What failed:** Model.submit branches to steerWhileRunning before parseCommand when a turn is streaming (src/tui/repl.zig), so a slash command typed while the agent runs (/help, /compact, /quit) is framed and queued as literal steering text for the model instead of executing. The user gets no command and the model reads '/help' as a course correction. Either parse commands before the steer branch or refuse them with a notice mid-run. Found 2026-08-22 while adding steering visibility.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
