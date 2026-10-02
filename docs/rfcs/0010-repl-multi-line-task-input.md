# RFC 0010 — REPL multi-line task input

## Status

Decided — 2026-08-17. ADR 0022

## Overview

vxfw.TextField is single-line; Enter always submits. Users cannot compose multi-paragraph tasks without bracketed paste folding. Need a deliberate input affordance (Shift+Enter, Alt+Enter, or modal) and a newline representation that survives submit history and the agent task boundary.

**Decision to make.** Which UX for deliberate multi-line input in the vaxis REPL and how are embedded newlines represented through submit/history/agent?

**Why now.** ROADMAP Planned and PRD 0005 list single-line-only as the next REPL gap.

**Drivers.** Must stay vaxis-native (no C dep), preserve Enter-to-submit muscle, not break existing paste-folding, keep sanitize/width/theme handling.

**Out of scope.** Image/multimodal, block-level markdown (already RFC 0009/ADR 0021), plan-mode wiring.

## Current state

`src/tui/repl.zig` uses single-line `vxfw.TextField`; Enter always submits and literal newlines only appear via bracketed-paste CR/LF folding. Pasted multi-line turns into one logical transcript row with spacing.

## Options considered

### Option A — Shift+Enter inserts newline, Enter still submits (in composer)

- **What it is:** Bind Shift+Enter (and Alt+Enter as fallback) in the composer to insert a literal newline marker; display as wrapped second visual line.
- **Maturity:** Common in chat UIs; vaxis already maps modified Enter.
- **How it would fit:** `src/tui/repl.zig` key handler + TextField model change to store newlines internally, submit joins with "\n".
- **Pros:** Preserves Enter=submit, discoverable, matches web compose.
- **Cons:** Needs TextField to become multi-line aware.
- **Cost to adopt:** Moderate — widget + style/wrap changes.
- **Cost to leave:** Revert handler.
- **Evidence:** `vxfw.TextField` single-line today — verified in tree.

### Option B — Modal editor (open-on-demand)

- **What it is:** Hotkey opens a small overlay editor with its own buffer; OK pastes into composer as one task with newlines.
- **Maturity:** Simple overlay widget pattern already in codebase.
- **How it would fit:** New widget + key routing change; less invasive to TextField.
- **Pros:** No change to single-line TextField semantics.
- **Cons:** Extra step, less fluid.
- **Cost to adopt:** New widget + overlay plumbing.
- **Cost to leave:** Remove widget.
- **Evidence:** Overlays exist in `src/tui/repl.zig` modal paths — verified.

### Option C — Heredoc/paste-mode helper (explicit)

- **What it is:** Helper command like `/paste` that reads stdin lines until a terminator, or bracketed paste already folded.
- **Maturity:** Use what exists.
- **How it would fit:** Minimal code.
- **Pros:** No UI change.
- **Cons:** Not discoverable as interactive input; poor UX for ad-hoc multiline.
- **Cost to adopt:** Trivial.
- **Cost to leave:** Nothing.
- **Evidence:** Paste folding already in `repl.zig:submit` — verified.

### Option D — status quo

## Implications by horizon

### Short term (this release / 0–3 months)

- **If A:** Multiline tasks become natural in REPL.
- **If B:** Achievable but modal friction remains.
- **If C/D:** Status quo; paste remains the only path.

### Medium term (3–12 months)

- **If A:** Cleaner agent tasks for repo-pasting workflows.
- **If B:** Two UX paths to maintain.
- **If D:** No change.

### Long term (12+ months)

- **If A:** Foundation for richer compose (slash, mentions).
- **If B:** May still need A later.
- **If D:** Permanent gap.

## Recommendation

**Recommended option:** Adopt Option A — Shift+Enter inserts newline in composer, Enter still submits

**Confidence:** 7/10

**Why this confidence.** The one open question, the vaxis signal for Shift+Enter, was answered by the terminal rather than by us: the kitty keyboard protocol reports the modifier, and terminals without it need `kp_enter`, which needed `patches/vaxis-ss3-keypad-enter.patch` to arrive as a distinct key at all. That fallback is why this sits at 7 rather than higher: on an older terminal the binding is a second key that does not exist there, which is a worse failure than no multi-line input at all. A terminal matrix covering the keypad path would raise this.

**Rationale.** Direct chat-like UX with minimal indirection, preserves Enter-to-submit, vaxis-mappable; keeps scope to one widget change. B adds modal friction, C does not deliver deliberate multi-line composition.

**Reversibility.** A composer behaviour, not a format. Undoing it means Enter inserts a newline and some other key submits, and nothing saved or written depends on which. The narrow point of no return is the marker: the composer field holds breaks as `newline_marker`, so a saved draft or history entry written by one build is misread by a build that lacks it. That is why the marker is decoded by `takeComposerText` and never rendered as a glyph.

## Open questions

- vaxis signal for Shift+Enter vs. Alt+Enter — verify key mapping.

## Next steps / action items

- [ ] PRD for REPL multi-line input; ADR; impl in `src/tui/repl.zig`.
