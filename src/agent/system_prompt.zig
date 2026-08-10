//! System prompt assembly: base instructions + skill files (agent-editable)
//! + tool catalog + persistent learnings.

const std = @import("std");
const types = @import("../llm/types.zig");

pub const PromptParts = struct {
    system_prompt_file: []const u8,
    skills_dir: []const u8,
    learnings_file: []const u8,
    max_skill_bytes: usize = 24 * 1024,
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
        try buf.appendSlice(arena, "## Skills\n\n");
        var it = d.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
            if (std.mem.eql(u8, entry.name, "SYSTEM.md")) continue; // base already included
            const content = d.readFileAlloc(io, entry.name, arena, .limited(parts.max_skill_bytes)) catch continue;
            if (std.mem.trim(u8, content, " \t\r\n").len < 20) continue;
            try buf.appendSlice(arena, "### ");
            try buf.appendSlice(arena, entry.name);
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

    // Tool catalog.
    if (tool_defs.len > 0) {
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
