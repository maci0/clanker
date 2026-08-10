//! The agent loop: think (LLM chat) -> act (execute WASM tool calls) ->
//! observe (feed results back), until the model answers without tool calls.

const std = @import("std");
const config = @import("../config.zig");
const types = @import("../llm/types.zig");
const client = @import("../llm/client.zig");
const registry = @import("../tools/registry.zig");
const runtime = @import("../sandbox/runtime.zig");
const host = @import("../sandbox/host.zig");
const system_prompt = @import("system_prompt.zig");
const log = @import("../util/log.zig");

/// Cumulative token usage across all LLM calls in a single agent run.
pub const RunStats = struct {
    total_prompt_tokens: u64 = 0,
    total_completion_tokens: u64 = 0,
    total_tokens: u64 = 0,
};

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
    /// Cumulative token usage across all LLM calls in this agent run.
    stats: RunStats = .{},

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
            .stats = .{},
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
            log.log(.info, "run tokens: prompt={d} completion={d} total={d}", .{ self.stats.total_prompt_tokens, self.stats.total_completion_tokens, self.stats.total_tokens });
        }
        try messages.append(self.arena, .{ .role = .system, .content = self.system_prompt_text });
        try messages.append(self.arena, .{ .role = .user, .content = task });

        var iteration: u32 = 0;
        while (iteration < self.max_iterations) : (iteration += 1) {
            try self.maybeCompactMessages(messages);
            const resp = try client.chat(self.ctx, self.arena, .{
                .provider = self.provider,
                .messages = messages.items,
                .tools = self.tool_defs,
            }, err_detail);

            if (resp.usage) |u| {
                self.stats.total_prompt_tokens += u.prompt_tokens;
                self.stats.total_completion_tokens += u.completion_tokens;
                self.stats.total_tokens += u.prompt_tokens + u.completion_tokens;
            }

            try messages.append(self.arena, resp.message);

            const calls = resp.message.tool_calls orelse {
                return resp; // final answer
            };
            if (calls.len == 0) return resp;

            log.log(.info, "iteration {d}: {d} tool call(s)", .{ iteration + 1, calls.len });

            // Execute tool calls in parallel for distinct tool names (each on
            // a worker thread with a large stack); a tool name repeated in the
            // same batch falls back to sequential execution because the zwasm
            // module is stateful and the cached instance is reused.
            const results = try self.executeCalls(calls);
            for (calls, results) |tc, content| {
                try messages.append(self.arena, .{
                    .role = .tool,
                    .tool_call_id = tc.id,
                    .content = content,
                });
            }
        }
        log.log(.error_, "agent hit the {d}-iteration limit without a final answer", .{self.max_iterations});
        return error.MaxIterationsExceeded;
    }

    /// Compacts the conversation history to keep context size bounded: if the
    /// accumulated message bytes (content + tool arguments) exceed 24000,
    /// keeps the system message and the last 6 messages, replacing the
    /// removed middle with a single user placeholder message.
    fn maybeCompactMessages(self: *Agent, messages: *std.ArrayList(types.Message)) !void {
        var total: usize = 0;
        for (messages.items) |m| {
            if (m.content) |c| total += c.len;
            if (m.tool_calls) |calls| {
                for (calls) |tc| total += tc.arguments.len;
            }
        }
        if (total <= 24000) return;
        // Need at least system + one middle + last 6 = 8 messages to compact.
        if (messages.items.len <= 7) return;
        log.log(.info, "compacting conversation: {d} messages, {d} bytes", .{ messages.items.len, total });
        const placeholder: []const u8 = "[earlier conversation compacted — the context is summarized above in learnings and skills]";
        const new_mid = [_]types.Message{.{ .role = .user, .content = placeholder }};
        try messages.replaceRange(self.arena, 1, messages.items.len - 7, &new_mid);
    }

    /// Runs a single tool call in the WASM sandbox; returns arena-owned JSON.
    fn executeTool(self: *Agent, tc: types.ToolCall) ![]const u8 {
        const tool = self.reg.get(tc.name) orelse {
            log.log(.warn, "agent called unknown tool '{s}'", .{tc.name});
            return std.fmt.allocPrint(self.arena, "{{\"ok\":false,\"error\":\"unknown tool: {s}\"}}", .{tc.name});
        };

        const wasm_bytes = std.Io.Dir.cwd().readFileAlloc(self.ctx.io, tool.wasm, self.ctx.gpa, .limited(1 << 20)) catch |err| {
            log.log(.error_, "tool '{s}': cannot load {s}: {s} (run `zig build tools`)", .{ tc.name, tool.wasm, @errorName(err) });
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
            .seed = self.cfg.agent.seed,
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

        const out = mod.executeTool(tc.arguments) catch |err| {
            log.log(.error_, "tool '{s}' failed: {s}", .{ tc.name, @errorName(err) });
            return error.ToolExecutionFailed;
        };
        defer self.ctx.gpa.free(out);
        const t1 = std.Io.Timestamp.now(self.ctx.io, .awake);
        const ms = @divTrunc(t0.durationTo(t1).nanoseconds, std.time.ns_per_ms);

        // Arena-own the result for the conversation history.
        const owned = try self.arena.dupe(u8, out);
        log.log(.info, "tool '{s}' -> {d} bytes in {d}ms", .{ tc.name, out.len, ms });
        return owned;
    }

    /// Executes a batch of tool calls, returning arena-owned results aligned
    /// with `calls`. Distinct tool names run in parallel on worker threads;
    /// duplicate names fall back to sequential execution (zwasm modules are
    /// stateful).
    fn executeCalls(self: *Agent, calls: []const types.ToolCall) ![]const []const u8 {
        const results = try self.arena.alloc([]const u8, calls.len);
        @memset(results, "");

        // ---- parallel pass: one worker per distinct tool name ----
        var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.ctx.gpa);
        var handles: std.ArrayList(WorkerHandle) = .empty;
        defer {
            // Join + free anything not yet handled (e.g. on error return).
            for (handles.items) |h| h.thread.join();
            for (handles.items) |h| {
                self.ctx.gpa.free(h.wasm_bytes);
                self.ctx.gpa.destroy(h.worker);
            }
            handles.deinit(self.ctx.gpa);
        }

        for (calls, 0..) |tc, i| {
            if (seen.contains(tc.name)) continue; // duplicate -> sequential pass
            try seen.put(self.ctx.gpa, tc.name, {});

            const tool = self.reg.get(tc.name) orelse {
                results[i] = try std.fmt.allocPrint(self.arena, "{{\"ok\":false,\"error\":\"unknown tool: {s}\"}}", .{tc.name});
                continue;
            };
            const wasm_path = try std.fmt.allocPrint(self.ctx.gpa, "{s}", .{tool.wasm});
            defer self.ctx.gpa.free(wasm_path);
            const wasm_bytes = std.Io.Dir.cwd().readFileAlloc(self.ctx.io, wasm_path, self.ctx.gpa, .limited(1 << 20)) catch |err| {
                log.log(.error_, "tool '{s}': cannot load {s}: {s}", .{ tc.name, wasm_path, @errorName(err) });
                return error.ToolWasmMissing;
            };

            const worker = try self.ctx.gpa.create(ToolWorker);
            worker.* = .{
                .ctx = self.ctx,
                .cfg = self.cfg,
                .tool = tool,
                .arguments = tc.arguments,
                .wasm_bytes = wasm_bytes,
            };
            const thread = try std.Thread.spawn(.{ .stack_size = parallel_tool_stack_bytes }, ToolWorker.run, .{worker});
            try handles.append(self.ctx.gpa, .{ .slot = i, .thread = thread, .worker = worker, .wasm_bytes = wasm_bytes });
        }

        // Join every worker and move its output into the matching slot.
        for (handles.items) |h| h.thread.join();
        for (handles.items) |h| {
            if (h.worker.err) |e| {
                log.log(.error_, "tool '{s}' failed: {s}", .{ h.worker.tool.name, @errorName(e) });
                return error.ToolExecutionFailed;
            }
            const out = h.worker.out.?;
            results[h.slot] = try self.arena.dupe(u8, out);
            self.ctx.gpa.free(out);
            self.ctx.gpa.free(h.wasm_bytes);
            self.ctx.gpa.destroy(h.worker);
        }
        handles.clearRetainingCapacity();

        // ---- sequential fallback: duplicate tool names (stateful modules) --
        for (calls, 0..) |tc, i| {
            if (results[i].len == 0) {
                results[i] = try self.executeTool(tc);
            }
        }
        return results;
    }
};

/// zwasm's interpreter recurses on the native stack, so a tool that runs fine
/// on the main thread can trap with CallStackExhausted on a std.Thread worker
/// (whose default stack is smaller than the process main stack). Give parallel
/// tool workers a large explicit stack size.
const parallel_tool_stack_bytes: usize = 64 * 1024 * 1024;

const WorkerHandle = struct {
    slot: usize,
    thread: std.Thread,
    worker: *ToolWorker,
    wasm_bytes: []u8,
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
            .seed = self.cfg.agent.seed,
        };

        log.log(.debug, "running tool '{s}' in sandbox args={s}", .{ self.tool.name, self.arguments });
        const t0 = std.Io.Timestamp.now(io, .awake);

        var mod = try runtime.ToolModule.load(self.ctx.gpa, io, &sb, self.wasm_bytes);
        defer mod.deinit();

        const out = try mod.executeTool(self.arguments);
        const t1 = std.Io.Timestamp.now(io, .awake);
        const ms = @divTrunc(t0.durationTo(t1).nanoseconds, std.time.ns_per_ms);
        log.log(.info, "tool '{s}' -> {d} bytes in {d}ms", .{ self.tool.name, out.len, ms });
        self.out = out;
    }
};
