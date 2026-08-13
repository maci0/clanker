//! Global token usage statistics, recorded at the LLM client choke point and
//! aggregated per (provider, model).
//!
//! Every chat completion (agent runs, improve-engine proposals, ck_llm tool
//! calls, subagents) is appended to `<state_dir>/token_stats.jsonl`:
//!   {"ts":...,"provider":"kimi-k3","model":"kimi-k3","prompt_tokens":...,
//!    "completion_tokens":...,"total_tokens":...,"cache_hit":...,
//!    "cache_miss":...,"cost":0.001,"duration_ms":123}
//!
//! Aggregation groups the log by provider+model and produces one Stat per
//! group (plus a totals row), newest usage counted exactly once.

const std = @import("std");
const ensuredir = @import("../util/ensuredir.zig");
const filelock = @import("../util/filelock.zig");
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
    if (state_dir.len > 0) ensuredir.ensureDir(base, io, state_dir) catch |err| {
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
    var guard = filelock.acquire(io, base, lock_dir, "token_stats", arena);
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

/// Parses the whole log (arena-owned Records). Empty/missing log -> empty.
pub fn loadAll(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8) ![]Record {
    _ = gpa;
    const path = subPath(arena, state_dir) catch return &[_]Record{};
    const raw = base.readFileAlloc(io, path, arena, .limited(max_log_bytes)) catch return &[_]Record{};
    var out: std.ArrayList(Record) = .empty;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const rec = std.json.parseFromSliceLeaky(Record, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        try out.append(arena, rec);
    }
    return out.toOwnedSlice(arena);
}

/// Groups records by (provider, model), newest-first by total tokens.
pub fn aggregate(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8) ![]Stat {
    const recs = try loadAll(base, io, gpa, arena, state_dir);
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

    const t = totals(stats);
    try std.testing.expectEqual(@as(u64, 3), t.calls);
    try std.testing.expectEqual(@as(u64, 1400), t.total_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 0.03), t.cost, 0.0001);
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
    try std.testing.expectEqual(@as(i64, 2), parsed.object.get("totals").?.object.get("calls").?.integer);
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
