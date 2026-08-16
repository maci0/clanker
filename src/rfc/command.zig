//! `clanker rfc <sub>`, the operator surface over the sandboxed `rfc` tool
//! (`tools/zig/rfc.zig`).
//!
//! Same arrangement as `reports/command.zig` and `research/command.zig`, for
//! the same reason: `cli.zig` owns argument parsing and the sandbox, printing
//! is neither, and the tool stays the single implementation of the store. The
//! tool call arrives through the `Tool` callback below, so this module renders
//! and tests without a WASM runtime.
//!
//! An RFC is the decision that has not been made yet. The renderer leads with
//! status, because "is this still open?" is the question a terminal reader has
//! before any other, and it prints the next free number on every listing so
//! the number to claim never has to be counted by hand.

const std = @import("std");
const log = @import("../util/log.zig");
const utf8 = @import("../util/utf8.zig");
const json_util = @import("../util/json.zig");

pub const Options = struct {
    /// "list" (default), "search", "open", "checklist", "create", "append",
    /// "update", "recommend" or "status".
    sub: []const u8 = "list",
    /// `search`: the query. `open`/`append`/`update`/`recommend`/`status`: the
    /// path. `create`: the title. `checklist`: the topic.
    arg1: ?[]const u8 = null,
    /// `create`: the overview. `append`: the content. `update`: the old text.
    /// `recommend`: the recommendation. `status`: the state.
    arg2: ?[]const u8 = null,
    /// `create`: the slug. `update`: the new text. `recommend`: the
    /// confidence. `status`: the note.
    arg3: ?[]const u8 = null,
    /// `recommend`: the rationale.
    arg4: ?[]const u8 = null,
};

pub const Error = error{
    BadSubcommand,
    MissingArg,
    /// The tool ran and refused the request (`{"ok":false,...}`), or answered
    /// something this command cannot read. The detail is already logged.
    ToolFailed,
};

/// How this command reaches the `rfc` WASM tool. `cli.zig` owns the registry,
/// the sandbox and the config a tool needs, so it passes the call in rather
/// than this module reaching back into it. Tests pass a canned answer through
/// the same seam.
pub const Tool = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, input: []const u8) anyerror![]const u8,
};

/// A matched line of an RFC, cut the same way `reports` cuts one.
const match_column_bytes: usize = 68;
/// Titles are the widest column and the least load-bearing: a reader who needs
/// the whole one opens the record.
const title_column_bytes: usize = 58;
/// Statuses are one word ("Draft", "Discussion", "Decided", ...).
const status_column_max: usize = 12;

pub fn cmd(init: std.process.Init, opts: Options, tool: Tool) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const sub = opts.sub;

    if (std.mem.eql(u8, sub, "list")) return list(io, arena, tool);
    if (std.mem.eql(u8, sub, "search")) return search(io, arena, opts, tool);
    if (std.mem.eql(u8, sub, "open")) return open(io, arena, opts, tool);
    if (std.mem.eql(u8, sub, "checklist")) return checklist(io, arena, opts, tool);
    if (std.mem.eql(u8, sub, "create")) return create(io, arena, opts, tool);
    if (std.mem.eql(u8, sub, "append")) return append(io, arena, opts, tool);
    if (std.mem.eql(u8, sub, "update")) return update(io, arena, opts, tool);
    if (std.mem.eql(u8, sub, "recommend")) return recommend(io, arena, opts, tool);
    if (std.mem.eql(u8, sub, "status")) return setStatus(io, arena, opts, tool);

    log.log(.error_, "unknown rfc subcommand '{s}' (expected list, search, open, checklist, create, append, update, recommend or status)", .{sub});
    return Error.BadSubcommand;
}

// ------------------------------------------------------------------ reading --

fn list(io: std.Io, arena: std.mem.Allocator, tool: Tool) !void {
    const result = try callTool(arena, tool, "{\"action\":\"list\"}");
    try out(io, try renderList(arena, arrayField(result, "rfcs"), unsignedField(result, "next_number")));
}

fn search(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const query = opts.arg1 orelse {
        log.log(.error_, "rfc search needs a query: clanker rfc search \"http client\"", .{});
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
    try out(io, try renderSearch(arena, query, arrayField(result, "rfcs"), arrayField(result, "adrs")));
}

fn open(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const path = opts.arg1 orelse {
        log.log(.error_, "rfc open needs a path: clanker rfc open docs/rfcs/<number>-<slug>.md", .{});
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
    // The RFC is markdown that was written to be read; print it as it is.
    const text = json_util.strFieldOrEmpty(result.object, "text");
    try out(io, text);
    if (text.len > 0 and text[text.len - 1] != '\n') try out(io, "\n");
}

/// What an RFC has to pin down, and the question to put to whoever asked for
/// it. This is the answer to "the request is too vague to draft from".
fn checklist(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    var input: std.Io.Writer.Allocating = .init(arena);
    defer input.deinit();
    var s = std.json.Stringify{ .writer = &input.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("action");
    try s.write("checklist");
    if (opts.arg1) |topic| {
        try s.objectField("topic");
        try s.write(topic);
    }
    try s.endObject();

    const result = try callTool(arena, tool, input.written());
    try out(io, try renderChecklist(arena, json_util.strFieldOrEmpty(result.object, "topic"), arrayField(result, "requirements")));
}

// ------------------------------------------------------------------ writing --

fn create(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const title = opts.arg1 orelse return missingCreateArg("a title naming the decision");
    const overview = opts.arg2 orelse return missingCreateArg("an overview of what has to be decided and why now");

    var input: std.Io.Writer.Allocating = .init(arena);
    defer input.deinit();
    var s = std.json.Stringify{ .writer = &input.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("action");
    try s.write("create");
    try s.objectField("title");
    try s.write(title);
    try s.objectField("overview");
    try s.write(overview);
    if (opts.arg3) |slug| {
        try s.objectField("slug");
        try s.write(slug);
    }
    try s.endObject();

    const result = try callTool(arena, tool, input.written());
    const path = json_util.strFieldOrEmpty(result.object, "path");
    var w: std.Io.Writer.Allocating = .init(arena);
    defer w.deinit();
    try w.writer.print("created {s}\n", .{path});
    // The scaffold is a skeleton, and an RFC with one option is not a
    // decision: saying so here is what keeps a stub from being mistaken for a
    // finished record.
    try w.writer.writeAll("\nAn RFC needs at least two candidates, the status quo, one out-of-the-box\noption, and a recommendation with a confidence from 0 to 10:\n");
    try w.writer.print("  clanker rfc open {s}\n", .{path});
    try w.writer.print("  clanker rfc recommend {s} \"<recommendation>\" <0-10> \"<rationale>\"\n", .{path});
    if (!boolField(result, "indexed")) {
        try w.writer.writeAll("\nThe inventory was not updated (it changed concurrently). Add the link\nby hand from docs/rfcs/README.md without replacing the other edit.\n");
    }
    try out(io, w.written());
}

fn missingCreateArg(what: []const u8) Error {
    log.log(.error_, "rfc create needs {s}: clanker rfc create \"HTTP client for the proxy\" \"The proxy needs one client and the choice is not recorded\"", .{what});
    return Error.MissingArg;
}

fn append(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const path = opts.arg1 orelse {
        log.log(.error_, "rfc append needs a path and markdown content: clanker rfc append docs/rfcs/<name>.md \"## Option C\\n\\n...\"", .{});
        return Error.MissingArg;
    };
    const content = opts.arg2 orelse {
        log.log(.error_, "rfc append needs the markdown to add after the path", .{});
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
        log.log(.error_, "rfc update needs a path, the exact old text, and its replacement", .{});
        return Error.MissingArg;
    };
    const old = opts.arg2 orelse {
        log.log(.error_, "rfc update needs the exact current text to replace; copy it from `clanker rfc open {s}`", .{path});
        return Error.MissingArg;
    };
    // An empty replacement deletes the old text, which the tool supports, so
    // the third argument has to be present but may be "".
    const new = opts.arg3 orelse {
        log.log(.error_, "rfc update needs replacement text after the old text (\"\" removes it)", .{});
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

/// The Recommendation section, which is the point of the document: a
/// recommendation with no confidence number is an opinion.
fn recommend(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const path = opts.arg1 orelse return missingRecommendArg("an RFC path");
    const text = opts.arg2 orelse return missingRecommendArg("the recommendation");
    const confidence_text = opts.arg3 orelse return missingRecommendArg("a confidence from 0 to 10");
    const rationale = opts.arg4 orelse "";

    const confidence = std.fmt.parseInt(u8, std.mem.trim(u8, confidence_text, " \t"), 10) catch {
        log.log(.error_, "rfc recommend needs a whole-number confidence from 0 to 10, not '{s}'", .{confidence_text});
        return Error.MissingArg;
    };
    if (confidence > 10) {
        log.log(.error_, "rfc recommend confidence is 0 to 10, not {d}", .{confidence});
        return Error.MissingArg;
    }

    var input: std.Io.Writer.Allocating = .init(arena);
    defer input.deinit();
    var s = std.json.Stringify{ .writer = &input.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("action");
    try s.write("recommend");
    try s.objectField("path");
    try s.write(path);
    try s.objectField("recommendation");
    try s.write(text);
    try s.objectField("confidence");
    try s.write(confidence);
    try s.objectField("rationale");
    try s.write(rationale);
    try s.endObject();

    const result = try callTool(arena, tool, input.written());
    try out(io, try std.fmt.allocPrint(arena, "recommended on {s} at confidence {d}/10\n", .{
        json_util.strFieldOrEmpty(result.object, "path"),
        unsignedField(result, "confidence"),
    }));
}

fn missingRecommendArg(what: []const u8) Error {
    log.log(.error_, "rfc recommend needs {s}: clanker rfc recommend docs/rfcs/<name>.md \"Adopt option B\" 7 \"Why, and what would move it\"", .{what});
    return Error.MissingArg;
}

fn setStatus(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const path = opts.arg1 orelse return missingStatusArg("an RFC path");
    const wanted = opts.arg2 orelse return missingStatusArg("a status: draft, discussion, decided, deferred, withdrawn or superseded");
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
        try w.writer.writeAll("\nThe inventory line was not updated (the entry is missing or the index\nchanged concurrently). Set its status by hand in docs/rfcs/README.md so\nthe index does not disagree with the record.\n");
    }
    try out(io, w.written());
}

fn missingStatusArg(what: []const u8) Error {
    log.log(.error_, "rfc status needs {s}: clanker rfc status docs/rfcs/<name>.md decided \"Chose option B; see the ADR\"", .{what});
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
        log.log(.error_, "rfc: the tool answered something that is not JSON", .{});
        return Error.ToolFailed;
    };
    if (parsed != .object) {
        log.log(.error_, "rfc: the tool answered something that is not a JSON object", .{});
        return Error.ToolFailed;
    }
    const ok = parsed.object.get("ok");
    if (ok == null or ok.? != .bool or !ok.?.bool) {
        const detail = if (parsed.object.get("error")) |e|
            (if (e == .string) e.string else "the tool refused the request")
        else
            "the tool refused the request";
        log.log(.error_, "rfc: {s}", .{detail});
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
/// counting it by hand off a directory listing is how two RFCs end up sharing
/// one.
pub fn renderList(arena: std.mem.Allocator, rfcs: []const std.json.Value, next_number: u64) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();

    if (rfcs.len == 0) {
        try w.writer.writeAll("no RFCs yet.\n\n");
        try w.writer.print("Open the first one as {d:0>4}:\n\n", .{next_number});
        try w.writer.writeAll("  clanker rfc create \"<decision>\" \"<what has to be decided and why now>\"\n");
        return w.written();
    }

    var status_width: usize = 6;
    for (rfcs) |r| {
        if (r != .object) continue;
        const s = json_util.strFieldOrEmpty(r.object, "status");
        const n = if (s.len == 0) 1 else s.len;
        if (n > status_width) status_width = @min(n, status_column_max);
    }

    try w.writer.print("{d} RFC(s)\n\n", .{rfcs.len});
    for (rfcs) |r| {
        if (r != .object) continue;
        const path = json_util.strFieldOrEmpty(r.object, "path");
        const title = json_util.strFieldOrEmpty(r.object, "title");
        // An unreadable RFC still gets a row: the path is what the reader
        // needs to go look, and hiding it would make it invisible.
        const status = if (json_util.strFieldOrEmpty(r.object, "status").len == 0)
            "?"
        else
            json_util.strFieldOrEmpty(r.object, "status");
        try w.writer.print("  {s}", .{utf8.cap(status, status_column_max)});
        var pad = status_width -| status.len;
        while (pad > 0) : (pad -= 1) try w.writer.writeByte(' ');
        try w.writer.print("  {s}\n", .{path});
        if (title.len > 0) {
            var indent = status_width + 4;
            while (indent > 0) : (indent -= 1) try w.writer.writeByte(' ');
            try w.writer.print("{s}\n", .{utf8.cap(title, title_column_bytes)});
        }
    }

    try w.writer.print("\nNEXT\n\n  next free number is {d:0>4}\n", .{next_number});
    try w.writer.writeAll("  clanker rfc open <path>          read one in full\n");
    return w.written();
}

/// RFCs and ADRs are searched together on purpose: a matching ADR means the
/// decision is already made, and that is the one answer that should stop an
/// RFC from being written at all. The renderer says so rather than leaving a
/// reader to notice which heading a hit fell under.
pub fn renderSearch(
    arena: std.mem.Allocator,
    query: []const u8,
    rfcs: []const std.json.Value,
    adrs: []const std.json.Value,
) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();

    if (rfcs.len == 0 and adrs.len == 0) {
        try w.writer.print("no RFC or ADR mentions \"{s}\".\n\n", .{query});
        try w.writer.writeAll("Open the decision rather than re-litigating it in a commit message:\n\n");
        try w.writer.writeAll("  clanker rfc create \"<decision>\" \"<what has to be decided and why now>\"\n");
        return w.written();
    }

    try w.writer.print("{d} matching line(s) for \"{s}\"\n\n", .{ rfcs.len + adrs.len, query });
    try renderMatchGroup(&w.writer, "RFCS", rfcs);
    try renderMatchGroup(&w.writer, "ADRS", adrs);
    if (adrs.len > 0) {
        try w.writer.writeAll("An ADR matched: that decision may already be made. Read it before\nopening an RFC over the same ground.\n\n");
    }
    try w.writer.writeAll("NEXT\n\n");
    try w.writer.writeAll("  clanker rfc open <path>          read the record before trusting it\n");
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

/// The checklist is a list of questions to put to a person, so each one is
/// printed as the question, with what it pins down under it.
pub fn renderChecklist(arena: std.mem.Allocator, topic: []const u8, requirements: []const std.json.Value) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();

    if (topic.len > 0) {
        try w.writer.print("What an RFC on \"{s}\" has to pin down\n\n", .{topic});
    } else {
        try w.writer.writeAll("What an RFC has to pin down\n\n");
    }

    if (requirements.len == 0) {
        try w.writer.writeAll("  the tool returned no requirements\n");
        return w.written();
    }

    for (requirements) |r| {
        if (r != .object) continue;
        const needs = json_util.strFieldOrEmpty(r.object, "needs");
        const why = json_util.strFieldOrEmpty(r.object, "why");
        const ask = json_util.strFieldOrEmpty(r.object, "ask");
        try w.writer.print("  {s}\n", .{needs});
        if (why.len > 0) try w.writer.print("      {s}\n", .{why});
        if (ask.len > 0) try w.writer.print("      ask: {s}\n", .{ask});
        try w.writer.writeByte('\n');
    }
    return w.written();
}

/// One line of a record, cut to the column on a UTF-8 boundary. RFC text is
/// full of em dashes and arrows, and half a codepoint renders as a replacement
/// character right where the reader is trying to recognize the line.
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
    try testing.expect(std.mem.find(u8, text, "no RFCs yet") != null);
    // Zero-padded, because that is the filename form the number is used in.
    try testing.expect(std.mem.find(u8, text, "0001") != null);
}

test "renderList prints status, path and title for each RFC" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rfcs = try parseValue(arena,
        \\[{"path":"docs/rfcs/0001-http-client.md","title":"HTTP client for the proxy","status":"Discussion"},
        \\ {"path":"docs/rfcs/0002-store.md","title":"State store","status":"Decided"}]
    );
    const text = try renderList(arena, rfcs.array.items, 3);
    try testing.expect(std.mem.find(u8, text, "2 RFC(s)") != null);
    try testing.expect(std.mem.find(u8, text, "docs/rfcs/0001-http-client.md") != null);
    try testing.expect(std.mem.find(u8, text, "HTTP client for the proxy") != null);
    try testing.expect(std.mem.find(u8, text, "Discussion") != null);
    try testing.expect(std.mem.find(u8, text, "Decided") != null);
    try testing.expect(std.mem.find(u8, text, "0003") != null);
}

test "renderList still lists an RFC whose status could not be read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rfcs = try parseValue(arena,
        \\[{"path":"docs/rfcs/0009-unreadable.md","title":"","status":""}]
    );
    const text = try renderList(arena, rfcs.array.items, 10);
    // The path is what a reader needs in order to go look; dropping the row
    // would make an unreadable record invisible.
    try testing.expect(std.mem.find(u8, text, "docs/rfcs/0009-unreadable.md") != null);
    try testing.expect(std.mem.find(u8, text, "?") != null);
}

test "renderSearch says a matching ADR may already have decided it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const adrs = try parseValue(arena,
        \\[{"file":"docs/adrs/0003-zwasm.md","line":12,"text":"we use zwasm for the sandbox"}]
    );
    const text = try renderSearch(arena, "zwasm", &.{}, adrs.array.items);
    try testing.expect(std.mem.find(u8, text, "ADRS") != null);
    try testing.expect(std.mem.find(u8, text, "docs/adrs/0003-zwasm.md") != null);
    try testing.expect(std.mem.find(u8, text, "may already be made") != null);
}

test "renderSearch with no hits points at create rather than reporting an error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try renderSearch(arena, "quantum", &.{}, &.{});
    try testing.expect(std.mem.find(u8, text, "no RFC or ADR mentions") != null);
    try testing.expect(std.mem.find(u8, text, "clanker rfc create") != null);
}

test "renderChecklist prints the question to ask under each requirement" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const reqs = try parseValue(arena,
        \\[{"needs":"the decision as a question","why":"an RFC without one drifts","ask":"What exactly is being decided?"}]
    );
    const text = try renderChecklist(arena, "http client", reqs.array.items);
    try testing.expect(std.mem.find(u8, text, "http client") != null);
    try testing.expect(std.mem.find(u8, text, "the decision as a question") != null);
    try testing.expect(std.mem.find(u8, text, "ask: What exactly is being decided?") != null);
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
    var canned: Canned = .{ .payload = "{\"ok\":false,\"error\":\"path must be below docs/rfcs/\"}" };
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
