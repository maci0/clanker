//! Clanker chatrooms: named group channels that peer clankers subscribe to
//! and exchange messages over.
//!
//! State (all under `base` + state_dir, default cwd() + "state/"):
//!   - chatrooms.jsonl      append-only log of every message in a subscribed
//!                          room: {"room","from","text","ts","id"}
//!   - chatrooms-sub.json   runtime subscription overrides: {"rooms":[...]}
//!                          (merged with config.toml "chatrooms"."rooms")
//!   - chatrooms-cursor.json  last message injected into the agent inbox, so a
//!                          run only surfaces messages not seen yet
//!
//! Sending fans the message out to every configured peer's
//! POST /api/chat/message; each peer appends it only when it subscribes to
//! the room, so every clanker's log is exactly the rooms it belongs to.

const std = @import("std");
const config_mod = @import("../config.zig");
const log = @import("../util/log.zig");
const atomic_write = @import("../util/atomic_write.zig");
const file_lock = @import("../util/file_lock.zig");
const ensure_dir = @import("../util/ensure_dir.zig");
const utf8 = @import("../util/utf8.zig");
const build_options = @import("build_options");

/// Guards the read-modify-write in `append`. Separate from the log so that
/// trimming, which replaces the log, cannot invalidate a held lock.
const lock_file_name = "chatrooms.lock";
const meta_lock_file_name = "chatrooms-meta.lock";

pub const log_path = "chatrooms.jsonl";
pub const sub_path = "chatrooms-sub.json";
pub const cursor_path = "chatrooms-cursor.json";
pub const max_text_len = 4096;
/// Room list last-message preview. Distinct from max_text_len (the send cap).
const last_text_preview_bytes = 120;
/// Newest messages injected into the agent inbox per run.
pub const inbox_limit = 5;

pub const Reaction = struct {
    emoji: []const u8,
    from: []const u8,
};

pub const Message = struct {
    room: []const u8,
    from: []const u8,
    text: []const u8,
    ts: i64,
    id: []const u8,
    thread_ts: ?[]const u8 = null,
    reactions: ?[]const Reaction = null,
    edited: ?i64 = null,
    deleted: ?bool = null,
};

pub const RoomInfo = struct {
    room: []const u8,
    messages: usize,
    last_ts: i64 = 0,
    last_from: []const u8 = "",
    last_text: []const u8 = "",
    topic: ?[]const u8 = null,
};

/// Durable inbox position. Message identity is the primary cursor because
/// timestamps are supplied by independent peers and are neither unique nor
/// monotonic. `ts` remains as a recovery cursor for legacy state and for when
/// bounded history trimming has removed the referenced message.
pub const Cursor = struct {
    id: []const u8 = "",
    ts: i64 = 0,
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
    var out: std.ArrayList(Message) = .empty;
    if (limit == 0) return out.toOwnedSlice(arena);
    // Walk lines from the end and stop at `limit`. Parsing every record
    // first then discarding all but the last page was O(log) allocations
    // for a 50-message inbox read.
    var end = raw.len;
    while (end > 0) {
        var start = end;
        while (start > 0 and raw[start - 1] != '\n') start -= 1;
        const line = raw[start..end];
        end = if (start > 0) start - 1 else 0;
        if (line.len == 0) continue;
        const m = std.json.parseFromSliceLeaky(Message, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        if (!std.mem.eql(u8, m.room, room)) continue;
        if (m.ts <= after) continue;
        try out.append(arena, m);
        if (out.items.len >= limit) break;
    }
    return out.toOwnedSlice(arena);
}

pub const AscPage = struct { msgs: []Message = &.{}, has_more: bool = false };

/// Oldest-first messages in `room` with ts > `after`, for callers that fold
/// the whole log forward (the board). `readHistory`'s newest-first shape is
/// wrong for them: the fold's cursor jumps to the newest timestamp on page
/// one and everything older is silently never seen.
///
/// When more than `limit` messages qualify, the page extends through every
/// message sharing the boundary timestamp: the caller's only cursor is
/// `ts > after` (timestamps are seconds, so a burst shares one), and cutting
/// a timestamp group mid-way would skip its remainder on the next page.
pub fn readHistoryAsc(base: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, state_dir: []const u8, room: []const u8, after: i64, limit: usize) !AscPage {
    const path = subPath(arena, state_dir, log_path) catch return .{};
    const raw = base.readFileAlloc(io, path, arena, .limited(1 << 20)) catch return .{};
    var out: std.ArrayList(Message) = .empty;
    // Keep only this room's page candidates. The log is shared across every
    // room (board + chat + inbox), so materializing the whole file first
    // allocated every foreign message on each board page.
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const m = std.json.parseFromSliceLeaky(Message, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        if (!std.mem.eql(u8, m.room, room)) continue;
        if (m.ts <= after) continue;
        try out.append(arena, m);
    }
    // Peer fan-in can append out of timestamp order, so the page boundary is
    // only a real ts boundary after sorting by (ts, id).
    std.mem.sort(Message, out.items, {}, struct {
        fn lt(_: void, a: Message, b: Message) bool {
            if (a.ts != b.ts) return a.ts < b.ts;
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.lt);
    if (out.items.len <= limit) return .{ .msgs = out.items, .has_more = false };
    var cut = limit;
    const boundary = out.items[limit - 1].ts;
    while (cut < out.items.len and out.items[cut].ts == boundary) cut += 1;
    return .{ .msgs = out.items[0..cut], .has_more = cut < out.items.len };
}

/// Aggregate stats per room, newest-first by last activity.
pub fn listRooms(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8) ![]RoomInfo {
    _ = gpa;
    const path = subPath(arena, state_dir, log_path) catch return &[_]RoomInfo{};
    const raw = base.readFileAlloc(io, path, arena, .limited(1 << 20)) catch return &[_]RoomInfo{};
    var by_room: std.StringArrayHashMapUnmanaged(RoomInfo) = .empty;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const m = std.json.parseFromSliceLeaky(Message, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        const gop = try by_room.getOrPut(arena, m.room);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .room = m.room, .messages = 0 };
        }
        gop.value_ptr.messages += 1;
        if (m.ts >= gop.value_ptr.last_ts) {
            gop.value_ptr.last_ts = m.ts;
            gop.value_ptr.last_from = m.from;
            gop.value_ptr.last_text = utf8.cap(m.text, last_text_preview_bytes);
        }
    }
    // Enrich with room metadata (topic, pins)
    const meta = loadMeta(base, io, arena, state_dir) catch null;
    const out = try arena.alloc(RoomInfo, by_room.count());
    var idx: usize = 0;
    var it = by_room.iterator();
    while (it.next()) |kv| {
        out[idx] = kv.value_ptr.*;
        if (meta) |m| {
            if (m.map.getPtr(kv.key_ptr.*)) |rm| {
                out[idx].topic = rm.topic;
            }
        }
        idx += 1;
    }
    return out;
}

// ------------------------------------------------------------------ writing --

/// Appends a message to the local log, trimming the log to
/// cfg.chatrooms.max_history entries. `serve` now runs one thread per
/// connection, so two local requests can call this at once, on top of the
/// cross-process case; the read-modify-write below is safe only because of
/// the exclusive `lock_file_name` lock, not because of any single-threading
/// assumption.
pub fn append(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, cfg: *const config_mod.Config, msg: Message) !void {
    if (state_dir.len > 0) try ensure_dir.ensureDir(base, io, state_dir);
    const path = try subPath(arena, state_dir, log_path);

    // This reads the whole log, adds a line, and writes the whole log back.
    // Two instances doing that at once both start from the same contents and
    // the second write discards the first message: chatrooms exist so that
    // separate clanker processes can talk to each other, so the concurrent
    // case is the ordinary one, not the exception.
    //
    // The lock is held on a file of its own rather than on the log, because
    // trimming replaces the log and a lock taken on the replaced file no
    // longer guards anything.
    const lock_path = try subPath(arena, state_dir, lock_file_name);
    // createFileRetry, not createFile: racing creates of a not-yet-existing
    // lock file spuriously fail ENOENT on macOS (see file_lock.zig), and every
    // such failure here is a concurrent append running unserialised, i.e. a
    // silently dropped message.
    const lock = file_lock.createFileRetry(io, base, lock_path, .{ .truncate = false, .lock = .exclusive }) catch |err| blk: {
        // Best effort: a chat message is worth delivering unserialised rather
        // than dropping outright, but say so.
        log.log(.warn, "[chat] could not lock {s} ({s}); a concurrent write may be lost", .{ lock_path, @errorName(err) });
        break :blk null;
    };
    defer if (lock) |f| f.close(io);

    const maybe_existing = base.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (maybe_existing) |e| gpa.free(e);
    const existing = maybe_existing orelse &[_]u8{};

    // A peer redelivering a message (retry after a lost response, at-least-once
    // delivery) must not duplicate it. Checked under the same lock as the
    // write below, so two racing deliveries of the same id cannot both pass
    // the check and both append. Empty ids (messages from a peer too old to
    // send one) are never deduped, matching the pre-existing behaviour for
    // them. The retained window is exactly what trimLog already keeps, so
    // this adds no unbounded state.
    if (msg.id.len > 0) {
        var existing_msgs: std.ArrayList(Message) = .empty;
        parseLog(arena, existing, &existing_msgs) catch |err| {
            log.log(.warn, "[chat] could not parse {s} ({s}); duplicate delivery would not be caught", .{ path, @errorName(err) });
        };
        for (existing_msgs.items) |m| {
            if (std.mem.eql(u8, m.id, msg.id)) {
                log.log(.debug, "[chat] duplicate message id '{s}' ignored", .{msg.id});
                return;
            }
        }
    }

    var line_buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&line_buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.write(msg);
    const line = line_buf[0..w.end];

    const max = cfg.chatrooms.max_history;
    // Under the cap, seek-append the new line. Rewriting the whole log on
    // every send used to copy up to 1 MiB per message even when nothing
    // needed dropping. Trim still rewrites, that is the only path that
    // must replace the file.
    if (max > 0 and jsonlLineCount(existing) + 1 <= max) {
        try appendLogLine(base, io, path, existing, line);
        return;
    }

    var out_list = std.ArrayList(u8).empty;
    defer out_list.deinit(gpa);
    try out_list.appendSlice(gpa, existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') try out_list.append(gpa, '\n');
    try out_list.appendSlice(gpa, line);
    try out_list.append(gpa, '\n');
    try trimLog(gpa, arena, &out_list, max);
    try atomic_write.writeFile(io, base, path, out_list.items);
}

fn jsonlLineCount(raw: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |ln| {
        if (ln.len > 0) n += 1;
    }
    return n;
}

fn appendLogLine(base: std.Io.Dir, io: std.Io, path: []const u8, existing: []const u8, line: []const u8) !void {
    const file = try base.createFile(io, path, .{ .truncate = false });
    defer file.close(io);
    const size = (try file.stat(io)).size;
    var wbuf: [512]u8 = undefined;
    var fw = file.writer(io, &wbuf);
    try fw.seekToUnbuffered(size);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') {
        try fw.interface.writeAll("\n");
    }
    try fw.interface.writeAll(line);
    try fw.interface.writeAll("\n");
    try fw.flush();
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
    // Swap instead of `out.* = new_list`: a plain struct copy would leave
    // `out` aliasing new_list's buffer, and the deferred new_list.deinit(gpa)
    // below would free it, leaving out.items dangling. The next write of
    // out.items would hit freed memory (writev → EFAULT → process abort).
    std.mem.swap(std.ArrayList(u8), out, &new_list);
}

/// Receives a message from a peer; appends it only when this instance
/// subscribes to the room. Returns whether it was accepted.
pub fn receive(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, cfg: *const config_mod.Config, msg: Message) !bool {
    if (!cfg.chatrooms.on) return false;
    if (!isSubscribed(base, io, arena, state_dir, cfg, msg.room)) return false;
    try append(base, io, gpa, arena, state_dir, cfg, msg);
    return true;
}

// --------------------------------------------------------------- mutations --
// These ops modify an existing message in-place by rewriting the single
// shared JSONL log (all rooms share one file).

/// Serialise a Message into the JSONL buffer.
fn serialiseMessage(m: Message, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    var line_buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&line_buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    s.beginObject() catch return error.TooLarge;
    inline for (@typeInfo(Message).@"struct".fields) |f| {
        s.objectField(f.name) catch return error.TooLarge;
        s.write(@field(m, f.name)) catch return error.TooLarge;
    }
    s.endObject() catch return error.TooLarge;
    try out.appendSlice(gpa, line_buf[0..w.end]);
    try out.append(gpa, '\n');
}

/// Rewrite the entire log after mutations have been applied in-place.
fn rewriteLog(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, messages: []const Message) !void {
    const path = try subPath(arena, state_dir, log_path);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(gpa);
    for (messages) |m| try serialiseMessage(m, &out, gpa);
    try atomic_write.writeFile(io, base, path, out.items);
}

/// Toggle a reaction on a message. Returns true if the reaction was added,
/// false if it was removed (toggle behaviour, like Slack).
pub fn toggleReaction(
    base: std.Io.Dir,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    state_dir: []const u8,
    cfg: *const config_mod.Config,
    msg_id: []const u8,
    emoji: []const u8,
    from: []const u8,
) !bool {
    _ = cfg;
    const lock_path = try subPath(arena, state_dir, lock_file_name);
    const lock = file_lock.createFileRetry(io, base, lock_path, .{ .truncate = false, .lock = .exclusive }) catch null;
    defer if (lock) |f| f.close(io);
    const path = try subPath(arena, state_dir, log_path);
    const raw = base.readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch return error.NotFound;
    var messages: std.ArrayList(Message) = .empty;
    try parseLog(arena, raw, &messages);

    var found = false;
    var was_added = false;
    for (messages.items) |*m| {
        if (!std.mem.eql(u8, m.id, msg_id)) continue;
        found = true;
        var new_reactions: std.ArrayList(Reaction) = .empty;
        var removed = false;
        if (m.reactions) |existing| {
            for (existing) |r| {
                if (std.mem.eql(u8, r.emoji, emoji) and std.mem.eql(u8, r.from, from)) {
                    removed = true;
                    continue;
                }
                try new_reactions.append(arena, r);
            }
        }
        if (!removed) {
            try new_reactions.append(arena, .{ .emoji = emoji, .from = from });
            was_added = true;
        }
        m.reactions = if (new_reactions.items.len > 0) new_reactions.items else null;
        break;
    }
    if (!found) return error.NotFound;
    try rewriteLog(base, io, gpa, arena, state_dir, messages.items);
    return was_added;
}

/// Edit a message's text. Only the original sender can edit.
pub fn editMessage(
    base: std.Io.Dir,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    state_dir: []const u8,
    cfg: *const config_mod.Config,
    msg_id: []const u8,
    new_text: []const u8,
    from: []const u8,
) !Message {
    _ = cfg;
    const lock_path = try subPath(arena, state_dir, lock_file_name);
    const lock = file_lock.createFileRetry(io, base, lock_path, .{ .truncate = false, .lock = .exclusive }) catch null;
    defer if (lock) |f| f.close(io);
    const path = try subPath(arena, state_dir, log_path);
    const raw = base.readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch return error.NotFound;
    var messages: std.ArrayList(Message) = .empty;
    try parseLog(arena, raw, &messages);

    var result: ?Message = null;
    for (messages.items) |*m| {
        if (!std.mem.eql(u8, m.id, msg_id)) continue;
        if (!std.mem.eql(u8, m.from, from)) return error.NotOwner;
        const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
        m.text = new_text;
        m.edited = now;
        result = m.*;
        break;
    }
    const updated = result orelse return error.NotFound;
    try rewriteLog(base, io, gpa, arena, state_dir, messages.items);
    return updated;
}

/// Mark a message as deleted. Only the original sender can delete.
pub fn deleteMessage(
    base: std.Io.Dir,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    state_dir: []const u8,
    cfg: *const config_mod.Config,
    msg_id: []const u8,
    from: []const u8,
) !void {
    _ = cfg;
    const lock_path = try subPath(arena, state_dir, lock_file_name);
    const lock = file_lock.createFileRetry(io, base, lock_path, .{ .truncate = false, .lock = .exclusive }) catch null;
    defer if (lock) |f| f.close(io);
    const path = try subPath(arena, state_dir, log_path);
    const raw = base.readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch return error.NotFound;
    var messages: std.ArrayList(Message) = .empty;
    try parseLog(arena, raw, &messages);

    var found = false;
    for (messages.items) |*m| {
        if (!std.mem.eql(u8, m.id, msg_id)) continue;
        if (!std.mem.eql(u8, m.from, from)) return error.NotOwner;
        m.deleted = true;
        m.text = "[deleted]";
        found = true;
        break;
    }
    if (!found) return error.NotFound;
    try rewriteLog(base, io, gpa, arena, state_dir, messages.items);
}

// ----------------------------------------------------------- room metadata --
// Topics, pins, and per-room metadata are stored in state/<state_dir>/room_meta.json.

pub const RoomMeta = struct {
    topic: ?[]const u8 = null,
    pins: ?[]const []const u8 = null, // array of message ids
};

fn metaPath(arena: std.mem.Allocator, state_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/room_meta.json", .{state_dir});
}

pub fn loadMeta(base: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, state_dir: []const u8) !std.json.ArrayHashMap(RoomMeta) {
    const path = try metaPath(arena, state_dir);
    const raw = base.readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch
        return std.json.ArrayHashMap(RoomMeta){};
    const parsed = std.json.parseFromSliceLeaky(
        std.json.ArrayHashMap(RoomMeta),
        arena,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch return std.json.ArrayHashMap(RoomMeta){};
    return parsed;
}

fn saveMeta(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, meta: std.json.ArrayHashMap(RoomMeta)) !void {
    const path = try metaPath(arena, state_dir);
    var buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    s.write(meta) catch return error.TooLarge;
    try atomic_write.writeFile(io, base, path, buf[0..w.end]);
    _ = gpa;
}

pub fn setTopic(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, room: []const u8, topic: []const u8) !void {
    const lock_path = try subPath(arena, state_dir, meta_lock_file_name);
    const lock = file_lock.createFileRetry(io, base, lock_path, .{ .truncate = false, .lock = .exclusive }) catch null;
    defer if (lock) |f| f.close(io);
    var meta = try loadMeta(base, io, arena, state_dir);
    const gop = try meta.map.getOrPut(arena, room);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    gop.value_ptr.topic = topic;
    try saveMeta(base, io, gpa, arena, state_dir, meta);
}

pub fn getTopic(base: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, state_dir: []const u8, room: []const u8) !?[]const u8 {
    const meta = try loadMeta(base, io, arena, state_dir);
    const entry = meta.map.get(room) orelse return null;
    return entry.topic;
}

pub fn togglePin(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, room: []const u8, msg_id: []const u8) !bool {
    const lock_path = try subPath(arena, state_dir, meta_lock_file_name);
    const lock = file_lock.createFileRetry(io, base, lock_path, .{ .truncate = false, .lock = .exclusive }) catch null;
    defer if (lock) |f| f.close(io);
    var meta = try loadMeta(base, io, arena, state_dir);
    const gop = try meta.map.getOrPut(arena, room);
    if (!gop.found_existing) gop.value_ptr.* = .{};

    if (gop.value_ptr.pins) |existing| {
        // Check if already pinned, if so, remove
        var new_pins: std.ArrayList([]const u8) = .empty;
        var was_pinned = false;
        for (existing) |p| {
            if (std.mem.eql(u8, p, msg_id)) {
                was_pinned = true;
                continue;
            }
            try new_pins.append(arena, p);
        }
        if (was_pinned) {
            gop.value_ptr.pins = if (new_pins.items.len > 0) new_pins.items else null;
            try saveMeta(base, io, gpa, arena, state_dir, meta);
            return false; // unpinned
        }
        try new_pins.append(arena, msg_id);
        gop.value_ptr.pins = new_pins.items;
    } else {
        var new_pins: std.ArrayList([]const u8) = .empty;
        try new_pins.append(arena, msg_id);
        gop.value_ptr.pins = new_pins.items;
    }
    try saveMeta(base, io, gpa, arena, state_dir, meta);
    return true; // pinned
}

pub fn getPins(base: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, state_dir: []const u8, room: []const u8) !?[]const []const u8 {
    const meta = try loadMeta(base, io, arena, state_dir);
    const entry = meta.map.get(room) orelse return null;
    return entry.pins;
}

// ------------------------------------------------------------------ sending --

/// Appends the message locally and fans it out to every configured peer's
/// POST /api/chat/message. Returns the message (with ts + id filled in).
pub fn sendMessage(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, cfg: *const config_mod.Config, room: []const u8, text: []const u8) !Message {
    return sendMessageOpts(base, io, gpa, arena, state_dir, cfg, room, text, null);
}

pub fn sendMessageOpts(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, cfg: *const config_mod.Config, room: []const u8, text: []const u8, thread_ts: ?[]const u8) !Message {
    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    const msg = Message{
        .room = room,
        .from = cfg.instance.name,
        .text = text,
        .ts = ts,
        .id = try makeId(arena, ts),
        .thread_ts = thread_ts,
    };
    try append(base, io, gpa, arena, state_dir, cfg, msg);
    fanOut(io, gpa, cfg, msg);
    return msg;
}

/// Per-peer delivery cooldown. A peer that is unreachable (a down dummy, a
/// machine off the network, a restarting server) is not retried on every
/// message and is not logged as an error on every attempt: the harness backs
/// off exponentially and logs the down/up transition once. `fanOut` can run
/// from any request thread (serve runs one thread per connection), so the
/// shared list below is guarded by a mutex and every read/write happens
/// inside it.
const PeerCooldown = struct {
    name: []const u8,
    fail_count: u32 = 0,
    down_since_ns: i128 = 0, // 0 = up
};

var cooldown_mutex: std.Io.Mutex = .init;
var peer_cooldowns: ?std.ArrayList(PeerCooldown) = null;

/// True when `name` is still inside its backoff window.
fn inCooldown(io: std.Io, name: []const u8) bool {
    cooldown_mutex.lockUncancelable(io);
    defer cooldown_mutex.unlock(io);
    const list = peer_cooldowns orelse return false;
    for (list.items) |*c| {
        if (!std.mem.eql(u8, c.name, name)) continue;
        if (c.down_since_ns == 0) return false;
        const now = std.Io.Timestamp.now(io, .real).nanoseconds;
        if (now >= c.down_since_ns and now - c.down_since_ns < cooldownWindow(c.fail_count)) return true;
        return false;
    }
    return false;
}

/// Record a failed delivery; returns the backoff window in seconds (0 if the
/// cooldown slot could not be allocated).
fn recordFailure(io: std.Io, gpa: std.mem.Allocator, name: []const u8, now: i128) i64 {
    cooldown_mutex.lockUncancelable(io);
    defer cooldown_mutex.unlock(io);
    if (peer_cooldowns == null) peer_cooldowns = .empty;
    const list = &peer_cooldowns.?;
    for (list.items) |*c| {
        if (!std.mem.eql(u8, c.name, name)) continue;
        c.fail_count += 1;
        c.down_since_ns = now;
        return @intCast(@divTrunc(cooldownWindow(c.fail_count), @as(i128, std.time.ns_per_s)));
    }
    list.append(gpa, .{ .name = name, .fail_count = 1, .down_since_ns = now }) catch return 0;
    return @intCast(@divTrunc(cooldownWindow(1), @as(i128, std.time.ns_per_s)));
}

/// Record a successful delivery; clears any cooldown for `name`. Returns true
/// when the peer was previously down (a recovery worth noting).
fn recordSuccess(io: std.Io, name: []const u8) bool {
    cooldown_mutex.lockUncancelable(io);
    defer cooldown_mutex.unlock(io);
    const list = peer_cooldowns orelse return false;
    for (list.items) |*c| {
        if (!std.mem.eql(u8, c.name, name)) continue;
        const was_down = c.fail_count != 0;
        c.fail_count = 0;
        c.down_since_ns = 0;
        return was_down;
    }
    return false;
}

/// Drops the whole cooldown table. Test-only: the table outlives any one test,
/// so a test that grows it has to give the memory back itself.
fn resetCooldowns(io: std.Io, gpa: std.mem.Allocator) void {
    cooldown_mutex.lockUncancelable(io);
    defer cooldown_mutex.unlock(io);
    if (peer_cooldowns) |*l| l.deinit(gpa);
    peer_cooldowns = null;
}

/// Exponential backoff window for a down peer: 5s base, doubling per
/// consecutive failure, capped at 5 minutes, so a recovered peer is retried
/// promptly while a hard-down one stops being hammered.
fn cooldownWindow(fail_count: u32) i128 {
    const base: i128 = 5 * std.time.ns_per_s;
    const cap: i128 = 300 * std.time.ns_per_s;
    if (fail_count == 0) return 0;
    var w: i128 = base;
    var i: u32 = 1;
    while (i < fail_count) : (i += 1) {
        if (w >= cap) return cap;
        w *|= 2;
    }
    return @min(w, cap);
}

fn fanOut(io: std.Io, gpa: std.mem.Allocator, cfg: *const config_mod.Config, msg: Message) void {
    if (!cfg.chatrooms.on) return;
    if (cfg.peers.len == 0) return;

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    for (cfg.peers) |peer| {
        // Skip a peer still inside its backoff window: don't hammer it and
        // don't re-log the same failure on every message.
        if (inCooldown(io, peer.name)) continue;

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
        if (msg.thread_ts) |tts| {
            s.objectField("thread_ts") catch continue;
            s.write(tts) catch continue;
        }
        s.endObject() catch continue;
        const body = body_buf[0..w.end];

        var response_buf: [64 * 1024]u8 = undefined;
        var rw: std.Io.Writer = .fixed(&response_buf);
        const result = http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .headers = .{ .content_type = .{ .override = "application/json" }, .user_agent = .{ .override = "clanker/" ++ build_options.version } },
            .response_writer = &rw,
        }) catch |err| {
            const window_s = recordFailure(io, gpa, peer.name, std.Io.Timestamp.now(io, .real).nanoseconds);
            if (window_s > 0) {
                log.log(.error_, "chat to '{s}' failed: {s}; marking peer down, backing off {d}s", .{ peer.name, @errorName(err), window_s });
            } else {
                log.log(.error_, "chat to '{s}' failed: {s}", .{ peer.name, @errorName(err) });
            }
            continue;
        };
        const status = result.status;
        // Body is a peer-controlled response, not delivery confirmation content
        // worth surfacing at the default log level; a status code is enough to
        // know the send worked, and skipping the body keeps a peer echoing
        // message text (or anything else) out of this instance's logs.
        if (recordSuccess(io, peer.name)) {
            log.log(.info, "chat {s}: HTTP {d} (peer back up)", .{ peer.name, @intFromEnum(status) });
        } else {
            log.log(.info, "chat {s}: HTTP {d}", .{ peer.name, @intFromEnum(status) });
        }
    }
}

// ------------------------------------------------------------ subscriptions --

/// Adds or removes `room` from the runtime subscription override set.
/// `on=true` joins (also removes the room from the "unsubscribed" set so it
/// can rejoin a config-default room); `on=false` leaves (adds to
/// "unsubscribed" so it overrides a config-default subscription).
pub fn subscribe(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, room: []const u8, on: bool) !void {
    if (state_dir.len > 0) try ensure_dir.ensureDir(base, io, state_dir);
    // Subscription changes are read-modify-write operations. Serialize them
    // so concurrent join/leave requests cannot silently discard each other.
    var guard = file_lock.acquire(io, base, if (state_dir.len > 0) state_dir else ".", "chatrooms-sub", gpa);
    defer guard.release();
    const path = try subPath(arena, state_dir, sub_path);
    var rooms: std.ArrayList([]const u8) = .empty;
    var unsub: std.ArrayList([]const u8) = .empty;
    const raw = base.readFileAlloc(io, path, arena, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (raw) |contents| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, contents, .{ .ignore_unknown_fields = true }) catch
            return error.InvalidSubscriptionState;
        if (parsed != .object) return error.InvalidSubscriptionState;
        if (parsed.object.get("rooms")) |rv| {
            if (rv != .array) return error.InvalidSubscriptionState;
            for (rv.array.items) |item| {
                if (item == .string) try rooms.append(arena, item.string);
            }
        }
        if (parsed.object.get("unsubscribed")) |rv| {
            if (rv != .array) return error.InvalidSubscriptionState;
            for (rv.array.items) |item| {
                if (item == .string) try unsub.append(arena, item.string);
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
    try atomic_write.writeFile(io, base, path, buf[0..w.end]);
    log.log(.info, "chat: subscribed to '{s}' = {any}", .{ room, on });
}

// ------------------------------------------------------------- agent inbox --

/// Oldest-first messages after `cursor`, capped. Returning the oldest pending
/// batch is essential: advancing a cursor after a newest-first capped batch
/// permanently skipped every older pending message.
pub fn readNew(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, cursor: Cursor) ![]Message {
    _ = gpa;
    const path = subPath(arena, state_dir, log_path) catch return &[_]Message{};
    const raw = base.readFileAlloc(io, path, arena, .limited(1 << 20)) catch return &[_]Message{};
    var all: std.ArrayList(Message) = .empty;
    try parseLog(arena, raw, &all);
    var start: usize = 0;
    var found_id = false;
    if (cursor.id.len > 0) {
        for (all.items, 0..) |m, i| {
            if (std.mem.eql(u8, m.id, cursor.id)) {
                start = i + 1;
                found_id = true;
            }
        }
    }

    var out: std.ArrayList(Message) = .empty;
    for (all.items[start..]) |m| {
        // Timestamp fallback supports the old {"ts":...} cursor and recovers
        // if retention trimmed away the id. Once the id is found, log order is
        // authoritative even when peer clocks move backwards.
        if (!found_id and m.ts <= cursor.ts) continue;
        try out.append(arena, m);
        if (out.items.len >= inbox_limit) break;
    }
    return out.toOwnedSlice(arena);
}

pub fn readCursor(base: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, state_dir: []const u8) Cursor {
    const path = subPath(arena, state_dir, cursor_path) catch return .{};
    const raw = base.readFileAlloc(io, path, arena, .limited(4096)) catch return .{};
    const parsed = std.json.parseFromSliceLeaky(Cursor, arena, raw, .{ .ignore_unknown_fields = true }) catch return .{};
    return parsed;
}

pub fn writeCursor(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, state_dir: []const u8, msg: Message) void {
    _ = gpa;
    if (state_dir.len > 0) ensure_dir.ensureDir(base, io, state_dir) catch return;
    var path_buf: [512]u8 = undefined;
    const path = if (state_dir.len == 0)
        cursor_path
    else
        std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ state_dir, cursor_path }) catch return;
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    s.write(Cursor{ .id = msg.id, .ts = msg.ts }) catch return;
    w.writeByte('\n') catch return;
    const body = buf[0..w.end];
    atomic_write.writeFile(io, base, path, body) catch return;
}

// ------------------------------------------------------------------ helpers --

var id_counter = std.atomic.Value(u32).init(0);

fn makeId(arena: std.mem.Allocator, ts: i64) ![]const u8 {
    const seq = id_counter.fetchAdd(1, .monotonic) +% 1;
    const pid = std.c.getpid();
    return std.fmt.allocPrint(arena, "m{d}-{d}-{x}", .{ ts, pid, seq });
}

// ------------------------------------------------------------------- tests --

test "jsonlLineCount ignores blank lines" {
    try std.testing.expectEqual(@as(usize, 0), jsonlLineCount(""));
    try std.testing.expectEqual(@as(usize, 0), jsonlLineCount("\n\n"));
    try std.testing.expectEqual(@as(usize, 1), jsonlLineCount("a\n"));
    try std.testing.expectEqual(@as(usize, 2), jsonlLineCount("a\n\nb\n"));
    try std.testing.expectEqual(@as(usize, 2), jsonlLineCount("a\nb"));
}

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

    const fresh = try readNew(tmp.dir, io, std.testing.allocator, arena, "", .{ .ts = 1000 });
    try std.testing.expectEqual(@as(usize, 1), fresh.len);
}

test "append trims to max_history and keeps the newest lines" {
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
    cfg.chatrooms.max_history = 3;

    // 6 appends force trimLog to drop the first 3 and keep the newest 3 on
    // every append past the cap. This exercises the trim (the old `out.* =
    // new_list` aliased the buffer and freed it, so the write hit freed
    // memory and the log came back corrupted / the write EFAULTed).
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        try append(tmp.dir, io, std.testing.allocator, arena, "", &cfg, .{
            .room = "dev",
            .from = "test-clanker",
            .text = try std.fmt.allocPrint(arena, "line {d}", .{i}),
            .ts = @as(i64, @intCast(i)),
            .id = try std.fmt.allocPrint(arena, "m{d}", .{i}),
        });
    }

    // Only the newest 3 survive, oldest dropped first.
    const hist = try readHistory(tmp.dir, io, std.testing.allocator, arena, "", "dev", 0, 50);
    try std.testing.expectEqual(@as(usize, 3), hist.len);
    try std.testing.expectEqualStrings("line 5", hist[0].text); // newest first
    try std.testing.expectEqualStrings("line 4", hist[1].text);
    try std.testing.expectEqualStrings("line 3", hist[2].text);

    // The trimmed log must still be a valid, parseable room file.
    const rooms = try listRooms(tmp.dir, io, std.testing.allocator, arena, "");
    try std.testing.expectEqual(@as(usize, 1), rooms.len);
    try std.testing.expectEqual(@as(usize, 3), rooms[0].messages);
}

test "readHistoryAsc pages oldest-first and extends through a shared boundary timestamp" {
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
    cfg.chatrooms.rooms = &.{"board"};
    cfg.chatrooms.max_history = 100;

    // 6 messages: ts 1, 2, 2, 2, 3, 4, plus one in another room that must
    // never appear. Appended newest-first-ish on purpose: the page boundary
    // is only a real ts boundary after the sort inside readHistoryAsc.
    const specs = [_]struct { ts: i64, id: []const u8 }{
        .{ .ts = 3, .id = "e" },
        .{ .ts = 1, .id = "a" },
        .{ .ts = 2, .id = "c" },
        .{ .ts = 2, .id = "b" },
        .{ .ts = 4, .id = "f" },
        .{ .ts = 2, .id = "d" },
    };
    for (specs) |sp| {
        try append(tmp.dir, io, std.testing.allocator, arena, "", &cfg, .{ .room = "board", .from = "t", .text = "x", .ts = sp.ts, .id = sp.id });
    }
    try append(tmp.dir, io, std.testing.allocator, arena, "", &cfg, .{ .room = "dev", .from = "t", .text = "x", .ts = 2, .id = "zz" });

    // limit 2 cuts inside the ts=2 group: the page must extend through it
    // (4 messages: ts 1, 2, 2, 2), or the caller's next `after` cursor of 2
    // would skip the group's remainder.
    const p1 = try readHistoryAsc(tmp.dir, io, arena, "", "board", 0, 2);
    try std.testing.expectEqual(@as(usize, 4), p1.msgs.len);
    try std.testing.expect(p1.has_more);
    try std.testing.expectEqualStrings("a", p1.msgs[0].id);
    try std.testing.expectEqualStrings("b", p1.msgs[1].id); // ties break by id
    try std.testing.expectEqualStrings("d", p1.msgs[3].id);

    // The next page picks up exactly where the cursor points.
    const p2 = try readHistoryAsc(tmp.dir, io, arena, "", "board", 2, 2);
    try std.testing.expectEqual(@as(usize, 2), p2.msgs.len);
    try std.testing.expect(!p2.has_more);
    try std.testing.expectEqualStrings("e", p2.msgs[0].id);
    try std.testing.expectEqualStrings("f", p2.msgs[1].id);

    // A page that fits under the limit reports no more and stays ascending.
    const all = try readHistoryAsc(tmp.dir, io, arena, "", "board", 0, 50);
    try std.testing.expectEqual(@as(usize, 6), all.msgs.len);
    try std.testing.expect(!all.has_more);
}

test "inbox cursor drains a capped same-timestamp burst without loss" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cfg = config_mod.Config{};
    cfg.chatrooms.max_history = 100;

    var i: usize = 0;
    while (i < inbox_limit + 2) : (i += 1) {
        const id = try std.fmt.allocPrint(arena, "burst-{d}", .{i});
        try append(tmp.dir, io, std.testing.allocator, arena, "", &cfg, .{
            .room = "dev",
            .from = "peer",
            .text = "burst",
            .ts = 1000,
            .id = id,
        });
    }

    const first = try readNew(tmp.dir, io, std.testing.allocator, arena, "", .{});
    try std.testing.expectEqual(@as(usize, inbox_limit), first.len);
    try std.testing.expectEqualStrings("burst-0", first[0].id);
    const second = try readNew(tmp.dir, io, std.testing.allocator, arena, "", .{
        .id = first[first.len - 1].id,
        .ts = first[first.len - 1].ts,
    });
    try std.testing.expectEqual(@as(usize, 2), second.len);
    try std.testing.expectEqualStrings("burst-5", second[0].id);
    try std.testing.expectEqualStrings("burst-6", second[1].id);
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

test "subscribe does not overwrite malformed state" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const malformed = "{not-json";
    try tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = malformed });
    try std.testing.expectError(error.InvalidSubscriptionState, subscribe(tmp.dir, io, std.testing.allocator, arena, "", "ops", true));
    const preserved = try tmp.dir.readFileAlloc(io, sub_path, arena, .limited(1024));
    try std.testing.expectEqualStrings(malformed, preserved);
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

test "receive ignores a redelivered message id" {
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

    const msg = Message{ .room = "dev", .from = "peer", .text = "hi", .ts = 1, .id = "dup-1" };
    try std.testing.expect(try receive(tmp.dir, io, std.testing.allocator, arena, "", &cfg, msg));
    // Redelivered (e.g. the sender retried after losing the response): same
    // state as running once, not a second entry.
    try std.testing.expect(try receive(tmp.dir, io, std.testing.allocator, arena, "", &cfg, msg));

    const hist = try readHistory(tmp.dir, io, std.testing.allocator, arena, "", "dev", 0, 10);
    try std.testing.expectEqual(@as(usize, 1), hist.len);

    // An id-less message (an old peer that never sent one) is never deduped.
    const no_id = Message{ .room = "dev", .from = "peer", .text = "no id here", .ts = 2, .id = "" };
    try std.testing.expect(try receive(tmp.dir, io, std.testing.allocator, arena, "", &cfg, no_id));
    try std.testing.expect(try receive(tmp.dir, io, std.testing.allocator, arena, "", &cfg, no_id));
    const hist2 = try readHistory(tmp.dir, io, std.testing.allocator, arena, "", "dev", 0, 10);
    try std.testing.expectEqual(@as(usize, 3), hist2.len);
}

test "messages from concurrent senders are all kept" {
    // append reads the whole log, adds a line and writes it back. Two senders
    // racing both start from the same contents, so the second write drops the
    // first message. Chatrooms exist for separate clanker processes to talk,
    // which makes that the ordinary case rather than an unlucky one.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cfg = config_mod.Config{};
    cfg.instance.name = "test-clanker";
    cfg.chatrooms.on = true;
    cfg.chatrooms.max_history = 10_000;

    const senders = 6;
    const per_sender = 10;

    const Sender = struct {
        dir: std.Io.Dir,
        io: std.Io,
        gpa: std.mem.Allocator,
        cfg: *const config_mod.Config,
        id: usize,

        fn run(self: *@This()) void {
            var arena_state = std.heap.ArenaAllocator.init(self.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var i: usize = 0;
            while (i < per_sender) : (i += 1) {
                const id = std.fmt.allocPrint(arena, "s{d}-{d}", .{ self.id, i }) catch return;
                append(self.dir, self.io, self.gpa, arena, "state", self.cfg, .{
                    .room = "dev",
                    .from = "tester",
                    .text = "hello",
                    .ts = @intCast(i),
                    .id = id,
                }) catch return;
            }
        }
    };

    var senders_buf: [senders]Sender = undefined;
    var threads: [senders]std.Thread = undefined;
    for (&senders_buf, 0..) |*w, i| {
        w.* = .{ .dir = tmp.dir, .io = io, .gpa = std.testing.allocator, .cfg = &cfg, .id = i };
        threads[i] = try std.Thread.spawn(.{}, Sender.run, .{w});
    }
    for (&threads) |*t| t.join();

    const raw = try tmp.dir.readFileAlloc(io, "state/chatrooms.jsonl", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(raw);

    var kept: usize = 0;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        kept += 1;
    }
    try std.testing.expectEqual(@as(usize, senders * per_sender), kept);
}

test "down-peer backoff grows, caps, and recovers on success" {
    // Pure window math: base 5s, doubling per consecutive failure, capped at
    // 5 minutes; no failures means no window.
    try std.testing.expectEqual(@as(i128, 0), cooldownWindow(0));
    try std.testing.expectEqual(@as(i128, 5 * std.time.ns_per_s), cooldownWindow(1));
    try std.testing.expectEqual(@as(i128, 10 * std.time.ns_per_s), cooldownWindow(2));
    try std.testing.expectEqual(@as(i128, 20 * std.time.ns_per_s), cooldownWindow(3));
    try std.testing.expectEqual(@as(i128, 300 * std.time.ns_per_s), cooldownWindow(100));

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Clear any cooldown state a prior test in this process may have left, and
    // hand the buffer back on the way out. clearRetainingCapacity keeps the
    // allocation by contract, and this table is a process-wide global, so
    // whatever it still holds when the test ends is charged to whichever test
    // grew it.
    resetCooldowns(io, std.testing.allocator);
    defer resetCooldowns(io, std.testing.allocator);

    const now = std.Io.Timestamp.now(io, .real).nanoseconds;
    try std.testing.expect(!inCooldown(io, "down-peer"));
    try std.testing.expectEqual(@as(i64, 5), recordFailure(io, std.testing.allocator, "down-peer", now));
    try std.testing.expect(inCooldown(io, "down-peer"));

    // A second consecutive failure doubles the window.
    try std.testing.expectEqual(@as(i64, 10), recordFailure(io, std.testing.allocator, "down-peer", now));

    // A successful delivery clears the cooldown and reports recovery once.
    try std.testing.expect(recordSuccess(io, "down-peer"));
    try std.testing.expect(!inCooldown(io, "down-peer"));
    try std.testing.expect(!recordSuccess(io, "down-peer"));
}

test "edit, delete and react distinguish missing from not-owner" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cfg = config_mod.Config{};
    cfg.instance.name = "alice";
    cfg.chatrooms.on = true;
    cfg.chatrooms.rooms = &.{"dev"};
    cfg.chatrooms.max_history = 100;

    try append(tmp.dir, io, std.testing.allocator, arena, "", &cfg, .{
        .room = "dev",
        .from = "alice",
        .text = "mine",
        .ts = 1,
        .id = "m1",
    });

    try std.testing.expectError(error.NotFound, editMessage(tmp.dir, io, std.testing.allocator, arena, "", &cfg, "nope", "x", "alice"));
    try std.testing.expectError(error.NotOwner, editMessage(tmp.dir, io, std.testing.allocator, arena, "", &cfg, "m1", "x", "bob"));
    const edited = try editMessage(tmp.dir, io, std.testing.allocator, arena, "", &cfg, "m1", "updated", "alice");
    try std.testing.expectEqualStrings("updated", edited.text);

    try std.testing.expectError(error.NotFound, toggleReaction(tmp.dir, io, std.testing.allocator, arena, "", &cfg, "nope", "👍", "alice"));
    try std.testing.expect(try toggleReaction(tmp.dir, io, std.testing.allocator, arena, "", &cfg, "m1", "👍", "alice"));

    try std.testing.expectError(error.NotFound, deleteMessage(tmp.dir, io, std.testing.allocator, arena, "", &cfg, "nope", "alice"));
    try std.testing.expectError(error.NotOwner, deleteMessage(tmp.dir, io, std.testing.allocator, arena, "", &cfg, "m1", "bob"));
    try deleteMessage(tmp.dir, io, std.testing.allocator, arena, "", &cfg, "m1", "alice");
}
