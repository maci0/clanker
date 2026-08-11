# PRD — Shared Kanban Board

## Status

Shipped. Single source of truth: `tools/zig/board.zig` + `tools/zig/cards.zig`.
Surface: web UI board view + ten agent-facing tools (`board_list`,
`board_add`, `board_move`, `board_update`, `board_claim`, `board_log`,
`board_subtask`, `board_depend`, `board_cost`, `board_delete`, plus the
multiplexed internal `board` entry point the web UI calls).

## Problem

Multiple clanker instances work the same repository at once. Without a shared
view of the work, two instances pick the same task, finished work gets
redone, and the owner cannot tell what any run spent. The board started as
HTTP handlers in `src/cli.zig` — a thing only the web UI could touch — and
then as a tool with its own file, `state/board.json`, which left two stores
for one idea (a room's todo list and the board file disagreed). Neither let a
clanker read or change its own board consistently with what the web UI
showed.

## Goals

1. One board, readable and writable identically by the web UI and by any
   clanker through a tool. Divergence between surfaces is a bug.
2. Replicate to peers with no new mechanism: ride the chatroom fan-out that
   already exists.
3. Resolve concurrent edits by rules that do not depend on arrival order
   (claims race; first claim stands; the loser is told who holds it).
4. Leave an audit trail: who did what, when, and what it cost.

## Non-goals

- WIP limits, swimlanes, sprint planning, custom columns. The column set is
  fixed (`cards.columns`).
- Access control. Anyone subscribed to the room holds the same messages; work
  that must not be seen belongs in a room the wrong readers are not in.
- Notifications beyond the room itself. An action message is its own
  announcement.

## Design

**The board is a chatroom.** There is no `state/board.json`. A card action is
a chat message (`@todo {...}`, encoded/decoded in `cards.zig`) appended to a
room (default `"board"`). The host appends and fans out to subscribed peers;
the folding — every rule about what a card is — happens inside the sandboxed
guest, because that is application logic and the host's job is transport.

**Derive, don't store.** Every read and every write response re-derives the
board by folding the room's whole log, oldest first, deduplicated by message
id, sorted by `(ts, id)`. The response after a write is re-derived rather
than assumed, because a concurrent claim from a peer may have won.

**Paging bound.** The guest reads history in pages through a 64 KB host
buffer, up to `max_pages = 64`. Running out of page budget while pages are
still arriving is an error, not a partial fold: `history()` refuses, since a
partial fold would quietly resurrect deleted cards and lose moves.
`error.TooLarge` covers the other size limit — a single page's JSON exceeding
the 64 KB buffer. Neither bound closes the paging-cursor hole in Known
issues, which reaches a partial fold without ever touching the cap.

**Ops.** `list`, `create`/`add`, `update`, `move`, `claim`, `assign`,
`close`, `delete`, `log`, `usage`, `subtask_add`, `subtask_toggle`,
`subtask_remove`, `depend_add`, `depend_remove`. Eight of the ten
agent-facing tools pin their op in the descriptor's `config`; `board_subtask`
and `board_depend` instead take `op` as a request field (one tool, several
sub-ops each) since a subtask/dependency action needs more than a fixed verb.
The internal multiplexed `board` entry point always names the op in the
request. Aliases (`subtask`/`subtask_id`, `on`/`depends_on`, `run`/`run_id`,
and `who`/`assignee` on `update`) are accepted so old callers keep working.
`create` takes `assignee` too, so a card can be put on someone the moment it
exists; the assignment folds as if stamped by the add itself, and a later
`assign` or `claim` outranks it by the usual rule.

**Validation lives in the guest.** Title 1–512 chars, bounded body, known
column, priority in {low, normal, high}, existing card id, no
self-dependency, non-negative finite cost. A request wrong in both op and id
is told the op is not real first.

**Views, not permissions.** `board_list` accepts `who` to narrow the answer
to what one clanker is concerned with. It narrows the answer, not the reach.

## Data model (per card)

`id` (the message id of the add), `title`, `body`, `column`, `status`
(derived), `priority`, `assignee`, `assigned_by`, `created_by`, `created`,
`deadline`, `subtasks[]`, `depends_on[]`, `blocked_by[]` (derived from cards
whose dependencies are unfinished — shown as blocked, not forbidden),
`log[]` (stamped entries), `usage` (aggregate object: `prompt_tokens`,
`completion_tokens`, `cost`, and a `runs[]` breakdown; totals add up across
runs — this one field is not itself an array, unlike the others above).

## Known issues

- **A log longer than one page folds from its newest messages only.** The
  host answers a history request with the *newest* 20 messages after the
  cursor (`src/sandbox/host.zig`), and the guest advances the cursor to the
  highest timestamp it has seen — so the first page jumps it to the end of
  the log and the second comes back empty. A board room past 20 messages
  folds without its oldest messages: adds fall off first, and every action on
  a card whose add was dropped is ignored. Measured, not guessed: a
  25-message log folds to 20 cards. The page-cap error cannot catch this —
  the loop ends well under budget — and the fix needs an oldest-first page
  shape from the host, which newest-first chat display must not inherit.
  That makes it a different fix from the (closed) page-cap one, and it is
  still open.

## Failure modes

| Condition | Behaviour |
|---|---|
| Chatrooms disabled | `list` fails: "chatrooms are disabled, and the board is a chatroom" |
| Log runs past the page budget | Error: the board refuses to fold from a partial log |
| Log longer than one history page | **Bug:** folds from the newest messages only, no error (see Known issues) |
| Claim race lost | Answer shows who holds the claim |
| Move to unknown column / unknown card | Named error before any write |
| Delete | Permanent; peers that already dropped it never restore it |

## Acceptance criteria

- [x] Web UI and `board_*` tools return the same board for the same room.
- [x] A claim race resolves to exactly one holder on every peer.
- [x] Every write returns the re-derived board, not the writer's assumption.
- [x] Cost accrues across runs on a card.
- [x] No *tracked* file under `state/` other than the room log (a stray,
  gitignored `state/board.json` from before this design may still sit in a
  local checkout; nothing reads it).
- [x] Exhausting the page budget errors instead of partially folding. (The
  paging-cursor hole in Known issues is a separate, still-open way to reach
  a partial fold; it never touches the cap.)

## Open questions / future work

- Board cap behaviour: archive old rooms or compact the log (a snapshot
  action) before a room outgrows what one fold can read. Compaction would
  also shrink the paging-cursor hole in Known issues, but that hole should
  be closed on its own — an oldest-first page shape for folds — whether or
  not compaction ever ships.
- Column set is fixed in `cards.zig`; configurable columns would need a
  room-level config action, not a descriptor change.
