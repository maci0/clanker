//! `clanker prd <sub>`, the operator surface over the sandboxed `prd` tool
//! (`tools/zig/prd.zig`).
//!
//! Same arrangement as `adr.zig` and `rfc.zig`: `cli.zig` owns
//! argument parsing and the sandbox, printing is neither, and the tool stays
//! the single implementation of the store.
//!
//! The listing groups by status rather than printing one flat list. A PRD
//! store is read to answer "what is still open", and thirty-odd rows in
//! filename order do not answer that — Draft and In progress are the rows a
//! reader is looking for, and Shipped is the bulk they have to scroll past to
//! find them.

const std = @import("std");
const utf8 = @import("../util/utf8.zig");
const json_util = @import("../util/json.zig");
const common = @import("common.zig");

pub const Options = struct {
    /// "list" (default), "search", "open", "checklist", "create", "append",
    /// "update" or "status".
    sub: []const u8 = "list",
    /// `search`: the query. `open`/`append`/`update`/`status`: the path.
    /// `create`: the title.
    arg1: ?[]const u8 = null,
    /// `create`: the problem. `append`: the content. `update`: the old text.
    /// `status`: the state.
    arg2: ?[]const u8 = null,
    /// `create`: the goals. `update`: the new text. `status`: the note.
    arg3: ?[]const u8 = null,
    /// `create`: the initial status.
    arg4: ?[]const u8 = null,
    /// `--replace-all` for `update`: rewrite every copy of the old text rather
    /// than refusing a repeated match.
    replace_all: bool = false,
};

pub const Error = common.Error;

pub const Tool = common.Tool;

/// Titles are the widest column and the least load-bearing: a reader who needs
/// the whole one opens the record.
const title_column_bytes: usize = 62;

/// The order the listing groups statuses in: what still needs work first, what
/// is finished last. A store read to answer "what is open" should not open
/// with thirty Shipped rows.
const status_order = [_][]const u8{ "Draft", "In progress", "Partial", "Implemented", "Shipped" };

/// Every subcommand the dispatch below accepts, in the order `--help`
/// lists them. The spec's usage line in `cli.zig` is pinned to this list.
pub const subcommands = [_][]const u8{ "list", "search", "open", "checklist", "create", "append", "update", "status", "rename" };

pub fn cmd(init: std.process.Init, opts: Options, tool: Tool) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const sub = opts.sub;

    if (std.mem.eql(u8, sub, "list")) return list(io, arena, tool);
    if (std.mem.eql(u8, sub, "search")) return search(io, arena, opts, tool);
    if (std.mem.eql(u8, sub, "open")) return open(io, arena, opts, tool);
    if (std.mem.eql(u8, sub, "checklist")) return checklist(io, arena, tool);
    if (std.mem.eql(u8, sub, "create")) return create(io, arena, opts, tool);
    if (std.mem.eql(u8, sub, "append")) return append(io, arena, opts, tool);
    if (std.mem.eql(u8, sub, "update")) return update(io, arena, opts, tool);
    if (std.mem.eql(u8, sub, "status")) return setStatus(io, arena, opts, tool);
    if (std.mem.eql(u8, sub, "rename")) return rename(io, arena, opts, tool);

    return common.badSubcommand("prd", &subcommands, sub);
}

// ------------------------------------------------------------------ reading --

fn list(io: std.Io, arena: std.mem.Allocator, tool: Tool) !void {
    const result = try common.callTool(arena, "prd", tool, "{\"action\":\"list\"}");
    try common.out(io, try renderList(arena, common.arrayField(result, "prds"), common.unsignedField(result, "next_number")));
}

fn search(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const query = try common.requireQuery("prd", opts.arg1);

    const input = try common.request(arena, &.{
        .{ .name = "action", .value = .{ .text = "search" } },
        .{ .name = "query", .value = .{ .text = query } },
    });

    const result = try common.callTool(arena, "prd", tool, input);
    try common.out(io, try renderSearch(arena, query, common.arrayField(result, "prds"), common.arrayField(result, "adrs")));
}

fn open(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    try common.out(io, try common.openRecord(arena, "prd", "docs/prds/<number>-<slug>.md", opts.arg1, tool));
}

/// What a Draft has to pin down before it counts as planned. This is the
/// answer to "the request is too vague to draft from".
fn checklist(io: std.Io, arena: std.mem.Allocator, tool: Tool) !void {
    const result = try common.callTool(arena, "prd", tool, "{\"action\":\"checklist\"}");
    try common.out(io, try renderChecklist(arena, common.arrayField(result, "requirements")));
}

// ------------------------------------------------------------------ writing --

fn create(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const title = opts.arg1 orelse return missingCreateArg("a title naming the feature");
    const problem = opts.arg2 orelse return missingCreateArg("the problem, stated from the situation rather than the solution");
    const goals = opts.arg3 orelse return missingCreateArg("numbered, verifiable goals");

    const input = try common.request(arena, &.{
        .{ .name = "action", .value = .{ .text = "create" } },
        .{ .name = "title", .value = .{ .text = title } },
        .{ .name = "problem", .value = .{ .text = problem } },
        .{ .name = "goals", .value = .{ .text = goals } },
        .{ .name = "status", .value = common.Field.optional(opts.arg4) },
    });

    const result = try common.callTool(arena, "prd", tool, input);
    try common.out(io, try renderCreated(
        arena,
        json_util.strFieldOrEmpty(result.object, "path"),
        json_util.strFieldOrEmpty(result.object, "status"),
        common.boolField(result, "indexed"),
    ));
    // The slug is derived from the title in this store, so a dated slug here
    // comes from a dated title rather than a typed one -- rarer than in
    // `reports`, and the same self-contradiction when it happens.
    if (try common.dateWarningBlock(arena, result)) |warning| try common.out(io, warning);
}

/// What to do with the record once it exists. A Draft gets the bar it has to
/// clear spelled out, because a Draft that reads finished and cannot be
/// started from is the failure mode this store actually has.
pub fn renderCreated(arena: std.mem.Allocator, path: []const u8, status: []const u8, indexed: bool) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();

    try w.writer.print("created {s}", .{path});
    if (status.len > 0) try w.writer.print(" ({s})", .{status});
    try w.writer.writeAll("\n");

    if (std.mem.eql(u8, status, "Draft")) {
        try w.writer.writeAll("\nA Draft is not planned until it names its dependencies, settles the\nblocking questions in Design rather than parking them under Open\nquestions, and lists implementation phases with file paths:\n\n");
        try w.writer.writeAll("  clanker prd checklist            what it has to pin down\n");
    } else {
        try w.writer.writeAll("\nGoals and acceptance criteria have to cover each other: a goal with no\nmatching checkbox is either wrong or untested.\n\n");
    }
    try w.writer.print("  clanker prd open {s}\n", .{path});
    if (!indexed) {
        try w.writer.writeAll("\nThe inventory was not updated (it changed concurrently). Add the row\nby hand to docs/prds/README.md without replacing the other edit.\n");
    }
    return w.written();
}

fn missingCreateArg(what: []const u8) Error {
    common.usageError("prd create needs {s}: clanker prd create \"Scheduled runs\" \"<what breaks without it>\" \"1. ...\" [draft|in_progress|shipped]", .{what});
    return Error.MissingArg;
}

fn append(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    try common.out(io, try common.appendRecord(arena, "prd", "docs/prds/<name>.md \"## Failure modes\\n\\n...\"", opts.arg1, opts.arg2, tool));
}

fn update(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    try common.out(io, try common.updateRecord(arena, "prd", opts.arg1, opts.arg2, opts.arg3, opts.replace_all, tool));
}

const status_usage: common.StatusUsage = .{
    .example = "docs/prds/<name>.md shipped \"src/foo.zig is the source of truth; exposed as clanker foo\"",
    .path_arg = "a PRD path",
    .status_arg = "a status: draft, in_progress or shipped",
    .index_warning = "\nThe inventory row was not updated (the row is missing or the index\nchanged concurrently). Set its Status cell by hand in docs/prds/README.md\nso the index does not disagree with the record.\n",
};

fn setStatus(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    try common.out(io, try common.setRecordStatus(arena, "prd", status_usage, opts.arg1, opts.arg2, opts.arg3, tool));
}

// ----------------------------------------------------------------- the tool --

// -------------------------------------------------------------- the listing --

/// The listing, grouped by status with the unfinished work first.
///
/// A flat list in filename order buries the four Drafts under thirty Shipped
/// rows, and "what is still open" is the question this store is read to
/// answer. Statuses outside the known vocabulary get their own trailing group
/// rather than being dropped: an unexpected wording is a document to go fix,
/// not a row to hide.
pub fn renderList(arena: std.mem.Allocator, raw_prds: []const std.json.Value, next_number: u64) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();

    // The tool reports the directory listing's own order, which is arbitrary.
    // Sorting on the path sorts on the number, so each status group below
    // reads in the order the documents are numbered.
    const prds = try arena.dupe(std.json.Value, raw_prds);
    std.mem.sort(std.json.Value, prds, {}, common.byPath);

    if (prds.len == 0) {
        try w.writer.writeAll("no PRDs yet.\n\n");
        try w.writer.print("Open the first one as {d:0>4}:\n\n", .{next_number});
        try w.writer.writeAll("  clanker prd create \"<feature>\" \"<what breaks without it>\" \"<numbered goals>\"\n");
        return w.written();
    }

    try w.writer.print("{d} PRD(s)\n", .{prds.len});

    var printed: usize = 0;
    for (status_order) |group| {
        var wrote_heading = false;
        for (prds) |p| {
            if (p != .object) continue;
            const status = json_util.strFieldOrEmpty(p.object, "status");
            if (!std.mem.eql(u8, status, group)) continue;
            if (!wrote_heading) {
                try w.writer.print("\n{s}\n\n", .{upper(arena, group) catch group});
                wrote_heading = true;
            }
            try printRow(&w.writer, p);
            printed += 1;
        }
    }

    // Anything whose status is not in the vocabulary, plus rows that could not
    // be read at all.
    var wrote_other = false;
    for (prds) |p| {
        if (p != .object) continue;
        const status = json_util.strFieldOrEmpty(p.object, "status");
        if (isKnownStatus(status)) continue;
        if (!wrote_other) {
            try w.writer.writeAll("\nOTHER\n\n");
            wrote_other = true;
        }
        try printRow(&w.writer, p);
        printed += 1;
    }

    try w.writer.print("\nNEXT\n\n  next free number is {d:0>4}\n", .{next_number});
    try w.writer.writeAll("  clanker prd open <path>          read one in full\n");
    try w.writer.writeAll("  clanker prd checklist            what a Draft has to pin down\n");
    return w.written();
}

fn printRow(w: *std.Io.Writer, p: std.json.Value) !void {
    const path = json_util.strFieldOrEmpty(p.object, "path");
    const title = json_util.strFieldOrEmpty(p.object, "title");
    try w.print("  {s}\n", .{path});
    if (title.len > 0) try w.print("      {s}\n", .{utf8.cap(stripPrdPrefix(title), title_column_bytes)});
}

/// Every PRD title in the store opens with "PRD — ", which is noise in a
/// column of PRDs. The prefix is dropped for display only; the document keeps
/// it.
fn stripPrdPrefix(title: []const u8) []const u8 {
    const prefix = "PRD — ";
    if (std.mem.startsWith(u8, title, prefix)) return title[prefix.len..];
    return title;
}

fn isKnownStatus(status: []const u8) bool {
    for (status_order) |known| {
        if (std.mem.eql(u8, status, known)) return true;
    }
    return false;
}

fn upper(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const buf = try arena.alloc(u8, s.len);
    for (s, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    return buf;
}

/// PRDs and ADRs are searched together: an ADR is what constrains a feature's
/// design, and a PRD specifying around a decision that already forecloses it
/// is the mistake worth catching before the document is written.
pub fn renderSearch(
    arena: std.mem.Allocator,
    query: []const u8,
    prds: []const std.json.Value,
    adrs: []const std.json.Value,
) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();

    if (prds.len == 0 and adrs.len == 0) {
        try w.writer.print("no PRD or ADR mentions \"{s}\".\n\n", .{query});
        try w.writer.writeAll("Write down what the feature is meant to be before building it:\n\n");
        try w.writer.writeAll("  clanker prd create \"<feature>\" \"<what breaks without it>\" \"<numbered goals>\"\n");
        return w.written();
    }

    try w.writer.print("{d} matching line(s) for \"{s}\"\n\n", .{ prds.len + adrs.len, query });
    try common.renderMatchGroup(&w.writer, "PRDS", prds);
    try common.renderMatchGroup(&w.writer, "ADRS", adrs);
    if (adrs.len > 0) {
        try w.writer.writeAll("An ADR matched: that decision constrains this feature's design. Read it\nbefore specifying around it.\n\n");
    }
    try w.writer.writeAll("NEXT\n\n");
    try w.writer.writeAll("  clanker prd open <path>          read the record before trusting it\n");
    return w.written();
}

/// The checklist is a list of questions to put to a person, so each one is
/// printed as the question, with what it pins down under it.
pub fn renderChecklist(arena: std.mem.Allocator, requirements: []const std.json.Value) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();

    try w.writer.writeAll("What a PRD has to pin down before it counts as planned\n\n");

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
        // These are whole sentences from the tool, long enough that a raw
        // print wraps them mid-thought at the terminal's own margin. Breaking
        // them here puts the break between words instead.
        if (why.len > 0) try common.wrapInto(&w.writer, why, "      ", common.help_columns);
        if (ask.len > 0) {
            // The "ask:" label wraps with the question rather than sitting on
            // a line of its own.
            const labelled = try std.fmt.allocPrint(arena, "ask: {s}", .{ask});
            try common.wrapInto(&w.writer, labelled, "      ", common.help_columns);
        }
        try w.writer.writeByte('\n');
    }
    return w.written();
}

// -------------------------------------------------------------------- tests --

const testing = std.testing;

test "renderList names the next free number when there is nothing to list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try renderList(arena, &.{}, 1);
    try testing.expect(std.mem.find(u8, text, "no PRDs yet") != null);
    try testing.expect(std.mem.find(u8, text, "0001") != null);
}

test "renderList puts unfinished work above shipped work" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Filename order would put the Shipped one first; the grouping must not.
    const prds = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\[{"path":"docs/prds/0001-shipped.md","title":"PRD — Chatrooms","status":"Shipped"},
        \\ {"path":"docs/prds/0032-draft.md","title":"PRD — MCP client bridge","status":"Draft"},
        \\ {"path":"docs/prds/0016-wip.md","title":"PRD — Eval kernel","status":"In progress"}]
    , .{});
    const text = try renderList(arena, prds.array.items, 37);

    const draft = std.mem.find(u8, text, "0032-draft.md").?;
    const wip = std.mem.find(u8, text, "0016-wip.md").?;
    const shipped = std.mem.find(u8, text, "0001-shipped.md").?;
    try testing.expect(draft < wip);
    try testing.expect(wip < shipped);
    try testing.expect(std.mem.find(u8, text, "3 PRD(s)") != null);
    // The redundant "PRD — " prefix is dropped in the column.
    try testing.expect(std.mem.find(u8, text, "  MCP client bridge") != null);
}

test "renderList groups an unknown status under OTHER instead of dropping it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prds = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\[{"path":"docs/prds/0036-sixel.md","title":"PRD — SIXEL","status":"Superseded-ish"},
        \\ {"path":"docs/prds/0009-unreadable.md","title":"","status":""}]
    , .{});
    const text = try renderList(arena, prds.array.items, 37);
    try testing.expect(std.mem.find(u8, text, "OTHER") != null);
    // A row whose status could not be read is still listed: the path is what
    // the reader needs in order to go look.
    try testing.expect(std.mem.find(u8, text, "docs/prds/0009-unreadable.md") != null);
    try testing.expect(std.mem.find(u8, text, "docs/prds/0036-sixel.md") != null);
}

test "renderSearch says an ADR hit constrains the design" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const adrs = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\[{"file":"docs/adrs/0001-board.md","line":9,"text":"the board is a chatroom"}]
    , .{});
    const text = try renderSearch(arena, "board", &.{}, adrs.array.items);
    try testing.expect(std.mem.find(u8, text, "ADRS") != null);
    try testing.expect(std.mem.find(u8, text, "constrains this feature's design") != null);
}

test "renderSearch with no hits points at create rather than reporting an error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try renderSearch(arena, "quantum", &.{}, &.{});
    try testing.expect(std.mem.find(u8, text, "no PRD or ADR mentions") != null);
    try testing.expect(std.mem.find(u8, text, "clanker prd create") != null);
}

test "renderCreated spells out the Draft bar only for a Draft" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const draft = try renderCreated(arena, "docs/prds/0037-x.md", "Draft", true);
    try testing.expect(std.mem.find(u8, draft, "not planned until") != null);
    try testing.expect(std.mem.find(u8, draft, "clanker prd checklist") != null);

    const shipped = try renderCreated(arena, "docs/prds/0037-x.md", "Shipped", true);
    try testing.expect(std.mem.find(u8, shipped, "not planned until") == null);
    try testing.expect(std.mem.find(u8, shipped, "cover each other") != null);
}

test "renderChecklist keeps every line inside the terminal column" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The real strings: the tool's `why` and `ask` sentences are long enough
    // to wrap mid-thought in an 80-column terminal if they are printed raw.
    const reqs = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\[{"needs":"Numbered goals, each checkable",
        \\  "why":"Goals and acceptance criteria have to cover each other; a goal with no matching checkbox is either wrong or untested",
        \\  "ask":"What must be true for this to be done, as a numbered list a reader can check off one at a time?"}]
    , .{});
    const text = try renderChecklist(arena, reqs.array.items);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len > 80) {
            std.debug.print("line is {d} columns: {s}\n", .{ line.len, line });
            return error.TestUnexpectedResult;
        }
    }
    // Wrapping must not lose words: the tail of each sentence still shows.
    try testing.expect(std.mem.find(u8, text, "untested") != null);
    try testing.expect(std.mem.find(u8, text, "one at a time?") != null);
    try testing.expect(std.mem.find(u8, text, "ask:") != null);
}

test "renderChecklist prints the question to ask under each requirement" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const reqs = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\[{"needs":"Numbered goals","why":"goals and criteria must cover each other","ask":"What must be true for this to be done?"}]
    , .{});
    const text = try renderChecklist(arena, reqs.array.items);
    try testing.expect(std.mem.find(u8, text, "Numbered goals") != null);
    try testing.expect(std.mem.find(u8, text, "ask: What must be true for this to be done?") != null);
}

/// `clanker prd rename <path> <new-slug>`. The PRD's number is its identity
/// and stays: the ROADMAP and the inventory table both cite it.
fn rename(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    try common.out(io, try common.renameRecord(
        arena,
        "prd",
        "docs/prds/<NNNN-name>.md",
        "lowercase letters, digits and hyphens; the PRD keeps its number",
        "docs/prds/",
        opts.arg1,
        opts.arg2,
        tool,
    ));
}

// ------------------------------------------------- template-drift detection

/// One `## ` section of a record: its heading line and everything under it up
/// to the next heading.
const Section = struct { heading: []const u8, body: []const u8 };

/// Walks a markdown record's top-level sections in order. Nothing clever: a
/// heading is a line that starts with `## `, and a body runs to the next one.
const SectionIter = struct {
    text: []const u8,
    i: usize = 0,

    fn lineEnd(self: SectionIter, from: usize) usize {
        return std.mem.findScalarPos(u8, self.text, from, '\n') orelse self.text.len;
    }

    fn next(self: *SectionIter) ?Section {
        while (self.i < self.text.len) {
            const end = self.lineEnd(self.i);
            const line = self.text[self.i..end];
            if (!std.mem.startsWith(u8, line, "## ")) {
                self.i = if (end < self.text.len) end + 1 else self.text.len;
                continue;
            }
            const body_start = if (end < self.text.len) end + 1 else self.text.len;
            var j = body_start;
            while (j < self.text.len) {
                const e = self.lineEnd(j);
                if (std.mem.startsWith(u8, self.text[j..e], "## ")) break;
                j = if (e < self.text.len) e + 1 else self.text.len;
            }
            self.i = j;
            return .{ .heading = line, .body = self.text[body_start..j] };
        }
        return null;
    }
};

fn trimmed(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// The first thing wrong with `doc` as a filled-in record, or null when there
/// is nothing wrong: a heading that appears twice, or a section whose body is
/// still `template`'s instruction prose for that same heading.
///
/// Both are the same authoring accident seen from two sides. PRDs 0052-0057
/// each carried a second, unfilled copy of `## Failure modes`,
/// `## Acceptance criteria` and `## Open questions / future work` straight out
/// of `TEMPLATE.md`, so `clanker prd open` printed the instructions as if they
/// were the record and a reader diffing doc against code had two Failure modes
/// tables to choose from. `prd create` renders the template exactly once
/// (re-run against origin/main to be sure), so this is not a tool defect to
/// fix once — it is drift a record can pick up any time a section is spliced
/// in above the ones the template already wrote.
fn templateDrift(arena: std.mem.Allocator, doc: []const u8, template: []const u8) !?[]const u8 {
    var seen: std.ArrayList([]const u8) = .empty;
    var it: SectionIter = .{ .text = doc };
    while (it.next()) |sec| {
        for (seen.items) |prior| {
            if (std.mem.eql(u8, prior, sec.heading))
                return try std.fmt.allocPrint(arena, "'{s}' appears twice", .{trimmed(sec.heading)});
        }
        try seen.append(arena, sec.heading);

        var t: SectionIter = .{ .text = template };
        while (t.next()) |tsec| {
            if (!std.mem.eql(u8, tsec.heading, sec.heading)) continue;
            if (std.mem.eql(u8, trimmed(tsec.body), trimmed(sec.body)))
                return try std.fmt.allocPrint(arena, "'{s}' is still the template's instruction prose", .{trimmed(sec.heading)});
        }
    }
    return null;
}

test "templateDrift names a duplicated heading and unfilled template prose" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const template =
        \\# PRD NNNN — Title
        \\
        \\## Problem
        \\
        \\What breaks today.
        \\
        \\## Failure modes
        \\
        \\A table: condition -> behaviour.
        \\
    ;
    const clean =
        \\# PRD 0001 — A thing
        \\
        \\## Problem
        \\
        \\The board loses cards.
        \\
        \\## Failure modes
        \\
        \\| store missing | empty board |
        \\
    ;
    try std.testing.expect(try templateDrift(arena, clean, template) == null);

    const doubled = clean ++
        \\
        \\## Failure modes
        \\
        \\| store missing | empty board |
        \\
    ;
    const dup = (try templateDrift(arena, doubled, template)).?;
    try std.testing.expect(std.mem.find(u8, dup, "appears twice") != null);

    const unfilled =
        \\# PRD 0002 — Another thing
        \\
        \\## Problem
        \\
        \\Real text.
        \\
        \\## Failure modes
        \\
        \\A table: condition -> behaviour.
        \\
    ;
    const prose = (try templateDrift(arena, unfilled, template)).?;
    try std.testing.expect(std.mem.find(u8, prose, "instruction prose") != null);
}

test "no PRD in the live checkout carries template boilerplate" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cwd = std.Io.Dir.cwd();
    const template = cwd.readFileAlloc(io, "docs/prds/TEMPLATE.md", arena, .limited(1 << 20)) catch |err| switch (err) {
        // A minimal checkout with no docs tree has nothing to check.
        error.FileNotFound => return,
        else => return err,
    };

    const scope = try cwd.openDir(io, "docs/prds", .{ .iterate = true });
    defer scope.close(io);
    var walk = scope.iterate();
    var checked: usize = 0;
    while (try walk.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        // Scaffolding, not records: the template is the prose everything else
        // is measured against, and the inventory is a table with no sections.
        if (std.mem.eql(u8, entry.name, "TEMPLATE.md")) continue;
        if (std.mem.eql(u8, entry.name, "README.md")) continue;
        const path = try std.fmt.allocPrint(arena, "docs/prds/{s}", .{entry.name});
        const text = try cwd.readFileAlloc(io, path, arena, .limited(4 << 20));
        checked += 1;
        if (try templateDrift(arena, text, template)) |why| {
            std.debug.print("{s}: {s}\n", .{ path, why });
            return error.TemplateBoilerplateInRecord;
        }
    }
    try std.testing.expect(checked > 0);
}
