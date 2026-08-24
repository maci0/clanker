# Bug — /attach queues any file and fabricates an image MIME type for it

## TL;DR

- **What failed:** The attach arm validates queue length, a 4 MiB cap and not-a-directory, with no MIME or extension check, so /attach report.pdf queues; at submit anything not png/jpg/jpeg/webp is labelled image/png. The web path it mirrors gates on image/, and the server refuses when modules.multimodal is off or the model lacks image_in, naming both. The REPL honours none of the three: the turn dies with an opaque provider 400.
- **Impact:** `/attach` on a non-image, or with a text-only model, fails the whole next turn with a provider error instead of refusing at the command.
- **Resolution:** Resolved on 2026-08-24. New attachGate + imageMimeForPath in src/tui/repl.zig refuse at the command: non-png/jpg/jpeg/webp paths, modules.multimodal off, and a model without image_in. The capability rule moved to config.Model.supportsImageInput, shared with cli.zig. Nothing is labelled image/png by default any more. Two unit tests; live over a pty all three refusals fire where the origin/main binary queued a PDF. clanker gate green on twelve checks.

## Status

Resolved on 2026-08-24. New attachGate + imageMimeForPath in src/tui/repl.zig refuse at the command: non-png/jpg/jpeg/webp paths, modules.multimodal off, and a model without image_in. The capability rule moved to config.Model.supportsImageInput, shared with cli.zig. Nothing is labelled image/png by default any more. Two unit tests; live over a pty all three refusals fire where the origin/main binary queued a PDF. clanker gate green on twelve checks.

## Symptom and impact

`/attach report.pdf` prints `attached: report.pdf (1 queued)`. The next turn dies with an opaque provider deserialize error or 400. With a text-only model a valid PNG is sent and rejected with no hint that the model lacks vision.

## Reproduction

`/attach` any non-image file, then send a task.

## Root cause

The `.attach` arm checks queue length, a 4 MiB size cap and not-a-directory only; at submit anything not `.png/.jpg/.jpeg/.webp` is labelled `image/png`. `ui/app/core/attachments.js` gates on `file.type` starting with `image/`, and `src/cli.zig` refuses when `modules.multimodal` is off or the active model does not declare `image_in`, naming the model and the knob in the 400. Neither `multimodal` nor `imageAttachmentsSupported` appears in `src/tui/repl.zig`.

## Resolution

Two pure helpers in `src/tui/repl.zig`, both decidable without a filesystem or
a live provider:

- `imageMimeForPath` returns the MIME type an extension names, or null. It
  knows exactly the four the wire encoder already knew how to label (png, jpg,
  jpeg, webp), matched case-insensitively so `SHOT.PNG` attaches. The old
  `else "image/png"` fallback is gone: guessing wider bought nothing but an
  opaque provider 400 a whole turn later.
- `attachGate` applies the type rule, then `modules.multimodal`, then the
  model's `image_in`. Type first, because a PDF is the wrong thing to attach
  whatever the model is, and saying so is more use than complaining about
  vision support.

The `.attach` arm consults the gate and refuses with a line naming the reason,
including the provider/model pair for the vision case and the config knob for
the multimodal case, the way `src/cli.zig` names both in its 400.

The capability rule itself moved to `config.Model.supportsImageInput`, and
`cli.zig`'s `imageAttachmentsSupported` now delegates to it. It had to move
somewhere shared rather than be copied: `cli.zig` imports `tui/repl.zig`, so
the TUI cannot reach into the HTTP gate's copy.

The submit drain also refuses a path `imageMimeForPath` does not recognise,
rather than trusting the attach-time gate: a queue outlives a rename.

## Verification

Unit tests `attachGate refuses non-images, multimodal off, and text-only
models` and `imageMimeForPath never fabricates a type` (`src/tui/repl.zig`).
The gate test covers all three refusals, their precedence, a model with no
declared capabilities (still attempted, matching the run gate), and a dot in a
directory name not counting as the file's extension.

`clanker gate` green on all twelve checks.

Live, over a real pty (110x34, TIOCSWINSZ) against deepseek:

- `/attach report.pdf`: the untouched `origin/main` binary printed `attached:
  report.pdf (1 queued)`. The fixed binary prints `attach: only png, jpg, jpeg
  and webp images can be attached; 'report.pdf' was ignored`.
- with `capabilities = ["thinking", "tool_use"]` declared on the active model:
  `attach: deepseek/deepseek-v4-flash does not declare vision support (the
  image_in capability); ...`.
- adding `image_in` to that list: `attached: shot.png (1 queued)`, so the gate
  is not simply refusing everything.
- with `modules.multimodal = false`: `attach: image attachments are disabled;
  enable modules.multimodal in your config`.

## Follow-up

PRD 0041's failure-modes table now carries the three refusals, and `docs/README.md`'s
command table says which types `/attach` takes and when it refuses.

## References

- Investigation: none yet
