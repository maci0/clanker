//! cmd_graph: read execution graphs (state/runs/*.json).
//! Input:  {"args": "" | "list" | "<run-id>" | "json" | "json <run-id>"}
//! Output: {"ok": true, "text": "..."}
//!
//! `""` renders the latest run, `<run-id>` renders that one, `list` prints one
//! line per run. The `json` modes put machine-readable text in the same field:
//! `json` is an array of run summaries and `json <run-id>` is a whole graph.
//! The web UI serves those two through `GET /api/runs` so the harness never
//! reads `state/runs/` itself.

const std = @import("std");
const lib = @import("lib.zig");

const GraphNode = struct {
    kind: []const u8 = "",
    iteration: u32 = 0,
    label: []const u8 = "",
    detail: []const u8 = "",
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    result_bytes: usize = 0,
    duration_ms: u64 = 0,
    ok: bool = true,
    output: []const u8 = "",
};

const GraphFile = struct {
    run_id: []const u8 = "",
    task: []const u8 = "",
    provider: []const u8 = "",
    duration_ms: u64 = 0,
    total_prompt_tokens: u64 = 0,
    total_completion_tokens: u64 = 0,
    nodes: []const GraphNode = &.{},
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = std.heap.wasm_allocator;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, input, .{});
    var args: []const u8 = "";
    if (parsed == .object) {
        if (parsed.object.get("args")) |a| {
            if (a == .string) args = std.mem.trim(u8, a.string, " \t");
        }
    }

    const raw = lib.fsList("state/runs") catch |err| return errJson(out, @errorName(err));
    const names = try std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{});

    if (std.mem.eql(u8, args, "list")) return listRuns(out, alloc, names);
    if (std.mem.eql(u8, args, "json")) return listRunsJson(out, alloc, names);
    if (std.mem.startsWith(u8, args, "json ")) {
        const want = std.mem.trim(u8, args["json ".len..], " \t");
        return runJson(out, alloc, names, want);
    }

    // No argument renders the most recent run (run-<ts> sorts chronologically);
    // an argument names the run to render.
    var best: ?[]const u8 = null;
    if (names == .array) {
        for (names.array.items) |item| {
            if (item != .string) continue;
            if (!std.mem.endsWith(u8, item.string, ".json")) continue;
            if (args.len > 0) {
                const stem = item.string[0 .. item.string.len - ".json".len];
                if (std.mem.eql(u8, stem, args)) best = item.string;
                continue;
            }
            if (best == null or std.mem.lessThan(u8, best.?, item.string)) best = item.string;
        }
    }
    const fname = best orelse {
        if (args.len > 0) return errJson(out, "no such run");
        try out.writeAll("{\"ok\":true,\"text\":\"(no runs yet — clanker run creates one)\"}");
        return;
    };
    const path = try std.fmt.allocPrint(std.heap.wasm_allocator, "state/runs/{s}", .{fname});
    defer std.heap.wasm_allocator.free(path);
    const content = lib.fsRead(path) catch |err| return errJson(out, @errorName(err));
    const g = std.json.parseFromSliceLeaky(GraphFile, std.heap.wasm_allocator, content, .{ .ignore_unknown_fields = true }) catch |err| return errJson(out, @errorName(err));

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.wasm_allocator);
    try buf.appendSlice(std.heap.wasm_allocator, g.run_id);
    try buf.appendSlice(std.heap.wasm_allocator, " — ");
    try buf.appendSlice(std.heap.wasm_allocator, g.task);
    const hdr = try std.fmt.allocPrint(std.heap.wasm_allocator, "  ({s}, {d}ms, prompt={d} completion={d})\n", .{ g.provider, g.duration_ms, g.total_prompt_tokens, g.total_completion_tokens });
    defer std.heap.wasm_allocator.free(hdr);
    try buf.appendSlice(std.heap.wasm_allocator, hdr);

    var iter_note: u32 = 0;
    for (g.nodes) |n| {
        if (n.iteration != iter_note) {
            iter_note = n.iteration;
            if (iter_note > 1) try buf.append(std.heap.wasm_allocator, '\n');
            const ih = try std.fmt.allocPrint(std.heap.wasm_allocator, "iter {d}\n", .{n.iteration});
            defer std.heap.wasm_allocator.free(ih);
            try buf.appendSlice(std.heap.wasm_allocator, ih);
        }
        if (std.mem.eql(u8, n.kind, "tool")) {
            const line = try std.fmt.allocPrint(std.heap.wasm_allocator, "  tool {s}  {d} B\n", .{ n.label, n.result_bytes });
            defer std.heap.wasm_allocator.free(line);
            try buf.appendSlice(std.heap.wasm_allocator, line);
        } else if (std.mem.eql(u8, n.kind, "final")) {
            const line = try std.fmt.allocPrint(std.heap.wasm_allocator, "  done {d} B, {s}\n", .{ n.result_bytes, n.detail });
            defer std.heap.wasm_allocator.free(line);
            try buf.appendSlice(std.heap.wasm_allocator, line);
        } else {
            const ntps: f64 = if (n.duration_ms > 0) @as(f64, @floatFromInt(n.completion_tokens)) / (@as(f64, @floatFromInt(n.duration_ms)) / 1000.0) else 0;
            const line = try std.fmt.allocPrint(std.heap.wasm_allocator, "  llm  {s}  {d}/{d} tok, {d}ms ({d:.1} tok/s)\n", .{ n.label, n.prompt_tokens, n.completion_tokens, n.duration_ms, ntps });
            defer std.heap.wasm_allocator.free(line);
            try buf.appendSlice(std.heap.wasm_allocator, line);
        }
    }

    var rbuf: [65536]u8 = undefined;
    var w: std.Io.Writer = .fixed(&rbuf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(buf.items);
    try s.endObject();
    try out.writeAll(rbuf[0..w.end]);
}

/// `list`: one line per recorded run, oldest first, with the task and shape of
/// each so a run id can be picked out and rendered.
fn listRuns(out: *lib.Out, alloc: std.mem.Allocator, names: std.json.Value) !void {
    if (names != .array or names.array.items.len == 0)
        return writeText(out, "(no runs yet — clanker run creates one)");

    var files: std.ArrayList([]const u8) = .empty;
    for (names.array.items) |item| {
        if (item != .string) continue;
        if (!std.mem.endsWith(u8, item.string, ".json")) continue;
        try files.append(alloc, item.string);
    }
    std.mem.sort([]const u8, files.items, {}, lessThanStr);

    var buf: std.ArrayList(u8) = .empty;
    for (files.items) |fname| {
        const path = try std.fmt.allocPrint(alloc, "state/runs/{s}", .{fname});
        const content = lib.fsRead(path) catch continue;
        const g = std.json.parseFromSliceLeaky(GraphFile, alloc, content, .{ .ignore_unknown_fields = true }) catch continue;
        const line = try std.fmt.allocPrint(alloc, "{s}\t{d}ms\t{d} node(s)\t{s}\n", .{ g.run_id, g.duration_ms, g.nodes.len, g.task });
        try buf.appendSlice(alloc, line);
    }
    try writeText(out, buf.items);
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// `json`: newest-first array of run summaries, for the web UI's run picker.
fn listRunsJson(out: *lib.Out, alloc: std.mem.Allocator, names: std.json.Value) !void {
    var files: std.ArrayList([]const u8) = .empty;
    if (names == .array) {
        for (names.array.items) |item| {
            if (item != .string) continue;
            if (!std.mem.endsWith(u8, item.string, ".json")) continue;
            try files.append(alloc, item.string);
        }
    }
    std.mem.sort([]const u8, files.items, {}, lessThanStr);

    var buf: [48 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginArray();
    // Newest first, and capped: the picker shows recent runs, not the archive.
    var shown: usize = 0;
    var i: usize = files.items.len;
    while (i > 0 and shown < 50) {
        i -= 1;
        const path = try std.fmt.allocPrint(alloc, "state/runs/{s}", .{files.items[i]});
        const content = lib.fsRead(path) catch continue;
        const g = std.json.parseFromSliceLeaky(GraphFile, alloc, content, .{ .ignore_unknown_fields = true }) catch continue;
        shown += 1;
        try s.beginObject();
        try s.objectField("run_id");
        try s.write(g.run_id);
        try s.objectField("task");
        try s.write(g.task);
        try s.objectField("provider");
        try s.write(g.provider);
        try s.objectField("duration_ms");
        try s.write(g.duration_ms);
        try s.objectField("nodes");
        try s.write(g.nodes.len);
        try s.objectField("prompt_tokens");
        try s.write(g.total_prompt_tokens);
        try s.objectField("completion_tokens");
        try s.write(g.total_completion_tokens);
        try s.endObject();
    }
    try s.endArray();
    try writeText(out, buf[0..w.end]);
}

/// `json <run-id>`: the whole graph, node by node, for the web UI's chart.
fn runJson(out: *lib.Out, alloc: std.mem.Allocator, names: std.json.Value, want: []const u8) !void {
    if (want.len == 0) return errJson(out, "usage: json <run-id>");
    var found: ?[]const u8 = null;
    if (names == .array) {
        for (names.array.items) |item| {
            if (item != .string) continue;
            if (!std.mem.endsWith(u8, item.string, ".json")) continue;
            const stem = item.string[0 .. item.string.len - ".json".len];
            if (std.mem.eql(u8, stem, want)) found = item.string;
        }
    }
    const fname = found orelse return errJson(out, "no such run");
    const path = try std.fmt.allocPrint(alloc, "state/runs/{s}", .{fname});
    const content = lib.fsRead(path) catch |err| return errJson(out, @errorName(err));
    // Parsed and re-emitted rather than passed through, so a hand-edited file
    // in state/runs/ cannot become the response body verbatim.
    const g = std.json.parseFromSliceLeaky(GraphFile, alloc, content, .{ .ignore_unknown_fields = true }) catch |err| return errJson(out, @errorName(err));

    var buf: [48 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.write(g);
    try writeText(out, buf[0..w.end]);
}

fn writeText(out: *lib.Out, text: []const u8) !void {
    var buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(text);
    try s.endObject();
    try out.writeAll(buf[0..w.end]);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
