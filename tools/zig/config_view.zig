//! config: read and pin the effective config so the agent knows its own
//! settings (providers, models, modules, budgets). The full dump shows
//! config.toml + config.local.toml raw (local last, matching
//! src/config.zig's load order). Optional {"section": "<key>"} filters to
//! one top-level key of the HOST-MERGED config via ck_harness_config -- a
//! wasm guest carries no TOML parser, so structured access goes through the
//! host, which already parsed and merged both files. Known keys include
//! providers, agent, modules, instance, peers, chatrooms, tui, improve,
//! web, serve, memory, notify, mesh, ttsr, advisor, hooks, mcp_servers,
//! models (the reconstructed flat `[models."provider/name"]` table).
//!
//! {"action":"get","key":"agent.reasoning_effort"} reads one dotted key of
//! the merged config. {"action":"set","key":...,"value":"..."} pins it in
//! config.local.toml -- never config.toml -- editing the one line
//! surgically so the operator's comments and formatting survive. The
//! merged config is struct-serialized, so an unknown key is refused rather
//! than silently ignored the way a typo'd TOML key would be, and the
//! merged value's type decides how the raw value must parse. Table
//! sections (providers, models, mcp_servers) are refused: their disk shape
//! is quoted [models."p/m"] / [[providers]] tables this line editor does
//! not speak. The change applies from the next command; the running
//! process keeps the config it loaded.
//! Input:  {"action": "dump" | "get" | "set", "section"?, "key"?, "value"?}
//! Output: {"ok": true, "text": "<TOML dump, JSON section, value, or confirmation>"}

const std = @import("std");
const lib = @import("lib.zig");
const logic = @import("config_logic.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    var section: []const u8 = "";
    var action: []const u8 = "dump";
    if (parsed == .object) {
        if (parsed.object.get("section")) |s| {
            if (s == .string) section = s.string;
        }
        if (parsed.object.get("action")) |a| {
            if (a == .string) action = a.string;
        }
    }

    if (std.mem.eql(u8, action, "get")) return getKey(parsed, out);
    if (std.mem.eql(u8, action, "set")) return setKey(parsed, out);
    if (!std.mem.eql(u8, action, "dump")) return lib.fail(out, "action is dump, get or set");
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(lib.alloc);

    if (section.len == 0) {
        // Whole-file dump needs the raw TOML bytes (no guest TOML parser).
        // Section mode goes through ck_harness_config and must not depend on
        // this read: a missing grant here used to fail every call, including
        // {"section":"modules"}.
        const base = lib.readConfigFile("config") orelse return lib.fail(out, "config.toml unreadable");
        const local = lib.readConfigFile("config.local");
        try text.appendSlice(lib.alloc, "=== ");
        try text.appendSlice(lib.alloc, base.name);
        try text.appendSlice(lib.alloc, " ===\n");
        try text.appendSlice(lib.alloc, base.text);
        if (local) |l| {
            try text.appendSlice(lib.alloc, "\n\n=== ");
            try text.appendSlice(lib.alloc, l.name);
            try text.appendSlice(lib.alloc, " ===\n");
            try text.appendSlice(lib.alloc, l.text);
        }
    } else {
        // Section filter over the host-merged config: ck_harness_config
        // returns it as JSON however it was stored on disk, and already has
        // the local override applied.
        const v = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, lib.harnessConfig(), .{ .ignore_unknown_fields = true }) catch return lib.fail(out, "could not parse the merged harness config");
        if (v == .object) {
            if (v.object.get(section)) |sec| {
                var buf: [65536]u8 = undefined;
                var w: std.Io.Writer = .fixed(&buf);
                var s = std.json.Stringify{ .writer = &w, .options = .{} };
                s.write(sec) catch return lib.fail(out, "section JSON did not fit in the output buffer");
                try text.appendSlice(lib.alloc, buf[0..w.end]);
            } else {
                try text.appendSlice(lib.alloc, "(no section '");
                try text.appendSlice(lib.alloc, section);
                try text.appendSlice(lib.alloc, "')");
            }
        }
    }

    return lib.okText(out, text.items);
}

// ------------------------------------------------------------------ get/set --

fn mergedConfig() !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, lib.harnessConfig(), .{}) catch error.BadMergedConfig;
}

fn getKey(parsed: std.json.Value, out: *lib.Out) !void {
    const key = lib.optStr(parsed, "key") orelse return lib.fail(out, "get needs {\"key\":\"agent.reasoning_effort\"}");
    if (!logic.keyValid(key)) return lib.fail(out, "a key is dotted bare segments, like agent.reasoning_effort");
    const merged = mergedConfig() catch return lib.fail(out, "could not parse the merged harness config");
    const v = logic.lookup(merged, key) orelse
        return lib.fail(out, try std.fmt.allocPrint(lib.alloc, "no key '{s}' in the merged config", .{key}));
    return lib.okText(out, try valueText(v));
}

fn setKey(parsed: std.json.Value, out: *lib.Out) !void {
    const key = lib.optStr(parsed, "key") orelse return lib.fail(out, "set needs {\"key\":\"agent.reasoning_effort\",\"value\":\"high\"}");
    const value = lib.optStr(parsed, "value") orelse return lib.fail(out, "set needs {\"key\":\"agent.reasoning_effort\",\"value\":\"high\"}");
    if (!logic.keyValid(key)) return lib.fail(out, "a key is dotted bare segments, like agent.reasoning_effort");

    // These sections' disk shape is quoted [models."p/m"] / [[providers]]
    // tables; refuse rather than guess where a line-based edit would land.
    const head = key[0 .. std.mem.findScalar(u8, key, '.') orelse key.len];
    inline for (.{ "providers", "models", "mcp_servers" }) |table| {
        if (std.mem.eql(u8, head, table))
            return lib.fail(out, table ++ " is a table of dynamic keys; edit config.local.toml by hand");
    }

    // Policy keys are refused outright: this tool runs sandboxed, so a set
    // here was chosen by the model, and these keys would let one run weaken
    // the sandbox every later run inherits.
    if (logic.forbiddenReason(key)) |k|
        return lib.fail(out, try std.fmt.allocPrint(lib.alloc, "set refuses '{s}': it changes sandbox or safety policy; the operator edits config.local.toml by hand", .{k}));

    const merged = mergedConfig() catch return lib.fail(out, "could not parse the merged harness config");
    // The merged config is struct-serialized, defaults included, so a key
    // it does not carry is not in the loader's schema: a typo, refused
    // here where a stray TOML key would be silently ignored.
    const existing = logic.lookup(merged, key) orelse
        return lib.fail(out, try std.fmt.allocPrint(lib.alloc, "no key '{s}' in the config schema; dump its section to see the valid keys", .{key}));
    const rendered = logic.renderValue(lib.alloc, existing, value) catch |err| switch (err) {
        error.NotScalar => return lib.fail(out, try std.fmt.allocPrint(lib.alloc, "'{s}' is a table, not a single value; set one of its keys instead", .{key})),
        error.TypeMismatch => return lib.fail(out, try std.fmt.allocPrint(lib.alloc, "'{s}' expects {s}, and '{s}' does not parse as one", .{ key, logic.typeName(existing), value })),
        error.OutOfMemory => return error.OutOfMemory,
    };

    const original: []const u8 = if (lib.readConfigFile("config.local")) |l| l.text else "";
    const new_text = try logic.setKey(lib.alloc, original, key, rendered);
    lib.fsWrite("config.local.toml", new_text) catch |err| return lib.failErr(out, err, "writing config.local.toml");

    const msg = try std.fmt.allocPrint(lib.alloc, "set {s} = {s} in config.local.toml (was {s}); applies from the next command", .{ key, rendered, try valueText(existing) });
    return lib.okText(out, msg);
}

/// A string prints bare (the operator asked for the value, not JSON); any
/// other value prints as JSON, which for TOML scalars reads the same.
fn valueText(v: std.json.Value) ![]const u8 {
    if (v == .string) return v.string;
    var buf: [65536]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    s.write(v) catch return error.ValueTooLarge;
    return lib.alloc.dupe(u8, buf[0..w.end]);
}
