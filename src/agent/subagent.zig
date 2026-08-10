//! Nested sub-agent runs: powers the `subagent` WASM tool via the
//! host.SubagentRunner callback wired by the app when modules.subagents is
//! enabled. A sub-agent is a fresh Agent with its own context and a bounded
//! iteration budget; sub-agents cannot spawn further sub-agents (no runaway
//! recursion).

const std = @import("std");
const config = @import("../config.zig");
const client = @import("../llm/client.zig");
const registry = @import("../tools/registry.zig");
const types = @import("../llm/types.zig");
const Agent = @import("loop.zig").Agent;

/// Bounded iteration budget for sub-agent runs.
const sub_max_iterations: u32 = 6;

/// Matches host.SubagentRunner: runs a nested agent on `task` and returns the
/// final answer text.
pub fn runNested(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    cfg: *const config.Config,
    task: []const u8,
    provider_name: ?[]const u8,
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
    var a = try Agent.init(&ctx, arena, provider, cfg, &reg, tool_defs);
    a.max_iterations = sub_max_iterations;
    // Sub-agents may not spawn further sub-agents.
    a.subagent_runner = null;
    // Run tools sequentially: the nested run happens on a tool-call thread
    // already, so spawning worker threads from within would explode threads.
    a.no_parallel_tools = true;

    var messages: std.ArrayList(types.Message) = .empty;
    var err_detail: ?[]const u8 = null;
    const resp = try a.run(&messages, task, &err_detail);
    // gpa-owned so the caller (ckSubagent) can use it after this fn's arena
    // is gone; the caller frees it.
    return gpa.dupe(u8, resp.message.content orelse "");
}
