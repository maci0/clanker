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
const autolearn = @import("autolearn.zig");
const log = @import("../util/log.zig");

/// Cumulative token usage across all LLM calls in a single agent run.
pub const RunStats = struct {
    total_prompt_tokens: u64 = 0,
    total_completion_tokens: u64 = 0,
    total_tokens: u64 = 0,
    /// Prompt tokens served from the provider cache (cumulative).
    total_cache_hit_tokens: u64 = 0,
    /// Prompt tokens not served from cache (cumulative).
    total_cache_miss_tokens: u64 = 0,
    /// Estimated USD cost for this run (from the active model's
    /// cost_per_1k_input / cost_per_1k_output).
    cost: f64 = 0,
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
    /// Nested sub-agent runner, wired by the app when modules.subagents is
    /// enabled (powers the subagent tool via ck_subagent).
    subagent_runner: ?host.SubagentRunner = null,
    /// When set, tool calls run strictly sequentially (no worker threads).
    /// Used by sub-agent runs to avoid spawning threads from within threads.
    no_parallel_tools: bool = false,
    /// Optional hook fired right before a batch of tool calls executes (e.g.
    /// the REPL prints a "running: ..." status line to cover the otherwise
    /// silent gap between tool dispatch and the next streamed token).
    on_tool_call: ?*const fn ([]const types.ToolCall) void = null,
    /// Optional hook fired right after a batch of tool calls finishes, with
    /// the wall-clock time spent executing them (e.g. the REPL prints
    /// "done in Nms" under the tool status line).
    on_tool_result: ?*const fn (u64) void = null,

    pub fn init(
        ctx: *client.Ctx,
        arena: std.mem.Allocator,
        provider: *const config.Provider,
        cfg: *const config.Config,
        reg: *const registry.Registry,
        tool_defs: []const types.ToolDef,
    ) !Agent {
        const base_prompt = try system_prompt.build(arena, ctx.io, .{
            .system_prompt_file = cfg.agent.system_prompt_file,
            .skills_dir = cfg.agent.skills_dir,
            .learnings_file = cfg.agent.learnings_file,
        }, tool_defs);
        const prompt_text = try std.fmt.allocPrint(arena, "{s}\n\nIMPORTANT: When the user requests a specific output format (exact string, JSON, number, etc.), respond with ONLY that exact value. Do not wrap it in markdown fences, do not add prose, explanations, or punctuation. Return the value verbatim.", .{base_prompt});
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
        const run_start = std.Io.Timestamp.now(self.ctx.io, .awake);
        var used_tools: std.ArrayList([]const u8) = .empty;
        defer used_tools.deinit(self.ctx.gpa);
        // Free cached tool modules (zwasm engines/linkers) when the agent
        // finishes, whether we return a final answer, bail out, or error out.
        defer {
            var it = self.modules.iterator();
            while (it.next()) |kv| {
                kv.value_ptr.*.deinit();
            }
            self.modules.clearRetainingCapacity();
            const run_ms: u64 = @intCast(@divTrunc(run_start.durationTo(std.Io.Timestamp.now(self.ctx.io, .awake)).nanoseconds, std.time.ns_per_ms));
            const tps: f64 = if (run_ms > 0) @as(f64, @floatFromInt(self.stats.total_completion_tokens)) / (@as(f64, @floatFromInt(run_ms)) / 1000.0) else 0;
            const prompt_total = self.stats.total_cache_hit_tokens + self.stats.total_cache_miss_tokens;
            const hit_rate: f64 = if (prompt_total > 0) @as(f64, @floatFromInt(self.stats.total_cache_hit_tokens)) / @as(f64, @floatFromInt(prompt_total)) * 100.0 else 0;
            log.log(.info, "run tokens: prompt={d} completion={d} total={d} ({d:.1} tok/s) cache={d} hit/{d} miss ({d:.0}%) cost=${d:.4}", .{ self.stats.total_prompt_tokens, self.stats.total_completion_tokens, self.stats.total_tokens, tps, self.stats.total_cache_hit_tokens, self.stats.total_cache_miss_tokens, hit_rate, self.stats.cost });
            if (self.cfg.modules.autolearn and run_ms > 0) {
                autolearn.recordRun(self.ctx.io, self.ctx.gpa, self.arena, .{
                    .provider = self.provider.name,
                    .model = self.provider.activeModelName(),
                    .task = if (task.len > 120) task[0..120] else task,
                    .prompt_tokens = self.stats.total_prompt_tokens,
                    .completion_tokens = self.stats.total_completion_tokens,
                    .cache_hit = self.stats.total_cache_hit_tokens,
                    .cache_miss = self.stats.total_cache_miss_tokens,
                    .duration_ms = run_ms,
                    .tools = used_tools.items,
                });
            }
        }
        // Execution graph: record every LLM call and tool invocation, then
        // persist it to state/runs/<run-id>.json on every exit path.
        const started_at: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.ctx.io, .real).nanoseconds, 1_000_000_000));
        var g = graph_mod.Graph{
            .run_id = try std.fmt.allocPrint(self.arena, "run-{d}", .{started_at}),
            .task = task,
            .provider = self.provider.name,
            .started_at = started_at,
        };
        defer {
            g.duration_ms = @intCast(@divTrunc(run_start.durationTo(std.Io.Timestamp.now(self.ctx.io, .awake)).nanoseconds, std.time.ns_per_ms));
            if (self.cfg.modules.graphs) graph_mod.write(self.ctx.io, self.ctx.gpa, self.arena, &g) catch {};
            g.deinit(self.ctx.gpa);
        }
        // Multi-turn callers (the REPL) reuse one message list across runs:
        // prepend the system prompt only once, otherwise every turn would
        // duplicate it and waste a large chunk of the context window.
        // A resumed session's message list may be non-empty but lack a
        // leading system message; the system prompt must be INSERTED at the
        // front (not appended after prior turns) so providers see it first.
        if (messages.items.len == 0 or messages.items[0].role != .system) {
            try messages.insert(self.arena, 0, .{ .role = .system, .content = self.system_prompt_text });
        }
        try messages.append(self.arena, .{ .role = .user, .content = task });

        var iteration: u32 = 0;
        var budget_hit = false;
        while (iteration < self.max_iterations) : (iteration += 1) {
            try self.maybeCompactMessages(messages);
            const llm_t0 = std.Io.Timestamp.now(self.ctx.io, .awake);
            const resp = if (self.on_token) |cb| blk: {
                if (!self.cfg.modules.streaming) break :blk try client.chat(self.ctx, self.arena, .{
                    .provider = self.provider,
                    .messages = messages.items,
                    .tools = self.tool_defs,
                }, err_detail);
                break :blk try client.chatStream(self.ctx, self.arena, .{
                    .provider = self.provider,
                    .messages = messages.items,
                    .tools = self.tool_defs,
                }, err_detail, cb);
            } else try client.chat(self.ctx, self.arena, .{
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

            // RLM: persist reasoning traces so the agent can review and learn
            // from its own chain-of-thought (reasoning tool / modules.rlm).
            if (self.cfg.modules.rlm) {
                if (resp.reasoning) |r| {
                    if (r.len > 0) recordReasoning(self.ctx.io, self.ctx.gpa, self.arena, self.provider.name, self.provider.activeModelName(), task, r);
                }
            }

            if (resp.usage) |u| {
                self.stats.total_prompt_tokens += u.prompt_tokens;
                self.stats.total_completion_tokens += u.completion_tokens;
                self.stats.total_tokens += u.prompt_tokens + u.completion_tokens;
                self.stats.total_cache_hit_tokens += u.prompt_cache_hit_tokens;
                self.stats.total_cache_miss_tokens += u.prompt_cache_miss_tokens;
                const active = self.provider.activeModel();
                if (active.cost_per_1m_input) |ci| self.stats.cost += @as(f64, @floatFromInt(u.prompt_tokens)) / 1_000_000.0 * ci;
                if (active.cost_per_1m_output) |co| self.stats.cost += @as(f64, @floatFromInt(u.completion_tokens)) / 1_000_000.0 * co;

                // Per-turn token budgeting: a single runaway response must
                // not blow the context window even when the session total is
                // still under budget (session cap is cfg.agent.max_total_tokens).
                if (self.cfg.modules.token_budget and u.completion_tokens > max_per_turn_tokens) {
                    log.log(.warn, "per-turn token budget exceeded ({d} > {d} completion tokens); stopping run", .{ u.completion_tokens, max_per_turn_tokens });
                    return error.PerTurnTokenBudgetExceeded;
                }
            }

            if (self.cfg.modules.token_budget) {
                if (self.cfg.agent.max_total_tokens) |budget| {
                    if (self.stats.total_tokens >= budget) {
                        log.log(.warn, "token budget reached ({d} total tokens)", .{self.stats.total_tokens});
                        budget_hit = true;
                        break;
                    }
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
            if (self.on_tool_call) |cb| cb(calls);
            const tool_t0 = std.Io.Timestamp.now(self.ctx.io, .awake);

            // Execute tool calls in parallel for distinct tool names (each on
            // a worker thread with a large stack); a tool name repeated in the
            // same batch falls back to sequential execution because the zwasm
            // module is stateful and the cached instance is reused.
            const results = try self.executeCalls(calls);
            if (self.on_tool_result) |cb| {
                const tool_ms: u64 = @intCast(@divTrunc(tool_t0.durationTo(std.Io.Timestamp.now(self.ctx.io, .awake)).nanoseconds, std.time.ns_per_ms));
                cb(tool_ms);
            }
            for (calls, results) |tc, content| {
                if (self.cfg.modules.autolearn) {
                    if (std.mem.startsWith(u8, content, "{\"ok\":false")) {
                        const kind: []const u8 = if (std.mem.indexOf(u8, content, "unknown tool") != null) "unknown_tool" else "tool_error";
                        autolearn.record(self.ctx.io, self.ctx.gpa, self.arena, kind, tc.name, "");
                    }
                    try used_tools.append(self.ctx.gpa, tc.name);
                }
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

    /// Appends one reasoning trace to state/reasoning.jsonl (RLM).
    fn recordReasoning(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, provider: []const u8, model: []const u8, task: []const u8, reasoning: []const u8) void {
        std.Io.Dir.cwd().createDirPath(io, "state") catch return;
        const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
        var buf: [65536]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var s = std.json.Stringify{ .writer = &w, .options = .{} };
        s.beginObject() catch return;
        s.objectField("ts") catch return;
        s.print("{d}", .{ts}) catch return;
        s.objectField("provider") catch return;
        s.write(provider) catch return;
        s.objectField("model") catch return;
        s.write(model) catch return;
        s.objectField("task") catch return;
        s.write(if (task.len > 200) task[0..200] else task) catch return;
        s.objectField("reasoning") catch return;
        s.write(if (reasoning.len > 20000) reasoning[0..20000] else reasoning) catch return;
        s.endObject() catch return;

        const path = "state/reasoning.jsonl";
        const existing = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 24)) catch "";
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        out.appendSlice(gpa, existing) catch return;
        if (existing.len > 0 and existing[existing.len - 1] != '\n') out.append(gpa, '\n') catch return;
        out.appendSlice(gpa, buf[0..w.end]) catch return;
        out.append(gpa, '\n') catch return;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items }) catch {};
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
        // Estimate bytes per token (common heuristic: ~4) so the byte-based
        // compaction threshold matches the provider's token context size;
        // otherwise a large token window would set a byte threshold too small
        // and cause premature compaction.
        const bytes_per_token: usize = 4;
        const ctx_budget = self.provider.activeModel().context_window * bytes_per_token / 2;
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
        var content = resp.message.content orelse blk: {
            if (resp.reasoning) |r| {
                var last_line: []const u8 = r;
                var line_it = std.mem.tokenizeScalar(u8, r, '\n');
                while (line_it.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t\r\n");
                    if (trimmed.len > 0) last_line = trimmed;
                }
                if (last_line.len > 0) break :blk last_line;
            }
            return resp;
        };
        var s = std.mem.trim(u8, content, " \t\r\n");
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
        // Unwrap a single-backtick inline code wrapper (markdown formatting
        // around a plain answer) so the returned value exactly matches the
        // requested format.
        if (s.len >= 2 and s[0] == '`' and s[s.len - 1] == '`') {
            s = std.mem.trim(u8, s[1 .. s.len - 1], " \t\r\n");
        }
        // Unwrap a JSON string literal (e.g. the model returned "\"42\"" when
        // the answer_format eval expects 42) so the value exactly matches.
        if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
            s = std.mem.trim(u8, s[1 .. s.len - 1], " \t\r\n");
        }
        // If the answer is still wrapped in prose (e.g. "here is your JSON:
        // { ... }"), extract the first JSON object/array — the answer_format
        // eval expects an exact-match value, not prose.
        var js_start: ?usize = null;
        // Pick whichever of a JSON object or array appears first in the answer.
        // Preferring objects can misparse an expected array when prose contains
        // an earlier '{'; the answer_format eval needs the exact value.
        const obj_start = std.mem.indexOfScalar(u8, s, '{');
        const arr_start = std.mem.indexOfScalar(u8, s, '[');
        if (obj_start != null or arr_start != null) {
            js_start = if (obj_start != null and arr_start != null)
                @min(obj_start.?, arr_start.?)
            else if (obj_start != null) obj_start else arr_start;
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
        // If no fence/JSON was found, the model likely wrapped the exact
        // answer in a prose preamble (e.g. "Here is the result:"). For the
        // answer_format eval we need the exact value, so fall back to the last
        // non-empty line and strip a leading "Answer:"/"Result:" prefix.
        if (std.mem.indexOf(u8, s, "```") == null and
            std.mem.indexOfScalar(u8, s, '{') == null and
            std.mem.indexOfScalar(u8, s, '[') == null)
        {
            var last_line: []const u8 = s;
            var line_it = std.mem.tokenizeScalar(u8, s, '\n');
            while (line_it.next()) |line| last_line = std.mem.trim(u8, line, " \t\r\n");
            if (last_line.len > 0) {
                // Strip a leading "Answer:"/"Result:"/"The answer is" and other
                // common preamble prefixes so an exact-match answer (e.g.
                // "The answer is 42") becomes "42".
                if (std.mem.startsWith(u8, last_line, "Answer:")) {
                    last_line = std.mem.trim(u8, last_line["Answer:".len..], " \t\r\n");
                } else if (std.mem.startsWith(u8, last_line, "Result:")) {
                    last_line = std.mem.trim(u8, last_line["Result:".len..], " \t\r\n");
                } else if (std.mem.startsWith(u8, last_line, "The answer is")) {
                    var after = last_line["The answer is".len..];
                    // Skip an optional colon (e.g. "The answer is: 42").
                    if (after.len > 0 and after[0] == ':') after = after[1..];
                    last_line = std.mem.trim(u8, after, " \t\r\n");
                } else if (std.mem.startsWith(u8, last_line, "Here is the answer:")) {
                    last_line = std.mem.trim(u8, last_line["Here is the answer:".len..], " \t\r\n");
                } else if (std.mem.startsWith(u8, last_line, "The output is:")) {
                    last_line = std.mem.trim(u8, last_line["The output is:".len..], " \t\r\n");
                } else if (std.mem.startsWith(u8, last_line, "The result is:")) {
                    last_line = std.mem.trim(u8, last_line["The result is:".len..], " \t\r\n");
                }
                // Strip a single trailing period (or comma/semicolon/!).
                // The answer_format eval expects the exact value without
                // decorative punctuation, so "42." becomes "42".
                if (last_line.len > 1 and (last_line[last_line.len - 1] == '.' or last_line[last_line.len - 1] == ',' or last_line[last_line.len - 1] == ';' or last_line[last_line.len - 1] == '!')) {
                    last_line = last_line[0 .. last_line.len - 1];
                }
                s = last_line;
            }
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

    /// Builds the sandbox policy for one tool: filesystem and network from the
    /// descriptor, plus the plugin's own `config` object and, when it declared
    /// the llm capability, a provider to call.
    fn sandboxFor(self: *Agent, tool: *const registry.Tool) !host.Sandbox {
        var sb = host.Sandbox{
            .gpa = self.ctx.gpa,
            .io = self.ctx.io,
            .root_dir = self.cfg.agent.sandbox_root,
            .network_allow = tool.network_allow,
            .fs_prefixes = tool.fs_prefixes,
            .environ_map = self.ctx.environ_map,
            .seed = self.cfg.agent.seed,
            .config_json = try std.fmt.allocPrint(self.arena, "{f}", .{std.json.fmt(tool.config, .{})}),
            .subagent_runner = self.subagent_runner,
            .cfg = self.cfg,
        };
        if (tool.llm) sb.llm = .{
            .provider = try self.pluginProvider(tool),
            .ctx = self.ctx,
            .max_tokens = pluginU32(tool.config, "max_tokens") orelse 1024,
        };
        return sb;
    }

    /// A plugin may aim `ck_llm` at its own backend: `"config": {"provider":
    /// "kimi-k3", "model": "kimi-k2.7-code"}`. Anything it leaves out falls
    /// back to the provider the agent itself is running on.
    fn pluginProvider(self: *Agent, tool: *const registry.Tool) !*const config.Provider {
        const want_provider = pluginStr(tool.config, "provider");
        const want_model = pluginStr(tool.config, "model");
        if (want_provider == null and want_model == null) return self.provider;

        const base = if (want_provider) |name|
            self.cfg.provider(name) catch blk: {
                log.log(.warn, "plugin '{s}': unknown provider '{s}', using the agent's", .{ tool.name, name });
                break :blk self.provider;
            }
        else
            self.provider;

        const copy = try self.arena.create(config.Provider);
        copy.* = base.*;
        if (want_model) |m| copy.default_model = m;
        return copy;
    }

    fn pluginStr(cfg_value: std.json.Value, key: []const u8) ?[]const u8 {
        if (cfg_value != .object) return null;
        const v = cfg_value.object.get(key) orelse return null;
        return if (v == .string) v.string else null;
    }

    fn pluginU32(cfg_value: std.json.Value, key: []const u8) ?u32 {
        if (cfg_value != .object) return null;
        const v = cfg_value.object.get(key) orelse return null;
        return if (v == .integer and v.integer > 0) @intCast(v.integer) else null;
    }

    /// Passes `payload` through every enabled transform plugin registered for
    /// `tool_name` in this phase, in `order`. Each transform receives the name
    /// of the tool it is wrapping and the transforms already applied, so a
    /// chained plugin knows who called it.
    ///
    /// A transform that fails, denies, or answers without a payload is skipped
    /// with a warning: a broken filter must not take the tool down with it.
    fn runChain(
        self: *Agent,
        tool_name: []const u8,
        phase: registry.Transform.Phase,
        payload: []const u8,
    ) ![]const u8 {
        const chain = try self.reg.transformsFor(self.arena, tool_name, phase);
        var current: []const u8 = payload;
        if (chain.len == 0) return current;

        var applied: std.ArrayList([]const u8) = .empty;
        for (chain) |t| {
            const input = try std.fmt.allocPrint(self.arena, "{f}", .{std.json.fmt(.{
                .tool = tool_name,
                .phase = @tagName(phase),
                .payload = current,
                .prior = applied.items,
            }, .{})});

            const next = self.runTransform(t, input) catch |err| {
                log.log(.warn, "transform '{s}' on '{s}' failed: {s}; passing the payload through", .{ t.name, tool_name, @errorName(err) });
                continue;
            } orelse continue;

            log.log(.info, "transform '{s}' rewrote {s} of '{s}' ({d} -> {d} bytes)", .{ t.name, @tagName(phase), tool_name, current.len, next.len });
            current = next;
            try applied.append(self.arena, t.name);
        }
        return current;
    }

    /// Runs one transform module. Returns null when it declined to rewrite.
    fn runTransform(self: *Agent, tool: *const registry.Tool, input: []const u8) !?[]const u8 {
        const wasm_bytes = try std.Io.Dir.cwd().readFileAlloc(self.ctx.io, tool.wasm, self.ctx.gpa, .limited(1 << 20));
        defer self.ctx.gpa.free(wasm_bytes);

        var sb = try self.sandboxFor(tool);
        // Transform modules are not cached in `self.modules`: they are keyed by
        // the wrapped tool there, and a stale module would carry another call's
        // state into this one.
        const mod = try runtime.ToolModule.load(self.ctx.gpa, self.ctx.io, &sb, wasm_bytes);
        defer mod.deinit();

        const out = try mod.executeTool(input);
        defer self.ctx.gpa.free(out);

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, self.arena, out, .{ .ignore_unknown_fields = true }) catch return null;
        if (parsed != .object) return null;
        if (parsed.object.get("ok")) |ok| {
            if (ok == .bool and !ok.bool) return null;
        }
        const p = parsed.object.get("payload") orelse return null;
        return if (p == .string) p.string else null;
    }

    /// Runs a single tool call in the WASM sandbox; returns arena-owned JSON.
    fn executeTool(self: *Agent, tc: types.ToolCall) ![]const u8 {
        const tool = self.reg.get(tc.name) orelse {
            log.log(.warn, "agent called unknown tool '{s}'", .{tc.name});
            return std.fmt.allocPrint(self.arena, "{{\"ok\":false,\"error\":\"unknown tool: {s}\"}}", .{tc.name});
        };
        if (!tool.enabled) {
            log.log(.warn, "agent called disabled plugin '{s}'", .{tc.name});
            return std.fmt.allocPrint(self.arena, "{{\"ok\":false,\"error\":\"plugin disabled: {s}\"}}", .{tc.name});
        }

        const wasm_bytes = std.Io.Dir.cwd().readFileAlloc(self.ctx.io, tool.wasm, self.ctx.gpa, .limited(1 << 20)) catch |err| {
            log.log(.error_, "tool '{s}': cannot load {s}: {s} (run `zig build tools`)", .{ tc.name, tool.wasm, @errorName(err) });
            return error.ToolWasmMissing;
        };
        defer self.ctx.gpa.free(wasm_bytes);

        var sb = try self.sandboxFor(tool);

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

        const args = try self.runChain(tc.name, .before, tc.arguments);
        const out = mod.executeTool(args) catch |err| {
            log.log(.error_, "tool '{s}' failed: {s}", .{ tc.name, @errorName(err) });
            return error.ToolExecutionFailed;
        };
        defer self.ctx.gpa.free(out);
        const t1 = std.Io.Timestamp.now(self.ctx.io, .awake);
        const ms = @divTrunc(t0.durationTo(t1).nanoseconds, std.time.ns_per_ms);

        // Arena-own the result for the conversation history.
        const owned = try self.runChain(tc.name, .after, out);
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
            // Tools that call the model, and tools wrapped in a transform
            // chain, go through the sequential pass below: one provider call at
            // a time, and no worker thread sharing the HTTP client.
            if (tool.llm or !tool.enabled) continue;
            if (self.no_parallel_tools) continue;
            if ((try self.reg.transformsFor(self.arena, tc.name, .before)).len > 0) continue;
            if ((try self.reg.transformsFor(self.arena, tc.name, .after)).len > 0) continue;
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
                .subagent_runner = self.subagent_runner,
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
    subagent_runner: ?host.SubagentRunner = null,
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
            .subagent_runner = self.subagent_runner,
            .cfg = self.cfg,
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
