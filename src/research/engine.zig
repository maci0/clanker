//! Research engine: drives autonomous research workflows for the
//! self-improvement loop. Provides structured exploration of codebases,
//! documentation, and external sources to inform improvement proposals.
//!
//! This is deliberately outside the protected surface (src/improve/,
//! src/evals/, src/toolhost/builder.zig) so clanker can keep strengthening
//! its research capabilities.

const std = @import("std");

/// A research finding: a piece of information discovered during exploration.
pub const Finding = struct {
    source: []const u8,
    summary: []const u8,
    relevance: f64 = 1.0,
};

/// Research context passed to the engine.
pub const Context = struct {
    query: []const u8 = "",
    scope: []const []const u8 = &.{},
    max_findings: usize = 20,
};

/// Placeholder research engine. The self-improvement loop can use this
/// to gather structured information before generating proposals.
pub const Engine = struct {
    arena: std.mem.Allocator,
    findings: std.ArrayList(Finding) = .empty,

    pub fn init(arena: std.mem.Allocator) Engine {
        return .{ .arena = arena };
    }

    pub fn deinit(self: *Engine) void {
        self.findings.deinit(self.arena);
    }

    /// Records a finding from any research source.
    pub fn addFinding(self: *Engine, finding: Finding) !void {
        try self.findings.append(self.arena, finding);
    }

    /// Returns all findings gathered so far.
    pub fn getFindings(self: *const Engine) []const Finding {
        return self.findings.items;
    }

    /// Summarizes findings into a single string for injection into an
    /// improvement context.
    pub fn summarize(self: *const Engine, arena: std.mem.Allocator) ![]const u8 {
        if (self.findings.items.len == 0) return "";
        var buf: std.ArrayList(u8) = .empty;
        for (self.findings.items, 0..) |f, i| {
            if (i > 0) try buf.appendSlice(arena, "\n");
            try buf.appendSlice(arena, "- ");
            try buf.appendSlice(arena, f.summary);
            if (f.source.len > 0) {
                try buf.appendSlice(arena, " (");
                try buf.appendSlice(arena, f.source);
                try buf.appendSlice(arena, ")");
            }
        }
        return buf.toOwnedSlice(arena);
    }
};

test "engine records and summarizes findings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var e = Engine.init(arena);
    defer e.deinit();

    try e.addFinding(.{ .source = "src/main.zig", .summary = "entry point" });
    try e.addFinding(.{ .source = "", .summary = "standalone note" });

    try std.testing.expectEqual(@as(usize, 2), e.getFindings().len);

    const sum = try e.summarize(arena);
    try std.testing.expect(std.mem.find(u8, sum, "entry point") != null);
    try std.testing.expect(std.mem.find(u8, sum, "(src/main.zig)") != null);
    try std.testing.expect(std.mem.find(u8, sum, "standalone note") != null);
    try std.testing.expect(std.mem.find(u8, sum, "()") == null);
}

test "empty engine summarizes to empty string" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var e = Engine.init(arena);
    defer e.deinit();

    const sum = try e.summarize(arena);
    try std.testing.expectEqualStrings("", sum);
}
