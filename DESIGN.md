---
name: clanker
description: Control-cabinet operator panel for a sandboxed AI agent harness
colors:
  paper: "#ffffff"
  bg: "#f7f7f8"
  surface: "#ffffff"
  surface-2: "#f4f4f5"
  border: "#e5e5e5"
  rule: "#ececec"
  fg: "#0d0d0d"
  fg-muted: "#555c67"
  accent: "#0b57d0"
  on-accent: "#ffffff"
  ok: "#117a3a"
  warn: "#b45309"
  danger: "#dc2626"
  violet: "#7c3aed"
  dark-bg: "#171717"
  dark-surface: "#212121"
  dark-fg: "#ececec"
  dark-fg-muted: "#9ca3af"
  dark-accent: "#7aa7ff"
typography:
  body:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, sans-serif"
    fontSize: "0.9375rem"
    fontWeight: 400
    lineHeight: 1.55
  step0: "0.8125rem"
  step1: "0.9375rem"
  step2: "1.0625rem"
  label:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "0.6875rem"
    fontWeight: 600
    letterSpacing: "0.06em"
  chip:
    fontFamily: "ui-sans-serif, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 500
  rail:
    fontFamily: "ui-sans-serif, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 500
  button:
    fontFamily: "ui-sans-serif, system-ui, sans-serif"
    fontSize: "14px"
    fontWeight: 600
  title:
    fontFamily: "ui-sans-serif, system-ui, sans-serif"
    fontSize: "1.0625rem"
    fontWeight: 600
    lineHeight: 1.3
rounded:
  sm: "6px"
  md: "10px"
  lg: "14px"
  pill: "999px"
spacing:
  1: "0.25rem"
  2: "0.4rem"
  3: "0.6rem"
  4: "0.9rem"
  5: "1.4rem"
  6: "2.2rem"
components:
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.on-accent}"
    rounded: "{rounded.pill}"
    padding: "0.5rem 1.05rem"
    height: "40px"
  button-secondary:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.fg}"
    rounded: "{rounded.pill}"
    padding: "0.4rem 0.8rem"
  button-plain:
    backgroundColor: "transparent"
    textColor: "{colors.fg-muted}"
    rounded: "{rounded.pill}"
    height: "32px"
  chip:
    backgroundColor: "{colors.surface-2}"
    textColor: "{colors.fg-muted}"
    rounded: "{rounded.sm}"
    padding: "0.15rem 0.55rem"
  composer:
    backgroundColor: "{colors.surface}"
    rounded: "24px"
    padding: "0.55rem 0.7rem 0.45rem"
---

# Design System: clanker

## Overview

**Creative North Star: "The Control Cabinet"**

clanker’s web UI is the switchgear panel for a fleet of small machine workers.
The vocabulary is literal: RAL-grey panel faces on a backplane, engraved mono
legend plates, and IEC 60073 indicator lamps (green healthy, amber abnormal,
red fault, blue operator action). Blue is the interactive colour because the
standard already assigns it.

One boldness, spent in one place: the lamps. Radial-gradient domes that glow
when something is live. Everything else stays flat and disciplined.

Day shift (light grey cabinet) is default; night shift (graphite) and named
palettes (Catppuccin, Tokyo Night, hackerman) remap the same tokens.

**Key Characteristics:**
- Operate mode: scanability over spectacle
- Tokens own color; PatternFly supplies structure only
- Mono for measurements and legends; sans for prose
- Depth is offset+blur lift, never a zero-offset halo

## Colors

IEC lamp semantics plus one operator blue. Neutrals carry the cabinet; accent
is rare and actionable.

### Primary
- **Operator Blue** (#0b57d0): primary actions, focus rings, engaged-channel lamp. Dark: #7aa7ff.

### Neutral
- **Paper / Surface** (#ffffff / #f7f7f8): panel faces and backplane
- **Ink** (#0d0d0d): body text
- **Muted engraving** (#555c67): secondary labels (dark: #9ca3af)
- **Rule** (#ececec): seams between jobs

### Semantic
- **Held / OK** (#117a3a), **Warn** (#b45309), **Fault** (#dc2626), **Violet** (#7c3aed) for AI-answer / special states

### Named Rules
**The Lamp Rule.** Status colour lives in lamps and chips, not in large washes.
**The Token Bridge Rule.** PatternFly globals (`--pf-t--global-*`) and button
component vars must remap to cabinet tokens so theme flips never leave light
greys on dark panels. Masthead `chip-btn` controls and the composer Run/Cancel
buttons stay off `pf-v6-c-button` so PF brand colours cannot override `--accent`.
Each `data-theme` sets `color-scheme: light|dark` to match.

## Typography

**Body Font:** system UI sans  
**Label/Mono Font:** system UI mono (legend plates, chips, measurements)

**Character:** Engraved mono for the panel; readable sans for conversation.

### Hierarchy
- **Title** (600, ~1.06rem): view headings
- **Body** (400, ~0.94rem, 1.55): transcript and forms; measure ~70ch
- **Label** (600, ~0.69rem, tracked caps where engraved): rail groups, chips

## Layout

- Shell: masthead + rail + main
- Rail fixed ~15rem; drawer below 40rem
- Main content centered; chat measure capped (~46rem)
- Breakpoints in rem (40rem phone drawer, 48rem rooms sidebar)
- Coarse pointer and narrow viewports: 44px minimum targets for rail, chips, submit

## Elevation & Depth

`--lift` / `--lift-high`: soft offset shadows on raised actuators and overlays.
Surfaces stack by token (bg → surface → surface-2), not by blur glass.

## Shapes

- Panels: 6–14px radius
- Actuators and composer: pill / 24px soft capsule
- Lamps: full circle

## Components

- **Primary button**: accent fill, on-accent text, pill
- **Secondary**: surface + border
- **Plain / chip-btn**: muted text, transparent; masthead chrome
- **Rail tab**: engraved row + lamp when selected
- **Composer**: sticky capsule with focus-within lift
- **Overlay**: PF backdrop + modal box; focus trapped

## Do's and Don'ts

**Do**
- Remap PF brand/icon/on-brand tokens when adding themes
- Keep blue for operator action only
- Test contrast in dark and named themes after PF upgrades

**Don't**
- Paint masthead chips with `pf-m-primary`
- Use side-tab accent borders on cards (blockquotes/thread indents are content structure, not card chrome)
- Restore rail collapsed state from localStorage on load (icon-rail flash)
