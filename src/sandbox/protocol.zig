//! Tool ABI helpers: packing (pointer, length) pairs into u64 and back.

pub fn packPtrLen(ptr: u32, len: u32) u64 {
    return (@as(u64, ptr) << 32) | len;
}

pub const PtrLen = struct {
    ptr: u32,
    len: u32,
};

pub fn unpackPtrLen(v: u64) PtrLen {
    return .{
        .ptr = @intCast(v >> 32),
        .len = @intCast(v & 0xFFFF_FFFF),
    };
}

test "pack/unpack round trip" {
    const p = packPtrLen(0x12345678, 0x9ABCDEF0);
    const r = unpackPtrLen(p);
    try std.testing.expectEqual(@as(u32, 0x12345678), r.ptr);
    try std.testing.expectEqual(@as(u32, 0x9ABCDEF0), r.len);
}

const std = @import("std");
