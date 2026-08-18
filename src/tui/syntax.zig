//! Dependency-free syntax highlighting for fenced code blocks, shared by the
//! legacy REPL (ANSI via MdStream in transcript.zig) and the vaxis REPL
//! (styled vaxis.Segment spans in repl.zig). Both flavors share the
//! same hand-rolled tokenizer below.
//!
//! Scope is deliberately small: this colors the fenced code blocks an LLM
//! actually emits in chat (Zig, Python, JS/TS, shell, JSON), not a full
//! tree-sitter. One shared C-like lexer covers Zig/JS/TS/shell-shaped code
//! with per-language keyword tables and toggles for comment/string syntax;
//! Python gets its own toggles on the same lexer. Unknown fence languages
//! fall back to the C-like lexer with no keywords, which still picks out
//! strings, numbers and comments correctly more often than not, and
//! wrong-but-readable highlighting beats a crash or a wall of one color.
//!
//! Safety: `emit`/`spansVaxis` strip C0 controls (except \n, \t), DEL and
//! UTF-8 C1 controls the same way transcript.zig's writeSanitized does;
//! everything rendered here is model output (CWE-150). Highlighter state
//! (unterminated strings, block comments) is carried across lines by the
//! caller, so a multi-line string keeps its color until its closing quote.

const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("theme.zig");
const sanitize = @import("sanitize.zig");

/// Token categories. Deliberately few: six colors are plenty to read by,
/// and every category maps to exactly one ANSI/vaxis style.
pub const Kind = enum {
    plain,
    keyword,
    string,
    comment,
    number,
    builtin, // @builtins, self/this/True, $VARS, JSON true/false/null
    preproc, // C #include style lines
};

pub const Token = struct {
    text: []const u8,
    kind: Kind,
};

/// Per-language lexer configuration. `line_comment = ""` disables line
/// comments (JSON), `hash_comment` uses '#' (Python/shell).
const Lang = struct {
    keywords: []const []const u8 = &.{},
    builtins: []const []const u8 = &.{},
    line_comment: []const u8 = "//",
    block_comments: bool = true,
    hash_comment: bool = false,
    raw_string_prefix: bool = false, // r"..." (Python)
    shell_vars: bool = false, // $VAR, ${VAR}
    preproc: bool = false, // #directive at line start (C-like)
};

const zig_keywords = [_][]const u8{
    "addrspace", "align",  "allowzero",   "and",            "anyframe",
    "anytype",   "asm",    "async",       "await",          "break",
    "callconv",  "catch",  "comptime",    "const",          "continue",
    "defer",     "else",   "enum",        "errdefer",       "error",
    "export",    "extern", "false",       "fn",             "for",
    "if",        "inline", "linksection", "noinline",       "nosuspend",
    "null",      "opaque", "or",          "orelse",         "packed",
    "pub",       "resume", "return",      "struct",         "suspend",
    "switch",    "test",   "threadlocal", "true",           "try",
    "undefined", "union",  "unreachable", "usingnamespace", "var",
    "volatile",  "while",
};

const zig_builtins = [_][]const u8{
    "i8",       "i16",    "i32",          "i64",            "i128",     "isize",
    "u8",       "u16",    "u32",          "u64",            "u128",     "usize",
    "f16",      "f32",    "f64",          "f80",            "f128",     "c_int",
    "c_uint",   "c_long", "c_ulong",      "c_char",         "bool",     "void",
    "noreturn", "type",   "comptime_int", "comptime_float", "anyerror",
};

const py_keywords = [_][]const u8{
    "and",    "as",       "assert", "async",  "await",    "break",
    "class",  "continue", "def",    "del",    "elif",     "else",
    "except", "finally",  "for",    "from",   "global",   "if",
    "import", "in",       "is",     "lambda", "nonlocal", "not",
    "or",     "pass",     "raise",  "return", "try",      "while",
    "with",   "yield",    "match",  "case",
};

const py_builtins = [_][]const u8{
    "True", "False",     "None",  "self", "cls",        "print",
    "len",  "range",     "str",   "int",  "float",      "list",
    "dict", "set",       "tuple", "type", "isinstance", "super",
    "open", "enumerate", "zip",   "map",  "filter",
};

const js_keywords = [_][]const u8{
    "async",    "await",    "break",     "case",    "catch",      "class",
    "const",    "continue", "debugger",  "default", "delete",     "do",
    "else",     "export",   "extends",   "finally", "for",        "from",
    "function", "if",       "import",    "in",      "instanceof", "let",
    "new",      "of",       "return",    "static",  "super",      "switch",
    "throw",    "try",      "typeof",    "var",     "void",       "while",
    "with",     "yield",    "interface", "type",    "enum",       "implements",
    "readonly", "declare",  "abstract",  "as",
};

const js_builtins = [_][]const u8{
    "true",     "false",   "null",   "undefined", "this",    "NaN",
    "Infinity", "console", "window", "document",  "process", "require",
    "module",   "exports",
};

const sh_keywords = [_][]const u8{
    "if",     "then", "else",   "elif", "fi",   "for", "while",
    "until",  "do",   "done",   "case", "esac", "in",  "function",
    "select", "time", "coproc",
};

const sh_builtins = [_][]const u8{
    "echo",  "cd",    "pwd",    "export", "local", "readonly",
    "unset", "shift", "return", "exit",   "set",   "source",
    "alias", "eval",  "exec",   "trap",   "test",  "true",
    "false",
};

fn langFor(name: []const u8) Lang {
    // Fence tags are matched loosely: "```ts" and "```typescript" are the
    // same language, "```zsh" is shell, an empty tag gets the C-like
    // default (strings/comments/numbers, no keywords).
    if (eqAny(name, &.{ "zig", "zon" })) return .{
        .keywords = &zig_keywords,
        .builtins = &zig_builtins,
    };
    if (eqAny(name, &.{ "python", "py", "python3" })) return .{
        .keywords = &py_keywords,
        .builtins = &py_builtins,
        .line_comment = "#",
        .block_comments = false,
        .hash_comment = true,
        .raw_string_prefix = true,
    };
    if (eqAny(name, &.{ "js", "javascript", "ts", "typescript", "jsx", "tsx", "mjs", "cjs" })) return .{
        .keywords = &js_keywords,
        .builtins = &js_builtins,
    };
    if (eqAny(name, &.{ "sh", "bash", "zsh", "shell", "console" })) return .{
        .keywords = &sh_keywords,
        .builtins = &sh_builtins,
        .line_comment = "#",
        .block_comments = false,
        .hash_comment = true,
        .shell_vars = true,
    };
    if (eqAny(name, &.{"json"})) return .{
        .builtins = &.{ "true", "false", "null" },
        .line_comment = "",
        .block_comments = false,
    };
    if (eqAny(name, &.{ "c", "h", "cpp", "c++", "cc", "hpp", "rs", "rust", "go", "java", "cs", "csharp" })) return .{
        .preproc = true,
    };
    return .{};
}

fn eqAny(s: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.ascii.eqlIgnoreCase(s, n)) return true;
    return false;
}

fn inList(list: []const []const u8, word: []const u8) bool {
    for (list) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

/// Mutable highlighter state carried across `highlightLine` calls: whether
/// we are inside an unterminated string or block comment. `lang` is chosen
/// once per fenced block from the fence's language tag.
pub const State = struct {
    in_string: u8 = 0, // 0, '\'', '"', or '`' (JS template literal)
    in_block_comment: bool = false,
    lang: Lang = .{},
    /// Zig is tokenized by std.zig.Tokenizer instead of the lexer below.
    use_zig_tokenizer: bool = false,

    pub fn init(fence_lang: []const u8) State {
        return .{
            .lang = langFor(fence_lang),
            .use_zig_tokenizer = eqAny(fence_lang, &.{ "zig", "zon" }),
        };
    }
};

/// Zig, tokenized by the compiler's own tokenizer rather than the hand-rolled
/// lexer below.
///
/// std.zig.Tokenizer is the real thing: it classifies exactly what the
/// compiler classifies, so `@"quoted identifiers"`, `\\` multiline strings,
/// character literals, `0x1F_FF` and every keyword come out right without a
/// keyword table that drifts from the language.
///
/// Line at a time is safe for Zig specifically: it has no block comments, and
/// a `\\` multiline string is a token per line, so no construct spans a line
/// boundary. That is a property of the language, not a shortcut, which is why
/// this is not done for the C-like languages below.
///
/// Returns false when the line cannot be tokenized (allocation failure), so
/// the caller can fall back rather than lose the line.
fn zigLine(gpa: std.mem.Allocator, line: []const u8, out: *std.ArrayList(Token)) bool {
    // The tokenizer wants a sentinel-terminated buffer.
    const buf = gpa.allocSentinel(u8, line.len, 0) catch return false;
    // Freed on the way out: every token below slices `line`, not this copy,
    // so nothing outlives it. Without this the transcript leaks a buffer per
    // line drawn, every frame.
    defer gpa.free(buf);
    @memcpy(buf, line);

    var tz = std.zig.Tokenizer.init(buf);
    var prev_end: usize = 0;
    while (true) {
        const tok = tz.next();
        if (tok.tag == .eof) break;
        // Whatever sat between two tokens (spaces, and comments, which this
        // tokenizer skips rather than emits) is re-read from the line so
        // nothing is dropped and the output still concatenates to the input.
        if (tok.loc.start > prev_end) {
            if (!emitGap(gpa, line[prev_end..tok.loc.start], out)) return false;
        }
        const text = line[tok.loc.start..tok.loc.end];
        var kind = kindOfZigTag(tok.tag);
        // Primitive types are identifiers to the compiler, not keywords, so
        // the tokenizer is right to call them that and the reader still wants
        // `u32` to stand out. The same table the generic lexer uses decides.
        if (kind == .plain and tok.tag == .identifier and inList(&zig_builtins, text)) kind = .builtin;
        out.append(gpa, .{ .text = text, .kind = kind }) catch return false;
        prev_end = tok.loc.end;
    }
    if (prev_end < line.len) {
        if (!emitGap(gpa, line[prev_end..], out)) return false;
    }
    return true;
}

/// The run between two tokens: whitespace, and comments, which the tokenizer
/// skips rather than emitting. The comment is split off from the whitespace
/// before it so the coloured span starts at `//` rather than at the indent
/// preceding it.
fn emitGap(gpa: std.mem.Allocator, gap: []const u8, out: *std.ArrayList(Token)) bool {
    if (std.mem.find(u8, gap, "//")) |at| {
        if (at > 0) out.append(gpa, .{ .text = gap[0..at], .kind = .plain }) catch return false;
        out.append(gpa, .{ .text = gap[at..], .kind = .comment }) catch return false;
    } else {
        out.append(gpa, .{ .text = gap, .kind = .plain }) catch return false;
    }
    return true;
}

fn kindOfZigTag(tag: std.zig.Token.Tag) Kind {
    return switch (tag) {
        .string_literal, .multiline_string_literal_line, .char_literal => .string,
        .number_literal => .number,
        .builtin => .builtin,
        .doc_comment, .container_doc_comment => .comment,
        else => blk: {
            // Every keyword tag is spelled "keyword_...", so this needs no
            // second list to keep in step with the language.
            const name = @tagName(tag);
            break :blk if (std.mem.startsWith(u8, name, "keyword_")) .keyword else .plain;
        },
    };
}

/// One full line of code (no trailing \n) becomes a list of styled tokens.
/// `out` is cleared and refilled; tokens borrow `line`.
/// Precondition: `line` contains no '\n'.
pub fn highlightLine(state: *State, gpa: std.mem.Allocator, line: []const u8, out: *std.ArrayList(Token)) !void {
    out.clearRetainingCapacity();
    if (state.use_zig_tokenizer) {
        if (zigLine(gpa, line, out)) return;
        // Fall through to the generic lexer if that could not allocate.
        out.clearRetainingCapacity();
    }
    const lang = state.lang;
    var i: usize = 0;
    var plain_start: usize = 0;

    if (state.in_block_comment) {
        if (std.mem.find(u8, line, "*/")) |close| {
            try out.append(gpa, .{ .text = line[0 .. close + 2], .kind = .comment });
            i = close + 2;
            plain_start = i;
            state.in_block_comment = false;
        } else {
            try out.append(gpa, .{ .text = line, .kind = .comment });
            return;
        }
    }
    if (state.in_string != 0) {
        const q = state.in_string;
        if (scanStringEnd(line, 0, q)) |end| {
            try out.append(gpa, .{ .text = line[0..end], .kind = .string });
            i = end;
            plain_start = i;
            state.in_string = 0;
        } else {
            try out.append(gpa, .{ .text = line, .kind = .string });
            return;
        }
    }

    // A '#' directive at the very start of a line (C preprocessor).
    if (lang.preproc and i == 0 and line.len > 0 and line[0] == '#') {
        try out.append(gpa, .{ .text = line, .kind = .preproc });
        return;
    }

    while (i < line.len) {
        const c = line[i];

        // Line comments: rest of the line is one token.
        if (lang.line_comment.len > 0 and std.mem.startsWith(u8, line[i..], lang.line_comment)) {
            try flushPlain(out, gpa, line, plain_start, i);
            try out.append(gpa, .{ .text = line[i..], .kind = .comment });
            return;
        }
        if (lang.hash_comment and c == '#') {
            try flushPlain(out, gpa, line, plain_start, i);
            try out.append(gpa, .{ .text = line[i..], .kind = .comment });
            return;
        }
        // Block comments.
        if (lang.block_comments and c == '/' and i + 1 < line.len and line[i + 1] == '*') {
            try flushPlain(out, gpa, line, plain_start, i);
            if (std.mem.findPos(u8, line, i + 2, "*/")) |close| {
                try out.append(gpa, .{ .text = line[i .. close + 2], .kind = .comment });
                i = close + 2;
            } else {
                try out.append(gpa, .{ .text = line[i..], .kind = .comment });
                state.in_block_comment = true;
                return;
            }
            plain_start = i;
            continue;
        }
        // Strings (and JS template literals). A Python raw string r"..."
        // reclaims the r prefix from the pending plain run.
        if (c == '"' or c == '\'' or c == '`') {
            var start = i;
            if (lang.raw_string_prefix and i > 0 and plain_start == i - 1 and
                (line[i - 1] == 'r' or line[i - 1] == 'R')) start = i - 1;
            try flushPlain(out, gpa, line, plain_start, start);
            if (scanStringEnd(line, i + 1, c)) |end| {
                try out.append(gpa, .{ .text = line[start..end], .kind = .string });
                i = end;
            } else {
                try out.append(gpa, .{ .text = line[start..], .kind = .string });
                state.in_string = c;
                return;
            }
            plain_start = i;
            continue;
        }
        // Numbers: hex/binary/octal/floats, close enough by accepting
        // [0-9a-fA-F._xob'] runs that start with a digit.
        if (std.ascii.isDigit(c)) {
            try flushPlain(out, gpa, line, plain_start, i);
            var end = i;
            while (end < line.len and isNumberChar(line[end])) end += 1;
            try out.append(gpa, .{ .text = line[i..end], .kind = .number });
            i = end;
            plain_start = i;
            continue;
        }
        // Shell variables.
        if (lang.shell_vars and c == '$' and i + 1 < line.len and
            (std.ascii.isAlphabetic(line[i + 1]) or line[i + 1] == '_' or line[i + 1] == '{'))
        {
            try flushPlain(out, gpa, line, plain_start, i);
            var end = i + 1;
            if (line[end] == '{') {
                while (end < line.len and line[end] != '}') end += 1;
                if (end < line.len) end += 1;
            } else {
                while (end < line.len and (std.ascii.isAlphanumeric(line[end]) or line[end] == '_')) end += 1;
            }
            try out.append(gpa, .{ .text = line[i..end], .kind = .builtin });
            i = end;
            plain_start = i;
            continue;
        }
        // Zig @builtins.
        if (c == '@' and i + 1 < line.len and std.ascii.isAlphabetic(line[i + 1])) {
            try flushPlain(out, gpa, line, plain_start, i);
            var end = i + 1;
            while (end < line.len and (std.ascii.isAlphanumeric(line[end]) or line[end] == '_')) end += 1;
            try out.append(gpa, .{ .text = line[i..end], .kind = .builtin });
            i = end;
            plain_start = i;
            continue;
        }
        // Identifiers: keyword / builtin lookup, else plain.
        if (std.ascii.isAlphabetic(c) or c == '_') {
            var end = i;
            while (end < line.len and (std.ascii.isAlphanumeric(line[end]) or line[end] == '_')) end += 1;
            const word = line[i..end];
            const kind: Kind = if (inList(lang.keywords, word))
                .keyword
            else if (inList(lang.builtins, word))
                .builtin
            else
                .plain;
            if (kind != .plain) {
                try flushPlain(out, gpa, line, plain_start, i);
                try out.append(gpa, .{ .text = word, .kind = kind });
                plain_start = end;
            }
            i = end;
            continue;
        }
        i += 1;
    }
    try flushPlain(out, gpa, line, plain_start, line.len);
}

fn flushPlain(out: *std.ArrayList(Token), gpa: std.mem.Allocator, line: []const u8, start: usize, end: usize) !void {
    if (end > start) try out.append(gpa, .{ .text = line[start..end], .kind = .plain });
}

/// Finds the byte just past the closing quote `q`, scanning from `i`.
/// Returns null when the string runs to the end of the line.
fn scanStringEnd(line: []const u8, i: usize, q: u8) ?usize {
    var j = i;
    while (j < line.len) {
        if (line[j] == '\\') {
            j += 2;
            continue;
        }
        if (line[j] == q) return j + 1;
        j += 1;
    }
    return null;
}

fn isNumberChar(c: u8) bool {
    return std.ascii.isHex(c) or c == '.' or c == '_' or c == '\'';
}

// ------------------------------------------------------------- ANSI output --

/// Styles for one theme. Derived from `tui/theme.zig`'s palette so the
/// highlighted code sits next to the rest of the REPL without clashing,
/// and every field is empty under `mono` (NO_COLOR), which makes `emit`
/// a pass-through.
pub const Style = struct {
    keyword: []const u8,
    string: []const u8,
    comment: []const u8,
    number: []const u8,
    builtin: []const u8,
    preproc: []const u8,
    reset: []const u8,
    /// Set when the theme is a 24-bit palette; the vaxis renderer uses it so
    /// the TUI shows the same colours the ANSI path writes.
    rgb: ?theme_mod.Rgb = null,

    pub fn fromTheme(t: *const theme_mod.Theme) Style {
        // The theme owns these now, so a palette like Catppuccin sets its own
        // rather than having magenta/green/cyan hardcoded underneath it. The
        // fallbacks keep any theme that predates the fields (and `mono`, whose
        // fields are all empty) behaving exactly as before.
        const on = t.reset.len > 0;
        return .{
            .keyword = if (t.syn_keyword.len > 0) t.syn_keyword else if (on) "\x1b[35m" else "",
            .string = if (t.syn_string.len > 0) t.syn_string else if (on) "\x1b[32m" else "",
            .comment = t.dim,
            .number = if (t.syn_number.len > 0) t.syn_number else t.code,
            .builtin = if (t.syn_builtin.len > 0) t.syn_builtin else if (on) "\x1b[36m" else "",
            .preproc = if (t.syn_preproc.len > 0) t.syn_preproc else if (on) "\x1b[33m" else "",
            .reset = t.reset,
            .rgb = t.rgb,
        };
    }

    fn ansiFor(self: *const Style, kind: Kind) []const u8 {
        return switch (kind) {
            .plain => "",
            .keyword => self.keyword,
            .string => self.string,
            .comment => self.comment,
            .number => self.number,
            .builtin => self.builtin,
            .preproc => self.preproc,
        };
    }

    pub fn vaxisFor(self: *const Style, kind: Kind) vaxis.Style {
        if (self.reset.len == 0) return .{};
        if (self.rgb) |c| {
            // A 24-bit theme names exact colours; the 16 indexed slots would
            // round them to whatever the terminal happens to have there.
            return switch (kind) {
                .plain => .{},
                .keyword => .{ .fg = .{ .rgb = c.keyword } },
                .string => .{ .fg = .{ .rgb = c.string } },
                .comment => .{ .fg = .{ .rgb = c.comment } },
                .number => .{ .fg = .{ .rgb = c.number } },
                .builtin => .{ .fg = .{ .rgb = c.builtin } },
                .preproc => .{ .fg = .{ .rgb = c.preproc } },
            };
        }
        return switch (kind) {
            .plain => .{},
            .keyword => .{ .fg = .{ .index = 5 } }, // magenta
            .string => .{ .fg = .{ .index = 2 } }, // green
            .comment => .{ .dim = true },
            .number => .{ .fg = .{ .index = 6 } }, // cyan
            .builtin => .{ .fg = .{ .index = 6 } },
            .preproc => .{ .fg = .{ .index = 3 } }, // yellow
        };
    }
};

/// Writes `tokens` to `w` with ANSI styling, stripping control bytes from
/// every token's text first (model output is untrusted, CWE-150). Styles
/// are written around each styled token, so under the mono theme (all
/// fields empty) the output is byte-identical to the input.
pub fn emit(w: *std.Io.Writer, style: *const Style, tokens: []const Token) void {
    for (tokens) |tok| {
        const ansi = style.ansiFor(tok.kind);
        if (ansi.len > 0) w.writeAll(ansi) catch {};
        writeSanitized(w, tok.text);
        if (ansi.len > 0) w.writeAll(style.reset) catch {};
    }
}

const writeSanitized = sanitize.writeSanitized;
const sanitizeAlloc = sanitize.sanitizeAlloc;

/// One full line of code highlighted straight to vaxis segments, for the
/// cell-based renderer in repl.zig. Controls are stripped per token;
/// segment text borrows `line` unless it needed sanitizing (then it is
/// `gpa`-owned, and the caller's arena lifetime covers it).
pub fn spansVaxis(state: *State, style: *const Style, gpa: std.mem.Allocator, line: []const u8, out: *std.ArrayList(vaxis.Segment)) !void {
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try highlightLine(state, gpa, line, &toks);
    out.clearRetainingCapacity();
    for (toks.items) |tok| {
        const clean = try sanitizeAlloc(gpa, tok.text);
        if (clean.len == 0) continue;
        try out.append(gpa, .{ .text = clean, .style = style.vaxisFor(tok.kind) });
    }
}

// ------------------------------------------------------------------- tests --

fn renderAlloc(allocator: std.mem.Allocator, fence_lang: []const u8, code: []const u8, style: *const Style) ![]u8 {
    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    var state = State.init(fence_lang);
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(allocator);
    var it = std.mem.splitScalar(u8, code, '\n');
    var first = true;
    while (it.next()) |line| {
        if (line.len == 0 and it.peek() == null) break; // trailing newline
        if (!first) w.writer.writeAll("\n") catch {};
        first = false;
        try highlightLine(&state, allocator, line, &toks);
        emit(&w.writer, style, toks.items);
    }
    return allocator.dupe(u8, w.written());
}

test "zig code gets keyword, string, comment and number colors" {
    const allocator = std.testing.allocator;
    const style = Style.fromTheme(&theme_mod.Theme.default);
    const out = try renderAlloc(allocator, "zig", "const x: u32 = 42; // the answer\nconst s = \"hi\";", &style);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[35mconst\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[36mu32\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[36m42\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[2m// the answer\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[32m\"hi\"\x1b[0m") != null);
}

test "python hash comments and builtins highlight" {
    const allocator = std.testing.allocator;
    const style = Style.fromTheme(&theme_mod.Theme.default);
    const out = try renderAlloc(allocator, "python", "def f(xs): # iterate\n    return [x for x in xs if x is not None]", &style);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[35mdef\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[2m# iterate\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[36mNone\x1b[0m") != null);
}

test "an invalid zig string does not color the next line" {
    const allocator = std.testing.allocator;
    const style = Style.fromTheme(&theme_mod.Theme.default);
    const out = try renderAlloc(allocator, "zig", "const s = \"one\ntwo\";", &style);
    defer allocator.free(out);
    // Zig has no newline-spanning quoted strings. The compiler tokenizer is
    // deliberately line-local for Zig, so an invalid opening quote cannot
    // colour valid-looking text on the next line as a string.
    try std.testing.expect(std.mem.find(u8, out, "two") != null);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[32mtwo") == null);
}

test "block comments span lines" {
    const allocator = std.testing.allocator;
    const style = Style.fromTheme(&theme_mod.Theme.default);
    const out = try renderAlloc(allocator, "js", "/* start\nstill comment */\nconst x = 1;", &style);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[2mstill comment */\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[35mconst\x1b[0m") != null);
}

test "json mode has no comments and colors booleans" {
    const allocator = std.testing.allocator;
    const style = Style.fromTheme(&theme_mod.Theme.default);
    const out = try renderAlloc(allocator, "json", "{\"ok\": true, \"n\": 3}", &style);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[32m\"ok\"\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[36mtrue\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[36m3\x1b[0m") != null);
    // Nothing is treated as a comment in JSON mode.
    try std.testing.expect(std.mem.find(u8, out, "\x1b[2m") == null);
}

test "shell variables and hash comments" {
    const allocator = std.testing.allocator;
    const style = Style.fromTheme(&theme_mod.Theme.default);
    const out = try renderAlloc(allocator, "bash", "export PATH=$HOME/bin # prepend", &style);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[36mexport\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[36m$HOME\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[2m# prepend\x1b[0m") != null);
}

test "mono theme emits no ANSI at all" {
    const allocator = std.testing.allocator;
    const style = Style.fromTheme(&theme_mod.Theme.mono);
    const out = try renderAlloc(allocator, "zig", "const x = 1; // c", &style);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "\x1b") == null);
    try std.testing.expectEqualStrings("const x = 1; // c", out);
}

test "control bytes are stripped from highlighted code" {
    const allocator = std.testing.allocator;
    const style = Style.fromTheme(&theme_mod.Theme.default);
    const out = try renderAlloc(allocator, "zig", "const \x1b[2Jx = 1;\x07", &style);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "[2Jx") != null);
    // No raw ESC other than the SGR sequences the highlighter itself wrote.
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        if (out[i] == 0x1b) {
            try std.testing.expect(std.mem.startsWith(u8, out[i..], "\x1b[35m") or
                std.mem.startsWith(u8, out[i..], "\x1b[36m") or
                std.mem.startsWith(u8, out[i..], "\x1b[0m"));
        }
    }
}

test "unknown fence language still highlights strings and numbers" {
    const allocator = std.testing.allocator;
    const style = Style.fromTheme(&theme_mod.Theme.default);
    const out = try renderAlloc(allocator, "brainfuck++", "x = \"s\" + 9 // y", &style);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[32m\"s\"\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, out, "\x1b[36m9\x1b[0m") != null);
}

test "vaxis spans carry styles and strip controls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const style = Style.fromTheme(&theme_mod.Theme.default);
    var state = State.init("zig");
    var segs: std.ArrayList(vaxis.Segment) = .empty;
    try spansVaxis(&state, &style, allocator, "const \x1bxx = 1", &segs);
    var saw_kw = false;
    for (segs.items) |s| {
        if (std.mem.eql(u8, s.text, "const")) {
            saw_kw = true;
            try std.testing.expectEqual(vaxis.Color{ .index = 5 }, s.style.fg);
        }
        try std.testing.expect(std.mem.findScalar(u8, s.text, 0x1b) == null);
    }
    try std.testing.expect(saw_kw);
}

fn kindsOf(gpa: std.mem.Allocator, lang: []const u8, line: []const u8, out: *std.ArrayList(Token)) !void {
    var st = State.init(lang);
    try highlightLine(&st, gpa, line, out);
}

fn findKind(toks: []const Token, text: []const u8) ?Kind {
    for (toks) |t| {
        if (std.mem.eql(u8, t.text, text)) return t.kind;
    }
    return null;
}

test "zig is tokenized by the compiler's tokenizer" {
    const gpa = std.testing.allocator;
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);

    try kindsOf(gpa, "zig", "const x: u32 = 0x1F_FF; // note", &toks);
    try std.testing.expectEqual(Kind.keyword, findKind(toks.items, "const").?);
    // A hand-rolled number scanner tends to stop at the underscore.
    try std.testing.expectEqual(Kind.number, findKind(toks.items, "0x1F_FF").?);

    // @"..." is one identifier, not a builtin followed by a string.
    try kindsOf(gpa, "zig", "var @\"if\" = 1;", &toks);
    try std.testing.expect(findKind(toks.items, "@\"if\"") != null);

    // A builtin is a builtin, and a char literal is a string, not a number.
    try kindsOf(gpa, "zig", "@memcpy(d, 'a');", &toks);
    try std.testing.expectEqual(Kind.builtin, findKind(toks.items, "@memcpy").?);
    try std.testing.expectEqual(Kind.string, findKind(toks.items, "'a'").?);
}

test "a zig line always concatenates back to itself" {
    // The renderer draws the tokens in order, so anything dropped between them
    // would silently vanish from the transcript.
    const gpa = std.testing.allocator;
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);

    const lines = [_][]const u8{
        "const std = @import(\"std\");",
        "    if (x) return error.Nope; // why",
        "\\\\a multiline string line",
        "",
        "   ",
        "fn f() void {}",
    };
    for (lines) |line| {
        try kindsOf(gpa, "zig", line, &toks);
        var rebuilt: std.ArrayList(u8) = .empty;
        defer rebuilt.deinit(gpa);
        for (toks.items) |t| try rebuilt.appendSlice(gpa, t.text);
        try std.testing.expectEqualStrings(line, rebuilt.items);
    }
}

test "other languages still use the hand-rolled lexer" {
    const gpa = std.testing.allocator;
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);

    try kindsOf(gpa, "python", "def f(): # hi", &toks);
    try std.testing.expectEqual(Kind.keyword, findKind(toks.items, "def").?);
    try std.testing.expectEqual(Kind.comment, findKind(toks.items, "# hi").?);
}

test "a 24-bit theme reaches both renderers" {
    const style = Style.fromTheme(&theme_mod.Theme.mocha);
    // The ANSI path writes mocha's own sequences, not the built-in magenta.
    try std.testing.expectEqualStrings(theme_mod.Theme.mocha.syn_keyword, style.keyword);
    try std.testing.expect(std.mem.find(u8, style.string, "38;2;") != null);
    // The vaxis path sets the same colour as an rgb cell rather than rounding
    // it to one of the 16 indexed slots.
    const vx = style.vaxisFor(.keyword);
    try std.testing.expectEqual(theme_mod.mocha_palette.mauve, vx.fg.rgb);

    // The default theme keeps its indexed colours, so nothing changes for it.
    const plain = Style.fromTheme(&theme_mod.Theme.default);
    try std.testing.expectEqualStrings("\x1b[35m", plain.keyword);
    try std.testing.expectEqual(@as(u8, 5), plain.vaxisFor(.keyword).fg.index);

    // mono stays colourless in both.
    const off = Style.fromTheme(&theme_mod.Theme.mono);
    try std.testing.expectEqualStrings("", off.keyword);
    try std.testing.expectEqual(vaxis.Style{}, off.vaxisFor(.keyword));
}
