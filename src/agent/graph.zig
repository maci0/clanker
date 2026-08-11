//! Execution graph: records how an agent run unfolded — each LLM call and
//! tool invocation with timing, token usage, and outcome. `Agent.run` hands
//! the assembled graph to the `cmd_graph` WASM tool once, at the end of the
//! run, which persists it under `state/runs/<run-id>.json` and also renders
//! it back (`clanker graph [run-id]` as an ASCII tree).

const std = @import("std");

pub const NodeKind = enum {
    llm,
    tool,
    final,
    /// A fork the human resolved: the model asked, the user picked.
    decision,
    /// A verdict the run turned on: a gate, an eval, a tool whose job is to
    /// answer pass or fail. `ok` carries the verdict; `detail` says why.
    check,
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
    /// How many times this step repeated back-to-back. A retry loop shows as
    /// one node with a count rather than twenty identical lines.
    repeats: u32 = 1,
    /// For a step that sent the run back around: the iteration it returned
    /// to. 0 when this node is not a loop edge.
    loop_to: u32 = 0,
    /// Truncated preview of what this node actually produced (tool result
    /// content, or the model's message content) — capped at
    /// `output_preview_cap` bytes so a large tool result can't blow up the
    /// graph file. Lets the web UI show what happened, not just its size.
    output: []const u8 = "",
};

pub const output_preview_cap = 4000;

/// Bounds a node's recorded output to `output_preview_cap` bytes.
pub fn truncatedPreview(s: []const u8) []const u8 {
    return if (s.len > output_preview_cap) s[0..output_preview_cap] else s;
}

pub const Graph = struct {
    run_id: []const u8,
    /// The run id of the agent that spawned this run — empty for top-level
    /// runs. A nested sub-agent run records its own graph (webui-plan 3.1);
    /// this is the upward link that parents it to the caller's timeline.
    parent_run_id: []const u8 = "",
    task: []const u8,
    provider: []const u8 = "",
    started_at: i64,
    duration_ms: u64 = 0,
    nodes: std.ArrayList(Node) = .empty,

    pub fn deinit(self: *Graph, gpa: std.mem.Allocator) void {
        self.nodes.deinit(gpa);
    }

    /// Appends a node, collapsing an immediate repeat of the same step into a
    /// count and marking a step that sends the run back over ground it has
    /// already covered.
    ///
    /// An agent loop retries: the same tool with the same label runs again
    /// after a failed check, and a timeline that lists it twenty times hides
    /// the shape of the run instead of showing it.
    pub fn add(self: *Graph, gpa: std.mem.Allocator, node: Node) !void {
        if (self.nodes.items.len > 0) {
            const last = &self.nodes.items[self.nodes.items.len - 1];
            if (last.kind == node.kind and std.mem.eql(u8, last.label, node.label) and
                last.ok == node.ok and node.kind != .final)
            {
                last.repeats += 1;
                last.duration_ms += node.duration_ms;
                last.prompt_tokens += node.prompt_tokens;
                last.completion_tokens += node.completion_tokens;
                last.result_bytes += node.result_bytes;
                last.iteration = node.iteration;
                return;
            }
        }
        var n = node;
        // A step whose label already appeared in an earlier iteration is the
        // run coming back around; record where it came back to.
        if (n.kind == .tool or n.kind == .check) {
            for (self.nodes.items) |prev| {
                if (prev.iteration < n.iteration and prev.kind == n.kind and
                    std.mem.eql(u8, prev.label, n.label))
                {
                    n.loop_to = prev.iteration;
                    break;
                }
            }
        }
        try self.nodes.append(gpa, n);
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

test "truncatedPreview caps output at output_preview_cap bytes" {
    const short = "hello";
    try std.testing.expectEqualStrings(short, truncatedPreview(short));
    const big = try std.testing.allocator.alloc(u8, output_preview_cap + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    const got = truncatedPreview(big);
    try std.testing.expectEqual(output_preview_cap, got.len);
    try std.testing.expectEqual(big.ptr, got.ptr);
}

test "repeated steps collapse, and a step revisited later marks the loop" {
    const gpa = std.testing.allocator;
    var g = Graph{ .run_id = "run-test", .task = "t", .provider = "p", .started_at = 0 };
    defer g.deinit(gpa);

    // A retry loop: the same tool three times in a row inside one iteration.
    try g.add(gpa, .{ .kind = .tool, .iteration = 1, .label = "gate", .result_bytes = 10, .duration_ms = 5 });
    try g.add(gpa, .{ .kind = .tool, .iteration = 1, .label = "gate", .result_bytes = 10, .duration_ms = 5 });
    try g.add(gpa, .{ .kind = .tool, .iteration = 1, .label = "gate", .result_bytes = 10, .duration_ms = 5 });
    try std.testing.expectEqual(@as(usize, 1), g.nodes.items.len);
    try std.testing.expectEqual(@as(u32, 3), g.nodes.items[0].repeats);
    // The collapsed node carries the totals, not just the first call's.
    try std.testing.expectEqual(@as(usize, 30), g.nodes.items[0].result_bytes);
    try std.testing.expectEqual(@as(u64, 15), g.nodes.items[0].duration_ms);

    // A different outcome is a different step, even for the same tool.
    try g.add(gpa, .{ .kind = .check, .iteration = 1, .label = "gate", .ok = false });
    try std.testing.expectEqual(@as(usize, 2), g.nodes.items.len);

    // Coming back to the same tool in a later iteration is a loop edge.
    try g.add(gpa, .{ .kind = .llm, .iteration = 2, .label = "chat" });
    try g.add(gpa, .{ .kind = .tool, .iteration = 2, .label = "gate", .result_bytes = 10 });
    const revisit = g.nodes.items[g.nodes.items.len - 1];
    try std.testing.expectEqual(@as(u32, 1), revisit.loop_to);
    try std.testing.expectEqual(@as(u32, 1), revisit.repeats);

    // A first-time step is not a loop.
    try g.add(gpa, .{ .kind = .tool, .iteration = 2, .label = "read_file" });
    try std.testing.expectEqual(@as(u32, 0), g.nodes.items[g.nodes.items.len - 1].loop_to);
}

test "consecutive final nodes are never collapsed" {
    const gpa = std.testing.allocator;
    var g = Graph{ .run_id = "run-final", .task = "t", .provider = "p", .started_at = 0 };
    defer g.deinit(gpa);

    try g.add(gpa, .{ .kind = .final, .iteration = 1, .label = "final" });
    try g.add(gpa, .{ .kind = .final, .iteration = 2, .label = "final" });
    try std.testing.expectEqual(@as(usize, 2), g.nodes.items.len);
    try std.testing.expectEqual(@as(u32, 1), g.nodes.items[0].repeats);
    try std.testing.expectEqual(@as(u32, 1), g.nodes.items[1].repeats);
}

test "total tokens aggregate across nodes, collapsed repeats count once per call" {
    const gpa = std.testing.allocator;
    var g = Graph{ .run_id = "run-tokens", .task = "t", .provider = "p", .started_at = 0 };
    defer g.deinit(gpa);

    // Two separate LLM steps: 100/20 and 50/30 tokens.
    try g.add(gpa, .{ .kind = .llm, .iteration = 1, .label = "chat", .prompt_tokens = 100, .completion_tokens = 20 });
    try g.add(gpa, .{ .kind = .tool, .iteration = 1, .label = "read_file" });
    try g.add(gpa, .{ .kind = .llm, .iteration = 2, .label = "chat", .prompt_tokens = 50, .completion_tokens = 30 });
    try std.testing.expectEqual(@as(u64, 150), g.totalPromptTokens());
    try std.testing.expectEqual(@as(u64, 50), g.totalCompletionTokens());

    // A back-to-back repeat collapses into one node whose token counts are
    // summed, so the totals still reflect every underlying call.
    var g2 = Graph{ .run_id = "run-repeats", .task = "t", .provider = "p", .started_at = 0 };
    defer g2.deinit(gpa);
    try g2.add(gpa, .{ .kind = .llm, .iteration = 1, .label = "chat", .prompt_tokens = 10, .completion_tokens = 5 });
    try g2.add(gpa, .{ .kind = .llm, .iteration = 1, .label = "chat", .prompt_tokens = 10, .completion_tokens = 5 });
    try g2.add(gpa, .{ .kind = .llm, .iteration = 1, .label = "chat", .prompt_tokens = 10, .completion_tokens = 5 });
    try std.testing.expectEqual(@as(usize, 1), g2.nodes.items.len);
    try std.testing.expectEqual(@as(u32, 3), g2.nodes.items[0].repeats);
    try std.testing.expectEqual(@as(u64, 30), g2.totalPromptTokens());
    try std.testing.expectEqual(@as(u64, 15), g2.totalCompletionTokens());

    // An empty graph totals to zero.
    var g3 = Graph{ .run_id = "run-empty", .task = "t", .provider = "p", .started_at = 0 };
    defer g3.deinit(gpa);
    try std.testing.expectEqual(@as(u64, 0), g3.totalPromptTokens());
    try std.testing.expectEqual(@as(u64, 0), g3.totalCompletionTokens());
}
