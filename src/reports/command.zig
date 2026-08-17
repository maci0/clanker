//! `clanker reports <sub>`, the operator surface over the sandboxed `reports`
//! tool (`tools/zig/reports.zig`).
//!
//! Lives here rather than in `cli.zig` for the reason `schedule/command.zig`
//! does: `cli.zig` owns argument parsing and dispatch, and a subsystem's own
//! printing is not argument parsing. The tool call itself stays in `cli.zig`
//! behind the `Tool` callback below, so this module renders and tests without
//! a WASM runtime.
//!
//! The tool answers in JSON built for a model. A person reading a terminal
//! wants the same records as a skimmable index: what exists, what state it is
//! in, and the path to paste into the next command. That translation is all
//! this file is.

const std = @import("std");
const log = @import("../util/log.zig");
const utf8 = @import("../util/utf8.zig");
const json_util = @import("../util/json.zig");

pub const Options = struct {
    /// "list" (default), "search", "open", "create", "append", "update" or
    /// "status".
    sub: []const u8 = "list",
    /// `search`: the query. `open`/`append`/`update`/`status`: the path.
    /// `create`: the record kind.
    arg1: ?[]const u8 = null,
    /// `create`: the slug. `append`: the content. `update`: the old text.
    /// `status`: the new state.
    arg2: ?[]const u8 = null,
    /// `create`: the title. `update`: the new text. `status`: the note.
    arg3: ?[]const u8 = null,
    /// `create`: the TL;DR summary.
    arg4: ?[]const u8 = null,
    /// `--kind` for `search`: "all" (default), "report" or "runbook". `create`
    /// takes its kind positionally, since there it is required rather than a
    /// filter.
    kind: ?[]const u8 = null,
};

pub const Error = error{
    BadSubcommand,
    MissingArg,
    /// The tool ran and refused the request (`{"ok":false,...}`), or answered
    /// something this command cannot read. The detail is already logged.
    ToolFailed,
};

/// How this command reaches the `reports` WASM tool. `cli.zig` owns the
/// registry, the sandbox and the config needed to load a tool, so it passes
/// the call in rather than this module reaching back into it. Tests pass a
/// canned answer through the same seam.
pub const Tool = struct {
    ctx: *anyopaque,
    /// Takes the tool's JSON input, returns its JSON output. The result is
    /// owned by the caller's arena.
    call: *const fn (ctx: *anyopaque, input: []const u8) anyerror![]const u8,
};

/// Statuses are one or two words ("Open", "Resolved", "Investigating"); a
/// runbook's inventory line carries a sentence instead. Past this many bytes
/// the trailing text is prose and gets its own line rather than a column.
const status_column_max: usize = 18;
/// Narrowest status column, so a listing of only "Open" records still leaves
/// the titles on a straight edge.
const status_column_min: usize = 10;
/// A matched line is one row of a search result; the rest of a 500-byte grep
/// hit belongs in the record, not in the summary. Sized so the row, its
/// four-space indent and its line number still fit an 80-column terminal,
/// which is the width the rest of clanker's output is written to.
const match_column_bytes: usize = 68;
/// Most matching lines one record contributes to a search result. A runbook
/// can match a query in hundreds of places, and printing them all pushes the
/// useful hits below the fold of the same terminal the result is read on; the
/// rest live in the record, where `clanker reports open <path>` shows them
/// with their surrounding context instead of a uniform column.
const max_search_lines_per_file: usize = 50;

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

    log.log(.error_, "unknown reports subcommand '{s}' (expected list, search, open, create, append, update or status)", .{sub});
    return Error.BadSubcommand;
}

// ------------------------------------------------------------------ reading --

fn list(io: std.Io, arena: std.mem.Allocator, tool: Tool) !void {
    const result = try callTool(arena, tool, "{\"action\":\"list\"}");
    const reports_index = json_util.strFieldOrEmpty(result.object, "reports_index");
    const runbooks_index = json_util.strFieldOrEmpty(result.object, "runbooks_index");
    try out(io, try renderList(arena, reports_index, runbooks_index));
}

fn search(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const query = opts.arg1 orelse {
        log.log(.error_, "reports search needs a query: clanker reports search \"worktree symlink\"", .{});
        return Error.MissingArg;
    };
    const kind = opts.kind orelse "all";

    var input: std.Io.Writer.Allocating = .init(arena);
    defer input.deinit();
    var s = std.json.Stringify{ .writer = &input.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("action");
    try s.write("search");
    try s.objectField("query");
    try s.write(query);
    try s.objectField("kind");
    try s.write(kind);
    try s.endObject();

    const result = try callTool(arena, tool, input.written());
    try out(io, try renderSearch(arena, query, kind, arrayField(result, "reports"), arrayField(result, "runbooks")));
}

fn open(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const path = opts.arg1 orelse {
        log.log(.error_, "reports open needs a path: clanker reports open docs/runbooks/<name>.md", .{});
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
    // The record is markdown that was written to be read; print it as it is
    // rather than reflowing someone's report in a pager-less terminal.
    const text = json_util.strFieldOrEmpty(result.object, "text");
    try out(io, text);
    if (text.len > 0 and text[text.len - 1] != '\n') try out(io, "\n");
}

// ------------------------------------------------------------------ writing --

fn create(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const kind = opts.arg1 orelse return missingCreateArg("a kind (bug, investigation, missing-tool or runbook)");
    const slug = opts.arg2 orelse return missingCreateArg("a slug");
    const title = opts.arg3 orelse return missingCreateArg("a title");
    const summary = opts.arg4 orelse return missingCreateArg("a TL;DR summary");

    var input: std.Io.Writer.Allocating = .init(arena);
    defer input.deinit();
    var s = std.json.Stringify{ .writer = &input.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("action");
    try s.write("create");
    try s.objectField("kind");
    try s.write(kind);
    try s.objectField("slug");
    try s.write(slug);
    try s.objectField("title");
    try s.write(title);
    try s.objectField("summary");
    try s.write(summary);
    try s.endObject();

    const result = try callTool(arena, tool, input.written());
    const path = json_util.strFieldOrEmpty(result.object, "path");
    var w: std.Io.Writer.Allocating = .init(arena);
    defer w.deinit();
    try w.writer.print("created {s}\n", .{path});
    // The scaffold is a skeleton: saying so here is what keeps a half-filled
    // record from being mistaken for a finished one.
    try w.writer.print("\nFill in the evidence, resolution and verification:\n  clanker reports open {s}\n", .{path});
    if (!boolField(result, "indexed")) {
        try w.writer.writeAll("\nThe inventory was not updated (it changed concurrently). Add the link\nby hand from the index README without replacing the other edit.\n");
    }
    try out(io, w.written());
}

fn missingCreateArg(what: []const u8) Error {
    log.log(.error_, "reports create needs {s}: clanker reports create investigation 2026-08-16-worktree-symlink \"Worktree setup rejects a symlink\" \"TL;DR of what was seen\"", .{what});
    return Error.MissingArg;
}

fn append(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const path = opts.arg1 orelse {
        log.log(.error_, "reports append needs a path and markdown content: clanker reports append docs/reports/bugs/<name>.md \"## New evidence\\n\\n...\"", .{});
        return Error.MissingArg;
    };
    const content = opts.arg2 orelse {
        log.log(.error_, "reports append needs the markdown to add after the path", .{});
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
        log.log(.error_, "reports update needs a path, the exact old text, and its replacement", .{});
        return Error.MissingArg;
    };
    const old = opts.arg2 orelse {
        log.log(.error_, "reports update needs the exact current text to replace; copy it from `clanker reports open {s}`", .{path});
        return Error.MissingArg;
    };
    // An empty replacement deletes the old text, which the tool supports, so
    // the third argument has to be present but may be "".
    const new = opts.arg3 orelse {
        log.log(.error_, "reports update needs replacement text after the old text (\"\" removes it)", .{});
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
    const path = opts.arg1 orelse return missingStatusArg("a record path");
    const wanted = opts.arg2 orelse return missingStatusArg("a state: open, investigating, resolved, reopened or closed");
    // The tool requires a note for "resolved", but every state reads better
    // with one, and asking here names the missing argument rather than
    // spending a tool call to be told.
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
        try w.writer.writeAll("\nThe inventory line was not updated (the entry is missing or the index\nchanged concurrently). Set its status by hand in docs/reports/README.md so\nthe index does not disagree with the record.\n");
    }
    try out(io, w.written());
}

fn missingStatusArg(what: []const u8) Error {
    log.log(.error_, "reports status needs {s}: clanker reports status docs/reports/bugs/<name>.md resolved \"Fixed in <commit>; verified by <check>\"", .{what});
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
        log.log(.error_, "reports: the tool answered something that is not JSON", .{});
        return Error.ToolFailed;
    };
    if (parsed != .object) {
        log.log(.error_, "reports: the tool answered something that is not a JSON object", .{});
        return Error.ToolFailed;
    }
    const ok = parsed.object.get("ok");
    if (ok == null or ok.? != .bool or !ok.?.bool) {
        const detail = if (parsed.object.get("error")) |e|
            (if (e == .string) e.string else "the tool refused the request")
        else
            "the tool refused the request";
        log.log(.error_, "reports: {s}", .{detail});
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

// --------------------------------------------------------------- the listing --

/// One inventory line of an index README, already resolved to a path a reader
/// can paste into `clanker reports open`.
pub const Entry = struct {
    title: []const u8,
    path: []const u8,
    /// The text after the em dash: a status for a report, a one-line summary
    /// for a runbook. Empty when the line carries neither.
    note: []const u8 = "",
};

const Section = struct {
    heading: []const u8,
    /// The `<!-- inventory:<kind>:start -->` marker this section is kept in.
    kind: []const u8,
    /// Inventory links are relative to the README that lists them.
    base_dir: []const u8,
    /// Which index README the block lives in.
    runbooks: bool = false,
};

const sections = [_]Section{
    .{ .heading = "BUGS", .kind = "bug", .base_dir = "docs/reports" },
    .{ .heading = "INVESTIGATIONS", .kind = "investigation", .base_dir = "docs/reports" },
    .{ .heading = "RUNBOOKS", .kind = "runbook", .base_dir = "docs/runbooks", .runbooks = true },
};

/// The whole index, one section per inventory block. Reports and runbooks are
/// printed together because that is how they are searched and how they are
/// used: the runbook is the current procedure, the report is why it is safe.
pub fn renderList(arena: std.mem.Allocator, reports_index: []const u8, runbooks_index: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();

    var total: usize = 0;
    for (sections) |sec| {
        const index = if (sec.runbooks) runbooks_index else reports_index;
        const entries = try inventory(arena, index, sec.kind, sec.base_dir);
        total += entries.len;

        try w.writer.print("{s}\n\n", .{sec.heading});
        if (entries.len == 0) {
            try w.writer.print("  (none yet in {s})\n\n", .{sec.base_dir});
            continue;
        }

        const width = statusWidth(entries);
        // The path sits under the title it belongs to. With no status column
        // to sit under -- a runbook inventory carries a summary, not a status
        // -- it is indented instead, so the titles stay the left edge that is
        // scanned and the detail stays visibly subordinate to them.
        const detail_indent = if (width == 0) 4 else 2 + width;
        for (entries) |e| {
            const status = if (e.note.len > 0 and e.note.len <= status_column_max) e.note else "";
            try w.writer.splatByteAll(' ', 2);
            try w.writer.print("{s}", .{status});
            try w.writer.splatByteAll(' ', width -| status.len);
            try w.writer.print("{s}\n", .{e.title});
            try w.writer.splatByteAll(' ', detail_indent);
            try w.writer.print("{s}\n", .{e.path});
            // Prose that would not fit the status column keeps its own line
            // rather than being cut down to a width it was never written for.
            if (status.len == 0 and e.note.len > 0) {
                try w.writer.splatByteAll(' ', detail_indent);
                try w.writer.print("{s}\n", .{e.note});
            }
            try w.writer.writeByte('\n');
        }
    }

    if (total == 0) {
        try w.writer.writeAll("Nothing is recorded yet. Start one with:\n\n");
        try w.writer.writeAll("  clanker reports create investigation <YYYY-MM-DD-slug> \"<title>\" \"<TL;DR>\"\n");
        return w.written();
    }

    try w.writer.writeAll("NEXT\n\n");
    try w.writer.writeAll("  clanker reports open <path>       print one record in full\n");
    try w.writer.writeAll("  clanker reports search \"<text>\"   search every report and runbook\n");
    return w.written();
}

/// Widest status that earned the column, so titles line up without the column
/// stretching to fit a sentence that is not a status. Zero when no entry in
/// the section has one at all: an empty column is 10 spaces of nothing in
/// front of every title.
fn statusWidth(entries: []const Entry) usize {
    var widest: usize = 0;
    for (entries) |e| {
        if (e.note.len == 0 or e.note.len > status_column_max) continue;
        // One space of gutter, so the widest status is not flush against the
        // title next to it.
        if (e.note.len + 1 > widest) widest = e.note.len + 1;
    }
    if (widest == 0) return 0;
    return @max(widest, status_column_min);
}

/// Read one `<!-- inventory:<kind>:start -->` block out of an index README.
///
/// The block is the index the `reports` tool itself maintains, so parsing it
/// here keeps one list rather than a second one that drifts. Anything that is
/// not a `- [title](link)` line is skipped: an inventory can carry a note or a
/// blank line between entries and still be an inventory.
pub fn inventory(
    arena: std.mem.Allocator,
    index_md: []const u8,
    kind: []const u8,
    base_dir: []const u8,
) ![]const Entry {
    var entries: std.ArrayList(Entry) = .empty;

    const start_marker = try std.fmt.allocPrint(arena, "<!-- inventory:{s}:start -->", .{kind});
    const end_marker = try std.fmt.allocPrint(arena, "<!-- inventory:{s}:end -->", .{kind});
    const start = std.mem.find(u8, index_md, start_marker) orelse return entries.items;
    const body_start = start + start_marker.len;
    const rest = index_md[body_start..];
    const body = rest[0..(std.mem.find(u8, rest, end_marker) orelse rest.len)];

    // An entry may wrap over several indented lines, so a line is only the end
    // of one when the next entry, a blank line, or the block itself begins.
    var current: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const starts_entry = std.mem.startsWith(u8, trimmed, "- ");
        if (starts_entry or trimmed.len == 0) {
            if (current.items.len > 0) {
                if (parseEntry(arena, current.items, base_dir)) |e| try entries.append(arena, e);
                current.clearRetainingCapacity();
            }
            if (!starts_entry) continue;
            try current.appendSlice(arena, trimmed[2..]);
            continue;
        }
        if (current.items.len == 0) continue;
        try current.append(arena, ' ');
        try current.appendSlice(arena, trimmed);
    }
    if (current.items.len > 0) {
        if (parseEntry(arena, current.items, base_dir)) |e| try entries.append(arena, e);
    }
    return entries.items;
}

/// `[Title](link) — Status` into its three parts, with the link resolved
/// against the index it was listed in.
///
/// Every field is copied out: `text` is the caller's line buffer, which is
/// cleared and refilled for the next entry, so a slice into it would read as
/// whichever entry came last by the time the listing is printed.
fn parseEntry(arena: std.mem.Allocator, text: []const u8, base_dir: []const u8) ?Entry {
    if (!std.mem.startsWith(u8, text, "[")) return null;
    const close = std.mem.find(u8, text, "](") orelse return null;
    const title = text[1..close];
    const after = text[close + 2 ..];
    const paren = std.mem.findScalar(u8, after, ')') orelse return null;
    const link = after[0..paren];
    if (title.len == 0 or link.len == 0) return null;

    var note = std.mem.trim(u8, after[paren + 1 ..], " \t");
    // The inventory writes an em dash; a hand-written line may use a hyphen or
    // an en dash instead, and none of them are part of the note.
    inline for (.{ "—", "–", "-" }) |dash| {
        if (std.mem.startsWith(u8, note, dash)) {
            note = std.mem.trim(u8, note[dash.len..], " \t");
            break;
        }
    }

    // An absolute link (an http URL, or a path already rooted in the repo) is
    // left alone; everything else is relative to the index README's directory.
    const path = if (std.mem.find(u8, link, "://") != null or std.mem.startsWith(u8, link, "docs/"))
        arena.dupe(u8, link) catch return null
    else
        std.fmt.allocPrint(arena, "{s}/{s}", .{ base_dir, std.mem.trimStart(u8, link, "./") }) catch return null;

    return .{
        .title = arena.dupe(u8, title) catch return null,
        .path = path,
        .note = arena.dupe(u8, note) catch return null,
    };
}

// ---------------------------------------------------------------- the search --

/// Grep hits grouped by the file they came from, because the question a search
/// answers is "which record is this in", not "which line".
pub fn renderSearch(
    arena: std.mem.Allocator,
    query: []const u8,
    kind: []const u8,
    reports: []const std.json.Value,
    runbooks: []const std.json.Value,
) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();

    if (reports.len == 0 and runbooks.len == 0) {
        // "nothing matched" has to say what was searched, or a --kind that
        // narrowed the search reads as a repository with no such record.
        if (std.mem.eql(u8, kind, "report")) {
            try w.writer.print("no report mentions \"{s}\".\n\n", .{query});
            try w.writer.writeAll("Only docs/reports was searched; --kind all searches the runbooks too.\n\n");
        } else if (std.mem.eql(u8, kind, "runbook")) {
            try w.writer.print("no runbook mentions \"{s}\".\n\n", .{query});
            try w.writer.writeAll("Only docs/runbooks was searched; --kind all searches the reports too.\n\n");
        } else {
            try w.writer.print("no report or runbook mentions \"{s}\".\n\n", .{query});
        }
        try w.writer.writeAll("Record what you find while tracing it:\n\n");
        try w.writer.writeAll("  clanker reports create investigation <YYYY-MM-DD-slug> \"<title>\" \"<TL;DR>\"\n");
        return w.written();
    }

    try w.writer.print("{d} matching line(s) for \"{s}\"\n\n", .{ reports.len + runbooks.len, query });
    try renderMatchGroup(&w.writer, "REPORTS", reports);
    try renderMatchGroup(&w.writer, "RUNBOOKS", runbooks);
    try w.writer.writeAll("NEXT\n\n");
    try w.writer.writeAll("  clanker reports open <path>       read the record before trusting it\n");
    return w.written();
}

fn renderMatchGroup(w: *std.Io.Writer, heading: []const u8, matches: []const std.json.Value) !void {
    if (matches.len == 0) return;
    try w.print("{s}\n\n", .{heading});

    var last_file: []const u8 = "";
    var file_lines: usize = 0;
    var skipped: usize = 0;
    for (matches) |m| {
        if (m != .object) continue;
        const file = json_util.strFieldOrEmpty(m.object, "file");
        if (!std.mem.eql(u8, file, last_file)) {
            // Leaving a capped record: say what the listing refused, then the
            // blank line that separates the next file's group.
            if (last_file.len > 0 and skipped > 0) {
                try w.print("    … {d} more matching line(s) in {s}\n", .{ skipped, last_file });
            }
            if (last_file.len > 0) try w.writeByte('\n');
            last_file = file;
            file_lines = 0;
            skipped = 0;
            try w.print("  {s}\n", .{file});
        }
        if (file_lines >= max_search_lines_per_file) {
            skipped += 1;
            continue;
        }
        file_lines += 1;
        const text = json_util.strFieldOrEmpty(m.object, "text");
        // A line number is printed unsigned: `{d}` on an i64 carries an
        // explicit `+`, which reads as a diff marker in a column of numbers.
        const line: u64 = blk: {
            const l = m.object.get("line") orelse break :blk 0;
            if (l != .integer or l.integer < 0) break :blk 0;
            break :blk @intCast(l.integer);
        };
        try w.print("    {d: >5}  {s}\n", .{ line, ellipsize(text, match_column_bytes) });
    }
    if (last_file.len > 0 and skipped > 0) {
        try w.print("    … {d} more matching line(s) in {s}\n", .{ skipped, last_file });
    }
    try w.writeAll("\n");
}

/// One line of a record, cut to the column on a UTF-8 boundary. Report text is
/// full of em dashes and arrows, and half a codepoint renders as a replacement
/// character right where the reader is trying to recognize the line.
fn ellipsize(s: []const u8, max: usize) []const u8 {
    const flat = std.mem.trim(u8, s, " \t\r\n");
    return utf8.cap(flat, max);
}

fn out(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

// ---------------------------------------------------------------------- tests --

const test_reports_index =
    \\# Operational reports
    \\
    \\## Inventory
    \\
    \\### Bugs
    \\
    \\<!-- inventory:bug:start -->
    \\- [Unknown goal id runs unscoped task](bugs/2026-08-15-unknown-goal.md) — Open
    \\
    \\- [Improve staging misses UI build inputs](bugs/2026-08-14-staging-ui.md) — Resolved
    \\<!-- inventory:bug:end -->
    \\
    \\### Investigations
    \\
    \\<!-- inventory:investigation:start -->
    \\- [Goal command lifecycle contract](investigations/2026-08-15-goal-contract.md) — Investigating
    \\<!-- inventory:investigation:end -->
    \\
;

const test_runbooks_index =
    \\# Runbooks
    \\
    \\<!-- inventory:runbook:start -->
    \\- [Improve staging build inputs](improve-staging-build-inputs.md) — Verify the
    \\  staging root list covers every local module declared by `build.zig`.
    \\<!-- inventory:runbook:end -->
    \\
;

test "an inventory block becomes entries whose paths are pasteable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bugs = try inventory(arena, test_reports_index, "bug", "docs/reports");
    try std.testing.expectEqual(@as(usize, 2), bugs.len);
    try std.testing.expectEqualStrings("Unknown goal id runs unscoped task", bugs[0].title);
    try std.testing.expectEqualStrings("docs/reports/bugs/2026-08-15-unknown-goal.md", bugs[0].path);
    try std.testing.expectEqualStrings("Open", bugs[0].note);
    try std.testing.expectEqualStrings("Resolved", bugs[1].note);

    const investigations = try inventory(arena, test_reports_index, "investigation", "docs/reports");
    try std.testing.expectEqual(@as(usize, 1), investigations.len);
    try std.testing.expectEqualStrings("docs/reports/investigations/2026-08-15-goal-contract.md", investigations[0].path);

    // A runbook entry wraps across lines, and its trailing text is a sentence
    // rather than a status.
    const runbooks = try inventory(arena, test_runbooks_index, "runbook", "docs/runbooks");
    try std.testing.expectEqual(@as(usize, 1), runbooks.len);
    try std.testing.expectEqualStrings("docs/runbooks/improve-staging-build-inputs.md", runbooks[0].path);
    try std.testing.expect(std.mem.find(u8, runbooks[0].note, "staging root list covers") != null);
}

test "a missing or empty inventory block is a listing with no entries, not an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(@as(usize, 0), (try inventory(arena, "", "bug", "docs/reports")).len);
    try std.testing.expectEqual(@as(usize, 0), (try inventory(arena, test_reports_index, "runbook", "docs/runbooks")).len);

    const text = try renderList(arena, "", "");
    try std.testing.expect(std.mem.find(u8, text, "(none yet in docs/reports)") != null);
    try std.testing.expect(std.mem.find(u8, text, "clanker reports create investigation") != null);
}

test "the listing keeps status, title and path each where they can be read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try renderList(arena, test_reports_index, test_runbooks_index);
    try std.testing.expect(std.mem.find(u8, text, "BUGS\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "INVESTIGATIONS\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "RUNBOOKS\n") != null);
    // Status column, then the title, then the path on its own line under it.
    try std.testing.expect(std.mem.find(u8, text, "  Open      Unknown goal id runs unscoped task\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "            docs/reports/bugs/2026-08-15-unknown-goal.md\n") != null);
    // Every path in the listing is one `clanker reports open` argument.
    try std.testing.expect(std.mem.find(u8, text, "docs/runbooks/improve-staging-build-inputs.md") != null);
    try std.testing.expect(std.mem.find(u8, text, "clanker reports open <path>") != null);

    // No line runs past a conventional terminal, which is what makes the
    // columns worth having.
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try std.testing.expect(line.len <= 100);
}

test "search groups hits by record and says so when there are none" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const matches = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\[{"file":"docs/reports/bugs/a.md","line":12,"text":"  NotDir on the shared state dir"},
        \\ {"file":"docs/reports/bugs/a.md","line":40,"text":"the symlink is resolved first"},
        \\ {"file":"docs/reports/bugs/b.md","line":7,"text":"unrelated NotDir mention"}]
    , .{});
    const runbook_matches = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\[{"file":"docs/runbooks/state-symlink.md","line":3,"text":"check the state symlink"}]
    , .{});

    const text = try renderSearch(arena, "NotDir", "all", matches.array.items, runbook_matches.array.items);
    try std.testing.expect(std.mem.find(u8, text, "4 matching line(s) for \"NotDir\"") != null);
    // The file is named once, then its own matching lines.
    try std.testing.expect(std.mem.find(u8, text, "  docs/reports/bugs/a.md\n       12  NotDir on the shared state dir\n       40  the symlink is resolved first\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "RUNBOOKS\n") != null);

    const empty = try renderSearch(arena, "nothing here", "all", &.{}, &.{});
    try std.testing.expect(std.mem.find(u8, empty, "no report or runbook mentions \"nothing here\"") != null);
    try std.testing.expect(std.mem.find(u8, empty, "clanker reports create investigation") != null);
}

test "search caps a record's lines at the column and names how many were hidden" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // One record with more hits than the column allows: the printed lines
    // stay bounded, and a hint names the ones the listing refused so a
    // reader knows the truncated file is where the rest lives.
    var matches: std.ArrayList(std.json.Value) = .empty;
    var i: usize = 0;
    while (i < max_search_lines_per_file + 12) : (i += 1) {
        try matches.append(arena, try std.json.parseFromSliceLeaky(std.json.Value, arena,
            \\{"file":"docs/runbooks/big.md","line":3,"text":"recurring phrase"}
        , .{}));
    }

    const text = try renderSearch(arena, "recurring", "all", &.{}, matches.items);
    try std.testing.expectEqual(max_search_lines_per_file, std.mem.count(u8, text, "recurring phrase"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "12 more matching line(s) in docs/runbooks/big.md"));
}

test "a refused tool call fails with the tool's own sentence, not a generic error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Canned = struct {
        answer: []const u8,
        fn call(ctx: *anyopaque, input: []const u8) anyerror![]const u8 {
            _ = input;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.answer;
        }
    };

    var refused: Canned = .{ .answer = "{\"ok\":false,\"error\":\"the record changed while appending\"}" };
    try std.testing.expectError(Error.ToolFailed, callTool(arena, .{ .ctx = &refused, .call = Canned.call }, "{}"));

    var garbage: Canned = .{ .answer = "not json" };
    try std.testing.expectError(Error.ToolFailed, callTool(arena, .{ .ctx = &garbage, .call = Canned.call }, "{}"));

    var fine: Canned = .{ .answer = "{\"ok\":true,\"path\":\"docs/reports/bugs/a.md\"}" };
    const parsed = try callTool(arena, .{ .ctx = &fine, .call = Canned.call }, "{}");
    try std.testing.expectEqualStrings("docs/reports/bugs/a.md", json_util.strFieldOrEmpty(parsed.object, "path"));
}
