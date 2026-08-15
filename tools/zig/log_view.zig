//! Pure helpers for the `logs` guest: name checks and a line-aligned tail.
//! Host-tested; the guest imports this rather than reimplementing the cut.

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

/// The last `max_bytes` of `raw`, cut forward to the first newline so the
/// view never opens mid-line. When the file fits, the whole thing is kept.
pub fn tailOnLineBoundary(raw: []const u8, max_bytes: usize) []const u8 {
    if (raw.len <= max_bytes) return raw;
    const window = raw[raw.len - max_bytes ..];
    if (std.mem.findScalar(u8, window, '\n')) |nl| return window[nl + 1 ..];
    return window;
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

test tailOnLineBoundary {
    try std.testing.expectEqualStrings("abc", tailOnLineBoundary("abc", 64));
    try std.testing.expectEqualStrings("", tailOnLineBoundary("", 64));
    // A window that starts mid-line drops the partial first line.
    try std.testing.expectEqualStrings("cd", tailOnLineBoundary("ab\ncd", 4));
    // No newline in the window: keep the raw window rather than invent one.
    try std.testing.expectEqualStrings("bcde", tailOnLineBoundary("abcde", 4));
    const exact = "x" ** 8;
    try std.testing.expectEqualStrings(exact, tailOnLineBoundary(exact, 8));
}
