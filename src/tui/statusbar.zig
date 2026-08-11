//! One status line above the input box: model, session, token usage,
//! budget, current activity. Pure render function so it's testable at any
//! width without a terminal — the caller decides where it lands on screen.

const std = @import("std");
const width = @import("width.zig");
const theme_mod = @import("theme.zig");
const Theme = theme_mod.Theme;

pub const StatusModel = struct {
    model: []const u8,
    session_id: []const u8,
    total_tokens: u64,
    /// `cfg.agent.max_total_tokens`, if the session has one.
    budget: ?u64 = null,
    activity: []const u8 = "ready",
    /// Segments contributed by `statusline: true` WASM plugins, already
    /// joined by the caller. Appended verbatim after the built-in fields so
    /// a plugin's own styling (if any) survives.
    extra: []const u8 = "",
};

/// Renders one line, truncated to fit `cols`. Styling is applied after
/// truncation so the ANSI bytes never get measured as display width or cut
/// mid-escape.
pub fn render(arena: std.mem.Allocator, theme: *const Theme, cols: usize, model: StatusModel) ![]const u8 {
    const budget_part = if (model.budget) |b|
        try std.fmt.allocPrint(arena, "/{d}", .{b})
    else
        "";
    const extra_part = if (model.extra.len > 0)
        try std.fmt.allocPrint(arena, " \xc2\xb7 {s}", .{model.extra})
    else
        "";
    const plain = try std.fmt.allocPrint(arena, "{s} \xc2\xb7 {s} \xc2\xb7 {d}{s} tok \xc2\xb7 {s}{s}", .{
        model.model, model.session_id, model.total_tokens, budget_part, model.activity, extra_part,
    });
    const fitted = width.truncateToWidth(plain, cols);
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ theme.dim, fitted, theme.reset });
}

test "renders model, session, tokens and activity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const line = try render(arena_state.allocator(), &Theme.default, 80, .{
        .model = "kimi-k3",
        .session_id = "repl-1",
        .total_tokens = 1234,
        .activity = "thinking",
    });
    try std.testing.expect(std.mem.indexOf(u8, line, "kimi-k3") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "repl-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "thinking") != null);
}

test "includes budget when set, omits it when null" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const with_budget = try render(arena_state.allocator(), &Theme.default, 80, .{
        .model = "m",
        .session_id = "s",
        .total_tokens = 10,
        .budget = 1000,
    });
    try std.testing.expect(std.mem.indexOf(u8, with_budget, "10/1000") != null);

    const without = try render(arena_state.allocator(), &Theme.default, 80, .{
        .model = "m",
        .session_id = "s",
        .total_tokens = 10,
    });
    try std.testing.expect(std.mem.indexOf(u8, without, "/") == null);
}

test "extra segment from a statusline plugin is appended" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const line = try render(arena_state.allocator(), &Theme.default, 80, .{
        .model = "m",
        .session_id = "s",
        .total_tokens = 1,
        .extra = "battery 80%",
    });
    try std.testing.expect(std.mem.indexOf(u8, line, "battery 80%") != null);
}

test "truncates plain content to fit narrow widths without breaking ANSI" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const line = try render(arena_state.allocator(), &Theme.default, 5, .{
        .model = "a-very-long-model-name",
        .session_id = "s",
        .total_tokens = 1,
    });
    // Still wrapped in the dim/reset pair even when truncated to almost nothing.
    try std.testing.expect(std.mem.startsWith(u8, line, "\x1b[2m"));
    try std.testing.expect(std.mem.endsWith(u8, line, "\x1b[0m"));
}

test "mono theme emits no ANSI codes at all" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const line = try render(arena_state.allocator(), &Theme.mono, 80, .{
        .model = "m",
        .session_id = "s",
        .total_tokens = 1,
    });
    try std.testing.expect(std.mem.indexOf(u8, line, "\x1b") == null);
}
