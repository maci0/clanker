//! cmd_status: show the instance identity and configured peers by reading
//! config.json (and config.local.json, which overrides it).
//! Input:  {"args": "..."}
//! Output: {"ok": true, "text": "<instance + peers>"}

const std = @import("std");
const lib = @import("lib.zig");

const InstanceInfo = struct {
    name: []const u8 = "",
    id: []const u8 = "",
};

const PeerInfo = struct {
    name: []const u8 = "",
    url: []const u8 = "",
};

const StatusInfo = struct {
    instance: ?InstanceInfo = null,
    peers: []const PeerInfo = &.{},
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    _ = parsed;

    var base = StatusInfo{};
    var local = StatusInfo{};
    if (lib.fsRead("config.json") catch null) |content| {
        base = std.json.parseFromSliceLeaky(StatusInfo, lib.alloc, content, .{ .ignore_unknown_fields = true }) catch base;
    }
    if (lib.fsRead("config.local.json") catch null) |content| {
        local = std.json.parseFromSliceLeaky(StatusInfo, lib.alloc, content, .{ .ignore_unknown_fields = true }) catch local;
    }

    const inst = if (local.instance) |i| i else if (base.instance) |i| i else InstanceInfo{};
    const peers = if (local.peers.len > 0) local.peers else base.peers;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(lib.alloc);
    try buf.appendSlice(lib.alloc, "instance: ");
    try buf.appendSlice(lib.alloc, if (inst.name.len > 0) inst.name else "(unnamed)");
    if (inst.id.len > 0) {
        try buf.appendSlice(lib.alloc, " (");
        try buf.appendSlice(lib.alloc, inst.id);
        try buf.append(lib.alloc, ')');
    }
    try buf.append(lib.alloc, '\n');
    if (peers.len == 0) {
        try buf.appendSlice(lib.alloc, "peers: none configured\n");
    } else {
        try buf.appendSlice(lib.alloc, "peers:\n");
        for (peers) |p| {
            try buf.appendSlice(lib.alloc, "  ");
            try buf.appendSlice(lib.alloc, p.name);
            try buf.appendSlice(lib.alloc, "  ");
            try buf.appendSlice(lib.alloc, p.url);
            try buf.append(lib.alloc, '\n');
        }
    }

    return lib.okText(out, buf.items);
}
