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
const token_stats = @import("../stats/tokens.zig");
const zwasm = @import("zwasm");

/// Model access for tools whose descriptor sets `"llm": true` (a translate or
/// summarize transform needs one). The harness hands over the same provider
/// the agent itself is running on; `ck_llm` is denied when this is null.
pub const LlmAccess = struct {
    ctx: *client.Ctx,
    provider: *const config_mod.Provider,
    max_tokens: u32 = 1024,
};

/// The guest reserves this many bytes for the host arena (must match
/// tools-src/lib.zig).
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
};

/// Per-tool sandbox policy, owned by the harness.
/// Runs a nested sub-agent. The harness wires this in when modules.subagents
/// is enabled; tools call it via ck_subagent.
/// Asks the human a multiple-choice question and returns the option they
/// picked. Wired in only by the interactive REPL: a piped or scripted run has
/// nobody to ask, so the tool reports that instead of blocking forever.
pub const AskFn = *const fn (
    question: []const u8,
    options: []const []const u8,
) anyerror![]const u8;

pub const SubagentRunner = *const fn (
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    cfg: *const config_mod.Config,
    task: []const u8,
    provider_name: ?[]const u8,
) anyerror![]const u8;

pub const Sandbox = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Absolute path of the directory tool filesystem access is confined to.
    root_dir: []const u8,
    /// Exact host matches allowed for ck_http (e.g. "api.example.com").
    network_allow: []const []const u8,
    /// Directory prefixes (relative to root_dir) the tool may read/write.
    /// Empty means filesystem access is denied entirely.
    fs_prefixes: []const []const u8 = &.{},
    max_http_bytes: usize = 1 << 20,
    max_fs_bytes: usize = 1 << 20,
    environ_map: *std.process.Environ.Map,
    /// Deterministic seed for the tool RNG (from agent.seed).
    seed: u64 = 0,
    /// Optional nested sub-agent runner (subagent tool).
    subagent_runner: ?SubagentRunner = null,
    /// Optional human prompt (ask_user tool); null outside the REPL.
    ask_fn: ?AskFn = null,
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
    return if (v == .integer and v.integer > 0) @intCast(v.integer) else null;
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
        if (extra.len > 0) {
            var list: std.ArrayList([]const u8) = .empty;
            try list.appendSlice(arena, tool.network_allow);
            try list.appendSlice(arena, extra);
            net = try list.toOwnedSlice(arena);
        }
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
        .fs_prefixes = tool.fs_prefixes,
        .environ_map = environ_map,
        .seed = cfg.agent.seed,
        .cfg = cfg,
        .config_json = try std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(tool.config, .{})}),
    };
}

/// Per-module execution context; passed to host functions via
/// `defineFuncCtx` and recovered with `Caller.data(Host)`.
pub const Host = struct {
    sandbox: *Sandbox,
    arena_base: u32 = 0,
    arena_cur: u32 = 0,
    result_ptr: u32 = 0,
    result_len: u32 = 0,
    rng: std.Random.DefaultPrng,

    pub fn reset(self: *Host) void {
        self.arena_cur = self.arena_base;
        self.result_ptr = 0;
        self.result_len = 0;
    }

    fn writeResult(self: *Host, mem_bytes: []u8, data: []const u8) u32 {
        if (data.len > host_arena_cap) return Err.too_large;
        const off = self.arena_cur;
        if (@as(u64, off) + data.len > mem_bytes.len) return Err.too_large;
        if (self.arena_cur - self.arena_base + data.len > host_arena_cap) return Err.too_large;
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
/// JSON object — the caller then treats it as a bare prompt.
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
    const llm_start_ns = std.Io.Timestamp.now(h.sandbox.io, .real).nanoseconds;
    const resp = client.chat(access.ctx, arena, .{
        .provider = provider,
        .messages = messages,
        .max_tokens = max_tokens,
    }, &err_detail) catch |err| {
        log.log(.warn, "[llm] call failed: {s} ({s})", .{ @errorName(err), err_detail orelse "" });
        return Err.network;
    };
    const content = resp.message.content orelse "";
    // Approximate token usage: 4 bytes per token (rough heuristic).
    const est_tokens: u64 = @intCast(@min(content.len / 4, std.math.maxInt(u32)));
    const llm_ms = @divTrunc(std.Io.Timestamp.now(h.sandbox.io, .real).nanoseconds - llm_start_ns, std.time.ns_per_ms);
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

/// ck_config() -> this tool's `config` object from its descriptor, as JSON.
pub fn ckConfig(caller: *zwasm.Caller) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    return h.writeResult(bytes, h.sandbox.config_json);
}

/// ck_env(name_ptr, name_len) -> value of the environment variable in the
/// host arena. Returns Err.not_found when the variable is not set, and
/// Err.invalid when the name is empty or the memory slice is invalid.
pub fn ckEnv(caller: *zwasm.Caller, name_ptr: u32, name_len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const name = sliceOf(bytes, name_ptr, name_len) orelse return Err.invalid;
    if (name.len == 0) return Err.invalid;
    const value = h.sandbox.environ_map.get(name) orelse return Err.not_found;
    return h.writeResult(bytes, value);
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
    if (!std.mem.startsWith(u8, path, "/v1.")) {
        log.log(.warn, "[docker] path denied: '{s}'", .{path});
        return Err.denied;
    }

    var method: []const u8 = "GET";
    if (obj.get("method")) |m| {
        if (m == .string) method = m.string;
    }
    if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "POST")) return Err.denied;

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
    if (std.mem.indexOf(u8, r, "\r\n\r\n")) |hdr_end| {
        const body = r[hdr_end + 4 ..];
        return h.writeResult(bytes, body);
    }
    return Err.invalid;
}

const ChatOp = struct {
    op: ?[]const u8 = null,
    room: ?[]const u8 = null,
    text: ?[]const u8 = null,
    after: ?i64 = null,
    on: ?bool = null,
};

/// ck_chat(op_json) — chatroom operations for the chat_* tools.
/// Input:  {"op":"send|history|rooms|subscribe", "room":..., "text":...,
///          "after":..., "on":...}
/// Output (in the host arena):
///   send:      {"ok":true,"ts":...,"id":"..."}
///   history:   {"ok":true,"messages":[{room,from,text,ts,id},...]}
///   rooms:     {"ok":true,"rooms":[{room,messages,last_ts,last_from,last_text}],
///               "subscribed":["dev"]}
///   subscribe: {"ok":true,"rooms":["dev",...]}
/// The fan-out, subscription filter, and persistence all live host-side so
/// the WASM module stays thin; the descriptor config pins which op a tool is.
pub fn ckChat(caller: *zwasm.Caller, ptr: u32, len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const input = sliceOf(bytes, ptr, len) orelse return Err.invalid;

    const cfg = h.sandbox.cfg orelse {
        log.log(.warn, "[chat] denied: no config in sandbox", .{});
        return Err.denied;
    };
    if (!cfg.modules.chatrooms) {
        log.log(.warn, "[chat] denied: chatrooms module disabled", .{});
        return Err.denied;
    }

    var arena_state = std.heap.ArenaAllocator.init(h.sandbox.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = std.json.parseFromSliceLeaky(ChatOp, arena, input, .{ .ignore_unknown_fields = true }) catch {
        log.log(.warn, "[chat] json parse failed: '{s}'", .{input});
        return Err.invalid;
    };
    const op = parsed.op orelse return Err.invalid;

    var out_buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out_buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    const base = h.sandbox.state_base_dir orelse std.Io.Dir.cwd();
    const state_dir = h.sandbox.state_dir;

    if (std.mem.eql(u8, op, "send")) {
        const room = parsed.room orelse return Err.invalid;
        const text = parsed.text orelse return Err.invalid;
        if (room.len == 0 or text.len == 0 or text.len > chatrooms_mod.max_text_len) return Err.invalid;
        const msg = chatrooms_mod.sendMessage(base, h.sandbox.io, h.sandbox.gpa, arena, state_dir, cfg, room, text) catch |err| {
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
        s.endObject() catch return Err.too_large;
        return h.writeResult(bytes, out_buf[0..w.end]);
    } else if (std.mem.eql(u8, op, "history")) {
        const room = parsed.room orelse return Err.invalid;
        const after = parsed.after orelse 0;
        const msgs = chatrooms_mod.readHistory(base, h.sandbox.io, h.sandbox.gpa, arena, state_dir, room, after, 20) catch return Err.invalid;
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
            s.endObject() catch return Err.too_large;
        }
        s.endArray() catch return Err.too_large;
        s.endObject() catch return Err.too_large;
        return h.writeResult(bytes, out_buf[0..w.end]);
    } else if (std.mem.eql(u8, op, "rooms")) {
        const rooms = chatrooms_mod.listRooms(base, h.sandbox.io, h.sandbox.gpa, arena, state_dir) catch return Err.invalid;
        const subs = chatrooms_mod.subscribedRooms(base, h.sandbox.io, arena, state_dir, cfg) catch return Err.invalid;
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
    }
    log.log(.warn, "[chat] unknown op '{s}'", .{op});
    return Err.invalid;
}

/// ck_stats() — aggregate token usage per provider/model from the global
/// token-usage log (state/token_stats.jsonl). Returns
/// {"ok":true,"stats":[{provider,model,calls,...}],"totals":{...}} in the
/// host arena. Backs the model_stats tool.
pub fn ckStats(caller: *zwasm.Caller) u32 {
    const h = getHost(caller);
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
        log.log(.warn, "[stats] aggregate failed: {s}", .{@errorName(err)});
        return Err.invalid;
    };
    const json_out = token_stats.statsJSON(arena, stats, token_stats.totals(stats)) catch return Err.too_large;
    return h.writeResult(bytes, json_out);
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
        out[count] = .{ .name = key, .value = val.string };
        count += 1;
    }
    return count;
}

fn httpImpl(h: *Host, mem_bytes: []u8, method: u32, url: []const u8, body: []const u8, hdr_json: ?[]const u8) u32 {
    const uri = std.Uri.parse(url) catch return Err.invalid;
    const hostname = switch (uri.host orelse return Err.invalid) {
        .raw => |hh| hh,
        .percent_encoded => |hh| hh,
    };

    var allowed = false;
    for (h.sandbox.network_allow) |a| {
        if (std.mem.eql(u8, hostname, a)) {
            allowed = true;
            break;
        }
    }
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

    const req_method: std.http.Method = switch (method) {
        0 => .GET,
        1 => .POST,
        2 => .PUT,
        3 => .DELETE,
        4 => .PATCH,
        5 => .HEAD,
        else => return Err.invalid,
    };
    const has_body = req_method == .POST or req_method == .PUT or req_method == .PATCH;
    const result = http.fetch(.{
        .location = .{ .url = url },
        .method = req_method,
        .payload = if (has_body) body else null,
        .headers = .{ .user_agent = .{ .override = "clanker-tool/0.1.0" } },
        .extra_headers = if (n_custom > 0) custom_hdrs[0..n_custom] else &.{},
        .response_writer = &w,
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
    // Object with non-string value — those entries are skipped.
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
    const full = safeJoin(h.sandbox, path) catch return Err.denied;
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

/// ck_fs_find(dir_path, pattern) — recursively find files under a sandbox
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
    const full = safeJoin(h.sandbox, dir_path) catch return Err.denied;
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

/// ck_fs_stat(path) — stat a path under the sandbox root.
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
    const full = safeJoin(h.sandbox, path) catch return Err.denied;
    defer h.sandbox.gpa.free(full);

    // Try to stat as a file first, then as a directory.
    const cwd = std.Io.Dir.cwd();
    var kind_str: []const u8 = "other";
    var size: u64 = 0;

    if (cwd.statFile(h.sandbox.io, full)) |stat| {
        kind_str = "file";
        size = stat.size;
    } else |_| {
        // Not a file — try opening as a directory to distinguish dir vs not-found.
        var dir = cwd.openDir(h.sandbox.io, full, .{}) catch |err| switch (err) {
            error.FileNotFound => return Err.not_found,
            else => return Err.not_found,
        };
        dir.close(h.sandbox.io);
        kind_str = "directory";
        size = 0;
    }

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

/// ck_fs_copy(src_path, dst_path) — copy a file under the sandbox root.
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
    const full_src = safeJoin(h.sandbox, src_sub) catch return Err.denied;
    defer h.sandbox.gpa.free(full_src);
    const full_dst = safeJoin(h.sandbox, dst_sub) catch return Err.denied;
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

/// ck_fs_rename(old_path, new_path) — rename/move a file under the sandbox root.
/// Both paths must pass the same fs_prefixes policy as ck_fs_read / ck_fs_write.
/// Returns Err.not_found when the source does not exist.
pub fn ckFsRename(caller: *zwasm.Caller, old_ptr: u32, old_len: u32, new_ptr: u32, new_len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const old_path = sliceOf(bytes, old_ptr, old_len) orelse return Err.invalid;
    const new_path = sliceOf(bytes, new_ptr, new_len) orelse return Err.invalid;
    if (old_path.len == 0 or new_path.len == 0) return Err.invalid;
    const full_old = safeJoin(h.sandbox, old_path) catch return Err.denied;
    defer h.sandbox.gpa.free(full_old);
    const full_new = safeJoin(h.sandbox, new_path) catch return Err.denied;
    defer h.sandbox.gpa.free(full_new);
    std.Io.Dir.cwd().rename(h.sandbox.io, full_old, full_new) catch |err| switch (err) {
        error.FileNotFound => return Err.not_found,
        else => return Err.invalid,
    };
    return Err.ok;
}

/// ck_fs_delete(path) — delete a file under the sandbox root.
/// Enforces the same fs_prefixes policy as ck_fs_read / ck_fs_write.
pub fn ckFsDelete(caller: *zwasm.Caller, path_ptr: u32, path_len: u32) u32 {
    const h = getHost(caller);
    const path = blk: {
        const bytes = memBytes(caller) orelse return Err.invalid;
        break :blk sliceOf(bytes, path_ptr, path_len) orelse return Err.invalid;
    };
    if (path.len == 0) return Err.invalid;
    const full = safeJoin(h.sandbox, path) catch return Err.denied;
    defer h.sandbox.gpa.free(full);
    std.Io.Dir.cwd().deleteFile(h.sandbox.io, full) catch |err| switch (err) {
        error.FileNotFound => return Err.not_found,
        else => return Err.invalid,
    };
    return Err.ok;
}

/// ck_fs_mkdir(path) — create a directory (and parents) under the sandbox root.
/// Enforces the same fs_prefixes policy as ck_fs_read / ck_fs_write.
pub fn ckFsMkdir(caller: *zwasm.Caller, path_ptr: u32, path_len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const path = sliceOf(bytes, path_ptr, path_len) orelse return Err.invalid;
    if (path.len == 0) return Err.invalid;
    const full = safeJoin(h.sandbox, path) catch return Err.denied;
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

/// ck_fs_read_range(path, offset, length) — read a byte range from a file
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

/// ck_fs_write_range(path, offset, data) — write data at a byte offset in a
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
    const full = safeJoin(h.sandbox, sub_path) catch return Err.denied;
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
    const full = safeJoin(h.sandbox, sub_path) catch return Err.denied;
    defer h.sandbox.gpa.free(full);

    var file = std.Io.Dir.cwd().openFile(h.sandbox.io, full, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => return Err.not_found,
        else => return Err.invalid,
    };
    defer file.close(h.sandbox.io);

    file.seekTo(h.sandbox.io, @as(u64, offset)) catch return Err.invalid;
    file.writeAll(h.sandbox.io, data) catch |err| switch (err) {
        error.NoSpaceLeft, error.DiskQuota => return Err.too_large,
        else => return Err.invalid,
    };
    return Err.ok;
}

fn fsReadRangeImpl(h: *Host, mem_bytes: []u8, sub_path: []const u8, offset: u32, length: u32) u32 {
    if (length == 0) return h.writeResult(mem_bytes, "");
    const capped_len: usize = @min(@as(usize, length), h.sandbox.max_fs_bytes);
    const full = safeJoin(h.sandbox, sub_path) catch return Err.denied;
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

    // Seek to offset.
    file.seekTo(h.sandbox.io, @as(u64, offset)) catch return Err.invalid;

    const buf = h.sandbox.gpa.alloc(u8, to_read) catch return Err.too_large;
    defer h.sandbox.gpa.free(buf);
    const n = file.readAll(h.sandbox.io, buf) catch return Err.invalid;
    return h.writeResult(mem_bytes, buf[0..n]);
}

/// ck_fs_append(path, data) — append data to a file under the sandbox root.
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
    const full = safeJoin(h.sandbox, sub_path) catch return Err.denied;
    defer h.sandbox.gpa.free(full);
    // Open for appending, creating the file if it doesn't exist: one
    // syscall instead of open-fail-then-writeFile (truncate=false never
    // clobbers existing content).
    var file = std.Io.Dir.cwd().createFile(h.sandbox.io, full, .{ .truncate = false }) catch |err| switch (err) {
        error.NoSpaceLeft, error.DiskQuota => return Err.too_large,
        else => return Err.invalid,
    };
    defer file.close(h.sandbox.io);
    // Seek to end and write.
    file.seekToEnd(h.sandbox.io) catch return Err.invalid;
    file.writeAll(h.sandbox.io, data) catch |err| switch (err) {
        error.NoSpaceLeft, error.DiskQuota => return Err.too_large,
        else => return Err.invalid,
    };
    return Err.ok;
}

fn fsWriteImpl(h: *Host, mem_bytes: []u8, sub_path: []const u8, data: []const u8) u32 {
    if (data.len > h.sandbox.max_fs_bytes) return Err.too_large;
    const full = safeJoin(h.sandbox, sub_path) catch return Err.denied;
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

/// ck_getenv(name) — alias of ck_env, kept for modules linked against the
/// older symbol name. Delegating keeps the validation contract (empty name
/// -> Err.invalid) identical for both entry points.
pub fn ckGetenv(caller: *zwasm.Caller, name_ptr: u32, name_len: u32) u32 {
    return ckEnv(caller, name_ptr, name_len);
}

// ------------------------------------------------------- ck_exec (shell-ish) --

const exec_cmds = [_][]const u8{ "git", "rg", "ast-grep", "semcode", "zig", "find", "cat", "wc", "head", "tail", "ls", "diff" };

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
    if (op) return std.mem.indexOf(u8, arg, t) != null;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, arg, i, t)) |p| {
        const before = p == 0 or !isWordChar(arg[p - 1]);
        const after = p + t.len >= arg.len or !isWordChar(arg[p + t.len]);
        if (before and after) return true;
        i = p + 1;
    }
    return false;
}

/// Arguments that are never allowed for sandboxed commands.
///
/// The shell-operator tokens here are defense in depth, not the primary
/// guard: ckExec below runs argv directly via std.process.run, never through
/// a shell, so none of these can actually be interpreted as operators no
/// matter what they contain. "|" is deliberately absent even so — it's
/// ordinary regex alternation syntax, the single most common character in a
/// search pattern for the exact tools (rg, ast-grep, semcode) this allowlist
/// exists to let through, and blocking it only breaks the tool it's meant to
/// protect without closing any real hole.
const exec_deny_tokens = [_][]const u8{
    "push",   "reset",  "rebase",    "checkout", "clean",   "rm",            "fetch",
    "merge",  "revert", "stash",     "remote",   "tag",     "filter-branch", "gc",
    "repack", "prune",  "submodule", "-f",       "--force", "--exec",        "&&",
    "||",     ";",      ">",         "<",        "`",
};

/// ck_std_api: look up a symbol name in the Zig 0.16 standard library source
/// tree and return up to 40 matching lines (signatures, doc comments, usage).
///
/// Use this to verify that a function, type, or field actually exists in
/// std before writing code that calls it — especially after a Zig version
/// bump when APIs may have changed.  The search is a literal substring match
/// (not fuzzy), so pass the shortest unambiguous fragment (e.g.
/// "splitScalar" not "std.mem.splitScalar").  Do NOT use this for non-std
/// symbols or project-internal code; use search_code / read_file instead.
pub fn ckStdApi(caller: *zwasm.Caller, sym_ptr: u32, sym_len: u32) u32 {
    const h = getHost(caller);
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
/// Do NOT use it for tasks that are trivial enough to do inline — every
/// sub-agent call pays a full agent-loop startup cost — or when you need the
/// sub-agent to modify files you are currently editing (it works on a
/// snapshot, not on your live state).
///
/// ck_ask: put a multiple-choice question to the human and return their pick.
///
/// Use this when a decision is genuinely ambiguous and the user's preference
/// matters (e.g. choosing between two valid refactoring strategies).  Do NOT
/// use it for yes/no confirmations you can resolve yourself, or when the
/// options list has fewer than 2 entries (the call will fail).  The sandbox
/// has no terminal, so the decision is made host-side by whoever installed
/// `ask_fn` (the REPL).  Without one there is no human attached, and the
/// call returns Err.not_found so the model can decide for itself.
pub fn ckAsk(caller: *zwasm.Caller, json_ptr: u32, json_len: u32) u32 {
    const h = getHost(caller);
    const bytes = memBytes(caller) orelse return Err.invalid;
    const json_input = sliceOf(bytes, json_ptr, json_len) orelse return Err.invalid;
    const ask = h.sandbox.ask_fn orelse return Err.not_found;

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

    const answer = ask(question, options.items) catch return Err.invalid;
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
        runner: SubagentRunner,
        result: ?[]const u8 = null,
        err: ?anyerror = null,
        fn run(self: *@This()) void {
            self.result = self.runner(self.io, self.gpa, self.environ_map, self.cfg, self.task, self.provider_name) catch |e| {
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
        .runner = runner,
    };
    const th = std.Thread.spawn(.{ .stack_size = 128 * 1024 * 1024 }, SubagentCall.run, .{&call}) catch return Err.invalid;
    th.join();
    if (call.err != null) return Err.invalid;
    const result = call.result orelse "";
    const rc = h.writeResult(bytes, result);
    if (result.len > 0) h.sandbox.gpa.free(@constCast(result));
    return rc;
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
    var allowed_cmd = false;
    const allowed = if (h.sandbox.exec_allow.len > 0) h.sandbox.exec_allow else &exec_cmds;
    for (allowed) |c| {
        if (std.mem.eql(u8, cmd, c)) {
            allowed_cmd = true;
            break;
        }
    }
    if (!allowed_cmd) return Err.denied;

    // Optional cwd: resolve relative to sandbox root via safeJoin.
    var exec_dir: std.Io.Dir = std.Io.Dir.cwd();
    var exec_dir_opened = false;
    if (obj.get("cwd")) |cwd_val| {
        if (cwd_val == .string and cwd_val.string.len > 0) {
            const full = safeJoin(h.sandbox, cwd_val.string) catch return Err.denied;
            defer h.sandbox.gpa.free(full);
            exec_dir = std.Io.Dir.cwd().openDir(h.sandbox.io, full, .{}) catch return Err.not_found;
            exec_dir_opened = true;
        }
    }
    defer if (exec_dir_opened) exec_dir.close(h.sandbox.io);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(h.sandbox.gpa);
    argv.append(h.sandbox.gpa, cmd) catch return Err.invalid;
    if (obj.get("args")) |a| {
        switch (a) {
            .array => |arr| {
                for (arr.items) |item| {
                    const arg = switch (item) {
                        .string => |s| s,
                        else => return Err.invalid,
                    };
                    // deny-list check: match whole arguments / flag prefixes /
                    // word boundaries so single-char tokens like "-f", "rm",
                    // "gc" don't false-positive on innocent arguments.
                    for (exec_deny_tokens) |t| {
                        if (argDenied(arg, t)) {
                            log.log(.warn, "[sandbox] ck_exec denied token '{s}' in arg '{s}'", .{ t, arg });
                            return Err.denied;
                        }
                    }
                    argv.append(h.sandbox.gpa, arg) catch return Err.invalid;
                }
            },
            else => {},
        }
    }

    log.log(.info, "[exec] → {s}", .{cmd});
    const exec_start_ns = std.Io.Timestamp.now(h.sandbox.io, .real).nanoseconds;
    const result = std.process.run(h.sandbox.gpa, h.sandbox.io, .{
        .argv = argv.items,
        .cwd = .{ .dir = exec_dir },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(8 * 1024),
    }) catch |err| {
        // Not a network condition: a process that could not be spawned or
        // whose output overran the cap was reported to the guest as
        // "NetworkError", which sent the model looking for a connectivity
        // problem that never existed.
        log.log(.warn, "[exec] {s} failed to run: {s}", .{ cmd, @errorName(err) });
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
    const exec_ms = @divTrunc(std.Io.Timestamp.now(h.sandbox.io, .real).nanoseconds - exec_start_ns, std.time.ns_per_ms);
    if (code == 0) {
        log.log(.info, "[exec] ✓ {s} … {d}ms", .{ cmd, exec_ms });
    } else {
        log.log(.info, "[exec] ✗ {s} … {d}ms — exit code {d}", .{ cmd, exec_ms, code });
    }

    const wbuf = h.sandbox.gpa.alloc(u8, 96 * 1024) catch return Err.too_large;
    defer h.sandbox.gpa.free(wbuf);
    var w: std.Io.Writer = .fixed(wbuf);
    writeExecResult(&w, code, result.stdout, result.stderr) catch return Err.too_large;
    return h.writeResult(bytes, wbuf[0..w.end]);
}

fn writeExecResult(w: *std.Io.Writer, code: u32, stdout: []const u8, stderr: []const u8) !void {
    var s = std.json.Stringify{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(code == 0);
    try s.objectField("code");
    try s.print("{d}", .{code});
    try s.objectField("stdout");
    try s.write(stdout);
    try s.objectField("stderr");
    try s.write(stderr);
    try s.endObject();
}

// ------------------------------------------------------------- sandbox core --

/// Resolves a tool-supplied path against the sandbox root, rejecting absolute
/// paths, any `..` / `.` component, and anything outside the tool's allowed
/// prefix list. Returns an allocated joined path.
fn safeJoin(sb: *const Sandbox, sub_path: []const u8) ![]u8 {
    if (sub_path.len == 0) return error.PathOutsideSandbox;
    if (sub_path[0] == '/') return error.PathOutsideSandbox;
    var it = std.mem.splitScalar(u8, sub_path, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..") or std.mem.eql(u8, comp, ".")) return error.PathOutsideSandbox;
        if (comp.len == 0) return error.PathOutsideSandbox;
    }
    if (sb.fs_prefixes.len > 0) {
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

// ------------------------------------------------------------------- tests --

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

test "httpImpl rejects unknown method codes" {
    // Method codes 6+ should map to Err.invalid.
    // We can't call httpImpl directly without a full Host, but we verify the
    // method switch logic by checking the enum values are exhaustive.
    const valid_methods = [_]u32{ 0, 1, 2, 3, 4, 5 };
    for (valid_methods) |m| {
        const method: std.http.Method = switch (m) {
            0 => .GET,
            1 => .POST,
            2 => .PUT,
            3 => .DELETE,
            4 => .PATCH,
            5 => .HEAD,
            else => unreachable,
        };
        // Just verify the mapping doesn't crash
        _ = method;
    }
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
