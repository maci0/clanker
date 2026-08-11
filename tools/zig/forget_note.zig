//! forget_note: remove a learning from persistent memory.
//!
//! write_note only appends, so memory could only ever grow. Notes that were
//! true once and are not any more do not sit quietly: they are in the system
//! prompt of every run, and the agent acts on them — proposing fixes for bugs
//! that are already fixed, re-reading files it was told are broken.
//!
//! Input:  {"match": "sandbox root bug"}          remove notes containing it
//!         {"match": "...", "dry_run": true}      report without removing
//! Output: {"ok": true, "removed": 2, "remaining": 9, "text": "<removed notes>"}

const std = @import("std");
const lib = @import("lib.zig");

const learnings_path = "state/learnings.md";

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = lib.alloc;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, input, .{}) catch
        return lib.fail(out, "input must be a JSON object");
    if (parsed != .object) return lib.fail(out, "input must be a JSON object");

    const match = switch (parsed.object.get("match") orelse return lib.fail(out, "missing required field: match")) {
        .string => |m| m,
        else => return lib.fail(out, "match must be a string"),
    };
    // A blank match would delete the whole memory, which is never what anyone
    // meant to ask for.
    if (match.len < 4) return lib.fail(out, "match must be at least 4 characters, so it cannot wipe the file by accident");

    var dry_run = false;
    if (parsed.object.get("dry_run")) |d| {
        if (d == .bool) dry_run = d.bool;
    }

    const raw = lib.fsRead(learnings_path) catch return lib.fail(out, "no learnings file yet");

    var kept: std.ArrayList(u8) = .empty;
    defer kept.deinit(alloc);
    var removed: std.ArrayList(u8) = .empty;
    defer removed.deinit(alloc);
    var n_removed: usize = 0;
    var n_kept: usize = 0;

    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, match) != null) {
            n_removed += 1;
            try removed.appendSlice(alloc, line);
            try removed.append(alloc, '\n');
            continue;
        }
        n_kept += 1;
        try kept.appendSlice(alloc, line);
        try kept.append(alloc, '\n');
    }

    if (n_removed > 0 and !dry_run) {
        lib.fsWrite(learnings_path, kept.items) catch return lib.fail(out, "could not rewrite the learnings file");
    }

    var buf: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("removed");
    try s.write(n_removed);
    try s.objectField("remaining");
    try s.write(n_kept);
    try s.objectField("dry_run");
    try s.write(dry_run);
    try s.objectField("text");
    try s.write(if (n_removed == 0) "nothing matched" else removed.items[0..@min(removed.items.len, 4000)]);
    try s.endObject();
    try out.writeAll(buf[0..w.end]);
}
