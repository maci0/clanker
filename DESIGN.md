---
name: clanker
description: An operations console for a fleet of small machine workers, laid out after Headlamp's Kubernetes UI.
colors:
  accent: "#0072c9"
  accent-text: "#0065b3"
  page: "#f5f5f5"
  surface: "#ffffff"
  surface-2: "#f3f2f1"
  border: "#8a8886"
  rule: "#e1dfdd"
  fg: "#242424"
  fg-muted: "#605e5c"
  ok: "#107c10"
  warn: "#8a6d00"
  danger: "#a4262c"
  rail-bg: "#242424"
  rail-active: "#3b3a39"
  rail-fg: "#f3f2f1"
  rail-muted: "#c8c6c4"
  rail-mark: "#f2e600"
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
    fontFamily: "ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, sans-serif"
    fontSize: "0.75rem"
    fontWeight: 600
    lineHeight: 1.4
    letterSpacing: "0"
rounded:
  sm: "3px"
  md: "4px"
  lg: "6px"
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
    backgroundColor: "{colors.accent}"
    textColor: "#ffffff"
    rounded: "{rounded.lg}"
    height: "40px"
  input:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.fg}"
    rounded: "{rounded.md}"
    height: "40px"
  section-card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.fg}"
    rounded: "{rounded.lg}"
    padding: "0.9rem 1.4rem"
---

# Design System: clanker

## Overview

clanker is an operator surface for a fleet of small machine workers. Its layout follows Headlamp, the Kubernetes UI: a dark sidebar of icon-and-label destinations, a white top bar, a light grey page, and each view's content in white section cards. The interface is dense because operators scan and act; hierarchy comes from grouping and state, not decorative whitespace.

Signal lamps stay: a small radial dome that lights only when state deserves attention. Everything around them is flat and neutral.

The mark, wordmark, icon library, mascot rules and voice live in the [brand guide](docs/brand/README.md). The tokens live in `ui/app/tailwind.src.css`, the page's only stylesheet; this file names them and never overrides them.

## Colors

Neutral greys carry the interface; blue is operator action, and green, amber and red are machine state.

### Primary

- **Accent** (`#0072c9`, text reading `#0065b3`): links, focus, selected controls, primary buttons.

### Neutral

- **Page** (`--bg`, `#f5f5f5`): the background behind the cards.
- **Surface** (`#ffffff`): section cards, the top bar, fields.
- **Surface 2** (`#f3f2f1`): wells, code blocks, secondary rows.
- **Border** (`#8a8886`): control boundaries, at 3:1 or better against the surface (WCAG 2.2 1.4.11).
- **Rule** (`#e1dfdd`): card edges and internal dividers.
- **Fg** (`#242424`) and **Fg muted** (`#605e5c`): text and metadata.

### Sidebar

The sidebar (`#rail`) is dark in both themes. It re-scopes `--bg`, `--surface`, `--rule` and `--fg` to the `--rail-*` values, so any utility inside it reads the dark set without a second class.

- **Rail bg** (`#242424`), **hover** (`#323130`), **active** (`#3b3a39`).
- **Rail fg** (`#f3f2f1`) and **rail muted** (`#c8c6c4`, group labels).
- **Rail mark** (`#f2e600`): the current-page bar. Used nowhere else.

### State

- **Ok** (`#107c10`): healthy and successful.
- **Warn** (`#8a6d00`): abnormal or cautionary.
- **Danger** (`#a4262c`): faults, destructive actions, failed state.

**The IEC rule.** Blue means operator action; green means healthy; amber means abnormal; red means fault. None of them is decoration.

Every theme in `themes/` carries its own reading of each role, derived from that palette and checked by `ui/app/contrast.test.ts`. The brand guide's contrast table lists every pair the UI sets, day and night, sidebar included.

## Typography

System sans for prose and labels; system mono for status chips, measurements, code and IDs. No web fonts.

- **Title** (600, `1.375rem`): view headings.
- **Body** (400, `1rem`, `1.6`): prose and transcript; reading measure near `70ch`.
- **Control** (600, `0.875rem`): buttons, inputs, dense rows.
- **Label** (600, `0.75rem`): group and field labels, sentence case, no letter-spacing (`--track-label: 0`).
- **Micro** (`0.6875rem`): counts and graph stamps only.

Sentence case everywhere. No uppercase labels.

## Layout

The shell is a CSS grid: the top bar spans both columns, the sidebar fills the left column below it, and the view fills the rest. The conversation view uses the full height with an independently scrolling transcript and a docked composer.

Every other view's top-level `<section>` is a card: surface background, one-pixel rule border, `6px` radius, `--lift-low` shadow, `0.9rem 1.4rem` padding. Chat and Rooms are exempt, since they fill the pane.

Spacing scale: `0.25rem`, `0.4rem`, `0.6rem`, `0.9rem`, `1.4rem`, `2.2rem`, `3.4rem`. At `40rem` and below the sidebar becomes an off-canvas drawer, multi-column views collapse, and touch targets rise to `44px`.

## Elevation

- **`--lift-low`**: section cards and rows.
- **`--lift`**: menus and small floating surfaces.
- **`--lift-high`**: dialogs and drag state.
- **`--bevel-*`**: input and pressed-button depth.
- **`--lamp-glow`** with **`--lamp-ring`**: a lit lamp.
- **`--ring`**: focus and "you are here" outlines.

Use a named token; no one-off shadows.

## Shapes

Radii are `3px`, `4px` and `6px`; cards take the largest. Borders are one pixel, `--border` on controls and `--rule` on cards and dividers.

## Components

### Sidebar

A `<nav aria-label="Sections">` of buttons in three `<details>` groups (Work, Watch, Set up). Each destination is an 18px icon from `core/icons.js` plus a label; `decorateRailTab` adds the icon, including to plugin tabs. The current destination carries `aria-current="page"`, the active background, and the 3px `--rail-mark` bar on its leading edge. Collapsed, the sidebar shows icons only and hides labels and counts.

### Buttons

- **Primary:** accent fill, white label, `6px` radius (`--radius-pill`).
- **Secondary:** surface fill, `--border` edge, same radius.
- **Danger:** danger fill for destructive actions only.
- **Focus:** two-pixel accent outline.

### Inputs

Surface background, `--border` edge, `4px` radius, accent border on focus. Focused fields on phones use at least `16px` text.

### Chips and lamps

Pair colour with words; a lamp is never the only indicator. A lamp is coloured by setting `color:` to a state token; `--lamp-dome` reads `currentColor`.

## Do and don't

**Do**

- Use the semantic tokens so every theme stays coherent.
- Keep rows dense, keyboard reachable, and tolerant of long text.
- Load view code when the operator opens the view, not at boot.
- Give every animation a reduced-motion path that keeps the state visible.

**Don't**

- Add a second blue or a separate status palette.
- Use the rail mark, lamps or glow as decoration.
- Uppercase or letter-space a label.
- Add a one-off shadow, spacing value or hard-coded colour where a token exists.
- Put a new non-chat feature on the eager load path without updating and justifying the weight budget.
