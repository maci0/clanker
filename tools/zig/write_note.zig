//! note_write: append a line to the persistent learnings file
//! (state/learnings.md via sandbox fs prefix "state/").
//! Input:  {"note": "..."}
//! Output: {"ok": true}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    const obj = parsed.object;
    const note = switch (obj.get("note") orelse return lib.fail(out, "missing note")) {
        .string => |s| s,
        else => return lib.fail(out, "note must be a string"),
    };

    const path = "state/learnings.md";

    // Appending, not rewriting. This used to read the whole file, add a line
    // and write the whole file back, so two notes written in the same turn -
    // tools here run in parallel - both started from the same contents and one
    // was lost. The host's append is atomic between writers.
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(lib.alloc);

    // A file that does not already end in a newline would otherwise get this
    // note glued onto its last line. One byte answers that without reading the
    // file back in.
    if (endsWithoutNewline(path)) try line.append(lib.alloc, '\n');
    try line.appendSlice(lib.alloc, "- ");
    try line.appendSlice(lib.alloc, note);
    try line.append(lib.alloc, '\n');

    lib.fsAppend(path, line.items) catch |err| {
        return lib.failErr(out, err, "writing the note");
    };

    try out.writeAll("{\"ok\":true}");
}

/// True when the file exists, is not empty, and its last byte is not a
/// newline. Reads that one byte rather than the whole file.
fn endsWithoutNewline(path: []const u8) bool {
    const raw = lib.fsStat(path) catch return false;
    const st = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{}) catch return false;
    if (st != .object) return false;
    const size_v = st.object.get("size") orelse return false;
    const size: u64 = switch (size_v) {
        .integer => |i| if (i <= 0) return false else @intCast(i),
        else => return false,
    };
    const last = lib.fsReadRange(path, @intCast(size - 1), 1) catch return false;
    return last.len == 1 and last[0] != '\n';
}
