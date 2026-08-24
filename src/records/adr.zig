//! `clanker adr <sub>`, the operator surface over the sandboxed `adr` tool
//! (`tools/zig/adr.zig`).
//!
//! Same arrangement as `rfc.zig` and `reports.zig`, for the
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
const utf8 = @import("../util/utf8.zig");
const json_util = @import("../util/json.zig");
const common = @import("common.zig");

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
    /// `--replace-all` for `update`: rewrite every copy of the old text rather
    /// than refusing a repeated match.
    replace_all: bool = false,
};

pub const Error = common.Error;

pub const Tool = common.Tool;

/// Titles are the widest column and the least load-bearing: a reader who needs
/// the whole one opens the record.
const title_column_bytes: usize = 62;
/// Statuses are one word ("Accepted", "Superseded", ...).
const status_column_max: usize = 12;

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

    return common.badSubcommand("adr", &subcommands, sub);
}

// ------------------------------------------------------------------ reading --

fn list(io: std.Io, arena: std.mem.Allocator, tool: Tool) !void {
    const result = try common.callTool(arena, "adr", tool, "{\"action\":\"list\"}");
    try common.out(io, try renderList(arena, common.arrayField(result, "adrs"), common.unsignedField(result, "next_number")));
}

fn search(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const query = try common.requireQuery("adr", opts.arg1);

    const input = try common.request(arena, &.{
        .{ .name = "action", .value = .{ .text = "search" } },
        .{ .name = "query", .value = .{ .text = query } },
    });

    const result = try common.callTool(arena, "adr", tool, input);
    try common.out(io, try renderSearch(
        arena,
        query,
        try common.sortedMatches(arena, common.arrayField(result, "adrs")),
        try common.sortedMatches(arena, common.arrayField(result, "rfcs")),
        try common.sortedMatches(arena, common.arrayField(result, "prds")),
    ));
}

fn open(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    try common.out(io, try common.openRecord(arena, "adr", "docs/adrs/<number>-<slug>.md", opts.arg1, tool));
}

// ------------------------------------------------------------------ writing --

fn create(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    const title = opts.arg1 orelse return missingCreateArg("a title phrased as the choice made");
    const context = opts.arg2 orelse return missingCreateArg("the context: the constraint that forced a choice");
    const decision = opts.arg3 orelse return missingCreateArg("the decision itself, in one or two sentences");
    const consequences = opts.arg4 orelse return missingCreateArg("the consequences, including the honest downside");

    const input = try common.request(arena, &.{
        .{ .name = "action", .value = .{ .text = "create" } },
        .{ .name = "title", .value = .{ .text = title } },
        .{ .name = "context", .value = .{ .text = context } },
        .{ .name = "decision", .value = .{ .text = decision } },
        .{ .name = "consequences", .value = .{ .text = consequences } },
        .{ .name = "rfc", .value = common.Field.optional(opts.arg5) },
    });

    const result = try common.callTool(arena, "adr", tool, input);
    try common.out(io, try renderCreated(
        arena,
        json_util.strFieldOrEmpty(result.object, "path"),
        json_util.strFieldOrEmpty(result.object, "rfc"),
        common.boolField(result, "indexed"),
    ));
    // The slug is derived from the title in this store, so a dated slug here
    // comes from a dated title rather than a typed one -- rarer than in
    // `reports`, and the same self-contradiction when it happens.
    if (try common.dateWarningBlock(arena, result)) |warning| try common.out(io, warning);
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
    common.usageError("adr create needs {s}: clanker adr create \"<decision as the choice made>\" \"<context>\" \"<decision>\" \"<consequences>\" [rfc path]", .{what});
    return Error.MissingArg;
}

fn append(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    try common.out(io, try common.appendRecord(arena, "adr", "docs/adrs/<name>.md \"## Revision\\n\\n...\"", opts.arg1, opts.arg2, tool));
}

fn update(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    try common.out(io, try common.updateRecord(arena, "adr", opts.arg1, opts.arg2, opts.arg3, opts.replace_all, tool));
}

const status_usage: common.StatusUsage = .{
    .example = "docs/adrs/<name>.md superseded \"Superseded by ADR 0021.\"",
    .path_arg = "an ADR path",
    .status_arg = "a status: accepted, superseded or deprecated",
    .index_warning = "\nThe inventory line was not updated (the entry is missing or the index\nchanged concurrently). Set its status by hand in docs/adrs/README.md so\nthe index does not disagree with the record.\n",
};

fn setStatus(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    try common.out(io, try common.setRecordStatus(arena, "adr", status_usage, opts.arg1, opts.arg2, opts.arg3, tool));
}

// ----------------------------------------------------------------- the tool --

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
    std.mem.sort(std.json.Value, adrs, {}, common.byPath);

    if (adrs.len == 0) {
        try w.writer.writeAll("no ADRs yet.\n\n");
        try w.writer.print("Record the first decision as {d:0>4}:\n\n", .{next_number});
        try w.writer.writeAll("  clanker adr create \"<the choice made>\" \"<context>\" \"<decision>\" \"<consequences>\"\n");
        return w.written();
    }

    try w.writer.print("{d} ADR(s)\n\n", .{adrs.len});
    try common.renderStatusRows(&w.writer, adrs, 8, status_column_max, title_column_bytes, stripAdrPrefix);

    try w.writer.print("\nNEXT\n\n  next free number is {d:0>4}\n", .{next_number});
    try w.writer.writeAll("  clanker adr open <path>          read one in full\n");
    return w.written();
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
    try common.renderMatchGroup(&w.writer, "ADRS", adrs);
    try common.renderMatchGroup(&w.writer, "RFCS", rfcs);
    try common.renderMatchGroup(&w.writer, "PRDS", prds);
    if (adrs.len > 0) {
        try w.writer.writeAll("An ADR matched: this is already decided. Read it before re-opening the\nquestion, and supersede it rather than editing it if it has to change.\n\n");
    } else if (rfcs.len > 0) {
        try w.writer.writeAll("Only RFCs matched: the question is open, not settled. Write the ADR once\nit is decided.\n\n");
    } else if (prds.len > 0) {
        try w.writer.writeAll("Only PRDs matched: a feature already specifies around this ground. Read\nit before opening an RFC over the same territory.\n\n");
    }
    try w.writer.writeAll("NEXT\n\n");
    try w.writer.writeAll("  clanker adr open <path>          read the record before trusting it\n");
    return w.written();
}

// -------------------------------------------------------------------- tests --

const testing = std.testing;

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

    const adrs = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\[{"path":"docs/adrs/0004-providers.md","title":"Providers are a native vtable","status":"Accepted"},
        \\ {"path":"docs/adrs/0002-old.md","title":"An earlier call","status":"Superseded"}]
    , .{});
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
    const adrs = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\[{"path":"docs/adrs/0011-c.md","title":"C","status":"Accepted"},
        \\ {"path":"docs/adrs/0002-a.md","title":"A","status":"Accepted"},
        \\ {"path":"docs/adrs/0004-b.md","title":"B","status":"Accepted"}]
    , .{});
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
    const adrs = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\[{"path":"docs/adrs/0001-board.md","title":"ADR 0001 — The board is a chatroom","status":"Accepted"},
        \\ {"path":"docs/adrs/0014-uploads.md","title":"ADR 0014: Uploads land in Knowledge","status":"Accepted"}]
    , .{});
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

    const adrs = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\[{"path":"docs/adrs/0001-x.md","title":"ADRs are a good idea","status":"Accepted"}]
    , .{});
    const text = try renderList(arena, adrs.array.items, 2);
    try testing.expect(std.mem.find(u8, text, "ADRs are a good idea") != null);
}

test "renderList still lists an ADR whose status could not be read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const adrs = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\[{"path":"docs/adrs/0009-unreadable.md","title":"","status":""}]
    , .{});
    const text = try renderList(arena, adrs.array.items, 10);
    try testing.expect(std.mem.find(u8, text, "docs/adrs/0009-unreadable.md") != null);
    try testing.expect(std.mem.find(u8, text, "?") != null);
}

test "renderSearch says an ADR hit means the question is settled" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const adrs = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\[{"file":"docs/adrs/0004-providers.md","line":12,"text":"providers are a native vtable"}]
    , .{});
    const text = try renderSearch(arena, "vtable", adrs.array.items, &.{}, &.{});
    try testing.expect(std.mem.find(u8, text, "ADRS") != null);
    try testing.expect(std.mem.find(u8, text, "already decided") != null);
    try testing.expect(std.mem.find(u8, text, "supersede it rather than editing it") != null);
}

test "renderSearch distinguishes an open RFC from a settled ADR" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rfcs = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\[{"file":"docs/rfcs/0006-locks.md","line":3,"text":"where ck_cas lock sidecars live"}]
    , .{});
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

/// `clanker adr rename <path> <new-slug>`. The ADR's number is its identity
/// and stays: a decision is cited by number, and `status ... superseded`
/// links forward to one.
fn rename(io: std.Io, arena: std.mem.Allocator, opts: Options, tool: Tool) !void {
    try common.out(io, try common.renameRecord(
        arena,
        "adr",
        "docs/adrs/<NNNN-name>.md",
        "lowercase letters, digits and hyphens; the ADR keeps its number",
        "docs/adrs/",
        opts.arg1,
        opts.arg2,
        tool,
    ));
}
