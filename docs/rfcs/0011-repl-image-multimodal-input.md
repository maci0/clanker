# RFC 0011 — REPL image/multimodal input

## Status

Decided — 2026-08-17. ADR 0023

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

Web UI has an image attachment path (webui-plan 1.3, media-src blob:). The vaxis REPL has no route for a task that needs an image — users must leave the REPL or use the web UI. Decide the attachment surface for  and how binary payloads reach the agent.

**Decision to make.** Which input surface do we adopt for image/multimodal attachments in the vaxis REPL (`clanker repl`), and how do binary payloads travel through the agent task boundary to the LLM?

**Why now.** ROADMAP Planned and PRD 0005 list REPL image input as the next multimodal gap; the web UI already has an attachment path (webui-plan 1.3) but the REPL has no way for `do X with this screenshot` tasks.

**Drivers.** Must stay vaxis-native, no extra runtime sandbox escape, reuse the existing `image_in` agent capability that the web UI already drives (multipart/vision), keep control-stripping and theme reuse, and not require a new external dependency.

**Out of scope.** Block-level markdown and multi-line input (separate RFC/PRD 0009/0010), full plan-mode workflow (body unchanged), and video/PTy concerns.

## Current state

The vaxis REPL (`src/tui/repl.zig`) has no image path: tasks are `TextField` text only; images via drag/drop or clipboard are ignored. `clanker run` and the web composer both send images as `image_in` to the agent. Files changed would be `src/tui/repl.zig` (and possibly `src/agent/*` plumbing to propagate the new input) plus docs. The workaround today is to paste an image path as text and hope the agent can read the file, which is inconsistent and privatized to `read_file`.

## Options considered

One subsection per option. Include the status quo ("do nothing / keep the
workaround") and at least one *out-of-the-box* option — something already in
the tree, a standard-library or OS primitive, an existing tool used differently,
or buying instead of building. An RFC with only the two obvious libraries has
not finished looking.

### Option A — `/attach <path>` command + drag-drop/paste that populates an `images` list sent as `image_in`

- **What it is:** REPL adds an `/attach` slash command that validates a local path and queues it as an image attachment; drag-drop or image paste onto the REPL auto-populates the same list; on submit the list travels with the task via the existing agent `image_in` channel that the web UI already uses.
- **Maturity:** Pattern already proven by web composer image input.
- **How it would fit:** Adds an `images` buffer to `src/tui/repl.zig:Model`, extends the input handler to recognize drops/pastes, and extends `submitTask` to send `image_in` alongside text; reuses file-read validation and control-strip.
- **Pros:** Parity with web UI; uses existing LLM plumbing (no new transport).
- **Cons:** Needs vaxis DnD/clipboard plumbing and image size caps.
- **Cost to adopt:** REPL-only, medium.
- **Cost to leave:** Remove `/attach` and buffer.
- **Evidence:** Web image path exists — `ui/app/app.js` webui-plan 1.3 — verified in tree.

### Option B — Require paths-as-text and fetch via `read_file`

- **What it is:** User pastes a filesystem path; the REPL does nothing special and the agent reads the file as a tool call if it wants an image.
- **Maturity:** Works today with no code change, but relies on the agent deciding to call `read_file` and understanding image bytes.
- **How it would fit:** No REPL change; maybe a hint line in the transcript.
- **Pros:** No new input plumbing.
- **Cons:** Inconsistent UX, agent-dependent, no drag/drop fidelity.
- **Cost to adopt:** Near-zero.
- **Cost to leave:** Nothing.
- **Evidence:** No REPL attachment today — verified.

### Option C — Dedicated modal image picker widget (overlay)

- **What it is:** Open a modal gallery to select images; OK attaches them.
- **Maturity:** New UI surface; more chrome.
- **How it would fit:** Overlay widget + key routing.
- **Pros:** Discoverable picker UI.
- **Cons:** Extra step; larger widget surface.
- **Cost to adopt:** Higher than Option A.
- **Cost to leave:** Remove overlay.
- **Evidence:** Overlays exist in `repl.zig` modal paths — verified.

### Option D — status quo

- **What it is:** keep doing what we do today.
- **Pros:**
- **Cons:**
- **Cost to adopt:** zero now; state what it costs later.
- **Evidence:**

## Implications by horizon

What following each candidate means over time. Where the options differ only in
one horizon, say so — that is usually the deciding fact.

### Short term (this release / 0–3 months)

- **If A:** Users can attach screenshots directly from the REPL.
- **If B:** Users still need to type paths; inconsistent.
- **If D:** Gap remains.

### Medium term (3–12 months)

- **If A:** Parity with web UI simplifies docs and tooling.
- **If B:** More support questions about path handling.
- **If D:** Gap accumulates.

### Long term (12+ months)

- **If A:** Foundation for richer multimodal workflows (drag/paste uniformity).
- **If B:** Would still want A later.
- **If D:** Permanent blocker for image tasks in the REPL.

## Recommendation

**Recommended option:** Adopt Option A — /attach plus drag-drop/paste into an images buffer sent as image_in

**Confidence:** 7/10

**Why this confidence.** _State what evidence would raise it, and what finding would sink this recommendation._

**Rationale.** Achieves web-composer parity by reusing the existing agent image_in transport; Option B leaves UX inconsistent and agent-dependent, Option C adds unnecessary modal weight.

**Reversibility.** _How hard is this to undo, and where is the point of no return?_

## Open questions

- Max image size and type gating — mirror web limits?
- Clipboard/drag payload MIME handling on different terminals — verify via spike.

## Next steps / action items

- [ ] PRD checklist; ADR; implement A in `src/tui/repl.zig`.
- [ ] Verify drag-drop/paste reachability in vaxis event stream.

## References



- Related ADRs, PRDs, reports, and prior RFCs.
- External sources, each with what it supports.

## Appendix

Optional: benchmark output, diagrams, licence texts, transcript excerpts, and
anything else too long for the body but needed to re-check the reasoning.
