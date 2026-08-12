# PRD — Arena (`clanker arena` / `/arena`)

## Status

Draft. Nothing below is built. Builds on shipped primitives: `ck_subagent`
and `ck_swarm` (`src/sandbox/host.zig`) for nested bounded agent runs,
`src/peers/chatrooms.zig` + the peer HTTP fan-out (`POST /api/chat/message`)
for the multi-instance transport, the Fleet pixel floor's canvas technique
(`tools/zig/webui/features/fleet.js`, `_floorFrame`) as the rendering
substrate, and the board tool's own-file persistence pattern
(`state/board.json`, per `tools/zig/board.zig`) for match state. This PRD's
job is to scope those into one coherent feature before any code is written.

## Problem

Clanker already lets several agents look at the same question — `providers
check` sweeps for connectivity, the planned blind side-by-side comparison
(`docs/ROADMAP.md`, Pi/Odysseus audit) would show independent answers side
by side, `ck_swarm` fans a task out to up to 8 parallel members. None of
these put two positions in the same room. A model that is confidently wrong
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
   the move log and judging logic don't change.
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
  shipped shape; 3-4 combatant matches are an explicit Open question, not
  assumed to fall out for free.

## Design

**Combatants and positions.** A match names a `question` and 2-4
`positions` (each a one-line stance, e.g. "use a message queue" vs. "use
direct calls"). Each position gets a combatant: a `provider` name (falls
back to the configured default) and, optionally, a `persona` string layered
onto its system framing the same way `ck_subagent`'s `Brief` already carries
`parent_task` context. Two positions with the same provider is allowed (the
same model arguing against itself is a legitimate, cheaper match shape) but
the interesting case, and the one worth defaulting examples to, is different
providers genuinely disagreeing.

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
every move so far, not just the opponent's; this is a chain of `ck_subagent`
calls, not a `ck_swarm` batch, precisely because `ck_swarm` members can't see
each other and this loop needs them to. A round ends when every combatant
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
post), out-of-order delivery across peers is a non-issue in practice — worth
a real look under an actual network partition before this ships (see Open
questions), not asserted safe here.

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
tool's result and, matching every other reasoning-trace tool clanker already
has (`rlm`'s `state/reasoning.jsonl`, `history`'s promotion log), appended
somewhere replayable rather than only returned once and forgotten.

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
judged the same way any other match is. The output is the same kind of
finding a `*-review.md` prompt already reports — file/line-shaped where
there's code to point at, prompt-wording-shaped for a skill draft — plus the
transcript of *why* one design held up and the other didn't, which a single
reviewer's one-pass verdict doesn't produce. Concretely: seed one position
with "here is my implementation/wording, defend it" and the other with
"here is the alternative, attack the first's weakest assumption," rather
than two abstract stances — the match needs something real to point at on
both sides, not just opinions.

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
  effect), loser's sprite stays in its last kneel/damage pose, and the
  status line's final update is the synthesized verdict headline — the real
  text, not just a canvas graphic, matching the "canvas plus real text side
  by side" split below.
- **Data and refresh.** Below the canvas, the actual move transcript
  (text cards, same tool-call card style used everywhere else) — the canvas
  never carries information the transcript doesn't also carry in words,
  same rule Fleet's node-detail panel already follows. A running match
  polls `GET /api/arena/<id>` — this view can't reuse Fleet's
  fetch-once-per-view-open pattern, since a match changes over real time
  while open, so it needs the same kind of interval polling `app.js`
  already uses elsewhere (`syncArchiveLabel`/`syncSessionMirror`,
  ~900-1200ms), gated the same way the vaxis REPL's own tick handler is —
  polling only while the match status is "running", stopped the moment it
  reaches a verdict, never a background timer left ticking on a finished
  match. No new socket: `docs/prds/0006-webui.md`'s existing constraint that
  `/api/run`'s stream is the one long-lived channel and everything else is
  polling holds here too.
- **Reduced motion.** No animation loop scheduled at all
  (`prefers-reduced-motion: reduce` skips `requestAnimationFrame` the same
  way `_floorFrame` already does); the canvas renders one static frame of
  the current state and the `aria-live` status text is authoritative,
  exactly Fleet's existing fallback, not a new one.

**REPL / CLI.** `/arena "<question>" --for "<stance>" --against "<stance>"`
in the flag-string-in-text style `/autoresearch` already established in
`command_registry`; prints a usage block on no args the same way. Each
round's moves render as transcript cards, one dim line per move (matching
tool-call card style), ending in a verdict block. `clanker arena` mirrors it
non-interactively for scripting, same pattern as `clanker autoresearch`
alongside `/autoresearch`.

## Failure modes

| Condition | Behaviour |
|---|---|
| A combatant's reply doesn't parse as a valid move | Scored as a weak `attack`, never dropped (see Move protocol) |
| A subagent call errors or times out mid-match | That combatant forfeits the round (treated as a no-op move, 0 damage dealt or blocked); match continues for the remaining combatants |
| `max_rounds` reached with no knockout | Judged on points: higher HP wins, verdict synthesizes both surviving positions weighted by HP |
| A peer goes unreachable mid-match (room-backed mode) | That combatant forfeits remaining rounds the same as a timeout; the match file records it explicitly rather than hanging |
| Third-party judge configured but no extra provider available | Falls back to self-reported judging, logged as a downgrade so the verdict's confidence can be read accordingly |
| A match is asked to start with only 1 position, or with a duplicate position | Refused at the tool boundary — a debate needs at least two distinct sides |

## Acceptance criteria

Phase 1 — single-process core:

- [ ] `arena` WASM tool: match setup, round loop over `ck_subagent`, move
      parsing with the weak-attack fallback, self-reported judging
- [ ] `state/arena/<id>.json` persistence, one entry per round
- [ ] Verdict synthesis at match end
- [ ] Round cap clamped to a ceiling (mirrors `rlm`'s `max_depth`)

Phase 2 — CLI and REPL:

- [ ] `clanker arena "<question>" --for X --against Y`
- [ ] `/arena` in `command_registry`, transcript cards per move, verdict block

Phase 3 — multi-instance:

- [ ] `arena-<id>` chatroom convention over the existing peer fan-out
- [ ] Turn-taking cue so peers don't race to post the same round
- [ ] Forfeit handling for an unreachable peer

Phase 4 — third-party judging:

- [ ] Judge-provider option, distinct from both combatants
- [ ] Fallback to self-reported judging when no third provider is
      configured, logged as a downgrade

Phase 5 — web UI:

- [ ] Arena view, `GET /api/arena/<id>` polling only while the match is
      running, stopped on verdict (not a standing background timer)
- [ ] Canvas battle layout on the Fleet floor's sprite technique, HP bars,
      attack/block/counter/concede/final_stand poses, idle bob during the
      wait between moves, `prefers-reduced-motion` static fallback
- [ ] `aria-live` status caption carrying real state in text, mirroring
      `#fleet-floor-status` — the canvas stays `aria-hidden`
- [ ] Real transcript rendered alongside the canvas, never only in it

Phase 6 — self-improve integration (separate proposal, not this PRD's ship):

- [ ] Advisory-only wiring into `engine.zig`'s feedback path
- [ ] Explicit test that no gate or invariant can be satisfied by an Arena
      verdict alone

Phase 7 — tool/skill design-review use case:

- [ ] Match seeding that takes "implementation/wording to defend" +
      "alternative to attack from," not bare stances
- [ ] Worked example against a real past decision (e.g. re-run one of
      `wasm-review.md`'s own move-or-stay verdicts as a match, compare)
- [ ] Verdict transcript format usable as review input, matching the
      file/line-shaped finding style `docs/prompts/*-review.md` prompts
      already report

## Open questions / future work

- **3-4 combatant matches.** The move protocol and round loop above are
  written for strict pairwise; a free-for-all changes both "who does a
  block target" and how HP/judging generalizes. Worth a follow-up once
  pairwise has real mileage, not designed blind here.
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
- **Multi-instance ordering under a real network partition**, not just the
  cue-based happy path described in Design.
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
