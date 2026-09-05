# ADR 0013 — SIXEL precedes Unicode cells for mascot rendering

## Status

Accepted. Implemented 2026-08-17 as
[PRD 0036](../prds/0036-sixel-mascot-rendering.md).

## Context

The REPL mascot currently has two paths: full-colour PNG frames through kitty
graphics, and Unicode half-block cells when kitty graphics are unavailable.
The latter is deliberately compact — particularly the `mini` and `xsmall`
sizes — but it has only two independently coloured samples per terminal cell.
Making it larger improves recognition by spending more terminal rows; it does
not improve the intentionally small layout.

Some terminals support SIXEL raster graphics but not kitty graphics. SIXEL can
place the original raster at the configured cell dimensions, retaining the
compact layout and most of the visual fidelity of the kitty path. A `$TERM`
name is not a capability signal: terminal emulators, SSH, and multiplexers can
all change what reaches the application. The current pinned libvaxis version
detects kitty graphics but does not expose a SIXEL image lifecycle.

## Decision

Add a SIXEL mascot renderer once the TUI has a positively detected,
lifecycle-safe SIXEL image path. Rendering precedence is kitty graphics first,
then SIXEL, then the existing Unicode half-block cells. A failed SIXEL setup
latches to the cell renderer for the session; it must not retry or emit raw
escape sequences during every animation frame.

The existing `mascot`, `mascot_size`, mode, facing, and speed configuration
remain unchanged. Selection is automatic from verified terminal capability,
not a user-maintained terminal-name list.

## Consequences

- SIXEL-capable non-Kitty terminals gain a faithful compact mascot without
  consuming extra composer or transcript rows.
- Terminals without a verified SIXEL path keep the present portable,
  dependency-free half-block rendering.
- The TUI must gain or adopt image lifetime support that cooperates with
  libvaxis's alternate screen, redraw, clipping, resize, and cleanup paths.
  The delivery work is specified in [PRD 0036](../prds/0036-sixel-mascot-rendering.md).
- This does not make a terminal with neither Kitty nor SIXEL display a
  high-resolution raster. A separate Braille micro-sprite remains a possible
  future improvement to the Unicode path.
