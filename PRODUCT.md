# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Operators who run one or more clanker agent instances locally or on a host.
Primary job: start conversations, steer goals on a board, watch runs and fleet
state, and manage tools, models, schedule, and knowledge without leaving the
browser.

*Assumption (inferred from README + ui/app; no interview round available):*
power-user / developer operators, not end consumers of a hosted SaaS.

## Product Purpose

clanker is a self-improving AI agent harness (Zig). The web UI (`clanker serve`)
is the control surface for that harness: chat, goals/board, runs, rooms, arena,
compare, and system setup.

Success: the operator can complete a task (ask, steer, inspect, recover) with
clear cost/status and without fighting the panel.

## Positioning

Tools run as sandboxed WASM guests; the harness improves itself through a gated
loop. The web UI is that operator panel, not a generic chatbot skin.

## Capabilities

- Chat with streaming turns, sessions, model/fallback controls
- Goals board (Kanban + structured goals)
- Runs / execution graphs, fleet, arena, blind compare
- Rooms (peer chat), models, search, schedule, knowledge, prompts, tools, system
- Theme cycling (system / light / dark / Catppuccin / Tokyo Night / hackerman)
- Command palette and keyboard shortcuts

## Constraints

- Assets ship inside `webui.wasm`; CSS/JS edits need `zig build tools` + serve restart
- Sandbox and improve anti-cheat boundaries live in the host, not the UI
- PatternFly v6 supplies page/masthead/nav/modal structure; visual world is custom

## Terminology

- **Rail**: left section navigation
- **Turn**: one assistant job in the transcript
- **Lamp**: IEC-style status indicator (green / amber / red / blue)
- **Composer**: task input + submit

## Accessibility

Keyboard navigation, skip links, focus-visible rings, reduced-motion handling,
and WCAG AA contrast are required for Operate use. Touch targets ≥44px on
narrow / coarse pointers.

## Voice

Direct, operator-facing, no marketing fluff. Prefer the product’s own words
(cabinet, lamp, channel, job) over generic AI-console copy.

## Open decisions

- Exact primary persona (solo hacker vs. small fleet ops) not confirmed by interview
- Whether to subset PatternFly further vs. keep deferred full stylesheet
