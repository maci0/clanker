//! Pure checks for web UI addons. No host I/O, so `zig build test` runs it.

const std = @import("std");

pub const max_name_len: usize = 64;
pub const max_js_bytes: usize = 512 * 1024;
pub const max_css_bytes: usize = 128 * 1024;
pub const max_title_len: usize = 64;
pub const max_desc_len: usize = 240;

pub const groups = [_][]const u8{ "Work", "Watch", "Set up" };

/// Surfaces a plugin.json may declare. Matches `pluginApi()` in
/// `ui/app/core/plugins.js`. An unknown name is a typo, not a grant.
pub const capabilities = [_][]const u8{
    "get",   "post",      "live", "emit",    "confirm", "prompt",
    "toast", "workspace", "icon", "storage", "render",  "session",
};

/// Fresh `state/webui_plugins.json` is missing: Files is the Work surface
/// (workspace browser) and ships on, Music is the demo addon, and Schedule,
/// Search, and Compare are the migrated built-in views. A written file —
/// including an empty enabled list after the operator turned them all off —
/// is respected; only a missing file seeds. `inherit_on` covers names that
/// used to be built-in and must stay on after an older file that only
/// listed files+music.
pub const default_enabled = [_][]const u8{ "files", "music", "schedule", "search", "compare" };

/// Shipped-as-core views that stay on after a pre-migration
/// `state/webui_plugins.json` listed only files+music. An operator who
/// turns one off is recorded in `disabled`.
pub const inherit_on = [_][]const u8{ "schedule", "search", "compare" };

pub fn isListed(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// `disabled` wins, then `enabled`, then `inherit_on`.
pub fn addonEnabled(enabled: []const []const u8, disabled: []const []const u8, name: []const u8) bool {
    if (isListed(disabled, name)) return false;
    if (isListed(enabled, name)) return true;
    return isListed(&inherit_on, name);
}

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

pub fn validCapability(cap: []const u8) bool {
    for (capabilities) |c| {
        if (std.mem.eql(u8, c, cap)) return true;
    }
    return false;
}

/// Why this capabilities list must not ship. Null means every name is known.
pub fn capabilitiesRejected(caps: []const []const u8) ?[]const u8 {
    for (caps) |c| {
        if (!validCapability(c)) return "unknown capability (get, post, live, emit, confirm, prompt, toast, workspace, icon, storage, render, session)";
    }
    return null;
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

test "capabilitiesRejected names the pluginApi surface" {
    try std.testing.expect(capabilitiesRejected(&.{ "get", "post", "live", "emit" }) == null);
    try std.testing.expect(validCapability("emit"));
    try std.testing.expect(capabilitiesRejected(&.{}) == null);
    try std.testing.expect(capabilitiesRejected(&.{"network"}) != null);
    try std.testing.expect(!validCapability("eval"));
    try std.testing.expect(validCapability("workspace"));
    try std.testing.expect(validCapability("session"));
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

test "first toggle on the fresh-checkout seed keeps the default addons on" {
    // The registry lives in one place (the webui_addon guest). A fresh
    // checkout seeds files+music+schedule+search+compare; enabling a brand-new addon must
    // not drop them, or the page would silently turn Files off on first use.
    const a = try mergeEnabled(std.testing.allocator, &default_enabled, "office", true);
    defer std.testing.allocator.free(a);
    try std.testing.expectEqual(@as(usize, 6), a.len);
    try std.testing.expectEqualStrings("files", a[0]);
    try std.testing.expectEqualStrings("music", a[1]);
    try std.testing.expectEqualStrings("schedule", a[2]);
    try std.testing.expectEqualStrings("search", a[3]);
    try std.testing.expectEqualStrings("compare", a[4]);
    try std.testing.expectEqualStrings("office", a[5]);
}

test "inherit_on keeps schedule after a pre-migration enabled list" {
    const old = [_][]const u8{ "files", "music" };
    try std.testing.expect(addonEnabled(&old, &.{}, "schedule"));
    try std.testing.expect(addonEnabled(&old, &.{}, "search"));
    try std.testing.expect(addonEnabled(&old, &.{}, "compare"));
    try std.testing.expect(addonEnabled(&old, &.{}, "files"));
    try std.testing.expect(!addonEnabled(&old, &.{}, "office"));
    const off = [_][]const u8{"schedule"};
    try std.testing.expect(!addonEnabled(&old, &off, "schedule"));
    try std.testing.expect(addonEnabled(&old, &off, "files"));
    try std.testing.expect(addonEnabled(&old, &off, "search"));
}
