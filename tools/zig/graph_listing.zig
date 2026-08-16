//! Pure run-listing primitives for tools/zig/graph.zig: the graph file shape
//! and the picker helpers over it. The guest is a sandboxed wasm module, where
//! a `test` block can never run, so this module lives here and
//! `zig build test` runs its tests on the host. The file-reading half
//! (`loadGraphListing`, which needs the sandbox fs ABI) stays in the guest.

const std = @import("std");

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

pub const GraphFile = struct {
    run_id: []const u8 = "",
    /// The run that spawned this one; empty for top-level runs. Carried so a
    /// nested (subagent) run's graph links back to its caller's.
    parent_run_id: []const u8 = "",
    provider: []const u8 = "",
    started_at: i64 = 0,
    duration_ms: u64 = 0,
    total_prompt_tokens: u64 = 0,
    total_completion_tokens: u64 = 0,
    /// Written in front of `task`/`nodes` so a picker can score a run from a
    /// 4 KiB prefix. Absent on graphs recorded before the field; those fall
    /// back to `nodes.len` when the whole file fit in the prefix.
    node_count: u32 = 0,
    /// Whether any check on this run returned a failing verdict, stamped at
    /// write time by `anyNodeFailed`. A listing reads a 4 KiB prefix and never
    /// sees `nodes`, so a run-level scalar is the only way a picker can tell a
    /// failed run from a good one; graphs recorded before the field read
    /// `false`, which is also what a run with no check node means.
    failed: bool = false,
    /// After the listing scalars: a pasted prompt can be tens of kilobytes
    /// and used to push `node_count` out of the prefix window.
    task: []const u8 = "",
    nodes: []const GraphNode = &.{},
};

pub fn stemOfJson(name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, ".json")) name[0 .. name.len - ".json".len] else name;
}

pub fn listingFromName(fname: []const u8) GraphFile {
    return .{ .run_id = stemOfJson(fname) };
}

pub fn listingNodeCount(g: GraphFile) usize {
    if (g.node_count > 0) return g.node_count;
    return g.nodes.len;
}

/// The first line of a task, clipped to a picker-sized label on a UTF-8
/// boundary so the JSON stays valid no matter where the cut lands.
pub fn labelOf(task: []const u8) []const u8 {
    const line = task[0 .. std.mem.findScalar(u8, task, '\n') orelse task.len];
    if (line.len <= label_max) return line;
    var end: usize = label_max;
    while (end > 0 and line[end] & 0xC0 == 0x80) end -= 1;
    return line[0..end];
}

const label_max = 200;

/// Graph filenames carry two different clocks: a top-level run is
/// `run-<unix seconds>` and a nested one `sub-<unix nanoseconds>` (see
/// `src/agent/subagent.zig`, which needs the finer clock because several
/// sub-agents can start within one second). Ordering the raw names puts every
/// `sub-` after every `run-` — `'s' > 'r'` — so the newest page of a listing
/// was months-old sub-runs and the web UI's run picker opened on one.
/// Compare on the timestamp instead, normalized to nanoseconds by padding the
/// digits out to nanosecond width. A name of neither shape scores 0 and keeps
/// its name order, which is what `janitor` wants for improve logs.
pub fn runOrderKey(name: []const u8) u64 {
    const stem = stemOfJson(name);
    const digits = if (std.mem.startsWith(u8, stem, "run-"))
        stem["run-".len..]
    else if (std.mem.startsWith(u8, stem, "sub-"))
        stem["sub-".len..]
    else
        return 0;
    if (digits.len == 0 or digits.len > ns_digits) return 0;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return 0;
    }
    var key: u64 = std.fmt.parseInt(u64, digits, 10) catch return 0;
    var scale = digits.len;
    while (scale < ns_digits) : (scale += 1) {
        key = std.math.mul(u64, key, 10) catch return std.math.maxInt(u64);
    }
    return key;
}

/// Width of a nanosecond unix timestamp for the era this runs in: 1.7e18 ns is
/// 19 digits, and a seconds-wide id is the same instant with nine fewer.
const ns_digits: usize = 19;

/// Oldest first, by the instant the run started rather than by filename.
/// Equal instants fall back to the name so the order stays total.
pub fn lessThanChronological(_: void, a: []const u8, b: []const u8) bool {
    const ka = runOrderKey(a);
    const kb = runOrderKey(b);
    if (ka != kb) return ka < kb;
    return std.mem.lessThan(u8, a, b);
}

/// Did any check on this run fail? Only `check` nodes carry a verdict — the
/// agent loop records one per tool declared `check: true` (`src/agent/loop.zig`)
/// — so a run with no check node is not failed, it is unjudged.
pub fn anyNodeFailed(g: GraphFile) bool {
    for (g.nodes) |n| {
        if (std.mem.eql(u8, n.kind, "check") and !n.ok) return true;
    }
    return false;
}

test anyNodeFailed {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const failed = try std.json.parseFromSliceLeaky(GraphFile, alloc, "{\"run_id\":\"run-1\",\"nodes\":[{\"kind\":\"check\",\"label\":\"gate\",\"ok\":false}]}", .{ .ignore_unknown_fields = true });
    try std.testing.expect(anyNodeFailed(failed));

    const passed = try std.json.parseFromSliceLeaky(GraphFile, alloc, "{\"run_id\":\"run-1\",\"nodes\":[{\"kind\":\"check\",\"label\":\"gate\",\"ok\":true}]}", .{ .ignore_unknown_fields = true });
    try std.testing.expect(!anyNodeFailed(passed));

    // A tool node's `ok` defaults true and is not a verdict; a run with no
    // check node at all is unjudged rather than failed.
    const unjudged = try std.json.parseFromSliceLeaky(GraphFile, alloc, "{\"run_id\":\"run-1\",\"nodes\":[{\"kind\":\"tool\",\"label\":\"read_file\"}]}", .{ .ignore_unknown_fields = true });
    try std.testing.expect(!anyNodeFailed(unjudged));

    // The listing scalar survives a prefix read that cut `nodes` away.
    const scalar_only = try std.json.parseFromSliceLeaky(GraphFile, alloc, "{\"run_id\":\"run-1\",\"node_count\":9,\"failed\":true}", .{ .ignore_unknown_fields = true });
    try std.testing.expect(scalar_only.failed);
    try std.testing.expect(!anyNodeFailed(scalar_only));
}

/// Every graph `state/runs/` holds, both id shapes. `janitor` picks its
/// retention set with this and re-checks it before deleting, so a shape left
/// out here is a file that accumulates forever — which is what `sub-` graphs
/// did while the predicate spelled out only `run-`. Requiring a parsable
/// timestamp (rather than just the prefix) keeps a hand-made `run-notes.json`
/// out of the sweep: the retention order could not rank it anyway.
pub fn isRunGraphName(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".json")) return false;
    return runOrderKey(name) != 0;
}

test isRunGraphName {
    try std.testing.expect(isRunGraphName("run-1786920177.json"));
    // The regression: a nested run's graph lives in the same directory and is
    // just as much a run graph, but only `run-` was ever swept.
    try std.testing.expect(isRunGraphName("sub-1786563209053324602.json"));
    try std.testing.expect(!isRunGraphName("run-1786920177"));
    try std.testing.expect(!isRunGraphName("improve-12.log"));
    try std.testing.expect(!isRunGraphName("run-notes.json"));
    try std.testing.expect(!isRunGraphName("goals.json"));
}

test runOrderKey {
    // Both id shapes land on the same nanosecond scale, so they interleave.
    try std.testing.expectEqual(@as(u64, 1786561572_000000000), runOrderKey("run-1786561572.json"));
    try std.testing.expectEqual(@as(u64, 1786563209053324602), runOrderKey("sub-1786563209053324602.json"));
    // Anything else sorts by name, not by a number read out of the middle.
    try std.testing.expectEqual(@as(u64, 0), runOrderKey("improve-12.log"));
    try std.testing.expectEqual(@as(u64, 0), runOrderKey("run-notanumber.json"));
    try std.testing.expectEqual(@as(u64, 0), runOrderKey("run-.json"));
}

test lessThanChronological {
    const recorded = [_][]const u8{
        "sub-1786563209053324602.json",
        "run-1786920177.json",
        "run-1786561572.json",
        "sub-1786471458413566380.json",
    };

    // The regression this replaced: `'s' > 'r'`, so a name sort collects every
    // `sub-` at the tail no matter when it ran, and the newest page of a
    // listing was months-old sub-runs.
    var by_name = recorded;
    std.mem.sort([]const u8, &by_name, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    try std.testing.expectEqualStrings("sub-1786563209053324602.json", by_name[3]);
    try std.testing.expectEqualStrings("run-1786920177.json", by_name[1]);

    // Chronological order interleaves the two shapes: the sub-run at
    // 1786471458 really did start before the run at 1786561572.
    var by_time = recorded;
    std.mem.sort([]const u8, &by_time, {}, lessThanChronological);
    try std.testing.expectEqualStrings("sub-1786471458413566380.json", by_time[0]);
    try std.testing.expectEqualStrings("run-1786561572.json", by_time[1]);
    try std.testing.expectEqualStrings("sub-1786563209053324602.json", by_time[2]);
    // Newest last: the tail is the page a listing shows.
    try std.testing.expectEqualStrings("run-1786920177.json", by_time[3]);

    // Names of an unrecognized shape keep plain name order.
    var logs = [_][]const u8{ "improve-9.log", "improve-10.log" };
    std.mem.sort([]const u8, &logs, {}, lessThanChronological);
    try std.testing.expectEqualStrings("improve-10.log", logs[0]);
}

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

test stemOfJson {
    try std.testing.expectEqualStrings("run-1", stemOfJson("run-1.json"));
    try std.testing.expectEqualStrings("run-1", stemOfJson("run-1"));
    try std.testing.expectEqualStrings("run-1", listingFromName("run-1.json").run_id);
}

test "GraphFile carries tool arguments for the web UI" {
    // parseFromSliceLeaky hands back slices with no handle to free, so the
    // parses go through an arena that is dropped at the end of the test.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src = "{\"run_id\":\"run-1\",\"task\":\"t\",\"nodes\":[{\"kind\":\"tool\",\"iteration\":1,\"label\":\"edit_file\",\"output\":\"{\\\"ok\\\":true}\",\"arguments\":\"{\\\"path\\\":\\\"a.zig\\\",\\\"old\\\":\\\"x\\\",\\\"new\\\":\\\"y\\\"}\"}]}";
    const g = try std.json.parseFromSliceLeaky(GraphFile, alloc, src, .{ .ignore_unknown_fields = true });
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
    const g0 = try std.json.parseFromSliceLeaky(GraphFile, alloc, old, .{ .ignore_unknown_fields = true });
    try std.testing.expect(g0.nodes[0].arguments == null);
}
