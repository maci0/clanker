//! chat: clanker chatroom tools. One WASM module backs fourteen descriptors
//! (chat_send / chat_dm / chat_history / chat_rooms / chat_subscribe /
//! chat_react / chat_edit / chat_delete / chat_topic / chat_pin and the
//! shared todo-list tools todo_add / todo_claim / todo_close / todo_list);
//! each descriptor's `config` object pins the op, e.g. {"op":"send"}. All
//! state, subscription filtering, and peer fan-out happen host-side in
//! ck_chat; this module only reads its op, forwards the tool arguments, and
//! passes the host JSON back.
//!
//!   chat_send:      {"room":"dev","text":"hello"}
//!   chat_dm:        {"to":"other-clanker","text":"hello"}
//!   chat_history:   {"room":"dev","after":0}
//!   chat_rooms:     {}
//!   chat_subscribe: {"room":"dev","on":true}
//!   todo_add:       {"title":"ship it"}
//!   todo_claim:     {"todo":"<id>"}
//!   todo_close:     {"todo":"<id>"}
//!   todo_list:      {}
//!
//! The todo_* ops target the run's private in-memory list (the host routes
//! on the absent "room" field; see src/agent/private_todos.zig). A todo op
//! that does name a room is refused by the host with a pointer at the board:
//! room todo lists are kanban cards now (src/sandbox/host.zig, ckChat).

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

    // Resolve compound ops: "topic" -> set_topic/get_topic, "pin" -> pin/get_pins.
    // Parse just enough to check for key presence; raw substring search matched
    // values too (a room named "topic" would misroute to set_topic).
    const effective_op = if (std.mem.eql(u8, op, "topic") or std.mem.eql(u8, op, "pin")) blk: {
        const obj = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{}) catch break :blk op;
        if (obj != .object) break :blk op;
        if (std.mem.eql(u8, op, "topic"))
            break :blk if (obj.object.get("topic") != null) @as([]const u8, "set_topic") else "get_topic"
        else
            break :blk if (obj.object.get("msg_id") != null) @as([]const u8, "pin") else "get_pins";
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
                lib.fail(out, "chat send needs \"room\" and \"text\"; a direct message is chat_dm with \"to\" and \"text\"")
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
            else if (std.mem.eql(u8, op, "rooms"))
                lib.fail(out, "chat rooms takes no arguments; the host rejected the fields it was given")
            else if (std.mem.eql(u8, op, "todo_add"))
                lib.fail(out, "todo_add needs \"title\" and writes the run's private list; a shared list is a board card (kanban_add)")
            else if (std.mem.eql(u8, op, "todo_claim"))
                lib.fail(out, "todo_claim needs \"todo\" (an id from todo_list) on the run's private list; shared claims are board cards (kanban_claim)")
            else if (std.mem.eql(u8, op, "todo_close"))
                lib.fail(out, "todo_close needs \"todo\" (an id from todo_list) on the run's private list; shared cards close on the board (kanban_move)")
            else if (std.mem.eql(u8, op, "todo_list"))
                lib.fail(out, "todo_list reads the run's private list and needs no fields; the shared board is kanban_list")
            else
                lib.fail(out, "the chat host rejected the arguments for this operation"),
            // Mirror the board's split between the two denials (they need
            // different fixes): chatrooms switched off is a config the
            // operator can flip; a tool denied chat access is a code/version
            // mismatch that no config change repairs.
            error.SandboxDenied => if (std.mem.startsWith(u8, op, "todo_"))
                lib.fail(out, "this todo names a \"room\", which makes it a chatroom list, and chatrooms are disabled: set modules.chatrooms = true (and chatrooms.on = true) in config.toml or config.local.toml and restart clanker, or omit \"room\" to use the run's private list")
            else
                lib.fail(out, "chatrooms are disabled: set modules.chatrooms = true (and chatrooms.on = true) in config.toml or config.local.toml, then restart clanker"),
            error.NoAccess => lib.fail(out, "this tool is denied chat access (not the chatrooms module); that is a tool-permission / clanker-version mismatch, rebuild clanker and restart it"),
            else => lib.failErr(out, err, "running the chat operation"),
        };
    };
    try out.writeAll(result);
}
