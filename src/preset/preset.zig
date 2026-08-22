//! Agent presets: preset.toml schema + Registry filter.
//! One preset.toml per preset under presets/ (plus user-configured roots in future).
//! Tools filtering reuses the same predicate plan_mode/confirm_writes use for write-capable checks.
//!
//! Parsing goes through util/toml_bridge.zig, the same TOML parser config.zig
//! uses: a preset.toml is operator-authored TOML and gets one parser, not a
//! second line-based approximation (the approximation silently dropped a
//! tools_deny written across multiple lines).

const std = @import("std");
const glob = @import("../util/glob.zig");
const toml_bridge = @import("../util/toml_bridge.zig");

pub const Preset = struct {
    description: []const u8 = "",
    system_prompt_append: []const u8 = "",
    tools_allow: []const []const u8 = &.{},
    tools_deny: []const []const u8 = &.{},
    default_provider: []const u8 = "",
    default_model: []const u8 = "",
};

pub fn parseString(alloc: std.mem.Allocator, toml_text: []const u8) !Preset {
    // Leaky: every slice is allocated from `alloc`, which must outlive the
    // returned Preset. Production callers pass a run/session arena.
    const value = toml_bridge.parseToJsonValue(alloc, toml_text) catch return error.PresetSyntax;
    if (value != .object) return error.PresetSyntax;
    const obj = value.object;

    var p = Preset{};
    p.description = try fieldString(alloc, obj, "description");
    p.system_prompt_append = try fieldString(alloc, obj, "system_prompt_append");
    p.default_provider = try fieldString(alloc, obj, "default_provider");
    p.default_model = try fieldString(alloc, obj, "default_model");
    p.tools_allow = try fieldStringArray(alloc, obj, "tools_allow");
    p.tools_deny = try fieldStringArray(alloc, obj, "tools_deny");
    return p;
}

/// Absent or non-string reads as "", matching how a preset omits a field.
fn fieldString(alloc: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = obj.get(key) orelse return "";
    if (v != .string) return "";
    return alloc.dupe(u8, v.string);
}

/// Absent reads as empty; present-but-wrong-shape is refused rather than read
/// as empty. An allow/deny list that silently vanished flips the preset's
/// whole access posture (a dropped tools_deny exposes write-capable tools),
/// so the file fails loudly instead.
fn fieldStringArray(alloc: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const v = obj.get(key) orelse return &.{};
    if (v != .array) return error.PresetSchema;
    var out: std.ArrayList([]const u8) = .empty;
    for (v.array.items) |item| {
        if (item != .string) return error.PresetSchema;
        try out.append(alloc, try alloc.dupe(u8, item.string));
    }
    return out.toOwnedSlice(alloc);
}

pub fn allowed(preset: Preset, tool_name: []const u8) bool {
    for (preset.tools_deny) |pat| if (glob.match(pat, tool_name)) return false;
    if (preset.tools_allow.len == 0) return true;
    for (preset.tools_allow) |pat| if (glob.match(pat, tool_name)) return true;
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
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const txt =
        \\description = "Research-only"
        \\tools_allow = []
        \\tools_deny = ["edit_file", "kanban_*"]
    ;
    const p = try parseString(alloc, txt);
    try std.testing.expect(!allowed(p, "edit_file"));
    try std.testing.expect(!allowed(p, "kanban_add"));
    try std.testing.expect(allowed(p, "read_file"));
    try std.testing.expect(allowed(p, "web_search"));
}

test "preset parse reads real TOML shapes the field-level read used to lose" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const p = try parseString(alloc,
        \\# a deny list written across lines, and a trailing comment
        \\tools_deny = [
        \\  "exec",
        \\  "patch_apply", # mutating
        \\]
        \\description = "say \"hi\""
        \\description_extra = "not the description"
        \\unknown_key = "ignored"
        \\
    );
    // The multi-line deny list is the load-bearing one: the old line-based
    // reader answered empty here, which exposed every write-capable tool.
    try std.testing.expectEqual(@as(usize, 2), p.tools_deny.len);
    try std.testing.expectEqualStrings("exec", p.tools_deny[0]);
    try std.testing.expectEqualStrings("patch_apply", p.tools_deny[1]);
    try std.testing.expect(!allowed(p, "exec"));
    try std.testing.expectEqualStrings("say \"hi\"", p.description);
    try std.testing.expectEqualStrings("", p.system_prompt_append);
}

test "preset wrong-shaped fields are refused or defaulted, never silently emptied" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // A scalar where the array belongs: reading it as an empty allow list
    // would flip minimal's posture to "everything allowed".
    try std.testing.expectError(error.PresetSchema, parseString(alloc, "tools_allow = \"read_file\"\n"));
    try std.testing.expectError(error.PresetSchema, parseString(alloc, "tools_deny = [1]\n"));
    // Broken TOML fails loudly rather than parsing as an all-allow preset.
    try std.testing.expectError(error.PresetSyntax, parseString(alloc, "description = \"unterminated\n"));

    // Absent arrays are the legitimate empty case.
    const p = try parseString(alloc, "description = \"x\"\n");
    try std.testing.expectEqual(@as(usize, 0), p.tools_allow.len);
    try std.testing.expectEqual(@as(usize, 0), p.tools_deny.len);
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

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "ok.toml", .data = "description = \"hi\"\n" });
    const p = try loadFromFile(io, arena_state.allocator(), tmp.dir, "ok");
    try std.testing.expectEqualStrings("hi", p.description);
}
