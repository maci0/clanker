//! Literal/substring stream rules with optional `*` wildcards. Compiles at
//! load; matches the tail of a ring buffer as tokens arrive.

const std = @import("std");

pub const PatternError = error{ EmptyPattern, BadEscape, OutOfMemory };

/// Compiled pattern: a sequence of literal fragments separated by `*`.
pub const Pattern = struct {
    parts: []const []const u8,
    /// Set when the pattern starts with `*`; when no literal fragments
    /// remain this is what makes an all-wildcards pattern match every input.
    leading_star: bool,
    /// True when the pattern ends with `*`.
    trailing_star: bool,

    pub fn compile(arena: std.mem.Allocator, src: []const u8) PatternError!Pattern {
        if (src.len == 0) return error.EmptyPattern;
        var parts: std.ArrayList([]const u8) = .empty;
        var buf: std.ArrayList(u8) = .empty;
        var leading_star = false;
        var i: usize = 0;
        while (i < src.len) : (i += 1) {
            const c = src[i];
            if (c == '\\') {
                if (i + 1 >= src.len) return error.BadEscape;
                i += 1;
                const next = src[i];
                if (next != '*' and next != '\\') return error.BadEscape;
                try buf.append(arena, next);
                continue;
            }
            if (c == '*') {
                if (buf.items.len == 0 and parts.items.len == 0) {
                    leading_star = true;
                } else {
                    try parts.append(arena, try arena.dupe(u8, buf.items));
                    buf.clearRetainingCapacity();
                }
                continue;
            }
            try buf.append(arena, c);
        }
        if (buf.items.len > 0) {
            try parts.append(arena, try arena.dupe(u8, buf.items));
        }
        if (parts.items.len == 0 and !leading_star) return error.EmptyPattern;
        const trailing_star = src[src.len - 1] == '*' and (src.len < 2 or src[src.len - 2] != '\\');
        return .{
            .parts = try parts.toOwnedSlice(arena),
            .leading_star = leading_star,
            .trailing_star = trailing_star,
        };
    }

    /// Returns true when every literal fragment appears somewhere in `hay`, in
    /// order, with each `*` wildcard spanning any bytes (including none).
    /// Matching is deliberately unanchored: a leading or trailing `*` does not
    /// change which slices match the bare fragments, because plain fragment
    /// search never requires the first fragment at offset 0 nor the last at the
    /// end. The only pattern without fragments is all wildcards, which matches
    /// every input.
    pub fn matches(self: Pattern, hay: []const u8) bool {
        if (self.parts.len == 0) return self.leading_star;
        var rest = hay;
        for (self.parts) |part| {
            const at = std.mem.find(u8, rest, part) orelse return false;
            rest = rest[at + part.len ..];
        }
        return true;
    }
};

pub const Rule = struct {
    name: []const u8,
    pattern: Pattern,
    inject: []const u8,
    max_fires: u32 = 1,
    fires: u32 = 0,
};

pub fn firstMatch(rules: []Rule, hay: []const u8) ?*Rule {
    for (rules) |*r| {
        if (r.max_fires > 0 and r.fires >= r.max_fires) continue;
        if (r.pattern.matches(hay)) return r;
    }
    return null;
}

test "compile rejects empty and bad escapes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.EmptyPattern, Pattern.compile(arena, ""));
    try std.testing.expectError(error.BadEscape, Pattern.compile(arena, "foo\\"));
    try std.testing.expectError(error.BadEscape, Pattern.compile(arena, "foo\\n"));
}

test "literal substring match" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const p = try Pattern.compile(arena_state.allocator(), "rm -rf /");
    try std.testing.expect(p.matches("please rm -rf /tmp"));
    try std.testing.expect(!p.matches("rm -r /"));
}

test "wildcard spans any bytes including empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const p = try Pattern.compile(arena_state.allocator(), "git push*--force");
    try std.testing.expect(p.matches("git push origin main --force"));
    try std.testing.expect(p.matches("git push--force"));
    try std.testing.expect(!p.matches("git push origin"));
}

test "escaped star is literal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const p = try Pattern.compile(arena_state.allocator(), "foo\\*bar");
    try std.testing.expect(p.matches("foo*bar"));
    try std.testing.expect(!p.matches("fooXbar"));
}

test "firstMatch is declaration order and respects max_fires" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rules = [_]Rule{
        .{ .name = "a", .pattern = try Pattern.compile(arena, "boom"), .inject = "no", .max_fires = 1, .fires = 1 },
        .{ .name = "b", .pattern = try Pattern.compile(arena, "boom"), .inject = "yes", .max_fires = 1 },
    };
    const hit = firstMatch(&rules, "kaboom").?;
    try std.testing.expectEqualStrings("b", hit.name);
}
