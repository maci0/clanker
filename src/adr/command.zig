//! `clanker adr <sub>`, the operator surface over the sandboxed `adr` tool
//! (`tools/zig/adr.zig`).
//!
//! Same arrangement as `rfc/command.zig` and `reports/command.zig`, for the
//! same reason: `cli.zig` owns argument parsing and the sandbox, printing is
//! neither, and the tool stays the single implementation of the store. The
//! tool call arrives through the `Tool` callback below, so this module renders
//! and tests without a WASM runtime.
//!
//! An ADR is the decision already made. The listing therefore leads with the
//! status, because the question a reader has about a decision record is
//! whether it still holds — a Superseded ADR read as current is worse than not
//! finding it at all.

const std = @import("std");
const log = @import("../util/log.zig");
const utf8 = @import("../util/utf8.zig");
const json_util = @import("../util/json.zig");

pub const Options = struct {
    /// "list" (default), "search", "open", "create", "append", "update" or
    /// "status".
    sub: []const u8 = "list",
    /// `search`: the query. `open`/`append`/`update`/`status`: the path.
    /// `create`: the title.
    arg1: ?[]const u8 = null,
    /// `create`: the context. `append`: the content. `update`: the old text.
    /// `status`: the state.
    arg2: ?[]const u8 = null,
    /// `create`: the decision. `update`: the new text. `status`: the note.
    arg3: ?[]const u8 = null,
    /// `create`: the consequences.
    arg4: ?[]const u8 = null,
    /// `create`: the RFC this decision came from.
    arg5: ?[]const u8 = null,
};

pub const Error = error{
    BadSubcommand,
    MissingArg,
    /// The tool ran and refused the request (`{"ok":false,...}`), or answered
    /// something this command cannot read. The detail is already logged.
    ToolFailed,
};

/// How this command reaches the `adr` WASM tool. `cli.zig` owns the registry,
/// the sandbox and the config a tool needs, so it passes the call in rather
/// than this module reaching back into it. Tests pass a canned answer through
/// the same seam.
pub const Tool = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, input: []const u8) anyerror![]const u8,
};

/// A matched line of an ADR, cut the same way `rfc` cuts one.
const match_column_bytes: usize = 68;
/// Titles are the widest column and the least load-bearing: a reader who needs
/// the whole one opens the record.
const title_column_bytes: usize = 62;
/// Statuses are one word ("Accepted", "Superseded", ...).
const status_column_max: usize = 12;

pub fn cmd(init: std.process.Init, opts: Options, tool: Tool) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const sub = opts.sub;

    if (std.mem.eql(u8, sub, "list")) return list(io, arena, tool);
    if (std.mem.eql(u8, sub, "search")) return search(io, arena, opts, tool);
    if (std.mem.eql(u8, sub, "open")) return open(io, arena, opts, tool);
    if (std.mem.eql(u8, sub, "create")) return create(io, arena, opts, tool);
    if (std.mem.eql(u8, sub, "append")) return append(io, arena, opts, tool);
    if (std.mem.eql(u8, sub, "update")) return update(io, arena, opts, tool);
    if (std.mem.eql(u8, sub, "status")) return setStatus(io, arena, opts, tool);

    log.log(.error_, "unknown adr subcommand '{s}' (expected list, search, open, create, append, update or status)", .{sub});
    return Error.BadSubcommand;
}

// ------------------------------------------------------------------ reading --

fn list(io: std.Io, arena: std.mem.Allocator, tool: Tool) !void {
    const result = try callTool(arena, tool, "{\"action\":\"list\"}");
    try out(io, try renderList(arena, arrayField(result, "adrs"), unsignedField(result, "next_number")));
}

fn search(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const query = opts.arg1 orelse {
        log.log(.error_, "adr search needs a query: clanker adr search \"provider vtable\"", .{});
        return Error.MissingArg;
    };

    var input: std.Io.Writer.Allocating = .init(arena);
    defer input.deinit();
    var s = std.json.Stringify{ .writer = &input.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("action");
    try s.write("search");
    try s.objectField("query");
    try s.write(query);
    try s.endObject();

    const result = try callTool(arena, tool, input.written());
    try out(io, try renderSearch(
        arena,
        query,
        arrayField(result, "adrs"),
        arrayField(result, "rfcs"),
        arrayField(result, "prds"),
    ));
}

fn open(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const path = opts.arg1 orelse {
        log.log(.error_, "adr open needs a path: clanker adr open docs/adrs/<number>-<slug>.md", .{});
        return Error.MissingArg;
    };

    var input: std.Io.Writer.Allocating = .init(arena);
    defer input.deinit();
    var s = std.json.Stringify{ .writer = &input.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("action");
    try s.write("open");
    try s.objectField("path");
    try s.write(path);
    try s.endObject();

    const result = try callTool(arena, tool, input.written());
    // The ADR is markdown that was written to be read; print it as it is.
    const text = json_util.strFieldOrEmpty(result.object, "text");
    try out(io, text);
    if (text.len > 0 and text[text.len - 1] != '\n') try out(io, "\n");
}

// ------------------------------------------------------------------ writing --

fn create(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const title = opts.arg1 orelse return missingCreateArg("a title phrased as the choice made");
    const context = opts.arg2 orelse return missingCreateArg("the context: the constraint that forced a choice");
    const decision = opts.arg3 orelse return missingCreateArg("the decision itself, in one or two sentences");
    const consequences = opts.arg4 orelse return missingCreateArg("the consequences, including the honest downside");

    var input: std.Io.Writer.Allocating = .init(arena);
    defer input.deinit();
    var s = std.json.Stringify{ .writer = &input.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("action");
    try s.write("create");
    try s.objectField("title");
    try s.write(title);
    try s.objectField("context");
    try s.write(context);
    try s.objectField("decision");
    try s.write(decision);
    try s.objectField("consequences");
    try s.write(consequences);
    if (opts.arg5) |rfc| {
        try s.objectField("rfc");
        try s.write(rfc);
    }
    try s.endObject();

    const result = try callTool(arena, tool, input.written());
    try out(io, try renderCreated(
        arena,
        json_util.strFieldOrEmpty(result.object, "path"),
        json_util.strFieldOrEmpty(result.object, "rfc"),
        boolField(result, "indexed"),
    ));
}

/// What to do with the record once it exists. The RFC line is printed only
/// when one was linked, because closing an RFC that does not exist is the kind
/// of instruction that teaches a reader to skim past this block.
pub fn renderCreated(arena: std.mem.Allocator, path: []const u8, rfc: []const u8, indexed: bool) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();

    try w.writer.print("created {s}\n", .{path});
    try w.writer.writeAll("\nConsequences is the section that decides whether this record is worth\nanything later: it has to name what the decision forecloses, not only\nwhat it buys.\n\n");
    try w.writer.print("  clanker adr open {s}\n", .{path});
    if (rfc.len > 0) {
        try w.writer.writeAll("\nThe RFC this came from is still open. Close it out so the two stores agree:\n\n");
        try w.writer.print("  clanker rfc status {s} decided \"<note naming this ADR>\"\n", .{rfc});
    }
    if (!indexed) {
        try w.writer.writeAll("\nThe inventory was not updated (it changed concurrently). Add the link\nby hand from docs/adrs/README.md without replacing the other edit.\n");
    }
    return w.written();
}

fn missingCreateArg(what: []const u8) Error {
    log.log(.error_, "adr create needs {s}: clanker adr create \"<decision as the choice made>\" \"<context>\" \"<decision>\" \"<consequences>\" [rfc path]", .{what});
    return Error.MissingArg;
}

fn append(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const path = opts.arg1 orelse {
        log.log(.error_, "adr append needs a path and markdown content: clanker adr append docs/adrs/<name>.md \"## Revision\\n\\n...\"", .{});
        return Error.MissingArg;
    };
    const content = opts.arg2 orelse {
        log.log(.error_, "adr append needs the markdown to add after the path", .{});
        return Error.MissingArg;
    };

    var input: std.Io.Writer.Allocating = .init(arena);
    defer input.deinit();
    var s = std.json.Stringify{ .writer = &input.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("action");
    try s.write("append");
    try s.objectField("path");
    try s.write(path);
    try s.objectField("content");
    try s.write(content);
    try s.endObject();

    const result = try callTool(arena, tool, input.written());
    try out(io, try std.fmt.allocPrint(arena, "appended to {s}\n", .{json_util.strFieldOrEmpty(result.object, "path")}));
}

fn update(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const path = opts.arg1 orelse {
        log.log(.error_, "adr update needs a path, the exact old text, and its replacement", .{});
        return Error.MissingArg;
    };
    const old = opts.arg2 orelse {
        log.log(.error_, "adr update needs the exact current text to replace; copy it from `clanker adr open {s}`", .{path});
        return Error.MissingArg;
    };
    // An empty replacement deletes the old text, which the tool supports, so
    // the third argument has to be present but may be "".
    const new = opts.arg3 orelse {
        log.log(.error_, "adr update needs replacement text after the old text (\"\" removes it)", .{});
        return Error.MissingArg;
    };

    var input: std.Io.Writer.Allocating = .init(arena);
    defer input.deinit();
    var s = std.json.Stringify{ .writer = &input.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("action");
    try s.write("update");
    try s.objectField("path");
    try s.write(path);
    try s.objectField("old");
    try s.write(old);
    try s.objectField("new");
    try s.write(new);
    try s.endObject();

    const result = try callTool(arena, tool, input.written());
    try out(io, try std.fmt.allocPrint(arena, "updated {s}\n", .{json_util.strFieldOrEmpty(result.object, "path")}));
}

fn setStatus(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const path = opts.arg1 orelse return missingStatusArg("an ADR path");
    const wanted = opts.arg2 orelse return missingStatusArg("a status: proposed, accepted, superseded or deprecated");
    const note = opts.arg3 orelse "";

    var input: std.Io.Writer.Allocating = .init(arena);
    defer input.deinit();
    var s = std.json.Stringify{ .writer = &input.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("action");
    try s.write("status");
    try s.objectField("path");
    try s.write(path);
    try s.objectField("status");
    try s.write(wanted);
    try s.objectField("note");
    try s.write(note);
    try s.endObject();

    const result = try callTool(arena, tool, input.written());
    var w: std.Io.Writer.Allocating = .init(arena);
    defer w.deinit();
    try w.writer.print("{s} is now {s}\n", .{
        json_util.strFieldOrEmpty(result.object, "path"),
        json_util.strFieldOrEmpty(result.object, "status"),
    });
    if (!boolField(result, "indexed")) {
        try w.writer.writeAll("\nThe inventory line was not updated (the entry is missing or the index\nchanged concurrently). Set its status by hand in docs/adrs/README.md so\nthe index does not disagree with the record.\n");
    }
    try out(io, w.written());
}

fn missingStatusArg(what: []const u8) Error {
    log.log(.error_, "adr status needs {s}: clanker adr status docs/adrs/<name>.md superseded \"Superseded by ADR 0021.\"", .{what});
    return Error.MissingArg;
}

// ----------------------------------------------------------------- the tool --

/// One call, one place that decides whether the answer is usable. A tool that
/// refuses says why in `error`, and that sentence is written for whoever asked
/// -- it names the conflict to reopen or the argument to fix -- so it is the
/// message, not a generic failure.
fn callTool(arena: std.mem.Allocator, tool: Tool, input: []const u8) !std.json.Value {
    const raw = try tool.call(tool.ctx, input);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{ .ignore_unknown_fields = true }) catch {
        log.log(.error_, "adr: the tool answered something that is not JSON", .{});
        return Error.ToolFailed;
    };
    if (parsed != .object) {
        log.log(.error_, "adr: the tool answered something that is not a JSON object", .{});
        return Error.ToolFailed;
    }
    const ok = parsed.object.get("ok");
    if (ok == null or ok.? != .bool or !ok.?.bool) {
        const detail = if (parsed.object.get("error")) |e|
            (if (e == .string) e.string else "the tool refused the request")
        else
            "the tool refused the request";
        log.log(.error_, "adr: {s}", .{detail});
        return Error.ToolFailed;
    }
    return parsed;
}

fn boolField(obj: std.json.Value, name: []const u8) bool {
    const v = obj.object.get(name) orelse return false;
    return v == .bool and v.bool;
}

fn arrayField(obj: std.json.Value, name: []const u8) []const std.json.Value {
    const v = obj.object.get(name) orelse return &.{};
    return if (v == .array) v.array.items else &.{};
}

/// A count off the tool, never negative. `@intCast` of a negative `integer`
/// wraps in ReleaseFast, so the sign is checked rather than assumed.
fn unsignedField(obj: std.json.Value, name: []const u8) u64 {
    const v = obj.object.get(name) orelse return 0;
    if (v != .integer or v.integer < 0) return 0;
    return @intCast(v.integer);
}

// -------------------------------------------------------------- the listing --

/// The listing: status first, then path, then title.
///
/// `next_number` is printed even when nothing is listed, because the first
/// thing anyone does after reading the index is claim the next number, and
/// counting it by hand off a directory listing is how two ADRs end up sharing
/// one.
pub fn renderList(arena: std.mem.Allocator, raw_adrs: []const std.json.Value, next_number: u64) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();

    // The tool reports the directory listing's own order, which is arbitrary.
    // A numbered store is read in number order, and the number leads the
    // filename, so sorting on the path is sorting on the number.
    const adrs = try arena.dupe(std.json.Value, raw_adrs);
    std.mem.sort(std.json.Value, adrs, {}, byPath);

    if (adrs.len == 0) {
        try w.writer.writeAll("no ADRs yet.\n\n");
        try w.writer.print("Record the first decision as {d:0>4}:\n\n", .{next_number});
        try w.writer.writeAll("  clanker adr create \"<the choice made>\" \"<context>\" \"<decision>\" \"<consequences>\"\n");
        return w.written();
    }

    var status_width: usize = 8;
    for (adrs) |r| {
        if (r != .object) continue;
        const s = json_util.strFieldOrEmpty(r.object, "status");
        const n = if (s.len == 0) 1 else s.len;
        if (n > status_width) status_width = @min(n, status_column_max);
    }

    try w.writer.print("{d} ADR(s)\n\n", .{adrs.len});
    for (adrs) |r| {
        if (r != .object) continue;
        const path = json_util.strFieldOrEmpty(r.object, "path");
        const title = json_util.strFieldOrEmpty(r.object, "title");
        // An unreadable ADR still gets a row: the path is what the reader
        // needs in order to go look, and hiding it would make it invisible.
        const raw_status = json_util.strFieldOrEmpty(r.object, "status");
        const status = if (raw_status.len == 0) "?" else raw_status;
        try w.writer.print("  {s}", .{utf8.cap(status, status_column_max)});
        var pad = status_width -| status.len;
        while (pad > 0) : (pad -= 1) try w.writer.writeByte(' ');
        try w.writer.print("  {s}\n", .{path});
        if (title.len > 0) {
            var indent = status_width + 4;
            while (indent > 0) : (indent -= 1) try w.writer.writeByte(' ');
            try w.writer.print("{s}\n", .{utf8.cap(stripAdrPrefix(title), title_column_bytes)});
        }
    }

    try w.writer.print("\nNEXT\n\n  next free number is {d:0>4}\n", .{next_number});
    try w.writer.writeAll("  clanker adr open <path>          read one in full\n");
    return w.written();
}

fn byPath(_: void, a: std.json.Value, b: std.json.Value) bool {
    const pa = if (a == .object) json_util.strFieldOrEmpty(a.object, "path") else "";
    const pb = if (b == .object) json_util.strFieldOrEmpty(b.object, "path") else "";
    return std.mem.lessThan(u8, pa, pb);
}

/// Every ADR title in the store repeats its own number — "ADR 0001 — X", and
/// in three files "ADR 0014: X". The path in the row above already carries it,
/// so the prefix is dropped for display only; the document keeps it.
fn stripAdrPrefix(title: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, title, "ADR ")) return title;
    var i: usize = "ADR ".len;
    const digits_start = i;
    while (i < title.len and std.ascii.isDigit(title[i])) i += 1;
    if (i == digits_start) return title;
    // Either separator, then whatever follows it.
    if (std.mem.startsWith(u8, title[i..], ": ")) return title[i + 2 ..];
    if (std.mem.startsWith(u8, title[i..], " \u{2014} ")) return title[i + 5 ..];
    return title;
}

/// ADRs, RFCs and PRDs are searched together on purpose. Which store a hit
/// lands in *is* the answer: an ADR means it is settled, an RFC means the same
/// ground is still open, and a PRD means a feature already specifies around
/// it. The renderer says so rather than leaving a reader to notice which
/// heading a hit fell under.
pub fn renderSearch(
    arena: std.mem.Allocator,
    query: []const u8,
    adrs: []const std.json.Value,
    rfcs: []const std.json.Value,
    prds: []const std.json.Value,
) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();

    if (adrs.len == 0 and rfcs.len == 0 and prds.len == 0) {
        try w.writer.print("no ADR, RFC or PRD mentions \"{s}\".\n\n", .{query});
        try w.writer.writeAll("Record the decision rather than leaving it in a commit message:\n\n");
        try w.writer.writeAll("  clanker adr create \"<the choice made>\" \"<context>\" \"<decision>\" \"<consequences>\"\n");
        return w.written();
    }

    try w.writer.print("{d} matching line(s) for \"{s}\"\n\n", .{ adrs.len + rfcs.len + prds.len, query });
    try renderMatchGroup(&w.writer, "ADRS", adrs);
    try renderMatchGroup(&w.writer, "RFCS", rfcs);
    try renderMatchGroup(&w.writer, "PRDS", prds);
    if (adrs.len > 0) {
        try w.writer.writeAll("An ADR matched: this is already decided. Read it before re-opening the\nquestion, and supersede it rather than editing it if it has to change.\n\n");
    } else if (rfcs.len > 0) {
        try w.writer.writeAll("Only RFCs matched: the question is open, not settled. Write the ADR once\nit is decided.\n\n");
    }
    try w.writer.writeAll("NEXT\n\n");
    try w.writer.writeAll("  clanker adr open <path>          read the record before trusting it\n");
    return w.written();
}

fn renderMatchGroup(w: *std.Io.Writer, heading: []const u8, matches: []const std.json.Value) !void {
    if (matches.len == 0) return;
    try w.print("{s}\n\n", .{heading});

    var last_file: []const u8 = "";
    for (matches) |m| {
        if (m != .object) continue;
        const file = json_util.strFieldOrEmpty(m.object, "file");
        const text = json_util.strFieldOrEmpty(m.object, "text");
        // A line number is printed unsigned: `{d}` on an i64 carries an
        // explicit `+`, which reads as a diff marker in a column of numbers.
        const line: u64 = blk: {
            const l = m.object.get("line") orelse break :blk 0;
            if (l != .integer or l.integer < 0) break :blk 0;
            break :blk @intCast(l.integer);
        };
        if (!std.mem.eql(u8, file, last_file)) {
            if (last_file.len > 0) try w.writeByte('\n');
            try w.print("  {s}\n", .{file});
            last_file = file;
        }
        try w.print("    {d: >5}  {s}\n", .{ line, ellipsize(text, match_column_bytes) });
    }
    try w.writeAll("\n");
}

/// One line of a record, cut to the column on a UTF-8 boundary. ADR text is
/// full of em dashes and backticks, and half a codepoint renders as a
/// replacement character right where the reader is trying to recognize it.
fn ellipsize(s: []const u8, max: usize) []const u8 {
    const flat = std.mem.trim(u8, s, " \t\r\n");
    return utf8.cap(flat, max);
}

fn out(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

// -------------------------------------------------------------------- tests --

const testing = std.testing;

fn parseValue(arena: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
}

test "renderList names the next free number when there is nothing to list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try renderList(arena, &.{}, 1);
    try testing.expect(std.mem.find(u8, text, "no ADRs yet") != null);
    // Zero-padded, because that is the filename form the number is used in.
    try testing.expect(std.mem.find(u8, text, "0001") != null);
}

test "renderList prints status, path and title for each ADR" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const adrs = try parseValue(arena,
        \\[{"path":"docs/adrs/0004-providers.md","title":"Providers are a native vtable","status":"Accepted"},
        \\ {"path":"docs/adrs/0002-old.md","title":"An earlier call","status":"Superseded"}]
    );
    const text = try renderList(arena, adrs.array.items, 18);
    try testing.expect(std.mem.find(u8, text, "2 ADR(s)") != null);
    try testing.expect(std.mem.find(u8, text, "docs/adrs/0004-providers.md") != null);
    try testing.expect(std.mem.find(u8, text, "Providers are a native vtable") != null);
    // A superseded ADR read as current is the failure this column prevents.
    try testing.expect(std.mem.find(u8, text, "Superseded") != null);
    try testing.expect(std.mem.find(u8, text, "0018") != null);
}

test "renderList sorts by path, because the store is numbered" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The tool reports whatever order the directory listing came back in.
    const adrs = try parseValue(arena,
        \\[{"path":"docs/adrs/0011-c.md","title":"C","status":"Accepted"},
        \\ {"path":"docs/adrs/0002-a.md","title":"A","status":"Accepted"},
        \\ {"path":"docs/adrs/0004-b.md","title":"B","status":"Accepted"}]
    );
    const text = try renderList(arena, adrs.array.items, 18);
    const a = std.mem.find(u8, text, "0002-a.md").?;
    const b = std.mem.find(u8, text, "0004-b.md").?;
    const c = std.mem.find(u8, text, "0011-c.md").?;
    try testing.expect(a < b);
    try testing.expect(b < c);
}

test "renderList drops the ADR number prefix the path already carries" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Both punctuations occur in the tree: "ADR 0001 — X" and "ADR 0014: X".
    const adrs = try parseValue(arena,
        \\[{"path":"docs/adrs/0001-board.md","title":"ADR 0001 — The board is a chatroom","status":"Accepted"},
        \\ {"path":"docs/adrs/0014-uploads.md","title":"ADR 0014: Uploads land in Knowledge","status":"Accepted"}]
    );
    const text = try renderList(arena, adrs.array.items, 18);
    try testing.expect(std.mem.find(u8, text, "The board is a chatroom") != null);
    try testing.expect(std.mem.find(u8, text, "Uploads land in Knowledge") != null);
    // The redundant prefix is gone from the title column.
    try testing.expect(std.mem.find(u8, text, "ADR 0001 —") == null);
    try testing.expect(std.mem.find(u8, text, "ADR 0014:") == null);
}

test "renderList keeps a title that is not a number prefix" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const adrs = try parseValue(arena,
        \\[{"path":"docs/adrs/0001-x.md","title":"ADRs are a good idea","status":"Accepted"}]
    );
    const text = try renderList(arena, adrs.array.items, 2);
    try testing.expect(std.mem.find(u8, text, "ADRs are a good idea") != null);
}

test "renderList still lists an ADR whose status could not be read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const adrs = try parseValue(arena,
        \\[{"path":"docs/adrs/0009-unreadable.md","title":"","status":""}]
    );
    const text = try renderList(arena, adrs.array.items, 10);
    try testing.expect(std.mem.find(u8, text, "docs/adrs/0009-unreadable.md") != null);
    try testing.expect(std.mem.find(u8, text, "?") != null);
}

test "renderSearch says an ADR hit means the question is settled" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const adrs = try parseValue(arena,
        \\[{"file":"docs/adrs/0004-providers.md","line":12,"text":"providers are a native vtable"}]
    );
    const text = try renderSearch(arena, "vtable", adrs.array.items, &.{}, &.{});
    try testing.expect(std.mem.find(u8, text, "ADRS") != null);
    try testing.expect(std.mem.find(u8, text, "already decided") != null);
    try testing.expect(std.mem.find(u8, text, "supersede it rather than editing it") != null);
}

test "renderSearch distinguishes an open RFC from a settled ADR" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rfcs = try parseValue(arena,
        \\[{"file":"docs/rfcs/0006-locks.md","line":3,"text":"where ck_cas lock sidecars live"}]
    );
    const text = try renderSearch(arena, "lock", &.{}, rfcs.array.items, &.{});
    try testing.expect(std.mem.find(u8, text, "RFCS") != null);
    try testing.expect(std.mem.find(u8, text, "open, not settled") != null);
    // The settled-decision warning must not fire when nothing is settled.
    try testing.expect(std.mem.find(u8, text, "already decided") == null);
}

test "renderSearch with no hits points at create rather than reporting an error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try renderSearch(arena, "quantum", &.{}, &.{}, &.{});
    try testing.expect(std.mem.find(u8, text, "no ADR, RFC or PRD mentions") != null);
    try testing.expect(std.mem.find(u8, text, "clanker adr create") != null);
}

test "renderCreated points at the RFC to close only when one was linked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const linked = try renderCreated(arena, "docs/adrs/0018-x.md", "docs/rfcs/0006-y.md", true);
    try testing.expect(std.mem.find(u8, linked, "clanker rfc status docs/rfcs/0006-y.md decided") != null);

    const unlinked = try renderCreated(arena, "docs/adrs/0018-x.md", "", true);
    try testing.expect(std.mem.find(u8, unlinked, "clanker rfc status") == null);
    // The consequences reminder is unconditional: it is the section that
    // decides whether the record is worth anything later.
    try testing.expect(std.mem.find(u8, unlinked, "forecloses") != null);
}

test "renderCreated reports an inventory that could not be updated" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try renderCreated(arena, "docs/adrs/0018-x.md", "", false);
    try testing.expect(std.mem.find(u8, text, "inventory was not updated") != null);
    try testing.expect(std.mem.find(u8, text, "docs/adrs/README.md") != null);
}

test "callTool reports the tool's own refusal sentence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Canned = struct {
        payload: []const u8,
        fn call(ctx: *anyopaque, _: []const u8) anyerror![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.payload;
        }
    };
    var canned: Canned = .{ .payload = "{\"ok\":false,\"error\":\"a superseded ADR needs a note naming what supersedes it\"}" };
    const tool: Tool = .{ .ctx = &canned, .call = Canned.call };
    try testing.expectError(Error.ToolFailed, callTool(arena, tool, "{}"));
}

test "unsignedField refuses a negative count instead of wrapping it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try parseValue(arena, "{\"next_number\":-1,\"good\":7}");
    try testing.expectEqual(@as(u64, 0), unsignedField(v, "next_number"));
    try testing.expectEqual(@as(u64, 7), unsignedField(v, "good"));
}
