# PRD — Port every web UI view onto Tailwind 4 and a shadcn-shaped component kit

## Status

Draft — opened 2026-09-27. Name the source files that are the single source of truth, and the surfaces that expose it.

Draft / In progress / Partial / Implemented / Shipped. Name the source files that are the single
source of truth, and the surface(s) that expose it (tools, HTTP, CLI, web
UI). If a claim below is known to be stale or contradicted by the code,
say so here up front rather than burying it in Design — a reader who only
reads Status should not walk away misinformed.

## Problem

The page carries 237 KB of hand-written CSS: app.css (frame, chat, goals) and views.css (every other view) over a subsetted PatternFly v6 sheet for the masthead, rail and nav, plus a per-plugin app.css in ui/plugins/. The design-token suite pins the cabinet's radii, type steps, spacing rungs and lamp values against those sheets, but the class vocabulary is untyped: a class name reaches the browser with no check that a rule defines it, and a rule with no class in any markup is dead weight nothing removes. The objective is Tailwind 4 utilities with a shadcn-style component kit, so the vocabulary is generated from use and the tokens stay the only source of values. shadcn/ui itself is React over Radix with a CLI that assumes TypeScript and a bundler; this page is preact/htm plus plain DOM factories inside a WASM guest that embeds each file at comptime, so the kit is a re-cut of shadcn's component source, not the library.

What breaks or is impossible without this, stated from the situation that
forced the decision, not from the solution. Include real constraints
(no server to mediate, must ride an existing transport, sandbox must be
able to enforce it) that shaped the design, not just the desired outcome.

## Goals

Every view, plugin and static markup in ui/app renders from Tailwind utilities whose values come from the existing cabinet tokens, and a shadcn-shaped component kit (variants, sizes, asChild-free DOM factories) covers the repeated controls. app.css, views.css and patternfly.min.css are deleted at the end, with no rule left unported: ui/app/tailwind.test.mjs's migrated ledger reaches every file that had a cabinet rule, and the same suite proves each class any of them names resolves in the compiled sheet. First paint does not grow: the compiled sheet plus index.html plus app.css stays inside the existing 64K gz budget at every step, and the final state is lighter than the three sheets it replaces. The cabinet's scale survives the port: padding, margin and gap use rungs 1-7, radii are rounded-plate/rounded-capsule, and no arbitrary value bypasses a token except a documented breakpoint. Adding a web UI view stays a drop-in under ui/plugins/, requiring no host rebuild and no edit to ui/app/.

Numbered, verifiable. Each goal should be checkable against the Acceptance
criteria below — if a goal has no matching checkbox, either the goal is
wrong or the criteria are incomplete.

## Non-goals

What this deliberately does not do, and why leaving it out is a feature
(not just unstarted work). This is what stops the next reader from
"fixing" a deliberate omission.

## Design

The mechanism, in the fewest sections that convey the real shape of the
thing. Prefer named sub-sections in bold (`**Thing.**`) over prose walls.
State *why* a non-obvious choice was made where it matters (e.g. "the guest
never touches state, so a misbehaving guest can't widen its reach") — the
why is what keeps a future editor from breaking an invariant they can't see.

If a table of ops/fields/endpoints exists in code, mirror it here exactly;
treat a mismatch between this table and the code as a bug in the PRD, not
a stylistic choice, and fix it the same day it's noticed.

For a **Draft** (or partially shipped) PRD, Design must also settle build
blockers and sequencing — do not leave "must decide before coding" items
only under Open questions:

- **Dependencies.** Other PRDs, ADRs, and existing code this rides on.
  Hard blockers first; soft/related after.
- **Implementation.** Numbered phases with concrete file paths (create /
  edit). Each phase should be independently checkable. Put "decide X"
  work in Design policy above, not as a phase that re-opens the decision.

## Known issues

Only needed when verification against code turned up real drift between
what was designed/promised (in this doc, in a manifest, in a code comment)
and what the code actually does. Omit this section entirely for a PRD with
no known drift — an empty "Known issues: none" is noise. Each entry: what
was promised, what actually happens, and where the fix belongs (file, not
just "somewhere").

## Failure modes

A table: condition -> behaviour. Every "what happens when X goes wrong"
answer a caller would otherwise have to read the source to find out. Mark
a row as a known bug (cross-reference Known issues) rather than describing
buggy behavior as if it were the design.

## Acceptance criteria

Checkboxes, each traceable to a Goal. Use `[ ]` honestly for anything not
currently true — an unchecked box that names the gap is more useful than a
checked box that's aspirational. Re-verify this section, not just Design,
whenever the code changes underneath a shipped PRD.

## Open questions / future work

Real unresolved decisions, each phrased so a reader unfamiliar with the
history can tell what's actually being asked and why it's still open
(what would resolving it cost or break?). Distinguish a genuine open
design question from a plain bug that just hasn't been fixed yet — a bug
belongs in Known issues, not here, even if fixing it is future work.

Do not park build blockers here. If implementation cannot start until a
choice is made, make the choice in Design (and say why), then leave only
follow-on / optional refinements in this section.
## Dependencies

- tailwindcss and @tailwindcss/cli as devDependencies (package.json, bun.lock), used only by `bun run css:build`; the compiled sheet is committed, so no build step runs at serve time.
- The cabinet token block in ui/app/app.css stays the single authoring site until the last rule moves: ui/app/tailwind.src.css maps it by var() reference.
- ui/app/tailwind.test.mjs is the migration ledger and the guard: its migrated list holds each file whose cabinet rules were deleted, and every class such a file names must resolve in a shipped sheet.
- Preact/htm/signals vendored modules are unchanged.
- The web UI weight budget (ui/app/weight-budget.test.mjs) is the ceiling: first paint counts index.html + app.css + tailwind.css.

## Design

Settled: the port lands in place, not on React with Radix and a bundler (ADR 0050). Theme values are var() references to cabinet tokens, never copies, and the radius scale is the cabinet's (rounded-plate, rounded-plate-lg, rounded-capsule) with Tailwind's own rounded-sm/md/lg cleared so a pasted shadcn snippet cannot silently pick 0.375rem. Preflight is deferred until the last cabinet rule is gone; only its border-style rule is inlined for the utility layer. The kit (ui/app/core/kit.js) builds DOM nodes through the existing tag factory in ui/app/core/ui.js, with shadcn's variant vocabulary expressed in cabinet utility names. Plugins are classic scripts and cannot import a module, so a plugin reaches the kit only through the plugin API and a declared capability.

## Implementation phases

1. Foundation (done). Toolchain in package.json; ui/app/tailwind.src.css with the @theme mapping and the two imports; ui/app/tailwind.css built by `bun run css:build`; the route registered in ui/webui.zig and src/serve/webui_assets.zig; the link in ui/app/index.html; ui/app/tailwind.test.mjs registered in build.zig.
2. Plugins, smallest first (activity done). For each ui/plugins/<name>/: re-cut its app.css rules as utilities in app.js, delete the sheet, add app.js to the ledger, rebuild the sheet, run `bun test ui/app ui/plugins`. Remaining: search, schedule, compare, mesh, music, health, files, office, arena3d.
3. Feature views under ui/app/features/: runs, models, system, board, goals, knowledge, prompts, todos, fleet, arena. Each deletes its views.css rules in the same change.
4. Chat and the frame: ui/app/index.html markup for the masthead, rail and nav (the PatternFly v6 classes), then app.js's chat, composer and transcript renderers. The kit gains a component only where a caller exists.
5. Plugins reach the kit: add a kit capability to the plugin API (ui/app/core/plugins.js), declare it in ui/plugins/README.md and gate it in ui/plugins/capabilities.test.mjs, then drop the duplicated class strings in the ported plugins.
6. Deletion: import preflight in ui/app/tailwind.src.css; delete ui/app/views.css and ui/app/app.css; delete ui/vendor/patternfly.min.css with scripts/subset-patternfly.py and ui/PATTERNFLY.md; drop the upgradePf* bridges in ui/app/core/ui.js and the deferred-sheet swap if nothing defers; drop the retired entries from src/serve/webui_assets.zig and ui/webui.zig and update ui/app/css-split.test.mjs, ui/app/webui-load.test.mjs and ui/app/design-tokens.test.mjs with them.
7. Records: a CHANGELOG entry per landed step (Added/Changed), the ui bullet in AGENTS.md, and the route row in docs/README.md.

## Acceptance criteria

- `bun test ui/app ui/plugins` and `zig build test` green at every step; `clanker gate` green at the end.
- No cabinet selector remains for a file on the migrated ledger, and every class a migrated file names resolves in a shipped sheet.
- First paint stays inside 64K gz; the final tree carries no PatternFly sheet, no views.css and no app.css.
- Adding a view under ui/plugins/ needs no host rebuild and no ui/app/ edit.
