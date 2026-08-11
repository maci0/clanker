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

pub const Rgb24 = [3]u8;

/// Token colours as 24-bit values, for renderers that set a colour rather
/// than emit an escape sequence.
pub const Rgb = struct {
    keyword: Rgb24,
    string: Rgb24,
    number: Rgb24,
    builtin: Rgb24,
    preproc: Rgb24,
    comment: Rgb24,
};

/// Catppuccin Mocha, verified against catppuccin/palette's palette.json
/// rather than transcribed from prose (a summary of the style guide had the
/// Surface and Overlay ramps inverted).
pub const mocha_palette = struct {
    pub const rosewater: Rgb24 = .{ 0xf5, 0xe0, 0xdc };
    pub const flamingo: Rgb24 = .{ 0xf2, 0xcd, 0xcd };
    pub const pink: Rgb24 = .{ 0xf5, 0xc2, 0xe7 };
    pub const mauve: Rgb24 = .{ 0xcb, 0xa6, 0xf7 };
    pub const red: Rgb24 = .{ 0xf3, 0x8b, 0xa8 };
    pub const maroon: Rgb24 = .{ 0xeb, 0xa0, 0xac };
    pub const peach: Rgb24 = .{ 0xfa, 0xb3, 0x87 };
    pub const yellow: Rgb24 = .{ 0xf9, 0xe2, 0xaf };
    pub const green: Rgb24 = .{ 0xa6, 0xe3, 0xa1 };
    pub const teal: Rgb24 = .{ 0x94, 0xe2, 0xd5 };
    pub const sky: Rgb24 = .{ 0x89, 0xdc, 0xeb };
    pub const sapphire: Rgb24 = .{ 0x74, 0xc7, 0xec };
    pub const blue: Rgb24 = .{ 0x89, 0xb4, 0xfa };
    pub const lavender: Rgb24 = .{ 0xb4, 0xbe, 0xfe };
    pub const text: Rgb24 = .{ 0xcd, 0xd6, 0xf4 };
    pub const subtext1: Rgb24 = .{ 0xba, 0xc2, 0xde };
    pub const subtext0: Rgb24 = .{ 0xa6, 0xad, 0xc8 };
    pub const overlay2: Rgb24 = .{ 0x93, 0x99, 0xb2 };
    pub const overlay1: Rgb24 = .{ 0x7f, 0x84, 0x9c };
    pub const overlay0: Rgb24 = .{ 0x6c, 0x70, 0x86 };
    pub const surface2: Rgb24 = .{ 0x58, 0x5b, 0x70 };
    pub const surface1: Rgb24 = .{ 0x45, 0x47, 0x5a };
    pub const surface0: Rgb24 = .{ 0x31, 0x32, 0x44 };
    pub const base: Rgb24 = .{ 0x1e, 0x1e, 0x2e };
    pub const mantle: Rgb24 = .{ 0x18, 0x18, 0x25 };
    pub const crust: Rgb24 = .{ 0x11, 0x11, 0x1b };
};

/// A 24-bit foreground SGR sequence, built at comptime so a theme field is
/// still a plain string literal.
fn fg(c: Rgb24) []const u8 {
    return std.fmt.comptimePrint("\x1b[38;2;{d};{d};{d}m", .{ c[0], c[1], c[2] });
}

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

    /// Fenced-code token colours, read by tui2/syntax.zig. Named here so a
    /// theme owns its whole palette rather than the highlighter hardcoding
    /// half of it.
    syn_keyword: []const u8 = "",
    syn_string: []const u8 = "",
    syn_number: []const u8 = "",
    syn_builtin: []const u8 = "",
    syn_preproc: []const u8 = "",
    /// The same colours as 24-bit RGB, for the vaxis renderer, which sets a
    /// cell colour rather than writing an escape. Empty means "use the
    /// terminal's own indexed colour", which is what the default theme wants.
    rgb: ?Rgb = null,

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
        .syn_keyword = "\x1b[35m",
        .syn_string = "\x1b[32m",
        .syn_number = "\x1b[36m",
        .syn_builtin = "\x1b[36m",
        .syn_preproc = "\x1b[33m",
    };

    /// Catppuccin Mocha (https://github.com/catppuccin/catppuccin), with the
    /// roles its style guide assigns: mauve keywords, green strings, peach
    /// numbers, overlay2 comments, blue functions/tools, yellow types and
    /// warnings, red errors. Truecolor, because the palette is 24-bit and
    /// approximating it with the 16 ANSI slots throws away the point of it.
    pub const mocha: Theme = .{
        .reset = "\x1b[0m",
        .bold = "\x1b[1m",
        .italic = "\x1b[3m",
        .dim = fg(mocha_palette.subtext0),
        .code = fg(mocha_palette.teal),
        .heading1 = "\x1b[1m" ++ fg(mocha_palette.mauve),
        .heading = "\x1b[1m" ++ fg(mocha_palette.blue),
        .quote = fg(mocha_palette.subtext0),
        .rule = fg(mocha_palette.overlay0),
        .list_num = fg(mocha_palette.peach),
        .fence = fg(mocha_palette.overlay0),
        .prompt = fg(mocha_palette.green),
        .tool = fg(mocha_palette.blue),
        .err = fg(mocha_palette.red),
        .answer_marker = "\x1b[1m" ++ fg(mocha_palette.mauve),
        .ask_question = "\x1b[1m" ++ fg(mocha_palette.yellow),
        .ask_pick = "\x1b[1m" ++ fg(mocha_palette.sapphire),
        .syn_keyword = fg(mocha_palette.mauve),
        .syn_string = fg(mocha_palette.green),
        .syn_number = fg(mocha_palette.peach),
        .syn_builtin = fg(mocha_palette.yellow),
        .syn_preproc = fg(mocha_palette.pink),
        .rgb = .{
            .keyword = mocha_palette.mauve,
            .string = mocha_palette.green,
            .number = mocha_palette.peach,
            .builtin = mocha_palette.yellow,
            .preproc = mocha_palette.pink,
            .comment = mocha_palette.overlay2,
        },
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
        if (std.mem.eql(u8, n, "mocha") or std.mem.eql(u8, n, "catppuccin")) return Theme.mocha;
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

test "mocha uses the palette's own values, verified against palette.json" {
    // Spot-checks against catppuccin/palette: mauve keywords, green strings,
    // peach numbers, red errors. A transcription slip in a 26-colour table is
    // otherwise invisible until someone looks at it.
    try std.testing.expectEqualStrings("\x1b[38;2;203;166;247m", Theme.mocha.syn_keyword);
    try std.testing.expectEqualStrings("\x1b[38;2;166;227;161m", Theme.mocha.syn_string);
    try std.testing.expectEqualStrings("\x1b[38;2;250;179;135m", Theme.mocha.syn_number);
    try std.testing.expectEqualStrings("\x1b[38;2;243;139;168m", Theme.mocha.err);
    // The Surface/Overlay ramps run dark to light in that order; a summary of
    // the style guide had them inverted, so this pins the direction.
    try std.testing.expect(mocha_palette.surface0[0] < mocha_palette.surface2[0]);
    try std.testing.expect(mocha_palette.overlay0[0] < mocha_palette.overlay2[0]);
    try std.testing.expect(mocha_palette.base[0] < mocha_palette.surface0[0]);
}

test "select accepts mocha by either name, and mono still wins" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try std.testing.expectEqualStrings(Theme.mocha.syn_keyword, select("mocha", &map).syn_keyword);
    try std.testing.expectEqualStrings(Theme.mocha.syn_keyword, select("catppuccin", &map).syn_keyword);
    try std.testing.expectEqualStrings("", select("mono", &map).syn_keyword);
}

test "the default theme's syntax colors are unchanged" {
    // These are asserted byte-for-byte elsewhere in the highlighter's tests;
    // moving them onto the theme must not have moved the values.
    try std.testing.expectEqualStrings("\x1b[35m", Theme.default.syn_keyword);
    try std.testing.expectEqualStrings("\x1b[32m", Theme.default.syn_string);
    try std.testing.expectEqualStrings("\x1b[36m", Theme.default.syn_number);
    try std.testing.expect(Theme.default.rgb == null);
}
