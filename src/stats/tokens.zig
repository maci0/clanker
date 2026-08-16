//! Global token usage statistics, recorded at the LLM client choke point and
//! aggregated per (provider, model).
//!
//! Every chat completion (agent runs, improve-engine proposals, ck_llm tool
//! calls, subagents) is appended to `<state_dir>/token_stats.jsonl`:
//!   {"ts":...,"provider":"kimi-k3","model":"kimi-k3","prompt_tokens":...,
//!    "completion_tokens":...,"total_tokens":...,"cache_hit":...,
//!    "cache_miss":...,"cost":0.001,"duration_ms":123,"ok":true,
//!    "http_status":200,"err":"","request_id":"http-3"}
//!
//! Aggregation groups the log by provider+model and produces one Stat per
//! group (plus a totals row), newest usage counted exactly once.

const std = @import("std");
const ensure_dir = @import("../util/ensure_dir.zig");
const file_lock = @import("../util/file_lock.zig");
const log = @import("../util/log.zig");
const atomic_write = @import("../util/atomic_write.zig");

pub const stat_path = "token_stats.jsonl";
/// Hard cap on the log so a busy harness cannot grow state without bound.
pub const max_log_bytes = 32 << 20;

pub const Record = struct {
    ts: i64,
    provider: []const u8,
    model: []const u8,
    prompt_tokens: u64,
    completion_tokens: u64,
    total_tokens: u64,
    cache_hit: u64,
    cache_miss: u64,
    cost: f64,
    duration_ms: u64,
    /// False when the completion never came back (transport, HTTP 4xx/5xx,
    /// parse). Defaults keep older log lines (successes only) readable.
    ok: bool = true,
    /// Provider HTTP status, 0 when the request never got a response.
    http_status: u16 = 0,
    /// Short error name or provider detail. Empty on success. Never a request
    /// body: those can echo prompts and credentials.
    err: []const u8 = "",
    /// Log correlation id when the call happened on an HTTP worker.
    request_id: []const u8 = "",
    /// Optional advisor-completion tokens for this turn. Omitted when unset.
    advisor_tokens: ?u64 = null,
    /// Classifier result from auto-thinking (`low`/`medium`/`high`/`xhigh`).
    thinking_level: ?[]const u8 = null,
    /// Round-trip ms of the thinking classifier call.
    thinking_classifier_ms: ?u64 = null,
};

/// Aggregated usage for one (provider, model) pair.
pub const Stat = struct {
    provider: []const u8,
    model: []const u8,
    calls: u64 = 0,
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    total_tokens: u64 = 0,
    cache_hit: u64 = 0,
    cache_miss: u64 = 0,
    cost: f64 = 0,
    duration_ms: u64 = 0,
    ok_calls: u64 = 0,
    error_calls: u64 = 0,
    thinking_low: u64 = 0,
    thinking_medium: u64 = 0,
    thinking_high: u64 = 0,
    thinking_xhigh: u64 = 0,

    pub fn thinkingTotal(self: *const Stat) u64 {
        return self.thinking_low + self.thinking_medium + self.thinking_high + self.thinking_xhigh;
    }

    pub fn errorRate(self: *const Stat) f64 {
        if (self.calls == 0) return 0;
        return @as(f64, @floatFromInt(self.error_calls)) / @as(f64, @floatFromInt(self.calls)) * 100.0;
    }

    pub fn cacheHitRate(self: *const Stat) f64 {
        const cached = self.cache_hit + self.cache_miss;
        if (cached == 0) return 0;
        return @as(f64, @floatFromInt(self.cache_hit)) / @as(f64, @floatFromInt(cached)) * 100.0;
    }

    pub fn tokensPerSec(self: *const Stat) f64 {
        if (self.duration_ms == 0) return 0;
        return @as(f64, @floatFromInt(self.total_tokens)) / (@as(f64, @floatFromInt(self.duration_ms)) / 1000.0);
    }
};

fn subPath(arena: std.mem.Allocator, state_dir: []const u8) ![]const u8 {
    if (state_dir.len == 0) return stat_path;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ state_dir, stat_path });
}

// ----------------------------------------------------------------- appending --

/// Appends one usage record. Best-effort: failures are logged, never fatal;
/// a stats write must not break a chat completion. O(1) append via a
/// truncate-free open + seek to end (the caller holds the only writer).
pub fn append(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, rec: Record) void {
    if (state_dir.len > 0) ensure_dir.ensureDir(base, io, state_dir) catch |err| {
        log.log(.warn, "[stats] mkdir failed: {s}", .{@errorName(err)});
        return;
    };
    const path = subPath(arena, state_dir) catch |err| {
        log.log(.warn, "[stats] path build failed: {s}", .{@errorName(err)});
        return;
    };

    // Keep trimming and appending in one critical section. Locking the data
    // file itself is insufficient because trimLog replaces its inode: a
    // waiter that already opened the old inode could append to an unlinked
    // file after the replacement and silently lose the record.
    const lock_dir = if (state_dir.len == 0) "." else state_dir;
    var guard = file_lock.acquire(io, base, lock_dir, "token_stats", arena);
    defer guard.release();

    // Trim the log when it outgrows the cap. Done before the file is opened
    // below because trimming atomically replaces it.
    if (base.statFile(io, path, .{})) |st| {
        if (st.size > max_log_bytes) trimLog(base, io, gpa, arena, path) catch {};
    } else |_| {}

    var line_buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&line_buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    s.write(rec) catch |err| {
        log.log(.warn, "[stats] encode failed: {s}", .{@errorName(err)});
        return;
    };
    const line = line_buf[0..w.end];

    // Several clanker processes write this file at once: an agent run, the
    // staged evals a promotion gate spawns, anything else driving the CLI. The
    // offset used to come from a stat taken before the file was even opened,
    // so two writers could read the same size and write to the same place,
    // and one record simply replaced the other. Nothing reported it: the file
    // stayed valid JSONL, just short.
    //
    // The lock makes the read-size-then-write pair atomic between cooperating
    // writers, and the size is taken from the locked handle rather than from
    // before it.
    const file = base.createFile(io, path, .{ .truncate = false, .lock = .exclusive }) catch |err| {
        log.log(.warn, "[stats] open failed: {s}", .{@errorName(err)});
        return;
    };
    defer file.close(io);
    const size = (file.stat(io) catch |err| {
        log.log(.warn, "[stats] stat failed: {s}", .{@errorName(err)});
        return;
    }).size;
    var wbuf: [512]u8 = undefined;
    var fw = file.writer(io, &wbuf);
    fw.seekToUnbuffered(size) catch |err| {
        log.log(.warn, "[stats] seek failed: {s}", .{@errorName(err)});
        return;
    };
    fw.interface.writeAll(line) catch |err| {
        log.log(.warn, "[stats] write failed: {s}", .{@errorName(err)});
        return;
    };
    fw.interface.writeAll("\n") catch |err| {
        log.log(.warn, "[stats] write failed: {s}", .{@errorName(err)});
        return;
    };
    fw.flush() catch |err| {
        log.log(.warn, "[stats] flush failed: {s}", .{@errorName(err)});
        return;
    };
}

/// Rewrites the log keeping only the newest lines (used when it hits the cap).
fn trimLog(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, path: []const u8) !void {
    _ = arena;
    const raw = try base.readFileAlloc(io, path, gpa, .limited(max_log_bytes + (1 << 16)));
    defer gpa.free(raw);
    // Keep the last 1000 lines.
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0) continue;
        try lines.append(gpa, ln);
    }
    const keep = if (lines.items.len > 1000) lines.items.len - 1000 else 0;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, raw.len);
    for (lines.items[keep..]) |ln| {
        try out.appendSlice(gpa, ln);
        try out.append(gpa, '\n');
    }
    try atomic_write.writeFile(io, base, path, out.items);
}

// -------------------------------------------------------------- aggregation --

/// Reads the whole log, skipping unparseable lines, as arena-owned Records.
/// Empty/missing log -> empty. Shared by `loadAll` and `aggregate` so the
/// read + line-split + parse loop cannot drift between them.
fn parseRecords(base: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]Record {
    var out: std.ArrayList(Record) = .empty;
    const raw = base.readFileAlloc(io, path, arena, .limited(max_log_bytes)) catch return &[_]Record{};
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const rec = std.json.parseFromSliceLeaky(Record, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        try out.append(arena, rec);
    }
    return out.toOwnedSlice(arena);
}

/// Parses the whole log (arena-owned Records). Empty/missing log -> empty.
pub fn loadAll(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8) ![]Record {
    _ = gpa;
    const path = subPath(arena, state_dir) catch return &[_]Record{};
    return parseRecords(base, io, arena, path);
}

/// Groups records by (provider, model), newest-first by total tokens.
pub fn aggregate(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8) ![]Stat {
    _ = gpa;
    const path = subPath(arena, state_dir) catch return &.{};
    const recs = try parseRecords(base, io, arena, path);
    var by_key: std.StringArrayHashMapUnmanaged(Stat) = .empty;
    for (recs) |r| {
        const key = std.fmt.allocPrint(arena, "{s}/{s}", .{ r.provider, r.model }) catch continue;
        const gop = try by_key.getOrPut(arena, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .provider = r.provider, .model = r.model };
        }
        gop.value_ptr.calls += 1;
        gop.value_ptr.prompt_tokens += r.prompt_tokens;
        gop.value_ptr.completion_tokens += r.completion_tokens;
        gop.value_ptr.total_tokens += r.total_tokens;
        gop.value_ptr.cache_hit += r.cache_hit;
        gop.value_ptr.cache_miss += r.cache_miss;
        gop.value_ptr.cost += r.cost;
        gop.value_ptr.duration_ms += r.duration_ms;
        if (r.ok) gop.value_ptr.ok_calls += 1 else gop.value_ptr.error_calls += 1;
        if (r.ok) if (r.thinking_level) |level| {
            if (std.mem.eql(u8, level, "low")) gop.value_ptr.thinking_low += 1;
            if (std.mem.eql(u8, level, "medium")) gop.value_ptr.thinking_medium += 1;
            if (std.mem.eql(u8, level, "high")) gop.value_ptr.thinking_high += 1;
            if (std.mem.eql(u8, level, "xhigh")) gop.value_ptr.thinking_xhigh += 1;
        };
    }
    const out = try arena.alloc(Stat, by_key.count());
    var idx: usize = 0;
    var it = by_key.iterator();
    while (it.next()) |kv| {
        out[idx] = kv.value_ptr.*;
        idx += 1;
    }
    std.mem.sort(Stat, out, {}, struct {
        fn lessThan(_: void, a: Stat, b: Stat) bool {
            return a.total_tokens > b.total_tokens;
        }
    }.lessThan);
    return out;
}

/// Sums a slice of stats into one totals row (empty provider/model).
pub fn totals(stats: []const Stat) Stat {
    var t = Stat{ .provider = "", .model = "" };
    for (stats) |s| {
        t.calls += s.calls;
        t.prompt_tokens += s.prompt_tokens;
        t.completion_tokens += s.completion_tokens;
        t.total_tokens += s.total_tokens;
        t.cache_hit += s.cache_hit;
        t.cache_miss += s.cache_miss;
        t.cost += s.cost;
        t.duration_ms += s.duration_ms;
        t.ok_calls += s.ok_calls;
        t.error_calls += s.error_calls;
        t.thinking_low += s.thinking_low;
        t.thinking_medium += s.thinking_medium;
        t.thinking_high += s.thinking_high;
        t.thinking_xhigh += s.thinking_xhigh;
    }
    return t;
}

/// Serializes {ok, stats, totals} for the ck_stats host fn and /api/stats.
pub fn statsJSON(arena: std.mem.Allocator, stats: []const Stat, total: Stat) ![]const u8 {
    var buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("stats");
    try s.beginArray();
    for (stats) |st| {
        try s.beginObject();
        try s.objectField("provider");
        try s.write(st.provider);
        try s.objectField("model");
        try s.write(st.model);
        try s.objectField("calls");
        try s.print("{d}", .{st.calls});
        try s.objectField("prompt_tokens");
        try s.print("{d}", .{st.prompt_tokens});
        try s.objectField("completion_tokens");
        try s.print("{d}", .{st.completion_tokens});
        try s.objectField("total_tokens");
        try s.print("{d}", .{st.total_tokens});
        try s.objectField("cache_hit");
        try s.print("{d}", .{st.cache_hit});
        try s.objectField("cache_miss");
        try s.print("{d}", .{st.cache_miss});
        try s.objectField("cache_hit_rate");
        try s.print("{d:.1}", .{st.cacheHitRate()});
        try s.objectField("tokens_per_sec");
        try s.print("{d:.1}", .{st.tokensPerSec()});
        try s.objectField("cost");
        try s.print("{d:.6}", .{st.cost});
        try s.objectField("duration_ms");
        try s.print("{d}", .{st.duration_ms});
        try s.objectField("ok_calls");
        try s.print("{d}", .{st.ok_calls});
        try s.objectField("error_calls");
        try s.print("{d}", .{st.error_calls});
        try s.objectField("error_rate");
        try s.print("{d:.1}", .{st.errorRate()});
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("totals");
    try s.beginObject();
    try s.objectField("calls");
    try s.print("{d}", .{total.calls});
    try s.objectField("prompt_tokens");
    try s.print("{d}", .{total.prompt_tokens});
    try s.objectField("completion_tokens");
    try s.print("{d}", .{total.completion_tokens});
    try s.objectField("total_tokens");
    try s.print("{d}", .{total.total_tokens});
    try s.objectField("cache_hit_rate");
    try s.print("{d:.1}", .{total.cacheHitRate()});
    try s.objectField("tokens_per_sec");
    try s.print("{d:.1}", .{total.tokensPerSec()});
    try s.objectField("cost");
    try s.print("{d:.6}", .{total.cost});
    try s.objectField("ok_calls");
    try s.print("{d}", .{total.ok_calls});
    try s.objectField("error_calls");
    try s.print("{d}", .{total.error_calls});
    try s.objectField("error_rate");
    try s.print("{d:.1}", .{total.errorRate()});
    try s.objectField("thinking_distribution");
    try s.beginObject();
    try s.objectField("low");
    try s.print("{d}", .{total.thinking_low});
    try s.objectField("medium");
    try s.print("{d}", .{total.thinking_medium});
    try s.objectField("high");
    try s.print("{d}", .{total.thinking_high});
    try s.objectField("xhigh");
    try s.print("{d}", .{total.thinking_xhigh});
    try s.endObject();
    try s.endObject();
    try s.endObject();
    return arena.dupe(u8, buf[0..w.end]);
}

// ------------------------------------------------------------------- tests --

test "append + aggregate groups by provider/model and sums" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const mk = struct {
        fn r(provider: []const u8, model: []const u8, prompt: u64, comp: u64, hit: u64, miss: u64) Record {
            return .{
                .ts = 1,
                .provider = provider,
                .model = model,
                .prompt_tokens = prompt,
                .completion_tokens = comp,
                .total_tokens = prompt + comp,
                .cache_hit = hit,
                .cache_miss = miss,
                .cost = 0.01,
                .duration_ms = 100,
            };
        }
    }.r;

    append(tmp.dir, io, std.testing.allocator, arena, "", mk("kimi-k3", "kimi-k3", 100, 20, 80, 20));
    append(tmp.dir, io, std.testing.allocator, arena, "", mk("kimi-k3", "kimi-k3", 200, 30, 200, 30));
    append(tmp.dir, io, std.testing.allocator, arena, "", mk("deepseek", "deepseek-v4-flash", 1000, 50, 900, 100));

    const stats = try aggregate(tmp.dir, io, std.testing.allocator, arena, "");
    try std.testing.expectEqual(@as(usize, 2), stats.len);
    // Sorted by total tokens desc: deepseek (1050) before kimi (350).
    try std.testing.expectEqualStrings("deepseek", stats[0].provider);
    try std.testing.expectEqual(@as(u64, 1), stats[0].calls);
    try std.testing.expectEqual(@as(u64, 1050), stats[0].total_tokens);
    try std.testing.expectEqual(@as(u64, 900), stats[0].cache_hit);
    try std.testing.expectEqual(@as(u64, 100), stats[0].cache_miss);
    try std.testing.expectEqual(@as(u64, 2), stats[1].calls);
    try std.testing.expectEqual(@as(u64, 350), stats[1].total_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 90.0), stats[0].cacheHitRate(), 0.01);
    try std.testing.expectEqual(@as(u64, 1), stats[0].ok_calls);
    try std.testing.expectEqual(@as(u64, 0), stats[0].error_calls);

    const t = totals(stats);
    try std.testing.expectEqual(@as(u64, 3), t.calls);
    try std.testing.expectEqual(@as(u64, 3), t.ok_calls);
    try std.testing.expectEqual(@as(u64, 0), t.error_calls);
    try std.testing.expectEqual(@as(u64, 1400), t.total_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 0.03), t.cost, 0.0001);
}

test "failed records count toward error_rate and older lines stay successes" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    append(tmp.dir, io, std.testing.allocator, arena, "", .{
        .ts = 1,
        .provider = "kimi-k3",
        .model = "kimi-k3",
        .prompt_tokens = 10,
        .completion_tokens = 2,
        .total_tokens = 12,
        .cache_hit = 0,
        .cache_miss = 10,
        .cost = 0,
        .duration_ms = 20,
    });
    append(tmp.dir, io, std.testing.allocator, arena, "", .{
        .ts = 2,
        .provider = "kimi-k3",
        .model = "kimi-k3",
        .prompt_tokens = 0,
        .completion_tokens = 0,
        .total_tokens = 0,
        .cache_hit = 0,
        .cache_miss = 0,
        .cost = 0,
        .duration_ms = 5,
        .ok = false,
        .http_status = 503,
        .err = "service_unavailable",
        .request_id = "http-9",
    });

    const stats = try aggregate(tmp.dir, io, std.testing.allocator, arena, "");
    try std.testing.expectEqual(@as(usize, 1), stats.len);
    try std.testing.expectEqual(@as(u64, 2), stats[0].calls);
    try std.testing.expectEqual(@as(u64, 1), stats[0].ok_calls);
    try std.testing.expectEqual(@as(u64, 1), stats[0].error_calls);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), stats[0].errorRate(), 0.01);

    // A pre-field line (no ok/err) must parse as a success so historical
    // logs do not suddenly look like a 100% error rate.
    const recs = try loadAll(tmp.dir, io, std.testing.allocator, arena, "");
    try std.testing.expect(recs[0].ok);
    try std.testing.expectEqual(@as(u16, 0), recs[0].http_status);
    try std.testing.expect(!recs[1].ok);
    try std.testing.expectEqual(@as(u16, 503), recs[1].http_status);
    try std.testing.expectEqualStrings("http-9", recs[1].request_id);

    const json_out = try statsJSON(arena, stats, totals(stats));
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, json_out, .{});
    try std.testing.expectEqual(@as(i64, 1), parsed.object.get("totals").?.object.get("error_calls").?.integer);
}

test "legacy token_stats lines without ok default to success" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const line =
        \\{"ts":1,"provider":"p","model":"m","prompt_tokens":1,"completion_tokens":1,"total_tokens":2,"cache_hit":0,"cache_miss":1,"cost":0.0,"duration_ms":1}
    ;
    const rec = try std.json.parseFromSliceLeaky(Record, arena, line, .{ .ignore_unknown_fields = true });
    try std.testing.expect(rec.ok);
    try std.testing.expectEqual(@as(u16, 0), rec.http_status);
    try std.testing.expectEqualStrings("", rec.err);
    try std.testing.expectEqualStrings("", rec.request_id);
}

test "statsJSON serializes stats + totals" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const stats = [_]Stat{.{ .provider = "kimi-k3", .model = "kimi-k3", .calls = 2, .total_tokens = 350, .cache_hit = 280, .cache_miss = 70 }};
    const json_out = try statsJSON(arena, &stats, totals(&stats));
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, json_out, .{});
    try std.testing.expect(parsed.object.get("ok").?.bool);
    try std.testing.expectEqual(@as(usize, 1), parsed.object.get("stats").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 350), parsed.object.get("stats").?.array.items[0].object.get("total_tokens").?.integer);
    const totals_obj = parsed.object.get("totals").?.object;
    try std.testing.expectEqual(@as(i64, 2), totals_obj.get("calls").?.integer);
    try std.testing.expectEqual(@as(i64, 350), totals_obj.get("total_tokens").?.integer);
    try std.testing.expect(totals_obj.get("cost") != null);
}

test "thinking metadata aggregates into CLI and API distributions" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for ([_][]const u8{ "low", "high", "high", "xhigh" }) |level| {
        append(tmp.dir, io, std.testing.allocator, arena, "", .{
            .ts = 1,
            .provider = "p",
            .model = "m",
            .prompt_tokens = 1,
            .completion_tokens = 1,
            .total_tokens = 2,
            .cache_hit = 0,
            .cache_miss = 1,
            .cost = 0,
            .duration_ms = 1,
            .thinking_level = level,
            .thinking_classifier_ms = 12,
        });
    }
    // Failed main calls do not skew the distribution of selected effort on
    // completed calls, even though their metadata remains useful in JSONL.
    append(tmp.dir, io, std.testing.allocator, arena, "", .{
        .ts = 2,
        .provider = "p",
        .model = "m",
        .prompt_tokens = 0,
        .completion_tokens = 0,
        .total_tokens = 0,
        .cache_hit = 0,
        .cache_miss = 0,
        .cost = 0,
        .duration_ms = 1,
        .ok = false,
        .thinking_level = "medium",
    });

    const stats = try aggregate(tmp.dir, io, std.testing.allocator, arena, "");
    const total = totals(stats);
    try std.testing.expectEqual(@as(u64, 1), total.thinking_low);
    try std.testing.expectEqual(@as(u64, 0), total.thinking_medium);
    try std.testing.expectEqual(@as(u64, 2), total.thinking_high);
    try std.testing.expectEqual(@as(u64, 1), total.thinking_xhigh);

    const table = try renderTable(arena, stats, total);
    try std.testing.expect(std.mem.find(u8, table, "thinking        low 1  medium 0  high 2  xhigh 1") != null);
    const json_out = try statsJSON(arena, stats, total);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, json_out, .{});
    const dist = parsed.object.get("totals").?.object.get("thinking_distribution").?.object;
    try std.testing.expectEqual(@as(i64, 2), dist.get("high").?.integer);
    try std.testing.expectEqual(@as(i64, 1), dist.get("xhigh").?.integer);
}

test "concurrent appends all survive" {
    // The offset used to come from a stat taken before the file was opened, so
    // two writers racing between the stat and the write landed on the same
    // offset and one record replaced the other. The file stayed valid JSONL,
    // just missing a line, which is why nothing ever noticed.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state");

    const writers = 8;
    const per_writer = 12;

    const Worker = struct {
        dir: std.Io.Dir,
        io: std.Io,
        gpa: std.mem.Allocator,
        id: u64,

        fn run(self: *@This()) void {
            var arena_state = std.heap.ArenaAllocator.init(self.gpa);
            defer arena_state.deinit();
            var i: u64 = 0;
            while (i < per_writer) : (i += 1) {
                append(self.dir, self.io, self.gpa, arena_state.allocator(), "state", .{
                    .ts = @intCast(self.id * 1000 + i),
                    .provider = "p",
                    .model = "m",
                    .prompt_tokens = 1,
                    .completion_tokens = 1,
                    .total_tokens = 2,
                    .cache_hit = 0,
                    .cache_miss = 1,
                    .cost = 0.0,
                    .duration_ms = 1,
                });
            }
        }
    };

    var workers: [writers]Worker = undefined;
    var threads: [writers]std.Thread = undefined;
    for (&workers, 0..) |*w, i| {
        w.* = .{ .dir = tmp.dir, .io = io, .gpa = std.testing.allocator, .id = i };
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{w});
    }
    for (&threads) |*t| t.join();

    const raw = try tmp.dir.readFileAlloc(io, "state/token_stats.jsonl", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(raw);

    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        // A lost record shows up as a short count; a half-overwritten one as a
        // line that no longer parses.
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        lines += 1;
    }
    try std.testing.expectEqual(@as(usize, writers * per_writer), lines);
}
