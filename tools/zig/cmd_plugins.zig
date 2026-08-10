//! cmd_plugins: list WASM plugins and switch the optional ones on or off.
//! Input:  {"args": "" | "on <name>" | "off <name>"}
//! Output: {"ok": true, "text": "<listing or confirmation>"}
//!
//! Tools marked `"internal": true` in their descriptor are core: they back the
//! REPL slash commands and the HTTP routes, so they are listed but never
//! toggleable. Everything else is a plugin, and its state lives in
//! state/plugins.json ({"disabled": [...]}) which the registry reads at load.

const std = @import("std");
const lib = @import("lib.zig");

const tools_dir = "tools/manifests";
const state_path = "state/plugins.json";

const Transform = struct {
    phase: []const u8 = "",
    order: i64 = 0,
};

const Descriptor = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    internal: bool = false,
    /// Descriptor default; state/plugins.json overrides it either way.
    enabled: bool = true,
    llm: bool = false,
    transform: ?Transform = null,
};

const Plugin = struct {
    name: []const u8,
    description: []const u8,
    /// Core tools back the harness itself and cannot be switched off. A
    /// transform is internal (hidden from the model) but still toggleable.
    core: bool,
    llm: bool,
    transform: ?Transform,
    enabled: bool,
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = std.heap.wasm_allocator;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, input, .{});
    var args: []const u8 = "";
    if (parsed == .object) {
        if (parsed.object.get("args")) |a| {
            if (a == .string) args = std.mem.trim(u8, a.string, " \t");
        }
    }

    const plugins = readPlugins(alloc) catch |err| return errJson(out, @errorName(err));

    if (args.len == 0) return listJson(out, alloc, plugins);

    const sep = std.mem.indexOfScalar(u8, args, ' ') orelse
        return errJson(out, "usage: /plugins [on|off <name>]");
    const verb = args[0..sep];
    const name = std.mem.trim(u8, args[sep + 1 ..], " \t");

    const want_enabled = if (std.mem.eql(u8, verb, "on"))
        true
    else if (std.mem.eql(u8, verb, "off"))
        false
    else
        return errJson(out, "usage: /plugins [on|off <name>]");

    if (name.len == 0) return errJson(out, "usage: /plugins [on|off <name>]");

    var target: ?*Plugin = null;
    for (plugins) |*p| {
        if (std.mem.eql(u8, p.name, name)) target = p;
    }
    const plugin = target orelse
        return textJson(out, alloc, "no such tool: ", name);
    if (plugin.core)
        return textJson(out, alloc, "core tool, cannot be switched off: ", name);
    if (plugin.enabled == want_enabled)
        return textJson(out, alloc, if (want_enabled) "already on: " else "already off: ", name);

    plugin.enabled = want_enabled;
    writeDisabled(plugins) catch |err| return errJson(out, @errorName(err));
    return textJson(out, alloc, if (want_enabled) "enabled: " else "disabled: ", name);
}

/// Every descriptor in tools/manifests, merged with the disabled list in state/.
fn readPlugins(alloc: std.mem.Allocator) ![]Plugin {
    const raw = try lib.fsList(tools_dir);
    const names = try std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{});
    if (names != .array) return error.BadToolsDir;

    var disabled: std.ArrayList([]const u8) = .empty;
    var forced_on: std.ArrayList([]const u8) = .empty;
    if (lib.fsRead(state_path)) |state_raw| {
        const state = std.json.parseFromSliceLeaky(std.json.Value, alloc, state_raw, .{}) catch
            std.json.Value{ .null = {} };
        if (state == .object) {
            try collectNames(alloc, state.object.get("disabled"), &disabled);
            try collectNames(alloc, state.object.get("enabled"), &forced_on);
        }
    } else |_| {}

    var out: std.ArrayList(Plugin) = .empty;
    for (names.array.items) |item| {
        if (item != .string) continue;
        if (!std.mem.endsWith(u8, item.string, ".tool.json")) continue;
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ tools_dir, item.string });
        const body = lib.fsRead(path) catch continue;
        const d = std.json.parseFromSliceLeaky(Descriptor, alloc, body, .{ .ignore_unknown_fields = true }) catch continue;
        if (d.name.len == 0) continue;
        const core = d.internal and d.transform == null;
        var enabled = d.enabled;
        for (disabled.items) |name| {
            if (std.mem.eql(u8, name, d.name)) enabled = false;
        }
        for (forced_on.items) |name| {
            if (std.mem.eql(u8, name, d.name)) enabled = true;
        }
        try out.append(alloc, .{
            .name = d.name,
            .description = d.description,
            .core = core,
            .llm = d.llm,
            .transform = d.transform,
            .enabled = enabled or core,
        });
    }
    std.mem.sort(Plugin, out.items, {}, lessByName);
    return out.items;
}

fn collectNames(alloc: std.mem.Allocator, list: ?std.json.Value, out: *std.ArrayList([]const u8)) !void {
    const v = list orelse return;
    if (v != .array) return;
    for (v.array.items) |item| {
        if (item == .string) try out.append(alloc, item.string);
    }
}

fn lessByName(_: void, a: Plugin, b: Plugin) bool {
    if (a.core != b.core) return !a.core;
    return std.mem.lessThan(u8, a.name, b.name);
}

fn writeDisabled(plugins: []const Plugin) !void {
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    // Both lists are written in full: a descriptor may default either way, so
    // "absent" cannot mean "on".
    try s.beginObject();
    try s.objectField("disabled");
    try s.beginArray();
    for (plugins) |p| {
        if (p.core or p.enabled) continue;
        try s.write(p.name);
    }
    try s.endArray();
    try s.objectField("enabled");
    try s.beginArray();
    for (plugins) |p| {
        if (p.core or !p.enabled) continue;
        try s.write(p.name);
    }
    try s.endArray();
    try s.endObject();
    try lib.fsWrite(state_path, buf[0..w.end]);
}

fn listJson(out: *lib.Out, alloc: std.mem.Allocator, plugins: []const Plugin) !void {
    var text: std.ArrayList(u8) = .empty;
    for (plugins) |p| {
        const mark = if (p.core) "core" else if (p.enabled) " on " else " off";
        var tags: []const u8 = "";
        if (p.transform) |tr| tags = try std.fmt.allocPrint(alloc, "(transform {s}, order {d}{s}) ", .{ tr.phase, tr.order, if (p.llm) ", llm" else "" });
        const line = try std.fmt.allocPrint(alloc, "[{s}] {s: <14} {s}{s}\n", .{ mark, p.name, tags, p.description });
        try text.appendSlice(alloc, line);
    }
    try text.appendSlice(alloc, "\n/plugins off <name> to disable, /plugins on <name> to enable. Core tools back the REPL and HTTP routes and stay on; transforms rewrite other tools' input or output.\n");
    try writeText(out, text.items);
}

fn textJson(out: *lib.Out, alloc: std.mem.Allocator, prefix: []const u8, name: []const u8) !void {
    try writeText(out, try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, name }));
}

fn writeText(out: *lib.Out, text: []const u8) !void {
    var buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(text);
    try s.endObject();
    try out.writeAll(buf[0..w.end]);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
