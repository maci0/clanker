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
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    var section: []const u8 = "";
    if (parsed == .object) {
        if (parsed.object.get("section")) |s| {
            if (s == .string) section = s.string;
        }
    }
    const base = lib.fsRead("config.json") catch return errJson(out, "config.json unreadable");
    const local = lib.fsRead("config.local.json") catch "";

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.heap.wasm_allocator);

    if (section.len == 0) {
        // Show both files; the agent can compare.
        try text.appendSlice(std.heap.wasm_allocator, "=== config.json ===\n");
        try text.appendSlice(std.heap.wasm_allocator, base);
        if (local.len > 0) {
            try text.appendSlice(std.heap.wasm_allocator, "\n\n=== config.local.json ===\n");
            try text.appendSlice(std.heap.wasm_allocator, local);
        }
    } else {
        // Section filter: prefer local, fall back to base.
        const chosen = if (local.len > 0) local else base;
        const v = std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, chosen, .{ .ignore_unknown_fields = true }) catch return errJson(out, "parse");
        if (v == .object) {
            if (v.object.get(section)) |sec| {
                var buf: [65536]u8 = undefined;
                var w: std.Io.Writer = .fixed(&buf);
                var s = std.json.Stringify{ .writer = &w, .options = .{} };
                s.write(sec) catch return errJson(out, "write");
                try text.appendSlice(std.heap.wasm_allocator, buf[0..w.end]);
            } else {
                try text.appendSlice(std.heap.wasm_allocator, "(no section '");
                try text.appendSlice(std.heap.wasm_allocator, section);
                try text.appendSlice(std.heap.wasm_allocator, "')");
            }
        }
    }

    var rbuf: [65536]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&rbuf);
    var s2 = std.json.Stringify{ .writer = &w2, .options = .{ .emit_null_optional_fields = false } };
    try s2.beginObject();
    try s2.objectField("ok");
    try s2.write(true);
    try s2.objectField("text");
    try s2.write(text.items);
    try s2.endObject();
    try out.writeAll(rbuf[0..w2.end]);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
