# Bug — An attachment that changed between /attach and submit is dropped with no line in the transcript

## TL;DR

- **What failed:** The submit-time drain has three silent-continue paths: the re-read (which answers StreamTooLong for a file grown to exactly the cap), a length check, and OOM. pending_images is set only when a part survived, but the queue is cleared unconditionally, so when every attachment fails the task is sent with no images anyway. PRD 0041 promises an error line with the queue unchanged; that holds at /attach time only.
- **Impact:** A screenshot regenerated between attach and send is dropped without a word, and the model answers as if no image existed.
- **Resolution:** Resolved on 2026-08-24. The submit drain is now readAttachments in src/tui/repl.zig: every arm reports one transcript line naming path and reason instead of catch continue. All attachments failing no longer sends the turn - the queue is kept and /attach clear drops it. The clear moved after Thread.spawn so a spawn failure keeps the queue. One report claim was wrong: .limited(cap+1) accepts exactly cap, so StreamTooLong means over the cap. Unit test plus a live pty before/after. Gate green on twelve.

## Status

Resolved on 2026-08-24. The submit drain is now readAttachments in src/tui/repl.zig: every arm reports one transcript line naming path and reason instead of catch continue. All attachments failing no longer sends the turn - the queue is kept and /attach clear drops it. The clear moved after Thread.spawn so a spawn failure keeps the queue. One report claim was wrong: .limited(cap+1) accepts exactly cap, so StreamTooLong means over the cap. Unit test plus a live pty before/after. Gate green on twelve.

## Symptom and impact

The transcript still shows `attached: shot.png (1 queued)` above a turn that was sent with no image at all. Editors that write-and-rename hit this every time.

## Reproduction

`/attach shot.png`, re-save the file from an editor, then send a task.

## Root cause

The submit-time drain `catch continue`s on the re-read, on an empty-or-over-cap length, and on OOM, with no transcript line for any of them; the `.limited(cap + 1)` read also answers `error.StreamTooLong` for a file grown to exactly the cap, so it reads as unreadable rather than too large. `pending_images` is assigned only when at least one part survived, but `pending_attach_paths.clearRetainingCapacity()` runs unconditionally — and before `Thread.spawn`, whose `errdefer` restores only `bridge_streaming`.

## Resolution

The drain moved out of `submitTaskWithGoal` into `readAttachments`, a free
function in `src/tui/repl.zig` taking the paths and an out-list of notices, so
it can be driven against a real tmpDir without standing up a `Model`. Every
former `catch continue` now appends one line naming the path and the reason:
unreadable (with the error name), over the cap, empty, not an image any more,
or out of memory. `Model.readPendingAttachments` puts those lines in the
transcript.

The drain runs at the very top of `submitTaskWithGoal`, before the task is
echoed and before any bridge state is set, so the total-failure case has no
half-started turn to unwind. When it returns `images == null` with a non-empty
queue the submit is abandoned with one further line and the queue is left
intact, which is the "queue unchanged" half of PRD 0041's contract and what
stops the model being asked about an image that was never sent. `/attach
clear` is the escape hatch, so a file that is permanently gone cannot wedge
every later turn: that is the failure mode the paste-mode latch report
describes, and this must not reintroduce it by another route.

`pending_attach_paths.clearRetainingCapacity()` moved to after
`std.Thread.spawn`. Clearing before it meant a spawn failure lost the queue
outright, since that path's `errdefer` restores only `bridge_streaming`.

One claim in the report is wrong and worth correcting rather than carrying
forward: `.limited(cap + 1)` does **not** answer `error.StreamTooLong` for a
file of exactly `cap` bytes. `Reader.appendRemainingAligned` raises it only
once the whole limit has been consumed, so with a limit of `cap + 1` a file of
`cap` bytes reads fine and one of `cap + 1` does not. Verified directly against
std with a four-size probe (0, cap-1, cap, cap+1). That makes `StreamTooLong`
unambiguously "too large", which is how it is now reported, and it made the old
`buf.len > cap` check dead code. The other silent paths were real.

## Verification

Unit test `readAttachments reports every dropped attachment instead of sending
nothing` (`src/tui/repl.zig`) covers an empty queue, a readable attachment, an
unreadable-and-empty pair (the regression: `images` null, two notices), a
partial failure that still sends what survived, over-cap versus exactly-at-cap,
and a queued path that is no longer an image.

The before-state was confirmed rather than assumed: with `readAttachments`
temporarily reverted to the old `catch continue` body behind the same
signature, that test fails; with the fix it passes.

`clanker gate` green on all twelve checks.

Live, over a real pty (110x34, TIOCSWINSZ) with `--provider deepseek --model
deepseek-v4-flash`: `/attach shot.png`, delete the file, then submit "in one
short sentence, describe the attached image".

- untouched `origin/main` binary: the turn runs and the model answers "There's
  no image attached to your message", with nothing in the transcript about the
  drop. Exactly the reported impact.
- fixed binary: `attach: cannot read 'shot.png' (FileNotFound), not sent`
  followed by the refusal line, and no turn runs. `/attach clear` then reports
  `attach: queue cleared (1 dropped)`, and the next task submits and is
  answered normally, so the refusal does not wedge the composer.

## Follow-up

PRD 0041's failure-modes table now carries the submit-time row alongside the
`/attach`-time ones, since the read that decides what is sent is a second
chance to fail and was not covered.

## References

- Investigation: none yet
