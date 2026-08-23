//! Print-once transcript elements: the streaming markdown renderer for the
//! assistant's prose, and bordered "cards" for tool calls. Nothing here is
//! redrawn, each element is written once and scrolls with the terminal, per
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
const width = @import("width.zig");
const theme_mod = @import("theme.zig");
const syntax = @import("syntax.zig");
const sanitize = @import("sanitize.zig");
const tool_out = @import("../util/tool_out.zig");
pub const Theme = theme_mod.Theme;

const strippedControl = sanitize.isControl;
const writeSanitized = sanitize.writeSanitized;

/// Renders markdown (bold, italic, inline code, fenced blocks, "- " bullets)
/// straight into ANSI as content streams in, one delta at a time. A marker
/// can split across two deltas (e.g. "**" arriving as two separate one-byte
/// chunks), so up to 2 bytes are held back whenever the tail of a chunk
/// could still be the start of a longer marker, and resolved once the next
/// chunk arrives.
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
    /// buffer are emitted unhighlighted (still control-stripped), a
    /// 4 KiB source line is a paste artifact, not something to color.
    fn emitFenceLine(self: *MdStream, w: *std.Io.Writer) void {
        const line = self.fence_line[0..self.fence_line_len];
        self.fence_line_len = 0;
        if (!self.syn_ready) {
            self.syn_ready = true;
            self.syn_state = syntax.State.init(self.fence_lang[0..self.fence_lang_len]);
            self.syn_style = syntax.Style.fromTheme(&self.theme);
        }
        // A 4096-byte line produces at most ~200 tokens (24 bytes each).
        // A stack-backed fixed buffer avoids the mmap/munmap syscalls that
        // page_allocator would do on every line of every fenced block.
        var fba_buf: [8192]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
        var toks: std.ArrayList(syntax.Token) = .empty;
        defer toks.deinit(fba.allocator());
        syntax.highlightLine(&self.syn_state, fba.allocator(), line, &toks) catch {
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
            // a fence. A control sequence (OSC ESC ] or CSI ESC [) is consumed
            // whole so its payload does not leak as visible text; a lone ESC is
            // a C0 control and drops. A sequence truncated at the end of this
            // chunk window is dropped too — it is escape machinery, not text.
            if (c == 0x1B) {
                if (i + 1 < total) {
                    const nxt = self.at(chunk, i + 1);
                    if (nxt == 0x5D or nxt == 0x5B) {
                        var j = i + 2;
                        while (j < total) {
                            const b = self.at(chunk, j);
                            if (nxt == 0x5D and (b == 0x07 or (b == 0x1B and j + 1 < total and self.at(chunk, j + 1) == 0x5C))) {
                                j += if (b == 0x07) 1 else 2;
                                break;
                            }
                            if (nxt == 0x5B) {
                                if (b >= 0x40 and b <= 0x7E) { // final byte
                                    j += 1;
                                    break;
                                }
                                if (b < 0x20 or b > 0x3F) break; // not a CSI byte
                            }
                            j += 1;
                        }
                        i = j;
                        continue;
                    }
                }
                i += 1; // lone ESC
                continue;
            }
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

// -------------------------------------------------------------- tool cards --
//
// The left-bar card from the module doc, as pure line builders. The vaxis
// REPL stores its transcript as plain strings and styles them into cells at
// draw time (no ANSI), so the card is built here as text, one place owns
// the shape and the sanitizing rules, and any surface that renders through
// strings reuses it instead of redrawing the style from memory.

/// The card glyphs: `╭─` opens, `│` rules the body, `╰─` closes. No right
/// edge, per the module doc: a left bar can't visually break no matter what
/// the tool printed.
pub const card_open = "\u{256d}\u{2500}";
pub const card_bar = "\u{2502}";
pub const card_close = "\u{2570}\u{2500}";

/// Byte cap on a card body preview: the agent's shared tool-args preview
/// budget (tool_out.args_preview_cap, also used by the confirm prompt and
/// the web stream). Enough of the arguments to judge the call, never all of
/// them, a whole file write would drown the transcript.
pub const card_preview_cap = tool_out.args_preview_cap;

/// One-line bounded preview of untrusted text for a card line. Controls are
/// dropped under the same rule writeSanitized enforces (CWE-150), except
/// that newline and tab each flatten to one space, a card line is one line
/// by construction. The cap cuts between code points, never through one (a
/// split code point is not a shorter preview but a malformed one), and a
/// cut is marked with "…".
pub fn cardPreview(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var truncated = false;
    var i: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        if (c == '\n' or c == '\t') {
            if (out.items.len >= card_preview_cap) {
                truncated = true;
                break;
            }
            try out.append(gpa, ' ');
            i += 1;
            continue;
        }
        // OSC sequences are consumed whole, matching writeSanitized and
        // sanitizeAlloc: stripping only the ESC byte leaves the payload visible.
        if (c == 0x1B and i + 1 < bytes.len and bytes[i + 1] == 0x5D) {
            var k = i + 2;
            while (k < bytes.len) {
                if (bytes[k] == 0x07) break;
                if (bytes[k] == 0x1B and k + 1 < bytes.len and bytes[k + 1] == 0x5C) {
                    k += 2;
                    break;
                }
                k += 1;
            }
            i = k;
            continue;
        }
        // CSI sequences are consumed whole too, matching writeSanitized:
        // stripping only the ESC byte would leak the parameter bytes.
        if (c == 0x1B and i + 1 < bytes.len and bytes[i + 1] == 0x5B) {
            i = sanitize.csiEnd(bytes, i);
            continue;
        }
        if (strippedControl(c)) {
            i += 1;
            continue;
        }
        if (c == 0xC2 and i + 1 < bytes.len and bytes[i + 1] >= 0x80 and bytes[i + 1] <= 0x9F) {
            i += 2;
            continue;
        }
        // Copy whole code points (an invalid lead byte passes through alone,
        // same as writeSanitized) so the cap check above never splits one.
        //
        // The claimed length is verified before the copy. Trusting it let a
        // lead byte carry the bytes after it past every control check above:
        // "\xE2\x1b[31m" copied `E2 1B 5B` whole and then printed `31m` as
        // prose, so a complete SGR sequence reached the terminal out of a
        // tool name or arguments the model chose — the CWE-150 hole this
        // function exists to close. Anything that is not the codepoint it
        // claims to be advances one byte and gets re-examined.
        const n: usize = std.unicode.utf8ByteSequenceLength(c) catch 1;
        const len: usize = if (n > 1 and i + n <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i .. i + n])) n else 1;
        if (out.items.len + len > card_preview_cap) {
            truncated = true;
            break;
        }
        try out.appendSlice(gpa, bytes[i .. i + len]);
        i += len;
    }
    if (truncated) {
        var omitted_lines: usize = 0;
        for (bytes[i..]) |b| {
            if (b == '\n') omitted_lines += 1;
        }
        if (omitted_lines > 0) {
            const marker = try std.fmt.allocPrint(gpa, "\u{2026} ({d} lines omitted)", .{omitted_lines});
            defer gpa.free(marker);
            try out.appendSlice(gpa, marker);
        } else {
            try out.appendSlice(gpa, "\u{2026}");
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The line naming a tool call: "╭─ ⚙ <name>" for the call that opens the
/// card, "│  ⚙ <name>" for the rest of its batch. A batch of parallel calls
/// shares one card because the agent reports one timing per batch (see
/// loop.zig's on_tool_result), per-call open corners would draw cards that
/// nothing ever closes. The name is untrusted (the model chose it), so it
/// takes the same preview pass as the body.
pub fn toolCardHeader(gpa: std.mem.Allocator, name: []const u8, first: bool) ![]u8 {
    const clean = try cardPreview(gpa, name);
    defer gpa.free(clean);
    if (first) return std.fmt.allocPrint(gpa, card_open ++ " \u{2699} {s}", .{clean});
    return std.fmt.allocPrint(gpa, card_bar ++ "  \u{2699} {s}", .{clean});
}

/// A card body line for the call's arguments: "│  <preview>". Null when
/// there is nothing worth a line, no arguments, or the no-argument call's
/// literal "{}", which says nothing the header didn't.
pub fn toolCardArgs(gpa: std.mem.Allocator, args: []const u8) !?[]u8 {
    const clean = try cardPreview(gpa, args);
    if (clean.len == 0 or std.mem.eql(u8, clean, "{}")) {
        gpa.free(clean);
        return null;
    }
    defer gpa.free(clean);
    return try std.fmt.allocPrint(gpa, card_bar ++ "  {s}", .{clean});
}

/// The closing line: "╰─ done in <N>ms", the same wording the plain status
/// line used, so logs and muscle memory carry over.
pub fn toolCardFooter(gpa: std.mem.Allocator, elapsed_ms: u64) ![]u8 {
    return std.fmt.allocPrint(gpa, card_close ++ " done in {d}ms", .{elapsed_ms});
}

/// True for lines produced by the card builders above, so a renderer that
/// styles stored lines after the fact (the vaxis REPL) can give card lines
/// the tool tint and a bar-preserving wrap without carrying extra state
/// alongside each line.
pub fn isToolCardLine(text: []const u8) bool {
    return std.mem.startsWith(u8, text, card_open) or
        std.mem.startsWith(u8, text, card_bar) or
        std.mem.startsWith(u8, text, card_close);
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
    try std.testing.expect(std.mem.find(u8, out, "\x1b[1;4mTitle") != null);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[1mSub") != null);
    try std.testing.expect(std.mem.find(u8, out, "# ") == null);
    // Quote gets a gutter, the rule becomes a line, list markers keep numbers.
    try std.testing.expect(std.mem.find(u8, out, "\u{2502} quoted") != null);
    try std.testing.expect(std.mem.find(u8, out, "\u{2500}\u{2500}\u{2500}") != null);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[36m1.\x1b[0m first") != null);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[36m2)\x1b[0m second") != null);
}

test "MdStream leaves fenced code untouched" {
    // Emphasis markers inside a code block are code, not markdown formatting.
    // Syntax highlighting may split the line with ANSI spans, so assert the
    // comment segment rather than requiring the whole source line to remain
    // one contiguous byte string.
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var md: MdStream = .{ .theme = Theme.mono };
    md.feed(&w, "```zig\nconst p: *u8 = x; // **not bold**\n```\nafter\n");
    md.flush(&w);
    const out = buf[0..w.end];

    try std.testing.expect(std.mem.find(u8, out, "// **not bold**") != null);
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

    try std.testing.expect(std.mem.find(u8, out, "python") == null);
    // The numeric token is coloured, so it sits between the surrounding
    // source fragments rather than leaving `print(1)` contiguous.
    try std.testing.expect(std.mem.find(u8, out, "print") != null);
    try std.testing.expect(std.mem.find(u8, out, "(") != null);
    try std.testing.expect(std.mem.find(u8, out, ")") != null);
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
    try std.testing.expect(std.mem.find(u8, buf[0..w.end], "\x1b") == null);
}

test "MdStream strips C0 controls and DEL from prose, keeping newline and tab" {
    const allocator = std.testing.allocator;
    // ESC [ 3 1 m is a CSI sequence and is consumed whole; the lone BEL,
    // NUL and DEL drop.
    const out = try mdStreamRender(allocator, &.{"a\x1b[31mb\x07c\x00d\x7fe\tf\ng"});
    defer allocator.free(out);
    try std.testing.expectEqualStrings("abcde\tf\ng", out);
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
    // The CSI sequence ESC [ 2 J is consumed whole even inside a fence, so
    // its parameter bytes never become visible text.
    try std.testing.expect(std.mem.find(u8, out, "xy") != null);
    try std.testing.expect(std.mem.find(u8, out, "[2J") == null);
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

test "cardPreview flattens newline and tab, strips controls, keeps short input" {
    const gpa = std.testing.allocator;
    // The newline/tab flatten, and the CSI sequence ESC [ 3 1 m is consumed
    // whole so its parameter bytes don't leak as "[31m"; DEL drops.
    const out = try cardPreview(gpa, "a\nb\tc\x1b[31md\x7f");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("a b cd", out);
}

test "cardPreview caps at the preview cap and marks the cut" {
    const gpa = std.testing.allocator;
    const out = try cardPreview(gpa, "x" ** 500);
    defer gpa.free(out);
    try std.testing.expectEqual(card_preview_cap + "\u{2026}".len, out.len);
    try std.testing.expect(std.mem.endsWith(u8, out, "\u{2026}"));
}

test "cardPreview never splits a code point at the cap" {
    const gpa = std.testing.allocator;
    // 399 ASCII bytes, then a 4-byte emoji that cannot fit: dropped whole.
    const out = try cardPreview(gpa, ("y" ** 399) ++ "\u{1F600}" ++ "z");
    defer gpa.free(out);
    try std.testing.expectEqualStrings(("y" ** 399) ++ "\u{2026}", out);
}

test "cardPreview strips C1 controls but keeps multi-byte codepoints" {
    const gpa = std.testing.allocator;
    // 0xC2 0x9B is U+009B (CSI), stripped; "©" (0xC2 0xA9) is text.
    const out = try cardPreview(gpa, "a\xc2\x9bb \xc2\xa9");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("ab \xc2\xa9", out);
}

test "tool card lines carry the left-bar shape and are recognizable" {
    const gpa = std.testing.allocator;
    const head = try toolCardHeader(gpa, "read_file", true);
    defer gpa.free(head);
    try std.testing.expectEqualStrings("\u{256d}\u{2500} \u{2699} read_file", head);

    const joined = try toolCardHeader(gpa, "list_dir", false);
    defer gpa.free(joined);
    try std.testing.expectEqualStrings("\u{2502}  \u{2699} list_dir", joined);

    const body = (try toolCardArgs(gpa, "{\"path\":\"a\"}")).?;
    defer gpa.free(body);
    try std.testing.expectEqualStrings("\u{2502}  {\"path\":\"a\"}", body);

    const foot = try toolCardFooter(gpa, 88);
    defer gpa.free(foot);
    try std.testing.expectEqualStrings("\u{2570}\u{2500} done in 88ms", foot);

    try std.testing.expect(isToolCardLine(head));
    try std.testing.expect(isToolCardLine(joined));
    try std.testing.expect(isToolCardLine(body));
    try std.testing.expect(isToolCardLine(foot));
    try std.testing.expect(!isToolCardLine("plain text"));
    try std.testing.expect(!isToolCardLine("\u{2699} old-style line"));
}

test "toolCardArgs skips empty and no-argument bodies" {
    const gpa = std.testing.allocator;
    try std.testing.expect((try toolCardArgs(gpa, "")) == null);
    try std.testing.expect((try toolCardArgs(gpa, "{}")) == null);
}

test "cardPreview strips OSC sequences whole" {
    const gpa = std.testing.allocator;
    const out = try cardPreview(gpa, "a\x1b]38;5;9\x07b");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("ab", out);
}

test "cardPreview strips CSI sequences whole" {
    const gpa = std.testing.allocator;
    const out = try cardPreview(gpa, "a\x1b[2Jb");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("ab", out);
}

test "cardPreview refuses an escape smuggled behind a UTF-8 lead byte" {
    const gpa = std.testing.allocator;
    // 0xE2 claims a three-byte codepoint; the two bytes it claims are ESC
    // and '['. Copying them on the lead byte's word skipped every control
    // check, so the whole SGR sequence reached the terminal.
    const out = try cardPreview(gpa, "\xE2\x1b[31mred");
    defer gpa.free(out);
    try std.testing.expect(std.mem.findScalar(u8, out, 0x1B) == null);
    try std.testing.expectEqualStrings("\xE2red", out);
    // A truncated codepoint at the end still passes through as bytes, and a
    // valid one is still copied whole.
    const cut = try cardPreview(gpa, "a\xE2\x82");
    defer gpa.free(cut);
    try std.testing.expectEqualStrings("a\xE2\x82", cut);
    const good = try cardPreview(gpa, "a\xE2\x82\xACb");
    defer gpa.free(good);
    try std.testing.expectEqualStrings("a\xE2\x82\xACb", good);
}

test "cardPreview strips OSC sequences (ST-terminated)" {
    const gpa = std.testing.allocator;
    const out = try cardPreview(gpa, "a\x1b]0;1\x1b\\b");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("ab", out);
}
