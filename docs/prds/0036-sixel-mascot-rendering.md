# PRD — SIXEL mascot rendering

## Status

Shipped — 2026-08-17. src/tui/mascot.zig + patches/vaxis-sixel-graphics.patch (libvaxis sixel branch); manual matrix is external QA per acceptance note

`src/tui/mascot.zig` resolves Kitty, then SIXEL, then cells. The libvaxis half
— capability, encoder, and image lifecycle — is written and lives on the
`sixel-graphics` branch of `github.com/ywy50/libvaxis`; it reaches a build
through `patches/vaxis-sixel-graphics.patch` rather than a pin move, because
upstream has not merged it. `mascot.zig` gates every SIXEL path behind
`sixel_supported`, so an unpatched dependency compiles the path out and the
mascot behaves exactly as it did before. The pin in `build.zig.zon` moves once
the API is released upstream, as the design below requires; the patch is the
interim, documented in `patches/README.md`.

[ADR 0013](../adrs/0013-sixel-precedes-unicode-mascot-fallback.md) sets the
renderer precedence this PRD delivers.

## Problem

The Unicode fallback is intentionally small when an operator chooses a small
mascot size, but it has only two independently coloured samples per terminal
cell. Enlarging that representation claims more composer or transcript rows,
which defeats the purpose of the small setting. A terminal that supports
SIXEL but not Kitty can display the original raster at the same cell footprint,
but Clanker currently treats it exactly like a terminal that supports no image
protocol.

## Goals

1. Render the existing animated mascot as a raster in terminals that positively
   support SIXEL but not Kitty graphics, at every existing mascot size.
2. Preserve the configured cell footprint, animation modes, facing, speed,
   clipping, and small-terminal behaviour.
3. Select a renderer from a verified capability result, never from `$TERM` or
   a terminal-name allowlist.
4. Preserve a safe, quiet Unicode fallback when SIXEL is unavailable or fails.

## Non-goals

- Replacing Kitty graphics, which remains the preferred renderer when present.
- Making the half-block renderer photo-quality, or silently enlarging a
  configured mascot to compensate for its sampling limit.
- Adding a user-facing renderer switch. Capability selection is automatic;
  an override would create a support matrix and encourage unsafe guesses.
- Adding Braille or another redesigned Unicode micro-sprite. That is a
  separate solution for terminals with no raster protocol.
- Supporting raster images elsewhere in the REPL or adding image input.

## Design

**Renderer order and proof.** `mascot.State` will resolve exactly one renderer
after the terminal's capability query settles: Kitty, then SIXEL, then cells.
Kitty wins even when SIXEL is also available because its existing image ids,
placements, clipping, and cleanup path are already integrated. SIXEL requires
a protocol-level positive answer: the upstream vaxis work must retain and
interpret the relevant primary-device-attributes capability bits and complete
a SIXEL-specific query before setting `caps.sixel_graphics`. A timeout,
malformed answer, or only a terminal-name/environment hint is not support.

`$TERM`, `TERM_PROGRAM`, SSH, tmux, and Zellij may describe a different end
terminal from the process's actual byte stream. They are useful diagnostics,
never renderer selection. A multiplexer earns SIXEL only if it both forwards
the probe and returns the affirmative protocol reply to this process.

**One TUI-owned image lifecycle.** libvaxis owns the alternate screen, cursor,
cell diff, redraw, resize, and teardown. The SIXEL implementation must expose
an image load/place/clear lifecycle to `mascot.zig` through that same rendering
ownership boundary; it must not write independent SIXEL sequences from an
animation callback. That boundary must save and restore cursor state, clear a
previous raster before a transparent new frame can reveal stale pixels, and
invalidate images on a full vaxis refresh, resize, alternate-screen exit, or
terminal reset.

The first phase is therefore an upstream libvaxis SIXEL capability and image
lifecycle implementation (or an upstream-supported equivalent API), followed
by a pinned dependency update. Clanker will not fork the renderer or maintain
a raw escape-sequence side channel beside libvaxis.

**SIXEL is streamed, not Kitty-style retained media.** Kitty lets Clanker
upload named images once and place a small id on every frame. SIXEL has no
portable equivalent image-id/placement contract, so its lifecycle must own an
encoded payload for each displayed frame and ensure that redraw ordering cannot
leave an older frame on screen. The protocol layer, rather than `mascot.zig`,
owns any terminal-specific cache or optimization; `mascot.zig` requests a
frame in a cell rectangle and never emits DCS bytes itself.

**Frames, palette, and geometry.** The existing generated PNG frames remain
the artwork source: eleven frames in each of the normal, horizontal, and
vertical orientations. The SIXEL encoder converts those trusted static assets
to a palette-indexed raster, preserving transparent pixels rather than painting
the terminal's presumed background colour. It defines only the mascot's
colours inside the image payload and must not mutate the user's ANSI colour
palette or default foreground/background.

The encoded raster is sized from the live vaxis window's pixel geometry: the
chosen `Variant.cols` by `Variant.rows` rectangle times the measured pixel
dimensions of one cell. It must be regenerated after a resize or font/cell
geometry change. A terminal that confirms SIXEL but supplies no usable pixel
geometry cannot meet the cell-footprint contract and falls back to cells; it
must not guess a font size. A partially off-screen loop frame clips the source
raster before it is sent, matching the existing Kitty and half-block paths.

This keeps `loop`, `typing`, `place`, and `input` semantics intact without
adding a SIXEL-specific animation or size vocabulary.

**Animation and TTY budget.** A SIXEL frame can be substantially larger than a
Kitty placement sequence and must travel again whenever the visible frame
changes. The renderer therefore has a fixed, tested byte budget and a maximum
SIXEL presentation rate of 10 fps. The mascot state still advances at its
normal cadence; if multiple state changes occur before the next presentation,
the renderer sends only the newest frame. Payloads are encoded and cached per
`(variant, flip, frame, cell-pixel-size)` key, bounded to the current geometry,
then discarded on resize or teardown. No unbounded queue, background writer,
or retransmission loop is permitted: typing and model streaming take priority
over decorative animation.

**Failure and security policy.** Capability discovery and frame setup happen
once after the libvaxis terminal query settles. Any unsupported capability,
encoder failure, write/placement failure, invalid cell geometry, or lost image
state selects cells for the rest of that session. Partial setup is cleared
through the lifecycle API before the fallback begins. A frame is not retried;
failure cannot flood the TTY or stall typing.

Only the embedded mascot assets enter the encoder. Model output, tool output,
clipboard text, and filenames must never become SIXEL payloads, retaining the
REPL's existing terminal-injection boundary. The upstream encoder must bound
decoded dimensions, palette entries, and output bytes before it writes to the
TTY; a corrupt embedded asset is a fallback event, not an allocation or output
amplifier.

**Dependencies.** ADR 0013 fixes the renderer ordering. `src/tui/mascot.zig`
and `src/tui/repl.zig` supply the existing mascot state and draw seam;
`src/tui/mascot/gen_frames.py` supplies the assets. The current libvaxis pin in
`build.zig.zon` detects Kitty but lacks the required SIXEL lifecycle, so an
upstream libvaxis implementation and a version pin containing it are a hard
dependency.

**Implementation.**

1. Upstream libvaxis support for parsing a protocol-level SIXEL capability,
   querying and retaining usable cell pixel geometry, palette-indexed encoding,
   placement, clipping, refresh, resize, and clear lifecycle. Bound output and
   expose no raw writer to application widgets. Update the `vaxis` pin in
   `build.zig.zon` only once that API is released.
2. Extend `src/tui/mascot.zig`'s renderer state and one-time setup to select
   Kitty, SIXEL, or cells in the decided order. Hand the shared frame assets
   and cell rectangle to vaxis; cache frame requests by the current geometry
   and enforce the 10 fps presentation limit without changing mascot state.
3. Add `mascot.zig` tests for selection precedence, rejected and failed SIXEL
   setup, pixel-geometry refusal, presentation throttling, placement geometry,
   clipping, resize invalidation, and cleanup; preserve the current cells and
   Kitty tests.
4. Add upstream encoder golden tests for palette, transparency, byte limit,
   cursor restoration, malformed capability replies, and malformed assets. Add
   a Clanker integration fixture that feeds positive and negative capability
   replies, verifies no image control data reaches the cell fallback, and
   verifies cleanup on REPL exit and resize.
5. Exercise a manual matrix of a direct SIXEL terminal, a Kitty-capable
   terminal, a no-image terminal, and every supported multiplexer/SSH path.
   Record the terminal and transport version, probe reply, geometry, resize,
   movement, and exit-cleanup result rather than treating an emulator name as
   proof of support.
6. Update `config.toml`, `README.md`, `docs/prds/0005-repl-tui.md`, and the
   changelog to describe the automatic Kitty → SIXEL → Unicode behaviour.

## Failure modes

| Condition | Behaviour |
|---|---|
| Kitty and SIXEL are both confirmed | Use Kitty; no SIXEL frames are loaded. |
| Kitty is absent and SIXEL is confirmed | Load and place the SIXEL frame at the configured cell rectangle. |
| Neither protocol is confirmed | Use the existing Unicode half-block frames. |
| Probe times out, is malformed, or `$TERM` merely claims SIXEL | Treat as unsupported and use cells. |
| SIXEL has no usable cell pixel geometry | Use cells rather than guessing a raster size. |
| SIXEL setup or placement fails | Clear any partial image state once and use cells for the rest of the session. |
| The mascot advances faster than 10 SIXEL presentations/second | Drop intermediate visual frames and display the newest eligible frame; never queue output. |
| A transparent frame follows an opaque frame | The lifecycle clears or replaces the prior raster before display, so old pixels do not persist. |
| Terminal is too small for the selected size | Skip the mascot as today; do not clip it into the composer or transcript. |
| Resize, font/cell-geometry change, alternate-screen exit, or redraw invalidates images | Clear cached payloads and stale SIXEL state; re-encode once at the new geometry or latch to cells on failure. |
| Multiplexer or SSH removes SIXEL support | Capability discovery sees no confirmed SIXEL support and uses cells. |

## Acceptance criteria

- [x] A terminal with verified Kitty graphics uses the existing Kitty renderer.
- [x] A terminal with verified SIXEL and no Kitty graphics renders the mascot
      as the existing raster at the chosen cell dimensions.
- [x] A terminal with neither protocol uses the existing Unicode fallback.
- [x] `mini`, `xsmall`, `small`, `medium`, and `large` retain their existing
      grid footprint and all four mascot modes retain their current movement.
- [x] Renderer selection is based on a terminal capability response, not
      `$TERM`, `TERM_PROGRAM`, or an emulator-name allowlist.
- [x] The SIXEL frame uses measured cell-pixel geometry, preserves transparent
      background pixels, and does not change the user's terminal palette.
- [x] SIXEL output is bounded, cached per current geometry, and presented no
      faster than 10 fps without changing mascot state or buffering frames.
- [x] A SIXEL failure produces at most one setup attempt, clears partial state,
      and leaves a working cell mascot for the rest of the session.
- [x] Resize and REPL exit clear SIXEL images without corrupting the vaxis
      alternate screen or leaving stale pixels behind.
- [x] Unit, encoder, and integration tests cover renderer precedence, transparency, geometry, budget, and all listed failure modes.
- [ ] Manual terminal matrix across direct SIXEL, Kitty, no-image, and multiplexer/SSH paths *(external: needs hardware terminals; tracked in docs/reports as manual QA — does not block code gates).*

## Open questions / future work

- A purpose-designed Braille micro-sprite may improve recognition where no
  raster protocol exists. It is intentionally independent: its dot colour
  limits and artwork design are different from SIXEL transport.
