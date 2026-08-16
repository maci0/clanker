//! Workflows: reusable prompt templates.
//!
//! A workflow is a markdown file in `workflows_dir` (default "workflows/").
//! Filename (without .md) is the workflow name. Optional YAML frontmatter between
//! leading `---` lines may set `description`, `name`, and `argument-hint`.
//!
//! Body is the prompt template. `{{args}}`, `{{arguments}}`, `$ARGUMENTS`, and
//! `{{$args}}` are replaced with the caller's argument string at run time.
//! Remaining content is used verbatim.
//!
//! `.cursor/workflows/*.md` is also read as a fallback source (see
//! `loadAllMerged`), so a project already using that convention needs no
//! duplicate files: `workflows/*.md` (configurable), `clanker workflow
//! list|show|run`, REPL `/workflows` + `/workflow`, and a `workflows` WASM
//! tool all see the same merged set.
//!
//! Parsing and argument expansion live in the shared, host-tested
//! `tools/zig/workflows_logic.zig` (imported by this module and by the
//! `workflows` WASM tool), so the CLI and the tool cannot drift apart.

const std = @import("std");
const logic = @import("workflows_logic");

/// The workflow record, shared with the `workflows` WASM tool.
pub const Workflow = logic.Workflow;

/// Argument substitution, shared with the `workflows` WASM tool.
pub const instantiate = logic.instantiate;

const max_file_bytes: usize = 64 * 1024;
const max_dir_entries: usize = 512;

/// Scan `workflows_dir` (relative to cwd) and return parsed workflows sorted by name.
/// Missing directory → empty list (not an error); individual unreadable / oversize
/// files are skipped.
pub fn loadAll(arena: std.mem.Allocator, io: std.Io, workflows_dir: []const u8) ![]Workflow {
    var out: std.ArrayList(Workflow) = .empty;

    var dir = std.Io.Dir.cwd().openDir(io, workflows_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return out.toOwnedSlice(arena),
        else => return err,
    };
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        if (entry.name.len <= 3) continue;
        if (names.items.len >= max_dir_entries) break;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    for (names.items) |fname| {
        const raw = dir.readFileAlloc(io, fname, arena, .limited(max_file_bytes)) catch continue;
        const stem = fname[0 .. fname.len - 3];
        const parsed = logic.parseWorkflow(arena, stem, fname, raw) catch continue;
        // Skip files with empty body, they would produce an empty prompt.
        if (std.mem.trim(u8, parsed.body, " \t\r\n").len == 0) continue;
        try out.append(arena, parsed);
    }

    // Already sorted by filename; a frontmatter `name:` can reorder, re-sort by final name.
    std.mem.sort(Workflow, out.items, {}, struct {
        fn lt(_: void, a: Workflow, b: Workflow) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return out.toOwnedSlice(arena);
}

/// Also reads `.cursor/workflows` when different from `workflows_dir`.
/// Primary wins on duplicate names. Re-sorts merged result. Keeping plain `loadAll`
/// single-dir for test stability.
pub fn loadAllMerged(arena: std.mem.Allocator, io: std.Io, workflows_dir: []const u8) ![]Workflow {
    const primary = try loadAll(arena, io, workflows_dir);
    if (workflows_dir.len == 0) return primary;
    const fallback = ".cursor/workflows";
    if (std.mem.eql(u8, workflows_dir, fallback)) return primary;
    const extra = try loadAll(arena, io, fallback);
    if (extra.len == 0) return primary;
    var out: std.ArrayList(Workflow) = .empty;
    try out.appendSlice(arena, primary);
    for (extra) |wf| {
        var dupe = false;
        for (primary) |p| if (std.mem.eql(u8, p.name, wf.name)) {
            dupe = true;
            break;
        };
        if (!dupe) try out.append(arena, wf);
    }
    std.mem.sort(Workflow, out.items, {}, struct {
        fn lt(_: void, a: Workflow, b: Workflow) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return out.toOwnedSlice(arena);
}

/// Find a workflow by exact name (case-sensitive).
pub fn findByName(workflows: []const Workflow, name: []const u8) ?Workflow {
    for (workflows) |w| {
        if (std.mem.eql(u8, w.name, name)) return w;
    }
    return null;
}

/// Short catalog line for the system prompt / `workflow list` table.
/// Chains (tool pipelines) are flagged with `[chain]` so the agent can
/// discover them as executable pipelines without guessing.
pub fn catalogText(arena: std.mem.Allocator, workflows: []const Workflow) ![]const u8 {
    if (workflows.len == 0) return "";
    var w: std.Io.Writer.Allocating = .init(arena);
    for (workflows) |wf| {
        const hint = if (wf.arg_hint.len > 0) wf.arg_hint else "";
        const chain_tag: []const u8 = if (wf.chain_json != null) " [chain]" else "";
        const text = if (wf.llm_description.len > 0) wf.llm_description else wf.description;
        if (hint.len > 0) {
            try w.writer.print("- {s} {s}: {s}{s}\n", .{ wf.name, hint, text, chain_tag });
        } else {
            try w.writer.print("- {s}: {s}{s}\n", .{ wf.name, text, chain_tag });
        }
    }
    return w.written();
}

// ------------------------------------------------------------------- tests ---

test "catalogText formats with and without arg_hint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const wfs = [_]Workflow{
        .{ .name = "plan", .description = "make a plan", .arg_hint = "[feat]", .body = "x", .rel_path = "plan.md" },
        .{ .name = "review", .description = "review code", .arg_hint = "", .body = "y", .rel_path = "review.md" },
    };
    const txt = try catalogText(arena, &wfs);
    try std.testing.expect(std.mem.find(u8, txt, "- plan [feat]: make a plan") != null);
    try std.testing.expect(std.mem.find(u8, txt, "- review: review code") != null);
}

test "loadAll: missing dir returns empty, not error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const all = try loadAll(arena, io, ".zig-cache/tmp/__no_such_workflows_dir__");
    try std.testing.expectEqual(@as(usize, 0), all.len);
}

test "loadAll: reads and sorts by final name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_name = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(dir_name);
    try tmp.dir.createDirPath(io, "wf");
    try tmp.dir.writeFile(io, .{ .sub_path = "wf/b.md", .data = "second" });
    try tmp.dir.writeFile(io, .{ .sub_path = "wf/a.md", .data = "first" });
    const wf_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/wf", .{dir_name});
    defer std.testing.allocator.free(wf_dir);
    const all = try loadAll(arena, io, wf_dir);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("a", all[0].name);
    try std.testing.expectEqualStrings("b", all[1].name);
}
