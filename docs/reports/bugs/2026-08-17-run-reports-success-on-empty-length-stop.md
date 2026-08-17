# Bug — clanker run exits clean when the final reply is length-truncated to empty

## TL;DR

- **What failed:** Observed live (run-1786940774, deepseek-v4-pro): the last chat call hit its completion cap (4096 tokens, detail 'length') and the assembled final answer was empty, yet the run graph records failed:false, the process exits 0, and stdout ends after the log lines with no answer and no warning. An operator (or a script) reading exit status believes the task succeeded. A length-stopped empty answer should be surfaced as a failure, or at least a loud warning naming the cap.
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
