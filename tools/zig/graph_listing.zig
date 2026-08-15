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
