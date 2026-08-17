# PRD — REPL image/multimodal input: /attach and drag-drop to image_in

## Status

In progress — thin slice shipped (see below).

Single source `src/tui/repl.zig` (plus agent image_in path). `/attach` + image_in plumbing shipped; drag-drop/image paste deferred per thin-slice plan.

## Problem

The REPL cannot attach images; users must leave the REPL or use the web UI for screenshot-dependent tasks.

Constraints: vaxis-native, image_in parity with web UI, size/type gating mirrored from web limits, no new sandbox escape.

## Goals

1. `/attach <path>` validates and queues an image for the next submit
2. Drag-drop and image paste onto the REPL auto-populate the same queue
3. Queued images travel with the task via the existing agent `image_in` channel


## Non-goals

- No video/PTY, no change to block markdown/multi-line (separate PRDs).
- No new external dependency or sandbox bypass — images ride existing `image_in`.

## Design
**Dependencies.** PRD 0005, ADR 0023, `src/tui/repl.zig` Model + submit path, `src/agent/*` image_in plumbing (web UI path as reference).

**Design.** `/attach` slash command enqueues validated paths; vaxis drag-drop and clipboard image events populate the same `images` buffer on `Model`; `submit` sends `text + images` via the agent's existing `image_in` (same multipart/vision path the web composer uses). Size/type caps mirror web limits.

**Implementation.**
1. Add `images` buffer and `/attach` command handling — `src/tui/repl.zig`.
2. Handle drag-drop and image paste events to enqueue images — `src/tui/repl.zig`.
3. Extend submit/steer to carry `image_in` alongside text — `src/tui/repl.zig` and `src/agent/*` as needed.
4. Tests for queueing, cap enforcement, and text+image submit — `src/tui/repl.zig`.
5. `zig fmt` + `zig build test` + `zig build tools` green.

## Failure modes

| Condition | Behaviour |
|---|---|
| `/attach` path missing/unreadable | Error line in transcript; queue unchanged |
| Image exceeds size cap | Rejected with size reason; no partial attach |
| Drag-drop of directory | Ignored with hint |

## Acceptance criteria

- [x] `/attach <path>` enqueues and survives to submit (pending_attach_paths + submitTask image_in)
- [ ] Drag-drop/image paste populates same queue (follow-up)
- [x] Queued images sent via `image_in` with task (RunThreadArgs pending_images → Agent.pending_images)
- [x] `zig build test` + `zig build tools` green

## Open questions / future work

- Exact byte cap mirrors web? Align during implementation.

