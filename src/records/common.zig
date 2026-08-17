//! What the five record-store commands (`adr`, `prd`, `reports`, `research`,
//! `rfc`) share: the seam they reach their WASM tool through, the JSON field
//! readers they decode its answer with, and the renderer for a search result.
//!
//! Each store carried its own copy of all of this, and the copies drifted:
//! `reports` grew a per-record cap on how many matching lines a search prints
//! and the other four kept printing every hit, so one grep-happy record could
//! push a search result below the fold in four of the five stores. Rendering a
//! matched line is the same problem in every store, so it is one function.

const std = @import("std");
const log = @import("../util/log.zig");
const utf8 = @import("../util/utf8.zig");
const json_util = @import("../util/json.zig");

pub const Error = error{
    BadSubcommand,
    MissingArg,
    /// The tool ran and refused the request (`{"ok":false,...}`), or answered
    /// something the command cannot read. The detail is already logged.
    ToolFailed,
};

/// How a record command reaches its WASM tool. `cli.zig` owns the registry,
/// the sandbox and the config needed to load a tool, so it passes the call in
/// rather than these modules reaching back into it. Tests pass a canned answer
/// through the same seam.
pub const Tool = struct {
    ctx: *anyopaque,
    /// Takes the tool's JSON input, returns its JSON output. The result is
    /// owned by the caller's arena.
    call: *const fn (ctx: *anyopaque, input: []const u8) anyerror![]const u8,
};

/// A matched line is one row of a search result; the rest of a 500-byte grep
/// hit belongs in the record, not in the summary. Sized so the row, its
/// four-space indent and its line number still fit an 80-column terminal,
/// which is the width the rest of clanker's output is written to.
pub const match_column_bytes: usize = 68;

/// Most matching lines one record contributes to a search result. A record can
/// match a query in hundreds of places, and printing them all pushes the
/// useful hits below the fold of the same terminal the result is read on; the
/// rest live in the record, where `<store> open <path>` shows them with their
/// surrounding context instead of a uniform column.
pub const match_lines_per_file_max: usize = 50;

/// One field of a tool request. `absent` is what an optional argument becomes
/// when it was not given: the field is left out of the object entirely, which
/// is what every one of these tools reads as "not supplied". Writing it as a
/// null would make each tool decide again whether null and missing differ.
pub const Field = struct {
    name: []const u8,
    value: Value,

    pub const Value = union(enum) {
        text: []const u8,
        number: u64,
        absent,
    };

    /// An argument the caller may or may not have: `.{ .name = "slug", .value
    /// = Field.optional(opts.arg3) }`.
    pub fn optional(s: ?[]const u8) Value {
        return if (s) |v| .{ .text = v } else .absent;
    }
};

/// Builds a record tool's request object. Every store spells its requests the
/// same way — an `action` plus a handful of flat scalars — and each used to
/// hand-roll the same eight lines of `std.json.Stringify` per subcommand, five
/// stores deep. One builder, so a field cannot be written with a stray
/// `objectField` and no value in one store only.
pub fn request(arena: std.mem.Allocator, fields: []const Field) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();
    var s = std.json.Stringify{ .writer = &w.writer, .options = .{} };
    try s.beginObject();
    for (fields) |f| {
        switch (f.value) {
            .text => |t| {
                try s.objectField(f.name);
                try s.write(t);
            },
            .number => |n| {
                try s.objectField(f.name);
                try s.write(n);
            },
            .absent => {},
        }
    }
    try s.endObject();
    return w.written();
}

/// Runs the store's tool and returns its parsed answer, or `ToolFailed` with
/// the reason already logged. `store` is the command's own name, which is what
/// prefixes the log line.
pub fn callTool(arena: std.mem.Allocator, store: []const u8, tool: Tool, input: []const u8) !std.json.Value {
    const raw = try tool.call(tool.ctx, input);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{ .ignore_unknown_fields = true }) catch {
        log.log(.error_, "{s}: the tool answered something that is not JSON", .{store});
        return Error.ToolFailed;
    };
    if (parsed != .object) {
        log.log(.error_, "{s}: the tool answered something that is not a JSON object", .{store});
        return Error.ToolFailed;
    }
    const ok = parsed.object.get("ok");
    if (ok == null or ok.? != .bool or !ok.?.bool) {
        const detail = if (parsed.object.get("error")) |e|
            (if (e == .string) e.string else "the tool refused the request")
        else
            "the tool refused the request";
        log.log(.error_, "{s}: {s}", .{ store, detail });
        return Error.ToolFailed;
    }
    return parsed;
}

// The three readers take a whole `std.json.Value` rather than its `.object`,
// so they are the ones a caller reaches for on a *nested* row of a tool answer
// as well as on the answer itself. A row is whatever the tool put in the array
// and need not be an object at all, so each checks the tag rather than
// unwrapping it: `.object` on a non-object is a panic, not a missing field.

pub fn boolField(obj: std.json.Value, name: []const u8) bool {
    if (obj != .object) return false;
    const v = obj.object.get(name) orelse return false;
    return v == .bool and v.bool;
}

pub fn arrayField(obj: std.json.Value, name: []const u8) []const std.json.Value {
    if (obj != .object) return &.{};
    const v = obj.object.get(name) orelse return &.{};
    return if (v == .array) v.array.items else &.{};
}

/// A count read unsigned: `{d}` on an i64 carries an explicit `+`, which reads
/// as a diff marker in a column of numbers. A negative count is not one, so it
/// reads as zero rather than wrapping through `@intCast`.
pub fn unsignedField(obj: std.json.Value, name: []const u8) u64 {
    if (obj != .object) return 0;
    const v = obj.object.get(name) orelse return 0;
    if (v != .integer or v.integer < 0) return 0;
    return @intCast(v.integer);
}

/// A matched line as it reads in a column: leading and trailing whitespace is
/// indentation the record needs and the summary does not.
pub fn ellipsize(s: []const u8, max: usize) []const u8 {
    const flat = std.mem.trim(u8, s, " \t\r\n");
    return utf8.cap(flat, max);
}

pub fn out(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

/// One heading and the matches under it, then the blank line that separates it
/// from whatever the caller writes next. An empty group prints nothing at all.
pub fn renderMatchGroup(w: *std.Io.Writer, heading: []const u8, matches: []const std.json.Value) !void {
    if (matches.len == 0) return;
    try w.print("{s}\n\n", .{heading});
    try renderMatchRows(w, matches);
    try w.writeAll("\n");
}

/// The matches themselves, grouped by the file they came from and capped at
/// `match_lines_per_file_max` rows per file. Matches are expected to arrive
/// already grouped by file: a file that appears twice starts a second group.
pub fn renderMatchRows(w: *std.Io.Writer, matches: []const std.json.Value) !void {
    var last_file: []const u8 = "";
    var file_lines: usize = 0;
    var skipped: usize = 0;
    for (matches) |m| {
        if (m != .object) continue;
        const file = json_util.strFieldOrEmpty(m.object, "file");
        if (!std.mem.eql(u8, file, last_file)) {
            // Leaving a capped record: say what the listing refused, then the
            // blank line that separates the next file's group.
            if (last_file.len > 0 and skipped > 0) try printSkipped(w, skipped, last_file);
            if (last_file.len > 0) try w.writeByte('\n');
            last_file = file;
            file_lines = 0;
            skipped = 0;
            try w.print("  {s}\n", .{file});
        }
        if (file_lines >= match_lines_per_file_max) {
            skipped += 1;
            continue;
        }
        file_lines += 1;
        const text = json_util.strFieldOrEmpty(m.object, "text");
        // A line number is printed unsigned: `{d}` on an i64 carries an
        // explicit `+`, which reads as a diff marker in a column of numbers.
        const line = unsignedField(m, "line");
        try w.print("    {d: >5}  {s}\n", .{ line, ellipsize(text, match_column_bytes) });
    }
    if (last_file.len > 0 and skipped > 0) try printSkipped(w, skipped, last_file);
}

fn printSkipped(w: *std.Io.Writer, skipped: usize, file: []const u8) !void {
    try w.print("    … {d} more matching line(s) in {s}\n", .{ skipped, file });
}

// ----------------------------------------------------------------- tests --

const testing = std.testing;

fn parseValue(arena: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
}

test "renderMatchRows caps one file and says how many it refused" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var input: std.Io.Writer.Allocating = .init(arena);
    try input.writer.writeByte('[');
    for (0..match_lines_per_file_max + 3) |i| {
        if (i > 0) try input.writer.writeByte(',');
        try input.writer.print("{{\"file\":\"docs/a.md\",\"line\":{d},\"text\":\"hit\"}}", .{i + 1});
    }
    try input.writer.writeByte(']');
    const matches = try parseValue(arena, input.written());

    var w: std.Io.Writer.Allocating = .init(arena);
    try renderMatchRows(&w.writer, matches.array.items);
    const rendered = w.written();

    try testing.expectEqual(
        match_lines_per_file_max,
        std.mem.count(u8, rendered, "  hit\n"),
    );
    try testing.expect(std.mem.indexOf(u8, rendered, "… 3 more matching line(s) in docs/a.md") != null);
    // The rows past the cap are the ones dropped, not the rows before it.
    try testing.expect(std.mem.indexOf(u8, rendered, "   50  hit") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "   51  hit") == null);
}

test "renderMatchGroup prints nothing for an empty group" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var w: std.Io.Writer.Allocating = .init(arena_state.allocator());
    try renderMatchGroup(&w.writer, "ADRS", &.{});
    try testing.expectEqualStrings("", w.written());
}

test "callTool names the store in its refusal" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const Canned = struct {
        answer: []const u8,
        fn call(ctx: *anyopaque, _: []const u8) anyerror![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.answer;
        }
    };
    var refused: Canned = .{ .answer = "{\"ok\":false,\"error\":\"no such record\"}" };
    try testing.expectError(
        Error.ToolFailed,
        callTool(arena_state.allocator(), "adr", .{ .ctx = &refused, .call = Canned.call }, "{}"),
    );

    var fine: Canned = .{ .answer = "{\"ok\":true,\"next_number\":7}" };
    const parsed = try callTool(arena_state.allocator(), "adr", .{ .ctx = &fine, .call = Canned.call }, "{}");
    try testing.expectEqual(@as(u64, 7), unsignedField(parsed, "next_number"));
    try testing.expectEqual(@as(u64, 0), unsignedField(parsed, "missing"));
}
