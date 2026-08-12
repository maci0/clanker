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

/// Strict pairwise is the shipped shape and the protocol below is written for
/// it. A request between the two counts is refused at the boundary with a
/// reason, rather than silently doing something the rules don't define yet.
pub const shipped_combatants: usize = 2;

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
};

/// Strips a fenced code block, if the reply is wrapped in one. Models asked
/// for JSON commonly answer with ```json … ```, and treating that as a parse
/// failure would score a perfectly good move as a weak attack.
fn stripFence(raw: []const u8) []const u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (!std.mem.startsWith(u8, s, "```")) return s;
    s = s[3..];
    // Skip the info string ("json", "JSON", …) up to the first newline.
    if (std.mem.indexOfScalar(u8, s, '\n')) |nl| s = s[nl + 1 ..];
    if (std.mem.lastIndexOf(u8, s, "```")) |close| s = s[0..close];
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Finds the outermost `{…}` span, honouring strings and escapes so a brace
/// inside `"text"` does not end the object early. Returns null when there is
/// no balanced object — prose with a stray `{` is a parse failure, not an
/// object.
fn objectSpan(s: []const u8) ?[]const u8 {
    const start = std.mem.indexOfScalar(u8, s, '{') orelse return null;
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
                // `start` is a '{', so depth is at least 1 here; the guard is
                // for ReleaseSmall, where an underflow would wrap silently
                // instead of trapping.
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
/// `\uXXXX` inside a salvaged argument are decoded by the same code that
/// decodes a complete one.
///
/// Returns null when the input was already balanced (nothing to repair) or is
/// too mangled to close.
fn repairTruncated(alloc: std.mem.Allocator, s: []const u8) ?[]const u8 {
    const start = std.mem.indexOfScalar(u8, s, '{') orelse return null;
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

/// Resolves one move against the damage currently in flight at the mover.
///
/// `incoming` is what the opponent's last attack put in flight; `credit` is
/// how much of it the judge agrees this move actually answered, in [0,1].
/// Self-judging supplies `credit` from the mover's own `opponent_landed`
/// (inverted), third-party judging from the judge call.
pub fn resolve(move: Move, confidence: f64, incoming: u16, credit: f64) Outcome {
    var out = Outcome{};
    switch (move) {
        .attack => {
            out.taken = incoming;
            out.dealt = scaled(base_damage, confidence);
        },
        .block => {
            out.blocked = scaled(incoming, credit);
            out.taken = incoming - out.blocked;
        },
        .counter => {
            out.blocked = scaled(incoming, credit);
            out.taken = incoming - out.blocked;
            out.dealt = scaled(base_damage, confidence);
        },
        .concede => {
            out.taken = incoming + concede_self_damage;
            out.conceded = true;
        },
        // A closing argument feeds the verdict, not the HP bars — but it does
        // not dodge what is already in flight.
        .final_stand => out.taken = incoming,
    }
    return out;
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

    pub fn alive(self: Combatant) bool {
        return self.hp > 0 and !self.conceded;
    }
};

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

/// True once the match cannot usefully continue: someone is down, everyone but
/// one has conceded, or the round cap is spent.
pub fn isOver(combatants: []const Combatant, rounds_done: u32, max_rounds: u32) bool {
    if (rounds_done >= max_rounds) return true;
    var alive: usize = 0;
    for (combatants) |c| {
        if (c.hp <= 0) return true;
        if (!c.conceded) alive += 1;
    }
    return alive <= 1;
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

    const reason: Reason = blk: {
        if (best == null) break :blk .draw;
        if (tied) break :blk .draw;
        if (conceded + 1 == combatants.len and conceded > 0) break :blk .concession;
        if (knocked_out) break :blk .knockout;
        break :blk .points;
    };
    return .{ .winner = if (reason == .draw) null else best, .reason = reason };
}

/// One line of real text stating the outcome — the canvas-free authority the
/// PRD's `aria-live` caption and the CLI's verdict block both need, and the
/// fallback when the synthesis call itself fails.
pub fn headline(buf: []u8, combatants: []const Combatant, labels: []const []const u8, v: Verdict) []const u8 {
    const w = v.winner orelse return std.fmt.bufPrint(buf, "Draw — no position outargued the other.", .{}) catch "Draw.";
    const loser: usize = if (w == 0) 1 else 0;
    const win_label = if (w < labels.len) labels[w] else "combatant";
    const lose_label = if (loser < labels.len) labels[loser] else "combatant";
    const detail = switch (v.reason) {
        .knockout => "by knockout",
        .concession => "by concession",
        .points => "on points",
        .draw => unreachable,
    };
    return std.fmt.bufPrint(buf, "{s} wins {s}, {d} HP to {s}'s {d} — \"{s}\" over \"{s}\".", .{
        win_label,
        detail,
        combatants[w].hp,
        lose_label,
        if (loser < combatants.len) combatants[loser].hp else 0,
        combatants[w].position,
        if (loser < combatants.len) combatants[loser].position else "",
    }) catch "Match decided.";
}

pub const PositionError = error{ TooFewPositions, TooManyPositions, DuplicatePosition, EmptyPosition, UnsupportedCount };

/// A debate needs at least two distinct sides. Refused at the tool boundary
/// rather than started and abandoned, per the PRD's failure-mode table.
pub fn validatePositions(positions: []const []const u8) PositionError!void {
    if (positions.len < 2) return error.TooFewPositions;
    if (positions.len > max_combatants) return error.TooManyPositions;
    if (positions.len > shipped_combatants) return error.UnsupportedCount;
    for (positions, 0..) |p, i| {
        const a = std.mem.trim(u8, p, " \t\r\n");
        if (a.len == 0) return error.EmptyPosition;
        for (positions[i + 1 ..]) |q| {
            if (std.mem.eql(u8, a, std.mem.trim(u8, q, " \t\r\n"))) return error.DuplicatePosition;
        }
    }
}

/// Match ids land in a path (`state/arena/<id>.json`), so they are restricted
/// to characters that cannot traverse out of it — not merely checked for
/// "..", which `a/../../b` passes.
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
        "kimi-k3 wins on points, 64 HP to deepseek's 41 — \"use a message queue\" over \"use direct calls\".",
        line,
    );
}

test "headline says draw without naming a winner" {
    const cs = [_]Combatant{ .{ .position = "a", .hp = 50 }, .{ .position = "b", .hp = 50 } };
    const labels = [_][]const u8{ "x", "y" };
    var buf: [512]u8 = undefined;
    const line = headline(&buf, &cs, &labels, decide(&cs));
    try std.testing.expect(std.mem.indexOf(u8, line, "Draw") != null);
}

test "validatePositions refuses one side, duplicates, blanks and unshipped counts" {
    try validatePositions(&.{ "a", "b" });
    try std.testing.expectError(error.TooFewPositions, validatePositions(&.{"a"}));
    try std.testing.expectError(error.TooFewPositions, validatePositions(&.{}));
    try std.testing.expectError(error.DuplicatePosition, validatePositions(&.{ "a", " a " }));
    try std.testing.expectError(error.EmptyPosition, validatePositions(&.{ "a", "  " }));
    // Between shipped (2) and Battle Royale's ceiling (8): a real mode that is
    // not built yet, told apart from a count no mode will ever support.
    try std.testing.expectError(error.UnsupportedCount, validatePositions(&.{ "a", "b", "c" }));
    try std.testing.expectError(error.UnsupportedCount, validatePositions(&.{ "a", "b", "c", "d", "e", "f", "g", "h" }));
    try std.testing.expectError(error.TooManyPositions, validatePositions(&.{ "a", "b", "c", "d", "e", "f", "g", "h", "i" }));
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
