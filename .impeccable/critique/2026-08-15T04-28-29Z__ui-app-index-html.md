---
target: clanker web UI
total_score: 26
max_score: 40
na_heuristics: 
p0_count: 2
p1_count: 2
timestamp: 2026-08-15T04-28-29Z
slug: ui-app-index-html
---
Method: dual-agent (A: 01a003a6-af08-7df2-af54-2ae4332c7e31 · B: 01a003a6-af08-7df2-af54-2afe3da7969b)

# Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Lamps, toasts, live chips; phone hides lamps; run receipts die on reload |
| 2 | Match System / Real World | 2 | Cabinet thesis vs ChatGPT composer, Slack rooms, Trello board |
| 3 | User Control and Freedom | 3 | Stop, Esc, Fork, Steer, Archive; Delete sits on an empty chat; theme is cycle-only |
| 4 | Consistency and Standards | 2 | Four dialects (cabinet, chat pills, Slack, Trello) plus PatternFly |
| 5 | Error Prevention | 3 | Confirms on delete/compact; “No limit” and “Create goal card” invite the wrong belief |
| 6 | Recognition Rather Than Recall | 2 | 14+ views, Files off by default, slash grammar, 11 themes in a title |
| 7 | Flexibility and Efficiency | 3 | Palette, digits 1–9, graph keys; collapsing the rail hides the session list |
| 8 | Aesthetic and Minimalist Design | 2 | Session admin and four run-shape toggles on an empty Chat |
| 9 | Error Recovery | 3 | Search / Schedule / Files name the failure; System Progress is a raw log |
| 10 | Help and Documentation | 3 | `?` overlay and honest meta; send is a silent circle; Files glyphs undocumented |
| **Total** | | **26/40** | **Acceptable** |

## Design Specificity Verdict

**Start here.** Authored thesis, category-default execution on the first screens.

**LLM assessment:** The page *declares* a control cabinet (IEC lamps, RAL greys, engraved mono). What lands is ChatGPT’s column (pills, circular send, four mode chips), Trello’s board, and Slack’s rooms (`slack-*` class names). PatternFly is a fourth coat. Compare, Schedule, tool breakers, Fleet mesh, and the 7px lamps are the parts that could only be clanker. Those are not the first screen. Chat’s 46rem measure and the session-first rail *are* product-specific and should stay.

**Deterministic scan:** Parent reran `detect.mjs --json ui/app` after Assessment B could not execute a shell. Exit 0, findings `[]`. Config already ignores `side-tab` on `ui/app/app.css` (turn-phase lamps, thread indent). No overlay injection (no native [Human] tab). Assessment B’s reconstruction matches a clean CLI: pulsing typing dots and lamp glows would be false positives if they ever fired.

**Visual overlays:** No reliable user-visible overlay. Fallback: CLI scan only; live-server injection skipped.

## Overall Impression

The operator topology is right (session rail, Chat as a reading column, other views filling the main). The paint on Chat, Board, and Rooms is three other products. The single biggest opportunity is empty Chat: one greeting, one composer, one Run, and the four repo suggestions, with session verbs and run-shape modes out of the first paint.

## What's Working

1. **Session-first rail.** Work stays visible; Watch and Set up fold; conversations are a place. The 15rem width and 40–75rem inset are a coherent contract, not waste.
2. **Chat as a 46rem / ~70ch column** with a docked composer and repo-true empty-state suggestions. That measure is a product decision.
3. **Where the cabinet is allowed to speak:** IEC lamps, Compare’s blind A/B, Schedule’s “nothing fires from this page,” live-region toasts, Steer, Plan, Worktree, skip-to-composer.

## Priority Issues

### [P0] Three products under one wordmark
- **Why it matters:** First impression is interchangeable local-agent chrome. Lamps cannot carry identity if Board is Trello and Rooms is Slack.
- **Fix:** Keep cabinet tokens + PF as structure. Rooms as a channel strip in cabinet type (rename `slack-*` when the paint changes). Board as a job board with IEC lane lamps. Chat may keep the measure and docked composer; drop the always-on pill circus.
- **Suggested command:** `/impeccable distill` (Chat empty + composer chrome) then `/impeccable quieter` on Rooms/Board imports.

### [P0] Empty Chat is not a single task
- **Why it matters:** Primary action is start a run. Fork / Rename / Archive / Delete / find-in-transcript / Plan / Research / No limit / Worktree / mic all compete with “What are we working on?”
- **Fix:** On `chat-empty`, show greeting, composer, suggestions, model, labeled Run. Park session verbs until a turn exists (they already live in the palette). Fold run-shape modes behind one control, default off.
- **Suggested command:** `/impeccable distill`

### [P1] “No limit” sits equal to Plan and Worktree
- **Why it matters:** The label reads like removing the governor. The title admits a 1000-step ceiling. Operators under pressure will tick power.
- **Fix:** One “Run shape” disclosure. Spell the budget as “Long run (1000 steps).” Make Worktree look like a safety plate, not a sibling checkbox.
- **Suggested command:** `/impeccable clarify`

### [P1] Board first paint is a form, a filter bar, a Trello, and a log
- **Why it matters:** Create does not start work. Empty state sits below objective / criterion / budget / worktree / Room / Only mine (twice) / Re-sync / six filters / ten label colors.
- **Fix:** Empty Board: one create, one sentence that this saves a card and does not start the loop, then lanes. Filters in a disclosure. One Only mine.
- **Suggested command:** `/impeccable onboard`

### [P2] Files is the missing Work surface, and it hides
- **Why it matters:** Operators run tasks against a checkout. Files is `group: "Work"` but off until System → plugins.
- **Fix:** Ship Files enabled in Work, or make it first-party. Visible labels (Hidden, Refresh, Close). Token colors, not linguist hex.
- **Suggested command:** `/impeccable onboard`

## Cognitive load

6 of 8 checklist items fail (single focus, chunking, hierarchy, one-thing, minimal choices, working memory). Grouping and progressive disclosure only partially pass. Decision points with >4 options: session verbs, composer toolbar (7), masthead, Set up (7), Watch (5), board filters (6), 11 themes, System’s six sections.

## Persona red flags

**Alex (power operator):** Collapsed rail deletes the conversation list. Two model chips. Files off by default. Send is an unlabeled circle; they will Ctrl+Enter and miss the workspace pane.

**Jordan (first-timer):** Greeting is right; then `theme: system`, `…` title, Fork on an empty chat, silent send, four mode words. Board form does not start a loop. Will not find System → plugins → Files.

**Sam (keyboard / SR):** Skip links and live-region toasts are excellent. Tab order still walks session verbs before `#task` unless they take skip-to-composer. Icon-only submit / voice / help / rail-collapse. Digit help says 1–9 while the tablist is 14+.

## Minor Observations

- Dual model chips (`#header-model` and `#composer-model`); composer is enough.
- Theme is an 11-way cycle; `hackerman` is the only theme that still belongs.
- `#card-form` is now correctly hidden (harden); it remains dead weight in the DOM.
- `#run-metrics` as a visit-only receipt is honest; say “this visit” or persist a last-run stamp.
- Do not stretch Chat to fill the column.

## Questions to Consider

- If the rail is already session-first, why does Rooms build a second Slack?
- What would the first ten seconds be if empty Chat hid every session verb and every run-shape toggle until the first turn landed?
- Is Files a plugin because it is optional, or because the Work rail was already full?
