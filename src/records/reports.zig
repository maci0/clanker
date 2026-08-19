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
const json_util = @import("../util/json.zig");
const common = @import("common.zig");

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

pub const Error = common.Error;

pub const Tool = common.Tool;

/// Statuses are one or two words ("Open", "Resolved", "Investigating"); a
/// runbook's inventory line carries a sentence instead. Past this many bytes
/// the trailing text is prose and gets its own line rather than a column.
const status_column_max: usize = 18;
/// Narrowest status column, so a listing of only "Open" records still leaves
/// the titles on a straight edge.
const status_column_min: usize = 10;

/// Every subcommand the dispatch below accepts, in the order `--help`
/// lists them. The spec's usage line in `cli.zig` is pinned to this list.
pub const subcommands = [_][]const u8{ "list", "search", "open", "create", "append", "update", "status", "rename" };

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
    if (std.mem.eql(u8, sub, "rename")) return rename(io, arena, opts, tool);

    return common.badSubcommand("reports", &subcommands, sub);
}

// ------------------------------------------------------------------ reading --

fn list(io: std.Io, arena: std.mem.Allocator, tool: Tool) !void {
    const result = try common.callTool(arena, "reports", tool, "{\"action\":\"list\"}");
    const reports_index = json_util.strFieldOrEmpty(result.object, "reports_index");
    const runbooks_index = json_util.strFieldOrEmpty(result.object, "runbooks_index");
    try common.out(io, try renderList(arena, reports_index, runbooks_index));
}

fn search(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const query = opts.arg1 orelse {
        common.usageError("reports search needs a query: clanker reports search \"worktree symlink\"", .{});
        return Error.MissingArg;
    };
    const kind = opts.kind orelse "all";

    const input = try common.request(arena, &.{
        .{ .name = "action", .value = .{ .text = "search" } },
        .{ .name = "query", .value = .{ .text = query } },
        .{ .name = "kind", .value = .{ .text = kind } },
    });

    const result = try common.callTool(arena, "reports", tool, input);
    try common.out(io, try renderSearch(arena, query, kind, common.arrayField(result, "reports"), common.arrayField(result, "runbooks")));
}

fn open(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    try common.out(io, try common.openRecord(arena, "reports", "docs/runbooks/<name>.md", opts.arg1, tool));
}

// ------------------------------------------------------------------ writing --

fn create(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const kind = opts.arg1 orelse return missingCreateArg("a kind (bug, investigation, missing-tool or runbook)");
    const slug = opts.arg2 orelse return missingCreateArg("a slug");
    const title = opts.arg3 orelse return missingCreateArg("a title");
    const summary = opts.arg4 orelse return missingCreateArg("a TL;DR summary");

    const input = try common.request(arena, &.{
        .{ .name = "action", .value = .{ .text = "create" } },
        .{ .name = "kind", .value = .{ .text = kind } },
        .{ .name = "slug", .value = .{ .text = slug } },
        .{ .name = "title", .value = .{ .text = title } },
        .{ .name = "summary", .value = .{ .text = summary } },
    });

    const result = try common.callTool(arena, "reports", tool, input);
    const path = json_util.strFieldOrEmpty(result.object, "path");
    var w: std.Io.Writer.Allocating = .init(arena);
    defer w.deinit();
    try w.writer.print("created {s}\n", .{path});
    // The scaffold is a skeleton: saying so here is what keeps a half-filled
    // record from being mistaken for a finished one.
    try w.writer.print("\nFill in the evidence, resolution and verification:\n  clanker reports open {s}\n", .{path});
    if (!common.boolField(result, "indexed")) {
        try w.writer.writeAll("\nThe inventory was not updated (it changed concurrently). Add the link\nby hand from the index README without replacing the other edit.\n");
    }
    try common.out(io, w.written());
}

fn rename(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const path = opts.arg1 orelse {
        common.usageError("reports rename needs a path and the new filename stem: clanker reports rename docs/reports/bugs/<name>.md <new-slug>", .{});
        return Error.MissingArg;
    };
    const slug = opts.arg2 orelse {
        common.usageError("reports rename needs the new filename stem after the path (report slugs start YYYY-MM-DD-)", .{});
        return Error.MissingArg;
    };

    const input = try common.request(arena, &.{
        .{ .name = "action", .value = .{ .text = "rename" } },
        .{ .name = "path", .value = .{ .text = path } },
        .{ .name = "slug", .value = .{ .text = slug } },
    });

    const result = try common.callTool(arena, "reports", tool, input);
    const to = json_util.strFieldOrEmpty(result.object, "to");
    var w: std.Io.Writer.Allocating = .init(arena);
    defer w.deinit();
    try w.writer.print("renamed {s}\n     -> {s}\n", .{ path, to });
    if (!common.boolField(result, "indexed")) {
        try w.writer.writeAll("\nThe inventory link was not rewritten (missing or changed concurrently);\nfix the README line by hand.\n");
    }
    if (result.object.get("references")) |refs| {
        if (refs == .array and refs.array.items.len > 0) {
            try w.writer.writeAll("\nStill naming the old record:\n");
            for (refs.array.items) |r| {
                if (r == .string) try w.writer.print("  {s}\n", .{r.string});
            }
        }
    }
    try w.writer.writeAll("\nMentions outside docs/reports/ and docs/runbooks/ are not visible to the\nreports tool; search the tree for the old name to catch them.\n");
    try common.out(io, w.written());
}

fn missingCreateArg(what: []const u8) Error {
    common.usageError("reports create needs {s}: clanker reports create investigation 2026-08-16-worktree-symlink \"Worktree setup rejects a symlink\" \"TL;DR of what was seen\"", .{what});
    return Error.MissingArg;
}

fn append(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    try common.out(io, try common.appendRecord(arena, "reports", "docs/reports/bugs/<name>.md \"## New evidence\\n\\n...\"", opts.arg1, opts.arg2, tool));
}

fn update(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    try common.out(io, try common.updateRecord(arena, "reports", opts.arg1, opts.arg2, opts.arg3, tool));
}

const status_usage: common.StatusUsage = .{
    .example = "docs/reports/bugs/<name>.md resolved \"Fixed in <commit>; verified by <check>\"",
    .path_arg = "a record path",
    .status_arg = "a state: open, investigating, resolved, reopened or closed",
    .index_warning = "\nThe inventory line was not updated (the entry is missing or the index\nchanged concurrently). Set its status by hand in docs/reports/README.md so\nthe index does not disagree with the record.\n",
};

fn setStatus(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    try common.out(io, try common.setRecordStatus(arena, "reports", status_usage, opts.arg1, opts.arg2, opts.arg3, tool));
}

// ----------------------------------------------------------------- the tool --

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
    .{ .heading = "MISSING TOOLS", .kind = "missing-tool", .base_dir = "docs/reports" },
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
        for (entries) |e| try renderInventoryRow(&w.writer, e, width, detail_indent);
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
///
/// Shared with `research.zig`, which lists the same inventory
/// entries in the same two columns: a second copy is how one listing gets a
/// wider gutter than the other.
pub fn statusWidth(entries: []const Entry) usize {
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

/// One row of an inventory listing: the status column, the title, then the
/// path (and any summary too long for that column) indented under it.
///
/// `clanker research` prints the same table, so the row lives here beside
/// `statusWidth` rather than being written out twice. The indent is a
/// parameter because a store with no status column indents its detail
/// differently from one that has it to sit under.
pub fn renderInventoryRow(w: *std.Io.Writer, e: Entry, width: usize, detail_indent: usize) !void {
    const status = if (e.note.len > 0 and e.note.len <= status_column_max) e.note else "";
    try w.splatByteAll(' ', 2);
    try w.print("{s}", .{status});
    try w.splatByteAll(' ', width -| status.len);
    try w.print("{s}\n", .{e.title});
    try w.splatByteAll(' ', detail_indent);
    try w.print("{s}\n", .{e.path});
    // Prose that would not fit the status column keeps its own line rather
    // than being cut down to a width it was never written for.
    if (status.len == 0 and e.note.len > 0) {
        try w.splatByteAll(' ', detail_indent);
        try w.print("{s}\n", .{e.note});
    }
    try w.writeByte('\n');
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
    try common.renderMatchGroup(&w.writer, "REPORTS", reports);
    try common.renderMatchGroup(&w.writer, "RUNBOOKS", runbooks);
    try w.writer.writeAll("NEXT\n\n");
    try w.writer.writeAll("  clanker reports open <path>       read the record before trusting it\n");
    return w.written();
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
    try std.testing.expect(std.mem.find(u8, text, "MISSING TOOLS\n") != null);
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
    while (i < common.match_lines_per_file_max + 12) : (i += 1) {
        try matches.append(arena, try std.json.parseFromSliceLeaky(std.json.Value, arena,
            \\{"file":"docs/runbooks/big.md","line":3,"text":"recurring phrase"}
        , .{}));
    }

    const text = try renderSearch(arena, "recurring", "all", &.{}, matches.items);
    try std.testing.expectEqual(common.match_lines_per_file_max, std.mem.count(u8, text, "recurring phrase"));
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
    try std.testing.expectError(Error.ToolFailed, common.callTool(arena, "reports", .{ .ctx = &refused, .call = Canned.call }, "{}"));

    var garbage: Canned = .{ .answer = "not json" };
    try std.testing.expectError(Error.ToolFailed, common.callTool(arena, "reports", .{ .ctx = &garbage, .call = Canned.call }, "{}"));

    var fine: Canned = .{ .answer = "{\"ok\":true,\"path\":\"docs/reports/bugs/a.md\"}" };
    const parsed = try common.callTool(arena, "reports", .{ .ctx = &fine, .call = Canned.call }, "{}");
    try std.testing.expectEqualStrings("docs/reports/bugs/a.md", json_util.strFieldOrEmpty(parsed.object, "path"));
}
