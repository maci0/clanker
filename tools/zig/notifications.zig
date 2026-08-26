//! notifications: the durable inbox behind `POST /api/notify`.
//! Input:  {"store":{"from":"...","kind":"...","topic":"...","payload":<json>,
//!                   "ts":N,"id":"..."}}
//! Output: {"ok":true} | {"ok":true,"duplicate":true} | {"ok":false,"error":"..."}
//!
//! The host route validates the request body and relays it here; the store
//! owns `state/notifications.jsonl` on disk. A notification is not a chat
//! message: nothing fans it out, and nothing replies to it.
//!
//! The append is a compare-and-swap: read the log, build the new content,
//! write it only if the log still hashes to what was read. Two simultaneous
//! deliveries cannot both append: one CAS wins, the loser re-reads, sees the
//! id, and reports the duplicate.

const lib = @import("lib.zig");
const logic = @import("notifications_logic.zig");

// The host arena accumulates every host result for the whole call, and the
// store reads the whole log (up to max_bytes) per attempt, re-reading on a
// CAS mismatch: give it room for a couple of full reads plus hashes.
pub const host_arena_cap = 4 * 1024 * 1024;
// A notify body is a message plus metadata; a peer payload can carry an
// attachment, so the input stays generous rather than the 64 KiB default.
pub const input_scratch_cap = 256 * 1024;

const store_path = "state/notifications.jsonl";

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const req = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    const body = req.object.get("store") orelse return lib.fail(out, "input needs a \"store\" object");
    if (body != .object) return lib.fail(out, "\"store\" must be a JSON object");
    const ts_f: f64 = lib.optNum(body, "ts") orelse 0;
    const received_f: f64 = lib.nowSeconds();
    const record = logic.Record{
        .from = lib.optStr(body, "from") orelse "",
        .kind = lib.optStr(body, "kind") orelse "",
        .topic = lib.optStr(body, "topic") orelse "",
        .payload = body.object.get("payload") orelse .null,
        .ts = @trunc(ts_f),
        .received_at = @trunc(received_f),
        .id = lib.optStr(body, "id"),
    };

    var attempt: u32 = 0;
    while (attempt < 3) : (attempt += 1) {
        const raw = lib.fsRead(store_path) catch |err| switch (err) {
            error.NotFound => "",
            else => return lib.failErr(out, err, "reading the notification log"),
        };
        const res = try logic.append(lib.alloc, raw, record, logic.max_bytes);
        if (res.duplicate) return out.writeAll("{\"ok\":true,\"duplicate\":true}");
        const expected = try lib.hash(raw);
        lib.fsWriteIf(store_path, expected, res.content) catch |err| switch (err) {
            error.Mismatch => continue,
            else => return lib.failErr(out, err, "writing the notification log"),
        };
        return out.writeAll("{\"ok\":true}");
    }
    return lib.fail(out, "notification log kept changing underneath; try again");
}
