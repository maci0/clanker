//! config_view: dump the effective config so the agent knows its own settings
//! (providers, models, modules, budgets). The full dump shows config.toml +
//! config.local.toml raw (local last, matching src/config.zig's load order).
//! Optional {"section": "<key>"} filters to one top-level key of the
//! HOST-MERGED config via ck_harness_config -- a wasm guest carries no TOML
//! parser, so structured access goes through the host, which already parsed
//! and merged both files. Known keys include providers, agent, modules,
//! instance, peers, chatrooms, tui, improve, web, serve, memory, notify,
//! models (the reconstructed flat `[models."provider/name"]` table).
//! Input:  {"section": "modules" | "providers" | "agent" | ""}
//! Output: {"ok": true, "text": "<TOML dump or JSON section>"}

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
