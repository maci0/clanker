//! The one derivation from a run's seed to a guest tool's `ck_random` stream.
//!
//! A sandbox is seeded in two places (`ToolModule.load` and the inline
//! `ck_tool_call` child in `sandbox/host.zig`), so the derivation lives here
//! rather than beside one of them: a tool loaded either way must draw the
//! same stream for the same `agent.seed` and the same module bytes, or a
//! replay of a run that called a nested tool diverges from the original at
//! the first `ck_random` the child makes.

const std = @import("std");

/// Effective seed for one guest from `seed` and the bytes that identify it.
///
/// `agent.seed = 0` (the default) is documented as time-seeded: the tool
/// RNG is reproducible only when a nonzero seed is set. Without this, seed 0
/// would be a pure function of the module bytes and every clanker instance
/// everywhere would draw the identical `ck_random` stream. The clock mixes
/// per-process entropy in; a nonzero seed stays deterministic, which is what
/// `clanker eval --seed` and a replay both rely on.
pub fn derive(seed: u64, salt: []const u8, io: std.Io) u64 {
    var h = std.hash.Wyhash.init(0x6A09E667F3BCC909);
    h.update(std.mem.asBytes(&seed));
    if (seed == 0) {
        const ts: u64 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
        h.update(std.mem.asBytes(&ts));
    }
    h.update(salt);
    return h.final();
}

test "derive with a nonzero seed is clock-independent (same seed ⇒ same stream)" {
    var tp_a = std.Io.Threaded.init(std.testing.allocator, .{});
    defer tp_a.deinit();
    var tp_b = std.Io.Threaded.init(std.testing.allocator, .{});
    defer tp_b.deinit();
    const salt = "module bytes";
    // Two independent Io instances carry two different clocks. A pinned
    // (nonzero) seed must derive the identical effective seed anyway, or
    // `agent.seed` could not replay a run; the seed-0 branch exists precisely
    // so the nonzero branch never has to touch the clock.
    try std.testing.expectEqual(
        derive(0x1234_5678_9abc_def0, salt, tp_a.io()),
        derive(0x1234_5678_9abc_def0, salt, tp_b.io()),
    );
}

test "a different salt for the same seed gives a different stream" {
    var tp = std.Io.Threaded.init(std.testing.allocator, .{});
    defer tp.deinit();
    try std.testing.expect(
        derive(7, "tool-a", tp.io()) != derive(7, "tool-b", tp.io()),
    );
}
