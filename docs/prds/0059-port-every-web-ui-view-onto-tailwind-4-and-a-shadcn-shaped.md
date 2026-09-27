# PRD — Port every web UI view onto Tailwind 4 and a shadcn-shaped component kit

## Status

Draft — opened 2026-09-27, foundation and every plugin but `arena3d` landed,
with all ten feature views, app.js, core/ui.js, core/kit.js, core/tools.js,
core/usage.js and lib/graph.js on the ledger (re-counted 2026-09-27; the
`bun test ui/app ui/plugins` suite is green at 371 pass). The single
source of truth is `ui/app/tailwind.src.css` (the authoring sheet) compiled
by `bun run css:build` into the committed `ui/app/tailwind.css`; the cabinet
token block in `ui/app/app.css` stays the source of values until the last
rule moves. The component kit is `ui/app/core/kit.js`. Surface: the web UI
only, no tool, HTTP or CLI surface changes.

## Problem

The page carried 237 KB of CSS at the time this PRD opened: app.css (frame,
chat, goals), views.css (every other view) and a subsetted PatternFly v6 sheet
for the masthead, rail and nav. Both the PatternFly sheet and its subset script
have since been deleted, no plugin ships its own app.css, and the committed
`tailwind.css` is a build product rather than a hand-written sheet, so the
figure no longer describes what is in the tree. The
design-token suite pins the cabinet's radii, type steps, spacing rungs and
lamp values against those sheets, but the class vocabulary is untyped: a
class name reaches the browser with no check that a rule defines it, and a
rule with no class in any markup is dead weight nothing removes. The objective
is Tailwind 4 utilities with a shadcn-style component kit, so the vocabulary
is generated from use and the tokens stay the only source of values.
shadcn/ui itself is React over Radix with a CLI that assumes TypeScript and a
bundler; this page is preact/htm plus plain DOM factories inside a WASM guest
that embeds each file at comptime, so the kit is a re-cut of shadcn's
component source, not the library.

## Goals

Every view, plugin and static markup in ui/app renders from Tailwind
utilities whose values come from the existing cabinet tokens, and a
shadcn-shaped component kit (variants, sizes, asChild-free DOM factories)
covers the repeated controls. app.css, views.css and patternfly.min.css are
deleted at the end, with no rule left unported: ui/app/tailwind.test.mjs's
migrated ledger reaches every file that had a cabinet rule, and the same suite
proves each class any of them names resolves in the compiled sheet. First
paint does not grow: the compiled sheet plus index.html plus app.css stays
inside the existing 64K gz budget at every step, and the final state is
lighter than the three sheets it replaces. The cabinet's scale survives the
port: padding, margin and gap use rungs 1-7, radii are
rounded-plate/rounded-capsule, and no arbitrary value bypasses a token except
a documented breakpoint. Adding a web UI view stays a drop-in under
ui/plugins/, requiring no host rebuild and no edit to ui/app/.

## Non-goals

- **Not the shadcn/ui package.** The kit re-cuts shadcn's component source
  against preact/htm and plain DOM factories; there is no npm dependency, no
  Radix, and no CLI. The page embeds each `ui/app` file at comptime inside a
  WASM guest with no bundler, so a library that ships a build step cannot be
  the dependency.
- **Not new design tokens.** Every utility value resolves to a rung, radius or
  lamp value the cabinet already defines. A new token means editing the token
  suite first, which is a separate record.
- **Not a first-paint regression at any intermediate step.** The 64K gz budget
  holds on every commit of the port, not only at the end; a port that is
  cheaper at the finish and heavier until then has traded one debt for another.
- **Not relaxing the drop-in boundary.** Adding a view keeps working through
  `ui/plugins/` with no host rebuild and no `ui/app/` edit, throughout the
  port rather than after it.
- **Not deleting the design-token suite.** The tokens stay the source of truth;
  the suite keeps pinning them. What the port adds is a check that every class
  a migrated file names resolves in the compiled sheet.

## Design

**No React, no bundler.** The port lands in place (ADR 0050). shadcn/ui ships
a build step and a Radix runtime; the page has neither, so the kit is a
re-cut of shadcn's component source rather than the library.

**Values are references, not copies.** A theme reads the cabinet tokens by
`var()`, and the radius scale is the cabinet's (rounded-plate,
rounded-plate-lg, rounded-capsule). Tailwind's own `rounded-sm`/`md`/`lg` are
cleared so a pasted shadcn snippet cannot silently pick 0.375rem.

**Preflight lands last.** Only its `border-style` rule is inlined for the
utility layer; the reset waits until the last cabinet rule is gone, because
applying a preflight over surviving hand-written rules changes what those
rules compute.

**The kit builds through the existing tag factory.** `ui/app/core/kit.js`
produces DOM nodes through `ui/app/core/ui.js`, with shadcn's variant
vocabulary expressed in cabinet utility names. It gains a component only
where a caller exists.

**Plugins are classic scripts.** A plugin cannot `import`, so it reaches the
kit only through the plugin API and a declared capability, gated in
`ui/plugins/capabilities.test.mjs`.

**Dependencies.**

- tailwindcss and @tailwindcss/cli as devDependencies (package.json,
  bun.lock), used only by `bun run css:build`; the compiled sheet is
  committed, so no build step runs at serve time.
- The cabinet token block in ui/app/app.css stays the single authoring site
  until the last rule moves: ui/app/tailwind.src.css maps it by var()
  reference.
- ui/app/tailwind.test.mjs is the migration ledger and the guard: its
  migrated list holds each file whose cabinet rules were deleted, and every
  class such a file names must resolve in a shipped sheet.
- Preact/htm/signals vendored modules are unchanged.
- The web UI weight budget (ui/app/weight-budget.test.mjs) is the ceiling:
  first paint counts index.html + app.css + tailwind.css.

**Implementation phases.**

1. Foundation (done). Toolchain in package.json; ui/app/tailwind.src.css
   with the @theme mapping and the two imports; ui/app/tailwind.css built by
   `bun run css:build`; the route registered in ui/webui.zig and
   src/serve/webui_assets.zig; the link in ui/app/index.html;
   ui/app/tailwind.test.mjs registered in build.zig.
2. Plugins, smallest first (done for all but `arena3d`). For each
   ui/plugins/<name>/: re-cut its app.css rules as utilities in app.js, delete
   the sheet, add app.js to the ledger, rebuild the sheet, run
   `bun test ui/app ui/plugins`. Remaining: `arena3d`.
3. Feature views under ui/app/features/: runs, models, system, board, goals,
   knowledge, prompts, todos, fleet, arena. Each deletes its views.css rules
   in the same change. All ten are on the ledger; what remains is the
   `views.css` deletion itself (phase 6).
4. Chat and the frame: ui/app/index.html markup for the masthead, rail and
   nav (the PatternFly v6 classes), then app.js's chat, composer and
   transcript renderers. The kit gains a component only where a caller
   exists.
5. Plugins reach the kit: add a kit capability to the plugin API
   (ui/app/core/plugins.js), declare it in ui/plugins/README.md and gate it in
   ui/plugins/capabilities.test.mjs, then drop the duplicated class strings
   in the ported plugins.
6. Deletion: import preflight in ui/app/tailwind.src.css; delete
   ui/app/views.css and ui/app/app.css; (the PatternFly sheet, its subset
   script `scripts/subset-patternfly.py` and `ui/PATTERNFLY.md` are already
   gone, deleted with the last `pf-v6-*` class); drop the
   upgradePf* bridges in ui/app/core/ui.js and the deferred-sheet swap if
   nothing defers; drop the retired entries from
   src/serve/webui_assets.zig and ui/webui.zig and update
   ui/app/css-split.test.mjs, ui/app/webui-load.test.mjs and
   ui/app/design-tokens.test.mjs with them.
7. Records: a CHANGELOG entry per landed step (Added/Changed), the ui bullet
   in AGENTS.md, and the route row in docs/README.md.

## Failure modes

| Condition | Behaviour |
| --- | --- |
| A class is written into `ui/app` or `ui/plugins` without rebuilding | It styles nothing; `ui/app/tailwind.test.mjs` fails instead of the page shipping an unstyled element |
| A migrated file names a class no shipped sheet defines | `ui/app/tailwind.test.mjs` fails; the migration is not marked done |
| A new `ui/app/**` module is added with no `@embedFile` in `ui/webui.zig` | Its import 404s at runtime; the asset suite is the only guard and it does not cover this |
| First paint exceeds 64K gz | `ui/app/weight-budget.test.mjs` fails |
| A plugin reaches the kit without the declared capability | The plugin API refuses; the plugin keeps its own class strings until phase 5 declares it |

## Acceptance criteria

- [x] `bun test ui/app ui/plugins` and `zig build test` green at every step;
      `clanker gate` green at the end.
- [ ] No cabinet selector remains for a file on the migrated ledger, and
      every class a migrated file names resolves in a shipped sheet.
- [ ] First paint stays inside 64K gz; the final tree carries no PatternFly
      sheet, no views.css and no app.css.
- [ ] Adding a view under ui/plugins/ needs no host rebuild and no ui/app/
      edit.

## Open questions / future work

- **Kit coverage per phase.** Phase 4 says the kit gains a component only
  where a caller exists, which leaves a mixed tree where some ported controls
  use the kit and equivalent ones do not. Settling on whether a repeated
  control is migrated to the kit or left as utilities is a per-component call
  once three or more callers exist.
