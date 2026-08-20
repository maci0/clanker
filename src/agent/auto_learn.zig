//! autolearn: observe how clanker is used, which tools/models run, which
//! tools the model asked for but do not exist, which tools error, and turn
//! those observations into actionable docs/ROADMAP.md items.
//!
//! Events are appended to state/autolearn.jsonl (one JSON object per line):
//!   {"ts":N,"type":"unknown_tool","tool":"x","detail":"..."}
//!   {"ts":N,"type":"tool_error","tool":"x","detail":"error name"}
//!   {"ts":N,"type":"run","provider":"kimi-k3","model":"kimi-k3",
//!    "prompt_tokens":N,"completion_tokens":N,"cache_hit":N,"cache_miss":N,
//!    "duration_ms":N,"tools":["a","b"]}
//!
//! `clanker autolearn` aggregates state/autolearn.jsonl plus the execution
//! graphs in state/runs/, then upserts an "Autolearn" section in
//! docs/ROADMAP.md with concrete, actionable items.

const std = @import("std");
const ensure_dir = @import("../util/ensure_dir.zig");
const append_line = @import("../util/append_line.zig");
const log = @import("../util/log.zig");
const file_lock = @import("../util/file_lock.zig");
const atomic_write = @import("../util/atomic_write.zig");
const utf8 = @import("../util/utf8.zig");
const test_env = @import("../util/test_env.zig");

const event_path = "state/autolearn.jsonl";
/// Hard cap on the log so a busy harness cannot grow state without bound.
const max_log_bytes = 8 << 20;
/// Lines kept when the log is trimmed for exceeding the cap.
const keep_lines = 2000;

pub const RunEvent = struct {
    provider: []const u8 = "",
    model: []const u8 = "",
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    cache_hit: u64 = 0,
    cache_miss: u64 = 0,
    duration_ms: u64 = 0,
    tools: []const []const u8 = &.{},
};

/// Byte caps for event fields written to state/autolearn.jsonl: a runaway
/// tool label, error detail, or configured name must cost a bounded number of log
/// bytes rather than grow the line or overflow a fixed buffer and silently
/// drop the observation it belongs to.
const cap_tool_bytes: usize = 128;
const cap_detail_bytes: usize = 512;
const cap_name_bytes: usize = 128;

/// Appends one event line to state/autolearn.jsonl (best effort).
pub fn record(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, type_: []const u8, tool: []const u8, detail: []const u8) void {
    recordTo(std.Io.Dir.cwd(), io, gpa, arena, type_, tool, detail);
}

fn recordTo(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, type_: []const u8, tool: []const u8, detail: []const u8) void {
    ensure_dir.ensureDir(base, io, "state") catch |err| {
        log.log(.warn, "autolearn: failed to create state dir: {s}", .{@errorName(err)});
        return;
    };
    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    // Long tool labels / error details are capped UTF-8-safe instead of
    // overflowing a fixed buffer and dropping the whole event: a runaway
    // field should cost bounded log bytes, never the observation itself.
    const tool_capped = utf8.cap(tool, cap_tool_bytes);
    const detail_capped = utf8.cap(detail, cap_detail_bytes);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const line = encodeEventLine(&out, ts, type_, tool_capped, detail_capped) catch |err| {
        // A mid-encode failure used to be seven bare `catch return`s that
        // dropped the record with no line saying so, unlike the token and
        // reasoning logs, which warn on the same failure. A lost autolearn
        // event is not user data, but a silent one is indistinguishable from
        // an event that never happened, so this says when it could not write.
        log.log(.warn, "autolearn: encode failed: {s}", .{@errorName(err)});
        return;
    };
    appendLine(base, io, gpa, arena, line);
}

/// Encodes one event record into `out` and returns the written slice. A
/// `![]const u8` return keeps every encode step propagating to the single
/// logged handler above; callers must not hold the slice past `out`'s deinit.
fn encodeEventLine(out: *std.Io.Writer.Allocating, ts: i64, type_: []const u8, tool: []const u8, detail: []const u8) ![]const u8 {
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("ts");
    try s.print("{d}", .{ts});
    try s.objectField("type");
    try s.write(type_);
    try s.objectField("tool");
    try s.write(tool);
    try s.objectField("detail");
    try s.write(detail);
    try s.endObject();
    return out.written();
}

/// Appends one line via a locked seek-to-end write: O(1) in the log size,
/// unlike a read-modify-write which turns every tool call's event into a
/// full read + rewrite of the whole log (quadratic over a session's calls).
/// The lock still guards against two processes interleaving writes.
fn appendLine(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, line: []const u8) void {
    var guard = file_lock.acquire(io, base, "state", "autolearn", gpa);
    defer guard.release();

    // Trim before opening for append below: trimming rewrites the file and
    // would otherwise contend with the handle appendLine is about to hold.
    if (base.statFile(io, event_path, .{})) |st| {
        if (st.size > max_log_bytes) trimLog(base, io, gpa, arena) catch |err| {
            log.log(.warn, "autolearn: failed to trim log: {s}", .{@errorName(err)});
        };
    } else |_| {}

    // Owner-only like every other store under state/: tool labels and error
    // detail are operational data about the user's work, and with the default
    // creation mode the file landed 0644 on first write, world-readable for
    // any other local user on a shared machine (the same exposure the privacy
    // pass removed from sessions, chatrooms, and token stats).
    const file = base.createFile(io, event_path, .{ .truncate = false, .permissions = atomic_write.private_file }) catch |err| {
        log.log(.warn, "autolearn: failed to open {s}: {s}", .{ event_path, @errorName(err) });
        return;
    };
    defer file.close(io);
    append_line.appendLine(io, file, line) catch |err| {
        log.log(.warn, "autolearn: failed to append to {s}: {s}", .{ event_path, @errorName(err) });
    };
}

/// Rewrites the log keeping only the newest `keep_lines` lines.
fn trimLog(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator) !void {
    _ = arena;
    // The file can be just over max_log_bytes when the trim is triggered: it
    // is trimmed the moment it crosses the cap, then one line is appended, so
    // it never exceeds the cap by more than a single line. Reading with the
    // same limit as the cap would fail with StreamTooLong on exactly the file
    // that needs trimming, the trim would silently never run once the log
    // crossed the cap, and it would keep growing forever. A fixed slack does
    // not help either: a single oversized detail/tool label can exceed any
    // budget, so the read is uncapped and the rewrite below brings the file
    // back under max_log_bytes.
    const raw = try base.readFileAlloc(io, event_path, gpa, .unlimited);
    defer gpa.free(raw);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0) continue;
        try lines.append(gpa, ln);
    }
    const keep = if (lines.items.len > keep_lines) lines.items.len - keep_lines else 0;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (lines.items[keep..]) |ln| {
        try out.appendSlice(gpa, ln);
        try out.append(gpa, '\n');
    }
    try atomic_write.writeFilePerms(io, base, event_path, out.items, atomic_write.private_file);
}

/// Records a completed run (from agent stats + used tool names).
pub fn recordRun(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, e: RunEvent) void {
    recordRunTo(std.Io.Dir.cwd(), io, gpa, arena, e);
}

fn recordRunTo(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, e: RunEvent) void {
    ensure_dir.ensureDir(base, io, "state") catch |err| {
        log.log(.warn, "autolearn: failed to create state dir: {s}", .{@errorName(err)});
        return;
    };
    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const line = encodeRunEventLine(&out, ts, e) catch |err| {
        // Same reason as encodeEventLine's handler: a bare `catch return` per
        // step dropped the record silently, so a lost run event was
        // indistinguishable from a run that never happened.
        log.log(.warn, "autolearn: encode failed: {s}", .{@errorName(err)});
        return;
    };
    appendLine(base, io, gpa, arena, line);
}

/// Encodes one run record into `out` and returns the written slice: the run
/// sibling of [[encodeEventLine]], whose `![]const u8` return keeps every
/// encode step propagating to the single logged handler in `recordRunTo`
/// instead of the chain of bare `catch return`s it replaces. Callers must
/// not hold the slice past `out`'s deinit.
fn encodeRunEventLine(out: *std.Io.Writer.Allocating, ts: i64, e: RunEvent) ![]const u8 {
    // Names are capped UTF-8-safe so malformed configuration cannot overflow
    // into a dropped event. User task text is deliberately not collected:
    // operational usage analytics need counts and tool names, not prompts.
    const provider_capped = utf8.cap(e.provider, cap_name_bytes);
    const model_capped = utf8.cap(e.model, cap_name_bytes);
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("ts");
    try s.print("{d}", .{ts});
    try s.objectField("type");
    try s.write("run");
    try s.objectField("provider");
    try s.write(provider_capped);
    try s.objectField("model");
    try s.write(model_capped);
    try s.objectField("prompt_tokens");
    try s.print("{d}", .{e.prompt_tokens});
    try s.objectField("completion_tokens");
    try s.print("{d}", .{e.completion_tokens});
    try s.objectField("cache_hit");
    try s.print("{d}", .{e.cache_hit});
    try s.objectField("cache_miss");
    try s.print("{d}", .{e.cache_miss});
    try s.objectField("duration_ms");
    try s.print("{d}", .{e.duration_ms});
    try s.objectField("tools");
    try s.beginArray();
    for (e.tools) |t| try s.write(utf8.cap(t, cap_name_bytes));
    try s.endArray();
    try s.endObject();
    return out.written();
}

// Aggregating state/autolearn.jsonl into roadmap items and upserting
// docs/ROADMAP.md is a fs-scoped read/aggregate/write, once per `clanker
// autolearn` invocation: that shape lives in the autolearn WASM tool
// (tools/zig/autolearn.zig), not here, including the optional `--model`
// rewrite via ck_llm. record()/recordRun() stay native because they run
// inside the agent loop's hot path (every tool call / every run), where a
// WASM dispatch per call would add real overhead.

// ------------------------------------------------------------------- tests --

test "recordTo appends without re-reading the existing log" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    recordTo(env.tmp.dir, io, std.testing.allocator, arena, "tool_call", "read_file", "");
    recordTo(env.tmp.dir, io, std.testing.allocator, arena, "tool_error", "read_file", "not found");

    const raw = try env.tmp.dir.readFileAlloc(io, event_path, std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(raw);

    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        lines += 1;
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{ .ignore_unknown_fields = true });
        try std.testing.expect(parsed.object.get("tool") != null);
    }
    try std.testing.expectEqual(@as(usize, 2), lines);
}

test "the autolearn log is owner-only on creation and survives a trim" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    // Fresh create (no file yet) must not land world-readable: the log holds
    // tool labels and error detail from the user's own runs.
    recordTo(env.tmp.dir, io, std.testing.allocator, arena, "tool_call", "read_file", "");
    var st = try env.tmp.dir.statFile(io, event_path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), @as(std.posix.mode_t, @intFromEnum(st.permissions)) & 0o777);

    // The trim path rewrites the whole file through a temp + rename; the
    // private mode must be re-applied on that rewrite, not just creation.
    try env.tmp.dir.createDirPath(io, "state");
    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < keep_lines + 10) : (i += 1) {
        const line = try std.fmt.allocPrint(arena, "{{\"ts\":{d}}}\n", .{i});
        try contents.appendSlice(std.testing.allocator, line);
    }
    try env.tmp.dir.writeFile(io, .{ .sub_path = event_path, .data = contents.items });
    try trimLog(env.tmp.dir, io, std.testing.allocator, std.testing.allocator);
    st = try env.tmp.dir.statFile(io, event_path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), @as(std.posix.mode_t, @intFromEnum(st.permissions)) & 0o777);
}

test "trimLog keeps only the newest keep_lines lines" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();

    try env.tmp.dir.createDirPath(io, "state");

    const arena = env.arena();

    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < keep_lines + 500) : (i += 1) {
        const line = try std.fmt.allocPrint(arena, "{{\"ts\":{d}}}\n", .{i});
        try contents.appendSlice(std.testing.allocator, line);
    }
    try env.tmp.dir.writeFile(io, .{ .sub_path = event_path, .data = contents.items });

    try trimLog(env.tmp.dir, io, std.testing.allocator, std.testing.allocator);

    const raw = try env.tmp.dir.readFileAlloc(io, event_path, std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(raw);
    var lines: usize = 0;
    var first_ts: ?usize = null;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        lines += 1;
        if (first_ts == null) {
            const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
            defer parsed.deinit();
            first_ts = @intCast(parsed.value.object.get("ts").?.integer);
        }
    }
    try std.testing.expectEqual(@as(usize, keep_lines), lines);
    // The oldest 500 lines (ts 0..499) were dropped.
    try std.testing.expectEqual(@as(usize, 500), first_ts.?);
}

test "recordRunTo writes a run event with all fields" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    const tools = [_][]const u8{ "read_file", "git" };
    recordRunTo(env.tmp.dir, io, std.testing.allocator, arena, .{
        .provider = "kimi-k3",
        .model = "kimi-k3",
        .prompt_tokens = 100,
        .completion_tokens = 50,
        .cache_hit = 10,
        .cache_miss = 90,
        .duration_ms = 1234,
        .tools = &tools,
    });

    const raw = try env.tmp.dir.readFileAlloc(io, event_path, std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(raw);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("run", parsed.object.get("type").?.string);
    try std.testing.expectEqualStrings("kimi-k3", parsed.object.get("provider").?.string);
    try std.testing.expectEqualStrings("kimi-k3", parsed.object.get("model").?.string);
    try std.testing.expectEqual(@as(i64, 100), parsed.object.get("prompt_tokens").?.integer);
    try std.testing.expectEqual(@as(i64, 50), parsed.object.get("completion_tokens").?.integer);
    try std.testing.expectEqual(@as(i64, 10), parsed.object.get("cache_hit").?.integer);
    try std.testing.expectEqual(@as(i64, 90), parsed.object.get("cache_miss").?.integer);
    try std.testing.expectEqual(@as(i64, 1234), parsed.object.get("duration_ms").?.integer);
    try std.testing.expect(parsed.object.get("task") == null);
    const arr = parsed.object.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 2), arr.items.len);
    try std.testing.expectEqualStrings("read_file", arr.items[0].string);
    try std.testing.expectEqualStrings("git", arr.items[1].string);
}
