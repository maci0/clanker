//! spill: persist and read back a tool result the request pruner omitted.
//! Input: {"write":{"session","id","content"}} (host-internal) |
//!         {"id":"<8hex>"} | {"id":"...","session":"..."} | {"list":true}
//! Output: {"ok":true,"id":"...","text":"..."} | {"ok":true,"bytes":N} |
//!         {"ok":true,"spills":["<session>/<id>.txt", ...]}.
//!
//! `write` is what the agent loop calls when the request-only pruner drops a
//! tool result's middle: the content lands under state/spills/<session>/ so
//! the model can read it back with `id`/`text` later. The same fs grant
//! covers both halves; the host never writes state/spills/ itself.

const std = @import("std");
const lib = @import("lib.zig");
const logic = @import("spill_logic.zig");

/// A spilled tool result is the full pre-prune content, so a busy session's
/// prune turn can legitimately exceed the normal 64 KiB tool-request buffer.
/// Keep the extra linear memory local to spill rather than charging every
/// WASM guest for it (same reason as graph.zig).
pub const input_scratch_cap = 2 * 1024 * 1024;

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const req = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    if (req.object.get("write")) |w| {
        if (w != .object) return lib.fail(out, "write must be an object");
        return writeOne(out, w);
    }
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

fn writeOne(out: *lib.Out, w: std.json.Value) !void {
    const session_id = lib.optStr(w, "session") orelse "default";
    if (!logic.validSessionId(session_id)) return lib.fail(out, "invalid session");
    const id = lib.optStr(w, "id") orelse return lib.fail(out, "missing id");
    if (!logic.validId(id)) return lib.fail(out, "id must be 8 lowercase hex");
    const content = lib.optStr(w, "content") orelse return lib.fail(out, "missing content");
    var path_buf: [96]u8 = undefined;
    const path = logic.pathFor(session_id, id, &path_buf) catch return lib.fail(out, "bad session");
    lib.fsWrite(path, content) catch |err| return lib.failErr(out, err, "writing the spill");
    var wout = lib.writer(out);
    try wout.writeAll("{\"ok\":true,\"bytes\":");
    try std.json.Stringify.value(content.len, .{}, &wout);
    try wout.writeAll("}");
    lib.commit(out, &wout);
}

fn listSpills(out: *lib.Out) !void {
    // Structured JSON so callers can machine-consume the listing. An empty
    // spills dir (state/spills/ missing) is a valid empty list, not an error:
    // {"ok":true,"spills":[]}.
    const raw = lib.fsList("state/spills") catch |err| switch (err) {
        error.NotFound => null,
        else => return lib.failErr(out, err, "listing state/spills"),
    };
    var w = lib.writer(out);
    try w.writeAll("{\"ok\":true,\"spills\":");
    try w.writeAll(raw orelse "[]");
    try w.writeAll("}");
    lib.commit(out, &w);
}
