---
name: clanker web UI
description: The terminal's discipline, windowed — a monospace instrument for watching an agent edit itself.
colors:
  cobalt: "#58a6ff"
  cobalt-veil: "#1f6feb33"
  on-cobalt: "#041024"
  ink: "#0d1117"
  surface: "#161b22"
  surface-raised: "#1c2129"
  hairline: "#30363d"
  rule: "#21262d"
  text: "#e6edf3"
  text-muted: "#9198a1"
  signal-ok: "#3fb950"
  danger: "#ff7b72"
  on-danger: "#1a0505"
typography:
  title:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "1.25rem"
    fontWeight: 700
    lineHeight: 1.5
    letterSpacing: "-0.02em"
  body:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, \"Segoe UI\", Roboto, sans-serif"
    fontSize: "1rem"
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: "normal"
  code:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "1rem"
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: "normal"
  label:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "0.75rem"
    fontWeight: 700
    lineHeight: 1.5
    letterSpacing: "0.08em"
  meta:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
    fontSize: "0.75rem"
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: "normal"
rounded:
  sm: "4px"
  md: "6px"
  lg: "10px"
  pill: "999px"
components:
  button-primary:
    backgroundColor: "{colors.cobalt}"
    textColor: "{colors.on-cobalt}"
    typography: "{typography.body}"
    rounded: "{rounded.md}"
    padding: "0.5rem 1.25rem"
    height: "44px"
  button-secondary:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text-muted}"
    typography: "{typography.meta}"
    rounded: "{rounded.md}"
    padding: "0.5rem 0.9rem"
    height: "44px"
  button-danger:
    backgroundColor: "{colors.danger}"
    textColor: "{colors.on-danger}"
    rounded: "{rounded.md}"
    padding: "0.5rem 1.25rem"
    height: "44px"
  chip:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text-muted}"
    typography: "{typography.meta}"
    rounded: "{rounded.pill}"
    padding: "0.15rem 0.5rem"
  field:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text}"
    typography: "{typography.code}"
    rounded: "{rounded.md}"
    padding: "0.75rem"
  turn-card:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.text}"
    rounded: "{rounded.lg}"
    padding: "0.9rem"
  graph-node:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text}"
    typography: "{typography.meta}"
    rounded: "{rounded.md}"
    padding: "0.4rem 0.6rem"
    width: "152px"
---

# Design System: clanker web UI

## Overview

**Creative North Star: "The Terminal, Windowed"**

This is the CLI's discipline given a browser's affordances. Monospace is the
native hand, not a code-block special case: the heading, the answer, the
metrics, the room log and the graph labels are all set in it, because the thing
being displayed is machine output and pretending otherwise would be a costume.
What the browser adds is click targets, layout, and colour-coded structure —
never a different personality. A person moving between `clanker repl` and this
page should recognise the same tool, not a friendlier sibling.

Running through it is an instrument-panel streak. Every number on screen is a
real reading taken from the run: prompt and completion tokens, wall time, cost
to four decimal places, bytes recorded, the duration bar under each graph node
scaled against the slowest call. Nothing is rounded into a reassuring summary
and nothing is a placeholder. When a value is missing the interface says so
rather than showing a plausible zero.

The mood is dense, legible, unhurried. Information sits close together and the
surfaces stay flat and quiet so that density never becomes noise; line-height
holds at 1.5 throughout and the single accent appears perhaps once per view.
Colour is reserved for meaning — kind, state, outcome — so a screen with no
colour in it is a screen where nothing needs attention.

**Key Characteristics:**

- Monospace-led, with sans reserved for a handful of control labels
- Flat surfaces, layered tonally; no shadows anywhere in the system
- Hairline borders as the only structural drawing tool
- One accent, used sparingly and always to mark the live or primary thing
- Colour encodes kind and outcome, never decoration
- Every reading is real; absence is stated, not filled

## Colors

A near-neutral slate ground with a single cobalt accent and two semantic
signals, tuned so the same roles hold in both themes.

### Primary

- **Cobalt** (`{colors.cobalt}`): The one live thing on screen. The run button,
  the streaming caret, the wordmark, links, model nodes in the run graph, and
  the focus ring. Its scarcity is what makes it readable at a glance.
- **Cobalt Veil** (`{colors.cobalt-veil}`): The spinner's unlit track — cobalt
  at 20% alpha, used only where the accent needs a ghost of itself to rotate
  against.

### Secondary

- **Signal Green** (`{colors.signal-ok}`): Tool execution and healthy state.
  Tool node borders and their duration bars, the live instance chip, and this
  instance's own messages in a room.

### Tertiary

- **Danger** (`{colors.danger}`): Failure only. Error text inside an answer, a
  failed tool node's border and cross mark, the Stop button. Never a warning,
  never emphasis.

### Neutral

- **Ink** (`{colors.ink}`): The page ground.
- **Surface** (`{colors.surface}`): Controls and inset fields — buttons, chips,
  inputs, graph nodes. One step up from the ground.
- **Surface Raised** (`{colors.surface-raised}`): Content sitting inside a
  container: the code block body, the detail panel, the room log, the "you"
  line of a turn. Two steps up.
- **Hairline** (`{colors.hairline}`): Borders on things you can interact with.
- **Rule** (`{colors.rule}`): Borders that only divide — card edges, section
  tops, dashed separators. Dimmer than Hairline so structure recedes behind
  controls.
- **Text** (`{colors.text}`) and **Text Muted** (`{colors.text-muted}`): Primary
  reading colour and everything secondary — metrics, timestamps, labels,
  placeholder text, empty states.

### Named Rules

**The Kind-Colour Rule.** Cobalt means a model call. Green means a tool. Red
means it failed. This encoding is fixed across the run graph, the transcript's
tool lines, and the chat log, and a new surface reuses it rather than choosing
fresh colours for the same distinctions.

**The One Accent Rule.** There is exactly one accent. A screen should rarely
show more than one cobalt element at a time; if two things are competing for it,
one of them is not actually primary.

**The Two-Border Rule.** `hairline` outlines what you can touch; `rule` outlines
what merely divides. Using the brighter border for a passive divider makes the
page look interactive where it isn't.

## Typography

**Display / Body Font:** ui-monospace stack (SFMono-Regular, Menlo, Consolas)
**Secondary Font:** system sans stack (system-ui, -apple-system, Segoe UI, Roboto)

**Character:** Monospace carries the system; the sans stack appears only on
primary button labels, where a proportional face reads better at a glance on an
action word. The pairing is deliberately unremarkable — both are platform
stacks, so the page loads with no webfont, no layout shift, and no network
request for type.

### Hierarchy

- **Title** (mono, 700, 1.25rem, letter-spacing -0.02em): The `clanker`
  wordmark, in cobalt. The only title on the page; sections use Label.
- **Body** (sans, 400, 1rem, line-height 1.5): Primary button labels and prose
  in fallback states. The narrowest role in the system.
- **Code** (mono, 400, 1rem, line-height 1.5): The answer stream itself and the
  task textarea. Same size as Body, so a typed task and its answer sit at one
  optical weight.
- **Label** (mono, 700, 0.75rem, letter-spacing 0.08em, uppercase): Section
  headings and field labels — TASK, RUNS, CHAT, RECORDED RUN. Uppercase and
  tracked so a 12px string still reads as a heading.
- **Meta** (mono, 400, 0.75rem): Every reading and secondary string — token
  counts, durations, costs, timestamps, node metrics, chips, empty states.

### Named Rules

**The Monospace-Default Rule.** New text is monospace unless there is a stated
reason otherwise. Sans is the exception, currently limited to primary button
labels.

**The 12px Floor Rule.** Nothing renders below 0.75rem. Micro-labels that want
to be smaller get muted colour instead of a smaller size.

## Layout

A single centred column, `max-width: 56rem`, with `1.25rem 1.5rem 2rem` padding
that tightens to `1rem` below 40rem. The page is a vertical stack of sections in
a fixed order — conversation picker, transcript, composer, Runs, Chat, Status —
each separated by a `2.5rem` top margin and a 1px `rule` top border. Turn cards
in the transcript sit `1.5rem` apart.

Sections that present a collection share one pattern: **a label, a native
`<select>`, then the detail below it**. Runs and Chat both use it, which is why
they read as one system despite showing different things. Anything wider than
the column scrolls inside its own container rather than widening the page — the
run graph, code blocks, and the room log all do this.

Density is high and deliberate: no decorative whitespace, no full-bleed
sections, no hero. Below 40rem the definition list collapses to one column and
toolbar buttons go full width; nothing else re-flows, because the column was
never wide enough to need to.

There is no spacing token scale. Values are chosen per rule, which is an honest
description of the current state rather than an endorsement — if a scale is ever
introduced it should be extracted from what is already used, not imposed.

## Elevation & Depth

**There are no shadows in this system.** Not one `box-shadow` exists, and none
should be added. Depth is expressed two ways only: tonal layering and hairline
borders.

Tonal layering runs `ink` → `surface` → `surface-raised`, three steps and no
more. A control sits one step above the page; content nested inside a container
sits two. Anything needing a fourth step is a sign the nesting is too deep, not
that the palette is short.

Borders do the rest of the work. A 1px `hairline` says "interactive"; a 1px
`rule` says "boundary"; dashed `rule` says "annotation" and appears on turn
footers, the run header, and the iteration tags.

### Named Rules

**The Flat-Forever Rule.** Depth comes from tone and stroke. A shadow, glow, or
blur introduced here would be the only one in the system, and would read as a
mistake rather than emphasis.

## Shapes

Rectilinear throughout, with four radii and no other geometry: `4px` for small
inset marks (the duration bar, the copy button), `6px` for controls and code
blocks, `10px` for cards and panels, and a full pill for chips. Larger container
means larger radius, consistently.

The recurring silhouette is a **bordered rectangle on a slightly lighter
ground** — turn card, graph node, code block, detail panel, and room log are all
the same object at different scales. The run graph is the one place with
non-rectangular drawing: 1.5px SVG polylines with a triangular arrowhead,
clipped to each box's edge, plus a dashed circle for the iteration tag.

Motion is minimal and always tied to a live process: a 0.7s linear spinner while
a tool runs, a 1.2s pulse on an empty answer awaiting its first token, a 1.1s
caret on the streaming answer, and a `scale(0.97)` press on buttons. Every one
has a `prefers-reduced-motion` alternative that preserves the state change
rather than removing the signal.

## Components

### Buttons

- **Shape:** Softly squared (`{rounded.md}`, 6px), minimum height 44px.
- **Primary:** Cobalt fill with near-black text (`{colors.on-cobalt}`), sans,
  600 weight, `0.5rem 1.25rem`. One per view.
- **Secondary:** Surface fill, muted text, 1px hairline border, mono at
  `{typography.meta}`, `0.5rem 0.9rem`. The default for everything that isn't
  the primary action — Refresh, Copy answer, Run again, Close.
- **Danger:** Danger fill with `{colors.on-danger}` text. Currently only Stop.
- **Chip button:** Pill radius, surface fill, muted text; hover lifts text to
  full and border to cobalt. Used for the theme cycle and New chat.
- **Hover / Focus:** Secondary and chip buttons brighten their text and shift
  their border to cobalt. Focus is a 2px cobalt outline at 2px offset, applied
  globally via `:focus-visible` — every focusable element has one.
- **Press:** `scale(0.97)`, suppressed under reduced motion.

### Chips

- **Style:** Pill, surface fill, muted mono text, transparent 1px border.
- **State:** Colour carries meaning — green when the instance is live, red when
  disconnected, muted otherwise.

### Cards / Containers

- **Corner Style:** `{rounded.lg}` (10px) for turn cards and panels.
- **Background:** Transparent on the page ground for turn cards;
  `surface-raised` for panels and logs.
- **Shadow Strategy:** None. See Elevation & Depth.
- **Border:** 1px `rule`.
- **Internal Padding:** `0.9rem`, with a `0.6rem 0.9rem` header strip where a
  card has one.

### Inputs / Fields

- **Style:** Surface fill, 1px hairline border, `{rounded.md}`, mono. The task
  textarea is `min-height: 5rem` and vertically resizable; single-line fields
  are 44px.
- **Focus:** The global cobalt `:focus-visible` outline; the filter and message
  inputs additionally shift their border to cobalt.
- **Placeholder:** Muted at full opacity — never faded further.
- **Disabled:** 50% opacity with `not-allowed` cursor.

### Navigation

There is no navigation. The page is one scrolling column and every section is
always present. Two skip links — to main content and to the composer — are the
only jump affordances; they sit off-screen until focused, then appear at
`top: 0.75rem` in cobalt.

### The Run Graph

The system's signature component. A Sugiyama-layered DAG of a recorded run,
drawn as **DOM buttons over an SVG edge layer**. Each node is a 152px-wide
bordered box carrying an uppercase kind label, a truncated name, a metrics line,
and a duration bar scaled against the slowest node in the run. Border colour
encodes kind (cobalt = model, green = tool, `text` = final answer) and a failed
node takes a 2px danger border with a `✕` prefix. Node heights are measured
after render and fed back into the layout — they are not assumed — and edges are
clipped to box edges so arrowheads stay visible. Iteration numbers hang left in
dashed circles. The whole canvas scrolls horizontally inside its own box.

### The Transcript Turn

A bordered card per exchange: a `surface-raised` header line prefixed `you · `
in cobalt, the streaming answer in mono, a dashed-top footer carrying the run's
readings and its Copy answer / Run again buttons. Tool activity appears above
the answer as cobalt `⚙ name` lines that gain a duration when they settle.

## Do's and Don'ts

### Do:

- **Do** set new text in monospace by default; reach for the sans stack only for
  a primary action label.
- **Do** reuse the kind encoding — cobalt for model, green for tool, red for
  failure — instead of picking new colours for the same distinction.
- **Do** express depth with the three tonal steps and the two border weights.
- **Do** give every collection the label → `<select>` → detail shape that Runs
  and Chat already share.
- **Do** let anything too wide scroll inside its own container, never the page.
- **Do** state absence plainly — "(nothing recorded for this node)", "No answer
  was recorded for this turn", "Showing the first 4000 of 9418 bytes".
- **Do** pair every animation with a `prefers-reduced-motion` alternative that
  keeps the state change legible.
- **Do** keep interactive targets at 44px and give every focusable element the
  global cobalt focus ring.

### Don't:

- **Don't** add a shadow, glow, blur, or gradient. The system is flat and has no
  precedent for any of them.
- **Don't** drift toward a consumer chat app: no message bubbles, avatars,
  emoji reactions, typing-dots, or gradient send buttons. The transcript is a
  record, not a messenger thread.
- **Don't** drift toward a SaaS dashboard: no card grids, donut or sparkline
  chrome, KPI tiles, or empty-state illustrations. Density and real values
  instead of decorative summary.
- **Don't** introduce a second accent, or spend cobalt on more than one element
  per view.
- **Don't** render text below 0.75rem; use muted colour for de-emphasis
  instead.
- **Don't** load a webfont, stylesheet, script, or image from another origin —
  the served CSP forbids it and the page is expected to work offline.
- **Don't** use a fourth tonal step or a brighter border to solve a nesting
  problem; restructure instead.
- **Don't** show a rounded or invented number where a real reading is missing.
