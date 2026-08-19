//! Pure logic behind the `config` guest's get/set actions: dotted-key
//! lookup over the host-merged config JSON, TOML value rendering with the
//! merged value's type as the schema, and the surgical config.local.toml
//! edit. No wasm imports, so `zig build test` covers it natively
//! (host_tested_helpers in build.zig).
//!
//! The edit is deliberately line-based, not a TOML round-trip: parsing and
//! re-serializing would reformat the whole file and destroy its comments,
//! and the file is the operator's, not ours. One line changes; everything
//! else survives byte-identical.

const std = @import("std");

/// A settable key is dotted bare segments (`agent.reasoning_effort`).
/// Quoted TOML keys (`models."deepseek/v4"`) are refused: they belong to
/// table sections get/set does not edit.
pub fn keyValid(key: []const u8) bool {
    if (key.len == 0) return false;
    var it = std.mem.splitScalar(u8, key, '.');
    while (it.next()) |seg| {
        if (seg.len == 0) return false;
        for (seg) |c| switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
            else => return false,
        };
    }
    return true;
}

/// Walk a dotted key through nested JSON objects. Null when any segment is
/// missing or the walk hits a non-object before the last segment.
pub fn lookup(root: std.json.Value, key: []const u8) ?std.json.Value {
    var cur = root;
    var it = std.mem.splitScalar(u8, key, '.');
    while (it.next()) |seg| {
        if (cur != .object) return null;
        cur = cur.object.get(seg) orelse return null;
    }
    return cur;
}

pub const RenderError = error{ NotScalar, TypeMismatch, OutOfMemory };

/// Human name of the type `renderValue` would hold `existing` to, for error
/// messages.
pub fn typeName(existing: std.json.Value) []const u8 {
    return switch (existing) {
        .bool => "a bool (true or false)",
        .integer => "an integer",
        .float, .number_string => "a number",
        .string => "a string",
        .null => "a scalar",
        .object, .array => "a table",
    };
}

/// Render `raw` as the TOML right-hand side for a key whose merged value is
/// `existing`. The merged config is struct-serialized, so `existing`'s JSON
/// type is the loader's schema type: a raw that does not parse as it is a
/// typo'd value, refused rather than written. `.null` (an unset optional)
/// carries no type, so the shape of `raw` itself decides.
pub fn renderValue(alloc: std.mem.Allocator, existing: std.json.Value, raw: []const u8) RenderError![]const u8 {
    switch (existing) {
        .object, .array => return error.NotScalar,
        .bool => {
            if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "false")) return alloc.dupe(u8, raw);
            return error.TypeMismatch;
        },
        .integer => {
            _ = std.fmt.parseInt(i64, raw, 10) catch return error.TypeMismatch;
            return alloc.dupe(u8, raw);
        },
        .float, .number_string => {
            _ = std.fmt.parseFloat(f64, raw) catch return error.TypeMismatch;
            return alloc.dupe(u8, raw);
        },
        .string => return quoteString(alloc, raw),
        .null => {
            if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "false")) return alloc.dupe(u8, raw);
            if (std.fmt.parseInt(i64, raw, 10)) |_| return alloc.dupe(u8, raw) else |_| {}
            if (std.fmt.parseFloat(f64, raw)) |_| return alloc.dupe(u8, raw) else |_| {}
            return quoteString(alloc, raw);
        },
    }
}

/// TOML basic string: backslash, quote and the control characters that have
/// short escapes get them; any other control character is escaped \uXXXX.
fn quoteString(alloc: std.mem.Allocator, raw: []const u8) RenderError![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    try text.append(alloc, '"');
    for (raw) |c| switch (c) {
        '\\' => try text.appendSlice(alloc, "\\\\"),
        '"' => try text.appendSlice(alloc, "\\\""),
        '\n' => try text.appendSlice(alloc, "\\n"),
        '\r' => try text.appendSlice(alloc, "\\r"),
        '\t' => try text.appendSlice(alloc, "\\t"),
        0...8, 11, 12, 14...31, 127 => {
            var buf: [6]u8 = undefined;
            const esc = std.fmt.bufPrint(&buf, "\\u{X:0>4}", .{c}) catch unreachable;
            try text.appendSlice(alloc, esc);
        },
        else => try text.append(alloc, c),
    };
    try text.append(alloc, '"');
    return text.toOwnedSlice(alloc);
}

/// Rewrite `original` (config.local.toml's text, "" when absent) so that
/// `key` holds `rendered`. The one matching assignment line is replaced in
/// place; a missing key is appended at the end of its section; a missing
/// section is appended at the end of the file. Everything else — comments,
/// blank lines, other sections — survives byte-identical.
pub fn setKey(alloc: std.mem.Allocator, original: []const u8, key: []const u8, rendered: []const u8) ![]const u8 {
    const last_dot = std.mem.lastIndexOfScalar(u8, key, '.');
    const section = if (last_dot) |i| key[0..i] else "";
    const leaf = if (last_dot) |i| key[i + 1 ..] else key;
    const line = try std.fmt.allocPrint(alloc, "{s} = {s}", .{ leaf, rendered });
    defer alloc.free(line);

    const span = sectionSpan(original, section);
    if (span) |sp| {
        if (assignmentLine(original[sp.start..sp.end], leaf)) |rel| {
            // Replace the one line, keeping everything around it.
            const line_start = sp.start + rel.start;
            const line_end = sp.start + rel.end;
            return std.mem.concat(alloc, u8, &.{ original[0..line_start], line, original[line_end..] });
        }
        // Key absent: insert at the section's end, before the blank lines
        // that separate it from the next section.
        var at = sp.end;
        while (at > sp.start) {
            const prev = lineStartBefore(original, at);
            if (std.mem.trim(u8, original[prev..at], " \t\r\n").len != 0) break;
            at = prev;
        }
        const lead: []const u8 = if (at > 0 and original[at - 1] != '\n') "\n" else "";
        return std.mem.concat(alloc, u8, &.{ original[0..at], lead, line, "\n", original[at..] });
    }

    // Section header absent. (A top-level key never lands here: the prelude
    // span exists even when it is empty, so "" always matched above.)
    const sep: []const u8 = if (original.len == 0) "" else if (std.mem.endsWith(u8, original, "\n\n")) "" else if (std.mem.endsWith(u8, original, "\n")) "\n" else "\n\n";
    return std.fmt.allocPrint(alloc, "{s}{s}[{s}]\n{s}\n", .{ original, sep, section, line });
}

const Span = struct { start: usize, end: usize };

/// Byte span of a section's body: from just past its header line to the
/// next header line (or EOF). `section` "" means the prelude before the
/// first header, which always exists (it is empty when the file opens with
/// a header). For a named section, null when no header line matches
/// `[section]` exactly (whitespace-trimmed).
fn sectionSpan(text: []const u8, section: []const u8) ?Span {
    var pos: usize = 0;
    var body_start: ?usize = if (section.len == 0) 0 else null;
    while (pos <= text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        const trimmed = std.mem.trim(u8, text[pos..nl], " \t\r");
        const is_header = trimmed.len >= 2 and trimmed[0] == '[';
        if (is_header) {
            if (body_start) |s| return .{ .start = s, .end = pos };
            if (headerNames(trimmed, section)) body_start = if (nl < text.len) nl + 1 else text.len;
        }
        if (nl == text.len) break;
        pos = nl + 1;
    }
    if (body_start) |s| return .{ .start = s, .end = text.len };
    return null;
}

/// Does a trimmed header line name exactly this section? `[[...]]` (array
/// of tables) never matches: those sections are not editable here.
fn headerNames(trimmed: []const u8, section: []const u8) bool {
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[1] == '[') return false;
    const close = std.mem.indexOfScalar(u8, trimmed, ']') orelse return false;
    // Anything after ] other than a comment makes it not a header.
    const rest = std.mem.trim(u8, trimmed[close + 1 ..], " \t");
    if (rest.len != 0 and rest[0] != '#') return false;
    const name = std.mem.trim(u8, trimmed[1..close], " \t");
    return std.mem.eql(u8, name, section);
}

/// Find the assignment line for `leaf` inside a section body. Returns the
/// line's span relative to the body. Exact key match only: `max_tokens`
/// must not hit `max_tokens_per_turn`, and a commented-out key is absent.
fn assignmentLine(body: []const u8, leaf: []const u8) ?Span {
    var pos: usize = 0;
    while (pos <= body.len) {
        const nl = std.mem.indexOfScalarPos(u8, body, pos, '\n') orelse body.len;
        const l = body[pos..nl];
        const trimmed = std.mem.trimStart(u8, l, " \t");
        if (std.mem.startsWith(u8, trimmed, leaf)) {
            const after = std.mem.trimStart(u8, trimmed[leaf.len..], " \t");
            if (after.len > 0 and after[0] == '=') return .{ .start = pos, .end = nl };
        }
        if (nl == body.len) break;
        pos = nl + 1;
    }
    return null;
}

fn lineStartBefore(text: []const u8, at: usize) usize {
    if (at == 0) return 0;
    // `at` sits at a line start; back over that line's own newline first.
    const before = if (at > 0 and text[at - 1] == '\n') at - 1 else at;
    if (std.mem.lastIndexOfScalar(u8, text[0..before], '\n')) |nl| return nl + 1;
    return 0;
}

// ------------------------------------------------------------------- tests --

const t = std.testing;

test "keyValid accepts dotted bare keys and refuses everything else" {
    try t.expect(keyValid("agent.reasoning_effort"));
    try t.expect(keyValid("default_provider"));
    try t.expect(keyValid("tui.mascot-size"));
    try t.expect(!keyValid(""));
    try t.expect(!keyValid("agent."));
    try t.expect(!keyValid("a..b"));
    try t.expect(!keyValid("models.\"deepseek/v4\""));
    try t.expect(!keyValid("agent reasoning"));
}

test "lookup walks nested objects and misses cleanly" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(),
        \\{"agent":{"reasoning_effort":"medium","max_iterations":40},"default_provider":"deepseek"}
    , .{});
    try t.expectEqualStrings("medium", lookup(v, "agent.reasoning_effort").?.string);
    try t.expectEqual(@as(i64, 40), lookup(v, "agent.max_iterations").?.integer);
    try t.expectEqualStrings("deepseek", lookup(v, "default_provider").?.string);
    try t.expect(lookup(v, "agent.nope") == null);
    try t.expect(lookup(v, "default_provider.deeper") == null);
}

test "renderValue holds a value to the merged type" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectEqualStrings("12", try renderValue(a, .{ .integer = 4096 }, "12"));
    try t.expectError(error.TypeMismatch, renderValue(a, .{ .integer = 4096 }, "not-a-number"));
    try t.expectEqualStrings("true", try renderValue(a, .{ .bool = false }, "true"));
    try t.expectError(error.TypeMismatch, renderValue(a, .{ .bool = false }, "yes"));
    try t.expectEqualStrings("\"medium\"", try renderValue(a, .{ .string = "low" }, "medium"));
    try t.expectEqualStrings("\"a \\\"b\\\" \\\\ c\"", try renderValue(a, .{ .string = "" }, "a \"b\" \\ c"));
    try t.expectError(error.NotScalar, renderValue(a, .{ .array = std.json.Array.init(a) }, "x"));
    // Unset optionals infer from the raw's own shape.
    try t.expectEqualStrings("7", try renderValue(a, .null, "7"));
    try t.expectEqualStrings("\"hi\"", try renderValue(a, .null, "hi"));
}

test "setKey replaces one assignment in place" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const original =
        \\# local overrides
        \\default_provider = "deepseek"
        \\
        \\[agent]
        \\max_tokens_per_turn = 4096
        \\reasoning_effort = "low"
        \\
        \\[tui]
        \\mascot = "loop"
        \\
    ;
    const got = try setKey(a, original, "agent.reasoning_effort", "\"high\"");
    try t.expectEqualStrings(
        \\# local overrides
        \\default_provider = "deepseek"
        \\
        \\[agent]
        \\max_tokens_per_turn = 4096
        \\reasoning_effort = "high"
        \\
        \\[tui]
        \\mascot = "loop"
        \\
    , got);
}

test "setKey matches the exact key, not a prefix of a longer one" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const original =
        \\[agent]
        \\max_tokens_per_turn = 4096
        \\
    ;
    const got = try setKey(a, original, "agent.max_tokens", "9000");
    try t.expectEqualStrings(
        \\[agent]
        \\max_tokens_per_turn = 4096
        \\max_tokens = 9000
        \\
    , got);
}

test "setKey appends a missing key at the section's end, before the blank separator" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const original =
        \\[agent]
        \\max_iterations = 40
        \\
        \\[tui]
        \\mascot = "loop"
        \\
    ;
    const got = try setKey(a, original, "agent.reasoning_effort", "\"high\"");
    try t.expectEqualStrings(
        \\[agent]
        \\max_iterations = 40
        \\reasoning_effort = "high"
        \\
        \\[tui]
        \\mascot = "loop"
        \\
    , got);
}

test "setKey creates a missing section at the end of the file" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const got = try setKey(a, "default_provider = \"deepseek\"\n", "agent.reasoning_effort", "\"high\"");
    try t.expectEqualStrings(
        \\default_provider = "deepseek"
        \\
        \\[agent]
        \\reasoning_effort = "high"
        \\
    , got);
}

test "setKey on an empty file writes just the section" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const got = try setKey(a, "", "agent.reasoning_effort", "\"high\"");
    try t.expectEqualStrings("[agent]\nreasoning_effort = \"high\"\n", got);
}

test "setKey writes a top-level key into the prelude, before the first header" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const original =
        \\[agent]
        \\max_iterations = 40
        \\
    ;
    const got = try setKey(a, original, "default_provider", "\"deepseek\"");
    try t.expectEqualStrings(
        \\default_provider = "deepseek"
        \\[agent]
        \\max_iterations = 40
        \\
    , got);
}

test "setKey replaces a top-level key in the prelude" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const original =
        \\default_provider = "deepseek"
        \\
        \\[agent]
        \\max_iterations = 40
        \\
    ;
    const got = try setKey(a, original, "default_provider", "\"ollama\"");
    try t.expectEqualStrings(
        \\default_provider = "ollama"
        \\
        \\[agent]
        \\max_iterations = 40
        \\
    , got);
}

test "setKey leaves a commented-out key alone and adds a live one" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const original =
        \\[agent]
        \\# reasoning_effort = "low"
        \\
    ;
    const got = try setKey(a, original, "agent.reasoning_effort", "\"high\"");
    try t.expectEqualStrings(
        \\[agent]
        \\# reasoning_effort = "low"
        \\reasoning_effort = "high"
        \\
    , got);
}

test "setKey never mistakes an array-of-tables header for a section" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const original =
        \\[[providers]]
        \\name = "deepseek"
        \\
    ;
    const got = try setKey(a, original, "providers.name", "\"other\"");
    // No [providers] table exists, so a new one is appended; the [[providers]]
    // entry is untouched. (The guest refuses providers.* before this runs;
    // this pins the parser's behavior all the same.)
    try t.expectEqualStrings(
        \\[[providers]]
        \\name = "deepseek"
        \\
        \\[providers]
        \\name = "other"
        \\
    , got);
}
