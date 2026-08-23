# Bug — /attach queues any file and fabricates an image MIME type for it

## TL;DR

- **What failed:** The attach arm validates queue length, a 4 MiB cap and not-a-directory, with no MIME or extension check, so /attach report.pdf queues; at submit anything not png/jpg/jpeg/webp is labelled image/png. The web path it mirrors gates on image/, and the server refuses when modules.multimodal is off or the model lacks image_in, naming both. The REPL honours none of the three: the turn dies with an opaque provider 400.
- **Impact:** `/attach` on a non-image, or with a text-only model, fails the whole next turn with a provider error instead of refusing at the command.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

`/attach report.pdf` prints `attached: report.pdf (1 queued)`. The next turn dies with an opaque provider deserialize error or 400. With a text-only model a valid PNG is sent and rejected with no hint that the model lacks vision.

## Reproduction

`/attach` any non-image file, then send a task.

## Root cause

The `.attach` arm checks queue length, a 4 MiB size cap and not-a-directory only; at submit anything not `.png/.jpg/.jpeg/.webp` is labelled `image/png`. `ui/app/core/attachments.js` gates on `file.type` starting with `image/`, and `src/cli.zig` refuses when `modules.multimodal` is off or the active model does not declare `image_in`, naming the model and the knob in the 400. Neither `multimodal` nor `imageAttachmentsSupported` appears in `src/tui/repl.zig`.

## Resolution

Open. Found by a read of the code against its own doc comments and the PRD it implements, not from a live incident.

## Verification

None yet: nothing is fixed. A fix needs a unit test at the named seam plus a live REPL turn.

## Follow-up

PRD 0041 says the size/type gating mirrors the web limits and claims `image_in` parity, so the PRD's acceptance criteria need re-checking alongside the fix.

## References

- Investigation: none yet
