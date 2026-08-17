# Bug — Activity view shows only 'log' actions, so a board being worked on looks idle

## TL;DR

- **What failed:** ui/plugins/activity/app.js builds its timeline from each card's 'log' array, and tools/zig/board.zig appends to that array for exactly one action: 'log'. add, move, update, claim, close, delete, subtask_* and depend append nothing, so every structural change is invisible in the view named Activity — whose own empty state says 'Move a card'. Here the newest entry was 2026-08-14 11:22 while the board room recorded five updates on 08-14 and an archive move on 08-16.
- **Impact:** To be confirmed.
- **Resolution:** Resolved on 2026-08-16. boardTimeline in ui/app/lib/board.js merges the card logs with the board room's action messages, deduping the log action that arrives on both; exposed as api.boardTimeline and consumed by ui/plugins/activity/app.js, which now reads both feeds. Verified by eight tests in ui/app/lib/board.test.mjs wired into zig build test, clanker gate, and a live run over this checkout's board that went from 23 entries newest 08-14 11:22 to 65 entries newest 08-16 22:41.

## Status

Resolved on 2026-08-16. boardTimeline in ui/app/lib/board.js merges the card logs with the board room's action messages, deduping the log action that arrives on both; exposed as api.boardTimeline and consumed by ui/plugins/activity/app.js, which now reads both feeds. Verified by eight tests in ui/app/lib/board.test.mjs wired into zig build test, clanker gate, and a live run over this checkout's board that went from 23 entries newest 08-14 11:22 to 65 entries newest 08-16 22:41.

## Symptom and impact

## Reproduction

## Root cause

## Resolution

## Verification

## Follow-up

## References

- Investigation: none yet
## Evidence

The view's `load()` read one feed:

    ((d.board && d.board.cards) || []).forEach(function (c) {
      (c.log || []).forEach(function (e) { entries.push({...}); });
    });

`c.log.append` occurs once in the tree, in `tools/zig/board.zig`'s fold, and
only for `action:"log"`. `add`, `move`, `update`, `claim`, `assign`,
`close`, `delete`, `subtask_*` and `depend` append nothing — a column change
sets `c.column`/`c.column_at` and returns.

The "goal run started"/"goal run finished" lines that filled the view are not
written by any code: `rg` finds neither string in the tree. They are text a
goal-loop agent chose as the `what` of a `log` action, so the view was in
practice a list of whatever an LLM had decided to narrate.

On this checkout the newest entry was 2026-08-14 11:22, while the board room
had recorded more since:

    clanker chat history board 1786677720

    [1786891280] clankerydoo: @todo {"action":"move","todo":"m1786662837-3249300-1","column":"archive"}
    [1786719150] clankerydoo: @todo {"action":"update","todo":"m1786567348-3779470-c8","goal":""}
    ... four more updates at 1786719142-1786719148

All 19 cards had been moved to `archive`, and none of that showed. The empty
state told the reader to "Move a card, or write a line in a card's activity
box" — of those two, only the second ever produced a row.

## Resolution

`boardTimeline(cards, messages)` in `ui/app/lib/board.js` merges both feeds,
because neither is complete on its own: the card logs outlive the room's
history window, and the room messages are the only record of every other
action. It renders each action through the existing `boardActionLine`, drops
non-action room chatter and malformed `@todo` JSON, resolves each action's
card title from the board, and skips `log` actions from the message feed so an
entry arriving on both feeds is not listed twice.

Exposed to plugins as `api.boardTimeline` in `ui/app/core/plugins.js`, beside
the existing `api.render`, rather than reimplemented in the plugin: plugins
load as classic scripts and cannot import. The plugin now requests
`/api/chat/messages?room=board&limit=500` alongside `/api/board`, and a room
that cannot be read degrades to the card logs rather than emptying the view.

## Verification

Eight tests in `ui/app/lib/board.test.mjs`, wired into `zig build test`, cover
the merge, the ordering, the double-listing, an action naming a card the board
no longer has, room chatter, and missing feeds. `clanker gate` passes.

Against this checkout's live board and room:

    before: 23 entries | newest: 14 Aug, 11:22
    after:  65 entries | newest: 16 Aug, 22:41

The first row is now `moved a card to Archive` on the card 'test this git
worktree flow and what it has access to', the 2026-08-16 action that the view
had been unable to show.