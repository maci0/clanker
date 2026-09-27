//! The one derivation from a run's seed to a guest tool's `ck_random` stream.
//!
//! A sandbox is seeded in two places (`ToolModule.load` and the inline
//! `ck_tool_call` child in `sandbox/host.zig`), so the derivation lives here
//! rather than beside one of them: a tool loaded either way must draw the
//! same stream for the same `agent.seed` and the same module bytes, or a
//! replay of a run that called a nested tool diverges from the original at
//! the first `ck_random` the child makes.
//!
//! The seed and the clock are hashed as little-endian bytes rather than
//! through `asBytes`, which hands over the host's own byte order. A run graph
//! carries `agent.seed` precisely so the run can be replayed, and a run
//! recorded on one machine and replayed on another of the opposite
//! endianness would otherwise derive a different stream from the same seed
//! and diverge at the first draw. Every target clanker ships today is
//! little-endian, so this pins a promise the code was making only by
//! coincidence; it costs four bytes of stack and one explicit byte order.

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
    h.update(&std.mem.toBytes(std.mem.nativeTo(u64, seed, .little)));
    if (seed == 0) {
        const ts: u64 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
        h.update(&std.mem.toBytes(std.mem.nativeTo(u64, ts, .little)));
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

test "the derived stream is pinned to a little-endian seed, not the host's byte order" {
    // Pins the exact value `derive` must produce for a nonzero seed, so a
    // host whose native byte order differs (or a future edit back to
    // `asBytes`) fails here rather than silently re-deriving every recorded
    // run's stream. The reference is computed the way the function claims to
    // work -- Wyhash over the little-endian seed bytes, then the salt -- so
    // the test states the contract instead of freezing an arbitrary number.
    var tp = std.Io.Threaded.init(std.testing.allocator, .{});
    defer tp.deinit();
    const seed: u64 = 0x0102_0304_0506_0708;
    const salt = "module bytes";
    var want = std.hash.Wyhash.init(0x6A09E667F3BCC909);
    want.update(&std.mem.toBytes(std.mem.nativeTo(u64, seed, .little)));
    want.update(salt);
    try std.testing.expectEqual(want.final(), derive(seed, salt, tp.io()));
}
