//! model_stats: aggregate global token usage per provider/model from the
//! harness's token-usage log (state/token_stats.jsonl). ck_stats only exposes
//! the authorized records from the configured state directory. This guest
//! owns parsing, aggregation, derived metrics, JSON output, and text rendering.

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const raw = lib.stats() catch |err| return lib.failErr(out, err, "reading token stats");
    const records = std.json.parseFromSliceLeaky([]const Record, lib.alloc, raw, .{ .ignore_unknown_fields = true }) catch |err|
        return lib.failErr(out, err, "parsing token stats");
    const result = aggregate(records) catch |err| return lib.failErr(out, err, "aggregating token stats");
    const request = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    if (request.object.get("args") != null) {
        const text = renderText(result.stats, result.totals) catch |err| return lib.failErr(out, err, "rendering token stats");
        return lib.okText(out, text);
    }
    var writer = lib.writer(out);
    var s = lib.json(&writer);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("stats");
    try s.write(result.stats);
    try s.objectField("totals");
    try s.write(result.totals);
    try s.endObject();
    lib.commit(out, &writer);
}

const Record = struct {
    ts: i64 = 0,
    provider: []const u8 = "",
    model: []const u8 = "",
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    total_tokens: u64 = 0,
    cache_hit: u64 = 0,
    cache_miss: u64 = 0,
    cost: f64 = 0,
    duration_ms: u64 = 0,
    ok: bool = true,
    http_status: u16 = 0,
    err: []const u8 = "",
    request_id: []const u8 = "",
};

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

fn aggregate(records: []const Record) !Stats {
    const Acc = struct {
        stat: Stat,
        cache_hit: u64 = 0,
        cache_miss: u64 = 0,
        duration_ms: u64 = 0,
    };
    var by_key: std.StringArrayHashMapUnmanaged(Acc) = .empty;
    for (records) |record| {
        const key = try std.fmt.allocPrint(lib.alloc, "{s}/{s}", .{ record.provider, record.model });
        const gop = try by_key.getOrPut(lib.alloc, key);
        if (!gop.found_existing) gop.value_ptr.* = .{ .stat = .{ .provider = record.provider, .model = record.model } };
        const stat = &gop.value_ptr.stat;
        stat.calls += 1;
        stat.prompt_tokens += record.prompt_tokens;
        stat.completion_tokens += record.completion_tokens;
        stat.total_tokens += record.total_tokens;
        stat.cost += record.cost;
        if (record.ok) stat.ok_calls += 1 else stat.error_calls += 1;
        gop.value_ptr.cache_hit += record.cache_hit;
        gop.value_ptr.cache_miss += record.cache_miss;
        gop.value_ptr.duration_ms += record.duration_ms;
    }

    const stats = try lib.alloc.alloc(Stat, by_key.count());
    var index: usize = 0;
    var it = by_key.iterator();
    while (it.next()) |entry| {
        stats[index] = entry.value_ptr.stat;
        const cache_total = entry.value_ptr.cache_hit + entry.value_ptr.cache_miss;
        stats[index].cache_hit_rate = if (cache_total == 0) 0 else @as(f64, @floatFromInt(entry.value_ptr.cache_hit)) / @as(f64, @floatFromInt(cache_total)) * 100.0;
        stats[index].tokens_per_sec = if (entry.value_ptr.duration_ms == 0) 0 else @as(f64, @floatFromInt(stats[index].total_tokens)) / (@as(f64, @floatFromInt(entry.value_ptr.duration_ms)) / 1000.0);
        index += 1;
    }
    std.mem.sort(Stat, stats, {}, struct {
        fn lessThan(_: void, a: Stat, b: Stat) bool {
            return a.total_tokens > b.total_tokens;
        }
    }.lessThan);

    var totals: Stat = .{};
    var cache_hits: u64 = 0;
    var cache_misses: u64 = 0;
    var duration_ms: u64 = 0;
    for (records) |record| {
        cache_hits += record.cache_hit;
        cache_misses += record.cache_miss;
        duration_ms += record.duration_ms;
    }
    for (stats) |stat| {
        totals.calls += stat.calls;
        totals.prompt_tokens += stat.prompt_tokens;
        totals.completion_tokens += stat.completion_tokens;
        totals.total_tokens += stat.total_tokens;
        totals.cost += stat.cost;
        totals.ok_calls += stat.ok_calls;
        totals.error_calls += stat.error_calls;
    }
    const cache_total = cache_hits + cache_misses;
    totals.cache_hit_rate = if (cache_total == 0) 0 else @as(f64, @floatFromInt(cache_hits)) / @as(f64, @floatFromInt(cache_total)) * 100.0;
    totals.tokens_per_sec = if (duration_ms == 0) 0 else @as(f64, @floatFromInt(totals.total_tokens)) / (@as(f64, @floatFromInt(duration_ms)) / 1000.0);
    return .{ .stats = stats, .totals = totals };
}

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
