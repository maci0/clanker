//! `clanker research <sub>`, the operator surface over the sandboxed `research`
//! tool (`tools/zig/research.zig`).
//!
//! Same arrangement as `reports/command.zig`, for the same reason: `cli.zig`
//! owns argument parsing and the sandbox, a subsystem's own printing is
//! neither, and the tool stays the single implementation of the store. The
//! tool call arrives through the `Tool` callback below, so this module renders
//! and tests without a WASM runtime.
//!
//! The tool answers in JSON shaped for a model: every angle, every source,
//! every hit, each with the provenance a model needs to decide what to open. A
//! person at a terminal wants the same material as columns they can skim and
//! paths they can paste. That translation is all this file is.
//!
//! Nothing here decides what is true. A sweep is other people's text; the
//! renderer says so at the end of every one, because the terminal is exactly
//! where a snippet is most likely to be mistaken for a finding.

const std = @import("std");
const log = @import("../util/log.zig");
const utf8 = @import("../util/utf8.zig");
const json_util = @import("../util/json.zig");
const common = @import("../records/common.zig");
const reports_cmd = @import("../reports/command.zig");

pub const Options = struct {
    /// "list" (default), "plan", "sweep", "search", "open", "create",
    /// "append", "update" or "status".
    sub: []const u8 = "list",
    /// `plan`/`sweep`: the topic. `search`: the query. `open`/`append`/
    /// `update`/`status`: the path. `create`: the slug.
    arg1: ?[]const u8 = null,
    /// `plan`: the question. `sweep`: the depth. `create`: the title.
    /// `append`: the content. `update`: the old text. `status`: the state.
    arg2: ?[]const u8 = null,
    /// `create`: the question. `update`: the new text. `status`: the note.
    arg3: ?[]const u8 = null,
    /// `create`: unused today; kept so the four positionals line up with the
    /// parser's, the way `reports` does.
    arg4: ?[]const u8 = null,
};

pub const Error = common.Error;

pub const Tool = common.Tool;

/// A snippet is a lead. Past this the line is prose that belongs in the page,
/// not in a column of candidates, and an 80-column terminal cannot hold it
/// anyway.
const snippet_bytes: usize = 96;
/// Statuses are one word ("Draft", "Current", "Stale", "Superseded").
const status_column_max: usize = 18;
const status_column_min: usize = 10;

pub fn cmd(init: std.process.Init, opts: Options, tool: Tool) !void {
    try common.out(init.io, try run(init.arena.allocator(), opts, tool));
}

/// The whole subcommand surface as rendered text. `cmd` prints it to stdout;
/// the TUI's `/research` folds the same text into the transcript, so both
/// surfaces stay one implementation of the store's operator view.
pub fn run(arena: std.mem.Allocator, opts: Options, tool: Tool) anyerror![]const u8 {
    const sub = opts.sub;

    if (std.mem.eql(u8, sub, "list")) return list(arena, tool);
    if (std.mem.eql(u8, sub, "plan")) return plan(arena, opts, tool);
    if (std.mem.eql(u8, sub, "sweep")) return sweep(arena, opts, tool);
    if (std.mem.eql(u8, sub, "search")) return search(arena, opts, tool);
    if (std.mem.eql(u8, sub, "open")) return open(arena, opts, tool);
    if (std.mem.eql(u8, sub, "create")) return create(arena, opts, tool);
    if (std.mem.eql(u8, sub, "append")) return append(arena, opts, tool);
    if (std.mem.eql(u8, sub, "update")) return update(arena, opts, tool);
    if (std.mem.eql(u8, sub, "status")) return setStatus(arena, opts, tool);

    log.log(.error_, "unknown research subcommand '{s}' (expected list, plan, sweep, search, open, create, append, update or status)", .{sub});
    return Error.BadSubcommand;
}

// ------------------------------------------------------------------ reading --

fn list(arena: std.mem.Allocator, tool: Tool) ![]const u8 {
    const result = try common.callTool(arena, "research", tool, "{\"action\":\"list\"}");
    return renderList(arena, json_util.strFieldOrEmpty(result.object, "index"));
}

fn search(arena: std.mem.Allocator, opts: Options, tool: Tool) ![]const u8 {
    const query = opts.arg1 orelse {
        log.log(.error_, "research search needs a query: clanker research search \"embedded kv\"", .{});
        return Error.MissingArg;
    };

    const input = try common.request(arena, &.{
        .{ .name = "action", .value = .{ .text = "search" } },
        .{ .name = "query", .value = .{ .text = query } },
    });
    const result = try common.callTool(arena, "research", tool, input);
    return renderSearch(arena, query, common.arrayField(result, "matches"));
}

fn open(arena: std.mem.Allocator, opts: Options, tool: Tool) ![]const u8 {
    const path = opts.arg1 orelse {
        log.log(.error_, "research open needs a path: clanker research open docs/research/<name>.md", .{});
        return Error.MissingArg;
    };

    const input = try common.request(arena, &.{
        .{ .name = "action", .value = .{ .text = "open" } },
        .{ .name = "path", .value = .{ .text = path } },
    });
    const result = try common.callTool(arena, "research", tool, input);
    // The note is markdown that was written to be read; return it as it is.
    const text = json_util.strFieldOrEmpty(result.object, "text");
    if (text.len > 0 and text[text.len - 1] != '\n') return std.fmt.allocPrint(arena, "{s}\n", .{text});
    return text;
}

// ---------------------------------------------------------------- gathering --

fn plan(arena: std.mem.Allocator, opts: Options, tool: Tool) ![]const u8 {
    const topic = opts.arg1 orelse {
        log.log(.error_, "research plan needs a topic: clanker research plan \"embedded key-value stores\" \"which one fits a single-writer sidecar?\"", .{});
        return Error.MissingArg;
    };
    const input = try common.request(arena, &.{
        .{ .name = "action", .value = .{ .text = "plan" } },
        .{ .name = "topic", .value = .{ .text = topic } },
        .{ .name = "question", .value = .{ .text = opts.arg2 orelse "" } },
        .{ .name = "depth", .value = .{ .text = opts.arg3 orelse "standard" } },
    });
    const result = try common.callTool(arena, "research", tool, input);
    return renderPlan(arena, result);
}

fn sweep(arena: std.mem.Allocator, opts: Options, tool: Tool) ![]const u8 {
    const topic = opts.arg1 orelse {
        log.log(.error_, "research sweep needs a topic: clanker research sweep \"embedded key-value stores\" deep", .{});
        return Error.MissingArg;
    };
    const input = try common.request(arena, &.{
        .{ .name = "action", .value = .{ .text = "sweep" } },
        .{ .name = "topic", .value = .{ .text = topic } },
        .{ .name = "depth", .value = .{ .text = opts.arg2 orelse "standard" } },
    });
    const result = try common.callTool(arena, "research", tool, input);
    return renderSweep(arena, result);
}

// ------------------------------------------------------------------ writing --

fn create(arena: std.mem.Allocator, opts: Options, tool: Tool) ![]const u8 {
    const slug = opts.arg1 orelse return missingCreateArg("a slug");
    const title = opts.arg2 orelse return missingCreateArg("a title");
    const question = opts.arg3 orelse return missingCreateArg("the question the note answers");

    const input = try common.request(arena, &.{
        .{ .name = "action", .value = .{ .text = "create" } },
        .{ .name = "slug", .value = .{ .text = slug } },
        .{ .name = "title", .value = .{ .text = title } },
        .{ .name = "question", .value = .{ .text = question } },
    });
    const result = try common.callTool(arena, "research", tool, input);
    const path = json_util.strFieldOrEmpty(result.object, "path");

    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();
    try w.writer.print("created {s}\n", .{path});
    // The scaffold is a skeleton of prompts. Saying so here is what keeps a
    // half-filled note from being mistaken for a finished one.
    try w.writer.print("\nFill the TL;DR, the options and the out-of-the-box options:\n  clanker research open {s}\n", .{path});
    try w.writer.writeAll("\nEvery claim needs a link, the date it was read, and a confidence.\nMark anything unchecked as unverified.\n");
    if (!common.boolField(result, "indexed")) {
        try w.writer.writeAll("\nThe inventory was not updated (it changed concurrently). Add the link\nby hand in docs/research/README.md without replacing the other edit.\n");
    }
    return try w.toOwnedSlice();
}

fn missingCreateArg(what: []const u8) Error {
    log.log(.error_, "research create needs {s}: clanker research create embedded-kv \"Embedded key-value stores\" \"Which one fits a single-writer sidecar?\"", .{what});
    return Error.MissingArg;
}

fn append(arena: std.mem.Allocator, opts: Options, tool: Tool) ![]const u8 {
    const path = opts.arg1 orelse {
        log.log(.error_, "research append needs a path and markdown content: clanker research append docs/research/<name>.md -- \"## Finding\\n\\n...\"", .{});
        return Error.MissingArg;
    };
    const content = opts.arg2 orelse {
        log.log(.error_, "research append needs the markdown to add after the path", .{});
        return Error.MissingArg;
    };

    const input = try common.request(arena, &.{
        .{ .name = "action", .value = .{ .text = "append" } },
        .{ .name = "path", .value = .{ .text = path } },
        .{ .name = "content", .value = .{ .text = content } },
    });
    const result = try common.callTool(arena, "research", tool, input);
    return std.fmt.allocPrint(arena, "appended to {s}\n", .{json_util.strFieldOrEmpty(result.object, "path")});
}

fn update(arena: std.mem.Allocator, opts: Options, tool: Tool) ![]const u8 {
    const path = opts.arg1 orelse {
        log.log(.error_, "research update needs a path, the exact old text, and its replacement", .{});
        return Error.MissingArg;
    };
    const old = opts.arg2 orelse {
        log.log(.error_, "research update needs the exact current text to replace; copy it from `clanker research open {s}`", .{path});
        return Error.MissingArg;
    };
    // An empty replacement deletes the old text, which the tool supports, so
    // the third argument has to be present but may be "".
    const new = opts.arg3 orelse {
        log.log(.error_, "research update needs replacement text after the old text (\"\" removes it)", .{});
        return Error.MissingArg;
    };

    const input = try common.request(arena, &.{
        .{ .name = "action", .value = .{ .text = "update" } },
        .{ .name = "path", .value = .{ .text = path } },
        .{ .name = "old", .value = .{ .text = old } },
        .{ .name = "new", .value = .{ .text = new } },
    });
    const result = try common.callTool(arena, "research", tool, input);
    return std.fmt.allocPrint(arena, "updated {s}\n", .{json_util.strFieldOrEmpty(result.object, "path")});
}

fn setStatus(arena: std.mem.Allocator, opts: Options, tool: Tool) ![]const u8 {
    const path = opts.arg1 orelse return missingStatusArg("a note path");
    const wanted = opts.arg2 orelse return missingStatusArg("a state: draft, current, stale or superseded");

    const input = try common.request(arena, &.{
        .{ .name = "action", .value = .{ .text = "status" } },
        .{ .name = "path", .value = .{ .text = path } },
        .{ .name = "status", .value = .{ .text = wanted } },
        .{ .name = "note", .value = .{ .text = opts.arg3 orelse "" } },
    });
    const result = try common.callTool(arena, "research", tool, input);

    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();
    try w.writer.print("{s} is now {s}\n", .{
        json_util.strFieldOrEmpty(result.object, "path"),
        json_util.strFieldOrEmpty(result.object, "status"),
    });
    if (!common.boolField(result, "indexed")) {
        try w.writer.writeAll("\nThe inventory line was not updated (the entry is missing or the index\nchanged concurrently). Set its status by hand in docs/research/README.md so\nthe index does not disagree with the note.\n");
    }
    return try w.toOwnedSlice();
}

fn missingStatusArg(what: []const u8) Error {
    log.log(.error_, "research status needs {s}: clanker research status docs/research/<name>.md current \"read on 2026-08-16\"", .{what});
    return Error.MissingArg;
}

// ----------------------------------------------------------------- the tool --

fn strOf(v: std.json.Value, name: []const u8) []const u8 {
    if (v != .object) return "";
    return json_util.strFieldOrEmpty(v.object, name);
}

// --------------------------------------------------------------- the listing --

/// The note inventory, read out of the index README the tool maintains.
///
/// The parser is `reports/command.zig`'s: both indexes are the same
/// `<!-- inventory:kind:start -->` block of `- [title](link) — status` lines,
/// written by the same `doc_scaffold.zig` helpers. One parser, so a change to
/// the block shape cannot fix one listing and silently break the other.
pub fn renderList(arena: std.mem.Allocator, index_md: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();

    const entries = try reports_cmd.inventory(arena, index_md, "research", "docs/research");
    if (entries.len == 0) {
        try w.writer.writeAll("No research notes yet. Gather sources, then record what survives:\n\n");
        try w.writer.writeAll("  clanker research sweep \"<topic>\"\n");
        try w.writer.writeAll("  clanker research create <slug> \"<title>\" \"<the question it answers>\"\n");
        return w.written();
    }

    try w.writer.writeAll("NOTES\n\n");
    const width = reports_cmd.statusWidth(entries);
    for (entries) |e| {
        const status = if (e.note.len > 0 and e.note.len <= status_column_max) e.note else "";
        try w.writer.splatByteAll(' ', 2);
        try w.writer.print("{s}", .{status});
        try w.writer.splatByteAll(' ', width -| status.len);
        try w.writer.print("{s}\n", .{e.title});
        try w.writer.splatByteAll(' ', 2 + width);
        try w.writer.print("{s}\n", .{e.path});
        // Prose that would not fit the status column keeps its own line rather
        // than being cut to a width it was never written for.
        if (status.len == 0 and e.note.len > 0) {
            try w.writer.splatByteAll(' ', 2 + width);
            try w.writer.print("{s}\n", .{e.note});
        }
        try w.writer.writeByte('\n');
    }

    try w.writer.writeAll("NEXT\n\n");
    try w.writer.writeAll("  clanker research open <path>        print one note in full\n");
    try w.writer.writeAll("  clanker research search \"<text>\"     search every note\n");
    try w.writer.writeAll("  clanker research sweep \"<topic>\"     gather sources for a new one\n");
    return w.written();
}

// ---------------------------------------------------------------- the search --

/// Grep hits grouped by the note they came from, because the question a search
/// answers is "which note is this in", not "which line".
pub fn renderSearch(arena: std.mem.Allocator, query: []const u8, matches: []const std.json.Value) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();

    if (matches.len == 0) {
        try w.writer.print("no research note mentions \"{s}\".\n\n", .{query});
        try w.writer.writeAll("Gather sources before writing one:\n\n");
        try w.writer.print("  clanker research plan \"{s}\"\n", .{query});
        try w.writer.print("  clanker research sweep \"{s}\"\n", .{query});
        return w.written();
    }

    try w.writer.print("{d} matching line(s) for \"{s}\"\n\n", .{ matches.len, query });
    try common.renderMatchRows(&w.writer, matches);
    try w.writer.writeAll("\nNEXT\n\n");
    try w.writer.writeAll("  clanker research open <path>       read the note before trusting it\n");
    return w.written();
}

// ------------------------------------------------------------------ the plan --

/// The queries a sweep would issue, the sources it cannot reach itself, and
/// the candidates no keyword search returns.
pub fn renderPlan(arena: std.mem.Allocator, result: std.json.Value) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();

    const topic = json_util.strFieldOrEmpty(result.object, "topic");
    try w.writer.print("plan: {s}\n", .{topic});
    try w.writer.print("depth {s}\n", .{json_util.strFieldOrEmpty(result.object, "depth")});
    if (result.object.get("warning")) |v| {
        if (v == .string) try w.writer.print("\nwarning: {s}\n", .{v.string});
    }

    const queries = common.arrayField(result, "queries");
    if (queries.len > 0) {
        try w.writer.writeAll("\nQUERIES\n\n");
        const width = columnWidth(queries, "angle");
        for (queries) |q| {
            try w.writer.splatByteAll(' ', 2);
            const angle = strOf(q, "angle");
            try w.writer.print("{s}", .{angle});
            try w.writer.splatByteAll(' ', width -| angle.len);
            try w.writer.print("{s}\n", .{strOf(q, "query")});
            // The reason an angle exists is the part that survives being
            // skimmed; it gets its own line under the query it explains.
            const why = strOf(q, "why");
            if (why.len > 0) {
                try w.writer.splatByteAll(' ', 2 + width);
                try w.writer.print("{s}\n", .{why});
            }
            try w.writer.writeByte('\n');
        }
    }

    const sources = common.arrayField(result, "sources");
    if (sources.len > 0) {
        try w.writer.writeAll("SOURCES\n\n");
        const width = columnWidth(sources, "name");
        for (sources) |s| {
            try w.writer.splatByteAll(' ', 2);
            const name = strOf(s, "name");
            try w.writer.print("{s}", .{name});
            try w.writer.splatByteAll(' ', width -| name.len);
            try w.writer.print("{s}\n", .{strOf(s, "covers")});
            try w.writer.splatByteAll(' ', 2 + width);
            try w.writer.print("reach it with {s}\n\n", .{strOf(s, "how")});
        }
    }

    const otb = common.arrayField(result, "out_of_the_box");
    if (otb.len > 0) {
        try w.writer.writeAll("OUT-OF-THE-BOX OPTIONS\n\n");
        try w.writer.writeAll("  A sweep cannot return these. Answer each one explicitly.\n\n");
        for (otb) |item| {
            if (item != .string) continue;
            try w.writer.print("  {s}\n", .{item.string});
        }
        try w.writer.writeByte('\n');
    }

    try w.writer.writeAll("NEXT\n\n");
    try w.writer.print("  clanker research sweep \"{s}\"   issue these queries across every source\n", .{topic});
    return w.written();
}

/// Widest value of `field` across the rows, plus a two-space gutter, so a
/// column is as wide as its content rather than a guessed constant.
fn columnWidth(rows: []const std.json.Value, field: []const u8) usize {
    var widest: usize = 0;
    for (rows) |r| {
        const v = strOf(r, field);
        if (v.len > widest) widest = v.len;
    }
    return widest + 2;
}

// ----------------------------------------------------------------- the sweep --

/// Everything the sweep gathered, one section per source, each hit with the
/// URL to open it. The closing line is not decoration: these are strangers'
/// words, and a terminal is where they are most easily mistaken for findings.
pub fn renderSweep(arena: std.mem.Allocator, result: std.json.Value) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    errdefer w.deinit();

    try w.writer.print("sweep: {s}\n", .{json_util.strFieldOrEmpty(result.object, "topic")});
    try w.writer.print("depth {s} · {d} fetches · {d} duplicate(s) dropped\n", .{
        json_util.strFieldOrEmpty(result.object, "depth"),
        common.unsignedField(result, "fetches"),
        common.unsignedField(result, "duplicates_dropped"),
    });
    if (result.object.get("warning")) |v| {
        if (v == .string) try w.writer.print("\nwarning: {s}\n", .{v.string});
    }

    const web = common.arrayField(result, "web");
    const github = common.arrayField(result, "github");
    const discussions = common.arrayField(result, "discussions");
    const papers = common.arrayField(result, "papers");

    if (web.len > 0) {
        try w.writer.writeAll("\nWEB\n\n");
        for (web) |hit| {
            try w.writer.print("  {s}\n", .{strOf(hit, "title")});
            try w.writer.print("    {s}\n", .{strOf(hit, "url")});
            const snippet = strOf(hit, "snippet");
            if (snippet.len > 0) try w.writer.print("    {s}\n", .{common.ellipsize(snippet, snippet_bytes)});
            // Which angle found it, and which backend answered: a hit only one
            // backend returns is worth a different amount of trust.
            try w.writer.print("    [{s} · {s}]\n\n", .{ strOf(hit, "angle"), strOf(hit, "backend") });
        }
    }

    if (github.len > 0) {
        try w.writer.writeAll("GITHUB\n\n");
        for (github) |repo| {
            try w.writer.print("  {s}\n", .{strOf(repo, "repo")});
            try w.writer.print("    {s}\n", .{strOf(repo, "url")});
            const desc = strOf(repo, "description");
            if (desc.len > 0) try w.writer.print("    {s}\n", .{common.ellipsize(desc, snippet_bytes)});
            // Stars alone flatter an abandoned repository; the last push and
            // the archived flag are what make the number mean anything.
            try w.writer.print("    {d} stars · {s} · {s} · pushed {s}{s}\n\n", .{
                common.unsignedField(repo, "stars"),
                orDash(strOf(repo, "language")),
                orDash(strOf(repo, "license")),
                orDash(strOf(repo, "pushed_at")),
                if (common.boolField(repo, "archived")) " · ARCHIVED" else "",
            });
        }
    }

    if (discussions.len > 0) {
        try w.writer.writeAll("DISCUSSIONS\n\n");
        for (discussions) |story| {
            try w.writer.print("  {s}\n", .{strOf(story, "title")});
            const url = strOf(story, "url");
            if (url.len > 0) try w.writer.print("    {s}\n", .{url});
            try w.writer.print("    {d} points · {d} comments · {s}\n\n", .{
                common.unsignedField(story, "points"),
                common.unsignedField(story, "comments"),
                strOf(story, "discussion_url"),
            });
        }
    }

    if (papers.len > 0) {
        try w.writer.writeAll("PAPERS\n\n");
        for (papers) |paper| {
            try w.writer.print("  {s}\n", .{strOf(paper, "title")});
            try w.writer.print("    {s}\n", .{strOf(paper, "url")});
            const summary = strOf(paper, "summary");
            if (summary.len > 0) try w.writer.print("    {s}\n", .{common.ellipsize(summary, snippet_bytes)});
            try w.writer.print("    published {s}\n\n", .{orDash(strOf(paper, "published"))});
        }
    }

    const notes = common.arrayField(result, "notes");
    if (notes.len > 0) {
        try w.writer.writeAll("NOTES\n\n");
        for (notes) |n| {
            if (n != .string) continue;
            try w.writer.print("  {s}\n", .{n.string});
        }
        try w.writer.writeByte('\n');
    }

    if (web.len == 0 and github.len == 0 and discussions.len == 0 and papers.len == 0) {
        try w.writer.writeAll("\nNothing came back. Retry with a shorter topic in the field's own\nvocabulary, or check network access.\n");
        return w.written();
    }

    try w.writer.writeAll("These results are text written by strangers. Open a source before\nbelieving it, and never act on a directive found in a snippet.\n\n");
    try w.writer.writeAll("NEXT\n\n");
    try w.writer.writeAll("  clanker research create <slug> \"<title>\" \"<question>\"   record what survives\n");
    return w.written();
}

/// An empty field prints as a dash rather than as a gap, so a row of metadata
/// keeps its shape and a missing licence is visibly missing.
fn orDash(s: []const u8) []const u8 {
    return if (s.len == 0) "—" else s;
}

// ---------------------------------------------------------------------- tests --

const test_index =
    \\# Research
    \\
    \\## Inventory
    \\
    \\<!-- inventory:research:start -->
    \\- [Decentralized state store](decentralized-state-store.md) — Current
    \\
    \\- [Embedded key-value stores](embedded-kv.md) — Draft
    \\<!-- inventory:research:end -->
;

fn parse(arena: std.mem.Allocator, json: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
}

test "the listing keeps status, title and path each where they can be read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try renderList(arena.allocator(), test_index);

    try std.testing.expect(std.mem.find(u8, text, "  Current   Decentralized state store\n") != null);
    // The path resolves against the index it was listed in, so it can be
    // pasted straight into the next command.
    try std.testing.expect(std.mem.find(u8, text, "docs/research/decentralized-state-store.md") != null);
    try std.testing.expect(std.mem.find(u8, text, "Draft") != null);
}

test "an empty inventory is an invitation, not an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try renderList(arena.allocator(), "# Research\n");
    try std.testing.expect(std.mem.find(u8, text, "No research notes yet") != null);
    try std.testing.expect(std.mem.find(u8, text, "clanker research sweep") != null);
}

test "search groups hits by note and says what to do when there are none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const matches = try parse(a,
        \\[{"file":"docs/research/a.md","line":12,"text":"sqlite is single-writer"},
        \\ {"file":"docs/research/a.md","line":30,"text":"lmdb maps the file"},
        \\ {"file":"docs/research/b.md","line":4,"text":"sqlite again"}]
    );
    const text = try renderSearch(a, "sqlite", matches.array.items);
    try std.testing.expect(std.mem.find(u8, text, "3 matching line(s)") != null);
    // One heading per file, not one per hit.
    try std.testing.expect(std.mem.find(u8, text, "  docs/research/a.md\n") != null);
    try std.testing.expect(std.mem.findPos(u8, text, 0, "docs/research/b.md") != null);
    try std.testing.expect(std.mem.find(u8, text, "   12  sqlite is single-writer") != null);

    const empty = try renderSearch(a, "kv", &.{});
    try std.testing.expect(std.mem.find(u8, empty, "no research note mentions \"kv\"") != null);
    try std.testing.expect(std.mem.find(u8, empty, "clanker research sweep \"kv\"") != null);
}

test "the plan prints each angle's query and the reason it exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try parse(a,
        \\{"ok":true,"topic":"embedded kv","depth":"standard",
        \\ "queries":[{"angle":"overview","query":"embedded kv 2026","why":"the field's own words"},
        \\            {"angle":"limits","query":"embedded kv limitations","why":"what it costs"}],
        \\ "sources":[{"name":"web","covers":"documentation","how":"research sweep"}],
        \\ "out_of_the_box":["Do nothing: what breaks?"]}
    );
    const text = try renderPlan(a, result);
    try std.testing.expect(std.mem.find(u8, text, "plan: embedded kv") != null);
    // Angle column is padded to the widest angle, so the queries line up.
    try std.testing.expect(std.mem.find(u8, text, "  overview  embedded kv 2026\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "  limits    embedded kv limitations\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "the field's own words") != null);
    try std.testing.expect(std.mem.find(u8, text, "OUT-OF-THE-BOX OPTIONS") != null);
    try std.testing.expect(std.mem.find(u8, text, "Do nothing: what breaks?") != null);
}

test "the sweep prints every source section and warns that hits are untrusted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = try parse(a,
        \\{"ok":true,"topic":"kv","depth":"deep","fetches":9,"duplicates_dropped":2,
        \\ "web":[{"title":"LMDB","url":"https://lmdb.tech","host":"lmdb.tech","snippet":"memory-mapped","angle":"overview","backend":"duckduckgo"}],
        \\ "github":[{"repo":"a/b","url":"https://github.com/a/b","description":"a store","stars":120,"language":"C","license":"MIT","pushed_at":"2026-01-02","archived":true}],
        \\ "discussions":[{"title":"Why lmdb","url":"https://x.dev","discussion_url":"https://news.ycombinator.com/item?id=1","points":80,"comments":40}],
        \\ "papers":[{"title":"A paper","url":"https://arxiv.org/abs/1","published":"2025-01-01","summary":"about stores"}],
        \\ "notes":["A source was unreachable for one query."]}
    );
    const text = try renderSweep(a, result);
    try std.testing.expect(std.mem.find(u8, text, "depth deep · 9 fetches · 2 duplicate(s) dropped") != null);
    inline for (.{ "WEB", "GITHUB", "DISCUSSIONS", "PAPERS", "NOTES" }) |heading| {
        try std.testing.expect(std.mem.find(u8, text, heading) != null);
    }
    // An archived repository has to say so next to its star count, or the
    // number reads as health.
    try std.testing.expect(std.mem.find(u8, text, "120 stars · C · MIT · pushed 2026-01-02 · ARCHIVED") != null);
    try std.testing.expect(std.mem.find(u8, text, "text written by strangers") != null);
}

test "an empty sweep says so instead of printing bare headings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try parse(a, "{\"ok\":true,\"topic\":\"kv\",\"depth\":\"quick\",\"fetches\":4,\"web\":[],\"github\":[]}");
    const text = try renderSweep(a, result);
    try std.testing.expect(std.mem.find(u8, text, "Nothing came back") != null);
    try std.testing.expect(std.mem.find(u8, text, "WEB") == null);
}

test "a missing licence or push date prints a dash rather than a gap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try parse(a,
        \\{"ok":true,"topic":"kv","depth":"quick","fetches":1,
        \\ "github":[{"repo":"a/b","url":"https://github.com/a/b","description":"","stars":3,"language":"","license":"","pushed_at":"","archived":false}]}
    );
    const text = try renderSweep(a, result);
    try std.testing.expect(std.mem.find(u8, text, "3 stars · — · — · pushed —\n") != null);
}

test "a refused tool call fails with the tool's own sentence, not a generic error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const Canned = struct {
        answer: []const u8,
        fn call(ctx: *anyopaque, _: []const u8) anyerror![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.answer;
        }
    };
    var canned: Canned = .{ .answer = "{\"ok\":false,\"error\":\"depth must be quick, standard, or deep\"}" };
    const tool: Tool = .{ .ctx = &canned, .call = Canned.call };
    try std.testing.expectError(Error.ToolFailed, common.callTool(arena.allocator(), "research", tool, "{}"));

    canned.answer = "not json at all";
    try std.testing.expectError(Error.ToolFailed, common.callTool(arena.allocator(), "research", tool, "{}"));
}
