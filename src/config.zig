//! Configuration loading: `config.toml` (committed example) merged with
//! `config.local.toml` (gitignored, user-specific). API keys are never stored
//! here — providers reference an environment variable by name instead.
//!
//! Providers and their models are declared separately: `[providers.<name>]`
//! holds connection settings (kind, base_url, api_key_env), and a top-level
//! `[models."<provider>/<model>"]` table (keyed by that composite id, each
//! entry naming its own `provider`) holds the model settings, inspired by
//! Kimi Code's config.toml shape. `distributeModels` files each entry into
//! its provider's `Provider.models` map at load time, so everything below
//! that point (`Provider.activeModel()`, `resolveProvider`, `merge`, and
//! every caller across the LLM client/agent loop) still sees the same
//! per-provider model map it always has — only the on-disk shape changed.

const std = @import("std");
const json = std.json;
const log = @import("util/log.zig");
const toml_bridge = @import("util/toml_bridge.zig");

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
    /// What the model supports, e.g. "tool_use", "image_in", "video_in",
    /// "audio_in", "thinking", "always_thinking" (models.dev's own
    /// modalities/reasoning/tool_call fields, `clanker providers fill`
    /// derives these; see cmdProvidersFill in cli.zig). Informational: lets a
    /// model entry self-document what it supports without a second lookup.
    capabilities: []const []const u8 = &.{},
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

    /// How long `providers check` waits for this endpoint before giving up on
    /// it, overriding `agent.provider_check_timeout_seconds` for this provider
    /// alone (seconds). Null takes that global default; 0 means no ceiling.
    /// Exists because one config mixes a LAN endpoint that either answers in a
    /// blink or is switched off with hosted ones that legitimately take a few
    /// seconds, and a single number cannot be short for both.
    check_timeout_seconds: ?u32 = null,

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
    tools_dir: []const u8 = "tools/manifests",
    skills_dir: []const u8 = "skills",
    system_prompt_file: []const u8 = "skills/SYSTEM.md",
    learnings_file: []const u8 = "state/learnings.md",
    /// Device-global operator instructions file. Empty (default) means
    /// `$HOME/.agents/AGENTS.md` when HOME is set; missing/empty files are
    /// skipped at prompt build time. Project-root `AGENTS.md` stays separate.
    global_instructions_file: []const u8 = "",
    /// Directory (relative to the process cwd) holding harness state:
    /// chatroom logs, run records, cursors.
    state_dir: []const u8 = "state",
    sandbox_root: []const u8 = ".",
    /// Directory holding reusable prompt templates ("workflows", Cursor-style).
    workflows_dir: []const u8 = "workflows",
    /// Directory for shared chain pipelines (tool-level, not prompt-level).
    /// When equal to workflows_dir, chains are stored as workflows/*.json
    /// alongside the prompt templates for a single place to manage them.
    chains_dir: []const u8 = "chains",
    /// Commit promoted improvements with git (git_commit_after_improve).
    git_commit: bool = true,
    /// Whether the `git` tool may run the PR-lifecycle verbs it otherwise
    /// cannot: `push`, `merge`, and `checkout`. Scoped to the command being
    /// `git` in ck_exec, so no other tool inherits the widening; the rest of
    /// the deny list (`reset`, `rebase`, `clean`, `rm`, `fetch`, `-f`, ...)
    /// still applies to git and to everything else. Default false = today's
    /// hardcoded denies.
    git_remote_ops: bool = false,
    /// Whole-command-line glob patterns a tool may run through ck_exec, e.g.
    /// "gh pr create*" or "gh pr merge*". When a pattern names a command,
    /// that command becomes strict: only an argv that matches one of its
    /// patterns runs, and the match also overrides the deny tokens for the
    /// args it grants ("gh pr merge" legitimately contains "merge"). Commands
    /// with no pattern stay under the deny-list check, so a pattern for `gh`
    /// does not widen `git` or anything else. `*` matches any run of
    /// characters, including across spaces and empty.
    exec_pattern_allow: []const []const u8 = &.{},
    seed: u64 = 0,
    /// How long a serve-side ask_user question waits for the browser before
    /// giving up (seconds). The wait holds one of the server's connection
    /// threads, so it must be bounded: on timeout the tool gets the same
    /// "nobody attached" answer a headless run gets and the run proceeds.
    ask_timeout_seconds: u32 = 120,
    /// How long `providers check` waits for one provider before reporting it
    /// as timed out and moving on (seconds). Unbounded, a single unreachable
    /// endpoint costs the whole sweep the OS's connect timeout (~75s on macOS)
    /// with nothing else on screen, which reads as a hang and gets Ctrl-C'd
    /// before the providers below it are ever reached. 10 leaves headroom for
    /// a cold TLS handshake plus a first token from a hosted provider, so a
    /// healthy one is not misreported. 0 disables the ceiling;
    /// `[providers.<name>] check_timeout_seconds` overrides it per provider.
    provider_check_timeout_seconds: u32 = 10,
    /// Gate write-capable tool calls (a descriptor with exec or filesystem
    /// access, or `"confirm": true`) on a human's allow/deny. `never` is
    /// today's behaviour; `browser` gates streaming web runs, where the
    /// question travels the run's own stream like ask_user. `always` is
    /// reserved for also gating interactive REPL sessions at the terminal,
    /// but src/tui/repl_vaxis.zig has no prompt-rendering path to answer it
    /// yet (see docs/ROADMAP.md, "vaxis REPL: close the gap left by the
    /// deleted REPL"): only cli.zig's serve path reads this field, gated on
    /// `!= .never`, so `always` behaves identically to `browser` until the
    /// REPL wires a confirm_fn of its own. Runs with no human channel —
    /// headless one-shots, the improve loop, nested sub-agents — are never
    /// gated, whatever this says: a confirm nobody can answer would deny
    /// every write instead of protecting anything.
    confirm_writes: ConfirmWrites = .never,
};

/// Which agent keys a config file actually set. Used so a partial
/// `config.local.toml` `"agent"` object does not replace the whole agent
/// struct (and reset `tools_dir` etc. to struct defaults).
pub const AgentFields = struct {
    max_iterations: bool = false,
    compact_threshold_bytes: bool = false,
    max_total_tokens: bool = false,
    max_tokens_per_turn: bool = false,
    max_history_tokens: bool = false,
    tool_catalog: bool = false,
    hot_tools: bool = false,
    tools_dir: bool = false,
    skills_dir: bool = false,
    system_prompt_file: bool = false,
    learnings_file: bool = false,
    global_instructions_file: bool = false,
    state_dir: bool = false,
    sandbox_root: bool = false,
    workflows_dir: bool = false,
    chains_dir: bool = false,
    git_commit: bool = false,
    git_remote_ops: bool = false,
    exec_pattern_allow: bool = false,
    seed: bool = false,
    ask_timeout_seconds: bool = false,
    provider_check_timeout_seconds: bool = false,
    confirm_writes: bool = false,
};

/// Who must approve a write-capable tool call before it runs.
pub const ConfirmWrites = enum { never, browser, always };

pub const Improve = struct {
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
    /// How many times in one improve run the model may answer with a request
    /// for files it was not shown instead of a patch. The context is a slice
    /// of the tree, so this is the loop's only way to look anything up; each
    /// one costs a call that produces no patch. 0 disables it.
    max_context_requests: u32 = 3,
    /// Reject a proposal whose only effect is to add code nothing can reach.
    /// Every other gate asks whether a change is safe; a change that does
    /// nothing is maximally safe, so without this the loop is rewarded for
    /// producing it. `src/util/json.zig` still carries three such promotions.
    inert_gate: bool = true,
    /// How many accepted improvements in a row may be test-only before the
    /// next test-only proposal is refused. Tests are worth promoting; a run
    /// that promotes nothing else has stopped improving the program and is
    /// only improving its own acceptance rate. 0 disables the check.
    max_consecutive_test_only: u32 = 3,
    /// Plan before patching: one model call per batch lists candidate
    /// improvements, the engine dedups them against history, picks the first
    /// novel one, pins its files into the context and asks the patch call to
    /// implement exactly that. Off, the patch call picks its own idea and
    /// writes an exact-match patch blind in the same breath — the shape every
    /// stuck-idea loop this repo has seen grew out of.
    plan_phase: bool = true,
    /// Provider the capability gate runs the staged eval suite on. The evals
    /// are mechanical capability checks (call a tool, read a field of its
    /// result), not reasoning work, so a fast cheap model grades them the
    /// same as a frontier one -- measured, the eval phase was ~334s of a
    /// ~368s gate on the proposal provider. null keeps the staged tree's own
    /// default provider.
    eval_provider: ?[]const u8 = null,
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

pub const Memory = struct {
    backend: []const u8 = "hybrid",
    chunk_strategy: []const u8 = "markdown",
    chunk_size: u32 = 800,
    chunk_overlap: u32 = 120,
    embedding_provider: []const u8 = "",
    embedding_model: []const u8 = "",
    vector_backend: []const u8 = "builtin",
    vector_top_k: u32 = 5,
    vector_threshold: f32 = 0.35,
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

/// Online-research web access. The sandbox denies network to a tool by
/// default: a tool reaches a host only when its descriptor names it
/// (`network_allow`) or the harness adds it from config (`network_from_config`).
/// This section is the config side of that second channel for the web/research
/// tools: every host listed here is added to `fetch_web` and `web_search`'s
/// allowlists at load, so granting a research site is a config edit, not a
/// manifest edit.
pub const Web = struct {
    /// Hostnames (no scheme, no path — matched against the URL's host) the
    /// research tools may reach. Default empty: out of the box the sandbox
    /// still lets a tool reach only its own `network_allow` hosts, which for
    /// `fetch_web` is a small static set. Adding a host here widens research
    /// without touching any manifest.
    allow: []const []const u8 = &.{},
};

pub const Config = struct {
    agent_present: bool = false,
    /// Which keys inside `"agent"` were set when this Config was parsed.
    agent_fields: AgentFields = .{},
    improve_present: bool = false,
    default_provider: []const u8 = "deepseek",
    providers: std.StringArrayHashMapUnmanaged(Provider) = .empty,
    agent: Agent = .{},
    improve: Improve = .{},
    peers: []const Peer = &.{},
    web: Web = .{},
    instance: Instance = .{},
    notify: Notify = .{},
    chatrooms: Chatrooms = .{},
    memory: Memory = .{},
    modules: Modules = .{},
    modules_present: bool = false,
    chatrooms_present: bool = false,
    memory_present: bool = false,
    instance_present: bool = false,
    default_provider_present: bool = false,
    peers_present: bool = false,
    web_present: bool = false,
    notify_present: bool = false,
    /// Path of the file that set `default_provider`, as actually read — the
    /// `.json` sibling when that is what answered. Null means no config named
    /// one and the struct fallback above is in force. Reported by `providers
    /// check`: "the default is X" is not much use without "because Y says so",
    /// since the base file and the local override disagree by design.
    default_provider_from: ?[]const u8 = null,

    pub fn provider(self: *const Config, name: ?[]const u8) !*const Provider {
        const want = name orelse self.default_provider;
        return self.providers.getPtr(want) orelse error.UnknownProvider;
    }

    /// The provider named by `--provider` (or the config default), with
    /// `--model` applied as a one-off override of its `default_model`.
    ///
    /// `--model <provider>/<model>` picks both at once, so `--model
    /// zai/glm-5.2` needs no separate `--provider`. The prefix is only read
    /// as a provider when config actually has one by that name and
    /// `--provider` was not given: a model id can contain a slash of its own
    /// (`moonshotai/kimi-k3` is a model, served by the provider named
    /// `kimi-k3`), and splitting those would send a request for a model that
    /// does not exist to a provider that does not either.
    pub fn resolveProvider(self: *const Config, provider_name: ?[]const u8, model_name: ?[]const u8) !Provider {
        var want_provider = provider_name;
        var want_model = model_name;
        if (want_provider == null) {
            if (want_model) |m| {
                if (std.mem.findScalar(u8, m, '/')) |slash| {
                    const head = m[0..slash];
                    const tail = m[slash + 1 ..];
                    if (head.len > 0 and tail.len > 0 and self.providers.getPtr(head) != null) {
                        want_provider = head;
                        want_model = tail;
                    }
                }
            }
        }
        var p = (try self.provider(want_provider)).*;
        if (want_model) |m| p.default_model = m;
        return p;
    }

    /// Loads `file_name` (TOML) plus `local_file_name` (if present) from
    /// `dir`. All returned strings are allocated in `arena`.
    pub fn load(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir, file_name: []const u8, local_file_name: []const u8) !Config {
        const base = (try loadFile(io, arena, dir, file_name, .required)).?;
        var cfg = base.cfg;
        if (cfg.default_provider_present) cfg.default_provider_from = base.path;
        if (try loadFile(io, arena, dir, local_file_name, .optional)) |local| {
            try merge(&cfg, local.cfg, arena);
            // merge() only takes default_provider when the local file named
            // one, so the provenance has to move on exactly the same condition.
            if (local.cfg.default_provider_present) cfg.default_provider_from = local.path;
        }
        // Checked on the merged result rather than per file. A local override
        // that only sets, say, `default_provider` has no "providers" section by
        // design, and warning about it points at a config that is in fact fine.
        if (cfg.providers.count() == 0) {
            log.log(.warn, "config {s}: no providers defined", .{base.path});
        } else if (cfg.providers.get(cfg.default_provider) == null) {
            // Otherwise a typo'd default_provider loads clean and only fails
            // on the first chat request, far from the config that caused it.
            log.log(.error_, "default_provider '{s}' is not in \"providers\"", .{cfg.default_provider});
            return error.DefaultProviderUnknown;
        }
        return cfg;
    }

    const LoadMode = enum { required, optional };

    /// A parsed config file plus the path it came from, kept so
    /// default_provider provenance can name its source file.
    const Loaded = struct { cfg: Config, path: []const u8 };

    /// TOML only: the requested file is read and parsed as TOML, full stop.
    /// A `.json` sibling fallback existed briefly during the JSON->TOML
    /// migration and was removed on purpose -- TOML is canonical, and a
    /// half-supported legacy format that only sometimes applies is worse
    /// than an error telling the user to convert the file.
    fn loadFile(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir, file_name: []const u8, mode: LoadMode) !?Loaded {
        const raw = dir.readFileAlloc(io, file_name, arena, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => return switch (mode) {
                .required => error.MissingConfig,
                .optional => null,
            },
            else => return err,
        };
        const root = toml_bridge.parseToJsonValue(arena, raw) catch |err| {
            log.log(.error_, "config {s}: invalid TOML: {s}", .{ file_name, @errorName(err) });
            return err;
        };
        return .{ .cfg = try parseConfig(arena, root), .path = file_name };
    }

    fn parseConfig(arena: std.mem.Allocator, root: json.Value) !Config {
        var cfg = Config{};
        const obj = switch (root) {
            .object => |o| o,
            else => return error.ConfigNotObject,
        };
        warnUnknownKeys(obj, &.{
            "default_provider", "agent",    "improve", "providers",
            "models",           "instance", "peers",   "notify",
            "chatrooms",        "modules",  "web",     "memory",
        }, "config");

        if (obj.get("default_provider")) |v| {
            cfg.default_provider = try jsonStr(v, "default_provider");
            cfg.default_provider_present = true;
        }
        if (obj.get("agent")) |v| {
            const parsed = try parseAgent(arena, v);
            cfg.agent = parsed.agent;
            cfg.agent_fields = parsed.fields;
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
                const p = try parseProvider(kv.key_ptr.*, kv.value_ptr.*);
                try cfg.providers.put(arena, kv.key_ptr.*, p);
            }
        }
        if (obj.get("models")) |v| {
            try distributeModels(arena, &cfg, v);
        }
        if (cfg.providers.count() > 0) try validateProviderModels(&cfg);
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
            cfg.peers_present = true;
        }
        if (obj.get("web")) |v| {
            cfg.web = try parseWeb(arena, v);
            cfg.web_present = true;
        }
        if (obj.get("notify")) |v| {
            cfg.notify = try parseNotify(arena, v);
            cfg.notify_present = true;
        }
        if (obj.get("chatrooms")) |v| {
            cfg.chatrooms = try parseChatrooms(arena, v);
            cfg.chatrooms_present = true;
        }
        if (obj.get("memory")) |v| {
            cfg.memory = try parseMemory(arena, v);
            cfg.memory_present = true;
        }
        if (obj.get("modules")) |v| {
            cfg.modules = try parseModules(arena, v);
            cfg.modules_present = true;
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
        };
        warnUnknownKeys(obj, &.{
            "base_url",         "kind",          "project",
            "location",         "api_key_env",   "service_account_file",
            "path",             "default_model", "check_timeout_seconds",
            // Legacy names: flagged with a dedicated error below, not a warning.
            "model",            "models",        "max_tokens",
            "context_window",   "temperature",   "top_p",
            "reasoning_effort",
        }, name);
        // Settings that belong to a model are rejected on the provider: they
        // differ per model on the same endpoint, and silently accepting them
        // here is how a config ends up meaning something other than it reads.
        if (obj.get("model") != null) {
            log.log(.error_, "provider '{s}': \"model\" was replaced by the top-level \"models\" table. Add [models.\"{s}/<name>\"] with \"provider\": \"{s}\", and set \"default_model\": \"<name>\" if there is more than one", .{ name, name, name });
            return error.ProviderLegacyModelFields;
        }
        if (obj.get("models") != null) {
            log.log(.error_, "provider '{s}': \"models\" moved out of the provider. Use the top-level [models.\"{s}/<name>\"] table with \"provider\": \"{s}\"", .{ name, name, name });
            return error.ProviderLegacyModelFields;
        }
        for ([_][]const u8{ "max_tokens", "context_window", "temperature", "top_p", "reasoning_effort" }) |legacy| {
            if (obj.get(legacy) != null) {
                log.log(.error_, "provider '{s}': \"{s}\" belongs to a model, not the provider. Move it into the top-level [models.\"{s}/<name>\"] table", .{ name, legacy, name });
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
        if (obj.get("check_timeout_seconds")) |k| {
            const secs = try jsonInt(k, "check_timeout_seconds");
            // Rejected rather than @intCast into a panic: a negative timeout
            // has no sensible reading, and "0 disables" is already taken.
            if (secs < 0) {
                log.log(.error_, "provider '{s}': \"check_timeout_seconds\" must be >= 0 (0 = no ceiling)", .{name});
                return error.BadCheckTimeout;
            }
            p.check_timeout_seconds = @intCast(secs);
        }

        // vertex_anthropic addresses the model by project/location in the URL
        // and authenticates from one of two credential sources; missing either
        // currently only surfaces as error.VertexProjectMissing (or a bare
        // MissingApiKey) on the first request, far from the config that caused
        // it.
        if (p.kind == .vertex_anthropic) {
            if (p.project.len == 0 or p.location.len == 0) {
                log.log(.error_, "provider '{s}': kind \"vertex_anthropic\" requires \"project\" and \"location\"", .{name});
                return error.VertexProjectMissing;
            }
            if (p.api_key_env == null and p.service_account_file.len == 0) {
                log.log(.error_, "provider '{s}': kind \"vertex_anthropic\" requires \"api_key_env\" or \"service_account_file\"", .{name});
                return error.VertexCredentialMissing;
            }
        }

        // Models are validated after the top-level "models" table is
        // distributed into each provider (distributeModels /
        // validateProviderModels below): at this point `p.models` is always
        // empty.
        return p;
    }

    /// Reads the top-level "models" table (keyed `"<provider>/<model>"`, each
    /// entry naming its own `"provider"`) and distributes each entry into
    /// that provider's `Provider.models` map. Kept separate from
    /// `parseProvider` because a model's home provider must already exist in
    /// `cfg.providers` before it can be filed there.
    fn distributeModels(arena: std.mem.Allocator, cfg: *Config, v: json.Value) !void {
        const models_obj = switch (v) {
            .object => |o| o,
            else => return error.ModelsNotObject,
        };
        var it = models_obj.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            const entry_obj = switch (kv.value_ptr.*) {
                .object => |o| o,
                else => return error.ModelNotObject,
            };
            const provider_name = try jsonStr(try required(entry_obj, "provider"), "provider");
            const p = cfg.providers.getPtr(provider_name) orelse {
                log.log(.error_, "models[\"{s}\"]: provider '{s}' is not declared under \"providers\"", .{ key, provider_name });
                return error.ModelUnknownProvider;
            };
            const prefix_len = provider_name.len + 1; // "<provider>/"
            if (key.len <= prefix_len or !std.mem.startsWith(u8, key, provider_name) or key[provider_name.len] != '/') {
                log.log(.error_, "models[\"{s}\"]: key must be \"{s}/<model-name>\" to match \"provider\": \"{s}\"", .{ key, provider_name, provider_name });
                return error.ModelKeyProviderMismatch;
            }
            const model_name = key[prefix_len..];
            const m = try parseModel(arena, model_name, kv.value_ptr.*);
            try p.models.put(arena, model_name, m);
        }
    }

    /// One shape, checked at startup: a provider names its models and picks
    /// one. Both failures below would otherwise surface as a confusing error
    /// on the first request instead of at load.
    fn validateProviderModels(cfg: *Config) !void {
        var it = cfg.providers.iterator();
        while (it.next()) |kv| {
            const name = kv.key_ptr.*;
            const p = kv.value_ptr;
            if (p.models.count() == 0) {
                log.log(.error_, "provider '{s}': no models declared (add a [models.\"{s}/<name>\"] entry)", .{ name, name });
                return error.ProviderMissingModel;
            }
            if (p.default_model.len == 0) {
                // One model is unambiguous, so naming it twice is noise.
                p.default_model = p.models.keys()[0];
            }
            if (p.models.get(p.default_model) == null) {
                log.log(.error_, "provider '{s}': default_model '{s}' is not in its models", .{ name, p.default_model });
                return error.ProviderDefaultModelUnknown;
            }
        }
    }

    fn parseModel(arena: std.mem.Allocator, name: []const u8, v: json.Value) !Model {
        const obj = switch (v) {
            .object => |o| o,
            else => return error.ModelNotObject,
        };
        var m = Model{};
        warnUnknownKeys(obj, &.{
            // "provider" is consumed by distributeModels (which provider this
            // entry belongs to, before the table-key prefix is stripped down
            // to the bare model name passed in here) — accepted, not unknown.
            "provider",
            "context_window",
            "max_tokens",
            "temperature",
            "top_p",
            "reasoning_effort",
            "display",
            "cost_per_1m_input",
            "cost_per_1m_output",
            "capabilities",
        }, name);
        if (obj.get("context_window")) |k| m.context_window = @intCast(try jsonInt(k, "context_window"));
        if (obj.get("max_tokens")) |k| m.max_tokens = @intCast(try jsonInt(k, "max_tokens"));
        if (obj.get("temperature")) |k| m.temperature = try jsonFloat(k, "temperature");
        if (obj.get("top_p")) |k| m.top_p = try jsonFloat(k, "top_p");
        if (obj.get("reasoning_effort")) |k| m.reasoning_effort = try jsonStr(k, "reasoning_effort");
        if (obj.get("display")) |k| m.display = try jsonStr(k, "display");
        if (obj.get("cost_per_1m_input")) |k| m.cost_per_1m_input = try jsonFloat(k, "cost_per_1m_input");
        if (obj.get("cost_per_1m_output")) |k| m.cost_per_1m_output = try jsonFloat(k, "cost_per_1m_output");
        if (obj.get("capabilities")) |k| {
            const arr = switch (k) {
                .array => |a| a,
                else => return error.CapabilitiesNotArray,
            };
            var caps: std.ArrayList([]const u8) = .empty;
            for (arr.items) |item| try caps.append(arena, try jsonStr(item, "capabilities[]"));
            m.capabilities = try caps.toOwnedSlice(arena);
        }
        return m;
    }

    fn parseInstance(arena: std.mem.Allocator, v: json.Value) !Instance {
        const obj = switch (v) {
            .object => |o| o,
            else => return error.InstanceNotObject,
        };
        var inst = Instance{};
        warnUnknownKeys(obj, &.{ "name", "id" }, "instance");
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
            warnUnknownKeys(obj, &.{ "name", "url" }, "peers[]");
            try out.append(arena, .{
                .name = try jsonStr(try required(obj, "name"), "name"),
                .url = try jsonStr(try required(obj, "url"), "url"),
            });
        }
        return out.toOwnedSlice(arena);
    }

    fn parseWeb(arena: std.mem.Allocator, v: json.Value) !Web {
        const obj = switch (v) {
            .object => |o| o,
            else => return error.WebNotObject,
        };
        var web = Web{};
        warnUnknownKeys(obj, &.{"allow"}, "web");
        if (obj.get("allow")) |k| {
            const arr = switch (k) {
                .array => |a| a,
                else => return error.WebAllowNotArray,
            };
            var allow: std.ArrayList([]const u8) = .empty;
            for (arr.items) |item| {
                const host = try jsonStr(item, "web.allow[]");
                if (!isBareHost(host)) return error.WebAllowHostInvalid;
                try allow.append(arena, host);
            }
            web.allow = try allow.toOwnedSlice(arena);
        }
        return web;
    }

    /// `ck_http` compares this exact string with the parsed URL hostname, so
    /// a URL, path, or host:port entry would never grant the intended access.
    fn isBareHost(host: []const u8) bool {
        return host.len > 0 and std.mem.findAny(u8, host, ":/?#@% \t\r\n") == null;
    }

    fn parseNotify(arena: std.mem.Allocator, v: json.Value) !Notify {
        _ = arena;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.NotifyNotObject,
        };
        var n = Notify{};
        warnUnknownKeys(obj, &.{ "on", "topic" }, "notify");
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
        warnUnknownKeys(obj, &.{ "on", "rooms", "max_history" }, "chatrooms");
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
        var seed: u64 = @as(u64, @intCast(std.c.getpid())) *% 0x9e3779b97f4a7c15;
        var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        if (std.posix.gethostname(&host_buf)) |host| {
            for (host) |ch| seed ^= std.hash.Wyhash.hash(0, &[_]u8{ch});
        } else |_| {}
        seed ^= std.hash.Wyhash.hash(0, @as([*]const u8, @ptrCast(&seed))[0..8]);
        var prng = std.Random.DefaultPrng.init(seed);
        const n = prng.random().intRangeAtMost(u16, 100, 999);
        // Futurama-robot flavored, matching friendlyInstanceName's word list
        // in cli.zig (cmdInit) so a fresh instance and a bare fallback name
        // both read as the same kind of thing.
        const bots = [_][]const u8{ "bender", "clamps", "calculon", "flexo", "crushinator", "hedonismbot", "roberto", "donbot", "preacherbot", "cogsworth", "servo", "gearbot", "rustbucket", "widget", "clunker", "tinman", "sparky", "rustbolt", "boltface", "mechbot" };
        const bot = bots[prng.random().intRangeAtMost(usize, 0, bots.len - 1)];
        return std.fmt.allocPrint(arena, "clanker-{s}-{d}", .{ bot, n });
    }

    const ParsedAgent = struct {
        agent: Agent,
        fields: AgentFields,
    };

    fn parseAgent(arena: std.mem.Allocator, v: json.Value) !ParsedAgent {
        const obj = switch (v) {
            .object => |o| o,
            else => return error.AgentNotObject,
        };
        var a = Agent{};
        var f = AgentFields{};
        warnUnknownKeys(obj, &.{
            "max_iterations",      "compact_threshold_bytes",        "max_total_tokens",
            "max_tokens_per_turn", "max_history_tokens",             "tool_catalog",
            "hot_tools",           "tools_dir",                      "skills_dir",
            "system_prompt_file",  "learnings_file",                 "global_instructions_file",
            "state_dir",           "sandbox_root",                   "workflows_dir",
            "chains_dir",          "git_commit",                     "git_remote_ops",
            "exec_pattern_allow",  "seed",                           "ask_timeout_seconds",
            "confirm_writes",      "provider_check_timeout_seconds",
        }, "agent");
        if (obj.get("max_iterations")) |k| {
            a.max_iterations = @intCast(try jsonInt(k, "max_iterations"));
            f.max_iterations = true;
        }
        if (obj.get("compact_threshold_bytes")) |k| {
            a.compact_threshold_bytes = @intCast(try jsonInt(k, "compact_threshold_bytes"));
            f.compact_threshold_bytes = true;
        }
        if (obj.get("max_total_tokens")) |k| {
            a.max_total_tokens = @intCast(try jsonInt(k, "max_total_tokens"));
            f.max_total_tokens = true;
        }
        if (obj.get("max_tokens_per_turn")) |k| {
            a.max_tokens_per_turn = @intCast(try jsonInt(k, "max_tokens_per_turn"));
            f.max_tokens_per_turn = true;
        }
        if (obj.get("max_history_tokens")) |k| {
            a.max_history_tokens = @intCast(try jsonInt(k, "max_history_tokens"));
            f.max_history_tokens = true;
        }
        if (obj.get("tools_dir")) |k| {
            a.tools_dir = try jsonStr(k, "tools_dir");
            f.tools_dir = true;
        }
        if (obj.get("skills_dir")) |k| {
            a.skills_dir = try jsonStr(k, "skills_dir");
            f.skills_dir = true;
        }
        if (obj.get("system_prompt_file")) |k| {
            a.system_prompt_file = try jsonStr(k, "system_prompt_file");
            f.system_prompt_file = true;
        }
        if (obj.get("learnings_file")) |k| {
            a.learnings_file = try jsonStr(k, "learnings_file");
            f.learnings_file = true;
        }
        if (obj.get("global_instructions_file")) |k| {
            a.global_instructions_file = try jsonStr(k, "global_instructions_file");
            f.global_instructions_file = true;
        }
        if (obj.get("state_dir")) |k| {
            a.state_dir = try jsonStr(k, "state_dir");
            f.state_dir = true;
        }
        if (obj.get("sandbox_root")) |k| {
            a.sandbox_root = try jsonStr(k, "sandbox_root");
            f.sandbox_root = true;
        }
        if (obj.get("workflows_dir")) |k| {
            a.workflows_dir = try jsonStr(k, "workflows_dir");
            f.workflows_dir = true;
        }
        if (obj.get("chains_dir")) |k| {
            a.chains_dir = try jsonStr(k, "chains_dir");
            f.chains_dir = true;
        }
        if (obj.get("git_commit")) |k| {
            a.git_commit = switch (k) {
                .bool => |b| b,
                else => return error.FieldNotBool,
            };
            f.git_commit = true;
        }
        if (obj.get("git_remote_ops")) |k| {
            a.git_remote_ops = switch (k) {
                .bool => |b| b,
                else => return error.FieldNotBool,
            };
            f.git_remote_ops = true;
        }
        if (obj.get("exec_pattern_allow")) |k| {
            const arr = switch (k) {
                .array => |ar| ar,
                else => return error.ExecPatternAllowNotArray,
            };
            var patterns: std.ArrayList([]const u8) = .empty;
            for (arr.items) |item| {
                const pat = try jsonStr(item, "exec_pattern_allow[]");
                if (pat.len == 0) return error.ExecPatternAllowEmpty;
                // The git tool's deny list (which refuses checkout, reset, etc.)
                // must never be overridable through exec_pattern_allow. If a
                // config names a git command here it silently grants a verb the
                // sandbox is supposed to refuse, breaking git_deny. Destructive
                // git verbs are meant to be enabled via git_remote_ops instead.
                if (std.mem.startsWith(u8, pat, "git") and
                    (pat.len == 3 or (pat.len > 3 and (pat[3] == ' ' or pat[3] == '\t'))))
                {
                    log.log(.error_, "agent: exec_pattern_allow must not name git commands (use git_remote_ops instead)", .{});
                    return error.ExecPatternAllowGitForbidden;
                }
                try patterns.append(arena, pat);
            }
            a.exec_pattern_allow = try patterns.toOwnedSlice(arena);
            f.exec_pattern_allow = true;
        }
        if (obj.get("tool_catalog")) |k| {
            a.tool_catalog = switch (k) {
                .bool => |b| b,
                else => return error.FieldNotBool,
            };
            f.tool_catalog = true;
        }
        if (obj.get("hot_tools")) |k| {
            a.hot_tools = @intCast(try jsonInt(k, "hot_tools"));
            f.hot_tools = true;
        }
        if (obj.get("seed")) |k| {
            a.seed = @intCast(try jsonInt(k, "seed"));
            f.seed = true;
        }
        if (obj.get("ask_timeout_seconds")) |k| {
            a.ask_timeout_seconds = @intCast(try jsonInt(k, "ask_timeout_seconds"));
            f.ask_timeout_seconds = true;
        }
        if (obj.get("provider_check_timeout_seconds")) |k| {
            const secs = try jsonInt(k, "provider_check_timeout_seconds");
            if (secs < 0) {
                log.log(.error_, "agent.provider_check_timeout_seconds must be >= 0 (0 = no ceiling)", .{});
                return error.BadCheckTimeout;
            }
            a.provider_check_timeout_seconds = @intCast(secs);
            f.provider_check_timeout_seconds = true;
        }
        if (obj.get("confirm_writes")) |k| {
            const s = try jsonStr(k, "confirm_writes");
            a.confirm_writes = std.meta.stringToEnum(ConfirmWrites, s) orelse
                return error.ConfirmWritesInvalid;
            f.confirm_writes = true;
        }
        return .{ .agent = a, .fields = f };
    }

    fn applyAgentFields(dst: *Agent, src: Agent, fields: AgentFields) void {
        if (fields.max_iterations) dst.max_iterations = src.max_iterations;
        if (fields.compact_threshold_bytes) dst.compact_threshold_bytes = src.compact_threshold_bytes;
        if (fields.max_total_tokens) dst.max_total_tokens = src.max_total_tokens;
        if (fields.max_tokens_per_turn) dst.max_tokens_per_turn = src.max_tokens_per_turn;
        if (fields.max_history_tokens) dst.max_history_tokens = src.max_history_tokens;
        if (fields.tool_catalog) dst.tool_catalog = src.tool_catalog;
        if (fields.hot_tools) dst.hot_tools = src.hot_tools;
        if (fields.tools_dir) dst.tools_dir = src.tools_dir;
        if (fields.skills_dir) dst.skills_dir = src.skills_dir;
        if (fields.system_prompt_file) dst.system_prompt_file = src.system_prompt_file;
        if (fields.learnings_file) dst.learnings_file = src.learnings_file;
        if (fields.global_instructions_file) dst.global_instructions_file = src.global_instructions_file;
        if (fields.state_dir) dst.state_dir = src.state_dir;
        if (fields.sandbox_root) dst.sandbox_root = src.sandbox_root;
        if (fields.workflows_dir) dst.workflows_dir = src.workflows_dir;
        if (fields.chains_dir) dst.chains_dir = src.chains_dir;
        if (fields.git_commit) dst.git_commit = src.git_commit;
        if (fields.git_remote_ops) dst.git_remote_ops = src.git_remote_ops;
        if (fields.exec_pattern_allow) dst.exec_pattern_allow = src.exec_pattern_allow;
        if (fields.seed) dst.seed = src.seed;
        if (fields.ask_timeout_seconds) dst.ask_timeout_seconds = src.ask_timeout_seconds;
        if (fields.provider_check_timeout_seconds) dst.provider_check_timeout_seconds = src.provider_check_timeout_seconds;
        if (fields.confirm_writes) dst.confirm_writes = src.confirm_writes;
    }

    fn parseImprove(arena: std.mem.Allocator, v: json.Value) !Improve {
        _ = arena;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.ImproveNotObject,
        };
        var im = Improve{};
        warnUnknownKeys(obj, &.{ "max_context_bytes", "capability_gate", "max_cache_bytes", "max_context_requests", "inert_gate", "max_consecutive_test_only", "eval_provider", "plan_phase" }, "improve");
        if (obj.get("max_context_bytes")) |k| {
            const n = try jsonInt(k, "max_context_bytes");
            im.max_context_bytes = if (n <= 0) null else @intCast(n);
        }
        if (obj.get("capability_gate")) |k| im.capability_gate = switch (k) {
            .bool => |b| b,
            else => im.capability_gate,
        };
        if (obj.get("max_cache_bytes")) |k| im.max_cache_bytes = @intCast(try jsonInt(k, "max_cache_bytes"));
        if (obj.get("max_context_requests")) |k| {
            const n = try jsonInt(k, "max_context_requests");
            im.max_context_requests = if (n <= 0) 0 else @intCast(n);
        }
        if (obj.get("inert_gate")) |k| im.inert_gate = switch (k) {
            .bool => |b| b,
            else => im.inert_gate,
        };
        if (obj.get("max_consecutive_test_only")) |k| {
            const n = try jsonInt(k, "max_consecutive_test_only");
            im.max_consecutive_test_only = if (n <= 0) 0 else @intCast(n);
        }
        if (obj.get("eval_provider")) |k| im.eval_provider = try jsonStr(k, "eval_provider");
        if (obj.get("plan_phase")) |k| im.plan_phase = switch (k) {
            .bool => |b| b,
            else => im.plan_phase,
        };
        return im;
    }

    fn merge(dst: *Config, src: Config, arena: std.mem.Allocator) !void {
        // Only override the default provider when the local file actually
        // named one; otherwise a bare config.local.toml would clobber the
        // global default with the struct fallback ("deepseek").
        if (src.default_provider_present) dst.default_provider = src.default_provider;
        var it = src.providers.iterator();
        while (it.next()) |kv| {
            try dst.providers.put(arena, kv.key_ptr.*, kv.value_ptr.*);
        }
        // Agent is field-merged: a local file that only sets e.g. sandbox_root
        // must not reset tools_dir (and the rest) to Agent{} defaults — that
        // made every tool disappear when tools_dir fell back to the struct
        // default instead of config.toml's "tools/manifests".
        if (src.agent_present) applyAgentFields(&dst.agent, src.agent, src.agent_fields);
        // Improve is still whole-section: it is small and rarely partial.
        if (src.improve_present) dst.improve = src.improve;
        if (src.peers_present) dst.peers = src.peers;
        if (src.web_present) dst.web = src.web;
        // Only override the instance when the local file actually named one:
        // a bare config.local.toml must not replace a stable name with a
        // pid-based default on every restart.
        if (src.instance_present) dst.instance = src.instance;
        if (src.notify_present) dst.notify = src.notify;
        if (src.chatrooms_present) dst.chatrooms = src.chatrooms;
        if (src.memory_present) dst.memory = src.memory;
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
        warnUnknownKeys(obj, &.{
            "mcp",        "peers",       "a2a",          "webui",     "graphs",
            "sessions",   "goal",        "token_budget", "streaming", "dotenv",
            "hot_reload", "autolearn",   "subagents",    "rlm",       "multimodal",
            "chatrooms",  "token_stats",
        }, "modules");
        for (fields) |f| {
            if (obj.get(f.key)) |val| {
                if (val == .bool) f.ptr.* = val.bool;
            }
        }
        return m;
    }

    fn parseMemory(arena: std.mem.Allocator, v: json.Value) !Memory {
        _ = arena;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.MemoryNotObject,
        };
        var m = Memory{};
        warnUnknownKeys(obj, &.{ "backend", "chunk", "embedding", "vector" }, "memory");
        if (obj.get("backend")) |k| m.backend = try jsonStr(k, "backend");
        if (obj.get("chunk")) |k| {
            const co = switch (k) {
                .object => |o| o,
                else => return error.MemoryNotObject,
            };
            warnUnknownKeys(co, &.{ "size", "overlap", "strategy" }, "memory.chunk");
            if (co.get("size")) |x| m.chunk_size = @intCast(try jsonInt(x, "chunk.size"));
            if (co.get("overlap")) |x| m.chunk_overlap = @intCast(try jsonInt(x, "chunk.overlap"));
            if (co.get("strategy")) |x| m.chunk_strategy = try jsonStr(x, "chunk.strategy");
        }
        if (obj.get("embedding")) |k| {
            const eo = switch (k) {
                .object => |o| o,
                else => return error.MemoryNotObject,
            };
            warnUnknownKeys(eo, &.{ "provider", "model" }, "memory.embedding");
            if (eo.get("provider")) |x| m.embedding_provider = try jsonStr(x, "embedding.provider");
            if (eo.get("model")) |x| m.embedding_model = try jsonStr(x, "embedding.model");
        }
        if (obj.get("vector")) |k| {
            const vo = switch (k) {
                .object => |o| o,
                else => return error.MemoryNotObject,
            };
            warnUnknownKeys(vo, &.{ "backend", "top_k", "threshold" }, "memory.vector");
            if (vo.get("backend")) |x| m.vector_backend = try jsonStr(x, "vector.backend");
            if (vo.get("top_k")) |x| m.vector_top_k = @intCast(try jsonInt(x, "vector.top_k"));
            if (vo.get("threshold")) |x| m.vector_threshold = @floatCast(try jsonFloat(x, "vector.threshold"));
        }
        return m;
    }

    // --- helpers -----------------------------------------------------------

    fn required(obj: json.ObjectMap, key: []const u8) !json.Value {
        return obj.get(key) orelse error.MissingField;
    }

    /// Warns (never fails the load) about a key in `obj` that isn't in
    /// `known`. `.ignore_unknown_fields` lets the JSON parser accept
    /// anything, so a misspelled key like `mx_iterations` would otherwise
    /// load clean and silently fall back to its default with no signal.
    fn warnUnknownKeys(obj: json.ObjectMap, known: []const []const u8, context: []const u8) void {
        var it = obj.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            for (known) |name| {
                if (std.mem.eql(u8, key, name)) break;
            } else {
                log.log(.warn, "config: unknown key '{s}' in {s} (ignored — check spelling)", .{ key, context });
            }
        }
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
            .float => |f| @trunc(f),
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

test "agent.global_instructions_file parses and defaults empty" {
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
        .sub_path = "config.toml",
        .data =
        \\default_provider = "ollama"
        \\
        \\[providers.ollama]
        \\base_url = "http://127.0.0.1:11434/v1"
        \\
        \\[models."ollama/llama3.1"]
        \\provider = "ollama"
        \\
        \\[agent]
        \\global_instructions_file = "/home/op/.agents/AGENTS.md"
        \\
        ,
    });
    const cfg = try Config.load(io, arena, dir, "config.toml", "config.local.toml");
    try std.testing.expectEqualStrings("/home/op/.agents/AGENTS.md", cfg.agent.global_instructions_file);
    try std.testing.expectEqualStrings("", (Agent{}).global_instructions_file);
}

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
        .sub_path = "config.toml",
        .data =
        \\default_provider = "deepseek"
        \\
        \\[providers.deepseek]
        \\kind = "openai_compat"
        \\base_url = "https://api.deepseek.com"
        \\api_key_env = "DEEPSEEK_API_KEY"
        \\
        \\[providers.ollama]
        \\base_url = "http://127.0.0.1:11434/v1"
        \\
        \\[models."deepseek/deepseek-chat"]
        \\provider = "deepseek"
        \\max_tokens = 2048
        \\
        \\[models."ollama/llama3.1"]
        \\provider = "ollama"
        \\
        \\[agent]
        \\max_iterations = 5
        \\
        ,
    });
    const cfg = try Config.load(io, arena, dir, "config.toml", "config.local.toml");
    try std.testing.expectEqualStrings("deepseek", cfg.default_provider);
    const ds = cfg.providers.getPtr("deepseek").?;
    try std.testing.expectEqual(ProviderKind.openai_compat, ds.kind);
    try std.testing.expectEqualStrings("https://api.deepseek.com", ds.base_url);
    try std.testing.expectEqualStrings("DEEPSEEK_API_KEY", ds.api_key_env.?);
    // A single flat models entry is normalized into a one-entry models map.
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

test "web.allow parses hostname entries onto Config" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const root = try json.parseFromSliceLeaky(json.Value, arena,
        \\{"web":{"allow":["example.org","docs.example"]}}
    , .{ .ignore_unknown_fields = true });
    const cfg = try Config.parseConfig(arena, root);
    try std.testing.expectEqual(@as(usize, 2), cfg.web.allow.len);
    try std.testing.expectEqualStrings("example.org", cfg.web.allow[0]);
    try std.testing.expectEqualStrings("docs.example", cfg.web.allow[1]);
}

test "config.local.toml web.allow replaces the global web allowlist" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data =
        \\web.allow = ["global.example", "keep.example"]
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "config.local.toml", .data =
        \\web.allow = ["local.example"]
    });
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
    try std.testing.expectEqual(@as(usize, 1), cfg.web.allow.len);
    try std.testing.expectEqualStrings("local.example", cfg.web.allow[0]);
}

test "confirm_writes parses its three values and rejects anything else" {
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
        .sub_path = "config.toml",
        .data =
        \\default_provider = "ollama"
        \\
        \\[providers.ollama]
        \\base_url = "http://127.0.0.1:11434/v1"
        \\
        \\[models."ollama/llama3.1"]
        \\provider = "ollama"
        \\
        \\[agent]
        \\confirm_writes = "browser"
        \\
        ,
    });
    const cfg = try Config.load(io, arena, dir, "config.toml", "config.local.toml");
    try std.testing.expectEqual(ConfirmWrites.browser, cfg.agent.confirm_writes);

    // Left out, the default keeps headless runs and the improve loop ungated.
    try std.testing.expectEqual(ConfirmWrites.never, (Agent{}).confirm_writes);

    // A typo must fail the load, not silently run without the gate the
    // config asked for.
    try dir.writeFile(io, .{
        .sub_path = "bad.toml",
        .data =
        \\default_provider = "ollama"
        \\
        \\[providers.ollama]
        \\base_url = "http://127.0.0.1:11434/v1"
        \\
        \\[models."ollama/llama3.1"]
        \\provider = "ollama"
        \\
        \\[agent]
        \\confirm_writes = "sometimes"
        \\
        ,
    });
    try std.testing.expectError(error.ConfirmWritesInvalid, Config.load(io, arena, dir, "bad.toml", "config.local.toml"));
}

test "a config.local.json sibling is ignored: TOML is canonical" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.toml",
        .data =
        \\default_provider = "committed"
        \\providers = { committed = { base_url = "https://a.test" }, from_json = { base_url = "https://c.test" } }
        \\models = { "committed/m" = { provider = "committed" }, "from_json/m" = { provider = "from_json" } }
        ,
    });
    // A leftover pre-migration file: it must have no effect at all, not even
    // as a fallback when no config.local.toml exists. A legacy format that
    // only sometimes applies is worse than requiring the file be converted.
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.local.json",
        .data =
        \\{ "default_provider": "from_json" }
        ,
    });
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
    try std.testing.expectEqualStrings("committed", cfg.default_provider);
    try std.testing.expectEqualStrings("config.toml", cfg.default_provider_from.?);
}

test "default_provider provenance names the file that set it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The base file sets it and no local override exists: the base owns it.
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.toml",
        .data =
        \\default_provider = "a"
        \\providers = { a = { base_url = "https://a.test" } }
        \\models = { "a/m" = { provider = "a" } }
        ,
    });
    const named = try Config.load(io, arena, tmp.dir, "config.toml", "missing.toml");
    try std.testing.expectEqualStrings("config.toml", named.default_provider_from.?);

    // Nothing sets it, so the struct fallback is in force and provenance is
    // null — which is what tells `providers check` to say so out loud.
    var bare = std.testing.tmpDir(.{});
    defer bare.cleanup();
    try bare.dir.writeFile(io, .{
        .sub_path = "config.toml",
        .data =
        \\providers = { deepseek = { base_url = "https://a.test" } }
        \\models = { "deepseek/m" = { provider = "deepseek" } }
        ,
    });
    const fallback = try Config.load(io, arena, bare.dir, "config.toml", "missing.toml");
    try std.testing.expectEqualStrings("deepseek", fallback.default_provider);
    try std.testing.expectEqual(@as(?[]const u8, null), fallback.default_provider_from);
}

test "a local override that does not name a default leaves provenance on the base" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.toml",
        .data =
        \\default_provider = "a"
        \\providers = { a = { base_url = "https://a.test" } }
        \\models = { "a/m" = { provider = "a" } }
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.local.toml",
        .data =
        // A local file that redefines a provider repeats its models: merge
        // replaces the whole provider entry, so anything left out is gone.
        \\providers = { a = { base_url = "https://override.test" } }
        \\models = { "a/m" = { provider = "a" } }
        ,
    });
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
    // merge() only takes default_provider when the local file named one, so
    // provenance must not drift to the local file just because it was read.
    try std.testing.expectEqualStrings("a", cfg.default_provider);
    try std.testing.expectEqualStrings("config.toml", cfg.default_provider_from.?);
    try std.testing.expectEqualStrings("https://override.test", cfg.providers.getPtr("a").?.base_url);
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
pub fn hostOf(url: []const u8) ?[]const u8 {
    const scheme_end = std.mem.find(u8, url, "://") orelse return null;
    const rest = url[scheme_end + 3 ..];
    const end = std.mem.findAny(u8, rest, "/?#") orelse rest.len;
    var host = rest[0..end];
    if (std.mem.findScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    if (host.len > 0 and host[0] == '[') {
        // IPv6 literal: the port sits after the closing bracket. std.Uri.host
        // excludes the brackets, so return the raw address or the granted host
        // could never match ck_http's comparison against a peer/providers URL
        // on IPv6.
        const close = std.mem.findScalar(u8, host, ']') orelse return null;
        host = host[1..close];
    } else if (std.mem.findScalar(u8, host, ':')) |colon| {
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

test "hostOf strips IPv6 brackets, userinfo, and ports" {
    // An IPv6 literal: std.Uri.host excludes the brackets, so the granted
    // host must too, or an IPv6 peer/provierd could never be reached by a
    // network_from_config tool.
    try std.testing.expectEqualStrings("::1", hostOf("http://[::1]:8080/agent").?);
    try std.testing.expectEqualStrings("::1", hostOf("http://[::1]").?);
    // Userinfo and port are stripped before the host comparison.
    try std.testing.expectEqualStrings("rig.lan", hostOf("https://user:pass@rig.lan:8443").?);
    // A URL with no scheme yields nothing rather than a bogus host.
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
        .sub_path = "config.toml",
        .data =
        \\default_provider = "flat"
        \\providers = { flat = { base_url = "https://example.test", model = "m1", context_window = 4096 } }
        ,
    });
    try std.testing.expectError(
        error.ProviderLegacyModelFields,
        Config.load(io, arena_state.allocator(), tmp.dir, "config.toml", "missing.toml"),
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
        .sub_path = "config.toml",
        .data =
        \\default_provider = "solo"
        \\providers = { solo = { base_url = "https://example.test" } }
        \\models = { "solo/only" = { provider = "solo", max_tokens = 128 } }
        ,
    });
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "missing.toml");
    const solo = cfg.providers.getPtr("solo").?;
    try std.testing.expectEqualStrings("only", solo.activeModelName());
    try std.testing.expectEqual(@as(u32, 128), solo.activeModel().max_tokens);
}

test "a local override with only default_provider keeps the base providers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.toml",
        .data =
        \\default_provider = "a"
        \\providers = { a = { base_url = "https://a.test" }, b = { base_url = "https://b.test" } }
        \\models = { "a/m" = { provider = "a" }, "b/m" = { provider = "b" } }
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.local.toml",
        .data =
        \\default_provider = "b"
        ,
    });
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
    // The point of the test: switching the default provider from a local file
    // must not look like a config that defines no providers.
    try std.testing.expectEqual(@as(usize, 2), cfg.providers.count());
    try std.testing.expectEqualStrings("b", cfg.default_provider);
    try std.testing.expectEqualStrings("https://b.test", (try cfg.provider(null)).base_url);
}

test "partial local agent keeps base tools_dir" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.toml",
        .data =
        \\default_provider = "a"
        \\providers = { a = { base_url = "https://a.test" } }
        \\models = { "a/m" = { provider = "a" } }
        \\agent = { tools_dir = "tools/manifests", max_iterations = 30 }
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.local.toml",
        .data =
        \\agent = { sandbox_root = "." }
        ,
    });
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
    try std.testing.expectEqualStrings("tools/manifests", cfg.agent.tools_dir);
    try std.testing.expectEqualStrings(".", cfg.agent.sandbox_root);
    try std.testing.expectEqual(@as(u32, 30), cfg.agent.max_iterations);
}

test "the providers-check timeout has a short default, a global key, and a per-provider override" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Default first: a config that says nothing about it still bounds a sweep.
    try std.testing.expectEqual(@as(u32, 10), (Agent{}).provider_check_timeout_seconds);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.toml",
        .data =
        \\default_provider = "hosted"
        \\providers = { hosted = { base_url = "https://a.test" }, lan = { base_url = "http://10.0.0.5:8000/v1", check_timeout_seconds = 2 } }
        \\models = { "hosted/m" = { provider = "hosted" }, "lan/m" = { provider = "lan" } }
        \\agent = { provider_check_timeout_seconds = 30 }
        ,
    });
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
    try std.testing.expectEqual(@as(u32, 30), cfg.agent.provider_check_timeout_seconds);
    // Null, not 30: the sweep reads the global default itself, so "unset" stays
    // distinguishable from "set to the same number".
    try std.testing.expect(cfg.providers.getPtr("hosted").?.check_timeout_seconds == null);
    try std.testing.expectEqual(@as(u32, 2), cfg.providers.getPtr("lan").?.check_timeout_seconds.?);
}

test "a negative check timeout is rejected instead of wrapping into a huge one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.toml",
        .data =
        \\default_provider = "a"
        \\providers = { a = { base_url = "https://a.test", check_timeout_seconds = -1 } }
        \\models = { "a/m" = { provider = "a" } }
        ,
    });
    try std.testing.expectError(error.BadCheckTimeout, Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml"));
}

test "agent.git_remote_ops and exec_pattern_allow parse from config" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.toml",
        .data =
        \\default_provider = "a"
        \\providers = { a = { base_url = "https://a.test" } }
        \\models = { "a/m" = { provider = "a" } }
        \\agent = { git_remote_ops = true, exec_pattern_allow = ["gh pr create*", "gh pr merge*"] }
        ,
    });
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
    try std.testing.expect(cfg.agent.git_remote_ops);
    try std.testing.expectEqual(@as(usize, 2), cfg.agent.exec_pattern_allow.len);
    try std.testing.expectEqualStrings("gh pr create*", cfg.agent.exec_pattern_allow[0]);
    try std.testing.expectEqualStrings("gh pr merge*", cfg.agent.exec_pattern_allow[1]);

    // Defaults stay false / empty when the keys are absent.
    var arena2 = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena2.deinit();
    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    try tmp2.dir.writeFile(io, .{
        .sub_path = "config.toml",
        .data =
        \\default_provider = "a"
        \\providers = { a = { base_url = "https://a.test" } }
        \\models = { "a/m" = { provider = "a" } }
        ,
    });
    const cfg2 = try Config.load(io, arena2.allocator(), tmp2.dir, "config.toml", "config.local.toml");
    try std.testing.expect(!cfg2.agent.git_remote_ops);
    try std.testing.expectEqual(@as(usize, 0), cfg2.agent.exec_pattern_allow.len);
}

test "exec_pattern_allow rejects git patterns to protect the deny list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.toml",
        .data =
        \\default_provider = "a"
        \\providers = { a = { base_url = "https://a.test" } }
        \\models = { "a/m" = { provider = "a" } }
        \\agent = { exec_pattern_allow = ["git checkout*"] }
        ,
    });
    try std.testing.expectError(
        error.ExecPatternAllowGitForbidden,
        Config.load(io, arena_state.allocator(), tmp.dir, "config.toml", "config.local.toml"),
    );
}

test "a vertex_anthropic provider missing project/location is rejected at load" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.toml",
        .data =
        \\default_provider = "v"
        \\providers = { v = { kind = "vertex_anthropic", base_url = "https://x.test", api_key_env = "TOK" } }
        \\models = { "v/m" = { provider = "v" } }
        ,
    });
    // Caught at startup rather than as error.VertexProjectMissing on the
    // first request, far from the config that caused it.
    try std.testing.expectError(
        error.VertexProjectMissing,
        Config.load(io, arena_state.allocator(), tmp.dir, "config.toml", "missing.toml"),
    );
}

test "a vertex_anthropic provider missing both credential sources is rejected at load" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.toml",
        .data =
        \\default_provider = "v"
        \\providers = { v = { kind = "vertex_anthropic", base_url = "https://x.test", project = "p", location = "us-central1" } }
        \\models = { "v/m" = { provider = "v" } }
        ,
    });
    try std.testing.expectError(
        error.VertexCredentialMissing,
        Config.load(io, arena_state.allocator(), tmp.dir, "config.toml", "missing.toml"),
    );
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
        .sub_path = "config.toml",
        .data =
        \\default_provider = "empty"
        \\providers = { empty = { base_url = "https://example.test" } }
        ,
    });
    try std.testing.expectError(
        error.ProviderMissingModel,
        Config.load(io, arena_state.allocator(), tmp.dir, "config.toml", "missing.toml"),
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
        .sub_path = "config.toml",
        .data =
        \\default_provider = "p"
        \\providers = { p = { base_url = "https://x.test", default_model = "absent" } }
        \\models = { "p/present" = { provider = "p" } }
        ,
    });
    // Caught at startup rather than at the first request.
    try std.testing.expectError(
        error.ProviderDefaultModelUnknown,
        Config.load(io, arena_state.allocator(), tmp.dir, "config.toml", "missing.toml"),
    );
}

test "a default_provider naming no provider is rejected at load" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.toml",
        .data =
        \\default_provider = "typo"
        \\providers = { real = { base_url = "https://x.test" } }
        \\models = { "real/m" = { provider = "real" } }
        ,
    });
    // A typo'd default_provider must fail at startup, not on the first chat
    // request from whichever caller happens to run first.
    try std.testing.expectError(
        error.DefaultProviderUnknown,
        Config.load(io, arena_state.allocator(), tmp.dir, "config.toml", "missing.toml"),
    );
}

test "agent.tool_catalog and hot_tools load from config" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.toml",
        .data =
        \\default_provider = "p"
        \\providers = { p = { base_url = "https://x.test" } }
        \\models = { "p/m" = { provider = "p" } }
        \\agent = { tool_catalog = false, hot_tools = 3 }
        ,
    });
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "missing.toml");
    try std.testing.expectEqual(false, cfg.agent.tool_catalog);
    try std.testing.expectEqual(@as(u32, 3), cfg.agent.hot_tools);
}

test "an unknown key in a known section does not fail the load" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.toml",
        .data =
        \\default_provider = "p"
        \\providers = { p = { base_url = "https://x.test" } }
        \\models = { "p/m" = { provider = "p" } }
        \\agent = { mx_iterations = 5 }
        ,
    });
    // A misspelled key only warns (logged, not asserted here); the load must
    // still succeed with the real default rather than silently misbehaving.
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "missing.toml");
    try std.testing.expectEqual(@as(u32, 24), cfg.agent.max_iterations);
}

test "resolveProvider splits provider/model and keeps opaque slash ids whole" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cfg = Config{ .default_provider = "zai" };
    var zai = Provider{ .name = "zai", .base_url = "https://zai.test", .default_model = "glm-5.2" };
    try zai.models.put(arena, "glm-5.2", .{});
    try cfg.providers.put(arena, "zai", zai);
    var kimi = Provider{ .name = "kimi-k3", .base_url = "https://api.moonshot.ai/v1", .default_model = "kimi-k3" };
    try kimi.models.put(arena, "kimi-k3", .{});
    try cfg.providers.put(arena, "kimi-k3", kimi);

    // --model zai/glm-5.2 needs no separate --provider.
    const a = try cfg.resolveProvider(null, "zai/glm-5.2");
    try std.testing.expectEqualStrings("zai", a.name);
    try std.testing.expectEqualStrings("glm-5.2", a.default_model);

    // kimi-k3/kimi-k3 heads a provider that is actually configured, so it
    // routes there.
    const b = try cfg.resolveProvider(null, "kimi-k3/kimi-k3");
    try std.testing.expectEqualStrings("kimi-k3", b.name);
    try std.testing.expectEqualStrings("kimi-k3", b.default_model);

    // An opaque model id whose head names no provider is sent verbatim on the
    // default provider, never split into a provider (and model) that does not
    // exist.
    const c = try cfg.resolveProvider(null, "moonshotai/kimi-k3");
    try std.testing.expectEqualStrings("zai", c.name);
    try std.testing.expectEqualStrings("moonshotai/kimi-k3", c.default_model);

    // An explicit --provider wins over the --model prefix.
    const d = try cfg.resolveProvider("kimi-k3", "zai/glm-5.2");
    try std.testing.expectEqualStrings("kimi-k3", d.name);
    try std.testing.expectEqualStrings("zai/glm-5.2", d.default_model);
}
// --- memory helpers (appended via patch) ---
