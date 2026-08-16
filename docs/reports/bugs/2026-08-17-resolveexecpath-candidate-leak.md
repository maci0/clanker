# Bug — resolveExecPath leaks PATH-candidate allocations through ckStdApi

## TL;DR

- **What failed:** Every clanker run on this checkout ends with DebugAllocator leak traces pointing at src/sandbox/host.zig:3621: resolveExecPath's std.fmt.allocPrint candidate strings reached via ckStdApi's rg resolution (host.zig:3746) are reported leaked at process exit. Observed twice on 2026-08-16/17 in run shutdown logs; repeated once per ck_std_api rg lookup. Not yet traced whether the leak is the returned path never freed by ckStdApi or the non-matching candidates never freed inside the loop.
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
