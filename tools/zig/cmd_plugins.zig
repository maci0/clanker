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
const config_state_path = "state/plugin_config.json";

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
    config: std.json.Value = .{ .null = {} },
    config_editable: []const []const u8 = &.{},
    /// What the tool accepts, and what it is permitted to reach. The schema is
    /// the closest thing a tool has to a list of actions.
    input_schema: std.json.Value = .{ .null = {} },
    network_allow: []const []const u8 = &.{},
    fs_prefixes: []const []const u8 = &.{},
    exec_allow: []const []const u8 = &.{},
    category: []const u8 = "",
    sequential: bool = false,
    check: bool = false,
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
    config: std.json.Value,
    config_editable: []const []const u8,
    d: Descriptor,
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = lib.alloc;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, input, .{});
    var args: []const u8 = "";
    if (parsed == .object) {
        if (parsed.object.get("args")) |a| {
            if (a == .string) args = std.mem.trim(u8, a.string, " \t");
        }
    }

    const plugins = readPlugins(alloc) catch |err| return lib.failErr(out, err, "reading the plugin list");

    if (args.len == 0) return listJson(out, alloc, plugins);
    // The REPL wants a rendered table; the web UI wants the same facts as data
    // so it can draw a row per plugin with a working toggle. Same reader, two
    // renderings, rather than the UI re-parsing a text table.
    if (std.mem.eql(u8, args, "json")) return listStructured(out, alloc, plugins);

    const sep = std.mem.findScalar(u8, args, ' ') orelse
        return lib.fail(out, "usage: /plugins [on|off <name>]");
    const verb = args[0..sep];
    const name = std.mem.trim(u8, args[sep + 1 ..], " \t");

    const want_enabled = if (std.mem.eql(u8, verb, "on"))
        true
    else if (std.mem.eql(u8, verb, "off"))
        false
    else
        return lib.fail(out, "usage: /plugins [on|off <name>]");

    if (name.len == 0) return lib.fail(out, "usage: /plugins [on|off <name>]");

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
    writeDisabled(plugins) catch |err| return lib.failErr(out, err, "reading the plugin list");
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

    // Machine-local setting overrides, layered the same way the enabled/disabled
    // lists above are. The registry does this merge natively for execution;
    // repeating it here is what keeps the listing honest about what a tool is
    // actually running with, rather than what its descriptor shipped.
    var overrides: std.json.Value = .{ .null = {} };
    if (lib.fsRead(config_state_path)) |cfg_raw| {
        overrides = std.json.parseFromSliceLeaky(std.json.Value, alloc, cfg_raw, .{}) catch .{ .null = {} };
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
            .config = effectiveConfig(alloc, d, overrides),
            .config_editable = d.config_editable,
            .d = d,
        });
    }
    std.mem.sort(Plugin, out.items, {}, lessByName);
    return out.items;
}

/// The descriptor's config with any opted-in key replaced by the machine-local
/// override. Keys the descriptor did not list stay at the shipped value, so a
/// stale or hand-edited state file cannot reach a tool's structural settings.
fn effectiveConfig(alloc: std.mem.Allocator, d: Descriptor, overrides: std.json.Value) std.json.Value {
    if (d.config != .object or d.config_editable.len == 0) return d.config;
    if (overrides != .object) return d.config;
    const mine = overrides.object.get(d.name) orelse return d.config;
    if (mine != .object) return d.config;

    var merged = d.config.object.clone(alloc) catch return d.config;
    for (d.config_editable) |key| {
        const v = mine.object.get(key) orelse continue;
        merged.put(alloc, key, v) catch continue;
    }
    return .{ .object = merged };
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

/// The same facts `listJson` renders as a table, as data:
/// `{"plugins":[{name, description, core, enabled, llm, transform}]}`.
///
/// Serialized into the envelope's `text` field rather than emitted at the top
/// level, because `toolText` in the harness extracts exactly that field and
/// hands it back as the HTTP body. cmd_graph's json mode does the same.
fn listStructured(out: *lib.Out, alloc: std.mem.Allocator, plugins: []const Plugin) !void {
    var doc: std.Io.Writer.Allocating = .init(alloc);
    var s = std.json.Stringify{ .writer = &doc.writer, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("plugins");
    try s.beginArray();
    for (plugins) |p| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(p.name);
        try s.objectField("description");
        try s.write(p.description);
        try s.objectField("core");
        try s.write(p.core);
        try s.objectField("enabled");
        try s.write(p.enabled);
        try s.objectField("llm");
        try s.write(p.llm);
        // Only sent when the descriptor opted something in. A plugin with no
        // tunable settings should not draw an empty settings panel.
        if (p.config_editable.len > 0 and p.config == .object) {
            try s.objectField("config_editable");
            try s.write(p.config_editable);
            try s.objectField("config");
            try s.beginObject();
            for (p.config_editable) |key| {
                const v = p.config.object.get(key) orelse continue;
                try s.objectField(key);
                try s.write(v);
            }
            try s.endObject();
        }
        // The detail panel's material: what the tool accepts, and the sandbox
        // policy it runs under. The policy is the part worth being able to
        // read without opening a manifest, since it is the answer to "what can
        // this thing actually reach".
        if (p.d.input_schema != .null) {
            try s.objectField("input_schema");
            try s.write(p.d.input_schema);
        }
        if (p.d.network_allow.len > 0) {
            try s.objectField("network_allow");
            try s.write(p.d.network_allow);
        }
        if (p.d.fs_prefixes.len > 0) {
            try s.objectField("fs_prefixes");
            try s.write(p.d.fs_prefixes);
        }
        if (p.d.exec_allow.len > 0) {
            try s.objectField("exec_allow");
            try s.write(p.d.exec_allow);
        }
        if (p.d.category.len > 0) {
            try s.objectField("category");
            try s.write(p.d.category);
        }
        if (p.d.sequential) {
            try s.objectField("sequential");
            try s.write(true);
        }
        if (p.d.check) {
            try s.objectField("check");
            try s.write(true);
        }
        if (p.transform) |tr| {
            try s.objectField("transform");
            try s.beginObject();
            try s.objectField("phase");
            try s.write(tr.phase);
            try s.objectField("order");
            try s.write(tr.order);
            try s.endObject();
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    return lib.okText(out, doc.written());
}

fn textJson(out: *lib.Out, alloc: std.mem.Allocator, prefix: []const u8, name: []const u8) !void {
    try writeText(out, try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, name }));
}

fn writeText(out: *lib.Out, text: []const u8) !void {
    return lib.okText(out, text);
}
