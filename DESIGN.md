---
name: clanker
description: A control cabinet for operating a fleet of small machine workers.
colors:
  operator-blue: "#1d5c9e"
  cabinet-backplane: "#dcd9d1"
  cabinet-panel: "#eeebe4"
  cabinet-well: "#e2dfd6"
  cabinet-edge: "#b9b5aa"
  cabinet-rule: "#cdc9bf"
  ink: "#1b1c18"
  muted-ink: "#4f534b"
  healthy-green: "#117a3a"
  warning-amber: "#8a6d00"
  fault-red: "#a72920"
  code-well: "#d4d0c6"
typography:
  title:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, sans-serif"
    fontSize: "1.375rem"
    fontWeight: 600
    lineHeight: 1.3
  body:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, sans-serif"
    fontSize: "1rem"
    fontWeight: 400
    lineHeight: 1.6
  label:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "0.75rem"
    fontWeight: 600
    lineHeight: 1.4
    letterSpacing: "0.06em"
tracking:
  label: "0.06em"
rounded:
  sm: "2px"
  md: "3px"
  lg: "4px"
  pill: "999px"
spacing:
  xs: "0.25rem"
  sm: "0.4rem"
  md: "0.6rem"
  lg: "0.9rem"
  xl: "1.4rem"
  2xl: "2.2rem"
  3xl: "3.4rem"
components:
  button-primary:
    backgroundColor: "{colors.operator-blue}"
    textColor: "#ffffff"
    rounded: "{rounded.pill}"
    padding: "0.5rem 1.05rem"
    height: "40px"
  input:
    backgroundColor: "{colors.cabinet-panel}"
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "0.55rem 0.75rem"
    height: "40px"
  panel:
    backgroundColor: "{colors.cabinet-panel}"
    textColor: "{colors.ink}"
    rounded: "{rounded.lg}"
    padding: "0.9rem"
---

# Design System: clanker

## Overview

**Creative North Star: "The Control Cabinet"**

clanker is an operator surface for a fleet of small machine workers. It borrows literally from industrial switchgear: warm RAL-grey panel faces on a darker backplane, engraved-looking labels, compact actuators, and IEC 60073 signal lamps. The interface is dense because operators scan and act; hierarchy comes from disciplined grouping, typography, and state rather than decorative whitespace.

The signature is the lamp: a radial dome that glows only when state deserves attention. Everything around it stays flat, machined, and restrained. Day shift uses warm cabinet greys; night shift uses graphite surfaces with brighter readings. Named palettes may change the atmosphere but preserve the same semantic roles.

**Key Characteristics:**

- Industrial, tactile, and operator-focused.
- Compact without sacrificing keyboard use or coarse-pointer targets.
- Flat panel geometry with structural depth and restrained motion.
- One semantic color vocabulary across themes and plugins.

## Colors

Warm cabinet neutrals carry the interface; blue is reserved for operator action, while green, amber, and red communicate machine state.

### Primary

- **Operator Blue** (`#1d5c9e`): links, focus, selected controls, and primary actuators.

### Neutral

- **Cabinet Backplane** (`#dcd9d1`): page background.
- **Cabinet Panel** (`#eeebe4`): primary working surfaces.
- **Cabinet Well** (`#e2dfd6`): inset and secondary surfaces.
- **Cabinet Edge** (`#b9b5aa`): strong boundaries.
- **Cabinet Rule** (`#cdc9bf`): internal dividers.
- **Ink** (`#1b1c18`): primary text.
- **Muted Ink** (`#4f534b`): metadata and supporting labels.

### Secondary

- **Healthy Green** (`#117a3a`): healthy and successful state.
- **Warning Amber** (`#8a6d00`): abnormal or cautionary state.
- **Fault Red** (`#a72920`): faults, destructive actions, and failed state.

**The IEC Rule.** Blue means operator action; green means healthy; amber means abnormal; red means fault. Never reuse those colors decoratively.

## Typography

**Display Font:** system sans-serif stack  
**Body Font:** system sans-serif stack  
**Label/Mono Font:** system monospace stack

**Character:** prose stays quiet and native to the host OS. Monospace is reserved for measurements, code, IDs, and engraved control labels—not used as a generic technical costume.

### Hierarchy

- **Title** (600, `1.375rem`): view and panel headings. Untracked: tight tracking is not a cabinet idea.
- **Body** (400, `1rem`, `1.6`): prose, transcript content, and explanations; cap reading measure near `70ch`.
- **Control** (600, `0.875rem`): buttons, inputs, and dense operational rows.
- **Label** (600, `0.75rem`, `--track-label` / `0.06em`): uppercase group labels and compact readings.
- **Micro** (`0.6875rem`): counts and graph stamps only.

**The Engraving Rule.** Use monospace only where alignment, measurement, code, or equipment labeling earns it.

## Layout

The application shell is a fixed masthead, a persistent navigation rail, and one main working surface. The conversation view uses the full available height with an independently scrolling transcript and docked composer. Dense views use flexible grids and wrapping rows; reading content stays near `70ch`.

The core spacing scale is `0.25rem`, `0.4rem`, `0.6rem`, `0.9rem`, `1.4rem`, `2.2rem`, and `3.4rem`. At `40rem` and below, the rail becomes an off-canvas drawer, multi-column views collapse, and primary touch targets rise to `44px`. Intermediate layouts span roughly `40–75rem`; room layouts use an additional `48rem` breakpoint.

## Elevation & Depth

Depth is structural: panel faces sit on a backplane, controls are raised or pressed, and overlays lift clear of the work surface. Shadows use offset and blur, never decorative halos.

### Shadow Vocabulary

- **Seated plate** (`--lift-low`): low separation for rows and cards.
- **Raised control** (`--lift`): menus, active controls, and small floating surfaces.
- **Floating overlay** (`--lift-high`): dialogs and drag state.
- **Machined states** (`--bevel-raised`, `--bevel-inset`, `--bevel-pressed`): actuator and input depth.

**The Structural Depth Rule.** Use a named lift or bevel token; do not invent one-off shadows.

## Shapes

Panels and fields use tight `2–4px` radii, like machined plates rather than soft cards. Pills are reserved for compact actuators, chips, lamps, and status housings. Borders are usually one pixel and use the semantic edge or rule token. PatternFly's radius and glass tokens (`--pf-t--global--border--radius-*`, glass blur, felt wallpaper) remap onto this scale in `ui/app/app.css`; leaving them at the library's 16px/24px defaults reintroduces a soft card on any PF class that still reads those tokens.

## Components

### Buttons

- **Shape:** tight plate or pill, depending on whether the control is a panel action or compact actuator.
- **Primary:** Operator Blue with explicit on-accent text.
- **Hover / Focus:** tonal change plus a two-pixel Operator Blue focus outline.
- **Active:** pressed bevel or a one-pixel travel where appropriate.

### Chips

- **Style:** pill housing with compact mono or control text.
- **State:** pair color with words; lamps are never the sole state indicator.

### Cards / Containers

- **Corner style:** `3–4px`.
- **Background:** Cabinet Panel or Cabinet Well.
- **Shadow strategy:** flat or seated by default; lift only for interaction or hierarchy.
- **Border:** one-pixel Rule or Edge.

### Inputs / Fields

- **Style:** inset cabinet well, readable sans-serif text, tight radius.
- **Focus:** Operator Blue border or inset-safe two-pixel outline.
- **Mobile:** focused fields use at least `16px` text; coarse-pointer controls use `44px` targets.

### Navigation

The rail behaves as a vertical tablist with roving focus and arrow-key navigation. Selected destinations combine an engaged lamp, semantic state, and `aria-selected`; mobile navigation becomes a scrim-backed drawer.

### Signal Lamp

The lamp is the signature component. Use the shared dome, ring, and glow tokens; set its color from the IEC state tokens and repeat the state in text or accessible naming.

## Do's and Don'ts

### Do:

- **Do** use semantic tokens so all named themes remain coherent.
- **Do** keep operational rows dense, scannable, keyboard reachable, and resilient to long text.
- **Do** defer view-specific code and heavy vendor assets until the operator opens that surface.
- **Do** provide reduced-motion alternatives that preserve useful state feedback.

### Don't:

- **Don't** introduce a second blue or unrelated status palette.
- **Don't** use lamps, glow, or monospace as decoration.
- **Don't** round working surfaces into generic soft SaaS cards.
- **Don't** leave PatternFly radius or glass tokens at library defaults.
- **Don't** add one-off shadows, spacing values, or hard-coded theme colors when a token exists.
- **Don't** place new non-chat features on the eager load path without updating and justifying the weight budget.
