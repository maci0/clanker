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
const test_env = @import("../util/test_env.zig");

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
/// reject the same input.
pub const max_topic_len = 1024;
/// Pins retained per room, newest kept. `togglePin` appends and the log
/// trims to `max_history` under it, so without a bound the pin list is the
/// one chatroom structure that grows forever — and it grows inside a file
/// every topic and pin write rewrites whole.
pub const max_pins_per_room = 200;
/// Rooms whose metadata `room_meta.json` is read back. Rooms are created by
/// sending to a name, so this is a cap on the file rather than on the domain;
/// it exists so `metaReadCap` is derived from policy the way `logReadCap` is,
/// instead of the fixed 1 MiB that preceded it.
const max_meta_rooms: usize = 4096;

/// The whole metadata file under a size the writer cannot exceed: each room
/// costs a name, a capped topic, and at most `max_pins_per_room` message ids.
/// A cap below what `saveMeta` can produce would make the file unreadable to
/// its own writer, which is the failure `logReadCap` documents for the log.
fn metaReadCap() usize {
    // 128 bytes per pinned id: a locally minted one is ~40 (`m<ts>-<pid>-<seq>`)
    // and a peer's is operator-controlled input, the same trust level as
    // `max_envelope_bytes` above.
    const per_room = max_topic_len * 2 + max_pins_per_room * 128 + 256;
    return max_meta_rooms * per_room;
}
/// Reaction emoji length cap (bytes). Enforced by the guest `chat` tool host
/// function (src/sandbox/host.zig) and by POST /api/chat/react, so both entry
/// points reject the same input.
pub const max_emoji_len = 64;
/// Room list last-message preview. Distinct from max_text_len (the send cap).
const last_text_preview_bytes = 120;
/// Newest messages injected into the agent inbox per run.
pub const inbox_limit = 5;
/// Operator-surface history page: CLI `clanker chat history` and HTTP
/// `GET /api/chat/messages`. Deliberately larger than the agent-facing
/// page — `chat_history_page_size` (20) in src/sandbox/host.zig protects
/// the model's context budget, while an operator scrolling a room reads
/// full text and can take more per request (PRD 0001).
pub const history_page_size = 50;
/// One line's JSON envelope beyond the text: room, from, id, ts, thread,
/// reactions, and framing. Text is capped at `max_text_len` and the JSON
/// escaping can double it, so a worst-case line is `max_text_len * 2` plus
/// this. A name or reaction pile-up larger than this is operator-controlled
/// input, the same trust level as `max_history` itself.
const max_envelope_bytes: usize = 2048;

/// The most a trimmed log can occupy: `max_history` entries at the worst-case
/// line size. The read in `append` (and the rewrite mutations) must cover the
/// whole retained window; a fixed 1 MiB cap silently truncated a log whose
/// window exceeded it — ~250 messages at the 4 KiB text cap cross 1 MiB
/// inside the default 500-entry history. Everything downstream that trusted
/// the read as the whole log then misfired: the line count under-counted so
/// the trim never ran and the log grew without bound past `max_history`, and
/// the redelivery dedup walked the tail of the truncated prefix (the middle
/// of the file) instead of the newest lines, so a retried message duplicated.
fn logReadCap(max_history: u32) usize {
    return @as(usize, max_history) * (max_text_len * 2 + max_envelope_bytes);
}

/// The whole log under the cap the writer trims to. Every reader of
/// `log_path` goes through here: `readFileAlloc` returns
/// `error.StreamTooLong` rather than a short read when the file exceeds the
/// limit, and each reader turns that into an empty result, so a cap below the
/// retained window is not a partial answer but a silent no-messages one. The
/// fixed 1 MiB cap this replaced did exactly that to the agent inbox, the
/// board fold and the room list once a room passed ~250 messages at the 4 KiB
/// text cap, well inside the default 500-entry history.
fn readLog(base: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, state_dir: []const u8, cfg: *const config_mod.Config) ![]u8 {
    const path = try subPath(arena, state_dir, log_path);
    return base.readFileAlloc(io, path, arena, .limited(logReadCap(cfg.chatrooms.max_history)));
}

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

/// Newest activity first. The underlying string map iterates in insertion
/// order, which for an append-only JSONL log is oldest room first; callers
/// documented listRooms as newest-first, so sort the enriched rows before
/// returning them.
fn roomInfoLessThan(_: void, a: RoomInfo, b: RoomInfo) bool {
    if (a.last_ts != b.last_ts) return a.last_ts > b.last_ts;
    return std.mem.lessThan(u8, a.room, b.room);
}

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

/// [chatrooms].rooms come from config.toml, which is operator-authored and not
/// checked by the TOML parser beyond shape. An empty name has no room to
/// subscribe to, and a duplicate name creates duplicate delivery paths when
/// the room list is folded into chatroom operations. Reject both in
/// `subscribedRooms`, where config defaults first meet runtime overrides.
fn validateConfiguredRooms(rooms: []const []const u8) !void {
    for (rooms, 0..) |room, i| {
        if (room.len == 0) return error.EmptyRoomName;
        for (rooms[0..i]) |prev| {
            if (std.mem.eql(u8, prev, room)) return error.DuplicateRoomName;
        }
    }
}

// ------------------------------------------------------------------ reading --

/// Rooms this instance subscribes to: config defaults minus the runtime
/// "unsubscribed" set, plus the runtime "rooms" overrides from
/// state/<sub_path>. Arena-owned.
pub fn subscribedRooms(base: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, state_dir: []const u8, cfg: *const config_mod.Config) ![][]const u8 {
    try validateConfiguredRooms(cfg.chatrooms.rooms);
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
pub fn readHistory(base: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, state_dir: []const u8, cfg: *const config_mod.Config, room: []const u8, after: i64, limit: usize) ![]Message {
    const raw = readLog(base, io, arena, state_dir, cfg) catch return &[_]Message{};
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
pub fn readHistoryAsc(base: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, state_dir: []const u8, cfg: *const config_mod.Config, room: []const u8, after: i64, limit: usize) !AscPage {
    const raw = readLog(base, io, arena, state_dir, cfg) catch return .{};
    if (limit == 0) return .{};
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
pub fn listRooms(base: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, state_dir: []const u8, cfg: *const config_mod.Config) ![]RoomInfo {
    const raw = readLog(base, io, arena, state_dir, cfg) catch return &[_]RoomInfo{};
    // Folded line by line through a scratch arena rather than parsed into
    // `arena`: the answer is one row per room, but the log holds up to
    // `max_history` messages at `max_text_len` each (~5 MiB at the defaults),
    // and every parsed message -- reaction arrays included -- used to stay
    // live in a request-scoped arena until the request ended. Only a room's
    // own strings are copied out, and only when they are the ones kept.
    var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    var by_room: std.StringArrayHashMapUnmanaged(RoomInfo) = .empty;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        defer _ = scratch_state.reset(.retain_capacity);
        const m = std.json.parseFromSliceLeaky(Message, scratch, line, .{ .ignore_unknown_fields = true }) catch continue;
        const gop = try by_room.getOrPut(arena, m.room);
        if (!gop.found_existing) {
            // `m.room` lives in `scratch`, which is about to be reset, but a
            // room survives the loop and owns both the key and its copy.
            const room = try arena.dupe(u8, m.room);
            gop.key_ptr.* = room;
            gop.value_ptr.* = .{ .room = room, .messages = 0 };
        }
        gop.value_ptr.messages += 1;
        if (m.ts >= gop.value_ptr.last_ts) {
            gop.value_ptr.last_ts = m.ts;
            gop.value_ptr.last_from = try arena.dupe(u8, m.from);
            gop.value_ptr.last_text = try arena.dupe(u8, utf8.cap(m.text, last_text_preview_bytes));
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
    std.mem.sort(RoomInfo, out, {}, roomInfoLessThan);
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
    return appendInner(base, io, gpa, arena, state_dir, cfg, msg, true);
}

/// Same as `append`, but for a message this process generated itself
/// (`sendMessageOpts`): the id comes from `makeId` (pid + monotonic counter),
/// so it cannot already exist in the log, and skipping the dedup scan avoids
/// JSON-parsing up to `max_history` lines of the retained window on every
/// local send. Wire-delivered messages keep going through `append` (and its
/// dedup), because a redelivery can repeat an id another process appended.
pub fn appendLocal(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, cfg: *const config_mod.Config, msg: Message) !void {
    return appendInner(base, io, gpa, arena, state_dir, cfg, msg, false);
}

fn appendInner(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, cfg: *const config_mod.Config, msg: Message, dedup: bool) !void {
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

    const maybe_existing = base.readFileAlloc(io, path, gpa, .limited(logReadCap(cfg.chatrooms.max_history))) catch |err| switch (err) {
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
    if (dedup and msg.id.len > 0) {
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
    // Owner-only: the chat log holds room messages between peers.
    try atomic_write.writeFilePerms(io, base, path, out_list.items, atomic_write.private_file);
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
/// recent redelivery) after checking only a few lines.
///
/// A line is only JSON-parsed when it plausibly carries the id: an exact
/// `"id":"<id>"` field pattern must be present first. `makeId` ids are
/// `m<ts>-<pid>-<seq>` — digits, letters, hyphens — which JSON never escapes,
/// so the byte pattern is exact for them. A match inside message *content*
/// (someone types `{"id":"x"}`) still falls through to the real parse and is
/// rejected by the `m.id` comparison, so a false byte match cannot drop a
/// legitimate message; it only costs one extra parse.
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
        checked += 1;
        // The field pattern is exact (the quotes and colon are JSON syntax, so
        // no unescaped sequence in a JSON string value can contain it), and
        // without it the line cannot be the message we are looking for. `id`
        // serializes after `room`/`from`/`text`, which may themselves contain
        // the pattern, so every occurrence is examined; a byte match only
        // gates the parse, the `m.id` comparison below is the final word.
        const needle = "\"id\":\"";
        var search_from: usize = 0;
        var plausibly_ours = false;
        while (std.mem.indexOf(u8, line[search_from..], needle)) |rel| {
            const k = search_from + rel;
            const after = line[k + needle.len ..];
            // `after.len > id.len` is the bounds guard for the `after[id.len]`
            // quote probe: `startsWith` already implies `>=`, so equality (a
            // line truncated right after the id chars) must not index.
            if (after.len > id.len and std.mem.startsWith(u8, after, id) and after[id.len] == '"') {
                plausibly_ours = true;
                break;
            }
            search_from = k + needle.len;
        }
        if (!plausibly_ours) continue;
        const m = std.json.parseFromSliceLeaky(Message, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        if (std.mem.eql(u8, m.id, id)) return true;
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
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    var s = std.json.Stringify{ .writer = &w.writer, .options = .{ .emit_null_optional_fields = false } };
    try s.write(m);
    try out.appendSlice(gpa, w.written());
    try out.append(gpa, '\n');
}

/// Rewrite the entire log after mutations have been applied in-place.
fn rewriteLog(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, messages: []const Message) !void {
    const path = try subPath(arena, state_dir, log_path);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(gpa);
    for (messages) |m| try serialiseMessage(m, &out, gpa);
    try atomic_write.writeFilePerms(io, base, path, out.items, atomic_write.private_file);
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
    const lock_path = try subPath(arena, state_dir, lock_file_name);
    const lock = acquireChatroomLock(io, base, lock_path);
    defer if (lock) |f| f.close(io);
    const raw = readLog(base, io, arena, state_dir, cfg) catch return error.NotFound;
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
    const lock_path = try subPath(arena, state_dir, lock_file_name);
    const lock = acquireChatroomLock(io, base, lock_path);
    defer if (lock) |f| f.close(io);
    const raw = readLog(base, io, arena, state_dir, cfg) catch return error.NotFound;
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
    const lock_path = try subPath(arena, state_dir, lock_file_name);
    const lock = acquireChatroomLock(io, base, lock_path);
    defer if (lock) |f| f.close(io);
    const raw = readLog(base, io, arena, state_dir, cfg) catch return error.NotFound;
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

/// Every mutation of `room_meta.json` is read-modify-write: load the whole
/// file, edit one room, write all of it back. That makes a failed *read* a
/// destructive event, not a missing one, so only "no file yet" may become an
/// empty map here. Swallowing every error into `{}` — what this used to do —
/// meant one oversized, truncated, or half-written file turned the next
/// `setTopic`/`togglePin` into a rewrite holding that single room, silently
/// dropping every other room's topic and pins. Callers already report the
/// error (`cli.zig` chat verbs, `ck_chat` in `sandbox/host.zig`), so refusing
/// the write is visible where the loss was not. The read-only listing path in
/// `host.zig` still falls back to an empty map on purpose: it renders topics
/// and never writes.
pub fn loadMeta(base: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, state_dir: []const u8) !std.json.ArrayHashMap(RoomMeta) {
    const path = try metaPath(arena, state_dir);
    const raw = base.readFileAlloc(io, path, arena, .limited(metaReadCap())) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return std.json.parseFromSliceLeaky(
        std.json.ArrayHashMap(RoomMeta),
        arena,
        raw,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
}

fn saveMeta(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, state_dir: []const u8, meta: std.json.ArrayHashMap(RoomMeta)) !void {
    const path = try metaPath(arena, state_dir);
    // Sized by the room count, not by a fixed frame. The 64 KiB stack buffer
    // this replaced put a hard ceiling on the *whole* file: past it every
    // topic and pin write failed `TooLarge` for good, with no way back except
    // editing the file by hand.
    var w: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &w.writer, .options = .{ .emit_null_optional_fields = false } };
    try s.write(meta);
    try atomic_write.writeFilePerms(io, base, path, w.written(), atomic_write.private_file);
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
    // Drop oldest past the cap rather than refusing the pin: the log the ids
    // point into is itself trimmed to `max_history`, so the oldest pins are
    // the ones already most likely to name a message that no longer exists.
    const kept = new_pins.items;
    gop.value_ptr.pins = if (kept.len > max_pins_per_room) kept[kept.len - max_pins_per_room ..] else kept;
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
    try appendLocal(base, io, gpa, arena, state_dir, cfg, msg);
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
/// The window is elapsed time, so it is measured on the monotonic clock
/// (`.awake`), not the wall clock: an NTP step or manual clock change must not
/// collapse a down peer's backoff to zero (hammering it) or stretch it by the
/// jump (starving it). The table is process-lifetime state and never crosses a
/// process or machine boundary, so a monotonic basis is safe here.
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
    const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
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

/// Runs the sandboxed `peers` tool with a `chat_fanout` request body and
/// returns its raw JSON output (arena-owned).
///
/// `fanOut` must not import `sandbox/runtime.zig` to get this: the sandbox
/// host imports this module for the `ck_chat` bridge, so a top-level import
/// here would close the `peers <-> sandbox` import cycle. The entry point
/// that owns the runtime (`cli.zig`) injects the runner once at startup,
/// before any message can be sent; `null` means "no runner injected, the
/// message stays local".
pub const PeersRunner = *const fn (
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    cfg: *const config_mod.Config,
    input: []const u8,
) anyerror![]u8;

pub var peers_runner: ?PeersRunner = null;

/// The `chat_fanout` request body for the `peers` tool.
fn encodeFanOut(enc: *std.Io.Writer.Allocating, msg: Message, skip: []const []const u8) !void {
    var s = std.json.Stringify{ .writer = &enc.writer, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("action");
    try s.write("chat_fanout");
    try s.objectField("room");
    try s.write(msg.room);
    try s.objectField("from");
    try s.write(msg.from);
    try s.objectField("text");
    try s.write(msg.text);
    try s.objectField("ts");
    try s.print("{d}", .{msg.ts});
    try s.objectField("id");
    try s.write(msg.id);
    if (msg.thread_ts) |tts| {
        try s.objectField("thread_ts");
        try s.write(tts);
    }
    try s.objectField("skip");
    try s.write(skip);
    try s.endObject();
}

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
    // One `catch` for the whole encode: bailing out of each step silently left
    // the message local with nothing said, while every other failure below
    // names itself. Nothing here can fail except allocation.
    encodeFanOut(&enc, msg, skip.items) catch |err| {
        log.log(.error_, "chat fan-out: could not encode message {s}: {s}", .{ msg.id, @errorName(err) });
        return;
    };
    const input = enc.written();

    const runner = peers_runner orelse {
        // Only cli.zig injects the runner (at startup). A miss means no
        // entry point ever did, and the message stays local — logged as an
        // error because a deployed mesh cannot see a silent non-delivery.
        log.log(.error_, "chat fan-out: 'peers' tool runner not injected; message stays local", .{});
        return;
    };
    const raw = runner(io, gpa, arena, environ_map, cfg, input) catch |err| {
        log.log(.error_, "chat fan-out: 'peers' tool failed: {s}", .{@errorName(err)});
        return;
    };

    const reply = std.json.parseFromSliceLeaky(FanOutReply, arena, raw, .{ .ignore_unknown_fields = true }) catch {
        log.log(.error_, "chat fan-out: the tool answered something that is not JSON", .{});
        return;
    };
    if (!reply.ok) {
        log.log(.error_, "chat fan-out: {s}", .{reply.@"error" orelse "unknown error"});
        return;
    }

    const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
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
    try atomic_write.writeFilePerms(io, base, path, buf[0..w.end], atomic_write.private_file);
    log.log(.info, "chat: subscribed to '{s}' = {any}", .{ room, on });
}

// ------------------------------------------------------------- agent inbox --

/// Oldest-first messages after `cursor`, capped. Returning the oldest pending
/// batch is essential: advancing a cursor after a newest-first capped batch
/// permanently skipped every older pending message.
pub fn readNew(base: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, state_dir: []const u8, cfg: *const config_mod.Config, cursor: Cursor) ![]Message {
    const raw = readLog(base, io, arena, state_dir, cfg) catch return &[_]Message{};
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
    atomic_write.writeFilePerms(io, base, path, body, atomic_write.private_file) catch return;
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
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    var cfg = config_mod.Config{};
    cfg.instance.name = "test-clanker";
    cfg.chatrooms.on = true;
    cfg.chatrooms.rooms = &.{"dev"};
    cfg.chatrooms.max_history = 100;

    const m1 = Message{ .room = "dev", .from = "test-clanker", .text = "hello world", .ts = 1000, .id = "m1" };
    try append(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, m1);
    const m2 = Message{ .room = "dev", .from = "other", .text = "hi back", .ts = 1001, .id = "m2" };
    try append(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, m2);

    const hist = try readHistory(env.tmp.dir, io, arena, "", &cfg, "dev", 0, 50);
    try std.testing.expectEqual(@as(usize, 2), hist.len);
    try std.testing.expectEqualStrings("hi back", hist[0].text); // newest first
    try std.testing.expectEqualStrings("hello world", hist[1].text);

    const after = try readHistory(env.tmp.dir, io, arena, "", &cfg, "dev", 1000, 50);
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqualStrings("hi back", after[0].text);

    const rooms = try listRooms(env.tmp.dir, io, arena, "", &cfg);
    try std.testing.expectEqual(@as(usize, 1), rooms.len);
    try std.testing.expectEqualStrings("dev", rooms[0].room);
    try std.testing.expectEqual(@as(usize, 2), rooms[0].messages);
    try std.testing.expectEqualStrings("other", rooms[0].last_from);

    const fresh = try readNew(env.tmp.dir, io, arena, "", &cfg, .{ .ts = 1000 });
    try std.testing.expectEqual(@as(usize, 1), fresh.len);
}

test "append dedups a redelivered id even when an older text holds the id byte pattern" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    var cfg = config_mod.Config{};
    cfg.instance.name = "test-clanker";
    cfg.chatrooms.on = true;
    cfg.chatrooms.rooms = &.{"dev"};
    cfg.chatrooms.max_history = 100;

    // The first message's text contains the exact `"id":"m42"` field pattern:
    // the byte prefilter in `hasMessageId` must not stop at that false match
    // and miss the real `id` field of the later redelivery.
    try append(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, .{
        .room = "dev",
        .from = "a",
        .text = "look: \"id\":\"m42\"",
        .ts = 1,
        .id = "m1",
    });
    try append(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, .{
        .room = "dev",
        .from = "b",
        .text = "real",
        .ts = 2,
        .id = "m42",
    });
    // Redelivery of m42: dropped despite the false byte pattern in m1's text.
    try append(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, .{
        .room = "dev",
        .from = "b",
        .text = "real again",
        .ts = 3,
        .id = "m42",
    });
    const raw = try env.tmp.dir.readFileAlloc(io, log_path, std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, raw, "\"id\":\"m42\""));
}

test "hasMessageId survives a line truncated right after the id bytes" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const arena = env.arena();

    // A log line cut off exactly after the id's last byte (no closing quote,
    // no trailing fields) used to index one past the slice end in the byte
    // prefilter; it must read as "not ours" rather than fault.
    const raw = "{\"room\":\"dev\",\"from\":\"a\",\"text\":\"x\",\"id\":\"m42";
    try std.testing.expect(!hasMessageId(arena, raw, "m42", 100));
    // A longer id in a truncated line still probes the byte after the id,
    // which is a digit here, not a quote.
    try std.testing.expect(!hasMessageId(arena, raw, "m4", 100));
}

test "appendLocal skips dedup while append keeps it" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    var cfg = config_mod.Config{};
    cfg.instance.name = "test-clanker";
    cfg.chatrooms.on = true;
    cfg.chatrooms.rooms = &.{"dev"};
    cfg.chatrooms.max_history = 100;

    // A locally generated id (the path `sendMessageOpts` takes) is unique by
    // construction, so appendLocal writes it twice without a dedup scan.
    const m = Message{ .room = "dev", .from = "test-clanker", .text = "hello", .ts = 1, .id = "m1-2-1" };
    try appendLocal(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, m);
    try appendLocal(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, m);
    // A redelivery of the same id through the wire path must still dedup.
    try append(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, m);

    const hist = try readHistory(env.tmp.dir, io, arena, "", &cfg, "dev", 0, 50);
    try std.testing.expectEqual(@as(usize, 2), hist.len);
    try std.testing.expectEqualStrings("hello", hist[0].text);
    try std.testing.expectEqualStrings("hello", hist[1].text);
}

test "append trims to max_history and keeps the newest lines" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

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
        try append(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, .{
            .room = "dev",
            .from = "test-clanker",
            .text = try std.fmt.allocPrint(arena, "line {d}", .{i}),
            .ts = @as(i64, @intCast(i)),
            .id = try std.fmt.allocPrint(arena, "m{d}", .{i}),
        });
    }

    // Only the newest 3 survive, oldest dropped first.
    const hist = try readHistory(env.tmp.dir, io, arena, "", &cfg, "dev", 0, 50);
    try std.testing.expectEqual(@as(usize, 3), hist.len);
    try std.testing.expectEqualStrings("line 5", hist[0].text); // newest first
    try std.testing.expectEqualStrings("line 4", hist[1].text);
    try std.testing.expectEqualStrings("line 3", hist[2].text);

    // The trimmed log must still be a valid, parseable room file.
    const rooms = try listRooms(env.tmp.dir, io, arena, "", &cfg);
    try std.testing.expectEqual(@as(usize, 1), rooms.len);
    try std.testing.expectEqual(@as(usize, 3), rooms[0].messages);
}

test "append still trims and dedups when the retained window exceeds 1 MiB" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    var cfg = config_mod.Config{};
    cfg.chatrooms.on = true;
    cfg.chatrooms.rooms = &.{"dev"};
    cfg.chatrooms.max_history = 256;

    // 4 KiB texts (the send cap) are the worst the system writes: 256 of
    // them already exceed the old fixed 1 MiB read cap, so the append read
    // truncated, the line count under-counted, the trim never ran, and the
    // log grew without bound past max_history.
    const text = "x" ** 4096;
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        try append(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, .{
            .room = "dev",
            .from = "test-clanker",
            .text = text,
            .ts = @as(i64, @intCast(i + 1)),
            .id = try std.fmt.allocPrint(arena, "m{d}", .{i}),
        });
    }

    // Only the newest 256 of 300 survive, and the oldest surviving line is
    // m44 (m0..m43 were trimmed). The log is ~1.1 MiB, past the old cap.
    const raw = try env.tmp.dir.readFileAlloc(io, log_path, std.testing.allocator, .limited(4 * 1024 * 1024));
    defer std.testing.allocator.free(raw);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(std.testing.allocator);
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0) continue;
        try lines.append(std.testing.allocator, ln);
    }
    try std.testing.expectEqual(@as(usize, 256), lines.items.len);
    try std.testing.expect(std.mem.find(u8, lines.items[0], "\"id\":\"m44\"") != null);
    try std.testing.expect(std.mem.find(u8, lines.items[255], "\"id\":\"m299\"") != null);

    // A redelivery of the newest message (a retry of a just-appended one)
    // must dedup even though its line sits at the end of a > 1 MiB log. The
    // old scan walked the tail of the truncated 1 MiB prefix -- the middle
    // of the file -- and appended a duplicate.
    try append(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, .{
        .room = "dev",
        .from = "test-clanker",
        .text = text,
        .ts = 999,
        .id = "m299",
    });
    const raw2 = try env.tmp.dir.readFileAlloc(io, log_path, std.testing.allocator, .limited(4 * 1024 * 1024));
    defer std.testing.allocator.free(raw2);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, raw2, "\"id\":\"m299\""));

    // Every reader of the same log must be capped the same way the writer
    // trims it. `readFileAlloc` answers `error.StreamTooLong` rather than a
    // short read, and each of these turns that into an empty result, so the
    // fixed 1 MiB cap they used to carry silently emptied the agent inbox,
    // the board fold and the room list on any room this size.
    const hist = try readHistory(env.tmp.dir, io, arena, "", &cfg, "dev", 0, 5);
    try std.testing.expectEqual(@as(usize, 5), hist.len);
    const asc = try readHistoryAsc(env.tmp.dir, io, arena, "", &cfg, "dev", 0, 5);
    try std.testing.expectEqual(@as(usize, 5), asc.msgs.len);
    const fresh = try readNew(env.tmp.dir, io, arena, "", &cfg, .{ .id = "m290" });
    try std.testing.expectEqual(@as(usize, inbox_limit), fresh.len);
    const rooms = try listRooms(env.tmp.dir, io, arena, "", &cfg);
    try std.testing.expectEqual(@as(usize, 1), rooms.len);
    try std.testing.expectEqual(@as(usize, 256), rooms[0].messages);
}

test "readHistoryAsc pages oldest-first and extends through a shared boundary timestamp" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

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
        try append(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, .{ .room = "board", .from = "t", .text = "x", .ts = sp.ts, .id = sp.id });
    }
    try append(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, .{ .room = "dev", .from = "t", .text = "x", .ts = 2, .id = "zz" });

    // limit 2 cuts inside the ts=2 group: the page must extend through it
    // (4 messages: ts 1, 2, 2, 2), or the caller's next `after` cursor of 2
    // would skip the group's remainder.
    const p1 = try readHistoryAsc(env.tmp.dir, io, arena, "", &cfg, "board", 0, 2);
    try std.testing.expectEqual(@as(usize, 4), p1.msgs.len);
    try std.testing.expect(p1.has_more);
    try std.testing.expectEqualStrings("a", p1.msgs[0].id);
    try std.testing.expectEqualStrings("b", p1.msgs[1].id); // ties break by id
    try std.testing.expectEqualStrings("d", p1.msgs[3].id);

    // The next page picks up exactly where the cursor points.
    const p2 = try readHistoryAsc(env.tmp.dir, io, arena, "", &cfg, "board", 2, 2);
    try std.testing.expectEqual(@as(usize, 2), p2.msgs.len);
    try std.testing.expect(!p2.has_more);
    try std.testing.expectEqualStrings("e", p2.msgs[0].id);
    try std.testing.expectEqualStrings("f", p2.msgs[1].id);

    // A page that fits under the limit reports no more and stays ascending.
    const all = try readHistoryAsc(env.tmp.dir, io, arena, "", &cfg, "board", 0, 50);
    try std.testing.expectEqual(@as(usize, 6), all.msgs.len);
    try std.testing.expect(!all.has_more);

    // A zero limit is an empty page, not an underflow on `limit - 1`.
    const none = try readHistoryAsc(env.tmp.dir, io, arena, "", &cfg, "board", 0, 0);
    try std.testing.expectEqual(@as(usize, 0), none.msgs.len);
    try std.testing.expect(!none.has_more);
}

test "inbox cursor drains a capped same-timestamp burst without loss" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    var cfg = config_mod.Config{};
    cfg.chatrooms.max_history = 100;

    var i: usize = 0;
    while (i < inbox_limit + 2) : (i += 1) {
        const id = try std.fmt.allocPrint(arena, "burst-{d}", .{i});
        try append(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, .{
            .room = "dev",
            .from = "peer",
            .text = "burst",
            .ts = 1000,
            .id = id,
        });
    }

    const first = try readNew(env.tmp.dir, io, arena, "", &cfg, .{});
    try std.testing.expectEqual(@as(usize, inbox_limit), first.len);
    try std.testing.expectEqualStrings("burst-0", first[0].id);
    const second = try readNew(env.tmp.dir, io, arena, "", &cfg, .{
        .id = first[first.len - 1].id,
        .ts = first[first.len - 1].ts,
    });
    try std.testing.expectEqual(@as(usize, 2), second.len);
    try std.testing.expectEqualStrings("burst-5", second[0].id);
    try std.testing.expectEqualStrings("burst-6", second[1].id);
}

test "subscribedRooms rejects empty and duplicate configured rooms" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    var cfg = config_mod.Config{};
    cfg.chatrooms.on = true;

    cfg.chatrooms.rooms = &.{""};
    try std.testing.expectError(error.EmptyRoomName, subscribedRooms(env.tmp.dir, io, arena, "", &cfg));

    cfg.chatrooms.rooms = &.{ "dev", "ops", "dev" };
    try std.testing.expectError(error.DuplicateRoomName, subscribedRooms(env.tmp.dir, io, arena, "", &cfg));

    cfg.chatrooms.rooms = &.{ "dev", "ops" };
    const rooms = try subscribedRooms(env.tmp.dir, io, arena, "", &cfg);
    try std.testing.expectEqual(@as(usize, 2), rooms.len);
}

test "subscribe on/off round-trip" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    var cfg = config_mod.Config{};
    cfg.chatrooms.on = true;
    cfg.chatrooms.rooms = &.{"dev"};

    try subscribe(env.tmp.dir, io, std.testing.allocator, arena, "", "ops", true);
    const rooms = try subscribedRooms(env.tmp.dir, io, arena, "", &cfg);
    try std.testing.expectEqual(@as(usize, 2), rooms.len);
    try std.testing.expect(isSubscribed(env.tmp.dir, io, arena, "", &cfg, "ops"));

    try subscribe(env.tmp.dir, io, std.testing.allocator, arena, "", "dev", false);
    const rooms2 = try subscribedRooms(env.tmp.dir, io, arena, "", &cfg);
    try std.testing.expectEqual(@as(usize, 1), rooms2.len);
    try std.testing.expectEqualStrings("ops", rooms2[0]);
}

test "subscribe does not overwrite malformed state" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    const malformed = "{not-json";
    try env.tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = malformed });
    try std.testing.expectError(error.InvalidSubscriptionState, subscribe(env.tmp.dir, io, std.testing.allocator, arena, "", "ops", true));
    const preserved = try env.tmp.dir.readFileAlloc(io, sub_path, arena, .limited(1024));
    try std.testing.expectEqualStrings(malformed, preserved);
}

test "meta ops with empty state_dir stay in the working directory" {
    // metaPath used to build "/room_meta.json" for state_dir == "", which
    // openat resolves at the filesystem root. The module's contract is that
    // every state file lives under base + state_dir, and "" means cwd.
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    try setTopic(env.tmp.dir, io, std.testing.allocator, arena, "", "dev", "topic");
    const topic = try getTopic(env.tmp.dir, io, arena, "", "dev");
    try std.testing.expectEqualStrings("topic", topic.?);

    // The meta file must exist under the base dir, never at "/room_meta.json".
    try env.tmp.dir.access(io, "room_meta.json", .{});
    const pinned = try togglePin(env.tmp.dir, io, std.testing.allocator, arena, "", "dev", "m1");
    try std.testing.expect(pinned);
    const pins = try getPins(env.tmp.dir, io, arena, "", "dev");
    try std.testing.expectEqual(@as(usize, 1), pins.?.len);
}

test "receive filters by subscription" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    var cfg = config_mod.Config{};
    cfg.chatrooms.on = true;
    cfg.chatrooms.rooms = &.{"dev"};

    const in_room = Message{ .room = "dev", .from = "peer", .text = "hi", .ts = 1, .id = "a" };
    try std.testing.expect(try receive(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, in_room));
    const out_room = Message{ .room = "other", .from = "peer", .text = "hi", .ts = 2, .id = "b" };
    try std.testing.expect(!try receive(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, out_room));

    const hist = try readHistory(env.tmp.dir, io, arena, "", &cfg, "other", 0, 10);
    try std.testing.expectEqual(@as(usize, 0), hist.len);
}

test "receive ignores a redelivered message id" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    var cfg = config_mod.Config{};
    cfg.chatrooms.on = true;
    cfg.chatrooms.rooms = &.{"dev"};

    const msg = Message{ .room = "dev", .from = "peer", .text = "hi", .ts = 1, .id = "dup-1" };
    try std.testing.expect(try receive(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, msg));
    // Redelivered (e.g. the sender retried after losing the response): same
    // state as running once, not a second entry.
    try std.testing.expect(try receive(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, msg));

    const hist = try readHistory(env.tmp.dir, io, arena, "", &cfg, "dev", 0, 10);
    try std.testing.expectEqual(@as(usize, 1), hist.len);

    // An id-less message (an old peer that never sent one) is never deduped.
    const no_id = Message{ .room = "dev", .from = "peer", .text = "no id here", .ts = 2, .id = "" };
    try std.testing.expect(try receive(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, no_id));
    try std.testing.expect(try receive(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, no_id));
    const hist2 = try readHistory(env.tmp.dir, io, arena, "", &cfg, "dev", 0, 10);
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

    const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
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

    const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
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

    const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
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
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    var cfg = config_mod.Config{};
    cfg.instance.name = "alice";
    cfg.chatrooms.on = true;
    cfg.chatrooms.rooms = &.{"dev"};
    cfg.chatrooms.max_history = 100;

    try append(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, .{
        .room = "dev",
        .from = "alice",
        .text = "mine",
        .ts = 1,
        .id = "m1",
    });

    try std.testing.expectError(error.NotFound, editMessage(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, "nope", "x", "alice"));
    try std.testing.expectError(error.NotOwner, editMessage(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, "m1", "x", "bob"));
    const edited = try editMessage(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, "m1", "updated", "alice");
    try std.testing.expectEqualStrings("updated", edited.text);

    try std.testing.expectError(error.NotFound, toggleReaction(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, "nope", "👍", "alice"));
    try std.testing.expect(try toggleReaction(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, "m1", "👍", "alice"));

    try std.testing.expectError(error.NotFound, deleteMessage(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, "nope", "alice"));
    try std.testing.expectError(error.NotOwner, deleteMessage(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, "m1", "bob"));
    try deleteMessage(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, "m1", "alice");
}

test "an unreadable room_meta.json refuses the write instead of erasing the other rooms" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    // Two rooms with metadata, then the file is corrupted under us.
    try setTopic(env.tmp.dir, io, std.testing.allocator, arena, "", "dev", "shipping");
    try setTopic(env.tmp.dir, io, std.testing.allocator, arena, "", "ops", "on call");
    try env.tmp.dir.writeFile(io, .{ .sub_path = "room_meta.json", .data = "{not json" });

    // Metadata mutation is read-modify-write, so a failed read must not become
    // an empty map: that rewrites the file with only the room being edited.
    try std.testing.expectError(
        error.SyntaxError,
        setTopic(env.tmp.dir, io, std.testing.allocator, arena, "", "dev", "clobbered"),
    );
    const after = try env.tmp.dir.readFileAlloc(io, "room_meta.json", arena, .limited(4096));
    try std.testing.expectEqualStrings("{not json", after);
}

test "pins stay bounded and a missing meta file is not an error" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    // No file yet is the one read failure that legitimately means "empty".
    try std.testing.expectEqual(@as(?[]const []const u8, null), try getPins(env.tmp.dir, io, arena, "", "dev"));

    var i: usize = 0;
    while (i < max_pins_per_room + 5) : (i += 1) {
        _ = try togglePin(env.tmp.dir, io, std.testing.allocator, arena, "", "dev", try std.fmt.allocPrint(arena, "m{d}", .{i}));
    }
    const pins = (try getPins(env.tmp.dir, io, arena, "", "dev")).?;
    try std.testing.expectEqual(max_pins_per_room, pins.len);
    // Oldest dropped, newest kept.
    try std.testing.expectEqualStrings("m5", pins[0]);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "m{d}", .{max_pins_per_room + 4}), pins[pins.len - 1]);
}

test "serialiseMessage scales past the former 64 KiB stack buffer" {
    const gpa = std.testing.allocator;
    const reaction_count: usize = 4000;
    const reactions = try gpa.alloc(Reaction, reaction_count);
    defer gpa.free(reactions);
    for (reactions) |*r| {
        r.* = .{ .emoji = "👍", .from = "peer" };
    }

    const msg = Message{
        .room = "dev",
        .from = "tester",
        .text = "x",
        .ts = 1,
        .id = "m1",
        .reactions = reactions,
    };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(gpa);
    try serialiseMessage(msg, &out, gpa);
    try std.testing.expect(out.items.len > 64 * 1024);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.items[0 .. out.items.len - 1], .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, reaction_count), parsed.value.object.get("reactions").?.array.items.len);
}
test "listRooms orders rooms newest-first by last activity" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    var cfg = config_mod.Config{};
    cfg.instance.name = "test-clanker";
    cfg.chatrooms.on = true;
    cfg.chatrooms.max_history = 100;

    // Appended in chronological order. Without the sort, listRooms returns
    // hash-map insertion order (oldest room first), contradicting its
    // "newest-first by last activity" contract.
    try append(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, .{
        .room = "dev",
        .from = "a",
        .text = "old dev",
        .ts = 1000,
        .id = "m1",
    });
    try append(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, .{
        .room = "ops",
        .from = "b",
        .text = "latest ops",
        .ts = 5000,
        .id = "m2",
    });
    try append(env.tmp.dir, io, std.testing.allocator, arena, "", &cfg, .{
        .room = "dev",
        .from = "a",
        .text = "newer dev",
        .ts = 3000,
        .id = "m3",
    });

    const rooms = try listRooms(env.tmp.dir, io, arena, "", &cfg);
    try std.testing.expectEqual(@as(usize, 2), rooms.len);
    try std.testing.expectEqualStrings("ops", rooms[0].room);
    try std.testing.expectEqualStrings("dev", rooms[1].room);
}
