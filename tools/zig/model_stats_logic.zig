//! The model_stats text renderer, shared by the model_stats WASM guest and
//! the host tests. Kept pure (no guest ABI, allocator passed in) so `zig
//! build test` runs its `test` blocks: the guest `tools/zig/model_stats.zig`
//! imports this and hands it `lib.alloc`, exactly like advisor_logic /
//! thinking_logic / graph_listing.
//!
//! The table shape here is the single implementation of what `clanker stats`
//! and `/api/stats` render. It used to live twice: natively in
//! `src/stats/tokens.zig`'s renderTable (CLI) and in the guest (web), and the
//! two drifted: the guest dropped the thinking breakdown and used a wider
//! cost column. A guest cannot import src/, so the renderer now lives here
//! and both surfaces go through the guest.

const std = @import("std");

/// Thinking-effort distribution of a totals row. Serialized by the host's
/// ck_stats as `totals.thinking_distribution`; present (all zeros) even when
/// no call used thinking, so the row format never depends on optionality.
pub const Thinking = struct {
    low: u64 = 0,
    medium: u64 = 0,
    high: u64 = 0,
    xhigh: u64 = 0,

    pub fn total(self: *const Thinking) u64 {
        return self.low + self.medium + self.high + self.xhigh;
    }
};

/// One provider/model row, in the shape ck_stats emits: the host precomputes
/// cache_hit_rate and tokens_per_sec (and the 6-decimal cost), so this struct
/// carries those values instead of recomputing them from raw counters.
pub const Stat = struct {
    provider: []const u8 = "",
    model: []const u8 = "",
    calls: u64 = 0,
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    total_tokens: u64 = 0,
    cache_hit_rate: f64 = 0,
    tokens_per_sec: f64 = 0,
    cost: f64 = 0,
    ok_calls: u64 = 0,
    error_calls: u64 = 0,
    /// Totals row only; per-row rows never carry it. Parsed from the nested
    /// `totals.thinking_distribution` object, zero elsewhere.
    thinking_distribution: Thinking = .{},
};

pub const Stats = struct {
    stats: []const Stat = &.{},
    totals: Stat = .{},
};

/// Human-readable table for `clanker stats` (via the guest) and any other
/// renderer. Column widths are load-bearing: the table is documented as
/// pipe-safe and awk-parseable, so a row's fields must land in the same
/// columns the header names.
pub fn renderText(alloc: std.mem.Allocator, stats: []const Stat, totals: Stat) ![]const u8 {
    if (stats.len == 0) return "no token usage recorded yet (run an agent task first)\n";

    // The table is read by comparing figures down the numeric columns, so
    // those columns must line up row to row. A provider or model name longer
    // than the default column width widens that column for the whole table
    // instead of shoving one row's numbers out of line with the rest.
    var provider_w: usize = 15;
    var model_w: usize = 30;
    for (stats) |stat| {
        provider_w = @max(provider_w, stat.provider.len);
        model_w = @max(model_w, stat.model.len);
    }

    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(alloc, try padRight(alloc, "provider", provider_w));
    try text.appendSlice(alloc, " ");
    try text.appendSlice(alloc, try padRight(alloc, "model", model_w));
    try text.appendSlice(alloc, "calls  prompt  output   total  cache%  tok/s     cost$  fail\n");
    for (stats) |stat| try appendRow(alloc, &text, provider_w, model_w, stat.provider, stat.model, stat);
    try appendRow(alloc, &text, provider_w, model_w, "totals", "", totals);
    if (totals.thinking_distribution.total() > 0) {
        try text.print(alloc, "thinking        low {d}  medium {d}  high {d}  xhigh {d}\n", .{
            totals.thinking_distribution.low,
            totals.thinking_distribution.medium,
            totals.thinking_distribution.high,
            totals.thinking_distribution.xhigh,
        });
    }
    return text.toOwnedSlice(alloc);
}

fn appendRow(
    alloc: std.mem.Allocator,
    text: *std.ArrayList(u8),
    provider_w: usize,
    model_w: usize,
    provider: []const u8,
    model: []const u8,
    stat: Stat,
) !void {
    const prompt = try compactCount(alloc, stat.prompt_tokens);
    const completion = try compactCount(alloc, stat.completion_tokens);
    const total = try compactCount(alloc, stat.total_tokens);
    // Cells are pre-padded so the numeric columns stay put no matter how
    // wide a provider or model name grows the leading columns.
    const line = try std.fmt.allocPrint(alloc, "{s} {s}{d:>5} {s:>7} {s:>7} {s:>7} {d:>5.1} {d:>7.1} {d:>8.2} {d:>5}\n", .{
        try padRight(alloc, provider, provider_w),
        try padRight(alloc, model, model_w),
        stat.calls,
        prompt,
        completion,
        total,
        stat.cache_hit_rate,
        stat.tokens_per_sec,
        stat.cost,
        stat.error_calls,
    });
    try text.appendSlice(alloc, line);
}

/// Right-pad `s` to at least `width` cells. Returns the input slice when it
/// already fills the column, so no allocation happens in the common case.
fn padRight(alloc: std.mem.Allocator, s: []const u8, width: usize) ![]const u8 {
    if (s.len >= width) return s;
    return std.fmt.allocPrint(alloc, "{s: <[1]}", .{ s, width });
}

/// Human tables optimize for comparison; the JSON path above preserves exact
/// counts for scripts. One decimal keeps nearby values distinct without making
/// eight-digit totals visually merge into the next column.
fn compactCount(alloc: std.mem.Allocator, value: u64) ![]const u8 {
    if (value < 1_000) return std.fmt.allocPrint(alloc, "{d}", .{value});
    if (value < 1_000_000) return std.fmt.allocPrint(alloc, "{d:.1}K", .{@as(f64, @floatFromInt(value)) / 1_000.0});
    if (value < 1_000_000_000) return std.fmt.allocPrint(alloc, "{d:.1}M", .{@as(f64, @floatFromInt(value)) / 1_000_000.0});
    return std.fmt.allocPrint(alloc, "{d:.1}B", .{@as(f64, @floatFromInt(value)) / 1_000_000_000.0});
}

// ------------------------------------------------------------------- tests --

test "empty stats name the empty case" {
    // The empty case returns a string literal, not an allocation, so it is
    // asserted but never freed.
    const got = try renderText(std.testing.allocator, &.{}, .{});
    try std.testing.expectEqualStrings("no token usage recorded yet (run an agent task first)\n", got);
}

test "columns stay aligned and the thinking breakdown renders from the totals" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = [_]Stat{
        .{
            .provider = "kimi-k3",
            .model = "kimi-k3",
            .calls = 2,
            .prompt_tokens = 300,
            .completion_tokens = 50,
            .total_tokens = 350,
            .cache_hit_rate = 93.3,
            .tokens_per_sec = 1750.0,
            .cost = 0.02,
            .ok_calls = 2,
        },
        // A provider name longer than the default column width must widen
        // the table, not shove this row's figures out of line (the numbers
        // column is the comparison surface).
        .{
            .provider = "google-vertex-anthropic",
            .model = "claude-opus-5@default",
            .calls = 29,
            .prompt_tokens = 0,
            .completion_tokens = 0,
            .total_tokens = 0,
            .error_calls = 29,
        },
    };
    var totals = Stat{};
    totals.calls = 31;
    totals.prompt_tokens = 300;
    totals.completion_tokens = 50;
    totals.total_tokens = 350;
    totals.cost = 0.02;
    totals.error_calls = 29;
    totals.thinking_distribution = .{ .low = 1, .high = 2, .xhigh = 1 };

    const text = try renderText(arena, &rows, totals);
    // The header widens with the table. `google-vertex-anthropic` is longer
    // than the default provider column, so pinning the exact spacing here
    // would assert the width this very fixture is meant to widen; what has to
    // hold is that the header leads with the two name columns and ends with
    // the numeric titles.
    const header = text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len];
    try std.testing.expect(std.mem.startsWith(u8, header, "provider "));
    try std.testing.expect(std.mem.find(u8, header, " model ") != null);
    try std.testing.expect(std.mem.endsWith(u8, header, "calls  prompt  output   total  cache%  tok/s     cost$  fail"));
    try std.testing.expect(std.mem.find(u8, text, "kimi-k3") != null);
    try std.testing.expect(std.mem.find(u8, text, "totals") != null);
    try std.testing.expect(std.mem.find(u8, text, "thinking        low 1  medium 0  high 2  xhigh 1") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "\n"));

    // The cost column is right-aligned to width 8 with two decimals, so a
    // totals row aligns with a per-provider row.
    try std.testing.expect(std.mem.find(u8, text, "    0.02") != null);

    // Every row's numeric columns start at the same offset, including the
    // row whose provider name exceeds the default column width.
    var it = std.mem.splitScalar(u8, text, '\n');
    var offset: ?usize = null;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const calls_at = std.mem.indexOf(u8, line, " 29 ") orelse
            std.mem.indexOf(u8, line, " 31 ") orelse
            std.mem.indexOf(u8, line, "    0.02") orelse continue;
        if (offset) |o| {
            try std.testing.expectEqual(o, calls_at);
        } else {
            offset = calls_at;
        }
    }
}

test "compactCount keeps small numbers exact and shortens the rest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("0", try compactCount(arena, 0));
    try std.testing.expectEqualStrings("999", try compactCount(arena, 999));
    try std.testing.expectEqualStrings("1.0K", try compactCount(arena, 1000));
    try std.testing.expectEqualStrings("12.3K", try compactCount(arena, 12345));
    try std.testing.expectEqualStrings("1.0M", try compactCount(arena, 1_000_000));
    try std.testing.expectEqualStrings("1.5B", try compactCount(arena, 1_500_000_000));
}

test "thinking distribution totals across all buckets" {
    const t = Thinking{ .low = 1, .medium = 2, .high = 3, .xhigh = 4 };
    try std.testing.expectEqual(@as(u64, 10), t.total());
    try std.testing.expectEqual(@as(u64, 0), (Thinking{}).total());
}
