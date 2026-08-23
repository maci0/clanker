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
const append_line = @import("../util/append_line.zig");
const file_lock = @import("../util/file_lock.zig");
const log = @import("../util/log.zig");
const atomic_write = @import("../util/atomic_write.zig");
const test_env = @import("../util/test_env.zig");

pub const stat_path = "token_stats.jsonl";
/// Hard cap on the log so a busy harness cannot grow state without bound.
pub const max_log_bytes = 32 << 20;
/// Headroom every reader must allow above the cap. The cap is enforced by the
/// *next* `append`, which trims only after seeing `size > max_log_bytes`, so a
/// log legitimately sits over the cap between the write that crossed it and the
/// write that trims it. A reader limited to exactly `max_log_bytes` fails on
/// that file, and both readers here answer a read failure with "no records",
/// which is indistinguishable from a fresh install.
pub const read_slack_bytes = 1 << 16;

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
        // Reported, not fatal: the append below still succeeds, but a trim that
        // keeps failing is the difference between a bounded log and one that
        // grows until the disk fills, and nothing else on this path would ever
        // say so. Every other failure here logs; this one used to be the
        // exception.
        if (st.size > max_log_bytes) trimLog(base, io, gpa, arena, path) catch |err|
            log.log(.warn, "[stats] trim of {s} failed ({d} bytes over cap): {s}", .{ path, st.size -| max_log_bytes, @errorName(err) });
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
    const file = base.createFile(io, path, .{ .truncate = false, .lock = .exclusive, .permissions = atomic_write.private_file }) catch |err| {
        log.log(.warn, "[stats] open failed: {s}", .{@errorName(err)});
        return;
    };
    defer file.close(io);
    append_line.appendLine(io, file, line) catch |err| {
        log.log(.warn, "[stats] append failed: {s}", .{@errorName(err)});
    };
}

/// Rewrites the log keeping only the newest lines (used when it hits the cap).
fn trimLog(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, path: []const u8) !void {
    _ = arena;
    const raw = try base.readFileAlloc(io, path, gpa, .limited(max_log_bytes + read_slack_bytes));
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
    try atomic_write.writeFilePerms(io, base, path, out.items, atomic_write.private_file);
}

// -------------------------------------------------------------- aggregation --

/// Reads the whole log, skipping unparseable lines, as arena-owned Records.
/// Empty/missing log -> empty. Shared by `loadAll` and `aggregate` so the
/// read + line-split + parse loop cannot drift between them.
fn parseRecords(base: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]Record {
    var out: std.ArrayList(Record) = .empty;
    const raw = base.readFileAlloc(io, path, arena, .limited(max_log_bytes + read_slack_bytes)) catch |err| {
        // Missing is the ordinary case (nothing has run yet) and stays quiet.
        // Anything else -- unreadable, or past the cap plus its slack -- would
        // otherwise report zero usage as if the harness had never run.
        if (err != error.FileNotFound) log.log(.warn, "[stats] read of {s} failed: {s}", .{ path, @errorName(err) });
        return &[_]Record{};
    };
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

/// One stat-validated cache entry for `aggregate`.
///
/// The log is capped at 32 MiB (~150k records), and every stats surface
/// (`clanker stats`, `/api/stats`, `ck_stats` from the model_stats guest)
/// lands here. Between appends the file is unchanged, so the second and later
/// calls re-read and re-parse up to 32 MiB for a handful of rows they already
/// produced. The cache is validated by the file's stat (inode + size + mtime):
/// appends change size, and a trim's atomic rename changes the inode, so a
/// stat match is a sound "nothing changed" answer. One entry, replaced (old
/// freed) on any change -- the same page-allocator-owned, stat-validated shape
/// as the wasm cache in src/sandbox/runtime.zig. The returned `[]Stat` is
/// process-stable, so callers must not free it (none do: ckStats consumes it
/// into a fresh arena immediately).
const AggregateCache = struct {
    const gpa = std.heap.page_allocator;

    const Entry = struct {
        path: []const u8,
        inode: u64,
        size: u64,
        mtime_ns: i96,
        stats: []Stat,
    };

    var mutex: std.atomic.Mutex = .unlocked;
    var entry: ?Entry = null;

    /// Spin on the raw mutex: the critical section is one stat-field compare,
    /// so a parked thread would cost more than it saves (same shape as the
    /// live bus's Spin in src/serve/live.zig).
    fn lock() void {
        while (!mutex.tryLock()) std.Thread.yield() catch {};
    }

    fn get(path: []const u8, st: FileStat) ?[]Stat {
        lock();
        defer mutex.unlock();
        const e = entry orelse return null;
        if (e.inode != @as(u64, @intCast(st.inode))) return null;
        if (e.size != st.size) return null;
        if (e.mtime_ns != st.mtime.nanoseconds) return null;
        if (!std.mem.eql(u8, e.path, path)) return null;
        return e.stats;
    }

    /// Stores `stats` for `(path, st)` and returns the slice callers may hand
    /// out. When an entry for the same version is already present, the first
    /// store wins and this call's freshly computed copy -- which nothing else
    /// holds -- is freed instead. Two threads can miss on the same file version
    /// at once (both fold before either stores), and the second store used to
    /// replace and free the first's stats while the first's caller was still
    /// reading them. A different version replaces the old entry as before, and
    /// an allocation failure leaves the cache empty with the caller owning what
    /// it computed.
    fn store(path: []const u8, st: FileStat, stats: []Stat) []Stat {
        lock();
        defer mutex.unlock();
        if (entry) |old| {
            const same_version = old.inode == @as(u64, @intCast(st.inode)) and
                old.size == st.size and
                old.mtime_ns == st.mtime.nanoseconds and
                std.mem.eql(u8, old.path, path);
            if (same_version) {
                freeStats(stats);
                return old.stats;
            }
            freeEntry(old);
        }
        const owned_path = gpa.dupe(u8, path) catch {
            return stats;
        };
        entry = .{
            .path = owned_path,
            .inode = @as(u64, @intCast(st.inode)),
            .size = st.size,
            .mtime_ns = st.mtime.nanoseconds,
            .stats = stats,
        };
        return stats;
    }

    fn freeStats(stats: []Stat) void {
        for (stats) |s| {
            gpa.free(s.provider);
            gpa.free(s.model);
        }
        gpa.free(stats);
    }

    fn freeEntry(e: Entry) void {
        freeStats(e.stats);
        gpa.free(e.path);
    }
};

const FileStat = std.Io.File.Stat;

/// Groups records by (provider, model), newest-first by total tokens.
///
/// The result is cache-owned (see `AggregateCache`): page_allocator memory
/// that is valid for the life of the process and replaced only when the log
/// changes. Folding the log line by line rather than through `parseRecords`
/// keeps the per-line parse in a scratch arena that resets immediately; only
/// a group's first sighting copies its names into the cache allocator.
pub fn aggregate(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8) ![]Stat {
    const path = subPath(arena, state_dir) catch return &.{};
    const st = base.statFile(io, path, .{}) catch |err| {
        // Missing is the ordinary case (nothing has run yet) and stays quiet.
        // Anything else -- unreadable, or past the cap plus its slack -- would
        // otherwise report zero usage as if the harness had never run.
        if (err != error.FileNotFound) log.log(.warn, "[stats] read of {s} failed: {s}", .{ path, @errorName(err) });
        return &.{};
    };
    if (AggregateCache.get(path, st)) |cached| return cached;
    const stats = try aggregateFold(base, io, gpa, path);
    return AggregateCache.store(path, st, stats);
}

/// The read + fold half of `aggregate`, allocating the group rows from the
/// cache's allocator so the public function can hand back process-stable
/// memory. Never caches a failed read: the caller stores only on success.
/// The map-key dupes are not reclaimed on cache replacement (bounded: a few
/// dozen short strings per log change, like the wasm cache's documented
/// superseded-generation leak); the row names in `out` are freed by
/// `AggregateCache.store`.
fn aggregateFold(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]Stat {
    const raw = base.readFileAlloc(io, path, gpa, .limited(max_log_bytes + read_slack_bytes)) catch |err| {
        if (err != error.FileNotFound) log.log(.warn, "[stats] read of {s} failed: {s}", .{ path, @errorName(err) });
        return &.{};
    };
    defer gpa.free(raw);

    const alloc = AggregateCache.gpa;

    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var by_key: std.array_hash_map.String(Stat) = .empty;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        defer _ = scratch_state.reset(.retain_capacity);
        const r = std.json.parseFromSliceLeaky(Record, scratch, line, .{ .ignore_unknown_fields = true }) catch continue;
        const key = std.fmt.allocPrint(scratch, "{s}/{s}", .{ r.provider, r.model }) catch continue;
        const gop = try by_key.getOrPut(alloc, key);
        if (!gop.found_existing) {
            // The key and both names live in `scratch`, which is about to be
            // reset; a group survives the loop, so it owns copies in the
            // cache allocator (freed when the cache entry is replaced).
            gop.key_ptr.* = try alloc.dupe(u8, key);
            gop.value_ptr.* = .{
                .provider = try alloc.dupe(u8, r.provider),
                .model = try alloc.dupe(u8, r.model),
            };
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
    const out = try alloc.alloc(Stat, by_key.count());
    var idx: usize = 0;
    var it = by_key.iterator();
    while (it.next()) |kv| {
        out[idx] = kv.value_ptr.*;
        idx += 1;
    }
    by_key.deinit(alloc);
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
///
/// The body grows to fit. It used to be built in a fixed 64 KiB buffer, which
/// is a ceiling on a list with no bound: one row per (provider, model) pair
/// ever recorded, at roughly 400 bytes each. Past ~150 pairs -- an OpenRouter
/// or `clanker compare` user reaches that without trying -- the write failed
/// and `ck_stats` answered `too_large`, so the whole stats surface went from
/// working to erroring on a threshold nothing announced.
pub fn statsJSON(arena: std.mem.Allocator, stats: []const Stat, total: Stat) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
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
    return out.toOwnedSlice();
}

// ------------------------------------------------------------------- tests --

test "append + aggregate groups by provider/model and sums" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

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

    append(env.tmp.dir, io, std.testing.allocator, arena, "", mk("kimi-k3", "kimi-k3", 100, 20, 80, 20));
    append(env.tmp.dir, io, std.testing.allocator, arena, "", mk("kimi-k3", "kimi-k3", 200, 30, 200, 30));
    append(env.tmp.dir, io, std.testing.allocator, arena, "", mk("deepseek", "deepseek-v4-flash", 1000, 50, 900, 100));

    const stats = try aggregate(env.tmp.dir, io, std.testing.allocator, arena, "");
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
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    append(env.tmp.dir, io, std.testing.allocator, arena, "", .{
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
    append(env.tmp.dir, io, std.testing.allocator, arena, "", .{
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

    const stats = try aggregate(env.tmp.dir, io, std.testing.allocator, arena, "");
    try std.testing.expectEqual(@as(usize, 1), stats.len);
    try std.testing.expectEqual(@as(u64, 2), stats[0].calls);
    try std.testing.expectEqual(@as(u64, 1), stats[0].ok_calls);
    try std.testing.expectEqual(@as(u64, 1), stats[0].error_calls);
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), stats[0].errorRate(), 0.01);

    // A pre-field line (no ok/err) must parse as a success so historical
    // logs do not suddenly look like a 100% error rate.
    const recs = try loadAll(env.tmp.dir, io, std.testing.allocator, arena, "");
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

test "statsJSON serializes more pairs than a fixed buffer held" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // One row per (provider, model) pair ever recorded, and nothing bounds how
    // many of those a harness accumulates. At ~400 bytes a row the old 64 KiB
    // buffer ran out around 150, and `ck_stats` turned that into `too_large`.
    const pairs = 600;
    const stats = try arena.alloc(Stat, pairs);
    for (stats, 0..) |*st, i| {
        st.* = .{
            .provider = try std.fmt.allocPrint(arena, "openrouter-{d}", .{i}),
            .model = try std.fmt.allocPrint(arena, "vendor/some-fairly-long-model-name-{d}", .{i}),
            .calls = 1,
            .total_tokens = 2,
            .ok_calls = 1,
        };
    }

    const json_out = try statsJSON(arena, stats, totals(stats));
    try std.testing.expect(json_out.len > 64 * 1024);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, json_out, .{});
    try std.testing.expectEqual(@as(usize, pairs), parsed.object.get("stats").?.array.items.len);
    try std.testing.expectEqual(@as(i64, pairs), parsed.object.get("totals").?.object.get("calls").?.integer);
}

test "an over-cap log still aggregates instead of reporting no usage" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    // `append` trims only on the write *after* the cap is crossed, so a log
    // sitting just over it is a state the writer produces on purpose. A reader
    // limited to exactly the cap failed here and answered "no records", which
    // reads as a fresh install rather than as a read that did not happen.
    const line =
        \\{"ts":1,"provider":"p","model":"m","prompt_tokens":1,"completion_tokens":1,"total_tokens":2,"cache_hit":0,"cache_miss":1,"cost":0.0,"duration_ms":1}
    ;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    while (body.items.len <= max_log_bytes) {
        try body.appendSlice(std.testing.allocator, line);
        try body.append(std.testing.allocator, '\n');
    }
    try env.tmp.dir.writeFile(io, .{ .sub_path = stat_path, .data = body.items });

    const stats = try aggregate(env.tmp.dir, io, std.testing.allocator, arena, "");
    try std.testing.expectEqual(@as(usize, 1), stats.len);
    try std.testing.expect(stats[0].calls > 0);
    try std.testing.expectEqual(stats[0].calls * 2, stats[0].total_tokens);
}

test "thinking metadata aggregates into CLI and API distributions" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    for ([_][]const u8{ "low", "high", "high", "xhigh" }) |level| {
        append(env.tmp.dir, io, std.testing.allocator, arena, "", .{
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
    append(env.tmp.dir, io, std.testing.allocator, arena, "", .{
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

    const stats = try aggregate(env.tmp.dir, io, std.testing.allocator, arena, "");
    const total = totals(stats);
    try std.testing.expectEqual(@as(u64, 1), total.thinking_low);
    try std.testing.expectEqual(@as(u64, 0), total.thinking_medium);
    try std.testing.expectEqual(@as(u64, 2), total.thinking_high);
    try std.testing.expectEqual(@as(u64, 1), total.thinking_xhigh);

    // The table rendering of the distribution lives in the model_stats guest
    // (tools/zig/model_stats_logic.zig, host-tested); the host surface of the
    // distribution is the totals row and the statsJSON serialization below.
    const json_out = try statsJSON(arena, stats, total);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, json_out, .{});
    const dist = parsed.object.get("totals").?.object.get("thinking_distribution").?.object;
    try std.testing.expectEqual(@as(i64, 2), dist.get("high").?.integer);
    try std.testing.expectEqual(@as(i64, 1), dist.get("xhigh").?.integer);
}

test "an unchanged log aggregates from cache; an append invalidates it" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    append(env.tmp.dir, io, std.testing.allocator, arena, "", .{
        .ts = 1,
        .provider = "kimi-k3",
        .model = "kimi-k3",
        .prompt_tokens = 100,
        .completion_tokens = 20,
        .total_tokens = 120,
        .cache_hit = 80,
        .cache_miss = 20,
        .cost = 0.01,
        .duration_ms = 100,
    });

    // A repeat read of an unchanged log returns the same cache entry, not a
    // freshly parsed one (same pointer: the log was not re-read).
    const first = try aggregate(env.tmp.dir, io, std.testing.allocator, arena, "");
    try std.testing.expectEqual(@as(u64, 1), first[0].calls);
    const second = try aggregate(env.tmp.dir, io, std.testing.allocator, arena, "");
    try std.testing.expect(first.ptr == second.ptr);

    // An append changes the file's size, so the next aggregate must see it.
    append(env.tmp.dir, io, std.testing.allocator, arena, "", .{
        .ts = 2,
        .provider = "kimi-k3",
        .model = "kimi-k3",
        .prompt_tokens = 200,
        .completion_tokens = 30,
        .total_tokens = 230,
        .cache_hit = 200,
        .cache_miss = 30,
        .cost = 0.02,
        .duration_ms = 90,
    });
    const third = try aggregate(env.tmp.dir, io, std.testing.allocator, arena, "");
    try std.testing.expectEqual(@as(u64, 2), third[0].calls);
    try std.testing.expectEqual(@as(u64, 300), third[0].prompt_tokens);
    try std.testing.expectEqual(@as(u64, 350), third[0].total_tokens);
}

test "a store for a version already cached keeps the first entry" {
    // Deterministic half of the concurrent-miss race: two calls that miss on
    // the same file version both fold and both store, and the loser must free
    // only its own copy -- the second store used to replace and free the
    // first's stats while its caller was still reading them.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "log", .data = "" });
    const st = try tmp.dir.statFile(io, "log", .{});

    const gpa = AggregateCache.gpa;
    const a = try gpa.alloc(Stat, 1);
    a[0] = .{ .provider = try gpa.dupe(u8, "p-a"), .model = try gpa.dupe(u8, "m-a") };
    try std.testing.expect((AggregateCache.store("log", st, a)).ptr == a.ptr);

    // Same path and version: the first entry wins; this copy is freed.
    const b = try gpa.alloc(Stat, 1);
    b[0] = .{ .provider = try gpa.dupe(u8, "p-b"), .model = try gpa.dupe(u8, "m-b") };
    const stored_b = AggregateCache.store("log", st, b);
    try std.testing.expect(stored_b.ptr == a.ptr);
    try std.testing.expect(stored_b.ptr != b.ptr);

    // Same version, different path: a different entry, so this replaces.
    const c = try gpa.alloc(Stat, 1);
    c[0] = .{ .provider = try gpa.dupe(u8, "p-c"), .model = try gpa.dupe(u8, "m-c") };
    const stored_c = AggregateCache.store("other", st, c);
    try std.testing.expect(stored_c.ptr == c.ptr);

    // Different version (mtime moved): replaces the old entry.
    var st2 = st;
    st2.mtime.nanoseconds += 1;
    const d = try gpa.alloc(Stat, 1);
    d[0] = .{ .provider = try gpa.dupe(u8, "p-d"), .model = try gpa.dupe(u8, "m-d") };
    const stored_d = AggregateCache.store("log", st2, d);
    try std.testing.expect(stored_d.ptr == d.ptr);
}

test "concurrent aggregates on one log version share one cache entry" {
    // The real race: every reader misses together (the log is unchanged
    // between their stat and their fold), so each folds and each stores. All
    // must come back holding the same live slice -- with the old store, a
    // later store freed an earlier reader's stats while it was still reading
    // them.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state");
    var seed_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer seed_arena.deinit();
    append(tmp.dir, io, std.testing.allocator, seed_arena.allocator(), "state", .{
        .ts = 1,
        .provider = "kimi-k3",
        .model = "kimi-k3",
        .prompt_tokens = 100,
        .completion_tokens = 20,
        .total_tokens = 120,
        .cache_hit = 80,
        .cache_miss = 20,
        .cost = 0.01,
        .duration_ms = 100,
    });

    const readers = 8;
    const Worker = struct {
        dir: std.Io.Dir,
        io: std.Io,
        gpa: std.mem.Allocator,
        result: ?[]Stat = null,

        fn run(self: *@This()) void {
            var arena_state = std.heap.ArenaAllocator.init(self.gpa);
            defer arena_state.deinit();
            self.result = aggregate(self.dir, self.io, self.gpa, arena_state.allocator(), "state") catch null;
        }
    };

    var workers: [readers]Worker = undefined;
    var threads: [readers]std.Thread = undefined;
    for (&workers, 0..) |*w, i| {
        w.* = .{ .dir = tmp.dir, .io = io, .gpa = std.testing.allocator };
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{w});
    }
    for (&threads) |*t| t.join();

    // Every reader must hold the same live slice (the first store won) and
    // each must still be readable -- the use-after-free that used to happen
    // when a later store freed an earlier reader's stats.
    var first: ?[*]Stat = null;
    for (&workers) |*w| {
        const r = w.result orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 1), r.len);
        try std.testing.expectEqualStrings("kimi-k3", r[0].provider);
        if (first) |fp| {
            try std.testing.expect(fp == r.ptr);
        } else {
            first = r.ptr;
        }
    }
}

test "concurrent appends all survive" { // The offset used to come from a stat taken before the file was opened, so
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
