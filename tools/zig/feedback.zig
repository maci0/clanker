//! feedback: human thumbs that never enter the model conversation.
//! Input: {"rating":"up"|"down","session":"...","turn":N,"note":"..."}
//!        {"list":true}
//! Output: {"ok":true} or a jsonl dump.

const std = @import("std");
const lib = @import("lib.zig");
const logic = @import("feedback_logic.zig");

const path = "state/feedback.jsonl";

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const req = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    if (lib.optBool(req, "list", false)) {
        const raw = lib.fsRead(path) catch |err| switch (err) {
            error.NotFound => return lib.okText(out, ""),
            else => return lib.failErr(out, err, "reading feedback"),
        };
        return lib.okText(out, raw);
    }

    const rating_s = lib.optStr(req, "rating") orelse return lib.fail(out, "missing rating");
    const rating = logic.parseRating(rating_s) orelse return lib.fail(out, "rating must be up or down");
    const session_id = lib.optStr(req, "session") orelse "default";
    const note = lib.optStr(req, "note") orelse "";
    var turn: ?usize = null;
    if (lib.optNum(req, "turn")) |n| {
        if (n >= 0) turn = @intFromFloat(n);
    }

    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try logic.writeLine(&w, .{
        .ts = @intFromFloat(lib.nowSeconds()),
        .session = session_id,
        .turn = turn,
        .rating = rating,
        .note = note,
    });
    lib.fsAppend(path, w.buffered()) catch |err| return lib.failErr(out, err, "writing feedback");
    try out.writeAll("{\"ok\":true}");
}
