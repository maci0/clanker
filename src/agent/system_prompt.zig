//! System prompt assembly: base instructions + skill files (agent-editable)
//! + tool catalog + persistent learnings.

const std = @import("std");
const types = @import("../llm/types.zig");

pub const PromptParts = struct {
    system_prompt_file: []const u8,
    skills_dir: []const u8,
    learnings_file: []const u8,
    max_skill_bytes: usize = 24 * 1024,
    /// This instance's own name and id. Without them the agent reads its own
    /// chatroom messages as someone else's and greets itself by name.
    instance_name: []const u8 = "",
    instance_id: []const u8 = "",
    /// Names of the peer instances it can talk to.
    peers: []const []const u8 = &.{},
    /// One line per tool, from registry.catalogText. When set, it replaces the
    /// full "Available tools" listing.
    catalog: []const u8 = "",
};

/// Builds the system prompt into `arena`-owned memory. Returns the prompt text.
pub fn build(
    arena: std.mem.Allocator,
    io: std.Io,
    parts: PromptParts,
    tool_defs: []const types.ToolDef,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    // Base instructions.
    const base = std.Io.Dir.cwd().readFileAlloc(io, parts.system_prompt_file, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => default_base,
        else => return err,
    };
    try buf.appendSlice(arena, base);
    try buf.appendSlice(arena, "\n\n");

    // Who this instance is. Chatrooms and peer messages carry sender names,
    // and an agent that does not know its own answers itself.
    if (parts.instance_name.len > 0 or parts.instance_id.len > 0) {
        try buf.appendSlice(arena, "## Identity\n\nYou are the clanker instance named \"");
        try buf.appendSlice(arena, if (parts.instance_name.len > 0) parts.instance_name else parts.instance_id);
        try buf.appendSlice(arena, "\"");
        if (parts.instance_id.len > 0 and !std.mem.eql(u8, parts.instance_id, parts.instance_name)) {
            try buf.appendSlice(arena, " (id ");
            try buf.appendSlice(arena, parts.instance_id);
            try buf.appendSlice(arena, ")");
        }
        try buf.appendSlice(arena, ". Chatroom and peer messages from that name are your own: do not answer or greet yourself.");
        if (parts.peers.len > 0) {
            try buf.appendSlice(arena, " The other instances you can reach are: ");
            for (parts.peers, 0..) |peer, i| {
                if (i > 0) try buf.appendSlice(arena, ", ");
                try buf.appendSlice(arena, peer);
            }
            try buf.appendSlice(arena, ".");
        }
        try buf.appendSlice(arena, "\n\n");
    }

    // Project conventions (AGENTS.md).
    const agents_md = std.Io.Dir.cwd().readFileAlloc(io, "AGENTS.md", arena, .limited(64 * 1024)) catch null;
    if (agents_md) |content| {
        if (content.len > 0) {
            try buf.appendSlice(arena, "## Project conventions (AGENTS.md)\n\n");
            try buf.appendSlice(arena, content);
            try buf.appendSlice(arena, "\n\n");
        }
    }

    // Skills (agent-editable markdown files in skills_dir).
    var dir = std.Io.Dir.cwd().openDir(io, parts.skills_dir, .{ .iterate = true }) catch null;
    if (dir) |*d| {
        defer d.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = d.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
            if (std.mem.eql(u8, entry.name, "SYSTEM.md")) continue; // base already included
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
        // Sort so the system prompt is byte-stable across runs; LLM prompt
        // caches key on the prompt prefix and unstable file order defeats it.
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        // Emit the section header lazily, right before the first skill that
        // actually passes the content filter: .md files with <20 bytes of
        // real content are skipped below, and a bare "## Skills" header with
        // no skills under it just wastes prompt tokens.
        var skills_header_done = false;
        for (names.items) |name| {
            const content = d.readFileAlloc(io, name, arena, .limited(parts.max_skill_bytes)) catch continue;
            if (std.mem.trim(u8, content, " \t\r\n").len < 20) continue;
            if (!skills_header_done) {
                try buf.appendSlice(arena, "## Skills\n\n");
                skills_header_done = true;
            }
            try buf.appendSlice(arena, "### ");
            try buf.appendSlice(arena, name);
            try buf.appendSlice(arena, "\n\n");
            try buf.appendSlice(arena, content);
            try buf.appendSlice(arena, "\n\n");
        }
    }

    // Persistent learnings.
    const learnings = std.Io.Dir.cwd().readFileAlloc(io, parts.learnings_file, arena, .limited(1 << 20)) catch null;
    if (learnings) |l| {
        if (l.len > 0) {
            try buf.appendSlice(arena, "## Learnings (persistent memory)\n\n");
            if (l.len > 4096) {
                try buf.appendSlice(arena, l[0..4096]);
                try buf.appendSlice(arena, "...");
            } else {
                try buf.appendSlice(arena, l);
            }
            try buf.appendSlice(arena, "\n\n");
        }
    }

    // Tool catalog. Count non-internal tools first so the section header
    // and usage trailer are not emitted (wasting prompt tokens) when every
    // registered tool is internal and the list would render empty.
    var visible_tools: usize = 0;
    for (tool_defs) |t| {
        if (!t.internal) visible_tools += 1;
    }
    // With a catalog, this section is the catalog: one line per tool for every
    // tool that exists, whether or not its schema is loaded. Without one it is
    // the full description of everything, which duplicates the descriptions
    // already carried by the tool schemas in the same request.
    if (parts.catalog.len > 0) {
        try buf.appendSlice(arena, "## Tool catalog\n\n");
        try buf.appendSlice(arena, parts.catalog);
        try buf.appendSlice(arena,
            \\
            \\Lines marked `*` are loaded and can be called now. To call any other
            \\tool, first call `load_tools` with its exact name from this list; its
            \\schema then stays available for the rest of this run. Do not guess a
            \\tool's arguments — load it and read them.
            \\
            \\Tool results come back as JSON. If a tool reports {"ok":false,...},
            \\adapt and retry or answer directly.
            \\
        );
    } else if (visible_tools > 0) {
        try buf.appendSlice(arena, "## Available tools\n\n");
        for (tool_defs) |t| {
            if (t.internal) continue;
            try buf.appendSlice(arena, "- `");
            try buf.appendSlice(arena, t.name);
            try buf.appendSlice(arena, "`: ");
            try buf.appendSlice(arena, t.description);
            try buf.appendSlice(arena, "\n");
        }
        try buf.appendSlice(arena, "\nCall a tool when you need information or side effects you cannot produce yourself. Tool results come back as JSON. If a tool reports {\"ok\":false,...}, adapt and retry or answer directly.\n");
    }

    return buf.toOwnedSlice(arena);
}

const default_base =
    \\You are clanker, a self-improving agent harness running in a Zig process.
    \\You have access to sandboxed tools implemented as WebAssembly modules.
    \\Be direct, correct, and concise. When you need information outside your
    \\training, use a tool. Never invent tool results.
;
