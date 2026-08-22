//! `clanker rfc <sub>`, the operator surface over the sandboxed `rfc` tool
//! (`tools/zig/rfc.zig`).
//!
//! Same arrangement as `reports.zig` and `research.zig`, for
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
const utf8 = @import("../util/utf8.zig");
const json_util = @import("../util/json.zig");
const common = @import("common.zig");

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
    /// `create`: the research note path (`docs/research/<name>.md`).
    /// `recommend`: the rationale.
    arg4: ?[]const u8 = null,
};

pub const Error = common.Error;

pub const Tool = common.Tool;

/// Titles are the widest column and the least load-bearing: a reader who needs
/// the whole one opens the record.
const title_column_bytes: usize = 58;
/// Statuses are one word ("Draft", "Discussion", "Decided", ...).
const status_column_max: usize = 12;

/// Every subcommand the dispatch below accepts, in the order `--help`
/// lists them. The spec's usage line in `cli.zig` is pinned to this list.
pub const subcommands = [_][]const u8{ "list", "search", "open", "checklist", "create", "append", "update", "recommend", "status", "rename" };

pub fn cmd(init: std.process.Init, opts: Options, tool: Tool) !void {
    try common.out(init.io, try run(init.arena.allocator(), opts, tool));
}

/// The whole subcommand surface as rendered text. `cmd` prints it to stdout;
/// the TUI's `/rfc` folds the same text into the transcript, so both surfaces
/// stay one implementation of the store's operator view.
pub fn run(arena: std.mem.Allocator, opts: Options, tool: Tool) anyerror![]const u8 {
    const sub = opts.sub;

    if (std.mem.eql(u8, sub, "list")) return list(arena, tool);
    if (std.mem.eql(u8, sub, "search")) return search(arena, opts, tool);
    if (std.mem.eql(u8, sub, "open")) return open(arena, opts, tool);
    if (std.mem.eql(u8, sub, "checklist")) return checklist(arena, opts, tool);
    if (std.mem.eql(u8, sub, "create")) return create(arena, opts, tool);
    if (std.mem.eql(u8, sub, "append")) return append(arena, opts, tool);
    if (std.mem.eql(u8, sub, "update")) return update(arena, opts, tool);
    if (std.mem.eql(u8, sub, "recommend")) return recommend(arena, opts, tool);
    if (std.mem.eql(u8, sub, "status")) return setStatus(arena, opts, tool);
    if (std.mem.eql(u8, sub, "rename")) return rename(arena, opts, tool);

    return common.badSubcommand("rfc", &subcommands, sub);
}

// ------------------------------------------------------------------ reading --

fn list(arena: std.mem.Allocator, tool: Tool) ![]const u8 {
    const result = try common.callTool(arena, "rfc", tool, "{\"action\":\"list\"}");
    return renderList(arena, common.arrayField(result, "rfcs"), common.unsignedField(result, "next_number"));
}

fn search(arena: std.mem.Allocator, opts: Options, tool: Tool) ![]const u8 {
    const query = try common.requireQuery("rfc", opts.arg1);

    const input = try common.request(arena, &.{
        .{ .name = "action", .value = .{ .text = "search" } },
        .{ .name = "query", .value = .{ .text = query } },
    });

    const result = try common.callTool(arena, "rfc", tool, input);
    return renderSearch(arena, query, try common.sortedMatches(arena, common.arrayField(result, "rfcs")), try common.sortedMatches(arena, common.arrayField(result, "adrs")));
}

fn open(arena: std.mem.Allocator, opts: Options, tool: Tool) ![]const u8 {
    return common.openRecord(arena, "rfc", "docs/rfcs/<number>-<slug>.md", opts.arg1, tool);
}

/// What an RFC has to pin down, and the question to put to whoever asked for
/// it. This is the answer to "the request is too vague to draft from".
fn checklist(arena: std.mem.Allocator, opts: Options, tool: Tool) ![]const u8 {
    const input = try common.request(arena, &.{
        .{ .name = "action", .value = .{ .text = "checklist" } },
        .{ .name = "topic", .value = common.Field.optional(opts.arg1) },
    });

    const result = try common.callTool(arena, "rfc", tool, input);
    return renderChecklist(
        arena,
        json_util.strFieldOrEmpty(result.object, "topic"),
        common.arrayField(result, "requirements"),
        common.arrayField(result, "next"),
    );
}

// ------------------------------------------------------------------ writing --

fn create(arena: std.mem.Allocator, opts: Options, tool: Tool) ![]const u8 {
    const title = opts.arg1 orelse return missingCreateArg("a title naming the decision");
    const overview = opts.arg2 orelse return missingCreateArg("an overview of what has to be decided and why now");

    const input = try common.request(arena, &.{
        .{ .name = "action", .value = .{ .text = "create" } },
        .{ .name = "title", .value = .{ .text = title } },
        .{ .name = "overview", .value = .{ .text = overview } },
        .{ .name = "slug", .value = common.Field.optional(opts.arg3) },
        .{ .name = "research", .value = common.Field.optional(opts.arg4) },
    });

    const result = try common.callTool(arena, "rfc", tool, input);
    const path = json_util.strFieldOrEmpty(result.object, "path");
    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();
    try w.writer.print("created {s}\n", .{path});
    // The scaffold is a skeleton, and an RFC with one option is not a
    // decision: saying so here is what keeps a stub from being mistaken for a
    // finished record.
    try w.writer.writeAll("\nAn RFC needs at least two candidates, the status quo, one out-of-the-box\noption, and a recommendation with a confidence from 0 to 10:\n");
    try w.writer.print("  clanker rfc open {s}\n", .{path});
    try w.writer.print("  clanker rfc recommend {s} \"<recommendation>\" <0-10> \"<rationale>\"\n", .{path});
    if (!common.boolField(result, "indexed")) {
        try w.writer.writeAll("\nThe inventory was not updated (it changed concurrently). Add the link\nby hand from docs/rfcs/README.md without replacing the other edit.\n");
    }
    return try w.toOwnedSlice();
}

fn missingCreateArg(what: []const u8) Error {
    common.usageError("rfc create needs {s}: clanker rfc create \"HTTP client for the proxy\" \"The proxy needs one client and the choice is not recorded\"", .{what});
    return Error.MissingArg;
}

fn append(arena: std.mem.Allocator, opts: Options, tool: Tool) ![]const u8 {
    return common.appendRecord(arena, "rfc", "docs/rfcs/<name>.md \"## Option C\\n\\n...\"", opts.arg1, opts.arg2, tool);
}

fn update(arena: std.mem.Allocator, opts: Options, tool: Tool) ![]const u8 {
    return common.updateRecord(arena, "rfc", opts.arg1, opts.arg2, opts.arg3, tool);
}

/// The Recommendation section, which is the point of the document: a
/// recommendation with no confidence number is an opinion.
fn recommend(arena: std.mem.Allocator, opts: Options, tool: Tool) ![]const u8 {
    const path = opts.arg1 orelse return missingRecommendArg("an RFC path");
    const text = opts.arg2 orelse return missingRecommendArg("the recommendation");
    const confidence_text = opts.arg3 orelse return missingRecommendArg("a confidence from 0 to 10");
    const rationale = opts.arg4 orelse "";

    const confidence = std.fmt.parseInt(u8, std.mem.trim(u8, confidence_text, " \t"), 10) catch {
        common.usageError("rfc recommend needs a whole-number confidence from 0 to 10, not '{s}'", .{confidence_text});
        return Error.MissingArg;
    };
    if (confidence > 10) {
        common.usageError("rfc recommend confidence is 0 to 10, not {d}", .{confidence});
        return Error.MissingArg;
    }

    const input = try common.request(arena, &.{
        .{ .name = "action", .value = .{ .text = "recommend" } },
        .{ .name = "path", .value = .{ .text = path } },
        .{ .name = "recommendation", .value = .{ .text = text } },
        .{ .name = "confidence", .value = .{ .number = confidence } },
        .{ .name = "rationale", .value = .{ .text = rationale } },
    });

    const result = try common.callTool(arena, "rfc", tool, input);
    return std.fmt.allocPrint(arena, "recommended on {s} at confidence {d}/10\n", .{
        json_util.strFieldOrEmpty(result.object, "path"),
        common.unsignedField(result, "confidence"),
    });
}

fn missingRecommendArg(what: []const u8) Error {
    common.usageError("rfc recommend needs {s}: clanker rfc recommend docs/rfcs/<name>.md \"Adopt option B\" 7 \"Why, and what would move it\"", .{what});
    return Error.MissingArg;
}

const status_usage: common.StatusUsage = .{
    .example = "docs/rfcs/<name>.md decided \"Chose option B; see the ADR\"",
    .path_arg = "an RFC path",
    .status_arg = "a status: draft, discussion, decided, deferred, withdrawn or superseded",
    .index_warning = "\nThe inventory line was not updated (the entry is missing or the index\nchanged concurrently). Set its status by hand in docs/rfcs/README.md so\nthe index does not disagree with the record.\n",
};

fn setStatus(arena: std.mem.Allocator, opts: Options, tool: Tool) ![]const u8 {
    return common.setRecordStatus(arena, "rfc", status_usage, opts.arg1, opts.arg2, opts.arg3, tool);
}

// ----------------------------------------------------------------- the tool --

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

    // The tool reports whatever order the directory listing came back in; an
    // RFC store is numbered, so sorting on the path is sorting on the number.
    const sorted = try arena.dupe(std.json.Value, rfcs);
    std.mem.sort(std.json.Value, sorted, {}, common.byPath);

    try w.writer.print("{d} RFC(s)\n\n", .{sorted.len});
    try common.renderStatusRows(&w.writer, sorted, 6, status_column_max, title_column_bytes, common.titleAsIs);

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
    try common.renderMatchGroup(&w.writer, "RFCS", rfcs);
    try common.renderMatchGroup(&w.writer, "ADRS", adrs);
    if (adrs.len > 0) {
        try w.writer.writeAll("An ADR matched: that decision may already be made. Read it before\nopening an RFC over the same ground.\n\n");
    }
    try w.writer.writeAll("NEXT\n\n");
    try w.writer.writeAll("  clanker rfc open <path>          read the record before trusting it\n");
    return w.written();
}

/// The checklist is a list of questions to put to a person, so each one is
/// printed as the question, with what it pins down under it. `next` is the
/// tool's own instruction for turning the answers into an RFC — where to get
/// the evidence, what the option set has to contain, and that the record ends
/// in a recommendation carrying a confidence. It used to be dropped here, so
/// `clanker rfc checklist` and the TUI's `/rfc checklist` returned the
/// questions and none of the guidance the `rfc` tool answers an agent with.
pub fn renderChecklist(
    arena: std.mem.Allocator,
    topic: []const u8,
    requirements: []const std.json.Value,
    next: []const std.json.Value,
) ![]const u8 {
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
        // Whole sentences from the tool: wrapped between words here rather
        // than at the terminal's own margin, which breaks them mid-thought.
        if (why.len > 0) try common.wrapInto(&w.writer, why, "      ", common.help_columns);
        if (ask.len > 0) {
            // The "ask:" label wraps with the question instead of sitting on
            // a line of its own.
            const labelled = try std.fmt.allocPrint(arena, "ask: {s}", .{ask});
            try common.wrapInto(&w.writer, labelled, "      ", common.help_columns);
        }
        try w.writer.writeByte('\n');
    }

    if (next.len > 0) {
        try w.writer.writeAll("NEXT\n\n");
        for (next) |step| {
            if (step != .string) continue;
            try common.wrapInto(&w.writer, step.string, "  ", common.help_columns);
            try w.writer.writeByte('\n');
        }
    }
    return w.written();
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

test "create passes a research path to the tool when arg4 is set" {
    const Ctx = struct {
        captured: []const u8 = "",
        fn call(ctx: *anyopaque, input: []const u8) anyerror![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.captured = input;
            return "{\"ok\":true,\"path\":\"docs/rfcs/0022-x.md\",\"indexed\":true}";
        }
    };
    var ctx = Ctx{};
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tool = Tool{ .ctx = &ctx, .call = Ctx.call };
    const text = try create(arena, .{
        .arg1 = "HTTP client",
        .arg2 = "The proxy needs one",
        .arg3 = "http-client",
        .arg4 = "docs/research/jcode-features.md",
    }, tool);
    try testing.expect(std.mem.find(u8, text, "docs/rfcs/0022-x.md") != null);
    try testing.expect(std.mem.find(u8, ctx.captured, "\"research\":\"docs/research/jcode-features.md\"") != null);
    try testing.expect(std.mem.find(u8, ctx.captured, "\"slug\":\"http-client\"") != null);
}

test "renderChecklist prints the question to ask under each requirement" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const reqs = try parseValue(arena,
        \\[{"needs":"the decision as a question","why":"an RFC without one drifts","ask":"What exactly is being decided?"}]
    );
    const text = try renderChecklist(arena, "http client", reqs.array.items, &.{});
    try testing.expect(std.mem.find(u8, text, "http client") != null);
    try testing.expect(std.mem.find(u8, text, "the decision as a question") != null);
    try testing.expect(std.mem.find(u8, text, "ask: What exactly is being decided?") != null);
}

/// `clanker rfc rename <path> <new-slug>`. The RFC's number is its identity
/// and stays: pass the new name without one.
fn rename(arena: std.mem.Allocator, opts: Options, tool: Tool) ![]const u8 {
    return common.renameRecord(
        arena,
        "rfc",
        "docs/rfcs/<NNNN-name>.md",
        "lowercase letters, digits and hyphens; the RFC keeps its number",
        "docs/rfcs/",
        opts.arg1,
        opts.arg2,
        tool,
    );
}

test "renderChecklist prints the tool's next steps under their own heading" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const reqs = try parseValue(arena,
        \\[{"needs":"the status quo","why":"doing nothing is an option","ask":"What happens today?"}]
    );
    const next = try parseValue(arena,
        \\["Put what the request does not answer to the operator with ask_user.","Then create it with a title and an overview."]
    );
    const text = try renderChecklist(arena, "http client", reqs.array.items, next.array.items);
    try testing.expect(std.mem.find(u8, text, "NEXT") != null);
    try testing.expect(std.mem.find(u8, text, "ask_user") != null);
    try testing.expect(std.mem.find(u8, text, "with a title and an overview") != null);
}

test "checklist renders the guidance the tool returned beside the requirements" {
    const Ctx = struct {
        fn call(_: *anyopaque, _: []const u8) anyerror![]const u8 {
            return
            \\{"ok":true,"topic":"state store","requirements":[{"needs":"the status quo","why":"w","ask":"a"}],
            \\ "next":["An RFC needs at least two real candidates, the status quo among them, and one out-of-the-box possibility."]}
            ;
        }
    };
    var ctx: u8 = 0;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try run(arena, .{ .sub = "checklist", .arg1 = "state store" }, Tool{ .ctx = &ctx, .call = Ctx.call });
    try testing.expect(std.mem.find(u8, text, "the status quo") != null);
    try testing.expect(std.mem.find(u8, text, "out-of-the-box") != null);
}
