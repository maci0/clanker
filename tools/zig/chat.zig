//! chat: clanker chatroom tools. One WASM module backs thirteen descriptors
//! (chat_send / chat_history / chat_rooms / chat_subscribe / chat_react /
//! chat_edit / chat_delete / chat_topic / chat_pin and the shared
//! todo-list tools todo_add / todo_claim / todo_close / todo_list); each
//! descriptor's `config` object pins the op, e.g. {"op":"send"}. All state,
//! subscription filtering, and peer fan-out happen host-side in ck_chat; this
//! module only reads its op, forwards the tool arguments, and passes the host
//! JSON back.
//!
//!   chat_send:      {"room":"dev","text":"hello"}
//!   chat_send:      {"to":"other-clanker","text":"hello"} (DM)
//!   chat_history:   {"room":"dev","after":0}
//!   chat_rooms:     {}
//!   chat_subscribe: {"room":"dev","on":true}
//!   todo_add:       {"room":"dev","title":"ship it"}
//!   todo_claim:     {"room":"dev","todo":"<id>"}
//!   todo_close:     {"room":"dev","todo":"<id>"}
//!   todo_list:      {"room":"dev"}
//!
//! The todo_* ops may omit "room": inside a sub-agent run that targets the
//! run's private in-memory list instead of a shared room list (the host
//! routes on the missing field; see src/agent/private_todos.zig).

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
    const cfg_parsed = std.json.parseFromSliceLeaky(Op, lib.alloc, cfg_json, .{ .ignore_unknown_fields = true }) catch {
        return lib.fail(out, "chat tool missing \"config\": {\"op\":...}");
    };
    const op = cfg_parsed.op orelse {
        return lib.fail(out, "chat tool missing op in config");
    };

    // Resolve compound ops: "topic" → set_topic/get_topic, "pin" → pin/get_pins.
    const effective_op = if (std.mem.eql(u8, op, "topic")) blk: {
        // If input contains a "topic" key, it's set_topic; otherwise get_topic.
        const has_topic = std.mem.indexOf(u8, input, "\"topic\"") != null;
        break :blk if (has_topic) "set_topic" else "get_topic";
    } else if (std.mem.eql(u8, op, "pin")) blk: {
        // If input contains a "msg_id" key, it's pin; otherwise get_pins.
        const has_msg_id = std.mem.indexOf(u8, input, "\"msg_id\"") != null;
        break :blk if (has_msg_id) "pin" else "get_pins";
    } else op;

    // Re-emit the input object verbatim so we can inject the op: the host
    // ignores unknown fields, so this is just {"op":"send", ...args...}.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(lib.alloc);
    try buf.appendSlice(lib.alloc, "{\"op\":\"");
    try buf.appendSlice(lib.alloc, effective_op);
    try buf.appendSlice(lib.alloc, "\"");
    if (input.len > 2 and input[0] == '{') {
        // Merge the argument fields; input keeps its closing brace.
        try buf.appendSlice(lib.alloc, ",");
        try buf.appendSlice(lib.alloc, input[1..]);
    } else {
        // "{}" (or non-object input): close the object ourselves.
        try buf.appendSlice(lib.alloc, "}");
    }

    const result = lib.chat(buf.items) catch |err| {
        // "InvalidArg" alone told a caller nothing: it names neither the field
        // that is missing nor the operation that wanted it, and every chat
        // tool shares this one call site.
        return switch (err) {
            error.InvalidArg => if (std.mem.eql(u8, op, "send"))
                lib.fail(out, "chat send needs \"room\" (or \"to\" for a direct message) and \"text\"")
            else if (std.mem.eql(u8, op, "history"))
                lib.fail(out, "chat history needs \"room\", and optionally \"after\" (a timestamp)")
            else if (std.mem.eql(u8, op, "subscribe"))
                lib.fail(out, "chat subscribe needs \"room\", and optionally \"on\" (true to join, false to leave)")
            else if (std.mem.eql(u8, op, "react"))
                lib.fail(out, "chat react needs \"room\", \"msg_id\", and \"emoji\"")
            else if (std.mem.eql(u8, op, "edit"))
                lib.fail(out, "chat edit needs \"room\", \"msg_id\", and \"text\"")
            else if (std.mem.eql(u8, op, "delete"))
                lib.fail(out, "chat delete needs \"room\" and \"msg_id\"")
            else if (std.mem.eql(u8, op, "topic"))
                lib.fail(out, "chat topic needs \"room\" (and \"topic\" to set)")
            else if (std.mem.eql(u8, op, "pin"))
                lib.fail(out, "chat pin needs \"room\" (and \"msg_id\" to pin/unpin)")
            else
                lib.fail(out, "the chat host rejected the arguments for this operation"),
            else => lib.failErr(out, err, "running the chat operation"),
        };
    };
    try out.writeAll(result);
}
