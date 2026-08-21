//! Anthropic prompt-cache idle clock (ADR 0035 / PRD 0046).
//!
//! Pure classification plus a process-wide last-success stamp *per
//! provider/model*. No daemon, no dummy warmer, no ProviderKind switch.
//! A missing stamp (process start, or a pair never seen) is cold for the
//! helper and not a warning: we have not observed a warm cache yet.

const std = @import("std");

/// Anthropic's documented prompt-cache TTL, in milliseconds.
pub const default_ttl_ms: u64 = 300_000;

/// True when there is no prior success, or idle time is at least `ttl_ms`.
pub fn isCold(last_ok_ms: u64, now_ms: u64, ttl_ms: u64) bool {
    if (last_ok_ms == 0) return true;
    if (now_ms < last_ok_ms) return false;
    return now_ms - last_ok_ms >= ttl_ms;
}

/// Warn only when we have a real stamp that has aged past the TTL. A first
/// request in a process is cold by `isCold` but not a surprise.
pub fn shouldWarn(last_ok_ms: u64, now_ms: u64, ttl_ms: u64) bool {
    return last_ok_ms != 0 and isCold(last_ok_ms, now_ms, ttl_ms);
}

/// Warm was expected and the provider reported no cache hit.
pub fn unexpectedMiss(expected_warm: bool, cache_hit: u32) bool {
    return expected_warm and cache_hit == 0;
}

/// Usage carries cache accounting when the provider reported a hit or a miss.
pub fn hasCacheAccounting(cache_hit: u32, cache_miss: u32) bool {
    return cache_hit > 0 or cache_miss > 0;
}

/// Stamp last success for this provider/model when usage has cache
/// accounting. Returns true when a hit was expected and cache_hit is 0
/// (caller logs). Independent of token_stats: call this before that guard.
pub fn afterUsage(
    provider: []const u8,
    model: []const u8,
    cache_hit: u32,
    cache_miss: u32,
    now_ms: u64,
) bool {
    if (!hasCacheAccounting(cache_hit, cache_miss)) return false;
    const expected_warm = !isCold(lastOk(provider, model), now_ms, default_ttl_ms);
    const miss = unexpectedMiss(expected_warm, cache_hit);
    stamp(provider, model, now_ms);
    return miss;
}

const max_name: usize = 96;
const max_slots: usize = 32;

const Slot = struct {
    provider: [max_name]u8 = undefined,
    model: [max_name]u8 = undefined,
    provider_len: u8 = 0,
    model_len: u8 = 0,
    last_ok_ms: u64 = 0,
    occupied: bool = false,
};

var table_mu: std.atomic.Mutex = .unlocked;
var slots: [max_slots]Slot = [_]Slot{.{}} ** max_slots;

fn lock() void {
    while (!table_mu.tryLock()) std.Thread.yield() catch {};
}

fn clip(s: []const u8) []const u8 {
    return s[0..@min(s.len, max_name)];
}

fn writeName(dst: *[max_name]u8, len: *u8, src: []const u8) void {
    const c = clip(src);
    @memcpy(dst[0..c.len], c);
    len.* = @intCast(c.len);
}

fn slotEql(slot: *const Slot, provider: []const u8, model: []const u8) bool {
    const p = slot.provider[0..slot.provider_len];
    const m = slot.model[0..slot.model_len];
    return std.mem.eql(u8, p, clip(provider)) and std.mem.eql(u8, m, clip(model));
}

fn findOccupiedLocked(provider: []const u8, model: []const u8) ?*Slot {
    for (&slots) |*slot| {
        if (slot.occupied and slotEql(slot, provider, model)) return slot;
    }
    return null;
}

fn allocSlotLocked(provider: []const u8, model: []const u8) *Slot {
    if (findOccupiedLocked(provider, model)) |slot| return slot;
    var free: ?*Slot = null;
    var oldest: *Slot = &slots[0];
    for (&slots) |*slot| {
        if (!slot.occupied) {
            if (free == null) free = slot;
            continue;
        }
        if (slot.last_ok_ms < oldest.last_ok_ms) oldest = slot;
    }
    const slot = free orelse oldest;
    slot.occupied = true;
    writeName(&slot.provider, &slot.provider_len, provider);
    writeName(&slot.model, &slot.model_len, model);
    return slot;
}

pub fn stamp(provider: []const u8, model: []const u8, now_ms: u64) void {
    lock();
    defer table_mu.unlock();
    const slot = allocSlotLocked(provider, model);
    slot.last_ok_ms = now_ms;
}

pub fn lastOk(provider: []const u8, model: []const u8) u64 {
    lock();
    defer table_mu.unlock();
    const slot = findOccupiedLocked(provider, model) orelse return 0;
    return slot.last_ok_ms;
}

test "isCold treats a missing stamp as cold" {
    try std.testing.expect(isCold(0, 1_000, default_ttl_ms));
}

test "isCold is warm inside the TTL and cold at the boundary" {
    const now: u64 = 10_000_000;
    try std.testing.expect(!isCold(now - 1_000, now, default_ttl_ms));
    try std.testing.expect(isCold(now - default_ttl_ms, now, default_ttl_ms));
    try std.testing.expect(!isCold(now + 50, now, default_ttl_ms));
}

test "shouldWarn is silent without a stamp" {
    try std.testing.expect(!shouldWarn(0, 1_000, default_ttl_ms));
    try std.testing.expect(shouldWarn(1, 1 + default_ttl_ms, default_ttl_ms));
}

test "unexpectedMiss fires only when a hit was expected" {
    try std.testing.expect(unexpectedMiss(true, 0));
    try std.testing.expect(!unexpectedMiss(true, 12));
    try std.testing.expect(!unexpectedMiss(false, 0));
}

test "stamp is visible to lastOk for that provider/model only" {
    stamp("anthropic", "claude-a", 42);
    try std.testing.expectEqual(@as(u64, 42), lastOk("anthropic", "claude-a"));
    try std.testing.expectEqual(@as(u64, 0), lastOk("anthropic", "claude-b"));
    try std.testing.expectEqual(@as(u64, 0), lastOk("openai", "claude-a"));
    stamp("anthropic", "claude-a", 0);
}

test "afterUsage stamps only the pair that reported cache accounting" {
    const now: u64 = 50_000;
    try std.testing.expect(!afterUsage("p-a", "m-a", 0, 12, now));
    try std.testing.expectEqual(@as(u64, now), lastOk("p-a", "m-a"));
    try std.testing.expectEqual(@as(u64, 0), lastOk("p-b", "m-a"));
    try std.testing.expectEqual(@as(u64, 0), lastOk("p-a", "m-b"));
    stamp("p-a", "m-a", 0);
}

test "afterUsage reports unexpected miss per pair, not globally" {
    const t0: u64 = 80_000;
    _ = afterUsage("p-warm", "m-1", 10, 0, t0);
    // A sibling model has never succeeded; it must not inherit warmth.
    try std.testing.expect(!afterUsage("p-warm", "m-2", 0, 4, t0 + 1_000));
    // The original pair is still inside the TTL, so a 0-hit is a surprise.
    try std.testing.expect(afterUsage("p-warm", "m-1", 0, 4, t0 + 1_000));
    stamp("p-warm", "m-1", 0);
    stamp("p-warm", "m-2", 0);
}

test "afterUsage with no cache accounting does not stamp" {
    try std.testing.expect(!afterUsage("p-none", "m-none", 0, 0, 99));
    try std.testing.expectEqual(@as(u64, 0), lastOk("p-none", "m-none"));
}
