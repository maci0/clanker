//! arena: run a bounded, judged debate between two positions and return a
//! verdict traceable to the transcript that produced it.
//!
//! Input (start a match):
//!   {"question": "...", "for": "<stance>", "against": "<stance>",
//!    "provider_for": "kimi-k3", "provider_against": "deepseek",
//!    "persona_for": "...", "persona_against": "...",
//!    "max_rounds": 4, "judge": "self"|"third", "judge_provider": "vertex-opus"}
//! Input (read one):  {"match": "<id>"}
//! Input (list):      {}
//! Output: {"ok": true, "id": "...", "verdict": {...}, "rounds": [...], "text": "<rendered>"}
//!
//! The rules live in arena_match.zig, which imports nothing from the guest ABI
//! and is therefore unit-tested on the host. This file is the shell: it composes
//! prompts, makes the calls, persists `state/arena/<id>.json`, and renders.
//!
//! Combatant turns go through `ck_llm`, not `ck_subagent`. A debate move is one
//! bounded completion with no tools and no file access — an agent run would
//! only add an iteration loop nothing uses — and `ck_llm` is available wherever
//! the tool is, so `clanker arena` works as a plain CLI invocation instead of
//! only from inside a parent agent run (`ck_subagent` returns NotFound there).
//!
//! Reference: docs/prds/0008-arena.md.

const std = @import("std");
const lib = @import("lib.zig");
const m = @import("arena_match.zig");

const alloc = lib.alloc;

const state_dir = "state/arena";
/// Every finished match lands one line here, so a verdict is replayable rather
/// than only returned once — the same reason `rlm` keeps state/reasoning.jsonl.
const ledger_path = state_dir ++ "/log.jsonl";

const Settings = struct {
    max_rounds: u32 = m.default_max_rounds,
    judge: []const u8 = "self",
    /// Output cap per combatant turn. A move is a paragraph; the cap is what
    /// keeps a match's cost proportional to its round count. Set well above a
    /// 120-word move on purpose — a reasoning model spends tokens before it
    /// writes anything, and a turn truncated to nothing is scored as a
    /// forfeited round, which is a worse outcome than a slightly dearer call.
    max_tokens: u32 = 1400,
};

/// Cap for one judge call. A judgment is two numbers and a sentence.
const judge_max_tokens: u32 = 500;

/// Cap for the closing synthesis. Higher than a judge call because this is the
/// one piece of prose a caller actually reads, and a verdict truncated
/// mid-sentence is the failure this number exists to prevent.
const synthesis_max_tokens: u32 = 1200;

fn settings() Settings {
    return std.json.parseFromSliceLeaky(Settings, alloc, lib.config(), .{ .ignore_unknown_fields = true }) catch Settings{};
}

/// Both combatants, plus everything about the match that does not change.
const Setup = struct {
    id: []const u8,
    question: []const u8,
    labels: [2][]const u8,
    personas: [2][]const u8,
    max_rounds: u32,
    max_tokens: u32,
    third_party: bool,
    judge_provider: []const u8,
    /// Why third-party judging is not in effect despite being asked for.
    downgrade: []const u8,
};

const MoveRecord = struct {
    round: u32,
    combatant: usize,
    move: []const u8,
    text: []const u8,
    confidence: f64,
    weak: bool,
    truncated: bool,
    forfeit: bool,
    err: []const u8,
    blocked: u16,
    taken: u16,
    dealt: u16,
    hp_after: i32,
    judged_by: []const u8,
    judge_note: []const u8,
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, input, .{}) catch
        return lib.fail(out, "input must be a JSON object");
    const obj = switch (root) {
        .object => |o| o,
        else => return lib.fail(out, "input must be a JSON object"),
    };

    if (strField(obj, "question")) |q| return startMatch(out, obj, q);
    if (strField(obj, "match")) |id| return readMatch(out, id);
    return listMatches(out);
}

// ------------------------------------------------------------ input helpers

/// A string field, or null when absent, the wrong type, or blank. Blank and
/// absent are the same thing for every field this tool takes.
fn strField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    if (v != .string) return null;
    const s = std.mem.trim(u8, v.string, " \t\r\n");
    return if (s.len == 0) null else s;
}

fn strOr(obj: std.json.ObjectMap, name: []const u8, fallback: []const u8) []const u8 {
    return strField(obj, name) orelse fallback;
}

fn uintField(obj: std.json.ObjectMap, name: []const u8) ?u32 {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        .integer => |n| if (n > 0) @intCast(@min(n, std.math.maxInt(u32))) else null,
        .float => |f| if (f >= 1.0) @intFromFloat(f) else null,
        else => null,
    };
}

/// Match ids are derived, not taken from the caller, so a caller can never aim
/// a match file anywhere. Content-seeded so two matches started in the same
/// second on different questions do not collide.
fn newId(question: []const u8) ![]const u8 {
    const secs: u64 = @intFromFloat(@max(0.0, lib.nowSeconds()));
    var hasher = std.hash.Wyhash.init(secs);
    hasher.update(question);
    return std.fmt.allocPrint(alloc, "arena-{d}-{x}", .{ secs, hasher.final() & 0xffff_ffff });
}

fn sideName(i: usize) []const u8 {
    return if (i == 0) "for" else "against";
}

/// A combatant's display name. The provider is the interesting half, but two
/// positions may legitimately share one provider (the same model arguing
/// against itself), so the side is always in there to keep labels distinct.
fn labelFor(i: usize, provider: []const u8) []const u8 {
    if (provider.len == 0) return sideName(i);
    return std.fmt.allocPrint(alloc, "{s} ({s})", .{ provider, sideName(i) }) catch sideName(i);
}

// ------------------------------------------------------------- judge picking

const HarnessProvider = struct { default_model: []const u8 = "" };
const HarnessConfig = struct {
    default_provider: []const u8 = "",
    providers: std.json.ArrayHashMap(HarnessProvider) = .{},
};

/// Resolves a combatant's provider to the name a judge has to differ from: an
/// unset provider is the configured default, and a judge sharing that is not a
/// third party.
fn effectiveProvider(named: []const u8, default_provider: []const u8) []const u8 {
    return if (named.len > 0) named else default_provider;
}

const JudgeChoice = struct { provider: []const u8, downgrade: []const u8 };

/// Picks a judge that is not fighting the match.
///
/// An explicit `judge_provider` is honoured unless it collides with a
/// combatant; otherwise the first configured provider that differs from both is
/// used. Either way, failing to find one is a downgrade to self-reported
/// judging with a reason recorded — never a refusal, and never a judge that is
/// also a combatant (see the PRD's failure-mode table).
fn pickJudge(requested: []const u8, providers: [2][]const u8) JudgeChoice {
    const cfg = std.json.parseFromSliceLeaky(HarnessConfig, alloc, lib.harnessConfig(), .{ .ignore_unknown_fields = true }) catch HarnessConfig{};
    const p0 = effectiveProvider(providers[0], cfg.default_provider);
    const p1 = effectiveProvider(providers[1], cfg.default_provider);

    if (requested.len > 0) {
        if (std.mem.eql(u8, requested, p0) or std.mem.eql(u8, requested, p1))
            return .{ .provider = "", .downgrade = "requested judge provider is also a combatant" };
        return .{ .provider = requested, .downgrade = "" };
    }

    var it = cfg.providers.map.iterator();
    while (it.next()) |kv| {
        const name = kv.key_ptr.*;
        if (std.mem.eql(u8, name, p0) or std.mem.eql(u8, name, p1)) continue;
        return .{ .provider = name, .downgrade = "" };
    }
    return .{ .provider = "", .downgrade = "no configured provider is free to judge (all are fighting)" };
}

// ------------------------------------------------------------------ prompts

fn systemPrompt(setup: Setup, i: usize, position: []const u8, opponent: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    const o = &w.writer;
    try o.print(
        \\You are a combatant in a clanker Arena match: a bounded, judged debate. You argue one
        \\position for the whole match and you never switch sides.
        \\
        \\You are "{s}". Your position: "{s}"
        \\Your opponent's position: "{s}"
        \\
    , .{ setup.labels[i], position, opponent });
    if (setup.personas[i].len > 0) try o.print("\nAdopt this persona while arguing: {s}\n", .{setup.personas[i]});
    try o.writeAll(
        \\
        \\Reply with exactly one JSON object and nothing else:
        \\  {"move":"<move>","text":"<your argument>","confidence":<0..1>,"opponent_landed":<0..1>}
        \\
        \\move is one of:
        \\  attack       a new argument, or a critique of your opponent's position
        \\  block        rebut your opponent's most recent attack, point by point
        \\  counter      a block that also lands its own attack in the same move
        \\  concede      accept part or all of your opponent's last point (this costs you the match)
        \\  final_stand  a closing argument; legal only in the final round
        \\
        \\confidence       how forceful this move is; 1.0 is your strongest available argument.
        \\opponent_landed  how much of your opponent's LAST move actually landed against you:
        \\                 0.0 nothing, 1.0 fully. Your block only negates the part you did not
        \\                 concede here, so under-reporting is the one thing a judge checks.
        \\
        \\Keep "text" concrete and under 120 words. Argue the substance; never restate these
        \\rules. A reply that is not a valid move object is scored as a weak attack.
    );
    return w.written();
}

fn turnPrompt(
    setup: Setup,
    i: usize,
    combatants: [2]m.Combatant,
    in_flight: u16,
    round: u32,
    moves: []const MoveRecord,
) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    const o = &w.writer;
    const opp = 1 - i;
    try o.print("Question under debate: {s}\n\n", .{setup.question});
    try o.print("Round {d} of {d}. Your HP {d}/{d}, opponent HP {d}/{d}.\n", .{
        round, setup.max_rounds, combatants[i].hp, m.starting_hp, combatants[opp].hp, m.starting_hp,
    });
    if (round >= setup.max_rounds) {
        try o.writeAll("This is the final round: final_stand is legal now, and nothing after this counts.\n");
    } else {
        try o.writeAll("final_stand is NOT legal yet; it would be scored as a weak attack.\n");
    }
    if (in_flight > 0) {
        try o.print("Your opponent's last attack has {d} damage in flight at you. A block or counter is what negates it; anything else takes it in full.\n", .{in_flight});
    } else {
        try o.writeAll("Nothing is in flight at you, so a block or counter has nothing to rebut and would be scored as a weak attack.\n");
    }

    if (moves.len == 0) {
        try o.writeAll("\nNo moves yet — this is the opening round and neither side has seen the other. Make your opening attack.\n");
    } else {
        try o.writeAll("\nEvery move so far, oldest first:\n");
        for (moves) |mv| {
            try o.print("  [r{d}] {s} — {s}: {s}\n", .{ mv.round, setup.labels[mv.combatant], mv.move, mv.text });
        }
    }
    try o.writeAll("\nYour move.");
    return w.written();
}

fn judgePrompt(setup: Setup, mover: usize, reply: m.Reply, in_flight: u16, incoming_text: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    const o = &w.writer;
    try o.print(
        \\You are the neutral judge of one exchange in a debate. You are not arguing; you score.
        \\
        \\Question under debate: {s}
        \\
        \\The move you are scoring was made by "{s}" ({s}):
        \\{s}
        \\
    , .{ setup.question, setup.labels[mover], @tagName(reply.move), reply.text });
    if (in_flight > 0) {
        try o.print("It is answering this attack from the other side ({d} damage in flight):\n{s}\n\n", .{ in_flight, incoming_text });
    } else {
        try o.writeAll("There was no attack in flight for it to answer.\n\n");
    }
    try o.writeAll(
        \\Reply with exactly one JSON object and nothing else:
        \\  {"landed":<0..1>,"blocked":<0..1>,"note":"<one sentence>"}
        \\
        \\landed   how much force this move's own new argument carries. 0.0 if it makes no new
        \\         argument, 1.0 if it is a strong, specific, well-supported point.
        \\blocked  how much of the incoming attack this move actually answered, point by point.
        \\         0.0 if it ignored or merely contradicted it, 1.0 if it fully defused it.
        \\         Use 0.0 when there was nothing in flight.
        \\note     one sentence on why, naming the specific point that did or did not land.
        \\
        \\Score what was argued, not who you agree with.
    );
    return w.written();
}

fn synthesisPrompt(setup: Setup, combatants: [2]m.Combatant, v: m.Verdict, moves: []const MoveRecord) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    const o = &w.writer;
    try o.print("A judged debate has finished. Write the answer it produced.\n\nQuestion: {s}\n\n", .{setup.question});
    for (combatants, 0..) |c, i| {
        try o.print("{s}: \"{s}\" — {d} HP left{s}\n", .{ setup.labels[i], c.position, c.hp, if (c.conceded) ", conceded" else "" });
    }
    if (v.winner) |wi| {
        try o.print("\nThe match went to {s} ({s}).\n", .{ setup.labels[wi], @tagName(v.reason) });
    } else {
        try o.writeAll("\nThe match was a draw.\n");
    }
    try o.writeAll("\nTranscript, oldest first:\n");
    for (moves) |mv| {
        try o.print("  [r{d}] {s} — {s}: {s}\n", .{ mv.round, setup.labels[mv.combatant], mv.move, mv.text });
    }
    try o.writeAll(
        \\
        \\In under 150 words, answer the question directly. Lead with the winning position, and
        \\carry over any point the losing side landed that the answer should still respect. Do not
        \\narrate the match, name HP, or say who won — the reader already has that. Prose only, no
        \\JSON, no headings.
    );
    return w.written();
}

// -------------------------------------------------------------- match runner

fn startMatch(out: *lib.Out, obj: std.json.ObjectMap, question: []const u8) !void {
    const cfg = settings();

    // Positions: the flag-shaped for/against pair, or an explicit array.
    var positions: [2][]const u8 = .{ "", "" };
    if (obj.get("positions")) |v| {
        if (v != .array) return lib.fail(out, "positions must be an array of stances");
        const items = v.array.items;
        // Validated before truncation, so a 3-way request is refused with the
        // reason rather than silently played as the first two positions.
        var listed: std.ArrayList([]const u8) = .empty;
        defer listed.deinit(alloc);
        for (items) |it| {
            if (it != .string) return lib.fail(out, "positions must be an array of stances");
            try listed.append(alloc, std.mem.trim(u8, it.string, " \t\r\n"));
        }
        try validate(out, listed.items) orelse return;
        positions = .{ listed.items[0], listed.items[1] };
    } else {
        // Absent and blank are different mistakes and want different fixes —
        // "you left a side out" vs "the side you gave is empty" — so they are
        // told apart here rather than collapsed into one by defaulting a
        // missing field to "".
        const for_side = strField(obj, "for");
        const against_side = strField(obj, "against");
        if (for_side == null or against_side == null) {
            const blanked = (obj.get("for") != null and for_side == null) or
                (obj.get("against") != null and against_side == null);
            return lib.fail(out, if (blanked)
                "a position cannot be blank"
            else
                "a debate needs two distinct positions: pass \"for\" and \"against\"");
        }
        positions = .{ for_side.?, against_side.? };
        try validate(out, &positions) orelse return;
    }

    const providers: [2][]const u8 = .{ strOr(obj, "provider_for", ""), strOr(obj, "provider_against", "") };

    const judge_mode = strOr(obj, "judge", cfg.judge);
    if (!std.mem.eql(u8, judge_mode, "self") and !std.mem.eql(u8, judge_mode, "third"))
        return lib.fail(out, "judge must be \"self\" or \"third\"");
    var third_party = std.mem.eql(u8, judge_mode, "third");
    var judge = JudgeChoice{ .provider = "", .downgrade = "" };
    if (third_party) {
        judge = pickJudge(strOr(obj, "judge_provider", ""), providers);
        if (judge.provider.len == 0) {
            third_party = false;
            lib.logInfo("[arena] third-party judging downgraded to self-reported");
        }
    }

    var setup = Setup{
        .id = try newId(question),
        .question = question,
        .labels = .{ labelFor(0, providers[0]), labelFor(1, providers[1]) },
        .personas = .{ strOr(obj, "persona_for", ""), strOr(obj, "persona_against", "") },
        .max_rounds = m.clampRounds(uintField(obj, "max_rounds") orelse cfg.max_rounds),
        .max_tokens = uintField(obj, "max_tokens") orelse cfg.max_tokens,
        .third_party = third_party,
        .judge_provider = judge.provider,
        .downgrade = judge.downgrade,
    };

    var combatants: [2]m.Combatant = .{
        .{ .position = positions[0], .provider = providers[0], .persona = setup.personas[0] },
        .{ .position = positions[1], .provider = providers[1], .persona = setup.personas[1] },
    };
    const systems: [2][]const u8 = .{
        try systemPrompt(setup, 0, positions[0], positions[1]),
        try systemPrompt(setup, 1, positions[1], positions[0]),
    };

    var moves: std.ArrayList(MoveRecord) = .empty;
    defer moves.deinit(alloc);
    // Damage aimed at each combatant, waiting for it to answer. Per-combatant
    // rather than one global slot: a forfeited round leaves damage standing
    // while the other side keeps attacking.
    var in_flight: [2]u16 = .{ 0, 0 };
    var rounds_played: u32 = 0;

    var round: u32 = 1;
    while (round <= setup.max_rounds) : (round += 1) {
        // Round 1 is both openings, made blind: neither side has anything to
        // react to, so it sees no transcript and takes no damage until round 2.
        const opening = round == 1;

        for (0..2) |i| {
            if (combatants[i].conceded) continue;
            const incoming: u16 = if (opening) 0 else in_flight[i];

            // Read out per turn, not once per round, for two reasons: the
            // second mover must see the first mover's move from this same round
            // ("every move so far", not just the previous round's), and
            // `moves.items` is invalidated by the append below the moment the
            // list grows — a slice hoisted out of this loop dangles as soon as
            // the third move reallocates it.
            const visible: []const MoveRecord = if (opening) &.{} else moves.items;
            const prompt = try turnPrompt(setup, i, combatants, incoming, round, visible);
            var no_reply: []const u8 = "";
            const raw: []const u8 = blk: {
                const answer = lib.llmSystem(systems[i], prompt, if (providers[i].len > 0) providers[i] else null, setup.max_tokens) catch |err| {
                    no_reply = @errorName(err);
                    break :blk "";
                };
                // A call that succeeded but came back empty is not a reply that
                // failed to parse: there is no text to keep, so the weak-attack
                // fallback would be crediting silence with damage and printing a
                // blank transcript line. Treat it as the round not being
                // answered, which is what it is.
                if (std.mem.trim(u8, answer, " \t\r\n").len == 0) {
                    no_reply = "empty reply";
                    break :blk "";
                }
                break :blk answer;
            };
            if (no_reply.len > 0) {
                // A combatant whose call errored, timed out or said nothing
                // forfeits the round: it deals nothing and blocks nothing, so
                // whatever was in flight lands. The match continues rather
                // than hanging.
                const o = m.forfeit(incoming);
                m.applyOutcome(&combatants[i], o);
                combatants[i].forfeits += 1;
                if (!opening) in_flight[i] = 0;
                try moves.append(alloc, .{
                    .round = round,
                    .combatant = i,
                    .move = "forfeit",
                    .text = "(no reply)",
                    .confidence = 0,
                    .weak = false,
                    .truncated = false,
                    .forfeit = true,
                    .err = no_reply,
                    .blocked = 0,
                    .taken = o.taken,
                    .dealt = 0,
                    .hp_after = combatants[i].hp,
                    .judged_by = "",
                    .judge_note = "",
                });
                continue;
            }

            const parsed = m.parseReply(alloc, raw);
            const reply = m.legalize(parsed, round >= setup.max_rounds, incoming);

            // Self-reported: the mover says how much of the incoming attack
            // landed, and its block gets credit for the rest. A reply that
            // omits the number gets half credit — neither free nor worthless.
            var credit: f64 = 1.0 - (reply.opponent_landed orelse 0.5);
            var confidence = reply.confidence;
            var judged_by: []const u8 = "self";
            var note: []const u8 = "";
            if (setup.third_party) {
                const incoming_text = lastAttackText(moves.items, 1 - i);
                if (judgeExchange(setup, i, reply, incoming, incoming_text)) |j| {
                    credit = j.blocked;
                    confidence = j.landed;
                    note = j.note;
                    judged_by = "third";
                } else {
                    // One judge call failing is not a reason to abandon the
                    // match; it is a reason to say which move was scored by
                    // whom, so the verdict's confidence can be read.
                    judged_by = "self (judge call failed)";
                }
            }
            // A reply that never parsed cannot also be credited with force:
            // the floor confidence is the whole point of the weak path.
            if (reply.weak) confidence = @min(confidence, m.weak_confidence);

            const o = m.resolve(reply.move, confidence, incoming, credit);
            m.applyOutcome(&combatants[i], o);
            if (!opening) in_flight[i] = 0;
            in_flight[1 - i] += o.dealt;

            try moves.append(alloc, .{
                .round = round,
                .combatant = i,
                .move = @tagName(reply.move),
                .text = reply.text,
                .confidence = confidence,
                .weak = reply.weak,
                .truncated = reply.truncated,
                .forfeit = false,
                .err = "",
                .blocked = o.blocked,
                .taken = o.taken,
                .dealt = o.dealt,
                .hp_after = combatants[i].hp,
                .judged_by = judged_by,
                .judge_note = note,
            });

            if (combatants[i].hp <= 0) break;
        }

        rounds_played = round;
        // Written every round, not only at the end, so a match in progress is
        // readable by another process (the web UI polls exactly this file).
        persist(setup, combatants, moves.items, rounds_played, null, "running") catch |err|
            lib.logInfo(@errorName(err));
        if (m.isOver(&combatants, round, setup.max_rounds)) break;
    }

    // Damage still in flight when the match ends never got answered, so it
    // lands — otherwise the last attack of a match would always be free.
    for (0..2) |i| {
        if (in_flight[i] == 0) continue;
        m.applyOutcome(&combatants[i], m.forfeit(in_flight[i]));
        in_flight[i] = 0;
    }

    const verdict = m.decide(&combatants);
    var head_buf: [1024]u8 = undefined;
    const head = m.headline(&head_buf, &combatants, &setup.labels, verdict);
    const answer = synthesize(setup, combatants, verdict, moves.items) orelse head;

    const final = Final{ .verdict = verdict, .headline = head, .answer = answer };
    persist(setup, combatants, moves.items, rounds_played, final, "finished") catch |err|
        lib.logInfo(@errorName(err));
    appendLedger(setup, combatants, verdict, head) catch {};

    try render(out, setup, combatants, moves.items, rounds_played, final, "finished");
}

/// Refusals for a bad position list. Returns null once it has written the
/// refusal, so the caller stops without a second error path.
fn validate(out: *lib.Out, positions: []const []const u8) !?void {
    m.validatePositions(positions) catch |err| {
        try lib.fail(out, switch (err) {
            error.TooFewPositions => "a debate needs two distinct positions: pass \"for\" and \"against\"",
            error.DuplicatePosition => "the two positions are identical — there is nothing to argue",
            error.EmptyPosition => "a position cannot be blank",
            error.UnsupportedCount => "only 2 combatants are supported so far; Battle Royale mode (3-8) is not implemented yet",
            error.TooManyPositions => "at most 8 positions, and only 2 are supported so far",
        });
        return null;
    };
    return {};
}

/// The most recent attack the given combatant put in flight, so the judge can
/// see what the move under review is answering.
fn lastAttackText(moves: []const MoveRecord, by: usize) []const u8 {
    var i = moves.len;
    while (i > 0) {
        i -= 1;
        const mv = moves[i];
        if (mv.combatant == by and mv.dealt > 0) return mv.text;
    }
    return "";
}

fn judgeExchange(setup: Setup, mover: usize, reply: m.Reply, in_flight: u16, incoming_text: []const u8) ?m.Judgment {
    const prompt = judgePrompt(setup, mover, reply, in_flight, incoming_text) catch return null;
    const raw = lib.llmSystem(null, prompt, if (setup.judge_provider.len > 0) setup.judge_provider else null, judge_max_tokens) catch return null;
    return m.parseJudgment(alloc, raw);
}

fn synthesize(setup: Setup, combatants: [2]m.Combatant, v: m.Verdict, moves: []const MoveRecord) ?[]const u8 {
    const prompt = synthesisPrompt(setup, combatants, v, moves) catch return null;
    // Synthesis is a reading of the transcript, not a position in it, so it
    // goes to the judge when there is one.
    const raw = lib.llmSystem(null, prompt, if (setup.judge_provider.len > 0) setup.judge_provider else null, synthesis_max_tokens) catch return null;
    const text = std.mem.trim(u8, raw, " \t\r\n");
    return if (text.len == 0) null else text;
}

const Final = struct {
    verdict: m.Verdict,
    headline: []const u8,
    answer: []const u8,
};

// ------------------------------------------------------------- persistence

fn matchPath(id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, state_dir ++ "/{s}.json", .{id});
}

fn writeMatchJson(
    s: *std.json.Stringify,
    setup: Setup,
    combatants: [2]m.Combatant,
    moves: []const MoveRecord,
    rounds_played: u32,
    final: ?Final,
    status: []const u8,
) !void {
    try s.beginObject();
    try s.objectField("id");
    try s.write(setup.id);
    try s.objectField("status");
    try s.write(status);
    try s.objectField("question");
    try s.write(setup.question);
    try s.objectField("max_rounds");
    try s.write(setup.max_rounds);
    try s.objectField("rounds_played");
    try s.write(rounds_played);
    try s.objectField("judge");
    try s.write(if (setup.third_party) "third" else "self");
    try s.objectField("judge_provider");
    try s.write(setup.judge_provider);
    if (setup.downgrade.len > 0) {
        try s.objectField("judge_downgraded");
        try s.write(setup.downgrade);
    }

    try s.objectField("combatants");
    try s.beginArray();
    for (combatants, 0..) |c, i| {
        try s.beginObject();
        try s.objectField("side");
        try s.write(sideName(i));
        try s.objectField("label");
        try s.write(setup.labels[i]);
        try s.objectField("position");
        try s.write(c.position);
        try s.objectField("provider");
        try s.write(c.provider);
        try s.objectField("persona");
        try s.write(c.persona);
        try s.objectField("hp");
        try s.write(c.hp);
        try s.objectField("max_hp");
        try s.write(m.starting_hp);
        try s.objectField("conceded");
        try s.write(c.conceded);
        try s.objectField("forfeits");
        try s.write(c.forfeits);
        try s.endObject();
    }
    try s.endArray();

    // Grouped by round rather than flat, so a reader (the pixel view, a replay)
    // can step a round at a time without regrouping.
    try s.objectField("rounds");
    try s.beginArray();
    var round: u32 = 1;
    while (round <= rounds_played) : (round += 1) {
        try s.beginObject();
        try s.objectField("round");
        try s.write(round);
        try s.objectField("moves");
        try s.beginArray();
        for (moves) |mv| {
            if (mv.round != round) continue;
            try s.beginObject();
            try s.objectField("combatant");
            try s.write(mv.combatant);
            try s.objectField("label");
            try s.write(setup.labels[mv.combatant]);
            try s.objectField("move");
            try s.write(mv.move);
            try s.objectField("text");
            try s.write(mv.text);
            try s.objectField("confidence");
            try s.write(mv.confidence);
            try s.objectField("weak");
            try s.write(mv.weak);
            if (mv.truncated) {
                try s.objectField("truncated");
                try s.write(true);
            }
            try s.objectField("blocked");
            try s.write(mv.blocked);
            try s.objectField("damage_taken");
            try s.write(mv.taken);
            try s.objectField("damage_dealt");
            try s.write(mv.dealt);
            try s.objectField("hp_after");
            try s.write(mv.hp_after);
            if (mv.judged_by.len > 0) {
                try s.objectField("judged_by");
                try s.write(mv.judged_by);
            }
            if (mv.judge_note.len > 0) {
                try s.objectField("judge_note");
                try s.write(mv.judge_note);
            }
            if (mv.forfeit) {
                try s.objectField("forfeit");
                try s.write(true);
                try s.objectField("error");
                try s.write(mv.err);
            }
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
    }
    try s.endArray();

    if (final) |f| {
        try s.objectField("verdict");
        try s.beginObject();
        try s.objectField("winner");
        if (f.verdict.winner) |wi| try s.write(wi) else try s.write(null);
        try s.objectField("winner_label");
        try s.write(if (f.verdict.winner) |wi| setup.labels[wi] else "");
        try s.objectField("reason");
        try s.write(@tagName(f.verdict.reason));
        try s.objectField("headline");
        try s.write(f.headline);
        try s.objectField("answer");
        try s.write(f.answer);
        try s.endObject();
    }
    try s.endObject();
}

fn persist(
    setup: Setup,
    combatants: [2]m.Combatant,
    moves: []const MoveRecord,
    rounds_played: u32,
    final: ?Final,
    status: []const u8,
) !void {
    var w: std.Io.Writer.Allocating = .init(alloc);
    defer w.deinit();
    var s = std.json.Stringify{ .writer = &w.writer, .options = .{} };
    try writeMatchJson(&s, setup, combatants, moves, rounds_played, final, status);
    try lib.fsWrite(try matchPath(setup.id), w.written());
}

fn appendLedger(setup: Setup, combatants: [2]m.Combatant, v: m.Verdict, head: []const u8) !void {
    var w: std.Io.Writer.Allocating = .init(alloc);
    defer w.deinit();
    var s = std.json.Stringify{ .writer = &w.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("id");
    try s.write(setup.id);
    try s.objectField("question");
    try s.write(setup.question);
    try s.objectField("winner");
    try s.write(if (v.winner) |wi| setup.labels[wi] else "draw");
    try s.objectField("reason");
    try s.write(@tagName(v.reason));
    try s.objectField("hp");
    try s.beginArray();
    for (combatants) |c| try s.write(c.hp);
    try s.endArray();
    try s.objectField("headline");
    try s.write(head);
    try s.endObject();
    try w.writer.writeByte('\n');
    try lib.fsAppend(ledger_path, w.written());
}

// ---------------------------------------------------------------- rendering

fn render(
    out: *lib.Out,
    setup: Setup,
    combatants: [2]m.Combatant,
    moves: []const MoveRecord,
    rounds_played: u32,
    final: ?Final,
    status: []const u8,
) !void {
    // The rendered transcript is built first so it can go into the JSON as
    // "text": the CLI and the REPL print that one field, and everything else
    // in the payload is for a program.
    var t: std.Io.Writer.Allocating = .init(alloc);
    defer t.deinit();
    try renderText(&t.writer, setup, combatants, moves, rounds_played, final);

    var w = out.writer();
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(t.written());
    try s.objectField("match");
    try writeMatchJson(&s, setup, combatants, moves, rounds_played, final, status);
    try s.endObject();
    lib.commit(out, &w);
}

fn renderText(
    o: *std.Io.Writer,
    setup: Setup,
    combatants: [2]m.Combatant,
    moves: []const MoveRecord,
    rounds_played: u32,
    final: ?Final,
) !void {
    try o.print("arena {s} — {s}\n", .{ setup.id, setup.question });
    for (combatants, 0..) |c, i| {
        try o.print("  {s:<8} \"{s}\"  [{s}]\n", .{ sideName(i), c.position, setup.labels[i] });
    }
    try o.print("  judge: {s}", .{if (setup.third_party) "third-party" else "self-reported"});
    if (setup.third_party) try o.print(" ({s})", .{setup.judge_provider});
    if (setup.downgrade.len > 0) try o.print(" — downgraded: {s}", .{setup.downgrade});
    try o.print(" · {d} of max {d} rounds\n", .{ rounds_played, setup.max_rounds });

    var round: u32 = 1;
    while (round <= rounds_played) : (round += 1) {
        try o.print("\nround {d}\n", .{round});
        for (moves) |mv| {
            if (mv.round != round) continue;
            try o.print("  {s} — {s}", .{ setup.labels[mv.combatant], mv.move });
            if (mv.weak) try o.writeAll(" (unparsed, scored weak)");
            if (mv.truncated) try o.writeAll(" (cut off, force capped)");
            try o.print("  {d} HP", .{mv.hp_after});
            if (mv.taken > 0) try o.print(" (-{d})", .{mv.taken});
            if (mv.blocked > 0) try o.print(" (blocked {d})", .{mv.blocked});
            if (mv.dealt > 0) try o.print(" (deals {d})", .{mv.dealt});
            try o.writeAll("\n");
            if (mv.forfeit) {
                try o.print("      forfeited the round: {s}\n", .{mv.err});
            } else {
                try o.print("      {s}\n", .{mv.text});
            }
            if (mv.judge_note.len > 0) try o.print("      judge: {s}\n", .{mv.judge_note});
        }
    }

    if (final) |f| {
        try o.print("\nverdict: {s}\n\n{s}\n", .{ f.headline, f.answer });
    } else {
        try o.writeAll("\n(match still running)\n");
    }
}

// -------------------------------------------------------------- read & list

fn readMatch(out: *lib.Out, id: []const u8) !void {
    if (!m.isSafeId(id)) return lib.fail(out, "not a match id");
    const raw = lib.fsRead(try matchPath(id)) catch return lib.fail(out, "no such match");
    const text = try renderStored(raw);

    // The stored document is already the canonical shape a reader wants, so it
    // is spliced in verbatim: re-encoding it through Stringify would only be a
    // chance to drift from the writer that produced it.
    var w = out.writer();
    try w.writeAll("{\"ok\":true,\"text\":");
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    try s.write(text);
    try w.writeAll(",\"match\":");
    try w.writeAll(raw);
    try w.writeAll("}");
    lib.commit(out, &w);
}

/// Re-renders a stored match into the same text a live run prints. Kept
/// deliberately thin: it reads the document's own fields rather than
/// reconstructing a Setup, so a field added to the writer cannot desync it.
fn renderStored(raw: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{}) catch return "(unreadable match file)";
    const doc = switch (parsed) {
        .object => |o| o,
        else => return "(unreadable match file)",
    };
    var t: std.Io.Writer.Allocating = .init(alloc);
    const o = &t.writer;
    try o.print("arena {s} — {s}\n", .{ jsonStr(doc, "id"), jsonStr(doc, "question") });
    if (doc.get("combatants")) |cs| if (cs == .array) {
        for (cs.array.items) |c| {
            if (c != .object) continue;
            try o.print("  {s:<8} \"{s}\"  [{s}]\n", .{ jsonStr(c.object, "side"), jsonStr(c.object, "position"), jsonStr(c.object, "label") });
        }
    };
    try o.print("  judge: {s} · status {s}\n", .{ jsonStr(doc, "judge"), jsonStr(doc, "status") });
    if (doc.get("rounds")) |rs| if (rs == .array) {
        for (rs.array.items) |r| {
            if (r != .object) continue;
            try o.print("\nround {s}\n", .{jsonNum(r.object, "round")});
            const mvs = r.object.get("moves") orelse continue;
            if (mvs != .array) continue;
            for (mvs.array.items) |mv| {
                if (mv != .object) continue;
                try o.print("  {s} — {s}  {s} HP\n      {s}\n", .{
                    jsonStr(mv.object, "label"),
                    jsonStr(mv.object, "move"),
                    jsonNum(mv.object, "hp_after"),
                    jsonStr(mv.object, "text"),
                });
            }
        }
    };
    if (doc.get("verdict")) |v| if (v == .object) {
        try o.print("\nverdict: {s}\n\n{s}\n", .{ jsonStr(v.object, "headline"), jsonStr(v.object, "answer") });
    };
    return t.written();
}

fn jsonStr(obj: std.json.ObjectMap, name: []const u8) []const u8 {
    const v = obj.get(name) orelse return "";
    return if (v == .string) v.string else "";
}

fn jsonNum(obj: std.json.ObjectMap, name: []const u8) []const u8 {
    const v = obj.get(name) orelse return "?";
    return switch (v) {
        .integer => |n| std.fmt.allocPrint(alloc, "{d}", .{n}) catch "?",
        .float => |f| std.fmt.allocPrint(alloc, "{d}", .{f}) catch "?",
        else => "?",
    };
}

fn listMatches(out: *lib.Out) !void {
    const ledger = lib.fsRead(ledger_path) catch
        return lib.okText(out, "(no arena matches yet — start one with a \"question\", \"for\" and \"against\")");
    var t: std.Io.Writer.Allocating = .init(alloc);
    defer t.deinit();
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, ledger, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, trimmed, .{}) catch continue;
        if (parsed != .object) continue;
        const doc = parsed.object;
        try t.writer.print("{s}\t{s}\t{s}\n", .{ jsonStr(doc, "id"), jsonStr(doc, "winner"), jsonStr(doc, "question") });
        count += 1;
    }
    if (count == 0) return lib.okText(out, "(no arena matches yet)");
    return lib.okText(out, t.written());
}
