//! cmd_graph: read and persist execution graphs (state/runs/*.json).
//! Input:  {"args": "" | "list" | "<run-id>" | "json" | "json <run-id>"}
//!         {"write": {run_id, task, provider, ...}}
//! Output: {"ok": true, "text": "..."}  |  {"ok": true}
//!
//! `""` renders the latest run, `<run-id>` renders that one, `list` prints one
//! line per run. The `json` modes put machine-readable text in the same field:
//! `json` is an array of run summaries and `json <run-id>` is a whole graph.
//! The web UI serves those two through `GET /api/runs` so the harness never
//! reads `state/runs/` itself.
//!
//! `write` persists a finished run: the agent loop accumulates nodes natively
//! (that part runs once per tool call, too hot for a WASM round-trip) and
//! hands the assembled graph here only once, at the end of the run, to become
//! JSON on disk.

const std = @import("std");
const lib = @import("lib.zig");

const GraphNode = struct {
    kind: []const u8 = "",
    repeats: u32 = 1,
    loop_to: u32 = 0,
    iteration: u32 = 0,
    label: []const u8 = "",
    detail: []const u8 = "",
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    result_bytes: usize = 0,
    duration_ms: u64 = 0,
    ok: bool = true,
    output: []const u8 = "",
    /// Tool-call arguments preview (JSON) recorded since the arguments field
    /// landed; absent for older runs. Re-emitted by `json <run-id>` so the
    /// web UI can render the change an edit tool made.
    arguments: ?[]const u8 = null,
};

const GraphFile = struct {
    run_id: []const u8 = "",
    /// The run that spawned this one; empty for top-level runs. Carried so a
    /// nested (subagent) run's graph links back to its caller's.
    parent_run_id: []const u8 = "",
    task: []const u8 = "",
    provider: []const u8 = "",
    started_at: i64 = 0,
    duration_ms: u64 = 0,
    total_prompt_tokens: u64 = 0,
    total_completion_tokens: u64 = 0,
    nodes: []const GraphNode = &.{},
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = lib.alloc;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, input, .{});
    if (parsed == .object) {
        if (parsed.object.get("write")) |g| return writeGraph(out, alloc, g);
    }
    var args: []const u8 = "";
    if (parsed == .object) {
        if (parsed.object.get("args")) |a| {
            if (a == .string) args = std.mem.trim(u8, a.string, " \t");
        }
    }

    // Same as cmd_sessions: state/runs does not exist until the first run
    // writes one, so a fresh checkout has no graph rather than a broken one.
    const raw: []const u8 = lib.fsList("state/runs") catch |err| switch (err) {
        error.NotFound => "[]",
        else => return lib.failErr(out, err, "reading the run graph"),
    };
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
        if (args.len > 0) return lib.fail(out, "no such run");
        try out.writeAll("{\"ok\":true,\"text\":\"(no runs yet — clanker run creates one)\"}");
        return;
    };
    const path = try std.fmt.allocPrint(lib.alloc, "state/runs/{s}", .{fname});
    defer lib.alloc.free(path);
    const content = lib.fsRead(path) catch |err| return lib.failErr(out, err, "reading the run graph");
    const g = std.json.parseFromSliceLeaky(GraphFile, lib.alloc, content, .{ .ignore_unknown_fields = true }) catch |err| return lib.failErr(out, err, "reading the run graph");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(lib.alloc);
    try buf.appendSlice(lib.alloc, g.run_id);
    try buf.appendSlice(lib.alloc, " — ");
    try buf.appendSlice(lib.alloc, g.task);
    const hdr = try std.fmt.allocPrint(lib.alloc, "  ({s}, {d}ms, prompt={d} completion={d})\n", .{ g.provider, g.duration_ms, g.total_prompt_tokens, g.total_completion_tokens });
    defer lib.alloc.free(hdr);
    try buf.appendSlice(lib.alloc, hdr);

    var iter_note: u32 = 0;
    for (g.nodes) |n| {
        if (n.iteration != iter_note) {
            iter_note = n.iteration;
            if (iter_note > 1) try buf.append(lib.alloc, '\n');
            const ih = try std.fmt.allocPrint(lib.alloc, "iter {d}\n", .{n.iteration});
            defer lib.alloc.free(ih);
            try buf.appendSlice(lib.alloc, ih);
        }
        if (std.mem.eql(u8, n.kind, "tool")) {
            // A retried step is one line with a count, and a step the run came
            // back around to says where it looped from.
            const line = if (n.repeats > 1)
                try std.fmt.allocPrint(lib.alloc, "  tool {s}  {d} B  x{d}\n", .{ n.label, n.result_bytes, n.repeats })
            else if (n.loop_to > 0)
                try std.fmt.allocPrint(lib.alloc, "  tool {s}  {d} B  (loops back to iter {d})\n", .{ n.label, n.result_bytes, n.loop_to })
            else
                try std.fmt.allocPrint(lib.alloc, "  tool {s}  {d} B\n", .{ n.label, n.result_bytes });
            defer lib.alloc.free(line);
            try buf.appendSlice(lib.alloc, line);
        } else if (std.mem.eql(u8, n.kind, "check")) {
            // The verdict a run turned on, and where it sent the run back to.
            const mark: []const u8 = if (n.ok) "pass" else "FAIL";
            const line = try std.fmt.allocPrint(lib.alloc, "  check {s} {s}{s}{s}\n", .{
                n.label,
                mark,
                if (n.detail.len > 0) "  " else "",
                n.detail,
            });
            defer lib.alloc.free(line);
            try buf.appendSlice(lib.alloc, line);
        } else if (std.mem.eql(u8, n.kind, "decision")) {
            // What the human chose, and out of what: a run that turned on a
            // human decision reads as unmotivated without it.
            const line = try std.fmt.allocPrint(lib.alloc, "  ask  {s}\n       -> {s}\n", .{ n.label, n.output });
            defer lib.alloc.free(line);
            try buf.appendSlice(lib.alloc, line);
        } else if (std.mem.eql(u8, n.kind, "final")) {
            const line = try std.fmt.allocPrint(lib.alloc, "  done {d} B, {s}\n", .{ n.result_bytes, n.detail });
            defer lib.alloc.free(line);
            try buf.appendSlice(lib.alloc, line);
        } else {
            const ntps: f64 = if (n.duration_ms > 0) @as(f64, @floatFromInt(n.completion_tokens)) / (@as(f64, @floatFromInt(n.duration_ms)) / 1000.0) else 0;
            const line = try std.fmt.allocPrint(lib.alloc, "  llm  {s}  {d}/{d} tok, {d}ms ({d:.1} tok/s)\n", .{ n.label, n.prompt_tokens, n.completion_tokens, n.duration_ms, ntps });
            defer lib.alloc.free(line);
            try buf.appendSlice(lib.alloc, line);
        }
    }

    return lib.okText(out, buf.items);
}

/// `list`: one line per recorded run, oldest first, with the task and shape of
/// each so a run id can be picked out and rendered.
fn listRuns(out: *lib.Out, alloc: std.mem.Allocator, names: std.json.Value) !void {
    if (names != .array or names.array.items.len == 0)
        return lib.okText(out, "(no runs yet — clanker run creates one)");

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
    try lib.okText(out, buf.items);
}

/// The first line of a task, clipped to a picker-sized label on a UTF-8
/// boundary so the JSON stays valid no matter where the cut lands.
fn labelOf(task: []const u8) []const u8 {
    const line = task[0 .. std.mem.findScalar(u8, task, '\n') orelse task.len];
    if (line.len <= label_max) return line;
    var end: usize = label_max;
    while (end > 0 and line[end] & 0xC0 == 0x80) end -= 1;
    return line[0..end];
}

const label_max = 200;

test labelOf {
    try std.testing.expectEqualStrings("one", labelOf("one\ntwo"));
    try std.testing.expectEqualStrings("short", labelOf("short"));
    const long = "x" ** 500;
    try std.testing.expectEqual(@as(usize, label_max), labelOf(long).len);
    // A multi-byte character straddling the cut is dropped whole, never split.
    const wide = "\u{00e9}" ** 300;
    const cut = labelOf(wide);
    try std.testing.expect(cut.len <= label_max);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "GraphFile carries tool arguments for the web UI" {
    const src = "{\"run_id\":\"run-1\",\"task\":\"t\",\"nodes\":[{\"kind\":\"tool\",\"iteration\":1,\"label\":\"edit_file\",\"output\":\"{\\\"ok\\\":true}\",\"arguments\":\"{\\\"path\\\":\\\"a.zig\\\",\\\"old\\\":\\\"x\\\",\\\"new\\\":\\\"y\\\"}\"}]}";
    const g = try std.json.parseFromSliceLeaky(GraphFile, std.testing.allocator, src, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), g.nodes.len);
    try std.testing.expectEqualStrings("edit_file", g.nodes[0].label);
    const args = g.nodes[0].arguments orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("{\"path\":\"a.zig\",\"old\":\"x\",\"new\":\"y\"}", args);
    // The web UI's view re-emits it: `json <run-id>` Stringifies GraphFile.
    var enc: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer enc.deinit();
    var s = std.json.Stringify{ .writer = &enc.writer, .options = .{ .emit_null_optional_fields = false } };
    try s.write(g);
    try std.testing.expect(std.mem.find(u8, enc.written(), "\"arguments\"") != null);
    // Old runs recorded before the field parsed fine and stay field-less.
    const old = "{\"run_id\":\"run-0\",\"task\":\"t\",\"nodes\":[{\"kind\":\"tool\",\"iteration\":1,\"label\":\"read_file\",\"output\":\"{}\"}]}";
    const g0 = try std.json.parseFromSliceLeaky(GraphFile, std.testing.allocator, old, .{ .ignore_unknown_fields = true });
    try std.testing.expect(g0.nodes[0].arguments == null);
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

    var enc: std.Io.Writer.Allocating = .init(alloc);
    var s = std.json.Stringify{ .writer = &enc.writer, .options = .{ .emit_null_optional_fields = false } };
    try s.beginArray();
    // A task can be the whole pasted prompt: one 23 KB task used to overflow
    // a fixed buffer and fail the entire list, taking the run picker with it.
    // The picker shows a label, so a label is all that is sent.
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
        try s.objectField("parent_run_id");
        try s.write(g.parent_run_id);
        try s.objectField("task");
        try s.write(labelOf(g.task));
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
    try lib.okText(out, enc.written());
}

/// `json <run-id>`: the whole graph, node by node, for the web UI's chart.
fn runJson(out: *lib.Out, alloc: std.mem.Allocator, names: std.json.Value, want: []const u8) !void {
    if (want.len == 0) return lib.fail(out, "usage: json <run-id>");
    var found: ?[]const u8 = null;
    if (names == .array) {
        for (names.array.items) |item| {
            if (item != .string) continue;
            if (!std.mem.endsWith(u8, item.string, ".json")) continue;
            const stem = item.string[0 .. item.string.len - ".json".len];
            if (std.mem.eql(u8, stem, want)) found = item.string;
        }
    }
    const fname = found orelse return lib.fail(out, "no such run");
    const path = try std.fmt.allocPrint(alloc, "state/runs/{s}", .{fname});
    const content = lib.fsRead(path) catch |err| return lib.failErr(out, err, "reading the run graph");
    // Parsed and re-emitted rather than passed through, so a hand-edited file
    // in state/runs/ cannot become the response body verbatim.
    const g = std.json.parseFromSliceLeaky(GraphFile, alloc, content, .{ .ignore_unknown_fields = true }) catch |err| return lib.failErr(out, err, "reading the run graph");

    var enc: std.Io.Writer.Allocating = .init(alloc);
    var s = std.json.Stringify{ .writer = &enc.writer, .options = .{ .emit_null_optional_fields = false } };
    try s.write(g);
    try lib.okText(out, enc.written());
}

/// `{"write": {run_id, task, provider, started_at, duration_ms, ...,
/// nodes: [...]}}`: persists a finished run's graph to
/// `state/runs/<run_id>.json`. The agent loop assembles the graph natively
/// (one call per LLM/tool step, too hot for a WASM round-trip) and hands the
/// whole thing here exactly once, at the end of the run.
fn writeGraph(out: *lib.Out, alloc: std.mem.Allocator, value: std.json.Value) !void {
    const g = std.json.parseFromValueLeaky(GraphFile, alloc, value, .{ .ignore_unknown_fields = true }) catch
        return lib.fail(out, "write needs a graph object");
    if (g.run_id.len == 0 or std.mem.findAny(u8, g.run_id, "/\\") != null)
        return lib.fail(out, "run_id must be non-empty and contain no path separators");

    var enc: std.Io.Writer.Allocating = .init(alloc);
    var s = std.json.Stringify{ .writer = &enc.writer, .options = .{ .emit_null_optional_fields = false } };
    try s.write(g);

    const path = try std.fmt.allocPrint(alloc, "state/runs/{s}.json", .{g.run_id});
    lib.fsWrite(path, enc.written()) catch |err| return lib.failErr(out, err, "writing the run graph");
    try out.writeAll("{\"ok\":true}");
}
