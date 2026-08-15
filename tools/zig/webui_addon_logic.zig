//! Pure checks for web UI addons. No host I/O, so `zig build test` runs it.

const std = @import("std");

pub const max_name_len: usize = 64;
pub const max_js_bytes: usize = 512 * 1024;
pub const max_css_bytes: usize = 128 * 1024;
pub const max_title_len: usize = 64;
pub const max_desc_len: usize = 240;

pub const groups = [_][]const u8{ "Work", "Watch", "Set up" };

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

pub fn validGroup(group: []const u8) bool {
    for (groups) |g| {
        if (std.mem.eql(u8, g, group)) return true;
    }
    return false;
}

pub fn validFile(file: []const u8) bool {
    return std.mem.eql(u8, file, "app.js") or
        std.mem.eql(u8, file, "app.css") or
        std.mem.eql(u8, file, "plugin.json");
}

/// Why this JS must not ship. Null means it passed the cheap static gates.
pub fn jsRejected(js: []const u8) ?[]const u8 {
    if (js.len == 0) return "app.js is empty";
    if (js.len > max_js_bytes) return "app.js is too large";
    if (std.mem.find(u8, js, "clanker.registerView") == null)
        return "app.js must call clanker.registerView";
    if (std.mem.find(u8, js, "innerHTML") != null)
        return "app.js must not assign innerHTML (build DOM with createElement / api.el)";
    if (std.mem.find(u8, js, "eval(") != null)
        return "app.js must not call eval (CSP forbids it)";
    if (std.mem.find(u8, js, "new Function") != null)
        return "app.js must not use new Function (CSP forbids it)";
    if (std.mem.find(u8, js, "document.write") != null)
        return "app.js must not use document.write";
    return null;
}

pub fn cssRejected(css: []const u8) ?[]const u8 {
    if (css.len > max_css_bytes) return "app.css is too large";
    return null;
}

/// Insert or drop `name` in an enabled list. Result is arena-owned.
pub fn mergeEnabled(
    arena: std.mem.Allocator,
    current: []const []const u8,
    name: []const u8,
    on: bool,
) ![]const []const u8 {
    var next: std.ArrayList([]const u8) = .empty;
    for (current) |e| {
        if (std.mem.eql(u8, e, name)) continue;
        try next.append(arena, e);
    }
    if (on) try next.append(arena, name);
    return next.toOwnedSlice(arena);
}

test "validName is a path-safe slug" {
    try std.testing.expect(validName("music"));
    try std.testing.expect(validName("board-burndown"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("a/b"));
    try std.testing.expect(!validName("../x"));
    try std.testing.expect(!validName("x" ** 65));
}

test "validGroup is one of the three rail sections" {
    try std.testing.expect(validGroup("Work"));
    try std.testing.expect(validGroup("Watch"));
    try std.testing.expect(validGroup("Set up"));
    try std.testing.expect(!validGroup("Tools"));
    try std.testing.expect(!validGroup("work"));
}

test "jsRejected requires registerView and refuses CSP-breaking APIs" {
    try std.testing.expectEqualStrings("app.js is empty", jsRejected("").?);
    try std.testing.expectEqualStrings(
        "app.js must call clanker.registerView",
        jsRejected("console.log('hi')").?,
    );
    try std.testing.expectEqualStrings(
        "app.js must not assign innerHTML (build DOM with createElement / api.el)",
        jsRejected("clanker.registerView({}); el.innerHTML = x").?,
    );
    try std.testing.expectEqualStrings(
        "app.js must not call eval (CSP forbids it)",
        jsRejected("clanker.registerView({}); eval(x)").?,
    );
    try std.testing.expect(jsRejected("clanker.registerView({ id: 'x', mount: function(){} });") == null);
}

test "mergeEnabled toggles a name without duplicating it" {
    const a = try mergeEnabled(std.testing.allocator, &.{ "files", "health" }, "music", true);
    defer std.testing.allocator.free(a);
    try std.testing.expectEqual(@as(usize, 3), a.len);
    try std.testing.expectEqualStrings("music", a[2]);

    const b = try mergeEnabled(std.testing.allocator, a, "music", true);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqual(@as(usize, 3), b.len);

    const c = try mergeEnabled(std.testing.allocator, b, "music", false);
    defer std.testing.allocator.free(c);
    try std.testing.expectEqual(@as(usize, 2), c.len);
}
