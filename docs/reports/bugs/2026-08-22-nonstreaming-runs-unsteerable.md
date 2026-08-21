# Bug — Non-streaming runs never register a steer slot

## TL;DR

- **What failed:** Only the streaming POST /api/run path calls runRegister (src/cli.zig ~15515), so a run started with stream:false never claims a steer slot: every POST /api/steer against it answers 404 no_run and the run proceeds unsteerable with no indication to the caller. Same applies when all 64 steer slots are taken: runRegister returns false and the run silently starts without a steer_fn. Found while adding webui steering visibility on 2026-08-22.
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
