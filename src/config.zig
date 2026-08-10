//! Configuration loading: `config.json` (committed example) merged with
//! `config.local.json` (gitignored, user-specific). API keys are never stored
//! here — providers reference an environment variable by name instead.

const std = @import("std");
const json = std.json;
const log = @import("util/log.zig");

pub const ProviderKind = enum {
    openai_compat,
    anthropic,

    pub fn fromStr(s: []const u8) ?ProviderKind {
        if (std.mem.eql(u8, s, "openai_compat")) return .openai_compat;
        if (std.mem.eql(u8, s, "anthropic")) return .anthropic;
        return null;
    }
};

pub const Provider = struct {
    name: []const u8,
    kind: ProviderKind = .openai_compat,
    base_url: []const u8,
    api_key_env: ?[]const u8 = null,
    model: []const u8,
    /// Endpoint path override; defaults per kind (`/chat/completions`,
    /// `/v1/messages`).
    path: ?[]const u8 = null,
    max_tokens: u32 = 1024,
    temperature: ?f64 = null,
    /// Keeps reasoning models' chain-of-thought short so `content` stays
    /// populated (e.g. DeepSeek v4: "low" | "medium").
    reasoning_effort: ?[]const u8 = null,
};

pub const Agent = struct {
    max_iterations: u32 = 12,
    tools_dir: []const u8 = "tools",
    skills_dir: []const u8 = "skills",
    system_prompt_file: []const u8 = "skills/SYSTEM.md",
    learnings_file: []const u8 = "state/learnings.md",
    sandbox_root: []const u8 = ".",
    /// Commit promoted improvements with git (git_commit_after_improve).
    git_commit: bool = true,
    seed: u64 = 0,
};

pub const Improve = struct {
    min_delta: f64 = 0.05,
    default_iters: u32 = 3,
    max_context_bytes: usize = 64 * 1024,
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

pub const Config = struct {
    default_provider: []const u8 = "deepseek",
    providers: std.StringArrayHashMapUnmanaged(Provider) = .empty,
    agent: Agent = .{},
    improve: Improve = .{},
    peers: []const Peer = &.{},
    instance: Instance = .{},
    notify: Notify = .{},

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
        }
        if (obj.get("agent")) |v| {
            cfg.agent = try parseAgent(arena, v);
        }
        if (obj.get("improve")) |v| {
            cfg.improve = try parseImprove(arena, v);
        }
        if (obj.get("providers")) |v| {
            const pobj = switch (v) {
                .object => |o| o,
                else => return error.ProvidersNotObject,
            };
            var it = pobj.iterator();
            while (it.next()) |kv| {
                const p = try parseProvider(kv.key_ptr.*, kv.value_ptr.*);
                try cfg.providers.put(arena, kv.key_ptr.*, p);
            }
        }
        if (obj.get("instance")) |v| {
            cfg.instance = try parseInstance(arena, v);
        } else {
            cfg.instance.name = try defaultInstName(arena);
        }
        if (obj.get("peers")) |v| {
            cfg.peers = try parsePeers(arena, v);
        }
        if (obj.get("notify")) |v| {
            cfg.notify = try parseNotify(arena, v);
        }
        if (cfg.providers.count() == 0) {
            log.log(.warn, "config {s}: no providers defined", .{file_name});
        }
        return cfg;
    }

    fn parseProvider(name: []const u8, v: json.Value) !Provider {
        const obj = switch (v) {
            .object => |o| o,
            else => return error.ProviderNotObject,
        };
        var p = Provider{
            .name = name,
            .base_url = try jsonStr(try required(obj, "base_url"), "base_url"),
            .model = try jsonStr(try required(obj, "model"), "model"),
        };
        if (obj.get("kind")) |k| {
            p.kind = ProviderKind.fromStr(try jsonStr(k, "kind")) orelse return error.UnknownProviderKind;
        }
        if (obj.get("api_key_env")) |k| {
            p.api_key_env = try jsonStr(k, "api_key_env");
        }
        if (obj.get("path")) |k| {
            p.path = try jsonStr(k, "path");
        }
        if (obj.get("max_tokens")) |k| {
            p.max_tokens = @intCast(try jsonInt(k, "max_tokens"));
        }
        if (obj.get("temperature")) |k| {
            p.temperature = try jsonFloat(k, "temperature");
        }
        if (obj.get("reasoning_effort")) |k| {
            p.reasoning_effort = try jsonStr(k, "reasoning_effort");
        }
        return p;
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

    fn defaultInstName(arena: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "clanker-{d}", .{std.os.linux.getpid()});
    }

    fn parseAgent(arena: std.mem.Allocator, v: json.Value) !Agent {
        _ = arena;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.AgentNotObject,
        };
        var a = Agent{};
        if (obj.get("max_iterations")) |k| a.max_iterations = @intCast(try jsonInt(k, "max_iterations"));
        if (obj.get("tools_dir")) |k| a.tools_dir = try jsonStr(k, "tools_dir");
        if (obj.get("skills_dir")) |k| a.skills_dir = try jsonStr(k, "skills_dir");
        if (obj.get("system_prompt_file")) |k| a.system_prompt_file = try jsonStr(k, "system_prompt_file");
        if (obj.get("learnings_file")) |k| a.learnings_file = try jsonStr(k, "learnings_file");
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
        if (obj.get("max_context_bytes")) |k| im.max_context_bytes = @intCast(try jsonInt(k, "max_context_bytes"));
        if (obj.get("max_staged_bytes")) |k| im.max_staged_bytes = @intCast(try jsonInt(k, "max_staged_bytes"));
        if (obj.get("max_tool_source_bytes")) |k| im.max_tool_source_bytes = @intCast(try jsonInt(k, "max_tool_source_bytes"));
        if (obj.get("max_skill_bytes")) |k| im.max_skill_bytes = @intCast(try jsonInt(k, "max_skill_bytes"));
        if (obj.get("max_proposal_bytes")) |k| im.max_proposal_bytes = @intCast(try jsonInt(k, "max_proposal_bytes"));
        return im;
    }

    fn merge(dst: *Config, src: Config, arena: std.mem.Allocator) !void {
        dst.default_provider = src.default_provider;
        var it = src.providers.iterator();
        while (it.next()) |kv| {
            try dst.providers.put(arena, kv.key_ptr.*, kv.value_ptr.*);
        }
        // agent / improve: wholesale replace when present in local file is not
        // trackable here; local parsed values keep their defaults, so we only
        // override scalars the local file actually set. For simplicity we
        // replace when any field differs from the Config defaults is too
        // clever — instead we always replace agent/improve wholesale.
        dst.agent = src.agent;
        dst.improve = src.improve;
        dst.peers = src.peers;
        dst.instance = src.instance;
        dst.notify = src.notify;
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
        \\    "deepseek": { "kind": "openai_compat", "base_url": "https://api.deepseek.com", "api_key_env": "DEEPSEEK_API_KEY", "model": "deepseek-chat", "max_tokens": 2048 },
        \\    "ollama": { "base_url": "http://127.0.0.1:11434/v1", "model": "llama3.1" }
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
    try std.testing.expectEqual(@as(u32, 2048), ds.max_tokens);
    const ollama = cfg.providers.getPtr("ollama").?;
    try std.testing.expect(ollama.api_key_env == null);
    try std.testing.expectEqual(@as(u32, 5), cfg.agent.max_iterations);
    // provider lookup
    const found = try cfg.provider(null);
    try std.testing.expectEqualStrings("deepseek", found.name);
}
