//! The agent loop: think (LLM chat) -> act (execute WASM tool calls) ->
//! observe (feed results back), until the model answers without tool calls.

const std = @import("std");
const config = @import("../config.zig");
const types = @import("../llm/types.zig");
const client = @import("../llm/client.zig");
const providers = @import("../llm/providers.zig");
const registry = @import("../tools/registry.zig");
const runtime = @import("../sandbox/runtime.zig");
const host = @import("../sandbox/host.zig");
const system_prompt = @import("system_prompt.zig");
const log = @import("../util/log.zig");

pub const Agent = struct {
    ctx: *client.Ctx,
    arena: std.mem.Allocator,
    provider: *const config.Provider,
    cfg: *const config.Config,
    reg: *const registry.Registry,
    tool_defs: []const types.ToolDef,
    max_iterations: u32,
    /// The system prompt (arena-owned), rebuilt when skills change.
    system_prompt_text: []const u8,
    /// Loaded tool modules, keyed by tool name (wasm modules are stateful in
    /// zwasm for AssemblyScript guests — cache and reuse instead of
    /// re-instantiating per call).
    modules: std.StringArrayHashMapUnmanaged(*runtime.ToolModule) = .empty,

    pub fn init(
        ctx: *client.Ctx,
        arena: std.mem.Allocator,
        provider: *const config.Provider,
        cfg: *const config.Config,
        reg: *const registry.Registry,
        tool_defs: []const types.ToolDef,
    ) !Agent {
        const prompt_text = try system_prompt.build(arena, ctx.io, .{
            .system_prompt_file = cfg.agent.system_prompt_file,
            .skills_dir = cfg.agent.skills_dir,
            .learnings_file = cfg.agent.learnings_file,
        }, tool_defs);
        return .{
            .ctx = ctx,
            .arena = arena,
            .provider = provider,
            .cfg = cfg,
            .reg = reg,
            .tool_defs = tool_defs,
            .max_iterations = cfg.agent.max_iterations,
            .system_prompt_text = prompt_text,
        };
    }

    /// Runs the agent on a task; returns the final assistant response.
    /// The full conversation transcript is appended to `messages` (arena).
    pub fn run(self: *Agent, messages: *std.ArrayList(types.Message), task: []const u8, err_detail: *?[]const u8) !types.ChatResponse {
        // Free cached tool modules (zwasm engines/linkers) when the agent
        // finishes, whether we return a final answer, bail out, or error out.
        defer {
            var it = self.modules.iterator();
            while (it.next()) |kv| {
                kv.value_ptr.*.deinit();
            }
            self.modules.clearRetainingCapacity();
        }
        try messages.append(self.arena, .{ .role = .system, .content = self.system_prompt_text });
        try messages.append(self.arena, .{ .role = .user, .content = task });

        var iteration: u32 = 0;
        while (iteration < self.max_iterations) : (iteration += 1) {
            const resp = try client.chat(self.ctx, self.arena, .{
                .provider = self.provider,
                .messages = messages.items,
                .tools = self.tool_defs,
            }, err_detail);

            try messages.append(self.arena, resp.message);

            const calls = resp.message.tool_calls orelse {
                return resp; // final answer
            };
            if (calls.len == 0) return resp;

            log.log(.info, "iteration {d}: {d} tool call(s)", .{ iteration + 1, calls.len });

            // Execute tool calls sequentially (parallel execution disabled:
            // zwasm instantiations on separate threads trap with
            // CallStackExhausted for batches of 2+ distinct tools).
            for (calls) |tc| {
                const result = try self.executeTool(tc);
                try messages.append(self.arena, .{
                    .role = .tool,
                    .tool_call_id = tc.id,
                    .content = result,
                });
            }
        }
        log.log(.error_, "agent hit the {d}-iteration limit without a final answer", .{self.max_iterations});
        return error.MaxIterationsExceeded;
    }

    /// Runs a single tool call in the WASM sandbox; returns arena-owned JSON.
    fn executeTool(self: *Agent, tc: types.ToolCall) ![]const u8 {
        const tool = self.reg.get(tc.name) orelse {
            log.log(.warn, "agent called unknown tool '{s}'", .{tc.name});
            return std.fmt.allocPrint(self.arena, "{{\"ok\":false,\"error\":\"unknown tool: {s}\"}}", .{tc.name});
        };

        const wasm_path = try std.fmt.allocPrint(self.ctx.gpa, "{s}", .{tool.wasm});
        defer self.ctx.gpa.free(wasm_path);
        const wasm_bytes = std.Io.Dir.cwd().readFileAlloc(self.ctx.io, wasm_path, self.ctx.gpa, .limited(1 << 20)) catch |err| {
            log.log(.error_, "tool '{s}': cannot load {s}: {s} (run `zig build tools`)", .{ tc.name, wasm_path, @errorName(err) });
            return error.ToolWasmMissing;
        };
        defer self.ctx.gpa.free(wasm_bytes);

        var sb = host.Sandbox{
            .gpa = self.ctx.gpa,
            .io = self.ctx.io,
            .root_dir = self.cfg.agent.sandbox_root,
            .network_allow = tool.network_allow,
            .fs_prefixes = tool.fs_prefixes,
            .environ_map = self.ctx.environ_map,
        };

        log.log(.debug, "running tool '{s}' in sandbox args={s}", .{ tc.name, tc.arguments });
        const t0 = std.Io.Timestamp.now(self.ctx.io, .awake);

        const mod = if (self.modules.get(tc.name)) |m|
            m
        else blk: {
            const m = runtime.ToolModule.load(self.ctx.gpa, self.ctx.io, &sb, wasm_bytes) catch |err| {
                log.log(.error_, "tool '{s}': sandbox load failed: {s}", .{ tc.name, @errorName(err) });
                return error.ToolLoadFailed;
            };
            try self.modules.put(self.arena, tc.name, m);
            break :blk m;
        };

        const out = mod.runTool(tc.arguments) catch |err| {
            log.log(.error_, "tool '{s}' failed: {s}", .{ tc.name, @errorName(err) });
            return error.ToolExecutionFailed;
        };
        defer self.ctx.gpa.free(out);
        const t1 = std.Io.Timestamp.now(self.ctx.io, .awake);
        const ms = @divTrunc(t0.durationTo(t1).nanoseconds, std.time.ns_per_ms);
        _ = &t0;

        // Arena-own the result for the conversation history.
        const owned = try self.arena.dupe(u8, out);
        log.log(.info, "tool '{s}' -> {d} bytes in {d}ms", .{ tc.name, out.len, ms });
        return owned;
    }
};

const ToolWorker = struct {
    ctx: *client.Ctx,
    cfg: *const config.Config,
    tool: *const registry.Tool,
    arguments: []const u8,
    wasm_bytes: []const u8,
    out: ?[]u8 = null,
    err: ?anyerror = null,

    fn run(self: *ToolWorker) void {
        self.execute() catch |e| {
            self.err = e;
        };
    }

    fn execute(self: *ToolWorker) !void {
        // Give each worker its own thread-safe I/O context so concurrent
        // zwasm instantiations cannot corrupt shared state and recurse
        // into a stack overflow.
        var threaded = std.Io.Threaded.init(self.ctx.gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var sb = host.Sandbox{
            .gpa = self.ctx.gpa,
            .io = io,
            .root_dir = self.cfg.agent.sandbox_root,
            .network_allow = self.tool.network_allow,
            .fs_prefixes = self.tool.fs_prefixes,
            .environ_map = self.ctx.environ_map,
        };

        log.log(.debug, "running tool '{s}' in sandbox args={s}", .{ self.tool.name, self.arguments });
        const t0 = std.Io.Timestamp.now(io, .awake);

        var mod = try runtime.ToolModule.load(self.ctx.gpa, io, &sb, self.wasm_bytes);
        defer mod.deinit();

        const out = try mod.runTool(self.arguments);
        const t1 = std.Io.Timestamp.now(io, .awake);
        const ms = @divTrunc(t0.durationTo(t1).nanoseconds, std.time.ns_per_ms);
        log.log(.info, "tool '{s}' -> {d} bytes in {d}ms", .{ self.tool.name, out.len, ms });
        self.out = out;
    }
};
