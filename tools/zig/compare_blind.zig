//! Rules for a blind side-by-side model comparison: which targets are legal,
//! what order the answers are shown in, what an anonymous label means, how a
//! model's own name is kept out of its own answer, and how a judge's reply is
//! read back into a winner.
//!
//! This module imports nothing from the guest ABI, so `zig build test` compiles
//! it for the host and runs the tests below — the same split `arena_match.zig`
//! has against `arena.zig`. `compare.zig` is the shell: it makes the calls,
//! persists `state/compare/<id>.json`, and renders.
//!
//! The one property everything here exists to protect: nothing a reader sees
//! before they pick may say which model produced which answer. That is a
//! property of the ordering (derived from the comparison id, not the order the
//! targets were configured in), of the labels (positional, not derived from the
//! provider), and of the answer text itself (a model that opens with "As
//! DeepSeek, I would..." has un-blinded itself, so its own names are struck out
//! of its own answer before anyone reads it).

const std = @import("std");

/// A comparison of one is not a comparison.
pub const min_entrants: usize = 2;

/// Bound on entrants per comparison. Every entrant is one concurrent model
/// call and one more answer the reader has to hold in their head, so this is a
/// cost ceiling on both sides, matching `arena`'s own roster cap.
pub const max_entrants: usize = 8;

/// Output cap per entrant, and the reason a comparison is affordable: the
/// question being asked is "which of these answers is better", which a reader
/// can only judge on answers short enough to read side by side.
pub const default_max_tokens: u32 = 600;

/// Cap for the judge call. A judgment is a label and a sentence.
pub const judge_max_tokens: u32 = 400;

/// Cap for the optional synthesis. Higher than the judge call because this is
/// prose someone reads, and a merged answer truncated mid-sentence is worse
/// than no merged answer at all.
pub const synthesis_max_tokens: u32 = 900;

/// Positional, never derived from the provider: label 0 is "A" whichever model
/// landed in slot 0.
pub const labels = [max_entrants][]const u8{ "A", "B", "C", "D", "E", "F", "G", "H" };

pub fn labelAt(pos: usize) []const u8 {
    return if (pos < labels.len) labels[pos] else "?";
}

/// One model to put in the comparison. An empty `model` means the provider's
/// configured default, which is what makes `--with deepseek` enough.
pub const Target = struct {
    provider: []const u8,
    model: []const u8 = "",
};

pub const TargetError = error{ TooFewTargets, TooManyTargets, DuplicateTarget, EmptyTarget };

/// Refused at the tool boundary, before a single model call is spent: two
/// entrants that are the same provider and the same model would produce two
/// samples of one model, which is a temperature demo, not a comparison.
pub fn validateTargets(targets: []const Target) TargetError!void {
    if (targets.len < min_entrants) return error.TooFewTargets;
    if (targets.len > max_entrants) return error.TooManyTargets;
    for (targets, 0..) |t, i| {
        if (std.mem.trim(u8, t.provider, " \t\r\n").len == 0) return error.EmptyTarget;
        for (targets[0..i]) |prior| {
            if (std.mem.eql(u8, prior.provider, t.provider) and std.mem.eql(u8, prior.model, t.model))
                return error.DuplicateTarget;
        }
    }
}

/// The seed the display order is derived from. Content-seeded rather than
/// clock-seeded so a stored comparison re-renders in the order it was shown in,
/// and so two comparisons of the same prompt do not share a permutation.
pub fn seedFrom(id: []const u8, prompt: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0x91d2_c0de);
    hasher.update(id);
    hasher.update("\x00");
    hasher.update(prompt);
    return hasher.final();
}

/// Fills `slots` with a permutation of `0..slots.len`, derived from `seed`.
/// `slots[pos]` is the target index shown at blind position `pos`.
///
/// Stable (the same seed always gives the same order, so a stored comparison
/// and a live one agree) but not revealing (it is not the order the targets
/// were configured or typed in, which is the order a reader would otherwise
/// assume and be right about).
pub fn blindOrder(slots: []usize, seed: u64) void {
    for (slots, 0..) |*s, i| s.* = i;
    if (slots.len < 2) return;
    var prng = std.Random.DefaultPrng.init(seed);
    var rand = prng.random();
    var i: usize = slots.len - 1;
    while (i > 0) : (i -= 1) {
        const j = rand.uintLessThan(usize, i + 1);
        std.mem.swap(usize, &slots[i], &slots[j]);
    }
}

// ------------------------------------------------------------- de-identifying

/// What a struck-out identity is replaced with. Deliberately visible: silently
/// deleting the words would leave a sentence that reads as if the model never
/// named itself, and a reader comparing answers should be able to see that one
/// of them tried to.
pub const redaction = "[model]";

/// Shortest identity fragment worth striking. Below this, a model name's parts
/// are ordinary words ("chat", "pro", "max", "mini") that appear in answers
/// about anything, and striking them would corrupt the text it is protecting.
pub const min_needle_len: usize = 6;

/// The strings that would give away which model wrote an answer: the provider
/// name, the model name, and the model name's own segments. `deepseek-reasoner`
/// yields "deepseek-reasoner", "deepseek" and "reasoner"; the "chat" of
/// `deepseek-chat` is below `min_needle_len` and is left alone.
///
/// Longest first, so a needle that contains another is struck as a whole rather
/// than leaving "[model]-reasoner" behind.
pub fn identityNeedles(alloc: std.mem.Allocator, provider: []const u8, model: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ provider, model }) |whole| {
        try addNeedle(alloc, &list, whole);
        var it = std.mem.splitAny(u8, whole, "-_/.:");
        while (it.next()) |part| try addNeedle(alloc, &list, part);
    }
    const out = try list.toOwnedSlice(alloc);
    std.mem.sort([]const u8, out, {}, struct {
        fn longerFirst(_: void, a: []const u8, b: []const u8) bool {
            return a.len > b.len;
        }
    }.longerFirst);
    return out;
}

fn addNeedle(alloc: std.mem.Allocator, list: *std.ArrayList([]const u8), candidate: []const u8) !void {
    const s = std.mem.trim(u8, candidate, " \t\r\n");
    if (s.len < min_needle_len) return;
    for (list.items) |existing| {
        if (std.ascii.eqlIgnoreCase(existing, s)) return;
    }
    try list.append(alloc, s);
}

/// Strikes every `needle` out of `text`, case-insensitively. Returns `text`
/// unchanged (not a copy) when nothing matched, so the common case allocates
/// nothing.
pub fn redactIdentity(alloc: std.mem.Allocator, text: []const u8, needles: []const []const u8) ![]const u8 {
    var current = text;
    var owned = false;
    for (needles) |needle| {
        const next = try strikeAll(alloc, current, needle);
        if (next.ptr == current.ptr and next.len == current.len) continue;
        if (owned) alloc.free(@constCast(current));
        current = next;
        owned = true;
    }
    return current;
}

fn strikeAll(alloc: std.mem.Allocator, text: []const u8, needle: []const u8) ![]const u8 {
    if (needle.len == 0 or needle.len > text.len) return text;
    if (findIgnoreCase(text, needle, 0) == null) return text;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        const hit = findIgnoreCase(text, needle, i) orelse break;
        try out.appendSlice(alloc, text[i..hit]);
        try out.appendSlice(alloc, redaction);
        i = hit + needle.len;
    }
    try out.appendSlice(alloc, text[i..]);
    return out.toOwnedSlice(alloc);
}

fn findIgnoreCase(haystack: []const u8, needle: []const u8, from: usize) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var i = from;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

// ------------------------------------------------------------------- picking

/// Prefixes a picker (human or model) puts in front of a bare label. Stripped
/// so "Answer B" resolves to B rather than to A, which is what a naive
/// first-letter scan would do and would be wrong in exactly the way that
/// matters.
const pick_prefixes = [_][]const u8{ "answer", "model", "candidate", "option", "response", "reply" };

/// Reads a blind label out of free text. Accepts "B", "b", "(B)", "Answer B:",
/// and the bare index "2" one-based. Returns null rather than guessing: a pick
/// that cannot be read must not silently become entrant A.
pub fn parseLabel(text: []const u8, n: usize) ?usize {
    var s = std.mem.trim(u8, text, " \t\r\n\"'`*.,:;()[]{}");
    // A prefix is only stripped when something follows it, so a reply of just
    // "answer" stays unreadable instead of becoming whatever trailed it.
    var stripped = true;
    while (stripped) {
        stripped = false;
        for (pick_prefixes) |p| {
            if (s.len > p.len and std.ascii.eqlIgnoreCase(s[0..p.len], p)) {
                const rest = std.mem.trim(u8, s[p.len..], " \t\r\n\"'`*.,:;()[]{}-");
                if (rest.len > 0) {
                    s = rest;
                    stripped = true;
                }
            }
        }
    }
    if (s.len != 1) return null;
    const c = std.ascii.toUpper(s[0]);
    if (c >= 'A' and c <= 'Z') {
        const pos = c - 'A';
        return if (pos < n) pos else null;
    }
    if (s[0] >= '1' and s[0] <= '9') {
        const pos = s[0] - '1';
        return if (pos < n) pos else null;
    }
    return null;
}

/// Whether a stored comparison may be read back with the label-to-model key
/// attached.
///
/// `clanker compare --show <id>` reveals, and should: whoever names a
/// comparison by id on the command line already watched the blind view that
/// minted the id. A browser opening the list has not. So a reader can ask to be
/// kept blind, and the answer to that ask is not advisory — a payload carrying
/// providers the page chooses not to paint is exactly as un-blinding as
/// painting them, because the bytes are in the tab either way, one devtools
/// panel from being read.
///
/// A recorded pick overrides the ask, because that is the moment blindness is
/// for: the reader has committed, and the whole point of the exercise is to
/// then be told who they picked.
pub fn mayReveal(asked_for_reveal: bool, has_pick: bool) bool {
    return asked_for_reveal or has_pick;
}

pub const Verdict = struct {
    /// Blind position the judge picked, not the target index. Resolving it back
    /// to a provider is the shell's job, and happens after the answer text has
    /// already been written out.
    pos: usize,
    reason: []const u8 = "",
};

/// Parses a judge reply of the documented shape
/// `{"winner": "B", "reason": "..."}`. Returns null when the reply names no
/// readable label, which the caller reports as "no verdict" rather than
/// defaulting to a winner: a judge that answers garbage must not become a judge
/// that always picks A.
pub fn parseVerdict(alloc: std.mem.Allocator, raw: []const u8, n: usize) ?Verdict {
    const span = objectSpan(stripFence(raw)) orelse return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, span, .{}) catch return null;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return null,
    };
    const winner = obj.get("winner") orelse return null;
    const pos = switch (winner) {
        .string => |s| parseLabel(s, n) orelse return null,
        // A judge that answers with a number means the label's position, and
        // counts from one the way the rendered list does.
        .integer => |i| blk: {
            if (i < 1 or i > @as(i64, @intCast(n))) return null;
            break :blk @as(usize, @intCast(i - 1));
        },
        else => return null,
    };
    return .{
        .pos = pos,
        .reason = if (obj.get("reason")) |r| (if (r == .string) r.string else "") else "",
    };
}

/// Strips a fenced code block, if the reply is wrapped in one. Models asked for
/// JSON commonly answer with ```json … ```, and treating that as a parse
/// failure would throw away a perfectly good verdict.
fn stripFence(raw: []const u8) []const u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (!std.mem.startsWith(u8, s, "```")) return s;
    s = s[3..];
    if (std.mem.findScalar(u8, s, '\n')) |nl| s = s[nl + 1 ..];
    if (std.mem.lastIndexOf(u8, s, "```")) |close| s = s[0..close];
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Finds the outermost `{…}` span, honouring strings and escapes so a brace
/// inside `"reason"` does not end the object early.
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

/// Comparison ids land in a path (`state/compare/<id>.json`), so they are
/// restricted to characters that cannot traverse out of it — not merely checked
/// for "..", which `a/../../b` passes.
pub fn isSafeId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

// ----------------------------------------------------------------- tests

test "validateTargets refuses a comparison that is not one" {
    const one = [_]Target{.{ .provider = "a" }};
    try std.testing.expectError(error.TooFewTargets, validateTargets(&one));

    var many: [max_entrants + 1]Target = undefined;
    for (&many, 0..) |*t, i| t.* = .{ .provider = "p", .model = labels[i % labels.len] };
    try std.testing.expectError(error.TooManyTargets, validateTargets(&many));

    const blank = [_]Target{ .{ .provider = "  " }, .{ .provider = "b" } };
    try std.testing.expectError(error.EmptyTarget, validateTargets(&blank));

    // Same provider, same model: two samples of one model, not a comparison.
    const dupe = [_]Target{ .{ .provider = "a", .model = "m" }, .{ .provider = "a", .model = "m" } };
    try std.testing.expectError(error.DuplicateTarget, validateTargets(&dupe));
}

test "validateTargets allows two models of one provider" {
    // The single-key case the live check runs on: one provider, two models.
    const pair = [_]Target{
        .{ .provider = "deepseek", .model = "deepseek-chat" },
        .{ .provider = "deepseek", .model = "deepseek-reasoner" },
    };
    try validateTargets(&pair);
}

test "blindOrder is a permutation, stable per seed and not the input order" {
    var slots: [4]usize = undefined;
    blindOrder(&slots, seedFrom("compare-1", "why is the sky blue"));

    var seen = [_]bool{false} ** 4;
    for (slots) |s| {
        try std.testing.expect(s < 4);
        try std.testing.expect(!seen[s]);
        seen[s] = true;
    }

    var again: [4]usize = undefined;
    blindOrder(&again, seedFrom("compare-1", "why is the sky blue"));
    try std.testing.expectEqualSlices(usize, &slots, &again);

    // A different comparison of the same prompt gets a different seed, so the
    // reader cannot learn the order from one run and apply it to the next.
    var other: [4]usize = undefined;
    blindOrder(&other, seedFrom("compare-2", "why is the sky blue"));
    try std.testing.expect(seedFrom("compare-1", "x") != seedFrom("compare-2", "x"));
    var seen_other = [_]bool{false} ** 4;
    for (other) |s| {
        try std.testing.expect(!seen_other[s]);
        seen_other[s] = true;
    }
}

test "blindOrder handles the degenerate sizes without touching memory it does not own" {
    var none: [0]usize = undefined;
    blindOrder(&none, 1);
    var one: [1]usize = undefined;
    blindOrder(&one, 1);
    try std.testing.expectEqual(@as(usize, 0), one[0]);
}

test "identityNeedles keeps the long fragments and drops the ordinary words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const needles = try identityNeedles(a, "deepseek", "deepseek-reasoner");
    // "deepseek-reasoner", "deepseek", "reasoner" — longest first.
    try std.testing.expectEqual(@as(usize, 3), needles.len);
    try std.testing.expectEqualStrings("deepseek-reasoner", needles[0]);
    for (needles[1..]) |n| try std.testing.expect(n.len >= min_needle_len);

    // "chat" is four characters: an ordinary word, left alone.
    const chat = try identityNeedles(a, "deepseek", "deepseek-chat");
    for (chat) |n| try std.testing.expect(!std.ascii.eqlIgnoreCase(n, "chat"));
}

test "redactIdentity strikes a model naming itself, whatever the case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const needles = try identityNeedles(a, "deepseek", "deepseek-reasoner");
    const out = try redactIdentity(a, "As DeepSeek, running DEEPSEEK-REASONER, I would say yes.", needles);
    try std.testing.expectEqualStrings(
        "As " ++ redaction ++ ", running " ++ redaction ++ ", I would say yes.",
        out,
    );
}

test "redactIdentity leaves an answer that never named itself untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const needles = try identityNeedles(a, "deepseek", "deepseek-chat");
    const text = "Rayleigh scattering: shorter wavelengths scatter more.";
    const out = try redactIdentity(a, text, needles);
    // Same bytes and the same allocation: nothing matched, nothing copied.
    try std.testing.expectEqual(text.ptr, out.ptr);
}

test "parseLabel reads the forms a picker actually types" {
    try std.testing.expectEqual(@as(?usize, 1), parseLabel("B", 3));
    try std.testing.expectEqual(@as(?usize, 1), parseLabel(" b ", 3));
    try std.testing.expectEqual(@as(?usize, 1), parseLabel("(B)", 3));
    try std.testing.expectEqual(@as(?usize, 1), parseLabel("Answer B", 3));
    try std.testing.expectEqual(@as(?usize, 1), parseLabel("**Answer: B**", 3));
    // One-based, matching the rendered list.
    try std.testing.expectEqual(@as(?usize, 1), parseLabel("2", 3));
}

test "parseLabel refuses what it cannot read instead of guessing A" {
    try std.testing.expectEqual(@as(?usize, null), parseLabel("", 3));
    try std.testing.expectEqual(@as(?usize, null), parseLabel("answer", 3));
    try std.testing.expectEqual(@as(?usize, null), parseLabel("they are both fine", 3));
    // Out of range: D was never on the table.
    try std.testing.expectEqual(@as(?usize, null), parseLabel("D", 3));
    try std.testing.expectEqual(@as(?usize, null), parseLabel("9", 3));
}

test "parseVerdict reads the documented judge reply, fenced or not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const plain = parseVerdict(a, "{\"winner\":\"C\",\"reason\":\"most specific\"}", 3).?;
    try std.testing.expectEqual(@as(usize, 2), plain.pos);
    try std.testing.expectEqualStrings("most specific", plain.reason);

    const fenced = parseVerdict(a, "```json\n{\"winner\":\"A\",\"reason\":\"clearest\"}\n```", 3).?;
    try std.testing.expectEqual(@as(usize, 0), fenced.pos);

    // A brace inside the reason must not end the object early.
    const braced = parseVerdict(a, "{\"winner\":\"B\",\"reason\":\"it showed {x} correctly\"}", 3).?;
    try std.testing.expectEqual(@as(usize, 1), braced.pos);
    try std.testing.expectEqualStrings("it showed {x} correctly", braced.reason);
}

test "parseVerdict refuses a judge that named nothing on the table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqual(@as(?Verdict, null), parseVerdict(a, "they were all good", 2));
    try std.testing.expectEqual(@as(?Verdict, null), parseVerdict(a, "{\"reason\":\"tie\"}", 2));
    try std.testing.expectEqual(@as(?Verdict, null), parseVerdict(a, "{\"winner\":\"D\"}", 2));
    try std.testing.expectEqual(@as(?Verdict, null), parseVerdict(a, "{\"winner\":7}", 2));
}

test "mayReveal honours a reader who asked to stay blind" {
    // The CLI's read-one path: asked to reveal, nothing picked yet, revealed.
    try std.testing.expect(mayReveal(true, false));
    // The browser's read-one path: asked to stay blind and nothing picked, so
    // the key stays out of the payload, not merely out of the render.
    try std.testing.expect(!mayReveal(false, false));
}

test "mayReveal opens up once a pick is on record" {
    // A pick is the reader committing, which is the event blindness was
    // protecting. Asking to stay blind after it cannot un-commit them.
    try std.testing.expect(mayReveal(false, true));
    try std.testing.expect(mayReveal(true, true));
}

test "isSafeId keeps a comparison id inside its own directory" {
    try std.testing.expect(isSafeId("compare-1786550737-ab12cd34"));
    try std.testing.expect(!isSafeId(""));
    try std.testing.expect(!isSafeId("../../etc/passwd"));
    try std.testing.expect(!isSafeId("a/../../b"));
    try std.testing.expect(!isSafeId("has space"));
}
