//! note_write: append a line to the persistent learnings file
//! (state/learnings.md via sandbox fs prefix "state/").
//! Input:  {"note": "..."}
//! Output: {"ok": true} | {"ok": true, "duplicate": true}

const std = @import("std");
const lib = @import("lib.zig");
const notes = @import("notes_logic.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

/// Retries for the same reason `forget_note` uses them: the file has two
/// writers and this one rewrites all of it.
const max_attempts = 3;

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    if (parsed != .object) return lib.fail(out, "input must be a JSON object");
    const obj = parsed.object;
    const note = lib.strFieldRequired(obj, "note") orelse return lib.fail(out, "note must be a non-empty string");

    const path = "state/learnings.md";

    // A retried note_write of the same sentence (tool error after the write
    // landed, the model calling it twice) must not grow a second bullet. The
    // file is the set of notes, so an exact existing line is a no-op.
    //
    // The scan alone was not enough, and this is why the write is a
    // compare-and-swap rather than an append. Append is the one write of the
    // three strengths that cannot express "only if this note is absent": it
    // carries no read to hash, so two identical calls racing -- tools in one
    // turn run in parallel, and a retry of a call whose reply was lost -- both
    // read a file without the note, both decided to append, and both landed.
    // Atomicity was never the missing property; atomic append does not stop
    // two writers who both already decided. `forget_note`, the other writer of
    // this one file, already hashed what it read and wrote compare-and-swap,
    // so this is that same shape.
    var attempt: u32 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        const existing = lib.fsRead(path) catch |err| switch (err) {
            error.NotFound => "",
            else => return lib.failErr(out, err, "reading the notes"),
        };
        const merged = (try notes.appendNote(lib.alloc, existing, note)) orelse {
            try out.writeAll("{\"ok\":true,\"duplicate\":true}");
            return;
        };
        const expected = lib.hash(existing) catch |err| return lib.failErr(out, err, "hashing the notes");
        lib.fsWriteIf(path, expected, merged) catch |err| switch (err) {
            // Someone else appended first. Re-read and re-decide against the
            // new contents: their note may be this one, in which case this
            // call is the duplicate and its reply says so.
            error.Mismatch => continue,
            else => return lib.failErr(out, err, "writing the note"),
        };
        try out.writeAll("{\"ok\":true}");
        return;
    }
    return lib.fail(out, "the notes file kept changing underneath; try again");
}
