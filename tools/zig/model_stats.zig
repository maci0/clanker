//! model_stats: present global token usage per provider/model from the
//! harness's token-usage log (state/token_stats.jsonl). ck_stats only exposes
//! the authorized aggregate from the configured state directory (raw records
//! would overflow the 1 MiB guest arena). This guest owns text rendering;
//! JSON callers get the host aggregate as-is.

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const raw = lib.stats() catch |err| return lib.failErr(out, err, "reading token stats");
    const request = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    if (request.object.get("args") != null) {
        const result = std.json.parseFromSliceLeaky(Stats, lib.alloc, raw, .{ .ignore_unknown_fields = true }) catch |err|
            return lib.failErr(out, err, "parsing token stats");
        const text = renderText(result.stats, result.totals) catch |err| return lib.failErr(out, err, "rendering token stats");
        return lib.okText(out, text);
    }
    try out.writeAll(raw);
}

const Stat = struct {
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
};

const Stats = struct {
    stats: []const Stat = &.{},
    totals: Stat = .{},
};

fn renderText(stats: []const Stat, totals: Stat) ![]const u8 {
    if (stats.len == 0) return "no token usage recorded yet (run an agent task first)\n";

    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(lib.alloc, "provider        model                          calls  prompt  output   total  cache%  tok/s       cost$  fail\n");
    for (stats) |stat| try appendRow(&text, stat.provider, stat.model, stat);
    try appendRow(&text, "totals", "", totals);
    return text.toOwnedSlice(lib.alloc);
}

fn appendRow(text: *std.ArrayList(u8), provider: []const u8, model: []const u8, stat: Stat) !void {
    const prompt = try compactCount(stat.prompt_tokens);
    const completion = try compactCount(stat.completion_tokens);
    const total = try compactCount(stat.total_tokens);
    const line = try std.fmt.allocPrint(lib.alloc, "{s:<15} {s:<30}{d:>5} {s:>7} {s:>7} {s:>7} {d:>5.1} {d:>7.1} {d:>10.4} {d:>5}\n", .{
        provider,
        model,
        stat.calls,
        prompt,
        completion,
        total,
        stat.cache_hit_rate,
        stat.tokens_per_sec,
        stat.cost,
        stat.error_calls,
    });
    try text.appendSlice(lib.alloc, line);
}

/// Human tables optimize for comparison; the JSON path above preserves exact
/// counts for scripts. One decimal keeps nearby values distinct without making
/// eight-digit totals visually merge into the next column.
fn compactCount(value: u64) ![]const u8 {
    if (value < 1_000) return std.fmt.allocPrint(lib.alloc, "{d}", .{value});
    if (value < 1_000_000) return std.fmt.allocPrint(lib.alloc, "{d:.1}K", .{@as(f64, @floatFromInt(value)) / 1_000.0});
    if (value < 1_000_000_000) return std.fmt.allocPrint(lib.alloc, "{d:.1}M", .{@as(f64, @floatFromInt(value)) / 1_000_000.0});
    return std.fmt.allocPrint(lib.alloc, "{d:.1}B", .{@as(f64, @floatFromInt(value)) / 1_000_000_000.0});
}
