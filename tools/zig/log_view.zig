//! Pure helpers for the `logs` guest: name checks and the tail window size.
//! Host-tested; the guest imports this rather than reimplementing the checks.
//! The line-aligned cut itself is `tail.onLineBoundary` (`src/util/tail.zig`).

const std = @import("std");

/// Bytes of log text the web view shows. Matches the native handler this
/// replaced, so a page that already scrolled a 64 KiB tail keeps that size.
pub const tail_bytes: usize = 64 * 1024;

/// A log name is a single path component. Anything with a separator or `..`
/// is refused before it is joined onto `state/logs/`, so a crafted name
/// cannot describe a path at all.
pub fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.findAny(u8, name, "/\\") != null) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| {
        if (c < 0x20 or c == 0x7f) return false;
    }
    return true;
}

test validName {
    try std.testing.expect(validName("clanker.log"));
    try std.testing.expect(validName("serve-2026-08-15.log"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("."));
    try std.testing.expect(!validName(".."));
    try std.testing.expect(!validName("../config.toml"));
    try std.testing.expect(!validName("a/b"));
    try std.testing.expect(!validName("a\\b"));
    try std.testing.expect(!validName("has\nnewline"));
}
