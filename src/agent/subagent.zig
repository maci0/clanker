//! Nested sub-agent runs: powers the `subagent` WASM tool via the
//! host.SubagentRunner callback wired by the app when modules.subagents is
//! enabled. A sub-agent is a fresh Agent with its own context and a bounded
//! iteration budget; sub-agents cannot spawn further sub-agents (no runaway
//! recursion).

const std = @import("std");
const config = @import("../config.zig");
const client = @import("../llm/client.zig");
const registry = @import("../toolhost/registry.zig");
const types = @import("../llm/types.zig");
const host = @import("../sandbox/host.zig");
const Agent = @import("loop.zig").Agent;
const private_todos = @import("private_todos.zig");
const elapsed = @import("../util/elapsed.zig");
const log = @import("../util/log.zig");

/// Bounded iteration budget for sub-agent runs.
const sub_max_iterations: u32 = 6;

/// Process-local counters for nested runs, surfaced in `/api/metrics` as the
/// `subagents` group. A nested run is a second agent loop with its own LLM
/// calls and its own unbounded wall time, and nothing else counts it: the
/// parent's `subagent` tool line reports the call's duration, but a run whose
/// worker thread never returns shows there as a tool call that never finished
/// and in no counter at all. Started minus completed is the signal for that.
/// No per-run, per-parent, or per-provider labels: those live in the correlated
/// log lines below, which keeps cardinality bounded the way the HTTP, job, and
/// schedule counters already do.
var subagent_starts_total = std.atomic.Value(u64).init(0);
var subagent_completions_total = std.atomic.Value(u64).init(0);
var subagent_errors_total = std.atomic.Value(u64).init(0);

pub const SubagentMetrics = struct {
    starts_total: u64,
    completions_total: u64,
    errors_total: u64,
};

pub fn snapshotSubagentMetrics() SubagentMetrics {
    return .{
        .starts_total = subagent_starts_total.load(.monotonic),
        .completions_total = subagent_completions_total.load(.monotonic),
        .errors_total = subagent_errors_total.load(.monotonic),
    };
}

/// The brief a parent hands down to a sub-agent; see `host.Brief`, whose
/// shape this callback matches (`host.SubagentRunner`).
pub const Brief = host.Brief;

/// Renders the brief and the task into the sub-agent's opening message.
fn briefedTask(arena: std.mem.Allocator, task: []const u8, brief: Brief) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    if (brief.parent_task.len > 0) {
        try buf.appendSlice(arena, "You are a sub-agent. The work you are part of: ");
        try buf.appendSlice(arena, brief.parent_task);
        try buf.appendSlice(arena, "\n\n");
    }
    if (brief.context.len > 0) {
        try buf.appendSlice(arena, "Already established (do not re-derive):\n");
        for (brief.context) |c| {
            try buf.appendSlice(arena, "- ");
            try buf.appendSlice(arena, c);
            try buf.appendSlice(arena, "\n");
        }
        try buf.appendSlice(arena, "\n");
    }
    if (brief.files.len > 0) {
        try buf.appendSlice(arena, "Read these first:\n");
        for (brief.files) |f| {
            try buf.appendSlice(arena, "- ");
            try buf.appendSlice(arena, f);
            try buf.appendSlice(arena, "\n");
        }
        try buf.appendSlice(arena, "\n");
    }
    if (buf.items.len == 0) return task;
    try buf.appendSlice(arena, "Your task: ");
    try buf.appendSlice(arena, task);
    try buf.appendSlice(arena, "\n\nAnswer with the result and the evidence for it. You have a short iteration budget, so do not explore beyond what the task needs. For multi-step work, track your steps on your private todo list (todo_add / todo_close / todo_list with no \"room\"): its final state is reported back with your answer, so your caller sees your progress even if you run out of iterations. If a decision hinges on something only your parent knows (context it did not put in this brief), ask it with ask_user {\"parent\": true} instead of guessing or burning iterations rediscovering it.");
    return buf.toOwnedSlice(arena);
}

/// Matches host.SubagentRunner: runs a nested agent on `task` and returns the
/// final answer text.
pub fn runNested(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    cfg: *const config.Config,
    task: []const u8,
    provider_name: ?[]const u8,
    brief: Brief,
    parent_ask: ?host.ParentAsk,
    parent_run_id: []const u8,
) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = environ_map, .cfg = cfg };
    var provider = try cfg.provider(provider_name);
    var provider_copy = provider.*;
    provider = &provider_copy;

    var reg = try registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir);
    const tool_defs = try reg.toToolDefs(arena);
    // No preset: a nested run inherits the parent's tool policy through
    // host.ToolPolicy, not through a preset object it was never handed.
    var a = try Agent.init(&ctx, arena, provider, cfg, &reg, tool_defs, null);
    defer a.deinit();
    a.max_iterations = sub_max_iterations;
    // Sub-agents may not spawn further sub-agents.
    a.subagent_runner = null;
    // Run tools sequentially: the nested run happens on a tool-call thread
    // already, so spawning worker threads from within would explode threads.
    a.serial_tools = true;
    // The parent as answerer: ask_user {"parent": true} in this run reaches
    // the agent that spawned it (see host.ParentAsk for the concurrency
    // story).
    a.parent_ask = parent_ask;
    // The nested run records its own execution graph (webui-plan 3.1). Its
    // id is nanosecond-resolution because the default "run-<seconds>" would
    // collide with the parent's, or a sibling's, spawned within the same
    // second, and one graph would silently overwrite the other. The "sub-"
    // prefix makes a nested run recognizable in state/runs/, and
    // parent_run_id is the upward link to the caller's timeline.
    const sub_run_id = try std.fmt.allocPrint(arena, "sub-{d}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    a.run_id_override = sub_run_id;
    a.parent_run_id = parent_run_id;

    // The run's private todo list: arena-owned, so it is discarded with the
    // run. Nothing about it persists except the summary appended below.
    var todos = private_todos.List{ .alloc = arena };
    a.private_todos = &todos;

    var messages: std.ArrayList(types.Message) = .empty;
    var err_detail: ?[]const u8 = null;
    // The run's own lifecycle, which nothing outside this function records: the
    // parent's `subagent` tool line names the call and how long it took, and
    // `sub-<ns>.json` is the run's graph, but neither carries the other id. The
    // lines below are what let an operator go from a slow or failed parent call
    // to the nested run that produced it, in either direction.
    const run_started = std.Io.Timestamp.now(io, .awake);
    _ = subagent_starts_total.fetchAdd(1, .monotonic);
    log.log(.debug, "subagent started run={s} parent={s} provider={s} task_bytes={d}", .{
        sub_run_id,
        parent_run_id,
        provider.name,
        task.len,
    });
    // Named rather than swallowed: the error itself travels back to the parent
    // tool call, which logs it too, but without this id.
    errdefer |err| {
        _ = subagent_errors_total.fetchAdd(1, .monotonic);
        log.log(.warn, "subagent failed run={s} parent={s} ms={d} err={s}", .{
            sub_run_id,
            parent_run_id,
            elapsed.since(io, run_started),
            @errorName(err),
        });
    }
    const resp = try a.run(&messages, try briefedTask(arena, task, brief), &err_detail);
    const content = resp.message.content orelse "";
    var answer: std.ArrayList(u8) = .empty;
    try answer.appendSlice(arena, content);
    // Surface how far the run got: with items still open (iteration cap,
    // usually) the summary is the parent's only view of the remaining work.
    const todo_summary = try private_todos.summary(&todos, arena);
    if (todo_summary.len > 0) {
        try answer.appendSlice(arena, "\n\n");
        try answer.appendSlice(arena, todo_summary);
    }
    // The link down: the parent's graph node records this result as its
    // output preview, so the sub-run id riding on the answer is what lets a
    // viewer walk from the parent's timeline into the nested one. Only when
    // a graph was actually persisted, a note pointing at nothing is noise.
    if (cfg.modules.graphs) {
        try answer.appendSlice(arena, "\n\n[subagent run: ");
        try answer.appendSlice(arena, sub_run_id);
        try answer.append(arena, ']');
    }
    // gpa-owned so the caller (ckSubagent) can use it after this fn's arena
    // is gone; the caller frees it.
    const out = try gpa.dupe(u8, answer.items);
    _ = subagent_completions_total.fetchAdd(1, .monotonic);
    log.log(.debug, "subagent finished run={s} parent={s} ms={d} bytes={d}", .{
        sub_run_id,
        parent_run_id,
        elapsed.since(io, run_started),
        out.len,
    });
    return out;
}

test "the brief tells a sub-agent what it cannot see" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const briefed = try briefedTask(arena, "Check whether runChain is reachable.", .{
        .parent_task = "wire the transform chain into executeTool",
        .context = &.{ "runChain exists but has no call site", "ast-grep cannot parse Zig here" },
        .files = &.{"src/agent/loop.zig"},
    });

    // The objective, the established facts and the pointers all survive.
    try std.testing.expect(std.mem.find(u8, briefed, "wire the transform chain") != null);
    try std.testing.expect(std.mem.find(u8, briefed, "no call site") != null);
    try std.testing.expect(std.mem.find(u8, briefed, "src/agent/loop.zig") != null);
    try std.testing.expect(std.mem.find(u8, briefed, "Check whether runChain is reachable.") != null);
    // Facts are marked as settled, or the sub-agent spends its budget
    // rediscovering them.
    try std.testing.expect(std.mem.find(u8, briefed, "do not re-derive") != null);
    // The private todo list is only useful if the sub-agent is told it has one.
    try std.testing.expect(std.mem.find(u8, briefed, "private todo list") != null);
    // Likewise the channel back up to the parent.
    try std.testing.expect(std.mem.find(u8, briefed, "ask_user {\"parent\": true}") != null);

    // With nothing to hand down, the task is passed through untouched rather
    // than wrapped in an empty preamble.
    const bare = try briefedTask(arena, "just do this", .{});
    try std.testing.expectEqualStrings("just do this", bare);
}
