# Bug — A truncated ck_exec result emits an unquoted note and is not JSON

## TL;DR

- **What failed:** writeExecResult adds a truncation note with Stringify.print, which writes raw text, so a search whose stdout exceeds 56 KiB returns invalid JSON. repo_search then writeAlls that blob and the agent warns malformed JSON. Escalation run-1787001820, repo_search query repair, 65148 bytes.
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
## Evidence

Escalation run `run-1787001820` node 10: `repo_search` `{"engine":"rg","query":"repair"}` returned 65148 bytes starting `{"ok":true,"code":0,"stdout":...` — the raw `ck_exec` wrapper, not compact matches. `writeExecResult` emits `"note":output was N bytes...` via `Stringify.print`, which writes a raw value; `std.json.parseFromSlice` of that object fails with `SyntaxError`. The guest's `parseFromSliceLeaky` then `writeAll`s the blob and `warnIfMalformed` fires.

The host test `writeExecResult truncation note is a JSON string` failed on the old `print` with that `SyntaxError` at `host.zig` parseFromSlice, then passed after `s.write(note)`.
## Root cause

`writeExecResult` in `src/sandbox/host.zig` wrote the truncation sentence with `Stringify.print`. That helper writes a raw value, not a JSON string, so the object became `"note":output was N bytes...` and `std.json.parseFromSlice` failed with `SyntaxError`. `repo_search` then `writeAll`'d the blob.

## Resolution

Format the sentence into a buffer and `s.write(note)` so it is a JSON string. `repo_search` now `lib.fail`s with a short message instead of echoing an unreadable exec wrapper.

## Verification

Host test `writeExecResult truncation note is a JSON string` in `src/sandbox/host.zig`.