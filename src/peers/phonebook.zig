//! `clanker phonebook`: scans every peer in config.json's `peers` list for
//! its `/.well-known/agent.json` card and prints a name/url/skills/status
//! table. Read-only network probing of other clankers, distinct from
//! chatrooms.zig's message fan-out.
//!
//! Dispatches into the sandboxed `peers` WASM tool (same one `notify` uses)
//! rather than making a native HTTP call, so peer traffic is gated by that
//! tool's `network_from_config` allowlist like any model-initiated call.

const std = @import("std");
const config = @import("../config.zig");
const registry = @import("../tools/registry.zig");
const runtime = @import("../sandbox/runtime.zig");
const log = @import("../util/log.zig");

const PhonebookPeer = struct {
    name: []const u8 = "",
    url: []const u8 = "",
    status: []const u8 = "down",
    card_name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    skills: ?[]const []const u8 = null,
    @"error": ?[]const u8 = null,
};

const PhonebookResult = struct {
    ok: bool = false,
    @"error": ?[]const u8 = null,
    peers: []const PhonebookPeer = &.{},
};

pub fn cmdPhonebook(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.toml", "config.local.toml");
    if (!cfg.modules.peers) {
        log.log(.error_, "peers module is disabled...", .{});
        return error.ModuleDisabled;
    }

    var reg = try registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir);
    const mod = runtime.loadNamedTool(gpa, io, arena, init.environ_map, &cfg, &reg, "peers", null) catch |err| {
        if (err == error.UnknownTool) {
            log.log(.error_, "internal tool 'peers' not found in {s}", .{cfg.agent.tools_dir});
        } else {
            log.log(.error_, "'peers' tool load failed: {s} (run `zig build tools`)", .{@errorName(err)});
        }
        return error.ToolWasmMissing;
    };
    defer mod.deinit();

    const raw = try mod.executeTool("{\"action\":\"phonebook\"}");
    defer gpa.free(raw);
    const result = std.json.parseFromSliceLeaky(PhonebookResult, arena, raw, .{ .ignore_unknown_fields = true }) catch PhonebookResult{};
    if (!result.ok) {
        log.log(.error_, "phonebook failed: {s}", .{result.@"error" orelse "unknown error"});
        return error.ToolFailed;
    }

    const out = std.Io.File.stdout();
    try out.writeStreamingAll(io, "name\turl\tskills\tstatus\n");
    for (result.peers) |p| {
        const name = p.card_name orelse p.name;
        var skills_joined: []const u8 = "";
        if (p.skills) |skills| {
            var buf: std.ArrayList(u8) = .empty;
            for (skills, 0..) |s, i| {
                if (i > 0) try buf.append(arena, ',');
                try buf.appendSlice(arena, s);
            }
            if (buf.items.len > 0) skills_joined = try buf.toOwnedSlice(arena);
        }
        const status = if (std.mem.eql(u8, p.status, "up")) p.status else (p.@"error" orelse p.status);
        const line = try std.fmt.allocPrint(arena, "{s}\t{s}\t{s}\t{s}\n", .{ name, p.url, skills_joined, status });
        try out.writeStreamingAll(io, line);
    }
}
