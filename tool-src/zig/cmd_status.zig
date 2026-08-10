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
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    _ = parsed;

    var base = StatusInfo{};
    var local = StatusInfo{};
    if (lib.fsRead("config.json") catch null) |content| {
        base = std.json.parseFromSliceLeaky(StatusInfo, std.heap.wasm_allocator, content, .{ .ignore_unknown_fields = true }) catch base;
    }
    if (lib.fsRead("config.local.json") catch null) |content| {
        local = std.json.parseFromSliceLeaky(StatusInfo, std.heap.wasm_allocator, content, .{ .ignore_unknown_fields = true }) catch local;
    }

    const inst = if (local.instance) |i| i else if (base.instance) |i| i else InstanceInfo{};
    const peers = if (local.peers.len > 0) local.peers else base.peers;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.wasm_allocator);
    try buf.appendSlice(std.heap.wasm_allocator, "instance: ");
    try buf.appendSlice(std.heap.wasm_allocator, if (inst.name.len > 0) inst.name else "(unnamed)");
    if (inst.id.len > 0) {
        try buf.appendSlice(std.heap.wasm_allocator, " (");
        try buf.appendSlice(std.heap.wasm_allocator, inst.id);
        try buf.append(std.heap.wasm_allocator, ')');
    }
    try buf.append(std.heap.wasm_allocator, '\n');
    if (peers.len == 0) {
        try buf.appendSlice(std.heap.wasm_allocator, "peers: none configured\n");
    } else {
        try buf.appendSlice(std.heap.wasm_allocator, "peers:\n");
        for (peers) |p| {
            try buf.appendSlice(std.heap.wasm_allocator, "  ");
            try buf.appendSlice(std.heap.wasm_allocator, p.name);
            try buf.appendSlice(std.heap.wasm_allocator, "  ");
            try buf.appendSlice(std.heap.wasm_allocator, p.url);
            try buf.append(std.heap.wasm_allocator, '\n');
        }
    }

    var rbuf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&rbuf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(buf.items);
    try s.endObject();
    try out.writeAll(rbuf[0..w.end]);
}
