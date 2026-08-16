//! graph: read and persist execution graphs (state/runs/*.json).
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
const graph_listing = @import("graph_listing.zig");

const GraphFile = graph_listing.GraphFile;
const listingFromName = graph_listing.listingFromName;
const listingNodeCount = graph_listing.listingNodeCount;
const labelOf = graph_listing.labelOf;
const lessThanChronological = graph_listing.lessThanChronological;

/// Graphs collect a bounded preview for every LLM and tool step. A long run
/// therefore legitimately exceeds the normal 64 KiB tool-request buffer when
/// the agent hands the complete graph here at shutdown. Keep that extra linear
/// memory local to graph rather than charging every WASM guest for it.
pub const input_scratch_cap = 2 * 1024 * 1024;

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

    // Same as sessions: state/runs does not exist until the first run
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

    // No argument renders the most recent run; an argument names the run to
    // render. "Most recent" is the largest timestamp, not the largest name:
    // a nested `sub-<ns>` id is lexically greater than every `run-<s>` id.
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
            if (best == null or lessThanChronological({}, best.?, item.string)) best = item.string;
        }
    }
    const fname = best orelse {
        if (args.len > 0) return lib.fail(out, "no such run");
        try out.writeAll("{\"ok\":true,\"text\":\"(no runs yet; clanker run creates one)\"}");
        return;
    };
    const path = try std.fmt.allocPrint(lib.alloc, "state/runs/{s}", .{fname});
    defer lib.alloc.free(path);
    const content = lib.fsRead(path) catch |err| return lib.failErr(out, err, "reading the run graph");
    const g = std.json.parseFromSliceLeaky(GraphFile, lib.alloc, content, .{ .ignore_unknown_fields = true }) catch |err| return lib.failErr(out, err, "reading the run graph");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(lib.alloc);
    try buf.appendSlice(lib.alloc, g.run_id);
    try buf.appendSlice(lib.alloc, ": ");
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

/// `list`: one line per recorded run, oldest first within the newest page,
/// with the task and shape of each so a run id can be picked out and rendered.
fn listRuns(out: *lib.Out, alloc: std.mem.Allocator, names: std.json.Value) !void {
    if (names != .array or names.array.items.len == 0)
        return lib.okText(out, "(no runs yet; clanker run creates one)");

    var files: std.ArrayList([]const u8) = .empty;
    for (names.array.items) |item| {
        if (item != .string) continue;
        if (!std.mem.endsWith(u8, item.string, ".json")) continue;
        try files.append(alloc, item.string);
    }
    std.mem.sort([]const u8, files.items, {}, lessThanChronological);

    // Same 50-run page as `json`: a 48 KiB prefix per file used to exhaust
    // the 1 MiB host arena after ~21 rows and drop the rest.
    const start = if (files.items.len > list_cap) files.items.len - list_cap else 0;
    const page = files.items[start..];

    var id_w: usize = 0;
    var dur_w: usize = 0;
    var node_w: usize = 0;
    var graphs: std.ArrayList(GraphFile) = .empty;
    for (page) |fname| {
        const path = try std.fmt.allocPrint(alloc, "state/runs/{s}", .{fname});
        const g = loadGraphListing(alloc, path, fname);
        id_w = @max(id_w, g.run_id.len);
        var dbuf: [16]u8 = undefined;
        if (std.fmt.bufPrint(&dbuf, "{d}ms", .{g.duration_ms})) |s| dur_w = @max(dur_w, s.len) else |_| {}
        var nbuf: [16]u8 = undefined;
        if (std.fmt.bufPrint(&nbuf, "{d} nodes", .{listingNodeCount(g)})) |s| node_w = @max(node_w, s.len) else |_| {}
        try graphs.append(alloc, g);
    }
    var buf: std.ArrayList(u8) = .empty;
    if (start > 0) {
        try buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, "(newest {d} of {d})\n", .{ list_cap, files.items.len }));
    }
    for (graphs.items) |g| {
        try buf.appendSlice(alloc, g.run_id);
        var col: usize = g.run_id.len;
        while (col < id_w + 2) : (col += 1) try buf.append(alloc, ' ');
        const dur_str = try std.fmt.allocPrint(alloc, "{d}ms", .{g.duration_ms});
        try buf.appendSlice(alloc, dur_str);
        col = dur_str.len;
        while (col < dur_w + 2) : (col += 1) try buf.append(alloc, ' ');
        const node_str = try std.fmt.allocPrint(alloc, "{d} nodes", .{listingNodeCount(g)});
        try buf.appendSlice(alloc, node_str);
        col = node_str.len;
        while (col < node_w + 2) : (col += 1) try buf.append(alloc, ' ');
        try buf.appendSlice(alloc, labelOf(g.task));
        try buf.append(alloc, '\n');
    }
    try lib.okText(out, buf.items);
}

/// Prefix a picker needs. Listing scalars sit in front of `task`/`nodes` on
/// newly written graphs, so 4 KiB is enough for a label and the counts. A
/// 48 KiB window times a few dozen files exhausted the 1 MiB host arena
/// mid-list (a full ck_fs_read of each graph used to do the same sooner).
const listing_prefix_bytes: usize = 4 * 1024;
/// Newest runs shown by `list` and `json`. Matches the web picker's page.
const list_cap: usize = 50;

fn closeJsonBeforeField(alloc: std.mem.Allocator, raw: []const u8, field: []const u8) ?[]const u8 {
    var needle_buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, ",\"{s}\":", .{field}) catch return null;
    const at = std.mem.find(u8, raw, needle) orelse return null;
    const prefix = std.mem.trimEnd(u8, raw[0..at], " \t\r\n");
    if (prefix.len == 0 or prefix[0] != '{') return null;
    return std.fmt.allocPrint(alloc, "{s}}}", .{prefix}) catch null;
}

fn loadGraphListing(alloc: std.mem.Allocator, path: []const u8, fname: []const u8) GraphFile {
    const fallback = listingFromName(fname);
    const content = lib.fsReadRange(path, 0, listing_prefix_bytes) catch return fallback;
    const trimmed = std.mem.trimEnd(u8, content, " \t\r\n");
    // A file that fit in the prefix is complete: keep `nodes` so older
    // graphs without `node_count` still report a length. A truncated
    // prefix is closed in front of `nodes`, or in front of `task` when a
    // long prompt pushed the array out of the window (new files write
    // listing scalars before `task`, so that cut still keeps the counts).
    const src = if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '}')
        trimmed
    else
        closeJsonBeforeField(alloc, content, "nodes") orelse
            closeJsonBeforeField(alloc, content, "task") orelse content;
    return std.json.parseFromSliceLeaky(GraphFile, alloc, src, .{ .ignore_unknown_fields = true }) catch fallback;
}

/// `json`: newest-first array of run summaries, for the web UI's run picker.
/// Newest is by start time, so a `run-<seconds>` and a `sub-<nanoseconds>` id
/// interleave; see `graph_listing.lessThanChronological`.
fn listRunsJson(out: *lib.Out, alloc: std.mem.Allocator, names: std.json.Value) !void {
    var files: std.ArrayList([]const u8) = .empty;
    if (names == .array) {
        for (names.array.items) |item| {
            if (item != .string) continue;
            if (!std.mem.endsWith(u8, item.string, ".json")) continue;
            try files.append(alloc, item.string);
        }
    }
    std.mem.sort([]const u8, files.items, {}, lessThanChronological);

    var enc: std.Io.Writer.Allocating = .init(alloc);
    var s = std.json.Stringify{ .writer = &enc.writer, .options = .{ .emit_null_optional_fields = false } };
    try s.beginArray();
    // A task can be the whole pasted prompt: one 23 KB task used to overflow
    // a fixed buffer and fail the entire list, taking the run picker with it.
    // The picker shows a label, so a label is all that is sent.
    // Newest first, and capped: the picker shows recent runs, not the archive.
    var shown: usize = 0;
    var i: usize = files.items.len;
    while (i > 0 and shown < list_cap) {
        i -= 1;
        const fname = files.items[i];
        const path = try std.fmt.allocPrint(alloc, "state/runs/{s}", .{fname});
        const g = loadGraphListing(alloc, path, fname);
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
        try s.write(listingNodeCount(g));
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

    var stored = g;
    if (stored.node_count == 0) stored.node_count = std.math.cast(u32, stored.nodes.len) orelse std.math.maxInt(u32);

    var enc: std.Io.Writer.Allocating = .init(alloc);
    var s = std.json.Stringify{ .writer = &enc.writer, .options = .{ .emit_null_optional_fields = false } };
    try s.write(stored);

    const path = try std.fmt.allocPrint(alloc, "state/runs/{s}.json", .{g.run_id});
    lib.fsWrite(path, enc.written()) catch |err| return lib.failErr(out, err, "writing the run graph");
    try out.writeAll("{\"ok\":true}");
}
