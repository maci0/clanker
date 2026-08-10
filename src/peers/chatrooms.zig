//! Clanker chatrooms: named group channels that peer clankers subscribe to
//! and exchange messages over.
//!
//! State (all under `base` + state_dir, default cwd() + "state/"):
//!   - chatrooms.jsonl      append-only log of every message in a subscribed
//!                          room: {"room","from","text","ts","id"}
//!   - chatrooms-sub.json   runtime subscription overrides: {"rooms":[...]}
//!                          (merged with config.json "chatrooms"."rooms")
//!   - chatrooms-cursor.json  last ts injected into the agent inbox, so a run
//!                          only surfaces messages the clanker hasn't seen yet
//!
//! Sending fans the message out to every configured peer's
//! POST /api/chat/message; each peer appends it only when it subscribes to
//! the room, so every clanker's log is exactly the rooms it belongs to.

const std = @import("std");
const config_mod = @import("../config.zig");
const log = @import("../util/log.zig");

pub const log_path = "chatrooms.jsonl";
pub const sub_path = "chatrooms-sub.json";
pub const cursor_path = "chatrooms-cursor.json";
pub const max_text_len = 4096;
/// Messages handed back per history call.
pub const history_limit = 50;
/// Newest messages injected into the agent inbox per run.
pub const inbox_limit = 5;

pub const Message = struct {
    room: []const u8,
    from: []const u8,
    text: []const u8,
    ts: i64,
    id: []const u8,
};

pub const RoomInfo = struct {
    room: []const u8,
    messages: usize,
    last_ts: i64 = 0,
    last_from: []const u8 = "",
    last_text: []const u8 = "",
};

fn subPath(arena: std.mem.Allocator, state_dir: []const u8, name: []const u8) ![]const u8 {
    if (state_dir.len == 0) return name;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ state_dir, name });
}

// ------------------------------------------------------------------ reading --

/// Rooms this instance subscribes to: config defaults minus the runtime
/// "unsubscribed" set, plus the runtime "rooms" overrides from
/// state/<sub_path>. Arena-owned.
pub fn subscribedRooms(base: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, state_dir: []const u8, cfg: *const config_mod.Config) ![][]const u8 {
    var rooms: std.ArrayList([]const u8) = .empty;
    var unsub: std.ArrayList([]const u8) = .empty;
    if (cfg.chatrooms.on) {
        for (cfg.chatrooms.rooms) |r| try rooms.append(arena, r);
    }
    const path = subPath(arena, state_dir, sub_path) catch return rooms.toOwnedSlice(arena);
    const raw = base.readFileAlloc(io, path, arena, .limited(64 * 1024)) catch return rooms.toOwnedSlice(arena);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{ .ignore_unknown_fields = true }) catch return rooms.toOwnedSlice(arena);
    if (parsed == .object) {
        if (parsed.object.get("unsubscribed")) |rv| {
            if (rv == .array) {
                for (rv.array.items) |item| {
                    if (item == .string) try unsub.append(arena, item.string);
                }
            }
        }
        if (parsed.object.get("rooms")) |rv| {
            if (rv == .array) {
                for (rv.array.items) |item| {
                    if (item != .string) continue;
                    const r = item.string;
                    var seen = false;
                    for (rooms.items) |have| {
                        if (std.mem.eql(u8, have, r)) seen = true;
                    }
                    if (!seen) try rooms.append(arena, r);
                }
            }
        }
    }
    // Drop rooms the instance explicitly left.
    var kept: std.ArrayList([]const u8) = .empty;
    for (rooms.items) |r| {
        var gone = false;
        for (unsub.items) |u| {
            if (std.mem.eql(u8, u, r)) gone = true;
        }
        if (!gone) try kept.append(arena, r);
    }
    return kept.toOwnedSlice(arena);
}

/// True when `room` is in the subscription set.
pub fn isSubscribed(base: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, state_dir: []const u8, cfg: *const config_mod.Config, room: []const u8) bool {
    const rooms = subscribedRooms(base, io, arena, state_dir, cfg) catch return false;
    for (rooms) |r| {
        if (std.mem.eql(u8, r, room)) return true;
    }
    return false;
}

fn parseLog(arena: std.mem.Allocator, raw: []const u8, out: *std.ArrayList(Message)) !void {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const msg = std.json.parseFromSliceLeaky(Message, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        try out.append(arena, msg);
    }
}

/// Newest-first messages in `room` with ts > `after`, limited to `limit`.
pub fn readHistory(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, room: []const u8, after: i64, limit: usize) ![]Message {
    _ = gpa;
    const path = subPath(arena, state_dir, log_path) catch return &[_]Message{};
    const raw = base.readFileAlloc(io, path, arena, .limited(1 << 20)) catch return &[_]Message{};
    var all: std.ArrayList(Message) = .empty;
    try parseLog(arena, raw, &all);
    var out: std.ArrayList(Message) = .empty;
    // Iterate newest-first so `limit` keeps the most recent messages.
    var i = all.items.len;
    while (i > 0) {
        i -= 1;
        const m = all.items[i];
        if (!std.mem.eql(u8, m.room, room)) continue;
        if (m.ts <= after) continue;
        try out.append(arena, m);
        if (out.items.len >= limit) break;
    }
    return out.toOwnedSlice(arena);
}

/// Aggregate stats per room, newest-first by last activity.
pub fn listRooms(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8) ![]RoomInfo {
    _ = gpa;
    const path = subPath(arena, state_dir, log_path) catch return &[_]RoomInfo{};
    const raw = base.readFileAlloc(io, path, arena, .limited(1 << 20)) catch return &[_]RoomInfo{};
    var all: std.ArrayList(Message) = .empty;
    try parseLog(arena, raw, &all);
    var by_room: std.StringArrayHashMapUnmanaged(RoomInfo) = .empty;
    for (all.items) |m| {
        const gop = try by_room.getOrPut(arena, m.room);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .room = m.room, .messages = 0 };
        }
        gop.value_ptr.messages += 1;
        if (m.ts >= gop.value_ptr.last_ts) {
            gop.value_ptr.last_ts = m.ts;
            gop.value_ptr.last_from = m.from;
            gop.value_ptr.last_text = if (m.text.len > 120) m.text[0..120] else m.text;
        }
    }
    const out = try arena.alloc(RoomInfo, by_room.count());
    var idx: usize = 0;
    var it = by_room.iterator();
    while (it.next()) |kv| {
        out[idx] = kv.value_ptr.*;
        idx += 1;
    }
    return out;
}

// ------------------------------------------------------------------ writing --

/// Appends a message to the local log, trimming the log to
/// cfg.chatrooms.max_history entries. The read-modify-write is safe because
/// chat tools are marked `sequential` (no parallel workers) and serve handles
/// one connection at a time.
pub fn append(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, cfg: *const config_mod.Config, msg: Message) !void {
    if (state_dir.len > 0) try base.createDirPath(io, state_dir);
    const path = try subPath(arena, state_dir, log_path);
    const maybe_existing = base.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch null;
    defer if (maybe_existing) |e| gpa.free(e);
    const existing = maybe_existing orelse &[_]u8{};

    var line_buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&line_buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.write(msg);
    const line = line_buf[0..w.end];

    var out_list = std.ArrayList(u8).empty;
    defer out_list.deinit(gpa);
    try out_list.appendSlice(gpa, existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') try out_list.append(gpa, '\n');
    try out_list.appendSlice(gpa, line);
    try out_list.append(gpa, '\n');
    try trimLog(gpa, arena, &out_list, cfg.chatrooms.max_history);
    try base.writeFile(io, .{ .sub_path = path, .data = out_list.items });
}

/// Keeps only the last `max` lines of the JSONL log.
fn trimLog(gpa: std.mem.Allocator, arena: std.mem.Allocator, out: *std.ArrayList(u8), max: u32) !void {
    if (max == 0) {
        out.clearRetainingCapacity();
        return;
    }
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, out.items, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0) continue;
        try lines.append(arena, ln);
    }
    if (lines.items.len <= max) return;
    const drop = lines.items.len - max;
    var out_it = std.mem.splitScalar(u8, out.items, '\n');
    var skipped: usize = 0;
    var new_list = std.ArrayList(u8).empty;
    defer new_list.deinit(gpa);
    while (out_it.next()) |ln| {
        if (ln.len == 0) continue;
        if (skipped < drop) {
            skipped += 1;
            continue;
        }
        try new_list.appendSlice(gpa, ln);
        try new_list.append(gpa, '\n');
    }
    out.* = new_list;
}

/// Receives a message from a peer; appends it only when this instance
/// subscribes to the room. Returns whether it was accepted.
pub fn receive(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, cfg: *const config_mod.Config, msg: Message) !bool {
    if (!cfg.chatrooms.on) return false;
    if (!isSubscribed(base, io, arena, state_dir, cfg, msg.room)) return false;
    try append(base, io, gpa, arena, state_dir, cfg, msg);
    return true;
}

// ------------------------------------------------------------------ sending --

/// Appends the message locally and fans it out to every configured peer's
/// POST /api/chat/message. Returns the message (with ts + id filled in).
pub fn sendMessage(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, cfg: *const config_mod.Config, room: []const u8, text: []const u8) !Message {
    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    const msg = Message{
        .room = room,
        .from = cfg.instance.name,
        .text = text,
        .ts = ts,
        .id = try makeId(arena, ts),
    };
    try append(base, io, gpa, arena, state_dir, cfg, msg);
    fanOut(io, gpa, cfg, msg);
    return msg;
}

fn fanOut(io: std.Io, gpa: std.mem.Allocator, cfg: *const config_mod.Config, msg: Message) void {
    if (!cfg.chatrooms.on) return;
    if (cfg.peers.len == 0) return;

    for (cfg.peers) |peer| {
        const url = std.fmt.allocPrint(gpa, "{s}/api/chat/message", .{std.mem.trimEnd(u8, peer.url, "/")}) catch |err| {
            log.log(.error_, "chat to '{s}' failed: {s}", .{ peer.name, @errorName(err) });
            continue;
        };
        defer gpa.free(url);

        var body_buf: [64 * 1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&body_buf);
        var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
        s.beginObject() catch continue;
        s.objectField("room") catch continue;
        s.write(msg.room) catch continue;
        s.objectField("from") catch continue;
        s.write(msg.from) catch continue;
        s.objectField("text") catch continue;
        s.write(msg.text) catch continue;
        s.objectField("ts") catch continue;
        s.print("{d}", .{msg.ts}) catch continue;
        s.objectField("id") catch continue;
        s.write(msg.id) catch continue;
        s.endObject() catch continue;
        const body = body_buf[0..w.end];

        var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
        defer http_client.deinit();
        var response_buf: [64 * 1024]u8 = undefined;
        var rw: std.Io.Writer = .fixed(&response_buf);
        const result = http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .headers = .{ .content_type = .{ .override = "application/json" }, .user_agent = .{ .override = "clanker/0.1.0" } },
            .response_writer = &rw,
        }) catch |err| {
            log.log(.error_, "chat to '{s}' failed: {s}", .{ peer.name, @errorName(err) });
            continue;
        };
        const status = result.status;
        const response = response_buf[0..rw.end];
        log.log(.info, "chat {s}: HTTP {d} ({s})", .{ peer.name, @intFromEnum(status), response });
    }
}

// ------------------------------------------------------------ subscriptions --

/// Adds or removes `room` from the runtime subscription override set.
/// `on=true` joins (also removes the room from the "unsubscribed" set so it
/// can rejoin a config-default room); `on=false` leaves (adds to
/// "unsubscribed" so it overrides a config-default subscription).
pub fn subscribe(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, room: []const u8, on: bool) !void {
    _ = gpa;
    if (state_dir.len > 0) try base.createDirPath(io, state_dir);
    const path = try subPath(arena, state_dir, sub_path);
    var rooms: std.ArrayList([]const u8) = .empty;
    var unsub: std.ArrayList([]const u8) = .empty;
    if (base.readFileAlloc(io, path, arena, .limited(64 * 1024)) catch null) |raw| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{ .ignore_unknown_fields = true }) catch null;
        if (parsed) |p| {
            if (p == .object) {
                if (p.object.get("rooms")) |rv| {
                    if (rv == .array) {
                        for (rv.array.items) |item| {
                            if (item == .string) try rooms.append(arena, item.string);
                        }
                    }
                }
                if (p.object.get("unsubscribed")) |rv| {
                    if (rv == .array) {
                        for (rv.array.items) |item| {
                            if (item == .string) try unsub.append(arena, item.string);
                        }
                    }
                }
            }
        }
    }

    if (on) {
        var already = false;
        for (rooms.items) |r| {
            if (std.mem.eql(u8, r, room)) already = true;
        }
        if (!already) try rooms.append(arena, room);
        var keep: std.ArrayList([]const u8) = .empty;
        for (unsub.items) |r| {
            if (!std.mem.eql(u8, r, room)) try keep.append(arena, r);
        }
        unsub = keep;
    } else {
        var already = false;
        for (unsub.items) |r| {
            if (std.mem.eql(u8, r, room)) already = true;
        }
        if (!already) try unsub.append(arena, room);
    }

    var buf: [16 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("rooms");
    try s.beginArray();
    for (rooms.items) |r| try s.write(r);
    try s.endArray();
    try s.objectField("unsubscribed");
    try s.beginArray();
    for (unsub.items) |r| try s.write(r);
    try s.endArray();
    try s.endObject();
    try base.writeFile(io, .{ .sub_path = path, .data = buf[0..w.end] });
    log.log(.info, "chat: subscribed to '{s}' = {any}", .{ room, on });
}

// ------------------------------------------------------------- agent inbox --

/// Newest-first messages across all rooms with ts > `since`, capped.
pub fn readNew(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, since: i64) ![]Message {
    _ = gpa;
    const path = subPath(arena, state_dir, log_path) catch return &[_]Message{};
    const raw = base.readFileAlloc(io, path, arena, .limited(1 << 20)) catch return &[_]Message{};
    var all: std.ArrayList(Message) = .empty;
    try parseLog(arena, raw, &all);
    var out: std.ArrayList(Message) = .empty;
    var i = all.items.len;
    while (i > 0) {
        i -= 1;
        const m = all.items[i];
        if (m.ts <= since) continue;
        try out.append(arena, m);
        if (out.items.len >= inbox_limit) break;
    }
    return out.toOwnedSlice(arena);
}

pub fn readCursor(base: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, state_dir: []const u8) i64 {
    const path = subPath(arena, state_dir, cursor_path) catch return 0;
    const raw = base.readFileAlloc(io, path, arena, .limited(4096)) catch return 0;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{ .ignore_unknown_fields = true }) catch return 0;
    if (parsed == .object) {
        if (parsed.object.get("ts")) |t| {
            if (t == .integer) return t.integer;
        }
    }
    return 0;
}

pub fn writeCursor(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, state_dir: []const u8, ts: i64) void {
    _ = gpa;
    if (state_dir.len > 0) base.createDirPath(io, state_dir) catch return;
    var path_buf: [512]u8 = undefined;
    const path = if (state_dir.len == 0)
        cursor_path
    else
        std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ state_dir, cursor_path }) catch return;
    var buf: [128]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"ts\":{d}}}\n", .{ts}) catch return;
    base.writeFile(io, .{ .sub_path = path, .data = body }) catch return;
}

// ------------------------------------------------------------------ helpers --

var id_counter: u32 = 0;

fn makeId(arena: std.mem.Allocator, ts: i64) ![]const u8 {
    // Unique per (second, process, call): two instances sending in the same
    // second can never collide because their pids differ, and a per-process
    // counter keeps ids unique within a burst. (No std.crypto.random in
    // Zig 0.16; chat tools are `sequential` and serve is single-threaded, so
    // the counter needs no atomics here.)
    id_counter +%= 1;
    const pid = std.os.linux.getpid();
    return std.fmt.allocPrint(arena, "m{d}-{d}-{x}", .{ ts, pid, id_counter });
}

// ------------------------------------------------------------------- tests --

test "append + readHistory + listRooms round-trip" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cfg = config_mod.Config{};
    cfg.instance.name = "test-clanker";
    cfg.chatrooms.on = true;
    cfg.chatrooms.rooms = &.{"dev"};
    cfg.chatrooms.max_history = 100;

    const m1 = Message{ .room = "dev", .from = "test-clanker", .text = "hello world", .ts = 1000, .id = "m1" };
    try append(tmp.dir, io, std.testing.allocator, arena, "", &cfg, m1);
    const m2 = Message{ .room = "dev", .from = "other", .text = "hi back", .ts = 1001, .id = "m2" };
    try append(tmp.dir, io, std.testing.allocator, arena, "", &cfg, m2);

    const hist = try readHistory(tmp.dir, io, std.testing.allocator, arena, "", "dev", 0, 50);
    try std.testing.expectEqual(@as(usize, 2), hist.len);
    try std.testing.expectEqualStrings("hi back", hist[0].text); // newest first
    try std.testing.expectEqualStrings("hello world", hist[1].text);

    const after = try readHistory(tmp.dir, io, std.testing.allocator, arena, "", "dev", 1000, 50);
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqualStrings("hi back", after[0].text);

    const rooms = try listRooms(tmp.dir, io, std.testing.allocator, arena, "");
    try std.testing.expectEqual(@as(usize, 1), rooms.len);
    try std.testing.expectEqualStrings("dev", rooms[0].room);
    try std.testing.expectEqual(@as(usize, 2), rooms[0].messages);
    try std.testing.expectEqualStrings("other", rooms[0].last_from);

    const fresh = try readNew(tmp.dir, io, std.testing.allocator, arena, "", 1000);
    try std.testing.expectEqual(@as(usize, 1), fresh.len);
}

test "subscribe on/off round-trip" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cfg = config_mod.Config{};
    cfg.chatrooms.on = true;
    cfg.chatrooms.rooms = &.{"dev"};

    try subscribe(tmp.dir, io, std.testing.allocator, arena, "", "ops", true);
    const rooms = try subscribedRooms(tmp.dir, io, arena, "", &cfg);
    try std.testing.expectEqual(@as(usize, 2), rooms.len);
    try std.testing.expect(isSubscribed(tmp.dir, io, arena, "", &cfg, "ops"));

    try subscribe(tmp.dir, io, std.testing.allocator, arena, "", "dev", false);
    const rooms2 = try subscribedRooms(tmp.dir, io, arena, "", &cfg);
    try std.testing.expectEqual(@as(usize, 1), rooms2.len);
    try std.testing.expectEqualStrings("ops", rooms2[0]);
}

test "receive filters by subscription" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cfg = config_mod.Config{};
    cfg.chatrooms.on = true;
    cfg.chatrooms.rooms = &.{"dev"};

    const in_room = Message{ .room = "dev", .from = "peer", .text = "hi", .ts = 1, .id = "a" };
    try std.testing.expect(try receive(tmp.dir, io, std.testing.allocator, arena, "", &cfg, in_room));
    const out_room = Message{ .room = "other", .from = "peer", .text = "hi", .ts = 2, .id = "b" };
    try std.testing.expect(!try receive(tmp.dir, io, std.testing.allocator, arena, "", &cfg, out_room));

    const hist = try readHistory(tmp.dir, io, std.testing.allocator, arena, "", "other", 0, 10);
    try std.testing.expectEqual(@as(usize, 0), hist.len);
}
