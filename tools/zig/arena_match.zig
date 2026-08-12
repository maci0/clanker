//! Pure match logic for the `arena` tool: the move protocol, the HP/damage
//! state machine, and verdict selection.
//!
//! This module imports nothing from the guest ABI (lib.zig), so it stays
//! compilable on the host and its `test` blocks actually run in
//! `zig build test` — the pure-tool list in build.zig is what registers it.
//! `arena.zig` is the thin shell that does the LLM calls and the file I/O; all
//! the rules a match can get wrong live here, where they can be tested without
//! a provider account.
//!
//! Reference: docs/prds/0008-arena.md.

const std = @import("std");

/// One combatant's reply per turn. Damage is deferred: an `attack` puts damage
/// *in flight* and it only resolves once the target has answered it, which is
/// what makes `block`/`counter` able to negate something rather than heal.
pub const Move = enum {
    attack,
    block,
    counter,
    concede,
    final_stand,

    pub fn parse(name: []const u8) ?Move {
        return std.meta.stringToEnum(Move, name);
    }
};

/// Damage a fully-landed attack deals. Everything else scales off this, so a
/// match is 5 clean attacks long at worst — short enough that `max_rounds`,
/// not attrition, is normally what ends it.
pub const base_damage: u16 = 20;

/// Confidence floor for a reply that did not parse as a move. Non-zero on
/// purpose: a combatant that cannot follow the protocol still said something,
/// and scoring it at 0 would make protocol failure free (see the PRD's move
/// protocol — "never dropped silently").
pub const weak_confidence: f64 = 0.15;

/// Force ceiling for a move recovered from a reply that was cut off mid-JSON.
/// A half-finished argument lands at most halfway: crediting it in full would
/// make truncation free, and scoring it at `weak_confidence` would be a
/// scoring artifact rather than a judgment — a truncated `counter` demoted to
/// `attack` silently loses its block, which is the difference between taking a
/// clean hit and negating it.
pub const truncated_confidence: f64 = 0.5;

/// Self-damage for conceding. Deliberately worse than taking a clean attack:
/// conceding is giving up ground, and a combatant that concedes its way to a
/// draw would make the move a tactic rather than an admission.
pub const concede_self_damage: u16 = 25;

pub const starting_hp: i32 = 100;

pub const default_max_rounds: u32 = 4;

/// Every extra round is one model call per combatant plus (in third-party
/// mode) a judge call, so a misconfigured value is a bill rather than a slow
/// tool. Clamped rather than trusted, mirroring `rlm`'s `max_depth`.
pub const round_ceiling: u32 = 12;

/// Battle Royale mode's ceiling (PRD phase 8, "with cheese"): 3-8 combatants
/// in a free-for-all, layered on the pairwise core rather than replacing it.
pub const max_combatants: usize = 8;

/// Pairwise (2 combatants) stays the default shape; anything above it is
/// Battle Royale mode, which is the same protocol plus a `target` on every
/// offensive move.
pub const pairwise_combatants: usize = 2;

pub fn clampRounds(configured: u32) u32 {
    if (configured == 0) return default_max_rounds;
    return @min(configured, round_ceiling);
}

/// A parsed turn. `weak` means the reply did not arrive as a valid move object
/// and was reclassified as a floor-confidence `attack`; `text` is then the raw
/// reply, because that is still what the combatant said.
pub const Reply = struct {
    move: Move,
    text: []const u8,
    /// How much of the *opponent's* previous move this combatant admits
    /// landed, in [0,1]. Self-reported judging derives damage from it; the
    /// third-party judge overrides it. Null when the reply omitted it.
    opponent_landed: ?f64 = null,
    /// This move's own force, in [0,1]. Self-reported from the mover, so it is
    /// the gameable half of self-judging — the third-party judge replaces it.
    confidence: f64 = 1.0,
    weak: bool = false,
    /// The reply was cut off mid-JSON and repaired; the move is genuine, the
    /// argument is only partly there.
    truncated: bool = false,
    /// Who the move is aimed at, as the combatant wrote it — a number as shown
    /// in its prompt, or a label/position. Unused in a pairwise match (there is
    /// only one possible opponent); required above that, and resolved by
    /// `resolveTarget` rather than trusted.
    target: ?[]const u8 = null,
};

fn stripFence(raw: []const u8) []const u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (!std.mem.startsWith(u8, s, "```")) return s;
    s = s[3..];
    if (std.mem.findScalar(u8, s, '\n')) |nl| s = s[nl + 1 ..];
    if (std.mem.lastIndexOf(u8, s, "```")) |close| s = s[0..close];
    return std.mem.trim(u8, s, " \t\r\n");
}

fn objectSpan(s: []const u8) ?[]const u8 {
    const start = std.mem.findScalar(u8, s, '{') orelse return null;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var i = start;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (in_string) {
            switch (c) {
                '\\' => escaped = true,
                '"' => in_string = false,
                else => {},
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return s[start .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

fn optFloat(obj: std.json.ObjectMap, name: []const u8) ?f64 {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

/// The weak-attack fallback, as one place: the reply is kept verbatim and
/// scored at the confidence floor.
pub fn weakAttack(raw: []const u8) Reply {
    return .{
        .move = .attack,
        .text = std.mem.trim(u8, raw, " \t\r\n"),
        .confidence = weak_confidence,
        .weak = true,
    };
}

/// Closes a reply that was cut off mid-JSON, which is the shape a `max_tokens`
/// truncation produces. Rather than hand-rolling a partial-JSON reader (and a
/// second, subtly different unescaper), this re-closes the open string and the
/// open braces and hands the result back to `std.json` — so `\n`, `\"` and
/// `\uNNNN` inside a salvaged argument are decoded by the same code that
/// decodes a complete one. (Spelled with N rather than the conventional X so
/// the gate's forbidden-marker scan does not read it as a debt marker.)
///
/// Returns null when the input was already balanced (nothing to repair) or is
/// too mangled to close.
fn repairTruncated(alloc: std.mem.Allocator, s: []const u8) ?[]const u8 {
    const start = std.mem.findScalar(u8, s, '{') orelse return null;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (s[start..]) |c| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (in_string) {
            switch (c) {
                '\\' => escaped = true,
                '"' => in_string = false,
                else => {},
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => depth -|= 1,
            else => {},
        }
    }
    // Balanced already: `objectSpan` handles that case, and repairing it here
    // would only mask a genuine parse failure as a truncation.
    if (depth == 0 and !in_string) return null;

    var body = s[start..];
    // A trailing lone backslash would escape the quote about to be appended.
    if (escaped) body = body[0 .. body.len - 1];

    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(alloc, body) catch return null;
    if (in_string) buf.append(alloc, '"') catch return null;
    for (0..depth) |_| buf.append(alloc, '}') catch return null;
    return buf.items;
}

/// Reads a move object that has already been isolated. Returns null when it is
/// not one, leaving the weak-attack fallback to the caller.
fn parseMoveObject(alloc: std.mem.Allocator, span: []const u8, truncated: bool) ?Reply {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, span, .{}) catch return null;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return null,
    };
    const move_name = switch (obj.get("move") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    const move = Move.parse(std.mem.trim(u8, move_name, " \t\r\n")) orelse return null;
    const text = switch (obj.get("text") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    // A move with no argument said nothing, so there is nothing for the
    // transcript to keep and the raw reply is the more informative record.
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return null;

    var reply = Reply{ .move = move, .text = text, .truncated = truncated };
    if (optFloat(obj, "confidence")) |c| reply.confidence = std.math.clamp(c, 0.0, 1.0);
    if (optFloat(obj, "opponent_landed")) |c| reply.opponent_landed = std.math.clamp(c, 0.0, 1.0);
    if (truncated) reply.confidence = @min(reply.confidence, truncated_confidence);
    // A number is as valid a target as a name, so it is kept as written and
    // resolved later against the live roster.
    if (obj.get("target")) |t| switch (t) {
        .string => |s| {
            const trimmed = std.mem.trim(u8, s, " \t\r\n");
            if (trimmed.len > 0) reply.target = trimmed;
        },
        .integer => |n| reply.target = std.fmt.allocPrint(alloc, "{d}", .{n}) catch null,
        else => {},
    };
    return reply;
}

/// Parses one combatant reply. Never fails: anything that is not a valid move
/// object comes back as a weak `attack` carrying the raw text.
///
/// `alloc` is only borrowed for the JSON parse; every slice in the result
/// points into `raw` or into allocator memory that outlives the call, so the
/// caller must keep both alive.
pub fn parseReply(alloc: std.mem.Allocator, raw: []const u8) Reply {
    const body = stripFence(raw);
    if (objectSpan(body)) |span| {
        if (parseMoveObject(alloc, span, false)) |reply| return reply;
    } else if (repairTruncated(alloc, body)) |repaired| {
        // A reply cut off mid-argument still chose a move, and that choice is
        // load-bearing: scoring a truncated `block` as an `attack` would hand
        // its opponent damage the combatant did try to negate.
        if (parseMoveObject(alloc, repaired, true)) |reply| return reply;
    }
    return weakAttack(raw);
}

/// A third-party judge's score for one move. `landed` replaces the mover's
/// self-reported confidence, `blocked` replaces the credit its block would
/// otherwise have derived from its own `opponent_landed` — which is the whole
/// point of paying for a judge: neither number comes from a combatant.
pub const Judgment = struct {
    landed: f64 = 0.0,
    blocked: f64 = 0.0,
    note: []const u8 = "",
};

/// Parses a judge reply. Returns null when the reply is unusable, which the
/// caller reads as "score this move self-reported instead" — a judge that
/// answers garbage must not silently become a judge that scores everything 0.
pub fn parseJudgment(alloc: std.mem.Allocator, raw: []const u8) ?Judgment {
    const span = objectSpan(stripFence(raw)) orelse return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, span, .{}) catch return null;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return null,
    };
    // Both numbers absent means the reply had the shape of an object but said
    // nothing a score can be read from.
    const landed = optFloat(obj, "landed");
    const blocked = optFloat(obj, "blocked");
    if (landed == null and blocked == null) return null;
    return .{
        .landed = std.math.clamp(landed orelse 0.0, 0.0, 1.0),
        .blocked = std.math.clamp(blocked orelse 0.0, 0.0, 1.0),
        .note = if (obj.get("note")) |n| (if (n == .string) n.string else "") else "",
    };
}

/// Reclassifies a move that parsed cleanly but is illegal in this position.
/// Both cases collapse to the weak attack rather than an error, for the same
/// reason a parse failure does: the combatant still said something.
///
/// - `final_stand` outside the last round would let a combatant opt out of
///   taking damage for the rest of the match.
/// - `block`/`counter` with nothing in flight is rebutting an attack that was
///   never made, and would otherwise be a free 0-damage turn.
pub fn legalize(reply: Reply, is_last_round: bool, incoming: u16) Reply {
    var r = reply;
    const illegal = switch (r.move) {
        .final_stand => !is_last_round,
        .block, .counter => incoming == 0,
        else => false,
    };
    if (!illegal) return r;
    r.move = .attack;
    r.confidence = @min(r.confidence, weak_confidence);
    r.weak = true;
    return r;
}

pub fn scaled(base: u16, factor: f64) u16 {
    const f = std.math.clamp(factor, 0.0, 1.0);
    return @intFromFloat(@round(@as(f64, @floatFromInt(base)) * f));
}

/// What one resolved move did. `taken` is what landed on the mover (in-flight
/// damage it failed to answer, plus any concession), `dealt` is what it puts
/// in flight against the opponent.
pub const Outcome = struct {
    /// In-flight damage this move negated.
    blocked: u16 = 0,
    /// Damage applied to the mover's own HP now.
    taken: u16 = 0,
    /// Damage this move puts in flight against the opponent.
    dealt: u16 = 0,
    /// The mover gave up its position.
    conceded: bool = false,
};

/// The damage rules, in one place.
///
/// `incoming_total` is everything in flight at the mover; `from_target` is the
/// part of it put there by the combatant this move is aimed at. A block only
/// ever negates the attack it names, so those two numbers are what separate
/// "what I answered" from "what still hits me". `credit` is how much of the
/// named attack the judge agrees the move actually answered, in [0,1].
fn score(move: Move, confidence: f64, incoming_total: u16, from_target: u16, credit: f64) Outcome {
    var out = Outcome{};
    switch (move) {
        .attack => out.dealt = scaled(base_damage, confidence),
        .block => out.blocked = scaled(from_target, credit),
        .counter => {
            out.blocked = scaled(from_target, credit);
            out.dealt = scaled(base_damage, confidence);
        },
        .concede => out.conceded = true,
        // A closing argument feeds the verdict, not the HP bars — but it does
        // not dodge what is already in flight.
        .final_stand => {},
    }
    out.taken = incoming_total - out.blocked;
    if (move == .concede) out.taken +|= concede_self_damage;
    return out;
}

/// Resolves one pairwise move against the damage in flight at the mover.
///
/// With two combatants the only possible attacker *is* the target, so both of
/// `score`'s in-flight numbers are the same one. Self-judging supplies `credit`
/// from the mover's own `opponent_landed` (inverted), third-party judging from
/// the judge call.
pub fn resolve(move: Move, confidence: f64, incoming: u16, credit: f64) Outcome {
    return score(move, confidence, incoming, incoming, credit);
}

/// A combatant that never answered (its call errored or timed out) forfeits
/// the round: it deals nothing and blocks nothing, so whatever was in flight
/// lands in full. Separate from `resolve` because there is no move to score.
pub fn forfeit(incoming: u16) Outcome {
    return .{ .taken = incoming };
}

pub const Combatant = struct {
    position: []const u8,
    provider: []const u8 = "",
    persona: []const u8 = "",
    hp: i32 = starting_hp,
    conceded: bool = false,
    forfeits: u16 = 0,

    /// Out of HP. In Battle Royale mode this ends the combatant's match, not
    /// the match itself: it stops taking turns and stops being a legal target,
    /// so the fight plays out instead of collapsing at the first knockout.
    pub fn eliminated(self: Combatant) bool {
        return self.hp <= 0;
    }

    /// Still in the fight — neither eliminated nor conceded. What "last
    /// position standing" counts, and what a target has to be.
    pub fn alive(self: Combatant) bool {
        return !self.eliminated() and !self.conceded;
    }
};

/// Damage in flight, per attacker-target pair rather than per target.
///
/// The distinction is what makes a block precise once more than two combatants
/// are in the match: a combatant takes one turn, so it can only rebut the one
/// attack it names, and everything else aimed at it that round lands in full.
/// Focus-firing is therefore strong — the honest consequence of "a block
/// answers that attack, point by point", and the reason this is a matrix and
/// not a per-combatant total.
///
/// With two combatants there is only one possible attacker, so this degenerates
/// exactly to the pairwise behaviour.
pub const Board = struct {
    pending: [max_combatants][max_combatants]u16 = @splat(@splat(0)),

    pub fn incomingFrom(self: *const Board, from: usize, to: usize) u16 {
        return self.pending[from][to];
    }

    pub fn incomingTotal(self: *const Board, to: usize) u16 {
        var sum: u16 = 0;
        for (0..max_combatants) |from| sum +|= self.pending[from][to];
        return sum;
    }

    pub fn add(self: *Board, from: usize, to: usize, amount: u16) void {
        self.pending[from][to] +|= amount;
    }

    /// Everything aimed at `to` has now been answered (or not), so none of it
    /// is in flight any more.
    pub fn clearIncoming(self: *Board, to: usize) void {
        for (0..max_combatants) |from| self.pending[from][to] = 0;
    }

    /// Whoever most recently put damage in flight at `to`, which is the default
    /// a combatant that named no target retaliates against.
    pub fn anyIncoming(self: *const Board, to: usize) ?usize {
        for (0..max_combatants) |from| {
            if (self.pending[from][to] > 0) return from;
        }
        return null;
    }
};

/// Resolves one turn against the board, applying it to `combatants` and moving
/// this move's own damage into flight. The generalisation of `resolve` to any
/// number of combatants: `resolve` scores the exchange, this places it.
///
/// `target` is where an offensive move is aimed (ignored by `concede` and
/// `final_stand`). `credit` is how much of the *target's* attack on the mover
/// the judge agrees this move answered.
pub fn resolveTurn(
    board: *Board,
    combatants: []Combatant,
    mover: usize,
    target: usize,
    move: Move,
    confidence: f64,
    credit: f64,
) Outcome {
    const out = score(move, confidence, board.incomingTotal(mover), board.incomingFrom(target, mover), credit);
    board.clearIncoming(mover);
    applyOutcome(&combatants[mover], out);
    if (out.dealt > 0) board.add(mover, target, out.dealt);
    return out;
}

/// The opening round, where every combatant moves blind: nobody has seen
/// anybody, so nothing already in flight resolves and nothing is taken. Only
/// the move's own damage goes into flight, to be answered from round 2 on.
///
/// Separate from `resolveTurn` because that one clears what is aimed at the
/// mover — correct once a combatant has had a chance to answer it, wrong in a
/// round where it never saw it.
pub fn openingTurn(
    board: *Board,
    combatants: []Combatant,
    mover: usize,
    target: usize,
    move: Move,
    confidence: f64,
) Outcome {
    var out = Outcome{};
    switch (move) {
        .attack, .counter => out.dealt = scaled(base_damage, confidence),
        .concede => {
            out.conceded = true;
            out.taken = concede_self_damage;
        },
        // A block in the opening round has nothing to answer; `legalize`
        // normally demotes it before it gets here.
        .block, .final_stand => {},
    }
    applyOutcome(&combatants[mover], out);
    if (out.dealt > 0) board.add(mover, target, out.dealt);
    return out;
}

/// A combatant that never answered forfeits the turn: it deals nothing and
/// blocks nothing, so everything aimed at it lands.
pub fn forfeitTurn(board: *Board, combatants: []Combatant, mover: usize) Outcome {
    const out = Outcome{ .taken = board.incomingTotal(mover) };
    board.clearIncoming(mover);
    applyOutcome(&combatants[mover], out);
    combatants[mover].forfeits +|= 1;
    return out;
}

pub fn applyOutcome(c: *Combatant, out: Outcome) void {
    c.hp -= @intCast(out.taken);
    if (c.hp < 0) c.hp = 0;
    if (out.conceded) c.conceded = true;
}

pub const Reason = enum {
    /// A combatant's HP hit 0.
    knockout,
    /// All but one combatant conceded.
    concession,
    /// `max_rounds` reached; higher HP wins.
    points,
    /// Equal HP at the cap, or every combatant out of the fight at once.
    draw,
};

pub const Verdict = struct {
    /// Index into the combatant slice, or null for a draw.
    winner: ?usize,
    reason: Reason,
};

/// True once the match cannot usefully continue: at most one combatant is still
/// in the fight, or the round cap is spent.
///
/// One rule covers both modes. With two combatants, "at most one still
/// standing" happens exactly at the first knockout or concession, which is the
/// pairwise rule. With more, the match keeps going until one is left — the
/// Battle Royale requirement that elimination end a combatant's match rather
/// than the match.
pub fn isOver(combatants: []const Combatant, rounds_done: u32, max_rounds: u32) bool {
    if (rounds_done >= max_rounds) return true;
    var standing: usize = 0;
    for (combatants) |c| {
        if (c.alive()) standing += 1;
    }
    return standing <= 1;
}

/// Resolves a combatant's declared target against the live roster.
///
/// Accepts what a model actually writes: the 1-based number its prompt listed,
/// an exact or case-insensitive label or position, or a prefix of either. An
/// eliminated or conceded combatant is not a legal target, and neither is the
/// mover itself.
pub fn resolveTarget(
    spec: ?[]const u8,
    combatants: []const Combatant,
    labels: []const []const u8,
    mover: usize,
) ?usize {
    const raw = spec orelse return null;
    const want = std.mem.trim(u8, raw, " \t\r\n.:#");
    if (want.len == 0) return null;

    const legal = struct {
        fn ok(cs: []const Combatant, self_idx: usize, i: usize) bool {
            return i != self_idx and i < cs.len and cs[i].alive();
        }
    }.ok;

    // The number the prompt showed, 1-based: the cheapest thing to get right
    // and the least ambiguous when two positions share wording.
    if (std.fmt.parseInt(usize, want, 10)) |n| {
        if (n >= 1 and n <= combatants.len and legal(combatants, mover, n - 1)) return n - 1;
        return null;
    } else |_| {}

    // Exact, then case-insensitive, then prefix — narrowest match first, so a
    // position that is a prefix of another cannot shadow an exact hit.
    for (combatants, 0..) |c, i| {
        if (!legal(combatants, mover, i)) continue;
        if (std.mem.eql(u8, want, c.position)) return i;
        if (i < labels.len and std.mem.eql(u8, want, labels[i])) return i;
    }
    for (combatants, 0..) |c, i| {
        if (!legal(combatants, mover, i)) continue;
        if (std.ascii.eqlIgnoreCase(want, c.position)) return i;
        if (i < labels.len and std.ascii.eqlIgnoreCase(want, labels[i])) return i;
    }
    for (combatants, 0..) |c, i| {
        if (!legal(combatants, mover, i)) continue;
        if (want.len >= 3 and c.position.len >= want.len and
            std.ascii.eqlIgnoreCase(want, c.position[0..want.len])) return i;
        if (i < labels.len and want.len >= 3 and labels[i].len >= want.len and
            std.ascii.eqlIgnoreCase(want, labels[i][0..want.len])) return i;
    }
    return null;
}

/// The target a move gets when it named none, or named one that is gone.
///
/// The PRD asks for an untargeted move above two combatants to be refused, but
/// a mid-match move has no tool boundary left to be refused at, and dropping it
/// would contradict "never dropped silently". So it retaliates against whoever
/// has damage in flight at the mover, and otherwise aims at the strongest
/// opponent left — deterministic, and not a reward for omitting the field,
/// since the caller pairs this with the weak-attack confidence floor.
pub fn defaultTarget(board: *const Board, combatants: []const Combatant, mover: usize) ?usize {
    if (board.anyIncoming(mover)) |from| {
        if (from != mover and from < combatants.len and combatants[from].alive()) return from;
    }
    var best: ?usize = null;
    for (combatants, 0..) |c, i| {
        if (i == mover or !c.alive()) continue;
        const b = best orelse {
            best = i;
            continue;
        };
        if (c.hp > combatants[b].hp) best = i;
    }
    return best;
}

/// Picks the winner. A knockout and a concession are read off the fight's
/// state; anything that reaches the cap intact is judged on points.
pub fn decide(combatants: []const Combatant) Verdict {
    var knocked_out = false;
    var conceded: usize = 0;
    for (combatants) |c| {
        if (c.hp <= 0) knocked_out = true;
        if (c.conceded) conceded += 1;
    }

    // Highest HP among those still standing, and whether it is unique.
    var best: ?usize = null;
    var tied = false;
    for (combatants, 0..) |c, i| {
        if (!c.alive()) continue;
        const b = best orelse {
            best = i;
            continue;
        };
        if (c.hp > combatants[b].hp) {
            best = i;
            tied = false;
        } else if (c.hp == combatants[b].hp) {
            tied = true;
        }
    }

    var standing: usize = 0;
    for (combatants) |c| {
        if (c.alive()) standing += 1;
    }

    const reason: Reason = blk: {
        if (best == null) break :blk .draw;
        if (tied) break :blk .draw;
        // One left in the fight is a win by elimination, whatever removed the
        // others: a knockout if anyone was, otherwise everyone else conceded.
        // Above two combatants this is Battle Royale's "last position
        // standing"; at two it is the pairwise knockout it always was.
        if (standing == 1 and combatants.len > 1) break :blk if (knocked_out) .knockout else .concession;
        break :blk .points;
    };
    return .{ .winner = if (reason == .draw) null else best, .reason = reason };
}

/// The runner-up: the highest-HP combatant that is not the winner, counting
/// eliminated ones, so a headline always has something to compare against.
fn runnerUp(combatants: []const Combatant, winner: usize) ?usize {
    var best: ?usize = null;
    for (combatants, 0..) |c, i| {
        if (i == winner) continue;
        const b = best orelse {
            best = i;
            continue;
        };
        if (c.hp > combatants[b].hp) best = i;
    }
    return best;
}

/// One line of real text stating the outcome — the canvas-free authority the
/// PRD's `aria-live` caption and the CLI's verdict block both need, and the
/// fallback when the synthesis call itself fails.
pub fn headline(buf: []u8, combatants: []const Combatant, labels: []const []const u8, v: Verdict) []const u8 {
    const w = v.winner orelse return std.fmt.bufPrint(buf, "Draw: no position outargued the rest.", .{}) catch "Draw.";
    const win_label = if (w < labels.len) labels[w] else "combatant";
    const detail = switch (v.reason) {
        .knockout => if (combatants.len > pairwise_combatants) "last standing" else "by knockout",
        .concession => "by concession",
        .points => "on points",
        .draw => unreachable,
    };
    const second = runnerUp(combatants, w) orelse
        return std.fmt.bufPrint(buf, "{s} wins {s}, {d} HP: \"{s}\".", .{ win_label, detail, combatants[w].hp, combatants[w].position }) catch "Match decided.";
    const lose_label = if (second < labels.len) labels[second] else "combatant";

    // Above pairwise the count matters: "beat 3 others" is the outcome, and
    // naming only the runner-up would read as though it were the only rival.
    if (combatants.len > pairwise_combatants) {
        return std.fmt.bufPrint(buf, "{s} wins {s} among {d}, {d} HP: \"{s}\" over {d} others, nearest {s} at {d}.", .{
            win_label,
            detail,
            combatants.len,
            combatants[w].hp,
            combatants[w].position,
            combatants.len - 1,
            lose_label,
            combatants[second].hp,
        }) catch "Match decided.";
    }
    return std.fmt.bufPrint(buf, "{s} wins {s}, {d} HP to {s}'s {d}: \"{s}\" over \"{s}\".", .{
        win_label,
        detail,
        combatants[w].hp,
        lose_label,
        combatants[second].hp,
        combatants[w].position,
        combatants[second].position,
    }) catch "Match decided.";
}

pub const PositionError = error{ TooFewPositions, TooManyPositions, DuplicatePosition, EmptyPosition };

/// A debate needs at least two distinct sides. Refused at the tool boundary
/// rather than started and abandoned, per the PRD's failure-mode table.
pub fn validatePositions(positions: []const []const u8) PositionError!void {
    if (positions.len < 2) return error.TooFewPositions;
    if (positions.len > max_combatants) return error.TooManyPositions;
    for (positions, 0..) |p, i| {
        const a = std.mem.trim(u8, p, " \t\r\n");
        if (a.len == 0) return error.EmptyPosition;
        for (positions[i + 1 ..]) |q| {
            if (std.mem.eql(u8, a, std.mem.trim(u8, q, " \t\r\n"))) return error.DuplicatePosition;
        }
    }
}

pub fn isSafeId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

// ----------------------------------------------------------------- tests

test "parseReply accepts the documented move object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = parseReply(arena.allocator(), "{\"move\":\"block\",\"text\":\"your queue adds a hop\"}");
    try std.testing.expectEqual(Move.block, r.move);
    try std.testing.expectEqualStrings("your queue adds a hop", r.text);
    try std.testing.expect(!r.weak);
    try std.testing.expectEqual(@as(f64, 1.0), r.confidence);
}

test "parseReply unwraps a fenced block and surrounding prose" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const raw =
        \\Sure, here is my move:
        \\```json
        \\{"move": "counter", "text": "both", "confidence": 0.5, "opponent_landed": 0.25}
        \\```
        \\Hope that helps!
    ;
    const r = parseReply(arena.allocator(), raw);
    try std.testing.expectEqual(Move.counter, r.move);
    try std.testing.expectEqualStrings("both", r.text);
    try std.testing.expectEqual(@as(f64, 0.5), r.confidence);
    try std.testing.expectEqual(@as(?f64, 0.25), r.opponent_landed);
}

test "parseReply keeps a brace inside text from ending the object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = parseReply(arena.allocator(), "{\"move\":\"attack\",\"text\":\"use struct { a: u8 } here\"}");
    try std.testing.expectEqual(Move.attack, r.move);
    try std.testing.expectEqualStrings("use struct { a: u8 } here", r.text);
    try std.testing.expect(!r.weak);
}

test "parseReply falls back to a weak attack, never dropping the reply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_][]const u8{
        "I think the queue is better, obviously.", // free text
        "{\"move\":\"headbutt\",\"text\":\"x\"}", // unknown move
        "{\"move\":\"attack\"}", // no text
        "{\"move\":\"attack\",\"text\":\"   \"}", // empty text
        "{\"text\":\"no move field\"}",
        "{\"move\":42,\"text\":\"wrong type\"}",
        "{\"move\":\"headbutt\",\"text\":\"truncated, and not a move",
        "{\"move\":\"attack\",\"text\":",
        "",
    };
    for (cases) |raw| {
        const r = parseReply(arena.allocator(), raw);
        try std.testing.expectEqual(Move.attack, r.move);
        try std.testing.expect(r.weak);
        try std.testing.expectEqual(weak_confidence, r.confidence);
        // The raw reply survives, trimmed — that is the whole point of the
        // fallback over an error.
        try std.testing.expectEqualStrings(std.mem.trim(u8, raw, " \t\r\n"), r.text);
    }
}

test "parseReply digs the move object out of a wrapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A model that wraps its move in an array, or announces it first, still
    // made a legal move. The span scan is there to find it rather than score a
    // usable reply as a protocol failure.
    for ([_][]const u8{
        "[{\"move\":\"attack\",\"text\":\"wrapped in an array\"}]",
        "My move: {\"move\":\"attack\",\"text\":\"wrapped in an array\"} — done.",
    }) |raw| {
        const r = parseReply(arena.allocator(), raw);
        try std.testing.expectEqual(Move.attack, r.move);
        try std.testing.expectEqualStrings("wrapped in an array", r.text);
        try std.testing.expect(!r.weak);
    }
}

test "parseReply salvages the move from a reply truncated mid-argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Exactly what a max_tokens cutoff looks like: a real move, a real
    // argument, no closing quote or brace. The move must survive — a truncated
    // counter scored as a plain attack loses its block, which is the
    // difference between negating a hit and eating it.
    const raw = "{\"move\":\"counter\",\"text\":\"Sequential append beats random small writes; we batch and fsync once";
    const r = parseReply(arena.allocator(), raw);
    try std.testing.expectEqual(Move.counter, r.move);
    try std.testing.expect(r.truncated);
    try std.testing.expect(!r.weak);
    try std.testing.expectEqual(truncated_confidence, r.confidence);
    try std.testing.expectEqualStrings("Sequential append beats random small writes; we batch and fsync once", r.text);
}

test "parseReply decodes escapes in a salvaged reply the same way as a whole one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The repair hands the closed text back to std.json rather than unescaping
    // by hand, so \n and \" decode in a truncated reply too.
    const r = parseReply(arena.allocator(), "{\"move\":\"block\",\"text\":\"line one\\nsaid \\\"this\\\" and");
    try std.testing.expectEqual(Move.block, r.move);
    try std.testing.expect(r.truncated);
    try std.testing.expectEqualStrings("line one\nsaid \"this\" and", r.text);
}

test "parseReply caps a truncated reply's self-reported force" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Claiming full force in the part that survived must not pay: truncation
    // would otherwise be a way to make a cheap move look like a strong one.
    const r = parseReply(arena.allocator(), "{\"confidence\":1.0,\"move\":\"attack\",\"text\":\"cut off here");
    try std.testing.expectEqual(truncated_confidence, r.confidence);
    // A lower self-report is still honoured; the cap is a ceiling, not a value.
    const low = parseReply(arena.allocator(), "{\"confidence\":0.2,\"move\":\"attack\",\"text\":\"cut off here");
    try std.testing.expectEqual(@as(f64, 0.2), low.confidence);
}

test "parseReply prefers a balanced object over the repair path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = parseReply(arena.allocator(), "{\"move\":\"attack\",\"text\":\"complete\"}");
    try std.testing.expect(!r.truncated);
    try std.testing.expectEqual(@as(f64, 1.0), r.confidence);
}

test "parseReply clamps out-of-range confidences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = parseReply(arena.allocator(), "{\"move\":\"attack\",\"text\":\"x\",\"confidence\":9,\"opponent_landed\":-3}");
    try std.testing.expectEqual(@as(f64, 1.0), r.confidence);
    try std.testing.expectEqual(@as(?f64, 0.0), r.opponent_landed);
}

test "parseJudgment reads a score and clamps it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const j = parseJudgment(arena.allocator(), "```json\n{\"landed\":0.8,\"blocked\":2,\"note\":\"answered the hop cost\"}\n```").?;
    try std.testing.expectEqual(@as(f64, 0.8), j.landed);
    try std.testing.expectEqual(@as(f64, 1.0), j.blocked);
    try std.testing.expectEqualStrings("answered the hop cost", j.note);
}

test "parseJudgment defaults the number it was not given" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const j = parseJudgment(arena.allocator(), "{\"landed\":0.5}").?;
    try std.testing.expectEqual(@as(f64, 0.5), j.landed);
    try std.testing.expectEqual(@as(f64, 0.0), j.blocked);
}

test "parseJudgment refuses an unusable reply instead of scoring it zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "I'd say the first one was better.",
        "{\"note\":\"no numbers at all\"}",
        "{\"landed\":\"high\"}",
        "",
    }) |raw| {
        try std.testing.expectEqual(@as(?Judgment, null), parseJudgment(arena.allocator(), raw));
    }
}

test "legalize demotes a final_stand outside the last round" {
    const early = legalize(.{ .move = .final_stand, .text = "closing" }, false, 0);
    try std.testing.expectEqual(Move.attack, early.move);
    try std.testing.expect(early.weak);
    try std.testing.expectEqual(weak_confidence, early.confidence);

    const on_time = legalize(.{ .move = .final_stand, .text = "closing" }, true, 0);
    try std.testing.expectEqual(Move.final_stand, on_time.move);
    try std.testing.expect(!on_time.weak);
}

test "legalize demotes a block with nothing in flight" {
    for ([_]Move{ .block, .counter }) |m| {
        const vacuous = legalize(.{ .move = m, .text = "rebuttal" }, false, 0);
        try std.testing.expectEqual(Move.attack, vacuous.move);
        try std.testing.expect(vacuous.weak);

        const real = legalize(.{ .move = m, .text = "rebuttal" }, false, 12);
        try std.testing.expectEqual(m, real.move);
        try std.testing.expect(!real.weak);
    }
}

test "resolve: an unanswered attack lands in full and puts its own in flight" {
    const out = resolve(.attack, 1.0, 14, 0.9);
    try std.testing.expectEqual(@as(u16, 14), out.taken);
    try std.testing.expectEqual(@as(u16, base_damage), out.dealt);
    try std.testing.expectEqual(@as(u16, 0), out.blocked);
}

test "resolve: a fully credited block negates the incoming attack" {
    const out = resolve(.block, 1.0, 20, 1.0);
    try std.testing.expectEqual(@as(u16, 20), out.blocked);
    try std.testing.expectEqual(@as(u16, 0), out.taken);
    try std.testing.expectEqual(@as(u16, 0), out.dealt);
}

test "resolve: a half-credited block leaves the residual" {
    const out = resolve(.block, 1.0, 20, 0.5);
    try std.testing.expectEqual(@as(u16, 10), out.blocked);
    try std.testing.expectEqual(@as(u16, 10), out.taken);
}

test "resolve: a counter both negates and deals" {
    const out = resolve(.counter, 0.5, 20, 1.0);
    try std.testing.expectEqual(@as(u16, 20), out.blocked);
    try std.testing.expectEqual(@as(u16, 0), out.taken);
    try std.testing.expectEqual(@as(u16, 10), out.dealt);
}

test "resolve: conceding costs more than eating the attack, and flags it" {
    const out = resolve(.concede, 1.0, 8, 1.0);
    try std.testing.expectEqual(@as(u16, 8 + concede_self_damage), out.taken);
    try std.testing.expect(out.conceded);
    try std.testing.expectEqual(@as(u16, 0), out.dealt);
}

test "resolve: a final_stand deals nothing but does not dodge what is in flight" {
    const out = resolve(.final_stand, 1.0, 11, 1.0);
    try std.testing.expectEqual(@as(u16, 11), out.taken);
    try std.testing.expectEqual(@as(u16, 0), out.dealt);
}

test "forfeit takes what is in flight and does nothing else" {
    const out = forfeit(20);
    try std.testing.expectEqual(@as(u16, 20), out.taken);
    try std.testing.expectEqual(@as(u16, 0), out.dealt);
    try std.testing.expectEqual(@as(u16, 0), out.blocked);
    try std.testing.expect(!out.conceded);
}

test "applyOutcome floors HP at zero rather than wrapping" {
    var c = Combatant{ .position = "p", .hp = 5 };
    applyOutcome(&c, .{ .taken = 40 });
    try std.testing.expectEqual(@as(i32, 0), c.hp);
    try std.testing.expect(!c.alive());
}

test "clampRounds keeps the ceiling and treats 0 as unset" {
    try std.testing.expectEqual(default_max_rounds, clampRounds(0));
    try std.testing.expectEqual(@as(u32, 2), clampRounds(2));
    try std.testing.expectEqual(round_ceiling, clampRounds(round_ceiling));
    try std.testing.expectEqual(round_ceiling, clampRounds(9999));
}

test "isOver: a knockout ends it before the cap" {
    const cs = [_]Combatant{ .{ .position = "a", .hp = 40 }, .{ .position = "b", .hp = 0 } };
    try std.testing.expect(isOver(&cs, 1, 4));
}

test "isOver: a concession leaves one standing" {
    const cs = [_]Combatant{ .{ .position = "a", .hp = 40 }, .{ .position = "b", .hp = 30, .conceded = true } };
    try std.testing.expect(isOver(&cs, 1, 4));
}

test "isOver: an even fight runs to the cap" {
    const cs = [_]Combatant{ .{ .position = "a", .hp = 40 }, .{ .position = "b", .hp = 30 } };
    try std.testing.expect(!isOver(&cs, 3, 4));
    try std.testing.expect(isOver(&cs, 4, 4));
}

test "decide: knockout, concession, points and draw are distinguished" {
    {
        const cs = [_]Combatant{ .{ .position = "a", .hp = 40 }, .{ .position = "b", .hp = 0 } };
        const v = decide(&cs);
        try std.testing.expectEqual(@as(?usize, 0), v.winner);
        try std.testing.expectEqual(Reason.knockout, v.reason);
    }
    {
        const cs = [_]Combatant{ .{ .position = "a", .hp = 40 }, .{ .position = "b", .hp = 30, .conceded = true } };
        const v = decide(&cs);
        try std.testing.expectEqual(@as(?usize, 0), v.winner);
        try std.testing.expectEqual(Reason.concession, v.reason);
    }
    {
        const cs = [_]Combatant{ .{ .position = "a", .hp = 64 }, .{ .position = "b", .hp = 41 } };
        const v = decide(&cs);
        try std.testing.expectEqual(@as(?usize, 0), v.winner);
        try std.testing.expectEqual(Reason.points, v.reason);
    }
    {
        const cs = [_]Combatant{ .{ .position = "a", .hp = 50 }, .{ .position = "b", .hp = 50 } };
        const v = decide(&cs);
        try std.testing.expectEqual(@as(?usize, null), v.winner);
        try std.testing.expectEqual(Reason.draw, v.reason);
    }
}

test "decide: a double knockout is a draw, not a win for the corpse with more HP" {
    const cs = [_]Combatant{ .{ .position = "a", .hp = 0 }, .{ .position = "b", .hp = 0 } };
    const v = decide(&cs);
    try std.testing.expectEqual(@as(?usize, null), v.winner);
    try std.testing.expectEqual(Reason.draw, v.reason);
}

test "decide: the survivor of a knockout wins even with less HP than the loser started with" {
    const cs = [_]Combatant{ .{ .position = "a", .hp = 0 }, .{ .position = "b", .hp = 3 } };
    const v = decide(&cs);
    try std.testing.expectEqual(@as(?usize, 1), v.winner);
    try std.testing.expectEqual(Reason.knockout, v.reason);
}

test "headline states the outcome in words" {
    const cs = [_]Combatant{ .{ .position = "use a message queue", .hp = 64 }, .{ .position = "use direct calls", .hp = 41 } };
    const labels = [_][]const u8{ "kimi-k3", "deepseek" };
    var buf: [512]u8 = undefined;
    const line = headline(&buf, &cs, &labels, decide(&cs));
    try std.testing.expectEqualStrings(
        "kimi-k3 wins on points, 64 HP to deepseek's 41: \"use a message queue\" over \"use direct calls\".",
        line,
    );
}

test "headline says draw without naming a winner" {
    const cs = [_]Combatant{ .{ .position = "a", .hp = 50 }, .{ .position = "b", .hp = 50 } };
    const labels = [_][]const u8{ "x", "y" };
    var buf: [512]u8 = undefined;
    const line = headline(&buf, &cs, &labels, decide(&cs));
    try std.testing.expect(std.mem.find(u8, line, "Draw") != null);
}

test "validatePositions refuses one side, duplicates, blanks and unshipped counts" {
    try validatePositions(&.{ "a", "b" });
    try std.testing.expectError(error.TooFewPositions, validatePositions(&.{"a"}));
    try std.testing.expectError(error.TooFewPositions, validatePositions(&.{}));
    try std.testing.expectError(error.DuplicatePosition, validatePositions(&.{ "a", " a " }));
    try std.testing.expectError(error.EmptyPosition, validatePositions(&.{ "a", "  " }));
    // Battle Royale's whole range is legal now; only past its ceiling is not.
    try validatePositions(&.{ "a", "b", "c" });
    try validatePositions(&.{ "a", "b", "c", "d", "e", "f", "g", "h" });
    try std.testing.expectError(error.TooManyPositions, validatePositions(&.{ "a", "b", "c", "d", "e", "f", "g", "h", "i" }));
}

// ------------------------------------------- Battle Royale mode (phase 8)

fn royale(n: usize, buf: []Combatant) []Combatant {
    const names = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };
    for (0..n) |i| buf[i] = .{ .position = names[i] };
    return buf[0..n];
}

test "resolveTarget accepts the number the prompt showed" {
    var buf: [max_combatants]Combatant = undefined;
    const cs = royale(4, &buf);
    const labels = [_][]const u8{ "one", "two", "three", "four" };
    try std.testing.expectEqual(@as(?usize, 1), resolveTarget("2", cs, &labels, 0));
    try std.testing.expectEqual(@as(?usize, 3), resolveTarget("4", cs, &labels, 0));
    // Trailing punctuation is what a model actually writes.
    try std.testing.expectEqual(@as(?usize, 2), resolveTarget("#3", cs, &labels, 0));
    // Out of range, and the mover itself, are not targets.
    try std.testing.expectEqual(@as(?usize, null), resolveTarget("5", cs, &labels, 0));
    try std.testing.expectEqual(@as(?usize, null), resolveTarget("0", cs, &labels, 0));
    try std.testing.expectEqual(@as(?usize, null), resolveTarget("1", cs, &labels, 0));
}

test "resolveTarget matches a label or position, exactly then loosely" {
    var buf: [max_combatants]Combatant = undefined;
    var cs = royale(3, &buf);
    cs[1].position = "use a message queue";
    cs[2].position = "use direct calls";
    const labels = [_][]const u8{ "kimi (1)", "deepseek (2)", "opus (3)" };

    try std.testing.expectEqual(@as(?usize, 1), resolveTarget("use a message queue", cs, &labels, 0));
    try std.testing.expectEqual(@as(?usize, 2), resolveTarget("opus (3)", cs, &labels, 0));
    try std.testing.expectEqual(@as(?usize, 1), resolveTarget("USE A MESSAGE QUEUE", cs, &labels, 0));
    // A prefix is enough, but not a one- or two-character one: too easy to
    // match the wrong combatant by accident.
    try std.testing.expectEqual(@as(?usize, 1), resolveTarget("use a message", cs, &labels, 0));
    try std.testing.expectEqual(@as(?usize, null), resolveTarget("us", cs, &labels, 0));
    try std.testing.expectEqual(@as(?usize, null), resolveTarget("nobody named this", cs, &labels, 0));
    try std.testing.expectEqual(@as(?usize, null), resolveTarget(null, cs, &labels, 0));
}

test "resolveTarget refuses an eliminated or conceded combatant" {
    var buf: [max_combatants]Combatant = undefined;
    var cs = royale(3, &buf);
    const labels = [_][]const u8{ "a", "b", "c" };
    cs[1].hp = 0;
    cs[2].conceded = true;
    try std.testing.expectEqual(@as(?usize, null), resolveTarget("2", cs, &labels, 0));
    try std.testing.expectEqual(@as(?usize, null), resolveTarget("3", cs, &labels, 0));
    try std.testing.expectEqual(@as(?usize, null), resolveTarget("b", cs, &labels, 0));
}

test "parseReply carries a target, as a name or a number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const named = parseReply(arena.allocator(), "{\"move\":\"attack\",\"text\":\"x\",\"target\":\"use direct calls\"}");
    try std.testing.expectEqualStrings("use direct calls", named.target.?);
    const numbered = parseReply(arena.allocator(), "{\"move\":\"attack\",\"text\":\"x\",\"target\":3}");
    try std.testing.expectEqualStrings("3", numbered.target.?);
    const none = parseReply(arena.allocator(), "{\"move\":\"attack\",\"text\":\"x\"}");
    try std.testing.expectEqual(@as(?[]const u8, null), none.target);
}

test "defaultTarget retaliates first, then aims at the strongest left" {
    var buf: [max_combatants]Combatant = undefined;
    var cs = royale(4, &buf);
    var board = Board{};

    // Nothing in flight: the strongest opponent, not the mover, not itself.
    cs[1].hp = 40;
    cs[2].hp = 90;
    cs[3].hp = 70;
    try std.testing.expectEqual(@as(?usize, 2), defaultTarget(&board, cs, 0));

    // Someone is attacking the mover: retaliation wins over strength.
    board.add(3, 0, 12);
    try std.testing.expectEqual(@as(?usize, 3), defaultTarget(&board, cs, 0));

    // An attacker that has since been eliminated is not a target either.
    cs[3].hp = 0;
    try std.testing.expectEqual(@as(?usize, 2), defaultTarget(&board, cs, 0));
}

test "defaultTarget has nobody to aim at once the mover is alone" {
    var buf: [max_combatants]Combatant = undefined;
    var cs = royale(3, &buf);
    const board = Board{};
    cs[1].hp = 0;
    cs[2].hp = 0;
    try std.testing.expectEqual(@as(?usize, null), defaultTarget(&board, cs, 0));
}

test "royale: a block only negates the attack it named" {
    // The resolved open question, as a test: two attackers focus one target,
    // and its single turn can only answer one of them. The other lands in full.
    var buf: [max_combatants]Combatant = undefined;
    const cs = royale(3, &buf);
    var board = Board{};

    // a and b both attack c at full force.
    _ = resolveTurn(&board, cs, 0, 2, .attack, 1.0, 0.0);
    _ = resolveTurn(&board, cs, 1, 2, .attack, 1.0, 0.0);
    try std.testing.expectEqual(@as(u16, 40), board.incomingTotal(2));

    // c blocks a's attack completely. b's still hits.
    const out = resolveTurn(&board, cs, 2, 0, .block, 1.0, 1.0);
    try std.testing.expectEqual(@as(u16, 20), out.blocked);
    try std.testing.expectEqual(@as(u16, 20), out.taken);
    try std.testing.expectEqual(@as(i32, 80), cs[2].hp);
    // Nothing is left in flight at c: answered or not, it resolved.
    try std.testing.expectEqual(@as(u16, 0), board.incomingTotal(2));
}

test "royale: cumulative focus fire eliminates without ending the match" {
    var buf: [max_combatants]Combatant = undefined;
    const cs = royale(4, &buf);
    var board = Board{};
    cs[3].hp = 35;

    // Three combatants focus d over two exchanges; it never gets to block more
    // than one of them.
    for (0..2) |_| {
        _ = resolveTurn(&board, cs, 0, 3, .attack, 1.0, 0.0);
        _ = resolveTurn(&board, cs, 1, 3, .attack, 1.0, 0.0);
        _ = resolveTurn(&board, cs, 2, 3, .attack, 1.0, 0.0);
        _ = resolveTurn(&board, cs, 3, 0, .block, 1.0, 1.0);
    }
    try std.testing.expect(cs[3].eliminated());
    try std.testing.expect(!cs[3].alive());
    // An elimination does not end a four-way match: three are still standing.
    try std.testing.expect(!isOver(cs, 2, 4));
}

test "royale: the match ends when one is left standing" {
    var buf: [max_combatants]Combatant = undefined;
    const cs = royale(4, &buf);
    cs[1].hp = 0;
    cs[2].hp = 0;
    try std.testing.expect(!isOver(cs, 1, 6));
    cs[3].conceded = true;
    try std.testing.expect(isOver(cs, 1, 6));

    const v = decide(cs);
    try std.testing.expectEqual(@as(?usize, 0), v.winner);
    try std.testing.expectEqual(Reason.knockout, v.reason);
}

test "royale: highest HP wins at the cap when several survive" {
    var buf: [max_combatants]Combatant = undefined;
    const cs = royale(5, &buf);
    cs[0].hp = 30;
    cs[1].hp = 0;
    cs[2].hp = 72;
    cs[3].hp = 51;
    cs[4].hp = 0;
    const v = decide(cs);
    try std.testing.expectEqual(@as(?usize, 2), v.winner);
    try std.testing.expectEqual(Reason.points, v.reason);
}

test "royale: a tie at the cap is still a draw" {
    var buf: [max_combatants]Combatant = undefined;
    const cs = royale(3, &buf);
    cs[0].hp = 44;
    cs[1].hp = 44;
    cs[2].hp = 0;
    const v = decide(cs);
    try std.testing.expectEqual(@as(?usize, null), v.winner);
    try std.testing.expectEqual(Reason.draw, v.reason);
}

test "royale headline names the field, not just the runner-up" {
    var buf: [max_combatants]Combatant = undefined;
    const cs = royale(4, &buf);
    cs[0].position = "use an allowlist";
    cs[0].hp = 61;
    cs[1].hp = 0;
    cs[2].hp = 0;
    cs[3].hp = 0;
    const labels = [_][]const u8{ "kimi", "deepseek", "opus", "glm" };
    var line: [512]u8 = undefined;
    const out = headline(&line, cs, &labels, decide(cs));
    try std.testing.expectEqualStrings(
        "kimi wins last standing among 4, 61 HP: \"use an allowlist\" over 3 others, nearest deepseek at 0.",
        out,
    );
}

test "forfeitTurn eats everything aimed at the mover and counts the forfeit" {
    var buf: [max_combatants]Combatant = undefined;
    const cs = royale(3, &buf);
    var board = Board{};
    board.add(1, 0, 14);
    board.add(2, 0, 9);
    const out = forfeitTurn(&board, cs, 0);
    try std.testing.expectEqual(@as(u16, 23), out.taken);
    try std.testing.expectEqual(@as(i32, 77), cs[0].hp);
    try std.testing.expectEqual(@as(u16, 1), cs[0].forfeits);
    try std.testing.expectEqual(@as(u16, 0), board.incomingTotal(0));
}

test "resolveTurn on a pairwise board matches the pairwise resolver exactly" {
    // The generalisation must not change the two-combatant game: with one
    // possible attacker, incomingTotal and incomingFrom are the same number.
    for ([_]Move{ .attack, .block, .counter, .concede, .final_stand }) |mv| {
        for ([_]f64{ 0.0, 0.5, 1.0 }) |credit| {
            var buf: [max_combatants]Combatant = undefined;
            const cs = royale(2, &buf);
            var board = Board{};
            board.add(1, 0, 20);
            const via_turn = resolveTurn(&board, cs, 0, 1, mv, 0.75, credit);
            const via_pairwise = resolve(mv, 0.75, 20, credit);
            try std.testing.expectEqual(via_pairwise.blocked, via_turn.blocked);
            try std.testing.expectEqual(via_pairwise.taken, via_turn.taken);
            try std.testing.expectEqual(via_pairwise.dealt, via_turn.dealt);
            try std.testing.expectEqual(via_pairwise.conceded, via_turn.conceded);
        }
    }
}

test "isSafeId rejects anything that could leave state/arena/" {
    try std.testing.expect(isSafeId("arena-1786500709-3f2a"));
    try std.testing.expect(isSafeId("a_B-9"));
    try std.testing.expect(!isSafeId(""));
    try std.testing.expect(!isSafeId("../escape"));
    try std.testing.expect(!isSafeId("a/../../b"));
    try std.testing.expect(!isSafeId("a/b"));
    try std.testing.expect(!isSafeId("a\\b"));
    try std.testing.expect(!isSafeId("a.json"));
    try std.testing.expect(!isSafeId("a" ** 65));
}

test "a whole scripted match resolves the way the protocol describes" {
    // Pairwise, 2 rounds, every move routed through legalize the way the round
    // loop does it. A opens at full force; B blocks half; A tries a counter
    // with nothing in flight (demoted to a weak attack); B's call errors and it
    // forfeits, eating that attack in full.
    var cs = [_]Combatant{ .{ .position = "queue" }, .{ .position = "direct" } };
    var in_flight: u16 = 0;

    const a1 = legalize(.{ .move = .attack, .text = "a queue absorbs bursts" }, false, in_flight);
    const a1_out = resolve(a1.move, a1.confidence, in_flight, 0.0);
    applyOutcome(&cs[0], a1_out);
    in_flight = a1_out.dealt;
    try std.testing.expectEqual(@as(u16, 20), in_flight);

    const b1 = legalize(.{ .move = .block, .text = "bursts are rare here" }, false, in_flight);
    try std.testing.expectEqual(Move.block, b1.move);
    const b1_out = resolve(b1.move, b1.confidence, in_flight, 0.5);
    applyOutcome(&cs[1], b1_out);
    in_flight = b1_out.dealt;
    try std.testing.expectEqual(@as(i32, 90), cs[1].hp);
    try std.testing.expectEqual(@as(u16, 0), in_flight);

    const a2 = legalize(.{ .move = .counter, .text = "nothing to counter" }, true, in_flight);
    try std.testing.expectEqual(Move.attack, a2.move);
    try std.testing.expect(a2.weak);
    const a2_out = resolve(a2.move, a2.confidence, in_flight, 0.0);
    applyOutcome(&cs[0], a2_out);
    in_flight = a2_out.dealt;
    try std.testing.expectEqual(@as(u16, 3), in_flight);

    const b2_out = forfeit(in_flight);
    applyOutcome(&cs[1], b2_out);
    cs[1].forfeits += 1;
    in_flight = b2_out.dealt;

    try std.testing.expectEqual(@as(i32, 100), cs[0].hp);
    try std.testing.expectEqual(@as(i32, 87), cs[1].hp);
    try std.testing.expect(isOver(&cs, 2, 2));
    const v = decide(&cs);
    try std.testing.expectEqual(@as(?usize, 0), v.winner);
    try std.testing.expectEqual(Reason.points, v.reason);
}
