//! chat: clanker chatroom tools. One WASM module backs four descriptors
//! (chat_send / chat_history / chat_rooms / chat_subscribe); each descriptor's
//! `config` object pins the op, e.g. {"op":"send"}. All state, subscription
//! filtering, and peer fan-out happen host-side in ck_chat; this module only
//! reads its op, forwards the tool arguments, and passes the host JSON back.
//!
//!   chat_send:      {"room":"dev","text":"hello"}
//!   chat_history:   {"room":"dev","after":0}
//!   chat_rooms:     {}
//!   chat_subscribe: {"room":"dev","on":true}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

const Op = struct {
    op: ?[]const u8 = null,
};

fn tool_main(input: []const u8, out: *lib.Out) !void {
    // The descriptor config pins the op: {"op":"send"} etc.
    const cfg_json = lib.config();
    const cfg_parsed = std.json.parseFromSliceLeaky(Op, std.heap.wasm_allocator, cfg_json, .{ .ignore_unknown_fields = true }) catch {
        return errJson(out, "chat tool missing \"config\": {\"op\":...}");
    };
    const op = cfg_parsed.op orelse {
        return errJson(out, "chat tool missing op in config");
    };

    // Re-emit the input object verbatim so we can inject the op: the host
    // ignores unknown fields, so this is just {"op":"send", ...args...}.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.wasm_allocator);
    try buf.appendSlice(std.heap.wasm_allocator, "{\"op\":\"");
    try buf.appendSlice(std.heap.wasm_allocator, op);
    try buf.appendSlice(std.heap.wasm_allocator, "\"");
    if (input.len > 2 and input[0] == '{') {
        // Merge the argument fields; input keeps its closing brace.
        try buf.appendSlice(std.heap.wasm_allocator, ",");
        try buf.appendSlice(std.heap.wasm_allocator, input[1..]);
    } else {
        // "{}" (or non-object input): close the object ourselves.
        try buf.appendSlice(std.heap.wasm_allocator, "}");
    }

    const result = lib.chat(buf.items) catch |err| return errJson(out, @errorName(err));
    try out.writeAll(result);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
