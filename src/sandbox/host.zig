//! Host functions exposed to WASM tool modules (`ck_*`), plus the sandbox
//! policy that constrains them: filesystem confined to a sandbox root,
//! network only to an explicit allowlist, and size caps on all I/O.
//!
//! ABI: each op returns a u32 error code (0 = ok); bulk data is written into
//! the module's host arena and read back via `ck_result()` -> u64 (ptr, len).
//! Runs on zwasm: host fns receive `*zwasm.Caller` and recover the sandbox
//! context via `caller.data(Host)`.

const std = @import("std");
const log = @import("../util/log.zig");
const redact = @import("../util/redact.zig");
const json_util = @import("../util/json.zig");
const protocol = @import("protocol.zig");
const client = @import("../llm/client.zig");
const types = @import("../llm/types.zig");
const session_mod = @import("../agent/session.zig");
const config_mod = @import("../config.zig");
const registry = @import("../toolhost/registry.zig");
const chatrooms_mod = @import("../peers/chatrooms.zig");
const private_todos_mod = @import("../agent/private_todos.zig");
const file_lock = @import("../util/file_lock.zig");
const atomic_write = @import("../util/atomic_write.zig");
const test_env = @import("../util/test_env.zig");
const utf8 = @import("../util/utf8.zig");
const secret_dotenv = @import("../util/secret_dotenv.zig");
const glob = @import("../util/glob.zig");
const fs_skip = @import("../util/fs_skip.zig");
const token_stats = @import("../stats/tokens.zig");
const build_options = @import("build_options");
const zwasm = @import("zwasm");
const python_wasi = @import("python_wasi.zig");
const subprocess = @import("../agent/subprocess.zig");
const jobs_mod = @import("jobs.zig");
const kernel_mod = @import("kernel.zig");
const dap = @import("../debug/dap.zig");
const ensure_dir = @import("../util/ensure_dir.zig");
const tail_util = @import("../util/tail.zig");
const live_mod = @import("../serve/live.zig");
const cas_lock_record = @import("cas_lock_record");

/// Model access for tools whose descriptor sets `"llm": true` (a translate or
/// summarize transform needs one). The harness hands over the same provider
/// the agent itself is running on; `ck_llm` is denied when this is null.
pub const LlmAccess = struct {
    ctx: *client.Ctx,
    provider: *const config_mod.Provider,
    max_tokens: u32 = 1024,
};

/// How much host-arena space a guest is assumed to have when it does not say.
/// Guests built from tools/zig/lib.zig export `host_arena_size`; the runtime
/// reads it and writes it to Host.arena_cap. Anything written past what the
/// guest actually reserved would corrupt its linear memory, so a module that
/// stays silent keeps the original, smallest guarantee.
pub const host_arena_cap = 64 * 1024;

/// Error codes returned by ck_* host functions.
/// Zig standard library directory, resolved by running `zig env`.
///
/// Read only by the `zig_std` tool and by the improve engine's std-symbol
/// help, so it is resolved on first use rather than at startup: the lookup
/// is a fork+exec of the Zig compiler, and paying it in `main` charged every
/// `clanker` invocation (`--help`, `mcp`, `acp`, every CLI verb) for a path
/// almost none of them read.
///
/// The answer lands in a static buffer, so there is no allocation to own and
/// nothing to free at exit. `zig_lib_dir_mutex` guards the one-shot: sandbox
/// host functions run on `clanker serve`'s worker threads, and the startup
/// call used to be what kept concurrent readers off a half-written slice.
var zig_lib_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
var zig_lib_dir_mutex: std.atomic.Mutex = .unlocked;
var zig_lib_dir_resolved: bool = false;
pub var zig_lib_dir: []const u8 = "";

pub fn zigLibDir(io: std.Io, environ_map: *std.process.Environ.Map) []const u8 {
    while (!zig_lib_dir_mutex.tryLock()) std.Thread.yield() catch {};
    defer zig_lib_dir_mutex.unlock();
    if (zig_lib_dir_resolved) return zig_lib_dir;
    zig_lib_dir_resolved = true;
    // `page_allocator`: the captured output is freed here and the answer is
    // copied into `zig_lib_dir_buf`, so no caller allocator has to outlive it.
    const gpa = std.heap.page_allocator;
    // `std.process.run` does not search PATH for a bare argv[0] (same
    // constraint `rg` hits below in `ckStdApi`), so resolve `zig` explicitly;
    // without it this always failed FileNotFound and `zig_std` could never
    // find a symbol, which is what the `std_api` capability eval caught.
    // A null `environ_map` in RunOptions gives the child no environment at
    // all, not the parent's: `zig env` needs HOME to resolve its cache dir
    // and fails with AppDataDirUnavailable on stderr, leaving stdout empty
    // (silently, since only stdout is read below) — so pass it through too.
    const zig_path = resolveExecPath(gpa, io, environ_map, "zig") orelse return zig_lib_dir;
    defer gpa.free(zig_path);
    const argv = [_][]const u8{ zig_path, "env" };
    const res = std.process.run(gpa, io, .{ .argv = &argv, .environ_map = environ_map }) catch return zig_lib_dir;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    // zig env prints Zig struct syntax: .lib_dir = "/path/to/lib"
    var it = std.mem.splitScalar(u8, res.stdout, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const idx = std.mem.find(u8, trimmed, ".lib_dir =") orelse continue;
        const rest = trimmed[idx + ".lib_dir =".len ..];
        const after = std.mem.trimStart(u8, rest, " \t\"");
        const end = std.mem.findScalar(u8, after, '"') orelse after.len;
        const dir = after[0..end];
        if (dir.len == 0 or dir.len > zig_lib_dir_buf.len) return zig_lib_dir;
        @memcpy(zig_lib_dir_buf[0..dir.len], dir);
        zig_lib_dir = zig_lib_dir_buf[0..dir.len];
        return zig_lib_dir;
    }
    return zig_lib_dir;
}

pub const Err = struct {
    pub const ok: u32 = 0;
    pub const denied: u32 = 1;
    pub const not_found: u32 = 2;
    pub const too_large: u32 = 3;
    pub const network: u32 = 4;
    pub const invalid: u32 = 5;
    pub const mismatch: u32 = 6;
    /// A specific denial: the *tool* was refused this host operation (e.g. a
    /// chat op the tool is not allowlisted for), as opposed to the *module*
    /// being off. Distinct from `denied` so a guest can tell "my access was
    /// denied" from "the feature is disabled", which lead to different fixes.
    pub const no_access: u32 = 7;
};

/// Asks the human a multiple-choice question and returns the option they
/// picked. Wired in only by the interactive REPL: a piped or scripted run has
/// nobody to ask, so the tool reports that instead of blocking forever.
pub const AskFn = *const fn (
    question: []const u8,
    options: []const []const u8,
) anyerror![]const u8;

/// Puts one write-capable tool call to the human before it runs
/// (agent.confirm_writes) and returns whether they allowed it. Installed by
/// the surfaces that have a human to ask, the streaming web run, the
/// interactive REPL, and left null everywhere else, which means "allow":
/// the improve loop and headless runs must never be gated on an answer
/// nobody is there to give. The preview is truncated by the caller; a
/// confirm that cannot reach its human (closed tab, timeout) answers deny,
/// because waving writes through an unattended gate is worse than making
/// the model take another path.
pub const ConfirmFn = *const fn (
    tool_name: []const u8,
    args_preview: []const u8,
) bool;

/// Answers a sub-agent's question on the parent's behalf (`ask_user` with
/// `{"parent": true}`). `ctx` is the parent agent; the answer is gpa-owned
/// and freed by the caller.
///
/// The concurrency decision this type encodes: the answer is a *re-entrant
/// path*, one bounded completion on the parent's provider over a snapshot of
/// the parent's transcript, not a queue that resolves at the parent's next
/// turn boundary. A queue cannot work here: ck_subagent joins the nested
/// thread, so the parent never reaches a turn boundary while its sub-agent
/// waits. The same join is what makes the re-entrant path safe: the subagent
/// tool is `sequential: true`, which pins it to the sequential tool path, so while
/// this callback runs the parent is parked with no other tool of its own in
/// flight, and its transcript cannot move under the reader.
pub const ParentAsk = struct {
    ctx: *anyopaque,
    call: *const fn (
        ctx: *anyopaque,
        gpa: std.mem.Allocator,
        question: []const u8,
        options: []const []const u8,
    ) anyerror![]const u8,
};

/// What the parent hands down to a sub-agent. A sub-agent starts with an
/// empty transcript on purpose - the point of delegating is to keep that work
/// out of the parent's context window, and copying the transcript back in
/// would double the tokens and pass along every wrong turn the parent already
/// took.
///
/// What it must not start without is the *brief*: the objective the work
/// serves, the facts the parent already established, and where to look. Left
/// to reconstruct those, a sub-agent re-reads what the parent just read and
/// answers a question nobody asked.
pub const Brief = struct {
    /// The parent's own task, so the sub-task is read in service of something.
    parent_task: []const u8 = "",
    /// Facts, constraints and decisions the parent already has in hand.
    context: []const []const u8 = &.{},
    /// Paths worth reading first. Passed by reference, not by value: the
    /// sub-agent reads them itself, which costs the parent nothing and keeps
    /// the bytes out of both prompts until they are needed.
    files: []const []const u8 = &.{},
};

/// Runs a nested sub-agent. The harness wires this in when modules.subagents
/// is enabled; tools call it via ck_subagent.
pub const SubagentRunner = *const fn (
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    cfg: *const config_mod.Config,
    task: []const u8,
    provider_name: ?[]const u8,
    brief: Brief,
    parent_ask: ?ParentAsk,
    parent_run_id: []const u8,
) anyerror![]const u8;

/// Decides whether a `ck_tool` nested call may run a named tool, when the
/// harness wires one in. Same ctx/call shape as [[ParentAsk]]; the loop
/// supplies its preset + plan-mode gates so a tool-calling tool cannot
/// re-enter a denied tool under the callee's own grants.
pub const ToolPolicy = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, tool_name: []const u8) bool,
};

/// Per-tool sandbox policy, owned by the harness.
pub const Sandbox = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Absolute path of the directory tool filesystem access is confined to.
    root_dir: []const u8,
    /// The checkout a run was started from, when `root_dir` is an isolated
    /// worktree under it (`clanker run --worktree`). Paths under
    /// `shared_prefixes` resolve here instead of under `root_dir`.
    ///
    /// The rule this implements: git-tracked source belongs to the run's own
    /// tree, because editing it in isolation is the whole point; everything git
    /// does NOT track is one checkout-wide thing every run shares, and an
    /// isolated run must reach it exactly as it would without isolation. Left
    /// as a snapshot instead, a run reads stale state and its writes go
    /// nowhere: the goal it was steered by, the session it should resume, the
    /// notes it just took are all invisible to the next run.
    ///
    /// Empty (the default, and every non-isolated run) means one root for
    /// everything, so nothing here changes unless a run asked to be isolated.
    shared_root: []const u8 = "",
    /// Named extra sandbox roots for a multi-root workspace (RFC 0001). A
    /// relative guest path whose first component matches a root name resolves
    /// the remainder under that root's directory; a bare path resolves under
    /// `root_dir` as before. Empty for every single-root run.
    extra_roots: []const config_mod.SandboxRoot = &.{},
    /// Hosts allowed for ck_http. Entries are exact hostnames or glob
    /// patterns (`*.example.com`, `sub?.example.com`); a bare `*` allows every
    /// host. See networkAllowed.
    network_allow: []const []const u8,
    /// Directory prefixes (relative to root_dir) the tool may read/write.
    /// Empty means filesystem access is denied entirely.
    fs_prefixes: []const []const u8 = &.{},
    /// Whether a component of an already-granted path may be a symlink
    /// (`agent.sandbox_follow_symlinks`, ADR 0017). Off by default: the
    /// no-follow walk in `safeJoinSecure` is what stops a link inside a
    /// granted prefix from reaching the rest of the filesystem. Deployments
    /// that deliberately place a granted prefix behind a link -- a checkout
    /// whose `state/` lives in external storage so it can be backed up --
    /// turn it on. It never widens which prefixes are granted.
    follow_symlinks: bool = false,
    max_http_bytes: usize = 1 << 20,
    max_fs_bytes: usize = 1 << 20,
    /// Instruction budget (wasm fuel) for one call of this tool, from the
    /// descriptor's `fuel` key. 0 means the runtime default; runtime.zig
    /// clamps positive values to that default as a ceiling, so a descriptor
    /// tightens its own budget but never raises it.
    fuel: u64 = 0,
    environ_map: *std.process.Environ.Map,
    /// Deterministic seed for the tool RNG (from agent.seed).
    seed: u64 = 0,
    /// Optional nested sub-agent runner (subagent tool).
    subagent_runner: ?SubagentRunner = null,
    /// Optional human prompt (ask_user tool); null outside the REPL.
    ask_fn: ?AskFn = null,
    /// A nested run's channel to the agent that spawned it (ask_user with
    /// {"parent": true}); wired only inside sub-agent runs.
    parent_ask: ?ParentAsk = null,
    /// This agent as an answerer for the sub-agents it spawns; ckSubagent
    /// hands it down to become the nested run's parent_ask.
    own_ask: ?ParentAsk = null,
    /// The task the parent agent is working on, handed to sub-agents so their
    /// piece is read in service of something rather than in a vacuum.
    parent_task: []const u8 = "",
    /// The graph run id of the agent driving this sandbox, handed to
    /// sub-agents so their own graphs record which run spawned them
    /// (webui-plan 3.1).
    parent_run_id: []const u8 = "",
    /// Effective config, for host functions that need it (subagent runner).
    cfg: ?*const config_mod.Config = null,
    /// Per-session token budget for ck_llm calls (0 = unlimited).
    session_token_budget: usize = 0,
    /// Tokens used so far by ck_llm calls in this session.
    used_session_tokens: u64 = 0,
    /// Non-null only for tools that declared the llm capability. A tool holding
    /// this runs sequentially: one provider call per tool call, never from the
    /// parallel worker pool.
    llm: ?LlmAccess = null,
    /// Whether the tool descriptor set session: true (the only gate on
    /// ck_session list/get/search of the session store).
    session: bool = false,
    /// The tool descriptor's `config` object, serialized. Returned verbatim by
    /// `ck_config` so a plugin can read its own settings.
    config_json: []const u8 = "{}",
    /// Commands allowed through ck_exec for this tool. Empty allows nothing:
    /// there is no fallback set, and `execAllowed` refuses every command for
    /// an empty list (pinned by "a tool may run only the commands its
    /// manifest names").
    exec_allow: []const []const u8 = &.{},
    /// Whether the `git` tool may run the PR-lifecycle verbs it otherwise
    /// cannot: `push`, `merge`, `checkout`. From cfg.agent.git_remote_ops; the
    /// git.zig guest mirrors it so its in-tool deny message does not pre-empt
    /// the widening. Scoped to the command being `git` in ck_exec, so no other
    /// tool inherits it. Default false = today's hardcoded denies.
    git_remote_ops: bool = false,
    /// Whole-command-line glob patterns a tool may run through ck_exec, from
    /// cfg.agent.exec_pattern_allow. When a pattern names a command, that
    /// command becomes strict: only an argv that matches one of its patterns
    /// runs, and the match also overrides the deny tokens for the args it
    /// grants ("gh pr merge" legitimately contains "merge"). Commands with no
    /// pattern stay under the deny-list check, so a pattern for `gh` does not
    /// widen `git` or anything else. `*` matches any run of characters,
    /// including across spaces and empty.
    exec_pattern_allow: []const []const u8 = &.{},
    /// Environment variables a guest may read, from the tool's manifest.
    env_allow: []const []const u8 = &.{},
    /// May emit onto the live bus via `ck_publish`. Default false; the
    /// import existing is not a grant. Events land on `Topic.plugin` only.
    live_publish: bool = false,
    /// May call another tool via `ck_tool`. Default false, only the chain
    /// tool sets this.
    tool_call: bool = false,
    tool_allow: ?[]const []const u8 = null,
    tool_self_name: []const u8 = "",
    tool_registry: ?*const registry.Registry = null,
    tool_call_depth: u8 = 0,
    /// Whether `ck_tool` may run a named tool. Null = no check (host tools,
    /// tests). The agent loop wires this to the same policy it applies to
    /// top-level calls (preset deny list, plan mode), so a tool-calling tool
    /// (chain, run_plan) cannot re-enter a denied tool with the callee's own
    /// grants. Deterministic gates only: the interactive confirm channel
    /// stays a top-level-batch concern, where the runner itself was approved.
    tool_policy: ?ToolPolicy = null,
    /// A nested run's private todo list (src/agent/private_todos.zig), wired
    /// only by subagent.runNested. When set, todo_* ops that name no "room"
    /// operate on it instead of a shared room list; null for top-level agents.
    private_todos: ?*private_todos_mod.List = null,
    /// Directory (relative to `state_base_dir`) holding the harness state:
    /// chatroom logs, subscriptions, cursor. Defaults to "state".
    state_dir: []const u8 = "state",
    /// Base directory for harness state; null = the process cwd. Tests point
    /// this at a temp dir so chatroom logs never touch the real checkout.
    state_base_dir: ?std.Io.Dir = null,
    /// Conversation id this sandbox belongs to. Empty means `"default"`.
    session_id: []const u8 = "",
    /// Shared kernel/DAP process table. Null uses the process-global registry.
    subprocs: ?*subprocess.Registry = null,
};

/// A plugin may aim ck_llm at its own backend with
/// `"config": {"provider": "kimi-k3", "model": "..."}`; anything it leaves out
/// falls back to the configured default.
fn pluginProvider(
    arena: std.mem.Allocator,
    cfg: *const config_mod.Config,
    tool: *const registry.Tool,
) !*const config_mod.Provider {
    const want_provider = json_util.pluginStr(tool.config, "provider");
    const want_model = json_util.pluginStr(tool.config, "model");
    const base = cfg.provider(want_provider) catch blk: {
        log.log(.warn, "plugin '{s}': unknown provider, using the default", .{tool.name});
        break :blk try cfg.provider(null);
    };
    if (want_model == null) return base;
    const copy = try arena.create(config_mod.Provider);
    copy.* = base.*;
    copy.default_model = want_model.?;
    return copy;
}

/// The single place a tool's sandbox policy is assembled from its descriptor.
/// Every caller (agent loop, parallel workers, CLI, MCP) goes through here:
/// hand-rolled Sandbox literals drift, and a missed field is a silently
/// missing capability or a silently missing restriction.
pub fn sandboxFor(
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    cfg: *const config_mod.Config,
    tool: *const registry.Tool,
    /// Supplied by callers that can spend tokens. Without it a tool declaring
    /// `"llm": true` still loads, but ck_llm is denied.
    llm_ctx: ?*client.Ctx,
) !Sandbox {
    var net = tool.network_allow;
    if (tool.network_from_config.len > 0) {
        const extra = try config_mod.configuredHosts(cfg, arena, tool.network_from_config);
        net = try appendNetworkAllow(arena, net, extra);
    }
    if (isResearchTool(tool.name)) {
        net = try appendNetworkAllow(arena, net, cfg.web.allow);
    }
    var llm_access: ?LlmAccess = null;
    if (tool.llm) {
        if (llm_ctx) |ctx| llm_access = .{
            .ctx = ctx,
            .provider = try pluginProvider(arena, cfg, tool),
            .max_tokens = json_util.pluginU32(tool.config, "max_tokens") orelse 1024,
        };
    }

    return .{
        .gpa = gpa,
        .io = io,
        .root_dir = cfg.agent.sandbox_root,
        .shared_root = cfg.agent.shared_root,
        .extra_roots = cfg.agent.sandbox_roots,
        .follow_symlinks = cfg.agent.sandbox_follow_symlinks,
        .network_allow = net,
        .llm = llm_access,
        .session = tool.session,
        .exec_allow = tool.exec_allow,
        .git_remote_ops = cfg.agent.git_remote_ops,
        .exec_pattern_allow = cfg.agent.exec_pattern_allow,
        .env_allow = tool.env_allow,
        .live_publish = tool.live_publish,
        .tool_call = tool.tool_call,
        .tool_allow = tool.tool_allow,
        .tool_self_name = tool.name,
        .tool_registry = null,
        .tool_call_depth = 0,
        .fs_prefixes = try fsPrefixesFor(arena, tool, cfg),
        .fuel = tool.fuel,
        .environ_map = environ_map,
        .seed = cfg.agent.seed,
        .cfg = cfg,
        // An exec-capable tool sees the harness's exec policy in its own
        // `config` so the git.zig / gh.zig guests can mirror the host's deny
        // decision instead of pre-empting it (e.g. a hardcoded in-tool "merge
        // is denied" would block what git_remote_ops just granted). Board
        // tools get the project's `#general` room the same way (RFC 0001).
        .config_json = try toolConfigFor(arena, tool, cfg),
    };
}

/// Descriptor `fs_prefixes` plus any extra `agent.tools_dir` entries the
/// plugins/tools guests need to list, and `agent.skills_dir` for the skills
/// guest. Extra entries stay relative to the sandbox root: a host-absolute
/// path is refused by `safeJoin` and so is only useful to `Registry.load` on
/// the host, not to a guest walk.
fn fsPrefixesFor(
    arena: std.mem.Allocator,
    tool: *const registry.Tool,
    cfg: *const config_mod.Config,
) ![]const []const u8 {
    const wants_extra = std.mem.eql(u8, tool.name, "plugins") or
        std.mem.eql(u8, tool.name, "tools") or
        std.mem.eql(u8, tool.name, "skills");
    if (!wants_extra) return tool.fs_prefixes;
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(arena, tool.fs_prefixes);
    if (std.mem.eql(u8, tool.name, "skills")) {
        // The skills guest scans agent.skills_dir (granted through
        // ck_harness_config); a non-default directory is refused by the
        // manifest's static "skills" prefix unless it lands here too.
        const skills_dir = cfg.agent.skills_dir;
        if (skills_dir.len > 0) {
            var seen = false;
            for (out.items) |have| {
                if (std.mem.eql(u8, have, skills_dir)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try out.append(arena, skills_dir);
        }
    }
    for (cfg.agent.tools_dir) |dir| {
        if (dir.len == 0) continue;
        var seen = false;
        for (out.items) |have| {
            if (std.mem.eql(u8, have, dir)) {
                seen = true;
                break;
            }
        }
        if (!seen) try out.append(arena, dir);
    }
    return try out.toOwnedSlice(arena);
}

/// Builds the `config` object handed to an exec-capable tool, merging its
/// descriptor config with the harness's exec policy (git_remote_ops,
/// exec_pattern_allow). Non-exec tools keep their own config untouched. The
/// extra keys are inert to a tool that does not read `config`.
pub fn execPolicyConfig(
    arena: std.mem.Allocator,
    tool_config: []const u8,
    cfg: *const config_mod.Config,
) ![]const u8 {
    _ = tool_config; // git.zig / gh.zig carry no descriptor config of their own.
    var out: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("git_remote_ops");
    try s.write(cfg.agent.git_remote_ops);
    try s.objectField("exec_pattern_allow");
    try s.beginArray();
    for (cfg.agent.exec_pattern_allow) |p| try s.write(p);
    try s.endArray();
    try s.endObject();
    return out.toOwnedSlice();
}

/// The board tools are one wasm (`board.wasm`) with a `kanban` multiplexed
/// entry and one op per `kanban_*` tool. The project's `#general` room is
/// `ws:<id>` (RFC 0001); a non-empty workspace defaults these tools to that
/// room so card actions land in the project feed instead of the global `board`.
fn isBoardTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "kanban") or std.mem.startsWith(u8, name, "kanban_");
}

/// Adds `"room": "ws:<id>"` to a board tool's descriptor config so board.zig
/// picks the project's `#general` room when the caller does not name one. The
/// descriptor's own keys (the pinned `op`) are kept; only `room` is overridden.
pub fn boardConfig(
    arena: std.mem.Allocator,
    tool_config: []const u8,
    workspace_id: []const u8,
) ![]const u8 {
    const room = try std.fmt.allocPrint(arena, "ws:{s}", .{workspace_id});
    var obj: std.json.ObjectMap = if (std.json.parseFromSliceLeaky(std.json.Value, arena, tool_config, .{})) |v| blk: {
        if (v == .object) break :blk v.object;
        break :blk std.json.ObjectMap.empty;
    } else |_| std.json.ObjectMap.empty;
    try obj.put(arena, "room", .{ .string = room });
    var out: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{} };
    try s.write(std.json.Value{ .object = obj });
    return out.toOwnedSlice();
}

/// The effective `config` object a tool sees in `ck_config`: the harness's exec
/// policy for exec-capable tools, the project board room for the kanban tools,
/// and the descriptor's own config otherwise. One function so the sequential
/// sandbox and the parallel worker inject the same thing.
pub fn toolConfigFor(
    arena: std.mem.Allocator,
    tool: *const registry.Tool,
    cfg: *const config_mod.Config,
) ![]const u8 {
    if (tool.exec_allow.len > 0) return execPolicyConfig(arena, tool.config_json, cfg);
    if (isBoardTool(tool.name) and cfg.agent.workspace_id.len > 0)
        return boardConfig(arena, tool.config_json, cfg.agent.workspace_id);
    return tool.config_json;
}

fn appendNetworkAllow(
    arena: std.mem.Allocator,
    current: []const []const u8,
    extra: []const []const u8,
) ![]const []const u8 {
    if (extra.len == 0) return current;
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(arena, current);
    try list.appendSlice(arena, extra);
    return list.toOwnedSlice(arena);
}

/// Tools whose whole job is reaching the open web, and which therefore read
/// the operator's `web.allow` on top of the hosts their manifest names. The
/// `research` sweep is one: its static hosts are the search and index APIs it
/// calls itself, and a site the operator wants it to reach should be a config
/// edit rather than a manifest edit.
fn isResearchTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "web_fetch") or
        std.mem.eql(u8, name, "web_search") or
        std.mem.eql(u8, name, "research");
}

test "boardConfig injects the project room and keeps the pinned op" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const with_op = try boardConfig(arena, "{\"op\":\"list\"}", "relumea");
    try std.testing.expectEqualStrings("{\"op\":\"list\",\"room\":\"ws:relumea\"}", with_op);

    const bare = try boardConfig(arena, "{}", "7dtd");
    try std.testing.expectEqualStrings("{\"room\":\"ws:7dtd\"}", bare);
}

test "execPolicyConfig injects git_remote_ops and exec_pattern_allow for exec tools" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cfg = config_mod.Config{};
    cfg.agent.git_remote_ops = true;
    cfg.agent.exec_pattern_allow = &.{ "gh pr create*", "gh pr merge*" };
    const out = try execPolicyConfig(arena, "", &cfg);
    try std.testing.expectEqualStrings(
        "{\"git_remote_ops\":true,\"exec_pattern_allow\":[\"gh pr create*\",\"gh pr merge*\"]}",
        out,
    );

    // A pattern containing a quote is escaped so the injected JSON stays valid
    // and the guest's parser cannot be handed malformed config.
    var cfg2 = config_mod.Config{};
    cfg2.agent.git_remote_ops = false;
    cfg2.agent.exec_pattern_allow = &.{"gh pr comment \"merge\" *"};
    const out2 = try execPolicyConfig(arena, "", &cfg2);
    try std.testing.expectEqualStrings(
        "{\"git_remote_ops\":false,\"exec_pattern_allow\":[\"gh pr comment \\\"merge\\\" *\"]}",
        out2,
    );

    // No patterns yields an empty array, which the guest reads as ungoverned.
    const cfg3 = config_mod.Config{};
    const out3 = try execPolicyConfig(arena, "", &cfg3);
    try std.testing.expectEqualStrings(
        "{\"git_remote_ops\":false,\"exec_pattern_allow\":[]}",
        out3,
    );
}

test "sandboxFor adds web.allow only to research tools and keeps static hosts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const cfg = config_mod.Config{ .web = .{ .allow = &.{ "github.com", "raw.githubusercontent.com" } } };
    const fetch = registry.Tool{
        .name = "web_fetch",
        .description = "test",
        .wasm = "test.wasm",
        .input_schema = .{ .object = .empty },
        .network_allow = &.{"api.github.com"},
    };
    const search = registry.Tool{
        .name = "web_search",
        .description = "test",
        .wasm = "test.wasm",
        .input_schema = .{ .object = .empty },
        .network_allow = &.{"html.duckduckgo.com"},
    };
    const unrelated = registry.Tool{
        .name = "peers",
        .description = "test",
        .wasm = "test.wasm",
        .input_schema = .{ .object = .empty },
        .network_allow = &.{"peer.static"},
    };

    const fetch_sb = try sandboxFor(std.testing.allocator, threaded.io(), arena, &env, &cfg, &fetch, null);
    try std.testing.expectEqual(@as(usize, 3), fetch_sb.network_allow.len);
    try std.testing.expectEqualStrings("api.github.com", fetch_sb.network_allow[0]);
    try std.testing.expectEqualStrings("github.com", fetch_sb.network_allow[1]);
    try std.testing.expectEqualStrings("raw.githubusercontent.com", fetch_sb.network_allow[2]);

    const search_sb = try sandboxFor(std.testing.allocator, threaded.io(), arena, &env, &cfg, &search, null);
    try std.testing.expectEqual(@as(usize, 3), search_sb.network_allow.len);
    try std.testing.expectEqualStrings("html.duckduckgo.com", search_sb.network_allow[0]);
    try std.testing.expectEqualStrings("github.com", search_sb.network_allow[1]);
    try std.testing.expectEqualStrings("raw.githubusercontent.com", search_sb.network_allow[2]);

    const unrelated_sb = try sandboxFor(std.testing.allocator, threaded.io(), arena, &env, &cfg, &unrelated, null);
    try std.testing.expectEqual(@as(usize, 1), unrelated_sb.network_allow.len);
    try std.testing.expectEqualStrings("peer.static", unrelated_sb.network_allow[0]);

    const no_web_cfg = config_mod.Config{};
    const no_web_fetch_sb = try sandboxFor(std.testing.allocator, threaded.io(), arena, &env, &no_web_cfg, &fetch, null);
    try std.testing.expectEqual(@as(usize, 1), no_web_fetch_sb.network_allow.len);
    try std.testing.expectEqualStrings("api.github.com", no_web_fetch_sb.network_allow[0]);
}

test "networkAllowed matches exact hosts, glob patterns, and the catch-all" {
    // Exact hostnames match only themselves.
    try std.testing.expect(networkAllowed(&.{"github.com"}, "github.com"));
    try std.testing.expect(!networkAllowed(&.{"github.com"}, "api.github.com"));

    // A wildcard subdomain pattern matches any depth of subdomain but not the
    // bare domain (mirrors exec_pattern_allow's glob semantics).
    try std.testing.expect(networkAllowed(&.{"*.github.com"}, "api.github.com"));
    try std.testing.expect(networkAllowed(&.{"*.github.com"}, "a.b.github.com"));
    try std.testing.expect(!networkAllowed(&.{"*.github.com"}, "github.com"));

    // `?` matches exactly one character.
    try std.testing.expect(networkAllowed(&.{"sub?.example.com"}, "sub1.example.com"));
    try std.testing.expect(!networkAllowed(&.{"sub?.example.com"}, "sub12.example.com"));

    // A bare `*` grants every host.
    try std.testing.expect(networkAllowed(&.{"*"}, "any.host.anywhere"));
    try std.testing.expect(networkAllowed(&.{"*"}, "127.0.0.1"));

    // An empty allowlist grants nothing.
    try std.testing.expect(!networkAllowed(&.{}, "github.com"));

    // The catch-all also grants a host a stricter sibling pattern would not.
    try std.testing.expect(networkAllowed(&.{ "raw.githubusercontent.com", "*" }, "internal.example"));
}

/// Per-module execution context; passed to host functions via
/// `defineFuncCtx` and recovered with `Caller.data(Host)`.
pub const Host = struct {
    sandbox: *Sandbox,
    arena_base: u32 = 0,
    arena_cur: u32 = 0,
    /// Bytes reserved by this guest at arena_base. Set from the module's
    /// `host_arena_size` export at instantiation.
    arena_cap: u32 = host_arena_cap,
    result_ptr: u32 = 0,
    result_len: u32 = 0,
    rng: std.Random.DefaultPrng,
    /// Set by `ToolModule.load` when `agent.seed` was time-mixed: the
    /// effective value is announced on the first `ck_random` draw, not at
    /// load, so read-only guest verbs (`stats`, `sessions`, HTTP relays)
    /// never print a replay line for randomness they never consume.
    seed_notice: ?u64 = null,

    pub fn reset(self: *Host) void {
        self.arena_cur = self.arena_base;
        self.result_ptr = 0;
        self.result_len = 0;
    }

    fn writeResult(self: *Host, mem_bytes: []u8, data: []const u8) u32 {
        if (data.len > self.arena_cap) return Err.too_large;
        const off = self.arena_cur;
        if (@as(u64, off) + data.len > mem_bytes.len) return Err.too_large;
        if (self.arena_cur - self.arena_base + data.len > self.arena_cap) return Err.too_large;
        @memcpy(mem_bytes[off .. off + data.len], data);
        self.result_ptr = off;
        self.result_len = @intCast(data.len);
        self.arena_cur += @intCast(data.len);
        return Err.ok;
    }
};

fn memBytes(caller: *zwasm.Caller) ?[]u8 {
    const mem = caller.memory() orelse return null;
    return mem.slice();
}

fn sliceOf(bytes: []u8, ptr: u32, len: u32) ?[]u8 {
    if (@as(u64, ptr) + len > bytes.len) return null;
    return bytes[ptr .. ptr + len];
}

fn getHost(caller: *zwasm.Caller) *Host {
    return caller.data(Host);
}

// --------------------------------------------------------------- ck_* fns --

pub fn ckLog(caller: *zwasm.Caller, level: u32, ptr: u32, len: u32) void {
    if (memBytes(caller)) |bytes| {
        if (sliceOf(bytes, ptr, len)) |msg| {
            const lvl: log.Level = switch (level) {
                0 => .debug,
                1 => .info,
                2 => .warn,
                else => .error_,
            };
            log.log(lvl, "[tool] {s}", .{msg});
        }
    }
}

pub fn ckNow(caller: *zwasm.Caller) u64 {
    // Returns nanoseconds since the Unix epoch (bit-pattern-clean; zwasm's f64
    // host-result marshalling has a bug, so guests reinterpret this).
    const h = getHost(caller);
    return @intCast(std.Io.Timestamp.now(h.sandbox.io, .real).nanoseconds);
}

pub fn ckRandom(caller: *zwasm.Caller) u64 {
    const h = getHost(caller);
    if (h.seed_notice) |seed| {
        // First real draw: this is the moment the effective seed becomes
        // worth recording for replay (same module bytes ⇒ same ck_random
        // stream). Sandboxes that never draw stay silent.
        log.log(.info, "sandbox rng: agent.seed=0 was time-seeded, effective seed 0x{x}; replay with agent.seed=0x{x}", .{ seed, seed });
        h.seed_notice = null;
    }
    return h.rng.random().int(u64);
}

/// ck_hash(ptr, len) -> 64-byte lowercase hex SHA-256 digest of the
/// guest memory region [ptr, ptr+len) written into the host arena.
/// Returns Err.ok on success; the digest is retrievable via ck_result().
/// Returns Err.invalid for bad pointers, Err.too_large if the input
/// exceeds max_fs_bytes.
pub fn ckHash(caller: *zwasm.Caller, ptr: u32, len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const data = sliceOf(bytes, ptr, len) orelse return Err.invalid;
    if (data.len > h.sandbox.max_fs_bytes) return Err.too_large;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    const digest = hasher.finalResult();
    const hex = std.fmt.bytesToHex(digest, .lower);
    return h.writeResult(bytes, &hex);
}

/// A parsed ck_llm JSON request object. Every field is optional; a value that
/// is missing, empty, or the wrong type stays null and the caller falls back
/// to the tool's configured defaults (an explicitly empty "prompt" string is
/// kept so the caller can reject it).
const CkLlmRequest = struct {
    prompt: ?[]const u8 = null,
    max_tokens: ?u32 = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    system: ?[]const u8 = null,
};

/// Parses `raw` as a ck_llm request object. Returns null when `raw` is not a
/// JSON object, the caller then treats it as a bare prompt.
fn parseCkLlmRequest(arena: std.mem.Allocator, raw: []const u8) ?CkLlmRequest {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return null;
    if (v != .object) return null;
    var req: CkLlmRequest = .{};
    if (v.object.get("prompt")) |p| {
        if (p == .string) req.prompt = p.string;
    }
    req.max_tokens = json_util.pluginU32(v, "max_tokens");
    req.provider = json_util.pluginStr(v, "provider");
    req.model = json_util.pluginStr(v, "model");
    if (v.object.get("system")) |sp| {
        if (sp == .string and sp.string.len > 0) req.system = sp.string;
    }
    return req;
}

/// Descriptor `max_tokens` is the grant. A guest may only lower it, never
/// raise it: otherwise a confused (or injected) tool call bills an unbounded
/// completion against the operator's key. A grant of 0 is treated as the
/// same 1024 default `sandboxFor` uses when the descriptor omits the key.
fn clampCkLlmMaxTokens(requested: ?u32, granted: u32) u32 {
    const cap: u32 = if (granted == 0) 1024 else granted;
    return @min(requested orelse cap, cap);
}

/// Why a completion carried no visible content, or null when it carried some.
///
/// `max_tokens` bounds *output*, and on a reasoning model reasoning is output:
/// the provider spends the grant on `reasoning_content` first and only then
/// emits content. A grant sized for the answer alone therefore runs out before
/// a single visible token, and the provider still answers 200 — `content: ""`,
/// `finish_reason: "length"`, the whole budget in `completion_tokens`. Handing
/// that back as an ordinary empty string makes every guest report that the
/// model returned nothing, which names the symptom and hides the one fact that
/// fixes it. Verified against deepseek-v4-pro on 2026-08-17: a 64-token grant
/// came back with 64 reasoning tokens and an empty `content`.
fn emptyCompletionCause(content: []const u8, finish_reason: ?[]const u8, reasoning: ?[]const u8) ?[]const u8 {
    if (content.len > 0) return null;
    const truncated = if (finish_reason) |fr| std.mem.eql(u8, fr, "length") else false;
    if (!truncated) return "the model returned no content";
    if (reasoning) |r| if (r.len > 0)
        return "the model spent the whole max_tokens grant on reasoning; raise the tool descriptor's config.max_tokens";
    return "the completion was cut off at the max_tokens grant before any content";
}

/// ck_session(request) -> JSON. The only way a sandboxed guest reaches the
/// session store (which is SQLite, host-side). Gate: the tool descriptor must
/// set `session: true`. Requests:
///   {"op":"list"}                       -> {"sessions":[{id,title,created,updated,workspace,archived,messages,bytes}]}
///   {"op":"get","id":"<sid>"}         -> the full session (meta + messages)
///   {"op":"search","q":"<query>"}     -> {"ok":true,"query":...,"hits":[...]}
pub fn ckSession(caller: *zwasm.Caller, ptr: u32, len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const raw = sliceOf(bytes, ptr, len) orelse return Err.invalid;
    if (!h.sandbox.session) {
        log.log(.warn, "[session] denied: tool descriptor does not set \"session\": true", .{});
        return Err.denied;
    }

    var arena_state = std.heap.ArenaAllocator.init(h.sandbox.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const req = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{ .ignore_unknown_fields = true }) catch return Err.invalid;
    if (req != .object) return Err.invalid;
    const op = json_util.strFieldOrNull(req.object, "op") orelse return Err.invalid;

    const sessions_dir = "state/sessions";
    var out_w: std.Io.Writer.Allocating = .init(h.sandbox.gpa);
    defer out_w.deinit();
    var w = std.json.Stringify{ .writer = &out_w.writer, .options = .{ .emit_null_optional_fields = false } };

    if (std.mem.eql(u8, op, "list")) {
        const metas = session_mod.listSessions(h.sandbox.io, arena, sessions_dir) catch return Err.invalid;
        w.beginObject() catch return Err.invalid;
        w.objectField("sessions") catch return Err.invalid;
        w.beginArray() catch return Err.invalid;
        for (metas) |m| {
            w.beginObject() catch return Err.invalid;
            w.objectField("id") catch return Err.invalid;
            w.write(m.id) catch return Err.invalid;
            w.objectField("title") catch return Err.invalid;
            w.write(m.title) catch return Err.invalid;
            w.objectField("created") catch return Err.invalid;
            w.write(m.created) catch return Err.invalid;
            w.objectField("updated") catch return Err.invalid;
            w.write(m.updated) catch return Err.invalid;
            w.objectField("workspace") catch return Err.invalid;
            w.write(m.workspace) catch return Err.invalid;
            w.objectField("archived") catch return Err.invalid;
            w.write(m.archived) catch return Err.invalid;
            w.objectField("messages") catch return Err.invalid;
            w.write(m.messages) catch return Err.invalid;
            w.objectField("bytes") catch return Err.invalid;
            w.write(m.bytes) catch return Err.invalid;
            w.endObject() catch return Err.invalid;
        }
        w.endArray() catch return Err.invalid;
        w.endObject() catch return Err.invalid;
        return h.writeResult(bytes, out_w.written());
    }

    if (std.mem.eql(u8, op, "get")) {
        const id = json_util.strFieldOrNull(req.object, "id") orelse return Err.invalid;
        if (!session_mod.validSessionId(id)) return Err.invalid;
        const s = session_mod.loadSession(h.sandbox.io, h.sandbox.gpa, arena, sessions_dir, id) catch return Err.invalid;
        w.beginObject() catch return Err.invalid;
        w.objectField("id") catch return Err.invalid;
        w.write(s.id) catch return Err.invalid;
        w.objectField("title") catch return Err.invalid;
        w.write(s.title) catch return Err.invalid;
        w.objectField("created") catch return Err.invalid;
        w.write(s.created) catch return Err.invalid;
        w.objectField("updated") catch return Err.invalid;
        w.write(s.updated) catch return Err.invalid;
        w.objectField("workspace") catch return Err.invalid;
        w.write(s.workspace) catch return Err.invalid;
        w.objectField("archived") catch return Err.invalid;
        w.write(s.archived) catch return Err.invalid;
        if (s.system_prompt) |sp| {
            w.objectField("system_prompt") catch return Err.invalid;
            w.write(sp) catch return Err.invalid;
        }
        w.objectField("messages") catch return Err.invalid;
        w.beginArray() catch return Err.invalid;
        for (s.messages) |m| {
            w.beginObject() catch return Err.invalid;
            w.objectField("role") catch return Err.invalid;
            w.write(m.role.asStr()) catch return Err.invalid;
            if (m.content) |c| {
                w.objectField("content") catch return Err.invalid;
                w.write(c) catch return Err.invalid;
            }
            if (m.images) |imgs| {
                if (imgs.len > 0) {
                    w.objectField("images") catch return Err.invalid;
                    w.beginArray() catch return Err.invalid;
                    for (imgs) |img| {
                        w.beginObject() catch return Err.invalid;
                        w.objectField("mime") catch return Err.invalid;
                        w.write(img.mime) catch return Err.invalid;
                        w.objectField("b64") catch return Err.invalid;
                        w.write(img.b64) catch return Err.invalid;
                        w.endObject() catch return Err.invalid;
                    }
                    w.endArray() catch return Err.invalid;
                }
            }
            if (m.tool_calls) |calls| {
                if (calls.len > 0) {
                    w.objectField("tool_calls") catch return Err.invalid;
                    w.beginArray() catch return Err.invalid;
                    for (calls) |tc| {
                        w.beginObject() catch return Err.invalid;
                        w.objectField("id") catch return Err.invalid;
                        w.write(tc.id) catch return Err.invalid;
                        w.objectField("name") catch return Err.invalid;
                        w.write(tc.name) catch return Err.invalid;
                        w.objectField("arguments") catch return Err.invalid;
                        w.write(tc.arguments) catch return Err.invalid;
                        w.endObject() catch return Err.invalid;
                    }
                    w.endArray() catch return Err.invalid;
                }
            }
            if (m.tool_call_id) |tid| {
                w.objectField("tool_call_id") catch return Err.invalid;
                w.write(tid) catch return Err.invalid;
            }
            w.endObject() catch return Err.invalid;
        }
        w.endArray() catch return Err.invalid;
        w.endObject() catch return Err.invalid;
        return h.writeResult(bytes, out_w.written());
    }

    if (std.mem.eql(u8, op, "search")) {
        const q = json_util.strFieldOrNull(req.object, "q") orelse return Err.invalid;
        const hits = session_mod.searchSessions(h.sandbox.io, h.sandbox.gpa, arena, sessions_dir, q, 50) catch return Err.invalid;
        w.beginObject() catch return Err.invalid;
        w.objectField("ok") catch return Err.invalid;
        w.write(true) catch return Err.invalid;
        w.objectField("query") catch return Err.invalid;
        w.write(q) catch return Err.invalid;
        w.objectField("hits") catch return Err.invalid;
        w.beginArray() catch return Err.invalid;
        for (hits) |hit| {
            w.beginObject() catch return Err.invalid;
            w.objectField("id") catch return Err.invalid;
            w.write(hit.id) catch return Err.invalid;
            w.objectField("title") catch return Err.invalid;
            w.write(hit.title) catch return Err.invalid;
            w.objectField("updated") catch return Err.invalid;
            w.write(hit.updated) catch return Err.invalid;
            w.objectField("snippet") catch return Err.invalid;
            w.write(hit.snippet) catch return Err.invalid;
            w.objectField("more") catch return Err.invalid;
            w.write(hit.more) catch return Err.invalid;
            w.endObject() catch return Err.invalid;
        }
        w.endArray() catch return Err.invalid;
        w.endObject() catch return Err.invalid;
        return h.writeResult(bytes, out_w.written());
    }

    return Err.invalid;
}

/// ck_llm(request) -> completion text in the host arena. The request is either
/// a bare prompt or a JSON object:
/// `{"prompt": "...", "provider": "<name>", "model": "<name>", "system": "...", "max_tokens": N}`.
/// Naming a provider (and optionally a model) is what lets a plugin reach a
/// backend other than the one it was configured with (the `providers` tool
/// pings each configured provider this way) without reimplementing the chat
/// protocol in the guest; "system" prepends a system message to the call.
pub fn ckLlm(caller: *zwasm.Caller, ptr: u32, len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const raw = sliceOf(bytes, ptr, len) orelse return Err.invalid;
    if (raw.len == 0) return Err.invalid;

    const access = h.sandbox.llm orelse {
        log.log(.warn, "[llm] denied: tool descriptor does not set \"llm\": true", .{});
        return Err.denied;
    };

    var arena_state = std.heap.ArenaAllocator.init(h.sandbox.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var prompt: []const u8 = raw;
    var provider = access.provider;
    var max_tokens = access.max_tokens;
    var system: ?[]const u8 = null;
    if (parseCkLlmRequest(arena, raw)) |req| {
        if (req.prompt) |p| prompt = p;
        max_tokens = clampCkLlmMaxTokens(req.max_tokens, access.max_tokens);
        if (req.system) |s| system = s;
        if (req.provider) |pn| {
            const cfg = h.sandbox.cfg orelse {
                log.log(.warn, "[llm] provider override needs config", .{});
                return Err.invalid;
            };
            provider = cfg.provider(pn) catch {
                log.log(.warn, "[llm] unknown provider '{s}'", .{pn});
                return Err.invalid;
            };
        }
        // Model override: copy the (possibly provider-overridden) provider and
        // swap its default model, mirroring pluginProvider.
        if (req.model) |mn| {
            const copy = arena.create(config_mod.Provider) catch return Err.invalid;
            copy.* = provider.*;
            copy.default_model = mn;
            provider = copy;
        }
    }
    if (prompt.len == 0) return Err.invalid;

    const messages: []const types.Message = if (system) |sys| blk: {
        const msgs = arena.alloc(types.Message, 2) catch return Err.invalid;
        msgs[0] = .{ .role = .system, .content = sys };
        msgs[1] = .{ .role = .user, .content = prompt };
        break :blk msgs;
    } else blk: {
        const msgs = arena.alloc(types.Message, 1) catch return Err.invalid;
        msgs[0] = .{ .role = .user, .content = prompt };
        break :blk msgs;
    };
    var err_detail: ?[]const u8 = null;
    // Announced before the call, not just after it: an LLM call is the longest
    // thing a tool can do, and without the arrow a hanging request is
    // indistinguishable from one that was never issued.
    log.log(.info, "[llm] → ck_llm", .{});
    // `.awake` is monotonic. Elapsed time measured against `.real` goes
    // negative when NTP steps the wall clock mid-call, which is exactly the
    // window a multi-second request sits in.
    const llm_t0 = std.Io.Timestamp.now(h.sandbox.io, .awake);
    const resp = client.chat(access.ctx, arena, .{
        .provider = provider,
        .messages = messages,
        .max_tokens = max_tokens,
    }, &err_detail) catch |err| {
        const failed_ms = @divTrunc(llm_t0.durationTo(std.Io.Timestamp.now(h.sandbox.io, .awake)).nanoseconds, std.time.ns_per_ms);
        var log_detail_buf: [redact.max_log_detail_len]u8 = undefined;
        log.log(.warn, "[llm] ✗ ck_llm … {d}ms: {s} ({s})", .{ failed_ms, @errorName(err), redact.forLog(&log_detail_buf, err_detail orelse "") });
        return Err.network;
    };
    const content = resp.message.content orelse "";
    // Prefer the provider's own count; it is already computed for
    // client.recordUsage, so budget enforcement and accounting agree on the
    // same number instead of drifting apart on non-English or JSON-heavy
    // output. Fall back to the byte heuristic only when a provider omits usage.
    const est_tokens: u64 = if (resp.usage) |u|
        u.total_tokens
    else
        @intCast(@min(content.len / 4, std.math.maxInt(u32)));
    const llm_ms = @divTrunc(llm_t0.durationTo(std.Io.Timestamp.now(h.sandbox.io, .awake)).nanoseconds, std.time.ns_per_ms);
    log.log(.info, "[llm] ✓ ck_llm … {d}ms (~{d} est. tokens)", .{ llm_ms, est_tokens });
    // An empty completion still returns to the guest as an empty string, so a
    // fail-open caller degrades as before; the cause is logged because the
    // guest cannot see finish_reason or the reasoning spend to report it.
    if (emptyCompletionCause(content, resp.finish_reason, resp.reasoning)) |why| {
        // Completion tokens, not the `est_tokens` total: the grant bounds
        // output alone, so a total that includes the prompt cannot be read
        // against it.
        const spent: u64 = if (resp.usage) |u| u.completion_tokens else 0;
        log.log(.warn, "[llm] ck_llm answered with no content ({d} of {d} max_tokens spent): {s}", .{ spent, max_tokens, why });
    }
    if (h.sandbox.session_token_budget > 0) {
        if (h.sandbox.used_session_tokens + est_tokens > h.sandbox.session_token_budget) {
            log.log(.warn, "[llm] session token budget exceeded", .{});
            return Err.too_large;
        }
        h.sandbox.used_session_tokens += est_tokens;
    }
    return h.writeResult(bytes, content);
}

/// Bound on targets per ck_llm_many call. Each one is an OS thread holding an
/// open HTTPS connection for the length of a completion, so this is a real
/// resource ceiling; it matches `max_swarm_tasks` for the same reason.
const max_llm_many_targets: usize = 8;

/// One leg of a ck_llm_many fan-out: everything the thread needs on the way in,
/// everything it learned on the way out. `text` and `detail` are gpa-owned and
/// freed by the caller after encoding, mirroring ckSwarm's SubagentCall.
const LlmManyCall = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    ctx: *client.Ctx,
    provider: *const config_mod.Provider,
    messages: []const types.Message,
    max_tokens: u32,
    text: ?[]const u8 = null,
    err: ?anyerror = null,
    detail: ?[]const u8 = null,
    ms: i64 = 0,
    tokens: u64 = 0,

    fn run(self: *@This()) void {
        // Its own arena, so nothing crosses between legs: the only allocator
        // shared with the other threads is the gpa underneath, which ckSwarm
        // already hands to nested agents the same way.
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var err_detail: ?[]const u8 = null;
        // `.awake` is monotonic: an NTP step mid-call would otherwise make one
        // leg of the comparison look faster than it ran, or negative.
        const t0 = std.Io.Timestamp.now(self.io, .awake);
        const resp = client.chat(self.ctx, arena, .{
            .provider = self.provider,
            .messages = self.messages,
            .max_tokens = self.max_tokens,
        }, &err_detail) catch |e| {
            self.ms = elapsedMsFrom(self.io, t0);
            self.err = e;
            // The provider's own error text is what makes a failed leg
            // actionable ("model not found" vs "insufficient balance"); the
            // error name alone is not.
            if (err_detail) |d| self.detail = self.gpa.dupe(u8, d) catch null;
            return;
        };
        self.ms = elapsedMsFrom(self.io, t0);
        const content = resp.message.content orelse "";
        self.tokens = if (resp.usage) |u| u.total_tokens else @intCast(@min(content.len / 4, std.math.maxInt(u32)));
        self.text = self.gpa.dupe(u8, content) catch |e| {
            self.err = e;
            return;
        };
    }
};

fn elapsedMsFrom(io: std.Io, t0: std.Io.Timestamp) i64 {
    return @intCast(@divTrunc(t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds, std.time.ns_per_ms));
}

/// ck_llm_many(request) -> a JSON array of completions, one per target, in the
/// order the targets were given.
///
/// Request: `{"prompt": "...", "system": "...", "max_tokens": N,
///            "targets": [{"provider": "<name>", "model": "<name>"}, ...]}`.
/// Reply:   `[{"provider":..,"model":..,"ok":true,"text":..,"ms":N,"tokens":N},
///            {"provider":..,"model":..,"ok":false,"error":"..","ms":N}]`.
///
/// The point of a separate host function rather than a loop of `ck_llm` in the
/// guest: a wasm guest is single-threaded, so N models asked one at a time cost
/// the sum of their latencies. Here they run side by side on their own threads
/// and cost the slowest one, which is what makes "ask five models the same
/// question" a thing anyone would sit through. The fan-out mirrors `ck_swarm`'s
/// (spawn, then join every leg before returning), so the caller never observes
/// a half-finished batch and the parent stays parked on the tool call for the
/// whole thing.
///
/// One failing target is a failing element, never a failing call: a comparison
/// of five models where one provider is out of credit is still a comparison of
/// four, and collapsing it to an error would throw the other four away.
pub fn ckLlmMany(caller: *zwasm.Caller, ptr: u32, len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const raw = sliceOf(bytes, ptr, len) orelse return Err.invalid;
    if (raw.len == 0) return Err.invalid;

    // Same gate as ck_llm: model access is a descriptor grant, and a batch of
    // calls is not a way around it.
    const access = h.sandbox.llm orelse {
        log.log(.warn, "[llm] denied: tool descriptor does not set \"llm\": true", .{});
        return Err.denied;
    };

    var arena_state = std.heap.ArenaAllocator.init(h.sandbox.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return Err.invalid;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return Err.invalid,
    };
    const prompt = switch (obj.get("prompt") orelse return Err.invalid) {
        .string => |s| s,
        else => return Err.invalid,
    };
    if (prompt.len == 0) return Err.invalid;
    var system: ?[]const u8 = null;
    if (obj.get("system")) |s| {
        if (s == .string and s.string.len > 0) system = s.string;
    }
    const max_tokens = clampCkLlmMaxTokens(json_util.pluginU32(parsed, "max_tokens"), access.max_tokens);

    const targets_val = obj.get("targets") orelse return Err.invalid;
    if (targets_val != .array) return Err.invalid;
    const targets = targets_val.array.items;
    if (targets.len == 0) return Err.invalid;
    if (targets.len > max_llm_many_targets) return Err.too_large;

    const cfg = h.sandbox.cfg orelse {
        log.log(.warn, "[llm] ck_llm_many needs config to resolve provider names", .{});
        return Err.invalid;
    };

    const messages: []const types.Message = if (system) |sys| blk: {
        const msgs = arena.alloc(types.Message, 2) catch return Err.invalid;
        msgs[0] = .{ .role = .system, .content = sys };
        msgs[1] = .{ .role = .user, .content = prompt };
        break :blk msgs;
    } else blk: {
        const msgs = arena.alloc(types.Message, 1) catch return Err.invalid;
        msgs[0] = .{ .role = .user, .content = prompt };
        break :blk msgs;
    };

    const calls = arena.alloc(LlmManyCall, targets.len) catch return Err.too_large;
    const names = arena.alloc([2][]const u8, targets.len) catch return Err.too_large;
    for (targets, 0..) |t, i| {
        if (t != .object) return Err.invalid;
        const pname = switch (t.object.get("provider") orelse return Err.invalid) {
            .string => |s| s,
            else => return Err.invalid,
        };
        var provider = cfg.provider(pname) catch {
            log.log(.warn, "[llm] unknown provider '{s}'", .{pname});
            return Err.invalid;
        };
        var model_name = provider.activeModelName();
        if (t.object.get("model")) |mv| {
            if (mv == .string and mv.string.len > 0) {
                // Copy the provider and swap its default model, mirroring
                // ck_llm's own model override.
                const copy = arena.create(config_mod.Provider) catch return Err.invalid;
                copy.* = provider.*;
                copy.default_model = mv.string;
                provider = copy;
                model_name = mv.string;
            }
        }
        names[i] = .{ pname, model_name };
        calls[i] = .{
            .io = h.sandbox.io,
            .gpa = h.sandbox.gpa,
            .ctx = access.ctx,
            .provider = provider,
            .messages = messages,
            .max_tokens = max_tokens,
        };
    }

    log.log(.info, "[llm] → ck_llm_many ({d} targets, concurrent)", .{calls.len});
    const threads = arena.alloc(std.Thread, calls.len) catch return Err.too_large;
    var spawned: usize = 0;
    while (spawned < calls.len) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, LlmManyCall.run, .{&calls[spawned]}) catch break;
    }
    // Anything past `spawned` never ran. Rather than reporting it as a spawn
    // failure and losing that model's answer, run the remainder inline: a
    // comparison that is slower than it could have been still answers the
    // question it was asked.
    for (calls[spawned..]) |*c| c.run();
    for (threads[0..spawned]) |th| th.join();

    defer for (calls) |c| {
        if (c.text) |t| h.sandbox.gpa.free(@constCast(t));
        if (c.detail) |d| h.sandbox.gpa.free(@constCast(d));
    };

    const buf = h.sandbox.gpa.alloc(u8, h.sandbox.max_fs_bytes) catch return Err.too_large;
    defer h.sandbox.gpa.free(buf);
    var w: std.Io.Writer = .fixed(buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    s.beginArray() catch return Err.too_large;
    var failures: usize = 0;
    var total_tokens: u64 = 0;
    for (calls, 0..) |c, i| {
        s.beginObject() catch return Err.too_large;
        s.objectField("provider") catch return Err.too_large;
        s.write(names[i][0]) catch return Err.too_large;
        s.objectField("model") catch return Err.too_large;
        s.write(names[i][1]) catch return Err.too_large;
        s.objectField("ms") catch return Err.too_large;
        s.write(c.ms) catch return Err.too_large;
        if (c.text) |t| {
            total_tokens += c.tokens;
            s.objectField("ok") catch return Err.too_large;
            s.write(true) catch return Err.too_large;
            s.objectField("tokens") catch return Err.too_large;
            s.write(c.tokens) catch return Err.too_large;
            s.objectField("text") catch return Err.too_large;
            s.write(t) catch return Err.too_large;
        } else {
            failures += 1;
            s.objectField("ok") catch return Err.too_large;
            s.write(false) catch return Err.too_large;
            s.objectField("error") catch return Err.too_large;
            const name: []const u8 = if (c.err) |e| @errorName(e) else "no answer";
            s.write(name) catch return Err.too_large;
            if (c.detail) |d| {
                s.objectField("detail") catch return Err.too_large;
                s.write(d) catch return Err.too_large;
            }
        }
        s.endObject() catch return Err.too_large;
    }
    s.endArray() catch return Err.too_large;
    if (failures > 0) log.log(.warn, "[llm] ck_llm_many: {d}/{d} targets failed", .{ failures, calls.len });
    log.log(.info, "[llm] ✓ ck_llm_many ({d} answered, ~{d} est. tokens)", .{ calls.len - failures, total_tokens });

    // Charged once for the batch, against the same session budget a loop of
    // ck_llm calls would have hit: running the calls side by side must not make
    // them free.
    if (h.sandbox.session_token_budget > 0) {
        if (h.sandbox.used_session_tokens + total_tokens > h.sandbox.session_token_budget) {
            log.log(.warn, "[llm] session token budget exceeded", .{});
            return Err.too_large;
        }
        h.sandbox.used_session_tokens += total_tokens;
    }
    return h.writeResult(bytes, buf[0..w.end]);
}

/// ck_config() -> this tool's `config` object from its descriptor, as JSON.
pub fn ckConfig(caller: *zwasm.Caller) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    return h.writeResult(bytes, h.sandbox.config_json);
}

/// ck_harness_config() -> the harness's own effective config (providers,
/// models, instance, peers, default_provider), as JSON. Distinct from
/// ck_config: that returns this *tool's* descriptor `config` object; this
/// returns clanker's config.toml/config.local.toml, merged, as the harness
/// parsed it, regardless of whether the checkout uses TOML or (legacy)
/// JSON. Guests need this because a wasm32-freestanding module carries no
/// TOML parser: reading config.toml's raw bytes directly only works for
/// tools that just display the file (config's whole-dump path); a tool
/// that needs structured fields (peers, providers, status, ask_user)
/// goes through the host, which already parsed it once at startup.
pub fn ckHarnessConfig(caller: *zwasm.Caller) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const cfg = h.sandbox.cfg orelse return Err.denied;
    const access = harnessConfigAccess(h.sandbox.tool_self_name) orelse {
        log.log(.warn, "[sandbox] ck_harness_config denied for tool '{s}'", .{h.sandbox.tool_self_name});
        return Err.denied;
    };

    var arena_state = std.heap.ArenaAllocator.init(h.sandbox.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const json_out = harnessConfigJSON(arena, cfg, access) catch return Err.too_large;
    return h.writeResult(bytes, json_out);
}

const HarnessConfigAccess = enum { full, providers, peers, workflows, chains, tools_dir, skills, kernel, debug };

/// ck_harness_config is a privileged structured view, independent of
/// fs_prefixes. Grant each shipped caller only the section it consumes and
/// fail closed for any other guest, including newly added tools.
fn harnessConfigAccess(tool_name: []const u8) ?HarnessConfigAccess {
    if (std.mem.eql(u8, tool_name, "config")) return .full;
    // arena needs the provider list for one question only: which configured
    // provider is free to judge a match, i.e. is not already fighting it.
    // `.providers` answers that without handing it the agent budgets,
    // mcp_servers and the rest of the merged config that `.full` carries.
    // No level carries api_key_env or service_account_file.
    // compare needs it for two questions: which providers exist (so `clanker
    // compare` with no --with can put the configured ones side by side) and
    // which one is free to judge, i.e. is not itself an entrant.
    if (std.mem.eql(u8, tool_name, "providers") or std.mem.eql(u8, tool_name, "arena") or
        std.mem.eql(u8, tool_name, "compare")) return .providers;
    if (std.mem.eql(u8, tool_name, "peers") or std.mem.eql(u8, tool_name, "status") or std.mem.eql(u8, tool_name, "ask_user")) return .peers;
    if (std.mem.eql(u8, tool_name, "workflows")) return .workflows;
    if (std.mem.eql(u8, tool_name, "chain")) return .chains;
    if (std.mem.eql(u8, tool_name, "plugins") or std.mem.eql(u8, tool_name, "tools")) return .tools_dir;
    // skills reads agent.skills_dir to find where to scan for skill files;
    // denied, it would silently fall back to the literal "skills" and drift
    // from a configured directory. `.skills` answers that one question.
    if (std.mem.eql(u8, tool_name, "skills")) return .skills;
    if (std.mem.eql(u8, tool_name, "kernel")) return .kernel;
    if (std.mem.eql(u8, tool_name, "debug")) return .debug;
    return null;
}

/// Serializes the fields of `Config` that guests actually consume. Providers
/// keep their nested `models` map (the shape guests already parse) even
/// though the harness itself now stores it distributed that way in memory
/// from a flat `[models."provider/model"]` table on disk, see
/// distributeModels in config.zig.
fn harnessConfigJSON(arena: std.mem.Allocator, cfg: *const config_mod.Config, access: HarnessConfigAccess) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &w.writer, .options = .{} };

    try s.beginObject();
    if (access == .full or access == .providers) {
        try s.objectField("default_provider");
        try s.write(cfg.default_provider);

        try s.objectField("providers");
        try s.beginObject();
        var pit = cfg.providers.iterator();
        while (pit.next()) |pkv| {
            const p = pkv.value_ptr;
            try s.objectField(pkv.key_ptr.*);
            try s.beginObject();
            try s.objectField("kind");
            try s.write(@tagName(p.kind));
            try s.objectField("base_url");
            try s.write(p.base_url);
            // api_key_env intentionally excluded from every access level:
            // env var names pointing to secrets should never cross into
            // guest memory. The host resolves them in src/llm/auth.zig.
            try s.objectField("default_model");
            try s.write(p.default_model);
            if (p.rpm) |r| {
                try s.objectField("rpm");
                try s.write(r);
            }
            try s.objectField("models");
            try s.beginObject();
            var mit = p.models.iterator();
            while (mit.next()) |mkv| {
                try s.objectField(mkv.key_ptr.*);
                try writeModelJson(&s, mkv.value_ptr, null);
            }
            try s.endObject();
            try s.endObject();
        }
        try s.endObject();
    }

    if (access == .full or access == .peers) {
        try s.objectField("instance");
        try s.beginObject();
        try s.objectField("name");
        try s.write(cfg.instance.name);
        try s.objectField("id");
        try s.write(cfg.instance.id);
        try s.endObject();

        try s.objectField("peers");
        try s.beginArray();
        for (cfg.peers) |p| {
            try s.beginObject();
            try s.objectField("name");
            try s.write(p.name);
            try s.objectField("url");
            try s.write(p.url);
            try s.endObject();
        }
        try s.endArray();
    }

    // Narrow views only get the one directory they read. The full view is
    // config's section mode, which looks up any top-level key of the
    // merged config, so a truncated `agent` (just the two dirs) would report
    // max_iterations and the other budgets as unset.
    if (access == .full) {
        try s.objectField("agent");
        try s.write(cfg.agent);
        // On disk, models are a top-level `[models."provider/name"]` table.
        // In memory they live under each provider. Reconstruct the flat
        // table so `config {"section":"models"}` is not reported as
        // missing after a successful load.
        try s.objectField("models");
        try s.beginObject();
        var mit = cfg.providers.iterator();
        while (mit.next()) |pkv| {
            const pname = pkv.key_ptr.*;
            var mm = pkv.value_ptr.models.iterator();
            while (mm.next()) |mkv| {
                const key = try std.fmt.allocPrint(arena, "{s}/{s}", .{ pname, mkv.key_ptr.* });
                try s.objectField(key);
                try writeModelJson(&s, mkv.value_ptr, pname);
            }
        }
        try s.endObject();
    } else if (access == .workflows or access == .chains or access == .tools_dir or access == .skills) {
        try s.objectField("agent");
        try s.beginObject();
        if (access == .workflows) {
            try s.objectField("workflows_dir");
            try s.write(cfg.agent.workflows_dir);
        }
        if (access == .chains) {
            try s.objectField("chains_dir");
            try s.write(cfg.agent.chains_dir);
        }
        if (access == .skills) {
            try s.objectField("skills_dir");
            try s.write(cfg.agent.skills_dir);
        }
        if (access == .tools_dir) {
            try s.objectField("tools_dir");
            // One deterministic write/scaffold destination (plugins new).
            try s.write(config_mod.firstToolsDir(cfg.agent.tools_dir));
            try s.objectField("tools_dirs");
            // Full scan list so /plugins and `tools list` match Registry.load.
            try s.write(cfg.agent.tools_dir);
        }
        try s.endObject();
    }

    // config's section mode looks up one top-level key of this object.
    // Emit every non-secret section so `{"section":"chatrooms"}` (or tui,
    // improve, web, ...) is not reported as missing when the file has it.
    // api_key_env / service_account_file stay off every access level.
    if (access == .full) {
        try s.objectField("modules");
        try s.write(cfg.modules);
        try s.objectField("improve");
        try s.write(cfg.improve);
        try s.objectField("web");
        try s.write(cfg.web);
        try s.objectField("serve");
        try s.write(cfg.serve);
        try s.objectField("memory");
        try s.write(cfg.memory);
        try s.objectField("notify");
        try s.write(cfg.notify);
        try s.objectField("chatrooms");
        try s.write(cfg.chatrooms);
        try s.objectField("tui");
        try s.write(cfg.tui);
        try s.objectField("kernel");
        try s.write(cfg.kernel);
        try s.objectField("debug");
        try s.write(cfg.debug);
        try s.objectField("mesh");
        try s.write(cfg.mesh);
        try s.objectField("ttsr");
        try s.write(cfg.ttsr);
        try s.objectField("advisor");
        try s.write(cfg.advisor);
        try s.objectField("hooks");
        try s.write(cfg.hooks);
        try s.objectField("mcp_servers");
        try s.beginObject();
        var msit = cfg.mcp_servers.iterator();
        while (msit.next()) |mskv| {
            try s.objectField(mskv.key_ptr.*);
            try writeMcpServerJson(&s, mskv.value_ptr);
        }
        try s.endObject();
    }
    if (access == .kernel) {
        try s.objectField("kernel");
        try s.write(cfg.kernel);
    }
    if (access == .debug) {
        try s.objectField("debug");
        try s.write(cfg.debug);
    }

    try s.endObject();
    return w.toOwnedSlice();
}

/// One external MCP server as JSON, with `env` and `headers` values stripped.
///
/// `api_key_env` and `service_account_file` are kept off every access level
/// because a credential must not cross into guest memory, and `mcp_servers`
/// is the one section that carries credentials *inline*: its `env` entries are
/// `NAME=value` and its `headers` are `Header: value`, which is where an
/// `Authorization: Bearer ...` or a `GITHUB_TOKEN=ghp_...` lands. Writing the
/// struct wholesale handed those values to the `config` guest, and from there
/// to the model transcript. The name half is what a guest can use ("which
/// variables does this server take"), so only the value half is dropped.
fn writeMcpServerJson(s: *std.json.Stringify, m: *const config_mod.McpServer) !void {
    try s.beginObject();
    try s.objectField("transport");
    try s.write(m.transport);
    try s.objectField("command");
    try s.write(m.command);
    try s.objectField("args");
    try s.write(m.args);
    try s.objectField("cwd");
    try s.write(m.cwd);
    try s.objectField("url");
    try s.write(m.url);
    try s.objectField("tool_call_timeout_ms");
    try s.write(m.tool_call_timeout_ms);
    try s.objectField("env");
    try writeNamesOnly(s, m.env, '=');
    try s.objectField("headers");
    try writeNamesOnly(s, m.headers, ':');
    try s.endObject();
}

/// Each entry up to and including the first `separator`, with the value
/// replaced by a fixed marker so a redacted entry still reads as "set" rather
/// than "absent". An entry with no separator is all name and is emitted whole.
fn writeNamesOnly(s: *std.json.Stringify, entries: []const []const u8, separator: u8) !void {
    try s.beginArray();
    var buf: [256]u8 = undefined;
    for (entries) |entry| {
        const cut = std.mem.findScalar(u8, entry, separator) orelse {
            try s.write(entry);
            continue;
        };
        // Over-long name: the marker alone still says the entry is set.
        const redacted = std.fmt.bufPrint(&buf, "{s}{c}<redacted>", .{ entry[0..cut], separator }) catch "<redacted>";
        try s.write(redacted);
    }
    try s.endArray();
}

/// One model's settings as JSON. `provider` is set only for the reconstructed
/// top-level `models` table (the on-disk field); nested maps under each
/// provider omit it because those guests already know the parent key.
fn writeModelJson(s: *std.json.Stringify, m: *const config_mod.Model, provider: ?[]const u8) !void {
    try s.beginObject();
    if (provider) |p| {
        try s.objectField("provider");
        try s.write(p);
    }
    // Emitted only when disabled: the guests' mirror default for a missing
    // key is `true`, which is also the config default. Without this a model
    // turned off in config stayed offered by every picker that reads the
    // bridge (the web Models view's own toggle wrote `enabled = false` and
    // the field never came back).
    if (!m.enabled) {
        try s.objectField("enabled");
        try s.write(false);
    }
    if (m.id.len > 0) {
        try s.objectField("id");
        try s.write(m.id);
    }
    try s.objectField("context_window");
    try s.write(m.context_window);
    try s.objectField("max_tokens");
    try s.write(m.max_tokens);
    if (m.display) |d| {
        try s.objectField("display");
        try s.write(d);
    }
    if (m.cost_per_1m_input) |c| {
        try s.objectField("cost_per_1m_input");
        try s.write(c);
    }
    if (m.cost_per_1m_output) |c| {
        try s.objectField("cost_per_1m_output");
        try s.write(c);
    }
    if (m.temperature) |t| {
        try s.objectField("temperature");
        try s.write(t);
    }
    if (m.top_p) |t| {
        try s.objectField("top_p");
        try s.write(t);
    }
    if (m.reasoning_effort) |r| {
        try s.objectField("reasoning_effort");
        try s.write(@tagName(r));
    }
    if (m.capabilities.len > 0) {
        try s.objectField("capabilities");
        try s.write(m.capabilities);
    }
    if (m.category.len > 0) {
        try s.objectField("category");
        try s.write(m.category);
    }
    if (m.rpm) |r| {
        try s.objectField("rpm");
        try s.write(r);
    }
    try s.endObject();
}

/// ck_env(name_ptr, name_len) -> value of the environment variable in the
/// host arena. Returns Err.not_found when the variable is not set, and
/// Err.invalid when the name is empty or the memory slice is invalid.
pub fn ckEnv(caller: *zwasm.Caller, name_ptr: u32, name_len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const name = sliceOf(bytes, name_ptr, name_len) orelse return Err.invalid;
    if (name.len == 0) return Err.invalid;
    if (!envAllowed(h.sandbox, name)) {
        log.log(.warn, "[sandbox] refused to read environment variable '{s}'", .{name});
        return Err.denied;
    }
    const value = h.sandbox.environ_map.get(name) orelse return Err.not_found;
    return h.writeResult(bytes, value);
}

/// Variables any tool may read: where it is running, and how to format output.
/// Empty `env_allow` means exactly this list; a manifest that names variables
/// replaces it, so the named set is the complete readable set and never these
/// defaults plus the names. Everything else has to be named by the manifest.
const env_default_allow = [_][]const u8{ "PWD", "HOME", "PATH", "LANG", "LC_ALL", "TERM", "TZ", "USER" };

/// The process environment holds this project's API keys, loaded from .env at
/// startup. Handing a guest any variable it asks for made the env_allow field
/// in a manifest decorative and put every key one getenv call away from a tool
/// the improvement engine wrote by itself.
fn envAllowed(sb: *const Sandbox, name: []const u8) bool {
    for (sb.env_allow) |allowed| {
        if (std.mem.eql(u8, allowed, name)) return true;
    }
    if (sb.env_allow.len > 0) return false;
    for (env_default_allow) |allowed| {
        if (std.mem.eql(u8, allowed, name)) return true;
    }
    return false;
}

/// Build the environment visible to a process launched on a guest's behalf.
/// ck_exec is still part of the guest boundary: inheriting the harness process
/// environment here would let an allowed executable print API keys that the
/// same guest is correctly denied through ck_env.
pub fn execEnvironment(gpa: std.mem.Allocator, sb: *const Sandbox) !std.process.Environ.Map {
    var filtered = std.process.Environ.Map.init(gpa);
    errdefer filtered.deinit();
    var it = sb.environ_map.iterator();
    while (it.next()) |entry| {
        if (envAllowed(sb, entry.key_ptr.*)) try filtered.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    return filtered;
}

pub fn ckResult(caller: *zwasm.Caller) u64 {
    const h = getHost(caller);
    return protocol.packPtrLen(h.result_ptr, h.result_len);
}

pub fn ckHttp(
    caller: *zwasm.Caller,
    method: u32,
    url_ptr: u32,
    url_len: u32,
    body_ptr: u32,
    body_len: u32,
    hdr_ptr: u32,
    hdr_len: u32,
) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const url = sliceOf(bytes, url_ptr, url_len) orelse return Err.invalid;
    const body = sliceOf(bytes, body_ptr, body_len) orelse &.{};
    const hdr_json = if (hdr_len > 0) sliceOf(bytes, hdr_ptr, hdr_len) else null;
    return httpImpl(h, bytes, method, url, body, hdr_json);
}

// Host-side implementation for the docker tool; registered in runtime.zig linkHostFns.

/// Where Docker's Unix socket lives, most specific first. The Linux package
/// creates /var/run/docker.sock; rootless installs put it under
/// XDG_RUNTIME_DIR (typically /run/user/<uid>); Docker Desktop on macOS
/// exposes ~/.docker/run/docker.sock and does not create the system path by
/// default. DOCKER_HOST names an override explicitly, but only the unix://
/// scheme is speakable here. Callers probe in order rather than switching on
/// the OS: a machine may carry more than one of these.
fn dockerSocketCandidates(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    if (env.get("DOCKER_HOST")) |dh| {
        if (std.mem.startsWith(u8, dh, "unix://")) try list.append(arena, dh["unix://".len..]);
    }
    if (env.get("XDG_RUNTIME_DIR")) |xdir| {
        try list.append(arena, try std.fmt.allocPrint(arena, "{s}/docker.sock", .{xdir}));
    }
    if (env.get("HOME")) |home| {
        try list.append(arena, try std.fmt.allocPrint(arena, "{s}/.docker/run/docker.sock", .{home}));
    }
    try list.append(arena, "/var/run/docker.sock");
    return list.items;
}

pub fn ckDocker(caller: *zwasm.Caller, path_ptr: u32, path_len: u32) u32 {
    const h = getHost(caller);
    // Docker's Unix socket is a privileged host-side channel that is not
    // represented by fs_prefixes or network_allow. Registration alone must
    // not make it callable by every guest linked into the shared runtime.
    if (!dockerAccessAllowed(h.sandbox)) {
        log.log(.warn, "[sandbox] ck_docker denied for tool '{s}'", .{h.sandbox.tool_self_name});
        return Err.denied;
    }
    const bytes = memBytes(caller) orelse return Err.invalid;
    const json_input = sliceOf(bytes, path_ptr, path_len) orelse return Err.invalid;

    // Parse into a scoped arena: parseFromSliceLeaky on the long-lived gpa
    // would leak the parse tree on every docker tool call (mirrors ckLlm).
    var arena_state = std.heap.ArenaAllocator.init(h.sandbox.gpa);
    defer arena_state.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), json_input, .{}) catch {
        // Log only the length, never the input (same rule as ck_chat): a
        // docker tool call carries container names, mounted host paths and
        // exec argv, so the whole payload on stderr is user data in a log a
        // collector keeps.
        log.log(.warn, "[docker] json parse failed ({d} bytes)", .{json_input.len});
        return Err.invalid;
    };
    const obj = switch (parsed) {
        .object => |o| o,
        else => return Err.invalid,
    };
    const path = switch (obj.get("path") orelse return Err.invalid) {
        .string => |s| s,
        else => return Err.invalid,
    };
    if (!dockerRequestAllowed(methodFromDockerInput(obj), path)) {
        log.log(.warn, "[docker] path denied: '{s}'", .{path});
        return Err.denied;
    }

    const method = methodFromDockerInput(obj);

    // Connect to the first Docker Unix socket that answers (std.Io.net API in
    // Zig 0.16). The location is per install mode, not per OS name: see
    // dockerSocketCandidates.
    var last_connect_err: ?anyerror = null;
    var found: ?std.Io.net.Stream = null;
    const sockets = dockerSocketCandidates(arena_state.allocator(), h.sandbox.environ_map) catch return Err.invalid;
    for (sockets) |sock| {
        const ua = std.Io.net.UnixAddress.init(sock) catch continue;
        found = ua.connect(h.sandbox.io) catch |err| {
            last_connect_err = err;
            continue;
        };
        break;
    }
    const stream = found orelse {
        log.log(.warn, "[docker] no reachable socket ({s})", .{
            if (last_connect_err) |e| @errorName(e) else "no candidates",
        });
        return Err.network;
    };
    defer stream.close(h.sandbox.io);

    // Build and send the HTTP request.
    const req = std.fmt.allocPrint(h.sandbox.gpa, "{s} {s} HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n", .{ method, path }) catch return Err.invalid;
    defer h.sandbox.gpa.free(req);
    var wbuf: [8192]u8 = undefined;
    var w = stream.writer(h.sandbox.io, &wbuf);
    w.interface.writeAll(req) catch return Err.network;
    w.interface.flush() catch return Err.network;

    // Read the full response.
    var resp = std.ArrayList(u8).empty;
    defer resp.deinit(h.sandbox.gpa);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const nr = std.posix.read(stream.socket.handle, &tmp) catch |err| {
            log.log(.warn, "[docker] read failed: {s}", .{@errorName(err)});
            return Err.network;
        };
        if (nr == 0) break;
        if (nr > h.sandbox.max_http_bytes -| resp.items.len) return Err.too_large;
        resp.appendSlice(h.sandbox.gpa, tmp[0..nr]) catch return Err.too_large;
    }

    // Strip headers and write the body into the host arena.
    const r = resp.items;
    if (std.mem.find(u8, r, "\r\n\r\n")) |hdr_end| {
        const body = r[hdr_end + 4 ..];
        return h.writeResult(bytes, body);
    }
    return Err.invalid;
}

fn dockerAccessAllowed(sb: *const Sandbox) bool {
    return std.mem.eql(u8, sb.tool_self_name, "docker");
}

/// Privileged persistent kernel eval. Import existing is not a grant: only
/// the `kernel` guest may call this, and only when `kernel.enabled` is true.
pub fn ckKernel(caller: *zwasm.Caller, ptr: u32, len: u32) u32 {
    const h = getHost(caller);
    if (!std.mem.eql(u8, h.sandbox.tool_self_name, "kernel")) {
        log.log(.warn, "[sandbox] ck_kernel denied for tool '{s}'", .{h.sandbox.tool_self_name});
        return Err.denied;
    }
    const cfg = h.sandbox.cfg orelse return Err.denied;
    if (!cfg.kernel.enabled) return Err.denied;
    const bytes = memBytes(caller) orelse return Err.invalid;
    const json_input = sliceOf(bytes, ptr, len) orelse return Err.invalid;

    var arena_state = std.heap.ArenaAllocator.init(h.sandbox.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json_input, .{}) catch return Err.invalid;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return Err.invalid,
    };
    const kind = switch (obj.get("kernel") orelse std.json.Value{ .string = "python" }) {
        .string => |s| s,
        else => "python",
    };
    if (std.mem.eql(u8, kind, "js")) {
        return h.writeResult(bytes, "{\"ok\":false,\"error\":\"js kernel not started: bun worker is still landing\"}");
    }
    if (!std.mem.eql(u8, kind, "python")) {
        return h.writeResult(bytes, "{\"ok\":false,\"error\":\"kernel must be \\\"python\\\" or \\\"js\\\"\"}");
    }
    const cell = switch (obj.get("cell") orelse std.json.Value{ .string = "" }) {
        .string => |s| s,
        else => "",
    };
    const reset = switch (obj.get("reset") orelse std.json.Value{ .bool = false }) {
        .bool => |b| b,
        else => false,
    };
    const pip: ?[]const u8 = switch (obj.get("pip") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => null,
    };
    const bash: ?[]const u8 = switch (obj.get("bash") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => null,
    };
    const timeout_ms: u32 = switch (obj.get("timeout_ms") orelse std.json.Value{ .integer = 10000 }) {
        .integer => |n| if (n <= 0) 10000 else @intCast(@min(n, std.math.maxInt(u32))),
        else => 10000,
    };
    const sid = if (h.sandbox.session_id.len > 0) h.sandbox.session_id else "default";
    const cwd_rel = std.fmt.allocPrint(arena, "{s}/kernels/{s}/{s}", .{ h.sandbox.state_dir, sid, kind }) catch
        return h.writeResult(bytes, kernel_mod.errorJson(arena, "out of memory"));
    const base = h.sandbox.state_base_dir orelse std.Io.Dir.cwd();
    ensure_dir.ensureDir(base, h.sandbox.io, cwd_rel) catch
        return h.writeResult(bytes, kernel_mod.errorJson(arena, "state/kernels/ directory not writable"));
    var kdir = base.openDir(h.sandbox.io, cwd_rel, .{}) catch
        return h.writeResult(bytes, kernel_mod.errorJson(arena, "state/kernels/ directory not writable"));
    defer kdir.close(h.sandbox.io);

    const reg = h.sandbox.subprocs orelse subprocess.processRegistry(h.sandbox.gpa, h.sandbox.io) catch
        return h.writeResult(bytes, kernel_mod.errorJson(arena, "subprocess registry unavailable"));

    const out = kernel_mod.eval(.{
        .io = h.sandbox.io,
        .gpa = h.sandbox.gpa,
        .arena = arena,
        .reg = reg,
        .session_id = sid,
        .kind = kind,
        .cwd = .{ .dir = kdir },
        .cell = cell,
        .reset = reset,
        .pip = pip,
        .bash = bash,
        .timeout_ms = timeout_ms,
        .max_output_bytes = cfg.kernel.max_output_bytes,
        .enabled = true,
    }) catch |err| {
        const msg = switch (err) {
            error.Python3NotFound => "python3 not found; install Python 3.10+",
            error.Timeout => "cell execution timed out; kernel restarted",
            error.KernelDisabled => "kernel is disabled (kernel.enabled = false)",
            else => @errorName(err),
        };
        return h.writeResult(bytes, kernel_mod.errorJson(arena, msg));
    };
    return h.writeResult(bytes, out);
}

/// Privileged DAP adapter channel. Import existing is not a grant: only the
/// `debug` guest may call this, and only when `debug.enabled` is true.
pub fn ckDebug(caller: *zwasm.Caller, ptr: u32, len: u32) u32 {
    const h = getHost(caller);
    if (!std.mem.eql(u8, h.sandbox.tool_self_name, "debug")) {
        log.log(.warn, "[sandbox] ck_debug denied for tool '{s}'", .{h.sandbox.tool_self_name});
        return Err.denied;
    }
    const cfg = h.sandbox.cfg orelse return Err.denied;
    if (!cfg.debug.enabled) return Err.denied;
    const bytes = memBytes(caller) orelse return Err.invalid;
    const json_input = sliceOf(bytes, ptr, len) orelse return Err.invalid;

    var arena_state = std.heap.ArenaAllocator.init(h.sandbox.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sid = if (h.sandbox.session_id.len > 0) h.sandbox.session_id else "default";
    const reg = h.sandbox.subprocs orelse subprocess.processRegistry(h.sandbox.gpa, h.sandbox.io) catch
        return h.writeResult(bytes, dap.errorJson(arena, "subprocess registry unavailable"));

    const sess = dap.liveSession(h.sandbox.gpa, h.sandbox.io, reg, sid) catch
        return h.writeResult(bytes, dap.errorJson(arena, "debug session unavailable"));

    // handle() copies the timeout knobs from HandleOpts onto the session;
    // writing them here too made the opts fields look dead.
    const out = dap.handle(sess, .{
        .io = h.sandbox.io,
        .gpa = h.sandbox.gpa,
        .arena = arena,
        .reg = reg,
        .session_id = sid,
        .enabled = true,
        .adapters = cfg.debug.adapters,
        .launch_timeout_ms = cfg.debug.launch_timeout_ms,
        .request_timeout_ms = cfg.debug.request_timeout_ms,
        .disconnect_timeout_ms = cfg.debug.disconnect_timeout_ms,
    }, json_input) catch |err| {
        const msg = switch (err) {
            error.DebugDisabled => "debug is disabled (debug.enabled = false)",
            error.MissingAdapter => "launch requires adapter matching debug.adapters",
            error.UnknownAdapter => "unknown adapter; check debug.adapters",
            error.AdapterNotFound => "adapter binary not found on PATH",
            error.LaunchTimeout => "launch timed out (debug.launch_timeout_ms); adapter terminated",
            error.RequestTimeout => "request timed out (debug.request_timeout_ms); adapter terminated",
            else => @errorName(err),
        };
        return h.writeResult(bytes, dap.errorJson(arena, msg));
    };
    return h.writeResult(bytes, out);
}

const python_cell_harness =
    \\import ast, io, json, sys, traceback
    \\src = sys.stdin.read()
    \\stdout = io.StringIO()
    \\stderr = io.StringIO()
    \\result = None
    \\ok = True
    \\try:
    \\    tree = ast.parse(src, mode="exec")
    \\    body, last = (tree.body[:-1], tree.body[-1]) if tree.body else ([], None)
    \\    g = {"__name__": "__main__"}
    \\    if body:
    \\        exec(compile(ast.Module(body=body, type_ignores=[]), "<cell>", "exec"), g, g)
    \\    if last is not None:
    \\        if isinstance(last, ast.Expr):
    \\            result = eval(compile(ast.Expression(last.value), "<cell>", "eval"), g, g)
    \\        else:
    \\            exec(compile(ast.Module(body=[last], type_ignores=[]), "<cell>", "exec"), g, g)
    \\except Exception:
    \\    ok = False
    \\    traceback.print_exc(file=stderr)
    \\print(json.dumps({"ok": ok, "stdout": stdout.getvalue(), "stderr": stderr.getvalue(), "result": None if result is None else repr(result)}))
;

fn runPythonCell(sb: *const Sandbox, arena: std.mem.Allocator, cell: []const u8) ![]const u8 {
    if (sb.cfg) |cfg| {
        if (statExists(sb.io, cfg.kernel.python_wasi_binary)) {
            return runPythonCellSandboxed(sb, arena, cfg, cell) catch |err| {
                log.log(.warn, "kernel: WASI python run failed ({s}); check {s} and {s}", .{ @errorName(err), cfg.kernel.python_wasi_binary, cfg.kernel.python_wasi_stdlib });
                return err;
            };
        }
        log.log(.warn, "kernel: '{s}' not found; falling back to an UNSANDBOXED host python3 subprocess. " ++
            "This fallback is deprecated and will be removed. Run ./scripts/setup-python-wasi.sh to sandbox it.", .{cfg.kernel.python_wasi_binary});
    }
    return runPythonCellUnsandboxed(sb, arena, cell);
}

fn statExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn runPythonCellSandboxed(sb: *const Sandbox, arena: std.mem.Allocator, cfg: *const config_mod.Config, cell: []const u8) ![]const u8 {
    const out = try python_wasi.run(
        sb.io,
        sb.gpa,
        cfg.kernel.python_wasi_binary,
        cfg.kernel.python_wasi_stdlib,
        &.{ "python", "-c", python_cell_harness },
        cell,
        .{
            .fuel = cfg.kernel.python_wasi_fuel,
            .timeout_ms = cfg.kernel.python_wasi_timeout_ms,
            .max_memory_bytes = cfg.kernel.python_wasi_max_memory_bytes,
            .max_output_bytes = cfg.kernel.max_output_bytes,
        },
    );
    defer sb.gpa.free(out.stdout);
    defer sb.gpa.free(out.stderr);
    if (out.stdout.len == 0) {
        const msg = if (out.stderr.len > 0) out.stderr else "no output";
        return std.fmt.allocPrint(arena, "{{\"ok\":false,\"error\":{f}}}", .{std.json.fmt(msg, .{})});
    }
    return arena.dupe(u8, out.stdout);
}

fn runPythonCellUnsandboxed(sb: *const Sandbox, arena: std.mem.Allocator, cell: []const u8) ![]const u8 {
    var child = std.process.spawn(sb.io, .{
        .argv = &.{ "python3", "-c", python_cell_harness },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.Python3NotFound,
        else => return err,
    };
    defer child.kill(sb.io);
    if (child.stdin) |stdin_file| {
        var wbuf: [4096]u8 = undefined;
        var writer = stdin_file.writer(sb.io, &wbuf);
        try writer.interface.writeAll(cell);
        try writer.interface.flush();
        stdin_file.close(sb.io);
        child.stdin = null;
    }
    var out: std.ArrayList(u8) = .empty;
    if (child.stdout) |stdout_file| {
        var rbuf: [8192]u8 = undefined;
        var reader = stdout_file.reader(sb.io, &rbuf);
        while (true) {
            const chunk = reader.interface.peekGreedy(1) catch break;
            try out.appendSlice(arena, chunk);
            reader.interface.toss(chunk.len);
            if (out.items.len > 512 * 1024) break;
        }
    }
    _ = try child.wait(sb.io);
    if (out.items.len == 0) return error.Python3NotFound;
    return out.items;
}

test "runPythonCell runs the WASI-sandboxed path when the vendored interpreter is present" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    if (!statExists(io, "vendor/python-wasi/bin/python-3.12.0.wasm")) return error.SkipZigTest;

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const cfg = config_mod.Config{ .kernel = .{ .enabled = true } };
    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = ".",
        .network_allow = &.{},
        .fs_prefixes = &.{},
        .environ_map = &env,
        .cfg = &cfg,
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try runPythonCell(&sb, arena_state.allocator(), "1 + 1");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), out, .{});
    try std.testing.expect(parsed.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("2", parsed.object.get("result").?.string);
}

fn methodFromDockerInput(obj: std.json.ObjectMap) []const u8 {
    const value = obj.get("method") orelse return "GET";
    return if (value == .string) value.string else "";
}

/// The Docker socket is equivalent to root authority on many hosts. This tool
/// is an inspection surface: GET only, and only the list/inspect endpoints.
/// A bare `/v1.*` prefix would still let a guest pull files out of a
/// container (`.../archive`), export an image tarball (`.../get`), or read
/// swarm secrets.
fn dockerRequestAllowed(method: []const u8, path: []const u8) bool {
    if (!std.mem.eql(u8, method, "GET")) return false;
    if (std.mem.findAny(u8, path, "\r\n \t\x00") != null) return false;
    if (!std.mem.startsWith(u8, path, "/v1.")) return false;

    var i: usize = 4;
    while (i < path.len and path[i] >= '0' and path[i] <= '9') : (i += 1) {}
    if (i == 4 or i >= path.len or path[i] != '/') return false;
    var rest = path[i + 1 ..];
    if (std.mem.findScalar(u8, rest, '?')) |q| rest = rest[0..q];
    if (rest.len == 0) return false;
    if (std.mem.find(u8, rest, "..") != null) return false;

    const exact = [_][]const u8{
        "info",            "version",     "_ping",
        "containers/json", "images/json", "networks",
        "volumes",         "system/df",
    };
    for (exact) |e| {
        if (std.mem.eql(u8, rest, e)) return true;
    }

    if (std.mem.startsWith(u8, rest, "containers/")) {
        const after = rest["containers/".len..];
        const slash = std.mem.findScalar(u8, after, '/') orelse return false;
        if (slash == 0) return false;
        const action = after[slash + 1 ..];
        return std.mem.eql(u8, action, "json") or
            std.mem.eql(u8, action, "logs") or
            std.mem.eql(u8, action, "stats") or
            std.mem.eql(u8, action, "top");
    }
    if (std.mem.startsWith(u8, rest, "images/")) {
        const after = rest["images/".len..];
        const last = std.mem.findScalarLast(u8, after, '/') orelse return false;
        if (last == 0 or last + 1 >= after.len) return false;
        const action = after[last + 1 ..];
        return std.mem.eql(u8, action, "json") or std.mem.eql(u8, action, "history");
    }
    if (std.mem.startsWith(u8, rest, "networks/")) {
        const id = rest["networks/".len..];
        return id.len > 0 and std.mem.findScalar(u8, id, '/') == null;
    }
    if (std.mem.startsWith(u8, rest, "volumes/")) {
        const name = rest["volumes/".len..];
        return name.len > 0 and std.mem.findScalar(u8, name, '/') == null;
    }
    return false;
}

test "docker request policy is query only" {
    try std.testing.expect(dockerRequestAllowed("GET", "/v1.41/containers/json"));
    try std.testing.expect(dockerRequestAllowed("GET", "/v1.41/containers/json?all=1"));
    try std.testing.expect(dockerRequestAllowed("GET", "/v1.41/containers/abc/json"));
    try std.testing.expect(dockerRequestAllowed("GET", "/v1.41/containers/abc/logs?stdout=1"));
    try std.testing.expect(dockerRequestAllowed("GET", "/v1.41/images/json"));
    try std.testing.expect(dockerRequestAllowed("GET", "/v1.41/images/library/nginx/json"));
    try std.testing.expect(dockerRequestAllowed("GET", "/v1.41/info"));
    try std.testing.expect(!dockerRequestAllowed("POST", "/v1.41/containers/prune"));
    try std.testing.expect(!dockerRequestAllowed("GET", "/containers/json"));
    try std.testing.expect(!dockerRequestAllowed("GET", "/v1.41/containers/json\r\nX-Evil: yes"));
    try std.testing.expect(!dockerRequestAllowed("GET", "/v1.41/containers/json HTTP/1.0\nEvil: yes"));
    try std.testing.expect(!dockerRequestAllowed("GET", "/v1.41/exec/a start"));
    try std.testing.expect(!dockerRequestAllowed("GET", "/v1.41/exec/a\tstart"));
    try std.testing.expect(!dockerRequestAllowed("GET", "/v1.41/x\x00y"));
    try std.testing.expect(!dockerRequestAllowed("GET", "/v1.41/containers/abc/archive?path=/etc/passwd"));
    try std.testing.expect(!dockerRequestAllowed("GET", "/v1.41/containers/abc/export"));
    try std.testing.expect(!dockerRequestAllowed("GET", "/v1.41/images/nginx/get"));
    try std.testing.expect(!dockerRequestAllowed("GET", "/v1.41/secrets"));
    try std.testing.expect(!dockerRequestAllowed("GET", "/v1.41/secrets/foo"));
    try std.testing.expect(!dockerRequestAllowed("GET", "/v1.41/configs"));
    try std.testing.expect(!dockerRequestAllowed("GET", "/v1.41/swarm"));
}

test "docker socket candidates follow install-mode precedence" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = std.process.Environ.Map.init(arena);

    // Bare Linux package install: only the system path.
    {
        const got = try dockerSocketCandidates(arena, &env);
        try std.testing.expectEqual(@as(usize, 1), got.len);
        try std.testing.expectEqualStrings("/var/run/docker.sock", got[0]);
    }

    // Docker Desktop on macOS: HOME path precedes the (absent) system one.
    try env.put("HOME", "/Users/al");
    {
        const got = try dockerSocketCandidates(arena, &env);
        try std.testing.expectEqual(@as(usize, 2), got.len);
        try std.testing.expectEqualStrings("/Users/al/.docker/run/docker.sock", got[0]);
        try std.testing.expectEqualStrings("/var/run/docker.sock", got[1]);
    }

    // Rootless Linux: XDG runtime dir wins over the Desktop path.
    try env.put("XDG_RUNTIME_DIR", "/run/user/1000");
    {
        const got = try dockerSocketCandidates(arena, &env);
        try std.testing.expectEqualStrings("/run/user/1000/docker.sock", got[0]);
    }

    // An explicit unix:// DOCKER_HOST overrides everything; other schemes are
    // not speakable over a Unix socket and add no candidate.
    try env.put("DOCKER_HOST", "unix:///tmp/custom.sock");
    {
        const got = try dockerSocketCandidates(arena, &env);
        try std.testing.expectEqualStrings("/tmp/custom.sock", got[0]);
    }
    try env.put("DOCKER_HOST", "tcp://127.0.0.1:2375");
    {
        const got = try dockerSocketCandidates(arena, &env);
        try std.testing.expectEqualStrings("/run/user/1000/docker.sock", got[0]);
    }
}

test "custom headers with CRLF are rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var hdrs: [max_custom_headers]std.http.Header = undefined;
    const n = parseCustomHeaders(arena, "{\"X-Ok\":\"safe\",\"X-Bad\":\"val\\r\\nInjected: yes\"}", &hdrs);
    try std.testing.expectEqual(@as(u32, 1), n);
    try std.testing.expectEqualStrings("X-Ok", hdrs[0].name);
}

const ChatOp = struct {
    op: ?[]const u8 = null,
    room: ?[]const u8 = null,
    to: ?[]const u8 = null,
    text: ?[]const u8 = null,
    after: ?i64 = null,
    oldest: ?bool = null,
    on: ?bool = null,
    title: ?[]const u8 = null,
    todo: ?[]const u8 = null,
    // Slack-style extensions
    msg_id: ?[]const u8 = null,
    emoji: ?[]const u8 = null,
    topic: ?[]const u8 = null,
    thread_ts: ?[]const u8 = null,
};

/// A direct message remains an ordinary chatroom so history, persistence and
/// peer fan-out need no second transport. Sorting the two participants gives
/// both callers exactly one room name, regardless of who sends first.
fn directMessageRoom(arena: std.mem.Allocator, from_raw: []const u8, to_raw: []const u8) ![]const u8 {
    const from = std.mem.trim(u8, from_raw, " \t\r\n");
    const to = std.mem.trim(u8, to_raw, " \t\r\n");
    if (from.len == 0 or to.len == 0 or std.mem.eql(u8, from, to)) return error.InvalidDirectMessage;
    const pair = if (std.mem.lessThan(u8, from, to)) .{ from, to } else .{ to, from };
    return std.fmt.allocPrint(arena, "dm:{s}|{s}", pair);
}

/// The agent-facing history response is deliberately small to protect its
/// context budget; the operator surfaces (CLI/HTTP) page larger on purpose,
/// see `chatrooms.history_page_size` (PRD 0001). Read one extra record
/// internally so callers that must fold a complete log can tell whether
/// another page exists without guessing from a full final page.
const chat_history_page_size = 20;
/// Per-message text in the history JSON: enough to read, short enough that
/// a page of messages cannot blow the guest arena.
const chat_history_text_preview_bytes = 600;

/// ck_chat(op_json), chatroom operations for the chat_* tools, plus the
/// private-list todo_* ops (see below).
/// Input:  {"op":"send|history|rooms|subscribe|todo_add|todo_claim|todo_close|todo_list",
///          "room"|"to":..., "text":..., "after":..., "on":..., "title":..., "todo":...}
/// Output (in the host arena):
///   send:      {"ok":true,"ts":...,"id":"..."}
///   history:   {"ok":true,"messages":[{room,from,text,ts,id},...],"has_more":bool}
///              (newest-first; {"oldest":true} pages oldest-first for log
///              folds, extending through a shared boundary timestamp)
///   rooms:     {"ok":true,"rooms":[{room,messages,last_ts,last_from,last_text}],
///               "subscribed":["dev"]}
///   subscribe: {"ok":true,"rooms":["dev",...]}
/// Room-scoped todo_* ops were removed once the board covered that need
/// (ADR 0002, docs/adrs/0002-private-todos-vs-shared-board.md); a todo_* op
/// naming a "room" now fails with a pointer to the kanban_* tools below.
/// The only surviving todo_* path is a run's private list (sub-agent runs
/// only; src/agent/private_todos.zig): same op names and response shapes,
/// but in-memory, single-owner, and never fanned out.
/// The fan-out, subscription filter, and persistence all live host-side so
/// the WASM module stays thin; the descriptor config pins which op a tool is.
pub fn ckChat(caller: *zwasm.Caller, ptr: u32, len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const input = sliceOf(bytes, ptr, len) orelse return Err.invalid;

    var arena_state = std.heap.ArenaAllocator.init(h.sandbox.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = std.json.parseFromSliceLeaky(ChatOp, arena, input, .{ .ignore_unknown_fields = true }) catch {
        // Log only the length, never the input: chat payloads contain
        // user-generated messages (personal data).
        log.log(.warn, "[chat] json parse failed ({d} bytes)", .{input.len});
        return Err.invalid;
    };
    const op = parsed.op orelse return Err.invalid;
    if (!chatAccessAllowed(h.sandbox.tool_self_name, op)) {
        log.log(.warn, "[sandbox] ck_chat denied op '{s}' for tool '{s}'", .{ op, h.sandbox.tool_self_name });
        // Distinct from the chatrooms-module gate below so a guest (the board)
        // can tell "this tool is not allowlisted for chat" from "chatrooms is
        // switched off". Both are denials, but the fixes are different: a
        // tool-access denial is a code/version mismatch (rebuild clanker), not
        // a config the operator set.
        return Err.no_access;
    }

    // A todo_* op that names no room targets the run's private list (wired
    // only inside sub-agent runs). Routed before the chatrooms gate on
    // purpose: a private list is in-memory state on this one run, not a chat
    // message, so it neither needs the module nor touches its log.
    if (std.mem.startsWith(u8, op, "todo_") and (parsed.room == null or parsed.room.?.len == 0)) {
        const list = h.sandbox.private_todos orelse
            return h.writeResult(bytes, "{\"ok\":false,\"error\":\"this run has no private todo list attached; this is a host wiring error, not a room todo\"}");
        const out = private_todos_mod.applyTodoOp(list, arena, op, parsed.title, parsed.todo) catch return Err.too_large;
        return h.writeResult(bytes, out);
    }

    const cfg = h.sandbox.cfg orelse {
        log.log(.warn, "[chat] denied: no config in sandbox", .{});
        return Err.denied;
    };
    if (!cfg.modules.chatrooms) {
        log.log(.warn, "[chat] denied: chatrooms module disabled", .{});
        return Err.denied;
    }

    var out_buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out_buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    const base = h.sandbox.state_base_dir orelse std.Io.Dir.cwd();
    const state_dir = h.sandbox.state_dir;

    if (std.mem.eql(u8, op, "send")) {
        // `to` is the direct-message spelling. It resolves to the same
        // ordinary room on either participant, so senders never need to know
        // or manually order the `dm:<a>|<b>` convention.
        if (parsed.room != null and parsed.to != null) return Err.invalid;
        const room = if (parsed.room) |r|
            r
        else if (parsed.to) |to|
            directMessageRoom(arena, cfg.instance.name, to) catch return Err.invalid
        else
            return Err.invalid;
        const text = parsed.text orelse return Err.invalid;
        if (room.len == 0 or text.len == 0 or text.len > chatrooms_mod.max_text_len) return Err.invalid;
        const msg = chatrooms_mod.sendMessageOpts(base, h.sandbox.io, h.sandbox.gpa, arena, state_dir, cfg, h.sandbox.environ_map, room, text, parsed.thread_ts) catch |err| {
            log.log(.warn, "[chat] send failed: {s}", .{@errorName(err)});
            return Err.invalid;
        };
        s.beginObject() catch return Err.too_large;
        s.objectField("ok") catch return Err.too_large;
        s.write(true) catch return Err.too_large;
        s.objectField("ts") catch return Err.too_large;
        s.print("{d}", .{msg.ts}) catch return Err.too_large;
        s.objectField("id") catch return Err.too_large;
        s.write(msg.id) catch return Err.too_large;
        if (msg.thread_ts) |tts| {
            s.objectField("thread_ts") catch return Err.too_large;
            s.write(tts) catch return Err.too_large;
        }
        s.endObject() catch return Err.too_large;
        return h.writeResult(bytes, out_buf[0..w.end]);
    } else if (std.mem.eql(u8, op, "history")) {
        const room = parsed.room orelse return Err.invalid;
        const after = parsed.after orelse 0;
        // Two page shapes for two consumers: chat display wants the newest
        // messages; a log fold (the board) pages forward with `ts > after`
        // and must be handed the oldest first, or its cursor jumps past
        // everything older than the newest page and folds a partial log.
        var msgs: []const chatrooms_mod.Message = undefined;
        var has_more = false;
        if (parsed.oldest orelse false) {
            const asc = chatrooms_mod.readHistoryAsc(base, h.sandbox.io, arena, state_dir, cfg, room, after, chat_history_page_size) catch return Err.invalid;
            msgs = asc.msgs;
            has_more = asc.has_more;
        } else {
            const page = chatrooms_mod.readHistory(base, h.sandbox.io, arena, state_dir, cfg, room, after, chat_history_page_size + 1) catch return Err.invalid;
            has_more = page.len > chat_history_page_size;
            msgs = page[0..@min(page.len, chat_history_page_size)];
        }
        s.beginObject() catch return Err.too_large;
        s.objectField("ok") catch return Err.too_large;
        s.write(true) catch return Err.too_large;
        s.objectField("messages") catch return Err.too_large;
        s.beginArray() catch return Err.too_large;
        for (msgs) |m| {
            s.beginObject() catch return Err.too_large;
            s.objectField("room") catch return Err.too_large;
            s.write(m.room) catch return Err.too_large;
            s.objectField("from") catch return Err.too_large;
            s.write(m.from) catch return Err.too_large;
            s.objectField("text") catch return Err.too_large;
            s.write(utf8.cap(m.text, chat_history_text_preview_bytes)) catch return Err.too_large;
            s.objectField("ts") catch return Err.too_large;
            s.print("{d}", .{m.ts}) catch return Err.too_large;
            s.objectField("id") catch return Err.too_large;
            s.write(m.id) catch return Err.too_large;
            if (m.thread_ts) |tts| {
                s.objectField("thread_ts") catch return Err.too_large;
                s.write(tts) catch return Err.too_large;
            }
            if (m.reactions) |reactions| {
                s.objectField("reactions") catch return Err.too_large;
                s.write(reactions) catch return Err.too_large;
            }
            if (m.edited) |ed| {
                s.objectField("edited") catch return Err.too_large;
                s.print("{d}", .{ed}) catch return Err.too_large;
            }
            if (m.deleted orelse false) {
                s.objectField("deleted") catch return Err.too_large;
                s.write(true) catch return Err.too_large;
            }
            s.endObject() catch return Err.too_large;
        }
        s.endArray() catch return Err.too_large;
        s.objectField("has_more") catch return Err.too_large;
        s.write(has_more) catch return Err.too_large;
        s.endObject() catch return Err.too_large;
        return h.writeResult(bytes, out_buf[0..w.end]);
    } else if (std.mem.eql(u8, op, "rooms")) {
        const rooms = chatrooms_mod.listRooms(base, h.sandbox.io, arena, state_dir, cfg) catch return Err.invalid;
        const subs = chatrooms_mod.subscribedRooms(base, h.sandbox.io, arena, state_dir, cfg) catch return Err.invalid;
        // Load room metadata for topics
        const meta = chatrooms_mod.loadMeta(base, h.sandbox.io, arena, state_dir) catch std.json.ArrayHashMap(chatrooms_mod.RoomMeta){};
        s.beginObject() catch return Err.too_large;
        s.objectField("ok") catch return Err.too_large;
        s.write(true) catch return Err.too_large;
        s.objectField("rooms") catch return Err.too_large;
        s.beginArray() catch return Err.too_large;
        for (rooms) |r| {
            s.beginObject() catch return Err.too_large;
            s.objectField("room") catch return Err.too_large;
            s.write(r.room) catch return Err.too_large;
            s.objectField("messages") catch return Err.too_large;
            s.print("{d}", .{r.messages}) catch return Err.too_large;
            s.objectField("last_ts") catch return Err.too_large;
            s.print("{d}", .{r.last_ts}) catch return Err.too_large;
            s.objectField("last_from") catch return Err.too_large;
            s.write(r.last_from) catch return Err.too_large;
            s.objectField("last_text") catch return Err.too_large;
            s.write(r.last_text) catch return Err.too_large;
            if (meta.map.get(r.room)) |rm| {
                if (rm.topic) |t| {
                    s.objectField("topic") catch return Err.too_large;
                    s.write(t) catch return Err.too_large;
                }
            }
            s.endObject() catch return Err.too_large;
        }
        s.endArray() catch return Err.too_large;
        s.objectField("subscribed") catch return Err.too_large;
        s.beginArray() catch return Err.too_large;
        for (subs) |sub| s.write(sub) catch return Err.too_large;
        s.endArray() catch return Err.too_large;
        s.endObject() catch return Err.too_large;
        return h.writeResult(bytes, out_buf[0..w.end]);
    } else if (std.mem.eql(u8, op, "subscribe")) {
        const room = parsed.room orelse return Err.invalid;
        const on = parsed.on orelse true;
        chatrooms_mod.subscribe(base, h.sandbox.io, h.sandbox.gpa, arena, state_dir, room, on) catch return Err.invalid;
        const subs = chatrooms_mod.subscribedRooms(base, h.sandbox.io, arena, state_dir, cfg) catch return Err.invalid;
        s.beginObject() catch return Err.too_large;
        s.objectField("ok") catch return Err.too_large;
        s.write(true) catch return Err.too_large;
        s.objectField("rooms") catch return Err.too_large;
        s.beginArray() catch return Err.too_large;
        for (subs) |sub| s.write(sub) catch return Err.too_large;
        s.endArray() catch return Err.too_large;
        s.endObject() catch return Err.too_large;
        return h.writeResult(bytes, out_buf[0..w.end]);
    } else if (std.mem.eql(u8, op, "react")) {
        const msg_id = parsed.msg_id orelse return Err.invalid;
        const emoji = parsed.emoji orelse return Err.invalid;
        if (emoji.len == 0 or emoji.len > chatrooms_mod.max_emoji_len) return Err.invalid;
        const was_added = chatrooms_mod.toggleReaction(
            base,
            h.sandbox.io,
            h.sandbox.gpa,
            arena,
            state_dir,
            cfg,
            msg_id,
            emoji,
            cfg.instance.name,
        ) catch |err| switch (err) {
            error.NotFound => return h.writeResult(bytes, "{\"ok\":false,\"error\":\"no such message\"}"),
            else => {
                log.log(.warn, "[chat] react failed: {s}", .{@errorName(err)});
                return Err.invalid;
            },
        };
        s.beginObject() catch return Err.too_large;
        s.objectField("ok") catch return Err.too_large;
        s.write(true) catch return Err.too_large;
        s.objectField("action") catch return Err.too_large;
        s.write(if (was_added) "added" else "removed") catch return Err.too_large;
        s.endObject() catch return Err.too_large;
        return h.writeResult(bytes, out_buf[0..w.end]);
    } else if (std.mem.eql(u8, op, "edit")) {
        const msg_id = parsed.msg_id orelse return Err.invalid;
        const new_text = parsed.text orelse return Err.invalid;
        if (new_text.len == 0 or new_text.len > chatrooms_mod.max_text_len) return Err.invalid;
        const msg = chatrooms_mod.editMessage(
            base,
            h.sandbox.io,
            h.sandbox.gpa,
            arena,
            state_dir,
            cfg,
            msg_id,
            new_text,
            cfg.instance.name,
        ) catch |err| switch (err) {
            error.NotFound => return h.writeResult(bytes, "{\"ok\":false,\"error\":\"no such message\"}"),
            error.NotOwner => return h.writeResult(bytes, "{\"ok\":false,\"error\":\"not your message\"}"),
            else => {
                log.log(.warn, "[chat] edit failed: {s}", .{@errorName(err)});
                return Err.invalid;
            },
        };
        s.beginObject() catch return Err.too_large;
        s.objectField("ok") catch return Err.too_large;
        s.write(true) catch return Err.too_large;
        s.objectField("id") catch return Err.too_large;
        s.write(msg.id) catch return Err.too_large;
        s.objectField("edited") catch return Err.too_large;
        s.print("{d}", .{msg.edited.?}) catch return Err.too_large;
        s.endObject() catch return Err.too_large;
        return h.writeResult(bytes, out_buf[0..w.end]);
    } else if (std.mem.eql(u8, op, "delete")) {
        const msg_id = parsed.msg_id orelse return Err.invalid;
        chatrooms_mod.deleteMessage(
            base,
            h.sandbox.io,
            h.sandbox.gpa,
            arena,
            state_dir,
            cfg,
            msg_id,
            cfg.instance.name,
        ) catch |err| switch (err) {
            error.NotFound => return h.writeResult(bytes, "{\"ok\":false,\"error\":\"no such message\"}"),
            error.NotOwner => return h.writeResult(bytes, "{\"ok\":false,\"error\":\"not your message\"}"),
            else => {
                log.log(.warn, "[chat] delete failed: {s}", .{@errorName(err)});
                return Err.invalid;
            },
        };
        s.beginObject() catch return Err.too_large;
        s.objectField("ok") catch return Err.too_large;
        s.write(true) catch return Err.too_large;
        s.endObject() catch return Err.too_large;
        return h.writeResult(bytes, out_buf[0..w.end]);
    } else if (std.mem.eql(u8, op, "set_topic")) {
        const room = parsed.room orelse return Err.invalid;
        const new_topic = parsed.topic orelse return Err.invalid;
        if (new_topic.len > chatrooms_mod.max_topic_len) return Err.invalid;
        chatrooms_mod.setTopic(base, h.sandbox.io, h.sandbox.gpa, arena, state_dir, room, new_topic) catch |err| {
            log.log(.warn, "[chat] set_topic failed: {s}", .{@errorName(err)});
            return Err.invalid;
        };
        s.beginObject() catch return Err.too_large;
        s.objectField("ok") catch return Err.too_large;
        s.write(true) catch return Err.too_large;
        s.endObject() catch return Err.too_large;
        return h.writeResult(bytes, out_buf[0..w.end]);
    } else if (std.mem.eql(u8, op, "get_topic")) {
        const room = parsed.room orelse return Err.invalid;
        const topic_val = chatrooms_mod.getTopic(base, h.sandbox.io, arena, state_dir, room) catch |err| {
            log.log(.warn, "[chat] get_topic failed: {s}", .{@errorName(err)});
            return Err.invalid;
        };
        s.beginObject() catch return Err.too_large;
        s.objectField("ok") catch return Err.too_large;
        s.write(true) catch return Err.too_large;
        s.objectField("topic") catch return Err.too_large;
        s.write(topic_val orelse "") catch return Err.too_large;
        s.endObject() catch return Err.too_large;
        return h.writeResult(bytes, out_buf[0..w.end]);
    } else if (std.mem.eql(u8, op, "pin")) {
        const msg_id = parsed.msg_id orelse return Err.invalid;
        const room = parsed.room orelse return Err.invalid;
        const was_pinned = chatrooms_mod.togglePin(base, h.sandbox.io, h.sandbox.gpa, arena, state_dir, room, msg_id) catch |err| {
            log.log(.warn, "[chat] pin failed: {s}", .{@errorName(err)});
            return Err.invalid;
        };
        s.beginObject() catch return Err.too_large;
        s.objectField("ok") catch return Err.too_large;
        s.write(true) catch return Err.too_large;
        s.objectField("action") catch return Err.too_large;
        s.write(if (was_pinned) "pinned" else "unpinned") catch return Err.too_large;
        s.endObject() catch return Err.too_large;
        return h.writeResult(bytes, out_buf[0..w.end]);
    } else if (std.mem.eql(u8, op, "get_pins")) {
        const room = parsed.room orelse return Err.invalid;
        const pins = chatrooms_mod.getPins(base, h.sandbox.io, arena, state_dir, room) catch |err| {
            log.log(.warn, "[chat] get_pins failed: {s}", .{@errorName(err)});
            return Err.invalid;
        };
        s.beginObject() catch return Err.too_large;
        s.objectField("ok") catch return Err.too_large;
        s.write(true) catch return Err.too_large;
        s.objectField("pins") catch return Err.too_large;
        s.beginArray() catch return Err.too_large;
        if (pins) |pin_list| {
            for (pin_list) |p| s.write(p) catch return Err.too_large;
        }
        s.endArray() catch return Err.too_large;
        s.endObject() catch return Err.too_large;
        return h.writeResult(bytes, out_buf[0..w.end]);
    } else if (std.mem.startsWith(u8, op, "todo_")) {
        // A room todo was a second, thinner copy of a board card: a title, a
        // claim, a closed flag, folded out of the same room log the board now
        // folds. One concept, so one implementation, and it is the board tool;
        // folding a log is application logic, while this host's job is the
        // append, the fan-out and the subscription filter. The branch near the
        // top of this function still handles a todo_* op with no room, which is
        // the run's own private list and genuinely a different thing.
        return h.writeResult(bytes, "{\"ok\":false,\"error\":\"room todo lists are board cards now: use kanban_add, kanban_move, kanban_claim or kanban_list. They fold the same room log, so nothing was lost, and a card also carries subtasks, dependencies, a work log and a cost.\"}");
    }
    log.log(.warn, "[chat] unknown op '{s}'", .{op});
    return Err.invalid;
}

fn chatAccessAllowed(tool_name: []const u8, op: []const u8) bool {
    // The board is one guest (board.wasm) behind the multiplexed `kanban`
    // entry plus the public `kanban_*` names, and it needs two ops rather
    // than one: it replicates each card into its room with "send" and folds
    // that room's log back with "history" on every read. "board" remains
    // as an alias so an older tool_self_name still reaches the room.
    if (std.mem.eql(u8, tool_name, "kanban") or
        std.mem.eql(u8, tool_name, "board") or
        std.mem.startsWith(u8, tool_name, "kanban_"))
        return std.mem.eql(u8, op, "send") or std.mem.eql(u8, op, "history");
    // The janitor announces what it pruned into the room. Like the board it
    // ignores a failed chat call, so being denied here cost it its
    // announcements silently rather than failing the prune.
    if (std.mem.eql(u8, tool_name, "janitor")) return std.mem.eql(u8, op, "send");

    const allowed_ops: ?[]const []const u8 = if (std.mem.eql(u8, tool_name, "chat_send") or
        std.mem.eql(u8, tool_name, "chat_dm"))
        &.{"send"}
    else if (std.mem.eql(u8, tool_name, "chat_history"))
        &.{"history"}
    else if (std.mem.eql(u8, tool_name, "chat_rooms"))
        &.{"rooms"}
    else if (std.mem.eql(u8, tool_name, "chat_subscribe"))
        &.{"subscribe"}
    else if (std.mem.eql(u8, tool_name, "chat_react"))
        &.{"react"}
    else if (std.mem.eql(u8, tool_name, "chat_edit"))
        &.{"edit"}
    else if (std.mem.eql(u8, tool_name, "chat_delete"))
        &.{"delete"}
    else if (std.mem.eql(u8, tool_name, "chat_topic"))
        &.{ "set_topic", "get_topic" }
    else if (std.mem.eql(u8, tool_name, "chat_pin"))
        &.{ "pin", "get_pins" }
    else if (std.mem.eql(u8, tool_name, "todo_add"))
        &.{"todo_add"}
    else if (std.mem.eql(u8, tool_name, "todo_claim"))
        &.{"todo_claim"}
    else if (std.mem.eql(u8, tool_name, "todo_close"))
        &.{"todo_close"}
    else if (std.mem.eql(u8, tool_name, "todo_list"))
        &.{"todo_list"}
    else
        null;
    if (allowed_ops) |ops| {
        for (ops) |allowed| {
            if (std.mem.eql(u8, allowed, op)) return true;
        }
    }
    return false;
}

/// ck_publish(json) posts one event onto the serve live bus. The payload is
/// the `data` value; the host stamps `t:"plugin"` and `from` as the calling
/// tool's name so a guest cannot spoof chat/run/metrics or another tool.
/// Denied unless the descriptor sets `"live_publish": true`.
pub fn ckPublish(caller: *zwasm.Caller, ptr: u32, len: u32) u32 {
    const h = getHost(caller);
    if (!h.sandbox.live_publish or h.sandbox.tool_self_name.len == 0) {
        log.log(.warn, "[sandbox] ck_publish denied for tool '{s}'", .{h.sandbox.tool_self_name});
        return Err.denied;
    }
    const bytes = memBytes(caller) orelse return Err.invalid;
    const raw = sliceOf(bytes, ptr, len) orelse return Err.invalid;
    if (raw.len == 0 or raw.len > live_mod.event_cap / 2) return Err.too_large;

    var arena_state = std.heap.ArenaAllocator.init(h.sandbox.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Refuse non-JSON so a subscriber never sees a broken `data` splice.
    // The value is then re-encoded rather than spliced raw: a guest can hand
    // over a valid document that still contains literal newlines (JSON
    // whitespace between tokens), and a raw `\n` inside the SSE `data:` line
    // terminates the frame, letting the guest inject fake `event:`/`data:`
    // pairs and spoof topics (chat/mesh/run/metrics) the host reserves to
    // itself. Compact re-encoding is newline-free and semantically identical.
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return Err.invalid;
    var w: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &w.writer, .options = .{ .emit_null_optional_fields = false } };
    s.write(parsed) catch return Err.invalid;
    const encoded = w.written();
    if (encoded.len == 0 or encoded.len > live_mod.event_cap / 2) return Err.too_large;
    live_mod.notePlugin(h.sandbox.tool_self_name, encoded);
    return Err.ok;
}

/// ck_stats() returns the host-side aggregate of token_stats.jsonl to the
/// model_stats guest. Shipping every raw record through the 1 MiB guest arena
/// fails once the log has a few thousand lines; the table itself is a handful
/// of (provider, model) rows. The native side resolves the state directory,
/// enforces the module switch, and aggregates. The guest renders.
pub fn ckStats(caller: *zwasm.Caller) u32 {
    const h = getHost(caller);
    if (!std.mem.eql(u8, h.sandbox.tool_self_name, "model_stats")) return Err.denied;
    const bytes = memBytes(caller) orelse return Err.invalid;

    const cfg = h.sandbox.cfg orelse return Err.denied;
    if (!cfg.modules.token_stats) {
        log.log(.warn, "[stats] denied: token_stats module disabled", .{});
        return Err.denied;
    }

    var arena_state = std.heap.ArenaAllocator.init(h.sandbox.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = h.sandbox.state_base_dir orelse std.Io.Dir.cwd();
    const state_dir = h.sandbox.state_dir;

    const stats = token_stats.aggregate(base, h.sandbox.io, h.sandbox.gpa, arena, state_dir) catch |err| {
        log.log(.warn, "[stats] read failed: {s}", .{@errorName(err)});
        return Err.invalid;
    };
    const json = token_stats.statsJSON(arena, stats, token_stats.totals(stats)) catch return Err.too_large;
    return h.writeResult(bytes, json);
}

/// Most bytes of the improve ledger `ck_improve_history` hands over. The guest
/// arena is 1 MiB (`host_arena_cap` in tools/zig/lib.zig) and the guest renders
/// only the newest few records, so a ledger grown past this still answers
/// instead of failing on size. Cut on a line boundary, or the oldest record in
/// the window arrives torn and is dropped by the guest's parse.
const improve_history_cap = 256 * 1024;

/// ck_improve_history() hands the improve ledger (`state/improvements.jsonl`)
/// to the `improve_history` guest over a host channel instead of through the
/// sandbox filesystem.
///
/// The guest used to read the path itself, granted by name in
/// `fs_prefixes`. That grant could not work in a `clanker improve-self`
/// worktree, which is the only place the tool has anything to say:
/// `linkSharedState` (src/improve/worktree.zig) makes that exact path a symlink
/// to the checkout's real file, and `safeJoinSecure`'s no-follow walk stats the
/// granted LEAF as well as the directories above it, so it was refused with
/// PathOutsideSandbox. The guest turns any read failure into "no history yet",
/// so the refusal surfaced as an empty history rather than an error: every
/// improve-self run was told it had never attempted anything, which is the one
/// answer that makes the loop repeat its own failures.
///
/// Reading here honours the existing rule rather than working around it. That
/// rule is already written down in `casLockPath` above -- a symlink under
/// `state/` is safe only where the HOST reads the path -- and this is the host,
/// whose native I/O follows the link exactly as the engine's own History does.
/// Widening the guest's reach instead would have meant either
/// `sandbox_follow_symlinks`, which ADR 0017 says nothing may set implicitly,
/// or routing improve-self through `shared_root`, which would also send
/// `state/learnings.md` to the checkout and break the one-way promotion the
/// improve worktree is built around.
pub fn ckImproveHistory(caller: *zwasm.Caller) u32 {
    const h = getHost(caller);
    if (!std.mem.eql(u8, h.sandbox.tool_self_name, "improve_history")) return Err.denied;
    const bytes = memBytes(caller) orelse return Err.invalid;

    var arena_state = std.heap.ArenaAllocator.init(h.sandbox.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = h.sandbox.state_base_dir orelse std.Io.Dir.cwd();
    const state_dir = std.mem.trimEnd(u8, if (h.sandbox.state_dir.len > 0) h.sandbox.state_dir else "state", "/");
    const path = std.fmt.allocPrint(arena, "{s}/improvements.jsonl", .{state_dir}) catch return Err.too_large;

    // A ledger that is not there yet is not an error: a checkout that has
    // never run improve-self has no file, and "no history yet" is the right
    // answer for it. Only a path that exists and cannot be read is a failure,
    // and that one must not be reported as an empty history.
    const raw = base.readFileAlloc(h.sandbox.io, path, arena, .limited(1 << 24)) catch |err| switch (err) {
        error.FileNotFound => return Err.not_found,
        else => {
            log.log(.warn, "[improve_history] could not read {s}: {s}", .{ path, @errorName(err) });
            return Err.invalid;
        },
    };
    return h.writeResult(bytes, tail_util.onLineBoundary(raw, improve_history_cap));
}

/// Maximum number of custom headers a tool may send per request.
const max_custom_headers = 16;

/// Parses a JSON object of string key-value pairs into extra HTTP headers.
/// Returns the number of headers written into `out`. Malformed input or
/// non-string values are silently skipped so the request still goes through
/// with whatever headers were valid.
fn parseCustomHeaders(
    arena: std.mem.Allocator,
    hdr_json: ?[]const u8,
    out: *[max_custom_headers]std.http.Header,
) u32 {
    const json = hdr_json orelse return 0;
    if (json.len == 0) return 0;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return 0;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return 0,
    };
    var count: u32 = 0;
    for (obj.keys(), obj.values()) |key, val| {
        if (count >= max_custom_headers) break;
        if (val != .string) continue;
        if (key.len == 0) continue;
        if (headerHasCrlf(key) or headerHasCrlf(val.string)) continue;
        out[count] = .{ .name = key, .value = val.string };
        count += 1;
    }
    return count;
}

fn headerHasCrlf(s: []const u8) bool {
    return std.mem.findAny(u8, s, "\r\n") != null;
}

/// Whether a tool may run `cmd`.
///
/// An empty list used to fall back to a fixed set of twelve commands - git,
/// find, cat and the rest - so a descriptor that declared nothing inherited
/// more authority than most that declare something. Naming what you run costs
/// one line, and every shipped tool that execs now does.
pub fn execAllowed(allow: []const []const u8, cmd: []const u8) bool {
    for (allow) |c| {
        if (std.mem.eql(u8, cmd, c)) return true;
    }
    return false;
}

/// Maps the guest's wire-format method code to a std.http.Method, or null for
/// any code the ck_http_fetch ABI does not define.
fn httpMethodFromCode(method: u32) ?std.http.Method {
    return switch (method) {
        0 => .GET,
        1 => .POST,
        2 => .PUT,
        3 => .DELETE,
        4 => .PATCH,
        5 => .HEAD,
        else => null,
    };
}

/// Whether `hostname` is granted by a network allowlist. Exact hostnames match
/// only themselves; an entry may be a glob pattern like `*.example.com` or
/// `sub?.example.com`, mirroring exec_pattern_allow (a bare `*` matches every
/// host, so `"*"` opens all web access). Exact entries from tool manifests and
/// configuredHosts carry no glob characters, so globMatch treats them exactly.
fn networkAllowed(allow: []const []const u8, hostname: []const u8) bool {
    for (allow) |a| {
        if (globMatch(a, hostname)) return true;
    }
    return false;
}

/// Wall-clock ceiling for one guest HTTP request.
///
/// `std.http.Client` has no read timeout of its own (`ConnectTcpOptions.timeout`
/// is declared and never referenced -- see `client.Abort`), so a host that is
/// allowlisted, accepts the connection and then says nothing blocks the calling
/// thread forever. That thread is the agent's turn: an unbounded `web_fetch`
/// does not fail a tool call, it ends the run with no error to classify. One
/// minute is well past any page a tool has business fetching and well short of
/// "never".
const http_timeout_ms: u32 = 60_000;

/// What one guest HTTP request did, kept apart from `Err.network` so the log
/// and the guest can tell a timeout, an oversized body and a refused connection
/// from each other. Collapsing all three into one code is why a wedged fetch
/// used to be indistinguishable from a DNS failure in the operator's log.
const HttpOutcome = union(enum) {
    /// Bytes written into the caller's response buffer.
    ok: usize,
    /// Response arrived with a >= 400 status.
    status: u16,
    /// Body outgrew `max_http_bytes`; the fixed writer refused the rest.
    too_large,
    /// Transport failure, carrying `@errorName` of the cause.
    transport: []const u8,
};

/// The arguments `httpFetchTask` needs, bundled so it can be handed to
/// `io.concurrent` as a single value.
const HttpFetchArgs = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    url: []const u8,
    method: std.http.Method,
    payload: ?[]const u8,
    extra_headers: []const std.http.Header,
    /// Caller-owned; stays alive until the task is joined or cancelled.
    out: []u8,
};

/// The fetch half of `httpImpl`, as a concurrent task so the caller can put a
/// deadline on it. Every exit sets `done`, or the waiter is never woken.
///
/// The client is created *here* rather than passed in: `abort` has to point at
/// a live client for the whole blocking read and at nothing once it is torn
/// down, and owning both in one scope is what makes that pairing checkable.
fn httpFetchTask(args: HttpFetchArgs, abort: *client.Abort, done: *std.Io.Event) HttpOutcome {
    defer done.set(args.io);

    var http: std.http.Client = .{ .allocator = args.gpa, .io = args.io };
    defer http.deinit();
    abort.arm(args.io, &http);
    defer abort.disarm(args.io);

    var w: std.Io.Writer = .fixed(args.out);
    const result = http.fetch(.{
        .location = .{ .url = args.url },
        .method = args.method,
        .payload = args.payload,
        .headers = .{ .user_agent = .{ .override = "clanker-tool/" ++ build_options.version } },
        .extra_headers = args.extra_headers,
        .response_writer = &w,
        // network_allow only checks `hostname` in httpImpl, once, against the
        // requested URL. std.http.Client auto-follows redirects by default,
        // and a redirect target is never re-checked against that allowlist;
        // an allowed host could 302 the sandboxed tool to an internal address
        // (e.g. a cloud metadata IP) the allowlist exists to block. Refusing
        // redirects outright keeps every request confined to the host that
        // was actually checked.
        .redirect_behavior = .not_allowed,
    }) catch |err| return switch (err) {
        // The only writer is the fixed buffer above, so a write failure is
        // always "the body did not fit", never a socket problem.
        error.WriteFailed => .too_large,
        else => .{ .transport = @errorName(err) },
    };

    const status = @intFromEnum(result.status);
    if (status >= 400) return .{ .status = status };
    return .{ .ok = w.end };
}

fn httpImpl(h: *Host, mem_bytes: []u8, method: u32, url: []const u8, body: []const u8, hdr_json: ?[]const u8) u32 {
    const uri = std.Uri.parse(url) catch return Err.invalid;
    const hostname = switch (uri.host orelse return Err.invalid) {
        .raw => |hh| hh,
        .percent_encoded => |hh| hh,
    };

    const allowed = networkAllowed(h.sandbox.network_allow, hostname);
    if (!allowed) {
        log.log(.warn, "[sandbox] tool denied network access to '{s}'", .{hostname});
        return Err.denied;
    }

    var arena_state = std.heap.ArenaAllocator.init(h.sandbox.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var custom_hdrs: [max_custom_headers]std.http.Header = undefined;
    const n_custom = parseCustomHeaders(arena, hdr_json, &custom_hdrs);

    const resp_buf = h.sandbox.gpa.alloc(u8, h.sandbox.max_http_bytes) catch return Err.too_large;
    defer h.sandbox.gpa.free(resp_buf);

    const req_method = httpMethodFromCode(method) orelse return Err.invalid;
    const has_body = req_method == .POST or req_method == .PUT or req_method == .PATCH;
    const args: HttpFetchArgs = .{
        .io = h.sandbox.io,
        .gpa = h.sandbox.gpa,
        .url = url,
        .method = req_method,
        .payload = if (has_body) body else null,
        .extra_headers = if (n_custom > 0) custom_hdrs[0..n_custom] else &.{},
        .out = resp_buf,
    };

    const outcome = httpWithTimeout(h.sandbox.io, args, http_timeout_ms) orelse {
        log.log(.warn, "[sandbox] http request to '{s}' timed out after {d}ms", .{ url, http_timeout_ms });
        return Err.network;
    };

    return switch (outcome) {
        .ok => |n| h.writeResult(mem_bytes, resp_buf[0..n]),
        .status => |code| blk: {
            log.log(.warn, "[sandbox] http request to '{s}' failed with status {d}", .{ url, code });
            break :blk Err.network;
        },
        .too_large => blk: {
            log.log(.warn, "[sandbox] http response from '{s}' exceeded max_http_bytes ({d})", .{ url, h.sandbox.max_http_bytes });
            break :blk Err.too_large;
        },
        .transport => |name| blk: {
            log.log(.warn, "[sandbox] http request to '{s}' failed: {s}", .{ url, name });
            break :blk Err.network;
        },
    };
}

/// Runs `httpFetchTask` under a wall-clock ceiling, returning null when the
/// budget is spent. On timeout the armed connections are shut down *before*
/// the task is cancelled: `Io.Future.cancel` cannot rescue a thread parked in
/// a blocking read on an established connection and would wedge the canceller
/// alongside it, whereas `shutdown(2)` makes that read return end-of-stream so
/// the task unwinds on its own (see `client.Abort`).
fn httpWithTimeout(io: std.Io, args: HttpFetchArgs, timeout_ms: u32) ?HttpOutcome {
    var abort: client.Abort = .{};
    var done: std.Io.Event = .unset;

    if (timeout_ms == 0) return httpFetchTask(args, &abort, &done);

    var future = io.concurrent(httpFetchTask, .{ args, &abort, &done }) catch |err| {
        // No worker to run it on. Refuse rather than falling back to an
        // unbounded call: an ungoverned wait is the failure being prevented.
        log.log(.warn, "[sandbox] http request to '{s}' could not start: {s}", .{ args.url, @errorName(err) });
        return .{ .transport = @errorName(err) };
    };
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{
        .clock = .awake,
        .raw = .{ .nanoseconds = @as(i96, timeout_ms) * std.time.ns_per_ms },
    });
    while (!done.isSet()) {
        done.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
            // Spurious wakeups report Timeout too, so the deadline decides
            // whether the budget is really spent, not this return.
            error.Timeout => {
                if (done.isSet()) break;
                if (deadline.durationFromNow(io).raw.nanoseconds > 0) continue;
                abort.trigger(io);
                // cancel() joins the task, so nothing is left writing into the
                // caller's response buffer or header slice after this returns.
                _ = future.cancel(io);
                return null;
            },
            error.Canceled => {
                abort.trigger(io);
                _ = future.cancel(io);
                return null;
            },
        };
    }
    return future.await(io);
}

test "httpWithTimeout gives up on a host that accepts and never answers" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The failure this exists to prevent: a host that is allowlisted, completes
    // the TCP handshake, and then sends nothing. The kernel's backlog accepts
    // for us, so `fetch` gets a live connection and blocks in a read that no
    // amount of `Io.Future.cancel` can rescue. Never accepting in this test is
    // deliberate -- an accept loop would only add a thread that must be joined.
    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    var out: [1024]u8 = undefined;
    const started = std.Io.Timestamp.now(io, .awake);
    const outcome = httpWithTimeout(io, .{
        .io = io,
        .gpa = allocator,
        .url = url,
        .method = .GET,
        .payload = null,
        .extra_headers = &.{},
        .out = &out,
    }, 300);
    const elapsed_ms = @divTrunc(started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds, std.time.ns_per_ms);

    // Null is the timeout, and it has to arrive on the budget rather than on
    // the OS connect timeout (~75s) that unbounded callers used to wait out.
    try std.testing.expect(outcome == null);
    try std.testing.expect(elapsed_ms < 30_000);
}

test "parseCustomHeaders parses valid JSON object into headers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hdrs: [max_custom_headers]std.http.Header = undefined;

    // Valid object with two string values.
    const n = parseCustomHeaders(arena, "{\"Authorization\":\"Bearer tok123\",\"Content-Type\":\"application/json\"}", &hdrs);
    try std.testing.expectEqual(@as(u32, 2), n);
    // Check both headers are present (order from JSON object is not guaranteed,
    // but the std JSON parser preserves insertion order).
    var found_auth = false;
    var found_ct = false;
    for (hdrs[0..n]) |hdr| {
        if (std.mem.eql(u8, hdr.name, "Authorization") and std.mem.eql(u8, hdr.value, "Bearer tok123")) found_auth = true;
        if (std.mem.eql(u8, hdr.name, "Content-Type") and std.mem.eql(u8, hdr.value, "application/json")) found_ct = true;
    }
    try std.testing.expect(found_auth);
    try std.testing.expect(found_ct);
}

test "directMessageRoom canonicalizes the two participants" {
    const arena = std.testing.allocator;
    const alice_to_bob = try directMessageRoom(arena, "alice", "bob");
    defer arena.free(alice_to_bob);
    const bob_to_alice = try directMessageRoom(arena, "bob", "alice");
    defer arena.free(bob_to_alice);
    try std.testing.expectEqualStrings("dm:alice|bob", alice_to_bob);
    try std.testing.expectEqualStrings(alice_to_bob, bob_to_alice);

    try std.testing.expectError(error.InvalidDirectMessage, directMessageRoom(arena, "alice", "alice"));
    try std.testing.expectError(error.InvalidDirectMessage, directMessageRoom(arena, "alice", "  \t"));
}

test "parseCustomHeaders handles null, empty, non-object, and non-string values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var hdrs: [max_custom_headers]std.http.Header = undefined;

    // null input.
    try std.testing.expectEqual(@as(u32, 0), parseCustomHeaders(arena, null, &hdrs));
    // Empty string.
    try std.testing.expectEqual(@as(u32, 0), parseCustomHeaders(arena, "", &hdrs));
    // Non-object JSON.
    try std.testing.expectEqual(@as(u32, 0), parseCustomHeaders(arena, "[1,2]", &hdrs));
    // Object with non-string value, those entries are skipped.
    const n2 = parseCustomHeaders(arena, "{\"X-Good\":\"yes\",\"X-Bad\":42}", &hdrs);
    try std.testing.expectEqual(@as(u32, 1), n2);
    try std.testing.expectEqualStrings("X-Good", hdrs[0].name);
    try std.testing.expectEqualStrings("yes", hdrs[0].value);
    // Invalid JSON.
    try std.testing.expectEqual(@as(u32, 0), parseCustomHeaders(arena, "{not json", &hdrs));
}

/// Lists the entries under an allowed directory as a JSON string array
/// written to the host arena. Directory names carry a trailing '/' so tools
/// can tell them from files (and recurse); anything that is neither a file
/// nor a directory is skipped. Enforces the same fs_prefixes policy as
/// ck_fs_read.
pub fn ckFsList(caller: *zwasm.Caller, path_ptr: u32, path_len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const path = sliceOf(bytes, path_ptr, path_len) orelse return Err.invalid;
    const full = safeJoinSecure(h.sandbox, path) catch return Err.denied;
    defer h.sandbox.gpa.free(full);

    var dir = std.Io.Dir.cwd().openDir(h.sandbox.io, full, .{ .iterate = true }) catch return Err.not_found;
    defer dir.close(h.sandbox.io);

    const buf = h.sandbox.gpa.alloc(u8, h.sandbox.max_fs_bytes) catch return Err.too_large;
    defer h.sandbox.gpa.free(buf);
    var w: std.Io.Writer = .fixed(buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    s.beginArray() catch return Err.too_large;
    var it = dir.iterate();
    while (it.next(h.sandbox.io) catch null) |entry| {
        if (entry.kind != .file and entry.kind != .directory) continue;
        if (entry.name.len == 0) continue;
        // A huge directory must not fail the whole listing: stop at the cap
        // and return a truncated (but still valid JSON) array instead of
        // Err.too_large, so tools always learn at least part of a directory.
        if (w.end + entry.name.len + 5 > h.sandbox.max_fs_bytes) break;
        if (entry.kind == .directory) {
            const name_slash = std.fmt.allocPrint(h.sandbox.gpa, "{s}/", .{entry.name}) catch return Err.too_large;
            defer h.sandbox.gpa.free(name_slash);
            s.write(name_slash) catch return Err.too_large;
        } else {
            s.write(entry.name) catch return Err.too_large;
        }
    }
    s.endArray() catch return Err.too_large;
    return h.writeResult(bytes, buf[0..w.end]);
}

/// Shared body of `ck_fs_find` and `ck_fs_grep`: resolve the directory under
/// the same fs_prefixes policy `ck_fs_read` enforces, then serialize whatever
/// `recurse` writes as one JSON array in the host arena.
fn fsWalkJson(
    caller: *zwasm.Caller,
    dir_ptr: u32,
    dir_len: u32,
    pat_ptr: u32,
    pat_len: u32,
    comptime recurse: anytype,
) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const dir_path = sliceOf(bytes, dir_ptr, dir_len) orelse return Err.invalid;
    const pattern = sliceOf(bytes, pat_ptr, pat_len) orelse return Err.invalid;
    if (pattern.len == 0) return Err.invalid;
    const full = safeJoinSecure(h.sandbox, dir_path) catch return Err.denied;
    defer h.sandbox.gpa.free(full);

    var dir = std.Io.Dir.cwd().openDir(h.sandbox.io, full, .{ .iterate = true }) catch return Err.not_found;
    defer dir.close(h.sandbox.io);

    const buf = h.sandbox.gpa.alloc(u8, h.sandbox.max_fs_bytes) catch return Err.too_large;
    defer h.sandbox.gpa.free(buf);
    var w: std.Io.Writer = .fixed(buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    s.beginArray() catch return Err.too_large;

    var count: u32 = 0;
    recurse(h, &s, dir, dir_path, pattern, 0, &count) catch return Err.too_large;

    s.endArray() catch return Err.too_large;
    return h.writeResult(bytes, buf[0..w.end]);
}

/// ck_fs_find(dir_path, pattern), recursively find files under a sandbox
/// directory whose names match a simple glob pattern. The pattern supports
/// '*' (matches any sequence of non-'/' chars) and '?' (matches exactly one
/// non-'/' char); everything else is a literal match. Returns a JSON string
/// array of relative paths (relative to the sandbox root) in the host arena.
/// Stops after `fs_find_max_results` matches, the same bound grep uses on
/// lines: a `*` walk of a large tree used to serialize every path (or fail
/// the whole call with too_large) instead of returning a useful page.
/// Enforces the same fs_prefixes policy as ck_fs_read.
/// Returns Err.not_found when the directory does not exist.
pub fn ckFsFind(caller: *zwasm.Caller, dir_ptr: u32, dir_len: u32, pat_ptr: u32, pat_len: u32) u32 {
    return fsWalkJson(caller, dir_ptr, dir_len, pat_ptr, pat_len, fsFindRecurse);
}

const fs_find_max_depth: u32 = 12;
const fs_find_max_results: u32 = 200;

fn joinRel(gpa: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{
        prefix,
        if (prefix.len > 0) "/" else "",
        name,
    });
}

fn fsFindRecurse(h: *Host, s: *std.json.Stringify, dir: std.Io.Dir, prefix: []const u8, pattern: []const u8, depth: u32, count: *u32) !void {
    if (depth > fs_find_max_depth) return;
    if (count.* >= fs_find_max_results) return;
    var it = dir.iterate();
    while (it.next(h.sandbox.io) catch null) |entry| {
        if (count.* >= fs_find_max_results) return;
        if (entry.name.len == 0) continue;
        if (entry.kind == .directory) {
            if (fs_skip.skipDir(entry.name)) continue;
            const rel = joinRel(h.sandbox.gpa, prefix, entry.name) catch return error.OutOfMemory;
            defer h.sandbox.gpa.free(rel);
            var sub = dir.openDir(h.sandbox.io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(h.sandbox.io);
            try fsFindRecurse(h, s, sub, rel, pattern, depth + 1, count);
        } else if (entry.kind == .file) {
            if (!globMatch(pattern, entry.name)) continue;
            const rel = joinRel(h.sandbox.gpa, prefix, entry.name) catch return error.OutOfMemory;
            defer h.sandbox.gpa.free(rel);
            try s.write(rel);
            count.* += 1;
        }
    }
}

/// Glob match, one implementation shared with the `gh`/`git` guests and the
/// preset filter. See src/util/glob.zig.
pub const globMatch = glob.match;

/// ck_fs_grep(dir_path, pattern), search for lines containing a literal
/// substring in files under a sandbox directory. Returns a JSON array of
/// `{"file":"<relative-path>","line":<number>,"text":"<line-content>"}` objects
/// in the host arena. Searches recursively up to `fs_grep_max_depth` levels
/// deep; stops after `fs_grep_max_results` matching lines. Binary files
/// (containing null bytes in the first 512 bytes) are skipped. Enforces the
/// same fs_prefixes policy as ck_fs_read.
pub fn ckFsGrep(caller: *zwasm.Caller, dir_ptr: u32, dir_len: u32, pat_ptr: u32, pat_len: u32) u32 {
    return fsWalkJson(caller, dir_ptr, dir_len, pat_ptr, pat_len, fsGrepRecurse);
}

const fs_grep_max_depth: u32 = 12;
const fs_grep_max_results: u32 = 200;
const fs_grep_max_line: usize = 500;

fn fsGrepRecurse(
    h: *Host,
    s: *std.json.Stringify,
    dir: std.Io.Dir,
    prefix: []const u8,
    pattern: []const u8,
    depth: u32,
    count: *u32,
) !void {
    if (depth > fs_grep_max_depth) return;
    if (count.* >= fs_grep_max_results) return;
    var it = dir.iterate();
    while (it.next(h.sandbox.io) catch null) |entry| {
        if (count.* >= fs_grep_max_results) return;
        if (entry.name.len == 0) continue;
        if (entry.kind == .directory) {
            // Hidden names (.git, .zig-cache) plus the same cache/vendor
            // trees find already skips. Without that, a project-root grep
            // (the rg-missing fallback in repo_search) reads hundreds of
            // megabytes of zig-pkg, zig-out, node_modules, and history
            // copies before it ever reaches source.
            if (entry.name[0] == '.') continue;
            if (fs_skip.skipDir(entry.name)) continue;
            const rel = joinRel(h.sandbox.gpa, prefix, entry.name) catch return error.OutOfMemory;
            defer h.sandbox.gpa.free(rel);
            var sub = dir.openDir(h.sandbox.io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(h.sandbox.io);
            try fsGrepRecurse(h, s, sub, rel, pattern, depth + 1, count);
        } else if (entry.kind == .file) {
            if (skipGrepName(entry.name)) continue;
            const rel = joinRel(h.sandbox.gpa, prefix, entry.name) catch return error.OutOfMemory;
            defer h.sandbox.gpa.free(rel);
            fsGrepFile(h, s, dir, entry.name, rel, pattern, count) catch continue;
        }
    }
}

/// File-name extensions a content search will never match usefully. Opening
/// them still costs a 1 MiB cap-read apiece, and a project-root walk hits
/// hundreds of `.wasm` / image / archive files before it reaches source.
fn skipGrepName(name: []const u8) bool {
    const dot = std.mem.findScalarLast(u8, name, '.') orelse return false;
    if (dot == 0) return false;
    const ext = name[dot..];
    if (ext.len < 2 or ext.len > 7) return false;
    var buf: [7]u8 = undefined;
    for (ext, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return grep_skip_ext.get(buf[0..ext.len]) != null;
}

const grep_skip_ext = std.StaticStringMap(void).initComptime(.{
    .{ ".wasm", {} },
    .{ ".png", {} },
    .{ ".jpg", {} },
    .{ ".jpeg", {} },
    .{ ".gif", {} },
    .{ ".webp", {} },
    .{ ".ico", {} },
    .{ ".bmp", {} },
    .{ ".zip", {} },
    .{ ".gz", {} },
    .{ ".tgz", {} },
    .{ ".bz2", {} },
    .{ ".xz", {} },
    .{ ".7z", {} },
    .{ ".tar", {} },
    .{ ".o", {} },
    .{ ".a", {} },
    .{ ".so", {} },
    .{ ".dll", {} },
    .{ ".dylib", {} },
    .{ ".exe", {} },
    .{ ".woff", {} },
    .{ ".woff2", {} },
    .{ ".ttf", {} },
    .{ ".otf", {} },
    .{ ".mp3", {} },
    .{ ".mp4", {} },
    .{ ".webm", {} },
    .{ ".wav", {} },
    .{ ".pdf", {} },
    .{ ".class", {} },
    .{ ".jar", {} },
    .{ ".pyc", {} },
    .{ ".map", {} },
    .{ ".obj", {} },
    .{ ".bin", {} },
    .{ ".sqlite", {} },
    .{ ".db", {} },
    .{ ".pack", {} },
});

fn fsGrepFile(
    h: *Host,
    s: *std.json.Stringify,
    dir: std.Io.Dir,
    name: []const u8,
    rel_path: []const u8,
    pattern: []const u8,
    count: *u32,
) !void {
    const st = dir.statFile(h.sandbox.io, name, .{}) catch return;
    if (st.size == 0 or pattern.len > st.size) return;

    // Read the file (up to max_fs_bytes).
    const data = dir.readFileAlloc(h.sandbox.io, name, h.sandbox.gpa, .limited(h.sandbox.max_fs_bytes)) catch return;
    defer h.sandbox.gpa.free(data);
    if (data.len == 0) return;

    // Skip binary files: check first 512 bytes for null.
    const check_len = @min(data.len, 512);
    if (std.mem.findScalar(u8, data[0..check_len], 0) != null) return;

    // Almost every file in a project-root walk holds no hit at all, and the
    // line loop below pays a fresh substring search per line to find that
    // out. One search over the whole buffer answers it instead: a pattern
    // absent from the bytes is absent from every line of them, so this only
    // ever skips work the loop would have done for nothing.
    if (std.mem.find(u8, data, pattern) == null) return;

    // Scan line by line.
    var line_no: u32 = 1;
    var start: usize = 0;
    while (start < data.len) {
        if (count.* >= fs_grep_max_results) return;
        const end = std.mem.findScalarPos(u8, data, start, '\n') orelse data.len;
        const line = data[start..end];
        if (std.mem.find(u8, line, pattern) != null) {
            // Cut on a codepoint boundary: a raw byte cut lands mid-UTF-8 and
            // the hit text is JSON-encoded below, so a split sequence would
            // make the whole ck_fs_grep result unparseable to the guest.
            const display = utf8.cap(line, fs_grep_max_line);
            s.beginObject() catch return error.OutOfMemory;
            s.objectField("file") catch return error.OutOfMemory;
            s.write(rel_path) catch return error.OutOfMemory;
            s.objectField("line") catch return error.OutOfMemory;
            s.print("{d}", .{line_no}) catch return error.OutOfMemory;
            s.objectField("text") catch return error.OutOfMemory;
            s.write(display) catch return error.OutOfMemory;
            s.endObject() catch return error.OutOfMemory;
            count.* += 1;
        }
        start = end + 1;
        line_no += 1;
    }
}

/// ck_fs_stat(path), stat a path under the sandbox root.
/// Returns a JSON object in the host arena:
///   {"exists":true,"kind":"file","size":1234,"mtime_ms":1786960145685}
/// kind is one of "file", "directory", or "other".
/// `mtime_ms` is the last-modification time in unix milliseconds. It is what
/// lets a guest age a directory out by recency (`janitor`'s spill sweep) when
/// the file names carry no order of their own — a spill id is a content hash,
/// so nothing but the timestamp says which ones a live run just wrote.
/// Returns Err.not_found when the path does not exist (no arena write).
/// Enforces the same fs_prefixes policy as ck_fs_read / ck_fs_write.
pub fn ckFsStat(caller: *zwasm.Caller, path_ptr: u32, path_len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const path = sliceOf(bytes, path_ptr, path_len) orelse return Err.invalid;
    if (path.len == 0) return Err.invalid;
    const full = safeJoinSecure(h.sandbox, path) catch return Err.denied;
    defer h.sandbox.gpa.free(full);

    // statFile answers for a directory too, so its own kind field decides
    // what this is. Trying a file stat first and calling any success "file"
    // reported every directory as a 190-byte file.
    const cwd = std.Io.Dir.cwd();
    const stat = cwd.statFile(h.sandbox.io, full, .{}) catch return Err.not_found;
    const kind_str: []const u8 = switch (stat.kind) {
        .file => "file",
        .directory => "directory",
        .sym_link => "symlink",
        else => "other",
    };
    const size: u64 = if (stat.kind == .directory) 0 else stat.size;

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    s.beginObject() catch return Err.too_large;
    s.objectField("exists") catch return Err.too_large;
    s.write(true) catch return Err.too_large;
    s.objectField("kind") catch return Err.too_large;
    s.write(kind_str) catch return Err.too_large;
    s.objectField("size") catch return Err.too_large;
    s.print("{d}", .{size}) catch return Err.too_large;
    s.objectField("mtime_ms") catch return Err.too_large;
    s.print("{d}", .{@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms)}) catch return Err.too_large;
    s.endObject() catch return Err.too_large;
    return h.writeResult(bytes, buf[0..w.end]);
}

/// ck_fs_copy(src_path, dst_path), copy a file under the sandbox root.
/// Both paths must pass the same fs_prefixes policy as ck_fs_read / ck_fs_write.
/// Creates parent directories for the destination automatically.
/// Returns Err.not_found when the source does not exist, Err.too_large when
/// the source exceeds max_fs_bytes.
pub fn ckFsCopy(caller: *zwasm.Caller, src_ptr: u32, src_len: u32, dst_ptr: u32, dst_len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const src_path = sliceOf(bytes, src_ptr, src_len) orelse return Err.invalid;
    const dst_path = sliceOf(bytes, dst_ptr, dst_len) orelse return Err.invalid;
    if (src_path.len == 0 or dst_path.len == 0) return Err.invalid;
    return fsCopyImpl(h, bytes, src_path, dst_path);
}

fn fsCopyImpl(h: *Host, mem_bytes: []u8, src_sub: []const u8, dst_sub: []const u8) u32 {
    const full_src = safeJoinSecure(h.sandbox, src_sub) catch return Err.denied;
    defer h.sandbox.gpa.free(full_src);
    const full_dst = safeJoinSecure(h.sandbox, dst_sub) catch return Err.denied;
    defer h.sandbox.gpa.free(full_dst);

    const data = std.Io.Dir.cwd().readFileAlloc(h.sandbox.io, full_src, h.sandbox.gpa, .limited(h.sandbox.max_fs_bytes)) catch |err| switch (err) {
        error.FileNotFound => return Err.not_found,
        error.StreamTooLong => return Err.too_large,
        else => return Err.invalid,
    };
    defer h.sandbox.gpa.free(data);

    if (std.mem.findScalarLast(u8, full_dst, '/')) |slash| {
        if (slash > 0) std.Io.Dir.cwd().createDirPath(h.sandbox.io, full_dst[0..slash]) catch {};
    }

    // Destination mode follows ck_fs_write: private under state/, where a
    // guest copy of a session/spill/note would otherwise recreate the
    // world-readable exposure the 0600 store mode removes.
    std.Io.Dir.cwd().writeFile(h.sandbox.io, .{ .sub_path = full_dst, .data = data, .flags = .{ .permissions = stateWritePermissions(h.sandbox.state_dir, dst_sub) } }) catch |err| switch (err) {
        error.NoSpaceLeft, error.DiskQuota => return Err.too_large,
        else => return Err.invalid,
    };

    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"bytes\":{d}}}", .{data.len}) catch return Err.too_large;
    return h.writeResult(mem_bytes, json);
}

/// ck_fs_rename(old_path, new_path), rename/move a file under the sandbox root.
/// Both paths must pass the same fs_prefixes policy as ck_fs_read / ck_fs_write.
/// Returns Err.not_found when the source does not exist.
pub fn ckFsRename(caller: *zwasm.Caller, old_ptr: u32, old_len: u32, new_ptr: u32, new_len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const old_path = sliceOf(bytes, old_ptr, old_len) orelse return Err.invalid;
    const new_path = sliceOf(bytes, new_ptr, new_len) orelse return Err.invalid;
    if (old_path.len == 0 or new_path.len == 0) return Err.invalid;
    const full_old = safeJoinSecure(h.sandbox, old_path) catch return Err.denied;
    defer h.sandbox.gpa.free(full_old);
    const full_new = safeJoinSecure(h.sandbox, new_path) catch return Err.denied;
    defer h.sandbox.gpa.free(full_new);
    std.Io.Dir.cwd().rename(full_old, std.Io.Dir.cwd(), full_new, h.sandbox.io) catch |err| switch (err) {
        error.FileNotFound => return Err.not_found,
        else => return Err.invalid,
    };
    return Err.ok;
}

/// ck_fs_delete(path), delete a file under the sandbox root.
/// Enforces the same fs_prefixes policy as ck_fs_read / ck_fs_write.
pub fn ckFsDelete(caller: *zwasm.Caller, path_ptr: u32, path_len: u32) u32 {
    const h = getHost(caller);
    const path = blk: {
        const bytes = memBytes(caller) orelse return Err.invalid;
        break :blk sliceOf(bytes, path_ptr, path_len) orelse return Err.invalid;
    };
    if (path.len == 0) return Err.invalid;
    const full = safeJoinSecure(h.sandbox, path) catch return Err.denied;
    defer h.sandbox.gpa.free(full);
    std.Io.Dir.cwd().deleteFile(h.sandbox.io, full) catch |file_err| switch (file_err) {
        error.FileNotFound => return Err.not_found,
        else => {
            // Not a regular file: try as an empty directory.
            std.Io.Dir.cwd().deleteDir(h.sandbox.io, full) catch |dir_err| switch (dir_err) {
                error.FileNotFound => return Err.not_found,
                else => return Err.invalid,
            };
        },
    };
    return Err.ok;
}

/// ck_fs_mkdir(path), create a directory (and parents) under the sandbox root.
/// Enforces the same fs_prefixes policy as ck_fs_read / ck_fs_write.
pub fn ckFsMkdir(caller: *zwasm.Caller, path_ptr: u32, path_len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const path = sliceOf(bytes, path_ptr, path_len) orelse return Err.invalid;
    if (path.len == 0) return Err.invalid;
    const full = safeJoinSecure(h.sandbox, path) catch return Err.denied;
    defer h.sandbox.gpa.free(full);
    std.Io.Dir.cwd().createDirPath(h.sandbox.io, full) catch |err| switch (err) {
        error.NoSpaceLeft, error.DiskQuota => return Err.too_large,
        else => return Err.invalid,
    };
    return Err.ok;
}

pub fn ckFsRead(caller: *zwasm.Caller, path_ptr: u32, path_len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const path = sliceOf(bytes, path_ptr, path_len) orelse return Err.invalid;
    return fsReadImpl(h, bytes, path);
}

/// ck_fs_read_range(path, offset, length), read a byte range from a file
/// under the sandbox root. Returns the slice [offset, offset+length) of the
/// file in the host arena. If the file is shorter than offset+length the
/// returned data is truncated to what is available (which may be empty if
/// offset >= file size). `length` is capped at max_fs_bytes.
/// Enforces the same fs_prefixes policy as ck_fs_read.
pub fn ckFsReadRange(caller: *zwasm.Caller, path_ptr: u32, path_len: u32, offset: u32, length: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const path = sliceOf(bytes, path_ptr, path_len) orelse return Err.invalid;
    return fsReadRangeImpl(h, bytes, path, offset, length);
}

/// ck_fs_write_range(path, offset, data), write data at a byte offset in a
/// file under the sandbox root. The file must already exist. Bytes in
/// [offset, offset+data.len) are overwritten; if offset+data.len exceeds the
/// current file size the file is extended. `data.len` is capped at
/// max_fs_bytes. Enforces the same fs_prefixes policy as ck_fs_write.
pub fn ckFsWriteRange(caller: *zwasm.Caller, path_ptr: u32, path_len: u32, offset: u32, data_ptr: u32, data_len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const path = sliceOf(bytes, path_ptr, path_len) orelse return Err.invalid;
    const data = sliceOf(bytes, data_ptr, data_len) orelse return Err.invalid;
    return fsWriteRangeImpl(h, path, data, offset);
}

fn fsReadImpl(h: *Host, mem_bytes: []u8, sub_path: []const u8) u32 {
    const full = safeJoinSecure(h.sandbox, sub_path) catch return Err.denied;
    defer h.sandbox.gpa.free(full);
    const data = std.Io.Dir.cwd().readFileAlloc(h.sandbox.io, full, h.sandbox.gpa, .limited(h.sandbox.max_fs_bytes)) catch |err| switch (err) {
        error.FileNotFound => return Err.not_found,
        error.StreamTooLong => return Err.too_large,
        else => return Err.invalid,
    };
    defer h.sandbox.gpa.free(data);
    return h.writeResult(mem_bytes, data);
}

fn fsWriteRangeImpl(h: *Host, sub_path: []const u8, data: []const u8, offset: u32) u32 {
    if (data.len == 0) return Err.ok;
    if (data.len > h.sandbox.max_fs_bytes) return Err.too_large;
    const full = safeJoinSecure(h.sandbox, sub_path) catch return Err.denied;
    defer h.sandbox.gpa.free(full);

    var file = std.Io.Dir.cwd().openFile(h.sandbox.io, full, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => return Err.not_found,
        else => return Err.invalid,
    };
    defer file.close(h.sandbox.io);

    // Positional, because there is no seek on this File: the offset is part
    // of the write rather than a mode the handle carries.
    file.writePositionalAll(h.sandbox.io, data, @as(u64, offset)) catch |err| switch (err) {
        error.NoSpaceLeft, error.DiskQuota => return Err.too_large,
        else => return Err.invalid,
    };
    return Err.ok;
}

fn fsReadRangeImpl(h: *Host, mem_bytes: []u8, sub_path: []const u8, offset: u32, length: u32) u32 {
    if (length == 0) return h.writeResult(mem_bytes, "");
    const capped_len: usize = @min(@as(usize, length), h.sandbox.max_fs_bytes);
    const full = safeJoinSecure(h.sandbox, sub_path) catch return Err.denied;
    defer h.sandbox.gpa.free(full);

    var file = std.Io.Dir.cwd().openFile(h.sandbox.io, full, .{}) catch |err| switch (err) {
        error.FileNotFound => return Err.not_found,
        else => return Err.invalid,
    };
    defer file.close(h.sandbox.io);

    // Get the file size via stat to handle offset >= size gracefully.
    const stat = file.stat(h.sandbox.io) catch return Err.invalid;
    if (@as(u64, offset) >= stat.size) return h.writeResult(mem_bytes, "");
    const avail = stat.size - @as(u64, offset);
    const to_read: usize = @intCast(@min(avail, capped_len));

    const buf = h.sandbox.gpa.alloc(u8, to_read) catch return Err.too_large;
    defer h.sandbox.gpa.free(buf);
    const n = file.readPositionalAll(h.sandbox.io, buf, @as(u64, offset)) catch return Err.invalid;
    return h.writeResult(mem_bytes, buf[0..n]);
}

/// ck_fs_append(path, data), append data to a file under the sandbox root.
/// Creates the file if it doesn't exist. Enforces the same fs_prefixes
/// policy as ck_fs_read / ck_fs_write.
pub fn ckFsAppend(caller: *zwasm.Caller, path_ptr: u32, path_len: u32, data_ptr: u32, data_len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const path = sliceOf(bytes, path_ptr, path_len) orelse return Err.invalid;
    const data = sliceOf(bytes, data_ptr, data_len) orelse &.{};
    return fsAppendImpl(h, path, data);
}

pub fn ckFsWrite(caller: *zwasm.Caller, path_ptr: u32, path_len: u32, data_ptr: u32, data_len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const path = sliceOf(bytes, path_ptr, path_len) orelse return Err.invalid;
    const data = sliceOf(bytes, data_ptr, data_len) orelse &.{};
    return fsWriteImpl(h, bytes, path, data);
}

fn fsAppendImpl(h: *Host, sub_path: []const u8, data: []const u8) u32 {
    if (data.len > h.sandbox.max_fs_bytes) return Err.too_large;
    const full = safeJoinSecure(h.sandbox, sub_path) catch return Err.denied;
    defer h.sandbox.gpa.free(full);
    // Open for appending, creating the file if it doesn't exist: one
    // syscall instead of open-fail-then-writeFile (truncate=false never
    // clobbers existing content).
    return appendLocked(h.sandbox.io, std.Io.Dir.cwd(), full, data, stateWritePermissions(h.sandbox.state_dir, sub_path));
}

/// Owner-only (0600) permissions for guest writes under the harness's state
/// dir: those are the personal-data stores (spilled conversation text,
/// notifications, per-session state). A tool authoring a project file keeps
/// the default mode, so this never changes the visibility of non-state files.
fn stateWritePermissions(state_dir: []const u8, rel: []const u8) std.Io.File.Permissions {
    const under_state = state_dir.len > 0 and std.mem.startsWith(u8, rel, state_dir) and
        (rel.len == state_dir.len or rel[state_dir.len] == '/');
    return if (under_state) atomic_write.private_file else .default_file;
}

/// Appends `data` to `rel`, creating it when absent.
///
/// Locked, because "ask for the size, then write there" is two steps: tools run
/// in parallel here, so two of them appending to one file both read the same
/// end and the second write lands on top of the first. The lock makes the pair
/// atomic between cooperating writers.
pub fn appendLocked(io: std.Io, base: std.Io.Dir, rel: []const u8, data: []const u8, permissions: std.Io.File.Permissions) u32 {
    // Through the retrying create: racing creates of a not-yet-existing log
    // spuriously fail ENOENT on macOS, and mapping that to Err.invalid here
    // silently dropped the append (file_lock.createFileRetry has the story).
    var file = file_lock.createFileRetry(io, base, rel, .{ .truncate = false, .lock = .exclusive, .permissions = permissions }) catch |err| switch (err) {
        error.NoSpaceLeft => return Err.too_large,
        else => return Err.invalid,
    };
    defer file.close(io);
    // This File has no seek, so the end is asked for and written to directly.
    const end = (file.stat(io) catch return Err.invalid).size;
    file.writePositionalAll(io, data, end) catch |err| switch (err) {
        error.NoSpaceLeft => return Err.too_large,
        else => return Err.invalid,
    };
    return Err.ok;
}

fn fsWriteImpl(h: *Host, mem_bytes: []u8, sub_path: []const u8, data: []const u8) u32 {
    if (data.len > h.sandbox.max_fs_bytes) return Err.too_large;
    const full = safeJoinSecure(h.sandbox, sub_path) catch return Err.denied;
    defer h.sandbox.gpa.free(full);
    // Create parent directories first so a tool can scaffold a file in a
    // fresh directory without a separate ck_fs_mkdir round-trip. A failure
    // here is harmless: writeFile below then fails and reports Err.invalid.
    if (std.mem.findScalarLast(u8, full, '/')) |slash| {
        if (slash > 0) std.Io.Dir.cwd().createDirPath(h.sandbox.io, full[0..slash]) catch {};
    }
    std.Io.Dir.cwd().writeFile(h.sandbox.io, .{ .sub_path = full, .data = data, .flags = .{ .permissions = stateWritePermissions(h.sandbox.state_dir, sub_path) } }) catch |err| switch (err) {
        error.NoSpaceLeft, error.DiskQuota => return Err.too_large,
        else => return Err.invalid,
    };
    // Report {"ok":true,"bytes":N} so a tool authoring a file gets the
    // same confirmation contract as the requested write_file built-in.
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"bytes\":{d}}}", .{data.len}) catch return Err.too_large;
    return h.writeResult(mem_bytes, json);
}

/// ck_fs_write_if(path, expected_hash, data), compare-and-swap file write.
/// Acquires an exclusive lock on a separate .lock file, reads the current
/// contents, hashes them to lowercase hex SHA-256, compares with
/// expected_hash, and writes data only if they match. A file that does not
/// exist matches an empty expected_hash so a guest can create one.
/// Returns Err.ok on success, Err.mismatch if the hash does not match,
/// or other Err codes for policy / I/O failures.
pub fn ckFsWriteIf(caller: *zwasm.Caller, path_ptr: u32, path_len: u32, expect_ptr: u32, expect_len: u32, data_ptr: u32, data_len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const path = sliceOf(bytes, path_ptr, path_len) orelse return Err.invalid;
    const expected_hex = sliceOf(bytes, expect_ptr, expect_len) orelse return Err.invalid;
    const data = sliceOf(bytes, data_ptr, data_len) orelse return Err.invalid;
    if (path.len == 0) return Err.invalid;
    return fsWriteIfImpl(h.sandbox, std.Io.Dir.cwd(), path, expected_hex, data);
}

fn fsWriteIfImpl(sb: *Sandbox, base: std.Io.Dir, sub_path: []const u8, expected_hex: []const u8, data: []const u8) u32 {
    if (data.len > sb.max_fs_bytes) return Err.too_large;
    const full = safeJoinSecure(sb, sub_path) catch return Err.denied;
    defer sb.gpa.free(full);

    // Lock on a separate file, not on the file being rewritten (a replace
    // invalidates a lock held on the replaced inode).
    const lock_path = casLockPath(sb, base, full) catch |err| {
        log.log(.warn, "[fs_write_if] could not prepare lock dir for '{s}': {s}", .{ sub_path, @errorName(err) });
        return Err.invalid;
    };
    defer sb.gpa.free(lock_path);
    // Through the retrying create, like appendLocked: the sidecar does not
    // exist before the first CAS on a path, so the first concurrent writers
    // race to create it, and a plain create loses that race on macOS with a
    // spurious FileNotFound (file_lock.createFileRetry has the story). Mapping
    // that to Err.invalid refuses a write that was never in conflict.
    const lock_file = file_lock.createFileRetry(sb.io, sb.state_base_dir orelse base, lock_path, .{ .truncate = false, .lock = .exclusive }) catch |err| {
        log.log(.warn, "[fs_write_if] could not acquire lock for '{s}': {s}", .{ sub_path, @errorName(err) });
        return Err.invalid;
    };
    defer lock_file.close(sb.io);
    writeLockHolder(sb, lock_file, full);

    // Read current contents (missing file -> empty).
    const current = base.readFileAlloc(sb.io, full, sb.gpa, .limited(sb.max_fs_bytes)) catch |err| switch (err) {
        error.FileNotFound => "",
        error.StreamTooLong => return Err.too_large,
        else => return Err.invalid,
    };
    const current_owned = current.len > 0;
    defer if (current_owned) sb.gpa.free(@constCast(current));

    // Hash current contents to lowercase hex SHA-256.
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(current);
    const digest = hasher.finalResult();
    const hex = std.fmt.bytesToHex(digest, .lower);

    // Compare: empty expected matches empty file (FileNotFound above).
    if (expected_hex.len == 0 and current.len == 0) {
        // Creating a new file, hash matches (both empty).
    } else if (expected_hex.len != hex.len or !std.mem.eql(u8, expected_hex, &hex)) {
        return Err.mismatch;
    }

    // Parent dirs, only now that the write is going to happen: a first write
    // into a missing directory (`sub/dir/schedule.json`) has to create it, but
    // a mismatch above is the ordinary contention outcome and must not leave a
    // directory tree behind for a file it never wrote.
    if (std.mem.findScalarLast(u8, full, '/')) |slash| {
        if (slash > 0) base.createDirPath(sb.io, full[0..slash]) catch {};
    }

    // Write (replace) the file.
    base.writeFile(sb.io, .{ .sub_path = full, .data = data, .flags = .{ .permissions = stateWritePermissions(sb.state_dir, sub_path) } }) catch |err| switch (err) {
        error.NoSpaceLeft, error.DiskQuota => return Err.too_large,
        else => return Err.invalid,
    };
    return Err.ok;
}

/// Records who most recently took this lock, and when, inside the lock file,
/// so a write that hangs is attributable to a run and a moment rather than
/// being a zero-byte name. Format and rationale: `tools/zig/cas_lock_record.zig`,
/// shared with the `janitor` guest that reads it back.
///
/// Best effort: this is a diagnostic line, and failing to write one is never a
/// reason to fail the compare-and-swap it accompanies.
fn writeLockHolder(sb: *Sandbox, file: std.Io.File, target: []const u8) void {
    var buf: [cas_lock_record.record_len]u8 = undefined;
    cas_lock_record.render(
        &buf,
        @as(u32, @intCast(std.c.getpid())),
        @as(i64, @intCast(@divTrunc(std.Io.Timestamp.now(sb.io, .real).nanoseconds, std.time.ns_per_ms))),
        sb.tool_self_name,
        target,
    );
    file.writePositionalAll(sb.io, &buf, 0) catch |err| {
        log.log(.warn, "[fs_write_if] could not record the lock holder: {s}", .{@errorName(err)});
    };
}

/// Where the compare-and-swap advisory lock for `full` lives: ADR 0031, one
/// lock inode per target *file* under `{state_dir}/locks/` rather than a
/// `<target>.ck_cas.lock` sidecar beside the target.
///
/// A lock file is never unlinked — unlinking one while it is held moves the
/// lock onto an unreachable inode and lets a second writer lock a fresh file
/// at the same name, so both believe they hold it (see
/// `docs/reports/investigations/2026-08-16-ck-cas-lock-sidecars.md`). The file
/// is therefore permanent by design, which is exactly why it must not sit in
/// the source tree: every record ever CAS-written left one behind, and every
/// improve worktree inherited a copy.
///
/// The name is a SHA-256 of the target with its directory part resolved
/// (`resolvedLockKey`), so every spelling of one file maps to one lock inode
/// while distinct files still serialise independently and two checkouts
/// sharing one `state/` do not collide.
fn casLockPath(sb: *Sandbox, base: std.Io.Dir, full: []const u8) ![]u8 {
    const state_dir = std.mem.trimEnd(u8, if (sb.state_dir.len > 0) sb.state_dir else "state", "/");

    // Which tree the lock directory belongs to. A relative state dir resolves
    // against the run's own root -- `shared_root` when there is one, since that
    // is the checkout an isolated run shares `state/` with -- and never against
    // the process cwd. The target is resolved against that same root, and a
    // lock that lands in a different tree guards nothing: a sandbox rooted in a
    // test's tmp tree used to write permanent lock files into the operator's
    // real `state/locks`, 328 of the 387 files there on 2026-08-17.
    const root = std.mem.trimEnd(u8, if (sb.shared_root.len > 0) sb.shared_root else sb.root_dir, "/");
    const dir = if (root.len == 0 or (state_dir.len > 0 and state_dir[0] == '/'))
        try std.fmt.allocPrint(sb.gpa, "{s}/locks", .{state_dir})
    else
        try std.fmt.allocPrint(sb.gpa, "{s}/{s}/locks", .{ root, state_dir });
    defer sb.gpa.free(dir);
    const state_base = sb.state_base_dir orelse base;
    // ensureDir, not createDirPath: an isolated run's `state` is a symlink to
    // the checkout's (`linkCheckoutStateAt`), and createDirPath alone reports
    // NotDir on that. An improve worktree is the other shape and this has to
    // work there too: `linkSharedState` gives it a real private `state/` on
    // purpose and links only `improvements.jsonl` and `history`, because a
    // symlink under `state/` is safe only where the *host* reads the path --
    // `safeJoinSecure`'s no-follow walk refuses a symlinked component to a
    // guest. Resolving the lock directory against `shared_root` is what keeps
    // both shapes on one lock inode per target, and it is allowed by that same
    // rule: this path is host bookkeeping and never goes through `safeJoin`.
    try ensure_dir.ensureDir(state_base, sb.io, dir);
    sweepAgedLocks(sb, state_base, dir);

    const key = try resolvedLockKey(sb, base, full);
    defer sb.gpa.free(key);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(key);
    const name = std.fmt.bytesToHex(hasher.finalResult(), .lower);
    return std.fmt.allocPrint(sb.gpa, "{s}/{s}.lock", .{ dir, name });
}

/// Name of the file whose mtime spaces out the lock sweep. Not a lock file:
/// `casLockName` refuses it, so a pass never sweeps its own marker.
const cas_lock_sweep_marker = ".swept";

/// How often a process walks `state/locks` looking for files to sweep. The
/// retention window is twelve hours (`cas_lock_record.keep_ms`), so an hour
/// between passes costs at most an hour of delay on a file that has already
/// been unused for half a day.
const cas_lock_sweep_interval_ms: i64 = 60 * 60 * 1000;

/// Deletes lock files under `dir` that nothing has re-acquired for
/// `cas_lock_record.keep_ms` and that nobody holds right now.
///
/// ADR 0031 says `state/locks` is swept; ADR 0008 says nothing in clanker
/// fires on its own, and `clanker janitor` deletes only when an operator types
/// `--yes`. The two are reconciled on this path rather than by a daemon: the
/// code that creates lock files removes the ones that are finished with, so the
/// sweep happens for an operator who never runs the janitor at all. The
/// `janitor` guest keeps its own pass for the same directory, and both decide
/// with the same shared rule (`cas_lock_record.agedOut`), so there is one
/// retention policy and not two.
///
/// Age alone must never license the delete. The record names the *last
/// acquisition*, not a live hold, so a writer that has been inside
/// `fs_write_if` since before the window still holds a lock whose record looks
/// old. The only honest question is whether the lock can be taken, and that is
/// what `lock_nonblocking` asks: `error.WouldBlock` means held, and the file
/// stays. Unlinking a held lock is the hazard the permanent-file design exists
/// to avoid -- the lock moves to an unreachable inode and a second writer locks
/// a fresh file at the same name, both believing they hold it. The unlink
/// therefore happens *while holding* the lock, so nothing can take it between
/// the check and the delete.
///
/// Best effort throughout: this is housekeeping attached to someone else's
/// write, and no failure here may fail that write.
fn sweepAgedLocks(sb: *Sandbox, state_base: std.Io.Dir, dir: []const u8) void {
    const io = sb.io;
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));

    var d = state_base.openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);

    // One pass per interval, per directory rather than per process: several
    // clanker processes share one state directory, and a marker they can all
    // see is what keeps them from each walking it.
    if (d.statFile(io, cas_lock_sweep_marker, .{})) |st| {
        const stamped = @divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms);
        if (now >= stamped and now - stamped < cas_lock_sweep_interval_ms) return;
    } else |_| {}
    d.writeFile(io, .{ .sub_path = cas_lock_sweep_marker, .data = "" }) catch return;

    // Names first, deletes after: unlinking during iteration can make a
    // directory walk skip entries.
    var doomed: std.ArrayList([]const u8) = .empty;
    defer {
        for (doomed.items) |n| sb.gpa.free(n);
        doomed.deinit(sb.gpa);
    }
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!casLockName(entry.name)) continue;
        if (doomed.items.len >= cas_lock_sweep_max) break;
        const record = d.readFileAlloc(io, entry.name, sb.gpa, .limited(4096)) catch continue;
        defer sb.gpa.free(record);
        const stale = if (record.len == 0)
            recordlessLockSettled(sb, d, entry.name, now)
        else
            cas_lock_record.agedOut(record, now, cas_lock_record.keep_ms);
        if (!stale) continue;
        const name = sb.gpa.dupe(u8, entry.name) catch continue;
        doomed.append(sb.gpa, name) catch {
            sb.gpa.free(name);
            continue;
        };
    }

    var swept: usize = 0;
    for (doomed.items) |name| {
        const f = d.createFile(io, name, .{
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch continue; // WouldBlock: held right now, so not ours to remove.
        defer f.close(io);
        d.deleteFile(io, name) catch continue;
        swept += 1;
    }
    if (swept > 0) log.log(.info, "[fs_write_if] swept {d} lock file(s) unused for 12h from {s}", .{ swept, dir });
}

/// Whether a lock file carrying *no record at all* has been sitting long
/// enough to remove.
///
/// `cas_lock_record.agedOut` reads a timestamp out of the record and answers
/// "not old" when it cannot, which is right for a record it fails to parse and
/// wrong for a file that has none: those were invisible to every sweeper and
/// accumulated without limit. 32 of them, all zero-byte and all older than the
/// holder record itself, had to be removed by hand from this checkout on
/// 2026-08-17.
///
/// Zero length is the discriminator, and it is a narrow one on purpose. A live
/// acquisition is zero-byte only between `createFileRetry` and
/// `writeLockHolder`, and it holds the lock across both, so the caller's
/// `lock_nonblocking` probe already refuses that case; the age floor covers only
/// the sliver where a writer has opened the file and not yet locked it. A
/// non-empty record that will not parse is still left alone -- unknown is not
/// old, and that rule is what keeps a garbage record from dating to 1970 and
/// taking live locks with it.
fn recordlessLockSettled(sb: *Sandbox, d: std.Io.Dir, name: []const u8, now_ms: i64) bool {
    const st = d.statFile(sb.io, name, .{}) catch return false;
    const mtime_ms: i64 = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms));
    if (now_ms < mtime_ms) return false; // clock moved, not an aged file
    return now_ms - mtime_ms >= cas_lock_sweep_interval_ms;
}

/// How many lock files one pass may remove. A pass runs inside someone else's
/// compare-and-swap write, so it is bounded work; what it does not reach this
/// hour, the next pass does.
const cas_lock_sweep_max: usize = 512;

/// A lock file is named for the hex SHA-256 of its target. Checking the shape
/// rather than the suffix keeps the sweep off anything else in the directory --
/// the sweep marker included. Mirrors `isCasLock` in `tools/zig/janitor.zig`.
fn casLockName(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".lock")) return false;
    const stem = name[0 .. name.len - ".lock".len];
    if (stem.len != 64) return false;
    for (stem) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// The string a lock name is hashed from: `full` with its directory part
/// resolved to a real absolute path.
///
/// It must be the *file* that names the lock, not the text that named the file.
/// One target is spelled several ways -- `./state/goals.json` under the default
/// `agent.sandbox_root`, `/abs/checkout/state/goals.json` under an isolated
/// run's `shared_root`, and the guest's own path under an absolute
/// `fs_prefixes` grant -- and hashing the spelling gave each of them a lock of
/// its own, so two writers to one file excluded nothing and the earlier write
/// was lost. The sidecar this replaced could not split that way: every spelling
/// named one file, and the kernel resolved them to one inode.
///
/// The basename is appended rather than resolved. The target need not exist
/// yet, and a lock keyed on a link's destination would be a different lock from
/// the one a writer of the link's own name takes.
fn resolvedLockKey(sb: *Sandbox, base: std.Io.Dir, full: []const u8) ![]u8 {
    const cut = std.mem.findScalarLast(u8, full, '/');
    const dir_part = if (cut) |i| (if (i == 0) full[0..1] else full[0..i]) else ".";
    const leaf = if (cut) |i| full[i + 1 ..] else full;

    // A first write into a missing directory has nothing below it to resolve,
    // so walk up to the nearest ancestor that does exist and keep the rest as
    // written. An absolute path floors at "/", a relative one at the base dir.
    const floor: usize = if (dir_part[0] == '/') 1 else 0;
    var end = dir_part.len;
    while (true) {
        const head = dir_part[0..end];
        if (base.realPathFileAlloc(sb.io, if (head.len == 0) "." else head, sb.gpa)) |abs| {
            defer sb.gpa.free(abs);
            const tail = std.mem.trim(u8, dir_part[end..], "/");
            const stem = std.mem.trimEnd(u8, abs, "/");
            if (tail.len == 0) return std.fmt.allocPrint(sb.gpa, "{s}/{s}", .{ stem, leaf });
            return std.fmt.allocPrint(sb.gpa, "{s}/{s}/{s}", .{ stem, tail, leaf });
        } else |_| {
            // Unresolvable all the way up: keep the path as written rather than
            // fail the write. A lock keyed on the raw string is what this
            // function replaced, so the fallback is never worse than that.
            if (end <= floor) return sb.gpa.dupe(u8, full);
            end = std.mem.findScalarLast(u8, dir_part[0..end], '/') orelse floor;
            if (end < floor) end = floor;
        }
    }
}

/// ck_getenv(name), alias of ck_env, kept for modules linked against the
/// older symbol name. Delegating keeps the validation contract (empty name
/// -> Err.invalid) identical for both entry points.
pub fn ckGetenv(caller: *zwasm.Caller, name_ptr: u32, name_len: u32) u32 {
    return ckEnv(caller, name_ptr, name_len);
}

// ------------------------------------------------------- ck_exec (shell-ish) --

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// Returns true if `arg` should be denied because it contains deny token `t`.
/// Bare subcommand words ("rm", "gc", "push", ...) are only matched as whole
/// words; dash flags ("-f", "--force", ...) match as exact/prefix flags;
/// shell-operator tokens match anywhere (defense in depth).
fn argDenied(arg: []const u8, t: []const u8) bool {
    if (t.len == 0) return false;
    if (std.mem.eql(u8, arg, t)) return true;
    if (t[0] == '-') return std.mem.startsWith(u8, arg, t);
    var op = true;
    for (t) |c| {
        if (isWordChar(c)) {
            op = false;
            break;
        }
    }
    if (op) return std.mem.find(u8, arg, t) != null;
    var i: usize = 0;
    while (std.mem.findPos(u8, arg, i, t)) |p| {
        const before = p == 0 or !isWordChar(arg[p - 1]);
        const after = p + t.len >= arg.len or !isWordChar(arg[p + t.len]);
        if (before and after) return true;
        i = p + 1;
    }
    return false;
}

/// Arguments that are never allowed for sandboxed commands: destructive git
/// verbs and flags that make a command run something else.
const exec_deny_tokens = [_][]const u8{
    "push",   "reset",  "rebase",    "checkout", "clean",   "rm",            "fetch",
    "merge",  "revert", "stash",     "remote",   "tag",     "filter-branch", "gc",
    "repack", "prune",  "submodule", "-f",       "--force", "--exec",
};

/// The deny tokens that git_remote_ops: true lifts for the `git` command
/// only. Everything else on exec_deny_tokens stays denied for git (and for
/// every other command); this is the PR lifecycle, not a footgun.
fn isGitRemoteOpToken(t: []const u8) bool {
    return std.mem.eql(u8, t, "push") or std.mem.eql(u8, t, "merge") or std.mem.eql(u8, t, "checkout");
}

/// Git global options that take a value, either as the next argument
/// (`-C <path>`, `--git-dir <path>`) or in the same argument (`--git-dir=<path>`).
/// The value must not be mistaken for the git verb: without this,
/// `git -C <worktree> status` read the worktree path as the subcommand and was
/// denied, which blocked the operator's per-worktree workflow (`git -C "$WT"
/// ...`) through the sandboxed git tool.
const git_value_options = [_][]const u8{
    "-C", "--git-dir",   "--work-tree", "--git-common-dir",
    "-c", "--namespace", "--exec-path", "--config-env",
};

/// Git has network-capable plumbing verbs such as ls-remote and archive that
/// are not recognizable as generic network programs. Keep the host boundary
/// on an allowlist so a replaced or malicious guest cannot bypass
/// network_allow merely by invoking an unlisted git subcommand.
fn gitVerbAllowed(argv: []const []const u8, remote_ops: bool) bool {
    if (argv.len < 2) return false;
    var verb: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (arg.len == 0) continue;
        if (arg[0] == '-') {
            // A value-taking global option written as `--name value` also
            // consumes the next argument; skip it too so it is not read as the
            // verb. `--name=value` is a single argument and is already skipped
            // by the flag check above.
            for (git_value_options) |o| {
                if (std.mem.eql(u8, arg, o)) {
                    i += 1;
                    break;
                }
            }
            continue;
        }
        verb = arg;
        break;
    }
    const v = verb orelse return false;
    const local = [_][]const u8{ "status", "diff", "log", "show", "add", "commit", "ls-files", "rev-parse", "branch", "worktree" };
    for (local) |allowed| if (std.mem.eql(u8, v, allowed)) return true;
    if (gitIndexVerbAllowed(v, argv)) return true;
    return remote_ops and (std.mem.eql(u8, v, "push") or std.mem.eql(u8, v, "merge") or std.mem.eql(u8, v, "checkout"));
}

/// The index verbs smart_commit needs to commit a group from the index rather
/// than from the working tree: `git add` stages the worktree copy and
/// `git commit -- <paths>` commits the worktree copy, so neither can honor an
/// index a session narrowed to its own hunks.
///
/// Each is granted only in the form that cannot write the working tree.
/// `git read-tree -u` updates it, and a bare `git restore <path>` discards
/// uncommitted work exactly the way the denied `checkout` does; those forms
/// stay out. `write-tree` only writes objects.
fn gitIndexVerbAllowed(verb: []const u8, argv: []const []const u8) bool {
    if (std.mem.eql(u8, verb, "write-tree")) return true;
    if (std.mem.eql(u8, verb, "read-tree")) {
        for (argv[1..]) |a| {
            if (std.mem.eql(u8, a, "-u") or std.mem.eql(u8, a, "--update")) return false;
        }
        return true;
    }
    if (!std.mem.eql(u8, verb, "restore")) return false;
    var staged = false;
    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "-W") or std.mem.eql(u8, a, "--worktree")) return false;
        if (std.mem.eql(u8, a, "-S") or std.mem.eql(u8, a, "--staged")) staged = true;
    }
    return staged;
}

/// The rewind guest may `git stash apply|show <hash>` to restore a checkpoint
/// and `git stash create` to take one. `create` makes a dangling commit and
/// leaves the working tree and refs untouched, so it is strictly less
/// invasive than the `apply` already granted. Other git verbs stay on the
/// normal allowlist.
fn rewindGitAllowed(tool_name: []const u8, argv: []const []const u8) bool {
    if (!std.mem.eql(u8, tool_name, "rewind")) return false;
    if (argv.len < 3) return false;
    if (!std.mem.eql(u8, argv[0], "git") and !std.mem.endsWith(u8, argv[0], "/git")) return false;
    if (!std.mem.eql(u8, argv[1], "stash")) return false;
    if (!std.mem.eql(u8, argv[2], "apply") and !std.mem.eql(u8, argv[2], "show") and !std.mem.eql(u8, argv[2], "create")) return false;
    return true;
}

/// First non-flag argument after argv[0], skipping empty tokens. Used by the
/// zig/uv verb allowlists the same way gitVerbAllowed finds the subcommand.
fn firstNonFlag(argv: []const []const u8) ?[]const u8 {
    if (argv.len < 2) return null;
    for (argv[1..]) |arg| {
        if (arg.len == 0) continue;
        if (arg[0] == '-') continue;
        return arg;
    }
    return null;
}

/// zig_check, zig_test, and gate may run `zig`, but the host must not let a
/// replaced guest turn that into `zig fetch` (network) or `zig run` (arbitrary
/// code). `fmt` is allowed only with `--check` so it cannot rewrite the tree.
fn zigVerbAllowed(argv: []const []const u8) bool {
    const v = firstNonFlag(argv) orelse return false;
    if (std.mem.eql(u8, v, "ast-check") or std.mem.eql(u8, v, "test") or std.mem.eql(u8, v, "build")) return true;
    if (!std.mem.eql(u8, v, "fmt")) return false;
    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "--check")) return true;
    }
    return false;
}

/// opencv is the only `uv` caller, and it runs one script. Anything else
/// (`uv pip`, `uvx`, `python3 -c`, a different file) is a sandbox bypass:
/// uv can download packages and run them, which is network plus exec the
/// descriptor never granted.
fn uvVerbAllowed(argv: []const []const u8) bool {
    const v = firstNonFlag(argv) orelse return false;
    if (!std.mem.eql(u8, v, "run")) return false;
    var saw_script = false;
    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--script") or std.mem.eql(u8, a, "-")) return false;
        if (std.mem.eql(u8, a, "tools/py/opencv.py")) saw_script = true;
    }
    return saw_script;
}

/// Host roots a sandboxed argv must never name. `/foo/` as an rg regex is not
/// one of these; `/etc/passwd` and `/home/me/.env` are.
///
/// The list spans both supported host families: the Linux roots first (also
/// the paths the original author's machine exercised), then the roots macOS
/// does not share — `/Users` (home), `/Volumes` (mount points), `/System`,
/// `/Library`, `/Applications`, and `/private`, where macOS actually keeps
/// the `/etc`, `/var` and `/tmp` that Linux spells at the top level. A
/// guest is denied host-absolute argv on every platform: its world is
/// relative to `sandbox_root`, so naming `/home/...` or `/Users/...` is the
/// same escape attempt in either place.
const host_abs_roots = [_][]const u8{
    "/etc",    "/home",    "/usr",          "/var",     "/tmp",  "/root",  "/opt",
    "/dev",    "/proc",    "/sys",          "/run",     "/boot", "/Users", "/Volumes",
    "/System", "/Library", "/Applications", "/private",
};

fn startsWithHostRoot(path: []const u8) bool {
    for (host_abs_roots) |root| {
        if (path.len < root.len) continue;
        if (!std.mem.eql(u8, path[0..root.len], root)) continue;
        if (path.len == root.len or path[root.len] == '/') return true;
    }
    return false;
}

/// The path a flag carries: `--git-dir=/etc/foo` yields `/etc/foo`; a bare
/// `-C` is not a path (the next argv element is checked on its own).
fn pathFromExecArg(arg: []const u8) []const u8 {
    if (std.mem.startsWith(u8, arg, "--")) {
        if (std.mem.findScalar(u8, arg, '=')) |eq| return arg[eq + 1 ..];
    }
    return arg;
}

fn isSearchCmd(cmd: []const u8) bool {
    return std.mem.eql(u8, cmd, "rg") or std.mem.eql(u8, cmd, "ast-grep") or std.mem.eql(u8, cmd, "semcode");
}

/// An exec argument that reaches outside the sandbox the same way a ck_fs_*
/// path would if it skipped safeJoin: a host-absolute root, or a `..`
/// component. argv[0] is the resolved command and is skipped.
///
/// Search tools (`rg`, `ast-grep`, `semcode`) treat most arguments as
/// patterns, so `..` is only checked on the last argument (the path). A
/// host-absolute root is still refused in every argument: `/etc/passwd` is
/// never a regex we need to search for.
fn execArgPathDenied(cmd: []const u8, argv: []const []const u8) ?[]const u8 {
    if (argv.len < 2) return null;
    if (isSearchCmd(cmd)) {
        for (argv[1..]) |arg| {
            if (startsWithHostRoot(pathFromExecArg(arg))) return arg;
        }
        const last = pathFromExecArg(argv[argv.len - 1]);
        if (argStepsUpward(last)) return argv[argv.len - 1];
        return null;
    }
    for (argv[1..]) |arg| {
        const path = pathFromExecArg(arg);
        if (path.len == 0) continue;
        if (startsWithHostRoot(path)) return arg;
        if (argStepsUpward(path)) return arg;
    }
    return null;
}

/// Git global options that hand git a program to run, or a git dir other than
/// the run's own. All are refused even when their value is a relative path
/// inside the sandbox, because git is granted as a version-control verb, not
/// as a code-execution grant:
///
///   - `-c <key>=<value>` / `--config-env=<key>=<env>` inject config that
///     names programs git will run: `core.hooksPath` executes hook scripts on
///     commit (verified: a guest can place `hooks/pre-commit` inside its
///     writable prefixes and commit), and `core.fsmonitor`, `core.sshCommand`,
///     `core.editor`, `core.pager`, `credential.helper`, `diff.external` all
///     spawn a config-named command. On git before 2.43 an `alias.*` can also
///     shadow a builtin verb and run a `!` shell command. The deny-token scan
///     skips `-c` values (they are not argv verbs), so the flag itself is
///     refused.
///   - `--exec-path=...` points git at a helper directory the guest chose
///     (the original refusal; git runs the helpers it finds there).
///   - `--git-dir=<path>` / `--git-common-dir=<path>` select a different git
///     dir. A guest can fabricate one (plain files) with a `pre-commit` hook
///     and have `git commit` execute it as a host process; only the run's own
///     `.git` may ever be used, and it is reachable without the flag.
///
/// Residual (not closed here): `-C <subdir>` is still allowed, and a guest
/// that can write inside a prefix could plant `<subdir>/.git` (a gitfile) plus
/// a fabricated git dir, then commit with `git -C <subdir>`. Closing that
/// needs a gitdir provenance check (spawn `git rev-parse --git-dir` before
/// exec and require the run's own `.git`), which the `-C` grant's
/// worktree-spelling use does not justify by itself.
fn gitExecDeniedArg(argv: []const []const u8) ?[]const u8 {
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--exec-path") or std.mem.startsWith(u8, arg, "--exec-path=")) return arg;
        if (std.mem.eql(u8, arg, "-c")) return arg;
        if (std.mem.eql(u8, arg, "--config-env") or std.mem.startsWith(u8, arg, "--config-env=")) return arg;
        if (std.mem.eql(u8, arg, "--git-dir") or std.mem.startsWith(u8, arg, "--git-dir=")) return arg;
        if (std.mem.eql(u8, arg, "--git-common-dir") or std.mem.startsWith(u8, arg, "--git-common-dir=")) return arg;
    }
    return null;
}

test "sandboxed git may not inject config or select a git dir" {
    // `-c core.hooksPath=<dir>` runs hook scripts on commit (verified: a
    // guest-placed pre-commit hook executes as a host process), and `-c`
    // values are exempt from the deny-token scan, so the flag itself is the
    // refused shape. On git before 2.43 an `alias.*` could also shadow a
    // builtin verb with a `!` shell command.
    try std.testing.expect(gitExecDeniedArg(&.{ "git", "-c", "core.hooksPath=src/hooks", "commit", "-m", "x" }) != null);
    // core.fsmonitor runs on plain status; --config-env is the same injection.
    try std.testing.expect(gitExecDeniedArg(&.{ "git", "--config-env=core.fsmonitor=GIT_FSMONITOR", "status" }) != null);
    // An alternate git dir can carry a pre-commit hook a guest fabricated.
    try std.testing.expect(gitExecDeniedArg(&.{ "git", "--git-dir=./evil.git", "--work-tree=./evil", "commit", "-m", "x" }) != null);
    try std.testing.expect(gitExecDeniedArg(&.{ "git", "--git-common-dir", "./evil.git", "status" }) != null);
    try std.testing.expect(gitExecDeniedArg(&.{ "git", "--exec-path=./helpers", "status" }) != null);
    // The legitimate forms stay: -C changes the cwd (path-checked by
    // execArgPathDenied) and --work-tree keeps the run's own git dir.
    try std.testing.expect(gitExecDeniedArg(&.{ "git", "-C", "src", "status" }) == null);
    try std.testing.expect(gitExecDeniedArg(&.{ "git", "--work-tree=src", "status" }) == null);
    try std.testing.expect(gitExecDeniedArg(&.{ "git", "status", "--porcelain" }) == null);
}

/// Whether `pattern` names `cmd`, i.e. its first whitespace-delimited token
/// is exactly `cmd`. A pattern whose command token carries a `*` cannot name a
/// specific command, so it does not make the command strict (it can still
/// grant an argv via globMatch).
fn patternNamesCmd(pattern: []const u8, cmd: []const u8) bool {
    var i: usize = 0;
    while (i < pattern.len and pattern[i] != ' ') : (i += 1) {}
    return std.mem.eql(u8, pattern[0..i], cmd);
}

const ExecPolicy = struct {
    /// Whether this command has an exec_pattern_allow pattern naming it. A
    /// governed command is strict: only a matching argv runs.
    governed: bool,
    /// Whether the full argv matched one of the command's patterns, which
    /// grants it (and overrides the deny tokens for the args it grants).
    allowed: bool,
};

/// Decides how exec_pattern_allow applies to this argv. Joins argv with single
/// spaces for the glob match so `*` spans argument boundaries. The joined
/// string is written into `join_buf` (left empty when there are no patterns).
fn execPolicyFor(
    sb: *const Sandbox,
    argv: []const []const u8,
    join_buf: []u8,
) ExecPolicy {
    if (sb.exec_pattern_allow.len == 0) return .{ .governed = false, .allowed = false };
    // ckExec resolves a bare command through PATH before building argv, so
    // argv[0] is an absolute path like /usr/bin/gh while exec_pattern_allow
    // names the command by its bare name (`gh pr create*`). Match on the
    // basename for both the command-name test and the glob: it keeps the
    // pattern working whether the command was invoked bare or resolved.
    var cmd: []const u8 = "";
    if (argv.len > 0) {
        const a0 = argv[0];
        cmd = if (std.mem.findScalarLast(u8, a0, '/')) |slash| a0[slash + 1 ..] else a0;
    }
    var j: usize = 0;
    const n0 = @min(cmd.len, join_buf.len);
    @memcpy(join_buf[0..n0], cmd[0..n0]);
    j += n0;
    for (argv[1..]) |a| {
        if (j < join_buf.len) {
            join_buf[j] = ' ';
            j += 1;
        }
        const n = @min(a.len, join_buf.len -| j);
        @memcpy(join_buf[j..][0..n], a[0..n]);
        j += n;
    }
    const joined = join_buf[0..j];
    var governed = false;
    var allowed = false;
    for (sb.exec_pattern_allow) |pat| {
        if (patternNamesCmd(pat, cmd)) governed = true;
        if (globMatch(pat, joined)) allowed = true;
    }
    return .{ .governed = governed, .allowed = allowed };
}

/// Shell operators, refused only when the command being run is a shell.
///
/// ckExec passes argv straight to std.process.run, never through a shell, so
/// these cannot be interpreted as operators by anything else: in an argument to
/// rg or ast-grep they are ordinary pattern syntax. Refusing them everywhere
/// broke the search tools this allowlist exists to serve, a review run was
/// denied the pattern "jsonInt|float => |@intFromFloat" because it contains a
/// greater-than sign. "|" was already exempt for the same reason; the rest
/// follow it.
const shell_op_deny_tokens = [_][]const u8{ "&&", "||", ";", ">", "<", "`" };

/// Resolves a bare command name (no '/') to an absolute path by searching
/// `PATH` from the sandbox's environ map, the same way a shell would.
///
/// `std.process.run`'s own argv[0] resolution is documented to search PATH
/// from "the parent environment", but that resolution did not find `zig` (on
/// PATH, confirmed executable) when called from this sandboxed exec path,
/// while the identical bare-name call from the non-sandboxed gate checks
/// succeeded, every capability eval that shells out (zig_check, zig_test)
/// failed on a plain FileNotFound before ever reaching the tool's own logic.
/// Resolving here removes the dependency on that implicit lookup entirely.
/// Returns null (falls back to the bare name) if `cmd` already looks like a
/// path, PATH is unset, or nothing on it matches, never a hard failure, so
/// exec_allow commands that behave fine today keep behaving the same way.
pub fn resolveExecPath(gpa: std.mem.Allocator, io: std.Io, environ_map: *std.process.Environ.Map, cmd: []const u8) ?[]u8 {
    if (std.mem.findScalar(u8, cmd, '/') != null) return null;
    const path_val = environ_map.get("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path_val, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, cmd }) catch return null;
        std.Io.Dir.accessAbsolute(io, candidate, .{ .execute = true }) catch {
            gpa.free(candidate);
            continue;
        };
        return candidate;
    }
    return null;
}

/// The argument that tripped a deny token, so the caller can say which one it
/// was instead of a bare "denied".
pub const DeniedArg = struct { token: []const u8, arg: []const u8 };

/// Why the exec policy refused an argv. See `execDenial`.
pub const ExecDenial = union(enum) {
    /// `git`, but not one of the subcommands the host allows.
    git_verb,
    /// `zig`, but not ast-check / fmt --check / test / build.
    zig_verb,
    /// `uv`, but not `uv run` of tools/py/opencv.py.
    uv_verb,
    /// `exec_pattern_allow` names this command, which makes it strict, and no
    /// pattern matched the argv.
    no_pattern_match,
    /// A destructive verb or a run-something-else flag (`exec_deny_tokens`).
    deny_token: DeniedArg,
    /// A shell operator in an argument to a command that is itself a shell.
    shell_operator: DeniedArg,
    /// An argument reaching into another run's isolated worktree. Carries the
    /// offending argument. See `foreignWorktreeArg`.
    foreign_worktree: []const u8,
    /// An argument that names a host-absolute path or walks `..`. Carries the
    /// offending argument. See `execArgPathDenied`.
    host_path: []const u8,
    /// A git global option that would make git run a guest-chosen program or
    /// open a guest-fabricated git dir (`-c`, `--config-env`, `--exec-path`,
    /// `--git-dir`, `--git-common-dir`). Carries the offending argument. See
    /// `gitExecDeniedArg`.
    git_config: []const u8,
};

/// The argv-level half of the ck_exec gate, factored out of `ckExec` so the
/// decision lives in exactly one place. Callers check `execAllowed(cmd)` first
///, that half needs only the command name, and refusing there avoids a PATH
/// scan for a command that was never permitted.
///
/// `cmd` is the command as the caller named it (bare, before PATH resolution);
/// `argv` is what would actually be spawned, argv[0] included. Null means the
/// argv passes.
///
/// The second caller is the REPL's `!` shell escape
/// (`src/tui/repl.zig`): a line typed at the prompt is refused by
/// exactly the rules that refuse a tool, rather than by a second, drifting
/// copy of them.
pub fn execDenial(sb: *const Sandbox, cmd: []const u8, argv: []const []const u8) ?ExecDenial {
    // exec_pattern_allow decides whether the deny list even applies. A command
    // with a pattern is strict: only an argv matching one of its patterns runs,
    // and a match also overrides the deny tokens for the args it grants. A
    // command with no pattern stays under the deny-list check below.
    // First, and deliberately ahead of exec_pattern_allow: crossing into
    // another run's tree is not an argv shape a manifest gets to grant. A
    // pattern-governed command returns early below, `null` when a pattern
    // matched, so anything checked after that point is bypassable by writing a
    // pattern -- which is exactly the wrong property for this rule.
    if (foreignWorktreeArg(argv)) |arg| return .{ .foreign_worktree = arg };
    // Same class of escape as a ck_fs_* path that skipped safeJoin: an
    // allowed command (rg, git -C, uv, zig) with a host-absolute or `..`
    // argument would read or write outside fs_prefixes. Checked ahead of
    // exec_pattern_allow so a pattern cannot grant `/etc/passwd`.
    if (execArgPathDenied(cmd, argv)) |arg| return .{ .host_path = arg };

    var join_buf: [4096]u8 = undefined;
    const policy = execPolicyFor(sb, argv, &join_buf);
    if (std.mem.eql(u8, cmd, "git")) {
        if (gitExecDeniedArg(argv)) |arg| return .{ .git_config = arg };
        if (rewindGitAllowed(sb.tool_self_name, argv)) return null;
        if (!gitVerbAllowed(argv, sb.git_remote_ops)) return .git_verb;
    }
    if (std.mem.eql(u8, cmd, "zig") and !zigVerbAllowed(argv)) return .zig_verb;
    if (std.mem.eql(u8, cmd, "uv") and !uvVerbAllowed(argv)) return .uv_verb;
    if (policy.governed) return if (policy.allowed) null else .no_pattern_match;

    // deny-list check: match whole arguments / flag prefixes / word
    // boundaries so single-char tokens like "-f", "rm", "gc" don't
    // false-positive on innocent arguments.
    for (argv) |arg| {
        for (exec_deny_tokens) |t| {
            // git_remote_ops lifts the PR-lifecycle verbs for `git` only;
            // every other token stays denied.
            if (sb.git_remote_ops and std.mem.eql(u8, cmd, "git") and isGitRemoteOpToken(t)) continue;
            if (argDenied(arg, t)) return .{ .deny_token = .{ .token = t, .arg = arg } };
        }
        if (runsAShell(cmd)) {
            for (shell_op_deny_tokens) |t| {
                if (argDenied(arg, t)) return .{ .shell_operator = .{ .token = t, .arg = arg } };
            }
        }
    }
    return null;
}

/// Whether `cmd` would interpret its arguments as shell syntax.
fn runsAShell(cmd: []const u8) bool {
    const base = if (std.mem.findScalarLast(u8, cmd, '/')) |i| cmd[i + 1 ..] else cmd;
    for ([_][]const u8{ "sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh", "env", "xargs" }) |shell| {
        if (std.mem.eql(u8, base, shell)) return true;
    }
    return false;
}

/// ck_std_api: look up a symbol name in the Zig 0.16 standard library source
/// tree and return up to 40 matching lines (signatures, doc comments, usage).
///
/// Use this to verify that a function, type, or field actually exists in
/// std before writing code that calls it, especially after a Zig version
/// bump when APIs may have changed.  The search is a literal substring match
/// (not fuzzy), so pass the shortest unambiguous fragment (e.g.
/// "splitScalar" not "std.mem.splitScalar").  Do NOT use this for non-std
/// symbols or project-internal code; use repo_search / read_file instead.
pub fn ckStdApi(caller: *zwasm.Caller, sym_ptr: u32, sym_len: u32) u32 {
    const h = getHost(caller);
    if (!std.mem.eql(u8, h.sandbox.tool_self_name, "zig_std")) return Err.denied;
    const bytes = memBytes(caller) orelse return Err.invalid;
    const sym = sliceOf(bytes, sym_ptr, sym_len) orelse return Err.invalid;
    const lib_dir = zigLibDir(h.sandbox.io, h.sandbox.environ_map);
    if (sym.len == 0 or lib_dir.len == 0) return Err.not_found;

    // rg is on PATH for interactive use but not for the sandbox host, which
    // inherits a minimal environment; resolve it explicitly so the std_api
    // tool works in capability evals and sub-agents too. See std_api evaluation.
    const rg = resolveExecPath(h.sandbox.gpa, h.sandbox.io, h.sandbox.environ_map, "rg") orelse return Err.not_found;
    defer h.sandbox.gpa.free(rg);
    const std_dir = std.fmt.allocPrint(h.sandbox.gpa, "{s}/std", .{lib_dir}) catch return Err.invalid;
    defer h.sandbox.gpa.free(std_dir);
    const argv = [_][]const u8{ rg, "-n", "-F", "--max-count", "40", sym, std_dir };
    const res = std.process.run(h.sandbox.gpa, h.sandbox.io, .{ .argv = &argv }) catch return Err.invalid;
    defer h.sandbox.gpa.free(res.stdout);
    defer h.sandbox.gpa.free(res.stderr);
    if (res.stdout.len == 0) return Err.not_found;
    return h.writeResult(bytes, res.stdout);
}

/// ck_subagent: spawn a nested sub-agent to perform an independent task and
/// return its final answer as a string.
///
/// Use this when a task is self-contained ("summarize this file", "write unit
/// tests for X") and does not need to share mutable state with the caller.
/// Do NOT use it for tasks that are trivial enough to do inline, every
/// sub-agent call pays a full agent-loop startup cost, or when you need the
/// sub-agent to modify files you are currently editing (it works on a
/// snapshot, not on your live state).
///
/// ck_ask: put a multiple-choice question to the human, or, with
/// {"to": "parent"}, to the agent that spawned this sub-agent, and return
/// the pick.
///
/// Use this when a decision is genuinely ambiguous and the asker cannot
/// resolve it alone (e.g. choosing between two valid refactoring strategies).
/// Do NOT use it for yes/no confirmations the model can resolve itself, or
/// when the options list has fewer than 2 entries (the call will fail). The
/// sandbox has no terminal, so the decision is made host-side: by whoever
/// installed `ask_fn` (the REPL) for the human target, or by the ParentAsk
/// callback (wired only inside sub-agent runs) for the parent target. When
/// the requested answerer is not attached the call returns Err.not_found so
/// the model can decide for itself.
/// ck_tool: a `tool_call:true` tool synchronously calls another tool.
/// Input: {"tool":"name","args":{...} | "raw json string"}.
/// Output: callee's JSON result (written to host arena).
/// Denied when tool_call is false, depth>0, self-recursion, allowlist miss,
/// unknown/disabled/internal target, or bad shape.
pub fn ckTool(caller: *zwasm.Caller, ptr: u32, len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const raw = sliceOf(bytes, ptr, len) orelse return Err.invalid;
    if (!h.sandbox.tool_call) return Err.denied;
    if (h.sandbox.tool_call_depth > 0) return Err.denied;
    const reg = h.sandbox.tool_registry orelse return Err.denied;
    var arena_state = std.heap.ArenaAllocator.init(h.sandbox.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return Err.invalid;
    if (v != .object) return Err.invalid;
    const tool_name = switch (v.object.get("tool") orelse return Err.invalid) {
        .string => |s| s,
        else => return Err.invalid,
    };
    if (tool_name.len == 0) return Err.invalid;
    if (h.sandbox.tool_self_name.len > 0 and std.mem.eql(u8, tool_name, h.sandbox.tool_self_name)) return Err.denied;
    if (h.sandbox.tool_allow) |allow| if (allow.len > 0) {
        var ok = false;
        for (allow) |a| if (std.mem.eql(u8, a, tool_name)) {
            ok = true;
            break;
        };
        if (!ok) return Err.denied;
    };
    const target = reg.get(tool_name) orelse return Err.not_found;
    if (!target.enabled) return Err.not_found;
    if (target.internal) return Err.not_found;
    if (h.sandbox.tool_policy) |pol| {
        if (!pol.call(pol.ctx, tool_name)) return Err.denied;
    }
    var args_json: []const u8 = "{}";
    if (v.object.get("args")) |av| {
        if (av == .string) {
            args_json = av.string;
        } else {
            var aw: std.Io.Writer.Allocating = .init(arena);
            var js = std.json.Stringify{ .writer = &aw.writer, .options = .{} };
            js.write(av) catch return Err.invalid;
            args_json = aw.written();
        }
    }
    const wasm_path = target.wasm;
    const wasm_bytes = std.Io.Dir.cwd().readFileAlloc(h.sandbox.io, wasm_path, h.sandbox.gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return Err.not_found,
        error.OutOfMemory => return Err.too_large,
        else => return Err.invalid,
    };
    defer h.sandbox.gpa.free(wasm_bytes);
    var child_sb: Sandbox = h.sandbox.*;
    h.sandbox.tool_call_depth += 1;
    defer h.sandbox.tool_call_depth -= 1;
    child_sb.tool_call = false;
    child_sb.tool_allow = null;
    child_sb.tool_registry = null;
    child_sb.tool_call_depth = 0;
    child_sb.tool_self_name = target.name;
    child_sb.live_publish = target.live_publish;
    // A child tool must not inherit the parent's ability to spawn agents
    // or to answer on its behalf: those are wired by the agent loop for
    // the tools that declared the capability, not inherited via chain.
    child_sb.subagent_runner = null;
    child_sb.own_ask = null;
    child_sb.fs_prefixes = target.fs_prefixes;
    child_sb.exec_allow = target.exec_allow;
    child_sb.network_allow = target.network_allow;
    child_sb.env_allow = target.env_allow;
    child_sb.fuel = target.fuel;
    child_sb.config_json = target.config_json;
    child_sb.llm = null;
    if (target.network_from_config.len > 0) {
        if (h.sandbox.cfg) |cfg| {
            if (config_mod.configuredHosts(cfg, arena, target.network_from_config)) |extra| {
                if (extra.len > 0) {
                    var merged: std.ArrayList([]const u8) = .empty;
                    merged.appendSlice(arena, child_sb.network_allow) catch {};
                    merged.appendSlice(arena, extra) catch {};
                    child_sb.network_allow = merged.toOwnedSlice(arena) catch child_sb.network_allow;
                }
            } else |_| {}
        }
    }
    if (target.llm) {
        if (h.sandbox.llm) |parent_llm| {
            child_sb.llm = .{ .ctx = parent_llm.ctx, .provider = parent_llm.provider, .max_tokens = parent_llm.max_tokens };
        }
    }
    // Inline WASM load (avoid runtime import cycle), same as runtime.ToolModule but without the type wrapper.
    const zwasm_mod = @import("zwasm");
    var engine = zwasm_mod.Engine.init(h.sandbox.gpa, .{}) catch return Err.invalid;
    defer engine.deinit();
    var linker = engine.linker();
    defer linker.deinit();
    const child_host = arena.create(Host) catch return Err.too_large;
    child_host.* = .{ .sandbox = &child_sb, .rng = std.Random.DefaultPrng.init(0x9E3779B97F4A7C15 ^ @as(u64, @intCast(std.hash.Wyhash.hash(0, tool_name)))) };
    linker.defineFuncCtx("env", "ck_log", child_host, fn (*zwasm_mod.Caller, u32, u32, u32) void, &ckLog) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_now", child_host, fn (*zwasm_mod.Caller) u64, &ckNow) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_random", child_host, fn (*zwasm_mod.Caller) u64, &ckRandom) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_http", child_host, fn (*zwasm_mod.Caller, u32, u32, u32, u32, u32, u32, u32) u32, &ckHttp) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_fs_read", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckFsRead) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_fs_read_range", child_host, fn (*zwasm_mod.Caller, u32, u32, u32, u32) u32, &ckFsReadRange) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_fs_write_range", child_host, fn (*zwasm_mod.Caller, u32, u32, u32, u32, u32) u32, &ckFsWriteRange) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_fs_append", child_host, fn (*zwasm_mod.Caller, u32, u32, u32, u32) u32, &ckFsAppend) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_fs_copy", child_host, fn (*zwasm_mod.Caller, u32, u32, u32, u32) u32, &ckFsCopy) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_fs_rename", child_host, fn (*zwasm_mod.Caller, u32, u32, u32, u32) u32, &ckFsRename) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_fs_delete", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckFsDelete) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_fs_mkdir", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckFsMkdir) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_fs_stat", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckFsStat) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_fs_find", child_host, fn (*zwasm_mod.Caller, u32, u32, u32, u32) u32, &ckFsFind) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_fs_grep", child_host, fn (*zwasm_mod.Caller, u32, u32, u32, u32) u32, &ckFsGrep) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_env", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckEnv) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_hash", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckHash) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_fs_write", child_host, fn (*zwasm_mod.Caller, u32, u32, u32, u32) u32, &ckFsWrite) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_fs_write_if", child_host, fn (*zwasm_mod.Caller, u32, u32, u32, u32, u32, u32) u32, &ckFsWriteIf) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_fs_list", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckFsList) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_getenv", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckGetenv) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_exec", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckExec) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_std_api", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckStdApi) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_subagent", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckSubagent) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_swarm", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckSwarm) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_ask", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckAsk) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_docker", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckDocker) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_kernel", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckKernel) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_debug", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckDebug) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_session", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckSession) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_llm", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckLlm) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_llm_many", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckLlmMany) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_chat", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckChat) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_publish", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckPublish) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_stats", child_host, fn (*zwasm_mod.Caller) u32, &ckStats) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_improve_history", child_host, fn (*zwasm_mod.Caller) u32, &ckImproveHistory) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_config", child_host, fn (*zwasm_mod.Caller) u32, &ckConfig) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_harness_config", child_host, fn (*zwasm_mod.Caller) u32, &ckHarnessConfig) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_result", child_host, fn (*zwasm_mod.Caller) u64, &ckResult) catch return Err.invalid;
    linker.defineFuncCtx("env", "abort", child_host, fn (*zwasm_mod.Caller, u32, u32, u32, u32) void, &struct {
        fn f(_: *zwasm_mod.Caller, _: u32, _: u32, _: u32, _: u32) void {}
    }.f) catch return Err.invalid;
    var mod = engine.compile(wasm_bytes) catch return Err.invalid;
    defer mod.deinit();
    const child_fuel: u64 = if (target.fuel == 0) 10_000_000_000 else @min(target.fuel, 10_000_000_000);
    var inst = linker.instantiate(&mod, .{ .fuel = .{ .limited = child_fuel }, .max_memory_pages = .{ .limited = 256 } }) catch return Err.invalid;
    defer inst.deinit();
    if (inst.exportFuncSig("host_arena")) |_| {
        var af = inst.typedFunc(fn () u32, "host_arena");
        child_host.arena_base = af.call(.{}) catch 0;
        child_host.arena_cur = child_host.arena_base;
    }
    if (inst.exportFuncSig("host_arena_size")) |_| {
        var sf = inst.typedFunc(fn () u32, "host_arena_size");
        const sz = sf.call(.{}) catch 0;
        if (sz > 0) child_host.arena_cap = sz;
    }
    if (args_json.len > std.math.maxInt(u32)) return Err.too_large;
    const args_len: u32 = @intCast(args_json.len);
    var scratch_fn = inst.typedFunc(fn (u32) u32, "scratch");
    const sp = scratch_fn.call(.{args_len}) catch return Err.invalid;
    if (sp == 0) return Err.too_large;
    const mem = inst.memory() orelse return Err.invalid;
    const slice = mem.slice();
    if (@as(u64, sp) + args_len > slice.len) return Err.too_large;
    @memcpy(slice[sp .. sp + args_len], args_json);
    var run_fn = inst.typedFunc(fn (u32, u32) u64, "run");
    const packed_val = run_fn.call(.{ sp, args_len }) catch return Err.invalid;
    const out_ptr: u32 = @intCast(packed_val >> 32);
    const out_len: u32 = @intCast(packed_val & 0xFFFF_FFFF);
    const mem2 = inst.memory() orelse return Err.invalid;
    const s2 = mem2.slice();
    if (@as(u64, out_ptr) + out_len > s2.len) return Err.invalid;
    const result = s2[out_ptr .. out_ptr + out_len];
    return h.writeResult(bytes, result);
}

pub fn ckAsk(caller: *zwasm.Caller, json_ptr: u32, json_len: u32) u32 {
    const h = getHost(caller);
    if (!std.mem.eql(u8, h.sandbox.tool_self_name, "ask_user")) return Err.denied;
    const bytes = memBytes(caller) orelse return Err.invalid;
    const json_input = sliceOf(bytes, json_ptr, json_len) orelse return Err.invalid;

    var arena_state = std.heap.ArenaAllocator.init(h.sandbox.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json_input, .{}) catch return Err.invalid;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return Err.invalid,
    };
    const question = switch (obj.get("question") orelse return Err.invalid) {
        .string => |q| q,
        else => return Err.invalid,
    };
    var options: std.ArrayList([]const u8) = .empty;
    if (obj.get("options")) |o| {
        if (o == .array) {
            for (o.array.items) |item| {
                if (item == .string and item.string.len > 0) options.append(arena, item.string) catch return Err.too_large;
            }
        }
    }
    // A question with nothing to choose between is a prompt for free text,
    // which this tool does not do: the model should just ask in its answer.
    if (options.items.len < 2) return Err.invalid;

    if (obj.get("to")) |t| {
        if (t == .string and std.mem.eql(u8, t.string, "parent")) {
            const pa = h.sandbox.parent_ask orelse return Err.not_found;
            const answer = pa.call(pa.ctx, h.sandbox.gpa, question, options.items) catch return Err.invalid;
            defer h.sandbox.gpa.free(@constCast(answer));
            return h.writeResult(bytes, answer);
        }
    }

    const ask = h.sandbox.ask_fn orelse return Err.not_found;
    // An installed ask_fn can still end up with nobody to answer, the serve
    // bridge times out when the browser tab is gone. That is the same
    // situation as no ask_fn at all, and not_found is what tells the tool to
    // say "decide yourself" rather than "the ask was malformed".
    const answer = ask(question, options.items) catch |err| return switch (err) {
        error.NoUser => Err.not_found,
        else => Err.invalid,
    };
    defer h.sandbox.gpa.free(@constCast(answer));
    return h.writeResult(bytes, answer);
}

/// ck_subagent is a privileged spawn channel. The agent loop attaches a
/// runner to every tool sandbox (a nested run needs a parent), so the import
/// existing is not a grant. Only the tools whose job is to spawn one may call it.
fn subagentAccessAllowed(name: []const u8) bool {
    return std.mem.eql(u8, name, "subagent") or std.mem.eql(u8, name, "rlm");
}

fn swarmAccessAllowed(name: []const u8) bool {
    return std.mem.eql(u8, name, "swarm");
}

/// One nested agent run, driven on its own thread by `ck_subagent` and by each
/// member of a `ck_swarm` batch.
const SubagentCall = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    cfg: *const config_mod.Config,
    task: []const u8,
    provider_name: ?[]const u8,
    brief: Brief,
    parent_ask: ?ParentAsk,
    parent_run_id: []const u8,
    runner: SubagentRunner,
    result: ?[]const u8 = null,
    err: ?anyerror = null,
    fn run(self: *@This()) void {
        self.result = self.runner(self.io, self.gpa, self.environ_map, self.cfg, self.task, self.provider_name, self.brief, self.parent_ask, self.parent_run_id) catch |e| {
            self.err = e;
            return;
        };
    }
};

pub fn ckSubagent(caller: *zwasm.Caller, json_ptr: u32, json_len: u32) u32 {
    const h = getHost(caller);
    if (!subagentAccessAllowed(h.sandbox.tool_self_name)) {
        log.log(.warn, "[sandbox] ck_subagent denied for tool '{s}'", .{h.sandbox.tool_self_name});
        return Err.denied;
    }
    const bytes = memBytes(caller) orelse return Err.invalid;
    const json_input = sliceOf(bytes, json_ptr, json_len) orelse return Err.invalid;
    const runner = h.sandbox.subagent_runner orelse return Err.not_found;

    var arena_state = std.heap.ArenaAllocator.init(h.sandbox.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json_input, .{}) catch return Err.invalid;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return Err.invalid,
    };
    const task = switch (obj.get("task") orelse return Err.invalid) {
        .string => |s| s,
        else => return Err.invalid,
    };
    var provider_name: ?[]const u8 = null;
    if (obj.get("provider")) |p| {
        if (p == .string and p.string.len > 0) provider_name = p.string;
    }
    // The brief the parent hands down: what it already knows, and where to
    // look. Without it the sub-agent re-derives what the parent just learned.
    var brief = Brief{ .parent_task = h.sandbox.parent_task };
    brief.context = stringArray(arena, obj.get("context")) catch &.{};
    brief.files = stringArray(arena, obj.get("files")) catch &.{};
    const cfg = h.sandbox.cfg orelse return Err.not_found;
    // Run the nested agent on its own thread with a large stack: nesting a
    // second zwasm interpreter on the caller's stack (which may itself be a
    // tool worker already running zwasm) overflows the native stack.
    var call = SubagentCall{
        .io = h.sandbox.io,
        .gpa = h.sandbox.gpa,
        .environ_map = h.sandbox.environ_map,
        .cfg = cfg,
        .task = task,
        .provider_name = provider_name,
        .brief = brief,
        // The spawning agent as answerer: it becomes the nested run's
        // parent_ask, reachable via ask_user {"parent": true}.
        .parent_ask = h.sandbox.own_ask,
        // Who spawned this run, so the nested graph records its parent.
        .parent_run_id = h.sandbox.parent_run_id,
        .runner = runner,
    };
    const background = switch (obj.get("background") orelse .null) {
        .bool => |b| b,
        else => false,
    };
    if (background) {
        const heap = h.sandbox.gpa.create(SubagentCall) catch return Err.invalid;
        heap.* = call;
        // ParentAsk is a re-entrant completion on a parked parent. A
        // background child does not park the parent, so that channel would
        // deadlock. The child must not call ask_user {parent:true}.
        heap.parent_ask = null;
        heap.task = h.sandbox.gpa.dupe(u8, task) catch return Err.invalid;
        if (provider_name) |p| heap.provider_name = h.sandbox.gpa.dupe(u8, p) catch return Err.invalid;
        heap.parent_run_id = h.sandbox.gpa.dupe(u8, h.sandbox.parent_run_id) catch return Err.invalid;
        var id_buf: [16]u8 = undefined;
        const now_ns: u64 = @intCast(@max(std.Io.Timestamp.now(h.sandbox.io, .awake).nanoseconds, 0));
        const id = jobs_mod.makeId(now_ns, &id_buf);
        const id_owned = h.sandbox.gpa.dupe(u8, id) catch return Err.invalid;
        const th = std.Thread.spawn(.{ .stack_size = 128 * 1024 * 1024 }, struct {
            /// Runs the nested agent, reports its completion to the job table,
            /// then releases the heap-allocated call and every gpa-owned copy
            /// it holds. The row's copies of `task` and the id are made by
            /// the starter below (`task_row`/`id_row`), owned by the starter
            /// until `registerSub` returns, so this worker can free its
            /// originals as soon as its completion is recorded -- held in a
            /// late-completion slot or attached to a row, either way the job
            /// table has its own copies.
            fn run(c: *SubagentCall, job_id: []const u8) void {
                c.run();
                const err_name: ?[]const u8 = if (c.err) |e| @errorName(e) else null;
                _ = jobs_mod.finishSub(job_id, c.result, err_name);
                c.gpa.free(c.task);
                c.gpa.free(job_id);
                if (c.provider_name) |p| c.gpa.free(p);
                c.gpa.free(c.parent_run_id);
                // The runner's result is gpa-owned (the synchronous path frees
                // it the same way); `finishSub` copied it into the row above.
                if (c.result) |r| c.gpa.free(@constCast(r));
                c.gpa.destroy(c);
            }
        }.run, .{ heap, id_owned }) catch {
            // The thread never started, so the closure's memory has no owner:
            // `heap` and its copies were handed to a worker that will not run.
            h.sandbox.gpa.free(id_owned);
            h.sandbox.gpa.free(heap.task);
            if (heap.provider_name) |p| h.sandbox.gpa.free(p);
            h.sandbox.gpa.free(heap.parent_run_id);
            h.sandbox.gpa.destroy(heap);
            return Err.invalid;
        };
        const sid = if (h.sandbox.session_id.len > 0) h.sandbox.session_id else "default";
        // Registration copies: the worker frees `heap.task`/`id_owned` as
        // soon as its completion lands, so they must not be what registerSub
        // reads. These are owned here until the call returns.
        const task_row = h.sandbox.gpa.dupe(u8, heap.task) catch {
            th.join();
            h.sandbox.gpa.free(id_owned);
            h.sandbox.gpa.free(heap.task);
            if (heap.provider_name) |p| h.sandbox.gpa.free(p);
            h.sandbox.gpa.free(heap.parent_run_id);
            if (heap.result) |r| h.sandbox.gpa.free(@constCast(r));
            h.sandbox.gpa.destroy(heap);
            return Err.invalid;
        };
        // Build the response from `id_owned` before handing the row's copy
        // over; both stay alive until registerSub has made its own.
        var out_buf: [128]u8 = undefined;
        const out = std.fmt.bufPrint(&out_buf, "{{\"ok\":true,\"job\":{f},\"status\":\"running\"}}", .{std.json.fmt(id_owned, .{})}) catch {
            th.join();
            h.sandbox.gpa.free(task_row);
            h.sandbox.gpa.free(id_owned);
            h.sandbox.gpa.free(heap.task);
            if (heap.provider_name) |p| h.sandbox.gpa.free(p);
            h.sandbox.gpa.free(heap.parent_run_id);
            if (heap.result) |r| h.sandbox.gpa.free(@constCast(r));
            h.sandbox.gpa.destroy(heap);
            return Err.invalid;
        };
        jobs_mod.registerSub(h.sandbox.gpa, id_owned, sid, task_row, th) catch {
            h.sandbox.gpa.free(task_row);
            return Err.invalid;
        };
        h.sandbox.gpa.free(task_row);
        return h.writeResult(bytes, out);
    }
    const th = std.Thread.spawn(.{ .stack_size = 128 * 1024 * 1024 }, SubagentCall.run, .{&call}) catch return Err.invalid;
    th.join();
    if (call.err) |e| {
        // The task is the operator's own prose, so it stays out of the log
        // line the way a chat payload does; its size is what a reader of this
        // record actually needs next to the error.
        log.log(.error_, "subagent failed: {s} (task {d} bytes)", .{ @errorName(e), task.len });
        return Err.invalid;
    }
    const result = call.result orelse "";
    const rc = h.writeResult(bytes, result);
    if (result.len > 0) h.sandbox.gpa.free(@constCast(result));
    return rc;
}

fn jobAccessAllowed(name: []const u8) bool {
    return std.mem.eql(u8, name, "jobs") or std.mem.eql(u8, name, "subagent");
}

/// ck_job: start / list / wait / kill background work. Privileged: only the
/// jobs and subagent guests. Exec start reuses the caller's exec_allow.
pub fn ckJob(caller: *zwasm.Caller, ptr: u32, len: u32) u32 {
    const h = getHost(caller);
    if (!jobAccessAllowed(h.sandbox.tool_self_name)) {
        log.log(.warn, "[sandbox] ck_job denied for tool '{s}'", .{h.sandbox.tool_self_name});
        return Err.denied;
    }
    const bytes = memBytes(caller) orelse return Err.invalid;
    const raw = sliceOf(bytes, ptr, len) orelse return Err.invalid;
    var arena_state = std.heap.ArenaAllocator.init(h.sandbox.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return Err.invalid;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return Err.invalid,
    };
    const op = switch (obj.get("op") orelse return Err.invalid) {
        .string => |s| s,
        else => return Err.invalid,
    };
    const sid = if (h.sandbox.session_id.len > 0) h.sandbox.session_id else "default";
    const reg = h.sandbox.subprocs orelse (subprocess.processRegistry(h.sandbox.gpa, h.sandbox.io) catch return Err.invalid);

    if (std.mem.eql(u8, op, "list")) {
        const json_out = jobs_mod.listJson(arena, reg, sid) catch return Err.invalid;
        return h.writeResult(bytes, json_out);
    }
    if (std.mem.eql(u8, op, "start")) {
        const argv_v = obj.get("argv") orelse return Err.invalid;
        if (argv_v != .array or argv_v.array.items.len == 0) return Err.invalid;
        var argv: std.ArrayList([]const u8) = .empty;
        for (argv_v.array.items) |item| {
            if (item != .string) return Err.invalid;
            argv.append(arena, item.string) catch return Err.invalid;
        }
        // The same gate ck_exec applies before execDenial: argv[0] must be one
        // of the commands the tool's manifest names. Without it, `jobs`
        // (exec_allow: git/zig/rg/ast-grep/semcode/uv) could start any binary
        // on PATH -- curl, python3, a shell -- because execDenial only refuses
        // deny tokens and unlisted git/zig/uv verbs; a bare "curl" passes it.
        if (!execAllowed(h.sandbox.exec_allow, argv.items[0])) {
            log.log(.warn, "[sandbox] ck_job denied command '{s}'; its manifest lists {d} command(s)", .{ argv.items[0], h.sandbox.exec_allow.len });
            return Err.denied;
        }
        if (execDenial(h.sandbox, argv.items[0], argv.items) != null) return Err.denied;
        // The child inherits nothing of the harness environment: same filter
        // as ck_exec (execEnvironment), so a job process cannot read API keys
        // that the same guest is denied through ck_env. startExec used to
        // spawn with the full process environment, letting an allowed
        // executable print every key the harness loaded from .env.
        var child_env = execEnvironment(h.sandbox.gpa, h.sandbox) catch return Err.invalid;
        defer child_env.deinit();
        const kind = jobs_mod.startExec(h.sandbox.io, h.sandbox.gpa, reg, sid, h.sandbox.root_dir, &child_env, argv.items) catch return Err.invalid;
        defer h.sandbox.gpa.free(kind);
        var out_buf: [160]u8 = undefined;
        const out = std.fmt.bufPrint(&out_buf, "{{\"ok\":true,\"id\":{f}}}", .{std.json.fmt(kind, .{})}) catch return Err.invalid;
        return h.writeResult(bytes, out);
    }
    if (std.mem.eql(u8, op, "kill")) {
        const id = switch (obj.get("id") orelse return Err.invalid) {
            .string => |s| s,
            else => return Err.invalid,
        };
        _ = jobs_mod.kill(reg, sid, id);
        return h.writeResult(bytes, "{\"ok\":true}");
    }
    if (std.mem.eql(u8, op, "wait")) {
        const id = switch (obj.get("id") orelse return Err.invalid) {
            .string => |s| s,
            else => return Err.invalid,
        };
        if (std.mem.startsWith(u8, id, "job-")) {
            const json_out = jobs_mod.waitExec(arena, id) catch return Err.not_found;
            return h.writeResult(bytes, json_out);
        }
        const json_out = jobs_mod.waitSub(arena, id) catch return Err.not_found;
        return h.writeResult(bytes, json_out);
    }
    return Err.invalid;
}

/// Bound on tasks per ck_swarm call: each spawns its own 128 MiB-stack
/// thread and a full nested agent, so this is a real resource ceiling, not
/// an arbitrary one.
const max_swarm_tasks: usize = 8;

/// Fans `tasks` out to that many nested agents on their own threads
/// (reusing the same subagent_runner as ck_subagent, a swarm member is
/// just a subagent run, bounded iterations and all), running concurrently,
/// then joins every one before returning. The join is load-bearing for the
/// same reason ck_subagent's is: it is what keeps the parent parked on this
/// llm:true tool call for the whole batch, so ParentAsk stays safe and the
/// caller never observes a partially-finished swarm.
pub fn ckSwarm(caller: *zwasm.Caller, json_ptr: u32, json_len: u32) u32 {
    const h = getHost(caller);
    if (!swarmAccessAllowed(h.sandbox.tool_self_name)) {
        log.log(.warn, "[sandbox] ck_swarm denied for tool '{s}'", .{h.sandbox.tool_self_name});
        return Err.denied;
    }
    const bytes = memBytes(caller) orelse return Err.invalid;
    const json_input = sliceOf(bytes, json_ptr, json_len) orelse return Err.invalid;
    const runner = h.sandbox.subagent_runner orelse return Err.not_found;

    var arena_state = std.heap.ArenaAllocator.init(h.sandbox.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json_input, .{}) catch return Err.invalid;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return Err.invalid,
    };
    const tasks = stringArray(arena, obj.get("tasks")) catch return Err.invalid;
    if (tasks.len == 0) return Err.invalid;
    if (tasks.len > max_swarm_tasks) return Err.too_large;
    var provider_name: ?[]const u8 = null;
    if (obj.get("provider")) |p| {
        if (p == .string and p.string.len > 0) provider_name = p.string;
    }
    const cfg = h.sandbox.cfg orelse return Err.not_found;
    // Each member gets the same brief a lone subagent would: what larger work
    // this serves. Unlike subagent there is no per-task context/files: a swarm
    // task is expected to be a complete, self-contained brief, since members
    // cannot see each other or the parent's transcript.
    const brief = Brief{ .parent_task = h.sandbox.parent_task };

    const calls = arena.alloc(SubagentCall, tasks.len) catch return Err.too_large;
    for (tasks, 0..) |task, i| {
        calls[i] = .{
            .io = h.sandbox.io,
            .gpa = h.sandbox.gpa,
            .environ_map = h.sandbox.environ_map,
            .cfg = cfg,
            .task = task,
            .provider_name = provider_name,
            .brief = brief,
            .parent_ask = h.sandbox.own_ask,
            .parent_run_id = h.sandbox.parent_run_id,
            .runner = runner,
        };
    }

    const threads = arena.alloc(std.Thread, calls.len) catch return Err.too_large;
    var spawned: usize = 0;
    while (spawned < calls.len) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{ .stack_size = 128 * 1024 * 1024 }, SubagentCall.run, .{&calls[spawned]}) catch break;
    }
    for (threads[0..spawned]) |th| th.join();
    // Any call past `spawned` never ran: result and err both stay null,
    // which the encoding loop below reports as "spawn failed", the same
    // shape as a member that ran and errored, so the batch's other results
    // are never lost to one thread-spawn failure.

    defer for (calls) |call| {
        if (call.result) |r| h.sandbox.gpa.free(@constCast(r));
    };

    const buf = h.sandbox.gpa.alloc(u8, h.sandbox.max_fs_bytes) catch return Err.too_large;
    defer h.sandbox.gpa.free(buf);
    var w: std.Io.Writer = .fixed(buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    s.beginArray() catch return Err.too_large;
    var failures: usize = 0;
    for (calls) |call| {
        s.beginObject() catch return Err.too_large;
        s.objectField("task") catch return Err.too_large;
        s.write(call.task) catch return Err.too_large;
        if (call.result) |r| {
            s.objectField("ok") catch return Err.too_large;
            s.write(true) catch return Err.too_large;
            s.objectField("text") catch return Err.too_large;
            s.write(r) catch return Err.too_large;
        } else {
            failures += 1;
            s.objectField("ok") catch return Err.too_large;
            s.write(false) catch return Err.too_large;
            s.objectField("error") catch return Err.too_large;
            const msg: []const u8 = if (call.err) |e| @errorName(e) else "spawn failed";
            s.write(msg) catch return Err.too_large;
        }
        s.endObject() catch return Err.too_large;
    }
    s.endArray() catch return Err.too_large;
    if (failures > 0) log.log(.warn, "swarm: {d}/{d} members failed", .{ failures, calls.len });

    return h.writeResult(bytes, buf[0..w.end]);
}

/// True if `path` (split on '/') names or enters a directory called
/// `.clanker-worktrees`, the per-run improve worktree container. Used to stop
/// an exec `cwd`/`dir` from landing inside a sibling run's worktree.
///
/// The container itself is refused too, and that is not an oversight to be
/// tidied up: this path becomes an exec'd child's cwd, and the child's own
/// arguments resolve against it. A cwd of `.clanker-worktrees` reaches
/// `123/src` with no `.clanker-worktrees` component left for this function to
/// see, so allowing the container does not merely permit a harmless
/// directory, it hands over every worktree under it. The container holds
/// nothing but sibling runs' trees, so refusing it costs nothing real, and
/// `ck_fs_list` can still enumerate it, which was its only use.
///
/// The `cwd`/`dir` field is not the only way in, and this function is not the
/// only caller: an argv naming the path itself, `git -C .clanker-worktrees/123
/// status` with no cwd at all, resolves against the run's directory rather
/// than through here. `foreignWorktreeArg` applies this same test to every
/// argument, and `execDenial` calls it before any other rule.
///
/// Keep this matching the component wherever it appears, and move the test
/// below in the same commit if it ever has to change. Loosening it to "only a
/// descent counts" has happened twice now, each time leaving the function and
/// its own test asserting opposite things, and main red.
fn pathHasWorktreeDir(path: []const u8) bool {
    // Any component, the last one included. Do not narrow this to "only a
    // descent counts" without changing the test below in the same commit --
    // see the paragraphs above for why the container itself is refused, and
    // the history for what happens when only one of the two moves.
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".clanker-worktrees")) return true;
    }
    return false;
}

/// True if `arg` is written as a path that walks *up* out of the directory it
/// resolves against, once `.` and `..` are cancelled textually. `src/../lib`
/// stays inside and is false; `../123` and `a/../../b` leave and are true.
///
/// Momentarily leaving counts, even if a later component would come back:
/// whether `../x/y` lands back inside depends on what the run's own directory
/// is called, which this cannot know and must not guess.
///
/// Absolute paths return false. They cannot "escape" relatively, and the
/// component test above is what covers them.
fn pathEscapesUpward(path: []const u8) bool {
    if (path.len > 0 and path[0] == '/') return false;
    var depth: isize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            depth -= 1;
            if (depth < 0) return true;
        } else depth += 1;
    }
    return false;
}

/// Whether `arg` is shaped like a path with a parent-directory step in it, as
/// opposed to a pattern that merely contains two dots.
///
/// This narrowing is the whole reason the upward check is safe to apply to
/// every argument: `rg` and `ast-grep` patterns are ordinary arguments here
/// (nothing runs through a shell), and `a..b` or `\.\.` are regex syntax, not
/// paths. Requiring a '/' next to the `..` leaves those alone.
fn argStepsUpward(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "..") or
        std.mem.startsWith(u8, arg, "../") or
        std.mem.endsWith(u8, arg, "/..") or
        std.mem.find(u8, arg, "/../") != null;
}

/// The argument that reaches into a run's isolated worktree other than the
/// caller's own, or null if none does. Two ways in, and both are closed here
/// because a run has exactly one legitimate tree and addresses it as `.`:
///
///   - Naming the container. `git -C .clanker-worktrees/123 status` from the
///     checkout, or the absolute equivalent. `pathHasWorktreeDir`.
///   - Walking up to a sibling. `git -C ../123 status` from *inside* a
///     worktree, where cwd is `<checkout>/.clanker-worktrees/<own-id>` and the
///     container is the parent, so no `.clanker-worktrees` component appears in
///     the argument at all. `pathEscapesUpward`.
///
/// The second case is why this is not just the first test applied to argv. An
/// isolated run is the one caller that sits inside the container, and it is
/// also the caller with the most to gain from reading the tree next door.
///
/// Read access is not the worst of it: `worktree` is an allowed git verb and
/// `remove` is not an `exec_deny_tokens` entry (the token is `rm`, which does
/// not match at a word boundary inside "remove"), so before this existed
/// `git worktree remove .clanker-worktrees/123` *deleted* a sibling run's tree,
/// commits and all.
///
/// Cost of the conservative direction: a run cannot name its own worktree
/// through the container either, absolutely or via `..`. It has no reason to --
/// cwd already is that tree -- and the `cwd`/`dir` guard has refused the same
/// shape since it was written, for the same reason.
fn foreignWorktreeArg(argv: []const []const u8) ?[]const u8 {
    for (argv) |arg| {
        if (pathHasWorktreeDir(arg)) return arg;
        if (argStepsUpward(arg) and pathEscapesUpward(arg)) return arg;
    }
    return null;
}

pub fn ckExec(caller: *zwasm.Caller, argv_ptr: u32, argv_len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const argv_json = sliceOf(bytes, argv_ptr, argv_len) orelse return Err.invalid;

    var arena_state = std.heap.ArenaAllocator.init(h.sandbox.gpa);
    defer arena_state.deinit();
    const parse_arena = arena_state.allocator();

    // parse {cmd, args}
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, parse_arena, argv_json, .{}) catch return Err.invalid;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return Err.invalid,
    };
    const cmd = switch (obj.get("cmd") orelse return Err.invalid) {
        .string => |s| s,
        else => return Err.invalid,
    };
    if (!execAllowed(h.sandbox.exec_allow, cmd)) {
        log.log(.warn, "[sandbox] tool may not run '{s}'; its manifest lists {d} command(s)", .{ cmd, h.sandbox.exec_allow.len });
        return Err.denied;
    }

    // Optional cwd: resolve relative to sandbox root via safeJoin. With no
    // cwd given the child runs at the sandbox ROOT, not the process cwd.
    //
    // Every ck_fs_* path resolves under root_dir (safeJoin prepends it), so a
    // child that inherited the process cwd instead saw a different tree than
    // the file tools the moment sandbox_root was not ".". That is exactly the
    // configuration per-run worktree isolation needs, and the split was
    // silent in both directions: `git rev-parse --show-toplevel` and `git
    // status` reported the main checkout while edit_file wrote into the
    // worktree, so an agent reading its own git output concluded its edits had
    // landed in the shared checkout and "recovered" by redoing them there --
    // which is how they ended up there for real. Nothing in either result
    // hinted the two disagreed. One root for the whole toolchain instead.
    //
    // Unchanged when sandbox_root is "." (the default): same directory either
    // way, so this only takes effect for a run that asked to be isolated.
    var exec_dir: std.Io.Dir = std.Io.Dir.cwd();
    var exec_dir_opened = false;
    if (obj.get("cwd")) |cwd_val| {
        if (cwd_val == .string and cwd_val.string.len > 0) {
            // Refuse a cwd that lands inside another run's isolated worktree.
            // `.clanker-worktrees/` is the per-run improve worktree container
            // under the repo root (src/improve/worktree.zig). The only session
            // legitimately inside one runs with that worktree as its sandbox
            // root, where the container sits *above* the root and a relative
            // cwd can never re-enter it (`..` is already refused below). Any
            // `.clanker-worktrees` component here is therefore a descent into
            // a sibling run's tree (e.g. a `gate` `dir` pointed at one).
            if (pathHasWorktreeDir(cwd_val.string)) {
                log.log(.warn, "[sandbox] ck_exec denied cwd '{s}': inside another run's worktree", .{cwd_val.string});
                return Err.denied;
            }
            const full = safeJoinSecure(h.sandbox, cwd_val.string) catch return Err.denied;
            defer h.sandbox.gpa.free(full);
            exec_dir = std.Io.Dir.cwd().openDir(h.sandbox.io, full, .{}) catch return Err.not_found;
            exec_dir_opened = true;
        }
    }
    if (!exec_dir_opened and !rootIsProcessCwd(h.sandbox.root_dir)) {
        exec_dir = std.Io.Dir.cwd().openDir(h.sandbox.io, h.sandbox.root_dir, .{}) catch return Err.not_found;
        exec_dir_opened = true;
    }
    defer if (exec_dir_opened) exec_dir.close(h.sandbox.io);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(h.sandbox.gpa);
    const resolved_cmd = resolveExecPath(h.sandbox.gpa, h.sandbox.io, h.sandbox.environ_map, cmd);
    defer if (resolved_cmd) |rc| h.sandbox.gpa.free(rc);
    argv.append(h.sandbox.gpa, resolved_cmd orelse cmd) catch return Err.invalid;
    if (obj.get("args")) |a| {
        switch (a) {
            .array => |arr| {
                for (arr.items) |item| {
                    const arg = switch (item) {
                        .string => |s| s,
                        else => return Err.invalid,
                    };
                    argv.append(h.sandbox.gpa, arg) catch return Err.invalid;
                }
            },
            else => {},
        }
    }

    if (execDenial(h.sandbox, cmd, argv.items)) |d| {
        switch (d) {
            .git_verb => log.log(.warn, "[sandbox] ck_exec denied unlisted git verb", .{}),
            .zig_verb => log.log(.warn, "[sandbox] ck_exec denied unlisted zig verb", .{}),
            .uv_verb => log.log(.warn, "[sandbox] ck_exec denied uv argv; only uv run of tools/py/opencv.py is allowed", .{}),
            .no_pattern_match => log.log(.warn, "[sandbox] ck_exec denied '{s}': exec_pattern_allow makes this command strict and no pattern matches", .{cmd}),
            .deny_token => |x| log.log(.warn, "[sandbox] ck_exec denied token '{s}' in arg '{s}'", .{ x.token, x.arg }),
            .shell_operator => |x| log.log(.warn, "[sandbox] ck_exec denied shell operator '{s}' in arg '{s}'", .{ x.token, x.arg }),
            .foreign_worktree => |a| log.log(.warn, "[sandbox] ck_exec denied arg '{s}': it reaches into another run's worktree", .{a}),
            .host_path => |a| log.log(.warn, "[sandbox] ck_exec denied arg '{s}': path is outside the sandbox", .{a}),
            .git_config => |a| log.log(.warn, "[sandbox] ck_exec denied arg '{s}': git config injection / alternate git dir would run guest-chosen code", .{a}),
        }
        return Err.denied;
    }

    log.log(.info, "[exec] → {s}", .{cmd});
    const exec_t0 = std.Io.Timestamp.now(h.sandbox.io, .awake);
    var child_env = execEnvironment(h.sandbox.gpa, h.sandbox) catch return Err.invalid;
    defer child_env.deinit();
    // A tool that needs to *talk* to a process, not just launch one, an LSP
    // client is the reason this exists, hands over the bytes to write to its
    // stdin. std.process.run cannot do that (it hardcodes .ignore), so that
    // case spawns the child directly.
    if (obj.get("stdin")) |sv| {
        if (sv == .string and sv.string.len > 0) {
            return execWithStdin(h, bytes, argv.items, exec_dir, &child_env, sv.string, cmd);
        }
    }

    const result = std.process.run(h.sandbox.gpa, h.sandbox.io, .{
        .argv = argv.items,
        .cwd = .{ .dir = exec_dir },
        // Explicit, not left to the Io backend's own fallback: with this
        // unset the child's env came from the Io instance's memoized copy
        // rather than a live read, and `zig test`/`zig ast-check` failed with
        // "unable to resolve zig cache directory: AppDataDirUnavailable"
        // even though HOME was set and correct in the real process env.
        .environ_map = &child_env,
        // Generous, because the result is truncated with a marker below
        // rather than refused: a search that matches a lot should return what
        // it found and say it was cut, not fail with StreamTooLong and leave
        // the caller guessing whether the tool or the pattern was at fault.
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| {
        // Not a network condition: a process that could not be spawned or
        // whose output overran the cap was reported to the guest as
        // "NetworkError", which sent the model looking for a connectivity
        // problem that never existed.
        // Carries the ✗ and a duration like the exit-code branch below, so
        // every → has a finish line in the same shape whatever went wrong.
        const failed_ms = @divTrunc(exec_t0.durationTo(std.Io.Timestamp.now(h.sandbox.io, .awake)).nanoseconds, std.time.ns_per_ms);
        log.log(.warn, "[exec] ✗ {s} … {d}ms, failed to run: {s}", .{ cmd, failed_ms, @errorName(err) });
        return switch (err) {
            error.FileNotFound => Err.not_found,
            error.StreamTooLong, error.FileTooBig, error.NoSpaceLeft => Err.too_large,
            else => Err.invalid,
        };
    };
    defer h.sandbox.gpa.free(result.stdout);
    defer h.sandbox.gpa.free(result.stderr);

    const code: u32 = switch (result.term) {
        .exited => |c| c,
        else => 1,
    };
    const exec_ms = @divTrunc(exec_t0.durationTo(std.Io.Timestamp.now(h.sandbox.io, .awake)).nanoseconds, std.time.ns_per_ms);
    if (code == 0) {
        log.log(.info, "[exec] ✓ {s} … {d}ms", .{ cmd, exec_ms });
    } else {
        log.log(.info, "[exec] ✗ {s} … {d}ms, exit code {d}", .{ cmd, exec_ms, code });
    }

    const wbuf = h.sandbox.gpa.alloc(u8, 96 * 1024) catch return Err.too_large;
    defer h.sandbox.gpa.free(wbuf);
    var w: std.Io.Writer = .fixed(wbuf);
    writeExecResult(&w, code, result.stdout, result.stderr) catch return Err.too_large;
    return h.writeResult(bytes, wbuf[0..w.end]);
}

/// How much of a command's output survives into the result. The guest sees it
/// through the host arena, so the whole of a large search cannot fit whatever
/// the process produced.
const exec_stdout_keep = 56 * 1024;
const exec_stderr_keep = 8 * 1024;

fn writeExecResult(w: *std.Io.Writer, code: u32, stdout: []const u8, stderr: []const u8) !void {
    var s = std.json.Stringify{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(code == 0);
    try s.objectField("code");
    try s.print("{d}", .{code});
    try s.objectField("stdout");
    try s.write(clipOutput(stdout, exec_stdout_keep));
    try s.objectField("stderr");
    try s.write(clipOutput(stderr, exec_stderr_keep));
    // Silent truncation reads as "that is all there is", which is how a search
    // that matched thousands of lines looks identical to one that matched
    // forty. Say it, and say what to do about it.
    if (stdout.len > exec_stdout_keep or stderr.len > exec_stderr_keep) {
        try s.objectField("truncated");
        try s.write(true);
        try s.objectField("note");
        var note_buf: [160]u8 = undefined;
        const note = std.fmt.bufPrint(&note_buf, "output was {d} bytes and was cut to {d}; narrow the pattern or the path to see the rest", .{ stdout.len, exec_stdout_keep }) catch "output was cut; narrow the pattern or the path to see the rest";
        try s.write(note);
    }
    try s.endObject();
}

/// What a command a native caller ran actually produced. `stdout`/`stderr` are
/// owned by the caller's allocator.
pub const ExecOutcome = struct {
    code: u32,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: ExecOutcome, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

/// How far `execUnderPolicy` got.
pub const ExecAttempt = union(enum) {
    /// The command is not on `sb.exec_allow`.
    not_allowed,
    /// On the allowlist, but the argv tripped the policy.
    denied: ExecDenial,
    /// Allowed and gated, but the process could not be run.
    failed: anyerror,
    ran: ExecOutcome,
};

/// The ck_exec gate for a caller that is not a WASM guest: resolves the
/// command through PATH, runs it past `execAllowed` + `execDenial`, and spawns
/// it with the same filtered environment (`execEnvironment`) a guest gets, so
/// an allowed binary still cannot print this project's API keys.
///
/// `clanker repl`'s `!` shell escape is the caller. It exists so that escape
/// is *not* a raw shell: it runs a fixed argv through the same policy a tool
/// goes through, with no shell interposed to expand globs, variables, pipes or
/// redirections. There is deliberately no caller-supplied `cwd`, no stdin and
/// no shell here; the child runs at the sandbox root, the same directory every
/// ck_fs_* path resolves under.
pub fn execUnderPolicy(
    sb: *const Sandbox,
    argv_in: []const []const u8,
    stdout_limit: usize,
    stderr_limit: usize,
) ExecAttempt {
    if (argv_in.len == 0 or argv_in[0].len == 0) return .not_allowed;
    const cmd = argv_in[0];
    if (!execAllowed(sb.exec_allow, cmd)) {
        log.log(.warn, "[exec] '{s}' is not on the caller's exec allowlist ({d} command(s))", .{ cmd, sb.exec_allow.len });
        return .not_allowed;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(sb.gpa);
    const resolved = resolveExecPath(sb.gpa, sb.io, sb.environ_map, cmd);
    defer if (resolved) |r| sb.gpa.free(r);
    argv.append(sb.gpa, resolved orelse cmd) catch return .{ .failed = error.OutOfMemory };
    argv.appendSlice(sb.gpa, argv_in[1..]) catch return .{ .failed = error.OutOfMemory };

    if (execDenial(sb, cmd, argv.items)) |d| {
        // A denial can name argv[0], which is the PATH-resolved path freed
        // with this frame. Report the command as the caller named it instead,
        // so the reason outlives the call. Tokens are static (exec_deny_tokens
        // / shell_op_deny_tokens) and the remaining arguments belong to the
        // caller, so only argv[0] needs the swap.
        const outlives = struct {
            fn arg(x: DeniedArg, argv0: []const u8, named: []const u8) DeniedArg {
                return .{ .token = x.token, .arg = if (x.arg.ptr == argv0.ptr) named else x.arg };
            }
        };
        return .{ .denied = switch (d) {
            .deny_token => |x| .{ .deny_token = outlives.arg(x, argv.items[0], cmd) },
            .shell_operator => |x| .{ .shell_operator = outlives.arg(x, argv.items[0], cmd) },
            .foreign_worktree => |a| .{ .foreign_worktree = if (a.ptr == argv.items[0].ptr) cmd else a },
            .host_path => |a| .{ .host_path = if (a.ptr == argv.items[0].ptr) cmd else a },
            else => d,
        } };
    }

    var child_env = execEnvironment(sb.gpa, sb) catch |err| return .{ .failed = err };
    defer child_env.deinit();

    log.log(.info, "[exec] → {s}", .{cmd});
    // Same root as ckExec and the ck_fs_* calls: the `!` escape has to see the
    // tree the tools see, or an isolated run's shell-out reports on the shared
    // checkout instead.
    var root_dir: std.Io.Dir = std.Io.Dir.cwd();
    var root_opened = false;
    if (!rootIsProcessCwd(sb.root_dir)) {
        if (std.Io.Dir.cwd().openDir(sb.io, sb.root_dir, .{})) |d| {
            root_dir = d;
            root_opened = true;
        } else |err| {
            log.log(.warn, "[exec] could not open sandbox root '{s}': {s}", .{ sb.root_dir, @errorName(err) });
            return .{ .failed = err };
        }
    }
    defer if (root_opened) root_dir.close(sb.io);
    const result = std.process.run(sb.gpa, sb.io, .{
        .argv = argv.items,
        .cwd = .{ .dir = root_dir },
        .environ_map = &child_env,
        .stdout_limit = .limited(stdout_limit),
        .stderr_limit = .limited(stderr_limit),
    }) catch |err| {
        log.log(.warn, "[exec] ✗ {s}, failed to run: {s}", .{ cmd, @errorName(err) });
        return .{ .failed = err };
    };
    return .{ .ran = .{
        .code = switch (result.term) {
            .exited => |c| c,
            else => 1,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    } };
}

/// `execUnderPolicy` for deterministic lifecycle integrations that need a
/// bounded JSON payload on stdin. It deliberately repeats no policy logic:
/// command resolution, allowlisting and argv denial call the same helpers as
/// the interactive escape above. Output collection and the child lifetime
/// share one monotonic deadline through `MultiReader.fill`.
pub fn execUnderPolicyInput(
    sb: *const Sandbox,
    argv_in: []const []const u8,
    input: []const u8,
    stdout_limit: usize,
    stderr_limit: usize,
    timeout_ms: u32,
    project_dir: []const u8,
) ExecAttempt {
    if (argv_in.len == 0 or argv_in[0].len == 0) return .not_allowed;
    const cmd = argv_in[0];
    if (!execAllowed(sb.exec_allow, cmd)) return .not_allowed;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(sb.gpa);
    const resolved = resolveExecPath(sb.gpa, sb.io, sb.environ_map, cmd);
    defer if (resolved) |r| sb.gpa.free(r);
    argv.append(sb.gpa, resolved orelse cmd) catch return .{ .failed = error.OutOfMemory };
    argv.appendSlice(sb.gpa, argv_in[1..]) catch return .{ .failed = error.OutOfMemory };
    if (execDenial(sb, cmd, argv.items)) |denial| {
        const outlives = struct {
            fn arg(x: DeniedArg, argv0: []const u8, named: []const u8) DeniedArg {
                return .{ .token = x.token, .arg = if (x.arg.ptr == argv0.ptr) named else x.arg };
            }
        };
        return .{ .denied = switch (denial) {
            .deny_token => |x| .{ .deny_token = outlives.arg(x, argv.items[0], cmd) },
            .shell_operator => |x| .{ .shell_operator = outlives.arg(x, argv.items[0], cmd) },
            .foreign_worktree => |a| .{ .foreign_worktree = if (a.ptr == argv.items[0].ptr) cmd else a },
            .host_path => |a| .{ .host_path = if (a.ptr == argv.items[0].ptr) cmd else a },
            else => denial,
        } };
    }

    var child_env = execEnvironment(sb.gpa, sb) catch |err| return .{ .failed = err };
    defer child_env.deinit();
    child_env.put("CLAUDE_PROJECT_DIR", project_dir) catch |err| return .{ .failed = err };

    var root_dir: std.Io.Dir = std.Io.Dir.cwd();
    var root_opened = false;
    if (!rootIsProcessCwd(sb.root_dir)) {
        root_dir = std.Io.Dir.cwd().openDir(sb.io, sb.root_dir, .{}) catch |err| return .{ .failed = err };
        root_opened = true;
    }
    defer if (root_opened) root_dir.close(sb.io);

    var child = std.process.spawn(sb.io, .{
        .argv = argv.items,
        .cwd = .{ .dir = root_dir },
        .environ_map = &child_env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| return .{ .failed = err };
    defer child.kill(sb.io);

    if (child.stdin) |stdin_file| {
        var buffer: [4096]u8 = undefined;
        var writer = stdin_file.writer(sb.io, &buffer);
        // A hook that never reads stdin (printf, echo) can exit before we
        // finish the write; the pipe then returns WriteFailed. That is not
        // a failed hook, the child's stdout still carries the decision.
        writer.interface.writeAll(input) catch {};
        writer.interface.flush() catch {};
        stdin_file.close(sb.io);
        child.stdin = null;
    }

    var multi_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi: std.Io.File.MultiReader = undefined;
    multi.init(sb.gpa, sb.io, multi_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();
    const stdout_reader = multi.reader(0);
    const stderr_reader = multi.reader(1);
    const timeout: std.Io.Timeout = if (timeout_ms == 0) .none else .{ .deadline = .fromNow(sb.io, .{
        .clock = .awake,
        .raw = .{ .nanoseconds = @as(i96, timeout_ms) * std.time.ns_per_ms },
    }) };
    while (multi.fill(64, timeout)) |_| {
        if (stdout_reader.buffered().len > stdout_limit or stderr_reader.buffered().len > stderr_limit)
            return .{ .failed = error.StreamTooLong };
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return .{ .failed = e },
    }
    multi.checkAnyError() catch |err| return .{ .failed = err };
    const term = child.wait(sb.io) catch |err| return .{ .failed = err };
    const stdout = multi.toOwnedSlice(0) catch |err| return .{ .failed = err };
    errdefer sb.gpa.free(stdout);
    const stderr = multi.toOwnedSlice(1) catch |err| return .{ .failed = err };
    return .{ .ran = .{
        .code = switch (term) {
            .exited => |code| code,
            else => 1,
        },
        .stdout = stdout,
        .stderr = stderr,
    } };
}

/// Keeps the head of `text`, ending on a line boundary so the last line is
/// whole rather than a fragment that reads as corrupted output.
fn clipOutput(text: []const u8, keep: usize) []const u8 {
    if (text.len <= keep) return text;
    const head = text[0..keep];
    if (std.mem.findScalarLast(u8, head, '\n')) |nl| return head[0 .. nl + 1];
    return head;
}

// ------------------------------------------------------------- sandbox core --

/// Resolves a tool-supplied path against the sandbox root, rejecting absolute
/// paths, any `..` / `.` component, and anything outside the tool's allowed
/// prefix list. Returns an allocated joined path.
/// Runs `argv` with `input` on its stdin and returns its output, for tools that
/// hold a conversation with a process (LSP over stdio) rather than firing one
/// off. Kept beside ckExec rather than inside it so the common path stays the
/// std.process.run one-liner.
fn execWithStdin(
    h: *Host,
    mem_bytes: []u8,
    argv: []const []const u8,
    exec_dir: std.Io.Dir,
    environ_map: *std.process.Environ.Map,
    input: []const u8,
    cmd: []const u8,
) u32 {
    const gpa = h.sandbox.gpa;
    const io = h.sandbox.io;

    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = exec_dir },
        .environ_map = environ_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        log.log(.warn, "[exec] {s} failed to spawn: {s}", .{ cmd, @errorName(err) });
        return switch (err) {
            error.FileNotFound => Err.not_found,
            else => Err.invalid,
        };
    };
    defer child.kill(io);

    // Write everything, then close: a server reading framed messages waits for
    // EOF (or a shutdown message) before exiting, and an open pipe would hang
    // the read below forever.
    if (child.stdin) |stdin_file| {
        var wbuf: [4096]u8 = undefined;
        var writer = stdin_file.writer(io, &wbuf);
        writer.interface.writeAll(input) catch {};
        writer.interface.flush() catch {};
        stdin_file.close(io);
        child.stdin = null;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    if (child.stdout) |stdout_file| {
        var rbuf: [8192]u8 = undefined;
        var reader = stdout_file.reader(io, &rbuf);
        while (true) {
            const chunk = reader.interface.peekGreedy(1) catch break;
            out.appendSlice(gpa, chunk) catch break;
            reader.interface.toss(chunk.len);
            if (out.items.len > 512 * 1024) break;
        }
    }

    const term = child.wait(io) catch return Err.invalid;
    const code: u32 = switch (term) {
        .exited => |c| c,
        else => 0,
    };
    const wbuf = gpa.alloc(u8, 640 * 1024) catch return Err.too_large;
    defer gpa.free(wbuf);
    var w: std.Io.Writer = .fixed(wbuf);
    writeExecResult(&w, code, out.items, "") catch return Err.too_large;
    return h.writeResult(mem_bytes, wbuf[0..w.end]);
}

/// A JSON array of strings as a slice, ignoring anything that is not a string.
fn stringArray(arena: std.mem.Allocator, value: ?std.json.Value) ![]const []const u8 {
    const v = value orelse return &.{};
    if (v != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (v.array.items) |item| {
        if (item == .string and item.string.len > 0) try out.append(arena, item.string);
    }
    return out.toOwnedSlice(arena);
}

/// Apply the lexical policy and reject every existing symlink component.
/// Host filesystem APIs follow symlinks, so the lexical check alone would let
/// `allowed/link/secret` escape when `allowed/link` points outside the root.
fn safeJoinSecure(sb: *const Sandbox, sub_path: []const u8) ![]u8 {
    const full = try safeJoin(sb, sub_path);
    errdefer sb.gpa.free(full);

    // Opted in (ADR 0017): the prefix grant from safeJoin above still decides
    // what may be touched; this only allows a component of that granted path
    // to be a link.
    if (sb.follow_symlinks) return full;

    // Check components from the root down. Once a component is absent, all
    // remaining components are absent too; write operations may create them.
    // This is deliberately no-follow so the symlink itself is visible.
    var end: usize = if (full.len > 0 and full[0] == '/') 1 else 0;
    while (end < full.len) {
        end = std.mem.findScalarPos(u8, full, end, '/') orelse full.len;
        if (end > 0) {
            const stat = std.Io.Dir.cwd().statFile(sb.io, full[0..end], .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => break,
                else => return err,
            };
            if (stat.kind == .sym_link) return error.PathOutsideSandbox;
        }
        if (end == full.len) break;
        end += 1;
    }
    return full;
}

/// Paths that belong to the checkout rather than to any one run's tree: the
/// things git does not track and every run shares. A run isolated in a worktree
/// resolves these against `Sandbox.shared_root` instead of its own root, so it
/// sees the same runtime state, credentials and coordination files it would
/// have seen without isolation. Keep in step with .gitignore.
///
/// Deliberately NOT shared: `zig-out` and `.zig-cache`. Both are untracked, so
/// the rule above would include them, but builds WRITE there -- a shared
/// zig-out lets a worktree's build clobber the binaries the checkout is using,
/// including the clanker binary that is running, and two trees installing into
/// one zig-out made the gate flaky (see linkSharedState in
/// src/improve/worktree.zig). Guest wasm modules, the part a run actually needs
/// to read, are pinned to the harness's own build instead
/// (Registry.rebaseWasmPaths), which is read-only and cannot collide.
pub const shared_prefixes = [_][]const u8{
    "state",
    ".local",
    ".agents",
    ".claude",
    ".env",
    "config.local.toml",
    "config.local.json",
};

/// Which root `sub_path` resolves against: the checkout for the shared,
/// untracked paths above, the run's own tree for everything else. Matching is
/// at a path boundary, so "state" and "state/x" are shared while a tracked
/// sibling that merely starts with the same bytes ("stateful.zig") is not.
fn rootForPath(sb: *const Sandbox, sub_path: []const u8) []const u8 {
    if (sb.shared_root.len == 0) return sb.root_dir;
    for (shared_prefixes) |p| {
        if (!std.mem.startsWith(u8, sub_path, p)) continue;
        if (sub_path.len == p.len or sub_path[p.len] == '/') return sb.shared_root;
    }
    return sb.root_dir;
}

/// True when `root_dir` names the process cwd itself, so an exec'd child needs
/// no explicit directory. Spelled out rather than compared against "." alone
/// because the config accepts the equivalent forms, and opening a directory we
/// are already in would only add a failure mode ("" is not a valid path).
fn rootIsProcessCwd(root_dir: []const u8) bool {
    return root_dir.len == 0 or
        std.mem.eql(u8, root_dir, ".") or
        std.mem.eql(u8, root_dir, "./");
}

/// True when `sub_path` names a dotenv file (or a path under one). Those
/// files hold the API keys env_allow exists to keep out of guest memory.
/// The rule itself is shared with the HTTP file browser:
/// `util/secret_dotenv.zig` owns which names count, here we only apply it to
/// every component of the sub_path.
fn isSecretDotenv(sub_path: []const u8) bool {
    return secret_dotenv.isSecretDotenvPath(sub_path);
}

/// Whether any `fs_prefixes` entry authorizes `sub_path` relative to one root.
/// "." authorizes the whole root; a bare prefix authorizes itself and every
/// path beneath it. Extracted from `safeJoin` so the multi-root branch checks
/// the same grant list against a named root's remainder.
fn fsPrefixAllows(prefixes: []const []const u8, sub_path: []const u8) bool {
    for (prefixes) |p| {
        // An empty entry names nothing, so it authorizes nothing -- the same
        // rule an empty list follows. It used to fall through to the boundary
        // check below, where `startsWith(sub_path, "")` is always true and the
        // `p.len == 0` arm returned true for every path: one stray "" in a
        // descriptor silently granted the whole sandbox root. `manifest.zig`
        // skips empty entries when validating, so nothing warned either.
        if (p.len == 0) continue;
        if (std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, "./")) return true;
        if (std.mem.startsWith(u8, sub_path, p)) {
            // The match must end at a path boundary: a bare prefix ("notes")
            // authorizes the directory itself and paths beneath it, but never
            // a sibling that merely shares the leading bytes ("notes2/x").
            if (p[p.len - 1] == '/' or sub_path.len == p.len or sub_path[p.len] == '/') return true;
        }
        // A prefix of "state/runs/" also authorizes "state/runs" itself,
        // otherwise a tool allowed to read inside a directory cannot list the
        // directory to find out what is in it.
        if (p.len > 1 and p[p.len - 1] == '/' and std.mem.eql(u8, sub_path, p[0 .. p.len - 1])) return true;
    }
    return false;
}

/// The named extra root whose name is the first path component of `sub_path`,
/// if any. `rest` is the remainder after the name ("" when the guest named the
/// root directory itself).
const RootSelect = struct {
    root: config_mod.SandboxRoot,
    rest: []const u8,
};

fn selectExtraRoot(sb: *const Sandbox, sub_path: []const u8) ?RootSelect {
    if (sb.extra_roots.len == 0) return null;
    var first = sub_path;
    var rest: []const u8 = "";
    if (std.mem.findScalar(u8, sub_path, '/')) |slash| {
        first = sub_path[0..slash];
        rest = sub_path[slash + 1 ..];
    }
    if (first.len == 0) return null;
    for (sb.extra_roots) |r| {
        if (std.mem.eql(u8, r.name, first)) {
            return .{ .root = r, .rest = rest };
        }
    }
    return null;
}

fn safeJoin(sb: *const Sandbox, sub_path: []const u8) ![]u8 {
    if (sub_path.len > 0 and sub_path[0] == '/') return safeJoinAbsolute(sb, sub_path);
    // .env is where the process loads API keys. env_allow exists so those
    // values never cross into guest memory via ck_env; reading the file
    // through ck_fs_* with fs_prefixes ["."] was the same leak by another
    // door. `.environment` is a different name and is not refused.
    if (isSecretDotenv(sub_path)) return error.PathOutsideSandbox;
    // The root itself, written "" or ".". Without this no host call could
    // address the sandbox root: listing or searching the project as a whole
    // was refused, and a tool given fs_prefixes ["."] still could not ask what
    // was in it. Only a tool allowed everywhere gets the root; one confined to
    // src/ has no business enumerating the tree above it.
    if (sub_path.len == 0 or std.mem.eql(u8, sub_path, ".") or std.mem.eql(u8, sub_path, "./")) {
        var root_ok = false;
        for (sb.fs_prefixes) |p| {
            if (std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, "./")) root_ok = true;
        }
        if (!root_ok) return error.PathOutsideSandbox;
        return sb.gpa.dupe(u8, std.mem.trimEnd(u8, sb.root_dir, "/"));
    }
    var it = std.mem.splitScalar(u8, sub_path, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..") or std.mem.eql(u8, comp, ".")) return error.PathOutsideSandbox;
        if (comp.len == 0) return error.PathOutsideSandbox;
    }
    // Multi-root: a first component naming one of the workspace's extra roots
    // selects that root; the rest is checked against the same prefix list and
    // resolved under the root's own directory. A bare path keeps resolving
    // under `root_dir`, so a single-root run is byte-for-byte the old path.
    if (selectExtraRoot(sb, sub_path)) |sel| {
        if (!fsPrefixAllows(sb.fs_prefixes, sel.rest)) return error.PathOutsideSandbox;
        const base = std.mem.trimEnd(u8, sel.root.path, "/");
        if (sel.rest.len == 0) return sb.gpa.dupe(u8, base);
        return std.fmt.allocPrint(sb.gpa, "{s}/{s}", .{ base, sel.rest });
    }
    // An empty list is no authority, not unlimited authority. This used to
    // skip the check entirely, so a descriptor written as "fs_prefixes":
    // [] - which reads as "this tool touches no files" and is what the
    // documentation says it means - handed the tool every file under the
    // sandbox root instead. Least privilege has to be the default that
    // costs nothing to ask for.
    if (!fsPrefixAllows(sb.fs_prefixes, sub_path)) return error.PathOutsideSandbox;
    return std.fmt.allocPrint(sb.gpa, "{s}/{s}", .{ std.mem.trimEnd(u8, rootForPath(sb, sub_path), "/"), sub_path });
}

/// An absolute guest path is allowed only when some `fs_prefixes` entry is
/// itself absolute and the path sits on or under that prefix. This is how a
/// plugins/tools guest lists an out-of-tree `agent.tools_dir` without opening
/// every host-absolute path.
fn safeJoinAbsolute(sb: *const Sandbox, sub_path: []const u8) ![]u8 {
    if (isSecretDotenv(sub_path)) return error.PathOutsideSandbox;
    var it = std.mem.splitScalar(u8, sub_path[1..], '/');
    while (it.next()) |comp| {
        if (comp.len == 0) return error.PathOutsideSandbox;
        if (std.mem.eql(u8, comp, "..") or std.mem.eql(u8, comp, ".")) return error.PathOutsideSandbox;
    }
    var allowed = false;
    for (sb.fs_prefixes) |p| {
        if (p.len == 0 or p[0] != '/') continue;
        const prefix = std.mem.trimEnd(u8, p, "/");
        if (std.mem.eql(u8, sub_path, prefix)) {
            allowed = true;
            break;
        }
        if (std.mem.startsWith(u8, sub_path, prefix) and sub_path.len > prefix.len and sub_path[prefix.len] == '/') {
            allowed = true;
            break;
        }
    }
    if (!allowed) return error.PathOutsideSandbox;
    return sb.gpa.dupe(u8, sub_path);
}

test "secure filesystem paths refuse symlink escapes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "allowed", .default_dir);
    try tmp.dir.createDir(io, "outside", .default_dir);
    try tmp.dir.symLink(io, "../outside", "allowed/link", .{ .is_directory = true });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = root_buf[0..root_len],
        .network_allow = &.{},
        .fs_prefixes = &.{"allowed/"},
        .environ_map = &env,
    };
    try std.testing.expectError(error.PathOutsideSandbox, safeJoinSecure(&sb, "allowed/link/secret"));
}

test "a named extra root resolves the remainder under that root" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "core/src");
    try tmp.dir.createDirPath(io, "web/src");

    const core = try tmp.dir.realPathFileAlloc(io, "core", std.testing.allocator);
    defer std.testing.allocator.free(core);
    const web = try tmp.dir.realPathFileAlloc(io, "web", std.testing.allocator);
    defer std.testing.allocator.free(web);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = core,
        .extra_roots = &.{.{ .name = "web", .path = web }},
        .network_allow = &.{},
        .fs_prefixes = &.{"."},
        .environ_map = &env,
    };

    // Bare paths still resolve under the primary root.
    const core_src = try safeJoinSecure(&sb, "src");
    defer sb.gpa.free(core_src);
    try std.testing.expect(std.mem.endsWith(u8, core_src, "/core/src"));

    // A root-named path resolves under the extra root.
    const web_src = try safeJoinSecure(&sb, "web/src");
    defer sb.gpa.free(web_src);
    try std.testing.expect(std.mem.endsWith(u8, web_src, "/web/src"));

    // The root directory itself is listable for a tool granted ".".
    const web_root = try safeJoinSecure(&sb, "web");
    defer sb.gpa.free(web_root);
    try std.testing.expect(std.mem.endsWith(u8, web_root, "/web"));

    // Traversal is refused before any root is selected.
    try std.testing.expectError(error.PathOutsideSandbox, safeJoinSecure(&sb, "web/../core"));

    // A prefix-restricted tool reaches the same prefix under the named root.
    var narrow = Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = core,
        .extra_roots = &.{.{ .name = "web", .path = web }},
        .network_allow = &.{},
        .fs_prefixes = &.{"src"},
        .environ_map = &env,
    };
    const narrow_web = try safeJoinSecure(&narrow, "web/src");
    defer narrow.gpa.free(narrow_web);
    try std.testing.expect(std.mem.endsWith(u8, narrow_web, "/web/src"));
    try std.testing.expectError(error.PathOutsideSandbox, safeJoinSecure(&narrow, "web/other"));
}

// ------------------------------------------------------------------- tests --

test "a shell operator in a search pattern is allowed, but not when running a shell" {
    // A real review run was refused the pattern "jsonInt|float => |@intFromFloat"
    // because it contains a greater-than sign. Nothing interprets it: argv goes
    // to execve, and rg reads it as a pattern.
    const pattern = "jsonInt|float => |@intFromFloat";
    for (exec_deny_tokens) |t| {
        try std.testing.expect(!argDenied(pattern, t));
    }
    // Redirection into a shell is still refused, because a shell would act on it.
    try std.testing.expect(runsAShell("sh"));
    try std.testing.expect(runsAShell("/bin/bash"));
    try std.testing.expect(!runsAShell("rg"));
    try std.testing.expect(!runsAShell("git"));
    var denied = false;
    for (shell_op_deny_tokens) |t| {
        if (argDenied("cat /etc/passwd > /tmp/out", t)) denied = true;
    }
    try std.testing.expect(denied);

    // Destructive git verbs stay refused for every command.
    try std.testing.expect(argDenied("push", "push"));
    try std.testing.expect(argDenied("--force", "--force"));
}

test "exec_deny_tokens does not block regex alternation but still blocks real danger" {
    for (exec_deny_tokens) |t| {
        try std.testing.expect(!std.mem.eql(u8, t, "|"));
    }
    var has_rm = false;
    var has_force = false;
    for (exec_deny_tokens) |t| {
        if (std.mem.eql(u8, t, "rm")) has_rm = true;
        if (std.mem.eql(u8, t, "--force")) has_force = true;
    }
    try std.testing.expect(has_rm);
    try std.testing.expect(has_force);
}

test "argDenied matches operator tokens anywhere, word tokens only at boundaries" {
    try std.testing.expect(argDenied("a|b|c", "|"));
    try std.testing.expect(argDenied("rm", "rm"));
    try std.testing.expect(!argDenied("gcc", "gc"));
    try std.testing.expect(argDenied("gc", "gc"));
    try std.testing.expect(argDenied("-force", "-f"));
    try std.testing.expect(argDenied("--force", "--force"));
}

test "skipGrepName skips binary artifacts and leaves source names alone" {
    try std.testing.expect(skipGrepName("app.wasm"));
    try std.testing.expect(skipGrepName("mascot.PNG"));
    try std.testing.expect(skipGrepName("libfoo.dylib"));
    try std.testing.expect(skipGrepName("bundle.js.map"));
    try std.testing.expect(skipGrepName("app.sqlite"));
    try std.testing.expect(!skipGrepName("loop.zig"));
    try std.testing.expect(!skipGrepName("README.md"));
    try std.testing.expect(!skipGrepName(".gitignore"));
}

test "find and grep share the same result cap" {
    try std.testing.expectEqual(fs_grep_max_results, fs_find_max_results);
}

test "globMatch handles basic patterns" {
    // Exact match
    try std.testing.expect(globMatch("foo.zig", "foo.zig"));
    try std.testing.expect(!globMatch("foo.zig", "bar.zig"));
    // Star wildcard
    try std.testing.expect(globMatch("*.zig", "foo.zig"));
    try std.testing.expect(globMatch("*.zig", ".zig"));
    try std.testing.expect(!globMatch("*.zig", "foo.txt"));
    try std.testing.expect(globMatch("foo.*", "foo.txt"));
    try std.testing.expect(globMatch("foo.*", "foo."));
    try std.testing.expect(globMatch("*", "anything"));
    try std.testing.expect(globMatch("*", ""));
    // Question mark wildcard
    try std.testing.expect(globMatch("?.zig", "a.zig"));
    try std.testing.expect(!globMatch("?.zig", "ab.zig"));
    try std.testing.expect(!globMatch("?.zig", ".zig"));
    // Mixed
    try std.testing.expect(globMatch("test_*.zig", "test_foo.zig"));
    try std.testing.expect(!globMatch("test_*.zig", "best_foo.zig"));
    // Multiple stars
    try std.testing.expect(globMatch("*foo*", "xfooy"));
    try std.testing.expect(globMatch("*foo*", "foo"));
    try std.testing.expect(!globMatch("*foo*", "bar"));
    // Empty pattern matches only empty name
    try std.testing.expect(globMatch("", ""));
    try std.testing.expect(!globMatch("", "x"));
}

test "isGitRemoteOpToken lifts exactly the PR lifecycle verbs" {
    try std.testing.expect(isGitRemoteOpToken("push"));
    try std.testing.expect(isGitRemoteOpToken("merge"));
    try std.testing.expect(isGitRemoteOpToken("checkout"));
    try std.testing.expect(!isGitRemoteOpToken("reset"));
    try std.testing.expect(!isGitRemoteOpToken("rebase"));
    try std.testing.expect(!isGitRemoteOpToken("fetch"));
    try std.testing.expect(!isGitRemoteOpToken("-f"));
}

test "git exec permits named local verbs and blocks network plumbing" {
    try std.testing.expect(gitVerbAllowed(&.{ "/usr/bin/git", "status", "--porcelain" }, false));
    try std.testing.expect(gitVerbAllowed(&.{ "git", "--no-pager", "log", "-1" }, false));
    try std.testing.expect(!gitVerbAllowed(&.{ "git", "ls-remote", "https://example.com/repo" }, false));
    try std.testing.expect(!gitVerbAllowed(&.{ "git", "archive", "--remote=https://example.com/repo" }, false));
    try std.testing.expect(!gitVerbAllowed(&.{ "git", "push" }, false));
    try std.testing.expect(gitVerbAllowed(&.{ "git", "push" }, true));
    // A value-taking global option must not be read as the verb. The operator
    // workflow drives a task worktree with `git -C <worktree> <verb>`; before
    // the fix, the worktree path after `-C` was mistaken for the subcommand
    // and denied.
    try std.testing.expect(gitVerbAllowed(&.{ "git", "-C", ".local/worktrees/wt", "status" }, false));
    try std.testing.expect(gitVerbAllowed(&.{ "git", "-C", ".local/worktrees/wt", "commit", "-m", "msg" }, false));
    // The verb-level check is not the final word: execDenial refuses
    // --git-dir/--git-common-dir outright (a fabricated git dir carries hooks
    // that run on commit), so the -C spelling above is the supported way to
    // address a worktree. These rows only pin that the verb is not the reason.
    try std.testing.expect(gitVerbAllowed(&.{ "git", "--git-dir=.local/worktrees/wt/.git", "--work-tree=.local/worktrees/wt", "add", "x" }, false));
    try std.testing.expect(gitVerbAllowed(&.{ "git", "--git-dir", ".local/worktrees/wt/.git", "--work-tree", ".local/worktrees/wt", "push", "origin", "branch" }, true));
    try std.testing.expect(!gitVerbAllowed(&.{ "git", "-C", ".local/worktrees/wt", "ls-remote" }, false));
}

test "git index verbs are allowed only in the forms that cannot touch the worktree" {
    // smart_commit builds each group's commit in the index so a hunk-narrowed
    // index is committed as staged. Only the index-only forms are granted.
    try std.testing.expect(gitVerbAllowed(&.{ "git", "write-tree" }, false));
    try std.testing.expect(gitVerbAllowed(&.{ "git", "read-tree", "HEAD" }, false));
    try std.testing.expect(gitVerbAllowed(&.{ "git", "read-tree", "--empty" }, false));
    try std.testing.expect(gitVerbAllowed(&.{ "git", "restore", "--staged", "--source=abc123", "--", "a.zig" }, false));

    // `git read-tree -u` writes the working tree, and `git restore` without
    // --staged overwrites worktree files -- that is what `checkout` is denied
    // for, so neither form may ride in on the new grant.
    try std.testing.expect(!gitVerbAllowed(&.{ "git", "read-tree", "-u", "--reset", "HEAD" }, false));
    try std.testing.expect(!gitVerbAllowed(&.{ "git", "read-tree", "--update", "HEAD" }, false));
    try std.testing.expect(!gitVerbAllowed(&.{ "git", "restore", "--", "a.zig" }, false));
    try std.testing.expect(!gitVerbAllowed(&.{ "git", "restore", "--staged", "--worktree", "--", "a.zig" }, false));
    try std.testing.expect(!gitVerbAllowed(&.{ "git", "restore", "--staged", "-W", "--", "a.zig" }, false));
}

test "patternNamesCmd matches only the first command token" {
    try std.testing.expect(patternNamesCmd("gh pr create*", "gh"));
    try std.testing.expect(patternNamesCmd("git push*", "git"));
    try std.testing.expect(!patternNamesCmd("gh pr create*", "git"));
    try std.testing.expect(!patternNamesCmd("gh pr create*", "ghh"));
    // A globbed command token cannot name a command, so it never makes it strict.
    try std.testing.expect(!patternNamesCmd("gh* pr", "gh"));
}

test "execPolicyFor: a pattern makes a command strict, matching argv is granted" {
    var sb = Sandbox{
        .gpa = undefined,
        .io = undefined,
        .root_dir = ".",
        .network_allow = &.{},
        .fs_prefixes = &.{},
        .environ_map = undefined,
        .exec_pattern_allow = &.{ "gh pr create*", "gh pr merge*" },
    };
    var join: [4096]u8 = undefined;
    const gh_create = [_][]const u8{ "gh", "pr", "create", "12", "--base", "main" };
    var p = execPolicyFor(&sb, &gh_create, &join);
    try std.testing.expect(p.governed);
    try std.testing.expect(p.allowed);
    const gh_merge = [_][]const u8{ "gh", "pr", "merge", "12" };
    p = execPolicyFor(&sb, &gh_merge, &join);
    try std.testing.expect(p.governed);
    try std.testing.expect(p.allowed);
    // A gh invocation outside the whitelist is governed but not allowed.
    const gh_issue = [_][]const u8{ "gh", "issue", "create", "foo" };
    p = execPolicyFor(&sb, &gh_issue, &join);
    try std.testing.expect(p.governed);
    try std.testing.expect(!p.allowed);
    // A command with no pattern (git) is not governed at all.
    const git_status = [_][]const u8{ "git", "status" };
    p = execPolicyFor(&sb, &git_status, &join);
    try std.testing.expect(!p.governed);
    try std.testing.expect(!p.allowed);
}

test "execPolicyFor: resolved absolute argv[0] still governs and allows" {
    var sb = Sandbox{
        .gpa = undefined,
        .io = undefined,
        .root_dir = ".",
        .network_allow = &.{},
        .fs_prefixes = &.{},
        .environ_map = undefined,
        .exec_pattern_allow = &.{ "gh pr create*", "gh pr merge*" },
    };
    var join: [4096]u8 = undefined;
    // ckExec resolves bare commands through PATH, so argv[0] is an absolute
    // path (/usr/bin/gh) while the pattern names the command by its basename.
    // `gh pr merge` must be governed AND allowed, or the deny-list would
    // refuse the `merge` token that the pattern explicitly grants.
    const gh_merge = [_][]const u8{ "/usr/bin/gh", "pr", "merge", "12" };
    const p = execPolicyFor(&sb, &gh_merge, &join);
    try std.testing.expect(p.governed);
    try std.testing.expect(p.allowed);
    const gh_create = [_][]const u8{ "/usr/local/bin/gh", "pr", "create", "--base", "main" };
    const pc = execPolicyFor(&sb, &gh_create, &join);
    try std.testing.expect(pc.governed);
    try std.testing.expect(pc.allowed);
}

test "execPolicyFor: no patterns leaves everything ungoverned" {
    var sb = Sandbox{
        .gpa = undefined,
        .io = undefined,
        .root_dir = ".",
        .network_allow = &.{},
        .fs_prefixes = &.{},
        .environ_map = undefined,
    };
    var join: [4096]u8 = undefined;
    const gh = [_][]const u8{ "gh", "pr", "create" };
    const p = execPolicyFor(&sb, &gh, &join);
    try std.testing.expect(!p.governed);
    try std.testing.expect(!p.allowed);
}

test "execDenial: the argv-level gate ckExec and the REPL escape share" {
    var sb = Sandbox{
        .gpa = undefined,
        .io = undefined,
        .root_dir = ".",
        .network_allow = &.{},
        .fs_prefixes = &.{},
        .environ_map = undefined,
        .exec_allow = &.{ "git", "rg", "sh" },
    };

    // An ordinary read-only argv passes.
    try std.testing.expect(execDenial(&sb, "git", &.{ "/usr/bin/git", "status" }) == null);
    try std.testing.expect(execDenial(&sb, "rg", &.{ "/usr/bin/rg", "needle", "src" }) == null);

    // A deny-list token refuses the argv, and the caller learns which token in
    // which argument so it can say so.
    const forced = execDenial(&sb, "rg", &.{ "/usr/bin/rg", "--force" }) orelse
        return error.TestExpectedDenial;
    try std.testing.expectEqualStrings("--force", forced.deny_token.token);
    try std.testing.expectEqualStrings("--force", forced.deny_token.arg);

    // For `git` the verb allowlist is consulted first, so a destructive verb
    // is refused as an unlisted verb rather than as a deny token, the same
    // refusal either way, but the precedence is worth pinning.
    try std.testing.expect(execDenial(&sb, "git", &.{ "/usr/bin/git", "reset", "--hard" }).? == .git_verb);
    try std.testing.expect(execDenial(&sb, "git", &.{ "/usr/bin/git", "ls-remote" }).? == .git_verb);
    // ...and git_remote_ops lifts exactly the PR-lifecycle verbs.
    try std.testing.expect(execDenial(&sb, "git", &.{ "/usr/bin/git", "push" }) != null);
    sb.git_remote_ops = true;
    try std.testing.expect(execDenial(&sb, "git", &.{ "/usr/bin/git", "push" }) == null);
    sb.git_remote_ops = false;

    // Shell operators are refused only when the command is itself a shell:
    // ">" is ordinary pattern syntax to rg.
    try std.testing.expect(execDenial(&sb, "rg", &.{ "/usr/bin/rg", "a > b" }) == null);
    const shell_op = execDenial(&sb, "sh", &.{ "/bin/sh", "-c", "a > b" }) orelse
        return error.TestExpectedDenial;
    try std.testing.expectEqualStrings(">", shell_op.shell_operator.token);

    // A pattern makes its command strict; a non-matching argv is refused even
    // though nothing on the deny list appears in it.
    sb.exec_pattern_allow = &.{"gh pr create*"};
    sb.exec_allow = &.{"gh"};
    try std.testing.expect(execDenial(&sb, "gh", &.{ "/usr/bin/gh", "pr", "create" }) == null);
    try std.testing.expect(execDenial(&sb, "gh", &.{ "/usr/bin/gh", "issue", "list" }).? == .no_pattern_match);

    // Another run's worktree is refused ahead of every rule above, so a
    // pattern cannot grant it. `gh` is still the pattern-governed command
    // here, and `gh pr create*` still matches this argv.
    const foreign = execDenial(&sb, "gh", &.{ "/usr/bin/gh", "pr", "create", "-F", ".clanker-worktrees/123/body.md" }) orelse
        return error.TestExpectedDenial;
    try std.testing.expectEqualStrings(".clanker-worktrees/123/body.md", foreign.foreign_worktree);

    // ...and ahead of the git verb allowlist, so the refusal names the real
    // reason rather than blaming the verb.
    sb.exec_pattern_allow = &.{};
    sb.exec_allow = &.{"git"};
    try std.testing.expect(execDenial(&sb, "git", &.{ "/usr/bin/git", "-C", ".clanker-worktrees/123", "status" }).? == .foreign_worktree);
    try std.testing.expect(execDenial(&sb, "git", &.{ "/usr/bin/git", "-C", "../123", "status" }).? == .foreign_worktree);
    // The run's own tree is `.`, which is unaffected.
    try std.testing.expect(execDenial(&sb, "git", &.{ "/usr/bin/git", "-C", ".", "status" }) == null);

    // Host-absolute and `..` path args are refused for every command, including
    // ones that take a user path (rg, git -C, zig).
    sb.exec_allow = &.{ "git", "rg", "zig", "uv" };
    try std.testing.expect(execDenial(&sb, "rg", &.{ "/usr/bin/rg", "needle", "/etc/passwd" }).? == .host_path);
    try std.testing.expect(execDenial(&sb, "git", &.{ "/usr/bin/git", "-C", "/home/me", "status" }).? == .host_path);
    try std.testing.expect(execDenial(&sb, "git", &.{ "/usr/bin/git", "--git-dir=/etc/foo", "status" }).? == .host_path);
    try std.testing.expect(execDenial(&sb, "rg", &.{ "/usr/bin/rg", "needle", "src/../.env" }).? == .host_path);
    // The macOS home and mount roots are denied the same way the Linux ones
    // are, so the argv gate does not silently weaken on a mac checkout.
    try std.testing.expect(execDenial(&sb, "rg", &.{ "/usr/bin/rg", "needle", "/Users/me/secret" }).? == .host_path);
    try std.testing.expect(execDenial(&sb, "git", &.{ "/usr/bin/git", "-C", "/Volumes/data/clanker", "status" }).? == .host_path);
    try std.testing.expect(execDenial(&sb, "rg", &.{ "/usr/bin/rg", "needle", "/private/tmp/out" }).? == .host_path);
    // An rg regex that merely starts with '/' is not a host root, and `..`
    // in a pattern (not the last/path argument) is ordinary regex syntax.
    try std.testing.expect(execDenial(&sb, "rg", &.{ "/usr/bin/rg", "/foo/", "src" }) == null);
    try std.testing.expect(execDenial(&sb, "rg", &.{ "/usr/bin/rg", "foo/../bar", "src" }) == null);

    try std.testing.expect(execDenial(&sb, "zig", &.{ "/usr/bin/zig", "ast-check", "src/main.zig" }) == null);
    try std.testing.expect(execDenial(&sb, "zig", &.{ "/usr/bin/zig", "fmt", "--check", "src" }) == null);
    try std.testing.expect(execDenial(&sb, "zig", &.{ "/usr/bin/zig", "test", "src/foo.zig" }) == null);
    try std.testing.expect(execDenial(&sb, "zig", &.{ "/usr/bin/zig", "build" }) == null);
    try std.testing.expect(execDenial(&sb, "zig", &.{ "/usr/bin/zig", "fetch", "https://example.com/x" }).? == .zig_verb);
    try std.testing.expect(execDenial(&sb, "zig", &.{ "/usr/bin/zig", "run", "src/main.zig" }).? == .zig_verb);
    try std.testing.expect(execDenial(&sb, "zig", &.{ "/usr/bin/zig", "fmt", "src" }).? == .zig_verb);

    const uv_ok = [_][]const u8{ "/usr/bin/uv", "run", "--quiet", "--with", "opencv-python-headless~=4.14", "python3", "tools/py/opencv.py", "info", "pic.png" };
    try std.testing.expect(execDenial(&sb, "uv", &uv_ok) == null);
    try std.testing.expect(execDenial(&sb, "uv", &.{ "/usr/bin/uv", "pip", "install", "pwn" }).? == .uv_verb);
    try std.testing.expect(execDenial(&sb, "uv", &.{ "/usr/bin/uv", "run", "python3", "-c", "print(1)" }).? == .uv_verb);
    // A host-absolute --exec-path is refused as a path first (execArgPathDenied
    // runs ahead of the git block); a relative one reaches gitExecDeniedArg.
    try std.testing.expect(execDenial(&sb, "git", &.{ "/usr/bin/git", "--exec-path=/tmp/evil", "status" }).? == .host_path);
    try std.testing.expect(execDenial(&sb, "git", &.{ "/usr/bin/git", "--exec-path=./helpers", "status" }).? == .git_config);
    // execDenial-level assertions (git_config): `-c core.hooksPath=<dir>`
    // executes hook scripts on commit (verified), and `-c` values are exempt
    // from the deny-token scan, so the flag itself is the refused shape; a
    // git dir other than the run's own can carry a hook a caller fabricated.
    // (On git before 2.43 an `alias.*` could also shadow a builtin verb with a
    // `!` shell command.)
    try std.testing.expect(execDenial(&sb, "git", &.{ "/usr/bin/git", "-c", "core.hooksPath=src/hooks", "commit", "-m", "x" }).? == .git_config);
    try std.testing.expect(execDenial(&sb, "git", &.{ "/usr/bin/git", "--config-env=core.fsmonitor=GIT_FSMONITOR", "status" }).? == .git_config);
    try std.testing.expect(execDenial(&sb, "git", &.{ "/usr/bin/git", "--git-dir=./evil.git", "--work-tree=./evil", "commit", "-m", "x" }).? == .git_config);
    try std.testing.expect(execDenial(&sb, "git", &.{ "/usr/bin/git", "--git-common-dir", "./evil.git", "status" }).? == .git_config);
    // -C and --work-tree stay allowed: they keep the run's own git dir, and
    // their path arguments are checked by execArgPathDenied.
    try std.testing.expect(execDenial(&sb, "git", &.{ "/usr/bin/git", "-C", ".", "status" }) == null);
    try std.testing.expect(execDenial(&sb, "git", &.{ "/usr/bin/git", "--work-tree=src", "status" }) == null);
}

test "ck_job start gate: execDenial alone passes an unlisted command, so the allowlist half must refuse it" {
    // The `jobs` tool's manifest names git/zig/rg/ast-grep/semcode/uv. execDenial
    // only refuses deny tokens and unlisted git/zig/uv verbs: a bare "curl" or
    // "python3" argv passes it. The ck_job start op therefore must run
    // execAllowed first, exactly like ckExec does, or the exec_allow grant is
    // decorative and the guest can start any binary on PATH.
    var sb = Sandbox{
        .gpa = undefined,
        .io = undefined,
        .root_dir = ".",
        .network_allow = &.{},
        .fs_prefixes = &.{},
        .environ_map = undefined,
        .exec_allow = &.{ "git", "zig", "rg", "ast-grep", "semcode", "uv" },
    };
    try std.testing.expect(execDenial(&sb, "curl", &.{"curl"}) == null);
    try std.testing.expect(!execAllowed(sb.exec_allow, "curl"));
    try std.testing.expect(execDenial(&sb, "python3", &.{ "python3", "-c", "print(1)" }) == null);
    try std.testing.expect(!execAllowed(sb.exec_allow, "python3"));

    // The commands the manifest does grant still pass both halves.
    try std.testing.expect(execAllowed(sb.exec_allow, "git"));
    try std.testing.expect(execDenial(&sb, "git", &.{ "/usr/bin/git", "status" }) == null);
    try std.testing.expect(execAllowed(sb.exec_allow, "rg"));
    try std.testing.expect(execDenial(&sb, "rg", &.{ "/usr/bin/rg", "needle", "src" }) == null);

    // Coding-agent CLIs stay off ck_exec: the driver is native harness spawn.
    try std.testing.expect(!execAllowed(sb.exec_allow, "claude"));
    try std.testing.expect(!execAllowed(sb.exec_allow, "codex"));
    try std.testing.expect(!execAllowed(sb.exec_allow, "grok"));
}

test "execUnderPolicyInput carries stdin and enforces one wall-clock deadline" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    // Resolution uses the process environment; the filtered child map only
    // needs a PATH for programs that inspect it themselves.
    try env.put("PATH", "/usr/bin:/bin");
    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = ".",
        .network_allow = &.{},
        .fs_prefixes = &.{},
        .environ_map = &env,
        .exec_allow = &.{ "tee", "sleep" },
    };
    const echoed = execUnderPolicyInput(&sb, &.{"tee"}, "hook payload", 1024, 1024, 1000, ".");
    switch (echoed) {
        .ran => |out| {
            defer out.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(u32, 0), out.code);
            try std.testing.expectEqualStrings("hook payload", out.stdout);
        },
        else => return error.TestExpectedExec,
    }
    const timed = execUnderPolicyInput(&sb, &.{ "sleep", "1" }, "", 1024, 1024, 10, ".");
    switch (timed) {
        .failed => |err| try std.testing.expectEqual(error.Timeout, err),
        else => return error.TestExpectedTimeout,
    }
}

test "execUnderPolicyInput treats a child that ignores stdin as ran" {
    // Hooks often use printf and never read the payload. On a fast runner
    // the child exits before the stdin write finishes (WriteFailed). That
    // must not become a failed hook; stdout still has the decision JSON.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = ".",
        .network_allow = &.{},
        .fs_prefixes = &.{},
        .environ_map = &env,
        .exec_allow = &.{"printf"},
    };
    const attempt = execUnderPolicyInput(
        &sb,
        &.{ "printf", "%s", "{\"decision\":\"deny\",\"reason\":\"policy\"}" },
        "{}",
        1024,
        1024,
        1000,
        ".",
    );
    switch (attempt) {
        .ran => |out| {
            defer out.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(u32, 0), out.code);
            try std.testing.expect(std.mem.find(u8, out.stdout, "deny") != null);
        },
        else => return error.TestExpectedExec,
    }
}

test "execUnderPolicy refuses a command that is not on the allowlist" {
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = undefined,
        .root_dir = ".",
        .network_allow = &.{},
        .fs_prefixes = &.{},
        .environ_map = &environ_map,
        .exec_allow = &.{"git"},
    };
    // Refused before any PATH lookup or spawn, so `.io` being undefined here
    // is exactly the point: nothing runs.
    try std.testing.expect(execUnderPolicy(&sb, &.{ "rm", "-rf", "/" }, 1024, 1024) == .not_allowed);
    try std.testing.expect(execUnderPolicy(&sb, &.{}, 1024, 1024) == .not_allowed);
    try std.testing.expect(execUnderPolicy(&sb, &.{""}, 1024, 1024) == .not_allowed);
}

test "an exec'd child runs at the sandbox root, not the process cwd" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A name that exists only inside the sandbox root, so "did the child run
    // there?" is answerable from its output alone, with no path comparison to
    // be defeated by /var -> /private/var and friends.
    const marker = "only-in-the-sandbox-root";
    try tmp.dir.writeFile(io, .{ .sub_path = marker, .data = "" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);

    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("PATH", "/bin:/usr/bin");

    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = root_buf[0..root_len],
        .network_allow = &.{},
        .fs_prefixes = &.{},
        .environ_map = &environ_map,
        .exec_allow = &.{"ls"},
    };

    {
        const attempt = execUnderPolicy(&sb, &.{"ls"}, 1 << 16, 1 << 16);
        try std.testing.expect(attempt == .ran);
        defer std.testing.allocator.free(attempt.ran.stdout);
        defer std.testing.allocator.free(attempt.ran.stderr);
        try std.testing.expectEqual(@as(u8, 0), attempt.ran.code);
        try std.testing.expect(std.mem.containsAtLeast(u8, attempt.ran.stdout, 1, marker));
    }

    // The regression this guards: with the root ignored the child inherited the
    // process cwd, so an isolated run's commands reported on the shared
    // checkout while its file writes went to the root. "." still means the
    // process cwd, which is what keeps the default configuration unchanged.
    sb.root_dir = ".";
    {
        const attempt = execUnderPolicy(&sb, &.{"ls"}, 1 << 16, 1 << 16);
        try std.testing.expect(attempt == .ran);
        defer std.testing.allocator.free(attempt.ran.stdout);
        defer std.testing.allocator.free(attempt.ran.stderr);
        try std.testing.expect(!std.mem.containsAtLeast(u8, attempt.ran.stdout, 1, marker));
    }
}

test "an isolated run resolves tracked paths in its worktree and untracked ones in the checkout" {
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = undefined,
        .root_dir = "/checkout/.clanker-worktrees/42",
        .shared_root = "/checkout",
        .network_allow = &.{},
        .fs_prefixes = &.{"."},
        .environ_map = &environ_map,
    };

    // Tracked source: the worktree's own, which is the entire point of
    // isolating the run.
    for ([_][]const u8{ "src/cli.zig", "docs/README.md", "build.zig", "AGENTS.md", "tools/manifests/git.tool.json" }) |p| {
        const got = try safeJoin(&sb, p);
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.startsWith(u8, got, "/checkout/.clanker-worktrees/42/"));
    }

    // Untracked and checkout-wide: the checkout's, so the run is not reading a
    // snapshot and writing where nobody looks.
    for ([_][]const u8{
        "state/goals.json",
        "state/sessions/abc.json",
        "state/learnings.md",
        "state/staging/imp-1/src/x.zig",
        ".local/board.json",
        ".agents/AGENTS.md",
        ".claude/settings.json",
        "config.local.toml",
    }) |p| {
        const got = try safeJoin(&sb, p);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("/checkout/", got[0..10]);
        try std.testing.expect(!std.mem.startsWith(u8, got, "/checkout/.clanker-worktrees"));
    }
    // .env is a shared prefix for worktree routing, but guests may not read
    // it: that file is where API keys live.
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, ".env"));

    // The prefix has to end on a path boundary: a tracked file whose name
    // merely starts with a shared prefix's bytes stays in the worktree.
    for ([_][]const u8{ "stateful.zig", "state_machine/x.zig", ".environment/x" }) |p| {
        const got = try safeJoin(&sb, p);
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.startsWith(u8, got, "/checkout/.clanker-worktrees/42/"));
    }

    // No shared_root (every non-isolated run): one root for everything, so the
    // routing cannot change what an unisolated run has always done.
    sb.shared_root = "";
    for ([_][]const u8{ "src/cli.zig", "state/goals.json" }) |p| {
        const got = try safeJoin(&sb, p);
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.startsWith(u8, got, "/checkout/.clanker-worktrees/42/"));
    }
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, ".env"));
}

test "rootIsProcessCwd treats only the cwd spellings as the process cwd" {
    try std.testing.expect(rootIsProcessCwd(""));
    try std.testing.expect(rootIsProcessCwd("."));
    try std.testing.expect(rootIsProcessCwd("./"));
    try std.testing.expect(!rootIsProcessCwd(".clanker-worktrees/1234"));
    try std.testing.expect(!rootIsProcessCwd("state/sandbox"));
    try std.testing.expect(!rootIsProcessCwd("/tmp/sandbox"));
    // Not a cwd spelling: ".." is a different directory, and treating it as
    // "no need to move" would silently run the child one level up.
    try std.testing.expect(!rootIsProcessCwd(".."));
}

test "safeJoin admits paths under a granted prefix and refuses everything else" {
    // Every `ck_fs_*` host function routes its path through safeJoin, and none
    // of them can be called directly (each wants a zwasm.Caller), so the policy
    // they share is asserted once here rather than once per caller.
    const cases = [_]struct {
        prefix: []const u8,
        allowed: []const []const u8,
        denied: []const []const u8,
    }{
        .{
            .prefix = "data/",
            .allowed = &.{ "data/info.txt", "data/copy.txt", "data/patch.bin", "data/subdir" },
            .denied = &.{ "secrets/key", "other/subdir", "data/../secrets/key", "data/../etc/passwd", "" },
        },
        .{
            .prefix = "logs/",
            .allowed = &.{"logs/app.log"},
            .denied = &.{ "secrets/key", "logs/../secrets/key", "" },
        },
    };

    for (cases) |case| {
        const prefixes = [_][]const u8{case.prefix};
        var sb = Sandbox{
            .gpa = std.testing.allocator,
            .io = undefined,
            .root_dir = "/tmp/sandbox",
            .network_allow = &.{},
            .fs_prefixes = &prefixes,
            .environ_map = undefined,
        };
        for (case.allowed) |path| {
            const joined = try safeJoin(&sb, path);
            defer std.testing.allocator.free(joined);
            var want_buf: [128]u8 = undefined;
            const want = try std.fmt.bufPrint(&want_buf, "/tmp/sandbox/{s}", .{path});
            try std.testing.expectEqualStrings(want, joined);
        }
        for (case.denied) |path| {
            try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, path));
        }
    }
}

test "httpMethodFromCode maps known codes and rejects unknown ones" {
    try std.testing.expectEqual(std.http.Method.GET, httpMethodFromCode(0).?);
    try std.testing.expectEqual(std.http.Method.POST, httpMethodFromCode(1).?);
    try std.testing.expectEqual(std.http.Method.PUT, httpMethodFromCode(2).?);
    try std.testing.expectEqual(std.http.Method.DELETE, httpMethodFromCode(3).?);
    try std.testing.expectEqual(std.http.Method.PATCH, httpMethodFromCode(4).?);
    try std.testing.expectEqual(std.http.Method.HEAD, httpMethodFromCode(5).?);

    try std.testing.expectEqual(@as(?std.http.Method, null), httpMethodFromCode(6));
    try std.testing.expectEqual(@as(?std.http.Method, null), httpMethodFromCode(999));
}

test "safeJoin bare prefix does not bleed into sibling names" {
    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = undefined,
        .root_dir = "/tmp/sandbox",
        .network_allow = &.{},
        .fs_prefixes = &.{"notes"},
        .environ_map = undefined,
    };
    // The directory itself and its children are allowed.
    const dir = try safeJoin(&sb, "notes");
    defer std.testing.allocator.free(dir);
    const child = try safeJoin(&sb, "notes/todo.txt");
    defer std.testing.allocator.free(child);
    // A sibling that merely shares the leading bytes must be rejected.
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "notes2/secret.txt"));
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "notes-old/plans.txt"));
}

test "safeJoin refuses dotenv files even under a wide fs_prefixes grant" {
    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = undefined,
        .root_dir = "/tmp/sandbox",
        .network_allow = &.{},
        .fs_prefixes = &.{"."},
        .environ_map = undefined,
    };
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, ".env"));
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, ".env.local"));
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, ".envrc"));
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "state/.env"));
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "foo/.env.production"));
    // A name that only shares the prefix bytes is not a dotenv file.
    const ok = try safeJoin(&sb, ".environment/x");
    defer std.testing.allocator.free(ok);
}

test "safeJoin rejects escapes" {
    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = undefined,
        .root_dir = "/tmp/sandbox",
        .network_allow = &.{},
        .fs_prefixes = &.{"notes/"},
        .environ_map = undefined,
    };
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "../etc/passwd"));
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "/etc/passwd"));
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "a/../../b"));
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "a//b"));
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "other/foo.txt"));

    var abs = Sandbox{
        .gpa = std.testing.allocator,
        .io = undefined,
        .root_dir = "/tmp/sandbox",
        .network_allow = &.{},
        .fs_prefixes = &.{"/home/user/.config/clanker/plugins"},
        .environ_map = undefined,
    };
    const abs_ok = try safeJoin(&abs, "/home/user/.config/clanker/plugins/echo.tool.json");
    defer std.testing.allocator.free(abs_ok);
    try std.testing.expectEqualStrings("/home/user/.config/clanker/plugins/echo.tool.json", abs_ok);
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&abs, "/home/user/.config/clanker/secrets"));
    const ok = try safeJoin(&sb, "notes/foo.txt");
    defer std.testing.allocator.free(ok);
    try std.testing.expectEqualStrings("/tmp/sandbox/notes/foo.txt", ok);

    // The prefix's own directory is listable; a sibling sharing its name is not.
    const dir = try safeJoin(&sb, "notes");
    defer std.testing.allocator.free(dir);
    try std.testing.expectEqualStrings("/tmp/sandbox/notes", dir);
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "notesx"));
}

test "pathHasWorktreeDir flags descent into another run's worktree" {
    // A cwd inside another run's worktree is refused.
    try std.testing.expect(pathHasWorktreeDir(".clanker-worktrees/123/src"));
    try std.testing.expect(pathHasWorktreeDir("state/.clanker-worktrees/456"));
    try std.testing.expect(pathHasWorktreeDir("./.clanker-worktrees/789"));
    // So is the container itself, however it is spelled, for the reason
    // written out above the function.
    try std.testing.expect(pathHasWorktreeDir(".clanker-worktrees"));
    try std.testing.expect(pathHasWorktreeDir(".clanker-worktrees/"));
    try std.testing.expect(pathHasWorktreeDir("state/.clanker-worktrees"));
    // Unrelated subdirs stay usable.
    try std.testing.expect(!pathHasWorktreeDir("src/sandbox"));
    try std.testing.expect(!pathHasWorktreeDir("state/runs"));
    try std.testing.expect(!pathHasWorktreeDir(""));
    try std.testing.expect(!pathHasWorktreeDir("clanker-worktrees/123")); // sibling name
}

test "pathEscapesUpward cancels . and .. textually" {
    try std.testing.expect(pathEscapesUpward(".."));
    try std.testing.expect(pathEscapesUpward("../123"));
    try std.testing.expect(pathEscapesUpward("./../123"));
    try std.testing.expect(pathEscapesUpward("a/../../b"));

    // Stays inside: a `..` that only cancels a component before it. `src/..`
    // is the starting directory itself, which is where the run already is.
    try std.testing.expect(!pathEscapesUpward("src/.."));
    try std.testing.expect(!pathEscapesUpward("src/../lib"));
    try std.testing.expect(!pathEscapesUpward("a/b/../../c"));
    try std.testing.expect(!pathEscapesUpward("src/sandbox"));
    try std.testing.expect(!pathEscapesUpward("./src"));
    try std.testing.expect(!pathEscapesUpward(""));

    // Absolute paths are the component test's business, not this one's.
    try std.testing.expect(!pathEscapesUpward("/etc/passwd"));
    try std.testing.expect(!pathEscapesUpward("/checkout/../etc"));
}

test "argStepsUpward tells a path from a pattern that happens to hold two dots" {
    try std.testing.expect(argStepsUpward(".."));
    try std.testing.expect(argStepsUpward("../123"));
    try std.testing.expect(argStepsUpward("src/../lib"));
    try std.testing.expect(argStepsUpward("src/.."));

    // rg / ast-grep patterns are ordinary arguments here (nothing runs through
    // a shell), so two dots without a '/' beside them must stay usable.
    try std.testing.expect(!argStepsUpward("a..b"));
    try std.testing.expect(!argStepsUpward("\\.\\."));
    try std.testing.expect(!argStepsUpward("fn .. end"));
    try std.testing.expect(!argStepsUpward("..foo"));
    try std.testing.expect(!argStepsUpward("src/foo..bar"));
    try std.testing.expect(!argStepsUpward(""));
}

test "foreignWorktreeArg closes both routes into a sibling run's tree" {
    // Naming the container, which is what a run in the checkout would do. This
    // is the case that used to walk straight past the cwd-only guard.
    try std.testing.expectEqualStrings(
        ".clanker-worktrees/123",
        foreignWorktreeArg(&.{ "/usr/bin/git", "-C", ".clanker-worktrees/123", "status" }).?,
    );
    try std.testing.expectEqualStrings(
        "/checkout/.clanker-worktrees/123",
        foreignWorktreeArg(&.{ "/usr/bin/git", "-C", "/checkout/.clanker-worktrees/123", "status" }).?,
    );
    // Not just readable before this: `worktree` is an allowed git verb and
    // "remove" is not matched by the "rm" deny token, so this deleted it.
    try std.testing.expectEqualStrings(
        ".clanker-worktrees/123",
        foreignWorktreeArg(&.{ "/usr/bin/git", "worktree", "remove", ".clanker-worktrees/123" }).?,
    );

    // Walking up to a sibling from inside a worktree, where cwd is
    // `<checkout>/.clanker-worktrees/<own-id>` and no `.clanker-worktrees`
    // component appears in the argument at all.
    try std.testing.expectEqualStrings(
        "../123",
        foreignWorktreeArg(&.{ "/usr/bin/git", "-C", "../123", "status" }).?,
    );

    // Ordinary argv is untouched, patterns included.
    try std.testing.expect(foreignWorktreeArg(&.{ "/usr/bin/git", "status" }) == null);
    try std.testing.expect(foreignWorktreeArg(&.{ "/usr/bin/rg", "needle", "src" }) == null);
    try std.testing.expect(foreignWorktreeArg(&.{ "/usr/bin/rg", "a..b", "src/../lib" }) == null);
    try std.testing.expect(foreignWorktreeArg(&.{ "/opt/homebrew/bin/zig", "build", "test" }) == null);
}

test "ckHash produces correct SHA-256 hex digest" {
    // Verify the hashing logic used by ckHash (we can't call ckHash directly
    // without a zwasm.Caller, but the core hash+hex path is pure).
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("hello");
    const digest = hasher.finalResult();
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        &hex,
    );
    // Empty input.
    var hasher2 = std.crypto.hash.sha2.Sha256.init(.{});
    hasher2.update("");
    const digest2 = hasher2.finalResult();
    const hex2 = std.fmt.bytesToHex(digest2, .lower);
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &hex2,
    );
}

test "parseCkLlmRequest extracts prompt, model, system, provider, max_tokens" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const req = parseCkLlmRequest(arena, "{\"prompt\":\"hi\",\"model\":\"m1\",\"system\":\"be brief\",\"provider\":\"p1\",\"max_tokens\":64}") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("hi", req.prompt.?);
    try std.testing.expectEqualStrings("m1", req.model.?);
    try std.testing.expectEqualStrings("be brief", req.system.?);
    try std.testing.expectEqualStrings("p1", req.provider.?);
    try std.testing.expectEqual(@as(u32, 64), req.max_tokens.?);
}

test "parseCkLlmRequest returns null for bare prompts and non-object JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(parseCkLlmRequest(arena, "just a plain prompt") == null);
    try std.testing.expect(parseCkLlmRequest(arena, "[1,2,3]") == null);
    try std.testing.expect(parseCkLlmRequest(arena, "42") == null);
}

test "parseCkLlmRequest ignores malformed and out-of-range fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const req = parseCkLlmRequest(arena, "{\"prompt\":\"x\",\"max_tokens\":-5,\"model\":\"\",\"provider\":7}") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("x", req.prompt.?);
    try std.testing.expect(req.max_tokens == null);
    try std.testing.expect(req.model == null);
    try std.testing.expect(req.provider == null);
    try std.testing.expect(req.system == null);

    // A max_tokens beyond u32 range must be ignored, not panic @intCast.
    const big = parseCkLlmRequest(arena, "{\"prompt\":\"x\",\"max_tokens\":9000000000}") orelse return error.TestUnexpectedNull;
    try std.testing.expect(big.max_tokens == null);
}

test "ck_llm max_tokens cannot exceed the descriptor grant" {
    try std.testing.expectEqual(@as(u32, 1024), clampCkLlmMaxTokens(null, 1024));
    try std.testing.expectEqual(@as(u32, 64), clampCkLlmMaxTokens(64, 1024));
    try std.testing.expectEqual(@as(u32, 1024), clampCkLlmMaxTokens(99_999, 1024));
    try std.testing.expectEqual(@as(u32, 1024), clampCkLlmMaxTokens(4_000_000_000, 0));
    try std.testing.expectEqual(@as(u32, 256), clampCkLlmMaxTokens(256, 0));
}

test "ck_llm names why a completion came back with no visible content" {
    // Content present: nothing to diagnose, whatever the other fields say.
    try std.testing.expect(emptyCompletionCause("text", "length", "thought") == null);

    // The reasoning-budget case: a thinking model spent the whole max_tokens
    // grant before emitting a visible token. The grant is the actionable part.
    try std.testing.expectEqualStrings(
        "the model spent the whole max_tokens grant on reasoning; raise the tool descriptor's config.max_tokens",
        emptyCompletionCause("", "length", "We need answer user.").?,
    );

    // Truncated with no reasoning at all is still a budget problem, but not
    // the reasoning one, so it must not claim reasoning it did not see.
    try std.testing.expectEqualStrings(
        "the completion was cut off at the max_tokens grant before any content",
        emptyCompletionCause("", "length", null).?,
    );

    // Anything else that answers empty is a model-side refusal or a stop, and
    // the honest answer is that we do not know which.
    try std.testing.expectEqualStrings(
        "the model returned no content",
        emptyCompletionCause("", "stop", null).?,
    );
    try std.testing.expectEqualStrings(
        "the model returned no content",
        emptyCompletionCause("", null, null).?,
    );
}

test "Host.writeResult enforces the arena cap and memory bounds" {
    var host = Host{
        .sandbox = undefined,
        .rng = std.Random.DefaultPrng.init(0),
    };
    var mem: [host_arena_cap + 64]u8 = undefined;

    // A payload at or under the cap passes through and is recorded as (ptr, len).
    const short = "hello sandbox";
    try std.testing.expectEqual(Err.ok, host.writeResult(&mem, short));
    try std.testing.expectEqual(@as(u32, 0), host.result_ptr);
    try std.testing.expectEqual(@as(u32, short.len), host.result_len);
    try std.testing.expectEqualStrings(short, mem[host.result_ptr .. host.result_ptr + host.result_len]);
    try std.testing.expectEqual(@as(u32, short.len), host.arena_cur);

    // A payload longer than host_arena_cap is rejected without moving the cursor.
    const oversized = [_]u8{0} ** (host_arena_cap + 1);
    const cur_before = host.arena_cur;
    try std.testing.expectEqual(Err.too_large, host.writeResult(&mem, &oversized));
    try std.testing.expectEqual(cur_before, host.arena_cur);

    // A write that would run past the end of the guest memory is rejected.
    host.arena_base = @intCast(mem.len - 4);
    host.arena_cur = host.arena_base;
    try std.testing.expectEqual(Err.too_large, host.writeResult(&mem, "0123456789"));
    try std.testing.expectEqual(host.arena_base, host.arena_cur);

    // Cumulative arena use beyond host_arena_cap is rejected even when the
    // backing memory itself is large enough to hold the payload.
    host.arena_base = 0;
    host.arena_cur = host_arena_cap;
    try std.testing.expectEqual(Err.too_large, host.writeResult(&mem, "x"));
}

test "Host.writeResult honours a guest-declared arena larger than the default" {
    // A guest that exports host_arena_size gets that much room; a guest that
    // does not keeps the 64 KiB default. Getting this wrong either rejects
    // reads the guest has space for or writes past the end of its buffer.
    var host = Host{
        .sandbox = undefined,
        .rng = std.Random.DefaultPrng.init(0),
    };
    try std.testing.expectEqual(@as(u32, host_arena_cap), host.arena_cap);

    const big_cap = host_arena_cap * 2;
    const payload = [_]u8{'z'} ** (host_arena_cap + 1);
    var mem: [big_cap + 64]u8 = undefined;

    // Over the default cap, so it is refused until the guest asks for more.
    try std.testing.expectEqual(Err.too_large, host.writeResult(&mem, &payload));

    host.arena_cap = big_cap;
    try std.testing.expectEqual(Err.ok, host.writeResult(&mem, &payload));
    try std.testing.expectEqual(@as(u32, payload.len), host.result_len);

    // The larger cap is still a cap: cumulative use beyond it is refused.
    host.arena_cur = big_cap;
    try std.testing.expectEqual(Err.too_large, host.writeResult(&mem, "x"));
}

test "writeExecResult serializes exit code and output streams as JSON" {
    var buf: [1024]u8 = undefined;

    // Success path: code 0 -> ok=true, stdout carried through, empty stderr.
    var w: std.Io.Writer = .fixed(&buf);
    try writeExecResult(&w, 0, "hello out", "");
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf[0..w.end], .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("ok").?.bool);
    try std.testing.expectEqual(@as(i64, 0), obj.get("code").?.integer);
    try std.testing.expectEqualStrings("hello out", obj.get("stdout").?.string);
    try std.testing.expectEqualStrings("", obj.get("stderr").?.string);

    // Failure path: nonzero code -> ok=false, stderr carried through.
    var w2: std.Io.Writer = .fixed(&buf);
    try writeExecResult(&w2, 3, "", "boom");
    const parsed2 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf[0..w2.end], .{});
    defer parsed2.deinit();
    const obj2 = parsed2.value.object;
    try std.testing.expect(!obj2.get("ok").?.bool);
    try std.testing.expectEqual(@as(i64, 3), obj2.get("code").?.integer);
    try std.testing.expectEqualStrings("boom", obj2.get("stderr").?.string);
}

test "writeExecResult truncation note is a JSON string" {
    // A search whose stdout exceeds exec_stdout_keep used to emit
    // `"note":output was N bytes...` (Stringify.print writes raw text).
    // repo_search then writeAll'd that blob and the agent warned
    // malformed JSON (run-1787001820, query "repair", 65148 bytes).
    var buf: [80 * 1024]u8 = undefined;
    const big = "x" ** (exec_stdout_keep + 64);
    var w: std.Io.Writer = .fixed(&buf);
    try writeExecResult(&w, 0, big, "");
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf[0..w.end], .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("ok").?.bool);
    try std.testing.expect(obj.get("truncated").?.bool);
    const note = obj.get("note") orelse return error.TestUnexpectedResult;
    try std.testing.expect(note == .string);
    try std.testing.expect(std.mem.find(u8, note.string, "narrow the pattern") != null);
}

test "a \".\" prefix authorizes the whole sandbox root" {
    // A descriptor written as {"fs_prefixes": ["."]} used to match nothing:
    // no relative path starts with a dot, so the tool was denied every file in
    // the project it was pointed at ("path is outside the sandbox").
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = threaded.io(),
        .root_dir = "/tmp/ck-root",
        .network_allow = &.{},
        .fs_prefixes = &.{"."},
        .environ_map = &env,
    };
    const joined = try safeJoin(&sb, "src/agent/loop.zig");
    defer std.testing.allocator.free(joined);
    try std.testing.expectEqualStrings("/tmp/ck-root/src/agent/loop.zig", joined);

    // Escapes are still refused: "." widens the prefix, it does not disable
    // the traversal check.
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "../etc/passwd"));
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "/etc/passwd"));

    // A narrow prefix still narrows.
    var narrow = sb;
    narrow.fs_prefixes = &.{"state/"};
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&narrow, "src/main.zig"));
}

test "a tool cannot read an environment variable it was not allowed" {
    // The process environment holds this project's API keys. Before this the
    // env_allow field in a manifest was decorative and any guest could ask for
    // any variable by name.
    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = undefined,
        .root_dir = ".",
        .network_allow = &.{},
        .environ_map = undefined,
    };

    // No declaration: only the harmless defaults.
    try std.testing.expect(envAllowed(&sb, "PWD"));
    try std.testing.expect(envAllowed(&sb, "HOME"));
    try std.testing.expect(!envAllowed(&sb, "ANTHROPIC_API_KEY"));
    try std.testing.expect(!envAllowed(&sb, "KIMI_API_KEY"));

    // A declaration is exact and replaces the defaults rather than adding to
    // them, so a tool that asks for one variable cannot reach the others.
    const allow = [_][]const u8{"MY_TOKEN"};
    sb.env_allow = &allow;
    try std.testing.expect(envAllowed(&sb, "MY_TOKEN"));
    try std.testing.expect(!envAllowed(&sb, "PWD"));
    try std.testing.expect(!envAllowed(&sb, "DEEPSEEK_API_KEY"));
}

test "exec subprocess environment cannot bypass env_allow" {
    var source = std.process.Environ.Map.init(std.testing.allocator);
    defer source.deinit();
    try source.put("PATH", "/bin");
    try source.put("HOME", "/tmp/example");
    try source.put("ANTHROPIC_API_KEY", "must-not-cross-boundary");

    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = undefined,
        .root_dir = ".",
        .network_allow = &.{},
        .environ_map = &source,
    };
    var filtered = try execEnvironment(std.testing.allocator, &sb);
    defer filtered.deinit();
    try std.testing.expectEqualStrings("/bin", filtered.get("PATH").?);
    try std.testing.expectEqualStrings("/tmp/example", filtered.get("HOME").?);
    try std.testing.expect(filtered.get("ANTHROPIC_API_KEY") == null);

    sb.env_allow = &.{"ANTHROPIC_API_KEY"};
    var explicit = try execEnvironment(std.testing.allocator, &sb);
    defer explicit.deinit();
    try std.testing.expectEqualStrings("must-not-cross-boundary", explicit.get("ANTHROPIC_API_KEY").?);
    try std.testing.expect(explicit.get("PATH") == null);
}

test "docker host channel is scoped to the docker tool" {
    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = undefined,
        .root_dir = ".",
        .network_allow = &.{},
        .environ_map = undefined,
        .tool_self_name = "unrelated",
    };
    try std.testing.expect(!dockerAccessAllowed(&sb));
    sb.tool_self_name = "docker-helper";
    try std.testing.expect(!dockerAccessAllowed(&sb));
    sb.tool_self_name = "docker";
    try std.testing.expect(dockerAccessAllowed(&sb));
}

test "subagent and swarm host channels are scoped to the tools that spawn them" {
    try std.testing.expect(subagentAccessAllowed("subagent"));
    try std.testing.expect(subagentAccessAllowed("rlm"));
    try std.testing.expect(!subagentAccessAllowed("subagent-helper"));
    try std.testing.expect(!subagentAccessAllowed("swarm"));
    try std.testing.expect(!subagentAccessAllowed("read_file"));
    try std.testing.expect(jobAccessAllowed("jobs"));
    try std.testing.expect(jobAccessAllowed("subagent"));
    try std.testing.expect(!jobAccessAllowed("read_file"));
    try std.testing.expect(rewindGitAllowed("rewind", &.{ "git", "stash", "apply", "0123456789abcdef0123456789abcdef01234567" }));
    try std.testing.expect(rewindGitAllowed("rewind", &.{ "git", "stash", "create", "clanker-rewind" }));
    try std.testing.expect(!rewindGitAllowed("git", &.{ "git", "stash", "apply", "x" }));
    try std.testing.expect(!rewindGitAllowed("rewind", &.{ "git", "stash", "drop" }));
    try std.testing.expect(swarmAccessAllowed("swarm"));
    try std.testing.expect(!swarmAccessAllowed("swarm-helper"));
    try std.testing.expect(!swarmAccessAllowed("subagent"));
    try std.testing.expect(!swarmAccessAllowed("rlm"));
}

test "chat host channel pins each descriptor to its operation" {
    try std.testing.expect(chatAccessAllowed("chat_send", "send"));
    try std.testing.expect(chatAccessAllowed("chat_dm", "send"));
    try std.testing.expect(chatAccessAllowed("todo_close", "todo_close"));
    try std.testing.expect(!chatAccessAllowed("chat_send", "history"));
    try std.testing.expect(!chatAccessAllowed("chat_dm", "history"));
    try std.testing.expect(!chatAccessAllowed("chat_send-helper", "send"));
    try std.testing.expect(!chatAccessAllowed("chat_dm-helper", "send"));
    try std.testing.expect(!chatAccessAllowed("unrelated", "send"));
}

test "harness config access is scoped to each tool's consumed fields" {
    try std.testing.expectEqual(HarnessConfigAccess.providers, harnessConfigAccess("providers").?);
    try std.testing.expectEqual(HarnessConfigAccess.peers, harnessConfigAccess("peers").?);
    try std.testing.expectEqual(HarnessConfigAccess.workflows, harnessConfigAccess("workflows").?);
    try std.testing.expectEqual(HarnessConfigAccess.chains, harnessConfigAccess("chain").?);
    try std.testing.expectEqual(HarnessConfigAccess.tools_dir, harnessConfigAccess("plugins").?);
    try std.testing.expectEqual(HarnessConfigAccess.tools_dir, harnessConfigAccess("tools").?);
    try std.testing.expectEqual(HarnessConfigAccess.skills, harnessConfigAccess("skills").?);
    try std.testing.expect(harnessConfigAccess("unrelated") == null);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cfg = config_mod.Config{};
    var p = config_mod.Provider{
        .name = "v",
        .base_url = "https://x.test",
        .api_key_env = "VERTEX_KEY",
        .service_account_file = "/secret/sa.json",
        .default_model = "m",
    };
    try p.models.put(arena, "m", .{});
    try cfg.providers.put(arena, "v", p);

    const workflows = try harnessConfigJSON(arena, &cfg, .workflows);
    try std.testing.expect(std.mem.find(u8, workflows, "workflows_dir") != null);
    try std.testing.expect(std.mem.find(u8, workflows, "chains_dir") == null);
    try std.testing.expect(std.mem.find(u8, workflows, "providers") == null);
    try std.testing.expect(std.mem.find(u8, workflows, "peers") == null);
    try std.testing.expect(std.mem.find(u8, workflows, "max_iterations") == null);

    const providers_json = try harnessConfigJSON(arena, &cfg, .providers);
    try std.testing.expect(std.mem.find(u8, providers_json, "default_provider") != null);
    try std.testing.expect(std.mem.find(u8, providers_json, "api_key_env") == null);
    try std.testing.expect(std.mem.find(u8, providers_json, "service_account_file") == null);
    try std.testing.expect(std.mem.find(u8, providers_json, "peers") == null);
    try std.testing.expect(std.mem.find(u8, providers_json, "agent") == null);

    const peers = try harnessConfigJSON(arena, &cfg, .peers);
    try std.testing.expect(std.mem.find(u8, peers, "peers") != null);
    try std.testing.expect(std.mem.find(u8, peers, "instance") != null);
    try std.testing.expect(std.mem.find(u8, peers, "providers") == null);
    try std.testing.expect(std.mem.find(u8, peers, "agent") == null);

    cfg.agent.tools_dir = &.{ "vendor/my-tools", "vendor/overrides" };
    const tools_dir_json = try harnessConfigJSON(arena, &cfg, .tools_dir);
    try std.testing.expect(std.mem.find(u8, tools_dir_json, "tools_dir") != null);
    try std.testing.expect(std.mem.find(u8, tools_dir_json, "vendor/my-tools") != null);
    try std.testing.expect(std.mem.find(u8, tools_dir_json, "vendor/overrides") != null);
    try std.testing.expect(std.mem.find(u8, tools_dir_json, "providers") == null);
    try std.testing.expect(std.mem.find(u8, tools_dir_json, "max_iterations") == null);

    // skills resolves agent.skills_dir through the same bridge; denied, the
    // guest would silently fall back to the literal "skills" directory.
    cfg.agent.skills_dir = "custom-skills";
    const skills_json = try harnessConfigJSON(arena, &cfg, .skills);
    try std.testing.expect(std.mem.find(u8, skills_json, "skills_dir") != null);
    try std.testing.expect(std.mem.find(u8, skills_json, "custom-skills") != null);
    try std.testing.expect(std.mem.find(u8, skills_json, "providers") == null);
    try std.testing.expect(std.mem.find(u8, skills_json, "peers") == null);
    try std.testing.expect(std.mem.find(u8, skills_json, "workflows_dir") == null);

    // The skills guest's sandbox prefixes must cover the configured directory
    // it was just told to scan, or the grant above only produces denials.
    const skills_tool = registry.Tool{
        .name = "skills",
        .description = "",
        .wasm = "zig-out/tools/skills.wasm",
        .input_schema = .{ .object = .empty },
        .fs_prefixes = &.{ "skills", "state/skills.json" },
    };
    const skills_prefixes = try fsPrefixesFor(arena, &skills_tool, &cfg);
    try std.testing.expect(std.mem.eql(u8, skills_prefixes[0], "skills"));
    try std.testing.expect(std.mem.eql(u8, skills_prefixes[1], "state/skills.json"));
    try std.testing.expect(std.mem.eql(u8, skills_prefixes[2], "custom-skills"));
    // A tool that does not consume tools_dir/skills_dir keeps its prefixes.
    const other_tool = registry.Tool{
        .name = "edit_file",
        .description = "",
        .wasm = "zig-out/tools/edit_file.wasm",
        .input_schema = .{ .object = .empty },
        .fs_prefixes = &.{"state/runs"},
    };
    const other_prefixes = try fsPrefixesFor(arena, &other_tool, &cfg);
    try std.testing.expectEqual(@as(usize, 1), other_prefixes.len);

    const full = try harnessConfigJSON(arena, &cfg, .full);
    try std.testing.expect(std.mem.find(u8, full, "\"modules\"") != null);
    try std.testing.expect(std.mem.find(u8, full, "max_iterations") != null);
    try std.testing.expect(std.mem.find(u8, full, "chatrooms") != null);
    try std.testing.expect(std.mem.find(u8, full, "\"tui\"") != null);
    // The on-disk top-level models table is reconstructed so section mode
    // can look it up by the same key a human wrote in config.toml.
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, full, .{});
    const models = parsed.object.get("models") orelse return error.TestExpectedEqual;
    try std.testing.expect(models == .object);
    const entry = models.object.get("v/m") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("v", entry.object.get("provider").?.string);
    // A model disabled in config must cross the bridge as disabled, or every
    // picker reading the bridge keeps offering it after `enabled = false`.
    var hidden = p;
    hidden.models = .empty;
    try hidden.models.put(arena, "off", .{ .enabled = false });
    try cfg.providers.put(arena, "v", hidden);
    const with_disabled = try harnessConfigJSON(arena, &cfg, .providers);
    const dparsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, with_disabled, .{});
    const drow = dparsed.object.get("providers").?.object.get("v").?.object.get("models").?.object.get("off").?;
    try std.testing.expect(drow.object.get("enabled") != null);
    try std.testing.expectEqual(false, drow.object.get("enabled").?.bool);
    // No access level, not even .full, should expose credential fields.
    try std.testing.expect(std.mem.find(u8, full, "api_key_env") == null);
    try std.testing.expect(std.mem.find(u8, full, "service_account_file") == null);
}

test "harnessConfigJSON redacts inline mcp_servers credentials" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cfg = config_mod.Config{};
    var p = config_mod.Provider{ .name = "v", .base_url = "https://x.test", .default_model = "m" };
    try p.models.put(arena, "m", .{});
    try cfg.providers.put(arena, "v", p);
    // `env` and `headers` are the one place a literal secret sits in
    // config.toml: there is no `*_env` indirection for them.
    try cfg.mcp_servers.put(arena, "gh", .{
        .transport = "http",
        .url = "https://mcp.example.test",
        .env = &.{ "GITHUB_TOKEN=not-a-real-secret-value", "NO_COLOR" },
        .headers = &.{"Authorization: Bearer also-not-a-real-secret"},
    });

    const full = try harnessConfigJSON(arena, &cfg, .full);
    try std.testing.expect(std.mem.find(u8, full, "not-a-real-secret-value") == null);
    try std.testing.expect(std.mem.find(u8, full, "also-not-a-real-secret") == null);
    // The names stay: "which variables does this server take" is the useful
    // half and carries no secret.
    try std.testing.expect(std.mem.find(u8, full, "GITHUB_TOKEN=<redacted>") != null);
    try std.testing.expect(std.mem.find(u8, full, "Authorization:<redacted>") != null);
    // A bare name has no value half to drop and is emitted whole.
    try std.testing.expect(std.mem.find(u8, full, "\"NO_COLOR\"") != null);
    // The rest of the server is still described.
    try std.testing.expect(std.mem.find(u8, full, "https://mcp.example.test") != null);
}

test "ck_chat access covers every shipped caller, one op at a time" {
    // Each chat_* / todo_* manifest gets exactly the op it is named for, and
    // nothing else.
    const single = [_]struct { tool: []const u8, op: []const u8 }{
        .{ .tool = "chat_send", .op = "send" },
        .{ .tool = "chat_dm", .op = "send" },
        .{ .tool = "chat_history", .op = "history" },
        .{ .tool = "chat_rooms", .op = "rooms" },
        .{ .tool = "chat_subscribe", .op = "subscribe" },
        .{ .tool = "todo_add", .op = "todo_add" },
        .{ .tool = "todo_claim", .op = "todo_claim" },
        .{ .tool = "todo_close", .op = "todo_close" },
        .{ .tool = "todo_list", .op = "todo_list" },
    };
    for (single) |c| {
        try std.testing.expect(chatAccessAllowed(c.tool, c.op));
        try std.testing.expect(!chatAccessAllowed(c.tool, "send") or std.mem.eql(u8, c.op, "send"));
        try std.testing.expect(!chatAccessAllowed(c.tool, "rooms") or std.mem.eql(u8, c.op, "rooms"));
    }

    // board.wasm is registered under the multiplexed `kanban` name plus the
    // public `kanban_*` tools and needs two ops: "send" replicates a card
    // into the room, "history" folds that log back on read. Granting one op
    // per tool broke replication silently, because the board ignores a
    // failed chat call, so this is pinned per name, not just for `kanban`.
    //
    // The names are read off the shipped manifests rather than written out
    // here, because a hard-coded copy is what let this break in the first
    // place: commit 4fadb86 renamed the tools board_* -> kanban_* and this
    // test kept asserting the old names against the old matching, so it stayed
    // green while every renamed tool silently lost chat access. A rename edits
    // a manifest's "name" and never its "wasm", so keying off the module is
    // what makes the next one fail here instead of in production.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var man_dir = std.Io.Dir.cwd().openDir(io, "tools/manifests", .{ .iterate = true }) catch return error.SkipZigTest;
    defer man_dir.close(io);

    var board_names: usize = 0;
    var man_it = man_dir.iterate();
    while (man_it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".tool.json")) continue;
        const raw = try man_dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20));
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{ .ignore_unknown_fields = true }) catch continue;
        if (v != .object) continue;
        const wasm = v.object.get("wasm") orelse continue;
        if (wasm != .string) continue;
        if (!std.mem.endsWith(u8, wasm.string, "board.wasm")) continue;
        const name = v.object.get("name") orelse continue;
        if (name != .string) continue;

        board_names += 1;
        try std.testing.expect(chatAccessAllowed(name.string, "send"));
        try std.testing.expect(chatAccessAllowed(name.string, "history"));
        // Not a blanket grant: the board has no business subscribing or
        // enumerating rooms.
        try std.testing.expect(!chatAccessAllowed(name.string, "rooms"));
        try std.testing.expect(!chatAccessAllowed(name.string, "subscribe"));
        try std.testing.expect(!chatAccessAllowed(name.string, "todo_add"));
    }
    // An empty or unreadable manifests directory would otherwise let the loop
    // above assert nothing at all and still pass.
    try std.testing.expect(board_names >= 11);

    // The janitor announces what it pruned, and only that.
    try std.testing.expect(chatAccessAllowed("janitor", "send"));
    try std.testing.expect(!chatAccessAllowed("janitor", "history"));

    // Fail closed for anything else, including a name that merely looks close.
    for ([_][]const u8{ "", "chat", "boardroom", "unrelated", "arena" }) |tool| {
        for ([_][]const u8{ "send", "history", "rooms", "subscribe", "todo_add" }) |op| {
            try std.testing.expect(!chatAccessAllowed(tool, op));
        }
    }
}

test "parallel appends to one file all land" {
    // Tools run in parallel, and ck_fs_append is how they add to a shared log.
    // Reading the end and writing to it is two steps: without the lock, two
    // appends read the same end and one overwrites the other.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const writers = 8;
    const per_writer = 16;
    const line = "0123456789abcdef\n";

    const Worker = struct {
        dir: std.Io.Dir,
        io: std.Io,
        fn run(self: *@This()) void {
            var i: usize = 0;
            while (i < per_writer) : (i += 1) {
                _ = appendLocked(self.io, self.dir, "log.txt", line, .default_file);
            }
        }
    };

    var workers: [writers]Worker = undefined;
    var threads: [writers]std.Thread = undefined;
    for (&workers, 0..) |*w, i| {
        w.* = .{ .dir = tmp.dir, .io = io };
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{w});
    }
    for (&threads) |*t| t.join();

    const raw = try tmp.dir.readFileAlloc(io, "log.txt", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqual(@as(usize, writers * per_writer * line.len), raw.len);
}

test "a tool with no declared prefixes reaches no file at all" {
    // An empty fs_prefixes used to skip the check, so a descriptor saying
    // "this tool touches no files" granted every file under the sandbox root.
    // The image tool shipped that way and read whatever path it was handed.
    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = undefined,
        .root_dir = ".",
        .network_allow = &.{},
        .environ_map = undefined,
    };

    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "src/main.zig"));
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "."));

    // A declared prefix grants exactly what it names.
    const only_state = [_][]const u8{"state"};
    sb.fs_prefixes = &only_state;
    const inside = try safeJoin(&sb, "state/notes.md");
    std.testing.allocator.free(inside);
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "src/main.zig"));

    // An empty entry is the empty list one level down: it names nothing, so
    // it grants nothing. It used to satisfy the boundary check for every path
    // and hand the tool the whole root, and manifest validation skips empty
    // entries, so the descriptor that carried one looked clean.
    const stray_empty = [_][]const u8{ "", "state" };
    sb.fs_prefixes = &stray_empty;
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "src/main.zig"));
    const still_state = try safeJoin(&sb, "state/notes.md");
    std.testing.allocator.free(still_state);

    // "." is how a tool asks for the whole tree, and still cannot escape it.
    const everything = [_][]const u8{"."};
    sb.fs_prefixes = &everything;
    const anywhere = try safeJoin(&sb, "src/main.zig");
    std.testing.allocator.free(anywhere);
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "../outside"));
}

/// The sandbox the compare-and-swap tests below share: rooted at "." with a
/// "." prefix, so `safeJoin` allows any relative path under the temp tree.
fn testSandboxAtRoot(gpa: std.mem.Allocator, io: std.Io) Sandbox {
    return .{
        .gpa = gpa,
        .io = io,
        .root_dir = ".",
        .network_allow = &.{},
        .fs_prefixes = &.{"."},
        .environ_map = undefined,
    };
}

test "fsWriteIfImpl writes when hash matches and rejects on mismatch" {
    var fixture: test_env.Env = .init();
    defer fixture.deinit();
    const gpa = std.testing.allocator;
    const io = fixture.io();

    var sb = testSandboxAtRoot(gpa, io);

    // 1) Empty expected hash creates a missing file.
    const rc1 = fsWriteIfImpl(&sb, fixture.tmp.dir, "cas_test.txt", "", "hello world");
    try std.testing.expectEqual(Err.ok, rc1);
    const after1 = try fixture.tmp.dir.readFileAlloc(io, "cas_test.txt", gpa, .limited(1 << 20));
    defer gpa.free(after1);
    try std.testing.expectEqualStrings("hello world", after1);

    // 2) Correct hash writes.
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("hello world");
    const digest = hasher.finalResult();
    const hex = std.fmt.bytesToHex(digest, .lower);
    const rc2 = fsWriteIfImpl(&sb, fixture.tmp.dir, "cas_test.txt", &hex, "updated");
    try std.testing.expectEqual(Err.ok, rc2);
    const after2 = try fixture.tmp.dir.readFileAlloc(io, "cas_test.txt", gpa, .limited(1 << 20));
    defer gpa.free(after2);
    try std.testing.expectEqualStrings("updated", after2);

    // 3) Stale hash writes nothing and returns mismatch.
    const rc3 = fsWriteIfImpl(&sb, fixture.tmp.dir, "cas_test.txt", &hex, "should not land");
    try std.testing.expectEqual(Err.mismatch, rc3);
    const after3 = try fixture.tmp.dir.readFileAlloc(io, "cas_test.txt", gpa, .limited(1 << 20));
    defer gpa.free(after3);
    try std.testing.expectEqualStrings("updated", after3);
}

test "safeJoinSecure refuses a symlinked component unless the sandbox opts in" {
    // ADR 0017: a checkout whose `state/` is a symlink into external storage
    // is a supported layout, but following it is off by default so the
    // escape check stays the same for every deployment that did not ask.
    var fixture: test_env.Env = .init();
    defer fixture.deinit();
    const gpa = std.testing.allocator;
    const io = fixture.io();

    // A real directory, and a symlink standing in for it the way `state` does.
    try fixture.tmp.dir.createDirPath(io, "real_state/runs");
    try fixture.tmp.dir.symLink(io, "real_state", "state", .{});

    // safeJoinSecure stats through `std.Io.Dir.cwd()`, so the root has to be a
    // path that resolves from the process cwd rather than a handle. tmpDir
    // creates its directory at this fixed place.
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{fixture.tmp.sub_path});
    defer gpa.free(root);

    var sb = Sandbox{
        .gpa = gpa,
        .io = io,
        .root_dir = root,
        .network_allow = &.{},
        .fs_prefixes = &.{"state/"},
        .environ_map = undefined,
    };

    // Default: the symlinked component is refused even though the manifest
    // grants the prefix.
    try std.testing.expectError(error.PathOutsideSandbox, safeJoinSecure(&sb, "state/runs/x.json"));

    // Opted in: the same granted path resolves.
    sb.follow_symlinks = true;
    const full = try safeJoinSecure(&sb, "state/runs/x.json");
    defer gpa.free(full);
    try std.testing.expect(std.mem.endsWith(u8, full, "state/runs/x.json"));

    // The grant itself is unchanged: a path outside every prefix is still
    // refused, flag or no flag.
    try std.testing.expectError(error.PathOutsideSandbox, safeJoinSecure(&sb, "elsewhere/x.json"));
}

test "fsWriteIfImpl survives racing creates of a not-yet-existing lock file" {
    // The lock sidecar does not exist before the first CAS on a path, so the
    // first concurrent writers all create it at once. That is exactly the race
    // `file_lock.createFileRetry` absorbs: a plain create loses it on macOS
    // (~2 in 400) and reports FileNotFound, which this function would turn
    // into Err.invalid -- a valid write refused for no reason. Every attempt
    // here must end ok or mismatch; never invalid.
    var fixture: test_env.Env = .init();
    defer fixture.deinit();
    const gpa = std.testing.allocator;
    const io = fixture.io();

    const Worker = struct {
        dir: std.Io.Dir,
        io: std.Io,
        gpa: std.mem.Allocator,
        invalid: u32 = 0,

        fn run(self: *@This()) void {
            var sb = testSandboxAtRoot(self.gpa, self.io);
            var i: usize = 0;
            while (i < 25) : (i += 1) {
                // Empty expected hash: ok on the create, mismatch once another
                // worker got there first. Both are correct answers; Err.invalid
                // is the lock create having failed.
                const rc = fsWriteIfImpl(&sb, self.dir, "race_cas.txt", "", "x");
                if (rc == Err.invalid) self.invalid += 1;
            }
        }
    };

    var workers: [8]Worker = undefined;
    var threads: [8]std.Thread = undefined;
    for (&workers, 0..) |*w, i| {
        w.* = .{ .dir = fixture.tmp.dir, .io = io, .gpa = gpa };
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{w});
    }
    for (&threads) |*t| t.join();
    for (&workers) |*w| try std.testing.expectEqual(@as(u32, 0), w.invalid);
}

test "fsWriteIfImpl creates missing parent directories" {
    var fixture: test_env.Env = .init();
    defer fixture.deinit();
    const gpa = std.testing.allocator;
    const io = fixture.io();

    var sb = testSandboxAtRoot(gpa, io);

    // Use a path with no shared/cwd component: `state/` is a symlink in
    // improve staging worktrees (linkSharedState), so safeJoinSecure reports
    // it as an escape and the test fails every improve-self run. A throwaway
    // nested path still exercises the missing-parent-directory creation.
    const rc = fsWriteIfImpl(&sb, fixture.tmp.dir, "sub/dir/schedule.json", "", "{\"entries\":[]}");
    try std.testing.expectEqual(Err.ok, rc);
    const got = try fixture.tmp.dir.readFileAlloc(io, "sub/dir/schedule.json", gpa, .limited(1 << 20));
    defer gpa.free(got);
    try std.testing.expectEqualStrings("{\"entries\":[]}", got);
}

test "fsWriteIfImpl leaves no lock sidecar beside the target and no dirs on mismatch" {
    var fixture: test_env.Env = .init();
    defer fixture.deinit();
    const gpa = std.testing.allocator;
    const io = fixture.io();

    var sb = testSandboxAtRoot(gpa, io);

    // ADR 0031: the lock lives under state/locks/, so a CAS write must not
    // drop a permanent `<target>.ck_cas.lock` into the tree it wrote into.
    try std.testing.expectEqual(Err.ok, fsWriteIfImpl(&sb, fixture.tmp.dir, "docs/note.md", "", "hello"));
    try std.testing.expectError(
        error.FileNotFound,
        fixture.tmp.dir.statFile(io, "docs/note.md.ck_cas.lock", .{}),
    );
    const lock_dir = try fixture.tmp.dir.statFile(io, "state/locks", .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, lock_dir.kind);

    // One lock inode per target path, and the name carries no part of the
    // target: a reader must not be able to reconstruct `docs/note.md` from it.
    var locks = try fixture.tmp.dir.openDir(io, "state/locks", .{ .iterate = true });
    defer locks.close(io);
    var it = locks.iterate();
    var lock_count: usize = 0;
    while (try it.next(io)) |entry| {
        // The sweep marker shares the directory and is not a lock.
        if (std.mem.eql(u8, entry.name, cas_lock_sweep_marker)) continue;
        lock_count += 1;
        try std.testing.expect(casLockName(entry.name));
        try std.testing.expect(std.mem.find(u8, entry.name, "note") == null);
    }
    try std.testing.expectEqual(@as(usize, 1), lock_count);

    // The lock file carries who took it and when, so a write that hangs is
    // attributable. It is fixed width, so a later shorter record cannot leave
    // the tail of an earlier longer one behind.
    var it2 = locks.iterate();
    const entry = while (try it2.next(io)) |e| {
        if (casLockName(e.name)) break e;
    } else unreachable; // the count above already found exactly one
    const rec = try locks.readFileAlloc(io, entry.name, gpa, .limited(1 << 12));
    defer gpa.free(rec);
    try std.testing.expectEqual(@as(usize, cas_lock_record.record_len), rec.len);
    try std.testing.expectEqual(@as(u8, '\n'), rec[rec.len - 1]);
    try std.testing.expect(std.mem.startsWith(u8, rec, "pid="));
    try std.testing.expect(std.mem.find(u8, rec, " acquired_ms=") != null);
    try std.testing.expect(std.mem.find(u8, rec, "target=") != null);
    try std.testing.expect(std.mem.find(u8, rec, "docs/note.md") != null);

    // A mismatch is the ordinary contention outcome. It used to run
    // createDirPath before the compare, so a refused write still materialised
    // a directory tree for a file that never existed.
    const stale = "0" ** 64;
    try std.testing.expectEqual(
        Err.mismatch,
        fsWriteIfImpl(&sb, fixture.tmp.dir, "never/written/here.md", stale, "nope"),
    );
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, "never", .{}));
}

test "a CAS lock is keyed by the resolved target, so two spellings share one lock" {
    // The lock name used to be the SHA-256 of the joined path *string*, and the
    // same file is spelled two ways in production: `./state/goals.json` in an
    // ordinary run (agent.sandbox_root defaults to ".") and
    // `/abs/checkout/state/goals.json` in an isolated one, whose shared_root is
    // std.process.currentPathAlloc. Two names meant two lock inodes on one
    // file, so neither writer excluded the other and the earlier write was lost
    // (docs/reports/bugs/2026-08-17-cas-lock-name-hashes-an-unresolved-path.md).
    var fixture: test_env.Env = .init();
    defer fixture.deinit();
    const gpa = std.testing.allocator;
    const io = fixture.io();
    try fixture.tmp.dir.createDirPath(io, "notes");

    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = abs_buf[0..try fixture.tmp.dir.realPath(io, &abs_buf)];

    var relative = Sandbox{
        .gpa = gpa,
        .io = io,
        .root_dir = ".",
        .network_allow = &.{},
        .fs_prefixes = &.{"."},
        .environ_map = undefined,
    };
    var absolute = Sandbox{
        .gpa = gpa,
        .io = io,
        .root_dir = abs,
        .network_allow = &.{},
        .fs_prefixes = &.{"."},
        .environ_map = undefined,
    };

    try std.testing.expectEqual(Err.ok, fsWriteIfImpl(&relative, fixture.tmp.dir, "notes/x.md", "", "one"));
    // The second sandbox addresses the same file, so an empty expected hash is
    // now a mismatch rather than a create. That is what makes the count below
    // meaningful: one file, reached twice.
    try std.testing.expectEqual(Err.mismatch, fsWriteIfImpl(&absolute, fixture.tmp.dir, "notes/x.md", "", "two"));

    var locks = try fixture.tmp.dir.openDir(io, "state/locks", .{ .iterate = true });
    defer locks.close(io);
    var it = locks.iterate();
    var lock_count: usize = 0;
    // Lock files only: the sweep's own marker lives in this directory too.
    while (try it.next(io)) |entry| {
        if (casLockName(entry.name)) lock_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), lock_count);
}

test "CAS locks live under the sandbox root, not beside the process cwd" {
    // The lock directory was resolved against the process cwd while the target
    // was resolved against the sandbox root, so a sandbox rooted in a test's
    // tmp tree wrote permanent lock files into the operator's real state/locks:
    // 328 of the 387 files there on 2026-08-17 named a .zig-cache/tmp target.
    var fixture: test_env.Env = .init();
    defer fixture.deinit();
    const gpa = std.testing.allocator;
    const io = fixture.io();
    try fixture.tmp.dir.createDirPath(io, "proj/docs");

    var sb = Sandbox{
        .gpa = gpa,
        .io = io,
        .root_dir = "proj",
        .network_allow = &.{},
        .fs_prefixes = &.{"."},
        .environ_map = undefined,
    };

    try std.testing.expectEqual(Err.ok, fsWriteIfImpl(&sb, fixture.tmp.dir, "docs/note.md", "", "hi"));
    const lock_dir = try fixture.tmp.dir.statFile(io, "proj/state/locks", .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, lock_dir.kind);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, "state", .{}));
}

test "a CAS write sweeps aged lock files and keeps fresh or held ones" {
    // ADR 0031's Consequences say state/locks is swept, and nothing in clanker
    // fires on its own (ADR 0008) -- so the sweep has to happen on the path
    // that creates the files. An operator who never types `clanker janitor
    // --yes` would otherwise keep every lock file forever.
    var fixture: test_env.Env = .init();
    defer fixture.deinit();
    const gpa = std.testing.allocator;
    const io = fixture.io();
    try fixture.tmp.dir.createDirPath(io, "state/locks");

    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
    const aged_ms = now - 13 * 60 * 60 * 1000;
    const aged = "state/locks/" ++ "0" ** 64 ++ ".lock";
    const fresh = "state/locks/" ++ "1" ** 64 ++ ".lock";
    const held = "state/locks/" ++ "2" ** 64 ++ ".lock";

    var rec: [cas_lock_record.record_len]u8 = undefined;
    cas_lock_record.render(&rec, 1, aged_ms, "reports", "docs/target-that-is-gone.md");
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = aged, .data = &rec });
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = held, .data = &rec });
    cas_lock_record.render(&rec, 2, now, "reports", "docs/written-just-now.md");
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = fresh, .data = &rec });

    // An aged record is not a held lock: the record names the *last*
    // acquisition and a hold is only ever answered by trying to take it. A
    // writer that has been inside fs_write_if since before the window must
    // keep its lock file.
    const holder = try fixture.tmp.dir.createFile(io, held, .{ .truncate = false, .lock = .exclusive });

    var sb = testSandboxAtRoot(gpa, io);
    try std.testing.expectEqual(Err.ok, fsWriteIfImpl(&sb, fixture.tmp.dir, "docs/note.md", "", "hello"));

    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, aged, .{}));
    _ = try fixture.tmp.dir.statFile(io, fresh, .{});
    _ = try fixture.tmp.dir.statFile(io, held, .{});
    holder.close(io);
}

test "a recordless lock file is swept once settled, never while fresh or held" {
    // `agedOut` reads a timestamp out of the record, so a lock file with no
    // record was invisible to both sweepers and would have sat there forever:
    // 32 such files, all zero-byte, all predating the holder record, were found
    // in this checkout on 2026-08-17 and had to be removed by hand.
    //
    // Length is the discriminator, not content. A live acquisition is
    // zero-byte only between `createFileRetry` and `writeLockHolder`, and it
    // holds the lock across both, so the flock guard already covers the
    // in-flight case; the age floor covers the sliver where a writer has opened
    // the file but not yet locked it. A non-empty record that cannot be parsed
    // stays untouched -- unknown is still not old.
    var fixture: test_env.Env = .init();
    defer fixture.deinit();
    const gpa = std.testing.allocator;
    const io = fixture.io();
    try fixture.tmp.dir.createDirPath(io, "state/locks");

    const settled = "state/locks/" ++ "4" ** 64 ++ ".lock";
    const fresh = "state/locks/" ++ "5" ** 64 ++ ".lock";
    const held = "state/locks/" ++ "6" ** 64 ++ ".lock";
    const garbage = "state/locks/" ++ "7" ** 64 ++ ".lock";
    for ([_][]const u8{ settled, fresh, held }) |p| {
        try fixture.tmp.dir.writeFile(io, .{ .sub_path = p, .data = "" });
    }
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = garbage, .data = "not a record at all\n" });

    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
    const old_ns: i128 = @as(i128, now - 2 * 60 * 60 * 1000) * std.time.ns_per_ms;
    for ([_][]const u8{ settled, held, garbage }) |p| {
        try fixture.tmp.dir.setTimestamps(io, p, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(old_ns) } } });
    }
    const holder = try fixture.tmp.dir.createFile(io, held, .{ .truncate = false, .lock = .exclusive });

    var sb = testSandboxAtRoot(gpa, io);
    try std.testing.expectEqual(Err.ok, fsWriteIfImpl(&sb, fixture.tmp.dir, "docs/note.md", "", "hi"));

    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.statFile(io, settled, .{}));
    _ = try fixture.tmp.dir.statFile(io, fresh, .{});
    _ = try fixture.tmp.dir.statFile(io, held, .{});
    _ = try fixture.tmp.dir.statFile(io, garbage, .{});
    holder.close(io);
}

test "the lock sweep is rate limited by its marker, not run on every CAS write" {
    // The sweep walks a directory, so it must not run once per compare-and-swap
    // write. The marker's mtime is what spaces the passes out, and it is shared
    // between processes for the same reason the lock is.
    var fixture: test_env.Env = .init();
    defer fixture.deinit();
    const gpa = std.testing.allocator;
    const io = fixture.io();

    var sb = testSandboxAtRoot(gpa, io);

    // First write: the marker does not exist, so this pass sweeps and stamps it.
    try std.testing.expectEqual(Err.ok, fsWriteIfImpl(&sb, fixture.tmp.dir, "docs/one.md", "", "1"));
    _ = try fixture.tmp.dir.statFile(io, "state/locks/" ++ cas_lock_sweep_marker, .{});

    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
    const aged = "state/locks/" ++ "3" ** 64 ++ ".lock";
    var rec: [cas_lock_record.record_len]u8 = undefined;
    cas_lock_record.render(&rec, 1, now - 13 * 60 * 60 * 1000, "reports", "docs/gone.md");
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = aged, .data = &rec });

    // Second write, well inside the interval: no walk, so the aged file is
    // still there. It goes on the next pass.
    try std.testing.expectEqual(Err.ok, fsWriteIfImpl(&sb, fixture.tmp.dir, "docs/two.md", "", "2"));
    _ = try fixture.tmp.dir.statFile(io, aged, .{});
}

test "a tool may run only the commands its manifest names" {
    const none: []const []const u8 = &.{};
    try std.testing.expect(!execAllowed(none, "git"));
    try std.testing.expect(!execAllowed(none, "rg"));

    const only_zig = [_][]const u8{"zig"};
    try std.testing.expect(execAllowed(&only_zig, "zig"));
    try std.testing.expect(!execAllowed(&only_zig, "git"));
    // Not a prefix or substring match: "zigzag" is a different program.
    try std.testing.expect(!execAllowed(&only_zig, "zigzag"));

    const several = [_][]const u8{ "rg", "ast-grep", "semcode" };
    try std.testing.expect(execAllowed(&several, "ast-grep"));
    try std.testing.expect(!execAllowed(&several, "sh"));
}

test "sandboxFor carries the descriptor's fuel budget into the sandbox" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    const cfg = config_mod.Config{};
    var tool = registry.Tool{
        .name = "thrifty",
        .description = "d",
        .wasm = "t.wasm",
        .input_schema = .{ .object = .{} },
        .fuel = 2_000_000,
    };
    const sb = try sandboxFor(std.testing.allocator, io, arena, &env_map, &cfg, &tool, null);
    try std.testing.expectEqual(@as(u64, 2_000_000), sb.fuel);

    // Unset (0), the sandbox stays on 0 and runtime.zig's fuelBudget resolves
    // it to the default at instantiation.
    tool.fuel = 0;
    const sb2 = try sandboxFor(std.testing.allocator, io, arena, &env_map, &cfg, &tool, null);
    try std.testing.expectEqual(@as(u64, 0), sb2.fuel);
}
