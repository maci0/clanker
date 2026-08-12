//! arena: run a bounded, judged debate between two positions — or a Battle
//! Royale between up to eight — and return a verdict traceable to the
//! transcript that produced it.
//!
//! Input (pairwise match):
//!   {"question": "...", "for": "<stance>", "against": "<stance>",
//!    "provider_for": "kimi-k3", "provider_against": "deepseek",
//!    "persona_for": "...", "persona_against": "...",
//!    "max_rounds": 4, "judge": "self"|"third", "judge_provider": "vertex-opus"}
//! Input (Battle Royale, 3-8):
//!   {"question": "...", "positions": ["...", "...", "..."],
//!    "providers": ["kimi-k3", "deepseek", "vertex-opus"], "personas": [...]}
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

/// Everything about the match that does not change while it runs.
const Setup = struct {
    id: []const u8,
    question: []const u8,
    labels: []const []const u8,
    personas: []const []const u8,
    max_rounds: u32,
    max_tokens: u32,
    third_party: bool,
    judge_provider: []const u8,
    /// Why third-party judging is not in effect despite being asked for.
    downgrade: []const u8,
    /// Design-review mode: each side has a real artifact to point at, and the
    /// verdict is a review finding rather than prose. Seeded from
    /// `defend`/`alternative` instead of bare stances, because a match between
    /// two opinions with nothing concrete on either side is what this mode
    /// exists to avoid.
    review: bool = false,
    /// The text each combatant defends, indexed like `labels`. Empty outside
    /// review mode.
    artifacts: []const []const u8 = &.{},
    /// Where each artifact lives, when the caller named a path. What makes a
    /// finding file-shaped rather than an opinion.
    paths: []const []const u8 = &.{},
};

const MoveRecord = struct {
    round: u32,
    combatant: usize,
    /// Who the move was aimed at, once resolved against the live roster.
    /// Meaningless for `concede`, `final_stand` and a forfeit, which is what
    /// `targeted` says.
    target: usize,
    targeted: bool,
    /// The move named no usable target and was aimed by `defaultTarget`.
    retargeted: bool,
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

const strField = lib.strFieldTrimmed;
const uintField = lib.uintFieldMap;

fn strOr(obj: std.json.ObjectMap, name: []const u8, fallback: []const u8) []const u8 {
    return strField(obj, name) orelse fallback;
}

fn newId(question: []const u8) ![]const u8 {
    return lib.prefixedId("arena", question);
}

const royale_sides = [m.max_combatants][]const u8{ "p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8" };

/// A combatant's seat. Pairwise keeps the for/against language the CLI flags
/// use; a Battle Royale numbers them instead, matching the roster the turn
/// prompt prints and the number a combatant names to target one.
fn sideName(i: usize, n: usize) []const u8 {
    if (n <= m.pairwise_combatants) return if (i == 0) "for" else "against";
    return if (i < royale_sides.len) royale_sides[i] else "p?";
}

/// A combatant's display name. The provider is the interesting half, but
/// positions may legitimately share one provider (the same model arguing
/// against itself), so the seat is always in there to keep labels distinct.
fn labelFor(i: usize, n: usize, provider: []const u8) []const u8 {
    const side = sideName(i, n);
    if (provider.len == 0) return side;
    return std.fmt.allocPrint(alloc, "{s} ({s})", .{ provider, side }) catch side;
}

// ------------------------------------------------------------- judge picking

const HarnessProvider = lib.HarnessProvider;
const HarnessConfig = lib.HarnessConfig;

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
/// combatant; otherwise the first configured provider that differs from every
/// one of them is used. Either way, failing to find one is a downgrade to
/// self-reported judging with a reason recorded — never a refusal, and never a
/// judge that is also a combatant (see the PRD's failure-mode table). A big
/// enough Battle Royale can therefore use up every configured provider, which
/// is exactly when the downgrade matters.
fn pickJudge(requested: []const u8, providers: []const []const u8) JudgeChoice {
    const cfg = lib.parseHarnessConfig();

    const fighting = struct {
        fn any(ps: []const []const u8, default_provider: []const u8, name: []const u8) bool {
            for (ps) |p| {
                if (std.mem.eql(u8, name, effectiveProvider(p, default_provider))) return true;
            }
            return false;
        }
    }.any;

    if (requested.len > 0) {
        if (fighting(providers, cfg.default_provider, requested))
            return .{ .provider = "", .downgrade = "requested judge provider is also a combatant" };
        return .{ .provider = requested, .downgrade = "" };
    }

    var it = cfg.providers.map.iterator();
    while (it.next()) |kv| {
        const name = kv.key_ptr.*;
        if (fighting(providers, cfg.default_provider, name)) continue;
        return .{ .provider = name, .downgrade = "" };
    }
    return .{ .provider = "", .downgrade = "no configured provider is free to judge (all are fighting)" };
}

// ------------------------------------------------------------------ prompts

/// " (src/x.zig)" when the caller named a path for this side, else "". What
/// turns the verdict's finding from an opinion into something file-shaped.
fn pathNote(setup: Setup, i: usize) []const u8 {
    if (i >= setup.paths.len or setup.paths[i].len == 0) return "";
    return std.fmt.allocPrint(alloc, " ({s})", .{setup.paths[i]}) catch "";
}

fn systemPrompt(setup: Setup, i: usize, combatants: []const m.Combatant) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    const o = &w.writer;
    const royale = combatants.len > m.pairwise_combatants;
    try o.print(
        \\You are a combatant in a clanker Arena match: a bounded, judged debate. You argue one
        \\position for the whole match and you never switch sides.
        \\
        \\You are "{s}". Your position: "{s}"
        \\
    , .{ setup.labels[i], combatants[i].position });
    if (royale) {
        try o.print("This is a Battle Royale: {d} positions, all against each other. The others are:\n", .{combatants.len});
        for (combatants, 0..) |c, j| {
            if (j == i) continue;
            try o.print("  [{d}] {s}: \"{s}\"\n", .{ j + 1, setup.labels[j], c.position });
        }
        try o.writeAll("Only one position can win. Nobody is your ally.\n");
    } else {
        try o.print("Your opponent's position: \"{s}\"\n", .{combatants[1 - i].position});
    }
    if (setup.review) {
        // Both artifacts, not just this combatant's: a design review is only
        // adversarial if each side can quote the other's actual text back at it
        // rather than arguing against a paraphrase.
        const opp = if (i == 0) @as(usize, 1) else 0;
        try o.writeAll("\nThis is a design review, not an abstract debate. You have the real thing to point at.\n");
        try o.print("\nWhat you are defending{s}:\n<<<\n{s}\n>>>\n", .{ pathNote(setup, i), setup.artifacts[i] });
        if (opp < setup.artifacts.len) {
            try o.print("\nThe alternative you must attack{s}:\n<<<\n{s}\n>>>\n", .{ pathNote(setup, opp), setup.artifacts[opp] });
        }
        try o.writeAll(
            \\
            \\Quote the specific line, name, or wording you are attacking or defending. Go after the
            \\weakest assumption in the alternative, not its weakest sentence. "It is simpler" is not
            \\an argument; "it drops the X case, see the Y branch" is.
            \\
        );
    }
    if (setup.personas[i].len > 0) try o.print("\nAdopt this persona while arguing: {s}\n", .{setup.personas[i]});

    try o.writeAll(
        \\
        \\Reply with exactly one JSON object and nothing else:
        \\
    );
    if (royale) {
        try o.writeAll(
            \\  {"move":"<move>","target":<number>,"text":"<your argument>","confidence":<0..1>,"opponent_landed":<0..1>}
            \\
            \\move is one of:
            \\  attack       a new argument, or a critique of the target's position
            \\  block        rebut the target's most recent attack on you, point by point
            \\  counter      a block that also lands its own attack on the target
            \\  concede      accept part or all of what was argued against you (this costs you the match)
            \\  final_stand  a closing argument; legal only in the final round
            \\
            \\target           REQUIRED for attack, block and counter: the bracketed number of the
            \\                 combatant you are aiming at, from the list above. You may only block
            \\                 the one attack you name, so pick the attack that hurts you most:
            \\                 everything else aimed at you this round lands in full. A move with no
            \\                 usable target is aimed at the strongest opponent left, at reduced force.
            \\
        );
    } else {
        try o.writeAll(
            \\  {"move":"<move>","text":"<your argument>","confidence":<0..1>,"opponent_landed":<0..1>}
            \\
            \\move is one of:
            \\  attack       a new argument, or a critique of your opponent's position
            \\  block        rebut your opponent's most recent attack, point by point
            \\  counter      a block that also lands its own attack in the same move
            \\  concede      accept part or all of your opponent's last point (this costs you the match)
            \\  final_stand  a closing argument; legal only in the final round
            \\
        );
    }
    try o.writeAll(
        \\confidence       how forceful this move is; 1.0 is your strongest available argument.
        \\opponent_landed  how much of the last move against you actually landed: 0.0 nothing,
        \\                 1.0 fully. Your block only negates the part you did not concede here,
        \\                 so under-reporting is the one thing a judge checks.
        \\
        \\Keep "text" concrete and under 120 words. Argue the substance; never restate these
        \\rules. A reply that is not a valid move object is scored as a weak attack.
    );
    return w.written();
}

fn turnPrompt(
    setup: Setup,
    i: usize,
    combatants: []const m.Combatant,
    board: *const m.Board,
    opening: bool,
    round: u32,
    moves: []const MoveRecord,
) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    const o = &w.writer;
    const royale = combatants.len > m.pairwise_combatants;
    try o.print("Question under debate: {s}\n\n", .{setup.question});
    try o.print("Round {d} of {d}. Your HP {d}/{d}.\n", .{ round, setup.max_rounds, combatants[i].hp, m.starting_hp });

    if (royale) {
        // The live roster, because who is still in the fight is exactly what a
        // combatant needs to pick a legal target.
        try o.writeAll("\nStanding:\n");
        for (combatants, 0..) |c, j| {
            if (j == i) continue;
            if (!c.alive()) {
                try o.print("  [{d}] {s}: {s} (out: {s})\n", .{ j + 1, setup.labels[j], c.position, if (c.conceded) "conceded" else "eliminated" });
                continue;
            }
            try o.print("  [{d}] {s}: {s} ({d} HP)\n", .{ j + 1, setup.labels[j], c.position, c.hp });
        }
    } else {
        try o.print("Your opponent has {d}/{d} HP.\n", .{ combatants[1 - i].hp, m.starting_hp });
    }

    if (round >= setup.max_rounds) {
        try o.writeAll("\nThis is the final round: final_stand is legal now, and nothing after this counts.\n");
    } else {
        try o.writeAll("\nfinal_stand is NOT legal yet; it would be scored as a weak attack.\n");
    }

    // What is aimed at this combatant, itemised: with several attackers, which
    // one to block is the actual decision of the turn.
    const total = if (opening) 0 else board.incomingTotal(i);
    if (total > 0) {
        try o.print("Damage in flight at you, {d} total:\n", .{total});
        for (combatants, 0..) |_, from| {
            const amount = board.incomingFrom(from, i);
            if (amount == 0) continue;
            try o.print("  {d} from [{d}] {s}\n", .{ amount, from + 1, setup.labels[from] });
        }
        if (royale) {
            try o.writeAll("A block or counter negates only the one you target. The rest lands whatever you do.\n");
        } else {
            try o.writeAll("A block or counter is what negates it; anything else takes it in full.\n");
        }
    } else {
        try o.writeAll("Nothing is in flight at you, so a block or counter has nothing to rebut and would be scored as a weak attack.\n");
    }

    if (moves.len == 0) {
        try o.writeAll("\nNo moves yet; this is the opening round and nobody has seen anybody. Make your opening attack.\n");
    } else {
        try o.writeAll("\nEvery move so far, oldest first:\n");
        for (moves) |mv| {
            if (mv.targeted) {
                try o.print("  [r{d}] {s} {s} at {s}: {s}\n", .{ mv.round, setup.labels[mv.combatant], mv.move, setup.labels[mv.target], mv.text });
            } else {
                try o.print("  [r{d}] {s} {s}: {s}\n", .{ mv.round, setup.labels[mv.combatant], mv.move, mv.text });
            }
        }
    }
    try o.writeAll("\nYour move.");
    return w.written();
}

fn judgePrompt(
    setup: Setup,
    mover: usize,
    target: usize,
    reply: m.Reply,
    in_flight: u16,
    incoming_text: []const u8,
) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    const o = &w.writer;
    try o.print(
        \\You are the neutral judge of one exchange in a debate. You are not arguing; you score.
        \\
        \\Question under debate: {s}
        \\
        \\The move you are scoring was made by "{s}" ({s}), aimed at "{s}":
        \\{s}
        \\
    , .{ setup.question, setup.labels[mover], @tagName(reply.move), setup.labels[target], reply.text });
    if (in_flight > 0) {
        try o.print("It is answering this attack from \"{s}\" ({d} damage in flight):\n{s}\n\n", .{ setup.labels[target], in_flight, incoming_text });
    } else {
        try o.writeAll("There was no attack from that combatant in flight for it to answer.\n\n");
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

fn synthesisPrompt(setup: Setup, combatants: []const m.Combatant, v: m.Verdict, moves: []const MoveRecord) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    const o = &w.writer;
    try o.print("A judged debate has finished. Write the answer it produced.\n\nQuestion: {s}\n\n", .{setup.question});
    for (combatants, 0..) |c, i| {
        const state = if (c.conceded) ", conceded" else if (c.eliminated()) ", eliminated" else "";
        try o.print("{s}: \"{s}\", {d} HP left{s}\n", .{ setup.labels[i], c.position, c.hp, state });
    }
    if (v.winner) |wi| {
        try o.print("\nThe match went to {s} ({s}).\n", .{ setup.labels[wi], @tagName(v.reason) });
    } else {
        try o.writeAll("\nThe match was a draw.\n");
    }
    try o.writeAll("\nTranscript, oldest first:\n");
    for (moves) |mv| {
        if (mv.targeted) {
            try o.print("  [r{d}] {s} {s} at {s}: {s}\n", .{ mv.round, setup.labels[mv.combatant], mv.move, setup.labels[mv.target], mv.text });
        } else {
            try o.print("  [r{d}] {s} {s}: {s}\n", .{ mv.round, setup.labels[mv.combatant], mv.move, mv.text });
        }
    }
    if (setup.review) {
        // The same shape a docs/prompts/*-review.md prompt already reports, so a
        // verdict can be pasted into a review rather than translated into one.
        // The transcript of why one design held up is the part a single
        // reviewer's one-pass verdict does not produce.
        try o.writeAll(
            \\
            \\Report this as a design-review finding, not prose. Exactly these lines:
            \\
            \\Verdict: <the position that held up>
            \\Reason: <one line, naming the specific assumption that broke or held>
            \\Where: <file, or file:line, or the wording under review; "n/a" if there is none>
            \\Respect: <the point the losing side landed that the winner must still handle, or "none">
            \\Confidence: <high|medium|low, and one clause why>
            \\
            \\Judge what was argued. If the losing side landed something the winner never answered,
            \\say so on the Respect line rather than smoothing it over: that line is the reason this
            \\is worth more than a single reviewer's verdict.
        );
        return w.written();
    }
    try o.writeAll(
        \\
        \\In under 150 words, answer the question directly. Lead with the winning position, and
        \\carry over any point a losing position landed that the answer should still respect. Do not
        \\narrate the match, name HP, or say who won; the reader already has that. Prose only, no
        \\JSON, no headings.
    );
    return w.written();
}

// -------------------------------------------------------------- match runner

fn startMatch(out: *lib.Out, obj: std.json.ObjectMap, question: []const u8) !void {
    const cfg = settings();

    // Design-review seeding: two real artifacts, not two abstract stances. The
    // PRD is explicit that the match needs something to point at on both sides,
    // so this mode derives the positions rather than asking for them.
    const defend = strField(obj, "defend");
    const alternative = strField(obj, "alternative");
    const review = defend != null or alternative != null;
    var artifacts: []const []const u8 = &.{};
    var paths: []const []const u8 = &.{};

    // Positions: the flag-shaped for/against pair, an explicit array (which is
    // how a Battle Royale of 3-8 is asked for), or a review's two artifacts.
    var positions: []const []const u8 = &.{};
    if (review) {
        if (defend == null or alternative == null)
            return lib.fail(out, "a design review needs both \"defend\" and \"alternative\": one artifact to defend and one to attack from");
        if (obj.get("positions") != null or obj.get("for") != null or obj.get("against") != null)
            return lib.fail(out, "\"defend\"/\"alternative\" derive the positions; do not also pass \"for\", \"against\" or \"positions\"");
        const pair = try alloc.alloc([]const u8, 2);
        // A stance the combatant can actually restate, defaulting to the shape
        // the PRD describes rather than making the caller phrase it twice.
        pair[0] = strField(obj, "defend_stance") orelse "keep the implementation as written";
        pair[1] = strField(obj, "alternative_stance") orelse "adopt the alternative instead";
        try validate(out, pair) orelse return;
        positions = pair;

        const arts = try alloc.alloc([]const u8, 2);
        arts[0] = defend.?;
        arts[1] = alternative.?;
        artifacts = arts;
        const ps = try alloc.alloc([]const u8, 2);
        ps[0] = strField(obj, "defend_path") orelse "";
        ps[1] = strField(obj, "alternative_path") orelse "";
        paths = ps;
    } else if (obj.get("positions")) |v| {
        if (v != .array) return lib.fail(out, "positions must be an array of stances");
        var listed: std.ArrayList([]const u8) = .empty;
        for (v.array.items) |it| {
            if (it != .string) return lib.fail(out, "positions must be an array of stances");
            try listed.append(alloc, std.mem.trim(u8, it.string, " \t\r\n"));
        }
        try validate(out, listed.items) orelse return;
        positions = listed.items;
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
                "a debate needs two distinct positions: pass \"for\" and \"against\", or \"positions\" for a Battle Royale");
        }
        const pair = try alloc.alloc([]const u8, 2);
        pair[0] = for_side.?;
        pair[1] = against_side.?;
        try validate(out, pair) orelse return;
        positions = pair;
    }

    const n = positions.len;
    const royale = n > m.pairwise_combatants;

    // Providers: the pairwise flags, or a parallel array for a royale. A short
    // array leaves the rest on the configured default rather than erroring —
    // "give the first two their own model" is a reasonable thing to mean.
    const providers = try alloc.alloc([]const u8, n);
    @memset(providers, "");
    const personas = try alloc.alloc([]const u8, n);
    @memset(personas, "");
    if (!royale) {
        providers[0] = strOr(obj, "provider_for", "");
        providers[1] = strOr(obj, "provider_against", "");
        personas[0] = strOr(obj, "persona_for", "");
        personas[1] = strOr(obj, "persona_against", "");
    }
    if (obj.get("providers")) |v| if (v == .array) {
        for (v.array.items, 0..) |it, i| {
            if (i >= n or it != .string) continue;
            providers[i] = std.mem.trim(u8, it.string, " \t\r\n");
        }
    };
    if (obj.get("personas")) |v| if (v == .array) {
        for (v.array.items, 0..) |it, i| {
            if (i >= n or it != .string) continue;
            personas[i] = std.mem.trim(u8, it.string, " \t\r\n");
        }
    };

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

    const labels = try alloc.alloc([]const u8, n);
    for (0..n) |i| labels[i] = labelFor(i, n, providers[i]);

    const setup = Setup{
        .id = try newId(question),
        .question = question,
        .labels = labels,
        .personas = personas,
        .max_rounds = m.clampRounds(uintField(obj, "max_rounds") orelse cfg.max_rounds),
        .max_tokens = uintField(obj, "max_tokens") orelse cfg.max_tokens,
        .third_party = third_party,
        .judge_provider = judge.provider,
        .downgrade = judge.downgrade,
        .review = review,
        .artifacts = artifacts,
        .paths = paths,
    };

    const combatants = try alloc.alloc(m.Combatant, n);
    for (0..n) |i| combatants[i] = .{ .position = positions[i], .provider = providers[i], .persona = personas[i] };
    const systems = try alloc.alloc([]const u8, n);
    for (0..n) |i| systems[i] = try systemPrompt(setup, i, combatants);

    var moves: std.ArrayList(MoveRecord) = .empty;
    defer moves.deinit(alloc);
    // Damage in flight, per attacker-target pair: a forfeited turn leaves
    // damage standing while everyone else keeps attacking, and a block can only
    // negate the one attack it names.
    var board = m.Board{};
    var rounds_played: u32 = 0;

    var round: u32 = 1;
    while (round <= setup.max_rounds) : (round += 1) {
        // Round 1 is every opening, made blind: nobody has anything to react
        // to, so it sees no transcript and takes no damage until round 2.
        const opening = round == 1;

        for (0..n) |i| {
            // An eliminated or conceded combatant is out of the match, not just
            // out of this round: it stops taking turns entirely.
            if (!combatants[i].alive()) continue;

            // Read out per turn, not once per round, for two reasons: a later
            // mover must see the earlier movers' moves from this same round
            // ("every move so far", not just the previous round's), and
            // `moves.items` is invalidated by the append below the moment the
            // list grows — a slice hoisted out of this loop dangles as soon as
            // the third move reallocates it.
            const visible: []const MoveRecord = if (opening) &.{} else moves.items;
            const prompt = try turnPrompt(setup, i, combatants, &board, opening, round, visible);
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
                const o = m.forfeitTurn(&board, combatants, i);
                try moves.append(alloc, .{
                    .round = round,
                    .combatant = i,
                    .target = i,
                    .targeted = false,
                    .retargeted = false,
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

            // Where the move is aimed. Pairwise has exactly one candidate, so
            // the field is not asked for and not needed; above that a move that
            // named nobody usable is aimed by `defaultTarget` and pays the
            // weak-confidence floor for it, since dropping the move outright
            // would contradict "never dropped silently".
            var retargeted = false;
            const target: usize = blk: {
                if (!royale) break :blk 1 - i;
                if (m.resolveTarget(parsed.target, combatants, setup.labels, i)) |t| break :blk t;
                retargeted = true;
                break :blk m.defaultTarget(&board, combatants, i) orelse i;
            };
            // Nobody left to aim at: the match is already decided, so this turn
            // has nothing to do.
            if (target == i) break;

            const incoming = if (opening) 0 else board.incomingFrom(target, i);
            var reply = m.legalize(parsed, round >= setup.max_rounds, incoming);
            if (retargeted) {
                reply.weak = true;
                reply.confidence = @min(reply.confidence, m.weak_confidence);
            }

            // Self-reported: the mover says how much of the incoming attack
            // landed, and its block gets credit for the rest. A reply that
            // omits the number gets half credit — neither free nor worthless.
            var credit: f64 = 1.0 - (reply.opponent_landed orelse 0.5);
            var confidence = reply.confidence;
            var judged_by: []const u8 = "self";
            var note: []const u8 = "";
            if (setup.third_party) {
                const incoming_text = lastAttackText(moves.items, target, i);
                if (judgeExchange(setup, i, target, reply, incoming, incoming_text)) |j| {
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

            // In the opening round nothing has been seen, so nothing resolves
            // yet: only the move's own damage goes into flight.
            const o = if (opening)
                m.openingTurn(&board, combatants, i, target, reply.move, confidence)
            else
                m.resolveTurn(&board, combatants, i, target, reply.move, confidence, credit);

            const offensive = switch (reply.move) {
                .attack, .block, .counter => true,
                .concede, .final_stand => false,
            };
            try moves.append(alloc, .{
                .round = round,
                .combatant = i,
                .target = target,
                .targeted = offensive,
                .retargeted = retargeted and offensive,
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
        }

        rounds_played = round;
        // Written every round, not only at the end, so a match in progress is
        // readable by another process (the web UI polls exactly this file).
        persist(setup, combatants, moves.items, rounds_played, null, "running") catch |err|
            lib.logInfo(@errorName(err));
        if (m.isOver(combatants, round, setup.max_rounds)) break;
    }

    // Damage still in flight when the match ends never got answered, so it
    // lands — otherwise the last attack of a match would always be free.
    for (0..n) |i| {
        const pending = board.incomingTotal(i);
        if (pending == 0) continue;
        m.applyOutcome(&combatants[i], .{ .taken = pending });
        board.clearIncoming(i);
    }

    const verdict = m.decide(combatants);
    var head_buf: [1024]u8 = undefined;
    const head = m.headline(&head_buf, combatants, setup.labels, verdict);
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
            error.DuplicatePosition => "the two positions are identical, so there is nothing to argue",
            error.EmptyPosition => "a position cannot be blank",
            error.TooManyPositions => "at most 8 positions; Battle Royale mode tops out there",
        });
        return null;
    };
    return {};
}

/// The most recent attack `by` aimed at `at`, so the judge sees the specific
/// argument the move under review is answering — not merely the last thing that
/// combatant said, which in a Battle Royale may have been aimed elsewhere.
fn lastAttackText(moves: []const MoveRecord, by: usize, at: usize) []const u8 {
    var i = moves.len;
    while (i > 0) {
        i -= 1;
        const mv = moves[i];
        if (mv.combatant == by and mv.dealt > 0 and mv.targeted and mv.target == at) return mv.text;
    }
    return "";
}

fn judgeExchange(
    setup: Setup,
    mover: usize,
    target: usize,
    reply: m.Reply,
    in_flight: u16,
    incoming_text: []const u8,
) ?m.Judgment {
    const prompt = judgePrompt(setup, mover, target, reply, in_flight, incoming_text) catch return null;
    const raw = lib.llmSystem(null, prompt, if (setup.judge_provider.len > 0) setup.judge_provider else null, judge_max_tokens) catch return null;
    return m.parseJudgment(alloc, raw);
}

fn synthesize(setup: Setup, combatants: []const m.Combatant, v: m.Verdict, moves: []const MoveRecord) ?[]const u8 {
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
    combatants: []const m.Combatant,
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
    if (setup.review) {
        // A review match's verdict is a finding, not prose, so a reader has to
        // be able to tell which it is holding without parsing the text.
        try s.objectField("mode");
        try s.write("review");
    }
    if (setup.downgrade.len > 0) {
        try s.objectField("judge_downgraded");
        try s.write(setup.downgrade);
    }

    try s.objectField("combatants");
    try s.beginArray();
    for (combatants, 0..) |c, i| {
        try s.beginObject();
        try s.objectField("side");
        try s.write(sideName(i, combatants.len));
        try s.objectField("label");
        try s.write(setup.labels[i]);
        try s.objectField("position");
        try s.write(c.position);
        try s.objectField("provider");
        try s.write(c.provider);
        try s.objectField("persona");
        try s.write(c.persona);
        // The artifact is what makes a review finding checkable later: without
        // the path, "Where:" in the verdict has nothing behind it.
        if (i < setup.paths.len and setup.paths[i].len > 0) {
            try s.objectField("path");
            try s.write(setup.paths[i]);
        }
        try s.objectField("hp");
        try s.write(c.hp);
        try s.objectField("max_hp");
        try s.write(m.starting_hp);
        try s.objectField("conceded");
        try s.write(c.conceded);
        // Out of the match, not just out of a round — what the pixel view needs
        // to know whose sprite the bulldozer comes for (PRD phase 5).
        try s.objectField("eliminated");
        try s.write(c.eliminated());
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
            if (mv.targeted) {
                try s.objectField("target");
                try s.write(mv.target);
                try s.objectField("target_label");
                try s.write(setup.labels[mv.target]);
                if (mv.retargeted) {
                    try s.objectField("retargeted");
                    try s.write(true);
                }
            }
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
    combatants: []const m.Combatant,
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

fn appendLedger(setup: Setup, combatants: []const m.Combatant, v: m.Verdict, head: []const u8) !void {
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
    combatants: []const m.Combatant,
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

    var w = lib.writer(out);
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
    combatants: []const m.Combatant,
    moves: []const MoveRecord,
    rounds_played: u32,
    final: ?Final,
) !void {
    if (setup.review) {
        try o.print("arena {s}: design review. {s}\n", .{ setup.id, setup.question });
    } else if (combatants.len > m.pairwise_combatants) {
        try o.print("arena {s}: battle royale, {d} positions. {s}\n", .{ setup.id, combatants.len, setup.question });
    } else {
        try o.print("arena {s}: {s}\n", .{ setup.id, setup.question });
    }
    for (combatants, 0..) |c, i| {
        try o.print("  {s:<8} \"{s}\"  [{s}]{s}\n", .{ sideName(i, combatants.len), c.position, setup.labels[i], pathNote(setup, i) });
    }
    try o.print("  judge: {s}", .{if (setup.third_party) "third-party" else "self-reported"});
    if (setup.third_party) try o.print(" ({s})", .{setup.judge_provider});
    if (setup.downgrade.len > 0) try o.print(" (downgraded: {s})", .{setup.downgrade});
    try o.print(" · {d} of max {d} rounds\n", .{ rounds_played, setup.max_rounds });

    var round: u32 = 1;
    while (round <= rounds_played) : (round += 1) {
        try o.print("\nround {d}\n", .{round});
        for (moves) |mv| {
            if (mv.round != round) continue;
            try o.print("  {s} {s}", .{ setup.labels[mv.combatant], mv.move });
            // Who a move was aimed at is only worth printing when there was a
            // choice; in a pairwise match it is always the one opponent.
            if (mv.targeted and combatants.len > m.pairwise_combatants) {
                try o.print(" at {s}", .{setup.labels[mv.target]});
                if (mv.retargeted) try o.writeAll(" (no target named)");
            }
            if (mv.weak) try o.writeAll(" (unparsed, scored weak)");
            if (mv.truncated) try o.writeAll(" (cut off, force capped)");
            try o.print("  {d} HP", .{mv.hp_after});
            if (mv.taken > 0) try o.print(" (-{d})", .{mv.taken});
            if (mv.blocked > 0) try o.print(" (blocked {d})", .{mv.blocked});
            if (mv.dealt > 0) try o.print(" (deals {d})", .{mv.dealt});
            if (mv.hp_after <= 0) try o.writeAll("  ELIMINATED");
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
    var w = lib.writer(out);
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
    try o.print("arena {s}: {s}\n", .{ jsonStr(doc, "id"), jsonStr(doc, "question") });
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
                const at = jsonStr(mv.object, "target_label");
                try o.print("  {s} {s}", .{ jsonStr(mv.object, "label"), jsonStr(mv.object, "move") });
                if (at.len > 0) try o.print(" at {s}", .{at});
                try o.print("  {s} HP\n      {s}\n", .{ jsonNum(mv.object, "hp_after"), jsonStr(mv.object, "text") });
            }
        }
    };
    if (doc.get("verdict")) |v| if (v == .object) {
        try o.print("\nverdict: {s}\n\n{s}\n", .{ jsonStr(v.object, "headline"), jsonStr(v.object, "answer") });
    };
    return t.written();
}

const jsonStr = lib.jsonStrField;

fn jsonNum(obj: std.json.ObjectMap, name: []const u8) []const u8 {
    const v = obj.get(name) orelse return "?";
    return switch (v) {
        .integer => |n| std.fmt.allocPrint(alloc, "{d}", .{n}) catch "?",
        .float => |f| std.fmt.allocPrint(alloc, "{d}", .{f}) catch "?",
        else => "?",
    };
}

/// Past matches, newest first, as both a text table and a structured array.
///
/// The array is what the web UI's match picker reads; the text is what the CLI
/// and an agent get. Both come off the same ledger lines rather than walking
/// every match file, which is the reason the ledger exists.
fn listMatches(out: *lib.Out) !void {
    const ledger = lib.fsRead(ledger_path) catch
        return emptyList(out, "(no arena matches yet; start one with a \"question\", \"for\" and \"against\")");

    var entries: std.ArrayList(std.json.ObjectMap) = .empty;
    defer entries.deinit(alloc);
    var it = std.mem.splitScalar(u8, ledger, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, trimmed, .{}) catch continue;
        if (parsed != .object) continue;
        try entries.append(alloc, parsed.object);
    }
    if (entries.items.len == 0) return emptyList(out, "(no arena matches yet)");

    // Newest first: the ledger is append-ordered, and a picker wants the match
    // that just finished at the top.
    std.mem.reverse(std.json.ObjectMap, entries.items);

    var t: std.Io.Writer.Allocating = .init(alloc);
    defer t.deinit();
    for (entries.items) |doc| {
        try t.writer.print("{s}\t{s}\t{s}\n", .{ jsonStr(doc, "id"), jsonStr(doc, "winner"), jsonStr(doc, "question") });
    }

    var w = lib.writer(out);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(t.written());
    try s.objectField("matches");
    try s.beginArray();
    for (entries.items) |doc| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(jsonStr(doc, "id"));
        try s.objectField("question");
        try s.write(jsonStr(doc, "question"));
        try s.objectField("winner");
        try s.write(jsonStr(doc, "winner"));
        try s.objectField("reason");
        try s.write(jsonStr(doc, "reason"));
        try s.objectField("headline");
        try s.write(jsonStr(doc, "headline"));
        if (doc.get("hp")) |hp| if (hp == .array) {
            try s.objectField("hp");
            try s.beginArray();
            for (hp.array.items) |v| try s.write(if (v == .integer) v.integer else 0);
            try s.endArray();
        };
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

/// An empty listing still answers with `matches`, so a caller does not have to
/// tell "no matches" apart from "this build has no such field".
fn emptyList(out: *lib.Out, msg: []const u8) !void {
    var w = lib.writer(out);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(msg);
    try s.objectField("matches");
    try s.beginArray();
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}
