//! note_write: append a line to the persistent learnings file
//! (state/learnings.md via sandbox fs prefix "state/").
//! Input:  {"note": "..."}
//! Output: {"ok": true} | {"ok": true, "duplicate": true}

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

    // A retried note_write of the same sentence (tool error after the append
    // landed, the model calling it twice) used to grow a second bullet. The
    // file is the set of notes, so an exact existing line is a no-op.
    const existing = lib.fsRead(path) catch |err| switch (err) {
        error.NotFound => "",
        else => return lib.failErr(out, err, "reading the notes"),
    };
    if (noteLinePresent(existing, note)) {
        try out.writeAll("{\"ok\":true,\"duplicate\":true}");
        return;
    }

    // Appending, not rewriting. This used to read the whole file, add a line
    // and write the whole file back, so two notes written in the same turn -
    // tools here run in parallel - both started from the same contents and one
    // was lost. The host's append is atomic between writers.
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(lib.alloc);

    // A file that does not already end in a newline would otherwise get this
    // note glued onto its last line.
    if (existing.len > 0 and existing[existing.len - 1] != '\n') try line.append(lib.alloc, '\n');
    try line.appendSlice(lib.alloc, "- ");
    try line.appendSlice(lib.alloc, note);
    try line.append(lib.alloc, '\n');

    lib.fsAppend(path, line.items) catch |err| {
        return lib.failErr(out, err, "writing the note");
    };

    try out.writeAll("{\"ok\":true}");
}

/// True when `existing` already has a `- {note}` line. Compared as a whole
/// line so a shorter note cannot match inside a longer one.
fn noteLinePresent(existing: []const u8, note: []const u8) bool {
    var it = std.mem.splitScalar(u8, existing, '\n');
    while (it.next()) |line| {
        const t = std.mem.trimEnd(u8, line, "\r");
        if (t.len >= 2 and t[0] == '-' and t[1] == ' ' and std.mem.eql(u8, t[2..], note)) return true;
    }
    return false;
}
