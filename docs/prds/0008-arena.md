# PRD — Arena (`clanker arena` / `/arena`)

## Status

In progress (Phase 3 open). Sources of truth: `tools/zig/arena.zig`,
`tools/zig/arena_match.zig`, `ui/app/features/arena.js`, and the
CLI/HTTP routes in `src/cli.zig` (`cmdArena`, `GET /api/arena/<id>`).
Surfaces: `clanker arena`, REPL `/arena`, Arena web UI view.

**Shipped:** Phases 1–2 and 4–8 — pairwise match core, CLI/REPL, third-party
judging, web UI arena view, advisory `improve-self` read, design-review
seeding (`--defend` / `--alternative`), Battle Royale mode. Two deliberate
deviations from the first draft (combatant turns go through `ck_llm` rather
than `ck_subagent`; an untargeted move above two combatants is retargeted
rather than refused) are recorded in Known issues and reflected in Design.

**Not shipped:** Phase 3 (multi-instance over a chatroom). Needs two reachable
`clanker serve` peers; partition ordering is decided in Design below.

## Problem

Clanker already lets several agents look at the same question — `providers
check` sweeps for connectivity, shipped `clanker compare` shows independent
answers side by side unlabeled, `ck_swarm` fans a task out to up to 8
parallel members. None of these put two positions in the same room. A model that is confidently wrong
reads identically to a model that is confidently right until something
forces it to answer a specific rebuttal, and clanker has no primitive for
that: `ck_swarm`'s own doc comment is explicit that "members cannot see each
other or the parent's transcript" (`src/sandbox/host.zig`, `ckSwarm`) — by
design, for the batch-fan-out case, but it means arguing is not something a
swarm call can do at all. Building a debate today means hand-rolling a loop
of alternating `ck_subagent` calls and stitching the transcript together by
hand every time, and nothing about that loop is visible anywhere — the Fleet
floor animates read/edit/exec/ask activity per agent, but has no notion of
two agents in conflict over the same question.

Separately: clanker can run combatants two structurally different ways —
nested subagents on threads inside one process (fast, one provider account,
proven by `ck_subagent`/`ck_swarm`) or genuinely separate `clanker serve`
instances talking over HTTP (different providers, different API keys, real
peer processes, proven by the chatrooms/peers machinery). Whichever shape a
debate takes, the moves need one shared, ordered log both shapes can write
to and read from — that log is most of the actual design problem here, not
the pixel art.

## Goals

1. A bounded, sequential multi-round debate primitive: 2-4 combatants, each
   given a position, each seeing every prior move (not just their own) before
   producing their next one, until a match ends.
2. One protocol that works whether combatants are same-process subagents or
   separate peer clanker instances — the caller picks the shape per match,
   the move log and judging logic don't change. **Phase 3 (peer/chatroom
   shape) is open; same-process is shipped.**
3. A verdict at the end: a synthesized answer to the original question,
   traceable to the transcript that produced it, consumable by a human
   (`/arena`, `clanker arena`) or by another process (see Self-improve
   integration).
4. A legible, optional visualization in the web UI built on the Fleet floor's
   existing canvas technique — two facing ranks, sprite attack/block poses,
   HP bars — that never becomes the only place the outcome is visible.
5. A design-review use case for new tools and skills: two candidate
   approaches defend themselves against each other before either is built,
   surfacing weaknesses a single reviewer would miss (see Design → Tool/skill
   design review). This is judging tradeoffs, not measuring output — kept
   distinct from Goal 3's benchmarking-shaped uses on purpose.

## Non-goals

- **Not a promotion gate.** An Arena verdict never blocks or auto-promotes an
  `improve-self` proposal by itself. It is at most an advisory signal a human
  or the engine's existing feedback path can read — turning it into a hard
  gate would hand a self-authored proposal a judge it could learn to
  persuade instead of a check it has to pass, which is exactly the shortest
  path `docs/prompts/self-improve-safety-review.md` exists to catch.
- **Not a replacement for `ck_subagent`/`ck_swarm`.** Those stay the right
  choice whenever a task doesn't need cross-visibility between members —
  cheaper, genuinely parallel, already shipped. Arena exists only for the
  case where seeing the opponent's last move is the point.
- **Not real-time multiplayer.** A match runs to completion (or its round
  cap) inside one tool call or one CLI invocation. Spectating is polling the
  transcript, the same way the Fleet view polls runs today — no new
  transport.
- **Not a general 2D game engine.** The pixel rendering is Fleet's existing
  procedural sprite technique (`fillRect` blocks, `imageSmoothingEnabled =
  false`, no image assets) extended to a battle layout, not a new drawing
  framework or asset pipeline.
- **Not free-for-all by default.** Strict pairwise (2 combatants) is the
  default shape; Battle Royale mode (Design → Battle Royale mode, Phase 8,
  now shipped) is a layer on top of the pairwise core, asked for explicitly
  with a `positions` array, never assumed.

## Design

**Combatants and positions.** A match names a `question` and 2-4
`positions` (each a one-line stance, e.g. "use a message queue" vs. "use
direct calls"). Each position gets a combatant: a `provider` name (falls
back to the configured default) and, optionally, a `persona` string layered
onto its system framing the same way `ck_subagent`'s `Brief` already carries
`parent_task` context. Two positions may share a provider (the same model
arguing against itself is a legitimate, cheaper match shape), but the case
worth defaulting examples to is different providers genuinely disagreeing.

**The move protocol.** Each combatant's turn produces one structured reply:

```json
{"move": "attack", "text": "..."}
```

`move` is one of:

| Move | Meaning | Effect |
|---|---|---|
| `attack` | A new argument or a critique of the opponent's position | Damages the opponent, scaled by the judge's confidence |
| `block` | Directly rebuts the opponent's most recent attack, point by point | Negates that attack's damage if the judge agrees it actually answered the point |
| `counter` | A block that also lands its own attack in the same move | Negates incoming damage and deals its own, only if the judge credits both halves |
| `concede` | Accepts part or all of the opponent's last point | Self-damage, and updates the combatant's own recorded position for the final verdict |
| `final_stand` | A closing argument | Only legal in the last round; no damage, feeds the verdict directly |

A reply that fails to parse as one of these (free text, wrong shape) is
scored as a weak `attack` with a floor confidence — never dropped silently,
since a combatant that can't follow the protocol still said something the
transcript and the verdict should account for.

**Round loop (single-process mode).** For 2 combatants: round 1 is both
positions' opening `attack` (parallel, no prior moves to react to — this is
the one point in a match that could reuse `ck_swarm`'s batch shape). From
round 2 on, combatants move in a fixed order and each one's call includes
every move so far, not just the opponent's; this is a chain of `ck_llm`
completions (see Known issues for why not `ck_subagent`), not a `ck_swarm`
batch, because `ck_swarm` members can't see each other and this loop needs
them to. A round ends when every combatant
has moved once; the match ends when a combatant's HP hits 0, all-but-one
combatant has conceded, or `max_rounds` is reached (default 4, clamped to a
ceiling the way the `rlm` tool's `max_depth` config already clamps its
recursion — a misconfigured value should stay a setting, not a bill).

**Room-backed mode (multi-instance).** When combatants are on different
physical `clanker serve` instances (different peers, potentially different
provider accounts entirely), the shared log is a chatroom: an `arena-<id>`
room, one message per move (`chatrooms.append`, fanned out over the existing
`POST /api/chat/message` peer push — no new transport). A combatant's turn
is: read the room's messages since its last move, run its subagent call over
that transcript, post the reply as the next message. This is the same
`chatrooms.jsonl` + cursor machinery `docs/prds/0001-chatrooms.md` already
specifies, used as a turn-taking log instead of a free-form channel — closer
to how `todo_*` used to ride chat messages before the board took over
(`docs/prds/0003-run-todos.md`) than to normal room chatter. The ordering
guarantee this needs is weaker than a general chat log's: a round doesn't
start until every combatant's move for the previous round is visible, so as
long as each peer waits for its cue before moving (rather than racing to
post), out-of-order delivery across peers is a non-issue in the happy path.

**Decision (before Phase 3):** under a network partition, chatroom delivery
is best-effort. A missing peer move is a forfeit after timeout (reuse
`agent.ask_timeout_seconds`, or an arena-specific timeout if one is added),
not a reorder of the round. The match file records the forfeit explicitly;
there is no attempt to invent an alternate move order from partial delivery.

**Judging and HP.** Each combatant starts at 100 HP. After each move, a
judge call scores it: did the attack land, did the block actually answer the
point, how much damage. Two judge modes, both configurable per match:

- **Self-reported** (default, cheap): the *opponent's next reply* includes an
  implicit concession or contest of the previous move, and damage is derived
  from that — no extra model call, but gameable (a combatant judging its own
  exposure has an incentive to under-report).
- **Third-party judge** (recommended whenever the verdict matters): one
  additional bounded call, on a provider not already fighting the match,
  scores the exchange. Costs one extra call per round but removes the
  self-scoring incentive problem entirely.

**Battle Royale mode (shipped, Phase 8).** The 3-8 combatant free-for-all,
layered on the pairwise core, not the default (see Non-goals). Same move
protocol, one addition: `attack`/`block`/`counter` carry a `target` naming
another combatant's position. A move with no usable `target` when more than
2 combatants are in the match is not refused (a mid-match move has no tool
boundary left to be refused at, and dropping it would contradict "never
dropped silently"): it is aimed by `defaultTarget` (retaliate against
whoever has damage in flight at the mover, else the strongest opponent
left), recorded as `retargeted`, and pays the weak-confidence floor. A round with N
combatants is N independent judged exchanges (attacker vs. its declared
target), not one N-way brawl: the judge call shape stays identical to
pairwise, there are just more of them per round. A combatant at 0 HP is
eliminated for the rest of the match (no longer a legal target, no longer
takes a turn) rather than ending the match, so a battle royale plays out
instead of collapsing at the first knockout. Verdict: last position
standing, or highest HP at the round cap if more than one survives, the
same judged-on-points fallback pairwise already has. Multi-attacker
targeting is resolved cumulatively, per attacker-target pair
(`arena_match.zig`'s `Board`, a pending-damage matrix): each exchange is
judged on its own, a combatant's single turn can block or counter only the
one attack it names, and everything else aimed at it that round lands in
full. Focus-firing is therefore strong (the honest consequence of "a block
answers that attack, point by point"), and there is no holistic per-round
judge call. (The mode's "with cheese" nickname is a nod to the meeting that
approved it, not part of the spec.)

**State and persistence.** A match gets its own file, `state/arena/<id>.json`
— append a move + judge result per round, same shape as `state/runs/run-
<id>.json` already accumulates nodes for an execution graph, not a
chatroom-log fold. The room (multi-instance mode) is the wire format
combatants exchange moves over; the match file is the source of truth for
HP, round count, and the eventual verdict, written by whichever instance is
coordinating the match.

**Verdict output.** At match end: winner (higher HP, or the last position
standing after concessions), a synthesized answer combining the winning
position with any point the loser landed before going down (not just "X
won" — the actual content), and the full move transcript. Returned as the
tool's result and, like clanker's other reasoning-trace tools (`rlm`'s
`state/reasoning.jsonl`, `history`'s promotion log), appended somewhere
replayable rather than only returned once and forgotten.

**Self-improve integration (advisory only).** `src/improve/engine.zig` could
run an Arena match — "promote this proposal" vs. "reject this proposal",
using two configured providers — as a cheap early read before the expensive
`capabilityGate` eval suite runs. If the reject side wins convincingly, that
is worth surfacing in `self.feedback` the same way a failed gate already is,
or logged to history for a human to read later. It must never become a
condition `capabilityGate`, `gate_invariants`, or promotion itself checks —
see Non-goals. This integration is explicitly a later phase, not part of the
initial ship.

**Tool/skill design review (distinct from benchmarking).** Arena is not a
replacement for measuring which of two implementations is faster or more
correct — that question already has a right home: `evals/` +
`capabilityGate` for pass/fail correctness, `docs/prds/0004-autoresearch.md`'s
`command -> scalar` harness for anything with a real metric. What neither of
those does is compare *designs* before either is built, the way the
`docs/prompts/*-review.md` prompts already do for a single reviewer working
alone (`wasm-review.md`'s native-vs-WASM-tool decision tree is the clearest
example). Arena's fit is making that adversarial: two candidate approaches
to a not-yet-built tool or skill (allowlist vs. denylist validation, two
competing wordings of a skill's system prompt, "should this move to WASM"
argued both ways) each defend their own design and attack the other's,
judged like any other match. The output is the same kind of
finding a `*-review.md` prompt already reports — file/line-shaped where
there's code to point at, prompt-wording-shaped for a skill draft — plus the
transcript of *why* one design held up and the other didn't, which a single
reviewer's one-pass verdict doesn't produce. Concretely: seed one position
with "here is my implementation/wording, defend it" and the other with
"here is the alternative, attack the first's weakest assumption," rather
than two abstract stances — the match needs something real to point at on
both sides, not just opinions.

**Worked example (phase 7).** Re-running one of `docs/prompts/wasm-review.md`'s
own move-or-stay decisions as a match, to check the mode against a verdict the
repo already reached:

```
clanker arena "Should the deterministic gate runner stay native in
  src/gate/checks.zig, or move to a WASM tool?" \
  --defend src/gate/checks.zig \
  --alternative "Reimplement the gate as a sandboxed WASM tool ..." --rounds 2
```

`--defend` was given a path, so the real file was read in and travels with the
match; the finding can then name it. Both sides quoted actual identifiers
(`runZigArgs`, `resolveZigBin`, `configWeakeningGate`, `skipIfNoSpawnableZig`),
which is the point of seeding with artifacts rather than stances.

The verdict, in the review shape:

```
Verdict: for
Reason: The alternative's "togglable like any other plugin" breaks the gate's
  non-circumventable safety, which the current implementation preserves by
  staying outside the protected surface.
Where: The phrase "togglable like any other plugin" in the proposed approach.
Respect: The losing side's unaddressed point that runZigArgs uses unsandboxed
  std.process.run, allowing cache writes or network access; for's counter only
  disputed the binary-resolution fallbacks, not the lack of isolation.
Confidence: high
```

That agrees with the decision already in the tree (`checks.zig` is a trust root
and stays native, per the review prompt's own step 1). The part a single-pass
reviewer does not produce is the `Respect` line: the losing side landed a real
objection about `std.process.run` being unsandboxed that the winner never
answered, and the finding says so instead of smoothing it over. Two caveats on
reading too much into one match: both sides shared a provider here, and one
combatant forfeited a round to an empty completion.

**Web UI: the arena view.** Extends the Fleet floor's canvas technique into
a dedicated view, not a mode of Fleet itself — a match is an event with a
start and an end, Fleet's floor is an ambient always-on backdrop, and
conflating the two would make the floor stop being decorative-and-idle the
way its own non-goal requires.

- **DOM, mirroring `#fleet-floor` exactly.** `<div id="arena-stage"
  aria-hidden="true">` wrapping `<canvas id="arena-canvas" width="640"
  height="200" style="image-rendering:pixelated">`, plus a sibling
  `<p id="arena-status" aria-live="polite">` — same split Fleet already
  uses: the canvas is purely decorative (`aria-hidden`), the live region
  carries the actual state in text ("Round 3: kimi-k3 attacks — vertex-opus
  blocks (-8 HP)."), and is *also* what a screen reader or a
  `prefers-reduced-motion` session gets instead of the animation. No new
  a11y surface to design, the pattern already exists and already passed the
  axe-core sweep once.

- **Arena v2: the 3D stage (shipped 2026-08-14).** A `3D` toggle in the
  view's header swaps the pixel canvas for a three.js scene
  (`features/arena3d.js`), per-browser via `localStorage`, defaulting off.
  Same decorative contract, inherited rather than restated: the scene lives
  inside the same `aria-hidden` `#arena-stage`, carries nothing the
  transcript and status line do not, renders one still frame under reduced
  motion, and stops its rAF the moment the view hides. The scene: a ringed
  dais in theme-fog; one solid per combatant slot (icosahedron, octahedron,
  torus knot, …) with the hue the 2D view and Fleet derive from the same
  label hash, so identity survives the dimension change; HP as a depleting
  floor arc; moves as effects (attack/counter arc a glowing bolt,
  block flashes a shield shell, final_stand raises a light pillar, a
  concession sinks and dims, an elimination shatters the solid into
  particles that spiral into the centre — the compactor as a vortex); the
  winner gets an orbiting halo. Camera slow-orbits, drag to steer, wheel to
  zoom. three.js 0.180 is vendored (`ui/vendor/three.module.min.js`
  + `three.core.min.js` — the minified module build is split in two and the
  first imports the second), served under `/webui/vendor/` like mermaid,
  and loaded by dynamic `import()` on first toggle only, so a session that
  never opens 3D never fetches it. A load failure (no WebGL, old browser)
  falls back to the 2D stage and says so in the status line.
- **Stage layout.** Two combatants only (pairwise, per Non-goals), facing
  each other left and right across a ground plane drawn with the same
  tiled-fill technique as Fleet's desk floor, backdrop in `--surface-2` with
  a `--rule` horizon line — no new colors, themes it for free the way Fleet
  already does. Each combatant is the same procedural block-sprite Fleet
  draws (head/torso/arm `fillRect`s, `_colorFor(name)`'s hash-to-hue), just
  posed toward center instead of at a desk. A room-backed (peer) combatant
  is labeled and colored exactly as it already appears in the Fleet roster
  — the same peer looks like the same peer in both views.
- **HP bars.** A segmented pixel bar above each sprite, `fillRect` blocks
  like a SNES health bar, thresholds reusing Fleet's existing bucket palette
  (its `ok`/`tool`/`exec` glow colors) rather than inventing new hex values
  — green above half, amber below half, red in the last segment.
- **Move poses, driven directly by the `move` field.** `attack`: a short
  lunge (translate toward center over a few frames, same `t`-driven timing
  `_floorFrame` already uses for its idle bob, just larger amplitude) plus a
  floating `-N` damage number that rises and fades, drawn with the same
  `10px monospace` `fillText` Fleet already uses for labels — no new font,
  no sprite sheet. `block`: arms-up pose held for the opponent's lunge
  frame, no damage number, a brief flash on the blocking sprite instead.
  `counter`: block pose immediately followed by the attacker's own lunge.
  `concede`: a kneel (torso block shortened, sprite lowered), HP bar dims.
  `final_stand`: held attack pose, no resolution until the verdict.
- **The idle/thinking gap.** A subagent call is a real multi-second wait,
  and a frozen frame during it is exactly the "silent wait" failure mode
  `docs/prompts/delight-review.md`'s rubric scores worst — so between moves
  each sprite keeps Fleet's existing idle bob (`Math.sin(t/420 + i*1.1)`)
  and the status line says who's composing a reply, instead of the stage
  just sitting still.
- **The verdict moment.** Winner holds an arms-up pose with a small flash
  (reusing the lamp-glow `globalAlpha` breathing technique, not a new
  effect), and the status line's final update is the synthesized verdict
  headline — the real text, not just a canvas graphic, matching the "canvas
  plus real text side by side" split below. The loser doesn't just sit in
  its kneel pose: see the next bullet.
- **The eliminated combatant's exit ("trash compactor").** A short, purely
  decorative sequence after the verdict flash, same non-goal as everything
  else on this stage: skippable, and the status line already said who lost
  in words before this plays. A small procedural bulldozer sprite (a body
  block, a blade rect, two tread squares that step-cycle on the same
  `t`-driven timing the idle bob already uses) drives in from the stage
  edge, and the loser's sprite — still in its last kneel/damage pose — gets
  pushed ahead of the blade toward a dark hole rect at the stage's far edge,
  then scales down and fades into it, reusing the fade technique
  the `concede` pose already dims its HP bar with. A brief crossfade cuts to
  a second scene: two solid wall rects closing in from left and right on the
  now-small loser sprite, holding just short of full closure (the point is
  the walls closing, not actually squashing anything) before the view
  returns to the normal stage. In a multi-loser Battle Royale match (Phase
  8), each elimination gets its own bulldozer pass, one at a time, in
  elimination order — not a pile-up. `prefers-reduced-motion` skips the
  whole sequence: no bulldozer, no walls, just the same static final frame
  plus the status line's "`<name>` eliminated" text, which is authoritative
  either way.
- **Data and refresh.** Below the canvas, the actual move transcript
  (text cards, same tool-call card style used everywhere else) — the canvas
  never carries information the transcript doesn't also carry in words,
  same rule Fleet's node-detail panel already follows. A running match
  polls `GET /api/arena/<id>`: a match changes while open, so this needs
  `app.js`'s interval-polling pattern (`syncArchiveLabel`/
  `syncSessionMirror`, ~900-1200ms) rather than Fleet's fetch-once-per-view
  pattern, gated like the vaxis REPL's own tick handler: polling only while
  the match status is "running", stopped the moment it reaches a verdict,
  never a background timer left ticking on a finished match. No new socket:
  the transport constraint is `docs/prds/0006-webui.md`'s, unchanged here.
- **Reduced motion.** No animation loop scheduled at all
  (`prefers-reduced-motion: reduce` skips `requestAnimationFrame` the same
  way `_floorFrame` already does); the canvas renders one static frame of
  the current state and the `aria-live` status text is authoritative,
  exactly Fleet's existing fallback, not a new one.

**REPL / CLI.** `/arena "<question>" --for "<stance>" --against "<stance>"`,
the flag-string-in-text style `/autoresearch` already established in the
slash-command table (`command_registry`, `src/tui/repl.zig`); prints a usage block on
no args the same way. Each round's moves render as transcript cards, one dim
line per move (matching tool-call card style), ending in a verdict block.
`clanker arena` mirrors it non-interactively for scripting, same pattern as
`clanker autoresearch` alongside `/autoresearch`.

**Phase 3 implementation.** Multi-instance / room-backed mode only (Phases 1–2
and 4–8 already shipped):

1. Wire combatant turns to an `arena-<id>` chatroom via `chatrooms.append` and
   peer fan-out (`src/peers/chatrooms.zig`, `POST /api/chat/message`), reading
   room messages since the last move as the turn transcript.
2. Extend `tools/zig/arena_match.zig` (and CLI/HTTP start paths) with a
   room-backed match mode that waits for each peer's cue before posting the
   next move; reuse the partition/forfeit timeout decided above.
3. Record peer forfeits in the match file (`state/arena/<id>.json`) the same
   way timeouts already do; no new transport.
4. Keep canvas / CLI / REPL consumers on `GET /api/arena/<id>` unchanged; they
   already read the shared match file.

## Known issues

Two deliberate deviations from this PRD as first written, kept here so a
reader diffing doc against code knows they are decisions, not drift:

- **Combatant turns go through `ck_llm`, not `ck_subagent`.** A debate move is
  one bounded completion with no tools and no file access, so an agent run
  would only add an iteration loop nothing uses; and `ck_subagent` returns
  `NotFound` outside a parent agent run, which would have made `clanker arena`
  impossible as a plain subcommand. The per-combatant `provider` override that
  makes "different providers genuinely disagreeing" work is a `ck_llm` feature
  already (`providers check` uses it).
- **An untargeted move above two combatants is not refused at the tool
  boundary** (see Battle Royale mode). A mid-match move has no tool boundary
  left to be refused at, and dropping it would contradict "never dropped
  silently", so `defaultTarget` retaliates against whoever has damage in
  flight at the mover, else aims at the strongest opponent left, records the
  move as `retargeted`, and pays the weak-confidence floor.

## Failure modes

| Condition | Behaviour |
|---|---|
| A combatant's reply doesn't parse as a valid move | Scored as a weak `attack`, never dropped (see Move protocol) |
| A combatant's `ck_llm` call errors, times out, or returns empty mid-match | That combatant forfeits the round (treated as a no-op move, 0 damage dealt or blocked); match continues for the remaining combatants |
| `max_rounds` reached with no knockout | Judged on points: higher HP wins, verdict synthesizes both surviving positions weighted by HP |
| A peer goes unreachable mid-match (room-backed mode) | That combatant forfeits remaining rounds the same as a timeout; the match file records it explicitly rather than hanging |
| Third-party judge configured but no extra provider available | Falls back to self-reported judging, logged as a downgrade so the verdict's confidence can be read accordingly |
| A match is asked to start with only 1 position, or with a duplicate position | Refused at the tool boundary — a debate needs at least two distinct sides |
| `positions` length at match start (any mode) | `<2` → too few; `>8` → `"at most 8 positions"`; blank or duplicate stance refused the same way. `validatePositions` accepts 2..8 — pairwise is exactly 2, and 3-8 is Battle Royale mode |
| Invalid `--defend` / design-review input | Tool refuses unless both `defend` and `alternative` are present; do not also pass `for`/`against`/`positions`. A `--defend` value that looks path-shaped but is missing is treated as literal text (CLI `arenaArtifact`), not an error |
| Match file write fails (`state/arena/<id>.json`) | Logged (`persist` catch); the in-process match continues / finishes and still returns a verdict. Spectators polling the file see a stall or a missing final |
| Peer move missing past timeout (Phase 3) | Forfeit for that combatant (see Design partition decision); no reorder |

## Acceptance criteria

Phase 1 — single-process core:

- [x] `arena` WASM tool: match setup, round loop over `ck_llm` (see Known
      issues), move parsing with the weak-attack fallback, self-reported
      judging
- [x] `state/arena/<id>.json` persistence, one entry per round
- [x] Verdict synthesis at match end
- [x] Round cap clamped to a ceiling (mirrors `rlm`'s `max_depth`)

Phase 2 — CLI and REPL:

- [x] `clanker arena "<question>" --for X --against Y`
- [x] `/arena` in `command_registry`, transcript cards per move, verdict block

Phase 3 — multi-instance:

- [ ] `arena-<id>` chatroom convention over the existing peer fan-out
- [ ] Turn-taking cue so peers don't race to post the same round
- [ ] Forfeit handling for an unreachable peer

Phase 4 — third-party judging:

- [x] Judge-provider option, distinct from both combatants
- [x] Fallback to self-reported judging when no third provider is
      configured, logged as a downgrade

Phase 5 — web UI:

- [x] Arena view, `GET /api/arena/<id>` polling only while the match is
      running, stopped on verdict (not a standing background timer)
- [x] Canvas battle layout on the Fleet floor's sprite technique, HP bars,
      attack/block/counter/concede/final_stand poses, idle bob during the
      wait between moves, `prefers-reduced-motion` static fallback
- [x] `aria-live` status caption carrying real state in text, mirroring
      `#fleet-floor-status` — the canvas stays `aria-hidden`
- [x] Real transcript rendered alongside the canvas, never only in it
- [x] Trash-compactor elimination sequence (bulldozer push -> hole -> wall
      closeup), skipped entirely under `prefers-reduced-motion` in favor of
      the status line's static "eliminated" text

Phase 6 — self-improve integration (separate proposal, not this PRD's ship):

- [x] Advisory-only wiring into `engine.zig`'s feedback path
- [x] Explicit test that no gate or invariant can be satisfied by an Arena
      verdict alone

Phase 7 — tool/skill design-review use case:

- [x] Match seeding that takes "implementation/wording to defend" +
      "alternative to attack from," not bare stances
- [x] Worked example against a real past decision (e.g. re-run one of
      `wasm-review.md`'s own move-or-stay verdicts as a match, compare)
- [x] Verdict transcript format usable as review input, matching the
      file/line-shaped finding style `docs/prompts/*-review.md` prompts
      already report

Phase 8 — Battle Royale mode ("with cheese," 3-8 combatants):

- [x] `target` field on `attack`/`block`/`counter` once a match has more
      than 2 combatants (an unusable target is retargeted, not refused; see
      Known issues)
- [x] Elimination at 0 HP instead of match-end; eliminated combatants stop
      taking turns and stop being a legal target
- [x] Last-standing / highest-HP-at-cap verdict, generalized from pairwise's
      existing points fallback
- [x] Resolved: simultaneous multi-attacker targeting is cumulative, per
      attacker-target pair: each exchange judged on its own, one block
      negates only the attack it names, the rest lands in full (see Design →
      Battle Royale mode; `arena_match.zig`'s `Board` and its focus-fire
      tests pin it)

## Open questions / future work

- **Cost/fairness across providers.** A free local model arguing against a
  paid frontier model is not a fair fight in the way that matters for a
  judged debate (one side can afford to think longer per move). Whether
  match config should normalize this (equal token budget per move?) or just
  document the asymmetry is unresolved.
- **Judge bias with only two configured providers.** Third-party judging
  needs a provider that isn't fighting; a two-provider config has none.
  Whether to allow the same provider to judge with a different persona (weak
  isolation) or refuse third-party judging entirely below three configured
  providers is open.
- **Replay/spectator mode.** Watching a finished match's rounds play back in
  the pixel view, distinct from the live-match case Phase 5 covers.
- **Crossover with autoresearch.** Could a match's verdict feed into
  `docs/prds/0004-autoresearch.md`'s harness contract as a `command -> scalar`
  metric (HP delta) for optimization loops that want a debate-shaped scoring
  function instead of a benchmark command? Unexplored.
- **Does adversarial judging actually correlate with build-time outcomes?**
  For the design-review use case, an untested assumption: that the design a
  match favors is also the one that holds up once built and evaled. Worth
  checking a handful of matches against their eventual `capabilityGate`
  results before trusting Arena verdicts as review input rather than just
  another opinion.
