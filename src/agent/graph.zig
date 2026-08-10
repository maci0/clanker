//! Execution graph: records how an agent run unfolded — each LLM call and
//! tool invocation with timing, token usage, and outcome — and persists it as
//! JSON under `state/runs/<run-id>.json` for replay, analysis, and self-review
//! (`clanker graph [run-id]` renders it as an ASCII tree).

const std = @import("std");

pub const NodeKind = enum {
    llm,
    tool,
    final,
};

pub const Node = struct {
    kind: NodeKind,
    iteration: u32,
    /// Short label: tool name, "chat", or "final".
    label: []const u8 = "",
    /// Optional note: finish reason, error name, truncated answer.
    detail: []const u8 = "",
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    result_bytes: usize = 0,
    duration_ms: u64 = 0,
    ok: bool = true,
};

pub const Graph = struct {
    run_id: []const u8,
    task: []const u8,
    provider: []const u8 = "",
    started_at: i64,
    duration_ms: u64 = 0,
    nodes: std.ArrayList(Node) = .empty,

    pub fn deinit(self: *Graph, gpa: std.mem.Allocator) void {
        self.nodes.deinit(gpa);
    }

    pub fn add(self: *Graph, gpa: std.mem.Allocator, node: Node) !void {
        try self.nodes.append(gpa, node);
    }

    pub fn totalPromptTokens(self: *const Graph) u64 {
        var t: u64 = 0;
        for (self.nodes.items) |n| t += n.prompt_tokens;
        return t;
    }

    pub fn totalCompletionTokens(self: *const Graph) u64 {
        var t: u64 = 0;
        for (self.nodes.items) |n| t += n.completion_tokens;
        return t;
    }
};

pub const LoadedGraph = struct {
    graph: Graph,
    arena_state: std.heap.ArenaAllocator,
};

/// Serializes the graph to JSON and writes `state/runs/<run_id>.json`.
pub fn write(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, g: *const Graph) !void {
    _ = gpa;
    std.Io.Dir.cwd().createDirPath(io, "state/runs") catch {};

    var buf: [1 << 20]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("run_id");
    try s.write(g.run_id);
    try s.objectField("task");
    try s.write(g.task);
    try s.objectField("provider");
    try s.write(g.provider);
    try s.objectField("started_at");
    try s.print("{d}", .{g.started_at});
    try s.objectField("duration_ms");
    try s.print("{d}", .{g.duration_ms});
    try s.objectField("total_prompt_tokens");
    try s.print("{d}", .{g.totalPromptTokens()});
    try s.objectField("total_completion_tokens");
    try s.print("{d}", .{g.totalCompletionTokens()});
    try s.objectField("nodes");
    try s.beginArray();
    for (g.nodes.items) |n| {
        try s.beginObject();
        try s.objectField("kind");
        try s.write(switch (n.kind) {
            .llm => "llm",
            .tool => "tool",
            .final => "final",
        });
        try s.objectField("iteration");
        try s.print("{d}", .{n.iteration});
        try s.objectField("label");
        try s.write(n.label);
        try s.objectField("detail");
        try s.write(n.detail);
        try s.objectField("prompt_tokens");
        try s.print("{d}", .{n.prompt_tokens});
        try s.objectField("completion_tokens");
        try s.print("{d}", .{n.completion_tokens});
        try s.objectField("result_bytes");
        try s.print("{d}", .{n.result_bytes});
        try s.objectField("duration_ms");
        try s.print("{d}", .{n.duration_ms});
        try s.objectField("ok");
        try s.write(n.ok);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();

    const path = try std.fmt.allocPrint(arena, "state/runs/{s}.json", .{g.run_id});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf[0..w.end] });
}

/// Reads a graph JSON file back into a Graph (arena-backed).
pub fn load(io: std.Io, gpa: std.mem.Allocator, run_id: []const u8) !LoadedGraph {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    const arena = arena_state.allocator();
    const path = try std.fmt.allocPrint(arena, "state/runs/{s}.json", .{run_id});
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 24));
    const parsed = try std.json.parseFromSliceLeaky(GraphFile, arena, data, .{ .ignore_unknown_fields = true });
    var g = Graph{
        .run_id = parsed.run_id,
        .task = parsed.task,
        .provider = parsed.provider,
        .started_at = parsed.started_at,
        .duration_ms = parsed.duration_ms,
    };
    for (parsed.nodes) |n| {
        try g.nodes.append(arena, .{
            .kind = switch (std.mem.eql(u8, n.kind, "tool")) {
                true => NodeKind.tool,
                false => if (std.mem.eql(u8, n.kind, "final")) NodeKind.final else NodeKind.llm,
            },
            .iteration = n.iteration,
            .label = n.label,
            .detail = n.detail,
            .prompt_tokens = n.prompt_tokens,
            .completion_tokens = n.completion_tokens,
            .result_bytes = n.result_bytes,
            .duration_ms = n.duration_ms,
            .ok = n.ok,
        });
    }
    return .{ .graph = g, .arena_state = arena_state };
}

pub fn deinitLoaded(l: *LoadedGraph) void {
    l.arena_state.deinit();
}

const GraphFile = struct {
    run_id: []const u8,
    task: []const u8,
    provider: []const u8 = "",
    started_at: i64,
    duration_ms: u64 = 0,
    nodes: []const NodeFile = &.{},
};

const NodeFile = struct {
    kind: []const u8,
    iteration: u32 = 0,
    label: []const u8 = "",
    detail: []const u8 = "",
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    result_bytes: usize = 0,
    duration_ms: u64 = 0,
    ok: bool = true,
};

/// Lists persisted runs: (run_id, task, duration_ms, node count) pairs.
pub fn listRuns(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator) ![]const []const u8 {
    _ = gpa;
    var out: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, "state/runs", .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const id = entry.name[0 .. entry.name.len - 5];
        try out.append(arena, try arena.dupe(u8, id));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out.toOwnedSlice(arena);
}
