# ADR 0023 — REPL image/multimodal input via /attach and drag-drop to image_in

## Status

Accepted — 2026-08-17. Records the decision opened in [RFC 0011 — REPL image/multimodal input](../rfcs/0011-repl-image-multimodal-input.md).

## Context

REPL has no image path; web UI does via image_in. Multimodal tasks need a native REPL surface.

Options in RFC 0011: A /attach+DnD→image_in, B path-as-text→read_file, C modal picker, D status quo.

## Decision

REPL gains an /attach command plus drag-drop/paste that populate an images buffer; on submit the buffer travels as the existing agent image_in channel alongside text, mirroring the web composer.

> The RFC recommended: **Recommended option:** Adopt Option A — /attach plus drag-drop/paste into an images buffer sent as image_in




## Consequences

Web-like ergonomics at the terminal; vaxis drag/clipboard plumbing and image size gating add surface to own. Reversible: remove /attach and buffer. Option B would still require file-read via the agent; Option C's modal is heavier.


