//! In-process request-per-minute limiter.
//!
//! Config names a cap (`rpm` on a model or a provider). This module waits
//! until the sliding 60s window has a free slot, then records the send.
//! No subprocess, no external token bucket: one mutex and a stamp list
//! per key. Two threads on the same key serialize; different keys do not
//! block each other except for the lock hold around the prune/record.

const std = @import("std");
const config = @import("../config.zig");
const log = @import("../util/log.zig");

pub const window_ns: i64 = 60 * std.time.ns_per_s;

var mutex: std.Io.Mutex = .init;
var buckets: std.StringArrayHashMapUnmanaged(std.ArrayList(i64)) = .empty;

/// How long to sleep before the next send is allowed. `0` means go now.
/// `stamps` is oldest-first and may still contain entries older than the
/// window; those are ignored, not required to be pruned first.
pub fn waitNs(now_ns: i64, stamps: []const i64, rpm: u32) u64 {
    if (rpm == 0) return 0;
    const cutoff = now_ns - window_ns;
    var first: usize = 0;
    while (first < stamps.len and stamps[first] < cutoff) first += 1;
    const live = stamps[first..];
    if (live.len < rpm) return 0;
    const ready = live[0] + window_ns;
    if (ready <= now_ns) return 0;
    return @intCast(ready - now_ns);
}

fn nowNs(io: std.Io) i64 {
    return @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
}

fn waitKey(io: std.Io, gpa: std.mem.Allocator, key: []const u8, rpm: u32) !void {
    if (rpm == 0) return;
    while (true) {
        mutex.lockUncancelable(io);
        const now = nowNs(io);
        const gop = buckets.getOrPut(gpa, key) catch |err| {
            mutex.unlock(io);
            return err;
        };
        if (!gop.found_existing) {
            gop.key_ptr.* = gpa.dupe(u8, key) catch |err| {
                _ = buckets.swapRemove(key);
                mutex.unlock(io);
                return err;
            };
            gop.value_ptr.* = .empty;
        }
        var list = gop.value_ptr;
        const cutoff = now - window_ns;
        var keep: usize = 0;
        while (keep < list.items.len and list.items[keep] < cutoff) keep += 1;
        if (keep > 0) {
            const rest = list.items.len - keep;
            std.mem.copyForwards(i64, list.items[0..rest], list.items[keep..]);
            list.shrinkRetainingCapacity(rest);
        }
        const delay = waitNs(now, list.items, rpm);
        if (delay == 0) {
            list.append(gpa, now) catch |err| {
                mutex.unlock(io);
                return err;
            };
            mutex.unlock(io);
            return;
        }
        mutex.unlock(io);
        log.log(.debug, "rate limit {s}: waiting {d}ms (rpm {d})", .{
            key, delay / std.time.ns_per_ms, rpm,
        });
        try std.Io.sleep(io, .{ .nanoseconds = delay }, .awake);
    }
}

/// The model bucket's key: provider plus the WIRE SKU, not the local table
/// name, so every alias of one SKU (`grok4.6-coding` / `grok4.6-general`,
/// both `id = "grok-4.6"`) draws from the same budget — the upstream limit
/// is on the SKU, whatever the config calls it locally.
pub fn modelKey(buf: []u8, provider: *const config.Provider) ![]const u8 {
    return std.fmt.bufPrint(buf, "m:{s}/{s}", .{ provider.name, provider.wireModelName() }) catch
        error.RateLimitKeyTooLong;
}

/// Wait for every cap that applies: the active model's `rpm` (bucket shared
/// by every request for that SKU, across serve connections, goal turns, and
/// the proxy alike) then the provider's `rpm` (shared across all of that
/// provider's models). Both windows live in one process-wide table, so all
/// concurrent requests contribute to and honor the same counts.
pub fn waitFor(io: std.Io, gpa: std.mem.Allocator, provider: *const config.Provider) !void {
    if (provider.activeModel().rpm) |r| {
        if (r > 0) {
            var buf: [256]u8 = undefined;
            const key = try modelKey(&buf, provider);
            try waitKey(io, gpa, key, r);
        }
    }
    if (provider.rpm) |r| {
        if (r > 0) {
            var buf: [256]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "p:{s}", .{provider.name}) catch
                return error.RateLimitKeyTooLong;
            try waitKey(io, gpa, key, r);
        }
    }
}

/// Frees stamp lists; call once at shutdown.
pub fn deinit(io: std.Io, gpa: std.mem.Allocator) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    var it = buckets.iterator();
    while (it.next()) |kv| {
        gpa.free(kv.key_ptr.*);
        kv.value_ptr.deinit(gpa);
    }
    buckets.deinit(gpa);
}

// ------------------------------------------------------------------- tests --

test "waitNs is zero under the cap and after stamps age out" {
    const rpm: u32 = 2;
    const t0: i64 = 10 * window_ns;
    try std.testing.expectEqual(@as(u64, 0), waitNs(t0, &.{}, rpm));
    try std.testing.expectEqual(@as(u64, 0), waitNs(t0, &.{t0}, rpm));
    // Two sends in the window: next wait is until the oldest expires.
    try std.testing.expectEqual(@as(u64, window_ns), waitNs(t0, &.{ t0, t0 }, rpm));
    try std.testing.expectEqual(@as(u64, window_ns / 2), waitNs(t0 + window_ns / 2, &.{ t0, t0 }, rpm));
    // Oldest is already outside the window: the remaining stamp is under cap.
    try std.testing.expectEqual(@as(u64, 0), waitNs(t0 + window_ns, &.{ t0, t0 + 1 }, rpm));
    try std.testing.expectEqual(@as(u64, 0), waitNs(t0, &.{t0}, 0));
}

test "waitNs ignores stamps older than the window when counting" {
    const rpm: u32 = 1;
    const t0: i64 = 2 * window_ns;
    // One live stamp at t0, plus an expired one: at cap, wait a full window.
    try std.testing.expectEqual(@as(u64, window_ns), waitNs(t0, &.{ t0 - window_ns - 1, t0 }, rpm));
}

test "aliases of one wire SKU share a model bucket; distinct SKUs do not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var coding = try config.Provider.single(arena, "xai", "https://api.x.ai/v1", .openai_compat, "grok4.6-coding", .{ .max_tokens = 64, .id = "grok-4.6", .rpm = 10 });
    var general = coding;
    try coding.models.put(arena, "grok4.6-general", .{ .id = "grok-4.6", .rpm = 10 });
    general.models = coding.models;
    general.default_model = "grok4.6-general";

    var a_buf: [256]u8 = undefined;
    var b_buf: [256]u8 = undefined;
    const a = try modelKey(&a_buf, &coding);
    const b = try modelKey(&b_buf, &general);
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expectEqualStrings("m:xai/grok-4.6", a);

    var plain = try config.Provider.single(arena, "xai", "https://api.x.ai/v1", .openai_compat, "grok-3", .{ .max_tokens = 64, .rpm = 10 });
    var p_buf: [256]u8 = undefined;
    const p = try modelKey(&p_buf, &plain);
    try std.testing.expectEqualStrings("m:xai/grok-3", p);
}
