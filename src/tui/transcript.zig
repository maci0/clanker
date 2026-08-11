//! Print-once transcript elements: the streaming markdown renderer for the
//! assistant's prose, and bordered "cards" for tool calls. Nothing here is
//! redrawn — each element is written once and scrolls with the terminal, per
//! the fixed-region-compositor design (only the status bar + input box at
//! the bottom get diffed; see region.zig's doc comment for why).
//!
//! Cards use a left-bar style (`\u{256d}\u{2500}` open corner, `\u{2502}`
//! rule, `\u{2570}\u{2500}` close corner) rather than a full box with a
//! right-hand border: closing a right edge means padding every line to an
//! exact column count, which is one more place width math can drift for
//! wide/malformed input. A left bar reads just as much like a "card" and
//! can't visually break no matter what the tool printed.

const std = @import("std");
const types = @import("../llm/types.zig");
const width = @import("width.zig");
const theme_mod = @import("theme.zig");
const syntax = @import("../tui2/syntax.zig");
pub const Theme = theme_mod.Theme;

// -------------------------------------------------------- control stripping --
//
// Everything this file renders is text clanker didn't generate itself — LLM
// responses, tool output, peer chat received over HTTP — so a raw ESC byte in
// that text would otherwise print straight to the user's terminal (CWE-150,
// terminal injection). Control bytes are dropped at these chokepoints; the
// printable remainder of an escape sequence (e.g. the "[31m" after a stripped
// ESC) stays as inert visible text, which keeps the pass stateless instead of
// having to track CSI sequences across stream chunks. The ANSI clanker
// intentionally emits comes from Theme and is written around the sanitized
// text, never through it.

/// A C0 control or DEL that must not reach the terminal. `\n` stays (line
/// structure) and `\t` stays (layout, can't start an escape sequence).
fn strippedControl(c: u8) bool {
    return (c < 0x20 and c != '\n' and c != '\t') or c == 0x7F;
}

/// Writes `bytes` with C0 controls (except \n and \t), DEL, and UTF-8-encoded
/// C1 controls (0xC2 0x80..0x9F, i.e. U+0080..U+009F) removed. Bare
/// continuation bytes in that range are left alone — they are the tails of
/// legitimate multi-byte codepoints like "€" (0xE2 0x82 0xAC).
fn writeSanitized(w: *std.Io.Writer, bytes: []const u8) void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        if (strippedControl(bytes[i])) {
            if (i > start) w.writeAll(bytes[start..i]) catch {};
            i += 1;
            start = i;
        } else if (bytes[i] == 0xC2 and i + 1 < bytes.len and bytes[i + 1] >= 0x80 and bytes[i + 1] <= 0x9F) {
            if (i > start) w.writeAll(bytes[start..i]) catch {};
            i += 2;
            start = i;
        } else {
            i += 1;
        }
    }
    if (start < bytes.len) w.writeAll(bytes[start..]) catch {};
}

/// Renders the same markdown subset as the `format` WASM tool (bold, italic,
/// inline code, fenced blocks, "- " bullets) straight into ANSI as content
/// streams in, one delta at a time. A marker can split across two deltas
/// (e.g. "**" arriving as two separate one-byte chunks), so up to 2 bytes
/// are held back whenever the tail of a chunk could still be the start of a
/// longer marker, and resolved once the next chunk arrives.
pub const MdStream = struct {
    theme: Theme = Theme.default,
    in_fence: bool = false,
    /// True for the language tag right after an opening fence (e.g. the
    /// "python" in "```python\n"), which is consumed and never printed.
    in_fence_lang: bool = false,
    in_bold: bool = false,
    in_italic: bool = false,
    in_code: bool = false,
    /// Styling opened by a line construct (heading, quote) and closed at the
    /// newline that ends it.
    line_style: bool = false,
    at_line_start: bool = true,
    /// Longest marker needing lookahead: "###### " (7 bytes).
    hold: [7]u8 = undefined,
    hold_len: usize = 0,
    /// Fence language tag ("zig" in ```zig), collected while in_fence_lang
    /// and handed to the highlighter when the fence opens. 16 bytes covers
    /// every tag an LLM realistically emits; longer ones just highlight
    /// less precisely (truncation never breaks rendering).
    fence_lang: [16]u8 = undefined,
    fence_lang_len: usize = 0,
    /// Highlighter state for the open fence, initialized (from fence_lang)
    /// on the first line of the fence body. syn_ready tracks that init so
    /// `syn_state` can stay undefined until then.
    syn_state: syntax.State = undefined,
    syn_style: syntax.Style = .{ .keyword = "", .string = "", .comment = "", .number = "", .builtin = "", .preproc = "", .reset = "" },
    syn_ready: bool = false,
    /// The current fenced line accumulates here and is emitted (highlighted)
    /// on its newline, so tokens spanning write calls still color correctly.
    fence_line: [4096]u8 = undefined,
    fence_line_len: usize = 0,

    fn at(self: *const MdStream, chunk: []const u8, idx: usize) u8 {
        return if (idx < self.hold_len) self.hold[idx] else chunk[idx - self.hold_len];
    }

    /// Bytes from `i` that are the same character `c`, capped at `max`.
    fn runOf(self: *const MdStream, chunk: []const u8, i: usize, total: usize, c: u8, max: usize) usize {
        var n: usize = 0;
        while (i + n < total and n < max and self.at(chunk, i + n) == c) n += 1;
        return n;
    }

    /// Emits the accumulated fence line through the syntax highlighter,
    /// initialized on first use from fence_lang. Lines longer than the
    /// buffer are emitted unhighlighted (still control-stripped) — a
    /// 4 KiB source line is a paste artifact, not something to color.
    fn emitFenceLine(self: *MdStream, w: *std.Io.Writer) void {
        const line = self.fence_line[0..self.fence_line_len];
        self.fence_line_len = 0;
        if (!self.syn_ready) {
            self.syn_ready = true;
            self.syn_state = syntax.State.init(self.fence_lang[0..self.fence_lang_len]);
            self.syn_style = syntax.Style.fromTheme(&self.theme);
        }
        var toks: std.ArrayList(syntax.Token) = .empty;
        defer toks.deinit(std.heap.page_allocator);
        syntax.highlightLine(&self.syn_state, std.heap.page_allocator, line, &toks) catch {
            // OOM: fall back to the same plain-but-sanitized path the
            // pre-highlighting renderer used. Never lose the line.
            writeSanitized(w, line);
            return;
        };
        syntax.emit(w, &self.syn_style, toks.items);
    }

    pub fn feed(self: *MdStream, w: *std.Io.Writer, chunk: []const u8) void {
        const t = &self.theme;
        const total = self.hold_len + chunk.len;
        var i: usize = 0;
        while (i < total) {
            const remaining = total - i;
            const c = self.at(chunk, i);

            // The language tag right after an opening fence (e.g. "python")
            // is consumed, not printed: it names the block, it isn't code.
            // It is remembered in fence_lang so the body can be highlighted.
            if (self.in_fence_lang) {
                if (c != '\n' and c != ' ' and c != '\r' and self.fence_lang_len < self.fence_lang.len) {
                    self.fence_lang[self.fence_lang_len] = c;
                    self.fence_lang_len += 1;
                }
                self.in_fence_lang = (c != '\n');
                self.at_line_start = (c == '\n');
                i += 1;
                continue;
            }

            // Untrusted control bytes never reach the terminal, in or out of
            // a fence. A lone 0xC2 at the chunk boundary is held back like a
            // split marker: the next chunk decides if it completes a C1.
            if (strippedControl(c)) {
                i += 1;
                continue;
            }
            if (c == 0xC2) {
                if (remaining < 2) break;
                if (self.at(chunk, i + 1) >= 0x80 and self.at(chunk, i + 1) <= 0x9F) {
                    i += 2;
                    continue;
                }
            }

            // Inside a fence everything is literal: a code block full of *,
            // _ and ` must not toggle emphasis on its way to the terminal.
            // The body is syntax-highlighted per line (see emitFenceLine).
            if (self.in_fence) {
                if (c == '`' and self.fence_line_len == 0) {
                    if (remaining < 3) break;
                    if (self.at(chunk, i + 1) == '`' and self.at(chunk, i + 2) == '`') {
                        self.in_fence = false;
                        w.writeAll(t.reset) catch {};
                        i += 3;
                        self.at_line_start = false;
                        continue;
                    }
                }
                if (c == '\n') {
                    self.emitFenceLine(w);
                    w.writeAll("\n") catch {};
                    self.at_line_start = true;
                    i += 1;
                    continue;
                }
                if (self.fence_line_len < self.fence_line.len) {
                    self.fence_line[self.fence_line_len] = c;
                    self.fence_line_len += 1;
                }
                self.at_line_start = false;
                i += 1;
                continue;
            }

            // ---- line-start constructs ----
            if (self.at_line_start) {
                // Heading: "# " .. "###### ". Rendered by weight, not by
                // repeating the hashes back at the reader.
                if (c == '#') {
                    const hashes = self.runOf(chunk, i, total, '#', 6);
                    if (i + hashes >= total) break; // need the char after them
                    if (hashes <= 6 and self.at(chunk, i + hashes) == ' ') {
                        w.writeAll(if (hashes == 1) t.heading1 else t.heading) catch {};
                        self.line_style = true;
                        i += hashes + 1;
                        self.at_line_start = false;
                        continue;
                    }
                }
                // Horizontal rule: a line of --- or ***.
                if (c == '-' or c == '*') {
                    const rule_run = self.runOf(chunk, i, total, c, 4);
                    if (rule_run >= 3) {
                        if (i + rule_run >= total) break; // the line may continue
                        if (self.at(chunk, i + rule_run) == '\n') {
                            w.writeAll(t.rule) catch {};
                            w.writeAll("\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80") catch {};
                            w.writeAll(t.reset) catch {};
                            i += rule_run;
                            continue;
                        }
                    }
                }
                // Block quote.
                if (c == '>') {
                    if (remaining < 2) break;
                    if (self.at(chunk, i + 1) == ' ') {
                        w.writeAll(t.quote) catch {};
                        w.writeAll("\xe2\x94\x82 ") catch {};
                        self.line_style = true;
                        i += 2;
                        self.at_line_start = false;
                        continue;
                    }
                }
                // Ordered list: "1. " / "1) ", marker in cyan.
                if (c >= '0' and c <= '9') {
                    var d: usize = 0;
                    while (i + d < total and d < 3 and self.at(chunk, i + d) >= '0' and self.at(chunk, i + d) <= '9') d += 1;
                    if (i + d + 1 >= total) break;
                    const sep = self.at(chunk, i + d);
                    if ((sep == '.' or sep == ')') and self.at(chunk, i + d + 1) == ' ') {
                        w.writeAll(t.list_num) catch {};
                        var k: usize = 0;
                        while (k < d) : (k += 1) w.writeAll(&[_]u8{self.at(chunk, i + k)}) catch {};
                        w.writeAll(&[_]u8{sep}) catch {};
                        w.writeAll(t.reset) catch {};
                        w.writeAll(" ") catch {};
                        i += d + 2;
                        self.at_line_start = false;
                        continue;
                    }
                }
                // Bullet: "- " or "* ".
                if (c == '-' or c == '*') {
                    if (remaining < 2) break;
                    if (self.at(chunk, i + 1) == ' ') {
                        w.writeAll("\xe2\x80\xa2 ") catch {};
                        i += 2;
                        self.at_line_start = false;
                        continue;
                    }
                }
            }

            // ---- inline constructs ----
            if (c == '`' and remaining < 3) break; // could still become ```
            if (c == '`' and self.at(chunk, i + 1) == '`' and self.at(chunk, i + 2) == '`') {
                self.in_fence = true;
                self.in_fence_lang = true;
                self.fence_lang_len = 0;
                self.fence_line_len = 0;
                self.syn_ready = false;
                w.writeAll(t.fence) catch {};
                i += 3;
                self.at_line_start = false;
                continue;
            }
            if (c == '*' and remaining < 2) break; // could still become **
            if (c == '*' and self.at(chunk, i + 1) == '*') {
                self.in_bold = !self.in_bold;
                w.writeAll(if (self.in_bold) t.bold else t.reset) catch {};
                i += 2;
                self.at_line_start = false;
                continue;
            }
            if (c == '`') {
                self.in_code = !self.in_code;
                w.writeAll(if (self.in_code) t.code else t.reset) catch {};
                i += 1;
                self.at_line_start = false;
                continue;
            }
            if (c == '*') {
                self.in_italic = !self.in_italic;
                w.writeAll(if (self.in_italic) t.italic else t.reset) catch {};
                i += 1;
                self.at_line_start = false;
                continue;
            }

            // A heading or quote's styling ends with its line.
            if (c == '\n' and self.line_style) {
                w.writeAll(t.reset) catch {};
                self.line_style = false;
            }
            w.writeAll(&[_]u8{c}) catch {};
            self.at_line_start = (c == '\n');
            i += 1;
        }
        const left = total - i;
        var j: usize = 0;
        while (j < left) : (j += 1) self.hold[j] = self.at(chunk, i + j);
        self.hold_len = left;
    }

    /// Flushes any still-held bytes as literal text (no more input is
    /// coming, so a trailing lone "*" or "`" was never a real marker) and
    /// closes any formatting left open, then resets for the next turn
    /// (keeping the theme it was constructed with).
    pub fn flush(self: *MdStream, w: *std.Io.Writer) void {
        if (self.hold_len > 0) {
            // Held bytes can carry a control that arrived right behind a
            // possible marker at a chunk end; they get the same stripping
            // they'd have gotten had more input resolved the marker.
            writeSanitized(w, self.hold[0..self.hold_len]);
        }
        // An unterminated fence's last partial line still deserves its
        // highlight pass rather than being dropped on the floor.
        if (self.in_fence and self.fence_line_len > 0) self.emitFenceLine(w);
        if (self.in_code) w.writeAll(self.theme.reset) catch {};
        if (self.in_italic) w.writeAll(self.theme.reset) catch {};
        if (self.in_bold) w.writeAll(self.theme.reset) catch {};
        if (self.in_fence) w.writeAll(self.theme.reset) catch {};
        if (self.line_style) w.writeAll(self.theme.reset) catch {};
        const kept_theme = self.theme;
        self.* = .{ .theme = kept_theme };
    }
};

// --------------------------------------------------------------- tool cards --

/// A card's args preview and result body wrap at this width regardless of
/// how wide the terminal is — an 80-column-ish card reads better than one
/// stretched edge-to-edge on a wide monitor.
pub const max_card_width: usize = 96;
/// A result body longer than this many lines is truncated: a card is a
/// glance at what happened, not a pager for a tool's full output.
pub const max_body_lines: usize = 6;

fn cardWidth(cols: usize) usize {
    return @min(cols, max_card_width);
}

/// Opens a tool-call card: `╭─ ⚙ tool_name  {truncated args}`.
pub fn printCallCard(w: *std.Io.Writer, theme: *const Theme, tool_name: []const u8, args_json: []const u8, cols: usize) void {
    const cw = cardWidth(cols);
    w.writeAll(theme.tool) catch {};
    w.writeAll("\xe2\x95\xad\xe2\x94\x80 \xe2\x9a\x99 ") catch {};
    w.writeAll(tool_name) catch {};
    w.writeAll(theme.reset) catch {};
    if (args_json.len > 0 and !std.mem.eql(u8, args_json, "{}")) {
        const budget = if (cw > tool_name.len + 8) cw - tool_name.len - 8 else 20;
        w.writeAll(theme.dim) catch {};
        w.writeAll("  ") catch {};
        writeSanitized(w, width.truncateToWidth(args_json, budget));
        w.writeAll(theme.reset) catch {};
    }
    w.writeAll("\n") catch {};
}

/// Prints one tool's result inside its card, truncated to `max_body_lines`
/// rows and `cols` width. `result_json` is the raw JSON the tool returned
/// (or null if it produced nothing) — shown as-is rather than reformatted,
/// matching how the args preview already treats raw JSON as the display
/// text rather than something to parse and re-render.
pub fn printResultBody(w: *std.Io.Writer, theme: *const Theme, result_json: ?[]const u8, cols: usize) void {
    const text = result_json orelse return;
    if (text.len == 0) return;
    const cw = cardWidth(cols);
    const budget = if (cw > 4) cw - 4 else 20;
    var it = std.mem.splitScalar(u8, text, '\n');
    var shown: usize = 0;
    while (it.next()) |line| {
        if (shown >= max_body_lines) {
            w.writeAll(theme.dim) catch {};
            w.writeAll("\xe2\x94\x82  \xe2\x80\xa6") catch {};
            w.writeAll(theme.reset) catch {};
            w.writeAll("\n") catch {};
            return;
        }
        w.writeAll(theme.dim) catch {};
        w.writeAll("\xe2\x94\x82  ") catch {};
        writeSanitized(w, width.truncateToWidth(line, budget));
        w.writeAll(theme.reset) catch {};
        w.writeAll("\n") catch {};
        shown += 1;
    }
}

/// Closes a tool-call card: `╰─ done in {ms}ms`.
pub fn printCardFooter(w: *std.Io.Writer, theme: *const Theme, elapsed_ms: u64) void {
    w.writeAll(theme.dim) catch {};
    var buf: [32]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "\xe2\x95\xb0\xe2\x94\x80 done in {d}ms", .{elapsed_ms}) catch return;
    w.writeAll(line) catch {};
    w.writeAll(theme.reset) catch {};
    w.writeAll("\n") catch {};
}

// ------------------------------------------------------------------- tests --

fn mdStreamRender(allocator: std.mem.Allocator, chunks: []const []const u8) ![]u8 {
    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    var md: MdStream = .{};
    for (chunks) |c| md.feed(&w.writer, c);
    md.flush(&w.writer);
    return allocator.dupe(u8, w.written());
}

test "MdStream renders bold, italic, inline code, and bullets" {
    const allocator = std.testing.allocator;
    const out = try mdStreamRender(allocator, &.{"**bold** *italic* `code` and:\n- one\n- two"});
    defer allocator.free(out);
    try std.testing.expectEqualStrings(
        "\x1b[1mbold\x1b[0m \x1b[3mitalic\x1b[0m \x1b[36mcode\x1b[0m and:\n\xe2\x80\xa2 one\n\xe2\x80\xa2 two",
        out,
    );
}

test "MdStream resolves a marker split across two feeds" {
    const allocator = std.testing.allocator;
    // "**bold**" fed one byte at a time must match the whole-chunk render.
    var chunks: [8][]const u8 = undefined;
    const text = "**bold**";
    for (text, 0..) |_, i| chunks[i] = text[i .. i + 1];
    const out = try mdStreamRender(allocator, &chunks);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("\x1b[1mbold\x1b[0m", out);
}

test "MdStream flushes a trailing unterminated marker as literal text" {
    const allocator = std.testing.allocator;
    const out = try mdStreamRender(allocator, &.{"looks like a footnote*"});
    defer allocator.free(out);
    try std.testing.expectEqualStrings("looks like a footnote*", out);
}

test "MdStream only treats a leading dash-space as a bullet at line start" {
    const allocator = std.testing.allocator;
    const out = try mdStreamRender(allocator, &.{"a - b\n- c"});
    defer allocator.free(out);
    try std.testing.expectEqualStrings("a - b\n\xe2\x80\xa2 c", out);
}

test "MdStream renders headings, rules, quotes and ordered lists" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var md: MdStream = .{};
    md.feed(&w, "# Title\nbody\n## Sub\n> quoted\n---\n1. first\n2) second\n");
    md.flush(&w);
    const out = buf[0..w.end];

    // Headings are styled, and the hashes themselves are not echoed.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1;4mTitle") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1mSub") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# ") == null);
    // Quote gets a gutter, the rule becomes a line, list markers keep numbers.
    try std.testing.expect(std.mem.indexOf(u8, out, "\u{2502} quoted") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\u{2500}\u{2500}\u{2500}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[36m1.\x1b[0m first") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[36m2)\x1b[0m second") != null);
}

test "MdStream leaves fenced code untouched" {
    // Emphasis markers inside a code block are code, not formatting: toggling
    // on them corrupted every snippet containing * or `.
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var md: MdStream = .{ .theme = Theme.mono };
    md.feed(&w, "```zig\nconst p: *u8 = x; // **not bold**\n```\nafter\n");
    md.flush(&w);
    const out = buf[0..w.end];

    try std.testing.expect(std.mem.indexOf(u8, out, "const p: *u8 = x; // **not bold**") != null);
    // And the fence closes, so following text is not left dim.
    try std.testing.expect(std.mem.endsWith(u8, out, "after\n"));
}

test "MdStream consumes the fence language tag instead of printing it" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var md: MdStream = .{ .theme = Theme.mono };
    md.feed(&w, "```python\nprint(1)\n```\n");
    md.flush(&w);
    const out = buf[0..w.end];

    try std.testing.expect(std.mem.indexOf(u8, out, "python") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "print(1)") != null);
}

test "MdStream does not mistake a hyphen mid-sentence for a rule" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var md: MdStream = .{};
    md.feed(&w, "well-known --- inline\n");
    md.flush(&w);
    try std.testing.expectEqualStrings("well-known --- inline\n", buf[0..w.end]);
}

test "MdStream under the mono theme emits no ANSI codes at all" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var md: MdStream = .{ .theme = Theme.mono };
    md.feed(&w, "**bold** `code` # heading\n");
    md.flush(&w);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..w.end], "\x1b") == null);
}

test "MdStream strips C0 controls and DEL from prose, keeping newline and tab" {
    const allocator = std.testing.allocator;
    // The ESC is dropped; the "[31m" behind it survives as inert text.
    const out = try mdStreamRender(allocator, &.{"a\x1b[31mb\x07c\x00d\x7fe\tf\ng"});
    defer allocator.free(out);
    try std.testing.expectEqualStrings("a[31mb" ++ "c" ++ "d" ++ "e\tf\ng", out);
}

test "MdStream strips controls inside a fence too" {
    const allocator = std.testing.allocator;
    var w: std.Io.Writer.Allocating = .init(allocator);
    defer w.deinit();
    var md: MdStream = .{ .theme = Theme.mono };
    md.feed(&w.writer, "```\nx\x1b[2Jy\n```\n");
    md.flush(&w.writer);
    const out = try allocator.dupe(u8, w.written());
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "x[2Jy") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[2J") == null);
}

test "MdStream strips C1 controls but keeps multi-byte codepoints intact" {
    const allocator = std.testing.allocator;
    // 0xC2 0x9B is U+009B (CSI), stripped; "©" (0xC2 0xA9) and "€"
    // (0xE2 0x82 0xAC, whose middle byte falls in 0x80..0x9F) are text.
    const out = try mdStreamRender(allocator, &.{"a\xc2\x9bb \xc2\xa9 \xe2\x82\xac"});
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ab \xc2\xa9 \xe2\x82\xac", out);
}

test "MdStream strips a C1 control split across two feeds" {
    const allocator = std.testing.allocator;
    const out = try mdStreamRender(allocator, &.{ "a\xc2", "\x9bb" });
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ab", out);
}

test "MdStream strips a control held back behind an unresolved marker" {
    const allocator = std.testing.allocator;
    // The chunk ends while "`\x1b" could still become a fence, so both bytes
    // are held; flush must not write the ESC out raw.
    const out = try mdStreamRender(allocator, &.{"x`\x1b"});
    defer allocator.free(out);
    try std.testing.expectEqualStrings("x`", out);
}

test "printCallCard shows the tool name and a truncated args preview" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    printCallCard(&out.writer, &Theme.default, "read_file", "{\"path\":\"src/main.zig\"}", 80);
    const bytes = out.written();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "src/main.zig") != null);
}

test "printCallCard omits the preview for empty or trivial args" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    printCallCard(&out.writer, &Theme.default, "calculator", "{}", 80);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "{}") == null);
}

test "printCallCard under mono theme emits no ANSI codes" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    printCallCard(&out.writer, &Theme.mono, "read_file", "{\"path\":\"x\"}", 80);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b") == null);
}

test "printResultBody truncates past max_body_lines" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    printResultBody(&out.writer, &Theme.default, "1\n2\n3\n4\n5\n6\n7\n8\n", 80);
    const bytes = out.written();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "7") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\xe2\x80\xa6") != null);
}

test "printResultBody is a no-op for a null or empty result" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    printResultBody(&out.writer, &Theme.default, null, 80);
    printResultBody(&out.writer, &Theme.default, "", 80);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "printResultBody strips control bytes from tool output" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    printResultBody(&out.writer, &Theme.mono, "x\x1b[2Jy\r\nnext\x07line\n", 80);
    const bytes = out.written();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "x[2Jy") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "nextline") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b") == null);
}

test "printCallCard strips control bytes from the args preview" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    printCallCard(&out.writer, &Theme.mono, "exec", "{\"cmd\":\"\x1b]0;owned\x07\"}", 80);
    const bytes = out.written();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "]0;owned") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b") == null);
}

test "printCardFooter reports elapsed time" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    printCardFooter(&out.writer, &Theme.default, 42);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "42ms") != null);
}
