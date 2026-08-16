//! spill: read back a tool result the request pruner omitted.
//! Input: {"id":"<8hex>"} | {"id":"...","session":"..."} | {"list":true}
//! Output: {"ok":true,"id":"...","text":"..."} or a listing.

const std = @import("std");
const lib = @import("lib.zig");
const logic = @import("spill_logic.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const req = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    if (lib.optBool(req, "list", false)) return listSpills(out);

    const raw_id = lib.optStr(req, "id") orelse blk: {
        if (lib.optStr(req, "text")) |text| {
            break :blk logic.parseId(text) orelse return lib.fail(out, "no spill id in text");
        }
        return lib.fail(out, "missing id");
    };
    if (!logic.validId(raw_id)) return lib.fail(out, "id must be 8 lowercase hex");

    const session_id = lib.optStr(req, "session") orelse "default";
    if (!logic.validSessionId(session_id)) return lib.fail(out, "invalid session");
    var path_buf: [96]u8 = undefined;
    const path = logic.pathFor(session_id, raw_id, &path_buf) catch return lib.fail(out, "bad session");
    const text = lib.fsRead(path) catch |err| return switch (err) {
        error.NotFound => lib.fail(out, "no spilled result with that id"),
        else => lib.failErr(out, err, "reading the spill"),
    };
    var w = lib.writer(out);
    try w.writeAll("{\"ok\":true,\"id\":");
    try std.json.Stringify.value(raw_id, .{}, &w);
    try w.writeAll(",\"text\":");
    try std.json.Stringify.value(text, .{}, &w);
    try w.writeAll("}");
    lib.commit(out, &w);
}

fn listSpills(out: *lib.Out) !void {
    const raw = lib.fsList("state/spills") catch |err| switch (err) {
        error.NotFound => return lib.okText(out, "no spilled tool results"),
        else => return lib.failErr(out, err, "listing state/spills"),
    };
    return lib.okText(out, raw);
}
