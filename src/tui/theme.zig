//! Named ANSI styling, so a "no color" mode is one struct swap instead of a
//! sweep through every hardcoded `\x1b[...` literal. `default` matches the
//! REPL's existing colors byte-for-byte (this is a centralization, not a
//! redesign); `mono` is every field empty, for `NO_COLOR` and `--theme mono`.
//!
//! Deliberately not exhaustive: only fields actually consumed by tui/ and
//! the REPL's transcript/prompt code are named here. Widening it is cheap
//! (add a field, default it to `""` in `mono`); the goal is "no reader has
//! to decode a raw escape code to know what a style means", not "every
//! possible SGR combination gets a name".

const std = @import("std");

pub const Theme = struct {
    reset: []const u8 = "",

    bold: []const u8 = "",
    italic: []const u8 = "",
    dim: []const u8 = "",
    code: []const u8 = "",
    heading1: []const u8 = "",
    heading: []const u8 = "",
    quote: []const u8 = "",
    rule: []const u8 = "",
    list_num: []const u8 = "",
    fence: []const u8 = "",

    prompt: []const u8 = "",
    tool: []const u8 = "",
    err: []const u8 = "",
    answer_marker: []const u8 = "",
    ask_question: []const u8 = "",
    ask_pick: []const u8 = "",

    pub const default: Theme = .{
        .reset = "\x1b[0m",
        .bold = "\x1b[1m",
        .italic = "\x1b[3m",
        .dim = "\x1b[2m",
        .code = "\x1b[36m",
        .heading1 = "\x1b[1;4m",
        .heading = "\x1b[1m",
        .quote = "\x1b[2m",
        .rule = "\x1b[2m",
        .list_num = "\x1b[36m",
        .fence = "\x1b[2m",
        .prompt = "\x1b[32m",
        .tool = "\x1b[36m",
        .err = "\x1b[31m",
        .answer_marker = "\x1b[1;35m",
        .ask_question = "\x1b[1;33m",
        .ask_pick = "\x1b[1;36m",
    };

    /// Every field empty: no SGR codes are ever written, so output stays
    /// identical whether or not the terminal understands color.
    pub const mono: Theme = .{};
};

/// `default` unless `NO_COLOR` is set (to any non-empty value, matching the
/// https://no-color.org/ convention) or `name` asks for `"mono"` — an
/// explicit `--theme mono`/config value wins even if `NO_COLOR` is unset.
pub fn select(name: ?[]const u8, environ_map: *const std.process.Environ.Map) Theme {
    if (name) |n| {
        if (std.mem.eql(u8, n, "mono")) return Theme.mono;
        if (std.mem.eql(u8, n, "default")) return Theme.default;
    }
    if (environ_map.get("NO_COLOR")) |v| {
        if (v.len > 0) return Theme.mono;
    }
    return Theme.default;
}

test "default theme matches the REPL's existing byte-for-byte colors" {
    try std.testing.expectEqualStrings("\x1b[32m", Theme.default.prompt);
    try std.testing.expectEqualStrings("\x1b[36m", Theme.default.tool);
    try std.testing.expectEqualStrings("\x1b[1;35m", Theme.default.answer_marker);
}

test "mono theme is every field empty" {
    try std.testing.expectEqualStrings("", Theme.mono.bold);
    try std.testing.expectEqualStrings("", Theme.mono.reset);
    try std.testing.expectEqualStrings("", Theme.mono.err);
}

test "select falls back to mono when NO_COLOR is set" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("NO_COLOR", "1");
    const t = select(null, &map);
    try std.testing.expectEqualStrings("", t.bold);
}

test "select prefers an explicit theme name over NO_COLOR" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("NO_COLOR", "1");
    const t = select("default", &map);
    try std.testing.expectEqualStrings("\x1b[1m", t.bold);
}

test "select defaults to color when NO_COLOR is unset" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    const t = select(null, &map);
    try std.testing.expectEqualStrings("\x1b[1m", t.bold);
}
