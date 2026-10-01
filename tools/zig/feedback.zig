//! feedback: human thumbs that never enter the model conversation.
//! Input: {"rating":"up"|"down","session":"...","turn":N,"note":"..."}
//!        {"list":true}
//! Output: {"ok":true} | {"ok":true,"duplicate":true} | jsonl dump on list.
//!
//! The append is a compare-and-swap on the log's hash: the rating is deduped
//! on (session, turn, rating), so a double-clicked thumb, a replayed fetch or a
//! retried POST stores one row, and two simultaneous posts cannot both append.
//! One CAS wins, the loser re-reads, sees the rating, and answers duplicate.

const std = @import("std");
const lib = @import("lib.zig");
const num = @import("num");
const logic = @import("feedback_logic.zig");

const path = "state/feedback.jsonl";

// The host arena accumulates every host result for the whole call and the
// store reads the whole log (up to logic.max_bytes) per attempt, re-reading on
// a CAS mismatch: room for a couple of full reads plus hashes.
pub const host_arena_cap = 4 * 1024 * 1024;
// A rating is a word and a note; keep the default input budget.
pub const input_scratch_cap = 64 * 1024;

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
        // `n >= 0` is false for nan, but `1e30` passes it and `@trunc` of that
        // to usize is undefined behaviour in the ReleaseSmall build this ships
        // as. The value is persisted, so the check belongs before the write.
        turn = num.intFromFloat(usize, n);
    }

    const entry = logic.Entry{
        .ts = @trunc(lib.nowSeconds()),
        .session = session_id,
        .turn = turn,
        .rating = rating,
        .note = note,
    };

    var attempt: u32 = 0;
    while (attempt < 3) : (attempt += 1) {
        const raw = lib.fsRead(path) catch |err| switch (err) {
            error.NotFound => "",
            else => return lib.failErr(out, err, "reading feedback"),
        };
        const res = try logic.append(lib.alloc, raw, entry, logic.max_bytes);
        if (res.duplicate) return out.writeAll("{\"ok\":true,\"duplicate\":true}");
        const expected = try lib.hash(raw);
        lib.fsWriteIf(path, expected, res.content) catch |err| switch (err) {
            error.Mismatch => continue,
            else => return lib.failErr(out, err, "writing feedback"),
        };
        return out.writeAll("{\"ok\":true}");
    }
    return lib.fail(out, "feedback log kept changing underneath; try again");
}
