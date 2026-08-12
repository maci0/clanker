//! model_stats: aggregate global token usage per provider/model from the
//! harness's token-usage log (state/token_stats.jsonl). All aggregation is
//! host-side in ck_stats. Model calls receive the structured result unchanged;
//! the CLI requests a text table so presentation also has one implementation.

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const result = lib.stats() catch |err| return lib.failErr(out, err, "reading token stats");
    const request = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    if (request.object.get("args") != null) {
        const text = renderText(result) catch |err| return lib.failErr(out, err, "rendering token stats");
        return lib.okText(out, text);
    }
    try out.writeAll(result);
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
};

const Stats = struct {
    stats: []const Stat = &.{},
    totals: Stat = .{},
};

fn renderText(raw: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(Stats, lib.alloc, raw, .{ .ignore_unknown_fields = true });
    if (parsed.stats.len == 0) return "no token usage recorded yet (run an agent task first)\n";

    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(lib.alloc, "provider        model                          calls  prompt  output   total  cache%  tok/s       cost$\n");
    for (parsed.stats) |stat| try appendRow(&text, stat.provider, stat.model, stat);
    try appendRow(&text, "totals", "", parsed.totals);
    return text.toOwnedSlice(lib.alloc);
}

fn appendRow(text: *std.ArrayList(u8), provider: []const u8, model: []const u8, stat: Stat) !void {
    const prompt = try compactCount(stat.prompt_tokens);
    const completion = try compactCount(stat.completion_tokens);
    const total = try compactCount(stat.total_tokens);
    const line = try std.fmt.allocPrint(lib.alloc, "{s:<15} {s:<30}{d:>5} {s:>7} {s:>7} {s:>7} {d:>5.1} {d:>7.1} {d:>10.4}\n", .{
        provider,
        model,
        stat.calls,
        prompt,
        completion,
        total,
        stat.cache_hit_rate,
        stat.tokens_per_sec,
        stat.cost,
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
