# Bug — A round-1 arena forfeit resolves damage the combatant never had a chance to see

## TL;DR

- **What failed:** The round loop (tools/zig/arena.zig) branches on `opening` for a real reply, openingTurn versus resolveTurn, but calls m.forfeitTurn unconditionally. forfeitTurn takes board.incomingTotal(mover) and clears it, which openingTurn's own doc comment says is wrong in a round where nobody has seen anybody. PRD 0008 calls a forfeit a no-op move with 0 damage dealt or blocked. Above two combatants the cost scales with turn index, in the one round with no ordering effect.
- **Impact:** In Battle Royale mode a round-1 forfeit cost more the later in turn order the combatant sat: the last of eight ate up to 7 x 20 = 140 and could be eliminated on the opening round, while the first ate nothing. Pairwise, a round-1 silence took the opening attack in full and wiped it off the board, so it could never be blocked in round 2 - a garbage reply would have cost less than silence.
- **Resolution:** Resolved on 2026-08-23. forfeitTurn (tools/zig/arena_match.zig) takes the round loop's opening flag; a round-1 forfeit takes nothing and clears nothing. Pinned by two host tests and a live forfeiting match.

## Status

Resolved on 2026-08-23. forfeitTurn (tools/zig/arena_match.zig) takes the round loop's opening flag; a round-1 forfeit takes nothing and clears nothing. Pinned by two host tests and a live forfeiting match.

## Symptom and impact

A combatant whose round-1 call errors, times out or comes back empty is
recorded `forfeit`, and before this fix it also had `board.incomingTotal`
applied to its HP and the board cleared. In round 1 nothing in flight has been
seen by anyone, so that damage was neither answerable nor answered - it was
charged for a failure that could not have happened. The size of the charge is
the combatant's index, which is turn order, so the penalty scaled with a seat
number in the one round PRD 0008 gives no ordering effect.

## Reproduction

Live pairwise match, `--for-provider deepseek --against-provider moonshotai`
(no key, so every call errors and every round is a forfeit), 2 rounds. Post-fix
the round-1 forfeit reads `moonshotai (against) forfeit  100 HP` and the round-2
forfeit `83 HP (-17)`: the opening attack stayed in flight and landed once, in
the round it could have been answered. Pre-fix the same match charged the 17 in
round 1 and the round-2 forfeit was free.

## Root cause

`tools/zig/arena.zig`, round loop. The real-reply path respects `opening`:

```zig
const o = if (opening)
    m.openingTurn(&board, combatants, i, target, reply.move, confidence)
else
    m.resolveTurn(&board, combatants, i, target, reply.move, confidence, credit);
```

The no-reply path does not:

```zig
const o = m.forfeitTurn(&board, combatants, i);
```

`forfeitTurn` (`tools/zig/arena_match.zig`) is
`.{ .taken = board.incomingTotal(mover) }` followed by
`board.clearIncoming(mover)` - exactly what `openingTurn`'s doc comment says
must not happen in round 1: "Separate from `resolveTurn` because that one
clears what is aimed at the mover - correct once a combatant has had a chance
to answer it, wrong in a round where it never saw it."

Consequences:

- Pairwise: A opens at full force, B's call comes back empty. B takes 20
  immediately and A's attack is wiped off the board, so B never gets to block
  it. A round-1 garbage reply would have cost less than round-1 silence.
- Battle Royale: combatant index is turn order, so in an 8-way match a
  round-1 forfeit by `p8` eats up to 7 x 20 = 140 and can be eliminated on
  the opening round, while a round-1 forfeit by `p1` costs 0. Round 1 is the
  one round that is supposed to have no ordering effect at all.

PRD 0008's failure table: "That combatant forfeits the round (treated as a
no-op move, 0 damage dealt or blocked)".

Suggested fix and pin: an `openingForfeit` that counts the forfeit, takes
nothing and clears nothing, selected by the same `opening` flag; a host test
driving `openingTurn(board, cs, 0, 1, .attack, 1.0)` then the round-1 forfeit
and asserting `cs[1].hp == 100` and `board.incomingFrom(0, 1) == 20`.

## Resolution

`forfeitTurn` (`tools/zig/arena_match.zig`) gained an `opening` parameter
rather than a second `openingForfeit` function: the two signatures are
identical, so a separate name is one more thing the round loop can pick wrong,
while a required parameter forces the caller to answer the question. With
`opening` set it returns an empty `Outcome` and leaves the board alone; from
round 2 on it is unchanged. `tools/zig/arena.zig` passes the same `opening`
flag its real-reply path already used to choose between `openingTurn` and
`resolveTurn`.

## Verification

Two host tests in `tools/zig/arena_match.zig`: "a round-1 forfeit takes nothing
and leaves the opening attack in flight" (pairwise; `incomingFrom(0,1)` still
holds `base_damage` afterwards) and "a round-1 forfeit costs the same wherever
the mover sits in turn order" (8-way; first and last mover pay the same, and
all seven opening attacks survive). Both fail when the parameter is ignored -
checked by reverting the body and re-running the filter. `clanker gate`: 11/11
PASS. Live match as under Reproduction.

## Follow-up

The call-site branch itself is not covered by a host test: `arena.zig` is the
WASM shell and its round loop needs `ck_llm`. Same gap the `openingTurn` /
`resolveTurn` branch beside it has had since Battle Royale landed; the live
forfeit match above is what covers it.

## References

- Investigation: none yet
