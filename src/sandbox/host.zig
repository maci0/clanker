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
const protocol = @import("protocol.zig");
const client = @import("../llm/client.zig");
const types = @import("../llm/types.zig");
const config_mod = @import("../config.zig");
const registry = @import("../tools/registry.zig");
const chatrooms_mod = @import("../peers/chatrooms.zig");
const private_todos_mod = @import("../agent/private_todos.zig");
const filelock = @import("../util/filelock.zig");
const token_stats = @import("../stats/tokens.zig");
const build_options = @import("build_options");
const zwasm = @import("zwasm");

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
pub const scratch_cap = 64 * 1024;

/// Error codes returned by ck_* host functions.
/// Zig standard library directory (set at startup from build_options).
/// Used by the std_api tool to look up symbol signatures.
pub var zig_lib_dir: []const u8 = "";

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
/// tool is `llm: true`, which pins it to the sequential tool path, so while
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

/// Per-tool sandbox policy, owned by the harness.
pub const Sandbox = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Absolute path of the directory tool filesystem access is confined to.
    root_dir: []const u8,
    /// Hosts allowed for ck_http. Entries are exact hostnames or glob
    /// patterns (`*.example.com`, `sub?.example.com`); a bare `*` allows every
    /// host. See networkAllowed.
    network_allow: []const []const u8,
    /// Directory prefixes (relative to root_dir) the tool may read/write.
    /// Empty means filesystem access is denied entirely.
    fs_prefixes: []const []const u8 = &.{},
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
    /// The tool descriptor's `config` object, serialized. Returned verbatim by
    /// `ck_config` so a plugin can read its own settings.
    config_json: []const u8 = "{}",
    /// Commands allowed through ck_exec for this tool. Empty falls back to the
    /// harness default set below.
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
    /// May call another tool via `ck_tool`. Default false, only the chain
    /// tool sets this.
    tool_call: bool = false,
    tool_allow: ?[]const []const u8 = null,
    tool_self_name: []const u8 = "",
    tool_registry: ?*const registry.Registry = null,
    tool_call_depth: u8 = 0,
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
};

/// A plugin may aim ck_llm at its own backend with
/// `"config": {"provider": "kimi-k3", "model": "..."}`; anything it leaves out
/// falls back to the configured default.
fn pluginProvider(
    arena: std.mem.Allocator,
    cfg: *const config_mod.Config,
    tool: *const registry.Tool,
) !*const config_mod.Provider {
    const want_provider = pluginStr(tool.config, "provider");
    const want_model = pluginStr(tool.config, "model");
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

pub fn pluginStr(cfg_value: std.json.Value, key: []const u8) ?[]const u8 {
    if (cfg_value != .object) return null;
    const v = cfg_value.object.get(key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}

fn pluginU32(cfg_value: std.json.Value, key: []const u8) ?u32 {
    if (cfg_value != .object) return null;
    const v = cfg_value.object.get(key) orelse return null;
    // Reject out-of-u32-range values instead of panicking in @intCast (a
    // plugin's tool.json is not trusted input).
    if (v == .integer and v.integer > 0 and v.integer <= std.math.maxInt(u32)) return @intCast(v.integer);
    return null;
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
            .max_tokens = pluginU32(tool.config, "max_tokens") orelse 1024,
        };
    }

    return .{
        .gpa = gpa,
        .io = io,
        .root_dir = cfg.agent.sandbox_root,
        .network_allow = net,
        .llm = llm_access,
        .exec_allow = tool.exec_allow,
        .git_remote_ops = cfg.agent.git_remote_ops,
        .exec_pattern_allow = cfg.agent.exec_pattern_allow,
        .env_allow = tool.env_allow,
        .tool_call = tool.tool_call,
        .tool_allow = tool.tool_allow,
        .tool_self_name = tool.name,
        .tool_registry = null,
        .tool_call_depth = 0,
        .fs_prefixes = tool.fs_prefixes,
        .fuel = tool.fuel,
        .environ_map = environ_map,
        .seed = cfg.agent.seed,
        .cfg = cfg,
        // An exec-capable tool sees the harness's exec policy in its own
        // `config` so the git.zig / gh.zig guests can mirror the host's deny
        // decision instead of pre-empting it (e.g. a hardcoded in-tool "merge
        // is denied" would block what git_remote_ops just granted).
        .config_json = if (tool.exec_allow.len > 0)
            try execPolicyConfig(arena, tool.config_json, cfg)
        else
            tool.config_json,
    };
}

/// Builds the `config` object handed to an exec-capable tool, merging its
/// descriptor config with the harness's exec policy (git_remote_ops,
/// exec_pattern_allow). Non-exec tools keep their own config untouched. The
/// extra keys are inert to a tool that does not read `config`. The JSON is
/// built by hand because it is small and controlled, and avoids relying on
/// std.json.Stringify's serialization of a nested string slice.
pub fn execPolicyConfig(
    arena: std.mem.Allocator,
    tool_config: []const u8,
    cfg: *const config_mod.Config,
) ![]const u8 {
    _ = tool_config; // git.zig / gh.zig carry no descriptor config of their own.
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '{');
    try out.appendSlice(arena, "\"git_remote_ops\":");
    try out.appendSlice(arena, if (cfg.agent.git_remote_ops) "true" else "false");
    try out.appendSlice(arena, ",\"exec_pattern_allow\":[");
    for (cfg.agent.exec_pattern_allow, 0..) |p, i| {
        if (i > 0) try out.append(arena, ',');
        try appendJsonString(arena, &out, p);
    }
    try out.appendSlice(arena, "]}");
    return out.toOwnedSlice(arena);
}

fn appendJsonString(arena: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(arena, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(arena, "\\\""),
            '\\' => try out.appendSlice(arena, "\\\\"),
            '\n' => try out.appendSlice(arena, "\\n"),
            '\r' => try out.appendSlice(arena, "\\r"),
            '\t' => try out.appendSlice(arena, "\\t"),
            else => try out.append(arena, c),
        }
    }
    try out.append(arena, '"');
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

fn isResearchTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "fetch_web") or std.mem.eql(u8, name, "web_search");
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
        .name = "fetch_web",
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
    if (v.object.get("max_tokens")) |m| {
        // Reject out-of-u32-range values instead of panicking in @intCast.
        if (m == .integer and m.integer > 0 and m.integer <= std.math.maxInt(u32)) req.max_tokens = @intCast(m.integer);
    }
    if (v.object.get("provider")) |pn| {
        if (pn == .string and pn.string.len > 0) req.provider = pn.string;
    }
    if (v.object.get("model")) |mn| {
        if (mn == .string and mn.string.len > 0) req.model = mn.string;
    }
    if (v.object.get("system")) |sp| {
        if (sp == .string and sp.string.len > 0) req.system = sp.string;
    }
    return req;
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
        if (req.max_tokens) |m| max_tokens = m;
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
        log.log(.warn, "[llm] ✗ ck_llm … {d}ms: {s} ({s})", .{ failed_ms, @errorName(err), err_detail orelse "" });
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
/// freed by the caller after encoding, mirroring ckSwarm's SwarmCall.
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
    var max_tokens = access.max_tokens;
    if (obj.get("max_tokens")) |m| {
        if (m == .integer and m.integer > 0 and m.integer <= std.math.maxInt(u32)) max_tokens = @intCast(m.integer);
    }

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
/// tools that just display the file (config_view's whole-dump path); a tool
/// that needs structured fields (peers, providers, cmd_status, ask_user)
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

const HarnessConfigAccess = enum { full, providers, peers, workflows, chains };

/// ck_harness_config is a privileged structured view, independent of
/// fs_prefixes. Grant each shipped caller only the section it consumes and
/// fail closed for any other guest, including newly added tools.
fn harnessConfigAccess(tool_name: []const u8) ?HarnessConfigAccess {
    if (std.mem.eql(u8, tool_name, "config_view")) return .full;
    // arena needs the provider list for one question only: which configured
    // provider is free to judge a match, i.e. is not already fighting it.
    // `.providers` answers that without handing it the api_key_env names
    // `.full` carries.
    // compare needs it for two questions: which providers exist (so `clanker
    // compare` with no --with can put the configured ones side by side) and
    // which one is free to judge, i.e. is not itself an entrant.
    if (std.mem.eql(u8, tool_name, "providers") or std.mem.eql(u8, tool_name, "arena") or
        std.mem.eql(u8, tool_name, "compare")) return .providers;
    if (std.mem.eql(u8, tool_name, "peers") or std.mem.eql(u8, tool_name, "cmd_status") or std.mem.eql(u8, tool_name, "ask_user")) return .peers;
    if (std.mem.eql(u8, tool_name, "workflows")) return .workflows;
    if (std.mem.eql(u8, tool_name, "chain")) return .chains;
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
            try s.objectField("models");
            try s.beginObject();
            var mit = p.models.iterator();
            while (mit.next()) |mkv| {
                const m = mkv.value_ptr;
                try s.objectField(mkv.key_ptr.*);
                try s.beginObject();
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
                try s.endObject();
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

    if (access == .full or access == .workflows or access == .chains) {
        try s.objectField("agent");
        try s.beginObject();
        if (access == .full or access == .workflows) {
            try s.objectField("workflows_dir");
            try s.write(cfg.agent.workflows_dir);
        }
        if (access == .full or access == .chains) {
            try s.objectField("chains_dir");
            try s.write(cfg.agent.chains_dir);
        }
        try s.endObject();
    }

    // config_view's section mode promises the merged `modules` table. Keep
    // this on the full view only: no other guest consumer needs feature
    // flags, and narrower views should not grow unrelated config fields.
    if (access == .full) {
        try s.objectField("modules");
        try s.write(cfg.modules);
    }

    try s.endObject();
    return w.toOwnedSlice();
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
/// Everything else has to be named by the tool's manifest.
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
        log.log(.warn, "[docker] json parse failed: '{s}'", .{json_input});
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

    // Connect to the Docker Unix socket (std.Io.net API in Zig 0.16).
    const ua = std.Io.net.UnixAddress.init("/var/run/docker.sock") catch |err| {
        log.log(.warn, "[docker] unixaddr init failed: {s}", .{@errorName(err)});
        return Err.invalid;
    };
    const stream = ua.connect(h.sandbox.io) catch |err| {
        log.log(.warn, "[docker] connect failed: {s}", .{@errorName(err)});
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
        resp.appendSlice(h.sandbox.gpa, tmp[0..nr]) catch return Err.too_large;
        if (resp.items.len > h.sandbox.max_http_bytes) return Err.too_large;
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

fn methodFromDockerInput(obj: std.json.ObjectMap) []const u8 {
    const value = obj.get("method") orelse return "GET";
    return if (value == .string) value.string else "";
}

/// The Docker socket is equivalent to root authority on many hosts. This tool
/// is an inspection surface, so the native boundary permits only GET even if
/// a modified guest asks for a state-changing daemon operation.
fn dockerRequestAllowed(method: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, method, "GET") and
        std.mem.startsWith(u8, path, "/v1.") and
        std.mem.findAny(u8, path, "\r\n \t\x00") == null;
}

test "docker request policy is query only" {
    try std.testing.expect(dockerRequestAllowed("GET", "/v1.41/containers/json"));
    try std.testing.expect(!dockerRequestAllowed("POST", "/v1.41/containers/prune"));
    try std.testing.expect(!dockerRequestAllowed("GET", "/containers/json"));
    try std.testing.expect(!dockerRequestAllowed("GET", "/v1.41/containers/json\r\nX-Evil: yes"));
    try std.testing.expect(!dockerRequestAllowed("GET", "/v1.41/containers/json HTTP/1.0\nEvil: yes"));
    try std.testing.expect(!dockerRequestAllowed("GET", "/v1.41/exec/a start"));
    try std.testing.expect(!dockerRequestAllowed("GET", "/v1.41/exec/a\tstart"));
    try std.testing.expect(!dockerRequestAllowed("GET", "/v1.41/x\x00y"));
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
/// context budget. Read one extra record internally so callers that must fold
/// a complete log can tell whether another page exists without guessing from
/// a full final page.
const chat_history_page_size = 20;

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
        const msg = chatrooms_mod.sendMessageOpts(base, h.sandbox.io, h.sandbox.gpa, arena, state_dir, cfg, room, text, parsed.thread_ts) catch |err| {
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
            const asc = chatrooms_mod.readHistoryAsc(base, h.sandbox.io, arena, state_dir, room, after, chat_history_page_size) catch return Err.invalid;
            msgs = asc.msgs;
            has_more = asc.has_more;
        } else {
            const page = chatrooms_mod.readHistory(base, h.sandbox.io, h.sandbox.gpa, arena, state_dir, room, after, chat_history_page_size + 1) catch return Err.invalid;
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
            s.write(if (m.text.len > 600) m.text[0..600] else m.text) catch return Err.too_large;
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
        const rooms = chatrooms_mod.listRooms(base, h.sandbox.io, h.sandbox.gpa, arena, state_dir) catch return Err.invalid;
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
        if (emoji.len == 0 or emoji.len > 64) return Err.invalid;
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
        ) catch |err| {
            log.log(.warn, "[chat] react failed: {s}", .{@errorName(err)});
            return Err.invalid;
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
        const result = chatrooms_mod.editMessage(
            base,
            h.sandbox.io,
            h.sandbox.gpa,
            arena,
            state_dir,
            cfg,
            msg_id,
            new_text,
            cfg.instance.name,
        ) catch |err| {
            log.log(.warn, "[chat] edit failed: {s}", .{@errorName(err)});
            return Err.invalid;
        };
        if (result) |msg| {
            s.beginObject() catch return Err.too_large;
            s.objectField("ok") catch return Err.too_large;
            s.write(true) catch return Err.too_large;
            s.objectField("id") catch return Err.too_large;
            s.write(msg.id) catch return Err.too_large;
            s.objectField("edited") catch return Err.too_large;
            s.print("{d}", .{msg.edited.?}) catch return Err.too_large;
            s.endObject() catch return Err.too_large;
            return h.writeResult(bytes, out_buf[0..w.end]);
        } else {
            return h.writeResult(bytes, "{\"ok\":false,\"error\":\"not found or not authorised\"}");
        }
    } else if (std.mem.eql(u8, op, "delete")) {
        const msg_id = parsed.msg_id orelse return Err.invalid;
        const ok = chatrooms_mod.deleteMessage(
            base,
            h.sandbox.io,
            h.sandbox.gpa,
            arena,
            state_dir,
            cfg,
            msg_id,
            cfg.instance.name,
        ) catch |err| {
            log.log(.warn, "[chat] delete failed: {s}", .{@errorName(err)});
            return Err.invalid;
        };
        if (ok) {
            s.beginObject() catch return Err.too_large;
            s.objectField("ok") catch return Err.too_large;
            s.write(true) catch return Err.too_large;
            s.endObject() catch return Err.too_large;
            return h.writeResult(bytes, out_buf[0..w.end]);
        } else {
            return h.writeResult(bytes, "{\"ok\":false,\"error\":\"not found or not authorised\"}");
        }
    } else if (std.mem.eql(u8, op, "set_topic")) {
        const room = parsed.room orelse return Err.invalid;
        const new_topic = parsed.topic orelse return Err.invalid;
        if (new_topic.len > 1024) return Err.invalid;
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
    // The board is one guest (board.wasm) behind eleven manifest names, and it
    // needs two ops rather than one: it replicates each card into its room with
    // "send" and folds that room's log back with "history" on every read.
    // Matched on the "board" name (the internal multiplexed entry) and the
    // "kanban_" prefix the public tools use (commit 4fadb86 renamed the tools
    // from board_* to kanban_*).
    if (std.mem.eql(u8, tool_name, "board") or
        std.mem.startsWith(u8, tool_name, "kanban_"))
        return std.mem.eql(u8, op, "send") or std.mem.eql(u8, op, "history");
    // The janitor announces what it pruned into the room. Like the board it
    // ignores a failed chat call, so being denied here cost it its
    // announcements silently rather than failing the prune.
    if (std.mem.eql(u8, tool_name, "cmd_janitor")) return std.mem.eql(u8, op, "send");

    const allowed_ops: ?[]const []const u8 = if (std.mem.eql(u8, tool_name, "chat_send"))
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

/// ck_stats() exposes the authorized global token-usage records to the
/// model_stats guest. Parsing and aggregation are application logic and live
/// in tools/zig/stats.zig; the native boundary only resolves the configured
/// state directory, enforces the module switch, and reads the protected log.
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

    const records = token_stats.loadAll(base, h.sandbox.io, h.sandbox.gpa, arena, state_dir) catch |err| {
        log.log(.warn, "[stats] read failed: {s}", .{@errorName(err)});
        return Err.invalid;
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{} };
    s.write(records) catch return Err.too_large;
    return h.writeResult(bytes, out.written());
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

    var http: std.http.Client = .{ .allocator = h.sandbox.gpa, .io = h.sandbox.io };
    defer http.deinit();

    const resp_buf = h.sandbox.gpa.alloc(u8, h.sandbox.max_http_bytes) catch return Err.too_large;
    defer h.sandbox.gpa.free(resp_buf);
    var w: std.Io.Writer = .fixed(resp_buf);

    const req_method = httpMethodFromCode(method) orelse return Err.invalid;
    const has_body = req_method == .POST or req_method == .PUT or req_method == .PATCH;
    const result = http.fetch(.{
        .location = .{ .url = url },
        .method = req_method,
        .payload = if (has_body) body else null,
        .headers = .{ .user_agent = .{ .override = "clanker-tool/" ++ build_options.version } },
        .extra_headers = if (n_custom > 0) custom_hdrs[0..n_custom] else &.{},
        .response_writer = &w,
        // network_allow only checks `hostname` above, once, against the
        // requested URL. std.http.Client auto-follows redirects by default,
        // and a redirect target is never re-checked against that allowlist;
        // an allowed host could 302 the sandboxed tool to an internal address
        // (e.g. a cloud metadata IP) the allowlist exists to block. Refusing
        // redirects outright keeps every request confined to the host that
        // was actually checked.
        .redirect_behavior = .not_allowed,
    }) catch return Err.network;

    const response = resp_buf[0..w.end];
    if (@intFromEnum(result.status) >= 400) {
        log.log(.warn, "[sandbox] http request to '{s}' failed with status {d}", .{ url, @intFromEnum(result.status) });
        return Err.network;
    }
    return h.writeResult(mem_bytes, response);
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

/// ck_fs_find(dir_path, pattern), recursively find files under a sandbox
/// directory whose names match a simple glob pattern. The pattern supports
/// '*' (matches any sequence of non-'/' chars) and '?' (matches exactly one
/// non-'/' char); everything else is a literal match. Returns a JSON string
/// array of relative paths (relative to the sandbox root) in the host arena.
/// Enforces the same fs_prefixes policy as ck_fs_read.
/// Returns Err.not_found when the directory does not exist.
pub fn ckFsFind(caller: *zwasm.Caller, dir_ptr: u32, dir_len: u32, pat_ptr: u32, pat_len: u32) u32 {
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

    fsFindRecurse(h, &s, dir, dir_path, pattern, 0) catch return Err.too_large;

    s.endArray() catch return Err.too_large;
    return h.writeResult(bytes, buf[0..w.end]);
}

const fs_find_max_depth: u32 = 12;

/// Directories a name search should never descend into. Without this, a search
/// of the project answers mostly with copies of it: build caches, vendored
/// dependencies, and the staging trees the improvement engine leaves behind.
const fs_skip_dirs = [_][]const u8{ ".git", ".zig-cache", "zig-out", "zig-pkg", "node_modules", "staging", "history" };

fn skipDir(name: []const u8) bool {
    for (fs_skip_dirs) |d| {
        if (std.mem.eql(u8, name, d)) return true;
    }
    return false;
}

fn fsFindRecurse(h: *Host, s: *std.json.Stringify, dir: std.Io.Dir, prefix: []const u8, pattern: []const u8, depth: u32) !void {
    if (depth > fs_find_max_depth) return;
    var it = dir.iterate();
    while (it.next(h.sandbox.io) catch null) |entry| {
        if (entry.name.len == 0) continue;
        const rel = std.fmt.allocPrint(h.sandbox.gpa, "{s}{s}{s}", .{
            prefix,
            if (prefix.len > 0) "/" else "",
            entry.name,
        }) catch return error.OutOfMemory;
        defer h.sandbox.gpa.free(rel);

        if (entry.kind == .directory) {
            if (skipDir(entry.name)) continue;
            var sub = dir.openDir(h.sandbox.io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(h.sandbox.io);
            try fsFindRecurse(h, s, sub, rel, pattern, depth + 1);
        } else if (entry.kind == .file) {
            if (globMatch(pattern, entry.name)) {
                try s.write(rel);
            }
        }
    }
}

/// Simple glob match: '*' matches zero or more non-'/' chars, '?' matches
/// exactly one non-'/' char, everything else is literal (case-sensitive).
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    var pi: usize = 0;
    var ni: usize = 0;
    var star_p: ?usize = null;
    var star_n: usize = 0;
    while (ni < name.len or pi < pattern.len) {
        if (pi < pattern.len and pattern[pi] == '*') {
            star_p = pi;
            star_n = ni;
            pi += 1;
            continue;
        }
        if (ni < name.len and pi < pattern.len) {
            if (pattern[pi] == '?' and name[ni] != '/') {
                pi += 1;
                ni += 1;
                continue;
            }
            if (pattern[pi] == name[ni]) {
                pi += 1;
                ni += 1;
                continue;
            }
        }
        if (star_p) |sp| {
            pi = sp + 1;
            star_n += 1;
            if (star_n > name.len) return false;
            ni = star_n;
            continue;
        }
        return false;
    }
    return true;
}

/// ck_fs_grep(dir_path, pattern), search for lines containing a literal
/// substring in files under a sandbox directory. Returns a JSON array of
/// `{"file":"<relative-path>","line":<number>,"text":"<line-content>"}` objects
/// in the host arena. Searches recursively up to `fs_grep_max_depth` levels
/// deep; stops after `fs_grep_max_results` matching lines. Binary files
/// (containing null bytes in the first 512 bytes) are skipped. Enforces the
/// same fs_prefixes policy as ck_fs_read.
pub fn ckFsGrep(caller: *zwasm.Caller, dir_ptr: u32, dir_len: u32, pat_ptr: u32, pat_len: u32) u32 {
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
    fsGrepRecurse(h, &s, dir, dir_path, pattern, 0, &count) catch return Err.too_large;

    s.endArray() catch return Err.too_large;
    return h.writeResult(bytes, buf[0..w.end]);
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
        const rel = std.fmt.allocPrint(h.sandbox.gpa, "{s}{s}{s}", .{
            prefix,
            if (prefix.len > 0) "/" else "",
            entry.name,
        }) catch return error.OutOfMemory;
        defer h.sandbox.gpa.free(rel);

        if (entry.kind == .directory) {
            // Skip hidden directories (e.g. .git)
            if (entry.name[0] == '.') continue;
            var sub = dir.openDir(h.sandbox.io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(h.sandbox.io);
            try fsGrepRecurse(h, s, sub, rel, pattern, depth + 1, count);
        } else if (entry.kind == .file) {
            fsGrepFile(h, s, dir, entry.name, rel, pattern, count) catch continue;
        }
    }
}

fn fsGrepFile(
    h: *Host,
    s: *std.json.Stringify,
    dir: std.Io.Dir,
    name: []const u8,
    rel_path: []const u8,
    pattern: []const u8,
    count: *u32,
) !void {
    // Read the file (up to max_fs_bytes).
    const data = dir.readFileAlloc(h.sandbox.io, name, h.sandbox.gpa, .limited(h.sandbox.max_fs_bytes)) catch return;
    defer h.sandbox.gpa.free(data);
    if (data.len == 0) return;

    // Skip binary files: check first 512 bytes for null.
    const check_len = @min(data.len, 512);
    for (data[0..check_len]) |b| {
        if (b == 0) return;
    }

    // Scan line by line.
    var line_no: u32 = 1;
    var start: usize = 0;
    while (start < data.len) {
        if (count.* >= fs_grep_max_results) return;
        const end = std.mem.findScalarPos(u8, data, start, '\n') orelse data.len;
        const line = data[start..end];
        if (std.mem.find(u8, line, pattern) != null) {
            const display = if (line.len > fs_grep_max_line) line[0..fs_grep_max_line] else line;
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
///   {"exists":true,"kind":"file","size":1234}
/// kind is one of "file", "directory", or "other".
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

    // Read the source file (up to max_fs_bytes).
    const data = std.Io.Dir.cwd().readFileAlloc(h.sandbox.io, full_src, h.sandbox.gpa, .limited(h.sandbox.max_fs_bytes)) catch |err| switch (err) {
        error.FileNotFound => return Err.not_found,
        error.StreamTooLong => return Err.too_large,
        else => return Err.invalid,
    };
    defer h.sandbox.gpa.free(data);

    // Create parent directories for the destination.
    if (std.mem.lastIndexOfScalar(u8, full_dst, '/')) |slash| {
        if (slash > 0) std.Io.Dir.cwd().createDirPath(h.sandbox.io, full_dst[0..slash]) catch {};
    }

    // Write the destination file.
    std.Io.Dir.cwd().writeFile(h.sandbox.io, .{ .sub_path = full_dst, .data = data }) catch |err| switch (err) {
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
    return appendLocked(h.sandbox.io, std.Io.Dir.cwd(), full, data);
}

/// Appends `data` to `rel`, creating it when absent.
///
/// Locked, because "ask for the size, then write there" is two steps: tools run
/// in parallel here, so two of them appending to one file both read the same
/// end and the second write lands on top of the first. The lock makes the pair
/// atomic between cooperating writers.
pub fn appendLocked(io: std.Io, base: std.Io.Dir, rel: []const u8, data: []const u8) u32 {
    // Through the retrying create: racing creates of a not-yet-existing log
    // spuriously fail ENOENT on macOS, and mapping that to Err.invalid here
    // silently dropped the append (filelock.createFileRetry has the story).
    var file = filelock.createFileRetry(io, base, rel, .{ .truncate = false, .lock = .exclusive }) catch |err| switch (err) {
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
    if (std.mem.lastIndexOfScalar(u8, full, '/')) |slash| {
        if (slash > 0) std.Io.Dir.cwd().createDirPath(h.sandbox.io, full[0..slash]) catch {};
    }
    std.Io.Dir.cwd().writeFile(h.sandbox.io, .{ .sub_path = full, .data = data }) catch |err| switch (err) {
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
    const lock_path = std.fmt.allocPrint(sb.gpa, "{s}.ck_cas.lock", .{full}) catch return Err.invalid;
    defer sb.gpa.free(lock_path);
    const lock_file = base.createFile(sb.io, lock_path, .{ .truncate = false, .lock = .exclusive }) catch |err| {
        log.log(.warn, "[fs_write_if] could not acquire lock for '{s}': {s}", .{ sub_path, @errorName(err) });
        return Err.invalid;
    };
    defer lock_file.close(sb.io);

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

    // Create parent directories.
    if (std.mem.lastIndexOfScalar(u8, full, '/')) |slash| {
        if (slash > 0) base.createDirPath(sb.io, full[0..slash]) catch {};
    }

    // Write (replace) the file.
    base.writeFile(sb.io, .{ .sub_path = full, .data = data }) catch |err| switch (err) {
        error.NoSpaceLeft, error.DiskQuota => return Err.too_large,
        else => return Err.invalid,
    };
    return Err.ok;
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
    return remote_ops and (std.mem.eql(u8, v, "push") or std.mem.eql(u8, v, "merge") or std.mem.eql(u8, v, "checkout"));
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
        cmd = if (std.mem.lastIndexOfScalar(u8, a0, '/')) |slash| a0[slash + 1 ..] else a0;
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
/// succeeded, every capability eval that shells out (zig_check, test_file)
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
    /// `exec_pattern_allow` names this command, which makes it strict, and no
    /// pattern matched the argv.
    no_pattern_match,
    /// A destructive verb or a run-something-else flag (`exec_deny_tokens`).
    deny_token: DeniedArg,
    /// A shell operator in an argument to a command that is itself a shell.
    shell_operator: DeniedArg,
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
/// (`src/tui/repl_vaxis.zig`): a line typed at the prompt is refused by
/// exactly the rules that refuse a tool, rather than by a second, drifting
/// copy of them.
pub fn execDenial(sb: *const Sandbox, cmd: []const u8, argv: []const []const u8) ?ExecDenial {
    // exec_pattern_allow decides whether the deny list even applies. A command
    // with a pattern is strict: only an argv matching one of its patterns runs,
    // and a match also overrides the deny tokens for the args it grants. A
    // command with no pattern stays under the deny-list check below.
    var join_buf: [4096]u8 = undefined;
    const policy = execPolicyFor(sb, argv, &join_buf);
    if (std.mem.eql(u8, cmd, "git") and !gitVerbAllowed(argv, sb.git_remote_ops)) return .git_verb;
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
    const base = if (std.mem.lastIndexOfScalar(u8, cmd, '/')) |i| cmd[i + 1 ..] else cmd;
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
/// symbols or project-internal code; use search_code / read_file instead.
pub fn ckStdApi(caller: *zwasm.Caller, sym_ptr: u32, sym_len: u32) u32 {
    const h = getHost(caller);
    if (!std.mem.eql(u8, h.sandbox.tool_self_name, "std_api")) return Err.denied;
    const bytes = memBytes(caller) orelse return Err.invalid;
    const sym = sliceOf(bytes, sym_ptr, sym_len) orelse return Err.invalid;
    if (sym.len == 0 or zig_lib_dir.len == 0) return Err.not_found;

    const std_dir = std.fmt.allocPrint(h.sandbox.gpa, "{s}/std", .{zig_lib_dir}) catch return Err.invalid;
    defer h.sandbox.gpa.free(std_dir);
    const argv = [_][]const u8{ "rg", "-n", "-F", "--max-count", "40", sym, std_dir };
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
    linker.defineFuncCtx("env", "ck_llm", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckLlm) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_llm_many", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckLlmMany) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_chat", child_host, fn (*zwasm_mod.Caller, u32, u32) u32, &ckChat) catch return Err.invalid;
    linker.defineFuncCtx("env", "ck_stats", child_host, fn (*zwasm_mod.Caller) u32, &ckStats) catch return Err.invalid;
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
    var scratch_fn = inst.typedFunc(fn (u32) u32, "scratch");
    const sp = scratch_fn.call(.{@intCast(args_json.len)}) catch return Err.invalid;
    if (sp == 0) return Err.too_large;
    const mem = inst.memory() orelse return Err.invalid;
    const slice = mem.slice();
    if (@as(u64, sp) + args_json.len > slice.len) return Err.too_large;
    @memcpy(slice[sp .. sp + args_json.len], args_json);
    var run_fn = inst.typedFunc(fn (u32, u32) u64, "run");
    const packed_val = run_fn.call(.{ sp, @intCast(args_json.len) }) catch return Err.invalid;
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

pub fn ckSubagent(caller: *zwasm.Caller, json_ptr: u32, json_len: u32) u32 {
    const h = getHost(caller);
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
    const th = std.Thread.spawn(.{ .stack_size = 128 * 1024 * 1024 }, SubagentCall.run, .{&call}) catch return Err.invalid;
    th.join();
    if (call.err) |e| {
        log.log(.error_, "subagent '{s}' failed: {s}", .{ task, @errorName(e) });
        return Err.invalid;
    }
    const result = call.result orelse "";
    const rc = h.writeResult(bytes, result);
    if (result.len > 0) h.sandbox.gpa.free(@constCast(result));
    return rc;
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
    // Each member gets the same brief a lone subagent would: what larger
    // work this serves. Unlike subagent, there is no per-task context/files
    //, a swarm task is expected to be a complete, self-contained brief
    // since members cannot see each other or the parent's transcript.
    const brief = Brief{ .parent_task = h.sandbox.parent_task };

    const SwarmCall = struct {
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

    const calls = arena.alloc(SwarmCall, tasks.len) catch return Err.too_large;
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
        threads[spawned] = std.Thread.spawn(.{ .stack_size = 128 * 1024 * 1024 }, SwarmCall.run, .{&calls[spawned]}) catch break;
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

/// True if `path` (split on '/') descends through a directory named
/// `.clanker-worktrees`, the per-run improve worktree container. Used to
/// stop an exec `cwd`/`dir` from landing inside a sibling run's worktree.
fn pathHasWorktreeDir(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".clanker-worktrees")) {
            // The container itself is fine; only descent *into* it matters.
            return it.rest().len > 0;
        }
    }
    return false;
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
            .no_pattern_match => log.log(.warn, "[sandbox] ck_exec denied '{s}': exec_pattern_allow makes this command strict and no pattern matches", .{cmd}),
            .deny_token => |x| log.log(.warn, "[sandbox] ck_exec denied token '{s}' in arg '{s}'", .{ x.token, x.arg }),
            .shell_operator => |x| log.log(.warn, "[sandbox] ck_exec denied shell operator '{s}' in arg '{s}'", .{ x.token, x.arg }),
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
        try s.print("output was {d} bytes and was cut to {d}; narrow the pattern or the path to see the rest", .{ stdout.len, exec_stdout_keep });
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

/// Keeps the head of `text`, ending on a line boundary so the last line is
/// whole rather than a fragment that reads as corrupted output.
fn clipOutput(text: []const u8, keep: usize) []const u8 {
    if (text.len <= keep) return text;
    const head = text[0..keep];
    if (std.mem.lastIndexOfScalar(u8, head, '\n')) |nl| return head[0 .. nl + 1];
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

/// True when `root_dir` names the process cwd itself, so an exec'd child needs
/// no explicit directory. Spelled out rather than compared against "." alone
/// because the config accepts the equivalent forms, and opening a directory we
/// are already in would only add a failure mode ("" is not a valid path).
fn rootIsProcessCwd(root_dir: []const u8) bool {
    return root_dir.len == 0 or
        std.mem.eql(u8, root_dir, ".") or
        std.mem.eql(u8, root_dir, "./");
}

fn safeJoin(sb: *const Sandbox, sub_path: []const u8) ![]u8 {
    if (sub_path[0..@min(sub_path.len, 1)].len > 0 and sub_path[0] == '/') return error.PathOutsideSandbox;
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
    {
        // An empty list is no authority, not unlimited authority. This used to
        // skip the check entirely, so a descriptor written as "fs_prefixes":
        // [] - which reads as "this tool touches no files" and is what the
        // documentation says it means - handed the tool every file under the
        // sandbox root instead. Least privilege has to be the default that
        // costs nothing to ask for.
        var allowed = false;
        for (sb.fs_prefixes) |p| {
            // "." means the sandbox root itself: every relative path under it
            // is inside. Without this a descriptor written as ["."] matched
            // nothing at all, since no relative path starts with a dot, and
            // the tool was denied every file in the project it was pointed at.
            if (std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, "./")) {
                allowed = true;
                break;
            }
            if (std.mem.startsWith(u8, sub_path, p)) {
                // The match must end at a path boundary: a bare prefix
                // ("notes") authorizes the directory itself and paths
                // beneath it, but never a sibling that merely shares the
                // leading bytes ("notes2/x"). Trailing-slash prefixes
                // ("notes/") only match beneath the directory, as before.
                if (p.len == 0 or p[p.len - 1] == '/' or sub_path.len == p.len or sub_path[p.len] == '/') {
                    allowed = true;
                    break;
                }
            }
            // A prefix of "state/runs/" also authorizes "state/runs" itself,
            // otherwise a tool allowed to read inside a directory cannot list
            // the directory to find out what is in it.
            if (p.len > 1 and p[p.len - 1] == '/' and std.mem.eql(u8, sub_path, p[0 .. p.len - 1])) {
                allowed = true;
                break;
            }
        }
        if (!allowed) return error.PathOutsideSandbox;
    }
    return std.fmt.allocPrint(sb.gpa, "{s}/{s}", .{ std.mem.trimEnd(u8, sb.root_dir, "/"), sub_path });
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
    try std.testing.expect(gitVerbAllowed(&.{ "git", "--git-dir=.local/worktrees/wt/.git", "--work-tree=.local/worktrees/wt", "add", "x" }, false));
    try std.testing.expect(gitVerbAllowed(&.{ "git", "--git-dir", ".local/worktrees/wt/.git", "--work-tree", ".local/worktrees/wt", "push", "origin", "branch" }, true));
    try std.testing.expect(!gitVerbAllowed(&.{ "git", "-C", ".local/worktrees/wt", "ls-remote" }, false));
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

test "ckFsStat uses safeJoin policy" {
    // Verify the safeJoin policy that ckFsStat relies on.
    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = undefined,
        .root_dir = "/tmp/sandbox",
        .network_allow = &.{},
        .fs_prefixes = &.{"data/"},
        .environ_map = undefined,
    };
    // Allowed prefix
    const ok = try safeJoin(&sb, "data/info.txt");
    defer std.testing.allocator.free(ok);
    try std.testing.expectEqualStrings("/tmp/sandbox/data/info.txt", ok);
    // Disallowed prefix
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "secrets/key"));
    // Traversal attempt
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "data/../secrets/key"));
    // Empty path
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, ""));
}

test "ckFsCopy uses safeJoin policy for both paths" {
    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = undefined,
        .root_dir = "/tmp/sandbox",
        .network_allow = &.{},
        .fs_prefixes = &.{"data/"},
        .environ_map = undefined,
    };
    // Both paths allowed
    const ok_src = try safeJoin(&sb, "data/original.txt");
    defer std.testing.allocator.free(ok_src);
    const ok_dst = try safeJoin(&sb, "data/copy.txt");
    defer std.testing.allocator.free(ok_dst);
    try std.testing.expectEqualStrings("/tmp/sandbox/data/original.txt", ok_src);
    try std.testing.expectEqualStrings("/tmp/sandbox/data/copy.txt", ok_dst);
    // Source outside prefix
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "secrets/original.txt"));
    // Destination outside prefix
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "secrets/copy.txt"));
    // Traversal in source
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "data/../secrets/key"));
    // Traversal in destination
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "data/../etc/passwd"));
    // Empty paths
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, ""));
}

test "ckFsRename uses safeJoin policy for both paths" {
    // Verify the safeJoin policy that ckFsRename relies on.
    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = undefined,
        .root_dir = "/tmp/sandbox",
        .network_allow = &.{},
        .fs_prefixes = &.{"data/"},
        .environ_map = undefined,
    };
    // Both paths allowed
    const ok_src = try safeJoin(&sb, "data/old.txt");
    defer std.testing.allocator.free(ok_src);
    const ok_dst = try safeJoin(&sb, "data/new.txt");
    defer std.testing.allocator.free(ok_dst);
    try std.testing.expectEqualStrings("/tmp/sandbox/data/old.txt", ok_src);
    try std.testing.expectEqualStrings("/tmp/sandbox/data/new.txt", ok_dst);
    // Source outside prefix
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "secrets/old.txt"));
    // Destination outside prefix
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "secrets/new.txt"));
    // Traversal in source
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "data/../secrets/key"));
    // Traversal in destination
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "data/../etc/passwd"));
    // Empty paths
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, ""));
}

test "ckFsDelete uses safeJoin policy" {
    // Verify the safeJoin policy that ckFsDelete relies on.
    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = undefined,
        .root_dir = "/tmp/sandbox",
        .network_allow = &.{},
        .fs_prefixes = &.{"data/"},
        .environ_map = undefined,
    };
    // Allowed prefix
    const ok = try safeJoin(&sb, "data/file.txt");
    defer std.testing.allocator.free(ok);
    try std.testing.expectEqualStrings("/tmp/sandbox/data/file.txt", ok);
    // Disallowed prefix
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "secrets/key"));
    // Traversal attempt
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "data/../secrets/key"));
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

test "ckFsWriteRange uses safeJoin policy" {
    // Verify the safeJoin policy that ckFsWriteRange relies on.
    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = undefined,
        .root_dir = "/tmp/sandbox",
        .network_allow = &.{},
        .fs_prefixes = &.{"data/"},
        .environ_map = undefined,
    };
    // Allowed prefix
    const ok = try safeJoin(&sb, "data/patch.bin");
    defer std.testing.allocator.free(ok);
    try std.testing.expectEqualStrings("/tmp/sandbox/data/patch.bin", ok);
    // Disallowed prefix
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "secrets/key"));
    // Traversal attempt
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "data/../secrets/key"));
    // Empty path
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, ""));
}

test "ckFsAppend uses safeJoin policy" {
    // Verify the safeJoin policy that ckFsAppend relies on.
    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = undefined,
        .root_dir = "/tmp/sandbox",
        .network_allow = &.{},
        .fs_prefixes = &.{"logs/"},
        .environ_map = undefined,
    };
    // Allowed prefix
    const ok = try safeJoin(&sb, "logs/app.log");
    defer std.testing.allocator.free(ok);
    try std.testing.expectEqualStrings("/tmp/sandbox/logs/app.log", ok);
    // Disallowed prefix
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "secrets/key"));
    // Traversal attempt
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "logs/../secrets/key"));
    // Empty path
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, ""));
}

test "ckFsMkdir rejects paths outside sandbox" {
    // We can't call ckFsMkdir directly (needs a zwasm.Caller), but we can
    // verify the safeJoin policy it relies on rejects the same cases.
    var sb = Sandbox{
        .gpa = std.testing.allocator,
        .io = undefined,
        .root_dir = "/tmp/sandbox",
        .network_allow = &.{},
        .fs_prefixes = &.{"data/"},
        .environ_map = undefined,
    };
    // Allowed prefix
    const ok = try safeJoin(&sb, "data/subdir");
    defer std.testing.allocator.free(ok);
    try std.testing.expectEqualStrings("/tmp/sandbox/data/subdir", ok);
    // Disallowed prefix
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "other/subdir"));
    // Traversal
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "data/../etc"));
    // Empty
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, ""));
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
    // A cwd that re-enters the per-run improve worktree container is refused.
    try std.testing.expect(pathHasWorktreeDir(".clanker-worktrees/123/src"));
    try std.testing.expect(pathHasWorktreeDir("state/.clanker-worktrees/456"));
    try std.testing.expect(pathHasWorktreeDir("./.clanker-worktrees/789"));
    // "Through", not "at": the container holds every run's worktree and is not
    // itself any run's, so naming it is allowed however it is spelled and only
    // going a level deeper is refused.
    //
    // Strictness here would not buy the isolation it looks like it buys: this
    // checks the `cwd` field only, so `git -C .clanker-worktrees/123 status`
    // with no cwd at all reads a sibling's tree either way. Closing that needs
    // the argv checked too, which is a bigger change than this guard.
    try std.testing.expect(!pathHasWorktreeDir(".clanker-worktrees"));
    try std.testing.expect(!pathHasWorktreeDir(".clanker-worktrees/"));
    // Unrelated subdirs stay usable.
    try std.testing.expect(!pathHasWorktreeDir("src/sandbox"));
    try std.testing.expect(!pathHasWorktreeDir("state/runs"));
    try std.testing.expect(!pathHasWorktreeDir(""));
    try std.testing.expect(!pathHasWorktreeDir("clanker-worktrees/123")); // sibling name
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

test "pluginStr and pluginU32 fall back to null on missing, empty, or wrong-typed fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"provider\":\"kimi\",\"model\":\"m1\",\"max_tokens\":512}", .{});
    try std.testing.expectEqualStrings("kimi", pluginStr(v, "provider").?);
    try std.testing.expectEqualStrings("m1", pluginStr(v, "model").?);
    try std.testing.expect(pluginStr(v, "missing") == null);
    try std.testing.expectEqual(@as(?u32, 512), pluginU32(v, "max_tokens"));

    // Non-object values yield null for every key.
    const arr = try std.json.parseFromSliceLeaky(std.json.Value, arena, "[1,2]", .{});
    try std.testing.expect(pluginStr(arr, "provider") == null);
    try std.testing.expect(pluginU32(arr, "max_tokens") == null);

    // Empty strings and non-positive integers are treated as unset.
    const bad = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"provider\":\"\",\"max_tokens\":0}", .{});
    try std.testing.expect(pluginStr(bad, "provider") == null);
    try std.testing.expect(pluginU32(bad, "max_tokens") == null);

    // A value beyond u32 range must be ignored, not panic @intCast.
    const huge = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"max_tokens\":9000000000}", .{});
    try std.testing.expect(pluginU32(huge, "max_tokens") == null);
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

test "chat host channel pins each descriptor to its operation" {
    try std.testing.expect(chatAccessAllowed("chat_send", "send"));
    try std.testing.expect(chatAccessAllowed("todo_close", "todo_close"));
    try std.testing.expect(!chatAccessAllowed("chat_send", "history"));
    try std.testing.expect(!chatAccessAllowed("chat_send-helper", "send"));
    try std.testing.expect(!chatAccessAllowed("unrelated", "send"));
}

test "harness config access is scoped to each tool's consumed fields" {
    try std.testing.expectEqual(HarnessConfigAccess.providers, harnessConfigAccess("providers").?);
    try std.testing.expectEqual(HarnessConfigAccess.peers, harnessConfigAccess("peers").?);
    try std.testing.expectEqual(HarnessConfigAccess.workflows, harnessConfigAccess("workflows").?);
    try std.testing.expectEqual(HarnessConfigAccess.chains, harnessConfigAccess("chain").?);
    try std.testing.expect(harnessConfigAccess("unrelated") == null);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cfg = config_mod.Config{};

    const workflows = try harnessConfigJSON(arena, &cfg, .workflows);
    try std.testing.expect(std.mem.find(u8, workflows, "workflows_dir") != null);
    try std.testing.expect(std.mem.find(u8, workflows, "chains_dir") == null);
    try std.testing.expect(std.mem.find(u8, workflows, "providers") == null);
    try std.testing.expect(std.mem.find(u8, workflows, "peers") == null);

    const providers_json = try harnessConfigJSON(arena, &cfg, .providers);
    try std.testing.expect(std.mem.find(u8, providers_json, "default_provider") != null);
    try std.testing.expect(std.mem.find(u8, providers_json, "api_key_env") == null);
    try std.testing.expect(std.mem.find(u8, providers_json, "peers") == null);
    try std.testing.expect(std.mem.find(u8, providers_json, "agent") == null);

    const peers = try harnessConfigJSON(arena, &cfg, .peers);
    try std.testing.expect(std.mem.find(u8, peers, "peers") != null);
    try std.testing.expect(std.mem.find(u8, peers, "instance") != null);
    try std.testing.expect(std.mem.find(u8, peers, "providers") == null);
    try std.testing.expect(std.mem.find(u8, peers, "agent") == null);

    const full = try harnessConfigJSON(arena, &cfg, .full);
    try std.testing.expect(std.mem.find(u8, full, "\"modules\"") != null);
    // No access level, not even .full, should expose api_key_env names.
    try std.testing.expect(std.mem.find(u8, full, "api_key_env") == null);
}

test "ck_chat access covers every shipped caller, one op at a time" {
    // Each chat_* / todo_* manifest gets exactly the op it is named for, and
    // nothing else.
    const single = [_]struct { tool: []const u8, op: []const u8 }{
        .{ .tool = "chat_send", .op = "send" },
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

    // board.wasm is registered under eleven manifest names and needs two ops:
    // "send" replicates a card into the room, "history" folds that log back on
    // read. Granting one op per tool broke replication silently, because the
    // board ignores a failed chat call, so this is pinned per name, not just
    // for the bare "board".
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
    try std.testing.expect(chatAccessAllowed("cmd_janitor", "send"));
    try std.testing.expect(!chatAccessAllowed("cmd_janitor", "history"));

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
                _ = appendLocked(self.io, self.dir, "log.txt", line);
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

    // "." is how a tool asks for the whole tree, and still cannot escape it.
    const everything = [_][]const u8{"."};
    sb.fs_prefixes = &everything;
    const anywhere = try safeJoin(&sb, "src/main.zig");
    std.testing.allocator.free(anywhere);
    try std.testing.expectError(error.PathOutsideSandbox, safeJoin(&sb, "../outside"));
}

test "fsWriteIfImpl writes when hash matches and rejects on mismatch" {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Use "." prefix so safeJoin allows any relative path under root_dir.
    var sb = Sandbox{
        .gpa = gpa,
        .io = io,
        .root_dir = ".",
        .network_allow = &.{},
        .fs_prefixes = &.{"."},
        .environ_map = undefined,
    };

    // 1) Empty expected hash creates a missing file.
    const rc1 = fsWriteIfImpl(&sb, tmp.dir, "cas_test.txt", "", "hello world");
    try std.testing.expectEqual(Err.ok, rc1);
    const after1 = try tmp.dir.readFileAlloc(io, "cas_test.txt", gpa, .limited(1 << 20));
    defer gpa.free(after1);
    try std.testing.expectEqualStrings("hello world", after1);

    // 2) Correct hash writes.
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("hello world");
    const digest = hasher.finalResult();
    const hex = std.fmt.bytesToHex(digest, .lower);
    const rc2 = fsWriteIfImpl(&sb, tmp.dir, "cas_test.txt", &hex, "updated");
    try std.testing.expectEqual(Err.ok, rc2);
    const after2 = try tmp.dir.readFileAlloc(io, "cas_test.txt", gpa, .limited(1 << 20));
    defer gpa.free(after2);
    try std.testing.expectEqualStrings("updated", after2);

    // 3) Stale hash writes nothing and returns mismatch.
    const rc3 = fsWriteIfImpl(&sb, tmp.dir, "cas_test.txt", &hex, "should not land");
    try std.testing.expectEqual(Err.mismatch, rc3);
    const after3 = try tmp.dir.readFileAlloc(io, "cas_test.txt", gpa, .limited(1 << 20));
    defer gpa.free(after3);
    try std.testing.expectEqualStrings("updated", after3);
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
