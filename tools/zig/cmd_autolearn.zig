//! cmd_autolearn: read state/autolearn.jsonl, aggregate usage observations
//! into actionable roadmap items, and upsert an "## Autolearn" section into
//! docs/ROADMAP.md.
//! Input:  {} (no fields used)
//! Output: {"ok": true, "text": "<the generated section>"}

const std = @import("std");
const lib = @import("lib.zig");

const event_path = "state/autolearn.jsonl";
const roadmap_path = "docs/ROADMAP.md";

const Count = struct {
    n: u64 = 0,
    detail: []const u8 = "",
};

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
    tools: []const []const u8 = &.{},
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    _ = input;
    const alloc = lib.alloc;

    var unknown: std.StringArrayHashMapUnmanaged(Count) = .empty;
    var errors: std.StringArrayHashMapUnmanaged(Count) = .empty;
    var tool_uses: std.StringArrayHashMapUnmanaged(u64) = .empty;
    var run_count: u64 = 0;
    var cache_hit: u64 = 0;
    var cache_miss: u64 = 0;
    var model_uses: std.StringArrayHashMapUnmanaged(u64) = .empty;

    const data = lib.fsRead(event_path) catch null;
    if (data) |d| {
        var it = std.mem.splitScalar(u8, d, '\n');
        while (it.next()) |line| {
            const l = std.mem.trim(u8, line, " \t\r\n");
            if (l.len == 0) continue;
            const ev = std.json.parseFromSliceLeaky(Event, alloc, l, .{ .ignore_unknown_fields = true }) catch continue;
            if (std.mem.eql(u8, ev.type, "unknown_tool")) {
                const gop = try unknown.getOrPut(alloc, ev.tool);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                gop.value_ptr.n += 1;
                // The item renders as "last: <detail>", so the newest
                // non-empty detail wins (events are appended in order).
                if (ev.detail.len > 0) gop.value_ptr.detail = ev.detail;
            } else if (std.mem.eql(u8, ev.type, "tool_error")) {
                const gop = try errors.getOrPut(alloc, ev.tool);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                gop.value_ptr.n += 1;
                if (ev.detail.len > 0) gop.value_ptr.detail = ev.detail;
            } else if (std.mem.eql(u8, ev.type, "run")) {
                run_count += 1;
                cache_hit += ev.cache_hit;
                cache_miss += ev.cache_miss;
                if (ev.model.len > 0) {
                    const g = try model_uses.getOrPut(alloc, ev.model);
                    if (g.found_existing) g.value_ptr.* += 1 else g.value_ptr.* = 1;
                }
                for (ev.tools) |t| {
                    const g = try tool_uses.getOrPut(alloc, t);
                    if (g.found_existing) g.value_ptr.* += 1 else g.value_ptr.* = 1;
                }
            }
        }
    }

    var items: std.ArrayList([]const u8) = .empty;

    // Most-used tools.
    {
        const ToolUse = struct { name: []const u8, n: u64 };
        var list: std.ArrayList(ToolUse) = .empty;
        var it = tool_uses.iterator();
        while (it.next()) |kv| try list.append(alloc, .{ .name = kv.key_ptr.*, .n = kv.value_ptr.* });
        std.mem.sort(ToolUse, list.items, {}, struct {
            fn lt(_: void, a: ToolUse, b: ToolUse) bool {
                return a.n > b.n;
            }
        }.lt);
        if (list.items.len > 0) {
            var names: std.ArrayList(u8) = .empty;
            for (list.items[0..@min(list.items.len, 3)]) |t| {
                if (names.items.len > 0) try names.append(alloc, ',');
                try names.appendSlice(alloc, t.name);
            }
            try items.append(alloc, try std.fmt.allocPrint(alloc, "Optimize the most-used tools: {s} (usage tracked in state/autolearn.jsonl).", .{names.items}));
        }
    }

    // Missing tools the model asked for.
    var it = unknown.iterator();
    while (it.next()) |kv| {
        try items.append(alloc, try std.fmt.allocPrint(alloc, "Add missing tool '{s}' (the model requested it {d} time(s)): {s}", .{ kv.key_ptr.*, kv.value_ptr.n, kv.value_ptr.detail }));
    }

    // Tool errors.
    var eit = errors.iterator();
    while (eit.next()) |kv| {
        try items.append(alloc, try std.fmt.allocPrint(alloc, "Fix '{s}' tool errors ({d} failure(s), last: {s})", .{ kv.key_ptr.*, kv.value_ptr.n, kv.value_ptr.detail }));
    }

    // Cache efficiency.
    const cache_total = cache_hit + cache_miss;
    if (cache_total > 0) {
        const rate: f64 = @as(f64, @floatFromInt(cache_hit)) / @as(f64, @floatFromInt(cache_total)) * 100.0;
        if (rate < 70) {
            try items.append(alloc, try std.fmt.allocPrint(alloc, "Improve prompt-cache hit rate ({d:.0}% across {d} run(s)): keep the system prompt and skill context byte-stable so providers cache more of the prefix.", .{ rate, run_count }));
        }
    }

    // Model usage.
    if (model_uses.count() > 1) {
        var mit = model_uses.iterator();
        while (mit.next()) |kv| {
            try items.append(alloc, try std.fmt.allocPrint(alloc, "Re-evaluate default model: '{s}' used in {d} run(s) — tune its config (temperature, max_tokens, cost) or make it the default.", .{ kv.key_ptr.*, kv.value_ptr.* }));
        }
    }

    var section: std.ArrayList(u8) = .empty;
    try section.appendSlice(alloc, "## Autolearn\n\n");
    try section.appendSlice(alloc, "Automatically observed from usage patterns (state/autolearn.jsonl). Refresh with `clanker autolearn`.\n\n");
    if (items.items.len == 0) {
        try section.appendSlice(alloc, "- No actionable observations yet — run a few tasks, then `clanker autolearn`.\n");
    } else {
        for (items.items) |i| {
            try section.appendSlice(alloc, "- ");
            try section.appendSlice(alloc, i);
            try section.appendSlice(alloc, "\n");
        }
    }
    try section.appendSlice(alloc, "\n");

    try upsertRoadmap(alloc, section.items);

    return lib.okText(out, section.items);
}

/// Replaces any existing "## Autolearn" section in docs/ROADMAP.md (from the
/// marker to EOF, since it is always the last section) with the new one.
fn upsertRoadmap(alloc: std.mem.Allocator, section: []const u8) !void {
    const existing = lib.fsRead(roadmap_path) catch "";
    const marker = "## Autolearn";
    var out: std.ArrayList(u8) = .empty;
    if (std.mem.indexOf(u8, existing, marker)) |idx| {
        try out.appendSlice(alloc, existing[0..idx]);
    } else {
        try out.appendSlice(alloc, existing);
        if (existing.len > 0 and existing[existing.len - 1] != '\n') try out.append(alloc, '\n');
        try out.appendSlice(alloc, "\n");
    }
    try out.appendSlice(alloc, section);
    try lib.fsWrite(roadmap_path, out.items);
}
