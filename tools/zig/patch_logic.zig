//! Pure text-patch primitives for tools/zig/patch_apply.zig. The guest is a
//! sandboxed wasm module, where a `test` block can never run, so the pure
//! function its tests pin lives here and `zig build test` runs them on the
//! host. Same shape as commit_logic / compare_logic.

const std = @import("std");

/// Replaces the first occurrence of `old` in `text` with `new`, or appends
/// `new` when `old` is empty. Same semantics as the native patch applier it
/// replaced: exact match, first occurrence only, never line-numbered.
pub fn patchOnce(alloc: std.mem.Allocator, text: []const u8, old: []const u8, new: []const u8) ![]u8 {
    if (old.len == 0) return std.mem.concat(alloc, u8, &.{ text, new });
    const idx = std.mem.find(u8, text, old) orelse return error.OldTextNotFound;
    return std.mem.concat(alloc, u8, &.{ text[0..idx], new, text[idx + old.len ..] });
}

test "patchOnce replaces only the first exact-match occurrence" {
    const got = try patchOnce(std.testing.allocator, "hello world world", "world", "zig");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hello zig world", got);
}

test "patchOnce appends when old is empty" {
    const got = try patchOnce(std.testing.allocator, "hello", "", " world");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hello world", got);
}

test "patchOnce fails when old text is not found" {
    try std.testing.expectError(error.OldTextNotFound, patchOnce(std.testing.allocator, "hello", "xyz", "new"));
}
