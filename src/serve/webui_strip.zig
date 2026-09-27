//! Comment stripping for the bytes `clanker serve` puts on the wire.
//!
//! The web UI's source is heavily commented, and the comments are the reason
//! the modules read the way they do: what each gate pins, what a number means,
//! why a request exists. gzip hides much of that (English prose compresses to
//! about a third of its size), but a third of 59 KB of `app.js` comments is
//! still ~20 KB of the 77 KB gz every visitor downloads before the page can
//! run, and the same ratio holds across the eager module set: comments are
//! roughly a quarter of the first paint. They are read by whoever edits the
//! file, never by the browser.
//!
//! So the repo keeps its comments and the wire does not get them. The strip
//! runs once per asset per process, in front of the render cache's output
//! (see `renderWebuiCached` in `src/cli.zig`), so the bytes that are hashed
//! into the ETag, counted into `Content-Length` and fed to the gzip cache are
//! the stripped ones: the browser can never see a comment, and a rebuild that
//! only edits a comment changes nothing on the wire.
//!
//! Safety rules, in order of how much damage a mistake would do:
//!
//!   * A comment is replaced by a space, never by nothing, so two tokens that
//!     were separated by it stay separated (`a/*x*/in b` is not `ain b`).
//!   * A line comment keeps its newline: `return // note` must not become
//!     `return` followed by the next line, which is a different program.
//!   * A block comment spanning lines collapses to a newline, because a
//!     newline can terminate a statement (`return /* \n */ x` returns).
//!   * A string or regex literal that is not closed before its line ends is
//!     not treated as one: the opening quote is emitted as ordinary code and
//!     scanning continues. A misread regex can then cost at most the rest of
//!     its own line, and a misread division deletes nothing at all.
//!   * A template literal is scanned as a template, substitutions and all, so
//!     a `//` inside one is text rather than the start of a comment that would
//!     eat the rest of the line.
//!   * Anything that fails to scan cleanly returns the input untouched, so a
//!     future syntax the scanner does not model degrades to today's bytes
//!     rather than to a broken page.

const std = @import("std");

pub const Lang = enum { js, css, html };

/// Stripped copy of `body` in `arena`, or `body` itself when the scan decided
/// it could not speak for the result. The returned slice is valid for the
/// arena passed in.
pub fn strip(lang: Lang, arena: std.mem.Allocator, body: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(arena, body.len) catch return body;
    const scanned = switch (lang) {
        .js => scanJs(arena, body, &out),
        .css => scanCss(arena, body, &out),
        .html => scanHtml(arena, body, &out),
    };
    if (!scanned or out.items.len > body.len) return body;
    // Exact-size slice, not the over-reserved buffer: callers free what they
    // are given, and an allocator is entitled to refuse a length that does not
    // match the allocation.
    return out.toOwnedSlice(arena) catch body;
}

// -- JavaScript -------------------------------------------------------------

/// What the last significant token produced, which is what decides whether a
/// `/` divides or opens a regex.
const Sig = enum { none, value, op };

const Frame = enum {
    /// Inside the text of a template literal, between `` ` `` and the next
    /// `` ` `` or `${`.
    template,
    /// Inside a `${ ... }` substitution, with the brace depth counted so the
    /// `}` that ends it is not read as a block.
    subst,
};

/// True when a `/` here opens a regex literal rather than dividing. Division
/// follows something that produced a value (an identifier, a number, a
/// literal, a closed `)`/`]`); a regex follows an operator, an opening
/// bracket, a comma, or a statement boundary. `}` is a boundary because it
/// almost always closes a block, and a block is followed by a statement.
fn regexAllowed(prev: Sig, word: []const u8) bool {
    if (prev == .value) return false;
    return !std.mem.eql(u8, word, "this") and
        !std.mem.eql(u8, word, "true") and
        !std.mem.eql(u8, word, "false") and
        !std.mem.eql(u8, word, "null") and
        !std.mem.eql(u8, word, "super");
}

fn identAt(body: []const u8, i: usize) ?[]const u8 {
    const c = body[i];
    if (!(std.ascii.isAlphabetic(c) or c == '_' or c == '$')) return null;
    var j = i + 1;
    while (j < body.len) {
        const d = body[j];
        if (std.ascii.isAlphanumeric(d) or d == '_' or d == '$') {
            j += 1;
        } else break;
    }
    return body[i..j];
}

fn scanJs(arena: std.mem.Allocator, body: []const u8, out: *std.ArrayList(u8)) bool {
    var frames: std.ArrayList(Frame) = .empty;
    var prev: Sig = .none;
    var word: []const u8 = "";
    // Open `{` depth per substitution frame; the value is the depth inside
    // the innermost substitution.
    var depth: usize = 0;
    var i: usize = 0;
    while (i < body.len) {
        if (frames.items.len > 0 and frames.items[frames.items.len - 1] == .template) {
            const c = body[i];
            if (c == '`') {
                _ = frames.pop();
                out.append(arena, c) catch return false;
                prev = .value;
                word = "";
                i += 1;
                continue;
            }
            if (c == '\\') {
                const end = @min(i + 2, body.len);
                out.appendSlice(arena, body[i..end]) catch return false;
                i = end;
                continue;
            }
            if (c == '$' and i + 1 < body.len and body[i + 1] == '{') {
                frames.append(arena, .subst) catch return false;
                depth = 0;
                prev = .none;
                word = "";
                out.appendSlice(arena, "${") catch return false;
                i += 2;
                continue;
            }
            const next = std.mem.indexOfAny(u8, body[i..], "`\\$") orelse body.len - i;
            out.appendSlice(arena, body[i .. i + next]) catch return false;
            i += next;
            continue;
        }

        const c = body[i];
        switch (c) {
            '/' => {
                if (i + 1 < body.len and body[i + 1] == '/') {
                    while (i < body.len and body[i] != '\n') i += 1;
                    continue;
                }
                if (i + 1 < body.len and body[i + 1] == '*') {
                    var j = i + 2;
                    var multiline = false;
                    while (j + 1 < body.len) : (j += 1) {
                        if (body[j] == '\n') multiline = true;
                        if (body[j] == '*' and body[j + 1] == '/') break;
                    }
                    if (j + 1 >= body.len) return false;
                    out.append(arena, if (multiline) '\n' else ' ') catch return false;
                    prev = .op;
                    word = "";
                    i = j + 2;
                    continue;
                }
                if (regexAllowed(prev, word)) {
                    const end = regexEnd(body, i + 1) orelse {
                        // Not a regex after all: emit the slash as code and let
                        // the next step decide what it was. Nothing is lost.
                        out.append(arena, '/') catch return false;
                        prev = .op;
                        word = "";
                        i += 1;
                        continue;
                    };
                    out.appendSlice(arena, body[i..end]) catch return false;
                    prev = .value;
                    word = "";
                    i = end;
                    continue;
                }
                out.append(arena, '/') catch return false;
                prev = .op;
                word = "";
                i += 1;
            },
            '`', '\'', '"' => {
                if (c == '`') {
                    // Opening a template: the text after it is not code, and a
                    // `//` in it must stay text.
                    frames.append(arena, .template) catch return false;
                    out.append(arena, c) catch return false;
                    prev = .value;
                    word = "";
                    i += 1;
                    continue;
                }
                const end = stringEnd(body, i, c) orelse {
                    out.append(arena, c) catch return false;
                    prev = .op;
                    word = "";
                    i += 1;
                    continue;
                };
                out.appendSlice(arena, body[i..end]) catch return false;
                prev = .value;
                word = "";
                i = end;
            },
            '{' => {
                if (frames.items.len > 0 and frames.items[frames.items.len - 1] == .subst) depth += 1;
                out.append(arena, c) catch return false;
                prev = .op;
                word = "";
                i += 1;
            },
            '}' => {
                if (frames.items.len > 0 and frames.items[frames.items.len - 1] == .subst) {
                    if (depth == 0) {
                        _ = frames.pop();
                        out.append(arena, '}') catch return false;
                        i += 1;
                        continue;
                    }
                    depth -= 1;
                }
                out.append(arena, c) catch return false;
                prev = .op;
                word = "";
                i += 1;
            },
            ')', ']' => {
                out.append(arena, c) catch return false;
                prev = .value;
                word = "";
                i += 1;
            },
            ' ', '\t', '\r', '\n' => {
                out.append(arena, c) catch return false;
                i += 1;
            },
            else => {
                if (identAt(body, i)) |id| {
                    out.appendSlice(arena, id) catch return false;
                    word = id;
                    prev = if (regexAllowed(.op, id)) .op else .value;
                    i += id.len;
                    continue;
                }
                if (std.ascii.isDigit(c)) {
                    const start = i;
                    while (i < body.len and (std.ascii.isAlphanumeric(body[i]) or body[i] == '.' or body[i] == '_')) i += 1;
                    out.appendSlice(arena, body[start..i]) catch return false;
                    prev = .value;
                    word = "";
                    continue;
                }
                out.append(arena, c) catch return false;
                prev = .op;
                word = "";
                i += 1;
            },
        }
    }
    // A template or substitution left open means the scanner lost track, and
    // everything after that point was read in the wrong mode.
    return frames.items.len == 0;
}

/// End of the single- or double-quoted literal opening at `start`, or null
/// when it is not closed on its line. An escape always consumes the next byte,
/// so `\"` never ends the literal.
fn stringEnd(body: []const u8, start: usize, quote: u8) ?usize {
    var i = start + 1;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == '\\') {
            i += 1;
            continue;
        }
        if (c == '\n') return null;
        if (c == quote) return i + 1;
    }
    return null;
}

/// End of the regex literal whose body starts at `start`, or null when there
/// is no closing `/` on this line.
fn regexEnd(body: []const u8, start: usize) ?usize {
    var i = start;
    var in_class = false;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == '\\') {
            i += 1;
            continue;
        }
        if (c == '\n') return null;
        if (in_class) {
            if (c == ']') in_class = false;
            continue;
        }
        if (c == '[') in_class = true;
        if (c == '/') {
            var j = i + 1;
            while (j < body.len and std.ascii.isAlphabetic(body[j])) j += 1;
            return j;
        }
    }
    return null;
}

// -- CSS --------------------------------------------------------------------

/// Comments are the only construct a CSS comment can hide inside, so the scan
/// tracks `'` and `"` (which appear in `content:` and `url()`) and nothing
/// else. A `/*` that opens but never closes ends the scan, and the caller
/// keeps the original bytes.
fn scanCss(arena: std.mem.Allocator, body: []const u8, out: *std.ArrayList(u8)) bool {
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '/' and i + 1 < body.len and body[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, body, i + 2, "*/") orelse return false;
            var multiline = false;
            for (body[i..end]) |d| {
                if (d == '\n') multiline = true;
            }
            out.append(arena, if (multiline) '\n' else ' ') catch return false;
            i = end + 2;
            continue;
        }
        if (c == '\'' or c == '"') {
            const end = stringEnd(body, i, c) orelse return false;
            out.appendSlice(arena, body[i..end]) catch return false;
            i = end;
            continue;
        }
        out.append(arena, c) catch return false;
        i += 1;
    }
    return true;
}

// -- HTML -------------------------------------------------------------------

/// `<!-- ... -->` in the markup. `script` and `style` bodies are the one
/// place a `<!--` is not a comment, and the shipped page has no inline script
/// or style: its CSP is `script-src 'self'` with no `'unsafe-inline'`, which
/// is what `preact-boot.js` exists for. `htmlCommentFree` pins that.
fn scanHtml(arena: std.mem.Allocator, body: []const u8, out: *std.ArrayList(u8)) bool {
    var i: usize = 0;
    while (i < body.len) {
        const at = std.mem.indexOfPos(u8, body, i, "<!--") orelse {
            out.appendSlice(arena, body[i..]) catch return false;
            return true;
        };
        const end = std.mem.indexOfPos(u8, body, at + 4, "-->") orelse {
            out.appendSlice(arena, body[i..]) catch return false;
            return true;
        };
        out.appendSlice(arena, body[i..at]) catch return false;
        var multiline = false;
        for (body[at + 4 .. end]) |d| {
            if (d == '\n') multiline = true;
        }
        out.append(arena, if (multiline) '\n' else ' ') catch return false;
        i = end + 3;
    }
    return true;
}

/// True when the document has no inline `<script>` or `<style>` body, so HTML
/// comment stripping cannot reach text that is not markup. The serve path
/// checks this before stripping and falls back to the raw bytes otherwise.
pub fn htmlCommentFree(body: []const u8) bool {
    return !hasInlineRawText(body);
}

fn hasInlineRawText(body: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, body, i, '<')) |at| {
        i = at + 1;
        if (std.mem.startsWith(u8, body[at..], "<!--")) {
            // A `<!--` region is markup being commented out, so a `<script>`
            // named inside one is prose the page writes about itself rather
            // than a body. The shipped index.html names the tag in its own
            // header comment, and reading that as a body is what left the
            // document it exists to strip unstripped. Nothing after an
            // unterminated comment is markup.
            const end = std.mem.indexOfPos(u8, body, at + 4, "-->") orelse return false;
            i = end + 3;
            continue;
        }
        const name = if (std.mem.startsWith(u8, body[at..], "<script"))
            "<script"
        else if (std.mem.startsWith(u8, body[at..], "<style"))
            "<style"
        else
            continue;
        // A body is the span between the opening tag's own `>` and the next
        // `<`. Reading that `<` for a `/` cannot decide the question, because
        // in both `<script src=..></script>` and `<script>..</script>` it is
        // the closing tag's own `<`; only the span tells them apart, and the
        // first carries none.
        const open_end = std.mem.indexOfScalarPos(u8, body, at + name.len, '>') orelse return false;
        const close = std.mem.indexOfScalarPos(u8, body, open_end + 1, '<') orelse body.len;
        i = @max(close, at + name.len);
        if (std.mem.trim(u8, body[open_end + 1 .. close], " \t\r\n").len != 0) return true;
    }
    return false;
}

// -- tests ------------------------------------------------------------------

/// Every assertion goes through an arena, because `strip` hands back the
/// caller's own bytes when it declines to strip: freeing that would be an
/// invalid free, and freeing nothing when it did strip would be a leak.
fn expectStripped(lang: Lang, src: []const u8, want: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings(want, strip(lang, arena_state.allocator(), src));
}

test "js: line and block comments go, the newline after a line comment stays" {
    try expectStripped(.js,
        \\// leading note
        \\const a = 1; // trailing note
        \\/* block
        \\   note */const b = 2;
        \\
    , "\nconst a = 1; \n\nconst b = 2;\n");
}

test "js: a comment between two tokens cannot join them" {
    try expectStripped(.js, "a/*x*/in b;", "a in b;");
}

test "js: strings keep comment-looking bytes" {
    const src = "var u = \"https://x/y\"; var t = 'a/*b*/c';";
    try expectStripped(.js, src, src);
}

test "js: a regex is not a comment and its body is untouched" {
    const src = "var re = /a\\/\\/b/g; var n = len / 2; var m = len /2;";
    try expectStripped(.js, src, src);
}

test "js: division by a paren stays division, so its operand is not eaten" {
    const src = "var q = (a + b) / total; var r = x.y / z;";
    try expectStripped(.js, src, src);
}

test "js: a comment inside a template substitution goes, a URL inside a template does not" {
    try expectStripped(.js, "var a = `${x /* why */ + y}`; var b = `see https://x/y`;\nvar c = 1; // gone\n", "var a = `${x   + y}`; var b = `see https://x/y`;\nvar c = 1; \n");
}

test "js: a template spanning lines is text, so its comment-looking bytes stay" {
    try expectStripped(.js, "var a = `line one // not a comment\nline two`; // gone\n", "var a = `line one // not a comment\nline two`; \n");
}

test "js: an unterminated string, block comment or template returns the input" {
    for ([_][]const u8{ "var a = \"oops\nvar b = 1;", "var a = 1; /* oops", "var a = `oops\n" }) |src| {
        try expectStripped(.js, src, src);
    }
}

test "css: comments go, quoted text does not" {
    try expectStripped(.css, "/* head */.a { content: \"/* not a comment */\"; }", " .a { content: \"/* not a comment */\"; }");
}

test "html: comments go and the document keeps its markup" {
    try expectStripped(.html, "<html><!-- note --><body>hi</body></html>", "<html> <body>hi</body></html>");
}

test "html: an unterminated comment returns the input" {
    try expectStripped(.html, "<html><!-- oops", "<html><!-- oops");
}

test "htmlCommentFree sees an inline script or style body" {
    try std.testing.expect(htmlCommentFree("<html><body>hi</body></html>"));
    try std.testing.expect(!htmlCommentFree("<script type=\"module\">x</script>"));
    try std.testing.expect(!htmlCommentFree("<style>.a{}</style>"));
    try std.testing.expect(htmlCommentFree("<script src=\"/webui/app.js\"></script>"));
}

test "htmlCommentFree: a tag named in a comment is prose, and an empty body is no body" {
    // The shipped page names `<script>` in its own header comment and ships
    // only `src`-carrying tags. Neither may read as an inline body, or the one
    // document this exists for is served with its comments intact.
    try std.testing.expect(htmlCommentFree("<!-- their <script> tags sit at the end -->\n"));
    try std.testing.expect(htmlCommentFree("<script src=\"/webui/a.js\"></script>\n<script src=\"/webui/b.js\"></script>"));
    try std.testing.expect(htmlCommentFree("<script src=\"/webui/a.js\">   \n</script>"));
    try std.testing.expect(!htmlCommentFree("<!-- <script>a()</script> --><style>.a{}</style>"));
    try std.testing.expect(htmlCommentFree("<html><!-- oops"));
}

test "every shipped webui source strips smaller than it was" {
    // The point of the whole module: comments are what comes off, and a
    // syntax the scanner cannot model leaves the file untouched rather than
    // returning something longer.
    for ([_]struct { lang: Lang, src: []const u8 }{
        .{ .lang = .js, .src = "// only a comment\n" },
        .{ .lang = .js, .src = "export const a = 1; // x\n" },
        .{ .lang = .css, .src = "/* x */\n.a{b:c}\n" },
        .{ .lang = .html, .src = "<!-- x -->\n<p>y</p>\n" },
    }) |case| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        try std.testing.expect(strip(case.lang, arena_state.allocator(), case.src).len < case.src.len);
    }
}
