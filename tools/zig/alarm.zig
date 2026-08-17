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

const path = "state/alarms.json";
const max_alarms = 50;
const max_message = 500;

const Alarm = struct {
    id: []const u8,
    ts: i64, // next fire time, epoch seconds
    message: []const u8,
    set_ts: i64,
    every: i64 = 0, // recurrence interval in minutes; 0 means one-shot
};

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
                .float => |f| @trunc(f),
                else => return lib.fail(out, "in_minutes must be a number"),
            };
            if (mins < 0) return lib.fail(out, "in_minutes must not be negative");
            if (mins > std.math.maxInt(i64) / 60) return lib.fail(out, "in_minutes is too large");
            break :blk now + mins * 60;
        }
        if (obj.get("at")) |v| {
            const at: i64 = switch (v) {
                .integer => |i| i,
                else => return lib.fail(out, "at must be an integer epoch-seconds timestamp"),
            };
            break :blk at;
        }
        return lib.fail(out, "set needs in_minutes or at");
    };
    const every: i64 = blk: {
        const v = obj.get("every_minutes") orelse break :blk 0;
        const mins: i64 = switch (v) {
            .integer => |i| i,
            .float => |f| @trunc(f),
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
        const id = try std.fmt.allocPrint(lib.alloc, "a-{d}-{d}", .{ fire, loaded.alarms.items.len });
        try loaded.alarms.append(lib.alloc, .{ .id = id, .ts = fire, .message = message, .set_ts = now, .every = every });
        if (try store(loaded)) {
            const reply = try std.fmt.allocPrint(lib.alloc, "{{\"ok\":true,\"id\":\"{s}\",\"fires_in_seconds\":{d}}}", .{ id, fire - now });
            return out.writeAll(reply);
        }
    }
    return lib.fail(out, "alarms file kept changing underneath; try again");
}

fn doList(out: *lib.Out) !void {
    const loaded = try load();
    const now: i64 = @trunc(lib.nowSeconds());
    var jbuf: [65536]u8 = undefined;
    var w: std.Io.Writer = .fixed(&jbuf);
    var s: std.json.Stringify = .{ .writer = &w, .options = .{} };
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
    return out.writeAll(jbuf[0..w.end]);
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
                    const step: i64 = if (a.every > std.math.maxInt(i64) / 60) 60 else a.every * 60;
                    const behind = @max(now - a.ts, 0);
                    a.ts += (@divTrunc(behind, step) + 1) * step;
                    next_ts = a.ts;
                    i += 1;
                } else {
                    _ = loaded.alarms.orderedRemove(i);
                }
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
    const parsed = std.json.parseFromSliceLeaky([]Alarm, lib.alloc, raw, .{ .ignore_unknown_fields = true }) catch return result;
    for (parsed) |a| try result.alarms.append(lib.alloc, a);
    return result;
}

/// True when the write landed; false on a CAS mismatch (caller re-reads and
/// retries). Any other failure is a real error.
fn store(loaded: Loaded) !bool {
    var jbuf: [65536]u8 = undefined;
    var w: std.Io.Writer = .fixed(&jbuf);
    var s: std.json.Stringify = .{ .writer = &w, .options = .{ .whitespace = .indent_2 } };
    try s.write(loaded.alarms.items);
    lib.fsWriteIf(path, loaded.seen_hash, jbuf[0..w.end]) catch |err| switch (err) {
        error.Mismatch => return false,
        else => return err,
    };
    return true;
}
