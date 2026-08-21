# Bug — steerEnqueue delivers to the first matching slot only

## TL;DR

- **What failed:** POST /api/steer walks steer_slots and stops at the first slot whose goal OR session key matches (src/cli.zig steerEnqueue). Two concurrent runs registered for the same goal id mean only the first-found slot ever receives steering; the other run is silently unsteerable. A body naming both goal and session also matches on either key alone (OR, not AND), so a mismatched pair still enqueues. Found while adding webui steering visibility on 2026-08-22.
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
