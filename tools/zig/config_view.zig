//! config_view: dump the effective config so the agent knows its own settings
//! (providers, models, modules, budgets). Shows config.json + config.local.json
//! (local wins). Optional {"section": "modules"} filters to one top-level key.
//! Input:  {"section": "modules" | "providers" | ""}
//! Output: {"ok": true, "text": "<JSON>"}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    var section: []const u8 = "";
    if (parsed == .object) {
        if (parsed.object.get("section")) |s| {
            if (s == .string) section = s.string;
        }
    }
    const base = lib.fsRead("config.json") catch return lib.fail(out, "config.json unreadable");
    const local = lib.fsRead("config.local.json") catch "";

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(lib.alloc);

    if (section.len == 0) {
        // Show both files; the agent can compare.
        try text.appendSlice(lib.alloc, "=== config.json ===\n");
        try text.appendSlice(lib.alloc, base);
        if (local.len > 0) {
            try text.appendSlice(lib.alloc, "\n\n=== config.local.json ===\n");
            try text.appendSlice(lib.alloc, local);
        }
    } else {
        // Section filter: prefer local, fall back to base.
        const chosen = if (local.len > 0) local else base;
        const v = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, chosen, .{ .ignore_unknown_fields = true }) catch return lib.fail(out, "parse");
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
