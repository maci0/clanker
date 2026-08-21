# Bug — Steer framing sentence is persisted as the user's own words

## TL;DR

- **What failed:** handleSteer (src/cli.zig) and TUI steerWhileRunning (src/tui/repl.zig) prefix each steering message with the '[The user interjected...]' framing sentence, and the run saves that framed text verbatim as a role=user message in the session file. Every transcript consumer shows the harness's framing as user-typed text; the webui also split the turn there. Webui render side fixed 2026-08-22 via client-side detection, but the stored shape is the defect.
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
