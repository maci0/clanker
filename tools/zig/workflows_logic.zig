//! Shared workflow parsing and expansion logic, used by both sides of the
//! workflows surface: the native harness (`src/agent/workflows.zig` for
//! `clanker workflow`, the REPL, and the system-prompt catalog) and the
//! `workflows` WASM tool (`tools/zig/workflows.zig`). One implementation so
//! the two cannot drift: the model's catalog and the CLI's `workflow list`
//! must agree on which files load, what the frontmatter means, and how
//! `{{args}}` expands.
//!
//! Pure logic: no guest ABI, no std.Io, so `host_tested_helpers` in build.zig
//! runs its tests on the host target and the wasm build compiles it in via a
//! relative import.

const std = @import("std");

pub const Workflow = struct {
    /// File stem, or `name:` from frontmatter when present.
    name: []const u8,
    /// Human-facing: shown in the webui/CLI, never sent to the model.
    description: []const u8,
    /// Model-facing: what actually lands in the system prompt's per-turn
    /// catalog line. Falls back to `description` when a workflow's frontmatter
    /// has no `llm_description`, so an unmigrated workflow still works, just
    /// not as cheaply.
    llm_description: []const u8 = "",
    /// Free-form facets from frontmatter `tags: a, b, c` (comma-separated;
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
    /// prompt AND a tool pipeline, `clanker workflow run plan "..."` expands
    /// the prompt while `chain: {chain:"plan"}` or inline steps can be invoked
    /// from the workflow body.
    chain_json: ?[]const u8 = null,
};

/// Parses one workflow file: strips a leading `---` frontmatter block, reads
/// its `key: value` subset (name, description, llm_description, tags,
/// argument-hint/arg_hint/args_hint, chain), trims the outer blank lines off
/// the body, infers a description from the first body line when none was
/// given, and validates the resulting name. `stem` is the filename stem used
/// as the default name; `rel_path` is kept for diagnostics.
pub fn parseWorkflow(arena: std.mem.Allocator, stem: []const u8, rel_path: []const u8, raw: []const u8) !Workflow {
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

    // Validate name: alphanum, dash, underscore, dot.
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

/// Apply argument substitution to a workflow body. Replaces every occurrence of
/// `{{args}}`, `{{arguments}}`, `{{$args}}`, and `$ARGUMENTS` with `args` (empty → "").
/// Caller owns the result (arena).
pub fn instantiate(arena: std.mem.Allocator, body: []const u8, args: []const u8) ![]const u8 {
    // Fast path: no placeholder present.
    if (std.mem.find(u8, body, "{{") == null and std.mem.find(u8, body, "$ARGUMENTS") == null) {
        if (args.len == 0) return body;
        // No placeholder but args given: append them (Cursor does similarly, extra args become trailing context).
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

/// Extracts the `chain:` frontmatter value from a raw workflow body. Used by
/// the tool's `{"name":...,"chain":""}` request to surface the embedded
/// pipeline; the native side reads `chain_json` straight out of `parseWorkflow`.
pub fn extractChainFrontmatter(alloc: std.mem.Allocator, body: []const u8) !?[]const u8 {
    // Very small frontmatter chain extraction: look for `chain:` line in leading `---` block.
    if (!std.mem.startsWith(u8, body, "---")) return null;
    const first_nl = std.mem.findScalar(u8, body, '\n') orelse return null;
    const first_line = std.mem.trim(u8, body[0..first_nl], " \t\r");
    if (!std.mem.eql(u8, first_line, "---")) return null;
    const rel = std.mem.find(u8, body[first_nl + 1 ..], "\n---") orelse return null;
    const fm = body[first_nl + 1 .. first_nl + 1 + rel];
    var lines = std.mem.splitScalar(u8, fm, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const colon = std.mem.findScalar(u8, trimmed, ':') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "chain")) continue;
        var val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or (val[0] == '\'' and val[val.len - 1] == '\''))) {
            val = val[1 .. val.len - 1];
        }
        if (val.len > 0) return try alloc.dupe(u8, val);
    }
    return null;
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

test "parseWorkflow: llm_description and chain frontmatter are captured" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw =
        \\---
        \\llm_description: cheap catalog line
        \\chain: '[{"tool":"plan","args":"{{args}}"}]'
        \\---
        \\Do the thing: {{args}}
    ;
    const wf = try parseWorkflow(arena, "plan", "plan.md", raw);
    try std.testing.expectEqualStrings("cheap catalog line", wf.llm_description);
    try std.testing.expect(wf.chain_json != null);
    const chain = try extractChainFrontmatter(arena, raw);
    try std.testing.expect(chain != null);
    try std.testing.expect(std.mem.find(u8, chain.?, "plan") != null);
}

test "parseWorkflow: an invalid name is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.InvalidWorkflowName, parseWorkflow(arena, "bad name", "bad name.md", "body"));
    try std.testing.expectError(error.InvalidWorkflowName, parseWorkflow(arena, "", "empty.md", "body"));
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
