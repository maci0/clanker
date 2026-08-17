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
//! POST /api/chat/message via the sandboxed `peers` tool (the host keeps the
//! per-peer backoff table and hands the guest the names to skip); each peer
//! appends it only when it subscribes to the room, so every clanker's log is
//! exactly the rooms it belongs to.

const std = @import("std");
const config_mod = @import("../config.zig");
const log = @import("../util/log.zig");
const atomic_write = @import("../util/atomic_write.zig");
const file_lock = @import("../util/file_lock.zig");
const ensure_dir = @import("../util/ensure_dir.zig");
const utf8 = @import("../util/utf8.zig");
const registry = @import("../toolhost/registry.zig");
const runtime = @import("../sandbox/runtime.zig");

/// Guards the read-modify-write in `append`. Separate from the log so that
/// trimming, which replaces the log, cannot invalidate a held lock.
const lock_file_name = "chatrooms.lock";
const meta_lock_file_name = "chatrooms-meta.lock";

/// Takes the exclusive lock for a chatroom read-modify-write, or null when it
/// could not. Best effort by design: a message or mutation is worth applying
/// unserialised rather than dropping outright, but the failure must not pass
/// silently — an unlocked read-modify-write is exactly the case where two
/// writers discard each other's write (see file_lock.zig), and every such
/// discard loses a message with no trace.
fn acquireChatroomLock(io: std.Io, base: std.Io.Dir, lock_path: []const u8) ?std.Io.File {
    // createFileRetry, not createFile: racing creates of a not-yet-existing
    // lock file spuriously fail ENOENT on macOS (see file_lock.zig), and every
    // such failure here is a concurrent write running unserialised, i.e. a
    // silently dropped message.
    return file_lock.createFileRetry(io, base, lock_path, .{ .truncate = false, .lock = .exclusive }) catch |err| blk: {
        log.log(.warn, "[chat] could not lock {s} ({s}); a concurrent write may be lost", .{ lock_path, @errorName(err) });
        break :blk null;
    };
}

pub const log_path = "chatrooms.jsonl";
pub const sub_path = "chatrooms-sub.json";
pub const cursor_path = "chatrooms-cursor.json";
pub const max_text_len = 4096;
/// Room topic length cap. Enforced by the guest `chat` tool host function
/// (src/sandbox/host.zig) and by POST /api/chat/topic, so both entry points
/// reject the same input and a topic cannot overflow the room_meta.json
/// buffer (saveMeta's 64 KiB fixed frame).
pub const max_topic_len = 1024;
/// Reaction emoji length cap (bytes). Enforced by the guest `chat` tool host
/// function (src/sandbox/host.zig) and by POST /api/chat/react, so both entry
/// points reject the same input.
pub const max_emoji_len = 64;
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
    const lock = acquireChatroomLock(io, base, lock_path);
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
    // them. The log never holds more than `max_history` entries after an
    // append (trimLog keeps exactly the newest `max`), and a redelivery is a
    // retry of a just-appended message, so scanning the tail of the retained
    // window finds any duplicate: parsing every record in the log used to cost
    // one JSON parse per message on every send.
    if (msg.id.len > 0) {
        if (hasMessageId(arena, existing, msg.id, cfg.chatrooms.max_history)) {
            log.log(.debug, "[chat] duplicate message id '{s}' ignored", .{msg.id});
            return;
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

/// True when `id` appears among the last `max` lines of `raw`. The log is
/// trimmed to `max_history` entries on every append, so the last `max` lines
/// cover the whole log; walking from the end also finds a duplicate (always a
/// recent redelivery) after parsing only a few lines.
fn hasMessageId(arena: std.mem.Allocator, raw: []const u8, id: []const u8, max: u32) bool {
    if (max == 0) return false;
    var end = raw.len;
    var checked: u32 = 0;
    while (end > 0 and checked < max) {
        var start = end;
        while (start > 0 and raw[start - 1] != '\n') start -= 1;
        const line = raw[start..end];
        end = if (start > 0) start - 1 else 0;
        if (line.len == 0) continue;
        const m = std.json.parseFromSliceLeaky(Message, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        if (std.mem.eql(u8, m.id, id)) return true;
        checked += 1;
    }
    return false;
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
    const lock = acquireChatroomLock(io, base, lock_path);
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
    const lock = acquireChatroomLock(io, base, lock_path);
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
    const lock = acquireChatroomLock(io, base, lock_path);
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
    // Same empty-state_dir rule as subPath/writeCursor: an unguarded "" would
    // produce "/room_meta.json", which openat resolves at the filesystem root
    // instead of the working directory.
    if (state_dir.len == 0) return "room_meta.json";
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
    const lock = acquireChatroomLock(io, base, lock_path);
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
    const lock = acquireChatroomLock(io, base, lock_path);
    defer if (lock) |f| f.close(io);
    var meta = try loadMeta(base, io, arena, state_dir);
    const gop = try meta.map.getOrPut(arena, room);
    if (!gop.found_existing) gop.value_ptr.* = .{};

    var new_pins: std.ArrayList([]const u8) = .empty;
    var was_pinned = false;
    if (gop.value_ptr.pins) |existing| {
        for (existing) |p| {
            if (std.mem.eql(u8, p, msg_id)) {
                was_pinned = true;
                continue;
            }
            try new_pins.append(arena, p);
        }
    }
    if (was_pinned) {
        gop.value_ptr.pins = if (new_pins.items.len > 0) new_pins.items else null;
        try saveMeta(base, io, gpa, arena, state_dir, meta);
        return false; // unpinned
    }
    try new_pins.append(arena, msg_id);
    gop.value_ptr.pins = new_pins.items;
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
pub fn sendMessage(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, cfg: *const config_mod.Config, environ_map: *std.process.Environ.Map, room: []const u8, text: []const u8) !Message {
    return sendMessageOpts(base, io, gpa, arena, state_dir, cfg, environ_map, room, text, null);
}

pub fn sendMessageOpts(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, cfg: *const config_mod.Config, environ_map: *std.process.Environ.Map, room: []const u8, text: []const u8, thread_ts: ?[]const u8) !Message {
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
    fanOut(io, gpa, arena, environ_map, cfg, msg);
    return msg;
}

/// Per-peer delivery cooldown. A peer that is unreachable (a down dummy, a
/// machine off the network, a restarting server) is not retried on every
/// message and is not logged as an error on every attempt: the harness backs
/// off exponentially and logs the down/up transition once. `fanOut` can run
/// from any request thread (serve runs one thread per connection), so the
/// shared table below is guarded by a mutex and every read/write happens
/// inside it.
///
/// The table is process-lifetime state with one slot per configured peer, so
/// it is a fixed-size static array rather than a heap list. Two things follow
/// from that, and both were bugs while it was an `ArrayList`: nothing has to
/// free it at exit (a `[[peers]]` entry that does not answer used to end an
/// ordinary command in a DebugAllocator leak trace), and the name is *copied*
/// rather than borrowed. The name `recordFailure` sees comes from `fanOut`'s
/// arena-parsed tool reply, which is freed when that request's arena is, so a
/// borrowed slice left every later `inCooldown` comparing against memory the
/// arena had already reclaimed.
const max_cooldown_peers = 64;
const max_cooldown_name = 64;

const PeerCooldown = struct {
    name_buf: [max_cooldown_name]u8 = undefined,
    name_len: u8 = 0,
    fail_count: u32 = 0,
    down_since_ns: i128 = 0, // 0 = up

    fn name(self: *const PeerCooldown) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

var cooldown_mutex: std.Io.Mutex = .init;
var peer_cooldowns: [max_cooldown_peers]PeerCooldown = @splat(.{});
var peer_cooldown_count: usize = 0;

/// The slot for `name`, or null when the peer has none yet.
fn cooldownSlot(name: []const u8) ?*PeerCooldown {
    for (peer_cooldowns[0..peer_cooldown_count]) |*c| {
        if (std.mem.eql(u8, c.name(), name)) return c;
    }
    return null;
}

/// True when `name` is still inside its backoff window.
fn inCooldown(io: std.Io, name: []const u8) bool {
    cooldown_mutex.lockUncancelable(io);
    defer cooldown_mutex.unlock(io);
    const c = cooldownSlot(name) orelse return false;
    if (c.down_since_ns == 0) return false;
    const now = std.Io.Timestamp.now(io, .real).nanoseconds;
    return now >= c.down_since_ns and now - c.down_since_ns < cooldownWindow(c.fail_count);
}

/// Record a failed delivery; returns the backoff window in seconds (0 when the
/// peer has no slot and cannot be given one: the table is full, or the name is
/// longer than a slot holds). Delivery is unaffected either way; only the
/// backoff and its one-line log are.
fn recordFailure(io: std.Io, name: []const u8, now: i128) i64 {
    cooldown_mutex.lockUncancelable(io);
    defer cooldown_mutex.unlock(io);
    if (cooldownSlot(name)) |c| {
        c.fail_count += 1;
        c.down_since_ns = now;
        return @intCast(@divTrunc(cooldownWindow(c.fail_count), @as(i128, std.time.ns_per_s)));
    }
    if (peer_cooldown_count == peer_cooldowns.len or name.len > max_cooldown_name) return 0;
    const c = &peer_cooldowns[peer_cooldown_count];
    @memcpy(c.name_buf[0..name.len], name);
    c.name_len = @intCast(name.len);
    c.fail_count = 1;
    c.down_since_ns = now;
    peer_cooldown_count += 1;
    return @intCast(@divTrunc(cooldownWindow(1), @as(i128, std.time.ns_per_s)));
}

/// Record a successful delivery; clears any cooldown for `name`. Returns true
/// when the peer was previously down (a recovery worth noting).
fn recordSuccess(io: std.Io, name: []const u8) bool {
    cooldown_mutex.lockUncancelable(io);
    defer cooldown_mutex.unlock(io);
    const c = cooldownSlot(name) orelse return false;
    const was_down = c.fail_count != 0;
    c.fail_count = 0;
    c.down_since_ns = 0;
    return was_down;
}

/// Empties the cooldown table. Test-only: the table is process-wide, so a test
/// that fills it would otherwise leave its peers cooling down for the next one.
fn resetCooldowns(io: std.Io) void {
    cooldown_mutex.lockUncancelable(io);
    defer cooldown_mutex.unlock(io);
    peer_cooldown_count = 0;
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

/// One peer's outcome from the guest's `chat_fanout` action, so the host can
/// move each peer into or out of its backoff window.
const FanOutResult = struct {
    name: []const u8 = "",
    ok: bool = false,
    @"error": ?[]const u8 = null,
};

const FanOutReply = struct {
    ok: bool = false,
    @"error": ?[]const u8 = null,
    results: []const FanOutResult = &.{},
};

fn fanOut(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, environ_map: *std.process.Environ.Map, cfg: *const config_mod.Config, msg: Message) void {
    if (!cfg.chatrooms.on) return;
    if (cfg.peers.len == 0) return;

    // The HTTP delivery itself runs inside the sandboxed `peers` tool, the
    // same gate phonebook and notify use: every request is confined to the
    // configured peer hosts by that tool's `network_from_config` allowlist.
    // The host keeps the per-peer backoff table and hands over the names it
    // is already cooling down, so a down peer is not hammered on every
    // message while its cooldown is still running.
    var skip: std.ArrayList([]const u8) = .empty;
    defer skip.deinit(gpa);
    for (cfg.peers) |peer| {
        if (inCooldown(io, peer.name)) skip.append(gpa, peer.name) catch {};
    }

    var enc: std.Io.Writer.Allocating = .init(arena);
    defer enc.deinit();
    var s = std.json.Stringify{ .writer = &enc.writer, .options = .{ .emit_null_optional_fields = false } };
    s.beginObject() catch return;
    s.objectField("action") catch return;
    s.write("chat_fanout") catch return;
    s.objectField("room") catch return;
    s.write(msg.room) catch return;
    s.objectField("from") catch return;
    s.write(msg.from) catch return;
    s.objectField("text") catch return;
    s.write(msg.text) catch return;
    s.objectField("ts") catch return;
    s.print("{d}", .{msg.ts}) catch return;
    s.objectField("id") catch return;
    s.write(msg.id) catch return;
    if (msg.thread_ts) |tts| {
        s.objectField("thread_ts") catch return;
        s.write(tts) catch return;
    }
    s.objectField("skip") catch return;
    s.write(skip.items) catch return;
    s.endObject() catch return;
    const input = enc.written();

    var reg = registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir) catch |err| {
        log.log(.error_, "chat fan-out: tool registry load failed: {s}", .{@errorName(err)});
        return;
    };
    const mod = runtime.loadNamedTool(gpa, io, arena, environ_map, cfg, &reg, "peers", null) catch |err| {
        log.log(.error_, "chat fan-out: 'peers' tool load failed: {s}", .{@errorName(err)});
        return;
    };
    defer mod.deinit();
    const raw = mod.executeTool(input) catch |err| {
        log.log(.error_, "chat fan-out: 'peers' tool failed: {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(raw);

    const reply = std.json.parseFromSliceLeaky(FanOutReply, arena, raw, .{ .ignore_unknown_fields = true }) catch {
        log.log(.error_, "chat fan-out: the tool answered something that is not JSON", .{});
        return;
    };
    if (!reply.ok) {
        log.log(.error_, "chat fan-out: {s}", .{reply.@"error" orelse "unknown error"});
        return;
    }

    const now = std.Io.Timestamp.now(io, .real).nanoseconds;
    for (reply.results) |r| {
        if (r.ok) {
            // A completed delivery clears any cooldown; a peer that had been
            // down coming back is worth saying once.
            if (recordSuccess(io, r.name)) {
                log.log(.info, "chat {s}: delivered (peer back up)", .{r.name});
            } else {
                log.log(.info, "chat {s}: delivered", .{r.name});
            }
        } else {
            const window_s = recordFailure(io, r.name, now);
            if (window_s > 0) {
                log.log(.error_, "chat to '{s}' failed: {s}; marking peer down, backing off {d}s", .{ r.name, r.@"error" orelse "unknown error", window_s });
            } else {
                log.log(.error_, "chat to '{s}' failed: {s}", .{ r.name, r.@"error" orelse "unknown error" });
            }
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
    // Walk lines from the end and stop at the cursor id: the cursor sits at
    // the newest message the agent has read, so pending messages are always
    // in the tail, and the old forward scan parsed every record in the log on
    // every agent turn even when nothing new had arrived. Messages are
    // collected newest-first and reversed below, and the timestamp fallback
    // applies only when the id was never found (a legacy {"ts":...} cursor, or
    // retention trimmed the id away); once the id is found, log order is
    // authoritative even when peer clocks move backwards.
    var end = raw.len;
    var out: std.ArrayList(Message) = .empty;
    var found_id = false;
    var done = false;
    while (end > 0 and !done) {
        var start = end;
        while (start > 0 and raw[start - 1] != '\n') start -= 1;
        const line = raw[start..end];
        end = if (start > 0) start - 1 else 0;
        if (line.len == 0) continue;
        const m = std.json.parseFromSliceLeaky(Message, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        if (cursor.id.len > 0 and std.mem.eql(u8, m.id, cursor.id)) {
            found_id = true;
            done = true;
            continue;
        }
        try out.append(arena, m);
    }
    std.mem.reverse(Message, out.items);
    if (!found_id) {
        var kept: std.ArrayList(Message) = .empty;
        for (out.items) |m| {
            if (m.ts <= cursor.ts) continue;
            try kept.append(arena, m);
        }
        out = kept;
    }
    if (out.items.len > inbox_limit) out.items.len = inbox_limit;
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

test "meta ops with empty state_dir stay in the working directory" {
    // metaPath used to build "/room_meta.json" for state_dir == "", which
    // openat resolves at the filesystem root. The module's contract is that
    // every state file lives under base + state_dir, and "" means cwd.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try setTopic(tmp.dir, io, std.testing.allocator, arena, "", "dev", "topic");
    const topic = try getTopic(tmp.dir, io, arena, "", "dev");
    try std.testing.expectEqualStrings("topic", topic.?);

    // The meta file must exist under the base dir, never at "/room_meta.json".
    try tmp.dir.access(io, "room_meta.json", .{});
    const pinned = try togglePin(tmp.dir, io, std.testing.allocator, arena, "", "dev", "m1");
    try std.testing.expect(pinned);
    const pins = try getPins(tmp.dir, io, arena, "", "dev");
    try std.testing.expectEqual(@as(usize, 1), pins.?.len);
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
    // again on the way out: the table is a process-wide global, so a peer this
    // test marks down would otherwise still be down for the next one.
    resetCooldowns(io);
    defer resetCooldowns(io);

    const now = std.Io.Timestamp.now(io, .real).nanoseconds;
    try std.testing.expect(!inCooldown(io, "down-peer"));
    try std.testing.expectEqual(@as(i64, 5), recordFailure(io, "down-peer", now));
    try std.testing.expect(inCooldown(io, "down-peer"));

    // A second consecutive failure doubles the window.
    try std.testing.expectEqual(@as(i64, 10), recordFailure(io, "down-peer", now));

    // A successful delivery clears the cooldown and reports recovery once.
    try std.testing.expect(recordSuccess(io, "down-peer"));
    try std.testing.expect(!inCooldown(io, "down-peer"));
    try std.testing.expect(!recordSuccess(io, "down-peer"));
}

test "a cooldown outlives the arena the peer name was parsed into" {
    // `fanOut` reads each peer's name out of the tool reply it parsed into the
    // request arena, then hands it to `recordFailure`. The cooldown table is
    // process-lifetime, so a borrowed name is read back after that arena is
    // gone; the slot copies the bytes instead.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    resetCooldowns(io);
    defer resetCooldowns(io);

    const now = std.Io.Timestamp.now(io, .real).nanoseconds;
    {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const parsed = try std.json.parseFromSliceLeaky(
            FanOutResult,
            arena_state.allocator(),
            \\{"name":"ephemeral-peer","ok":false,"error":"refused"}
        ,
            .{ .ignore_unknown_fields = true },
        );
        try std.testing.expectEqual(@as(i64, 5), recordFailure(io, parsed.name, now));
    }
    try std.testing.expect(inCooldown(io, "ephemeral-peer"));
    try std.testing.expect(recordSuccess(io, "ephemeral-peer"));
}

test "the cooldown table refuses what it cannot hold instead of truncating" {
    // No slot and an over-long name both mean "no backoff for this peer"; the
    // 0 return is what keeps `fanOut` from claiming a window it is not keeping.
    // Truncating instead would alias two peers onto one slot.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    resetCooldowns(io);
    defer resetCooldowns(io);

    const now = std.Io.Timestamp.now(io, .real).nanoseconds;
    const too_long = "p" ** (max_cooldown_name + 1);
    try std.testing.expectEqual(@as(i64, 0), recordFailure(io, too_long, now));
    try std.testing.expect(!inCooldown(io, too_long));

    var buf: [16]u8 = undefined;
    for (0..max_cooldown_peers) |i| {
        const name = try std.fmt.bufPrint(&buf, "peer-{d}", .{i});
        try std.testing.expectEqual(@as(i64, 5), recordFailure(io, name, now));
    }
    try std.testing.expectEqual(@as(i64, 0), recordFailure(io, "one-too-many", now));
    // A peer that already has a slot keeps backing off with the table full.
    try std.testing.expectEqual(@as(i64, 10), recordFailure(io, "peer-0", now));
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
