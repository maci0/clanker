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
  ok-deep: "#0a7a2e"
  warn: "#b45309"
  warn-deep: "#9a7a0a"
  danger: "#dc2626"
  violet: "#7c3aed"
  code-bg: "#0d1117"
  code-fg: "#e6edf3"
  lamp-highlight: "#ffffff"
  shadow: "rgba(0,0,0,0.08)"
  shadow-soft: "rgba(0,0,0,0.06)"
  shadow-deep: "rgba(0,0,0,0.12)"
  shadow-blue: "rgba(9,30,66,0.25)"
  shadow-blue-soft: "rgba(9,30,66,0.15)"
  dark-bg: "#171717"
  dark-surface: "#212121"
  dark-surface-2: "#2f2f2f"
  dark-fg: "#ececec"
  dark-fg-muted: "#9ca3af"
  dark-accent: "#7aa7ff"
  mocha-bg: "#181825"
  mocha-surface: "#1e1e2e"
  mocha-surface-2: "#313244"
  mocha-fg: "#cdd6f4"
  mocha-accent: "#cba6f7"
  tokyonight-bg: "#1a1b26"
  tokyonight-surface-2: "#292e42"
  tokyonight-fg: "#c0caf5"
  tokyonight-accent: "#9d7cd8"
  # Board card covers / labels (Kanban color chips)
  cover-orange: "#c45a0a"
  cover-red: "#c41212"
  cover-purple: "#6b2fb8"
  cover-blue: "#0b5ab8"
  cover-sky: "#2a8ecc"
  cover-pink: "#c23a7a"
  label-green: "#22a24a"
  label-yellow: "#c9a50a"
  label-orange: "#e07a1a"
  label-red: "#c62828"
  label-purple: "#6a3db8"
  label-blue: "#3d8af0"
  label-sky: "#5ab5e8"
  label-pink: "#e85a9a"
  label-lime: "#6ab82f"
  # Arena / fleet / schedule CSS+canvas fallbacks when tokens unset
  lamp-ok: "#2fae4d"
  lamp-running: "#e5b54a"
  danger-short: "#d33"
  canvas-border: "#343b3f"
typography:
  micro:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "9px"
    fontWeight: 600
  caption:
    fontFamily: "ui-sans-serif, system-ui, sans-serif"
    fontSize: "10px"
    fontWeight: 500
  dense:
    fontFamily: "ui-sans-serif, system-ui, sans-serif"
    fontSize: "11px"
    fontWeight: 500
  label:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "0.6875rem"
    fontWeight: 600
    letterSpacing: "0.06em"
  step0:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "0.8125rem"
    fontWeight: 400
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
  body:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, sans-serif"
    fontSize: "0.9375rem"
    fontWeight: 400
    lineHeight: 1.55
  ui:
    fontFamily: "ui-sans-serif, system-ui, sans-serif"
    fontSize: "16px"
    fontWeight: 400
  title:
    fontFamily: "ui-sans-serif, system-ui, sans-serif"
    fontSize: "1.0625rem"
    fontWeight: 600
    lineHeight: 1.3
  lead:
    fontFamily: "ui-sans-serif, system-ui, sans-serif"
    fontSize: "18px"
    fontWeight: 600
  feature:
    fontFamily: "ui-sans-serif, system-ui, sans-serif"
    fontSize: "20px"
    fontWeight: 600
  display-sm:
    fontFamily: "ui-sans-serif, system-ui, sans-serif"
    fontSize: "1.15rem"
    fontWeight: 600
  display:
    fontFamily: "ui-sans-serif, system-ui, sans-serif"
    fontSize: "1.3rem"
    fontWeight: 600
rounded:
  hairline: "2px"
  tight: "4px"
  xs: "3px"
  sm: "6px"
  control: "8px"
  soft: "9px"
  md: "10px"
  panel: "12px"
  lg: "14px"
  bubble: "18px"
  composer: "24px"
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
  rail-tab:
    backgroundColor: "transparent"
    textColor: "{colors.fg-muted}"
    rounded: "{rounded.md}"
    height: "32px"
  rail-tab-selected:
    backgroundColor: "{colors.surface-2}"
    textColor: "{colors.fg}"
    rounded: "{rounded.md}"
  rail-new:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.on-accent}"
    rounded: "{rounded.pill}"
    height: "36px"
  composer:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.composer}"
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
- **Held / OK** (#117a3a), **Warn** (#b45309), **Fault** (#dc2626), **Violet** (#7c3aed) for special states
- Deep lamp fills (`ok-deep`, `warn-deep`) for denser status chips
- Arena/schedule lamp fallbacks: `lamp-ok` #2fae4d, `lamp-running` #e5b54a, `danger-short` #d33
- Canvas theme fallback border: `canvas-border` #343b3f (arena/fleet when `--border` unset)

### Board chips
Kanban cover and label swatches are fixed brand chips (not theme tokens):
covers `cover-orange`…`cover-pink`; labels `label-green`…`label-lime` (see frontmatter).

### Named themes
Catppuccin / Tokyo Night / hackerman / frappe / etc. live as full
`:root[data-theme="…"]` blocks in `ui/app/app.css`. Frontmatter lists the
mocha and tokyonight anchors used most often; other named ramps stay in CSS.
System dark applies only when `data-theme` is absent
(`:root:not([data-theme])` under `prefers-color-scheme: dark`).

### Named Rules
**The Lamp Rule.** Status colour lives in lamps and chips, not in large washes.
**The Token Bridge Rule.** PatternFly globals (`--pf-t--global-*`) and button
component vars must remap to cabinet tokens so theme flips never leave light
greys on dark panels. Masthead `chip-btn` controls and the composer Run/Cancel
buttons stay off `pf-v6-c-button` so PF brand colours cannot override `--accent`.
Rail tabs stay off `pf-v6-c-nav__link` for the same reason. Each `data-theme`
sets `color-scheme: light|dark` to match.

## Typography

**Body Font:** system UI sans  
**Label/Mono Font:** system UI mono (legend plates, chips, measurements)

**Character:** Engraved mono for the panel; readable sans for conversation.

CSS steps: `--step--1` 0.6875rem, `--step-0` 0.8125rem, `--step-1` 0.9375rem,
`--step-2` 1.0625rem, `--step-3` 1.25rem.

### Hierarchy
- **Title** (600, ~1.06rem): view headings
- **Body** (400, ~0.94rem, 1.55): transcript and forms; measure ~70ch
- **UI / lead** (16px / 18px): denser app chrome and empty-state titles
- **Label** (600, ~0.69rem, tracked caps where engraved): rail groups, chips
- **Dense** (11px): meta rows and compact toolbars

## Layout

- Shell: masthead + rail + main
- Rail fixed ~15rem; drawer below 40rem
- Main content centered; chat measure capped (~46rem)
- Breakpoints in rem (40rem phone drawer, 48rem rooms sidebar)
- Coarse pointer and narrow viewports: 44px minimum for rail tabs, New chat,
  pins, session actions, chat message actions, chips, and composer submit/voice

## Elevation & Depth

`--lift` / `--lift-high`: soft offset shadows on raised actuators and overlays.
Blue-tinted soft shadows (`shadow-blue*`) appear on a few raised PF-adjacent
surfaces. Surfaces stack by token (bg → surface → surface-2), not by blur glass.

## Shapes

- Panels: 6–14px (`sm` / `md` / `lg`) plus `panel` 12px where a mid step is needed
- Dense controls: `hairline` 2px, `tight` 4px, `xs` 3px, `control` 8px, `soft` 9px
- Actuators and composer: pill / 24px soft capsule (`composer`)
- Chat bubbles: 18px (`bubble`)
- Lamps: full circle

## Components

- **Primary button**: accent fill, on-accent text, pill
- **Secondary**: surface + border
- **Plain / chip-btn**: muted text, transparent; masthead chrome
- **Rail tab**: engraved row + lamp when selected (`appearance: none`)
- **Rail new**: accent CTA; 44px tall under 40rem / coarse pointer
- **Composer**: sticky capsule with focus-within lift
- **Model picker**: combobox + listbox popover (not a modal dialog). Arrow keys
  move `aria-activedescendant`; Tab dismisses and moves to the next control;
  Escape returns focus to the trigger pill
- **Overlay**: PF backdrop + modal box; focus trapped

## Do's and Don'ts

**Do**
- Remap PF brand/icon/on-brand tokens when adding themes
- Keep blue for operator action only
- Test contrast in dark and named themes after PF upgrades
- Prefer documented radius/type steps over new literals
- Document new board/arena hex in frontmatter when you add chip colours

**Don't**
- Paint masthead chips with `pf-m-primary`
- Use side-tab accent borders on cards (blockquote/thread indents are content structure, not card chrome)
- Restore rail collapsed state from localStorage on load (icon-rail flash)
- Hand-carve `patternfly.min.css` in a polish pass; subsetting is a measured optimize task
- Give model-picker options a tab stop; arrows own that list