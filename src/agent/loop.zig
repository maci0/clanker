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
const graph_mod = @import("graph.zig");
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
    /// Optional streaming hook: when set, LLM responses are streamed (SSE)
    /// and every content delta is delivered here as it arrives (e.g. the
    /// REPL renders tokens live). Tool-call flows still assemble a normal
    /// ChatResponse internally.
    on_token: ?*const fn ([]const u8) void = null,

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
        // Execution graph: record every LLM call and tool invocation, then
        // persist it to state/runs/<run-id>.json on every exit path.
        const run_start = std.Io.Timestamp.now(self.ctx.io, .awake);
        const started_at: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.ctx.io, .real).nanoseconds, 1_000_000_000));
        var g = graph_mod.Graph{
            .run_id = try std.fmt.allocPrint(self.arena, "run-{d}", .{started_at}),
            .task = task,
            .provider = self.provider.name,
            .started_at = started_at,
        };
        defer {
            g.duration_ms = @intCast(@divTrunc(run_start.durationTo(std.Io.Timestamp.now(self.ctx.io, .awake)).nanoseconds, std.time.ns_per_ms));
            graph_mod.write(self.ctx.io, self.ctx.gpa, self.arena, &g) catch {};
            g.deinit(self.ctx.gpa);
        }
        // Multi-turn callers (the REPL) reuse one message list across runs:
        // prepend the system prompt only once, otherwise every turn would
        // duplicate it and waste a large chunk of the context window.
        if (messages.items.len == 0 or messages.items[0].role != .system) {
            try messages.append(self.arena, .{ .role = .system, .content = self.system_prompt_text });
        }
        try messages.append(self.arena, .{ .role = .user, .content = task });

        var iteration: u32 = 0;
        var budget_hit = false;
        while (iteration < self.max_iterations) : (iteration += 1) {
            try self.maybeCompactMessages(messages);
            const llm_t0 = std.Io.Timestamp.now(self.ctx.io, .awake);
            const resp = if (self.on_token) |cb|
                try client.chatStream(self.ctx, self.arena, .{
                    .provider = self.provider,
                    .messages = messages.items,
                    .tools = self.tool_defs,
                }, err_detail, cb)
            else
                try client.chat(self.ctx, self.arena, .{
                    .provider = self.provider,
                    .messages = messages.items,
                    .tools = self.tool_defs,
                }, err_detail);
            try g.add(self.ctx.gpa, .{
                .kind = .llm,
                .iteration = iteration + 1,
                .label = "chat",
                .detail = resp.finish_reason orelse "",
                .prompt_tokens = if (resp.usage) |u| u.prompt_tokens else 0,
                .completion_tokens = if (resp.usage) |u| u.completion_tokens else 0,
                .duration_ms = @intCast(@divTrunc(llm_t0.durationTo(std.Io.Timestamp.now(self.ctx.io, .awake)).nanoseconds, std.time.ns_per_ms)),
                .ok = true,
            });

            if (resp.usage) |u| {
                self.stats.total_prompt_tokens += u.prompt_tokens;
                self.stats.total_completion_tokens += u.completion_tokens;
                self.stats.total_tokens += u.prompt_tokens + u.completion_tokens;

                // Per-turn token budgeting: a single runaway response must
                // not blow the context window even when the session total is
                // still under budget (session cap is cfg.agent.max_total_tokens).
                if (u.completion_tokens > max_per_turn_tokens) {
                    log.log(.warn, "per-turn token budget exceeded ({d} > {d} completion tokens); stopping run", .{ u.completion_tokens, max_per_turn_tokens });
                    return error.PerTurnTokenBudgetExceeded;
                }
            }

            if (self.cfg.agent.max_total_tokens) |budget| {
                if (self.stats.total_tokens >= budget) {
                    log.log(.warn, "token budget reached ({d} total tokens)", .{self.stats.total_tokens});
                    budget_hit = true;
                    break;
                }
            }

            try messages.append(self.arena, resp.message);

            const calls = resp.message.tool_calls orelse {
                try g.add(self.ctx.gpa, .{
                    .kind = .final,
                    .iteration = iteration + 1,
                    .label = "final",
                    .detail = resp.finish_reason orelse "",
                    .result_bytes = if (resp.message.content) |c| c.len else 0,
                    .duration_ms = @intCast(@divTrunc(llm_t0.durationTo(std.Io.Timestamp.now(self.ctx.io, .awake)).nanoseconds, std.time.ns_per_ms)),
                });
                return try self.finish(messages, resp);
            };
            if (calls.len == 0) {
                try g.add(self.ctx.gpa, .{
                    .kind = .final,
                    .iteration = iteration + 1,
                    .label = "final",
                    .detail = resp.finish_reason orelse "",
                    .result_bytes = if (resp.message.content) |c| c.len else 0,
                    .duration_ms = @intCast(@divTrunc(llm_t0.durationTo(std.Io.Timestamp.now(self.ctx.io, .awake)).nanoseconds, std.time.ns_per_ms)),
                });
                return try self.finish(messages, resp);
            }

            log.log(.info, "iteration {d}: {d} tool call(s)", .{ iteration + 1, calls.len });

            // Execute tool calls in parallel for distinct tool names (each on
            // a worker thread with a large stack); a tool name repeated in the
            // same batch falls back to sequential execution because the zwasm
            // module is stateful and the cached instance is reused.
            const results = try self.executeCalls(calls);
            for (calls, results) |tc, content| {
                try g.add(self.ctx.gpa, .{
                    .kind = .tool,
                    .iteration = iteration + 1,
                    .label = tc.name,
                    .result_bytes = content.len,
                });
                try messages.append(self.arena, .{
                    .role = .tool,
                    .tool_call_id = tc.id,
                    .content = content,
                });
            }
        }
        if (budget_hit) return error.SessionTokenBudgetExceeded;
        log.log(.error_, "agent hit the {d}-iteration limit without a final answer", .{self.max_iterations});
        return error.MaxIterationsExceeded;
    }

    /// Compacts the conversation history to keep context size bounded: if the
    /// accumulated message bytes (content + tool arguments) exceed the
    /// effective threshold (compact_threshold_bytes, capped at half the
    /// provider's context window; 0 selects the auto half-window value),
    /// keeps the system message and the last 6 messages (extended backwards
    /// when needed so a tool_call/tool-result exchange is never split),
    /// replacing the removed middle with a single user placeholder message.
    fn maybeCompactMessages(self: *Agent, messages: *std.ArrayList(types.Message)) !void {
        var total: usize = 0;
        for (messages.items) |m| {
            if (m.content) |c| total += c.len;
            if (m.tool_calls) |calls| {
                for (calls) |tc| total += tc.arguments.len;
            }
        }
        // Effective context budget: never exceed half the provider's context
        // window (room for input plus output), and honor an explicit byte cap.
        // compact_threshold_bytes == 0 means "auto" = half the context window.
        const ctx_budget = self.provider.context_window / 2;
        const threshold = if (self.cfg.agent.compact_threshold_bytes == 0)
            ctx_budget
        else
            @min(self.cfg.agent.compact_threshold_bytes, ctx_budget);
        if (total <= threshold) return;
        // Need at least system + one middle + last 6 = 8 messages to compact.
        if (messages.items.len <= 7) return;
        log.log(.info, "compacting conversation: {d} messages, {d} bytes", .{ messages.items.len, total });
        const placeholder: []const u8 = "[earlier conversation compacted — the context is summarized above in learnings and skills]";
        const new_mid = [_]types.Message{.{ .role = .user, .content = placeholder }};
        // Never split a tool-call exchange: if the kept window would start
        // with tool-result messages whose assistant tool_call message is being
        // removed, extend the window backwards to include it. Providers reject
        // tool messages that do not follow a matching tool_calls message.
        var keep_start = messages.items.len - 6;
        while (keep_start > 1 and messages.items[keep_start].role == .tool) keep_start -= 1;
        try messages.replaceRange(self.arena, 1, keep_start - 1, &new_mid);
    }

    /// Returns the final assistant response with the content cleaned of
    /// markdown fences and surrounding whitespace, so the answer exactly
    /// matches the requested format (the answer_format eval).
    fn finalAnswer(self: *Agent, resp: types.ChatResponse) !types.ChatResponse {
        var content = resp.message.content orelse return resp;
        var s = std.mem.trim(u8, content, " \t\r\n");
        // Remove surrounding double quotes (the model sometimes wraps the
        // answer in quotes, which fails the exact-match answer_format eval).
        if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
            s = s[1 .. s.len - 1];
            s = std.mem.trim(u8, s, " \t\r\n");
        }
        // Also strip surrounding single quotes (some models wrap plain-text
        // answers in single quotes, which also fails exact-match evals).
        if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') {
            s = s[1 .. s.len - 1];
            s = std.mem.trim(u8, s, " \t\r\n");
        }
        // Find the first code fence marker; if present, extract content between
        // the fences even if prose precedes it (the answer_format eval expects
        // an exact-match answer, not a fenced/prose-wrapped variant).
        if (std.mem.indexOf(u8, s, "```")) |start| {
            const after_first = s[start + 3 ..];
            const body_start = if (std.mem.indexOf(u8, after_first, "\n")) |nl| nl + 1 else 0;
            var body = after_first[body_start..];
            if (std.mem.lastIndexOf(u8, body, "```")) |end| {
                body = body[0..end];
            }
            s = std.mem.trim(u8, body, " \t\r\n");
        }
        // If the answer is still wrapped in prose (e.g. "here is your JSON:
        // { ... }"), extract the first JSON object/array — the answer_format
        // eval expects an exact-match value, not prose.
        var js_start: ?usize = null;
        // Prefer a JSON object if present, even if an array appears earlier
        // in prose (the answer_format eval expects an exact-match value, and
        // JSON objects are the overwhelmingly common answer format).
        if (std.mem.indexOfScalar(u8, s, '{')) |i| {
            js_start = i;
        } else if (std.mem.indexOfScalar(u8, s, '[')) |i| {
            js_start = i;
        }
        if (js_start) |start| {
            var depth: usize = 0;
            var in_str = false;
            var end: usize = 0;
            for (s[start..], 0..) |ch, i| {
                if (ch == '"' and (i == 0 or s[start + i - 1] != '\\')) in_str = !in_str;
                if (in_str) continue;
                if (ch == '{' or ch == '[') {
                    depth += 1;
                } else if (ch == '}' or ch == ']') {
                    if (depth == 0) break;
                    depth -= 1;
                    if (depth == 0) {
                        end = start + i + 1;
                        break;
                    }
                }
            }
            if (end > 0) s = s[start..end];
        }
        if (s.len != content.len) {
            content = try self.arena.dupe(u8, s);
        }
        var msg = resp.message;
        msg.content = content;
        return .{ .message = msg, .usage = resp.usage, .reasoning = resp.reasoning, .raw = resp.raw };
    }

    /// Cleans the final response (exact-match) and updates the last transcript
    /// message so persisted sessions carry the same exact answer the caller sees.
    fn finish(self: *Agent, messages: *std.ArrayList(types.Message), resp: types.ChatResponse) !types.ChatResponse {
        const ans = try self.finalAnswer(resp);
        if (messages.items.len > 0) {
            messages.items[messages.items.len - 1] = ans.message;
        }
        return ans;
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
            const wasm_bytes = std.Io.Dir.cwd().readFileAlloc(self.ctx.io, tool.wasm, self.ctx.gpa, .limited(1 << 20)) catch |err| {
                log.log(.error_, "tool '{s}': cannot load {s}: {s}", .{ tc.name, tool.wasm, @errorName(err) });
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

/// Hard cap on a single response's completion tokens (per-turn budgeting): a
/// lone huge response must not blow the context window, even if the session
/// total is still under budget. Complements cfg.agent.max_total_tokens and
/// the byte-based history compaction in maybeCompactMessages.
const max_per_turn_tokens: u32 = 32768;

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
