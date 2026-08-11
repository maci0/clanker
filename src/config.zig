//! Configuration loading: `config.json` (committed example) merged with
//! `config.local.json` (gitignored, user-specific). API keys are never stored
//! here — providers reference an environment variable by name instead.

const std = @import("std");
const json = std.json;
const log = @import("util/log.zig");

pub const ProviderKind = enum {
    openai_compat,
    anthropic,
    /// Anthropic models served through Google Vertex AI: same message format,
    /// but the model lives in the URL and auth is a GCP bearer token.
    vertex_anthropic,

    pub fn fromStr(s: []const u8) ?ProviderKind {
        if (std.mem.eql(u8, s, "openai_compat")) return .openai_compat;
        if (std.mem.eql(u8, s, "anthropic")) return .anthropic;
        if (std.mem.eql(u8, s, "vertex_anthropic")) return .vertex_anthropic;
        return null;
    }
};

pub const Model = struct {
    /// Total model context window in tokens (input + output). Used to size
    /// conversation compaction and the improve context budget.
    context_window: u32 = 131072,
    /// Per-request max output tokens (completion cap).
    max_tokens: u32 = 1024,
    temperature: ?f64 = null,
    /// Nucleus sampling cutoff. Left null by default and generally best set
    /// *instead of* temperature rather than alongside it: both narrow the same
    /// distribution, and Anthropic's API documents adjusting only one.
    top_p: ?f64 = null,
    /// Keeps reasoning models' chain-of-thought short so `content` stays
    /// populated (e.g. DeepSeek v4: "low" | "medium").
    reasoning_effort: ?[]const u8 = null,
    /// What to call this model in the UI, when the wire id is not what a
    /// person calls it. `kimi-k3` on api.moonshot.ai is sent bare because that
    /// is what the vendor's own API accepts, but it is read as
    /// `moonshotai/kimi-k3`, the way an OpenRouter-routed model is written.
    /// Display only: never sent.
    display: ?[]const u8 = null,
    /// Estimated USD per 1M input tokens (for run cost accounting).
    cost_per_1m_input: ?f64 = null,
    /// Estimated USD per 1M output tokens (for run cost accounting).
    cost_per_1m_output: ?f64 = null,
};

pub const Provider = struct {
    name: []const u8,
    kind: ProviderKind = .openai_compat,
    base_url: []const u8,
    api_key_env: ?[]const u8 = null,
    /// vertex_anthropic only: the GCP project and region that serve the model,
    /// and the service account JSON used to mint access tokens.
    project: []const u8 = "",
    location: []const u8 = "",
    service_account_file: []const u8 = "",
    /// Per-model settings keyed by model name. When non-empty, `default_model`
    /// selects the active model; the legacy flat fields below are ignored.
    models: std.StringArrayHashMapUnmanaged(Model) = .empty,
    /// Default model name within `models` (or the legacy `model` name).
    default_model: []const u8 = "",

    /// Endpoint path override; defaults per kind (`/chat/completions`,
    /// `/v1/messages`).
    path: ?[]const u8 = null,

    /// Name of the active model (sent as the API `model` field).
    /// Builds a provider with one model. JSON loading normalizes into exactly
    /// this shape, so programmatic callers (tests, ad-hoc providers) do not
    /// have to assemble the map by hand.
    pub fn single(
        arena: std.mem.Allocator,
        name: []const u8,
        base_url: []const u8,
        kind: ProviderKind,
        model_name: []const u8,
        settings: Model,
    ) !Provider {
        var p = Provider{ .name = name, .base_url = base_url, .kind = kind, .default_model = model_name };
        try p.models.put(arena, model_name, settings);
        return p;
    }

    /// The active model's name. Loading guarantees `default_model` is set and
    /// present in `models`, so there is exactly one place this can come from.
    pub fn activeModelName(self: *const Provider) []const u8 {
        return self.default_model;
    }

    /// The active model's settings.
    pub fn activeModel(self: *const Provider) Model {
        return self.models.get(self.default_model) orelse .{};
    }
};

pub const Agent = struct {
    /// A review or audit task spends most of its turns reading before it can
    /// answer anything. At 12 those runs ended at the ceiling with no answer
    /// and the whole run wasted, which costs more than the extra turns would
    /// have.
    max_iterations: u32 = 24,
    compact_threshold_bytes: usize = 24000,
    max_total_tokens: ?u32 = null,
    /// Per-turn cap on input tokens; conversation is compacted before a turn
    /// whose content would exceed it.
    max_tokens_per_turn: u32 = 4096,
    /// Total history token budget; when accumulated conversation history goes
    /// beyond this, older messages are compacted away.
    max_history_tokens: u32 = 16000,
    /// Send full schemas only for the tools this clanker actually uses,
    /// and let the model ask for the rest by name. With forty-odd tools the
    /// schemas are several thousand tokens in every single request, and most
    /// of them are not wanted on most turns.
    tool_catalog: bool = true,
    /// How many of the most-used tools keep their schemas loaded without
    /// being asked for. Measured, not configured: see tools/usage.zig.
    hot_tools: u32 = 10,
    tools_dir: []const u8 = "tools",
    skills_dir: []const u8 = "skills",
    system_prompt_file: []const u8 = "skills/SYSTEM.md",
    learnings_file: []const u8 = "state/learnings.md",
    /// Directory (relative to the process cwd) holding harness state:
    /// chatroom logs, run records, cursors.
    state_dir: []const u8 = "state",
    sandbox_root: []const u8 = ".",
    /// Commit promoted improvements with git (git_commit_after_improve).
    git_commit: bool = true,
    seed: u64 = 0,
};

pub const Improve = struct {
    min_delta: f64 = 0.05,
    default_iters: u32 = 3,
    /// null (or 0 in the file) means the engine sizes the context from the
    /// model's own window. A fixed number here overrides that, and a stale one
    /// silently keeps a 1M-window model on a 64 KiB diet.
    max_context_bytes: ?usize = null,
    /// Run the staged tree's task evals before promoting. They cost one agent
    /// run each, which is the price of noticing a patch that compiles, passes
    /// every unit test, and breaks a tool an agent depends on.
    capability_gate: bool = true,
    /// Ceiling on the local zig build cache, checked before each attempt.
    /// The cache only ever grows (zig never prunes it) and each gate run adds
    /// to it; unbounded, it reached 72 GB here and filled the disk, which
    /// stops self-improvement completely. Dropping it costs about a second,
    /// because the artifacts themselves live in zig's global cache. 0 disables.
    max_cache_bytes: u64 = 4 << 30,
    max_staged_bytes: usize = 256 * 1024,
    max_tool_source_bytes: usize = 64 * 1024,
    max_skill_bytes: usize = 32 * 1024,
    max_proposal_bytes: usize = 512 * 1024,
};

/// A peer clanker instance that may be notified about events.
pub const Peer = struct {
    name: []const u8,
    url: []const u8,
};

/// Identity of this clanker instance.
pub const Instance = struct {
    name: []const u8 = "",
    id: []const u8 = "",
};

/// Peer notification settings.
pub const Notify = struct {
    on: bool = true,
    topic: []const u8 = "clanker",
};

/// Clanker chatrooms: named group channels that peer clankers subscribe to
/// and exchange messages over. Messages are fanned out to every configured
/// peer via POST /api/chat/message; each peer keeps its own log of the rooms
/// it subscribes to (state/chatrooms.jsonl).
pub const Chatrooms = struct {
    on: bool = true,
    /// Rooms this instance subscribes to by default. `chat_subscribe` may
    /// add/remove rooms at runtime (state/chatrooms-sub.json).
    rooms: []const []const u8 = &.{},
    /// How many messages the log is trimmed to on write.
    max_history: u32 = 500,
};

pub const Modules = struct {
    mcp: bool = true,
    peers: bool = true,
    a2a: bool = true,
    webui: bool = true,
    graphs: bool = true,
    sessions: bool = true,
    goal: bool = true,
    token_budget: bool = true,
    streaming: bool = true,
    dotenv: bool = true,
    /// REPL self-restart when the binary is rebuilt.
    hot_reload: bool = true,
    /// Record usage patterns / missing tools and feed them into the roadmap.
    autolearn: bool = true,
    /// Allow the agent to delegate tasks to nested sub-agent runs.
    subagents: bool = true,
    /// Persist reasoning traces and expose them to the agent (Reasoning &
    /// Learning module).
    rlm: bool = true,
    /// Multimodal: attach images to messages (image tool + image_url blocks).
    multimodal: bool = true,
    /// Chatrooms: group channels between peer clankers (chat_* tools, the
    /// /api/chat/* endpoints, and inbox injection on run).
    chatrooms: bool = true,
    /// Global token usage stats: every chat completion is recorded to
    /// state/token_stats.jsonl and aggregated per provider/model
    /// (model_stats tool, `clanker stats`, GET /api/stats).
    token_stats: bool = true,
};

pub const Config = struct {
    agent_present: bool = false,
    improve_present: bool = false,
    default_provider: []const u8 = "deepseek",
    providers: std.StringArrayHashMapUnmanaged(Provider) = .empty,
    agent: Agent = .{},
    improve: Improve = .{},
    peers: []const Peer = &.{},
    instance: Instance = .{},
    notify: Notify = .{},
    chatrooms: Chatrooms = .{},
    modules: Modules = .{},
    modules_present: bool = false,
    chatrooms_present: bool = false,
    instance_present: bool = false,
    default_provider_present: bool = false,

    pub fn provider(self: *const Config, name: ?[]const u8) !*const Provider {
        const want = name orelse self.default_provider;
        return self.providers.getPtr(want) orelse error.UnknownProvider;
    }

    /// Loads `config.json` plus `config.local.json` (if present) from `dir`.
    /// All returned strings are allocated in `arena`.
    pub fn load(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir, file_name: []const u8, local_file_name: []const u8) !Config {
        var cfg = (try loadFile(io, arena, dir, file_name, .required)).?;
        if (try loadFile(io, arena, dir, local_file_name, .optional)) |local| {
            try merge(&cfg, local, arena);
        }
        return cfg;
    }

    const LoadMode = enum { required, optional };

    fn loadFile(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir, file_name: []const u8, mode: LoadMode) !?Config {
        const raw = dir.readFileAlloc(io, file_name, arena, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => switch (mode) {
                .required => return error.MissingConfig,
                .optional => return null,
            },
            else => return err,
        };
        const cfg = try parseConfig(arena, raw, file_name);
        return cfg;
    }

    fn parseConfig(arena: std.mem.Allocator, raw: []const u8, file_name: []const u8) !Config {
        const root = try json.parseFromSliceLeaky(json.Value, arena, raw, .{ .ignore_unknown_fields = true });
        var cfg = Config{};
        const obj = switch (root) {
            .object => |o| o,
            else => return error.ConfigNotObject,
        };

        if (obj.get("default_provider")) |v| {
            cfg.default_provider = try jsonStr(v, "default_provider");
            cfg.default_provider_present = true;
        }
        if (obj.get("agent")) |v| {
            cfg.agent = try parseAgent(arena, v);
            cfg.agent_present = true;
        }
        if (obj.get("improve")) |v| {
            cfg.improve = try parseImprove(arena, v);
            cfg.improve_present = true;
        }
        if (obj.get("providers")) |v| {
            const pobj = switch (v) {
                .object => |o| o,
                else => return error.ProvidersNotObject,
            };
            var it = pobj.iterator();
            while (it.next()) |kv| {
                const p = try parseProvider(arena, kv.key_ptr.*, kv.value_ptr.*);
                try cfg.providers.put(arena, kv.key_ptr.*, p);
            }
        }
        if (obj.get("instance")) |v| {
            cfg.instance = try parseInstance(arena, v);
            cfg.instance_present = true;
        } else {
            // Only a fallback when nothing parsed one yet: a later local file
            // without an "instance" section must not clobber a named instance
            // with a pid-based default (merge() checks instance_present).
            if (!cfg.instance_present) cfg.instance.name = try defaultInstName(arena);
        }
        if (obj.get("peers")) |v| {
            cfg.peers = try parsePeers(arena, v);
        }
        if (obj.get("notify")) |v| {
            cfg.notify = try parseNotify(arena, v);
        }
        if (obj.get("chatrooms")) |v| {
            cfg.chatrooms = try parseChatrooms(arena, v);
            cfg.chatrooms_present = true;
        }
        if (obj.get("modules")) |v| {
            cfg.modules = try parseModules(arena, v);
            cfg.modules_present = true;
        }
        if (cfg.providers.count() == 0) {
            log.log(.warn, "config {s}: no providers defined", .{file_name});
        }
        return cfg;
    }

    fn parseProvider(arena: std.mem.Allocator, name: []const u8, v: json.Value) !Provider {
        const obj = switch (v) {
            .object => |o| o,
            else => return error.ProviderNotObject,
        };
        var p = Provider{
            .name = name,
            .base_url = try jsonStr(try required(obj, "base_url"), "base_url"),
        };
        // Settings that belong to a model are rejected on the provider: they
        // differ per model on the same endpoint, and silently accepting them
        // here is how a config ends up meaning something other than it reads.
        if (obj.get("model") != null) {
            log.log(.error_, "provider '{s}': \"model\" was replaced by \"models\". Use \"models\": {{\"<name>\": {{...}}}} and, with more than one, \"default_model\": \"<name>\"", .{name});
            return error.ProviderLegacyModelFields;
        }
        for ([_][]const u8{ "max_tokens", "context_window", "temperature", "top_p", "reasoning_effort" }) |legacy| {
            if (obj.get(legacy) != null) {
                log.log(.error_, "provider '{s}': \"{s}\" belongs to a model, not the provider. Move it into \"models\": {{\"<name>\": {{\"{s}\": ...}}}}", .{ name, legacy, legacy });
                return error.ProviderLegacyModelFields;
            }
        }
        if (obj.get("kind")) |k| {
            p.kind = ProviderKind.fromStr(try jsonStr(k, "kind")) orelse return error.UnknownProviderKind;
        }
        if (obj.get("project")) |k| {
            p.project = try jsonStr(k, "project");
        }
        if (obj.get("location")) |k| {
            p.location = try jsonStr(k, "location");
        }
        if (obj.get("service_account_file")) |k| {
            p.service_account_file = try jsonStr(k, "service_account_file");
        }
        if (obj.get("api_key_env")) |k| {
            p.api_key_env = try jsonStr(k, "api_key_env");
        }
        if (obj.get("path")) |k| {
            p.path = try jsonStr(k, "path");
        }
        if (obj.get("default_model")) |k| {
            p.default_model = try jsonStr(k, "default_model");
        }
        if (obj.get("models")) |models_v| {
            const models_obj = switch (models_v) {
                .object => |o| o,
                else => return error.ModelsNotObject,
            };
            var it = models_obj.iterator();
            while (it.next()) |kv| {
                const m = try parseModel(kv.key_ptr.*, kv.value_ptr.*);
                try p.models.put(arena, kv.key_ptr.*, m);
            }
        }

        // One shape, checked at startup: a provider names its models and picks
        // one. Both failures below would otherwise surface as a confusing error
        // on the first request instead of at load.
        if (p.models.count() == 0) {
            log.log(.error_, "provider '{s}': no \"models\" declared", .{name});
            return error.ProviderMissingModel;
        }
        if (p.default_model.len == 0) {
            // One model is unambiguous, so naming it twice is noise.
            p.default_model = p.models.keys()[0];
        }
        if (p.models.get(p.default_model) == null) {
            log.log(.error_, "provider '{s}': default_model '{s}' is not in \"models\"", .{ name, p.default_model });
            return error.ProviderDefaultModelUnknown;
        }
        return p;
    }

    fn parseModel(name: []const u8, v: json.Value) !Model {
        _ = name;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.ModelNotObject,
        };
        var m = Model{};
        if (obj.get("context_window")) |k| m.context_window = @intCast(try jsonInt(k, "context_window"));
        if (obj.get("max_tokens")) |k| m.max_tokens = @intCast(try jsonInt(k, "max_tokens"));
        if (obj.get("temperature")) |k| m.temperature = try jsonFloat(k, "temperature");
        if (obj.get("top_p")) |k| m.top_p = try jsonFloat(k, "top_p");
        if (obj.get("reasoning_effort")) |k| m.reasoning_effort = try jsonStr(k, "reasoning_effort");
        if (obj.get("display")) |k| m.display = try jsonStr(k, "display");
        if (obj.get("cost_per_1m_input")) |k| m.cost_per_1m_input = try jsonFloat(k, "cost_per_1m_input");
        if (obj.get("cost_per_1m_output")) |k| m.cost_per_1m_output = try jsonFloat(k, "cost_per_1m_output");
        return m;
    }

    fn parseInstance(arena: std.mem.Allocator, v: json.Value) !Instance {
        const obj = switch (v) {
            .object => |o| o,
            else => return error.InstanceNotObject,
        };
        var inst = Instance{};
        if (obj.get("name")) |k| {
            inst.name = try jsonStr(k, "name");
        } else {
            inst.name = try defaultInstName(arena);
        }
        if (obj.get("id")) |k| {
            inst.id = try jsonStr(k, "id");
        }
        return inst;
    }

    fn parsePeers(arena: std.mem.Allocator, v: json.Value) ![]const Peer {
        const arr = switch (v) {
            .array => |a| a,
            else => return error.PeersNotArray,
        };
        var out: std.ArrayList(Peer) = .empty;
        for (arr.items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => return error.PeerNotObject,
            };
            try out.append(arena, .{
                .name = try jsonStr(try required(obj, "name"), "name"),
                .url = try jsonStr(try required(obj, "url"), "url"),
            });
        }
        return out.toOwnedSlice(arena);
    }

    fn parseNotify(arena: std.mem.Allocator, v: json.Value) !Notify {
        _ = arena;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.NotifyNotObject,
        };
        var n = Notify{};
        if (obj.get("on")) |k| n.on = switch (k) {
            .bool => |b| b,
            else => return error.FieldNotBool,
        };
        if (obj.get("topic")) |k| n.topic = try jsonStr(k, "topic");
        return n;
    }

    fn parseChatrooms(arena: std.mem.Allocator, v: json.Value) !Chatrooms {
        const obj = switch (v) {
            .object => |o| o,
            else => return error.ChatroomsNotObject,
        };
        var c = Chatrooms{};
        if (obj.get("on")) |k| c.on = switch (k) {
            .bool => |b| b,
            else => return error.FieldNotBool,
        };
        if (obj.get("rooms")) |k| {
            const arr = switch (k) {
                .array => |a| a,
                else => return error.ChatroomsRoomsNotArray,
            };
            var rooms: std.ArrayList([]const u8) = .empty;
            for (arr.items) |item| {
                try rooms.append(arena, try jsonStr(item, "rooms[]"));
            }
            c.rooms = try rooms.toOwnedSlice(arena);
        }
        if (obj.get("max_history")) |k| c.max_history = @intCast(try jsonInt(k, "max_history"));
        return c;
    }

    fn defaultInstName(arena: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "clanker-{d}", .{std.c.getpid()});
    }

    fn parseAgent(arena: std.mem.Allocator, v: json.Value) !Agent {
        _ = arena;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.AgentNotObject,
        };
        var a = Agent{};
        if (obj.get("max_iterations")) |k| a.max_iterations = @intCast(try jsonInt(k, "max_iterations"));
        if (obj.get("compact_threshold_bytes")) |k| a.compact_threshold_bytes = @intCast(try jsonInt(k, "compact_threshold_bytes"));
        if (obj.get("max_total_tokens")) |k| a.max_total_tokens = @intCast(try jsonInt(k, "max_total_tokens"));
        if (obj.get("max_tokens_per_turn")) |k| a.max_tokens_per_turn = @intCast(try jsonInt(k, "max_tokens_per_turn"));
        if (obj.get("max_history_tokens")) |k| a.max_history_tokens = @intCast(try jsonInt(k, "max_history_tokens"));
        if (obj.get("tools_dir")) |k| a.tools_dir = try jsonStr(k, "tools_dir");
        if (obj.get("skills_dir")) |k| a.skills_dir = try jsonStr(k, "skills_dir");
        if (obj.get("system_prompt_file")) |k| a.system_prompt_file = try jsonStr(k, "system_prompt_file");
        if (obj.get("learnings_file")) |k| a.learnings_file = try jsonStr(k, "learnings_file");
        if (obj.get("state_dir")) |k| a.state_dir = try jsonStr(k, "state_dir");
        if (obj.get("sandbox_root")) |k| a.sandbox_root = try jsonStr(k, "sandbox_root");
        if (obj.get("git_commit")) |k| a.git_commit = switch (k) {
            .bool => |b| b,
            else => a.git_commit,
        };
        if (obj.get("seed")) |k| a.seed = @intCast(try jsonInt(k, "seed"));
        return a;
    }

    fn parseImprove(arena: std.mem.Allocator, v: json.Value) !Improve {
        _ = arena;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.ImproveNotObject,
        };
        var im = Improve{};
        if (obj.get("min_delta")) |k| im.min_delta = try jsonFloat(k, "min_delta");
        if (obj.get("default_iters")) |k| im.default_iters = @intCast(try jsonInt(k, "default_iters"));
        if (obj.get("max_context_bytes")) |k| {
            const n = try jsonInt(k, "max_context_bytes");
            im.max_context_bytes = if (n <= 0) null else @intCast(n);
        }
        if (obj.get("capability_gate")) |k| im.capability_gate = switch (k) {
            .bool => |b| b,
            else => im.capability_gate,
        };
        if (obj.get("max_cache_bytes")) |k| im.max_cache_bytes = @intCast(try jsonInt(k, "max_cache_bytes"));
        if (obj.get("max_staged_bytes")) |k| im.max_staged_bytes = @intCast(try jsonInt(k, "max_staged_bytes"));
        if (obj.get("max_tool_source_bytes")) |k| im.max_tool_source_bytes = @intCast(try jsonInt(k, "max_tool_source_bytes"));
        if (obj.get("max_skill_bytes")) |k| im.max_skill_bytes = @intCast(try jsonInt(k, "max_skill_bytes"));
        if (obj.get("max_proposal_bytes")) |k| im.max_proposal_bytes = @intCast(try jsonInt(k, "max_proposal_bytes"));
        return im;
    }

    fn merge(dst: *Config, src: Config, arena: std.mem.Allocator) !void {
        // Only override the default provider when the local file actually
        // named one; otherwise a bare config.local.json would clobber the
        // global default with the struct fallback ("deepseek").
        if (src.default_provider_present) dst.default_provider = src.default_provider;
        var it = src.providers.iterator();
        while (it.next()) |kv| {
            try dst.providers.put(arena, kv.key_ptr.*, kv.value_ptr.*);
        }
        // Only override agent/improve when the local file actually defined
        // them; otherwise the local defaults would clobber the global file.
        if (src.agent_present) dst.agent = src.agent;
        if (src.improve_present) dst.improve = src.improve;
        dst.peers = src.peers;
        // Only override the instance when the local file actually named one:
        // a bare config.local.json must not replace a stable name with a
        // pid-based default on every restart.
        if (src.instance_present) dst.instance = src.instance;
        dst.notify = src.notify;
        if (src.chatrooms_present) dst.chatrooms = src.chatrooms;
        if (src.modules_present) dst.modules = src.modules;
    }

    fn parseModules(arena: std.mem.Allocator, v: json.Value) !Modules {
        _ = arena;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.ModulesNotObject,
        };
        var m = Modules{};
        const fields = [_]struct { key: []const u8, ptr: *bool }{
            .{ .key = "mcp", .ptr = &m.mcp },
            .{ .key = "peers", .ptr = &m.peers },
            .{ .key = "a2a", .ptr = &m.a2a },
            .{ .key = "webui", .ptr = &m.webui },
            .{ .key = "graphs", .ptr = &m.graphs },
            .{ .key = "sessions", .ptr = &m.sessions },
            .{ .key = "goal", .ptr = &m.goal },
            .{ .key = "token_budget", .ptr = &m.token_budget },
            .{ .key = "streaming", .ptr = &m.streaming },
            .{ .key = "dotenv", .ptr = &m.dotenv },
            .{ .key = "hot_reload", .ptr = &m.hot_reload },
            .{ .key = "autolearn", .ptr = &m.autolearn },
            .{ .key = "subagents", .ptr = &m.subagents },
            .{ .key = "rlm", .ptr = &m.rlm },
            .{ .key = "multimodal", .ptr = &m.multimodal },
            .{ .key = "chatrooms", .ptr = &m.chatrooms },
            .{ .key = "token_stats", .ptr = &m.token_stats },
        };
        for (fields) |f| {
            if (obj.get(f.key)) |val| {
                if (val == .bool) f.ptr.* = val.bool;
            }
        }
        return m;
    }

    // --- helpers -----------------------------------------------------------

    fn required(obj: json.ObjectMap, key: []const u8) !json.Value {
        return obj.get(key) orelse error.MissingField;
    }

    fn jsonStr(v: json.Value, key: []const u8) ![]const u8 {
        _ = key;
        return switch (v) {
            .string => |s| s,
            else => error.FieldNotString,
        };
    }

    fn jsonInt(v: json.Value, key: []const u8) !i64 {
        _ = key;
        return switch (v) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            .number_string => |s| std.fmt.parseInt(i64, s, 10) catch error.FieldNotInt,
            else => error.FieldNotInt,
        };
    }

    fn jsonFloat(v: json.Value, key: []const u8) !f64 {
        _ = key;
        return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            .number_string => |s| std.fmt.parseFloat(f64, s) catch error.FieldNotNumber,
            else => error.FieldNotNumber,
        };
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test "config load and merge" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try dir.writeFile(io, .{
        .sub_path = "config.json",
        .data =
        \\{
        \\  "default_provider": "deepseek",
        \\  "providers": {
        \\    "deepseek": { "kind": "openai_compat", "base_url": "https://api.deepseek.com", "api_key_env": "DEEPSEEK_API_KEY", "models": { "deepseek-chat": { "max_tokens": 2048 } } },
        \\    "ollama": { "base_url": "http://127.0.0.1:11434/v1", "models": { "llama3.1": {} } }
        \\  },
        \\  "agent": { "max_iterations": 5 }
        \\}
        ,
    });
    const cfg = try Config.load(io, arena, dir, "config.json", "config.local.json");
    try std.testing.expectEqualStrings("deepseek", cfg.default_provider);
    const ds = cfg.providers.getPtr("deepseek").?;
    try std.testing.expectEqual(ProviderKind.openai_compat, ds.kind);
    try std.testing.expectEqualStrings("https://api.deepseek.com", ds.base_url);
    try std.testing.expectEqualStrings("DEEPSEEK_API_KEY", ds.api_key_env.?);
    // The legacy flat shape is normalized into a one-entry models map.
    try std.testing.expectEqualStrings("deepseek-chat", ds.activeModelName());
    try std.testing.expectEqual(@as(u32, 2048), ds.activeModel().max_tokens);
    try std.testing.expectEqual(@as(usize, 1), ds.models.count());
    const ollama = cfg.providers.getPtr("ollama").?;
    try std.testing.expect(ollama.api_key_env == null);
    try std.testing.expectEqual(@as(u32, 5), cfg.agent.max_iterations);
    // provider lookup
    const found = try cfg.provider(null);
    try std.testing.expectEqualStrings("deepseek", found.name);
}

/// Hosts a tool may reach when its descriptor sets `network_from_config`.
/// `"peers"` yields every configured peer host, `"providers"` every provider
/// base_url host. Descriptors cannot know these: they come from config, and
/// change whenever a peer or provider is added.
pub fn configuredHosts(self: *const Config, arena: std.mem.Allocator, which: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (std.mem.eql(u8, which, "peers")) {
        for (self.peers) |p| {
            if (hostOf(p.url)) |h| try out.append(arena, h);
        }
    } else if (std.mem.eql(u8, which, "providers")) {
        var it = self.providers.iterator();
        while (it.next()) |kv| {
            if (hostOf(kv.value_ptr.base_url)) |h| try out.append(arena, h);
        }
    }
    return out.toOwnedSlice(arena);
}

/// The hostname of a URL, without the port: `ck_http` matches against
/// `std.Uri.host`, which excludes it, so keeping `:17932` here would deny every
/// peer that runs on a non-default port.
fn hostOf(url: []const u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const rest = url[scheme_end + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    var host = rest[0..end];
    if (std.mem.indexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    if (host.len > 0 and host[0] == '[') {
        // IPv6 literal: the port sits after the closing bracket.
        const close = std.mem.indexOfScalar(u8, host, ']') orelse return null;
        host = host[0 .. close + 1];
    } else if (std.mem.indexOfScalar(u8, host, ':')) |colon| {
        host = host[0..colon];
    }
    return if (host.len == 0) null else host;
}

test "configuredHosts extracts peer and provider hosts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cfg = Config{};
    cfg.peers = &.{
        .{ .name = "a", .url = "http://127.0.0.1:17932" },
        .{ .name = "b", .url = "https://rig.lan:8080/agent" },
    };
    const peer_hosts = try configuredHosts(&cfg, arena, "peers");
    try std.testing.expectEqual(@as(usize, 2), peer_hosts.len);
    try std.testing.expectEqualStrings("127.0.0.1", peer_hosts[0]);
    try std.testing.expectEqualStrings("rig.lan", peer_hosts[1]);

    try std.testing.expectEqual(@as(usize, 0), (try configuredHosts(&cfg, arena, "nothing")).len);
    try std.testing.expect(hostOf("not-a-url") == null);
}

test "legacy flat provider fields are rejected with a pointer to the fix" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.json",
        .data =
        \\{"default_provider":"flat","providers":{"flat":{"base_url":"https://example.test","model":"m1","context_window":4096}}}
        ,
    });
    try std.testing.expectError(
        error.ProviderLegacyModelFields,
        Config.load(io, arena_state.allocator(), tmp.dir, "config.json", "missing.json"),
    );
}

test "a single model needs no default_model" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.json",
        .data =
        \\{"default_provider":"solo","providers":{"solo":{"base_url":"https://example.test","models":{"only":{"max_tokens":128}}}}}
        ,
    });
    const cfg = try Config.load(io, arena, tmp.dir, "config.json", "missing.json");
    const solo = cfg.providers.getPtr("solo").?;
    try std.testing.expectEqualStrings("only", solo.activeModelName());
    try std.testing.expectEqual(@as(u32, 128), solo.activeModel().max_tokens);
}

test "a provider with no models is rejected at load" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.json",
        .data =
        \\{"default_provider":"empty","providers":{"empty":{"base_url":"https://example.test"}}}
        ,
    });
    try std.testing.expectError(
        error.ProviderMissingModel,
        Config.load(io, arena_state.allocator(), tmp.dir, "config.json", "missing.json"),
    );
}

test "a default_model with no matching entry is rejected at load" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.json",
        .data =
        \\{"default_provider":"p","providers":{"p":{"base_url":"https://x.test","default_model":"absent","models":{"present":{}}}}}
        ,
    });
    // Caught at startup rather than at the first request.
    try std.testing.expectError(
        error.ProviderDefaultModelUnknown,
        Config.load(io, arena_state.allocator(), tmp.dir, "config.json", "missing.json"),
    );
}
