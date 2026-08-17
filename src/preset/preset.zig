//! Agent presets: preset.toml schema + Registry filter.
//! One preset.toml per preset under presets/ (plus user-configured roots in future).
//! Tools filtering reuses the same predicate plan_mode/confirm_writes use for write-capable checks.

const std = @import("std");

pub const Preset = struct {
    description: []const u8 = "",
    system_prompt_append: []const u8 = "",
    tools_allow: []const []const u8 = &.{},
    tools_deny: []const []const u8 = &.{},
    default_provider: []const u8 = "",
    default_model: []const u8 = "",
};

pub fn parseString(alloc: std.mem.Allocator, toml_text: []const u8) !Preset {
    // Minimal TOML-like parse for the shipped keys: description, system_prompt_append, tools_allow/deny arrays.
    // Defer full config.toml parser reuse until PRD needs hot-reload or complex quoting.
    var p = Preset{};
    var lines = std.mem.splitScalar(u8, toml_text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "description")) {
            if (findQuoted(line)) |q| p.description = try alloc.dupe(u8, q);
        } else if (std.mem.startsWith(u8, line, "system_prompt_append")) {
            if (findQuoted(line)) |q| p.system_prompt_append = try alloc.dupe(u8, q);
        } else if (std.mem.startsWith(u8, line, "tools_allow")) {
            p.tools_allow = try parseStringArray(alloc, line);
        } else if (std.mem.startsWith(u8, line, "tools_deny")) {
            p.tools_deny = try parseStringArray(alloc, line);
        } else if (std.mem.startsWith(u8, line, "default_provider")) {
            if (findQuoted(line)) |q| p.default_provider = try alloc.dupe(u8, q);
        } else if (std.mem.startsWith(u8, line, "default_model")) {
            if (findQuoted(line)) |q| p.default_model = try alloc.dupe(u8, q);
        }
    }
    return p;
}

fn findQuoted(line: []const u8) ?[]const u8 {
    const a = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const b = std.mem.indexOfScalarPos(u8, line, a + 1, '"') orelse return null;
    return line[a + 1 .. b];
}

fn parseStringArray(alloc: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    const l = std.mem.indexOfScalar(u8, line, '[') orelse return &.{};
    const r = std.mem.indexOfScalarPos(u8, line, l, ']') orelse return &.{};
    const inner = line[l + 1 .. r];
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t\"'");
        if (t.len > 0) try out.append(alloc, try alloc.dupe(u8, t));
    }
    return out.toOwnedSlice(alloc);
}

fn globMatch(pattern: []const u8, name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '*')) |star| {
        const pre = pattern[0..star];
        const suf = pattern[star + 1 ..];
        if (!std.mem.startsWith(u8, name, pre)) return false;
        if (suf.len == 0) return true;
        return std.mem.endsWith(u8, name, suf);
    }
    return std.mem.eql(u8, pattern, name);
}

pub fn allowed(preset: Preset, tool_name: []const u8) bool {
    for (preset.tools_deny) |pat| if (globMatch(pat, tool_name)) return false;
    if (preset.tools_allow.len == 0) return true;
    for (preset.tools_allow) |pat| if (globMatch(pat, tool_name)) return true;
    return false;
}

test "preset parse + filter" {
    const alloc = std.testing.allocator;
    const txt =
        \\description = "Research-only"
        \\tools_allow = []
        \\tools_deny = ["edit_file", "kanban_*"]
    ;
    const p = try parseString(alloc, txt);
    defer {
        alloc.free(p.description);
        for (p.tools_deny) |s| alloc.free(s);
        alloc.free(p.tools_deny);
        if (p.tools_allow.len > 0) alloc.free(p.tools_allow);
    }
    try std.testing.expect(!allowed(p, "edit_file"));
    try std.testing.expect(!allowed(p, "kanban_add"));
    try std.testing.expect(allowed(p, "read_file"));
    try std.testing.expect(allowed(p, "web_search"));
}

test "preset allowlist" {
    const p = Preset{ .tools_allow = &.{ "read_file", "web_*" }, .tools_deny = &.{} };
    try std.testing.expect(allowed(p, "read_file"));
    try std.testing.expect(allowed(p, "web_search"));
    try std.testing.expect(!allowed(p, "edit_file"));
}
