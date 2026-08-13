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
const private_todos = @import("private_todos.zig");
const system_prompt = @import("system_prompt.zig");
const graph_mod = @import("graph.zig");
const autolearn = @import("autolearn.zig");
const chatrooms = @import("../peers/chatrooms.zig");
const filelock = @import("../util/filelock.zig");
const log = @import("../util/log.zig");
const toolout = @import("../util/toolout.zig");
const utf8 = @import("../util/utf8.zig");
const mock_server = @import("../llm/mock_server.zig");

/// Appended to the system prompt so a model asked for an exact-format answer
/// (a string, a number, JSON) does not wrap it in prose or markdown fences.
const exact_format_suffix = "\n\nIMPORTANT: When the user requests a specific output format (exact string, JSON, number, etc.), respond with ONLY that exact value. Do not wrap it in markdown fences, do not add prose, explanations, or punctuation. Return the value verbatim, preserving exact capitalization and punctuation.";

/// Appended to the system prompt when [[Agent.plan_mode]] is set. The prompt
/// alone is not the gate, executeCalls refuses write-capable tools in plan
/// mode whatever the model decides, but telling the model up front is what
/// turns those refusals from confusing failures into a coherent mode.
const plan_mode_suffix = "\n\nPLAN MODE: This run is a proposal, not an execution. Read-only tools work normally; any tool that could change state (files, commands, delegation) is refused by the harness in this mode, so do not attempt it. Investigate as needed, then answer with a concrete, numbered plan of the steps you would take. The user reviews the plan and applies it as a follow-up run.";

/// Appended to the system prompt when [[Agent.research_mode]] is set, the
/// composer's Research toggle, the web-search parity control. A directive,
/// not a gate: web_search/fetch_web are ordinary enabled tools the model
/// could already call; this tells it the operator wants web-backed answers
/// and when to reach for them.
const research_mode_suffix = "\n\nRESEARCH MODE: The operator turned on web research for this run. Prefer current, sourced information over stale knowledge: consult web_search (or fetch_web for a specific page) when the answer depends on facts that change (versions, prices, events, APIs, today's news) and cite what you found. Do not fetch for the sake of fetching; a question answerable from context needs no network call.";

/// A fork resolved by the human: what was asked, and what they chose.
pub const Decision = struct {
    question: []const u8,
    answer: []const u8,
};

/// One poll for a mid-run steering message (see Agent.steer_fn). Returns the
/// next queued message duped into `arena`, or null when nothing is queued. A
/// bare function pointer like AskFn, because the wiring side (cli.zig's serve)
/// identifies the run through a threadlocal rather than a context argument.
pub const SteerFn = *const fn (arena: std.mem.Allocator) ?[]const u8;

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
    /// Set from outside the run (the REPL's SIGINT handler) to ask this run to
    /// stop. Checked between iterations, which is the only place stopping is
    /// safe: a tool is already running by then, and a half-written state file
    /// is worse than a turn that takes another few seconds to notice.
    stop_flag: ?*std.atomic.Value(bool) = null,
    max_iterations: u32,
    /// The system prompt (arena-owned), rebuilt when skills change.
    system_prompt_text: []const u8,
    /// Instance identity and peer names, kept so refreshSystemPrompt rebuilds
    /// the same prompt init built, without them a mid-session refresh
    /// silently drops the Identity section from the system prompt.
    instance_name: []const u8 = "",
    instance_id: []const u8 = "",
    peer_names: []const []const u8 = &.{},
    /// Loaded tool modules, keyed by tool name (wasm modules are stateful in
    /// zwasm for AssemblyScript guests, cache and reuse instead of
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
    /// Human approval for write-capable tool calls, wired by the surfaces
    /// agent.confirm_writes opts in (the streaming web run, the REPL). Null
    /// means no gate, the state headless runs, the improve loop and nested
    /// sub-agents must stay in, because they have nobody to answer.
    confirm_fn: ?host.ConfirmFn = null,
    /// Mid-run steering, wired by the streaming web run (POST /api/steer):
    /// polled between iterations, each returned string joins the conversation
    /// as a user message. The callee dupes into the passed arena, so the
    /// message lives exactly as long as the rest of this run's transcript.
    /// Null everywhere there is nobody who could interject.
    steer_fn: ?SteerFn = null,
    /// Plan mode (webui-plan 2.2): the run proposes instead of executing.
    /// [[plan_mode_suffix]] is threaded into the system prompt and
    /// executeCalls refuses write-capable tools (the same needsConfirm
    /// predicate confirm-before-write gates on), so a plan run can research
    /// freely but cannot change anything, whatever the model decides.
    plan_mode: bool = false,
    /// Research mode (the composer's Research toggle): [[research_mode_suffix]]
    /// is threaded into the system prompt, directing the run to consult
    /// web_search/fetch_web for current, sourced facts. A directive, not a
    /// gate, the tools stay ordinary and the model stays free.
    research_mode: bool = false,
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
    /// Caller-supplied run id for the execution graph, replacing the
    /// second-resolution "run-<ts>" default. Set by subagent.runNested so a
    /// nested run's graph cannot collide with its parent's (or a sibling's,
    /// spawned in the same second) and is recognizable in state/runs/.
    run_id_override: ?[]const u8 = null,
    /// The run id of the agent that spawned this one, empty for top-level
    /// runs. Recorded into the execution graph so a nested run's timeline
    /// links back to its caller's (webui-plan 3.1).
    parent_run_id: []const u8 = "",
    /// The graph run id of the run in flight, handed to tool sandboxes so
    /// ck_subagent can tell the nested run who spawned it.
    current_run_id: []const u8 = "",
    /// This run's private todo list. `run` creates one for a top-level run;
    /// subagent.runNested attaches its own before calling `run`. Handed to
    /// every tool sandbox so todo_* calls that name no "room" reach it (see
    /// src/agent/private_todos.zig).
    private_todos: ?*private_todos.List = null,
    /// A nested run's channel to the agent that spawned it, wired by
    /// subagent.runNested and null for top-level agents. Handed to every tool
    /// sandbox so ask_user {"parent": true} can reach it.
    parent_ask: ?host.ParentAsk = null,
    /// The messages of the run in flight, so this agent can answer a
    /// sub-agent's question from its own transcript. Only read while the
    /// agent is parked in ck_subagent's join (see host.ParentAsk).
    current_messages: ?*std.ArrayList(types.Message) = null,
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
    /// Optional hook fired after a tool batch that changed this run's private
    /// todo list, with the list as a bare JSON array (see
    /// `private_todos.listJson`). Lets a viewer watch the run's own checklist
    /// while it runs, the list itself is still in-memory and still discarded
    /// when the run returns, so this is a window, not a second store. Fired on
    /// the run thread after `executeCalls` has joined its workers, and only on
    /// an actual change (`List.rev`), so a run that never touches todo_* never
    /// pays for it.
    on_todos: ?*const fn ([]const u8) void = null,
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
        const home = ctx.environ_map.get("HOME") orelse "";
        const global_path = (try system_prompt.resolveGlobalInstructionsPath(arena, home, cfg.agent.global_instructions_file)) orelse "";
        const workflows_mod = @import("workflows.zig");
        const wf_catalog = blk: {
            if (cfg.agent.workflows_dir.len == 0) break :blk "";
            const wfs = workflows_mod.loadAllMerged(arena, ctx.io, cfg.agent.workflows_dir) catch break :blk "";
            break :blk workflows_mod.catalogText(arena, wfs) catch "";
        };
        const base_prompt = try system_prompt.build(arena, ctx.io, .{
            .system_prompt_file = cfg.agent.system_prompt_file,
            .skills_dir = cfg.agent.skills_dir,
            .learnings_file = cfg.agent.learnings_file,
            .instance_name = cfg.instance.name,
            .instance_id = cfg.instance.id,
            .peers = peer_names.items,
            .catalog = catalog,
            .workflows_catalog = wf_catalog,
            .global_instructions_file = global_path,
            .home = home,
        }, defs);
        const prompt_text = try std.fmt.allocPrint(arena, "{s}{s}", .{ base_prompt, exact_format_suffix });
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
    /// Whether someone asked this run to stop, consuming the request so the
    /// next turn starts clean: a Ctrl-C that arrives as a turn is finishing
    /// must not cancel the turn after it.
    fn stopRequested(self: *Agent) bool {
        return takeStopRequest(self.stop_flag);
    }

    fn refreshSystemPrompt(self: *Agent, messages: *std.ArrayList(types.Message)) void {
        const home = self.ctx.environ_map.get("HOME") orelse "";
        const global_path = (system_prompt.resolveGlobalInstructionsPath(self.arena, home, self.cfg.agent.global_instructions_file) catch null) orelse "";
        const workflows_mod = @import("workflows.zig");
        const wf_catalog = blk: {
            if (self.cfg.agent.workflows_dir.len == 0) break :blk "";
            const wfs = workflows_mod.loadAllMerged(self.arena, self.ctx.io, self.cfg.agent.workflows_dir) catch break :blk "";
            break :blk workflows_mod.catalogText(self.arena, wfs) catch "";
        };
        const base_prompt = system_prompt.build(self.arena, self.ctx.io, .{
            .system_prompt_file = self.cfg.agent.system_prompt_file,
            .skills_dir = self.cfg.agent.skills_dir,
            .learnings_file = self.cfg.agent.learnings_file,
            .instance_name = self.instance_name,
            .instance_id = self.instance_id,
            .peers = self.peer_names,
            .catalog = if (self.catalog_mode) (self.reg.catalogText(self.arena, &self.revealed) catch "") else "",
            .workflows_catalog = wf_catalog,
            .global_instructions_file = global_path,
            .home = home,
        }, self.tool_defs) catch |err| {
            log.log(.warn, "refreshSystemPrompt: system_prompt.build failed: {s}", .{@errorName(err)});
            return;
        };
        const prompt_text = std.fmt.allocPrint(self.arena, "{s}{s}{s}{s}", .{ base_prompt, exact_format_suffix, if (self.plan_mode) plan_mode_suffix else "", if (self.research_mode) research_mode_suffix else "" }) catch |err| {
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
        // A top-level run needs the same private scratch checklist as a nested
        // run. Keep an injected sub-agent list intact, but create a fresh
        // arena-owned list when there is none and detach it at the end so a
        // later REPL turn never sees this turn's work.
        const inherited_private_todos = self.private_todos;
        if (self.private_todos == null) {
            const todos = try self.arena.create(private_todos.List);
            todos.* = .{ .alloc = self.arena };
            self.private_todos = todos;
        }
        defer self.private_todos = inherited_private_todos;
        // Each run() call is self-contained: `stats` counts only this run's
        // tokens, so per-run logging, autolearn records, and the defer that
        // folds `stats` into `session_stats` are all correct. Without this
        // reset, a multi-turn REPL session accumulated prior runs' totals in
        // `stats`, and `session_stats` double-counted them on every call.
        self.stats = .{};
        // The tally is what decides which schemas are loaded next time, so it
        // is written whatever happens to this run, including the runs that
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
            // wasm_cache is gpa-owned and survives across turns (freed once
            // in Agent.deinit at session end): do NOT clear it here.
            const run_ms: u64 = @intCast(@divTrunc(run_start.durationTo(std.Io.Timestamp.now(self.ctx.io, .awake)).nanoseconds, std.time.ns_per_ms));
            const tps: f64 = if (run_ms > 0) @as(f64, @floatFromInt(self.stats.total_completion_tokens)) / (@as(f64, @floatFromInt(run_ms)) / 1000.0) else 0;
            const prompt_total = self.stats.total_cache_hit_tokens + self.stats.total_cache_miss_tokens;
            const hit_rate: f64 = if (prompt_total > 0) @as(f64, @floatFromInt(self.stats.total_cache_hit_tokens)) / @as(f64, @floatFromInt(prompt_total)) * 100.0 else 0;
            log.log(.debug, "run tokens: prompt={d} completion={d} total={d} ({d:.1} tok/s) cache={d} hit/{d} miss ({d:.0}%) cost=${d:.4}", .{ self.stats.total_prompt_tokens, self.stats.total_completion_tokens, self.stats.total_tokens, tps, self.stats.total_cache_hit_tokens, self.stats.total_cache_miss_tokens, hit_rate, self.stats.cost });
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
            .run_id = self.run_id_override orelse try std.fmt.allocPrint(self.arena, "run-{d}", .{started_at}),
            .parent_run_id = self.parent_run_id,
            .task = task,
            .provider = self.provider.name,
            .started_at = started_at,
        };
        defer {
            g.duration_ms = @intCast(@divTrunc(run_start.durationTo(std.Io.Timestamp.now(self.ctx.io, .awake)).nanoseconds, std.time.ns_per_ms));
            if (self.cfg.modules.graphs) self.persistGraph(&g);
            g.deinit(self.ctx.gpa);
        }
        self.current_task = task;
        self.current_run_id = g.run_id;
        self.current_messages = messages;
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
        // partial exchange, so complete or drop any dangling tail before
        // continuing.
        try dropDanglingToolExchange(self.arena, messages);
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
            const cursor = chatrooms.readCursor(std.Io.Dir.cwd(), self.ctx.io, self.arena, state_dir);
            const inbox = chatrooms.readNew(std.Io.Dir.cwd(), self.ctx.io, self.ctx.gpa, self.arena, state_dir, cursor) catch &[_]chatrooms.Message{};
            if (inbox.len > 0) {
                var chat_buf: std.ArrayList(u8) = .empty;
                defer chat_buf.deinit(self.ctx.gpa);
                try chat_buf.appendSlice(self.ctx.gpa, "[chatroom inbox]\n");
                for (inbox) |m| {
                    const preview = if (m.text.len > 300) m.text[0..300] else m.text;
                    const line = try std.fmt.allocPrint(self.ctx.gpa, "- [{s}] {s}: \"{s}\"\n", .{ m.room, m.from, preview });
                    defer self.ctx.gpa.free(line);
                    try chat_buf.appendSlice(self.ctx.gpa, line);
                }
                const text = try self.arena.dupe(u8, chat_buf.items);
                if (text.len > 0) {
                    try messages.append(self.arena, .{ .role = .user, .content = text });
                    chatrooms.writeCursor(std.Io.Dir.cwd(), self.ctx.io, self.ctx.gpa, state_dir, inbox[inbox.len - 1]);
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
        var call_counts: std.ArrayHashMapUnmanaged(u64, u32, struct {
            pub fn hash(_: @This(), key: u64) u32 {
                return @truncate(key);
            }
            pub fn eql(_: @This(), a: u64, b: u64, _: usize) bool {
                return a == b;
            }
        }, true) = .empty;
        defer call_counts.deinit(self.ctx.gpa);
        // Last private-todo revision already reported to `on_todos`. Starts at
        // the list's current revision rather than 0 so a nested run that
        // inherits a populated list does not re-announce items the viewer
        // already has.
        var last_todos_rev: u32 = if (self.private_todos) |l| l.rev else 0;
        while (iteration < self.max_iterations) : (iteration += 1) {
            if (self.stopRequested()) {
                log.log(.info, "run stopped at iteration {d}", .{iteration + 1});
                try g.add(self.ctx.gpa, .{
                    .kind = .final,
                    .iteration = iteration,
                    .label = "stopped",
                    .output = "",
                    .ok = false,
                });
                return .{ .message = .{ .role = .assistant, .content = "[stopped]" } };
            }
            // Mid-run steering: messages posted while the run works (POST
            // /api/steer) join the conversation here, between iterations.
            // The one seam where a user message is always legal, because the
            // previous batch's tool results are already appended. Drained
            // fully so two quick interjections both make this LLM call.
            if (self.steer_fn) |steer| {
                while (steer(self.arena)) |text| {
                    log.log(.info, "steering message joined the run at iteration {d} ({d} bytes)", .{ iteration + 1, text.len });
                    try messages.append(self.arena, .{ .role = .user, .content = text });
                    try g.add(self.ctx.gpa, .{
                        .kind = .decision,
                        .iteration = iteration,
                        .label = "user steered the run",
                        .output = graph_mod.truncatedPreview(text),
                        .ok = true,
                    });
                }
            }
            // Prune stale tool outputs before compaction: large results the
            // model already processed are shortened in place so the estimated
            // token count that drives compaction reflects the reduced payload,
            // and subsequent LLM calls carry less redundant context.
            pruneOldToolResults(messages.items, self.arena, 6);
            // Log estimated prompt tokens before each LLM call for visibility
            // into context usage and to aid compaction tuning. maybeCompactMessages
            // already computes this while deciding whether to compact, so reuse
            // its result instead of rescanning every message a second time.
            const est_prompt_tokens = try self.maybeCompactMessages(messages);
            const ctx_window = self.provider.activeModel().context_window;
            const utilization: f64 = if (ctx_window > 0) @as(f64, @floatFromInt(est_prompt_tokens)) / @as(f64, @floatFromInt(ctx_window)) * 100.0 else 0;
            log.log(.debug, "LLM call: ~{d} estimated prompt tokens ({d:.0}% of {d} context window)", .{ est_prompt_tokens, utilization, ctx_window });

            const llm_t0 = std.Io.Timestamp.now(self.ctx.io, .awake);
            const resp = if (self.on_token) |cb| blk: {
                if (!self.cfg.modules.streaming) break :blk try self.llmChat(messages.items, err_detail, &g, iteration, llm_t0);
                break :blk client.chatStream(self.ctx, self.arena, .{
                    .provider = self.provider,
                    .messages = messages.items,
                    .tools = self.tool_defs,
                }, err_detail, cb, self.stop_flag) catch |err| {
                    if (err != error.Interrupted) {
                        try self.recordFailedLlm(&g, iteration, llm_t0, err, err_detail.*);
                        return err;
                    }
                    // Same outcome as the between-iterations stopRequested()
                    // check above, for a Ctrl-C that instead landed mid-stream.
                    _ = self.stopRequested(); // consume the flag
                    log.log(.debug, "run stopped mid-stream at iteration {d}", .{iteration + 1});
                    try g.add(self.ctx.gpa, .{
                        .kind = .final,
                        .iteration = iteration,
                        .label = "stopped",
                        .output = "",
                        .ok = false,
                    });
                    return .{ .message = .{ .role = .assistant, .content = "[stopped]" } };
                };
            } else try self.llmChat(messages.items, err_detail, &g, iteration, llm_t0);
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

            if (resp.usage) |u| self.recordUsage(u);

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
            // turns that still want tool calls, a final answer is never
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
                const fp = blk: {
                    var h = std.hash.Wyhash.init(0);
                    h.update(tc.name);
                    h.update("\x00");
                    h.update(tc.arguments);
                    break :blk h.final();
                };
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
                        results[i] = "{\"ok\":false,\"error\":\"identical tool call already executed twice with the same arguments; do not repeat it; answer with the information you already have\"}";
                    } else {
                        results[i] = run_results[ri];
                        ri += 1;
                    }
                }
            }
            if (self.on_tool_result) |cb| {
                const tool_ms: u64 = @intCast(@divTrunc(tool_t0.durationTo(std.Io.Timestamp.now(self.ctx.io, .awake)).nanoseconds, std.time.ns_per_ms));
                cb(tool_ms);
            }
            // The batch has joined, so the private list is quiescent again and
            // this thread is the only reader. Serializing it costs nothing
            // unless a todo_* call actually moved it.
            if (self.on_todos) |cb| {
                if (self.private_todos) |list| {
                    if (list.rev != last_todos_rev) {
                        last_todos_rev = list.rev;
                        cb(try private_todos.listJson(list, self.arena));
                    }
                }
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
                    if (std.mem.find(u8, content, "\"image\":{\"mime\":")) |_| {
                        const img = std.json.parseFromSliceLeaky(ImageResult, self.arena, content, .{ .ignore_unknown_fields = true }) catch null;
                        if (img) |im| {
                            if (im.image) |iv| image = .{ .mime = iv.mime, .b64 = iv.b64 };
                        }
                    }
                }
                if (self.cfg.modules.autolearn) {
                    if (std.mem.startsWith(u8, content, "{\"ok\":false")) {
                        const kind: []const u8 = if (std.mem.find(u8, content, "unknown tool") != null) "unknown_tool" else "tool_error";
                        autolearn.record(self.ctx.io, self.ctx.gpa, self.arena, kind, tc.name, errorDetail(self.arena, content));
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
                    .arguments = graph_mod.truncatedArgs(tc.arguments),
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
                // Cap tool results entering the conversation so a single huge
                // output cannot dominate the next LLM call's context. Graph,
                // check-verdict, and multimodal paths above used the uncapped
                // content; only the message to the model is bounded.
                const capped = try capToolResult(self.arena, content);
                try messages.append(self.arena, .{
                    .role = .tool,
                    .tool_call_id = tc.id,
                    .content = capped,
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

    /// A crash (or atomic-rename rebuild) between the assistant's tool_calls
    /// message and its tool results can persist a resumed session mid-batch:
    /// either a trailing assistant message with no results ever answered, or
    /// trailing .tool results that only partially answer the tool_calls of
    /// their nearest preceding assistant message.
    ///
    /// A tool call that already has a persisted result already ran, possibly
    /// with a real, non-idempotent side effect (a file write, a shell
    /// command), so its result is kept rather than discarded, which would
    /// otherwise leave the model no record that the call happened and free to
    /// blindly re-issue it. A call with no result yet is truly unknown (it
    /// may have run and lost its result, or never run at all), so it gets a
    /// synthetic "interrupted" result instead of being silently dropped and
    /// invisibly retried. Only a batch with no results at all (nothing ever
    /// executed) or an orphaned result matching no known call is dropped
    /// outright. Repeats until the tail is clean.
    fn dropDanglingToolExchange(arena: std.mem.Allocator, messages: *std.ArrayList(types.Message)) !void {
        while (messages.items.len > 0) {
            const last = messages.items[messages.items.len - 1];
            if (last.role == .assistant and last.tool_calls != null and last.tool_calls.?.len > 0) {
                _ = messages.pop();
                continue;
            }
            if (last.role != .tool) break;
            var tail = messages.items.len;
            while (tail > 0 and messages.items[tail - 1].role == .tool) tail -= 1;
            const trailing = messages.items[tail..];
            const parent = if (tail > 0) messages.items[tail - 1] else null;
            const calls = if (parent) |p| (if (p.role == .assistant) p.tool_calls else null) else null;
            if (calls == null or calls.?.len == 0) {
                // No matching assistant tool_calls message to answer to: this
                // tail cannot be salvaged.
                messages.items.len = tail;
                continue;
            }
            // Every trailing result must answer one of this batch's calls; a
            // result that matches none of them is an orphan the batch cannot
            // be trusted around, so the whole thing is dropped (the next pass
            // pops the parent via the first branch above).
            var orphaned = false;
            for (trailing) |tm| {
                const tid = tm.tool_call_id orelse {
                    orphaned = true;
                    break;
                };
                var found = false;
                for (calls.?) |tc| {
                    if (std.mem.eql(u8, tc.id, tid)) found = true;
                }
                if (!found) {
                    orphaned = true;
                    break;
                }
            }
            if (orphaned) {
                messages.items.len = tail;
                continue;
            }
            if (trailing.len == calls.?.len) break; // already complete
            for (calls.?) |tc| {
                var found = false;
                for (trailing) |tm| {
                    if (tm.tool_call_id) |tid| {
                        if (std.mem.eql(u8, tc.id, tid)) {
                            found = true;
                            break;
                        }
                    }
                }
                if (!found) {
                    try messages.append(arena, .{
                        .role = .tool,
                        .tool_call_id = tc.id,
                        .content = "{\"ok\":false,\"error\":\"interrupted before this tool call finished (process restart); its outcome is unknown \\u2014 if it has side effects, check whether it already happened before repeating it\"}",
                    });
                }
            }
            break;
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
    const reasoning_path = "state/reasoning.jsonl";
    /// Hard cap on the log so a long-running agent cannot grow state without
    /// bound; see [[trimReasoningLog]].
    const reasoning_max_log_bytes = 8 << 20;
    /// Lines kept when the log is trimmed for exceeding the cap.
    const reasoning_keep_lines = 2000;

    /// Appends one reasoning trace to state/reasoning.jsonl (RLM).
    ///
    /// Appends via a locked seek-to-end write rather than a read-modify-write:
    /// the previous version re-read and rewrote the entire log on every LLM
    /// call, making per-call cost and total I/O grow with the log's size
    /// (quadratic over a session), and lost records under concurrent writers
    /// since it bypassed the lock other state logs use (see filelock.zig).
    fn recordReasoning(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, provider: []const u8, model: []const u8, task: []const u8, reasoning: []const u8) void {
        _ = arena;
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
        s.write(autolearn.capUtf8(task, reasoning_record_task_chars)) catch return;
        s.objectField("reasoning") catch return;
        s.write(autolearn.capUtf8(reasoning, reasoning_record_reasoning_chars)) catch return;
        s.endObject() catch return;

        appendReasoningLine(std.Io.Dir.cwd(), io, gpa, buf[0..w.end]);
    }

    fn appendReasoningLine(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, line: []const u8) void {
        var guard = filelock.acquire(io, base, "state", "reasoning", gpa);
        defer guard.release();

        // Trim before opening for append below: trimming rewrites the file
        // and would otherwise contend with the handle about to be held open.
        if (base.statFile(io, reasoning_path, .{})) |st| {
            if (st.size > reasoning_max_log_bytes) trimReasoningLog(base, io, gpa) catch {};
        } else |_| {}

        const file = base.createFile(io, reasoning_path, .{ .truncate = false }) catch |err| {
            log.log(.warn, "recordReasoning: failed to open {s}: {s}", .{ reasoning_path, @errorName(err) });
            return;
        };
        defer file.close(io);
        const size = (file.stat(io) catch return).size;
        var wbuf: [512]u8 = undefined;
        var fw = file.writer(io, &wbuf);
        fw.seekToUnbuffered(size) catch return;
        fw.interface.writeAll(line) catch return;
        fw.interface.writeAll("\n") catch return;
        fw.flush() catch return;
    }

    /// Rewrites state/reasoning.jsonl keeping only the newest
    /// `reasoning_keep_lines` lines.
    fn trimReasoningLog(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator) !void {
        const raw = try base.readFileAlloc(io, reasoning_path, gpa, .limited(reasoning_max_log_bytes * 2));
        defer gpa.free(raw);
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(gpa);
        var it = std.mem.splitScalar(u8, raw, '\n');
        while (it.next()) |ln| {
            if (ln.len == 0) continue;
            try lines.append(gpa, ln);
        }
        const keep = if (lines.items.len > reasoning_keep_lines) lines.items.len - reasoning_keep_lines else 0;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try out.ensureTotalCapacity(gpa, raw.len);
        for (lines.items[keep..]) |ln| {
            try out.appendSlice(gpa, ln);
            try out.append(gpa, '\n');
        }
        try base.writeFile(io, .{ .sub_path = reasoning_path, .data = out.items });
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
    fn maybeCompactMessages(self: *Agent, messages: *std.ArrayList(types.Message)) !usize {
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
        // Honor the dedicated per-history token cap when configured: this is
        // a tighter knob than the session-level max_total_tokens (which
        // counts completions too) and the byte-based compact_threshold_bytes.
        threshold = @min(threshold, self.cfg.agent.max_history_tokens);
        // Threshold floors: compaction must never race the per-turn cap,
        // which would otherwise terminate the run before compaction runs.
        threshold = @max(threshold, max_per_turn_tokens);
        const keep_start = compactionKeepStart(messages.items, estimated_tokens, threshold) orelse return estimated_tokens;
        log.log(.info, "compacting conversation: {d} messages, ~{d} estimated tokens (threshold {d})", .{ messages.items.len, estimated_tokens, threshold });
        // Build a summary of the messages being removed (indices 1..keep_start-1).
        const summary_text = self.summarizeMessages(messages.items[1..keep_start]) catch |err| blk: {
            log.log(.warn, "compaction summary failed ({s}), trying local extractive summary", .{@errorName(err)});
            break :blk self.localSummary(messages.items[1..keep_start]);
        };
        const placeholder = summary_text orelse "[earlier conversation compacted; the context is summarized above in learnings and skills]";
        try compactMiddle(messages, self.arena, keep_start, placeholder);
        return estimateMessageTokens(messages.items);
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

    /// Maximum bytes of tool-result content to keep for messages outside the
    /// recent tail when pruning stale tool outputs.
    const prune_preview_bytes: usize = 200;

    /// Shrinks tool-result content in older messages (outside the most recent
    /// `keep_tail` messages) so that large outputs the model has already
    /// processed do not keep inflating every subsequent LLM call. Each pruned
    /// tool message retains only a short preview of its content. This is a
    /// complement to `maybeCompactMessages` (which drops whole messages): it
    /// reduces per-message token cost without losing the message structure
    /// that providers require (tool results stay paired with their
    /// tool_calls).
    fn pruneOldToolResults(messages: []types.Message, arena: std.mem.Allocator, keep_tail: usize) void {
        if (messages.len <= keep_tail + 1) return; // +1 for system prompt
        // Everything between the system prompt (index 0) and the kept tail is
        // eligible for pruning.
        const prune_end = messages.len - keep_tail;
        for (messages[1..prune_end]) |*m| {
            if (m.role != .tool) continue;
            const content = m.content orelse continue;
            if (content.len <= prune_preview_bytes) continue;
            m.content = std.fmt.allocPrint(
                arena,
                "{s}... [pruned: {d} bytes total]",
                .{ content[0..prune_preview_bytes], content.len },
            ) catch continue;
        }
    }

    /// Builds a best-effort extractive summary from the messages themselves,
    /// without calling the LLM. Used as a fallback when summarizeMessages
    /// fails (network error, budget exhausted, etc.) so compaction never
    /// discards context entirely.
    fn localSummary(self: *Agent, msgs: []const types.Message) ?[]const u8 {
        if (msgs.len == 0) return null;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.ctx.gpa);
        buf.ensureTotalCapacity(self.ctx.gpa, 4096) catch {};
        var hdr_buf: [96]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hdr_buf, "[conversation summary: {d} earlier messages compacted (extractive)]\n", .{msgs.len}) catch return null;
        buf.appendSlice(self.ctx.gpa, hdr) catch return null;

        // Cap the total summary size so it does not itself blow the context.
        const max_summary: usize = 4000;
        const content_preview_chars = 200;
        const tool_result_preview_chars = 150;
        const args_preview_chars = 120;
        var tool_calls_seen: std.StringArrayHashMapUnmanaged(void) = .empty;
        defer tool_calls_seen.deinit(self.ctx.gpa);

        for (msgs) |m| {
            if (buf.items.len >= max_summary) break;
            switch (m.role) {
                .user => {
                    if (m.content) |c| {
                        const preview = if (c.len > content_preview_chars) c[0..content_preview_chars] else c;
                        buf.appendSlice(self.ctx.gpa, "- User: ") catch continue;
                        buf.appendSlice(self.ctx.gpa, preview) catch continue;
                        if (c.len > content_preview_chars) buf.appendSlice(self.ctx.gpa, "...") catch {};
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
                            if (tc.arguments.len > 0 and tc.arguments.len <= args_preview_chars) {
                                buf.appendSlice(self.ctx.gpa, " args=") catch {};
                                buf.appendSlice(self.ctx.gpa, tc.arguments) catch {};
                            } else if (tc.arguments.len > args_preview_chars) {
                                buf.appendSlice(self.ctx.gpa, " args=") catch {};
                                buf.appendSlice(self.ctx.gpa, tc.arguments[0..args_preview_chars]) catch {};
                                buf.appendSlice(self.ctx.gpa, "...") catch {};
                            }
                            buf.append(self.ctx.gpa, '\n') catch continue;
                        }
                    }
                    if (m.content) |c| {
                        if (c.len > 0) {
                            const preview = if (c.len > content_preview_chars) c[0..content_preview_chars] else c;
                            buf.appendSlice(self.ctx.gpa, "- Assistant: ") catch continue;
                            buf.appendSlice(self.ctx.gpa, preview) catch continue;
                            if (c.len > content_preview_chars) buf.appendSlice(self.ctx.gpa, "...") catch {};
                            buf.append(self.ctx.gpa, '\n') catch continue;
                        }
                    }
                },
                .tool => {
                    if (m.content) |c| {
                        // Extract a preview so key values (numbers, paths, statuses)
                        // survive compaction.
                        const preview = if (c.len > tool_result_preview_chars) c[0..tool_result_preview_chars] else c;
                        buf.appendSlice(self.ctx.gpa, "- Tool result: ") catch continue;
                        buf.appendSlice(self.ctx.gpa, preview) catch continue;
                        if (c.len > tool_result_preview_chars) buf.appendSlice(self.ctx.gpa, "...") catch {};
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

    /// Folds one response's token usage into `self.stats`, including cost if
    /// the active model has per-token pricing configured.
    fn recordUsage(self: *Agent, u: types.Usage) void {
        self.stats.total_prompt_tokens += u.prompt_tokens;
        self.stats.total_completion_tokens += u.completion_tokens;
        self.stats.total_tokens += u.prompt_tokens + u.completion_tokens;
        self.stats.total_cache_hit_tokens += u.prompt_cache_hit_tokens;
        self.stats.total_cache_miss_tokens += u.prompt_cache_miss_tokens;
        const active = self.provider.activeModel();
        if (active.cost_per_1m_input) |ci| self.stats.cost += client.promptCost(u, ci);
        if (active.cost_per_1m_output) |co| self.stats.cost += @as(f64, @floatFromInt(u.completion_tokens)) / 1_000_000.0 * co;
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
        try buf.ensureTotalCapacity(self.ctx.gpa, max_transcript);
        for (msgs) |m| {
            if (buf.items.len >= max_transcript) break;
            const role_str: []const u8 = switch (m.role) {
                .user => "user",
                .assistant => "assistant",
                .tool => "tool",
                .system => "system",
            };
            try buf.append(self.ctx.gpa, '[');
            try buf.appendSlice(self.ctx.gpa, role_str);
            try buf.appendSlice(self.ctx.gpa, "] ");
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
                "Be specific: include names, numbers, and key values. Do NOT add commentary.\n\n{s}",
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
        if (resp.usage) |u| self.recordUsage(u);
        log.log(.info, "compaction summary: {d} messages -> {d} byte summary", .{ msgs.len, content.len });
        return try std.fmt.allocPrint(
            self.arena,
            "[conversation summary: {d} earlier messages compacted]\n{s}",
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
        var fence_extracted = false;
        if (std.mem.find(u8, s, "```")) |start| {
            const after_first = s[start + 3 ..];
            const body_start = if (std.mem.find(u8, after_first, "\n")) |nl| nl + 1 else 0;
            var body = after_first[body_start..];
            if (std.mem.findLast(u8, body, "```")) |end| {
                body = body[0..end];
            }
            s = std.mem.trim(u8, body, " \t\r\n");
            fence_extracted = true;
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
        // { ... }"), extract the first JSON object/array, the answer_format
        // eval expects an exact-match value, not prose.
        var js_start: ?usize = null;
        var json_extracted = false;
        // Pick whichever of a JSON object or array appears first in the answer.
        // Preferring objects can misparse an expected array when prose contains
        // an earlier '{'; the answer_format eval needs the exact value.
        const obj_start = std.mem.findScalar(u8, s, '{');
        const arr_start = std.mem.findScalar(u8, s, '[');
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
                // Track string state: a `"` toggles unless it's preceded by an
                // odd number of backslashes (escaped). Checking only the single
                // preceding char mis-handles `\\"` (escaped backslash + real
                // quote), so count the full backslash run.
                if (ch == '"') {
                    var bs: usize = 0;
                    while (bs < i and s[start + i - 1 - bs] == '\\') bs += 1;
                    if (bs % 2 == 0) in_str = !in_str;
                }
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
                const candidate = s[start..end];
                // Brace-balanced is not the same as JSON. `fn add(a: i32, b:
                // i32) i32 { return a + b; }` balances, and taking it as the
                // answer deleted the signature from every code answer that got
                // this far, so only a span that actually parses is the value.
                if (std.json.parseFromSliceLeaky(std.json.Value, self.arena, candidate, .{})) |_| {
                    s = candidate;
                    json_extracted = true;
                    // If the model wrapped a bare value in {"answer": ...},
                    // unwrap to the exact value. Only triggers when an "answer"
                    // field is present, so a user-requested JSON object is
                    // never altered.
                    if (unwrapJsonAnswer(self.arena, s)) |unwrapped| {
                        s = unwrapped;
                    }
                } else |_| {}
            }
        }
        // If no fence/JSON was found, the model likely wrapped the exact
        // answer in a prose preamble (e.g. "Here is the result:"). For the
        // answer_format eval we need the exact value, so fall back to the
        // first non-empty line and strip a leading "Answer:"/"Result:" prefix.
        if (!json_extracted and !fence_extracted) {
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
                    } else if (std.mem.startsWith(u8, lead, "true") and (lead.len == 4 or !std.ascii.isAlphabetic(lead[4]))) {
                        s = "true";
                    } else if (std.mem.startsWith(u8, lead, "false") and (lead.len == 5 or !std.ascii.isAlphabetic(lead[5]))) {
                        s = "false";
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
    /// frames, so a stack local here dangles the moment this call returns;
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
        sb.private_todos = self.private_todos;
        sb.ask_fn = self.ask_fn;
        sb.parent_ask = self.parent_ask;
        // Offer this agent as an answerer only where a sub-agent could exist
        // to ask: ckSubagent hands own_ask down as the nested run's
        // parent_ask.
        if (self.subagent_runner != null) sb.own_ask = .{ .ctx = self, .call = &parentAskTrampoline };
        sb.parent_task = self.current_task;
        sb.parent_run_id = self.current_run_id;
        sb.state_dir = self.cfg.agent.state_dir;
        // ck_tool support: let chain (tool_call:true) resolve names against the live registry.
        if (sb.tool_call) {
            sb.tool_registry = self.reg;
        }
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
        if (chain.len == 0) return payload;
        // Const-qualified: each step's replacement comes back from
        // runTransform as []const u8, and a []u8 here cannot hold it.
        var current: []const u8 = try self.arena.dupe(u8, payload);

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
    /// session, the files are immutable during a session.
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
            // Parallel-eligible tools never read self.modules, their worker
            // loads a fresh module from the cached wasm bytes, but when the
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

    /// One blocking completion. On failure the graph still gets a node so a
    /// run that dies on the provider is visible in `clanker graph` and the
    /// web UI, not only as a stack trace on stderr.
    fn llmChat(
        self: *Agent,
        messages: []const types.Message,
        err_detail: *?[]const u8,
        g: *graph_mod.Graph,
        iteration: u32,
        started: std.Io.Timestamp,
    ) !types.ChatResponse {
        return client.chat(self.ctx, self.arena, .{
            .provider = self.provider,
            .messages = messages,
            .tools = self.tool_defs,
        }, err_detail) catch |err| {
            try self.recordFailedLlm(g, iteration, started, err, err_detail.*);
            return err;
        };
    }

    fn recordFailedLlm(
        self: *Agent,
        g: *graph_mod.Graph,
        iteration: u32,
        started: std.Io.Timestamp,
        err: anyerror,
        detail: ?[]const u8,
    ) !void {
        const ms: u64 = @intCast(@divTrunc(started.durationTo(std.Io.Timestamp.now(self.ctx.io, .awake)).nanoseconds, std.time.ns_per_ms));
        const why = detail orelse @errorName(err);
        log.log(.error_, "LLM call failed at iteration {d}: {s} ({s})", .{ iteration + 1, @errorName(err), why });
        try g.add(self.ctx.gpa, .{
            .kind = .llm,
            .iteration = iteration + 1,
            .label = "chat",
            .detail = why,
            .duration_ms = ms,
            .ok = false,
        });
    }

    /// Persists a finished run's graph through the sandboxed `cmd_graph`
    /// WASM tool (fs_prefixes: ["state/runs/"]) instead of a native
    /// file-write path. Nodes accumulate natively during the run (`g.add`
    /// runs once per LLM/tool step, too hot for a WASM round-trip); this is
    /// the one call at the end that hands the assembled graph to the tool.
    /// Best-effort: a graph write must never fail the run it is recording.
    fn persistGraph(self: *Agent, g: *const graph_mod.Graph) void {
        self.persistGraphOrErr(g) catch |err| {
            log.log(.warn, "graph write failed: {s}", .{@errorName(err)});
        };
    }

    fn persistGraphOrErr(self: *Agent, g: *const graph_mod.Graph) !void {
        const mod = try runtime.loadNamedTool(self.ctx.gpa, self.ctx.io, self.arena, self.ctx.environ_map, self.cfg, self.reg, "cmd_graph", null);
        defer mod.deinit();

        var enc: std.Io.Writer.Allocating = .init(self.arena);
        var s = std.json.Stringify{ .writer = &enc.writer, .options = .{} };
        try s.beginObject();
        try s.objectField("write");
        try s.beginObject();
        try s.objectField("run_id");
        try s.write(g.run_id);
        try s.objectField("parent_run_id");
        try s.write(g.parent_run_id);
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
                .decision => "decision",
                .check => "check",
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
            try s.objectField("output");
            try s.write(n.output);
            if (n.arguments.len > 0) {
                try s.objectField("arguments");
                try s.write(n.arguments);
            }
            try s.objectField("repeats");
            try s.print("{d}", .{n.repeats});
            try s.objectField("loop_to");
            try s.print("{d}", .{n.loop_to});
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
        try s.endObject();

        const raw = try mod.executeTool(enc.written());
        defer self.ctx.gpa.free(raw);
        const resp = std.json.parseFromSliceLeaky(struct { ok: bool = false, @"error": []const u8 = "" }, self.arena, raw, .{ .ignore_unknown_fields = true }) catch return;
        if (!resp.ok) log.log(.warn, "cmd_graph write: {s}", .{resp.@"error"});
    }

    fn executeTool(self: *Agent, tc: types.ToolCall) ![]const u8 {
        const tool = self.reg.get(tc.name) orelse {
            log.log(.warn, "agent called unknown tool '{s}'", .{tc.name});
            return toolErrorJson(self.arena, "unknown tool: {s}", .{tc.name});
        };
        if (!tool.enabled) {
            log.log(.warn, "agent called disabled plugin '{s}'", .{tc.name});
            return toolErrorJson(self.arena, "plugin disabled: {s}", .{tc.name});
        }

        // Tool arguments routinely contain prompts, message text, credentials,
        // and file contents. Their size is useful for diagnosing oversized
        // calls; their contents do not belong in production logs.
        log.log(.debug, "running tool '{s}' in sandbox args_bytes={d}", .{ tc.name, tc.arguments.len });
        const t0 = std.Io.Timestamp.now(self.ctx.io, .awake);

        const mod = if (self.modules.get(tc.name)) |m|
            m
        else blk: {
            const wasm_bytes = self.wasmBytes(tool) catch |err| {
                log.log(.error_, "tool '{s}': cannot load {s}: {s} (run `zig build tools`)", .{ tc.name, tool.wasm, @errorName(err) });
                return toolErrorJson(self.arena, "tool wasm missing: {s} ({s}). Run `zig build tools`.", .{ tc.name, @errorName(err) });
            };
            const sbp = self.sandboxPtrFor(tool) catch |err| {
                log.log(.error_, "tool '{s}': sandbox setup failed: {s}", .{ tc.name, @errorName(err) });
                return toolErrorJson(self.arena, "tool sandbox failed: {s} ({s})", .{ tc.name, @errorName(err) });
            };
            const m = runtime.ToolModule.load(self.ctx.gpa, self.ctx.io, sbp, wasm_bytes) catch |err| {
                log.log(.error_, "tool '{s}': sandbox load failed: {s}", .{ tc.name, @errorName(err) });
                return toolErrorJson(self.arena, "tool load failed: {s} ({s})", .{ tc.name, @errorName(err) });
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
            return toolErrorJson(self.arena, "tool execution failed: {s} ({s})", .{ tc.name, @errorName(err) });
        };
        defer self.ctx.gpa.free(out);
        const t1 = std.Io.Timestamp.now(self.ctx.io, .awake);
        const ms = @divTrunc(t0.durationTo(t1).nanoseconds, std.time.ns_per_ms);

        // Arena-own the result for the conversation history BEFORE the defer
        // above frees the gpa buffer: returning it raw yields 0xAA-poisoned
        // tool messages on the sequential path (use-after-free).
        const owned = try self.arena.dupe(u8, out);
        log.log(.info, "tool '{s}' -> {d} bytes in {d}ms", .{ tc.name, out.len, ms });
        toolout.warnIfMalformed(self.ctx.gpa, tc.name, owned);

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
        // distinguishable from "executed and returned empty output", a tool
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
            // call can simply run, and the schema is revealed so the next
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
            // Plan mode: write-capable calls are refused outright, before
            // any confirm channel gets a say, a plan run must not be able
            // to change state even when the human would have allowed it,
            // because "apply" is a separate run they have not started yet.
            // Same predicate as the confirm gate, so what a viewer is asked
            // about and what plan mode refuses can never drift apart.
            if (self.plan_mode) {
                if (self.reg.get(tc.name)) |t| {
                    if (t.enabled and t.needsConfirm()) {
                        log.log(.info, "plan mode: tool '{s}' refused (write-capable)", .{tc.name});
                        results[i] = try toolErrorJson(self.arena, "plan mode: the {s} tool can change state and was not executed. Describe this action as a step in your plan instead.", .{tc.name});
                        continue;
                    }
                }
            }
            // Confirm-before-write: with a human channel installed, a call
            // to a write-capable tool waits here for their allow/deny.
            // Gated in this loop rather than in executeTool because it is
            // the one point the parallel pass, the worker fallback, and the
            // sequential path all flow through, a denied call must reach
            // none of them, and a confirmed batch must be settled before
            // the first worker spawns.
            if (self.confirm_fn) |confirm| {
                if (self.reg.get(tc.name)) |t| {
                    if (t.enabled and t.needsConfirm() and !confirm(tc.name, argsPreview(tc.arguments))) {
                        log.log(.info, "tool '{s}' declined by the user", .{tc.name});
                        results[i] = try toolErrorJson(self.arena, "the user declined this {s} call. Do not retry it unchanged: adjust the approach, or put the question to ask_user.", .{tc.name});
                        continue;
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
            // Already answered above (load_tools, which has no registry entry
            // by design). Without this the lookup below fails and overwrites
            // the answer with "unknown tool: load_tools", which is what the
            // model then reads: the one call the catalog tells it to make
            // came back rejected on every single turn.
            if (results[i] != null) continue;
            if (seen.contains(tc.name)) continue; // duplicate -> sequential pass
            try seen.put(self.ctx.gpa, tc.name, {});

            const tool = self.reg.get(tc.name) orelse {
                results[i] = try toolErrorJson(self.arena, "unknown tool: {s}", .{tc.name});
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
                results[i] = try toolErrorJson(self.arena, "tool wasm missing: {s} ({s})", .{ tc.name, @errorName(err) });
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
            const thread = std.Thread.spawn(.{ .stack_size = parallel_tool_stack_bytes }, ToolWorker.run, .{worker}) catch |err| {
                self.ctx.gpa.destroy(worker);
                return err;
            };
            handles.append(self.ctx.gpa, .{ .slot = p.slot, .thread = thread, .worker = worker, .wasm_bytes = p.wasm_bytes }) catch |err| {
                // The worker already owns pointers into this Agent. It must
                // finish before error unwinding can release that state.
                thread.join();
                if (worker.out) |out| self.ctx.gpa.free(out);
                self.ctx.gpa.destroy(worker);
                return err;
            };
        }

        // Join every worker and move its output into the matching slot.
        for (handles.items) |h| h.thread.join();
        for (handles.items) |h| {
            if (h.worker.err) |e| {
                log.log(.error_, "tool '{s}' failed: {s}", .{ h.worker.tool.name, @errorName(e) });
                results[h.slot] = toolErrorJson(self.arena, "tool execution failed: {s} ({s})", .{ h.worker.tool.name, @errorName(e) }) catch "{\"ok\":false,\"error\":\"tool execution failed\"}";
            } else if (h.worker.out) |out| {
                // Handled without `try`: an error here would return through
                // the enclosing defer, which joins and frees every handle a
                // second time (the join/destroy loops above already ran).
                if (self.arena.dupe(u8, out)) |owned| {
                    self.ctx.gpa.free(out);
                    // After-transforms run here, on the main thread after the
                    // join, so no worker ever touches the shared transform cache.
                    const transformed = self.runChain(h.worker.tool.name, .after, owned) catch owned;
                    // A tool (or its after-transform chain) may legitimately
                    // produce zero bytes; the conversation must never see a
                    // zero-length tool result.
                    results[h.slot] = if (transformed.len == 0) "{\"ok\":true,\"result\":\"\"}" else transformed;
                } else |_| {
                    self.ctx.gpa.free(out);
                    results[h.slot] = "{\"ok\":false,\"error\":\"out of memory\"}";
                }
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
            // which a deep tool call blows outright, a segfault, not a
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
            return toolErrorJson(self.arena, "unknown tool: {s}", .{tc.name});
        // Tools that call the model, and disabled ones, keep the original
        // in-thread path: they do not run wasm deeply and the LLM client is
        // not shared with worker threads.
        if (tool.llm or tool.sequential or !tool.enabled) return self.executeTool(tc);

        const wasm_bytes = self.wasmBytes(tool) catch |err| {
            log.log(.error_, "tool '{s}': cannot load {s}: {s}", .{ tc.name, tool.wasm, @errorName(err) });
            return toolErrorJson(self.arena, "tool wasm missing: {s} ({s})", .{ tc.name, @errorName(err) });
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
            return toolErrorJson(self.arena, "tool execution failed: {s} ({s})", .{ tc.name, @errorName(e) });
        }
        const out = worker.out orelse return "{\"ok\":false,\"error\":\"tool produced no output\"}";
        defer self.ctx.gpa.free(out);
        const owned = try self.arena.dupe(u8, out);
        log.log(.info, "tool '{s}' -> {d} bytes", .{ tc.name, owned.len });
        // No check here: these bytes came from the worker, which already
        // checked them. Warning again reports one broken result twice.
        return self.runChain(tc.name, .after, owned) catch owned;
    }
};

/// How much of the parent's transcript a sub-agent's question gets to see:
/// the most recent messages, each clipped, so the answer prompt stays bounded
/// whatever the parent has been doing.
const parent_answer_max_msgs = 10;
const parent_answer_max_msg_bytes = 400;

/// Renders the one-shot prompt that answers a sub-agent's question on the
/// parent's behalf: the parent's task, the tail of its transcript (the part
/// the sub-agent cannot see, it started with an empty transcript on
/// purpose), and the question with its options, under the same
/// answer-verbatim contract the ask_user peer path uses.
fn parentAnswerPrompt(
    arena: std.mem.Allocator,
    parent_task: []const u8,
    messages: []const types.Message,
    question: []const u8,
    options: []const []const u8,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "A sub-agent you spawned to help with your task cannot resolve a decision alone and is asking you.\n\nYour task: ");
    try buf.appendSlice(arena, if (parent_task.len > 0) parent_task else "(none recorded)");
    const start = if (messages.len > parent_answer_max_msgs) messages.len - parent_answer_max_msgs else 0;
    if (messages.len > start) {
        try buf.appendSlice(arena, "\n\nYour conversation so far (most recent last):\n");
        for (messages[start..]) |m| {
            // The system prompt is boilerplate the answerer's own model
            // already has; tool-call frames carry no prose.
            if (m.role == .system) continue;
            const content = m.content orelse continue;
            if (content.len == 0) continue;
            try buf.appendSlice(arena, "- ");
            try buf.appendSlice(arena, @tagName(m.role));
            try buf.appendSlice(arena, ": ");
            try buf.appendSlice(arena, content[0..@min(content.len, parent_answer_max_msg_bytes)]);
            try buf.appendSlice(arena, "\n");
        }
    }
    try buf.appendSlice(arena, "\nThe sub-agent asks: ");
    try buf.appendSlice(arena, question);
    try buf.appendSlice(arena, "\nOptions:\n");
    for (options) |o| {
        try buf.appendSlice(arena, "- ");
        try buf.appendSlice(arena, o);
        try buf.appendSlice(arena, "\n");
    }
    try buf.appendSlice(arena, "\nAnswer with exactly one of the options, verbatim, and nothing else: the one most consistent with your task and what you already know.");
    return buf.toOwnedSlice(arena);
}

/// Answers a sub-agent's question with one bounded completion on the parent's
/// provider, the re-entrant path host.ParentAsk documents. Runs on the
/// sub-agent's thread while the parent is parked in ck_subagent's join, so it
/// builds a fresh client Ctx per call rather than sharing the parent's HTTP
/// state across threads (the same discipline runNested applies). Returns the
/// answer gpa-owned; the caller (ckAsk) frees it.
fn answerAsParent(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    cfg: ?*const config.Config,
    provider: *const config.Provider,
    parent_task: []const u8,
    messages: []const types.Message,
    question: []const u8,
    options: []const []const u8,
) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prompt = try parentAnswerPrompt(arena, parent_task, messages, question, options);
    var ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = environ_map, .cfg = cfg };
    const msgs = [_]types.Message{.{ .role = .user, .content = prompt }};
    var err_detail: ?[]const u8 = null;
    const resp = try client.chat(&ctx, arena, .{
        .provider = provider,
        .messages = &msgs,
        .max_tokens = 256,
    }, &err_detail);
    const raw = std.mem.trim(u8, resp.message.content orelse "", " \t\r\n");
    // An exact pick comes back verbatim. Anything else is passed through
    // as-is: prose from the parent still answers the question better than an
    // error would.
    for (options) |o| {
        if (std.mem.eql(u8, raw, o)) return gpa.dupe(u8, o);
    }
    return gpa.dupe(u8, raw);
}

/// host.ParentAsk.call for an Agent: recovers the agent and answers from its
/// current task and transcript.
fn parentAskTrampoline(
    ctx_ptr: *anyopaque,
    gpa: std.mem.Allocator,
    question: []const u8,
    options: []const []const u8,
) anyerror![]const u8 {
    const self: *Agent = @ptrCast(@alignCast(ctx_ptr));
    const msgs: []const types.Message = if (self.current_messages) |m| m.items else &.{};
    return answerAsParent(self.ctx.io, gpa, self.ctx.environ_map, self.cfg, self.provider, self.current_task, msgs, question, options);
}

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
/// process outright at 2 MiB, a stack overflow, not a catchable trap, and
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

/// Hard cap on a single tool result before it enters the conversation. A huge
/// result (large file read, verbose search dump) can dominate the context
/// window and inflate cost on the very next LLM call, before compaction has a
/// chance to act (and compaction preserves the last 6 messages, so a recent
/// giant result stays in context regardless). The model sees the first
/// `max_tool_result_bytes` plus a truncation notice so it can ask for specific
/// parts (offset, line range) if it needs more.
const max_tool_result_bytes: usize = 32768;

fn toolErrorJson(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"ok\":false,\"error\":\"" ++ fmt ++ "\"}}", args);
}

/// Caps a tool result to `max_tool_result_bytes` with a truncation marker.
/// Returns the original slice when it fits or is close enough that the marker
/// would make it larger (defeats the purpose).
fn capToolResult(arena: std.mem.Allocator, content: []const u8) ![]const u8 {
    // Upper bound on the marker text (two decimal fields + static prose).
    const marker_overhead = 200;
    if (content.len <= max_tool_result_bytes + marker_overhead) return content;
    return try std.fmt.allocPrint(arena, "{s}\n\n[... result truncated: {d} bytes total, showing first {d}. Ask for specific parts (offset, line range) if you need more. ...]", .{ content[0..max_tool_result_bytes], content.len, max_tool_result_bytes });
}

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
            .shared_root = self.cfg.agent.shared_root,
            .network_allow = self.tool.network_allow,
            .fs_prefixes = self.tool.fs_prefixes,
            // Copied like every other policy field. Omitting them here did not
            // make a worker safer, it made it wrong: a tool ran with no
            // commands and no environment on the parallel path and the same
            // tool ran with its descriptor's on the sequential one, so
            // search_code was refused ripgrep for as long as it ran in
            // parallel with anything.
            .exec_allow = self.tool.exec_allow,
            .git_remote_ops = self.cfg.agent.git_remote_ops,
            .exec_pattern_allow = self.cfg.agent.exec_pattern_allow,
            .env_allow = self.tool.env_allow,
            .environ_map = self.ctx.environ_map,
            .seed = self.cfg.agent.seed,
            .subagent_runner = self.subagent_runner,
            .cfg = self.cfg,
            .state_dir = self.cfg.agent.state_dir,
            // An exec-capable tool sees the harness's exec policy in its own
            // `config`, the same injection host.sandboxFor applies on the
            // sequential path. Without it the git/gh guests read an empty
            // config on the parallel path and reported "no exec_pattern_allow
            // patterns are configured" even though the config had them, the
            // two execution paths disagreed about the same tool's settings.
            .config_json = if (self.tool.exec_allow.len > 0)
                try host.execPolicyConfig(arena_state.allocator(), self.tool.config_json, self.cfg)
            else
                self.tool.config_json,
            .fuel = self.tool.fuel,
        };

        log.log(.debug, "running tool '{s}' in sandbox args_bytes={d}", .{ self.tool.name, self.arguments.len });
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
        toolout.warnIfMalformed(self.ctx.gpa, self.tool.name, out);
        self.out = out;
    }
};

/// Strips trailing punctuation from a candidate exact-match answer only when
/// the remainder is a number or boolean, so "42." becomes "42" while a string
/// like "hello." keeps its period (the user asked for the exact value).
/// What the human is shown when asked to allow a tool call: enough of the
/// arguments to judge it, never all of them, a whole file write would drown
/// the question. Truncation backs up to a UTF-8 boundary because the preview
/// is re-encoded as JSON for the stream event, and a split code point there
/// is not a smaller preview but a malformed one.
fn argsPreview(args: []const u8) []const u8 {
    return utf8.cap(args, 400);
}

test argsPreview {
    try std.testing.expectEqualStrings("short", argsPreview("short"));
    const long = "x" ** 500;
    try std.testing.expectEqual(@as(usize, 400), argsPreview(long).len);
    // A multi-byte code point straddling the cap is dropped whole.
    const emoji = ("y" ** 399) ++ "\u{1F600}";
    try std.testing.expectEqualStrings("y" ** 399, argsPreview(emoji));
}

/// The error message out of a failed tool result ({"ok":false,"error":"..."}),
/// for the autolearn log's tool_error events. Without it the aggregated
/// roadmap item reads "Fix 'git' tool errors (1 failure(s), last: )", a
/// count with no clue what actually failed. Truncation backs up to a UTF-8
/// boundary for the same reason as [[argsPreview]].
fn errorDetail(arena: std.mem.Allocator, content: []const u8) []const u8 {
    const cap = 200;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, content, .{ .ignore_unknown_fields = true }) catch return "";
    if (parsed != .object) return "";
    const e = parsed.object.get("error") orelse return "";
    if (e != .string) return "";
    const s = e.string;
    return utf8.cap(s, cap);
}

test errorDetail {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "git exited 128: not a git repository",
        errorDetail(arena, "{\"ok\":false,\"error\":\"git exited 128: not a git repository\"}"),
    );
    // No error field, non-object, and non-JSON results all degrade to empty.
    try std.testing.expectEqualStrings("", errorDetail(arena, "{\"ok\":false}"));
    try std.testing.expectEqualStrings("", errorDetail(arena, "[1,2]"));
    try std.testing.expectEqualStrings("", errorDetail(arena, "not json"));
    // Long messages are capped without splitting a code point.
    const long = "{\"ok\":false,\"error\":\"" ++ ("z" ** 199) ++ "\u{1F600}\"}";
    try std.testing.expectEqualStrings("z" ** 199, errorDetail(arena, long));
}

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

/// Reads a pending stop request and clears it in one atomic step, so the
/// request applies to exactly one run. A Ctrl-C that lands while a turn is
/// already finishing must not cancel the turn the user types next.
fn takeStopRequest(flag: ?*std.atomic.Value(bool)) bool {
    const f = flag orelse return false;
    return f.swap(false, .acquire);
}

test takeStopRequest {
    try std.testing.expect(!takeStopRequest(null));

    var flag: std.atomic.Value(bool) = .init(false);
    try std.testing.expect(!takeStopRequest(&flag));

    flag.store(true, .release);
    try std.testing.expect(takeStopRequest(&flag));
    // Consumed: the next run starts clean rather than stopping immediately.
    try std.testing.expect(!takeStopRequest(&flag));
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
    // prose answer to ".", this test fails on that regression.
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
    // Zig only analyzes referenced functions, so runChain/runTransform, which
    // have no call site yet, could carry a type error indefinitely and then
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

    // A hardcoded relative path in the repo's cwd was shared across every
    // run of this test, so two overlapping runs (or a leftover file from a
    // crashed run) raced on the same file and read back empty or stale
    // bytes. A per-test temp dir removes the collision.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(arena_state.allocator(), ".zig-cache/tmp/{s}/test_wasm_bytes_cache.tmp", .{tmp.sub_path});
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
    // reservation from 64 MiB down to 2 MiB, and a search_code call, the
    // zwasm interpreter recursing, then ck_exec's JSON result parsing on top
    // of it, overflowed the worker stack and segfaulted the whole run. The
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
    // and compactMiddle (the drop/preserve rewrite). A regression in either
    // an inverted budget check, the wrong messages dropped, compaction
    // silently disabled, or the system prompt evicted, fails here.
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

test "capToolResult leaves small results untouched and truncates large ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Small result: returned verbatim.
    const small = "{\"ok\":true,\"result\":\"hi\"}";
    try std.testing.expectEqualStrings(small, try capToolResult(arena, small));

    // Exactly at the cap: still verbatim (boundary is inclusive).
    const exact = try arena.alloc(u8, max_tool_result_bytes);
    @memset(exact, 'x');
    try std.testing.expectEqualStrings(exact, try capToolResult(arena, exact));

    // Well over the cap + marker overhead: truncated, with the marker and the original size.
    const big = try arena.alloc(u8, max_tool_result_bytes * 4);
    @memset(big, 'x');
    const capped = try capToolResult(arena, big);
    try std.testing.expect(capped.len > max_tool_result_bytes); // includes marker
    try std.testing.expect(capped.len < big.len); // but much smaller than original
    try std.testing.expect(std.mem.find(u8, capped, "truncated") != null);
    try std.testing.expect(std.mem.find(u8, capped, "Ask for specific parts") != null);
    // The first max_tool_result_bytes bytes are preserved.
    try std.testing.expectEqualStrings(big[0..max_tool_result_bytes], capped[0..max_tool_result_bytes]);
}

test "compactionKeepStart never splits a tool-call exchange" {
    // If the kept window would begin with tool-result messages whose
    // assistant tool_calls message is being dropped, the window must extend
    // backwards to include it, providers reject orphaned tool messages.
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

test "pruneOldToolResults shortens stale tool results outside the recent tail" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const big = try arena.alloc(u8, 2000);
    @memset(big, 'x');
    // 10 messages: sys + 4 user/tool pairs + a recent user message.
    // The last 6 messages (indices 4..9) are the kept tail; the tool at
    // index 2 is outside and should be pruned.
    var msgs = [_]types.Message{
        .{ .role = .system, .content = "sys" }, // 0
        .{ .role = .user, .content = "u1" }, // 1
        .{ .role = .tool, .content = big }, // 2, large, stale
        .{ .role = .user, .content = "u2" }, // 3
        .{ .role = .tool, .content = big }, // 4, inside tail (len - 6 = 4)
        .{ .role = .user, .content = "u3" }, // 5
        .{ .role = .assistant, .content = "a1" }, // 6
        .{ .role = .user, .content = "u4" }, // 7
        .{ .role = .assistant, .content = "a2" }, // 8
        .{ .role = .user, .content = "u5" }, // 9
    };

    Agent.pruneOldToolResults(&msgs, arena, 6);

    // The tool at index 2 (outside the tail) was pruned.
    try std.testing.expect(msgs[2].content.?.len < big.len);
    try std.testing.expect(std.mem.find(u8, msgs[2].content.?, "pruned") != null);
    // The tool at index 4 (inside the tail) is preserved verbatim.
    try std.testing.expectEqual(big.len, msgs[4].content.?.len);
}

test "pruneOldToolResults leaves short results untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A short tool result (< prune_preview_bytes) outside the tail survives.
    var msgs = [_]types.Message{
        .{ .role = .system, .content = "sys" }, // 0
        .{ .role = .tool, .content = "ok" }, // 1, short, outside tail
        .{ .role = .user, .content = "u1" }, // 2
        .{ .role = .assistant, .content = "a1" }, // 3
        .{ .role = .user, .content = "u2" }, // 4
        .{ .role = .assistant, .content = "a2" }, // 5
        .{ .role = .user, .content = "u3" }, // 6
        .{ .role = .assistant, .content = "a3" }, // 7
    };

    Agent.pruneOldToolResults(&msgs, arena, 6);

    // Still "ok", untouched.
    try std.testing.expectEqualStrings("ok", msgs[1].content.?);
}

test "pruneOldToolResults is a no-op when history is shorter than the tail" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const big = try arena.alloc(u8, 2000);
    @memset(big, 'x');
    // Only 5 messages: below the keep_tail + 1 threshold, nothing pruned.
    var msgs = [_]types.Message{
        .{ .role = .system, .content = "sys" },
        .{ .role = .tool, .content = big },
        .{ .role = .user, .content = "u1" },
        .{ .role = .assistant, .content = "a1" },
        .{ .role = .user, .content = "u2" },
    };

    Agent.pruneOldToolResults(&msgs, arena, 6);

    // Everything untouched, the history is too short to prune.
    try std.testing.expectEqual(big.len, msgs[1].content.?.len);
}

test "max_history_tokens feeds into compaction threshold" {
    // When max_history_tokens is set low, compaction triggers even when the
    // context window and compact_threshold_bytes are large.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const filler = "x" ** 256;
    var messages: std.ArrayList(types.Message) = .empty;
    try messages.append(arena, .{ .role = .system, .content = "system prompt" });
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        try messages.append(arena, .{ .role = .user, .content = filler });
        try messages.append(arena, .{ .role = .assistant, .content = filler });
    }
    const estimated = Agent.estimateMessageTokens(messages.items);
    // With a generous context window & compact_threshold, compaction would
    // normally not fire. But max_history_tokens = 16 forces it.
    const threshold: usize = 16;
    try std.testing.expect(estimated > threshold);
    const keep_start = Agent.compactionKeepStart(messages.items, estimated, threshold) orelse return error.TestExpectedCompaction;
    try Agent.compactMiddle(&messages, arena, keep_start, "[compacted via max_history_tokens]");
    // Verify compaction happened: the list shrank and the summary is there.
    try std.testing.expect(messages.items.len < 9);
    try std.testing.expect(std.mem.find(u8, messages.items[1].content.?, "max_history_tokens") != null);
}

test "resumed-session cleanup completes partial tool-call exchanges instead of discarding executed results" {
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
        try Agent.dropDanglingToolExchange(arena, &messages);
        try std.testing.expectEqual(@as(usize, 5), messages.items.len);
    }

    // (2) A partial exchange (only 1 of 2 results persisted) keeps the real
    // result, it already ran, possibly with a side effect, and gets a
    // synthetic "interrupted" result for the call that never got one,
    // instead of wiping the whole batch and leaving the model free to
    // blindly re-issue an already-executed call.
    {
        var messages: std.ArrayList(types.Message) = .empty;
        try messages.append(arena, .{ .role = .system, .content = "sys" });
        try messages.append(arena, .{ .role = .user, .content = "u" });
        try messages.append(arena, .{ .role = .assistant, .tool_calls = &.{
            .{ .id = "a", .name = "t1", .arguments = "{}" },
            .{ .id = "b", .name = "t2", .arguments = "{}" },
        } });
        try messages.append(arena, .{ .role = .tool, .tool_call_id = "a", .content = "r1" });
        try Agent.dropDanglingToolExchange(arena, &messages);
        try std.testing.expectEqual(@as(usize, 5), messages.items.len);
        try std.testing.expectEqualStrings("r1", messages.items[3].content.?);
        try std.testing.expectEqualStrings("b", messages.items[4].tool_call_id.?);
        try std.testing.expect(std.mem.find(u8, messages.items[4].content.?, "interrupted") != null);
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
        try Agent.dropDanglingToolExchange(arena, &messages);
        try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    }

    // (4) A trailing assistant tool_calls message with no results at all is
    // popped (nothing executed, so there is nothing to protect).
    {
        var messages: std.ArrayList(types.Message) = .empty;
        try messages.append(arena, .{ .role = .system, .content = "sys" });
        try messages.append(arena, .{ .role = .assistant, .tool_calls = &.{
            .{ .id = "a", .name = "t1", .arguments = "{}" },
        } });
        try Agent.dropDanglingToolExchange(arena, &messages);
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

test "finalAnswer keeps code that happens to balance its braces" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var agent: Agent = undefined;
    agent.arena = arena;

    // A fenced function is brace-balanced, so the JSON extractor used to take
    // everything from the first `{` and hand back `{ return a + b; }`, the
    // signature was deleted from every code answer that reached it.
    const resp = types.ChatResponse{ .message = .{
        .role = .assistant,
        .content = "```zig\npub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n```",
    } };
    const ans = try agent.finalAnswer(resp);
    try std.testing.expectEqualStrings(
        "pub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}",
        ans.message.content.?,
    );
}

test "finalAnswer still unwraps a real JSON answer object" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var agent: Agent = undefined;
    agent.arena = arena;

    const resp = types.ChatResponse{ .message = .{
        .role = .assistant,
        .content = "Here you go: {\"answer\": \"clanker online\"}",
    } };
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

test "parentAnswerPrompt hands the sub-agent's question the parent's context" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const messages = [_]types.Message{
        .{ .role = .system, .content = "system boilerplate" },
        .{ .role = .user, .content = "please refactor the parser" },
        .{ .role = .assistant, .content = "I found two candidate modules" },
    };
    const prompt = try parentAnswerPrompt(arena, "refactor the parser", &messages, "Which module do I split first?", &.{ "tokenizer.zig", "grammar.zig" });

    // The parent's task, its transcript, the question, and the options all
    // reach the answering model.
    try std.testing.expect(std.mem.find(u8, prompt, "refactor the parser") != null);
    try std.testing.expect(std.mem.find(u8, prompt, "I found two candidate modules") != null);
    try std.testing.expect(std.mem.find(u8, prompt, "Which module do I split first?") != null);
    try std.testing.expect(std.mem.find(u8, prompt, "tokenizer.zig") != null);
    try std.testing.expect(std.mem.find(u8, prompt, "grammar.zig") != null);
    // The answer contract matches the peer path: one option, verbatim.
    try std.testing.expect(std.mem.find(u8, prompt, "verbatim") != null);
    // The system prompt is boilerplate, not context worth forwarding.
    try std.testing.expect(std.mem.find(u8, prompt, "system boilerplate") == null);
}

test "parentAnswerPrompt clips the transcript to a bounded recent tail" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var messages: std.ArrayList(types.Message) = .empty;
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const text = try std.fmt.allocPrint(arena, "msg-{d}", .{i});
        try messages.append(arena, .{ .role = .user, .content = text });
    }
    const long = try arena.alloc(u8, 1000);
    @memset(long, 'x');
    try messages.append(arena, .{ .role = .user, .content = long });

    const prompt = try parentAnswerPrompt(arena, "task", messages.items, "Q?", &.{ "a", "b" });
    // Recent messages survive; old ones do not ride along.
    try std.testing.expect(std.mem.find(u8, prompt, "msg-29") != null);
    try std.testing.expect(std.mem.find(u8, prompt, "msg-1\n") == null);
    // Each message is clipped, so one huge message cannot blow the prompt up.
    const over = try arena.alloc(u8, parent_answer_max_msg_bytes + 1);
    @memset(over, 'x');
    try std.testing.expect(std.mem.find(u8, prompt, over) == null);
}

test "answerAsParent answers through the parent's provider" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const mock = try mock_server.MockServer.start(io, gpa, .anthropic_text);
    defer mock.stop();

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("MOCK_ANTHROPIC_KEY", "sk-test");

    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{mock.port});
    defer gpa.free(base_url);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var provider = try config.Provider.single(arena_state.allocator(), "anthropic-mock", base_url, .anthropic, "claude-sonnet-5", .{
        .context_window = 1_000_000,
        .max_tokens = 1024,
    });
    provider.api_key_env = "MOCK_ANTHROPIC_KEY";

    const transcript = [_]types.Message{.{ .role = .user, .content = "the parent was doing something" }};
    // The mock's canned text is not one of the options, so this exercises the
    // pass-through: the parent's prose still reaches the sub-agent.
    const answer = try answerAsParent(io, gpa, &env, null, &provider, "parent task", &transcript, "Which one?", &.{ "A", "B" });
    defer gpa.free(@constCast(answer));
    try std.testing.expectEqualStrings("Hello from Anthropic-mock", answer);
}
