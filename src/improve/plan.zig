//! The planning half of plan-then-patch: parsing the idea list a planning
//! call returns, and deciding whether an idea is a repeat of work history
//! already records.
//!
//! The single-shot loop asked one model call to pick what to improve and
//! write an exact-match patch in the same breath, and every steering
//! mechanism around it (stuck_hint, mixHint, the "do not repeat that
//! mistake" line) is prose a model can talk past. Splitting the choice out
//! makes it mechanical: the engine dedups the candidate ideas against
//! history and pins the chosen idea's files into the context before any
//! patch is attempted, so the patch call sees the exact bytes it must match
//! instead of guessing at them.

const std = @import("std");
const json = std.json;
const proposal = @import("proposal.zig");

pub const Idea = struct {
    text: []const u8,
    files: []const []const u8,
};

/// The idea list a planning call returns:
/// `{"ideas": [{"idea": "...", "files": ["src/x.zig"]}]}`.
///
/// Returns null when the response is not that shape — including when the
/// model answered with a patch proposal despite being asked to plan — so the
/// caller can fall back to the unplanned behaviour instead of failing the
/// iteration. Files outside the readable surface are dropped rather than
/// failing the idea: the path was advisory (it steers context pinning), and
/// one hallucinated path must not cost an otherwise good idea.
pub fn parsePlan(
    arena: std.mem.Allocator,
    raw: []const u8,
    max_ideas: usize,
    max_files: usize,
) !?[]const Idea {
    const cleaned = proposal.stripMarkdownFence(raw);
    const v = json.parseFromSliceLeaky(json.Value, arena, cleaned, .{ .ignore_unknown_fields = true }) catch return null;
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const arr = switch (obj.get("ideas") orelse return null) {
        .array => |a| a,
        else => return null,
    };

    var out: std.ArrayList(Idea) = .empty;
    for (arr.items) |item| {
        const iobj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const text_raw = switch (iobj.get("idea") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const text = std.mem.trim(u8, text_raw, " \t\r\n");
        if (text.len == 0) continue;

        var files: std.ArrayList([]const u8) = .empty;
        if (iobj.get("files")) |fv| switch (fv) {
            .array => |fa| for (fa.items) |f| {
                const p = switch (f) {
                    .string => |s| s,
                    else => continue,
                };
                if (!proposal.validateReadPath(p)) continue;
                var seen = false;
                for (files.items) |have| {
                    if (std.mem.eql(u8, have, p)) seen = true;
                }
                if (seen) continue;
                try files.append(arena, p);
                if (files.items.len >= max_files) break;
            },
            else => {},
        };

        try out.append(arena, .{ .text = text, .files = try files.toOwnedSlice(arena) });
        if (out.items.len >= max_ideas) break;
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(arena);
}

/// Whether history already records an attempt at (approximately) this idea.
///
/// The planning prompt says not to repeat history, but that instruction has
/// the same weakness as every other prose hint here, so this is the
/// mechanical backstop. An idea counts as tried when at least four fifths of
/// its significant words appear in one past summary: exact matching misses
/// every paraphrase ("cache the registry" vs "add a cache for the
/// registry"), and anything looser starts eating novel ideas that share a
/// file name with an old one.
pub fn tried(arena: std.mem.Allocator, idea: []const u8, summaries: []const []const u8) !bool {
    const idea_toks = try tokens(arena, idea);
    if (idea_toks.len == 0) return false;
    for (summaries) |s| {
        const sum_toks = try tokens(arena, s);
        var hits: usize = 0;
        for (idea_toks) |t| {
            if (containsToken(sum_toks, t)) hits += 1;
        }
        if (hits * 5 >= idea_toks.len * 4) return true;
    }
    return false;
}

/// Lowercased alphanumeric words of the text, short ones dropped. Length is
/// the whole significance test: "the", "add" and "fix" appear in nearly
/// every summary, and letting them score turns any two ideas about the same
/// verb into a match.
fn tokens(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n,.;:'\"`()[]{}<>/\\|!?-_=+*");
    while (it.next()) |w| {
        if (w.len < 4) continue;
        const lower: []u8 = try arena.dupe(u8, w);
        for (lower) |*c| c.* = std.ascii.toLower(c.*);
        // Lightweight plural stemming: strip a trailing 's' so
        // "registries"/"registry" and "providers"/"provider" converge.
        // Handle -ies -> -y (e.g. registries -> registry) and plain -s.
        var word: []const u8 = lower;
        if (word.len > 4) {
            if (std.mem.endsWith(u8, word, "ies")) {
                lower[word.len - 3] = 'y';
                word = word[0 .. word.len - 2];
            } else if (std.mem.endsWith(u8, word, "ses") or std.mem.endsWith(u8, word, "xes") or std.mem.endsWith(u8, word, "zes")) {
                word = word[0 .. word.len - 2];
            } else if (word[word.len - 1] == 's' and word[word.len - 2] != 's') {
                word = word[0 .. word.len - 1];
            }
        }
        if (word.len < 4) continue;
        try out.append(arena, word);
    }
    return try out.toOwnedSlice(arena);
}

fn containsToken(list: []const []const u8, tok: []const u8) bool {
    for (list) |t| {
        if (std.mem.eql(u8, t, tok)) return true;
    }
    return false;
}

test "parsePlan reads ideas, drops unreadable paths, caps the list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw =
        \\{"ideas": [
        \\  {"idea": "cache the tool registry between attempts", "files": ["src/tools/registry.zig", "../etc/passwd", "tools/bin/x.wasm", "src/tools/registry.zig"]},
        \\  {"idea": "   ", "files": ["src/cli.zig"]},
        \\  {"idea": "retry transient provider errors", "files": []},
        \\  {"idea": "third", "files": ["src/main.zig"]},
        \\  {"idea": "fourth"}
        \\]}
    ;
    const ideas = (try parsePlan(arena, raw, 3, 4)).?;
    try std.testing.expectEqual(@as(usize, 3), ideas.len);
    try std.testing.expectEqualStrings("cache the tool registry between attempts", ideas[0].text);
    // The traversal and the committed-bytes path are dropped, the duplicate
    // is kept once.
    try std.testing.expectEqual(@as(usize, 1), ideas[0].files.len);
    try std.testing.expectEqualStrings("src/tools/registry.zig", ideas[0].files[0]);
    // The blank idea is skipped entirely, so "retry ..." is second.
    try std.testing.expectEqualStrings("retry transient provider errors", ideas[1].text);
    try std.testing.expectEqual(@as(usize, 0), ideas[1].files.len);
    try std.testing.expectEqualStrings("third", ideas[2].text);
}

test "parsePlan strips a markdown fence" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = "```json\n{\"ideas\": [{\"idea\": \"do the thing\", \"files\": []}]}\n```";
    const ideas = (try parsePlan(arena, raw, 6, 4)).?;
    try std.testing.expectEqual(@as(usize, 1), ideas.len);
    try std.testing.expectEqualStrings("do the thing", ideas[0].text);
}

test "parsePlan returns null for a patch proposal or an empty list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A model that ignored the planning request and sent a patch anyway.
    try std.testing.expectEqual(
        @as(?[]const Idea, null),
        try parsePlan(arena, "{\"summary\": \"x\", \"changes\": []}", 6, 4),
    );
    try std.testing.expectEqual(@as(?[]const Idea, null), try parsePlan(arena, "{\"ideas\": []}", 6, 4));
    try std.testing.expectEqual(@as(?[]const Idea, null), try parsePlan(arena, "not json at all", 6, 4));
}

test "tried matches a paraphrase of a past summary, not a novel idea" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const summaries = [_][]const u8{
        "Cache the tool registry load in improveOnce so attempts stop re-reading manifests",
        "Add a Bing RSS fallback to web_search when DuckDuckGo is unreachable",
    };

    // Same idea, different words around the same significant tokens.
    try std.testing.expect(try tried(arena, "cache the registry load in improveOnce", &summaries));
    // Shares a file's vocabulary ("web_search") but is a different change.
    try std.testing.expect(!try tried(arena, "web_search should honour the sandbox timeout budget", &summaries));
    try std.testing.expect(!try tried(arena, "retry transient provider errors in client.chat", &summaries));
    // Nothing significant to compare on either side.
    try std.testing.expect(!try tried(arena, "do it", &summaries));
}
