//! alarm: personal reminders a clanker sets for its future self
//! (state/alarms.json). A due alarm surfaces in the system prompt of every
//! later run until it is cancelled, so "check whether CI went green in 20
//! minutes" survives the end of the session that thought of it.
//! Input:  {"action":"set","message":"...","in_minutes":20}
//!         {"action":"set","message":"...","at":1786540000}
//!         {"action":"list"}
//!         {"action":"cancel","id":"a-..."}
//! Output: {"ok":true,...} (list carries alarms with a "due" flag)

const std = @import("std");
const lib = @import("lib.zig");

const path = "state/alarms.json";
const max_alarms = 50;
const max_message = 500;

const Alarm = struct {
    id: []const u8,
    ts: i64, // fire time, epoch seconds
    message: []const u8,
    set_ts: i64,
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
    if (std.mem.eql(u8, action, "cancel")) return doCancel(obj, out);
    return lib.fail(out, "action must be set, list, or cancel");
}

fn doSet(obj: std.json.ObjectMap, out: *lib.Out) !void {
    const message = switch (obj.get("message") orelse return lib.fail(out, "set needs a message")) {
        .string => |s| s,
        else => return lib.fail(out, "message must be a string"),
    };
    if (message.len == 0) return lib.fail(out, "message is empty");
    if (message.len > max_message) return lib.fail(out, "message too long (max 500 bytes)");

    const now: i64 = @intFromFloat(lib.nowSeconds());
    const fire: i64 = blk: {
        if (obj.get("in_minutes")) |v| {
            const mins: i64 = switch (v) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                else => return lib.fail(out, "in_minutes must be a number"),
            };
            if (mins < 0) return lib.fail(out, "in_minutes must not be negative");
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

    var attempt: u32 = 0;
    while (attempt < 3) : (attempt += 1) {
        var loaded = try load();
        if (loaded.alarms.items.len >= max_alarms) return lib.fail(out, "alarm list is full (50); cancel some first");
        const id = try std.fmt.allocPrint(lib.alloc, "a-{d}-{d}", .{ fire, loaded.alarms.items.len });
        try loaded.alarms.append(lib.alloc, .{ .id = id, .ts = fire, .message = message, .set_ts = now });
        if (try store(loaded)) {
            const reply = try std.fmt.allocPrint(lib.alloc, "{{\"ok\":true,\"id\":\"{s}\",\"fires_in_seconds\":{d}}}", .{ id, fire - now });
            return out.writeAll(reply);
        }
    }
    return lib.fail(out, "alarms file kept changing underneath; try again");
}

fn doList(out: *lib.Out) !void {
    const loaded = try load();
    const now: i64 = @intFromFloat(lib.nowSeconds());
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
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    return out.writeAll(jbuf[0..w.end]);
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
