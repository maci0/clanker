//! Persistent session store: serializes conversations to
//! `state/sessions/<id>.json` under an arbitrary base directory.

const std = @import("std");
const json = std.json;
const types = @import("../llm/types.zig");
const atomic_write = @import("../util/atomic_write.zig");
const ensure_dir = @import("../util/ensure_dir.zig");
const test_env = @import("../util/test_env.zig");
const utf8 = @import("../util/utf8.zig");

pub const Session = struct {
    id: []const u8,
    title: []const u8,
    messages: []const types.Message,
    created: i64,
    updated: i64,
    /// Which workspace this conversation belongs to. The id of a row in
    /// `state/workspaces.json`, or a leftover label from before folders were
    /// registered. "" is the default workspace (the serve cwd).
    workspace: []const u8 = "",
    /// Whether this chat is archived / hidden from the default listing.
    /// False absences still decode as false, so pre-archive sessions need no migration.
    archived: bool = false,
};

const store_dir = "state/sessions";

/// Session ids are path fragments, not arbitrary labels. Enforce the storage
/// boundary here even when a caller forgets its own input validation.
pub fn validSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

/// Writes a session to `base_dir/state/sessions/<id>.json`.
pub fn saveSession(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, session: Session) !void {
    if (!validSessionId(session.id)) return error.InvalidSessionId;
    try ensure_dir.ensureDir(base, io, store_dir);

    // Grows to fit the conversation rather than a fixed cap: a fixed buffer
    // silently failed (and callers `catch {}`'d the failure away) once a
    // long-context model's history crossed it, so the session simply stopped
    // being saved with no visible error.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var s = json.Stringify{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };

    // The transcript is parsed back as UTF-8 JSON on load (std.json rejects
    // invalid UTF-8 in strings with SyntaxError), but the writer passes bytes
    // >= 0x80 through verbatim. A single non-UTF-8 byte in any untrusted text
    // field (argv, pasted input, subprocess output) used to make the file
    // unloadable, and listings silently dropped it. Sanitize at the write
    // boundary so what we store is what the reader can read; the valid
    // fast path is a validation pass, no copy.
    const clean_title = try utf8.sanitize(arena, session.title);

    try s.beginObject();
    try s.objectField("id");
    try s.write(session.id);
    try s.objectField("title");
    try s.write(clean_title);
    try s.objectField("created");
    try s.write(session.created);
    try s.objectField("updated");
    try s.write(session.updated);
    if (session.workspace.len > 0) {
        try s.objectField("workspace");
        try s.write(session.workspace);
    }
    if (session.archived) {
        try s.objectField("archived");
        try s.write(true);
    }
    // Listing fields sit in front of the transcript so a picker can score a
    // row from the first few kilobytes. Without them every GET /api/sessions
    // parsed every message of every conversation (each file up to 16 MiB).
    try s.objectField("message_count");
    try s.write(session.messages.len);
    try s.objectField("bytes");
    try s.write(transcriptBytes(session.messages));
    try s.objectField("messages");
    try s.beginArray();
    for (session.messages) |m| {
        try s.beginObject();
        try s.objectField("role");
        try s.write(m.role.asStr());
        if (m.content) |c| {
            try s.objectField("content");
            try s.write(try utf8.sanitize(arena, c));
        }
        // Attachments are model-visible input, so they belong in the log the
        // next request is derived from. Dropping them here let `--continue`
        // and `forkSession` resend "what is in this picture?" with no picture
        // and no error. ponytail: base64 inline, same shape as the wire; the
        // ceiling is that every turn rewrites the whole transcript, so a
        // 4-image conversation re-serializes ~21 MB per save. Move the parts
        // to a content-addressed sidecar under `state/sessions/<id>.files/`
        // if that latency ever shows up.
        if (m.images) |imgs| {
            if (imgs.len > 0) {
                try s.objectField("images");
                try s.beginArray();
                for (imgs) |img| {
                    try s.beginObject();
                    try s.objectField("mime");
                    try s.write(img.mime);
                    try s.objectField("b64");
                    try s.write(img.b64);
                    try s.endObject();
                }
                try s.endArray();
            }
        }
        if (m.tool_calls) |calls| {
            try s.objectField("tool_calls");
            try s.beginArray();
            for (calls) |tc| {
                try s.beginObject();
                try s.objectField("id");
                try s.write(try utf8.sanitize(arena, tc.id));
                try s.objectField("name");
                try s.write(try utf8.sanitize(arena, tc.name));
                try s.objectField("arguments");
                try s.write(try utf8.sanitize(arena, tc.arguments));
                try s.endObject();
            }
            try s.endArray();
        }
        if (m.tool_call_id) |tid| {
            try s.objectField("tool_call_id");
            try s.write(try utf8.sanitize(arena, tid));
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();

    const path = try std.fmt.allocPrint(gpa, "{s}/{s}.json", .{ store_dir, session.id });
    defer gpa.free(path);
    // Atomic: a reader (including this same process resuming after a
    // hot-reload restart) must never observe a session file truncated
    // mid-write.
    // Owner-only: the transcript holds the user's prompts and model replies;
    // the default mode left it world-readable for any other local user.
    try atomic_write.writeFilePerms(io, base, path, out.written(), atomic_write.private_file);
}

const StoredToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

const StoredImage = struct {
    mime: []const u8,
    b64: []const u8,
};

pub const StoredMessage = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    /// Absent on every session written before attachments were persisted, so
    /// an old transcript still decodes; it just has nothing to restore.
    images: ?[]const StoredImage = null,
    tool_calls: ?[]const StoredToolCall = null,
    tool_call_id: ?[]const u8 = null,
};

pub const StoredSession = struct {
    id: []const u8,
    title: []const u8,
    created: i64,
    updated: i64,
    workspace: []const u8 = "",
    archived: bool = false,
    messages: []const StoredMessage = &.{},
};

/// Loads a session from `base_dir/state/sessions/<id>.json`.
pub fn loadSession(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, id: []const u8) !Session {
    _ = gpa;
    if (!validSessionId(id)) return error.InvalidSessionId;
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ store_dir, id });
    // 64 MiB, not 16: four max-size attachments (4 MB each, `max_run_images`
    // in cli.zig) base64-expand to ~21 MB on their own, so a cap sized for
    // text alone would refuse to load the very sessions that now round-trip.
    const raw = try base.readFileAlloc(io, path, arena, .limited(1 << 26));
    const stored = try json.parseFromSliceLeaky(StoredSession, arena, raw, .{ .ignore_unknown_fields = true });

    var messages: std.ArrayList(types.Message) = .empty;
    for (stored.messages) |sm| {
        var msg = types.Message{
            .role = try roleFromStr(sm.role),
            .content = sm.content,
            .tool_call_id = sm.tool_call_id,
        };
        if (sm.images) |imgs| {
            if (imgs.len > 0) {
                var img_list: std.ArrayList(types.ImagePart) = .empty;
                for (imgs) |img| try img_list.append(arena, .{ .mime = img.mime, .b64 = img.b64 });
                msg.images = try img_list.toOwnedSlice(arena);
            }
        }
        if (sm.tool_calls) |calls| {
            var tc_list: std.ArrayList(types.ToolCall) = .empty;
            for (calls) |tc| try tc_list.append(arena, .{ .id = tc.id, .name = tc.name, .arguments = tc.arguments });
            msg.tool_calls = try tc_list.toOwnedSlice(arena);
        }
        try messages.append(arena, msg);
    }

    return .{
        .id = stored.id,
        .title = stored.title,
        .created = stored.created,
        .updated = stored.updated,
        .workspace = stored.workspace,
        .archived = stored.archived,
        .messages = try messages.toOwnedSlice(arena),
    };
}

/// Removes a saved conversation. Its execution graphs stay: they are the
/// record of runs that really happened, and are addressed by run id rather
/// than by session.
pub fn deleteSession(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir, id: []const u8) !void {
    if (!validSessionId(id)) return error.InvalidSessionId;
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ store_dir, id });
    try base.deleteFile(io, path);
}

/// Forks a conversation: the same messages written back under a new id,
/// titled "fork of <old title>". A fork is a branch you can abandon without
/// losing the conversation it came from. Returns the new id (arena-owned).
pub fn forkSession(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, id: []const u8) ![]const u8 {
    if (!validSessionId(id)) return error.InvalidSessionId;
    const s = try loadSession(io, gpa, arena, base, id);
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    // Nanosecond suffix keeps two forks of the same session distinct and
    // stays within the alphanumeric/dash alphabet validSessionId accepts.
    const new_id = try std.fmt.allocPrint(arena, "{s}-fork-{d}", .{ id, std.Io.Timestamp.now(io, .real).nanoseconds });
    try saveSession(io, gpa, arena, base, .{
        .id = new_id,
        .title = try std.fmt.allocPrint(arena, "fork of {s}", .{s.title}),
        .workspace = s.workspace,
        .messages = s.messages,
        .created = now,
        .updated = now,
    });
    return new_id;
}

/// The message index just past turn `n`'s answer: the Nth user message plus
/// everything up to and including the assistant message that completes the
/// turn (tool-call steps and tool results in between included). A turn
/// whose reply is still pending, a stopped run with no final assistant
/// content, cuts before its user message, so a branch never strands half a
/// turn. `n` is 1-based; past the last turn is `error.TurnOutOfRange`.
fn turnCutoff(messages: []const types.Message, n: usize) !usize {
    var users: usize = 0;
    for (messages, 0..) |m, i| {
        if (m.role != .user) continue;
        users += 1;
        if (users != n) continue;
        // End of the turn: the next user message, or the end of the list.
        var j = i + 1;
        while (j < messages.len and messages[j].role != .user) j += 1;
        // The turn's last word is its final assistant message; a pending
        // turn (user with no answer) or a dangling tool round must not leak
        // into the branch, so cut before the user message in those cases.
        var last_assistant: ?usize = null;
        var k = i + 1;
        while (k < j) : (k += 1) {
            if (messages[k].role == .assistant) last_assistant = k;
        }
        if (last_assistant) |p| return p + 1;
        return i;
    }
    return error.TurnOutOfRange;
}

/// Branches a conversation at a turn: the messages through the end of turn
/// `turn_no` copied under a new id, titled "branch of <old title>". Turns
/// before the branch point stay shared context; nothing after it exists in
/// the branch yet, so continuing it explores a different direction without
/// touching the original, the per-turn branch a chat UI offers, as opposed
/// to `forkSession`'s whole-conversation copy. Returns the new id
/// (arena-owned).
pub fn branchSession(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    base: std.Io.Dir,
    id: []const u8,
    turn_no: usize,
) ![]const u8 {
    const s = try loadSession(io, gpa, arena, base, id);
    const cutoff = try turnCutoff(s.messages, turn_no);
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    // Nanosecond suffix keeps two branches of the same session distinct and
    // stays within the alphanumeric/dash alphabet validSessionId accepts.
    const new_id = try std.fmt.allocPrint(arena, "{s}-branch-{d}", .{ id, std.Io.Timestamp.now(io, .real).nanoseconds });
    try saveSession(io, gpa, arena, base, .{
        .id = new_id,
        .title = try std.fmt.allocPrint(arena, "branch of {s}", .{s.title}),
        .workspace = s.workspace,
        .messages = s.messages[0..cutoff],
        .created = now,
        .updated = now,
    });
    return new_id;
}

/// Two or three content words from `task`, for the rail. Skips filler so
/// "please add a websocket for the live map" becomes "add websocket live",
/// not a 60-character prefix of the opening sentence.
pub const title_max = 28;

fn isTitleWordByte(c: u8) bool {
    // Bytes >= 0x80 are (or start) a UTF-8 sequence: treat a run of them as
    // one word, so a non-Latin task ("修复登录 bug") earns a title instead of
    // "(untitled)". ASCII separators still break words inside CJK text that
    // spaces them ("修复 登录").
    if (c >= 0x80) return true;
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '\'';
}

fn isTitleSkip(word: []const u8) bool {
    const map = std.StaticStringMap(void).initComptime(.{
        .{ "a", {} },
        .{ "an", {} },
        .{ "the", {} },
        .{ "to", {} },
        .{ "of", {} },
        .{ "for", {} },
        .{ "and", {} },
        .{ "or", {} },
        .{ "in", {} },
        .{ "on", {} },
        .{ "at", {} },
        .{ "is", {} },
        .{ "are", {} },
        .{ "be", {} },
        .{ "been", {} },
        .{ "being", {} },
        .{ "should", {} },
        .{ "would", {} },
        .{ "could", {} },
        .{ "can", {} },
        .{ "will", {} },
        .{ "just", {} },
        .{ "please", {} },
        .{ "this", {} },
        .{ "that", {} },
        .{ "it", {} },
        .{ "with", {} },
        .{ "from", {} },
        .{ "as", {} },
        .{ "by", {} },
        .{ "if", {} },
        .{ "so", {} },
        .{ "do", {} },
        .{ "does", {} },
        .{ "did", {} },
        .{ "not", {} },
        .{ "no", {} },
        .{ "we", {} },
        .{ "i", {} },
        .{ "you", {} },
        .{ "my", {} },
        .{ "our", {} },
        .{ "me", {} },
        .{ "have", {} },
        .{ "has", {} },
        .{ "had", {} },
        .{ "how", {} },
        .{ "what", {} },
        .{ "when", {} },
        .{ "where", {} },
        .{ "why", {} },
        .{ "also", {} },
        .{ "need", {} },
        .{ "want", {} },
        .{ "make", {} },
        .{ "add", {} },
    });
    var buf: [16]u8 = undefined;
    if (word.len == 0 or word.len > buf.len) return false;
    _ = std.ascii.lowerString(buf[0..word.len], word);
    return map.has(buf[0..word.len]);
}

fn appendTitleWord(out: []u8, used: *usize, word: []const u8) bool {
    if (word.len == 0) return false;
    const need_space: usize = if (used.* > 0) 1 else 0;
    if (used.* + need_space >= out.len) return false;
    if (need_space == 1) {
        out[used.*] = ' ';
        used.* += 1;
    }
    // A multibyte word cut mid-sequence would write invalid UTF-8 into the
    // title; snap the take to a codepoint boundary. ASCII words are unchanged.
    const take = utf8.cap(word, @min(word.len, out.len - used.*)).len;
    if (take == 0) return false;
    @memcpy(out[used.*..][0..take], word[0..take]);
    used.* += take;
    return true;
}

/// Writes a couple-word label into `out`. The return is a prefix of `out`.
pub fn titleFromTask(out: []u8, task: []const u8) []const u8 {
    const cap = @min(out.len, title_max);
    const dest = out[0..cap];
    var used: usize = 0;
    var words: u8 = 0;
    var i: usize = 0;
    while (i < task.len and words < 3 and used < dest.len) {
        while (i < task.len and !isTitleWordByte(task[i])) i += 1;
        const start = i;
        while (i < task.len and isTitleWordByte(task[i])) i += 1;
        const word = task[start..i];
        if (word.len == 0) break;
        if (isTitleSkip(word)) continue;
        if (!appendTitleWord(dest, &used, word)) break;
        words += 1;
    }
    if (words == 0) {
        i = 0;
        while (i < task.len and words < 2 and used < dest.len) {
            while (i < task.len and !isTitleWordByte(task[i])) i += 1;
            const start = i;
            while (i < task.len and isTitleWordByte(task[i])) i += 1;
            const word = task[start..i];
            if (word.len == 0) break;
            if (!appendTitleWord(dest, &used, word)) break;
            words += 1;
        }
    }
    if (used == 0) return "(untitled)";
    return dest[0..used];
}

/// A renamed title, a fork/branch label, or an already-short summary stays.
/// Long auto prefixes (the old first-60-chars titles) are replaced.
pub fn keepTitle(existing: []const u8) bool {
    const t = std.mem.trim(u8, existing, " \t\r\n");
    if (t.len == 0) return false;
    if (std.mem.startsWith(u8, t, "fork of ") or std.mem.startsWith(u8, t, "branch of ")) return true;
    if (t.len > 32) return false;
    var n: u8 = 0;
    var in_word = false;
    for (t) |c| {
        if (c == ' ') {
            in_word = false;
        } else if (!in_word) {
            in_word = true;
            n += 1;
            if (n > 4) return false;
        }
    }
    return true;
}

/// Keep `existing` when it looks chosen; otherwise summarise `task`.
pub fn nextTitle(out: []u8, existing: []const u8, task: []const u8) []const u8 {
    if (keepTitle(existing)) return std.mem.trim(u8, existing, " \t\r\n");
    return titleFromTask(out, task);
}

/// First user line in the transcript, else `task`.
pub fn titleSource(messages: []const types.Message, task: []const u8) []const u8 {
    for (messages) |m| {
        if (m.role != .user) continue;
        if (m.content) |c| {
            const t = std.mem.trim(u8, c, " \t\r\n");
            if (t.len > 0) return t;
        }
    }
    return task;
}

test "titleFromTask is a couple of content words" {
    var buf: [title_max]u8 = undefined;
    try std.testing.expectEqualStrings("left bar chat", titleFromTask(&buf, "left bar chat title should be a couple word summary of the chat"));
    try std.testing.expectEqualStrings("Implement remaining clanker", titleFromTask(&buf, "Implement remaining clanker PRDs starting with persist"));
    try std.testing.expectEqualStrings("websocket live map", titleFromTask(&buf, "please add a websocket for the live map"));
    try std.testing.expectEqualStrings("a", titleFromTask(&buf, "a"));
    try std.testing.expectEqualStrings("(untitled)", titleFromTask(&buf, "   "));
    try std.testing.expect(keepTitle("Mesh map"));
    try std.testing.expect(keepTitle("fork of Original"));
    try std.testing.expect(!keepTitle("left bar chat title should be a couple word summary of the"));
    try std.testing.expectEqualStrings("Mesh map", nextTitle(&buf, "Mesh map", "something else entirely"));
}

test "titleFromTask handles non-Latin tasks" {
    var buf: [title_max]u8 = undefined;
    // Space-separated CJK words earn a title like Latin text does (up to 3).
    try std.testing.expectEqualStrings("修复 登录 bug", titleFromTask(&buf, "修复 登录 bug 页面"));
    // An unsplit CJK sentence is one long word: the title is its start,
    // truncated on a codepoint boundary (never mid-character).
    const long_cjk = "这是一个很长的中文句子用于测试标题截断";
    const t = titleFromTask(&buf, long_cjk);
    try std.testing.expect(std.unicode.utf8ValidateSlice(t));
    try std.testing.expect(t.len <= title_max);
    try std.testing.expectEqualStrings("这是一个很长的中文", t);
    // A mixed run keeps its non-ASCII characters whole.
    try std.testing.expectEqualStrings("héllo world", titleFromTask(&buf, "héllo world"));
}

/// Retitles a conversation in place, leaving its messages untouched.
///
/// Auto titles are a couple of content words from the opening task. A
/// picker full of 60-character prefixes is what this replaced.
pub fn renameSession(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, id: []const u8, title: []const u8) !void {
    const s = try loadSession(io, gpa, arena, base, id);
    try saveSession(io, gpa, arena, base, .{
        .id = s.id,
        .title = title,
        .workspace = s.workspace,
        .messages = s.messages,
        .created = s.created,
        .updated = s.updated,
    });
}

/// Enough of a session to list it without reading every message: what a
/// picker needs to show one row.
pub const SessionMeta = struct {
    id: []const u8,
    title: []const u8 = "",
    created: i64 = 0,
    updated: i64 = 0,
    workspace: []const u8 = "",
    archived: bool = false,
    messages: usize = 0,
    /// Total byte length of the transcript's message content (plus tool-call
    /// arguments). Compaction thresholds are in bytes, so a picker can show
    /// this: it is how close a conversation is to being compacted.
    bytes: usize = 0,
};

/// Copies listing fields out of a parsed transcript so the file buffer can
/// be dropped. Peak memory for a picker is then one conversation, not the
/// sum of every saved one (each file may be up to 16 MiB).
fn sessionMetaFromStored(arena: std.mem.Allocator, stored: StoredSession) !SessionMeta {
    return .{
        .id = try arena.dupe(u8, stored.id),
        .title = try arena.dupe(u8, stored.title),
        .created = stored.created,
        .updated = stored.updated,
        .workspace = try arena.dupe(u8, stored.workspace),
        .archived = stored.archived,
        .messages = stored.messages.len,
        .bytes = storedTranscriptBytes(stored.messages),
    };
}

/// Counted the same way on both sides: `bytes` is written from the live
/// messages and recomputed from the stored ones when the header is missing,
/// so the two must agree or a session changes size just by being re-listed.
/// Attachments count because they dominate a multimodal transcript.
fn transcriptBytes(messages: []const types.Message) usize {
    var bytes: usize = 0;
    for (messages) |m| {
        if (m.content) |c| bytes += c.len;
        if (m.images) |imgs| {
            for (imgs) |img| bytes += img.b64.len;
        }
        if (m.tool_calls) |calls| {
            for (calls) |tc| bytes += tc.arguments.len;
        }
    }
    return bytes;
}

fn storedTranscriptBytes(messages: []const StoredMessage) usize {
    var bytes: usize = 0;
    for (messages) |sm| {
        if (sm.content) |c| bytes += c.len;
        if (sm.images) |imgs| {
            for (imgs) |img| bytes += img.b64.len;
        }
        if (sm.tool_calls) |calls| {
            for (calls) |tc| bytes += tc.arguments.len;
        }
    }
    return bytes;
}

/// Enough of the file to hold id/title/timestamps and the listing counters
/// that sit in front of `messages`. A 4 KiB title would miss them and fall
/// back to a full parse; real titles are a couple of words.
const listing_header_bytes: usize = 4096;

const StoredListing = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    created: i64 = 0,
    updated: i64 = 0,
    workspace: []const u8 = "",
    archived: bool = false,
    message_count: ?usize = null,
    bytes: ?usize = null,
};

/// First `listing_header_bytes` of `path`, or null when the file cannot be
/// opened. A short file returns whatever it contains.
fn readListingPrefix(io: std.Io, base: std.Io.Dir, path: []const u8, buf: *[listing_header_bytes]u8) ?[]const u8 {
    var file = base.openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const n = reader.interface.readSliceShort(buf) catch return null;
    if (n == 0) return null;
    return buf[0..n];
}

/// Closes a JSON object just before a top-level `,"<field>":` so a prefix
/// that still has the transcript (or a truncated tail) parses as the header
/// fields alone.
fn closeJsonBeforeField(arena: std.mem.Allocator, raw: []const u8, field: []const u8) ?[]const u8 {
    var needle_buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, ",\"{s}\":", .{field}) catch return null;
    const at = std.mem.find(u8, raw, needle) orelse return null;
    const prefix = std.mem.trimEnd(u8, raw[0..at], " \t\r\n");
    if (prefix.len == 0 or prefix[0] != '{') return null;
    return std.fmt.allocPrint(arena, "{s}}}", .{prefix}) catch null;
}

fn storedListingFromPrefix(scratch: std.mem.Allocator, prefix: []const u8) ?StoredListing {
    const src = closeJsonBeforeField(scratch, prefix, "messages") orelse blk: {
        const trimmed = std.mem.trimEnd(u8, prefix, " \t\r\n");
        if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '}') break :blk trimmed;
        return null;
    };
    const h = json.parseFromSliceLeaky(StoredListing, scratch, src, .{ .ignore_unknown_fields = true }) catch return null;
    if (h.id.len == 0) return null;
    return h;
}

fn sessionMetaFromPrefix(arena: std.mem.Allocator, scratch: std.mem.Allocator, prefix: []const u8) ?SessionMeta {
    const h = storedListingFromPrefix(scratch, prefix) orelse return null;
    // Counters are optional: files written before message_count/bytes still
    // carry id/title/updated in the first kilobytes. Missing counts stay 0
    // until the next save, rather than pulling the whole transcript just to
    // fill a picker column.
    return .{
        .id = arena.dupe(u8, h.id) catch return null,
        .title = arena.dupe(u8, h.title) catch return null,
        .created = h.created,
        .updated = h.updated,
        .workspace = arena.dupe(u8, h.workspace) catch return null,
        .archived = h.archived,
        .messages = h.message_count orelse 0,
        .bytes = h.bytes orelse 0,
    };
}

/// Lists every saved session, most recently updated first, the order a
/// picker wants, since the session you were just in is the one you are most
/// likely to return to. A file that cannot be read or parsed is skipped
/// rather than failing the whole listing: one corrupt session should not make
/// the others unreachable.
pub fn listSessions(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir) ![]SessionMeta {
    var out: std.ArrayList(SessionMeta) = .empty;

    var dir = base.openDir(io, store_dir, .{ .iterate = true }) catch return out.toOwnedSlice(arena);
    defer dir.close(io);

    var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_state.deinit();
    var header_buf: [listing_header_bytes]u8 = undefined;

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        defer _ = scratch_state.reset(.retain_capacity);
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const scratch = scratch_state.allocator();
        const path = std.fmt.allocPrint(scratch, "{s}/{s}", .{ store_dir, entry.name }) catch continue;
        if (readListingPrefix(io, base, path, &header_buf)) |prefix| {
            if (sessionMetaFromPrefix(arena, scratch, prefix)) |meta| {
                out.append(arena, meta) catch continue;
                continue;
            }
        }
        // Prefix missed id/title (a 4 KiB title pushed the header off the
        // window). Walk the transcript only then, never for a file that
        // already named itself in the first kilobytes.
        const raw = base.readFileAlloc(io, path, scratch, .limited(1 << 24)) catch continue;
        const stored = json.parseFromSliceLeaky(StoredSession, scratch, raw, .{ .ignore_unknown_fields = true }) catch continue;
        out.append(arena, sessionMetaFromStored(arena, stored) catch continue) catch continue;
    }

    std.mem.sort(SessionMeta, out.items, {}, struct {
        fn newestFirst(_: void, a: SessionMeta, b: SessionMeta) bool {
            return a.updated > b.updated;
        }
    }.newestFirst);
    return out.toOwnedSlice(arena);
}

/// One message that matched a search, with enough around it to recognise.
pub const SearchHit = struct {
    id: []const u8,
    title: []const u8,
    updated: i64,
    archived: bool = false,
    /// Index into the stored message list, so the browser can say which turn
    /// and jump there rather than only naming the conversation.
    turn: usize,
    role: []const u8,
    snippet: []const u8,
    /// Matches in this conversation beyond the one reported. A conversation
    /// is one row however often the word appears in it, and this is what
    /// stops that from reading as "found once".
    more: usize = 0,
};

/// Characters of context kept either side of a match.
const snippet_radius = 90;

/// Case-insensitive substring position, ASCII-folded. Deliberately not a
/// fuzzy or subsequence match: the rail filter is already fuzzy over titles,
/// and a fuzzy match over whole transcripts finds a hit in nearly every
/// conversation, which is the same as finding nothing.
pub fn findFold(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    return std.ascii.findIgnoreCase(haystack, needle);
}

/// False when `query` cannot appear in this file's raw JSON, so the
/// transcript parse can be skipped. Queries that JSON would escape (`"`,
/// `\`, controls) must still be parsed: the stored form is not the needle.
fn rawMayContainQuery(raw: []const u8, query: []const u8) bool {
    for (query) |c| {
        if (c < 0x20 or c == '"' or c == '\\') return true;
    }
    return findFold(raw, query) != null;
}

/// The text around `at`, trimmed to a word boundary where one is close, with
/// ellipses marking each end that was cut. Newlines and tabs collapse to
/// spaces so a hit renders as one line whatever the message looked like.
pub fn snippetAround(arena: std.mem.Allocator, text: []const u8, at: usize, match_len: usize) []const u8 {
    const start_raw = if (at > snippet_radius) at - snippet_radius else 0;
    const end_raw = @min(text.len, at + match_len + snippet_radius);
    // Never cut inside the match itself while hunting for a space.
    var start = start_raw;
    if (start > 0) {
        if (std.mem.findScalarPos(u8, text[start..at], 0, ' ')) |sp| start += sp + 1;
    }
    var end = end_raw;
    if (end < text.len) {
        const tail_from = at + match_len;
        if (tail_from < end) {
            if (std.mem.findScalarLast(u8, text[tail_from..end], ' ')) |sp| end = tail_from + sp;
        }
    }
    // A radius cut can land mid-codepoint. Snap both cuts to codepoint
    // boundaries so the snippet stays valid UTF-8: it is re-encoded as JSON
    // for the web UI, where a split character renders as U+FFFD.
    if (start > 0 and start < end) {
        while (start < end and (text[start] & 0xC0) == 0x80) start += 1;
    }
    if (end < text.len) {
        while (end > start and (text[end] & 0xC0) == 0x80) end -= 1;
    }
    var out: std.ArrayList(u8) = .empty;
    if (start > 0) out.appendSlice(arena, "\u{2026}") catch return text[start..end];
    for (text[start..end]) |c| {
        const ch: u8 = switch (c) {
            '\n', '\r', '\t' => ' ',
            else => c,
        };
        // Control bytes never reach the page: this is model output and tool
        // results, the same untrusted text transcript.zig strips.
        if (ch < 0x20 or ch == 0x7f) continue;
        out.append(arena, ch) catch return text[start..end];
    }
    if (end < text.len) out.appendSlice(arena, "\u{2026}") catch {};
    return out.items;
}

/// Every stored conversation holding `query` in a message, newest first, one
/// row per conversation.
///
/// Reads the same directory `listSessions` walks and in the same way, so a
/// `state/` that is a symlink into the checkout resolves identically for both.
/// A file that fails to read or parse is skipped rather than failing the
/// search, matching how the listing treats a corrupt session.
pub fn searchSessions(
    io: std.Io,
    arena: std.mem.Allocator,
    base: std.Io.Dir,
    query: []const u8,
    limit: usize,
) ![]SearchHit {
    var out: std.ArrayList(SearchHit) = .empty;
    if (query.len == 0 or limit == 0) return out.toOwnedSlice(arena);

    var dir = base.openDir(io, store_dir, .{ .iterate = true }) catch return out.toOwnedSlice(arena);
    defer dir.close(io);

    var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_state.deinit();
    var header_buf: [listing_header_bytes]u8 = undefined;

    // Score files from the listing header (4 KiB), then open transcripts
    // newest-first and stop once `limit` conversations match. Opening every
    // file first (each up to 16 MiB) then sorting was the same work as a
    // miss even when the newest 50 already filled the page.
    const Candidate = struct { name: []const u8, updated: i64 };
    var candidates: std.ArrayList(Candidate) = .empty;

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        defer _ = scratch_state.reset(.retain_capacity);
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const scratch = scratch_state.allocator();
        const path = std.fmt.allocPrint(scratch, "{s}/{s}", .{ store_dir, entry.name }) catch continue;
        const updated: i64 = blk: {
            if (readListingPrefix(io, base, path, &header_buf)) |prefix| {
                if (storedListingFromPrefix(scratch, prefix)) |h| break :blk h.updated;
            }
            // Prefix missed updated (a 4 KiB title pushed the header off
            // the window). Parse only then, never for a file that already
            // named its timestamp in the first kilobytes.
            const raw = base.readFileAlloc(io, path, scratch, .limited(1 << 24)) catch continue;
            const stored = json.parseFromSliceLeaky(StoredSession, scratch, raw, .{ .ignore_unknown_fields = true }) catch continue;
            break :blk stored.updated;
        };
        const name = arena.dupe(u8, entry.name) catch continue;
        candidates.append(arena, .{ .name = name, .updated = updated }) catch continue;
    }

    std.mem.sort(Candidate, candidates.items, {}, struct {
        fn newestFirst(_: void, a: Candidate, b: Candidate) bool {
            return a.updated > b.updated;
        }
    }.newestFirst);

    for (candidates.items) |c| {
        if (out.items.len >= limit) break;
        defer _ = scratch_state.reset(.retain_capacity);
        const scratch = scratch_state.allocator();
        const path = std.fmt.allocPrint(scratch, "{s}/{s}", .{ store_dir, c.name }) catch continue;
        const raw = base.readFileAlloc(io, path, scratch, .limited(1 << 24)) catch continue;
        // A query that cannot appear escaped in JSON (`"` / `\` / controls)
        // is stored verbatim. If the raw file does not contain it, skip the
        // transcript parse: most conversations miss a typical search.
        if (!rawMayContainQuery(raw, query)) continue;
        const stored = json.parseFromSliceLeaky(StoredSession, scratch, raw, .{ .ignore_unknown_fields = true }) catch continue;

        var first: ?SearchHit = null;
        var count: usize = 0;
        for (stored.messages, 0..) |m, idx| {
            const content = m.content orelse continue;
            const at = findFold(content, query) orelse continue;
            count += 1;
            if (first != null) continue;
            // Strings from `stored` die with the scratch arena; copy the
            // hit out before the next file reset.
            first = .{
                .id = arena.dupe(u8, stored.id) catch break,
                .title = arena.dupe(u8, stored.title) catch break,
                .updated = stored.updated,
                .archived = stored.archived,
                .turn = idx,
                .role = arena.dupe(u8, m.role) catch break,
                .snippet = arena.dupe(u8, snippetAround(arena, content, at, query.len)) catch break,
            };
        }
        if (first) |*hit| {
            hit.more = count - 1;
            out.append(arena, hit.*) catch continue;
        }
    }

    return out.toOwnedSlice(arena);
}

/// The most recently updated session's id, or null when none exist, what
/// `--continue` means, for both `clanker run` and the REPL.
///
/// Only the listing header is read: `--continue` must not parse every
/// transcript just to learn which file is newest.
pub fn latestSessionId(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir) ?[]const u8 {
    var dir = base.openDir(io, store_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_state.deinit();
    var header_buf: [listing_header_bytes]u8 = undefined;

    var best_id: ?[]const u8 = null;
    var best_updated: i64 = std.math.minInt(i64);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        defer _ = scratch_state.reset(.retain_capacity);
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const scratch = scratch_state.allocator();
        const path = std.fmt.allocPrint(scratch, "{s}/{s}", .{ store_dir, entry.name }) catch continue;
        const prefix = readListingPrefix(io, base, path, &header_buf) orelse continue;
        const h = storedListingFromPrefix(scratch, prefix) orelse continue;
        if (h.updated < best_updated) continue;
        best_updated = h.updated;
        best_id = arena.dupe(u8, h.id) catch continue;
    }
    return best_id;
}

/// The compaction budget a session is trimmed to before every save.
pub const max_session_tokens = 128 * 1024;

/// Chars/4, rounded up. Short strings are not free. One function so
/// save-time trim, mid-turn compaction, and the context meter cannot drift.
pub fn estimateTextTokens(bytes: usize) usize {
    if (bytes == 0) return 0;
    return bytes / 4 + @intFromBool(bytes % 4 != 0);
}

pub fn estimatedTokens(message: types.Message) usize {
    var bytes: usize = if (message.content) |content| content.len else 0;
    if (message.tool_calls) |calls| {
        for (calls) |call| bytes +|= call.arguments.len;
    }
    return estimateTextTokens(bytes);
}

/// Drops oldest non-system messages until the estimated token count fits under
/// `max_tokens` so long sessions auto-compact instead of exceeding the context
/// window. Token count is estimated as chars/4 (a rough heuristic).
///
/// Dropping stops at a tool-call boundary. What is removed is always a prefix
/// of the non-system messages, so the budget cutoff can land between an
/// assistant message carrying `tool_calls` and the `tool` messages answering
/// it, leaving a tool result with nothing to answer to. Every provider rejects
/// that (OpenAI 400s on a `tool` message not preceded by `tool_calls`;
/// Anthropic rejects an unmatched `tool_result` block), and nothing downstream
/// repairs it — [[Agent.dropDanglingToolExchange]] only cleans the tail. So
/// once anything has been dropped, leading tool results go with it, the same
/// invariant [[Agent.tailStart]] guards on the other compactor.
pub fn compactMessages(messages: *std.ArrayList(types.Message), max_tokens: usize) void {
    var total: usize = 0;
    for (messages.items) |m| total +|= estimatedTokens(m);
    if (total <= max_tokens) return;
    // A single left-to-right compaction pass: `orderedRemove` per dropped
    // message shifts the whole tail, which is O(n^2) once a long session
    // needs many messages trimmed. Writing survivors back in place is O(n).
    var write: usize = 0;
    // True until a non-system message survives; only then can a `tool` message
    // have a call to answer.
    var orphaning = true;
    for (messages.items) |m| {
        if (m.role == .system) {
            messages.items[write] = m;
            write += 1;
            continue;
        }
        if (total > max_tokens or (orphaning and m.role == .tool)) {
            total -|= estimatedTokens(m);
            continue;
        }
        orphaning = false;
        messages.items[write] = m;
        write += 1;
    }
    messages.shrinkRetainingCapacity(write);
}

fn roleFromStr(s: []const u8) !types.Role {
    if (std.mem.eql(u8, s, "system")) return .system;
    if (std.mem.eql(u8, s, "user")) return .user;
    if (std.mem.eql(u8, s, "assistant")) return .assistant;
    if (std.mem.eql(u8, s, "tool")) return .tool;
    return error.InvalidRole;
}

// ------------------------------------------------------------------- tests --

test "session store rejects ids that can escape its directory" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    const bad_id = "../../escaped";
    try std.testing.expectError(error.InvalidSessionId, saveSession(io, std.testing.allocator, arena, env.tmp.dir, .{
        .id = bad_id,
        .title = "bad",
        .messages = &.{},
        .created = 0,
        .updated = 0,
    }));
    try std.testing.expectError(error.InvalidSessionId, loadSession(io, std.testing.allocator, arena, env.tmp.dir, bad_id));
    try std.testing.expectError(error.InvalidSessionId, deleteSession(io, arena, env.tmp.dir, bad_id));
    try std.testing.expectError(error.InvalidSessionId, forkSession(io, std.testing.allocator, arena, env.tmp.dir, bad_id));
    try std.testing.expectError(error.FileNotFound, env.tmp.dir.statFile(io, "escaped.json", .{}));
}

test "a saved session round-trips its image attachments, including through a fork" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    var imgs = [_]types.ImagePart{.{ .mime = "image/png", .b64 = "aGk=" }};
    const messages = [_]types.Message{
        .{ .role = .user, .content = "what is in this picture?", .images = &imgs },
        .{ .role = .assistant, .content = "a greeting" },
    };
    try saveSession(io, std.testing.allocator, arena, env.tmp.dir, .{
        .id = "vision",
        .title = "vision",
        .messages = &messages,
        .created = 0,
        .updated = 0,
    });

    // The attachment is model-visible input, so resuming must resend it.
    const loaded = try loadSession(io, std.testing.allocator, arena, env.tmp.dir, "vision");
    const got = loaded.messages[0].images orelse return error.AttachmentDropped;
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("image/png", got[0].mime);
    try std.testing.expectEqualStrings("aGk=", got[0].b64);
    // A message that never had one still decodes as having none.
    try std.testing.expect(loaded.messages[1].images == null);

    // forkSession round-trips through load+save, so it stripped them too.
    const fork_id = try forkSession(io, std.testing.allocator, arena, env.tmp.dir, "vision");
    const forked = try loadSession(io, std.testing.allocator, arena, env.tmp.dir, fork_id);
    const fork_imgs = forked.messages[0].images orelse return error.AttachmentDropped;
    try std.testing.expectEqualStrings("aGk=", fork_imgs[0].b64);

    // The listing counter agrees with what a re-listing recomputes.
    const metas = try listSessions(io, arena, env.tmp.dir);
    for (metas) |m| {
        if (!std.mem.eql(u8, m.id, "vision")) continue;
        try std.testing.expectEqual(transcriptBytes(&messages), m.bytes);
    }
}

test "session load rejects an unknown persisted message role" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    try env.tmp.dir.createDirPath(io, "state/sessions");
    try env.tmp.dir.writeFile(io, .{ .sub_path = "state/sessions/bad-role.json", .data =
        \\{"id":"bad-role","title":"bad","created":0,"updated":0,"messages":[{"role":"operator","content":"do not reinterpret me"}]}
    });
    try std.testing.expectError(error.InvalidRole, loadSession(io, std.testing.allocator, arena, env.tmp.dir, "bad-role"));
}

test "a session with invalid UTF-8 in untrusted text still round-trips" {
    // The storage format is UTF-8 JSON and the loader rejects invalid UTF-8
    // with SyntaxError, but the writer used to pass stray bytes through
    // verbatim. One latin-1 byte in a message or title then bricked the file:
    // loadSession failed and listings silently dropped the session. The write
    // boundary now replaces invalid bytes with U+FFFD so what is stored always
    // parses back.
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    const dirty_title = [_]u8{ 'c', 'a', 'f', 0xE9 };
    const dirty_content = [_]u8{ 'p', 'a', 's', 't', 'e', 'd', ' ', 0xFF, ' ', 0xF0, 0x9F };
    const messages = [_]types.Message{
        .{ .role = .user, .content = &dirty_content },
        .{ .role = .assistant, .content = "valid \u{E9}" },
    };
    try saveSession(io, std.testing.allocator, arena, env.tmp.dir, .{
        .id = "dirty",
        .title = &dirty_title,
        .messages = &messages,
        .created = 0,
        .updated = 0,
    });

    const loaded = try loadSession(io, std.testing.allocator, arena, env.tmp.dir, "dirty");
    try std.testing.expectEqualStrings("caf\u{FFFD}", loaded.title);
    // The truncated 0xF0 0x9F emoji pair is two invalid bytes -> two U+FFFDs.
    try std.testing.expectEqualStrings("pasted \u{FFFD} \u{FFFD}\u{FFFD}", loaded.messages[0].content.?);
    try std.testing.expectEqualStrings("valid \u{E9}", loaded.messages[1].content.?);
    try std.testing.expect(std.unicode.utf8ValidateSlice(loaded.messages[0].content.?));
}

test "compactMessages counts short content and tool-call arguments" {
    var messages: std.ArrayList(types.Message) = .empty;
    defer messages.deinit(std.testing.allocator);
    try messages.appendSlice(std.testing.allocator, &.{
        .{ .role = .system, .content = "system" },
        .{ .role = .user, .content = "abc" },
        .{ .role = .assistant, .tool_calls = &.{.{
            .id = "call-1",
            .name = "read",
            .arguments = "12345678",
        }} },
        .{ .role = .assistant, .content = "keep" },
    });

    compactMessages(&messages, 3);

    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqual(types.Role.system, messages.items[0].role);
    try std.testing.expectEqualStrings("keep", messages.items[1].content.?);
}

test "compactMessages counts tool-call arguments toward the token estimate" {
    // An assistant message whose own content is absent but whose tool-call
    // arguments are long must estimate tokens from those arguments, the way
    // listSessions counts byte weight. Without it, a session made almost
    // entirely of tool calls would never compact no matter how long the
    // arguments got.
    var messages: std.ArrayList(types.Message) = .empty;
    defer messages.deinit(std.testing.allocator);
    try messages.append(std.testing.allocator, .{ .role = .system, .content = "sys" });
    try messages.append(std.testing.allocator, .{
        .role = .assistant,
        .tool_calls = &.{.{
            .id = "c1",
            .name = "read_file",
            .arguments = "aaaaaaaaaaaaaaaa", // 16 bytes → 4 tokens
        }},
    });
    try messages.append(std.testing.allocator, .{ .role = .user, .content = "bbbb" });

    // System (1) + tool call (4) + user (1) = 6 tokens. A budget of 4 evicts
    // the oldest non-system message, the 4-token tool call, and leaves
    // system + the 1-token user message. If arguments were not counted the
    // tool call would be free, the total would be 2 ≤ 4, and nothing would
    // be dropped.
    compactMessages(&messages, 4);
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqual(types.Role.system, messages.items[0].role);
    try std.testing.expectEqual(types.Role.user, messages.items[1].role);
    try std.testing.expectEqualStrings("bbbb", messages.items[1].content.?);
}

test "estimateTextTokens rounds up so short strings are not free" {
    try std.testing.expectEqual(@as(usize, 0), estimateTextTokens(0));
    try std.testing.expectEqual(@as(usize, 1), estimateTextTokens(1));
    try std.testing.expectEqual(@as(usize, 1), estimateTextTokens(4));
    try std.testing.expectEqual(@as(usize, 2), estimateTextTokens(5));
}

test "estimatedTokens rounds up so short messages are not free" {
    try std.testing.expectEqual(@as(usize, 1), estimatedTokens(.{ .role = .user, .content = "a" }));
    try std.testing.expectEqual(@as(usize, 1), estimatedTokens(.{ .role = .user, .content = "abcd" }));
    try std.testing.expectEqual(@as(usize, 2), estimatedTokens(.{ .role = .user, .content = "abcde" }));
    // A tool-call-only message contributes its arguments toward the token
    // estimate: 10 bytes -> ceil(10/4) = 3 tokens.
    const m = types.Message{ .role = .assistant, .tool_calls = &.{.{
        .id = "c",
        .name = "read",
        .arguments = "abcdefghij",
    }} };
    try std.testing.expectEqual(@as(usize, 3), estimatedTokens(m));
}

test "compactMessages preserves system messages even when they exceed the budget" {
    var messages: std.ArrayList(types.Message) = .empty;
    defer messages.deinit(std.testing.allocator);
    try messages.appendSlice(std.testing.allocator, &.{
        .{ .role = .system, .content = "a system prompt larger than this budget" },
        .{ .role = .user, .content = "remove me" },
    });

    compactMessages(&messages, 0);

    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expectEqual(types.Role.system, messages.items[0].role);
}

test "compactMessages never leaves a tool result with no tool_calls to answer" {
    var messages: std.ArrayList(types.Message) = .empty;
    defer messages.deinit(std.testing.allocator);
    // The budget is spent by the system prompt and the tail, so the cutoff
    // lands on the assistant message carrying the calls and its two results
    // become the leading survivors.
    try messages.appendSlice(std.testing.allocator, &.{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "aaaaaaaaaaaaaaaa" },
        .{ .role = .assistant, .tool_calls = &.{
            .{ .id = "c1", .name = "read", .arguments = "aaaaaaaaaaaaaaaa" },
            .{ .id = "c2", .name = "read", .arguments = "aaaaaaaaaaaaaaaa" },
        } },
        .{ .role = .tool, .tool_call_id = "c1", .content = "r1" },
        .{ .role = .tool, .tool_call_id = "c2", .content = "r2" },
        .{ .role = .assistant, .content = "done" },
    });

    compactMessages(&messages, 3);

    // Every surviving tool message answers a tool_call still in the list.
    for (messages.items, 0..) |m, i| {
        if (m.role != .tool) continue;
        var answered = false;
        for (messages.items[0..i]) |prior| {
            for (prior.tool_calls orelse &.{}) |tc| {
                if (std.mem.eql(u8, tc.id, m.tool_call_id.?)) answered = true;
            }
        }
        try std.testing.expect(answered);
    }
    // The tail and the system prompt still survive; only the orphaned
    // exchange went with the over-budget prefix.
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqual(types.Role.system, messages.items[0].role);
    try std.testing.expectEqualStrings("done", messages.items[1].content.?);
}

test "latestSessionId picks the most recently updated session" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    // No store yet: null, not an error.
    try std.testing.expect(latestSessionId(io, arena, env.tmp.dir) == null);

    try saveSession(io, std.testing.allocator, arena, env.tmp.dir, .{
        .id = "older",
        .title = "t",
        .messages = &.{},
        .created = 100,
        .updated = 100,
    });
    try saveSession(io, std.testing.allocator, arena, env.tmp.dir, .{
        .id = "newer",
        .title = "t",
        .messages = &.{},
        .created = 50,
        .updated = 200,
    });
    try std.testing.expectEqualStrings("newer", latestSessionId(io, arena, env.tmp.dir).?);
}

test "listSessions and latestSessionId use the listing header without the transcript" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    try env.tmp.dir.createDirPath(io, "state/sessions");
    // Deliberately not valid past `messages`: if listing walked the
    // transcript this file would be skipped as corrupt.
    try env.tmp.dir.writeFile(io, .{
        .sub_path = "state/sessions/hdr.json",
        .data = "{\"id\":\"hdr\",\"title\":\"from-header\",\"created\":1,\"updated\":9,\"message_count\":3,\"bytes\":42,\"messages\":[THIS IS NOT JSON",
    });

    const list = try listSessions(io, arena, env.tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("hdr", list[0].id);
    try std.testing.expectEqualStrings("from-header", list[0].title);
    try std.testing.expectEqual(@as(usize, 3), list[0].messages);
    try std.testing.expectEqual(@as(usize, 42), list[0].bytes);
    try std.testing.expectEqualStrings("hdr", latestSessionId(io, arena, env.tmp.dir).?);
}

test "listSessions lists a pre-counter file from the header alone" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    try env.tmp.dir.createDirPath(io, "state/sessions");
    // No message_count/bytes, and the transcript is garbage: a full parse
    // would skip this file. The picker still needs the title and updated.
    try env.tmp.dir.writeFile(io, .{
        .sub_path = "state/sessions/old.json",
        .data = "{\"id\":\"old\",\"title\":\"legacy\",\"created\":1,\"updated\":8,\"messages\":[THIS IS NOT JSON",
    });

    const list = try listSessions(io, arena, env.tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("old", list[0].id);
    try std.testing.expectEqualStrings("legacy", list[0].title);
    try std.testing.expectEqual(@as(i64, 8), list[0].updated);
    try std.testing.expectEqual(@as(usize, 0), list[0].messages);
    try std.testing.expectEqual(@as(usize, 0), list[0].bytes);
    try std.testing.expectEqualStrings("old", latestSessionId(io, arena, env.tmp.dir).?);
}

test "session save/load round trip" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const session = Session{
        .id = "s1",
        .title = "Test session",
        .messages = &.{
            .{ .role = .system, .content = "sys" },
            .{ .role = .user, .content = "hello" },
            .{ .role = .assistant, .content = null, .tool_calls = &.{.{
                .id = "tc1",
                .name = "calc",
                .arguments = "{}",
            }} },
            .{ .role = .tool, .tool_call_id = "tc1", .content = "42" },
        },
        .created = 100,
        .updated = 200,
    };
    try saveSession(io, gpa, arena, tmp.dir, session);

    const loaded = try loadSession(io, gpa, arena, tmp.dir, "s1");
    try std.testing.expectEqualStrings("s1", loaded.id);
    try std.testing.expectEqualStrings("Test session", loaded.title);
    try std.testing.expectEqual(@as(i64, 100), loaded.created);
    try std.testing.expectEqual(@as(i64, 200), loaded.updated);
    try std.testing.expectEqual(@as(usize, 4), loaded.messages.len);
    try std.testing.expectEqual(types.Role.system, loaded.messages[0].role);
    try std.testing.expectEqual(types.Role.assistant, loaded.messages[2].role);
    try std.testing.expectEqual(@as(usize, 1), loaded.messages[2].tool_calls.?.len);
    try std.testing.expectEqualStrings("calc", loaded.messages[2].tool_calls.?[0].name);
    try std.testing.expectEqual(types.Role.tool, loaded.messages[3].role);
    try std.testing.expectEqualStrings("42", loaded.messages[3].content.?);
    try std.testing.expectEqualStrings("tc1", loaded.messages[3].tool_call_id.?);
}

test "a session larger than the old fixed 1MB buffer still saves and loads" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const chunk = try arena.alloc(u8, 64 * 1024);
    @memset(chunk, 'x');
    var messages: std.ArrayList(types.Message) = .empty;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try messages.append(arena, .{ .role = .user, .content = chunk });
    }

    const session = Session{
        .id = "big",
        .title = "Big session",
        .messages = messages.items,
        .created = 1,
        .updated = 2,
    };
    try saveSession(io, gpa, arena, tmp.dir, session);

    const loaded = try loadSession(io, gpa, arena, tmp.dir, "big");
    try std.testing.expectEqual(@as(usize, 20), loaded.messages.len);
    try std.testing.expectEqualStrings(chunk, loaded.messages[19].content.?);
}

test "forkSession copies a conversation under a new id and leaves the original alone" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try saveSession(io, gpa, arena, tmp.dir, .{
        .id = "s1",
        .title = "Original",
        .messages = &.{
            .{ .role = .user, .content = "hello" },
            .{ .role = .assistant, .content = "hi there" },
        },
        .created = 100,
        .updated = 200,
    });

    const new_id = try forkSession(io, gpa, arena, tmp.dir, "s1");
    try std.testing.expect(!std.mem.eql(u8, new_id, "s1"));

    const forked = try loadSession(io, gpa, arena, tmp.dir, new_id);
    try std.testing.expectEqualStrings(new_id, forked.id);
    try std.testing.expectEqualStrings("fork of Original", forked.title);
    try std.testing.expectEqual(@as(usize, 2), forked.messages.len);
    try std.testing.expectEqualStrings("hello", forked.messages[0].content.?);
    try std.testing.expectEqualStrings("hi there", forked.messages[1].content.?);

    // Two forks of the same session get distinct ids.
    const second_id = try forkSession(io, gpa, arena, tmp.dir, "s1");
    try std.testing.expect(!std.mem.eql(u8, new_id, second_id));

    // The source conversation is untouched.
    const original = try loadSession(io, gpa, arena, tmp.dir, "s1");
    try std.testing.expectEqualStrings("Original", original.title);
    try std.testing.expectEqual(@as(usize, 2), original.messages.len);

    // Forking a session that does not exist fails rather than inventing one.
    try std.testing.expectError(error.FileNotFound, forkSession(io, gpa, arena, tmp.dir, "nope"));
}

test "branchSession cuts the conversation at a turn and leaves the original alone" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try saveSession(io, gpa, arena, tmp.dir, .{
        .id = "s1",
        .title = "Original",
        .messages = &.{
            .{ .role = .system, .content = "shared context" },
            .{ .role = .user, .content = "u1" },
            .{ .role = .assistant, .tool_calls = &.{.{
                .id = "c1",
                .name = "read",
                .arguments = "{}",
            }} },
            .{ .role = .tool, .tool_call_id = "c1", .content = "result" },
            .{ .role = .assistant, .content = "a1" },
            .{ .role = .user, .content = "u2" },
            .{ .role = .assistant, .content = "a2" },
            .{ .role = .user, .content = "u3" },
            .{ .role = .assistant, .content = "a3" },
        },
        .created = 100,
        .updated = 200,
    });

    // Branch at turn 2: the tool round of turn 1 is fully included, and
    // nothing after turn 2 is.
    const new_id = try branchSession(io, gpa, arena, tmp.dir, "s1", 2);
    const branched = try loadSession(io, gpa, arena, tmp.dir, new_id);
    try std.testing.expectEqualStrings("branch of Original", branched.title);
    try std.testing.expectEqual(@as(usize, 7), branched.messages.len);
    try std.testing.expectEqualStrings("a2", branched.messages[branched.messages.len - 1].content.?);
    try std.testing.expectEqualStrings("shared context", branched.messages[0].content.?);

    // The source conversation is untouched, all nine messages.
    const original = try loadSession(io, gpa, arena, tmp.dir, "s1");
    try std.testing.expectEqualStrings("Original", original.title);
    try std.testing.expectEqual(@as(usize, 9), original.messages.len);

    // Branching at the last turn copies the whole conversation.
    const whole = try branchSession(io, gpa, arena, tmp.dir, "s1", 3);
    const whole_session = try loadSession(io, gpa, arena, tmp.dir, whole);
    try std.testing.expectEqual(@as(usize, 9), whole_session.messages.len);

    // Two branches of the same session get distinct ids.
    const second_id = try branchSession(io, gpa, arena, tmp.dir, "s1", 1);
    try std.testing.expect(!std.mem.eql(u8, new_id, second_id));

    // Turn 0 and past-the-end are refused, not silently clamped.
    try std.testing.expectError(error.TurnOutOfRange, branchSession(io, gpa, arena, tmp.dir, "s1", 0));
    try std.testing.expectError(error.TurnOutOfRange, branchSession(io, gpa, arena, tmp.dir, "s1", 4));
    // A pending turn (user message with no answer) cuts before it instead.
    try saveSession(io, gpa, arena, tmp.dir, .{
        .id = "s2",
        .title = "Pending",
        .messages = &.{
            .{ .role = .user, .content = "done turn" },
            .{ .role = .assistant, .content = "answered" },
            .{ .role = .user, .content = "in flight" },
        },
        .created = 100,
        .updated = 200,
    });
    const pending = try branchSession(io, gpa, arena, tmp.dir, "s2", 2);
    const pending_session = try loadSession(io, gpa, arena, tmp.dir, pending);
    try std.testing.expectEqual(@as(usize, 2), pending_session.messages.len);
    try std.testing.expectEqualStrings("answered", pending_session.messages[1].content.?);

    // Branching a session that does not exist fails rather than inventing one.
    try std.testing.expectError(error.FileNotFound, branchSession(io, gpa, arena, tmp.dir, "nope", 1));
}

test "listSessions reports the byte weight of each conversation" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try saveSession(io, gpa, arena, tmp.dir, .{
        .id = "s1",
        .title = "weighted",
        .messages = &.{
            .{ .role = .user, .content = "hello" },
            .{ .role = .assistant, .content = "hi there" },
        },
        .created = 1,
        .updated = 2,
    });

    const list = try listSessions(io, arena, tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("s1", list[0].id);
    // 5 + 8 bytes of message content.
    try std.testing.expectEqual(@as(usize, 13), list[0].bytes);
    try std.testing.expectEqual(@as(usize, 2), list[0].messages);

    // An empty store lists nothing rather than failing.
    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    const empty = try listSessions(io, arena, tmp2.dir);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "listSessions counts tool-call argument bytes toward the session weight" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try saveSession(io, allocator, arena, tmp.dir, .{
        .id = "tool-weight",
        .title = "tool calls",
        .messages = &.{
            .{ .role = .user, .content = "hello" },
            .{ .role = .assistant, .tool_calls = &.{.{
                .id = "c1",
                .name = "read_file",
                .arguments = "{\"path\":\"build.zig\"}",
            }} },
        },
        .created = 1,
        .updated = 2,
    });

    const list = try listSessions(io, arena, tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    // "hello" (5) + the tool-call arguments (20) = 25 bytes of transcript weight.
    try std.testing.expectEqual(@as(usize, 25), list[0].bytes);
    try std.testing.expectEqual(@as(usize, 2), list[0].messages);
}

test "rename and delete change only the selected saved session" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for ([_][]const u8{ "first", "second" }) |id| {
        try saveSession(io, allocator, arena, tmp.dir, .{
            .id = id,
            .title = id,
            .messages = &.{.{ .role = .user, .content = "preserved" }},
            .created = 10,
            .updated = 20,
        });
    }

    try renameSession(io, allocator, arena, tmp.dir, "first", "renamed");
    const renamed = try loadSession(io, allocator, arena, tmp.dir, "first");
    try std.testing.expectEqualStrings("renamed", renamed.title);
    try std.testing.expectEqualStrings("preserved", renamed.messages[0].content.?);
    try std.testing.expectEqual(@as(i64, 10), renamed.created);
    try std.testing.expectEqual(@as(i64, 20), renamed.updated);
    try std.testing.expectEqualStrings("second", (try loadSession(io, allocator, arena, tmp.dir, "second")).title);

    try deleteSession(io, arena, tmp.dir, "first");
    try std.testing.expectError(error.FileNotFound, loadSession(io, allocator, arena, tmp.dir, "first"));
    try std.testing.expectEqualStrings("second", (try loadSession(io, allocator, arena, tmp.dir, "second")).id);
}

test "listSessions skips corrupt entries without hiding valid sessions" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try saveSession(io, allocator, arena, tmp.dir, .{
        .id = "valid",
        .title = "available",
        .messages = &.{},
        .created = 1,
        .updated = 2,
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "state/sessions/corrupt.json", .data = "not json" });
    try tmp.dir.writeFile(io, .{ .sub_path = "state/sessions/ignored.txt", .data = "not json" });

    const sessions = try listSessions(io, arena, tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("valid", sessions[0].id);
}

pub fn setArchived(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, id: []const u8, archived: bool) !void {
    var s = try loadSession(io, gpa, arena, base, id);
    s.archived = archived;
    try saveSession(io, gpa, arena, base, s);
}

/// Imports a JSON chat export (OpenAI format) into a new local session.
/// Accepts an array of {"role":"user"|"assistant","content":string} (unknown
/// roles/tools are skipped) so both providers' exports and our own
/// /api/sessions/<id> JSON can be pasted without conversion.
pub fn importChat(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, title: []const u8, messages_in: []const StoredMessage) ![]const u8 {
    var out: std.ArrayList(types.Message) = .empty;
    for (messages_in) |sm| {
        if (sm.content == null or sm.content.?.len == 0) continue;
        const role = roleFromStr(sm.role) catch continue;
        if (role != .user and role != .assistant) continue;
        try out.append(arena, .{ .role = role, .content = sm.content });
    }
    if (out.items.len == 0) return error.MissingField;
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    const new_id = try std.fmt.allocPrint(arena, "sess-{d}-{d}", .{ now, @rem(std.Io.Timestamp.now(io, .real).nanoseconds, 1000000) });
    try saveSession(io, gpa, arena, base, .{
        .id = new_id,
        .title = if (title.len > 0) title else "imported chat",
        .messages = try out.toOwnedSlice(arena),
        .created = now,
        .updated = now,
        .archived = false,
    });
    return new_id;
}

/// Moves a conversation to a workspace. "" is the default one.
pub fn setWorkspace(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    base: std.Io.Dir,
    id: []const u8,
    workspace: []const u8,
) !void {
    var s = try loadSession(io, gpa, arena, base, id);
    s.workspace = workspace;
    try saveSession(io, gpa, arena, base, s);
}

test "a workspace survives a save and load" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try saveSession(io, allocator, arena, tmp.dir, .{
        .id = "ws-test",
        .title = "In a folder",
        .messages = &.{},
        .created = 1,
        .updated = 2,
        .workspace = "research",
    });
    const back = try loadSession(io, allocator, arena, tmp.dir, "ws-test");
    try std.testing.expectEqualStrings("research", back.workspace);

    // The default workspace is absence, so a session without one round-trips
    // to the empty string rather than to a literal name.
    try saveSession(io, allocator, arena, tmp.dir, .{
        .id = "ws-none",
        .title = "Loose",
        .messages = &.{},
        .created = 1,
        .updated = 2,
    });
    const loose = try loadSession(io, allocator, arena, tmp.dir, "ws-none");
    try std.testing.expectEqualStrings("", loose.workspace);
}

test "compactMessages keeps system messages and drops the oldest non-system ones" {
    var messages: std.ArrayList(types.Message) = .empty;
    defer messages.deinit(std.testing.allocator);

    // Three non-system messages of 12 chars each estimate 3 tokens (chars/4),
    // plus one system message that must survive compaction.
    try messages.append(std.testing.allocator, .{ .role = .system, .content = "sys" });
    try messages.append(std.testing.allocator, .{ .role = .user, .content = "abcdefghijkl" });
    try messages.append(std.testing.allocator, .{ .role = .user, .content = "abcdefghijkl" });
    try messages.append(std.testing.allocator, .{ .role = .assistant, .content = "abcdefghijkl" });

    // Estimated total = 9 tokens; budget 4 drops the two oldest non-system
    // messages (6 tokens) and leaves system + the newest assistant message.
    compactMessages(&messages, 4);

    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqual(types.Role.system, messages.items[0].role);
    try std.testing.expectEqual(types.Role.assistant, messages.items[1].role);
    try std.testing.expectEqualStrings("abcdefghijkl", messages.items[1].content.?);
}

test "compactMessages under a tiny budget still never drops the system message" {
    var messages: std.ArrayList(types.Message) = .empty;
    defer messages.deinit(std.testing.allocator);

    try messages.append(std.testing.allocator, .{ .role = .system, .content = "sys" });
    try messages.append(std.testing.allocator, .{ .role = .user, .content = "abcdefghijkl" });

    compactMessages(&messages, 0);
    // Only the system message can survive a zero budget.
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expectEqual(types.Role.system, messages.items[0].role);
}

test "renameSession retitles in place and deleteSession removes the file" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try saveSession(io, gpa, arena, tmp.dir, .{
        .id = "s1",
        .title = "Old",
        .messages = &.{.{ .role = .user, .content = "hello" }},
        .created = 1,
        .updated = 2,
    });

    try renameSession(io, gpa, arena, tmp.dir, "s1", "New");
    const renamed = try loadSession(io, gpa, arena, tmp.dir, "s1");
    try std.testing.expectEqualStrings("New", renamed.title);
    try std.testing.expectEqual(@as(usize, 1), renamed.messages.len);

    try deleteSession(io, arena, tmp.dir, "s1");
    try std.testing.expectError(error.FileNotFound, loadSession(io, gpa, arena, tmp.dir, "s1"));
}
test "setWorkspace moves a session into a workspace and back" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try saveSession(io, gpa, arena, tmp.dir, .{
        .id = "ws-move",
        .title = "Move me",
        .messages = &.{},
        .created = 1,
        .updated = 2,
    });

    // Move into a workspace.
    try setWorkspace(io, gpa, arena, tmp.dir, "ws-move", "research");
    const moved = try loadSession(io, gpa, arena, tmp.dir, "ws-move");
    try std.testing.expectEqualStrings("research", moved.workspace);

    // Moving back to "" is the default workspace.
    try setWorkspace(io, gpa, arena, tmp.dir, "ws-move", "");
    const loose = try loadSession(io, gpa, arena, tmp.dir, "ws-move");
    try std.testing.expectEqualStrings("", loose.workspace);
}

test "listSessions orders by most recently updated" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try saveSession(io, gpa, arena, tmp.dir, .{
        .id = "older",
        .title = "older",
        .messages = &.{},
        .created = 100,
        .updated = 100,
    });
    try saveSession(io, gpa, arena, tmp.dir, .{
        .id = "newer",
        .title = "newer",
        .messages = &.{},
        .created = 50,
        .updated = 200,
    });

    const list = try listSessions(io, arena, tmp.dir);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("newer", list[0].id);
    try std.testing.expectEqualStrings("older", list[1].id);
}

test "deleteSession on a missing session returns FileNotFound without touching the repo" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // No session exists, so deletion must fail cleanly. Everything stays
    // inside the temporary dir: nothing in the checkout (e.g. state/) may be
    // created or modified, which is what keeps this test from interfering
    // with the git tool's deny checks in the eval suite.
    try std.testing.expectError(error.FileNotFound, deleteSession(io, arena, tmp.dir, "nope"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(io, "state", .{}));
}

test "compactMessages is a no-op on an empty message list" {
    var messages: std.ArrayList(types.Message) = .empty;
    defer messages.deinit(std.testing.allocator);
    compactMessages(&messages, 0);
    try std.testing.expectEqual(@as(usize, 0), messages.items.len);
}

test "findFold matches case-insensitively and reports the position" {
    try std.testing.expectEqual(@as(?usize, 0), findFold("Hello", "hello"));
    try std.testing.expectEqual(@as(?usize, 4), findFold("say HELLO there", "hello"));
    try std.testing.expectEqual(@as(?usize, null), findFold("nothing here", "zig"));
    // A needle longer than the haystack, and an empty needle, find nothing
    // rather than matching everything.
    try std.testing.expectEqual(@as(?usize, null), findFold("hi", "hello"));
    try std.testing.expectEqual(@as(?usize, null), findFold("hello", ""));
}

test "snippetAround keeps context, marks both cuts, and flattens the line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Short enough to need no cutting: no ellipsis either end.
    const whole = snippetAround(arena, "the cron spec is wrong", 4, 4);
    try std.testing.expectEqualStrings("the cron spec is wrong", whole);

    // A match in the middle of something long is cut on both sides.
    const long = "x" ** 300 ++ " needle " ++ "y" ** 300;
    const cut = snippetAround(arena, long, 301, 6);
    try std.testing.expect(std.mem.startsWith(u8, cut, "\u{2026}"));
    try std.testing.expect(std.mem.endsWith(u8, cut, "\u{2026}"));
    try std.testing.expect(std.mem.find(u8, cut, "needle") != null);
    // Bounded by the radius either side, not by the message length.
    try std.testing.expect(cut.len < 300);

    // Newlines become spaces and control bytes are dropped, so a hit is one
    // line of safe text however the message was written.
    const messy = snippetAround(arena, "first\nsecond\ttab\x07bell", 0, 5);
    try std.testing.expectEqualStrings("first second tab" ++ "bell", messy);

    // A radius cut can land mid-codepoint. Each é is two bytes, so a radius
    // of 90 from a match at 201 cuts inside a character at both ends; the
    // snippet must stay valid UTF-8 whatever the cut position.
    const uni = "é" ** 100 ++ " needle " ++ "é" ** 100;
    const ucut = snippetAround(arena, uni, 201, 6);
    try std.testing.expect(std.unicode.utf8ValidateSlice(ucut));
    try std.testing.expect(std.mem.find(u8, ucut, "needle") != null);
    try std.testing.expect(std.mem.startsWith(u8, ucut, "\u{2026}"));
    try std.testing.expect(std.mem.endsWith(u8, ucut, "\u{2026}"));
}

test "searchSessions finds conversations by message text, newest first" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    try saveSession(io, std.testing.allocator, arena, env.tmp.dir, .{
        .id = "older",
        .title = "cron questions",
        .created = 100,
        .updated = 100,
        .messages = &.{
            .{ .role = .user, .content = "how do I read a CRON spec" },
            .{ .role = .assistant, .content = "five fields, and the cron spec is read at a fixed offset" },
        },
    });
    try saveSession(io, std.testing.allocator, arena, env.tmp.dir, .{
        .id = "newer",
        .title = "unrelated",
        .created = 200,
        .updated = 200,
        .messages = &.{.{ .role = .user, .content = "nothing to do with schedules, though it mentions a spec" }},
    });

    // Case-insensitive, and the conversation the word appears in twice is one
    // row that says so rather than two rows.
    const hits = try searchSessions(io, arena, env.tmp.dir, "cron", 10);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("older", hits[0].id);
    try std.testing.expectEqualStrings("cron questions", hits[0].title);
    try std.testing.expectEqual(@as(usize, 0), hits[0].turn);
    try std.testing.expectEqualStrings("user", hits[0].role);
    try std.testing.expectEqual(@as(usize, 1), hits[0].more);
    try std.testing.expect(std.mem.find(u8, hits[0].snippet, "CRON") != null);

    // A word in both conversations returns both, newest first.
    const both = try searchSessions(io, arena, env.tmp.dir, "spec", 10);
    try std.testing.expectEqual(@as(usize, 2), both.len);
    try std.testing.expectEqualStrings("newer", both[0].id);

    // No match is an empty list, not an error, and neither is an empty store.
    try std.testing.expectEqual(@as(usize, 0), (try searchSessions(io, arena, env.tmp.dir, "zzzz", 10)).len);
    var empty = std.testing.tmpDir(.{});
    defer empty.cleanup();
    try std.testing.expectEqual(@as(usize, 0), (try searchSessions(io, arena, empty.dir, "cron", 10)).len);

    // The limit is applied after the sort, so it keeps the newest.
    const capped = try searchSessions(io, arena, env.tmp.dir, "spec", 1);
    try std.testing.expectEqual(@as(usize, 1), capped.len);
    try std.testing.expectEqualStrings("newer", capped[0].id);
}

test "rawMayContainQuery skips a miss and still parses escaped needles" {
    try std.testing.expect(!rawMayContainQuery("{\"content\":\"hello world\"}", "zzzz"));
    try std.testing.expect(rawMayContainQuery("{\"content\":\"hello world\"}", "HELLO"));
    try std.testing.expect(rawMayContainQuery("{\"content\":\"say \\\"hi\\\"\"}", "\"hi\""));
}
