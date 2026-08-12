//! Workflows: reusable prompt templates, like Cursor's desktop workflows.
//!
//! A workflow is a markdown file in `workflows_dir` (default "workflows/").
//! Filename (without .md) is the workflow name. Optional YAML frontmatter between
//! leading `---` lines may set `description`, `name`, and `argument-hint`.
//!
//! Body is the prompt template. `{{args}}`, `{{arguments}}`, `$ARGUMENTS`, and
//! `{{$args}}` are replaced with the caller's argument string at run time.
//! Remaining content is used verbatim.
//!
//! Cursor parity: project workflows in `.cursor/workflows/*.md`, listed in the
//! command palette / slash menu, invoked as `/workflow-name`. Clanker mirrors
//! that with `workflows/*.md` (configurable), `clanker workflow list|show|run`,
//! REPL `/workflows` + `/workflow`, and a `workflows` WASM tool for the agent.

const std = @import("std");

pub const Workflow = struct {
    /// File stem, or `name:` from frontmatter when present.
    name: []const u8,
    /// Human-facing: shown in the webui/CLI, never sent to the model.
    description: []const u8,
    /// Model-facing: what actually lands in the system prompt's per-turn
    /// catalog line (see `catalogText`). Falls back to `description` when a
    /// workflow's frontmatter has no `llm_description`, so an unmigrated
    /// workflow still works, just not as cheaply.
    llm_description: []const u8 = "",
    /// Free-form facets from frontmatter `tags: a, b, c` (comma-separated —
    /// the frontmatter parser is a key:value-per-line subset, not real YAML,
    /// so no bracketed array syntax). For filtering/organization; not sent
    /// to the model.
    tags: []const []const u8 = &.{},
    /// Hint shown in help, e.g. "[feature description]".
    arg_hint: []const u8,
    /// Prompt template body (frontmatter stripped, trimmed of leading/trailing blank lines).
    body: []const u8,
    /// Relative path under workflows_dir, for diagnostics.
    rel_path: []const u8,
    /// Optional chain pipeline embedded in frontmatter: JSON array of steps
    /// (same schema as `chain` tool's `steps`). Lets a workflow double as a
    /// prompt AND a tool pipeline — `clanker workflow run plan "..."` expands
    /// the prompt while `chain: {chain:"plan"}` or inline steps can be invoked
    /// from the workflow body.
    chain_json: ?[]const u8 = null,
};

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
        const parsed = parseWorkflow(arena, stem, fname, raw) catch continue;
        // Skip files with empty body — they would produce an empty prompt.
        if (std.mem.trim(u8, parsed.body, " \t\r\n").len == 0) continue;
        try out.append(arena, parsed);
    }

    // Already sorted by filename; a frontmatter `name:` can reorder — re-sort by final name.
    std.mem.sort(Workflow, out.items, {}, struct {
        fn lt(_: void, a: Workflow, b: Workflow) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return out.toOwnedSlice(arena);
}

/// Cursor parity: also reads `.cursor/workflows` when different from `workflows_dir`.
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

/// Apply argument substitution to a workflow body. Replaces every occurrence of
/// `{{args}}`, `{{arguments}}`, `{{$args}}`, and `$ARGUMENTS` with `args` (empty → "").
/// Caller owns the result (arena).
pub fn instantiate(arena: std.mem.Allocator, body: []const u8, args: []const u8) ![]const u8 {
    // Fast path: no placeholder present.
    if (std.mem.find(u8, body, "{{") == null and std.mem.find(u8, body, "$ARGUMENTS") == null) {
        if (args.len == 0) return body;
        // No placeholder but args given: append them (Cursor does similarly — extra args become trailing context).
        return try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ body, args });
    }
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < body.len) {
        if (std.mem.startsWith(u8, body[i..], "{{args}}")) {
            try out.appendSlice(arena, args);
            i += "{{args}}".len;
        } else if (std.mem.startsWith(u8, body[i..], "{{arguments}}")) {
            try out.appendSlice(arena, args);
            i += "{{arguments}}".len;
        } else if (std.mem.startsWith(u8, body[i..], "{{$args}}")) {
            try out.appendSlice(arena, args);
            i += "{{$args}}".len;
        } else if (std.mem.startsWith(u8, body[i..], "$ARGUMENTS")) {
            try out.appendSlice(arena, args);
            i += "$ARGUMENTS".len;
        } else {
            try out.append(arena, body[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(arena);
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

// ----------------------------------------------------------------- parsing ---

fn parseWorkflow(arena: std.mem.Allocator, stem: []const u8, rel_path: []const u8, raw: []const u8) !Workflow {
    var name = try arena.dupe(u8, stem);
    var description: []const u8 = "";
    var llm_description: []const u8 = "";
    var tags: []const []const u8 = &.{};
    var arg_hint: []const u8 = "";
    var chain_json: ?[]const u8 = null;
    var body: []const u8 = raw;

    // Frontmatter: leading `---\n` ... `\n---\n` (or `\n---` at EOF).
    if (std.mem.startsWith(u8, raw, "---")) {
        const first_nl = std.mem.findScalar(u8, raw, '\n') orelse raw.len;
        // First line must be exactly "---" (allow trailing spaces).
        const first_line = std.mem.trim(u8, raw[0..first_nl], " \t\r");
        if (std.mem.eql(u8, first_line, "---")) {
            if (std.mem.find(u8, raw[first_nl + 1 ..], "\n---")) |rel| {
                const fm_start = first_nl + 1;
                const fm_end = fm_start + rel;
                const fm = raw[fm_start..fm_end];
                const after = raw[fm_end + "\n---".len ..];
                // Body starts after the closing fence line (consume one trailing newline if present).
                body = if (after.len > 0 and after[0] == '\n') after[1..] else if (after.len > 0 and after[0] == '\r' and after.len > 1 and after[1] == '\n') after[2..] else after;
                // Very small YAML subset: key: value per line.
                var lines = std.mem.splitScalar(u8, fm, '\n');
                while (lines.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t\r");
                    if (trimmed.len == 0 or trimmed[0] == '#') continue;
                    const colon = std.mem.findScalar(u8, trimmed, ':') orelse continue;
                    const key = std.mem.trim(u8, trimmed[0..colon], " \t");
                    var val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
                    // Strip surrounding quotes.
                    if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or (val[0] == '\'' and val[val.len - 1] == '\''))) {
                        val = val[1 .. val.len - 1];
                    }
                    if (std.ascii.eqlIgnoreCase(key, "name") and val.len > 0) {
                        name = try arena.dupe(u8, val);
                    } else if (std.ascii.eqlIgnoreCase(key, "description") and val.len > 0) {
                        description = try arena.dupe(u8, val);
                    } else if ((std.ascii.eqlIgnoreCase(key, "llm-description") or std.ascii.eqlIgnoreCase(key, "llm_description")) and val.len > 0) {
                        llm_description = try arena.dupe(u8, val);
                    } else if (std.ascii.eqlIgnoreCase(key, "tags") and val.len > 0) {
                        var out_tags: std.ArrayList([]const u8) = .empty;
                        var parts = std.mem.splitScalar(u8, val, ',');
                        while (parts.next()) |part| {
                            const t = std.mem.trim(u8, part, " \t");
                            if (t.len > 0) out_tags.append(arena, try arena.dupe(u8, t)) catch {};
                        }
                        tags = out_tags.items;
                    } else if ((std.ascii.eqlIgnoreCase(key, "argument-hint") or std.ascii.eqlIgnoreCase(key, "arg_hint") or std.ascii.eqlIgnoreCase(key, "args_hint")) and val.len > 0) {
                        arg_hint = try arena.dupe(u8, val);
                    } else if (std.ascii.eqlIgnoreCase(key, "chain") and val.len > 0) {
                        chain_json = try arena.dupe(u8, val);
                    }
                }
            }
        }
    }

    // Trim outer blank lines but keep internal formatting.
    body = std.mem.trim(u8, body, " \r\n");
    if (description.len == 0) {
        description = try arena.dupe(u8, inferDescription(body));
    }
    if (description.len == 0) description = try arena.dupe(u8, "no description");

    // Validate name: alphanum, dash, underscore.
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) {
            return error.InvalidWorkflowName;
        }
    }
    if (name.len == 0 or name.len > 64) return error.InvalidWorkflowName;

    return .{
        .name = name,
        .description = description,
        .llm_description = llm_description,
        .tags = tags,
        .arg_hint = arg_hint,
        .body = try arena.dupe(u8, body),
        .rel_path = try arena.dupe(u8, rel_path),
        .chain_json = if (chain_json) |c| try arena.dupe(u8, c) else null,
    };
}

fn inferDescription(body: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        var t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        // Strip leading markdown heading markers.
        while (t.len > 0 and t[0] == '#') t = std.mem.trim(u8, t[1..], " \t");
        if (t.len == 0) continue;
        const end = @min(t.len, 120);
        // Cut at sentence end if within budget.
        if (std.mem.findScalar(u8, t[0..end], '.')) |dot| {
            if (dot >= 20) return t[0 .. dot + 1];
        }
        return t[0..end];
    }
    return "";
}

// ------------------------------------------------------------------- tests ---

test "parseWorkflow: frontmatter overrides name and description" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw =
        \\---
        \\name: my-plan
        \\description: Create a plan for the feature
        \\argument-hint: "[feature]"
        \\---
        \\Create a plan for: {{args}}
    ;
    const wf = try parseWorkflow(arena, "unused", "unused.md", raw);
    try std.testing.expectEqualStrings("my-plan", wf.name);
    try std.testing.expectEqualStrings("Create a plan for the feature", wf.description);
    try std.testing.expectEqualStrings("[feature]", wf.arg_hint);
    try std.testing.expectEqualStrings("Create a plan for: {{args}}", wf.body);
}

test "parseWorkflow: no frontmatter infers description from body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw = "# Code review\n\nReview this code for bugs.";
    const wf = try parseWorkflow(arena, "review", "review.md", raw);
    try std.testing.expectEqualStrings("review", wf.name);
    try std.testing.expectEqualStrings("Code review", wf.description);
    try std.testing.expect(std.mem.find(u8, wf.body, "Review this") != null);
}

test "parseWorkflow: quoted description and arg_hint aliases" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw =
        \\---
        \\description: "Fix it"
        \\arg_hint: '<file>'
        \\---
        \\Do it: {{args}}
    ;
    const wf = try parseWorkflow(arena, "fix", "fix.md", raw);
    try std.testing.expectEqualStrings("Fix it", wf.description);
    try std.testing.expectEqualStrings("<file>", wf.arg_hint);
}

test "instantiate: all placeholder spellings replaced" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = "A {{args}} B {{arguments}} C {{$args}} D $ARGUMENTS E";
    const out = try instantiate(arena, body, "X");
    try std.testing.expectEqualStrings("A X B X C X D X E", out);
}

test "instantiate: no placeholder appends args" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try instantiate(arena, "hello", "world");
    try std.testing.expectEqualStrings("hello\n\nworld", out);
    const out2 = try instantiate(arena, "hello", "");
    try std.testing.expectEqualStrings("hello", out2);
}

test "instantiate: placeholder with empty args yields empty insertion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try instantiate(arena, "before {{args}} after", "");
    try std.testing.expectEqualStrings("before  after", out);
}

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
