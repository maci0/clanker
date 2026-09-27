//! Seed encoding for `std.testing.fuzz` corpora.
//!
//! A corpus entry is not the input the harness reads: it is a stream of Smith
//! directives, and `smith.slice` takes the next one as a 4-byte little-endian
//! length followed by that many bytes. A corpus entry that is the raw string
//! therefore loses its first four bytes to that length field -- a JSON seed
//! arrives as a document missing its opening `{"ab`, fails to parse, and the
//! harness asserts on nothing. Nothing fails either way, so a corpus of raw
//! strings looks like coverage while steering none of it, in `zig build test`
//! and in `zig test -fuzz` alike.
//!
//! So every seed goes through `entry`, and the test below pins the encoding
//! against a real `Smith` rather than against this file's own arithmetic.

const std = @import("std");

/// The Smith encoding of one `smith.slice` seed: the length the slice will
/// read, then the bytes it fills.
pub fn entry(comptime seed: []const u8) []const u8 {
    if (seed.len > std.math.maxInt(u32)) @compileError("fuzz seed longer than a Smith length field");
    const encoded = comptime blk: {
        var buf: [4 + seed.len]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], @intCast(seed.len), .little);
        @memcpy(buf[4..], seed);
        break :blk buf;
    };
    return &encoded;
}

test "entry decodes back to the seed through a real Smith" {
    const seeds = [_][]const u8{
        entry("{\"path\":\"src/cli.zig\"}"),
        entry(""),
        entry("[DONE]"),
        entry("\x00\xff{\"a\":1}"),
    };
    for (seeds, 0..) |corpus_entry, i| {
        var smith: std.testing.Smith = .{ .in = corpus_entry };
        var buf: [64]u8 = undefined;
        const len = smith.slice(&buf);
        const raw = [_][]const u8{ "{\"path\":\"src/cli.zig\"}", "", "[DONE]", "\x00\xff{\"a\":1}" };
        try std.testing.expectEqualStrings(raw[i], buf[0..len]);
    }
}

test "a raw seed is silently eaten four bytes at a time, which is the trap entry exists to remove" {
    // Pins the reason the helper exists. A raw seed does not fail loudly: the
    // slice reads its first four bytes as a length field, clamps that to what
    // is left, and hands the harness the *rest* of the string. A JSON seed
    // therefore arrives as a document missing its opening `{"ab`, parses as
    // garbage, and asserts nothing -- which is why a corpus of raw strings
    // looks like coverage while steering none of it.
    const raw = "{\"path\":\"src/cli.zig\"}";
    var smith: std.testing.Smith = .{ .in = raw };
    var buf: [64]u8 = undefined;
    const len = smith.slice(&buf);
    try std.testing.expectEqual(@as(u32, raw.len - 4), len);
    try std.testing.expectEqualStrings("th\":\"src/cli.zig\"}", buf[0..len]);
}
