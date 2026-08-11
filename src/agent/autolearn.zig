//! autolearn: observe how clanker is used — which tools/models run, which
//! tools the model asked for but do not exist, which tools error — and turn
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
const log = @import("../util/log.zig");
const filelock = @import("../util/filelock.zig");

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
    /// The task text (truncated), used to detect recurring task patterns.
    task: []const u8 = "",
    tools: []const []const u8 = &.{},
};

/// Appends one event line to state/autolearn.jsonl (best effort).
pub fn record(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, type_: []const u8, tool: []const u8, detail: []const u8) void {
    std.Io.Dir.cwd().createDirPath(io, "state") catch |err| {
        std.log.warn("autolearn: failed to create state dir: {s}", .{@errorName(err)});
        return;
    };
    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));

    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    s.beginObject() catch return;
    s.objectField("ts") catch return;
    s.print("{d}", .{ts}) catch return;
    s.objectField("type") catch return;
    s.write(type_) catch return;
    s.objectField("tool") catch return;
    s.write(tool) catch return;
    s.objectField("detail") catch return;
    s.write(detail) catch return;
    s.endObject() catch return;

    appendLine(io, gpa, arena, buf[0..w.end]);
}

/// Appends one line via a locked seek-to-end write: O(1) in the log size,
/// unlike a read-modify-write which turns every tool call's event into a
/// full read + rewrite of the whole log (quadratic over a session's calls).
/// The lock still guards against two processes interleaving writes.
fn appendLine(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, line: []const u8) void {
    var guard = filelock.acquire(io, std.Io.Dir.cwd(), "state", "autolearn", gpa);
    defer guard.release();

    // Trim before opening for append below: trimming rewrites the file and
    // would otherwise contend with the handle appendLine is about to hold.
    if (std.Io.Dir.cwd().statFile(io, event_path, .{})) |st| {
        if (st.size > max_log_bytes) trimLog(io, gpa, arena) catch {};
    } else |_| {}

    const file = std.Io.Dir.cwd().createFile(io, event_path, .{ .truncate = false }) catch |err| {
        std.log.warn("autolearn: failed to open {s}: {s}", .{ event_path, @errorName(err) });
        return;
    };
    defer file.close(io);
    const size = (file.stat(io) catch return).size;
    var wbuf: [512]u8 = undefined;
    var fw = file.writer(io, &wbuf);
    fw.seekToUnbuffered(size) catch return;
    fw.interface.writeAll(line) catch return;
    fw.interface.writeAll("\n") catch return;
    fw.flush() catch return;
}

/// Rewrites the log keeping only the newest `keep_lines` lines.
fn trimLog(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator) !void {
    _ = arena;
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, event_path, gpa, .limited(max_log_bytes));
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
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = event_path, .data = out.items });
}

/// Records a completed run (from agent stats + used tool names).
pub fn recordRun(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, e: RunEvent) void {
    std.Io.Dir.cwd().createDirPath(io, "state") catch |err| {
        std.log.warn("autolearn: failed to create state dir: {s}", .{@errorName(err)});
        return;
    };
    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));

    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    s.beginObject() catch return;
    s.objectField("ts") catch return;
    s.print("{d}", .{ts}) catch return;
    s.objectField("type") catch return;
    s.write("run") catch return;
    s.objectField("provider") catch return;
    s.write(e.provider) catch return;
    s.objectField("model") catch return;
    s.write(e.model) catch return;
    s.objectField("prompt_tokens") catch return;
    s.print("{d}", .{e.prompt_tokens}) catch return;
    s.objectField("completion_tokens") catch return;
    s.print("{d}", .{e.completion_tokens}) catch return;
    s.objectField("cache_hit") catch return;
    s.print("{d}", .{e.cache_hit}) catch return;
    s.objectField("cache_miss") catch return;
    s.print("{d}", .{e.cache_miss}) catch return;
    s.objectField("duration_ms") catch return;
    s.print("{d}", .{e.duration_ms}) catch return;
    s.objectField("task") catch return;
    s.write(e.task) catch return;
    s.objectField("tools") catch return;
    s.beginArray() catch return;
    for (e.tools) |t| s.write(t) catch return;
    s.endArray() catch return;
    s.endObject() catch return;

    appendLine(io, gpa, arena, buf[0..w.end]);
}

// Aggregating state/autolearn.jsonl into roadmap items and upserting
// docs/ROADMAP.md is a fs-scoped read/aggregate/write, once per `clanker
// autolearn` invocation: that shape lives in the cmd_autolearn WASM tool
// (tools/zig/cmd_autolearn.zig), not here. record()/recordRun() stay native
// because they run inside the agent loop's hot path (every tool call / every
// run), where a WASM dispatch per call would add real overhead.
