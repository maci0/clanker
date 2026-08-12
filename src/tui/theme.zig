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
    /// UI roles beyond fenced-code syntax, for the vaxis REPL's chrome (box
    /// border, status line, tool-call lines, error text) — everything the
    /// ANSI-escape fields already colour but a cell-based renderer can't
    /// read out of an escape string.
    dim: Rgb24,
    tool: Rgb24,
    err: Rgb24,
    rule: Rgb24,
    /// The user's echoed prompt line and the "ready" status, so a turn's
    /// starting point is scannable and an idle prompt reads as go.
    prompt: Rgb24,
    /// The brand mark and the active provider/model in the status line, plus
    /// the "thinking/running" phase while a turn is in flight.
    accent: Rgb24,
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

/// Catppuccin Latte, the light member of the family. Same field names and
/// order as `mocha_palette`; values from catppuccin/palette's palette.json.
pub const latte_palette = struct {
    pub const rosewater: Rgb24 = .{ 0xdc, 0x8a, 0x78 };
    pub const flamingo: Rgb24 = .{ 0xdd, 0x78, 0x78 };
    pub const pink: Rgb24 = .{ 0xea, 0x76, 0xcb };
    pub const mauve: Rgb24 = .{ 0x88, 0x39, 0xef };
    pub const red: Rgb24 = .{ 0xd2, 0x0f, 0x39 };
    pub const maroon: Rgb24 = .{ 0xe6, 0x45, 0x53 };
    pub const peach: Rgb24 = .{ 0xfe, 0x64, 0x0b };
    pub const yellow: Rgb24 = .{ 0xdf, 0x8e, 0x1d };
    pub const green: Rgb24 = .{ 0x40, 0xa0, 0x2b };
    pub const teal: Rgb24 = .{ 0x17, 0x92, 0x99 };
    pub const sky: Rgb24 = .{ 0x04, 0xa5, 0xe5 };
    pub const sapphire: Rgb24 = .{ 0x20, 0x9f, 0xb5 };
    pub const blue: Rgb24 = .{ 0x1e, 0x66, 0xf5 };
    pub const lavender: Rgb24 = .{ 0x72, 0x87, 0xfd };
    pub const text: Rgb24 = .{ 0x4c, 0x4f, 0x69 };
    pub const subtext1: Rgb24 = .{ 0x5c, 0x5f, 0x77 };
    pub const subtext0: Rgb24 = .{ 0x6c, 0x6f, 0x85 };
    pub const overlay2: Rgb24 = .{ 0x7c, 0x7f, 0x93 };
    pub const overlay1: Rgb24 = .{ 0x8c, 0x8f, 0xa1 };
    pub const overlay0: Rgb24 = .{ 0x9c, 0xa0, 0xb0 };
    pub const surface2: Rgb24 = .{ 0xac, 0xb0, 0xbe };
    pub const surface1: Rgb24 = .{ 0xbc, 0xc0, 0xcc };
    pub const surface0: Rgb24 = .{ 0xcc, 0xd0, 0xda };
    pub const base: Rgb24 = .{ 0xef, 0xf1, 0xf5 };
    pub const mantle: Rgb24 = .{ 0xe6, 0xe9, 0xef };
    pub const crust: Rgb24 = .{ 0xdc, 0xe0, 0xe8 };
};

/// Catppuccin Frappé, the softer-contrast dark variant.
pub const frappe_palette = struct {
    pub const rosewater: Rgb24 = .{ 0xf2, 0xd5, 0xcf };
    pub const flamingo: Rgb24 = .{ 0xee, 0xbe, 0xbe };
    pub const pink: Rgb24 = .{ 0xf4, 0xb8, 0xe4 };
    pub const mauve: Rgb24 = .{ 0xca, 0x9e, 0xe6 };
    pub const red: Rgb24 = .{ 0xe7, 0x82, 0x84 };
    pub const maroon: Rgb24 = .{ 0xea, 0x99, 0x9c };
    pub const peach: Rgb24 = .{ 0xef, 0x9f, 0x76 };
    pub const yellow: Rgb24 = .{ 0xe5, 0xc8, 0x90 };
    pub const green: Rgb24 = .{ 0xa6, 0xd1, 0x89 };
    pub const teal: Rgb24 = .{ 0x81, 0xc8, 0xbe };
    pub const sky: Rgb24 = .{ 0x99, 0xd1, 0xdb };
    pub const sapphire: Rgb24 = .{ 0x85, 0xc1, 0xdc };
    pub const blue: Rgb24 = .{ 0x8c, 0xaa, 0xee };
    pub const lavender: Rgb24 = .{ 0xba, 0xbb, 0xf1 };
    pub const text: Rgb24 = .{ 0xc6, 0xd0, 0xf5 };
    pub const subtext1: Rgb24 = .{ 0xb5, 0xbf, 0xe2 };
    pub const subtext0: Rgb24 = .{ 0xa5, 0xad, 0xce };
    pub const overlay2: Rgb24 = .{ 0x94, 0x9c, 0xbb };
    pub const overlay1: Rgb24 = .{ 0x83, 0x8b, 0xa7 };
    pub const overlay0: Rgb24 = .{ 0x73, 0x79, 0x94 };
    pub const surface2: Rgb24 = .{ 0x62, 0x68, 0x80 };
    pub const surface1: Rgb24 = .{ 0x51, 0x57, 0x6d };
    pub const surface0: Rgb24 = .{ 0x41, 0x45, 0x59 };
    pub const base: Rgb24 = .{ 0x30, 0x34, 0x46 };
    pub const mantle: Rgb24 = .{ 0x29, 0x2c, 0x3c };
    pub const crust: Rgb24 = .{ 0x23, 0x26, 0x34 };
};

/// Catppuccin Macchiato, between Frappé and Mocha in contrast.
pub const macchiato_palette = struct {
    pub const rosewater: Rgb24 = .{ 0xf4, 0xdb, 0xd6 };
    pub const flamingo: Rgb24 = .{ 0xf0, 0xc6, 0xc6 };
    pub const pink: Rgb24 = .{ 0xf5, 0xbd, 0xe6 };
    pub const mauve: Rgb24 = .{ 0xc6, 0xa0, 0xf6 };
    pub const red: Rgb24 = .{ 0xed, 0x87, 0x96 };
    pub const maroon: Rgb24 = .{ 0xee, 0x99, 0xa0 };
    pub const peach: Rgb24 = .{ 0xf5, 0xa9, 0x7f };
    pub const yellow: Rgb24 = .{ 0xee, 0xd4, 0x9f };
    pub const green: Rgb24 = .{ 0xa6, 0xda, 0x95 };
    pub const teal: Rgb24 = .{ 0x8b, 0xd5, 0xca };
    pub const sky: Rgb24 = .{ 0x91, 0xd7, 0xe3 };
    pub const sapphire: Rgb24 = .{ 0x7d, 0xc4, 0xe4 };
    pub const blue: Rgb24 = .{ 0x8a, 0xad, 0xf4 };
    pub const lavender: Rgb24 = .{ 0xb7, 0xbd, 0xf8 };
    pub const text: Rgb24 = .{ 0xca, 0xd3, 0xf5 };
    pub const subtext1: Rgb24 = .{ 0xb8, 0xc0, 0xe0 };
    pub const subtext0: Rgb24 = .{ 0xa5, 0xad, 0xcb };
    pub const overlay2: Rgb24 = .{ 0x93, 0x9a, 0xb7 };
    pub const overlay1: Rgb24 = .{ 0x80, 0x87, 0xa2 };
    pub const overlay0: Rgb24 = .{ 0x6e, 0x73, 0x8d };
    pub const surface2: Rgb24 = .{ 0x5b, 0x60, 0x78 };
    pub const surface1: Rgb24 = .{ 0x49, 0x4d, 0x64 };
    pub const surface0: Rgb24 = .{ 0x36, 0x3a, 0x4f };
    pub const base: Rgb24 = .{ 0x24, 0x27, 0x3a };
    pub const mantle: Rgb24 = .{ 0x1e, 0x20, 0x30 };
    pub const crust: Rgb24 = .{ 0x18, 0x19, 0x26 };
};

/// Tokyo Night (folke/tokyonight.nvim), the flagship dark variant. Values
/// from the project's own generated `extras/lua/tokyonight_night.lua`
/// colorscheme, not transcribed from a screenshot.
pub const tokyo_night_palette = struct {
    pub const bg: Rgb24 = .{ 0x1a, 0x1b, 0x26 };
    pub const bg_highlight: Rgb24 = .{ 0x29, 0x2e, 0x42 };
    pub const terminal_black: Rgb24 = .{ 0x41, 0x48, 0x68 };
    pub const fg: Rgb24 = .{ 0xc0, 0xca, 0xf5 };
    pub const fg_dark: Rgb24 = .{ 0xa9, 0xb1, 0xd6 };
    pub const dark3: Rgb24 = .{ 0x54, 0x5c, 0x7e };
    pub const comment: Rgb24 = .{ 0x56, 0x5f, 0x89 };
    pub const blue: Rgb24 = .{ 0x7a, 0xa2, 0xf7 };
    pub const cyan: Rgb24 = .{ 0x7d, 0xcf, 0xff };
    pub const purple: Rgb24 = .{ 0x9d, 0x7c, 0xd8 };
    pub const magenta: Rgb24 = .{ 0xbb, 0x9a, 0xf7 };
    pub const red: Rgb24 = .{ 0xf7, 0x76, 0x8e };
    pub const orange: Rgb24 = .{ 0xff, 0x9e, 0x64 };
    pub const yellow: Rgb24 = .{ 0xe0, 0xaf, 0x68 };
    pub const green: Rgb24 = .{ 0x9e, 0xce, 0x6a };
    pub const teal: Rgb24 = .{ 0x1a, 0xbc, 0x9c };
};

/// Tokyo Night Storm: the same palette as Night with a lighter background
/// (`#24283b`/`#1f2335` vs `#1a1b26`/`#16161e`); every other value matches.
pub const tokyo_storm_palette = struct {
    pub const bg: Rgb24 = .{ 0x24, 0x28, 0x3b };
    pub const bg_highlight: Rgb24 = .{ 0x29, 0x2e, 0x42 };
    pub const terminal_black: Rgb24 = .{ 0x41, 0x48, 0x68 };
    pub const fg: Rgb24 = .{ 0xc0, 0xca, 0xf5 };
    pub const fg_dark: Rgb24 = .{ 0xa9, 0xb1, 0xd6 };
    pub const dark3: Rgb24 = .{ 0x54, 0x5c, 0x7e };
    pub const comment: Rgb24 = .{ 0x56, 0x5f, 0x89 };
    pub const blue: Rgb24 = .{ 0x7a, 0xa2, 0xf7 };
    pub const cyan: Rgb24 = .{ 0x7d, 0xcf, 0xff };
    pub const purple: Rgb24 = .{ 0x9d, 0x7c, 0xd8 };
    pub const magenta: Rgb24 = .{ 0xbb, 0x9a, 0xf7 };
    pub const red: Rgb24 = .{ 0xf7, 0x76, 0x8e };
    pub const orange: Rgb24 = .{ 0xff, 0x9e, 0x64 };
    pub const yellow: Rgb24 = .{ 0xe0, 0xaf, 0x68 };
    pub const green: Rgb24 = .{ 0x9e, 0xce, 0x6a };
    pub const teal: Rgb24 = .{ 0x1a, 0xbc, 0x9c };
};

/// Tokyo Night Day, the light variant. Values from
/// `extras/lua/tokyonight_day.lua`; every hue is inverted relative to Night,
/// not just lightened, so it does not share Night's field values.
pub const tokyo_day_palette = struct {
    pub const bg: Rgb24 = .{ 0xe1, 0xe2, 0xe7 };
    pub const bg_highlight: Rgb24 = .{ 0xc4, 0xc8, 0xda };
    pub const terminal_black: Rgb24 = .{ 0xa1, 0xa6, 0xc5 };
    pub const fg: Rgb24 = .{ 0x37, 0x60, 0xbf };
    pub const fg_dark: Rgb24 = .{ 0x61, 0x72, 0xb0 };
    pub const dark3: Rgb24 = .{ 0x89, 0x90, 0xb3 };
    pub const comment: Rgb24 = .{ 0x84, 0x8c, 0xb5 };
    pub const blue: Rgb24 = .{ 0x2e, 0x7d, 0xe9 };
    pub const cyan: Rgb24 = .{ 0x00, 0x71, 0x97 };
    pub const purple: Rgb24 = .{ 0x78, 0x47, 0xbd };
    pub const magenta: Rgb24 = .{ 0x98, 0x54, 0xf1 };
    pub const red: Rgb24 = .{ 0xf5, 0x2a, 0x65 };
    pub const orange: Rgb24 = .{ 0xb1, 0x5c, 0x00 };
    pub const yellow: Rgb24 = .{ 0x8c, 0x6c, 0x3e };
    pub const green: Rgb24 = .{ 0x58, 0x75, 0x39 };
    pub const teal: Rgb24 = .{ 0x11, 0x8c, 0x74 };
};

/// A 24-bit foreground SGR sequence, built at comptime so a theme field is
/// still a plain string literal.
fn fg(c: Rgb24) []const u8 {
    return std.fmt.comptimePrint("\x1b[38;2;{d};{d};{d}m", .{ c[0], c[1], c[2] });
}

/// Builds a Theme from any of `mocha_palette`/`latte_palette`/`frappe_palette`/
/// `macchiato_palette` (they share field names and Catppuccin's own style
/// guide role assignment) so the four flavours can't drift from each other by
/// a transcription slip in a hand-copied 20-field struct literal.
fn catppuccinTheme(comptime p: type) Theme {
    return .{
        .reset = "\x1b[0m",
        .bold = "\x1b[1m",
        .italic = "\x1b[3m",
        .dim = fg(p.subtext0),
        .code = fg(p.teal),
        .heading1 = "\x1b[1m" ++ fg(p.mauve),
        .heading = "\x1b[1m" ++ fg(p.blue),
        .quote = fg(p.subtext0),
        .rule = fg(p.overlay0),
        .list_num = fg(p.peach),
        .fence = fg(p.overlay0),
        .prompt = fg(p.green),
        .tool = fg(p.blue),
        .err = fg(p.red),
        .answer_marker = "\x1b[1m" ++ fg(p.mauve),
        .ask_question = "\x1b[1m" ++ fg(p.yellow),
        .ask_pick = "\x1b[1m" ++ fg(p.sapphire),
        .syn_keyword = fg(p.mauve),
        .syn_string = fg(p.green),
        .syn_number = fg(p.peach),
        .syn_builtin = fg(p.yellow),
        .syn_preproc = fg(p.pink),
        .rgb = .{
            .keyword = p.mauve,
            .string = p.green,
            .number = p.peach,
            .builtin = p.yellow,
            .preproc = p.pink,
            .comment = p.overlay2,
            .dim = p.subtext0,
            .tool = p.blue,
            .err = p.red,
            .rule = p.overlay0,
            .prompt = p.green,
            .accent = p.mauve,
        },
    };
}

/// Builds a Theme from any of `tokyo_night_palette`/`tokyo_storm_palette`/
/// `tokyo_day_palette`, using the role assignment tokyonight.nvim's own
/// `lua/tokyonight/groups/base.lua` makes: cyan keywords, green strings,
/// orange constants/numbers, blue functions, magenta statements/preproc,
/// grey comments.
fn tokyoNightTheme(comptime p: type) Theme {
    return .{
        .reset = "\x1b[0m",
        .bold = "\x1b[1m",
        .italic = "\x1b[3m",
        .dim = fg(p.comment),
        .code = fg(p.teal),
        .heading1 = "\x1b[1m" ++ fg(p.purple),
        .heading = "\x1b[1m" ++ fg(p.blue),
        .quote = fg(p.comment),
        .rule = fg(p.dark3),
        .list_num = fg(p.orange),
        .fence = fg(p.dark3),
        .prompt = fg(p.green),
        .tool = fg(p.blue),
        .err = fg(p.red),
        .answer_marker = "\x1b[1m" ++ fg(p.purple),
        .ask_question = "\x1b[1m" ++ fg(p.yellow),
        .ask_pick = "\x1b[1m" ++ fg(p.cyan),
        .syn_keyword = fg(p.cyan),
        .syn_string = fg(p.green),
        .syn_number = fg(p.orange),
        .syn_builtin = fg(p.blue),
        .syn_preproc = fg(p.magenta),
        .rgb = .{
            .keyword = p.cyan,
            .string = p.green,
            .number = p.orange,
            .builtin = p.blue,
            .preproc = p.magenta,
            .comment = p.comment,
            .dim = p.comment,
            .tool = p.blue,
            .err = p.red,
            .rule = p.dark3,
            .prompt = p.green,
            .accent = p.purple,
        },
    };
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

    /// Fenced-code token colours, read by tui/syntax.zig. Named here so a
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
    pub const mocha: Theme = catppuccinTheme(mocha_palette);

    /// Catppuccin Latte, the family's light variant. Same role assignment as
    /// Mocha; only the palette underneath changes.
    pub const latte: Theme = catppuccinTheme(latte_palette);

    /// Catppuccin Frappé, the softer-contrast dark variant.
    pub const frappe: Theme = catppuccinTheme(frappe_palette);

    /// Catppuccin Macchiato, between Frappé and Mocha in contrast.
    pub const macchiato: Theme = catppuccinTheme(macchiato_palette);

    /// Tokyo Night (folke/tokyonight.nvim), the flagship dark variant.
    pub const tokyo_night: Theme = tokyoNightTheme(tokyo_night_palette);

    /// Tokyo Night Storm: Night with a lighter background, same accents.
    pub const tokyo_storm: Theme = tokyoNightTheme(tokyo_storm_palette);

    /// Tokyo Night Day, the light variant (every hue inverted, not just
    /// lightened, so it reads as its own theme rather than a tint of Night).
    pub const tokyo_day: Theme = tokyoNightTheme(tokyo_day_palette);

    /// Hackerman: the green-phosphor terminal look, bright green on black,
    /// amber for numbers/warnings and red for errors so a failure still reads.
    /// Truecolor; the syntax roles all sit in the green family with a couple
    /// of accents so code stays legible without leaving the aesthetic.
    pub const hackerman: Theme = .{
        .reset = "\x1b[0m",
        .bold = "\x1b[1m",
        .italic = "\x1b[3m",
        .dim = "\x1b[38;2;0;120;0m",
        .code = "\x1b[38;2;0;255;170m",
        .heading1 = "\x1b[1m\x1b[38;2;120;255;120m",
        .heading = "\x1b[1m\x1b[38;2;80;255;80m",
        .quote = "\x1b[38;2;0;120;0m",
        .rule = "\x1b[38;2;0;90;0m",
        .list_num = "\x1b[38;2;0;255;170m",
        .fence = "\x1b[38;2;0;90;0m",
        .prompt = "\x1b[38;2;0;255;0m",
        .tool = "\x1b[38;2;0;255;170m",
        .err = "\x1b[38;2;255;60;60m",
        .answer_marker = "\x1b[1m\x1b[38;2;120;255;120m",
        .ask_question = "\x1b[1m\x1b[38;2;180;255;80m",
        .ask_pick = "\x1b[1m\x1b[38;2;0;255;170m",
        .syn_keyword = "\x1b[38;2;120;255;120m",
        .syn_string = "\x1b[38;2;0;255;170m",
        .syn_number = "\x1b[38;2;180;255;80m",
        .syn_builtin = "\x1b[38;2;0;220;140m",
        .syn_preproc = "\x1b[38;2;180;255;80m",
        .rgb = .{
            .keyword = .{ 120, 255, 120 },
            .string = .{ 0, 255, 170 },
            .number = .{ 180, 255, 80 },
            .builtin = .{ 0, 220, 140 },
            .preproc = .{ 180, 255, 80 },
            .comment = .{ 0, 120, 0 },
            .dim = .{ 0, 120, 0 },
            .tool = .{ 0, 255, 170 },
            .err = .{ 255, 60, 60 },
            .rule = .{ 0, 90, 0 },
            .prompt = .{ 0, 255, 0 },
            .accent = .{ 80, 255, 80 },
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
        if (std.mem.eql(u8, n, "latte")) return Theme.latte;
        if (std.mem.eql(u8, n, "frappe") or std.mem.eql(u8, n, "frappé")) return Theme.frappe;
        if (std.mem.eql(u8, n, "macchiato")) return Theme.macchiato;
        if (std.mem.eql(u8, n, "tokyonight") or std.mem.eql(u8, n, "tokyo-night") or std.mem.eql(u8, n, "tokyonight-night")) return Theme.tokyo_night;
        if (std.mem.eql(u8, n, "storm") or std.mem.eql(u8, n, "tokyonight-storm")) return Theme.tokyo_storm;
        if (std.mem.eql(u8, n, "day") or std.mem.eql(u8, n, "tokyonight-day")) return Theme.tokyo_day;
        if (std.mem.eql(u8, n, "hackerman")) return Theme.hackerman;
    }
    if (environ_map.get("NO_COLOR")) |v| {
        if (v.len > 0) return Theme.mono;
    }
    return Theme.default;
}

/// Canonical theme names for `/theme` and completion, aligned with the web
/// UI's palette set (core/theme.js). `select` also accepts the aliases
/// (`catppuccin`, `tokyo-night`, `storm`, `day`, ...); these are the names to
/// show and cycle through.
pub const names = [_][]const u8{
    "default",   "mono",       "mocha",            "latte",          "frappe",
    "macchiato", "tokyonight", "tokyonight-storm", "tokyonight-day", "hackerman",
};

/// Whether `select` recognizes `name` (canonical spelling or a known alias),
/// so `/theme <name>` can reject a typo instead of silently falling back to
/// default.
pub fn isKnown(name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return std.mem.eql(u8, name, "catppuccin") or
        std.mem.eql(u8, name, "tokyo-night") or
        std.mem.eql(u8, name, "tokyonight-night") or
        std.mem.eql(u8, name, "frappé") or
        std.mem.eql(u8, name, "storm") or
        std.mem.eql(u8, name, "day");
}

test "isKnown accepts every canonical name and rejects a typo" {
    for (names) |n| try std.testing.expect(isKnown(n));
    try std.testing.expect(isKnown("catppuccin"));
    try std.testing.expect(!isKnown("nord"));
    try std.testing.expect(!isKnown(""));
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

test "the other three Catppuccin flavours use their own palette's values" {
    // Same role (mauve keywords, green strings) verified against each
    // flavour's own palette.json, so a copy-paste from Mocha's hex would fail.
    try std.testing.expectEqualStrings("\x1b[38;2;136;57;239m", Theme.latte.syn_keyword);
    try std.testing.expectEqualStrings("\x1b[38;2;64;160;43m", Theme.latte.syn_string);
    try std.testing.expectEqualStrings("\x1b[38;2;202;158;230m", Theme.frappe.syn_keyword);
    try std.testing.expectEqualStrings("\x1b[38;2;166;209;137m", Theme.frappe.syn_string);
    try std.testing.expectEqualStrings("\x1b[38;2;198;160;246m", Theme.macchiato.syn_keyword);
    try std.testing.expectEqualStrings("\x1b[38;2;166;218;149m", Theme.macchiato.syn_string);
}

test "the RGB table carries the vaxis REPL's chrome roles too, not just syntax" {
    // The vaxis REPL has no ANSI escape codes to read (it sets cell colours
    // directly), so a theme that only fills in syn_* here would leave the
    // box border, status/tool lines, and error text uncoloured no matter
    // what CLANKER_THEME says.
    const mocha_rgb = Theme.mocha.rgb.?;
    try std.testing.expectEqual(mocha_palette.overlay0, mocha_rgb.rule);
    try std.testing.expectEqual(mocha_palette.subtext0, mocha_rgb.dim);
    try std.testing.expectEqual(mocha_palette.blue, mocha_rgb.tool);
    try std.testing.expectEqual(mocha_palette.red, mocha_rgb.err);

    const night_rgb = Theme.tokyo_night.rgb.?;
    try std.testing.expectEqual(tokyo_night_palette.dark3, night_rgb.rule);
    try std.testing.expectEqual(tokyo_night_palette.comment, night_rgb.dim);
    try std.testing.expectEqual(tokyo_night_palette.blue, night_rgb.tool);
    try std.testing.expectEqual(tokyo_night_palette.red, night_rgb.err);

    try std.testing.expect(Theme.default.rgb == null);
    try std.testing.expect(Theme.mono.rgb == null);
}

test "select accepts every Catppuccin flavour by name" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try std.testing.expectEqualStrings(Theme.latte.syn_keyword, select("latte", &map).syn_keyword);
    try std.testing.expectEqualStrings(Theme.frappe.syn_keyword, select("frappe", &map).syn_keyword);
    try std.testing.expectEqualStrings(Theme.macchiato.syn_keyword, select("macchiato", &map).syn_keyword);
}

test "Tokyo Night uses tokyonight.nvim's own role assignment" {
    // Keyword = cyan, String = green, Constant = orange, straight from
    // lua/tokyonight/groups/base.lua rather than guessed by analogy.
    try std.testing.expectEqualStrings("\x1b[38;2;125;207;255m", Theme.tokyo_night.syn_keyword);
    try std.testing.expectEqualStrings("\x1b[38;2;158;206;106m", Theme.tokyo_night.syn_string);
    try std.testing.expectEqualStrings("\x1b[38;2;255;158;100m", Theme.tokyo_night.syn_number);
}

test "Tokyo Night Storm shares Night's foreground palette" {
    // Storm and Night differ only in background shade upstream; this Theme
    // has no background field, so the two are the same theme for text colour
    // purposes. Asserting the equality documents that on purpose, rather
    // than leaving it looking like an oversight.
    try std.testing.expectEqualStrings(Theme.tokyo_night.syn_keyword, Theme.tokyo_storm.syn_keyword);
    try std.testing.expectEqualStrings(Theme.tokyo_night.err, Theme.tokyo_storm.err);
}

test "Tokyo Night Day inverts the palette rather than lightening it" {
    try std.testing.expectEqualStrings("\x1b[38;2;0;113;151m", Theme.tokyo_day.syn_keyword);
    try std.testing.expectEqualStrings("\x1b[38;2;88;117;57m", Theme.tokyo_day.syn_string);
}

test "select accepts Tokyo Night and its variant aliases" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try std.testing.expectEqualStrings(Theme.tokyo_night.syn_keyword, select("tokyonight", &map).syn_keyword);
    try std.testing.expectEqualStrings(Theme.tokyo_storm.syn_keyword, select("storm", &map).syn_keyword);
    try std.testing.expectEqualStrings(Theme.tokyo_day.syn_keyword, select("day", &map).syn_keyword);
    try std.testing.expectEqualStrings(Theme.tokyo_day.syn_keyword, select("tokyonight-day", &map).syn_keyword);
}
