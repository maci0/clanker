//! Does a promoted change actually do anything?
//!
//! Every gate in the improve loop answers one question: is this change *safe*?
//! It compiles, its unit tests pass, its formatting is clean, it breaks no
//! capability the eval suite checks. Nothing asks whether it changes what the
//! program does, and a change that does nothing at all passes every one of
//! those checks by construction, because there is nothing in it to break.
//!
//! That is a reward the loop will find. Two shapes of it are already in this
//! repository's own history:
//!
//!   - Twenty-five of the last forty promoted improvements added a unit test
//!     and touched no other code. A new test in an untouched file is the
//!     cheapest possible way to be accepted.
//!   - `intField`, `boolField` and `floatField` in `src/util/json.zig` are
//!     three separate promotions that each added a function, added a test for
//!     that function, and added no caller. They are still unreachable. An
//!     earlier run produced about fifteen `History` helper methods the same way
//!     ("so the engine can detect ..."), every one of them unreachable,
//!     because the engine that would have called them is outside the surface
//!     the loop may write, and all fifteen were later deleted by hand.
//!
//! Both are inert: they pass, they cost a promotion, and the program behaves
//! exactly as it did before. This module classifies a proposal so the engine
//! can say so.
//!
//! Classification is derived from the source, never from the model's own
//! summary. A summary is a sentence the model chooses, so gating on it would
//! be gating on a field the model can simply write differently.

const std = @import("std");
const log = @import("../util/log.zig");

/// What a proposal does, worst-to-best for the loop's purposes.
pub const Class = enum {
    /// Only `.md` files changed.
    docs_only,
    /// Only `test` blocks (or files under `tests/`) changed. The compiled
    /// behaviour of the program is identical.
    test_only,
    /// Purely additive, and every callable it adds is unreachable: nothing
    /// outside a test block refers to it.
    inert,
    /// Anything else, existing code changed, or something new is reachable.
    behavior,

    pub fn asStr(self: Class) []const u8 {
        return switch (self) {
            .docs_only => "docs_only",
            .test_only => "test_only",
            .inert => "inert",
            .behavior => "behavior",
        };
    }

    /// Parses what `asStr` wrote. Unknown text (including an entry written
    /// before this field existed) reads as `behavior`: an old promotion must
    /// not be counted toward a monoculture streak it was never classified for.
    pub fn fromStr(s: []const u8) Class {
        inline for (@typeInfo(Class).@"enum".fields) |f| {
            const c: Class = @enumFromInt(f.value);
            if (std.mem.eql(u8, s, c.asStr())) return c;
        }
        return .behavior;
    }
};

/// One change, as the classifier needs to see it: the file, the text that was
/// replaced, and the text that replaced it. Mirrors `proposal.Change` without
/// depending on it, so this module stays testable on literals.
pub const Change = struct {
    file: []const u8,
    old: []const u8,
    new: []const u8,
};

/// Blanks out everything that is not Zig code, in place of a real tokenizer:
/// line comments, string literals, character literals and multiline string
/// literals become spaces, and every other byte is kept where it is.
///
/// Length-preserving on purpose. Every scan below reports positions, and a
/// pass that shortened the text would report them against a buffer the caller
/// does not have.
///
/// It exists because every question this module asks is confused by text that
/// only looks like code. `src/improve/engine.zig` holds the improve prompt as
/// a multiline string containing `"changes": [` and a literal `{`; counted as
/// code, those braces close a block that was never opened.
pub fn blankNonCode(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, src.len);
    @memcpy(out, src);

    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        // A multiline string runs to the end of the line and has no escapes,
        // so it is checked before the line comment: both start with a slash
        // or a backslash pair and only the first two bytes tell them apart.
        if (c == '\\' and i + 1 < src.len and src[i + 1] == '\\') {
            while (i < src.len and src[i] != '\n') : (i += 1) out[i] = ' ';
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') : (i += 1) out[i] = ' ';
            continue;
        }
        if (c == '"' or c == '\'') {
            const quote = c;
            out[i] = ' ';
            i += 1;
            while (i < src.len and src[i] != quote and src[i] != '\n') {
                // An escaped quote does not close the literal, and an escaped
                // backslash must not be read as escaping the quote after it.
                if (src[i] == '\\' and i + 1 < src.len) {
                    out[i] = ' ';
                    i += 1;
                    if (i < src.len) {
                        out[i] = ' ';
                        i += 1;
                    }
                    continue;
                }
                out[i] = ' ';
                i += 1;
            }
            // The closing quote itself. An unterminated literal ends at the
            // newline, which is left alone so line structure survives.
            if (i < src.len and src[i] == quote) {
                out[i] = ' ';
                i += 1;
            }
            continue;
        }
        i += 1;
    }
    return out;
}

/// True when `code[at..]` starting a match for `needle` is a whole identifier
/// rather than a fragment of a longer one, so a search for `intField` does not
/// answer yes to `printIntFieldName`.
fn wholeToken(code: []const u8, at: usize, needle_len: usize) bool {
    if (at > 0 and isIdentByte(code[at - 1])) return false;
    const end = at + needle_len;
    if (end < code.len and isIdentByte(code[end])) return false;
    return true;
}

fn isIdentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Byte range `[start, end)`.
pub const Span = struct { start: usize, end: usize };

/// The `test { ... }` blocks in code-only text, as spans covering the `test`
/// keyword through the closing brace.
///
/// Takes text already run through `blankNonCode`, so a brace inside a string
/// cannot close a block and the word `test` inside a comment cannot open one.
pub fn testSpans(gpa: std.mem.Allocator, code: []const u8) ![]Span {
    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (std.mem.findPos(u8, code, i, "test")) |at| {
        i = at + 4;
        if (!wholeToken(code, at, 4)) continue;
        // A test declaration is `test` then an optional name then `{`. Anything
        // else between them means this `test` is something other than a
        // declaration -- a field named test, a call to a function called test.
        const brace = brace: {
            var j = at + 4;
            while (j < code.len) : (j += 1) {
                if (code[j] == '{') break :brace j;
                if (std.ascii.isWhitespace(code[j])) continue;
                // blankNonCode turned the name literal into spaces, so
                // anything still here is real syntax and this is not a test.
                break :brace null;
            }
            break :brace null;
        } orelse continue;

        const end = matchBrace(code, brace) orelse continue;
        try out.append(gpa, .{ .start = at, .end = end + 1 });
        i = end + 1;
    }
    return out.toOwnedSlice(gpa);
}

/// Index of the `}` closing the `{` at `open`, or null when the text runs out
/// first. Code-only input, so every brace it counts is real.
fn matchBrace(code: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < code.len) : (i += 1) {
        switch (code[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// The code with every `test` block removed, so what is left is the part that
/// decides how the program behaves.
pub fn nonTestCode(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    const code = try blankNonCode(gpa, src);
    defer gpa.free(code);
    const spans = try testSpans(gpa, code);
    defer gpa.free(spans);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var at: usize = 0;
    for (spans) |s| {
        try out.appendSlice(gpa, code[at..s.start]);
        at = s.end;
    }
    try out.appendSlice(gpa, code[at..]);
    return out.toOwnedSlice(gpa);
}

/// The non-empty lines of `src`, trimmed. What "the code did not change" has
/// to mean once `zig fmt` has run over the staged tree and may have reindented
/// a line the proposal never touched.
fn codeLines(gpa: std.mem.Allocator, src: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        try out.append(gpa, t);
    }
    return out.toOwnedSlice(gpa);
}

/// True when every line of `before` still appears in `after`, in order: the
/// change only added lines and removed or rewrote none.
///
/// A subsequence test rather than a set test. A proposal that deletes one
/// branch of an `if` and adds an unrelated function would pass a set test
/// (every remaining line is still present somewhere) and must not: rewriting
/// existing code is a behaviour change whatever else the proposal does.
fn isPurelyAdditive(before: []const []const u8, after: []const []const u8) bool {
    var i: usize = 0;
    for (after) |line| {
        if (i == before.len) return true;
        if (std.mem.eql(u8, line, before[i])) i += 1;
    }
    return i == before.len;
}

/// The names of functions declared in `code` (already code-only) that a
/// caller could reach by name.
///
/// `export`ed and `extern` functions are left out: the host calls a guest
/// module's `run` across the WASM boundary, and no Zig source ever names it.
/// Reported as unreachable, every new WASM tool would be rejected.
fn declaredFns(gpa: std.mem.Allocator, code: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (std.mem.findPos(u8, code, i, "fn")) |at| {
        i = at + 2;
        if (!wholeToken(code, at, 2)) continue;

        // What precedes the keyword decides whether this is a declaration at
        // all: `fn` also appears in a function *type* (`*const fn (u8) void`),
        // which declares no name.
        const before = std.mem.trimEnd(u8, code[0..at], " \t\r\n");
        if (std.mem.endsWith(u8, before, "export") or std.mem.endsWith(u8, before, "extern")) continue;

        var j = i;
        while (j < code.len and std.ascii.isWhitespace(code[j])) : (j += 1) {}
        const start = j;
        while (j < code.len and isIdentByte(code[j])) : (j += 1) {}
        if (j == start) continue; // anonymous: a function type, not a decl
        // A declaration's name is followed by its parameter list.
        var k = j;
        while (k < code.len and std.ascii.isWhitespace(code[k])) : (k += 1) {}
        if (k >= code.len or code[k] != '(') continue;

        try out.append(gpa, code[start..j]);
        i = j;
    }
    return out.toOwnedSlice(gpa);
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// True when `name` is referred to somewhere in `code` other than by its own
/// declaration. Code-only, test-free input, so a mention in a comment or from
/// a unit test does not count as a use.
fn referencesName(code: []const u8, name: []const u8) bool {
    var i: usize = 0;
    while (std.mem.findPos(u8, code, i, name)) |at| {
        i = at + name.len;
        if (!wholeToken(code, at, name.len)) continue;
        // Skip the declaration itself. Everything else -- a call, a `&fn`
        // reference, a re-export -- is a use.
        const before = std.mem.trimEnd(u8, code[0..at], " \t\r\n");
        if (std.mem.endsWith(u8, before, "fn")) {
            const head = std.mem.trimEnd(u8, before, "fn");
            if (head.len < before.len and (head.len == 0 or !isIdentByte(head[head.len - 1]))) continue;
        }
        return true;
    }
    return false;
}

/// Every `.zig` file under `roots`, as paths relative to `dir`.
fn zigFiles(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, roots: []const []const u8, out: *std.ArrayList([]const u8)) !void {
    for (roots) |root| {
        try walkZig(gpa, io, dir, root, out);
    }
}

fn walkZig(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, rel: []const u8, out: *std.ArrayList([]const u8)) !void {
    var sub = dir.openDir(io, rel, .{ .iterate = true }) catch return;
    defer sub.close(io);
    var it = sub.iterate();
    while (it.next(io) catch null) |entry| {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel, entry.name });
        switch (entry.kind) {
            .directory => {
                defer gpa.free(path);
                try walkZig(gpa, io, dir, path, out);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) {
                    gpa.free(path);
                    continue;
                }
                try out.append(gpa, path);
            },
            else => gpa.free(path),
        }
    }
}

/// Where the reachability scan looks for a caller. `build.zig` is included
/// because a new build step is named from there and nowhere else.
const scan_roots = [_][]const u8{ "src", "tools/zig", "tests" };
const scan_files = [_][]const u8{"build.zig"};

/// The result of classifying one proposal.
pub const Verdict = struct {
    class: Class,
    /// Names of added functions with no caller. Only populated for `.inert`;
    /// this is what the rejection message has to be able to list.
    unreachable_fns: []const []const u8,

    pub fn deinit(self: *Verdict, gpa: std.mem.Allocator) void {
        for (self.unreachable_fns) |n| gpa.free(n);
        gpa.free(self.unreachable_fns);
    }
};

/// Classifies `changes` against `dir`, the staged tree with the patch already
/// applied and formatted.
///
/// `dir` matters: reachability is a property of the tree as it will be after
/// promotion, so a function the same proposal adds a caller for in a second
/// file is reachable and must not be reported.
pub fn classify(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    changes: []const Change,
) !Verdict {
    if (changes.len == 0) return .{ .class = .behavior, .unreachable_fns = &.{} };

    var all_docs = true;
    for (changes) |c| {
        if (!std.mem.endsWith(u8, c.file, ".md")) all_docs = false;
    }
    if (all_docs) return .{ .class = .docs_only, .unreachable_fns = &.{} };

    // Non-test code, before and after, for every changed .zig file. A change
    // to anything else (a .tool.json descriptor, config.toml) is behaviour by
    // definition: it has no test blocks to hide in.
    var any_zig = false;
    var behaviour_changed = false;
    var purely_additive = true;
    var added: std.ArrayList([]const u8) = .empty;
    defer {
        for (added.items) |n| gpa.free(n);
        added.deinit(gpa);
    }

    for (changes) |c| {
        if (!std.mem.endsWith(u8, c.file, ".zig")) {
            behaviour_changed = true;
            continue;
        }
        any_zig = true;
        const after_src = dir.readFileAlloc(io, c.file, gpa, .limited(4 << 20)) catch |err| {
            // Unreadable means unclassifiable, and an unclassifiable proposal
            // must not be treated as inert: this gate would then reject work
            // on the strength of a file it could not open.
            log.log(.warn, "inert: could not read staged {s}: {s}", .{ c.file, @errorName(err) });
            behaviour_changed = true;
            continue;
        };
        defer gpa.free(after_src);
        const before_src = try reverseApply(gpa, after_src, c);
        defer gpa.free(before_src);

        const after_code = try nonTestCode(gpa, after_src);
        defer gpa.free(after_code);
        const before_code = try nonTestCode(gpa, before_src);
        defer gpa.free(before_code);

        const after_lines = try codeLines(gpa, after_code);
        defer gpa.free(after_lines);
        const before_lines = try codeLines(gpa, before_code);
        defer gpa.free(before_lines);

        // Files under tests/ are test files whole; their non-test code is the
        // harness around the cases and changing it is still only testing.
        const is_test_file = std.mem.startsWith(u8, c.file, "tests/");
        if (!is_test_file and !sameLines(before_lines, after_lines)) behaviour_changed = true;
        if (!isPurelyAdditive(before_lines, after_lines)) purely_additive = false;

        const before_fns = try declaredFns(gpa, before_code);
        defer gpa.free(before_fns);
        const after_fns = try declaredFns(gpa, after_code);
        defer gpa.free(after_fns);
        for (after_fns) |name| {
            if (contains(before_fns, name)) continue;
            if (contains(added.items, name)) continue;
            try added.append(gpa, try gpa.dupe(u8, name));
        }
    }

    if (!behaviour_changed) return .{ .class = .test_only, .unreachable_fns = &.{} };

    // Nothing was added, so there is nothing to be unreachable.
    if (added.items.len == 0 or !purely_additive)
        return .{ .class = .behavior, .unreachable_fns = &.{} };

    // Collect all source files and strip test blocks once, then scan for
    // every added name. The old code called reachable() per name, which
    // walked the directory tree and re-read every file each time.
    var zig_files: std.ArrayList([]const u8) = .empty;
    defer {
        for (zig_files.items) |f| gpa.free(f);
        zig_files.deinit(gpa);
    }
    try zigFiles(gpa, io, dir, &scan_roots, &zig_files);
    for (scan_files) |f| try zig_files.append(gpa, try gpa.dupe(u8, f));

    var processed: std.ArrayList([]const u8) = .empty;
    defer {
        for (processed.items) |c| gpa.free(c);
        processed.deinit(gpa);
    }
    for (zig_files.items) |f| {
        const src = dir.readFileAlloc(io, f, gpa, .limited(4 << 20)) catch {
            try processed.append(gpa, try gpa.dupe(u8, ""));
            continue;
        };
        defer gpa.free(src);
        try processed.append(gpa, try nonTestCode(gpa, src));
    }

    var uncalled: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (uncalled.items) |n| gpa.free(n);
        uncalled.deinit(gpa);
    }
    for (added.items) |name| {
        var reached = false;
        for (processed.items) |code| {
            if (referencesName(code, name)) {
                reached = true;
                break;
            }
        }
        if (!reached) try uncalled.append(gpa, try gpa.dupe(u8, name));
    }

    // Inert only when *every* addition is unreachable. A proposal that adds a
    // reachable function plus a small helper for it is ordinary work, and the
    // helper alone must not sink it.
    if (uncalled.items.len == added.items.len) {
        return .{ .class = .inert, .unreachable_fns = try uncalled.toOwnedSlice(gpa) };
    }
    for (uncalled.items) |n| gpa.free(n);
    uncalled.deinit(gpa);
    return .{ .class = .behavior, .unreachable_fns = &.{} };
}

fn sameLines(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// The file as it was before this change: `new` put back to `old`. Used
/// instead of reading the live tree so classification works the same way in a
/// worktree, in a staging directory, and in a unit test.
fn reverseApply(gpa: std.mem.Allocator, after: []const u8, c: Change) ![]u8 {
    if (c.new.len == 0) return gpa.dupe(u8, after);
    const at = std.mem.find(u8, after, c.new) orelse {
        // `zig fmt` runs over the staged tree before this, so a proposal whose
        // `new` text was reformatted is no longer findable verbatim. Treat the
        // before-state as unknown rather than guessing: the caller reads that
        // as behaviour, which is the safe direction.
        return gpa.dupe(u8, after);
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, after[0..at]);
    try out.appendSlice(gpa, c.old);
    try out.appendSlice(gpa, after[at + c.new.len ..]);
    return out.toOwnedSlice(gpa);
}

/// True when some non-test code in the staged tree names `name`.
fn reachable(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) !bool {
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    try zigFiles(gpa, io, dir, &scan_roots, &files);
    for (scan_files) |f| try files.append(gpa, try gpa.dupe(u8, f));

    for (files.items) |f| {
        const src = dir.readFileAlloc(io, f, gpa, .limited(4 << 20)) catch continue;
        defer gpa.free(src);
        const code = try nonTestCode(gpa, src);
        defer gpa.free(code);
        if (referencesName(code, name)) return true;
    }
    return false;
}

test "blankNonCode leaves code and erases everything else" {
    const gpa = std.testing.allocator;
    const src =
        \\const a = "brace { here";
        \\// comment with fn nope(
        \\const b = 1; // trailing
        \\
    ;
    const out = try blankNonCode(gpa, src);
    defer gpa.free(out);
    try std.testing.expectEqual(src.len, out.len);
    try std.testing.expect(std.mem.find(u8, out, "brace") == null);
    try std.testing.expect(std.mem.find(u8, out, "nope") == null);
    try std.testing.expect(std.mem.find(u8, out, "const b = 1;") != null);
}

test "blankNonCode erases a multiline string literal" {
    const gpa = std.testing.allocator;
    // The improve prompt is exactly this shape: braces and quotes inside a
    // multiline string, which must not be read as code.
    const src = "const p =\n    \\\\{\"changes\": [{\n    \\\\}\n;\nfn real() void {}\n";
    const out = try blankNonCode(gpa, src);
    defer gpa.free(out);
    try std.testing.expect(std.mem.find(u8, out, "changes") == null);
    try std.testing.expect(std.mem.find(u8, out, "fn real()") != null);
}

test "testSpans finds test blocks and nothing else" {
    const gpa = std.testing.allocator;
    const src =
        \\fn f() void {}
        \\test "one" {
        \\    if (true) { }
        \\}
        \\const latest = 1;
        \\
    ;
    const code = try blankNonCode(gpa, src);
    defer gpa.free(code);
    const spans = try testSpans(gpa, code);
    defer gpa.free(spans);
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    // The whole block, closing brace included.
    try std.testing.expectEqualStrings("}", code[spans[0].end - 1 .. spans[0].end]);
    // `latest` contains "test" but is not a declaration.
    try std.testing.expect(std.mem.find(u8, code[spans[0].start..spans[0].end], "latest") == null);
}

test "nonTestCode drops the cases and keeps the code" {
    const gpa = std.testing.allocator;
    const src =
        \\fn add(a: u8, b: u8) u8 {
        \\    return a + b;
        \\}
        \\test "add" {
        \\    _ = add(1, 2);
        \\}
        \\
    ;
    const out = try nonTestCode(gpa, src);
    defer gpa.free(out);
    try std.testing.expect(std.mem.find(u8, out, "return a + b;") != null);
    try std.testing.expect(std.mem.find(u8, out, "_ = add(1, 2);") == null);
}

test "declaredFns names declarations and skips function types and exports" {
    const gpa = std.testing.allocator;
    const src =
        \\pub fn wanted(x: u8) u8 { return x; }
        \\fn alsoWanted() void {}
        \\export fn run(p: u32) u64 { return p; }
        \\const cb: *const fn (u8) void = undefined;
        \\
    ;
    const code = try blankNonCode(gpa, src);
    defer gpa.free(code);
    const fns = try declaredFns(gpa, code);
    defer gpa.free(fns);
    try std.testing.expectEqual(@as(usize, 2), fns.len);
    try std.testing.expectEqualStrings("wanted", fns[0]);
    try std.testing.expectEqualStrings("alsoWanted", fns[1]);
}

test "referencesName ignores the declaration and longer identifiers" {
    const decl_only = "pub fn intField(o: u8) u8 { return o; }\n";
    try std.testing.expect(!referencesName(decl_only, "intField"));

    const called = "pub fn intField(o: u8) u8 { return o; }\nfn use() u8 { return intField(1); }\n";
    try std.testing.expect(referencesName(called, "intField"));

    const substring = "pub fn intField(o: u8) u8 { return o; }\nfn use() void { printIntFieldName(); }\n";
    try std.testing.expect(!referencesName(substring, "intField"));
}

test "isPurelyAdditive distinguishes an insert from a rewrite" {
    const before = [_][]const u8{ "a", "b", "c" };
    const inserted = [_][]const u8{ "a", "b", "new", "c" };
    const rewritten = [_][]const u8{ "a", "changed", "c" };
    try std.testing.expect(isPurelyAdditive(&before, &inserted));
    try std.testing.expect(!isPurelyAdditive(&before, &rewritten));
}

/// Sets up a staged tree in a temp dir and classifies one change against it.
fn classifyIn(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    files: []const struct { path: []const u8, data: []const u8 },
    change: Change,
) !Verdict {
    try dir.createDirPath(io, "src/util");
    for (files) |f| try dir.writeFile(io, .{ .sub_path = f.path, .data = f.data });
    return classify(gpa, io, dir, &.{change});
}

test "classify reports an added function with no caller as inert" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The shape three separate promotions took in this repository: a helper,
    // a test for the helper, no caller anywhere.
    const after =
        \\const std = @import("std");
        \\pub fn existing() u8 {
        \\    return 1;
        \\}
        \\pub fn intField(o: u8) u8 {
        \\    return o;
        \\}
        \\test "intField" {
        \\    try std.testing.expectEqual(@as(u8, 1), intField(1));
        \\}
        \\
    ;
    var v = try classifyIn(gpa, io, tmp.dir, &.{
        .{ .path = "src/util/json.zig", .data = after },
    }, .{
        .file = "src/util/json.zig",
        .old = "",
        .new =
        \\pub fn intField(o: u8) u8 {
        \\    return o;
        \\}
        \\test "intField" {
        \\    try std.testing.expectEqual(@as(u8, 1), intField(1));
        \\}
        \\
        ,
    });
    defer v.deinit(gpa);
    try std.testing.expectEqual(Class.inert, v.class);
    try std.testing.expectEqual(@as(usize, 1), v.unreachable_fns.len);
    try std.testing.expectEqualStrings("intField", v.unreachable_fns[0]);
}

test "classify accepts an added function that something calls" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const added =
        \\pub fn intField(o: u8) u8 {
        \\    return o;
        \\}
        \\
    ;
    var v = try classifyIn(gpa, io, tmp.dir, &.{
        .{ .path = "src/util/json.zig", .data = "const std = @import(\"std\");\n" ++ added },
        // A caller in a second file, which is why reachability is a question
        // about the tree and not about the patch.
        .{ .path = "src/util/caller.zig", .data = "const j = @import(\"json.zig\");\nfn use() u8 { return j.intField(1); }\n" },
    }, .{ .file = "src/util/json.zig", .old = "", .new = added });
    defer v.deinit(gpa);
    try std.testing.expectEqual(Class.behavior, v.class);
}

test "classify reports a change confined to test blocks as test_only" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const new_case =
        \\test "existing returns one" {
        \\    try std.testing.expectEqual(@as(u8, 1), existing());
        \\}
        \\
    ;
    const after =
        \\const std = @import("std");
        \\pub fn existing() u8 {
        \\    return 1;
        \\}
        \\
    ++ new_case;
    var v = try classifyIn(gpa, io, tmp.dir, &.{
        .{ .path = "src/util/json.zig", .data = after },
    }, .{ .file = "src/util/json.zig", .old = "", .new = new_case });
    defer v.deinit(gpa);
    try std.testing.expectEqual(Class.test_only, v.class);
}

test "classify reports a rewrite of existing code as behavior" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var v = try classifyIn(gpa, io, tmp.dir, &.{
        .{ .path = "src/util/json.zig", .data = "pub fn existing() u8 {\n    return 2;\n}\n" },
    }, .{ .file = "src/util/json.zig", .old = "    return 1;", .new = "    return 2;" });
    defer v.deinit(gpa);
    try std.testing.expectEqual(Class.behavior, v.class);
}

test "classify reports a documentation-only change as docs_only" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var v = try classify(gpa, io, tmp.dir, &.{.{ .file = "README.md", .old = "old", .new = "new" }});
    defer v.deinit(gpa);
    try std.testing.expectEqual(Class.docs_only, v.class);
}

test "Class round-trips through its own text and defaults to behavior" {
    inline for (@typeInfo(Class).@"enum".fields) |f| {
        const c: Class = @enumFromInt(f.value);
        try std.testing.expectEqual(c, Class.fromStr(c.asStr()));
    }
    // An entry written before the field existed carries no class at all.
    try std.testing.expectEqual(Class.behavior, Class.fromStr(""));
    try std.testing.expectEqual(Class.behavior, Class.fromStr("something_else"));
}
