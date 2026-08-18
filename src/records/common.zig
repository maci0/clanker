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
const diag = @import("../util/diag.zig");
const log = @import("../util/log.zig");
const utf8 = @import("../util/utf8.zig");
const json_util = @import("../util/json.zig");

pub const Error = error{
    BadSubcommand,
    MissingArg,
    /// The tool ran and refused the request (`{"ok":false,...}`), or answered
    /// something the command cannot read. The reason is already on stderr: a
    /// refusal as a diagnostic, an unreadable answer as a log record.
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

/// A usage mistake is an interactive diagnostic, not a runtime log. It gets
/// the same `error: ...` shape on stderr that `cli.printUsageError` gives
/// every other command, rather than the timestamped `[ERROR] ts_ms=...`
/// record `log.log` writes: `clanker reports bogus` and `clanker preset bogus`
/// are the same mistake and used to be answered in two different formats.
/// The caller still returns `BadSubcommand`/`MissingArg`, which is what makes
/// the exit status 2.
pub fn usageError(comptime fmt: []const u8, args: anytype) void {
    diag.errorLine(fmt, args);
}

/// Runs the store's tool and returns its parsed answer, or `ToolFailed` with
/// the reason already on stderr. `store` is the command's own name, which is
/// what prefixes the message.
///
/// A refusal is the caller's mistake — a path outside the store, a status
/// change missing its note — so it gets the same `error: ...` diagnostic as
/// `clanker workflow show nope`; it used to arrive as a timestamped `[ERROR]
/// ts_ms=...` record, which made "no such ADR" read like a subsystem fault.
/// An answer that is not readable JSON is the opposite case, a broken build
/// rather than a bad argument, and stays a log record.
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
        const detail = json_util.strFieldOrNull(parsed.object, "error") orelse "the tool refused the request";
        diag.errorLine("{s}: {s}", .{ store, detail });
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

// ------------------------------------------------- reading and editing --

// `open`, `append` and `update` are the same request in all five stores: a
// path (plus content) in, a fixed one-line confirmation out. Each store used
// to carry its own copy, differing only in the store name and the example path
// its usage line suggests, so they are three functions taking those two.

/// `<store> open <path>` — the record's markdown as it was written, with a
/// trailing newline. A record is markdown meant to be read, so it is returned
/// as it is rather than reflowed.
pub fn openRecord(
    arena: std.mem.Allocator,
    store: []const u8,
    example_path: []const u8,
    path_arg: ?[]const u8,
    tool: Tool,
) ![]const u8 {
    const path = path_arg orelse {
        usageError("{s} open needs a path: clanker {s} open {s}", .{ store, store, example_path });
        return Error.MissingArg;
    };
    const input = try request(arena, &.{
        .{ .name = "action", .value = .{ .text = "open" } },
        .{ .name = "path", .value = .{ .text = path } },
    });
    const result = try callTool(arena, store, tool, input);
    const text = json_util.strFieldOrEmpty(result.object, "text");
    if (text.len > 0 and text[text.len - 1] != '\n') return std.fmt.allocPrint(arena, "{s}\n", .{text});
    return text;
}

/// `<store> append <path> <markdown>`. `example` is the whole usage line after
/// `clanker <store> append `, because each store suggests a different section
/// heading for the kind of record it holds.
pub fn appendRecord(
    arena: std.mem.Allocator,
    store: []const u8,
    example: []const u8,
    path_arg: ?[]const u8,
    content_arg: ?[]const u8,
    tool: Tool,
) ![]const u8 {
    const path = path_arg orelse {
        usageError("{s} append needs a path and markdown content: clanker {s} append {s}", .{ store, store, example });
        return Error.MissingArg;
    };
    const content = content_arg orelse {
        usageError("{s} append needs the markdown to add after the path", .{store});
        return Error.MissingArg;
    };
    const input = try request(arena, &.{
        .{ .name = "action", .value = .{ .text = "append" } },
        .{ .name = "path", .value = .{ .text = path } },
        .{ .name = "content", .value = .{ .text = content } },
    });
    const result = try callTool(arena, store, tool, input);
    return std.fmt.allocPrint(arena, "appended to {s}\n", .{json_util.strFieldOrEmpty(result.object, "path")});
}

/// `<store> update <path> <old> <new>`. An empty replacement deletes the old
/// text, which the tools support, so the third argument has to be present but
/// may be "".
pub fn updateRecord(
    arena: std.mem.Allocator,
    store: []const u8,
    path_arg: ?[]const u8,
    old_arg: ?[]const u8,
    new_arg: ?[]const u8,
    tool: Tool,
) ![]const u8 {
    const path = path_arg orelse {
        usageError("{s} update needs a path, the exact old text, and its replacement", .{store});
        return Error.MissingArg;
    };
    const old = old_arg orelse {
        usageError("{s} update needs the exact current text to replace; copy it from `clanker {s} open {s}`", .{ store, store, path });
        return Error.MissingArg;
    };
    const new = new_arg orelse {
        usageError("{s} update needs replacement text after the old text (\"\" removes it)", .{store});
        return Error.MissingArg;
    };
    const input = try request(arena, &.{
        .{ .name = "action", .value = .{ .text = "update" } },
        .{ .name = "path", .value = .{ .text = path } },
        .{ .name = "old", .value = .{ .text = old } },
        .{ .name = "new", .value = .{ .text = new } },
    });
    const result = try callTool(arena, store, tool, input);
    return std.fmt.allocPrint(arena, "updated {s}\n", .{json_util.strFieldOrEmpty(result.object, "path")});
}

/// What a store's `status` usage line and its inventory warning say. These
/// four strings are the whole of what the five stores differ in; the request,
/// the confirmation line and the inventory check are the same everywhere.
pub const StatusUsage = struct {
    /// The whole example command after `clanker <store> status `.
    example: []const u8,
    /// What the first and second arguments are called when one is missing.
    path_arg: []const u8,
    status_arg: []const u8,
    /// Printed when the record moved but its inventory row did not.
    index_warning: []const u8,
};

/// `<store> status <path> <state> [note]`.
pub fn setRecordStatus(
    arena: std.mem.Allocator,
    store: []const u8,
    usage: StatusUsage,
    path_arg: ?[]const u8,
    status_arg: ?[]const u8,
    note_arg: ?[]const u8,
    tool: Tool,
) ![]const u8 {
    // The tools require a note for some states, but every state reads better
    // with one, and asking here names the missing argument rather than
    // spending a tool call to be told.
    const path = path_arg orelse return missingStatusArg(store, usage, usage.path_arg);
    const wanted = status_arg orelse return missingStatusArg(store, usage, usage.status_arg);

    const input = try request(arena, &.{
        .{ .name = "action", .value = .{ .text = "status" } },
        .{ .name = "path", .value = .{ .text = path } },
        .{ .name = "status", .value = .{ .text = wanted } },
        .{ .name = "note", .value = .{ .text = note_arg orelse "" } },
    });
    const result = try callTool(arena, store, tool, input);

    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();
    try w.writer.print("{s} is now {s}\n", .{
        json_util.strFieldOrEmpty(result.object, "path"),
        json_util.strFieldOrEmpty(result.object, "status"),
    });
    // Only `prd` answers with a reminder today; the rest never set the field.
    const reminder = json_util.strFieldOrEmpty(result.object, "reminder");
    if (reminder.len > 0) try w.writer.print("\n{s}\n", .{reminder});
    if (!boolField(result, "indexed")) try w.writer.writeAll(usage.index_warning);
    return w.written();
}

/// Sort predicate over record rows: by their `path` field, so a listing comes
/// out in store order however the tool happened to walk the directory. A row
/// that is not an object, or has no `path`, sorts first rather than erroring.
pub fn byPath(_: void, a: std.json.Value, b: std.json.Value) bool {
    const pa = if (a == .object) json_util.strFieldOrEmpty(a.object, "path") else "";
    const pb = if (b == .object) json_util.strFieldOrEmpty(b.object, "path") else "";
    return std.mem.lessThan(u8, pa, pb);
}

fn missingStatusArg(store: []const u8, usage: StatusUsage, what: []const u8) Error {
    usageError("{s} status needs {s}: clanker {s} status {s}", .{ store, what, store, usage.example });
    return Error.MissingArg;
}

// ----------------------------------------------------------------- tests --

const testing = std.testing;

fn parseValue(arena: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
}

test "request escapes strings, writes numbers unquoted, and omits an absent field" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings(
        "{\"action\":\"update\",\"old\":\"a \\\"quoted\\\" line\\n\"}",
        try request(arena, &.{
            .{ .name = "action", .value = .{ .text = "update" } },
            .{ .name = "old", .value = .{ .text = "a \"quoted\" line\n" } },
        }),
    );

    // A confidence is a number to the tool, not the string "7".
    try testing.expectEqualStrings(
        "{\"action\":\"recommend\",\"confidence\":7}",
        try request(arena, &.{
            .{ .name = "action", .value = .{ .text = "recommend" } },
            .{ .name = "confidence", .value = .{ .number = 7 } },
        }),
    );

    // An argument that was not given leaves out the field rather than sending
    // a null: the tools read a missing field as "not supplied".
    const absent: ?[]const u8 = null;
    const given: ?[]const u8 = "kv-stores";
    try testing.expectEqualStrings(
        "{\"action\":\"checklist\"}",
        try request(arena, &.{
            .{ .name = "action", .value = .{ .text = "checklist" } },
            .{ .name = "topic", .value = Field.optional(absent) },
        }),
    );
    try testing.expectEqualStrings(
        "{\"action\":\"checklist\",\"topic\":\"kv-stores\"}",
        try request(arena, &.{
            .{ .name = "action", .value = .{ .text = "checklist" } },
            .{ .name = "topic", .value = Field.optional(given) },
        }),
    );

    // Every field absent is still a well-formed object, not "{,}".
    try testing.expectEqualStrings(
        "{}",
        try request(arena, &.{.{ .name = "topic", .value = Field.optional(absent) }}),
    );
}

test "the field readers answer for a row that is not an object" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    // A tool answer's array holds whatever the tool put there; a bare string
    // row used to reach `.object` and panic rather than read as empty.
    const row = try parseValue(arena_state.allocator(), "\"not an object\"");
    try testing.expectEqual(false, boolField(row, "indexed"));
    try testing.expectEqual(@as(usize, 0), arrayField(row, "matches").len);
    try testing.expectEqual(@as(u64, 0), unsignedField(row, "line"));
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

    // A negative count reads as absent rather than wrapping through @intCast.
    var negative: Canned = .{ .answer = "{\"ok\":true,\"next_number\":-1}" };
    const wrapped = try callTool(arena_state.allocator(), "adr", .{ .ctx = &negative, .call = Canned.call }, "{}");
    try testing.expectEqual(@as(u64, 0), unsignedField(wrapped, "next_number"));
}
