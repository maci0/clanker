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

/// Filter a slice of tool names through the preset's allow/deny rules. Pure, host-testable,
/// and registry-agnostic: the CLI/agent can feed it tool-definition names without depending on
/// the WASM registry shape. Empty allow means "everything except deny", matching preset.toml.
pub fn filterNames(alloc: std.mem.Allocator, preset: Preset, names: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (names) |n| if (allowed(preset, n)) try out.append(alloc, n);
    return out.toOwnedSlice(alloc);
}

pub fn loadFromFile(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir, preset_name: []const u8) !Preset {
    if (preset_name.len == 0) return error.PresetNameEmpty;
    if (std.mem.findScalar(u8, preset_name, '/') != null or std.mem.findScalar(u8, preset_name, '\\') != null or std.mem.find(u8, preset_name, "..") != null)
        return error.PresetNameInvalid;
    const path = try std.fmt.allocPrint(alloc, "{s}.toml", .{preset_name});
    defer alloc.free(path);
    const text = std.Io.Dir.readFileAlloc(dir, io, path, alloc, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.PresetNotFound,
        else => return err,
    };
    defer alloc.free(text);
    return parseString(alloc, text);
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

test "preset filterNames respects deny then allow" {
    const alloc = std.testing.allocator;
    const p = Preset{ .tools_allow = &.{}, .tools_deny = &.{ "kanban_*", "edit_file" } };
    const names = &[_][]const u8{ "read_file", "edit_file", "kanban_add", "web_search" };
    const out = try filterNames(alloc, p, names);
    defer alloc.free(out);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("read_file", out[0]);
    try std.testing.expectEqualStrings("web_search", out[1]);
}

test "preset loadFromFile validates name and missing preset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try std.testing.expectError(error.PresetNameInvalid, loadFromFile(io, std.testing.allocator, tmp.dir, "../evil"));
    try std.testing.expectError(error.PresetNotFound, loadFromFile(io, std.testing.allocator, tmp.dir, "nope"));
    try tmp.dir.writeFile(io, .{ .sub_path = "ok.toml", .data = "description = \"hi\"\n" });
    const p = try loadFromFile(io, std.testing.allocator, tmp.dir, "ok");
    defer std.testing.allocator.free(p.description);
    try std.testing.expectEqualStrings("hi", p.description);
}
