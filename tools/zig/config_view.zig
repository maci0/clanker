//! config_view: dump the effective config so the agent knows its own settings
//! (providers, models, modules, budgets). Shows config.toml/config.json +
//! config.local.toml/config.local.json (local wins, .toml wins over .json,
//! matching src/config.zig's own load order). Optional {"section": "modules"}
//! filters to one top-level key (JSON files only: a TOML file's section can't
//! be picked out without a TOML parser, which this wasm tool doesn't carry).
//! Input:  {"section": "modules" | "providers" | ""}
//! Output: {"ok": true, "text": "<JSON>"}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

const Found = struct { name: []const u8, text: []const u8 };

fn readEither(toml_name: []const u8, json_name: []const u8) ?Found {
    if (lib.fsRead(toml_name) catch null) |t| return .{ .name = toml_name, .text = t };
    if (lib.fsRead(json_name) catch null) |j| return .{ .name = json_name, .text = j };
    return null;
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    var section: []const u8 = "";
    if (parsed == .object) {
        if (parsed.object.get("section")) |s| {
            if (s == .string) section = s.string;
        }
    }
    const base = readEither("config.toml", "config.json") orelse return lib.fail(out, "config.toml/config.json unreadable");
    const local = readEither("config.local.toml", "config.local.json");

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(lib.alloc);

    if (section.len == 0) {
        // Show both files; the agent can compare.
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
        // Section filter: prefer local, fall back to base.
        const chosen = if (local) |l| l else base;
        if (!std.mem.endsWith(u8, chosen.name, ".json")) {
            return lib.fail(out, "section filter needs a JSON config; the active file is TOML");
        }
        const v = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, chosen.text, .{ .ignore_unknown_fields = true }) catch return lib.fail(out, "parse");
        if (v == .object) {
            if (v.object.get(section)) |sec| {
                var buf: [65536]u8 = undefined;
                var w: std.Io.Writer = .fixed(&buf);
                var s = std.json.Stringify{ .writer = &w, .options = .{} };
                s.write(sec) catch return lib.fail(out, "write");
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
