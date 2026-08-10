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

const event_path = "state/autolearn.jsonl";

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
    std.Io.Dir.cwd().createDirPath(io, "state") catch return;
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

fn appendLine(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, line: []const u8) void {
    const existing = std.Io.Dir.cwd().readFileAlloc(io, event_path, arena, .limited(1 << 24)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return,
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, existing) catch return;
    if (existing.len > 0 and existing[existing.len - 1] != '\n') out.append(gpa, '\n') catch return;
    out.appendSlice(gpa, line) catch return;
    out.append(gpa, '\n') catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = event_path, .data = out.items }) catch |err| std.log.warn("autolearn: failed to persist event: {s}", .{@errorName(err)});
}

/// Records a completed run (from agent stats + used tool names).
pub fn recordRun(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, e: RunEvent) void {
    std.Io.Dir.cwd().createDirPath(io, "state") catch return;
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

const Count = struct {
    n: u64 = 0,
    detail: []const u8 = "",
};

/// Reads the event log and aggregates usage observations. Returns a markdown
/// section body (arena-owned) ready to insert under "## Autolearn".
pub fn review(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator) ![]const u8 {
    _ = gpa;
    var unknown: std.StringArrayHashMapUnmanaged(Count) = .empty;
    var errors: std.StringArrayHashMapUnmanaged(Count) = .empty;
    var tool_uses: std.StringArrayHashMapUnmanaged(u64) = .empty;
    var run_count: u64 = 0;
    var prompt_tok: u64 = 0;
    var completion_tok: u64 = 0;
    var cache_hit: u64 = 0;
    var cache_miss: u64 = 0;
    var model_uses: std.StringArrayHashMapUnmanaged(u64) = .empty;
    var task_repeats: std.StringArrayHashMapUnmanaged(u64) = .empty;

    const data = std.Io.Dir.cwd().readFileAlloc(io, event_path, arena, .limited(1 << 22)) catch null;
    if (data) |d| {
        var it = std.mem.splitScalar(u8, d, '\n');
        while (it.next()) |line| {
            const l = std.mem.trim(u8, line, " \t\r\n");
            if (l.len == 0) continue;
            const ev = std.json.parseFromSliceLeaky(Event, arena, l, .{ .ignore_unknown_fields = true }) catch continue;
            if (std.mem.eql(u8, ev.type, "unknown_tool")) {
                const gop = try unknown.getOrPut(arena, ev.tool);
                if (!gop.found_existing) gop.value_ptr.* = .{ .detail = ev.detail };
                gop.value_ptr.n += 1;
            } else if (std.mem.eql(u8, ev.type, "tool_error")) {
                const gop = try errors.getOrPut(arena, ev.tool);
                if (!gop.found_existing) gop.value_ptr.* = .{ .detail = ev.detail };
                gop.value_ptr.n += 1;
            } else if (std.mem.eql(u8, ev.type, "run")) {
                run_count += 1;
                prompt_tok += ev.prompt_tokens;
                completion_tok += ev.completion_tokens;
                cache_hit += ev.cache_hit;
                cache_miss += ev.cache_miss;
                if (ev.model.len > 0) {
                    const g = try model_uses.getOrPut(arena, ev.model);
                    if (g.found_existing) g.value_ptr.* += 1 else g.value_ptr.* = 1;
                }
                for (ev.tools) |t| {
                    const g = try tool_uses.getOrPut(arena, t);
                    if (g.found_existing) g.value_ptr.* += 1 else g.value_ptr.* = 1;
                }
                if (ev.task.len > 0) {
                    const g = try task_repeats.getOrPut(arena, ev.task);
                    if (g.found_existing) g.value_ptr.* += 1 else g.value_ptr.* = 1;
                }
            }
        }
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(arena);

    // Aggregate observations into actionable items.
    var items: std.ArrayList([]const u8) = .empty;
    defer items.deinit(arena);

    // Most-used tools.
    {
        const ToolUse = struct { name: []const u8, n: u64 };
        var list: std.ArrayList(ToolUse) = .empty;
        defer list.deinit(arena);
        var it = tool_uses.iterator();
        while (it.next()) |kv| try list.append(arena, .{ .name = kv.key_ptr.*, .n = kv.value_ptr.* });
        std.mem.sort(ToolUse, list.items, {}, struct {
            fn lt(_: void, a: ToolUse, b: ToolUse) bool {
                return a.n > b.n;
            }
        }.lt);
        if (list.items.len > 0) {
            var names: std.ArrayList(u8) = .empty;
            defer names.deinit(arena);
            for (list.items[0..@min(list.items.len, 3)]) |t| {
                if (names.items.len > 0) try names.append(arena, ',');
                try names.appendSlice(arena, t.name);
            }
            try items.append(arena, try std.fmt.allocPrint(arena, "Optimize the most-used tools: {s} (usage tracked in state/autolearn.jsonl).", .{names.items}));
        }
    }

    // Missing tools the model asked for.
    var it = unknown.iterator();
    while (it.next()) |kv| {
        try items.append(arena, try std.fmt.allocPrint(arena, "Add missing tool '{s}' (the model requested it {d} time(s)): {s}", .{ kv.key_ptr.*, kv.value_ptr.n, kv.value_ptr.detail }));
    }

    // Tool errors.
    var eit = errors.iterator();
    while (eit.next()) |kv| {
        try items.append(arena, try std.fmt.allocPrint(arena, "Fix '{s}' tool errors ({d} failure(s), last: {s})", .{ kv.key_ptr.*, kv.value_ptr.n, kv.value_ptr.detail }));
    }

    // Cache efficiency.
    const cache_total = cache_hit + cache_miss;
    if (cache_total > 0) {
        const rate: f64 = @as(f64, @floatFromInt(cache_hit)) / @as(f64, @floatFromInt(cache_total)) * 100.0;
        if (rate < 70) {
            try items.append(arena, try std.fmt.allocPrint(arena, "Improve prompt-cache hit rate ({d:.0}% across {d} run(s)): keep the system prompt and skill context byte-stable so providers cache more of the prefix.", .{ rate, run_count }));
        }
    }

    // Recurring tasks: the same task run more than once suggests a dedicated
    // tool or skill to automate it.
    var rit = task_repeats.iterator();
    while (rit.next()) |kv| {
        if (kv.value_ptr.* < 2) continue;
        try items.append(arena, try std.fmt.allocPrint(arena, "Build a dedicated tool or skill for the recurring task '{s}' (seen {d} time(s)) — automate it so future runs are one tool call instead of a full agent loop.", .{ kv.key_ptr.*, kv.value_ptr.* }));
    }

    // Model usage.
    if (model_uses.count() > 1) {
        var mit = model_uses.iterator();
        while (mit.next()) |kv| {
            try items.append(arena, try std.fmt.allocPrint(arena, "Re-evaluate default model: '{s}' used in {d} run(s) — tune its config (temperature, max_tokens, cost) or make it the default.", .{ kv.key_ptr.*, kv.value_ptr.* }));
        }
    }

    try out.appendSlice(arena, "## Autolearn\n\n");
    try out.appendSlice(arena, "Automatically observed from usage patterns (state/autolearn.jsonl + state/runs/). Refresh with `clanker autolearn`.\n\n");
    if (items.items.len == 0) {
        try out.appendSlice(arena, "- No actionable observations yet — run a few tasks, then `clanker autolearn`.\n");
    } else {
        for (items.items) |i| {
            try out.appendSlice(arena, "- ");
            try out.appendSlice(arena, i);
            try out.appendSlice(arena, "\n");
        }
    }
    try out.appendSlice(arena, "\n");
    return out.toOwnedSlice(arena);
}

/// Upserts the Autolearn section into docs/ROADMAP.md (replaces any existing
/// "## Autolearn" section).
pub fn applyRoadmap(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, section: []const u8) !void {
    const path = "docs/ROADMAP.md";
    const existing = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch "";
    const marker = "## Autolearn";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    if (std.mem.indexOf(u8, existing, marker)) |idx| {
        // Keep everything before the section, drop the old section to EOF.
        try out.appendSlice(gpa, existing[0..idx]);
    } else {
        try out.appendSlice(gpa, existing);
        if (existing.len > 0 and existing[existing.len - 1] != '\n') try out.append(gpa, '\n');
        try out.appendSlice(gpa, "\n");
    }
    try out.appendSlice(gpa, section);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

const Event = struct {
    ts: i64 = 0,
    type: []const u8 = "",
    tool: []const u8 = "",
    detail: []const u8 = "",
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    cache_hit: u64 = 0,
    cache_miss: u64 = 0,
    model: []const u8 = "",
    task: []const u8 = "",
    tools: []const []const u8 = &.{},
};
