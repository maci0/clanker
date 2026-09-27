//! Milliseconds elapsed since a `std.Io.Timestamp`, on the awake clock.
//!
//! Every timed call in the harness (a chat, a tool, an LLM leg, a provider
//! ping, a proxied request) starts by stamping `std.Io.Timestamp.now(io,
//! .awake)` and ends by asking how long that took. That last line was five
//! copies of the same two functions, split three ways on the return type and
//! with the negative-span clamp written out inline in a sixth, so the one
//! subtlety (a signed subtraction must not `@intCast` a negative span into an
//! unsigned field) had five chances to be forgotten and no single test.
//!
//! `.awake` is the monotonic clock, which is why these read it: an NTP step
//! mid-call would otherwise make one leg look faster than it ran, or negative.
//! The clamp stays anyway, because a clamped zero is a wrong number and a
//! `@intCast` panic in Debug is a crash.
//!
//! The signed form is not a second opinion about the answer; it is for the
//! session-event and tool-result integer fields that are `i64` on the wire
//! (JSON has no unsigned type, and those files parse through `jsonInt`).

const std = @import("std");

/// Whole milliseconds from `t0` to now, zero for a span that reads negative.
pub fn since(io: std.Io, t0: std.Io.Timestamp) u64 {
    return ms(t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);
}

/// `since` for a destination that is itself signed.
pub fn sinceSigned(io: std.Io, t0: std.Io.Timestamp) i64 {
    return msSigned(t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds);
}

fn ms(ns: i96) u64 {
    return @intCast(@max(0, @divTrunc(ns, std.time.ns_per_ms)));
}

fn msSigned(ns: i96) i64 {
    return @intCast(@max(0, @divTrunc(ns, std.time.ns_per_ms)));
}

test "a negative span reads as zero, not a wrapped count" {
    try std.testing.expectEqual(@as(u64, 0), ms(-1));
    try std.testing.expectEqual(@as(u64, 0), ms(-std.time.ns_per_s));
    try std.testing.expectEqual(@as(u64, 0), ms(0));
    try std.testing.expectEqual(@as(i64, 0), msSigned(-1));
    try std.testing.expectEqual(@as(i64, 0), msSigned(-std.time.ns_per_s));
}

test "milliseconds truncate toward zero past a whole millisecond" {
    try std.testing.expectEqual(@as(u64, 1), ms(std.time.ns_per_ms));
    try std.testing.expectEqual(@as(u64, 1), ms(std.time.ns_per_ms + 999_999));
    try std.testing.expectEqual(@as(u64, 1000), ms(std.time.ns_per_s));
    try std.testing.expectEqual(@as(i64, 1000), msSigned(std.time.ns_per_s));
}

test "since and sinceSigned measure the same span within a millisecond" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const t0 = std.Io.Timestamp.now(io, .awake);
    try io.sleep(.fromMilliseconds(30), .awake);
    const u = since(io, t0);
    const s = sinceSigned(io, t0);
    try std.testing.expect(u >= 29);
    try std.testing.expectEqual(u, @as(u64, @intCast(@max(0, s))));
}
