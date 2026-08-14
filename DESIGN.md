---
name: clanker
description: Control-cabinet operator UI for a self-improving AI agent harness
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
  accent-text: "#0b57d0"
  on-accent: "#ffffff"
  ok: "#117a3a"
  ok-fill: "#16a34a"
  violet: "#7c3aed"
  violet-text: "#6d28d9"
  danger: "#dc2626"
  on-danger: "#ffffff"
  warn: "#b45309"
  warn-text: "#92400e"
  code-bg: "#0d1117"
  code-fg: "#e6edf3"
  dark-bg: "#171717"
  dark-surface: "#212121"
  dark-fg: "#ececec"
  dark-accent: "#7aa7ff"
typography:
  sans:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, sans-serif"
    fontSize: "0.9375rem"
    fontWeight: 400
    lineHeight: 1.55
    letterSpacing: "normal"
  mono:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "0.8125rem"
    fontWeight: 500
    lineHeight: 1.45
    letterSpacing: "0.02em"
  legend:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "0.6875rem"
    fontWeight: 700
    lineHeight: 1.3
    letterSpacing: "0.1em"
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
  7: "3.4rem"
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
  chip-btn:
    backgroundColor: "transparent"
    textColor: "{colors.fg-muted}"
    rounded: "{rounded.pill}"
    height: "32px"
  rail-tab:
    backgroundColor: "transparent"
    textColor: "{colors.fg-muted}"
    rounded: "{rounded.md}"
    height: "32px"
---

## Overview

clanker’s web UI is a control cabinet, not a dark agent console or a paper log.
Vocabulary comes from real switchgear: RAL-grey panel faces, engraved mono
legend plates, and IEC 60073 lamps (green healthy, amber abnormal, red fault,
blue for operator action). PatternFly v6 supplies page shell, nav, buttons,
forms, and overlays; domain surfaces (transcript, board cards, run graph)
keep cabinet CSS. Blue is the interactive accent because the standard already
assigns it to operator action.

## Colors

Semantic roles live in CSS custom properties on `:root` and named themes
(`light`, `dark`, `mocha`, Catppuccin variants, Tokyo Night, `hackerman`).
Light defaults:

| Role | Token | Value |
|------|-------|-------|
| Canvas | `--bg` | `#f7f7f8` |
| Panel | `--surface` / `--surface-2` | `#ffffff` / `#f4f4f5` |
| Text | `--fg` / `--fg-muted` | `#0d0d0d` / `#555c67` |
| Action | `--accent` | `#0b57d0` |
| Success | `--ok` | `#117a3a` |
| Warning | `--warn` | `#b45309` |
| Danger | `--danger` | `#dc2626` |
| Info / AI tag | `--violet` | `#7c3aed` |

Lamps glow with radial gradients on status chips; do not use gradients for AI
chrome, chat bubbles, or progress. AI disclosure tags and robot avatars must
use `--violet` / `--chat-hue-2`, never one-off hex.

## Typography

Prose uses `--sans` (system UI stack). Measurements, legend plates, session
ids, and tool names use `--mono`. Type scale: `--step--1` through `--step-3`.
Body measure targets `--measure` (70ch). Do not load PatternFly Red Hat
webfonts; the cabinet face is the system stack.

## Layout

Shell: PatternFly `pf-v6-c-page` with sticky masthead, vertical rail nav, and
main content. Chat column max-width ~46rem; board/runs wider. Breakpoints in
rem (`40rem`, `48rem`, `60rem`). Under `60rem` the rail becomes a drawer.
Touch targets: 32px minimum on fine pointers; 44px under `pointer: coarse`
and for primary composer actions on narrow viewports.

## Elevation & Depth

Panels sit flat on the backplane. Depth uses offset+blur shadows
(`--lift`, `--lift-high`), never zero-offset colored halos. Live state is
shown by lamp glow, not card elevation.

## Shapes

Control radii: `--radius-sm` 6px, `--radius` 10px, `--radius-lg` 14px.
Actuators and chips are pills (`--radius-pill`). Prefer machined edges over
soft marketing cards.

## Components

- **Primary button / Run with AI:** accent fill, pill, ≥40px (44px coarse).
- **Secondary / chip-btn:** transparent or surface, muted text; PF plain
  chips must keep min 32×32 (never `min-height: auto`).
- **Rail tabs:** mono legends with a lamp on the selected channel.
- **Composer:** sticky cabinet panel above the fold; AI review notice under it.
- **Assistant turns:** robot avatar + sparkle + “AI-assisted response” + AI tag.
- **Toasts / modals / forms:** PatternFly components restyled through the
  cabinet token bridge.

## Do's and Don'ts

**Do**

- Spend boldness on lamps and the primary blue actuator.
- Keep AI transparency (banner, review notice, answer labels) visible.
- Prefer WASM guest tools over new native harness UI where possible.
- Honor `prefers-reduced-motion` and `forced-colors`.

**Don't**

- Paint nav/suggestion chips as primary blue pills (legacy button specificity).
- Use special AI gradients or purple-as-brand for the whole chrome.
- Animate layout properties (`width`/`height`) for drawers; use `transform`.
- Relink `patternfly-addons.css` unless you actually use `pf-v6-u-*` utilities.
- Drop PatternFly `@font-face` back in without vendoring the font files.
