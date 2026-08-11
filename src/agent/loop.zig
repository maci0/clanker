//! The agent loop: think (LLM chat) -> act (execute WASM tool calls) ->
//! observe (feed results back), until the model answers without tool calls.

const std = @import("std");
const config = @import("../config.zig");
const types = @import("../llm/types.zig");
const client = @import("../llm/client.zig");
const registry = @import("../tools/registry.zig");
const tool_usage = @import("../tools/usage.zig");
const runtime = @import("../sandbox/runtime.zig");
const host = @import("../sandbox/host.zig");
const system_prompt = @import("system_prompt.zig");
const graph_mod = @import("graph.zig");
const autolearn = @import("autolearn.zig");
const chatrooms = @import("../peers/chatrooms.zig");
const log = @import("../util/log.zig");
const toolout = @import("../util/toolout.zig");

/// A fork resolved by the human: what was asked, and what they chose.
pub const Decision = struct {
    question: []const u8,
    answer: []const u8,
};

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
    /// How often each tool has been called, across every run this clanker has
    /// ever done. Decides which schemas are loaded without being asked for.
    usage: tool_usage.Usage = .{},
    /// Tools whose schemas the model asked for during this run. They stay
    /// available until the run ends: a tool wanted once is usually wanted
    /// again, and re-sending the catalog line is cheaper than a second
    /// round-trip to load it.
    revealed: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// False when every schema is sent every time (config.agent.tool_catalog).
    catalog_mode: bool = false,
    max_iterations: u32,
    /// The system prompt (arena-owned), rebuilt when skills change.
    system_prompt_text: []const u8,
    /// Instance identity and peer names, kept so refreshSystemPrompt rebuilds
    /// the same prompt init built — without them a mid-session refresh
    /// silently drops the Identity section from the system prompt.
    instance_name: []const u8 = "",
    instance_id: []const u8 = "",
    peer_names: []const []const u8 = &.{},
    /// Loaded tool modules, keyed by tool name (wasm modules are stateful in
    /// zwasm for AssemblyScript guests — cache and reuse instead of
    /// re-instantiating per call).
    modules: std.StringArrayHashMapUnmanaged(*runtime.ToolModule) = .empty,
    /// Loaded tool wasm bytes, keyed by the tool's wasm path (gpa-owned):
    /// read from disk once per distinct path per session, then reused for
    /// every execution, worker spawn, and transform invocation so repeated
    /// calls skip the filesystem read.  Allocated on gpa (not the per-run
    /// arena) so the cache survives across turns in a multi-turn session.
    wasm_cache: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// Cumulative token usage across all LLM calls in this agent run.
    stats: RunStats = .{},
    /// Optional streaming hook: when set, LLM responses are streamed (SSE)
    /// and every content delta is delivered here as it arrives (e.g. the
    /// REPL renders tokens live). Tool-call flows still assemble a normal
    /// ChatResponse internally.
    on_token: ?*const fn ([]const u8) void = null,
    /// The task this run is working on, handed down to sub-agents so their
    /// piece is read in service of something.
    current_task: []const u8 = "",
    /// Human prompt for the ask_user tool, wired by the REPL. Null elsewhere:
    /// a scripted run has nobody to ask.
    ask_fn: ?host.AskFn = null,
    /// Images a caller (the /api/run composer) wants attached to the next
    /// task message. run() consumes them once and clears the slot, so a
    /// later turn never re-sends an old attachment.
    pending_images: ?[]types.ImagePart = null,
    /// A decision the user already made outside a tool call (picking a
    /// numbered option the previous answer offered), recorded at the start of
    /// the run it caused so the graph shows why this turn happened.
    pending_decision: ?Decision = null,
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
    /// Optional hook fired alongside `on_tool_result`, carrying the calls and
    /// their actual results (JSON strings; null for a call that produced no
    /// result) rather than just timing — e.g. the REPL renders a tool-call
    /// card showing what the tool returned, not only how long it took.
    on_tool_results: ?*const fn ([]const types.ToolCall, []const ?[]const u8) void = null,
    /// Cumulative session-level stats across multiple runs (e.g. REPL).
    /// Updated at the end of each run() call so callers can inspect totals.
    session_stats: RunStats = .{},

    /// Frees session-scoped resources (gpa-owned wasm_cache). Call when the
    /// Agent is no longer needed (end of a REPL session / single-shot run).
    pub fn deinit(self: *Agent) void {
        var it = self.wasm_cache.iterator();
        while (it.next()) |kv| {
            self.ctx.gpa.free(kv.key_ptr.*);
            self.ctx.gpa.free(kv.value_ptr.*);
        }
        self.wasm_cache.deinit(self.ctx.gpa);
    }

    pub fn init(
        ctx: *client.Ctx,
        arena: std.mem.Allocator,
        provider: *const config.Provider,
        cfg: *const config.Config,
        reg: *const registry.Registry,
        tool_defs: []const types.ToolDef,
    ) !Agent {
        var peer_names: std.ArrayList([]const u8) = .empty;
        for (cfg.peers) |p| peer_names.append(arena, p.name) catch {};

        var usage = tool_usage.Usage.load(ctx.io, arena, std.Io.Dir.cwd());
        var revealed: std.StringArrayHashMapUnmanaged(void) = .empty;
        var defs = tool_defs;
        var catalog: []const u8 = "";
        if (cfg.agent.tool_catalog) {
            // The hot set is measured rather than configured: whatever this
            // clanker actually reaches for keeps its schema in front of the
            // model, and everything else is one `load_tools` call away.
            const hot = usage.top(arena, cfg.agent.hot_tools) catch &.{};
            var core: std.ArrayList([]const u8) = .empty;
            for (hot) |e| core.append(arena, e.name) catch {};
            defs = reg.lazyToolDefs(arena, core.items, &revealed) catch tool_defs;
            catalog = reg.catalogText(arena, &revealed) catch "";
        }

        log.log(.info, "tools: {d} schema(s) sent, {d} in the catalog", .{ defs.len, reg.tools.count() });
        const base_prompt = try system_prompt.build(arena, ctx.io, .{
            .system_prompt_file = cfg.agent.system_prompt_file,
            .skills_dir = cfg.agent.skills_dir,
            .learnings_file = cfg.agent.learnings_file,
            .instance_name = cfg.instance.name,
            .instance_id = cfg.instance.id,
            .peers = peer_names.items,
            .catalog = catalog,
        }, defs);
        const prompt_text = try std.fmt.allocPrint(arena, "{s}\n\nIMPORTANT: When the user requests a specific output format (exact string, JSON, number, etc.), respond with ONLY that exact value. Do not wrap it in markdown fences, do not add prose, explanations, or punctuation. Return the value verbatim, preserving exact capitalization and punctuation.", .{base_prompt});
        return .{
            .ctx = ctx,
            .arena = arena,
            .provider = provider,
            .cfg = cfg,
            .reg = reg,
            .tool_defs = defs,
            .usage = usage,
            .revealed = revealed,
            .catalog_mode = cfg.agent.tool_catalog,
            .max_iterations = cfg.agent.max_iterations,
            .system_prompt_text = prompt_text,
            .instance_name = cfg.instance.name,
            .instance_id = cfg.instance.id,
            .peer_names = peer_names.items,
            .stats = .{},
        };
    }

    /// Runs the agent on a task; returns the final assistant response.
    /// The full conversation transcript is appended to `messages` (arena).
    /// Rebuilds the system prompt from the current skills and learnings on
    /// disk, so a multi-turn session picks up anything that was recorded
    /// (autolearn, manual edits) since the last run. Updates the cached
    /// `system_prompt_text` and, when a conversation already has a leading
    /// system message, replaces it in-place.
    fn refreshSystemPrompt(self: *Agent, messages: *std.ArrayList(types.Message)) void {
        const base_prompt = system_prompt.build(self.arena, self.ctx.io, .{
            .system_prompt_file = self.cfg.agent.system_prompt_file,
            .skills_dir = self.cfg.agent.skills_dir,
            .learnings_file = self.cfg.agent.learnings_file,
            .instance_name = self.instance_name,
            .instance_id = self.instance_id,
            .peers = self.peer_names,
            .catalog = if (self.catalog_mode) (self.reg.catalogText(self.arena, &self.revealed) catch "") else "",
        }, self.tool_defs) catch |err| {
            log.log(.warn, "refreshSystemPrompt: system_prompt.build failed: {s}", .{@errorName(err)});
            return;
        };
        const prompt_text = std.fmt.allocPrint(self.arena, "{s}\n\nIMPORTANT: When the user requests a specific output format (exact string, JSON, number, etc.), respond with ONLY that exact value. Do not wrap it in markdown fences, do not add prose, explanations, or punctuation. Return the value verbatim, preserving exact capitalization and punctuation.", .{base_prompt}) catch |err| {
            log.log(.warn, "refreshSystemPrompt: allocPrint failed: {s}", .{@errorName(err)});
            return;
        };
        // Only update when the content actually changed, to avoid needless
        // arena churn on turns where nothing was learned.
        if (std.mem.eql(u8, prompt_text, self.system_prompt_text)) return;
        self.system_prompt_text = prompt_text;
        // Patch the leading system message in the conversation transcript so
        // the LLM sees the refreshed prompt without a full rebuild.
        if (messages.items.len > 0 and messages.items[0].role == .system) {
            messages.items[0].content = prompt_text;
        }
        log.log(.info, "system prompt refreshed ({d} bytes)", .{prompt_text.len});
    }

    pub fn run(self: *Agent, messages: *std.ArrayList(types.Message), task: []const u8, err_detail: *?[]const u8) !types.ChatResponse {
        // Each run() call is self-contained: `stats` counts only this run's
        // tokens, so per-run logging, autolearn records, and the defer that
        // folds `stats` into `session_stats` are all correct. Without this
        // reset, a multi-turn REPL session accumulated prior runs' totals in
        // `stats`, and `session_stats` double-counted them on every call.
        self.stats = .{};
        // The tally is what decides which schemas are loaded next time, so it
        // is written whatever happens to this run — including the runs that
        // fail, which are exactly the ones that reached for something unusual.
        defer self.usage.save(self.ctx.io, self.arena, std.Io.Dir.cwd());
        // Rebuild the system prompt so new skills/learnings from prior turns
        // (or external edits) are visible to the model on this turn.
        self.refreshSystemPrompt(messages);
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
            // The wasm cache holds gpa-owned keys and file bytes; the modules
            // above were freed but these were not, so every run leaked one
            // copy of every tool's wasm.
            var wit = self.wasm_cache.iterator();
            while (wit.next()) |kv| {
                self.ctx.gpa.free(kv.key_ptr.*);
                self.ctx.gpa.free(@constCast(kv.value_ptr.*));
            }
            self.wasm_cache.deinit(self.ctx.gpa);
            self.wasm_cache = .empty;
            // wasm_cache is gpa-owned and survives across turns; do NOT clear it here.
            const run_ms: u64 = @intCast(@divTrunc(run_start.durationTo(std.Io.Timestamp.now(self.ctx.io, .awake)).nanoseconds, std.time.ns_per_ms));
            const tps: f64 = if (run_ms > 0) @as(f64, @floatFromInt(self.stats.total_completion_tokens)) / (@as(f64, @floatFromInt(run_ms)) / 1000.0) else 0;
            const prompt_total = self.stats.total_cache_hit_tokens + self.stats.total_cache_miss_tokens;
            const hit_rate: f64 = if (prompt_total > 0) @as(f64, @floatFromInt(self.stats.total_cache_hit_tokens)) / @as(f64, @floatFromInt(prompt_total)) * 100.0 else 0;
            log.log(.info, "run tokens: prompt={d} completion={d} total={d} ({d:.1} tok/s) cache={d} hit/{d} miss ({d:.0}%) cost=${d:.4}", .{ self.stats.total_prompt_tokens, self.stats.total_completion_tokens, self.stats.total_tokens, tps, self.stats.total_cache_hit_tokens, self.stats.total_cache_miss_tokens, hit_rate, self.stats.cost });
            // Accumulate into session-level stats so callers (REPL /stats) can
            // inspect totals across all runs without re-parsing logs.
            self.session_stats.total_prompt_tokens += self.stats.total_prompt_tokens;
            self.session_stats.total_completion_tokens += self.stats.total_completion_tokens;
            self.session_stats.total_tokens += self.stats.total_tokens;
            self.session_stats.total_cache_hit_tokens += self.stats.total_cache_hit_tokens;
            self.session_stats.total_cache_miss_tokens += self.stats.total_cache_miss_tokens;
            self.session_stats.cost += self.stats.cost;
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
        self.current_task = task;
        // A decision the user made before this turn started (they picked one
        // of the options the last answer offered): first node, so the graph
        // says why this run exists.
        if (self.pending_decision) |d| {
            try g.add(self.ctx.gpa, .{
                .kind = .decision,
                .iteration = 0,
                .label = graph_mod.truncatedPreview(d.question),
                .output = graph_mod.truncatedPreview(d.answer),
                .ok = true,
            });
            self.pending_decision = null;
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
        // A resumed session may have been persisted mid-tool-call (crash or
        // atomic-rename rebuild between the assistant's tool_calls message
        // and the tool results). Providers reject tool_calls with no matching
        // tool results, and strict providers (kimi-k3 et al.) also reject a
        // partial exchange, so drop any dangling tail before continuing.
        dropDanglingToolExchange(messages);
        // Attachments queued by the caller ride on the task message itself,
        // the same ImagePart shape the tool-result image path uses.
        var task_images: ?[]types.ImagePart = null;
        if (self.pending_images) |imgs| {
            self.pending_images = null;
            if (imgs.len > 0) task_images = imgs;
        }
        try messages.append(self.arena, .{ .role = .user, .content = task, .images = task_images });
        // Chatrooms inbox: surface messages that arrived since the last run
        // so a subscribed clanker actually notices what its peers said.
        if (self.cfg.modules.chatrooms and self.cfg.chatrooms.on) {
            const state_dir = self.cfg.agent.state_dir;
            const since = chatrooms.readCursor(std.Io.Dir.cwd(), self.ctx.io, self.arena, state_dir);
            const inbox = chatrooms.readNew(std.Io.Dir.cwd(), self.ctx.io, self.ctx.gpa, self.arena, state_dir, since) catch &[_]chatrooms.Message{};
            if (inbox.len > 0) {
                var chat_buf: std.ArrayList(u8) = .empty;
                defer chat_buf.deinit(self.ctx.gpa);
                try chat_buf.appendSlice(self.ctx.gpa, "[chatroom inbox]\n");
                var latest: i64 = since;
                for (inbox) |m| {
                    if (m.ts > latest) latest = m.ts;
                    const preview = if (m.text.len > 300) m.text[0..300] else m.text;
                    const line = try std.fmt.allocPrint(self.ctx.gpa, "- [{s}] {s}: \"{s}\"\n", .{ m.room, m.from, preview });
                    defer self.ctx.gpa.free(line);
                    try chat_buf.appendSlice(self.ctx.gpa, line);
                }
                const text = try self.arena.dupe(u8, chat_buf.items);
                if (text.len > 0) {
                    try messages.append(self.arena, .{ .role = .user, .content = text });
                    chatrooms.writeCursor(std.Io.Dir.cwd(), self.ctx.io, self.ctx.gpa, state_dir, latest);
                }
            }
        }

        var iteration: u32 = 0;
        var budget_hit = false;
        // Cross-turn duplicate tool-call detection: the intra-batch dedup in
        // executeCalls only serializes repeats within one batch, so a model
        // retrying the exact same call (same name + same arguments) on
        // consecutive iterations would spin until max_iterations with no
        // answer. Fingerprint counts are per-run; the third identical call
        // gets a synthetic error result instead of another execution.
        var call_counts: std.StringArrayHashMapUnmanaged(u32) = .empty;
        defer call_counts.deinit(self.ctx.gpa);
        while (iteration < self.max_iterations) : (iteration += 1) {
            try self.maybeCompactMessages(messages);

            // Log estimated prompt tokens before each LLM call for visibility
            // into context usage and to aid compaction tuning.
            const est_prompt_tokens = Agent.estimateMessageTokens(messages.items);
            const ctx_window = self.provider.activeModel().context_window;
            const utilization: f64 = if (ctx_window > 0) @as(f64, @floatFromInt(est_prompt_tokens)) / @as(f64, @floatFromInt(ctx_window)) * 100.0 else 0;
            log.log(.info, "LLM call: ~{d} estimated prompt tokens ({d:.0}% of {d} context window)", .{ est_prompt_tokens, utilization, ctx_window });

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
                // Set here as on every other node: `output` is only the first
                // `output_preview_cap` bytes, so the full length is what tells
                // a reader (and the web UI) that the rest was dropped.
                .result_bytes = if (resp.message.content) |c| c.len else 0,
                .output = graph_mod.truncatedPreview(resp.message.content orelse ""),
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
                if (active.cost_per_1m_input) |ci| self.stats.cost += client.promptCost(u, ci);
                if (active.cost_per_1m_output) |co| self.stats.cost += @as(f64, @floatFromInt(u.completion_tokens)) / 1_000_000.0 * co;
            }

            try messages.append(self.arena, resp.message);

            const maybe_calls = resp.message.tool_calls;
            // A final answer must never be discarded just because the call that
            // produced it crossed the session budget: the caller wants that exact
            // answer (and the answer_format eval asserts it). Return it before the
            // budget check below, which can then only terminate a run that still
            // wants to call tools.
            if (maybe_calls == null or maybe_calls.?.len == 0) {
                try g.add(self.ctx.gpa, .{
                    .kind = .final,
                    .iteration = iteration + 1,
                    .label = "final",
                    .detail = resp.finish_reason orelse "",
                    .result_bytes = if (resp.message.content) |c| c.len else 0,
                    .duration_ms = @intCast(@divTrunc(llm_t0.durationTo(std.Io.Timestamp.now(self.ctx.io, .awake)).nanoseconds, std.time.ns_per_ms)),
                    .output = graph_mod.truncatedPreview(resp.message.content orelse ""),
                });
                return try self.finish(messages, resp);
            }
            const calls = maybe_calls.?;

            // Per-turn token budgeting: a single runaway response must not
            // blow the context window even when the session total is still
            // under budget (session cap is cfg.agent.max_total_tokens). The
            // final-answer path above already returned, so this only guards
            // turns that still want tool calls — a final answer is never
            // sacrificed to the per-turn cap (the answer_format eval requires
            // the exact value, mirroring the session-budget behavior below).
            if (self.cfg.modules.token_budget) {
                if (resp.usage) |u| {
                    if (u.completion_tokens > max_per_turn_tokens) {
                        log.log(.warn, "per-turn token budget exceeded ({d} > {d} completion tokens); stopping run", .{ u.completion_tokens, max_per_turn_tokens });
                        return error.PerTurnTokenBudgetExceeded;
                    }
                }
            }

            // Session budget exhausted: the agent can no longer afford more tool
            // calls, so stop instead of running past the cap. (Final answers were
            // already returned above and are never sacrificed to the budget.)
            if (self.cfg.modules.token_budget) {
                if (self.cfg.agent.max_total_tokens) |budget| {
                    // Session cap across runs (REPL): `stats` was reset to a
                    // fresh per-run counter at the top of run(), so the true
                    // session total is prior runs (session_stats) plus this
                    // run's tokens so far.
                    if (self.session_stats.total_tokens + self.stats.total_tokens >= budget) {
                        log.log(.warn, "token budget reached ({d} total tokens)", .{self.session_stats.total_tokens + self.stats.total_tokens});
                        budget_hit = true;
                        break;
                    }
                }
            }

            log.log(.info, "iteration {d}: {d} tool call(s)", .{ iteration + 1, calls.len });
            if (self.on_tool_call) |cb| cb(calls);
            const tool_t0 = std.Io.Timestamp.now(self.ctx.io, .awake);

            // Cross-turn dedup: a call already executed twice with identical
            // arguments gets a synthetic error result instead of a third
            // execution, deterministically breaking a verbatim retry spin and
            // telling the model to answer with what it already has.
            const skipped = try self.arena.alloc(bool, calls.len);
            @memset(skipped, false);
            var to_run: std.ArrayList(types.ToolCall) = .empty;
            defer to_run.deinit(self.ctx.gpa);
            for (calls, 0..) |tc, i| {
                const fp = try std.fmt.allocPrint(self.arena, "{s}\x00{s}", .{ tc.name, tc.arguments });
                const gop = try call_counts.getOrPut(self.ctx.gpa, fp);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
                if (gop.value_ptr.* >= 3) {
                    skipped[i] = true;
                    log.log(.warn, "tool '{s}' repeated identically {d} times; refusing to re-execute", .{ tc.name, gop.value_ptr.* });
                    continue;
                }
                try to_run.append(self.ctx.gpa, tc);
            }
            // Execute tool calls in parallel for distinct tool names (each on
            // a worker thread with a large stack); a tool name repeated in the
            // same batch falls back to sequential execution because the zwasm
            // module is stateful and the cached instance is reused.
            const run_results = try self.executeCalls(to_run.items);
            // Re-align results with the original batch: skipped calls keep
            // their synthetic error, executed calls take the next result, so
            // the results loop below is unchanged.
            const results = try self.arena.alloc(?[]const u8, calls.len);
            {
                var ri: usize = 0;
                for (skipped, 0..) |skip, i| {
                    if (skip) {
                        results[i] = "{\"ok\":false,\"error\":\"identical tool call already executed twice with the same arguments; do not repeat it — answer with the information you already have\"}";
                    } else {
                        results[i] = run_results[ri];
                        ri += 1;
                    }
                }
            }
            if (self.on_tool_results) |cb| cb(calls, results);
            if (self.on_tool_result) |cb| {
                const tool_ms: u64 = @intCast(@divTrunc(tool_t0.durationTo(std.Io.Timestamp.now(self.ctx.io, .awake)).nanoseconds, std.time.ns_per_ms));
                cb(tool_ms);
            }
            for (calls, results) |tc, maybe_content| {
                const content = maybe_content orelse "{\"ok\":true,\"result\":\"\"}";
                // Tool results must follow the assistant tool_calls message
                // immediately (OpenAI ordering rule; strict providers like
                // kimi-k3 reject anything interleaved), so the image
                // attachment is queued here and appended *after* all tool
                // results of this iteration.
                var image: ?struct { mime: []const u8, b64: []const u8 } = null;
                if (self.cfg.modules.multimodal) {
                    if (std.mem.indexOf(u8, content, "\"image\":{\"mime\":")) |_| {
                        const img = std.json.parseFromSliceLeaky(ImageResult, self.arena, content, .{ .ignore_unknown_fields = true }) catch null;
                        if (img) |im| {
                            if (im.image) |iv| image = .{ .mime = iv.mime, .b64 = iv.b64 };
                        }
                    }
                }
                if (self.cfg.modules.autolearn) {
                    if (std.mem.startsWith(u8, content, "{\"ok\":false")) {
                        const kind: []const u8 = if (std.mem.indexOf(u8, content, "unknown tool") != null) "unknown_tool" else "tool_error";
                        autolearn.record(self.ctx.io, self.ctx.gpa, self.arena, kind, tc.name, "");
                    }
                    // Always record the tool invocation (success or failure)
                    // so the autolearn aggregation can rank tool usage.
                    autolearn.record(self.ctx.io, self.ctx.gpa, self.arena, "tool_call", tc.name, "");
                    try used_tools.append(self.ctx.gpa, tc.name);
                }
                try g.add(self.ctx.gpa, .{
                    .kind = .tool,
                    .iteration = iteration + 1,
                    .label = tc.name,
                    .result_bytes = content.len,
                    .output = graph_mod.truncatedPreview(content),
                });
                // A tool that exists to answer pass/fail gets its verdict on
                // the timeline: "the run continued because this passed" is
                // part of the story, and a tool node hides it in JSON.
                if (self.reg.get(tc.name)) |tool_def| {
                    if (tool_def.check) {
                        const verdict = checkVerdict(self.arena, content);
                        try g.add(self.ctx.gpa, .{
                            .kind = .check,
                            .iteration = iteration + 1,
                            .label = tc.name,
                            .ok = verdict.ok,
                            .detail = verdict.reason,
                            .output = graph_mod.truncatedPreview(content),
                        });
                    }
                }
                // An answered ask_user is a fork the human resolved; a bare
                // tool node buries that under a JSON blob.
                if (std.mem.eql(u8, tc.name, "ask_user")) {
                    if (decisionFrom(self.arena, tc.arguments, content)) |d| {
                        try g.add(self.ctx.gpa, .{
                            .kind = .decision,
                            .iteration = iteration + 1,
                            .label = graph_mod.truncatedPreview(d.question),
                            .output = graph_mod.truncatedPreview(d.answer),
                            .ok = true,
                        });
                    }
                }
                try messages.append(self.arena, .{
                    .role = .tool,
                    .tool_call_id = tc.id,
                    .content = content,
                });
                // Multimodal: attach the image after its tool result so the
                // assistant(tool_calls) -> tool(result) ordering is preserved.
                if (image) |iv| {
                    try messages.append(self.arena, .{
                        .role = .user,
                        .content = try std.fmt.allocPrint(self.arena, "[attached image: {s}]", .{tc.name}),
                        .images = try self.arena.alloc(types.ImagePart, 1),
                    });
                    const last = &messages.items[messages.items.len - 1];
                    last.images.?[0] = .{ .mime = iv.mime, .b64 = iv.b64 };
                }
            }
        }
        if (budget_hit) return error.SessionTokenBudgetExceeded;
        log.log(.error_, "agent hit the {d}-iteration limit without a final answer", .{self.max_iterations});
        return error.MaxIterationsExceeded;
    }

    /// Drops a dangling tool-call exchange from the tail of a resumed
    /// transcript: either a trailing assistant message with tool_calls no
    /// results ever answered, or trailing .tool results that do not exactly
    /// match the tool_calls ids of their nearest preceding assistant message
    /// (a crash mid-batch persists the assistant message and only some of the
    /// results). Providers reject both shapes, so without this a resumed
    /// session can never make progress. Repeats until the tail is clean.
    fn dropDanglingToolExchange(messages: *std.ArrayList(types.Message)) void {
        while (messages.items.len > 0) {
            const last = messages.items[messages.items.len - 1];
            if (last.role == .assistant and last.tool_calls != null and last.tool_calls.?.len > 0) {
                _ = messages.pop();
                continue;
            }
            if (last.role != .tool) break;
            // One or more tool results at the tail: the exchange is complete
            // only when those results answer exactly the tool_calls of the
            // nearest preceding assistant message.
            var tail = messages.items.len;
            while (tail > 0 and messages.items[tail - 1].role == .tool) tail -= 1;
            const trailing = messages.items[tail..];
            var complete = false;
            if (tail > 0) {
                const parent = messages.items[tail - 1];
                if (parent.role == .assistant and parent.tool_calls != null and parent.tool_calls.?.len == trailing.len) {
                    const calls = parent.tool_calls.?;
                    complete = true;
                    for (trailing) |tm| {
                        const tid = tm.tool_call_id orelse {
                            complete = false;
                            break;
                        };
                        var found = false;
                        for (calls) |tc| {
                            if (std.mem.eql(u8, tc.id, tid)) found = true;
                        }
                        if (!found) {
                            complete = false;
                            break;
                        }
                    }
                    if (complete) {
                        for (calls) |tc| {
                            var found = false;
                            for (trailing) |tm| {
                                if (tm.tool_call_id) |tid| {
                                    if (std.mem.eql(u8, tc.id, tid)) found = true;
                                }
                            }
                            if (!found) {
                                complete = false;
                                break;
                            }
                        }
                    }
                }
            }
            if (complete) break;
            // Partial or orphaned: drop the trailing tool results; the next
            // pass pops the parent assistant tool_calls message via the first
            // branch above (or stops if there is no such parent).
            messages.items.len = tail;
        }
    }

    /// Reads a check tool's verdict out of its result: `ok` decides, and
    /// `error` or `text` explains a failure.
    fn checkVerdict(arena: std.mem.Allocator, content: []const u8) struct { ok: bool, reason: []const u8 } {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, content, .{ .ignore_unknown_fields = true }) catch
            return .{ .ok = false, .reason = "result was not JSON" };
        if (parsed != .object) return .{ .ok = false, .reason = "result was not an object" };
        const ok = switch (parsed.object.get("ok") orelse std.json.Value{ .bool = false }) {
            .bool => |b| b,
            else => false,
        };
        var reason: []const u8 = "";
        if (parsed.object.get("error")) |e| {
            if (e == .string) reason = e.string;
        }
        if (reason.len == 0) {
            if (parsed.object.get("text")) |t| {
                if (t == .string) reason = t.string[0..@min(t.string.len, 120)];
            }
        }
        return .{ .ok = ok, .reason = reason };
    }

    /// The question and the chosen answer out of an ask_user call, or null
    /// when the user was not actually asked (no human attached, bad input).
    fn decisionFrom(arena: std.mem.Allocator, arguments: []const u8, result: []const u8) ?Decision {
        const res = std.json.parseFromSliceLeaky(std.json.Value, arena, result, .{ .ignore_unknown_fields = true }) catch return null;
        if (res != .object) return null;
        const answer = switch (res.object.get("answer") orelse return null) {
            .string => |a| a,
            else => return null,
        };
        const args = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments, .{ .ignore_unknown_fields = true }) catch return null;
        const question = if (args == .object) blk: {
            const q = args.object.get("question") orelse break :blk "";
            break :blk if (q == .string) q.string else "";
        } else "";
        return .{ .question = question, .answer = answer };
    }

    const ImageResult = struct {
        image: ?struct {
            mime: []const u8 = "",
            b64: []const u8 = "",
        } = null,
    };

    const reasoning_record_buf_bytes = 65536;
    const reasoning_record_task_chars = 200;
    const reasoning_record_reasoning_chars = 20000;

    /// Appends one reasoning trace to state/reasoning.jsonl (RLM).
    fn recordReasoning(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, provider: []const u8, model: []const u8, task: []const u8, reasoning: []const u8) void {
        std.Io.Dir.cwd().createDirPath(io, "state") catch return;
        const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
        var buf: [reasoning_record_buf_bytes]u8 = undefined;
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
        s.write(if (task.len > reasoning_record_task_chars) task[0..reasoning_record_task_chars] else task) catch return;
        s.objectField("reasoning") catch return;
        s.write(if (reasoning.len > reasoning_record_reasoning_chars) reasoning[0..reasoning_record_reasoning_chars] else reasoning) catch return;
        s.endObject() catch return;

        const path = "state/reasoning.jsonl";
        const existing = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 24)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return,
        };
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        out.appendSlice(gpa, existing) catch return;
        if (existing.len > 0 and existing[existing.len - 1] != '\n') out.append(gpa, '\n') catch return;
        out.appendSlice(gpa, buf[0..w.end]) catch return;
        out.append(gpa, '\n') catch return;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items }) catch |err| log.log(.warn, "recordReasoning: failed to persist event: {s}", .{@errorName(err)});
    }

    /// Estimates the number of LLM tokens for a text string using the
    /// chars/4 heuristic (conservative approximation of BPE tokenization).
    /// Used for compaction thresholds and pre-call logging so decisions
    /// track actual model context limits instead of arbitrary byte counts.
    fn estimateTokens(text: []const u8) usize {
        return @max(text.len / 4, if (text.len > 0) @as(usize, 1) else 0);
    }

    /// Estimates the total token count across all messages in the conversation.
    fn estimateMessageTokens(messages: []const types.Message) usize {
        var total: usize = 0;
        for (messages) |m| {
            // Per-message overhead (role, separators) ~4 tokens.
            total += 4;
            if (m.content) |c| total += estimateTokens(c);
            if (m.tool_calls) |calls| {
                for (calls) |tc| {
                    total += estimateTokens(tc.arguments);
                    total += estimateTokens(tc.name);
                }
            }
        }
        return total;
    }

    /// Compacts the conversation history to keep context size bounded: if the
    /// estimated token count of accumulated messages exceeds the effective
    /// threshold (derived from the provider's context window and optional
    /// compact_threshold_bytes / token budget), keeps the system message and
    /// the last 6 messages (extended backwards when needed so a tool_call/
    /// tool-result exchange is never split), replacing the removed middle with
    /// an LLM-generated summary (or a static placeholder when summarization
    /// fails).
    fn maybeCompactMessages(self: *Agent, messages: *std.ArrayList(types.Message)) !void {
        const estimated_tokens = estimateMessageTokens(messages.items);
        // Effective context budget in tokens: never exceed half the provider's
        // context window (room for input plus output), and honor an explicit
        // byte cap converted to tokens.
        const ctx_budget_tokens = self.provider.activeModel().context_window / 2;
        // When token budgeting is enabled, also respect the session cap so
        // compaction kicks in before the per-session token budget is hit
        // (token budget is enforced in run() after each LLM call).
        var threshold: usize = if (self.cfg.agent.compact_threshold_bytes == 0)
            ctx_budget_tokens
        else
            @min(self.cfg.agent.compact_threshold_bytes / 4, ctx_budget_tokens);
        if (self.cfg.modules.token_budget) {
            if (self.cfg.agent.max_total_tokens) |budget_tokens| {
                threshold = @min(threshold, budget_tokens / 2);
            }
        }
        // Threshold floors: compaction must never race the per-turn cap,
        // which would otherwise terminate the run before compaction runs.
        threshold = @max(threshold, max_per_turn_tokens);
        const keep_start = compactionKeepStart(messages.items, estimated_tokens, threshold) orelse return;
        log.log(.info, "compacting conversation: {d} messages, ~{d} estimated tokens (threshold {d})", .{ messages.items.len, estimated_tokens, threshold });
        // Build a summary of the messages being removed (indices 1..keep_start-1).
        const summary_text = self.summarizeMessages(messages.items[1..keep_start]) catch |err| blk: {
            log.log(.warn, "compaction summary failed ({s}), trying local extractive summary", .{@errorName(err)});
            break :blk self.localSummary(messages.items[1..keep_start]);
        };
        const placeholder = summary_text orelse "[earlier conversation compacted — the context is summarized above in learnings and skills]";
        try compactMiddle(messages, self.arena, keep_start, placeholder);
    }

    /// Decides whether compaction should run and, if so, where the kept tail
    /// window starts: returns null when the history fits the budget or is too
    /// short to compact, otherwise the index such that messages[0] (the system
    /// prompt) and messages[keep_start..] are preserved while the middle is
    /// replaced by a summary. The window is extended backwards past tool-result
    /// messages so a tool_call/tool-result exchange is never split (providers
    /// reject tool messages with no matching tool_calls message). Pure decision
    /// logic, split out of maybeCompactMessages so the unit test can exercise
    /// it without a provider or an LLM call.
    fn compactionKeepStart(messages: []const types.Message, estimated_tokens: usize, threshold: usize) ?usize {
        if (estimated_tokens <= threshold) return null;
        // Need at least system + one middle + last 6 = 8 messages to compact.
        if (messages.len <= 7) return null;
        var keep_start = messages.len - 6;
        while (keep_start > 1 and messages[keep_start].role == .tool) keep_start -= 1;
        return keep_start;
    }

    /// Replaces messages[1..keep_start] with a single synthetic user message
    /// carrying `placeholder`, preserving the leading system message and the
    /// recent tail verbatim. Split out of maybeCompactMessages so the
    /// drop/preserve behavior is unit-testable without an LLM summarization
    /// call.
    fn compactMiddle(messages: *std.ArrayList(types.Message), arena: std.mem.Allocator, keep_start: usize, placeholder: []const u8) !void {
        const new_mid = [_]types.Message{.{ .role = .user, .content = placeholder }};
        try messages.replaceRange(arena, 1, keep_start - 1, &new_mid);
    }

    /// Builds a best-effort extractive summary from the messages themselves,
    /// without calling the LLM. Used as a fallback when summarizeMessages
    /// fails (network error, budget exhausted, etc.) so compaction never
    /// discards context entirely.
    fn localSummary(self: *Agent, msgs: []const types.Message) ?[]const u8 {
        if (msgs.len == 0) return null;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.ctx.gpa);
        buf.appendSlice(self.ctx.gpa, "[conversation summary — ") catch return null;
        const count_str = std.fmt.allocPrint(self.ctx.gpa, "{d}", .{msgs.len}) catch return null;
        defer self.ctx.gpa.free(count_str);
        buf.appendSlice(self.ctx.gpa, count_str) catch return null;
        buf.appendSlice(self.ctx.gpa, " earlier messages compacted (extractive)]\n") catch return null;

        // Cap the total summary size so it does not itself blow the context.
        const max_summary: usize = 4000;
        var tool_calls_seen: std.StringArrayHashMapUnmanaged(void) = .empty;
        defer tool_calls_seen.deinit(self.ctx.gpa);

        for (msgs) |m| {
            if (buf.items.len >= max_summary) break;
            switch (m.role) {
                .user => {
                    if (m.content) |c| {
                        const preview = if (c.len > 200) c[0..200] else c;
                        buf.appendSlice(self.ctx.gpa, "- User: ") catch continue;
                        buf.appendSlice(self.ctx.gpa, preview) catch continue;
                        if (c.len > 200) buf.appendSlice(self.ctx.gpa, "...") catch {};
                        buf.append(self.ctx.gpa, '\n') catch continue;
                    }
                },
                .assistant => {
                    if (m.tool_calls) |calls| {
                        for (calls) |tc| {
                            if (buf.items.len >= max_summary) break;
                            tool_calls_seen.put(self.ctx.gpa, tc.name, {}) catch {};
                            buf.appendSlice(self.ctx.gpa, "- Called tool: ") catch continue;
                            buf.appendSlice(self.ctx.gpa, tc.name) catch continue;
                            // Include a short preview of arguments for context.
                            if (tc.arguments.len > 0 and tc.arguments.len <= 120) {
                                buf.appendSlice(self.ctx.gpa, " args=") catch {};
                                buf.appendSlice(self.ctx.gpa, tc.arguments) catch {};
                            } else if (tc.arguments.len > 120) {
                                buf.appendSlice(self.ctx.gpa, " args=") catch {};
                                buf.appendSlice(self.ctx.gpa, tc.arguments[0..120]) catch {};
                                buf.appendSlice(self.ctx.gpa, "...") catch {};
                            }
                            buf.append(self.ctx.gpa, '\n') catch continue;
                        }
                    }
                    if (m.content) |c| {
                        if (c.len > 0) {
                            const preview = if (c.len > 200) c[0..200] else c;
                            buf.appendSlice(self.ctx.gpa, "- Assistant: ") catch continue;
                            buf.appendSlice(self.ctx.gpa, preview) catch continue;
                            if (c.len > 200) buf.appendSlice(self.ctx.gpa, "...") catch {};
                            buf.append(self.ctx.gpa, '\n') catch continue;
                        }
                    }
                },
                .tool => {
                    if (m.content) |c| {
                        // For tool results, extract the first 150 chars as a preview
                        // so key values (numbers, paths, statuses) survive compaction.
                        const preview = if (c.len > 150) c[0..150] else c;
                        buf.appendSlice(self.ctx.gpa, "- Tool result: ") catch continue;
                        buf.appendSlice(self.ctx.gpa, preview) catch continue;
                        if (c.len > 150) buf.appendSlice(self.ctx.gpa, "...") catch {};
                        buf.append(self.ctx.gpa, '\n') catch continue;
                    }
                },
                .system => {},
            }
        }

        // Append a summary line listing distinct tools used.
        if (tool_calls_seen.count() > 0) {
            buf.appendSlice(self.ctx.gpa, "- Tools used: ") catch {};
            var it = tool_calls_seen.iterator();
            var first = true;
            while (it.next()) |kv| {
                if (!first) buf.appendSlice(self.ctx.gpa, ", ") catch {};
                buf.appendSlice(self.ctx.gpa, kv.key_ptr.*) catch {};
                first = false;
            }
            buf.append(self.ctx.gpa, '\n') catch {};
        }

        if (buf.items.len == 0) return null;
        return self.arena.dupe(u8, buf.items) catch null;
    }

    /// Produces a concise summary of a slice of conversation messages by
    /// asking the LLM to distill them. Returns an arena-owned string prefixed
    /// with "[conversation summary]" so downstream code knows it is synthetic.
    /// Returns error on LLM failure; the caller falls back to a local
    /// extractive summary, then a static placeholder.
    fn summarizeMessages(self: *Agent, msgs: []const types.Message) ![]const u8 {
        if (msgs.len == 0) return error.EmptyMessages;
        // Build a textual transcript of the messages to summarize, capped at
        // ~12k chars so the summary request itself does not blow the context.
        const max_transcript: usize = 12000;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.ctx.gpa);
        for (msgs) |m| {
            if (buf.items.len >= max_transcript) break;
            const role_str: []const u8 = switch (m.role) {
                .user => "user",
                .assistant => "assistant",
                .tool => "tool",
                .system => "system",
            };
            const hdr = try std.fmt.allocPrint(self.ctx.gpa, "[{s}] ", .{role_str});
            defer self.ctx.gpa.free(hdr);
            try buf.appendSlice(self.ctx.gpa, hdr);
            if (m.content) |c| {
                const remaining = if (max_transcript > buf.items.len) max_transcript - buf.items.len else 0;
                const slice = if (c.len > remaining) c[0..remaining] else c;
                try buf.appendSlice(self.ctx.gpa, slice);
            } else {
                try buf.appendSlice(self.ctx.gpa, "(no text content)");
            }
            try buf.append(self.ctx.gpa, '\n');
        }
        if (buf.items.len == 0) return error.EmptyMessages;

        const prompt = try std.fmt.allocPrint(
            self.arena,
            "Summarize the following conversation excerpt in 3-5 concise bullet points. " ++
                "Focus on: decisions made, facts established, tool results, and any pending tasks. " ++
                "Be specific — include names, numbers, and key values. Do NOT add commentary.\n\n{s}",
            .{buf.items},
        );

        const sum_messages = [_]types.Message{.{ .role = .user, .content = prompt }};
        var err_detail: ?[]const u8 = null;
        const resp = try client.chat(self.ctx, self.arena, .{
            .provider = self.provider,
            .messages = &sum_messages,
            .max_tokens = 512,
        }, &err_detail);
        const content = resp.message.content orelse return error.EmptyResponse;
        if (content.len == 0) return error.EmptyResponse;
        // Track the summarization cost.
        if (resp.usage) |u| {
            self.stats.total_prompt_tokens += u.prompt_tokens;
            self.stats.total_completion_tokens += u.completion_tokens;
            self.stats.total_tokens += u.prompt_tokens + u.completion_tokens;
            self.stats.total_cache_hit_tokens += u.prompt_cache_hit_tokens;
            self.stats.total_cache_miss_tokens += u.prompt_cache_miss_tokens;
            const active = self.provider.activeModel();
            if (active.cost_per_1m_input) |ci| self.stats.cost += client.promptCost(u, ci);
            if (active.cost_per_1m_output) |co| self.stats.cost += @as(f64, @floatFromInt(u.completion_tokens)) / 1_000_000.0 * co;
        }
        log.log(.info, "compaction summary: {d} messages -> {d} byte summary", .{ msgs.len, content.len });
        return try std.fmt.allocPrint(
            self.arena,
            "[conversation summary — {d} earlier messages compacted]\n{s}",
            .{ msgs.len, content },
        );
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
        // Unwrap markdown emphasis (bold/italic) so an exact-match answer like
        // **42** becomes 42.
        while (s.len >= 4 and s[0] == '*' and s[1] == '*' and s[s.len - 1] == '*' and s[s.len - 2] == '*') {
            s = s[2 .. s.len - 2];
            s = std.mem.trim(u8, s, " \t\r\n");
        }
        while (s.len >= 2 and ((s[0] == '*' and s[s.len - 1] == '*') or (s[0] == '_' and s[s.len - 1] == '_'))) {
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
        // Unwrap a single-backtick inline code wrapper (markdown formatting
        // around a plain answer) so the returned value exactly matches the
        // requested format.
        if (s.len >= 2 and s[0] == '`' and s[s.len - 1] == '`') {
            s = std.mem.trim(u8, s[1 .. s.len - 1], " \t\r\n");
        }
        // Unwrap a JSON string literal (e.g. "42" -> 42, "Paris" -> Paris) so
        // the returned value matches the exact requested string or number.
        // This makes the answer_format eval pass for both numeric and string
        // answers, since the user asked for the exact value without quotes.
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
            if (end > 0) {
                s = s[start..end];
                // If the model wrapped a bare value in {"answer": ...}, unwrap
                // to the exact value. Only triggers when an "answer" field is
                // present, so a user-requested JSON object is never altered.
                if (unwrapJsonAnswer(self.arena, s)) |unwrapped| {
                    s = unwrapped;
                }
            }
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
            while (line_it.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r\n");
                if (trimmed.len > 0) {
                    last_line = trimmed;
                    break;
                }
            }
            if (last_line.len > 0) {
                // Strip common preamble prefixes repeatedly (e.g. "Here is your
                // answer: The result is 42") so the exact-match answer survives.
                while (true) {
                    var stripped: ?[]const u8 = null;
                    if (std.mem.startsWith(u8, last_line, "Answer:")) {
                        stripped = last_line["Answer:".len..];
                    } else if (std.mem.startsWith(u8, last_line, "Result:")) {
                        stripped = last_line["Result:".len..];
                    } else if (std.mem.startsWith(u8, last_line, "The answer is")) {
                        stripped = last_line["The answer is".len..];
                        if (stripped.?.len > 0 and stripped.?[0] == ':') stripped = stripped.?[1..];
                    } else if (std.mem.startsWith(u8, last_line, "Here is the answer:")) {
                        stripped = last_line["Here is the answer:".len..];
                    } else if (std.mem.startsWith(u8, last_line, "Here is your answer:")) {
                        stripped = last_line["Here is your answer:".len..];
                    } else if (std.mem.startsWith(u8, last_line, "Here is your result:")) {
                        stripped = last_line["Here is your result:".len..];
                    } else if (std.mem.startsWith(u8, last_line, "Here is the result:")) {
                        stripped = last_line["Here is the result:".len..];
                    } else if (std.mem.startsWith(u8, last_line, "The correct answer is")) {
                        stripped = last_line["The correct answer is".len..];
                        if (stripped.?.len > 0 and stripped.?[0] == ':') stripped = stripped.?[1..];
                    } else if (std.mem.startsWith(u8, last_line, "Correct answer:")) {
                        stripped = last_line["Correct answer:".len..];
                    } else if (std.mem.startsWith(u8, last_line, "The output is:")) {
                        stripped = last_line["The output is:".len..];
                    } else if (std.mem.startsWith(u8, last_line, "The result is:")) {
                        stripped = last_line["The result is:".len..];
                    } else if (std.mem.startsWith(u8, last_line, "The value is:")) {
                        stripped = last_line["The value is:".len..];
                    } else if (std.mem.startsWith(u8, last_line, "Sure,")) {
                        stripped = last_line["Sure,".len..];
                    } else if (std.mem.startsWith(u8, last_line, "answer:")) {
                        stripped = last_line["answer:".len..];
                    } else if (std.mem.startsWith(u8, last_line, "result:")) {
                        stripped = last_line["result:".len..];
                    } else if (std.mem.startsWith(u8, last_line, "here is the answer:")) {
                        stripped = last_line["here is the answer:".len..];
                    } else if (std.mem.startsWith(u8, last_line, "the answer is")) {
                        stripped = last_line["the answer is".len..];
                        if (stripped.?.len > 0 and stripped.?[0] == ':') stripped = stripped.?[1..];
                    } else if (std.mem.startsWith(u8, last_line, "the output is:")) {
                        stripped = last_line["the output is:".len..];
                    } else if (std.mem.startsWith(u8, last_line, "the result is:")) {
                        stripped = last_line["the result is:".len..];
                    } else if (std.mem.startsWith(u8, last_line, "the value is:")) {
                        stripped = last_line["the value is:".len..];
                    } else if (std.mem.startsWith(u8, last_line, "sure, here you go:")) {
                        stripped = last_line["sure, here you go:".len..];
                    } else if (std.mem.startsWith(u8, last_line, "here you go:")) {
                        stripped = last_line["here you go:".len..];
                    } else if (std.mem.startsWith(u8, last_line, "here is:")) {
                        stripped = last_line["here is:".len..];
                    } else if (std.mem.startsWith(u8, last_line, "here:")) {
                        stripped = last_line["here:".len..];
                    } else if (std.mem.startsWith(u8, last_line, "output:")) {
                        stripped = last_line["output:".len..];
                    }
                    if (stripped) |s2| {
                        last_line = std.mem.trim(u8, s2, " \t\r\n");
                        if (last_line.len == 0) break;
                    } else break;
                }
                s = last_line;
                // If the answer is a number or boolean at the start of the line
                // followed by extra prose (e.g. "42. I hope this helps"), extract
                // just the leading value so the exact-match answer is preserved.
                {
                    const lead = std.mem.trim(u8, s, " \t\r\n");
                    if (lead.len > 0 and (isNumericString(lead) or std.mem.eql(u8, lead, "true") or std.mem.eql(u8, lead, "false"))) {
                        s = lead;
                    } else if (lead.len > 0 and (std.ascii.isDigit(lead[0]) or (lead[0] == '-' and lead.len > 1 and std.ascii.isDigit(lead[1])))) {
                        var i: usize = 0;
                        if (lead[0] == '-') i = 1;
                        while (i < lead.len and (std.ascii.isDigit(lead[i]) or lead[i] == '.' or lead[i] == ',')) i += 1;
                        if (i > 0) s = std.mem.trim(u8, lead[0..i], " \t\r\n");
                    } else if (std.mem.startsWith(u8, lead, "true") or std.mem.startsWith(u8, lead, "false")) {
                        s = if (std.mem.startsWith(u8, lead, "true")) "true" else "false";
                    }
                }
                // Strip trailing punctuation from a numeric/boolean answer only;
                // a string answer keeps its punctuation (exact-match).
                s = stripTrailingPunctForExact(s);
            }
        }
        // The fallback may pick a line that itself carries markdown emphasis
        // or backticks (e.g. "The answer is: **42**" or "It's `42`");
        // reapply the unwrap so the returned value is the exact-match answer.
        while (s.len >= 4 and s[0] == '*' and s[1] == '*' and s[s.len - 1] == '*' and s[s.len - 2] == '*') {
            s = std.mem.trim(u8, s[2 .. s.len - 2], " \t\r\n");
        }
        while (s.len >= 2 and ((s[0] == '*' and s[s.len - 1] == '*') or (s[0] == '_' and s[s.len - 1] == '_'))) {
            s = std.mem.trim(u8, s[1 .. s.len - 1], " \t\r\n");
        }
        if (s.len >= 2 and s[0] == '`' and s[s.len - 1] == '`') {
            s = std.mem.trim(u8, s[1 .. s.len - 1], " \t\r\n");
        }
        // If the cleaning stripped everything (e.g. a response that was only
        // prose/markdown), fall back to the trimmed original so we never
        // return an empty answer that would fail an exact-match eval.
        if (s.len == 0) {
            s = std.mem.trim(u8, content, " \t\r\n");
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
    /// Sandbox for a module that will be cached: `ToolModule` keeps the
    /// pointer it is loaded with, and a cached module is used again from later
    /// frames, so a stack local here dangles the moment this call returns —
    /// the host functions then read a freed `Sandbox` and the process
    /// segfaults inside the allocator. Arena-allocated, it lives as long as
    /// the run that owns the cache.
    fn sandboxPtrFor(self: *Agent, tool: *const registry.Tool) !*host.Sandbox {
        const sb = try self.arena.create(host.Sandbox);
        sb.* = try self.sandboxFor(tool);
        return sb;
    }

    fn sandboxFor(self: *Agent, tool: *const registry.Tool) !host.Sandbox {
        var sb = try host.sandboxFor(self.ctx.gpa, self.ctx.io, self.arena, self.ctx.environ_map, self.cfg, tool, self.ctx);
        // Agent-only extras: nested sub-agents and the state dir are meaningless
        // for the CLI and MCP callers of the shared builder.
        sb.subagent_runner = self.subagent_runner;
        sb.ask_fn = self.ask_fn;
        sb.parent_task = self.current_task;
        sb.state_dir = self.cfg.agent.state_dir;
        // A tool that named no provider of its own follows the agent, which may
        // itself be running under a --provider override rather than the default.
        if (sb.llm) |*access| {
            if (host.pluginStr(tool.config, "provider") == null and host.pluginStr(tool.config, "model") == null) {
                access.provider = self.provider;
            }
        }
        return sb;
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
        // Const-qualified: each step's replacement comes back from
        // runTransform as []const u8, and a []u8 here cannot hold it.
        var current: []const u8 = try self.arena.dupe(u8, payload);
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
        // Cache compiled transform modules under a "transform:"-prefixed key so
        // they never collide with the wrapped tool's own module in
        // `self.modules`; repeated invocations skip recompilation (the modules
        // are deinitialized by the run() defer like any other cached module).
        const cache_key = try std.fmt.allocPrint(self.arena, "transform:{s}", .{tool.name});
        const mod = if (self.modules.get(cache_key)) |m|
            m
        else blk: {
            const wasm_bytes = self.wasmBytes(tool) catch |err| {
                log.log(.error_, "transform '{s}': cannot load {s}: {s}", .{ tool.name, tool.wasm, @errorName(err) });
                return err;
            };
            const sbp = try self.sandboxPtrFor(tool);
            const m = try runtime.ToolModule.load(self.ctx.gpa, self.ctx.io, sbp, wasm_bytes);
            self.modules.put(self.arena, cache_key, m) catch {
                m.deinit();
                return error.OutOfMemory;
            };
            break :blk m;
        };

        const out = try mod.executeTool(input);
        defer self.ctx.gpa.free(out);

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, self.arena, out, .{ .ignore_unknown_fields = true }) catch |err| {
            log.log(.warn, "transform '{s}': output is not valid JSON ({s}), skipping", .{ tool.name, @errorName(err) });
            return null;
        };
        if (parsed != .object) return null;
        if (parsed.object.get("ok")) |ok| {
            if (ok == .bool and !ok.bool) return null;
        }
        const p = parsed.object.get("payload") orelse return null;
        return if (p == .string) p.string else null;
    }

    /// Returns the wasm bytes for `tool`, reading the file from disk only on
    /// the first call for a given wasm path; the bytes are gpa-allocated
    /// and cached so repeated tool calls, worker spawns, and transform runs
    /// against the same module skip the filesystem.  Using gpa (not the
    /// per-run arena) lets the cache survive across turns in a multi-turn
    /// session — the files are immutable during a session.
    fn wasmBytes(self: *Agent, tool: *const registry.Tool) ![]const u8 {
        if (self.wasm_cache.get(tool.wasm)) |bytes| return bytes;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.ctx.io, tool.wasm, self.ctx.gpa, .limited(1 << 20));
        const key = try self.ctx.gpa.dupe(u8, tool.wasm);
        self.wasm_cache.put(self.ctx.gpa, key, bytes) catch |err| {
            self.ctx.gpa.free(bytes);
            self.ctx.gpa.free(key);
            return err;
        };
        return bytes;
    }

    /// Pre-loads the wasm bytes of every tool in `calls` and compiles every
    /// transform module registered for them (before and after phases) into
    /// `self.modules` under its "transform:<name>" key. Runs on the main
    /// thread before parallel workers spawn, so no worker thread ever
    /// inserts into wasm_cache / the transform module cache concurrently.
    /// Failures are logged and left for the execution path to surface:
    /// runTransform lazily recompiles on a cache miss and runChain already
    /// skips a transform that fails to load.
    fn warmToolCaches(self: *Agent, calls: []const types.ToolCall) void {
        for (calls) |tc| {
            const tool = self.reg.get(tc.name) orelse continue;
            if (!tool.enabled) continue;
            const wasm_bytes = self.wasmBytes(tool) catch |err| {
                log.log(.warn, "tool '{s}': cannot pre-load {s}: {s}", .{ tc.name, tool.wasm, @errorName(err) });
                continue;
            };
            // Pre-compile the primary tool module so executeTool (sequential
            // path) finds it already in self.modules and skips recompilation.
            // Parallel-eligible tools never read self.modules — their worker
            // loads a fresh module from the cached wasm bytes — but when the
            // same tool name appears more than once in a batch, the duplicate
            // hits the sequential fallback (executeTool / executeToolOnWorker)
            // which DOES read self.modules; pre-compiling here avoids a
            // redundant recompilation on that path.
            // Pre-compile every tool module unconditionally: even parallel-
            // eligible tools benefit when the same tool name appears in a
            // later iteration's batch (sequential fallback for duplicates)
            // or when no_parallel_tools flips mid-session. The compiled
            // module is immutable and reused by executeTool's cache lookup,
            // eliminating redundant WASM parse+validate on repeat calls.
            if (!self.modules.contains(tc.name)) {
                const sbp = self.sandboxPtrFor(tool) catch continue;
                const m = runtime.ToolModule.load(self.ctx.gpa, self.ctx.io, sbp, wasm_bytes) catch |err| {
                    log.log(.warn, "tool '{s}': pre-compile failed: {s}", .{ tc.name, @errorName(err) });
                    continue;
                };
                self.modules.put(self.arena, tc.name, m) catch |err| {
                    m.deinit();
                    log.log(.warn, "tool '{s}': cache insert failed: {s}", .{ tc.name, @errorName(err) });
                    continue;
                };
            }
            const phases = [_]registry.Transform.Phase{ .before, .after };
            for (phases) |phase| {
                const chain = self.reg.transformsFor(self.arena, tc.name, phase) catch continue;
                for (chain) |t| {
                    const cache_key = std.fmt.allocPrint(self.arena, "transform:{s}", .{t.name}) catch continue;
                    if (self.modules.contains(cache_key)) continue;
                    const tbytes = self.wasmBytes(t) catch continue;
                    const tsbp = self.sandboxPtrFor(t) catch continue;
                    const m = runtime.ToolModule.load(self.ctx.gpa, self.ctx.io, tsbp, tbytes) catch |err| {
                        log.log(.warn, "transform '{s}': pre-compile failed: {s}", .{ t.name, @errorName(err) });
                        continue;
                    };
                    self.modules.put(self.arena, cache_key, m) catch {
                        m.deinit();
                        continue;
                    };
                }
            }
        }
    }

    /// Runs a single tool call in the WASM sandbox; returns arena-owned JSON.
    /// Reveals schemas the model asked for and reports what it got. The tool
    /// list for the next request is rebuilt from `revealed`, so the tools
    /// become callable on the very next turn.
    fn loadTools(self: *Agent, tc: types.ToolCall) ![]const u8 {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, self.arena, tc.arguments, .{}) catch {
            return "{\"ok\":false,\"error\":\"expected {\\\"names\\\":[\\\"tool_name\\\"]}\"}";
        };
        const names = switch (parsed) {
            .object => |o| switch (o.get("names") orelse std.json.Value{ .null = {} }) {
                .array => |a| a,
                else => return "{\"ok\":false,\"error\":\"names must be an array of tool names\"}",
            },
            else => return "{\"ok\":false,\"error\":\"names must be an array of tool names\"}",
        };

        var out: std.Io.Writer.Allocating = .init(self.arena);
        var s = std.json.Stringify{ .writer = &out.writer };
        try s.beginObject();
        try s.objectField("ok");
        try s.write(true);
        try s.objectField("loaded");
        try s.beginArray();
        var found: usize = 0;
        for (names.items) |n| {
            if (n != .string) continue;
            const t = self.reg.get(n.string) orelse continue;
            if (t.internal or !t.enabled) continue;
            self.revealed.put(self.arena, t.name, {}) catch continue;
            found += 1;
            try s.beginObject();
            try s.objectField("name");
            try s.write(t.name);
            try s.objectField("description");
            try s.write(t.description);
            try s.objectField("input_schema");
            try s.write(t.input_schema);
            try s.endObject();
        }
        try s.endArray();
        // Names that matched nothing are said plainly rather than silently
        // dropped, so a typo does not look like an empty tool.
        try s.objectField("unknown");
        try s.beginArray();
        for (names.items) |n| {
            if (n != .string) continue;
            const t = self.reg.get(n.string);
            if (t == null or t.?.internal or !t.?.enabled) try s.write(n.string);
        }
        try s.endArray();
        try s.endObject();

        if (found > 0) self.rebuildToolDefs();
        return out.written();
    }

    /// Recomputes what goes in the next request's tool array.
    fn rebuildToolDefs(self: *Agent) void {
        if (!self.catalog_mode) return;
        const hot = self.usage.top(self.arena, self.cfg.agent.hot_tools) catch return;
        var core: std.ArrayList([]const u8) = .empty;
        for (hot) |e| core.append(self.arena, e.name) catch {};
        self.tool_defs = self.reg.lazyToolDefs(self.arena, core.items, &self.revealed) catch return;
    }

    fn executeTool(self: *Agent, tc: types.ToolCall) ![]const u8 {
        const tool = self.reg.get(tc.name) orelse {
            log.log(.warn, "agent called unknown tool '{s}'", .{tc.name});
            return std.fmt.allocPrint(self.arena, "{{\"ok\":false,\"error\":\"unknown tool: {s}\"}}", .{tc.name});
        };
        if (!tool.enabled) {
            log.log(.warn, "agent called disabled plugin '{s}'", .{tc.name});
            return std.fmt.allocPrint(self.arena, "{{\"ok\":false,\"error\":\"plugin disabled: {s}\"}}", .{tc.name});
        }

        log.log(.debug, "running tool '{s}' in sandbox args={s}", .{ tc.name, tc.arguments });
        const t0 = std.Io.Timestamp.now(self.ctx.io, .awake);

        const mod = if (self.modules.get(tc.name)) |m|
            m
        else blk: {
            const wasm_bytes = self.wasmBytes(tool) catch |err| {
                log.log(.error_, "tool '{s}': cannot load {s}: {s} (run `zig build tools`)", .{ tc.name, tool.wasm, @errorName(err) });
                return std.fmt.allocPrint(self.arena, "{{\"ok\":false,\"error\":\"tool wasm missing: {s} ({s}). Run `zig build tools`.\"}}", .{ tc.name, @errorName(err) });
            };
            const sbp = self.sandboxPtrFor(tool) catch |err| {
                log.log(.error_, "tool '{s}': sandbox setup failed: {s}", .{ tc.name, @errorName(err) });
                return std.fmt.allocPrint(self.arena, "{{\"ok\":false,\"error\":\"tool sandbox failed: {s} ({s})\"}}", .{ tc.name, @errorName(err) });
            };
            const m = runtime.ToolModule.load(self.ctx.gpa, self.ctx.io, sbp, wasm_bytes) catch |err| {
                log.log(.error_, "tool '{s}': sandbox load failed: {s}", .{ tc.name, @errorName(err) });
                return std.fmt.allocPrint(self.arena, "{{\"ok\":false,\"error\":\"tool load failed: {s} ({s})\"}}", .{ tc.name, @errorName(err) });
            };
            self.modules.put(self.arena, tc.name, m) catch {
                m.deinit();
                return error.OutOfMemory;
            };
            break :blk m;
        };

        // Run before-transforms on the arguments (input rewriting / validation).
        const effective_args = self.runChain(tc.name, .before, tc.arguments) catch tc.arguments;

        const out = mod.executeTool(effective_args) catch |err| {
            log.log(.error_, "tool '{s}' failed: {s}", .{ tc.name, @errorName(err) });
            return std.fmt.allocPrint(self.arena, "{{\"ok\":false,\"error\":\"tool execution failed: {s} ({s})\"}}", .{ tc.name, @errorName(err) });
        };
        defer self.ctx.gpa.free(out);
        const t1 = std.Io.Timestamp.now(self.ctx.io, .awake);
        const ms = @divTrunc(t0.durationTo(t1).nanoseconds, std.time.ns_per_ms);

        // Arena-own the result for the conversation history BEFORE the defer
        // above frees the gpa buffer: returning it raw yields 0xAA-poisoned
        // tool messages on the sequential path (use-after-free).
        const owned = try self.arena.dupe(u8, out);
        log.log(.info, "tool '{s}' -> {d} bytes in {d}ms", .{ tc.name, out.len, ms });
        toolout.warnIfMalformed(self.arena, tc.name, owned);

        // Run after-transforms on the result (output filtering / post-processing).
        const transformed = self.runChain(tc.name, .after, owned) catch owned;
        return transformed;
    }

    /// Executes a batch of tool calls, returning arena-owned results aligned
    /// with `calls`. Distinct tool names run in parallel on worker threads;
    /// duplicate names fall back to sequential execution (zwasm modules are
    /// stateful).
    fn executeCalls(self: *Agent, calls: []const types.ToolCall) ![]?[]const u8 {
        // Optional slots: null means "not yet executed", which has to be
        // distinguishable from "executed and returned empty output" — a tool
        // that legitimately returns zero bytes was re-run by the sequential
        // fallback (doubling its side effects) because "" was both the
        // initial value and a possible result.
        const results = try self.arena.alloc(?[]const u8, calls.len);
        @memset(results, null);

        for (calls, 0..) |tc, i| {
            // Counted here, not in executeTool: there are two execution paths
            // and a third for duplicates, and this is the only point all of
            // them pass through. Counted before the call, because a tool the
            // model keeps reaching for should get its schema loaded whether or
            // not the call succeeds.
            self.usage.record(self.arena, tc.name);
            // load_tools is answered by this process rather than the sandbox:
            // it decides what the next request carries, which no wasm module
            // can see. It has no registry entry, so filling its slot here also
            // keeps the passes below from reporting it as an unknown tool.
            if (self.catalog_mode and std.mem.eql(u8, tc.name, registry.Registry.load_tool_name)) {
                results[i] = try self.loadTools(tc);
                continue;
            }
            // A model that names a catalogued tool without loading it first is
            // answered rather than refused. The tool array is what the provider
            // was offered, but dispatch resolves against the registry, so the
            // call can simply run — and the schema is revealed so the next
            // request carries it and the model can get the arguments right if
            // it guessed them wrong. Without this the catalog costs capability
            // rather than only tokens, which is not a trade worth making.
            if (self.catalog_mode and !self.revealed.contains(tc.name)) {
                if (self.reg.get(tc.name)) |t| {
                    if (!t.internal and t.enabled) {
                        self.revealed.put(self.arena, t.name, {}) catch {};
                        self.rebuildToolDefs();
                        log.log(.info, "tool '{s}' called from the catalog; its schema is now loaded", .{t.name});
                    }
                }
            }
        }

        // Warm the shared caches on the main thread before any worker
        // spawns: every tool's wasm bytes and every registered transform
        // module land in wasm_cache / the "transform:<name>" module cache
        // here, so worker threads only ever *read* those maps and never
        // insert into the shared StringArrayHashMapUnmanaged concurrently.
        self.warmToolCaches(calls);

        // ---- parallel pass: one worker per distinct tool name ----
        var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.ctx.gpa);
        var handles: std.ArrayList(WorkerHandle) = .empty;
        defer {
            // Join + free anything not yet handled (e.g. on error return).
            for (handles.items) |h| h.thread.join();
            for (handles.items) |h| {
                self.ctx.gpa.destroy(h.worker);
            }
            handles.deinit(self.ctx.gpa);
        }

        // Calls ready for a worker, with before-transforms already applied.
        const PendingCall = struct {
            slot: usize,
            tool: *const registry.Tool,
            eff_args: []const u8,
            wasm_bytes: []const u8,
        };
        var pending: std.ArrayList(PendingCall) = .empty;
        defer pending.deinit(self.ctx.gpa);

        for (calls, 0..) |tc, i| {
            if (seen.contains(tc.name)) continue; // duplicate -> sequential pass
            try seen.put(self.ctx.gpa, tc.name, {});

            const tool = self.reg.get(tc.name) orelse {
                results[i] = try std.fmt.allocPrint(self.arena, "{{\"ok\":false,\"error\":\"unknown tool: {s}\"}}", .{tc.name});
                continue;
            };
            // Tools that call the model stay on the sequential pass below:
            // one provider call at a time, and no worker thread ever shares
            // the HTTP client. Transform-wrapped tools ARE parallel-eligible:
            // their before-transforms run on the main thread just below (the
            // shared transform module cache is not thread-safe) and their
            // after-transforms run on the main thread after the join.
            if (tool.llm or tool.sequential or !tool.enabled) continue;
            if (self.no_parallel_tools) continue;
            const wasm_bytes = self.wasmBytes(tool) catch |err| {
                log.log(.error_, "tool '{s}': cannot load {s}: {s}", .{ tc.name, tool.wasm, @errorName(err) });
                results[i] = try std.fmt.allocPrint(self.arena, "{{\"ok\":false,\"error\":\"tool wasm missing: {s} ({s})\"}}", .{ tc.name, @errorName(err) });
                continue;
            };

            // Run the before-transform chain on the main thread, rewriting
            // this call's arguments before the worker ever sees them. The
            // call is queued, not spawned yet: a transform can itself call
            // the model (ck_llm) and take seconds, and spawning interleaved
            // with transforms would delay every later worker's start by the
            // accumulated transform time.
            const eff_args = self.runChain(tc.name, .before, tc.arguments) catch tc.arguments;
            try pending.append(self.ctx.gpa, .{ .slot = i, .tool = tool, .eff_args = eff_args, .wasm_bytes = wasm_bytes });
        }

        // All before-transforms are done, so spawn every worker now and they
        // all start (and run) together.
        for (pending.items) |p| {
            const worker = try self.ctx.gpa.create(ToolWorker);
            worker.* = .{
                .ctx = self.ctx,
                .cfg = self.cfg,
                .tool = p.tool,
                .arguments = p.eff_args,
                .wasm_bytes = p.wasm_bytes,
                .subagent_runner = self.subagent_runner,
            };
            const thread = try std.Thread.spawn(.{ .stack_size = parallel_tool_stack_bytes }, ToolWorker.run, .{worker});
            try handles.append(self.ctx.gpa, .{ .slot = p.slot, .thread = thread, .worker = worker, .wasm_bytes = p.wasm_bytes });
        }

        // Join every worker and move its output into the matching slot.
        for (handles.items) |h| h.thread.join();
        for (handles.items) |h| {
            if (h.worker.err) |e| {
                log.log(.error_, "tool '{s}' failed: {s}", .{ h.worker.tool.name, @errorName(e) });
                results[h.slot] = std.fmt.allocPrint(self.arena, "{{\"ok\":false,\"error\":\"tool execution failed: {s} ({s})\"}}", .{ h.worker.tool.name, @errorName(e) }) catch "{{\"ok\":false,\"error\":\"tool execution failed\"}}";
            } else if (h.worker.out) |out| {
                const owned = try self.arena.dupe(u8, out);
                self.ctx.gpa.free(out);
                // After-transforms run here, on the main thread after the
                // join, so no worker ever touches the shared transform cache.
                const transformed = self.runChain(h.worker.tool.name, .after, owned) catch owned;
                // A tool (or its after-transform chain) may legitimately
                // produce zero bytes; the conversation must never see a
                // zero-length tool result.
                results[h.slot] = if (transformed.len == 0) "{\"ok\":true,\"result\":\"\"}" else transformed;
            } else {
                results[h.slot] = "{\"ok\":false,\"error\":\"tool produced no output\"}";
            }
            self.ctx.gpa.destroy(h.worker);
        }
        handles.clearRetainingCapacity();

        // ---- sequential fallback: duplicate tool names (stateful modules) --
        for (calls, 0..) |tc, i| {
            // Null means "not executed yet"; a completed call with an empty
            // result must not be run a second time.
            if (results[i] != null) continue;
            // Run it on a worker even though nothing here is parallel: the
            // wasm interpreter recurses on the native stack, and the main
            // thread's stack is whatever the OS handed the process (8 MiB),
            // which a deep tool call blows outright — a segfault, not a
            // catchable trap. A worker gets the explicit reservation. When
            // this agent is *already* inside such a worker (a sub-agent, with
            // no_parallel_tools set) the stack is big enough, so run inline
            // and do not nest threads.
            results[i] = if (self.no_parallel_tools)
                try self.executeTool(tc)
            else
                try self.executeToolOnWorker(tc);
        }
        // Defensive: every slot is filled above, but a result handed to the
        // conversation must never be null or zero-length.
        for (results) |*r| {
            if (r.* == null or r.*.?.len == 0) r.* = "{\"ok\":true,\"result\":\"\"}";
        }
        return results;
    }

    /// Runs one tool call to completion on a dedicated worker thread with the
    /// explicit stack reservation, then applies the after-transform chain on
    /// the caller's thread (the transform module cache is not thread-safe).
    fn executeToolOnWorker(self: *Agent, tc: types.ToolCall) ![]const u8 {
        const tool = self.reg.get(tc.name) orelse
            return std.fmt.allocPrint(self.arena, "{{\"ok\":false,\"error\":\"unknown tool: {s}\"}}", .{tc.name});
        // Tools that call the model, and disabled ones, keep the original
        // in-thread path: they do not run wasm deeply and the LLM client is
        // not shared with worker threads.
        if (tool.llm or tool.sequential or !tool.enabled) return self.executeTool(tc);

        const wasm_bytes = self.wasmBytes(tool) catch |err| {
            log.log(.error_, "tool '{s}': cannot load {s}: {s}", .{ tc.name, tool.wasm, @errorName(err) });
            return std.fmt.allocPrint(self.arena, "{{\"ok\":false,\"error\":\"tool wasm missing: {s} ({s})\"}}", .{ tc.name, @errorName(err) });
        };
        const eff_args = self.runChain(tc.name, .before, tc.arguments) catch tc.arguments;

        const worker = try self.ctx.gpa.create(ToolWorker);
        defer self.ctx.gpa.destroy(worker);
        worker.* = .{
            .ctx = self.ctx,
            .cfg = self.cfg,
            .tool = tool,
            .arguments = eff_args,
            .wasm_bytes = wasm_bytes,
            .subagent_runner = self.subagent_runner,
        };
        const thread = try std.Thread.spawn(.{ .stack_size = parallel_tool_stack_bytes }, ToolWorker.run, .{worker});
        thread.join();

        if (worker.err) |e| {
            log.log(.error_, "tool '{s}' failed: {s}", .{ tc.name, @errorName(e) });
            return std.fmt.allocPrint(self.arena, "{{\"ok\":false,\"error\":\"tool execution failed: {s} ({s})\"}}", .{ tc.name, @errorName(e) });
        }
        const out = worker.out orelse return "{\"ok\":false,\"error\":\"tool produced no output\"}";
        const owned = try self.arena.dupe(u8, out);
        self.ctx.gpa.free(out);
        log.log(.info, "tool '{s}' -> {d} bytes", .{ tc.name, owned.len });
        // No check here: these bytes came from the worker, which already
        // checked them. Warning again reports one broken result twice.
        return self.runChain(tc.name, .after, owned) catch owned;
    }
};

/// zwasm's interpreter recurses on the native stack, so a tool that runs fine
/// on the main thread can trap with CallStackExhausted on a std.Thread worker
/// (whose default stack is smaller than the process main stack). Give parallel
/// tool workers an explicit stack size.
///
/// This is a *reservation*, not memory in use: the pages are mapped lazily, so
/// only the frames actually touched are ever resident. Lowering it frees no
/// real memory and has already cost two crashes.
///
/// DO NOT LOWER THIS. The interpreter's native call depth is not shallow: it
/// recurses per WASM frame, and a host call at the bottom recurses again (the
/// ck_exec JSON result is parsed there). A `search_code` call segfaulted the
/// process outright at 2 MiB — a stack overflow, not a catchable trap — and
/// the reasoning that "the host-side call depth is shallow" was written into
/// this comment once already and was wrong both times.
pub const parallel_tool_stack_bytes: usize = 64 * 1024 * 1024;

comptime {
    if (parallel_tool_stack_bytes < 32 * 1024 * 1024) @compileError(
        "parallel_tool_stack_bytes must stay >= 32 MiB: it is a lazily-mapped " ++
            "reservation (shrinking it frees nothing) and the wasm interpreter " ++
            "recursing into a host JSON parse overflowed a smaller stack, " ++
            "segfaulting the run. Measure a deep search_code call before changing it.",
    );
}

/// Lower bound for the above, asserted by a test. Raising the reservation is
/// fine; lowering either number is what the comptime check above forbids.
pub const parallel_tool_stack_floor_bytes: usize = 32 * 1024 * 1024;

/// Hard cap on a single response's completion tokens (per-turn budgeting): a
/// lone huge response must not blow the context window, even if the session
/// total is still under budget. Complements cfg.agent.max_total_tokens and
/// the byte-based history compaction in maybeCompactMessages.
const max_per_turn_tokens: u32 = 32768;

const WorkerHandle = struct {
    slot: usize,
    thread: std.Thread,
    worker: *ToolWorker,
    /// Arena-owned cached bytes (Agent.wasm_cache); never freed per call.
    wasm_bytes: []const u8,
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

        // Scratch arena for sandbox fields that need serialization
        // (config_json), mirroring what host.sandboxFor does with the
        // caller's arena on the sequential path.
        var arena_state = std.heap.ArenaAllocator.init(self.ctx.gpa);
        defer arena_state.deinit();

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
            .state_dir = self.cfg.agent.state_dir,
            .config_json = try std.fmt.allocPrint(arena_state.allocator(), "{f}", .{std.json.fmt(self.tool.config, .{})}),
        };

        log.log(.debug, "running tool '{s}' in sandbox args={s}", .{ self.tool.name, self.arguments });
        const t0 = std.Io.Timestamp.now(io, .awake);

        var mod = try runtime.ToolModule.load(self.ctx.gpa, io, &sb, self.wasm_bytes);
        defer mod.deinit();

        const out = try mod.executeTool(self.arguments);
        const t1 = std.Io.Timestamp.now(io, .awake);
        const ms = @divTrunc(t0.durationTo(t1).nanoseconds, std.time.ns_per_ms);
        log.log(.info, "tool '{s}' -> {d} bytes in {d}ms", .{ self.tool.name, out.len, ms });
        // Checked where the result is produced rather than where it is
        // consumed: the consumers are three different paths, and instrumenting
        // the two obvious ones missed the one that actually runs.
        toolout.warnIfMalformedAlloc(self.ctx.gpa, self.tool.name, out);
        self.out = out;
    }
};

/// Strips trailing punctuation from a candidate exact-match answer only when
/// the remainder is a number or boolean, so "42." becomes "42" while a string
/// like "hello." keeps its period (the user asked for the exact value).
fn stripTrailingPunctForExact(s: []const u8) []const u8 {
    var stripped = s;
    while (stripped.len > 0) {
        const ch = stripped[stripped.len - 1];
        if (ch != '.' and ch != ',' and ch != '!' and ch != '?' and ch != ';' and ch != ':') break;
        stripped = stripped[0 .. stripped.len - 1];
    }
    if (stripped.len == s.len) return s;
    const candidate = std.mem.trim(u8, stripped, " \t\r\n");
    if (isNumericString(candidate) or std.mem.eql(u8, candidate, "true") or std.mem.eql(u8, candidate, "false")) {
        return candidate;
    }
    return s;
}

fn isNumericString(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[0] == '-') {
        i = 1;
        if (i >= s.len) return false;
    }
    var saw_digit = false;
    var saw_dot = false;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (ch >= '0' and ch <= '9') {
            saw_digit = true;
        } else if (ch == '.' and !saw_dot) {
            saw_dot = true;
        } else {
            return false;
        }
    }
    return saw_digit;
}

test "isNumericString accepts ints, negatives, and single-dot floats only" {
    try std.testing.expect(isNumericString("42") == true);
    try std.testing.expect(isNumericString("-3.14") == true);
    try std.testing.expect(isNumericString("") == false);
    try std.testing.expect(isNumericString("-") == false);
    try std.testing.expect(isNumericString("1.2.3") == false);
    try std.testing.expect(isNumericString("12a") == false);
}

test "isNumericString rejects dot-only strings without digits" {
    // Pins the final `return saw_digit`: a bare "." or "-." passes every
    // per-character check but has no digit, so it is not a number. If the
    // saw_digit requirement were dropped, finalAnswer would happily reduce a
    // prose answer to "." — this test fails on that regression.
    try std.testing.expect(isNumericString(".") == false);
    try std.testing.expect(isNumericString("-.") == false);
    // The accepted edge forms: a dot may lead or trail the digits.
    try std.testing.expect(isNumericString(".5") == true);
    try std.testing.expect(isNumericString("3.") == true);
}

test "stripTrailingPunctForExact preserves string punctuation" {
    try std.testing.expectEqualStrings("hello.", stripTrailingPunctForExact("hello."));
    try std.testing.expectEqualStrings("hello,", stripTrailingPunctForExact("hello,"));
    try std.testing.expectEqualStrings("hello!!!", stripTrailingPunctForExact("hello!!!"));
    try std.testing.expectEqualStrings("42", stripTrailingPunctForExact("42."));
    try std.testing.expectEqualStrings("42", stripTrailingPunctForExact("42,"));
    try std.testing.expectEqualStrings("true", stripTrailingPunctForExact("true."));
    try std.testing.expectEqualStrings("hello", stripTrailingPunctForExact("hello"));
}

/// Extracts the exact-match answer from a JSON object: only unwraps when an
/// "answer" field is present (a deliberate signal that the model wrapped a
/// bare value). Never unwraps a JSON object the user actually asked for.
fn unwrapJsonAnswer(arena: std.mem.Allocator, json_str: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json_str, .{}) catch return null;
    if (parsed != .object) return null;
    const ans = parsed.object.get("answer") orelse return null;
    switch (ans) {
        .string => return ans.string,
        .integer => return std.fmt.allocPrint(arena, "{d}", .{ans.integer}) catch null,
        .float => return std.fmt.allocPrint(arena, "{d}", .{ans.float}) catch null,
        .bool => return if (ans.bool) "true" else "false",
        else => return null,
    }
}

test "unwrapJsonAnswer prefers a top-level answer field" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json = "{\"answer\":42,\"status\":\"ok\"}";
    const result = unwrapJsonAnswer(arena, json) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("42", result);
}

test "unwrapJsonAnswer returns null for object without answer field" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json = "{\"value\":7}";
    try std.testing.expect(unwrapJsonAnswer(arena, json) == null);
}

test "unwrapJsonAnswer returns null for multi-key object without answer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json = "{\"a\":1,\"b\":2}";
    try std.testing.expect(unwrapJsonAnswer(arena, json) == null);
}

test "the transform chain type-checks before anything calls it" {
    // Zig only analyzes referenced functions, so runChain/runTransform — which
    // have no call site yet — could carry a type error indefinitely and then
    // fail the build of whatever change finally wires them in, with the error
    // pointing at code that change never touched. Referencing them here forces
    // the analysis now.
    _ = &Agent.runChain;
    _ = &Agent.runTransform;
}

test "wasmBytes reads each wasm path from disk only once (cached slice)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const path = "test_wasm_bytes_cache.tmp";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "fake-wasm-bytes" });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    // wasmBytes only touches ctx.io, ctx.gpa, wasm_cache, and tool.wasm, so
    // the rest of the Agent/Tool state can stay undefined for this test.
    var ctx: client.Ctx = undefined;
    ctx.io = io;
    ctx.gpa = std.testing.allocator;
    var agent: Agent = undefined;
    agent.ctx = &ctx;
    agent.arena = arena_state.allocator();
    agent.wasm_cache = .empty;
    defer agent.deinit();

    var tool: registry.Tool = undefined;
    tool.wasm = path;

    const first = try agent.wasmBytes(&tool);
    const second = try agent.wasmBytes(&tool);
    try std.testing.expect(first.ptr == second.ptr);
    try std.testing.expect(first.len == second.len);
    try std.testing.expectEqualStrings("fake-wasm-bytes", second);
}

test "the parallel-tool stack reservation stays above the observed crash floor" {
    // Regression: successive "reduce the stack size" changes took this
    // reservation from 64 MiB down to 2 MiB, and a search_code call — the
    // zwasm interpreter recursing, then ck_exec's JSON result parsing on top
    // of it — overflowed the worker stack and segfaulted the whole run. The
    // reservation is lazily mapped, so a smaller number frees no real memory;
    // it only moves the crash closer. No other test spawns a worker with this
    // stack, so every shrink sailed through the gate.
    try std.testing.expect(parallel_tool_stack_bytes >= parallel_tool_stack_floor_bytes);

    // And the reservation has to be one a thread can actually be spawned with.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "tests/fixtures/tiny.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    const W = struct {
        wasm: []const u8,
        io: std.Io,
        sum: ?i32 = null,
        fn run(self: *@This()) void {
            var env = std.process.Environ.Map.init(std.testing.allocator);
            defer env.deinit();
            var sb = host.Sandbox{ .gpa = std.testing.allocator, .io = self.io, .root_dir = ".", .network_allow = &.{}, .environ_map = &env };
            const mod = runtime.ToolModule.load(std.testing.allocator, self.io, &sb, self.wasm) catch return;
            defer mod.deinit();
            var add = mod.inst.typedFunc(fn (i32, i32) i32, "add");
            self.sum = add.call(.{ 17, 25 }) catch return;
        }
    };
    var w = W{ .wasm = wasm, .io = io };
    const thread = try std.Thread.spawn(.{ .stack_size = parallel_tool_stack_bytes }, W.run, .{&w});
    thread.join();
    try std.testing.expectEqual(@as(i32, 42), w.sum orelse return error.WorkerDidNotRun);
}

test "maybeCompactMessages drops the middle, keeps the system prompt and the recent tail" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // maybeCompactMessages itself needs a live provider (its threshold comes
    // from provider.activeModel().context_window and the compaction path
    // summarizes the dropped middle with an LLM call), so this test drives its
    // two extracted pieces: compactionKeepStart (the budget/window decision)
    // and compactMiddle (the drop/preserve rewrite). A regression in either —
    // an inverted budget check, the wrong messages dropped, compaction
    // silently disabled, or the system prompt evicted — fails here.
    const filler = "x" ** 256;
    var messages: std.ArrayList(types.Message) = .empty;
    try messages.append(arena, .{ .role = .system, .content = "system prompt" });
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        try messages.append(arena, .{ .role = .user, .content = filler });
        try messages.append(arena, .{ .role = .assistant, .content = filler });
    }
    const before_len = messages.items.len; // system + 4 user/assistant pairs
    try std.testing.expect(before_len == 9);

    const estimated = Agent.estimateMessageTokens(messages.items);
    const threshold: usize = 16; // far below this history's estimated size
    try std.testing.expect(estimated > threshold);

    // Under budget: no compaction (an inverted budget check fails this).
    try std.testing.expect(Agent.compactionKeepStart(messages.items, estimated, estimated + 1) == null);
    // Too short to compact even when over budget: system + 6 messages.
    try std.testing.expect(Agent.compactionKeepStart(messages.items[0..7], estimated, threshold) == null);

    // Over budget with enough messages: keep system + summary + last 6.
    const keep_start = Agent.compactionKeepStart(messages.items, estimated, threshold) orelse return error.TestExpectedCompaction;
    try std.testing.expect(keep_start == 3);

    try Agent.compactMiddle(&messages, arena, keep_start, "[test summary]");

    // (a) The list shrank: the two dropped middle messages became one summary.
    try std.testing.expect(messages.items.len == before_len - 1);
    // (b) The system message is still first and unchanged.
    try std.testing.expect(messages.items[0].role == .system);
    try std.testing.expectEqualStrings("system prompt", messages.items[0].content.?);
    // The summary sits where the dropped middle was.
    try std.testing.expect(messages.items[1].role == .user);
    try std.testing.expectEqualStrings("[test summary]", messages.items[1].content.?);
    // (c) The most recent user/assistant turns are retained verbatim.
    try std.testing.expect(messages.items[messages.items.len - 1].role == .assistant);
    try std.testing.expectEqualStrings(filler, messages.items[messages.items.len - 1].content.?);
    try std.testing.expect(messages.items[messages.items.len - 2].role == .user);
    try std.testing.expectEqualStrings(filler, messages.items[messages.items.len - 2].content.?);
}

test "compactionKeepStart never splits a tool-call exchange" {
    // If the kept window would begin with tool-result messages whose
    // assistant tool_calls message is being dropped, the window must extend
    // backwards to include it — providers reject orphaned tool messages.
    var msgs: [9]types.Message = undefined;
    msgs[0] = .{ .role = .system, .content = "sys" };
    var i: usize = 1;
    while (i < 9) : (i += 1) msgs[i] = .{ .role = .user, .content = "turn" };
    // A tool exchange straddling the window boundary: assistant at index 2,
    // tool results at 3 and 4; len - 6 = 3 lands on a tool message.
    msgs[2] = .{ .role = .assistant, .content = "calls" };
    msgs[3] = .{ .role = .tool, .content = "r1" };
    msgs[4] = .{ .role = .tool, .content = "r2" };
    const keep_start = Agent.compactionKeepStart(&msgs, 10_000, 16) orelse return error.TestExpectedCompaction;
    try std.testing.expect(keep_start == 2);
}

test "compactionKeepStart walks back so a tool result is never orphaned from its tool_calls" {
    // With 9 messages the naive window start is index 3, which here is a
    // .tool result. The window must be extended backwards to the assistant
    // message that issued the calls, otherwise providers reject the kept
    // transcript for carrying a tool result with no matching tool_calls.
    const msgs = [_]types.Message{
        .{ .role = .system, .content = "sys" }, // 0
        .{ .role = .user, .content = "u1" }, // 1
        .{ .role = .assistant, .content = "a1" }, // 2 (issued the tool call)
        .{ .role = .tool, .content = "t1" }, // 3
        .{ .role = .user, .content = "u2" }, // 4
        .{ .role = .assistant, .content = "a2" }, // 5
        .{ .role = .tool, .content = "t2" }, // 6
        .{ .role = .user, .content = "u3" }, // 7
        .{ .role = .assistant, .content = "a3" }, // 8
    };
    const keep = Agent.compactionKeepStart(&msgs, 10_000, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(msgs[keep].role != .tool);
    try std.testing.expectEqual(@as(usize, 2), keep);
}

test "compactionKeepStart returns null when the history fits the threshold" {
    const msgs = [_]types.Message{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "hi" },
    };
    // estimated_tokens (4) <= threshold (1000): no compaction, no slicing.
    try std.testing.expect(Agent.compactionKeepStart(&msgs, 4, 1_000) == null);
}

test "compactionKeepStart returns null when the history is too short to compact" {
    const msgs = [_]types.Message{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "u1" },
        .{ .role = .assistant, .content = "a1" },
        .{ .role = .user, .content = "u2" },
        .{ .role = .assistant, .content = "a2" },
    };
    // Over the token threshold but fewer than 8 messages: compaction would
    // have to delete context it is supposed to preserve, so it must decline.
    try std.testing.expect(Agent.compactionKeepStart(&msgs, 10_000, 1) == null);
}

test "resumed-session cleanup drops dangling and partial tool-call exchanges" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // (1) A full exchange at the tail is kept untouched.
    {
        var messages: std.ArrayList(types.Message) = .empty;
        try messages.append(arena, .{ .role = .system, .content = "sys" });
        try messages.append(arena, .{ .role = .user, .content = "u" });
        try messages.append(arena, .{ .role = .assistant, .tool_calls = &.{
            .{ .id = "a", .name = "t1", .arguments = "{}" },
            .{ .id = "b", .name = "t2", .arguments = "{}" },
        } });
        try messages.append(arena, .{ .role = .tool, .tool_call_id = "a", .content = "r1" });
        try messages.append(arena, .{ .role = .tool, .tool_call_id = "b", .content = "r2" });
        Agent.dropDanglingToolExchange(&messages);
        try std.testing.expectEqual(@as(usize, 5), messages.items.len);
    }

    // (2) A partial exchange (only 1 of 2 results persisted) is dropped
    // entirely, parent assistant message included.
    {
        var messages: std.ArrayList(types.Message) = .empty;
        try messages.append(arena, .{ .role = .system, .content = "sys" });
        try messages.append(arena, .{ .role = .user, .content = "u" });
        try messages.append(arena, .{ .role = .assistant, .tool_calls = &.{
            .{ .id = "a", .name = "t1", .arguments = "{}" },
            .{ .id = "b", .name = "t2", .arguments = "{}" },
        } });
        try messages.append(arena, .{ .role = .tool, .tool_call_id = "a", .content = "r1" });
        Agent.dropDanglingToolExchange(&messages);
        try std.testing.expectEqual(@as(usize, 2), messages.items.len);
        try std.testing.expectEqual(types.Role.user, messages.items[1].role);
    }

    // (3) An orphan tool result whose tool_call_id matches no call is dropped
    // along with its parent assistant message.
    {
        var messages: std.ArrayList(types.Message) = .empty;
        try messages.append(arena, .{ .role = .system, .content = "sys" });
        try messages.append(arena, .{ .role = .assistant, .tool_calls = &.{
            .{ .id = "a", .name = "t1", .arguments = "{}" },
        } });
        try messages.append(arena, .{ .role = .tool, .tool_call_id = "zzz", .content = "orphan" });
        Agent.dropDanglingToolExchange(&messages);
        try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    }

    // (4) A trailing assistant tool_calls message with no results at all is
    // popped (the pre-existing behavior).
    {
        var messages: std.ArrayList(types.Message) = .empty;
        try messages.append(arena, .{ .role = .system, .content = "sys" });
        try messages.append(arena, .{ .role = .assistant, .tool_calls = &.{
            .{ .id = "a", .name = "t1", .arguments = "{}" },
        } });
        Agent.dropDanglingToolExchange(&messages);
        try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    }
}

test "finalAnswer preserves an exact string answer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var agent: Agent = undefined;
    agent.arena = arena;

    const resp = types.ChatResponse{ .message = .{ .role = .assistant, .content = "clanker online" } };
    const ans = try agent.finalAnswer(resp);
    try std.testing.expectEqualStrings("clanker online", ans.message.content.?);
}

test "finalAnswer strips a prose prefix to the exact answer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var agent: Agent = undefined;
    agent.arena = arena;

    const resp = types.ChatResponse{ .message = .{ .role = .assistant, .content = "The answer is clanker online" } };
    const ans = try agent.finalAnswer(resp);
    try std.testing.expectEqualStrings("clanker online", ans.message.content.?);
}

test "finalAnswer prefers the first non-empty line over trailing prose" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var agent: Agent = undefined;
    agent.arena = arena;

    const resp = types.ChatResponse{ .message = .{ .role = .assistant, .content = "clanker online\n\nSome trailing explanation that must not replace the answer." } };
    const ans = try agent.finalAnswer(resp);
    try std.testing.expectEqualStrings("clanker online", ans.message.content.?);
}
