# Bug — A round-1 arena forfeit resolves damage the combatant never had a chance to see

## TL;DR

- **What failed:** The round loop (tools/zig/arena.zig) branches on `opening` for a real reply, openingTurn versus resolveTurn, but calls m.forfeitTurn unconditionally. forfeitTurn takes board.incomingTotal(mover) and clears it, which openingTurn's own doc comment says is wrong in a round where nobody has seen anybody. PRD 0008 calls a forfeit a no-op move with 0 damage dealt or blocked. Above two combatants the cost scales with turn index, in the one round with no ordering effect.
- **Impact:** To be confirmed.
- **Resolution:** Open.

## Status

Open.

## Symptom and impact

## Reproduction

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

## Verification

## Follow-up

## References

- Investigation: none yet
