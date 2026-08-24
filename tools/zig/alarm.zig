//! alarm: personal reminders a clanker sets for its future self
//! (state/alarms.json). A due alarm surfaces in the system prompt of every
//! later run until it is cancelled, so "check whether CI went green in 20
//! minutes" survives the end of the session that thought of it.
//! Input:  {"action":"set","message":"...","in_minutes":20}
//!         {"action":"set","message":"...","at":1786540000}
//!         {"action":"set","message":"...","in_minutes":5,"every_minutes":30}
//!         {"action":"list"}
//!         {"action":"done","id":"a-..."}   handled: recurring advances, one-shot is removed
//!         {"action":"cancel","id":"a-..."} delete outright, recurring or not
//! Output: {"ok":true,...} (list carries alarms with "due" and "every_minutes")

const std = @import("std");
const lib = @import("lib.zig");
const alarm_store = @import("alarm_store");

const path = "state/alarms.json";
const max_alarms = 50;
const max_message = 500;

/// The integer part of `f`, or null when it does not fit an i64 (nan and inf
/// never do). Model-supplied floats go through here first: the raw narrowing
/// conversion traps the guest on those, turning a bad argument into a tool
/// failure instead of a validation message.
fn intFromFloatChecked(f: f64) ?i64 {
    if (!std.math.isFinite(f)) return null;
    const t = @trunc(f);
    if (!(t >= -9223372036854775808.0 and t < 9223372036854775808.0)) return null;
    return @trunc(t);
}

const Alarm = alarm_store.Alarm;

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    if (parsed != .object) return lib.fail(out, "input must be an object");
    const obj = parsed.object;
    const action = switch (obj.get("action") orelse return lib.fail(out, "missing action")) {
        .string => |s| s,
        else => return lib.fail(out, "action must be a string"),
    };

    if (std.mem.eql(u8, action, "set")) return doSet(obj, out);
    if (std.mem.eql(u8, action, "list")) return doList(out);
    if (std.mem.eql(u8, action, "done")) return doDone(obj, out);
    if (std.mem.eql(u8, action, "cancel")) return doCancel(obj, out);
    return lib.fail(out, "action must be set, list, done, or cancel");
}

fn doSet(obj: std.json.ObjectMap, out: *lib.Out) !void {
    const message = switch (obj.get("message") orelse return lib.fail(out, "set needs a message")) {
        .string => |s| s,
        else => return lib.fail(out, "message must be a string"),
    };
    if (message.len == 0) return lib.fail(out, "message is empty");
    if (message.len > max_message) return lib.fail(out, "message too long (max 500 bytes)");

    const now: i64 = @trunc(lib.nowSeconds());
    const fire: i64 = blk: {
        if (obj.get("in_minutes")) |v| {
            const mins: i64 = switch (v) {
                .integer => |i| i,
                .float => |f| intFromFloatChecked(f) orelse
                    return lib.fail(out, "in_minutes must be a number"),
                else => return lib.fail(out, "in_minutes must be a number"),
            };
            if (mins < 0) return lib.fail(out, "in_minutes must not be negative");
            if (mins > std.math.maxInt(i64) / 60) return lib.fail(out, "in_minutes is too large");
            // The guard above bounds the product, but `now + mins*60` can
            // still overflow when the product sits within `now` of maxInt,
            // which would store a wrapped (negative) fire time.
            if (now > 0 and mins > @divFloor(std.math.maxInt(i64) - now, 60)) return lib.fail(out, "in_minutes is too large");
            break :blk now + mins * 60;
        }
        if (obj.get("at")) |v| {
            const at: i64 = switch (v) {
                .integer => |i| i,
                else => return lib.fail(out, "at must be an integer epoch-seconds timestamp"),
            };
            // `fire - now` is printed in the reply and `now - ts` is the basis
            // of done's advance; both are i64. Reject an `at` whose difference
            // from now cannot be represented (only reachable beyond ~292
            // billion years from the epoch, where the sign-aware bounds below
            // are the only ones that cannot themselves overflow).
            if (at < 0 and now > 0 and at < std.math.minInt(i64) + now) return lib.fail(out, "at is too far from now");
            if (at > 0 and now <= 0 and at > std.math.maxInt(i64) + now) return lib.fail(out, "at is too far from now");
            break :blk at;
        }
        return lib.fail(out, "set needs in_minutes or at");
    };
    const every: i64 = blk: {
        const v = obj.get("every_minutes") orelse break :blk 0;
        const mins: i64 = switch (v) {
            .integer => |i| i,
            .float => |f| intFromFloatChecked(f) orelse
                return lib.fail(out, "every_minutes must be a number"),
            else => return lib.fail(out, "every_minutes must be a number"),
        };
        if (mins < 1) return lib.fail(out, "every_minutes must be at least 1");
        if (mins > std.math.maxInt(i64) / 60) return lib.fail(out, "every_minutes is too large");
        break :blk mins;
    };

    var attempt: u32 = 0;
    while (attempt < 3) : (attempt += 1) {
        var loaded = try load();
        if (loaded.alarms.items.len >= max_alarms) return lib.fail(out, "alarm list is full (50); cancel some first");
        // An id must be unique across the whole store, not just this
        // creation's list length: cancels recycle lengths, so two alarms
        // at the same fire time could otherwise share an id and a later
        // done/cancel would hit both. Scan the store for the highest
        // numeric suffix and take the next one.
        var next: u64 = 0;
        for (loaded.alarms.items) |a| {
            const field = std.mem.findScalarLast(u8, a.id, '-') orelse continue;
            const num = std.fmt.parseInt(u64, a.id[field + 1 ..], 10) catch continue;
            if (num >= next) next = num + 1;
        }
        const id = try std.fmt.allocPrint(lib.alloc, "a-{d}-{d}", .{ fire, next });
        try loaded.alarms.append(lib.alloc, .{ .id = id, .ts = fire, .message = message, .set_ts = now, .every = every });
        if (try store(loaded)) {
            if (every > 0) {
                const reply = try std.fmt.allocPrint(lib.alloc, "{{\"ok\":true,\"id\":\"{s}\",\"fires_in_seconds\":{d},\"every_minutes\":{d}}}", .{ id, fire - now, every });
                return out.writeAll(reply);
            }
            const reply = try std.fmt.allocPrint(lib.alloc, "{{\"ok\":true,\"id\":\"{s}\",\"fires_in_seconds\":{d}}}", .{ id, fire - now });
            return out.writeAll(reply);
        }
    }
    return lib.fail(out, "alarms file kept changing underneath; try again");
}

fn doList(out: *lib.Out) !void {
    const loaded = try load();
    const now: i64 = @trunc(lib.nowSeconds());
    // The fixed 64 KiB buffer could not hold the legal worst case: 50 alarms
    // at 500 bytes each, with JSON escaping potentially tripling the message
    // bytes, and a fixed writer panics on overflow. An arena-backed writer
    // grows instead of crashing the guest on a full list.
    var aw: std.Io.Writer.Allocating = .init(lib.alloc);
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("now");
    try s.write(now);
    try s.objectField("alarms");
    try s.beginArray();
    for (loaded.alarms.items) |a| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(a.id);
        try s.objectField("ts");
        try s.write(a.ts);
        try s.objectField("message");
        try s.write(a.message);
        try s.objectField("due");
        try s.write(a.ts <= now);
        try s.objectField("every_minutes");
        try s.write(a.every);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    return out.writeAll(aw.written());
}

/// Mark an alarm handled. A one-shot is removed (same as cancel); a
/// recurring alarm advances to its next occurrence strictly after now, so
/// handling a reminder that sat due for three intervals fires once next
/// interval rather than three more times.
fn doDone(obj: std.json.ObjectMap, out: *lib.Out) !void {
    const id = switch (obj.get("id") orelse return lib.fail(out, "done needs an id")) {
        .string => |s| s,
        else => return lib.fail(out, "id must be a string"),
    };
    const now: i64 = @trunc(lib.nowSeconds());
    var attempt: u32 = 0;
    while (attempt < 3) : (attempt += 1) {
        var loaded = try load();
        var found = false;
        var next_ts: i64 = 0;
        var i: usize = 0;
        while (i < loaded.alarms.items.len) {
            const a = &loaded.alarms.items[i];
            if (std.mem.eql(u8, a.id, id)) {
                found = true;
                if (a.every > 0) {
                    // The store file is plain JSON a hand edit can corrupt, so
                    // `every` and `ts` may be any i64. The advance below is
                    // computed with saturating operators: an extreme stored
                    // value must not overflow the guest's arithmetic and trap
                    // it. A wrap used to be able to put the next fire in the
                    // past, making the alarm permanently due.
                    const step: i64 = @max(60, @max(1, @min(a.every, std.math.maxInt(i64) / 60)) * 60);
                    const behind: i64 = if (a.ts >= now) 0 else if (now >= 0 and a.ts < now - std.math.maxInt(i64)) std.math.maxInt(i64) else now - a.ts;
                    const slots = @divTrunc(behind, step) +| 1;
                    const advance = slots *| step;
                    // For valid data the advance already lands strictly after
                    // `now`; the clamp only rescues the saturated case (a
                    // corrupt ts so old that `behind` pinned at maxInt), which
                    // would otherwise stay due forever.
                    a.ts = @max(a.ts +| advance, now +| step);
                    next_ts = a.ts;
                } else {
                    _ = loaded.alarms.orderedRemove(i);
                }
                break;
            } else i += 1;
        }
        if (!found) return lib.fail(out, "no alarm with that id");
        if (try store(loaded)) {
            if (next_ts > 0) {
                const reply = try std.fmt.allocPrint(lib.alloc, "{{\"ok\":true,\"next_in_seconds\":{d}}}", .{next_ts - now});
                return out.writeAll(reply);
            }
            return out.writeAll("{\"ok\":true}");
        }
    }
    return lib.fail(out, "alarms file kept changing underneath; try again");
}

fn doCancel(obj: std.json.ObjectMap, out: *lib.Out) !void {
    const id = switch (obj.get("id") orelse return lib.fail(out, "cancel needs an id")) {
        .string => |s| s,
        else => return lib.fail(out, "id must be a string"),
    };
    var attempt: u32 = 0;
    while (attempt < 3) : (attempt += 1) {
        var loaded = try load();
        var found = false;
        var i: usize = 0;
        while (i < loaded.alarms.items.len) {
            if (std.mem.eql(u8, loaded.alarms.items[i].id, id)) {
                _ = loaded.alarms.orderedRemove(i);
                found = true;
                break;
            } else i += 1;
        }
        if (!found) return lib.fail(out, "no alarm with that id");
        if (try store(loaded)) return out.writeAll("{\"ok\":true}");
    }
    return lib.fail(out, "alarms file kept changing underneath; try again");
}

const Loaded = struct {
    alarms: std.ArrayList(Alarm),
    // SHA-256 of the raw bytes the list was parsed from ("" when the file
    // does not exist yet): store()'s compare-and-swap token.
    seen_hash: []const u8,
};

fn load() !Loaded {
    var result: Loaded = .{ .alarms = .empty, .seen_hash = "" };
    const raw = lib.fsRead(path) catch |err| switch (err) {
        error.NotFound => return result,
        else => return err,
    };
    result.seen_hash = try lib.hash(raw);
    // A truncated or hand-emptied state file must recover as an empty list,
    // not brick every alarm operation with a JSON parse error.
    for (try alarm_store.parseList(lib.alloc, raw)) |a| try result.alarms.append(lib.alloc, a);
    return result;
}

/// True when the write landed; false on a CAS mismatch (caller re-reads and
/// retries). Any other failure is a real error.
fn store(loaded: Loaded) !bool {
    // Same growth reason as doList: the worst-case alarm list (50 x 500-byte
    // messages with JSON escaping) exceeds any fixed stack buffer worth
    // having, and an overflow would abort the write with no retry.
    var aw: std.Io.Writer.Allocating = .init(lib.alloc);
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.write(loaded.alarms.items);
    lib.fsWriteIf(path, loaded.seen_hash, aw.written()) catch |err| switch (err) {
        error.Mismatch => return false,
        else => return err,
    };
    return true;
}
