---
name: clanker web UI
description: "A field log sheet for a machine that edits itself: paper, printed depth rules, one oxide mark."
colors:
  paper: "#e8e2d6"
  desk: "#ddd6c7"
  paper-inset: "#ded7c8"
  rule-heavy: "#b3a992"
  rule-hair: "#c8bfab"
  ink: "#241f1a"
  ink-faded: "#58503f"
  oxide: "#b4531f"
  oxide-text: "#8f3e12"
  oxide-wash: "#b4531f1f"
  on-oxide: "#f7f3ea"
  lichen: "#4a6741"
  grease-red: "#9b2c1f"
  on-grease: "#f7f3ea"
  ochre: "#8a6414"
  ochre-text: "#6f4f0d"
typography:
  wordmark:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "1.375rem"
    fontWeight: 700
    lineHeight: 1.55
    letterSpacing: "-0.02em"
  heading:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, \"Segoe UI\", Roboto, sans-serif"
    fontSize: "1.375rem"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "-0.01em"
  depth:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "1.375rem"
    fontWeight: 700
    lineHeight: 1
    letterSpacing: "-0.02em"
    fontFeature: "tnum"
  body:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, \"Segoe UI\", Roboto, sans-serif"
    fontSize: "1rem"
    fontWeight: 400
    lineHeight: 1.55
    letterSpacing: "normal"
  data:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "0.8125rem"
    fontWeight: 400
    lineHeight: 1.55
    letterSpacing: "normal"
  caps:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "0.8125rem"
    fontWeight: 700
    lineHeight: 1.55
    letterSpacing: "0.08em"
  label:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, \"Segoe UI\", Roboto, sans-serif"
    fontSize: "0.6875rem"
    fontWeight: 700
    lineHeight: 1.55
    letterSpacing: "0.14em"
  meta:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "0.6875rem"
    fontWeight: 400
    lineHeight: 1.55
    letterSpacing: "0.02em"
    fontFeature: "tnum"
rounded:
  sm: "2px"
  base: "2px"
  lg: "3px"
  pill: "999px"
spacing:
  "1": "0.25rem"
  "2": "0.4rem"
  "3": "0.6rem"
  "4": "0.9rem"
  "5": "1.4rem"
  "6": "2.2rem"
  "7": "3.4rem"
components:
  button-primary:
    backgroundColor: "{colors.oxide}"
    textColor: "{colors.on-oxide}"
    typography: "{typography.body}"
    rounded: "{rounded.base}"
    padding: "0.5rem 1.25rem"
    height: "44px"
  button-secondary:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    typography: "{typography.data}"
    rounded: "{rounded.base}"
    padding: "0.45rem 0.85rem"
    height: "44px"
  button-danger:
    backgroundColor: "{colors.grease-red}"
    textColor: "{colors.on-grease}"
    typography: "{typography.body}"
    rounded: "{rounded.base}"
    padding: "0.5rem 1.25rem"
    height: "44px"
  button-danger-quiet:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.grease-red}"
    typography: "{typography.data}"
    rounded: "{rounded.base}"
    padding: "0.45rem 0.85rem"
    height: "44px"
  chip:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink-faded}"
    typography: "{typography.data}"
    rounded: "{rounded.pill}"
    padding: "0.15rem 0.5rem"
  chip-button:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink-faded}"
    typography: "{typography.data}"
    rounded: "{rounded.pill}"
    padding: "0.15rem 0.6rem"
    height: "32px"
  field:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.base}"
    padding: "0.75rem"
  select:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    typography: "{typography.data}"
    rounded: "{rounded.base}"
    padding: "0.4rem 0.6rem"
    height: "44px"
  rail-tab:
    backgroundColor: "transparent"
    textColor: "{colors.ink-faded}"
    typography: "{typography.data}"
    rounded: "{rounded.sm}"
    padding: "0.4rem 0.6rem 0.4rem 1.4rem"
    height: "32px"
  stratum:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    padding: "0.9rem 0 0 3.25rem"
  card:
    backgroundColor: "{colors.paper-inset}"
    textColor: "{colors.ink}"
    typography: "{typography.data}"
    rounded: "{rounded.base}"
    padding: "0.6rem"
  toast:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    typography: "{typography.data}"
    rounded: "{rounded.pill}"
    padding: "0.6rem 0.9rem"
---

# Design System: clanker web UI

## Overview

**Creative North Star: "Core Log"**

The surface is a field log sheet. A machine editing itself lays down strata; the
owner reads the column and decides which layers hold. Turns are not chat
bubbles and not cards: each one is a stratum bedded into a sheet of paper,
numbered in the margin against a ruled depth column, banded by what the layer is
made of. The composer sits at the foot of the column, where the next layer
lands.

The scene decided the ground. This page is read beside a terminal in a lit room,
on paper the owner annotates, so paper (`#e8e2d6`) is the default rendition and
drafting film (`#221d18`) is the night one. That is the reverse of the category
habit, and it was chosen deliberately: the rejected world is the dark agent
console with a neon accent and a chat column, and its opposite, the pastel
friendly-AI page.

Colour carries one job each and no job twice. Oxide orange is the active mark:
the layer being deposited, the current section, a link, focus. Lichen green is a
gate that held. Grease-pencil red is one that did not. A separate ochre carries
a limit approaching, so red never has to mean "warning". Everything else is ink
on paper. Prose is set in the system text face; every measurement is set in mono
with tabular numerals, because a logged quantity has to line up in a column.

**Key Characteristics:**

- Paper by default, drafting film at night; four palettes that agree value for value
- A ruled depth column down the sheet, each turn a numbered stratum
- Lithology hatching so kind survives greyscale, colour blindness and forced-colors
- One accent, spent only on the active mark
- Mono for measurements, the text face for prose; the choice of face is a claim about the content
- Square corners (2-3px); round only where the thing is physically round
- Drawn icons on one 24 grid at stroke 1.75; no glyph stands in for an icon

## Colors

Four palettes exist and agree: the bare `:root` (paper), the
`prefers-color-scheme: dark` block scoped to `:root:not([data-theme="light"])`
(film), and the two `[data-theme]` overrides that restate each palette in full so
the manual toggle wins in both directions. The frontmatter carries the paper
rendition; the film counterpart of every token is in
`.impeccable/design.json` under `colorMeta`.

### Primary

- **Oxide** (`#b4531f` paper / `#e07a3f` film): the pencil mark being made now.
  The live stratum's depth rule, the selected tab's tick, the streaming caret,
  the tool line, links, the focus ring, the primary button fill, a claimed todo.
  Nothing decorative gets it.
- **Oxide Wash** (`#b4531f1f` paper / `#e07a3f26` film): oxide at low alpha. The
  spinner's unlit track, the search-hit `mark`, and the 45-degree hatch of a
  model-only layer. Never a fill for a control.
- **On Oxide** (`#f7f3ea` paper / `#1a1410` film): text on an oxide fill.

### Secondary

- **Lichen** (`#4a6741` paper / `#8fae7f` film): a gate that held. The held mark
  in a turn's foot, a tool node's border and bar, an enabled plugin toggle, a
  closed todo, this instance's own messages in a room, string tokens in code.

### Tertiary

- **Grease Red** (`#9b2c1f` paper / `#e5705c` film): a gate that did not hold.
  Failure text, a failed node's 2px border, the fail hatch, a high-priority or
  late card, a bad toast. Failure only.
- **On Grease** (`#f7f3ea` paper / `#1a1410` film): text on a grease-red fill.
- **Ochre** (`#8a6414` paper / `#d2a24c` film): a limit approaching, not yet
  crossed. A column over its WIP limit, a card due soon, an open dependency.

### Neutral

- **Paper** (`#e8e2d6` paper / `#221d18` film): the sheet, and the fill of every
  control and field that sits on it (`--paper` and `--surface` are the same
  value).
- **Desk** (`#ddd6c7` paper / `#171310` film): the ground the sheet lies on, plus
  the source colour for every scrim, which is a `color-mix` of it.
- **Paper Inset** (`#ded7c8` paper / `#2a241e` film): content nested inside
  something else. Code bodies, the detail panel, the room log, board cards, the
  log tail.
- **Rule Heavy** (`#b3a992` paper / `#4a4034` film): the printed rule that
  outlines a control and tops a stratum.
- **Rule Hair** (`#c8bfab` paper / `#362f27` film): the hairline that divides a
  row, a section or a table line, including every dashed one.
- **Ink** (`#241f1a` paper / `#ece5d8` film): reading colour, and the depth
  number in the margin.
- **Ink Faded** (`#58503f` paper / `#a2988a` film): every secondary string, and
  the ticks on the depth rule.

### Named Rules

**The One Mark Rule.** Oxide means the thing being deposited now. If two
elements on a screen are oxide, one of them is not the active mark.

**The Gate Rule.** Lichen means a gate held, grease red means it did not, ochre
means a limit is approaching. Red is never a warning and never emphasis.

**The Two Rules Rule.** `rule-heavy` outlines what you can touch and tops a
stratum; `rule-hair` divides rows and sections. Using the heavy rule for a
passive divider makes the sheet look interactive where it is not.

**The Measured Contrast Rule.** Every text role was measured against every
ground it renders on, in both renditions. Paper: ink 12.66:1, ink faded 6.18:1,
lichen 4.92:1, grease red 5.87:1, on-oxide over oxide 4.52:1 (the tightest fill
pair in the system). Film: nothing below 4.97:1. Two paper-rendition pairs sit
under 4.5:1 and are therefore only AA at large or bold sizes: oxide as text on
paper (3.88:1, which the 22px bold wordmark clears at the 3:1 large-text
threshold but a 16px link does not) and ochre as text on paper (4.16:1). Do not
extend either use; new body-size text takes ink or ink faded.

## Typography

**Body Font:** system sans stack (`ui-sans-serif, system-ui, -apple-system,
"Segoe UI", Roboto, sans-serif`)
**Label/Mono Font:** system mono stack (`ui-monospace, SFMono-Regular, Menlo,
Consolas, monospace`)

**Character:** two faces with one rule between them. Prose reads in the text
face at 1.55 line-height; anything that is a quantity, an identifier or a
recorded string is set in mono with tabular numerals so columns of them align.
There is no display face and no webfont: the page loads nothing from another
origin.

### Hierarchy

The scale is five steps, `--step--1` through `--step-3`. Four are in use.

- **Wordmark** (mono, 700, 1.375rem / `--step-2`, `-0.02em`, oxide): the
  `clanker` title block in the header. The only mono heading.
- **Heading** (sans, 700, 1.375rem / `--step-2`, `-0.01em`, 1.2): every section
  heading, and `h3` in rendered markdown.
- **Depth** (mono, 700, 1.375rem / `--step-2`, tabular, line-height 1): the
  stratum's index, set right-aligned in the margin against the rule. The
  signature type role.
- **Body** (sans, 400, 1rem / `--step-1`, 1.55): the task as written, the
  answer, primary button labels, textareas, markdown paragraphs. Capped at
  `--measure` (70ch).
- **Data** (mono, 400, 0.8125rem / `--step-0`): the dominant role by far.
  Metrics, timestamps, code, tables, node labels, room messages, tool names,
  selects, JSON trees, the log tail.
- **Caps** (mono, 0.8125rem / `--step-0`, uppercase, `0.06em`-`0.08em`): column
  and panel headings inside a section. Weight 700 when it names a thing (board
  column title, tool detail heading), 400 when it merely heads a column (table
  `th`, `dt`, detail heads).
- **Label** (sans, 700, 0.6875rem / `--step--1`, `0.14em`, uppercase): the
  printed label above a field.
- **Meta** (mono, 400, 0.6875rem / `--step--1`, `0.02em`, tabular): the legend,
  `.meta` readings, the held mark.

`--step-3` (1.875rem) is defined and currently unused. Do not reach for it to
make something louder.

### Named Rules

**The Measurement Rule.** A logged quantity is mono and tabular; prose is the
text face. Choosing the face is choosing what the content is, so a number that
lands in the text face is a bug in the markup, not a style preference.

**The 11px Floor Rule.** `--step--1` (0.6875rem) is the smallest size in the
system. Anything that wants to be smaller gets ink faded instead.

## Layout

A three-part shell: a header title block ruled off with a hairline, a sticky
17rem rail, and the sheet. `main` is the sheet: paper fill, `--rule-heavy`
borders left and right, `--lift`, `max-width: 56rem`, `min-height: 100vh`,
padding `1.4rem 1.4rem 2.2rem` (`--space-5 --space-5 --space-6`). Views are
tab panels; exactly one is visible at a time.

The spacing scale is seven steps, all in use: `0.25rem`, `0.4rem`, `0.6rem`,
`0.9rem`, `1.4rem`, `2.2rem`, `3.4rem`. Steps 2 to 4 carry component padding and
row gaps, step 5 carries section rhythm and page padding, step 6 separates
sections and transcript entries, step 7 is used once, to hold the jump-to-latest
control clear of a turn's own buttons.

`--gutter` (3.25rem) is the depth column: the left inset of every stratum, and
the margin the index and the lithology band are drawn into. `--measure` (70ch)
caps every block that is read as prose: the task, the answer, markdown
paragraphs, lists, tables, quotes, a goal objective, a tool description.

Two breakpoints. At 60rem the rail leaves the flow and becomes a fixed panel
(`min(20rem, 85vw)`) behind a scrim, opened by the header Menu chip and
`visibility: hidden` when closed so it takes no tab stops. At 40rem the header
and sheet padding drop to 1rem, definition lists collapse to one column, and
toolbar buttons go full width. Anything wider than the column scrolls inside its
own box: code, tables, the board, the run canvas, the usage table. The page
never scrolls sideways.

### Named Rules

**The Depth Column Rule.** Every stratum is measured against the ruled spine at
`--gutter`. Only the index and the lithology band live in that margin. Content
starts at the gutter, never inside it.

## Elevation & Depth

Almost everything is bedded into the sheet. Exactly one element is lifted: the
sheet itself, on `--lift`. Depth otherwise comes from printed rules, two border
weights, and one inset tone, not from stacked shadows.

Shadows that do exist are real: an offset and a blur, never a zero-offset halo.
The floating layers (overlay box, toast, jump-to-latest, the narrow-screen rail)
carry their own scrim shadow mixed from `--desk` rather than reusing the lift
tokens, because they sit over the page rather than on the desk.

### Shadow Vocabulary

- **Lift** (`box-shadow: 0 1px 2px rgba(36,31,26,0.10), 0 6px 18px -8px rgba(36,31,26,0.30)`;
  film: `0 1px 2px rgba(0,0,0,0.5), 0 6px 18px -8px rgba(0,0,0,0.7)`): the sheet
  on the desk. One use in the system.
- **Lift High** (`box-shadow: 0 2px 4px rgba(36,31,26,0.12), 0 20px 44px -16px rgba(36,31,26,0.40)`;
  film: `0 2px 4px rgba(0,0,0,0.55), 0 20px 44px -16px rgba(0,0,0,0.8)`):
  defined and currently unused. It exists for a second sheet lifted off the
  first, not for hover emphasis.
- **Scrim shadows** (`0 0.5rem 1.5rem`, `0 1rem 3rem`, `0 0 3rem`, each
  `color-mix(in srgb, var(--desk) 55-70%, transparent)`): floating layers only.

### Named Rules

**The One Sheet Rule.** The sheet is lifted; everything on it is printed. A new
surface that wants a shadow is asking to be a second sheet, and usually should
be a ruled section instead.

## Shapes

A log sheet is cut, punched and ruled, so its corners are square: `--radius-sm`
and `--radius` are both 2px, `--radius-lg` is 3px. `--radius-pill` (999px) is
reserved for things that are physically round: a chip, a tag, a status flag, a
toast, the iteration tags on the run graph, the attachment remove button.

Structure is drawn with 1px strokes at two weights and three treatments: solid
heavy for controls and the top of a stratum, solid hairline for row and section
dividers, dashed hairline for a separator that continues a thing rather than
ending it (a turn's foot, a run head, nested JSON children, a tool tag).

Hatching is the one texture: three repeating linear gradients at different
angles and pitches, standing for what a layer is made of. 45 degrees in oxide
wash for a model-only turn, -45 degrees in faded ink for a turn where tools ran,
90 degrees in grease red for a turn that did not hold. The key is printed once
above the transcript.

### Named Rules

**The Cut Sheet Rule.** Square corners by default. If a new element wants a
radius above 3px, it has to be round, and it has to be small.

**The Drawn Not Coloured Rule.** A distinction that matters is drawn as well as
coloured. Hatching survives greyscale, colour blindness and forced-colors; a
fill alone does not.

## Components

### Component vocabulary

Every view is built from one small set (`UI` in `app.js`), so a control cannot
drift into its own spelling:

- **`UI.button(label, onclick, {kind, icon, title, label})`**: `kind: "primary"`
  for the one action a view exists for, `"danger"` for one that destroys, absent
  for everything else.
- **`UI.field(id, label, control)`**: a printed label above its control, the way
  the sheet labels every column.
- **`UI.empty(text)`**: what is absent and what would put something there. Never
  an apology.
- **`UI.meta(text)`**: a measurement. Mono, tabular.
- **`UI.bar(children)`**: a row of controls with one rhythm.
- **`UI.head(title, controls)`**: a section heading with its controls on the same
  rule.

### Buttons

- **Shape:** square (2px). Primary is 44px minimum height and unbordered;
  repeated in-list controls drop to 32px, which still clears the 24px minimum
  (code Copy, tool toggle, chip buttons, rail items, palette items).
- **Primary:** oxide fill, on-oxide label, text face at body size, padding
  `0.5rem 1.25rem`.
- **Secondary:** the default. Transparent fill, ink label, heavy-rule border,
  text face at data size, padding `0.45rem 0.85rem`. Hover shifts the border to
  ink faded and washes the fill with 4% ink.
- **Danger:** grease-red fill with on-grease text. Where it sits beside quiet
  buttons it takes the quiet form instead (`button.secondary.danger`: paper
  fill, grease-red label, heavy-rule border), inverting to the solid fill only
  on hover and focus.
- **Disabled:** `opacity: 0.5`, `cursor: not-allowed`. No colour change.
- **Press:** `transform: scale(0.97)`, suppressed under reduced motion.

### Chips

- **Style:** pill, paper fill, ink-faded text, mono at data size. A static chip
  has a transparent border; a chip that is a button has a heavy-rule border and a
  32px minimum height, because on a narrow screen the Menu chip is the only
  route to navigation.
- **State:** colour only. Lichen for live, grease red for down.

### Cards / Containers

- **Corner Style:** 2px for a board card, 3px for a panel (detail panel, board
  column, overlay box, log tail, goal, room log).
- **Background:** paper inset for anything nested; paper for a control.
- **Shadow Strategy:** none. Panels are bordered, not lifted.
- **Border:** hairline for a panel, heavy for a control.
- **Internal Padding:** `0.6rem` for a card, `0.9rem` for a panel.
- **Current card:** `box-shadow: inset 2px 0 0` in oxide, and a Highlight
  background under forced-colors, where inset shadows are dropped.

### Inputs / Fields

- **Style:** paper fill, heavy-rule border, 2px corners. A textarea is the text
  face at body size with `resize: vertical`; a select, search or single-line
  input is mono at data size. 44px minimum height, except plugin config fields at
  32px.
- **Label:** the text face at 0.6875rem, 700, `0.14em`, uppercase, ink faded,
  above the control on its own row.
- **Focus:** the global ring, plus an oxide border on the filter and config
  fields.
- **Drag state:** an oxide border on the composer's textarea while a file is
  over it.

### Navigation

The rail is a vertical tablist grouped by intent (Work / Watch / Set up), plus
a conversation list shown only under Chat. Tabs are the text face at data size,
uppercase, tracked `0.06em`, ink faded, 32px tall, with a transparent 2px-corner
border.

- **Hover:** paper-inset fill, ink text.
- **Selected:** ink text at weight 700 and a 3px oxide tick in the left margin
  (`::before`, `0.85em` tall), on a transparent fill. The tick is a reader's mark
  in the margin, not a filled row. The count beside the label turns oxide with
  it.
- **Narrow:** below 60rem the rail is a fixed panel over a `--desk` scrim,
  transitioned at 160ms, hidden from the tab order when closed.

### The Stratum (signature)

One turn, bedded into the sheet:

- **Top:** a heavy printed rule, `0.9rem` of space above the content, and the
  content inset by the full gutter. The last stratum closes with a hairline
  below it.
- **Depth rule:** a 1px continuous line in rule-heavy with 3px ticks over it in
  ink faded, one tick per 9px, drawn as two background gradients on `::before` so
  a hundred-turn transcript adds no nodes. The live stratum redraws both in
  oxide.
- **Index:** the turn number, mono 700 at 1.375rem, tabular, right-aligned in the
  margin, `aria-hidden`.
- **Band:** a `0.7rem` column between hairline borders, hatched by kind:
  model-only at first, re-hatched when a tool runs, re-hatched again if the turn
  did not hold.
- **Entry:** the task in the text face, prefixed by a real text author span, not
  generated content, so it survives copy and export.
- **Inclusions:** tool calls listed inside the layer, indented behind a hairline,
  each an oxide mono line with its duration in ink faded.
- **Foot:** dashed hairline above, mono at data size, tabular. Opens with the
  held mark (drawn tick in lichen, or drawn strike in grease red and the words
  "did not hold"), then tokens, wall time and cost, then the turn's own buttons.
- **Legend:** three hatched swatches over the transcript, printed once. Without
  it the hatching is texture rather than lithology.

### Icons

Drawn, never typed. Ten paths on one 24 grid: `pin`, `strike`, `log`, `find`,
`sample`, `copy`, `held`, `deposit`, `chevron`, `help`. Five are placed today
(`pin`, `strike`, `held`, `deposit`, `help`), and `chevron` is drawn again as a
CSS mask for disclosure markers; `log`, `find`, `sample` and `copy` are drawn
and waiting. Every icon is
`stroke-width: 1.75`, `stroke-linecap: square`, `stroke-linejoin: miter`,
`fill: none`, `stroke: currentColor`, rendered at 14-16px, `aria-hidden="true"`
and `focusable="false"`, because each sits inside a control that already carries
its accessible name. Disclosure triangles are the same chevron as a CSS mask, so
`details` markers share the stroke.

### Toasts and overlays

- **Toast:** fixed top right, pill, paper fill, hairline-heavy border, scrim
  shadow, the text face at data size, entering on a 140ms `translateY` that is
  removed under reduced motion. A bad toast borders and colours grease red.
  Toasts are the visible view of the `sr-only` live regions, which stay the
  source of truth.
- **Overlay:** the command palette and the shortcut sheet. One box on a
  `color-mix(--desk 72%)` scrim with a 2px backdrop blur, positioned `10vh` from
  the top rather than centred so the list grows downward into space the eye is
  already on. The box is 40rem wide, 3px corners, paper fill, `70vh` maximum.
  The selected palette row takes a paper-inset fill and a 2px inset oxide bar.

### Board

Columns scroll sideways as a group; each column scrolls down on its own. A
column is 15rem, hairline-bordered, 3px corners, capped at 32rem, with a mono
caps head and a tabular count that turns ochre over the limit. A card is
paper-inset, 2px corners, the text face at data size; dragging drops it to
`opacity: 0.5`; the drop target column borders oxide.

### Named Rules

**The Drawn Icon Rule.** No glyph stands in for an icon. A new icon is a path on
the 24 grid at stroke 1.75, or it does not ship.

**The Reduced Motion Rule.** Every animation has a reduced-motion alternative
that keeps the state change legible, not one that freezes it. The tool spinner
is hidden and the word it stood for is shown; the streaming caret and the
pending ellipsis settle to `opacity: 0.6`; the toast, the press, the rail slide,
the disclosure rotation and the skip-link travel are removed; JS-initiated
scrolling reads `matchMedia` and passes `auto`.

**The Focus Ring Rule.** `:focus-visible` is a 2px oxide outline at 2px offset,
declared globally and never removed, and `Highlight` under forced-colors. Every
action reachable by pointer is reachable and visible by keyboard.

**The Forced Colors Rule.** Under `forced-colors: active` every box that relied
on a border gets `1px solid ButtonText`, graph edges take `CanvasText`, and the
four selection states that are carried by an inset shadow (rail tab, rail item,
palette item, board card) take `Highlight` / `HighlightText` with
`forced-color-adjust: none`, because forced-colors drops `box-shadow`.

## Do's and Don'ts

### Do:

- **Do** spend oxide on the active mark only: the live layer, the current
  section, focus, a link, the one primary action.
- **Do** use lichen for a gate that held, grease red for one that did not, and
  ochre for a limit approaching. Red means failure, never warning.
- **Do** set measurements in mono with tabular numerals and prose in the text
  face; the face is the claim about what the content is.
- **Do** measure a new turn-like thing against the depth column at `--gutter`
  and number it in the margin.
- **Do** draw a distinction as well as colour it, and print the key once.
- **Do** keep corners square (2-3px), reserving the pill for things that are
  physically round.
- **Do** cap prose at `--measure` (70ch) and let anything wider scroll inside its
  own box.
- **Do** give every animation a reduced-motion alternative that keeps the state
  change legible.
- **Do** hold interactive targets at 44px, dropping to 32px only for a control
  that repeats down a list.
- **Do** state absence plainly: "No turns in this conversation yet.", "(nothing
  recorded for this node)", "did not hold".

### Don't:

- **Don't** treat the dark rendition as the default. Paper is the ground; film is
  the night reading of the same sheet, and both are complete palettes.
- **Don't** add a second accent, or spend oxide twice on one screen.
- **Don't** use grease red for emphasis or for a warning; ochre exists for the
  approaching limit.
- **Don't** lift anything else. The sheet carries the only `--lift` in the
  system, and `--lift-high` is not a hover treatment.
- **Don't** set body-size text in oxide or ochre on the paper rendition; they
  measure 3.88:1 and 4.16:1 there.
- **Don't** put a glyph, emoji or dingbat where an icon belongs, or draw an icon
  at another stroke weight.
- **Don't** render below `--step--1` (0.6875rem), or reach for the unused
  `--step-3` to make something louder.
- **Don't** turn a stratum back into a card: no floating edge, no fill, no
  bubble, no avatar.
- **Don't** load a webfont, stylesheet, script or image from another origin. The
  served CSP forbids it and the page is expected to work offline.
- **Don't** use the heavy rule for a passive divider or the hairline for a
  control's border.
