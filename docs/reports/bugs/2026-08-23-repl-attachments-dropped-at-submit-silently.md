# Bug — An attachment that changed between /attach and submit is dropped with no line in the transcript

## TL;DR

- **What failed:** The submit-time drain has three silent-continue paths: the re-read (which answers StreamTooLong for a file grown to exactly the cap), a length check, and OOM. pending_images is set only when a part survived, but the queue is cleared unconditionally, so when every attachment fails the task is sent with no images anyway. PRD 0041 promises an error line with the queue unchanged; that holds at /attach time only.
- **Impact:** A screenshot regenerated between attach and send is dropped without a word, and the model answers as if no image existed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

The transcript still shows `attached: shot.png (1 queued)` above a turn that was sent with no image at all. Editors that write-and-rename hit this every time.

## Reproduction

`/attach shot.png`, re-save the file from an editor, then send a task.

## Root cause

The submit-time drain `catch continue`s on the re-read, on an empty-or-over-cap length, and on OOM, with no transcript line for any of them; the `.limited(cap + 1)` read also answers `error.StreamTooLong` for a file grown to exactly the cap, so it reads as unreadable rather than too large. `pending_images` is assigned only when at least one part survived, but `pending_attach_paths.clearRetainingCapacity()` runs unconditionally — and before `Thread.spawn`, whose `errdefer` restores only `bridge_streaming`.

## Resolution

Open. Found by a read of the code against its own doc comments and the PRD it implements, not from a live incident.

## Verification

None yet: nothing is fixed. A fix needs a unit test at the named seam plus a live REPL turn.

## Follow-up

PRD 0041's failure-modes rows ("path missing/unreadable → error line in transcript; queue unchanged") are honoured at `/attach` time and not at the read that decides what is sent.

## References

- Investigation: none yet
