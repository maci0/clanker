//! Configuration loading: `config.toml` (committed example) merged with
//! `config.local.toml` (gitignored, user-specific). API keys are never stored
//! here, providers reference an environment variable by name instead.
//!
//! Providers and their models are declared separately: `[providers.<name>]`
//! holds connection settings (kind, base_url, api_key_env), and a top-level
//! `[models."<provider>/<model>"]` table (keyed by that composite id, each
//! entry naming its own `provider`) holds the model settings, inspired by
//! Kimi Code's config.toml shape. `distributeModels` files each entry into
//! its provider's `Provider.models` map at load time, so everything below
//! that point (`Provider.activeModel()`, `resolveProvider`, `merge`, and
//! every caller across the LLM client/agent loop) still sees the same
//! per-provider model map it always has, only the on-disk shape changed.

const std = @import("std");
const json = std.json;
const log = @import("util/log.zig");
const toml_bridge = @import("util/toml_bridge.zig");
const atomic_write = @import("util/atomic_write.zig");
const models_dev = @import("llm/models_dev.zig");

/// A schema failure is reported before it reaches the command dispatcher.
/// Keeping the original TOML source here is intentional: the intermediate
/// JSON value tree has no spans, while the operator needs the line they wrote.
threadlocal var diagnostic_source: ?DiagnosticSource = null;
threadlocal var diagnostic_scope: []const u8 = "";
threadlocal var diagnostic_emitted: bool = false;
threadlocal var diagnostics_suppressed: bool = false;
threadlocal var last_load_diagnostic: bool = false;

const DiagnosticSource = struct {
    file_name: []const u8,
    raw: []const u8,
};

/// The wire format a provider speaks. One tag per entry in the
/// `src/llm/registry.zig` registry; the tag *is* the `kind = "..."` spelling,
/// so adding a provider means adding a tag here and a row there, and nothing
/// else in this file.
pub const ProviderKind = enum {
    openai_compat,
    anthropic,
    /// Anthropic models served through Google Vertex AI: same message format,
    /// but the model lives in the URL and auth is a GCP bearer token.
    vertex_anthropic,
    /// Google Vertex AI. Gemini generateContent by default; a Claude model
    /// id uses the Anthropic Vertex wire instead. Same GCP auth as
    /// `vertex_anthropic`.
    vertex,
    /// Azure OpenAI chat completions: same body as openai_compat, but the
    /// deployment is in the URL and the key rides `api-key`.
    azure_openai,
    /// Google Gemini generateContent (AI Studio).
    gemini,

    pub fn fromStr(s: []const u8) ?ProviderKind {
        return std.meta.stringToEnum(ProviderKind, s);
    }
};

/// Reasoning effort for models that expose it on the OpenAI-compatible wire
/// (`/v1/chat/completions`): Ollama, DeepSeek, OpenAI, OpenRouter, ... Sent as
/// the `reasoning_effort` request field. `null` (unconfigured) omits the field
/// entirely; `none` explicitly disables reasoning on providers that accept it.
pub const ReasoningEffort = enum {
    none,
    low,
    medium,
    high,
    max,

    pub fn fromStr(s: []const u8) ?ReasoningEffort {
        return std.meta.stringToEnum(ReasoningEffort, s);
    }
};

/// How a provider's credential is acquired, a separate axis from the wire
/// kind, because one wire format can accept several (docs/adrs/0005). Left
/// unset, each kind auto-detects from the credential's shape where the two
/// are distinguishable, which is what keeps Anthropic zero-config.
pub const AuthStrategy = enum {
    /// Read `api_key_env` and present it the way the wire kind wants.
    api_key,
    /// A pasted OAuth access token (env var), presented as a bearer token.
    oauth_static,
    /// A token minted and renewed in-process. Vertex's GCP service-account
    /// token is the one provider that does this today.
    oauth_refresh,

    pub fn fromStr(s: []const u8) ?AuthStrategy {
        return std.meta.stringToEnum(AuthStrategy, s);
    }
};

pub const Model = struct {
    /// SKU sent as the API `model` field. Empty means the table-key name
    /// (the part after `provider/`) is the SKU. Set this to give one SKU
    /// two local names with different sampling settings
    /// (`grok4.6-coding` and `grok4.6-general` both `id = "grok-4.6"`).
    id: []const u8 = "",
    /// Total model context window in tokens (input + output). Used to size
    /// conversation compaction and the improve context budget. Unset in the
    /// file is filled from the models.dev snapshot when one exists.
    context_window: u32 = 131072,
    /// True when the file named `context_window`. Catalog fill skips those.
    context_window_set: bool = false,
    /// Per-request max output tokens (completion cap). Unset in the file is
    /// filled from the models.dev `limit.output` when one exists.
    max_tokens: u32 = 1024,
    /// True when the file named `max_tokens`. Catalog fill skips those.
    max_tokens_set: bool = false,
    temperature: ?f64 = null,
    /// Nucleus sampling cutoff. Left null by default and generally best set
    /// *instead of* temperature rather than alongside it: both narrow the same
    /// distribution, and Anthropic's API documents adjusting only one.
    top_p: ?f64 = null,
    /// Keeps reasoning models' chain-of-thought short so `content` stays
    /// populated (e.g. DeepSeek v4: "low" | "medium"). Sent as the
    /// `reasoning_effort` field on the OpenAI-compatible wire (Ollama,
    /// DeepSeek, OpenAI, ...). One of "none" | "low" | "medium" | "high" |
    /// "max"; null omits the field entirely.
    reasoning_effort: ?ReasoningEffort = null,
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
    /// Free-form grouping ("flagship", "fast", "reasoning", "cheap", ...),
    /// used to sort/group the model list in the webui picker, the TUI's
    /// /model picker, and the CLI. Purely presentational: never sent to a
    /// provider. Empty sorts last within its provider.
    category: []const u8 = "",
    /// Self-imposed requests per minute for this local name. Null or 0 is
    /// unlimited. Independent of the provider's own `rpm` (both apply).
    rpm: ?u32 = null,

    /// The name the provider API wants. `key` is the table-key name.
    pub fn wireName(self: Model, key: []const u8) []const u8 {
        return if (self.id.len > 0) self.id else key;
    }
};

pub const Provider = struct {
    name: []const u8,
    kind: ProviderKind = .openai_compat,
    base_url: []const u8,
    api_key_env: ?[]const u8 = null,
    /// Explicit credential-acquisition strategy, overriding the wire kind's
    /// auto-detection. Needed where a provider's API keys and OAuth tokens
    /// are not distinguishable by shape, since guessing wrong sends the
    /// secret on the wrong header.
    auth: ?AuthStrategy = null,
    /// vertex / vertex_anthropic only: the GCP project and region that serve
    /// the model, and an optional service account JSON. When the file is
    /// omitted, minting falls through to gcloud ADC.
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

    /// azure_openai only: the `api-version` query. Empty uses the kind default.
    api_version: []const u8 = "",

    /// Self-imposed requests per minute shared by every model on this
    /// provider. Null or 0 is unlimited. A model's own `rpm` is a separate
    /// cap on that name, not an override of this one.
    rpm: ?u32 = null,

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

    /// The active model's local name (table key / picker id). Loading
    /// guarantees `default_model` is set and present in `models`.
    pub fn activeModelName(self: *const Provider) []const u8 {
        return self.default_model;
    }

    /// The active model's settings.
    pub fn activeModel(self: *const Provider) Model {
        return self.models.get(self.default_model) orelse .{};
    }

    /// The SKU sent on the wire for the active model. Differs from
    /// `activeModelName` when that entry is a local alias (`id` set).
    pub fn wireModelName(self: *const Provider) []const u8 {
        return self.activeModel().wireName(self.default_model);
    }

    /// The SKU for a named entry, or `key` itself when that entry is
    /// missing or has no `id`.
    pub fn modelSku(self: *const Provider, key: []const u8) []const u8 {
        if (self.models.get(key)) |m| return m.wireName(key);
        return key;
    }
};

pub const Agent = struct {
    /// A review or audit task spends most of its turns reading before it can
    /// answer anything. At 12 those runs ended at the ceiling with no answer
    /// and the whole run wasted; 24 still bit interactive REPL sessions on
    /// ordinary multi-file work, and hitting the ceiling discards the whole
    /// turn (error.MaxIterationsExceeded), so the wasted cost is the full run.
    /// 50 matches what agentic coding CLIs (grok, kimi) allow per turn.
    max_iterations: u32 = 50,
    /// Completed agent turns a continuing `/goal` loop may start before it
    /// reports a blocked budget outcome. This is distinct from
    /// `max_iterations`, which limits tool/model rounds *inside* one turn.
    max_goal_turns: u32 = 50,
    compact_threshold_bytes: usize = 24000,
    tool_result_prune_bytes: usize = 8192,
    tool_result_prune_head_bytes: usize = 4096,
    tool_result_prune_tail_bytes: usize = 1024,
    repeat_tool_thresholds: []const u32 = &.{ 3, 5, 8 },
    repeat_tool_exclude: []const []const u8 = &.{ "todo_add", "todo_close", "todo_list" },
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
    /// being asked for. Measured, not configured: see toolhost/usage.zig.
    hot_tools: u32 = 10,
    /// Directories of `*.tool.json` manifests, scanned in order. A later
    /// directory wins on a tool `name` collision. Config accepts a string
    /// (normalized to one entry) or an array, so existing `config.toml`
    /// files keep working.
    tools_dir: []const []const u8 = &.{"tools/manifests"},
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

    /// Absolute path of the checkout an isolated run was started from, set at
    /// runtime by `run --worktree` (see cmdRun) and deliberately NOT readable
    /// from a config file: it describes how this process was invoked, not a
    /// preference, and a stale value in config.local.toml would point a normal
    /// run's untracked paths at some other directory. Empty everywhere else.
    /// Consumed by sandbox.host's `shared_prefixes` routing.
    shared_root: []const u8 = "",
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
    /// Extra commands the REPL's `!` shell escape may run, on top of the union
    /// of every registered tool's `exec_allow`. Empty (the default) means `!`
    /// runs exactly the commands clanker's own tools may run and nothing more;
    /// listing `["ls", "cat"]` here widens the escape without widening any
    /// tool, since nothing reads this field except `src/tui/repl.zig`.
    /// The rest of the ck_exec policy (the deny tokens, git's verb allowlist,
    /// `exec_pattern_allow`) still applies to whatever is named here.
    repl_exec_allow: []const []const u8 = &.{},
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
    /// but src/tui/repl.zig has no prompt-rendering path to answer it
    /// yet (see docs/ROADMAP.md, "vaxis REPL: close the gap left by the
    /// deleted REPL"): only cli.zig's serve path reads this field, gated on
    /// `!= .never`, so `always` behaves identically to `browser` until the
    /// REPL wires a confirm_fn of its own. Runs with no human channel:
    /// headless one-shots, the improve loop, nested sub-agents, are never
    /// gated, whatever this says: a confirm nobody can answer would deny
    /// every write instead of protecting anything.
    confirm_writes: ConfirmWrites = .never,
    /// Ordered fallback providers, tried after the selected provider cannot
    /// serve a request. Config accepts `fallback_provider` (string or array)
    /// or `fallback_providers` (array); a bare string becomes one entry so
    /// existing configs keep working. Empty means no reactive chain.
    fallback_providers: []const []const u8 = &.{},
    /// Opt-in per-turn classifier that selects a sampling-profile
    /// `reasoning_effort` row. Off until a calibration eval justifies it.
    auto_thinking: bool = false,
    /// `provider` or `provider/model`. Empty means cheapest configured
    /// provider by `cost_per_1m_input`, then first alphabetically.
    thinking_classifier_model: []const u8 = "",
    thinking_classifier_timeout_ms: u32 = 3000,
    /// Default worktree isolation for a plain typed `clanker run` (not
    /// goal-driven, not scheduled). `auto` keeps the historical behaviour:
    /// off for a run at the terminal. `yes`/`no` force the default without an
    /// explicit `--worktree`/`--no-worktree`; an explicit flag still wins.
    worktree: WorktreeDefault = .auto,
    /// Same, but for `--goal` runs and scheduled (`unattended`) runs, which
    /// have historically isolated by default. `auto` keeps that; `yes`/`no`
    /// force a default.
    goal_worktree: WorktreeDefault = .auto,
    /// Per-mode opt-in to worktree isolation. Each mode named here isolates
    /// by default (as if that mode's `worktree`/`goal_worktree` were `yes`);
    /// a mode left out keeps its historical default, and an empty list keeps
    /// every mode on those defaults. An explicit `--worktree`/`--no-worktree`
    /// still wins over the list. Modes: `run`, `goal`, `tui`, `webui`.
    git_worktree_on: []const WorktreeMode = &.{},
    /// Start plain `clanker run` calls as isolated work instead of attaching
    /// the newest active goal. Isolation also defaults the run to a git
    /// worktree; an explicit --goal/--no-worktree remains authoritative.
    isolated_cli: bool = false,
    /// Start the terminal REPL in its own worktree. A REPL has one live
    /// conversation, so this protects every turn in that session.
    isolated_tui: bool = false,
    /// Start Web UI chat runs isolated by default: no implicit active-goal
    /// steering and a private worktree. The checkbox can still opt a run out.
    isolated_webui: bool = false,
};

/// Persistent eval kernels (PRD 0016). Off by default: a kernel is an
/// unsandboxed subprocess with the host's ambient filesystem permission.
pub const Kernel = struct {
    enabled: bool = false,
    max_output_bytes: u32 = 65536,
    cleanup_delay_ms: u32 = 5000,
    /// WASI-sandboxed CPython, from `scripts/setup-python-wasi.sh`. Absent at
    /// this path (the default; the script is opt-in), `runPythonCell` falls
    /// back to an unsandboxed host `python3` subprocess and logs a
    /// deprecation warning rather than refusing the call outright.
    python_wasi_binary: []const u8 = "vendor/python-wasi/bin/python-3.12.0.wasm",
    python_wasi_stdlib: []const u8 = "vendor/python-wasi/usr/local/lib",
    /// Instruction budget for the WASI engine, not wall-clock. Engine-specific
    /// units (interp: instructions; JIT: poll-site crossings); the default is
    /// generous enough for real stdlib imports (see the JIT smoke test).
    python_wasi_fuel: u64 = 5_000_000_000,
    python_wasi_timeout_ms: u32 = 30_000,
    python_wasi_max_memory_bytes: u64 = 256 * 1024 * 1024,
};

/// One DAP adapter command line (PRD 0017). The name is the table key
/// (`[debug.adapters.lldb]`).
pub const DebugAdapter = struct {
    name: []const u8 = "",
    command: []const []const u8 = &.{},
};

/// Debug Adapter Protocol client (PRD 0017). Off by default: an adapter is
/// an unsandboxed subprocess, same carve-out as `[kernel]`.
pub const Debug = struct {
    enabled: bool = false,
    disconnect_timeout_ms: u32 = 3000,
    launch_timeout_ms: u32 = 15_000,
    adapters: []const DebugAdapter = &.{},
};

/// First configured fallback, used by the pre-emptive vision router. Empty
/// when no chain is configured.
pub fn firstFallbackProvider(dirs: []const []const u8) []const u8 {
    return if (dirs.len > 0) dirs[0] else "";
}

/// First configured manifest directory, used by `plugins new` and similar
/// "write into one place" surfaces. An empty list is treated as the in-tree
/// default so a malformed config cannot strand the scaffolder.
pub fn firstToolsDir(dirs: []const []const u8) []const u8 {
    return if (dirs.len > 0) dirs[0] else "tools/manifests";
}

/// Comma-separated `tools_dir` list for diagnostics. One entry is returned
/// as-is so existing single-directory messages stay unchanged.
pub fn toolsDirDisplay(arena: std.mem.Allocator, dirs: []const []const u8) ![]const u8 {
    if (dirs.len == 0) return "(empty)";
    if (dirs.len == 1) return dirs[0];
    return std.mem.join(arena, ", ", dirs);
}

/// Which agent keys a config file actually set. Used so a partial
/// `config.local.toml` `"agent"` object does not replace the whole agent
/// struct (and reset `tools_dir` etc. to struct defaults).
pub const AgentFields = struct {
    max_iterations: bool = false,
    max_goal_turns: bool = false,
    compact_threshold_bytes: bool = false,
    tool_result_prune_bytes: bool = false,
    tool_result_prune_head_bytes: bool = false,
    tool_result_prune_tail_bytes: bool = false,
    repeat_tool_thresholds: bool = false,
    repeat_tool_exclude: bool = false,
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
    repl_exec_allow: bool = false,
    seed: bool = false,
    ask_timeout_seconds: bool = false,
    provider_check_timeout_seconds: bool = false,
    confirm_writes: bool = false,
    fallback_provider: bool = false,
    auto_thinking: bool = false,
    thinking_classifier_model: bool = false,
    thinking_classifier_timeout_ms: bool = false,
    worktree: bool = false,
    goal_worktree: bool = false,
    git_worktree_on: bool = false,
    isolated_cli: bool = false,
    isolated_tui: bool = false,
    isolated_webui: bool = false,
};

/// Who must approve a write-capable tool call before it runs.
pub const ConfirmWrites = enum { never, browser, always };

/// Default worktree isolation when the CLI flag is not given. `auto` keeps
/// each command kind's historical default (off for a plain run, on for
/// goal/scheduled runs); `yes`/`no` force a default for that kind.
pub const WorktreeDefault = enum { auto, yes, no };
/// A session kind a `git_worktree_on` entry can name.
pub const WorktreeMode = enum { run, goal, tui, webui };

pub const Improve = struct {
    /// null (or 0 in the file) means the engine sizes the context from the
    /// model's own window. A fixed number here overrides that, and a stale one
    /// silently keeps a 1M-window model on a 64 KiB diet.
    max_context_bytes: ?usize = null,
    /// Run the staged tree's task evals before promoting. They cost one agent
    /// run each, which is the price of noticing a patch that compiles, passes
    /// every unit test, and breaks a tool an agent depends on.
    capability_gate: bool = true,
    /// Run an advisory Arena match ("promote this proposal" vs "reject this
    /// proposal") before the capability evals, as a cheap early read.
    ///
    /// Advisory only, and deliberately so: the verdict is logged and can ride
    /// along with a real gate failure's feedback, but nothing consults it and it
    /// can never reject a proposal on its own. Making it a gate would hand a
    /// self-authored proposal a judge it could learn to persuade instead of a
    /// check it has to pass, which is the shortest path
    /// docs/prompts/self-improve-safety-review.md exists to catch. Off by
    /// default: it is several model calls per attempt.
    arena_advisory: bool = false,
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
    /// writes an exact-match patch blind in the same breath, the shape every
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
    /// Optional mesh allowlist key (PRD 0011). Empty = match JOIN by name.
    id: []const u8 = "",
};

/// Clanker mesh (PRD 0011). Off via `modules.mesh = false`. Listen lives
/// only in `clanker serve`.
pub const Mesh = struct {
    listen_host: []const u8 = "127.0.0.1",
    listen_port: u16 = 7420,
    ping_interval_seconds: u32 = 15,
    admission: []const u8 = "allowlist",
    max_members: u16 = 32,
    max_pending_joins: u16 = 8,
    prompt_timeout_seconds: u32 = 120,
    max_frame_bytes: u32 = 1 << 20,
    max_file_bytes: u32 = 32 << 20,
    file_chunk_bytes: u32 = 32 << 10,
};

/// Identity of this clanker instance.
pub const Instance = struct {
    name: []const u8 = "",
    id: []const u8 = "",
};

/// What `clanker serve` binds, for deployments that cannot pass flags on the
/// invocation (a systemd unit, a container image).
///
/// Every field is optional because absent has to stay distinguishable from
/// "set to the default": these are the weakest layer, and `CLANKER_HOST` /
/// `CLANKER_WEBUI_PORT` and then `--host` / `--webui-port` are each allowed to
/// override whatever this said. A non-optional field with a default would look
/// identical to one the operator wrote by hand and would win over the env.
pub const Serve = struct {
    /// The interface every listener binds. Shared rather than per-surface:
    /// the process binds one address, and a future second surface (an API
    /// port split out from the web UI) is expected to add its own *port* key
    /// next to `webui_port`, not its own host.
    host: ?[]const u8 = null,
    /// The port the web UI and its same-origin API answer on. Named for the
    /// surface, not the process, so another surface can be given its own
    /// port later without either key being ambiguous.
    webui_port: ?u16 = null,
    /// Hostnames the server may present itself as, the config-file spelling
    /// of the repeatable `--serve-as`. A TOML array, not a comma-separated
    /// string, so no name ever has to be escaped.
    serve_as: []const []const u8 = &.{},
    /// Mount the OpenAI/Anthropic compatibility proxy. Off by default so a
    /// stock `clanker serve` does not grow `/proxy/v1`. See PRD 0026.
    proxy: bool = false,
    /// Optional distinct listen port. Unset or equal to `webui_port`: the
    /// proxy shares the web UI socket at `/proxy/v1/*`. A different usable
    /// port: a second listener with `/v1/*` at the root.
    proxy_port: ?u16 = null,
    /// Name of the env var holding the optional local proxy token. Never a
    /// secret value in toml.
    proxy_token_env: ?[]const u8 = null,
    /// `client_facing_name = "provider/id"` map so a Cursor-style model
    /// string can hit a configured provider without a third catalog.
    /// json.ArrayHashMap rather than the raw map: harnessConfigJSON
    /// stringifies the whole Serve struct, and only the wrapper knows how.
    proxy_aliases: std.json.ArrayHashMap([]const u8) = .{},
    /// Seconds to wait for the first upstream body byte. Null means the
    /// 300s default. 0 means no ceiling.
    proxy_first_byte_timeout_s: ?u32 = null,
    /// Seconds of silence after the first byte. Null means the 60s default.
    /// 0 means no ceiling.
    proxy_idle_timeout_s: ?u32 = null,
};

/// Which `[serve]` keys a config file actually set. `proxy` is a real bool
/// defaulting to false, so absent and false look identical after parse;
/// merge copies it only when this bit is set (same as `ModulesFields`).
pub const ServeFields = struct {
    host: bool = false,
    webui_port: bool = false,
    serve_as: bool = false,
    proxy: bool = false,
    proxy_port: bool = false,
    proxy_token_env: bool = false,
    proxy_aliases: bool = false,
    proxy_first_byte_timeout_s: bool = false,
    proxy_idle_timeout_s: bool = false,
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
    /// Agent Client Protocol stdio server (`clanker acp`). Opt-in because it
    /// exposes a full agent, unlike MCP's tool-only surface.
    acp: bool = false,
    peers: bool = true,
    a2a: bool = true,
    webui: bool = true,
    graphs: bool = true,
    sessions: bool = true,
    goal: bool = true,
    /// Attach the newest active goal to a run automatically when no explicit
    /// `--goal <id>` is given. Set to false to run with the goal module on
    /// (explicit goals, `/goal`, tracking all still work) but without runs
    /// steering themselves toward the newest active goal.
    goal_auto_steer: bool = true,
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
    /// TCP peer mesh (PRD 0011). Off by default: serve binds a socket.
    mesh: bool = false,
};

/// Which keys inside `"modules"` were set when this Config was parsed. Used so
/// a partial `config.local.toml` `"modules"` object does not replace the whole
/// modules struct (and reset all flags to struct defaults).
pub const ModulesFields = struct {
    mcp: bool = false,
    acp: bool = false,
    peers: bool = false,
    a2a: bool = false,
    webui: bool = false,
    graphs: bool = false,
    sessions: bool = false,
    goal: bool = false,
    goal_auto_steer: bool = false,
    token_budget: bool = false,
    streaming: bool = false,
    dotenv: bool = false,
    hot_reload: bool = false,
    autolearn: bool = false,
    subagents: bool = false,
    rlm: bool = false,
    multimodal: bool = false,
    chatrooms: bool = false,
    token_stats: bool = false,
    mesh: bool = false,
};

/// Online-research web access. The sandbox denies network to a tool by
/// default: a tool reaches a host only when its descriptor names it
/// (`network_allow`) or the harness adds it from config (`network_from_config`).
/// This section is the config side of that second channel for the web/research
/// tools: every host listed here is added to `fetch_web` and `web_search`'s
/// allowlists at load, so granting a research site is a config edit, not a
/// manifest edit.
pub const Web = struct {
    /// Hostnames (no scheme, no path, matched against the URL's host) the
    /// research tools may reach. Default empty: out of the box the sandbox
    /// still lets a tool reach only its own `network_allow` hosts, which for
    /// `fetch_web` is a small static set. Adding a host here widens research
    /// without touching any manifest.
    allow: []const []const u8 = &.{},
};

/// REPL appearance. Only the mascot for now, which is why there is no
/// `theme` key here: the theme is still an env var (`CLANKER_THEME`) plus the
/// session-scoped `/theme`, and moving it would change behaviour rather than
/// just add a key.
pub const Tui = struct {
    /// `off`, `type`, `loop`, `place` or `input`. Kept as the raw string
    /// rather than the `tui/mascot.zig` enum so config.zig owes nothing to the
    /// TUI: an unparseable value is reported where the flag is resolved, next
    /// to the identical failure from `--mascot=<junk>`, instead of failing
    /// config load for every non-REPL subcommand.
    mascot: []const u8 = "off",
    /// `mini`, `xsmall`, `small`, `medium` or `large`. Empty means "not set",
    /// so the flag and then the built-in default decide -- and that default is
    /// per mode, so an empty value is not the same as writing "medium":
    /// `mascot = "input"` with no size gets `mini`, which is the size that
    /// fits the composer. Same raw-string reasoning as above.
    mascot_size: []const u8 = "",
    /// `default` or `inverted`. Empty means "not set", which is the same as
    /// `default`: the mode's natural pose. `inverted` mirrors it in every mode.
    mascot_facing: []const u8 = "",
    /// `0..10`. Null means "not set", which is the same as `5` (the regular
    /// pace). `0` never moves, `10` is the fastest.
    mascot_speed: ?u8 = null,
};

pub const TtsrRule = struct {
    name: []const u8 = "",
    pattern: []const u8 = "",
    inject: []const u8 = "",
    max_fires: u32 = 1,
};

pub const Ttsr = struct {
    max_retries_per_turn: u32 = 3,
    buffer_bytes: u32 = 4096,
    rules: []const TtsrRule = &.{},
};

/// Post-turn second-model critique. Off by default; fails open. Distinct
/// from `improve.arena_advisory`, which is a per-proposal Arena verdict
/// inside the improve engine.
pub const Advisor = struct {
    enabled: bool = false,
    provider: []const u8 = "",
    model: []const u8 = "",
    scope: []const u8 = "turn",
    context_turns: u32 = 3,
    timeout_ms: u32 = 5000,
};

pub const Hooks = struct {
    enabled: bool = false,
    config_path: []const u8 = "hooks.json",
    default_timeout_ms: u32 = 60_000,
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
    serve: Serve = .{},
    serve_fields: ServeFields = .{},
    notify: Notify = .{},
    tui: Tui = .{},
    advisor: Advisor = .{},
    hooks: Hooks = .{},
    ttsr: Ttsr = .{},
    kernel: Kernel = .{},
    debug: Debug = .{},
    mesh: Mesh = .{},
    chatrooms: Chatrooms = .{},
    memory: Memory = .{},
    modules: Modules = .{},
    modules_fields: ModulesFields = .{},
    modules_present: bool = false,
    chatrooms_present: bool = false,
    memory_present: bool = false,
    instance_present: bool = false,
    serve_present: bool = false,
    serve_as_present: bool = false,
    default_provider_present: bool = false,
    peers_present: bool = false,
    web_present: bool = false,
    notify_present: bool = false,
    tui_present: bool = false,
    advisor_present: bool = false,
    hooks_present: bool = false,
    ttsr_present: bool = false,
    kernel_present: bool = false,
    debug_present: bool = false,
    mesh_present: bool = false,
    /// Path of the file that set `default_provider`, as actually read. Null
    /// means no config named one and the struct fallback above is in force.
    /// Reported by `providers check`: "the default is X" is not much use
    /// without "because Y says so", since the base file and the local override
    /// disagree by design.
    default_provider_from: ?[]const u8 = null,

    pub fn provider(self: *const Config, name: ?[]const u8) !*const Provider {
        const want = name orelse self.default_provider;
        return self.providers.getPtr(want) orelse error.UnknownProvider;
    }

    /// The provider named by `--provider` (or the config default), with
    /// `--model` applied as a one-off override of its `default_model`.
    ///
    /// `--model <provider>/<model>` picks both at once, so `--model
    /// moonshotai/kimi-k3` needs no separate `--provider`. The prefix is
    /// only read as a provider when config actually has one by that name
    /// and `--provider` was not given: a model id can contain a slash of
    /// its own (`zai/glm-5.2` on a router), and splitting those would send
    /// a request for a model that does not exist to a provider that does
    /// not either.
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
        if (!diagnostics_suppressed) last_load_diagnostic = false;
        const base = (try loadFile(io, arena, dir, file_name, .required)).?;
        var cfg = base.cfg;
        if (cfg.default_provider_present) cfg.default_provider_from = base.path;
        if (try loadFile(io, arena, dir, local_file_name, .optional)) |local| {
            try merge(&cfg, local.cfg, arena);
            // Applied after merge so a local `[models."..."]` entry can override
            // or add models even when `[providers.<name>]` replaced the base entry.
            if (local.models_table) |models| try distributeModels(arena, &cfg, models);
            // merge() only takes default_provider when the local file named
            // one, so the provenance has to move on exactly the same condition.
            if (local.cfg.default_provider_present) cfg.default_provider_from = local.path;
        }
        // Checked on the merged result rather than per file. A local override
        // that only sets, say, `default_provider` has no "providers" section by
        // design, and warning about it points at a config that is in fact fine.
        if (cfg.providers.count() > 0) try validateProviderModels(&cfg);
        applyCatalogSpecs(io, arena, dir, &cfg);
        if (cfg.providers.count() == 0) {
            log.log(.warn, "config {s}: no providers defined", .{base.path});
        } else if (cfg.providers.get(cfg.default_provider) == null) {
            // Otherwise a typo'd default_provider loads clean and only fails
            // on the first chat request, far from the config that caused it.
            log.log(.error_, "default_provider '{s}' is not in \"providers\"", .{cfg.default_provider});
            return error.DefaultProviderUnknown;
        }
        try validateToolResultPrune(cfg.agent);
        try validateRepeatToolThresholds(cfg.agent.repeat_tool_thresholds);
        // First boot: neither file named an instance, so `cfg.instance.name`
        // is the pid-seeded fallback from `defaultInstName`, which would pick
        // a *different* name next launch. Persist it once so the instance
        // keeps a stable identity (mesh, chat, run logs) across restarts.
        // Best-effort: a read-only checkout keeps working off the in-memory
        // fallback, it just re-rolls the name every launch.
        if (!cfg.instance_present) {
            persistInstanceName(io, arena, dir, local_file_name, cfg.instance.name);
        }
        return cfg;
    }

    /// Appends an `[instance]` table naming `name` to `local_file_name`,
    /// creating the file if absent. Swallows errors: this only runs on the
    /// happy path of "no instance configured yet", never something a caller
    /// should have to handle to get a working `Config`.
    fn persistInstanceName(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir, local_file_name: []const u8, name: []const u8) void {
        const existing = dir.readFileAlloc(io, local_file_name, arena, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return,
        };
        const sep = if (existing.len == 0 or std.mem.endsWith(u8, existing, "\n\n"))
            ""
        else if (std.mem.endsWith(u8, existing, "\n"))
            "\n"
        else
            "\n\n";
        const content = std.fmt.allocPrint(arena, "{s}{s}[instance]\nname = \"{s}\"\n", .{
            existing,
            sep,
            name,
        }) catch return;
        atomic_write.writeFile(io, dir, local_file_name, content) catch |err| {
            log.log(.warn, "config: could not persist instance name to {s}: {s}", .{ local_file_name, @errorName(err) });
        };
    }

    /// The startup dotenv probe needs to know whether `[modules] dotenv` is
    /// enabled, but the command that follows owns the operator-facing error.
    /// Suppressing this speculative read prevents printing every diagnostic
    /// twice when configuration is invalid.
    pub fn loadQuiet(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir, file_name: []const u8, local_file_name: []const u8) !Config {
        const prior = diagnostics_suppressed;
        diagnostics_suppressed = true;
        defer diagnostics_suppressed = prior;
        return load(io, arena, dir, file_name, local_file_name);
    }

    /// Returns and clears the operator-facing diagnostic emitted by the most
    /// recent load on this thread. The CLI uses this to avoid appending a bare
    /// implementation error name after an actionable configuration report.
    pub fn takeLoadDiagnostic() bool {
        const had_diagnostic = last_load_diagnostic;
        last_load_diagnostic = false;
        return had_diagnostic;
    }

    fn validateToolResultPrune(agent: Agent) !void {
        if (agent.tool_result_prune_bytes == 0) return;
        const kept = agent.tool_result_prune_head_bytes + @import("agent/prune.zig").marker.len + agent.tool_result_prune_tail_bytes;
        if (kept < agent.tool_result_prune_bytes) return;
        log.log(.error_, "agent tool-result pruning keeps {d} bytes but threshold is {d}", .{ kept, agent.tool_result_prune_bytes });
        return error.InvalidToolResultPruneConfig;
    }

    fn validateRepeatToolThresholds(thresholds: []const u32) !void {
        if (thresholds.len == 0) {
            log.log(.error_, "agent.repeat_tool_thresholds must not be empty", .{});
            return error.InvalidRepeatToolThresholds;
        }
        for (thresholds, 0..) |threshold, i| {
            if (threshold < 2) {
                log.log(.error_, "agent.repeat_tool_thresholds value {d} must be at least 2", .{threshold});
                return error.InvalidRepeatToolThresholds;
            }
            for (thresholds[0..i]) |previous| if (previous == threshold) {
                log.log(.error_, "agent.repeat_tool_thresholds contains duplicate value {d}", .{threshold});
                return error.InvalidRepeatToolThresholds;
            };
        }
    }

    const LoadMode = enum { required, optional };

    /// A parsed config file plus the path it came from, kept so
    /// default_provider provenance can name its source file. For the optional
    /// local file, `models_table` is deferred: entries are applied onto the
    /// merged base config in `load()` so a checkout-private file can add models
    /// without repeating every `[providers.<name>]` stanza.
    const Loaded = struct {
        cfg: Config,
        path: []const u8,
        models_table: ?json.Value = null,
    };

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
        var parse_line: ?usize = null;
        const root = toml_bridge.parseToJsonValueAtLine(arena, raw, &parse_line) catch |err| {
            logTomlSyntaxError(file_name, parse_line, err);
            return err;
        };
        const obj = switch (root) {
            .object => |o| o,
            else => return error.ConfigNotObject,
        };
        const prior_source = diagnostic_source;
        const prior_scope = diagnostic_scope;
        const prior_emitted = diagnostic_emitted;
        diagnostic_source = .{ .file_name = file_name, .raw = raw };
        diagnostic_scope = "";
        diagnostic_emitted = false;
        defer {
            diagnostic_source = prior_source;
            diagnostic_scope = prior_scope;
            diagnostic_emitted = prior_emitted;
        }
        var cfg = parseConfig(arena, root) catch |err| {
            // Every helper below emits a detailed error at the field that
            // rejected the value. This fallback protects a new validation
            // path from regressing to an opaque error while it is being added.
            if (!diagnostic_emitted) logUndiagnosedError(err);
            return err;
        };
        const models_table = obj.get("models");
        if (mode == .required) {
            if (models_table) |models| try distributeModels(arena, &cfg, models);
        }
        return .{
            .cfg = cfg,
            .path = file_name,
            .models_table = if (mode == .optional) models_table else null,
        };
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
            "serve",            "tui",      "advisor", "hooks",
            "ttsr",             "kernel",   "debug",   "mesh",
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
        if (obj.get("advisor")) |v| {
            cfg.advisor = try parseAdvisor(v);
            cfg.advisor_present = true;
        }
        if (obj.get("hooks")) |v| {
            cfg.hooks = try parseHooks(v);
            cfg.hooks_present = true;
        }
        if (obj.get("ttsr")) |v| {
            cfg.ttsr = try parseTtsr(arena, v);
            cfg.ttsr_present = true;
        }
        if (obj.get("kernel")) |v| {
            cfg.kernel = try parseKernel(v);
            cfg.kernel_present = true;
        }
        if (obj.get("debug")) |v| {
            cfg.debug = try parseDebug(arena, v);
            cfg.debug_present = true;
        }
        if (obj.get("mesh")) |v| {
            cfg.mesh = try parseMesh(v);
            cfg.mesh_present = true;
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
            cfg.instance_present = true;
        } else {
            // Only a fallback when nothing parsed one yet: a later local file
            // without an "instance" section must not clobber a named instance
            // with a pid-based default (merge() checks instance_present).
            if (!cfg.instance_present) cfg.instance.name = try defaultInstName(arena);
        }
        if (obj.get("serve")) |v| {
            const parsed = try parseServe(arena, v);
            cfg.serve = parsed.serve;
            cfg.serve_fields = parsed.fields;
            cfg.serve_present = true;
            cfg.serve_as_present = parsed.fields.serve_as;
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
        if (obj.get("tui")) |v| {
            cfg.tui = try parseTui(arena, v);
            cfg.tui_present = true;
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
            const parsed = try parseModules(arena, v);
            cfg.modules = parsed.modules;
            cfg.modules_fields = parsed.fields;
            cfg.modules_present = true;
        }
        return cfg;
    }

    fn parseProvider(name: []const u8, v: json.Value) !Provider {
        const prior_scope = diagnostic_scope;
        diagnostic_scope = "providers";
        defer diagnostic_scope = prior_scope;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.ProviderNotObject,
        };
        var p = Provider{
            .name = name,
            .base_url = try jsonStr(try required(obj, "base_url", "providers.<name>.base_url", "base_url = \"https://api.example.com\""), "providers.<name>.base_url"),
        };
        warnUnknownKeys(obj, &.{
            "base_url",
            "kind",
            "project",
            "location",
            "api_key_env",
            "auth",
            "service_account_file",
            "path",
            "default_model",
            "rpm",
            "check_timeout_seconds",
            // Legacy names: flagged with a dedicated error below, not a warning.
            "model",
            "models",
            "max_tokens",
            "context_window",
            "temperature",
            "top_p",
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
            const env_name = try jsonStr(k, "api_key_env");
            if (env_name.len == 0) {
                log.log(.error_, "provider '{s}': \"api_key_env\" must name a non-empty environment variable", .{name});
                return error.ApiKeyEnvEmpty;
            }
            p.api_key_env = env_name;
        }
        if (obj.get("auth")) |k| {
            const s = try jsonStr(k, "auth");
            p.auth = AuthStrategy.fromStr(s) orelse {
                log.log(.error_, "provider '{s}': unknown auth \"{s}\" (expected \"api_key\", \"oauth_static\" or \"oauth_refresh\")", .{ name, s });
                return error.UnknownAuthStrategy;
            };
        }
        if (obj.get("path")) |k| {
            p.path = try jsonStr(k, "path");
        }
        if (obj.get("api_version")) |k| {
            p.api_version = try jsonStr(k, "api_version");
        }
        if (obj.get("default_model")) |k| {
            p.default_model = try jsonStr(k, "default_model");
        }
        if (obj.get("rpm")) |k| {
            p.rpm = try jsonUnsigned(u32, k, "rpm");
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

        // vertex / vertex_anthropic address the model by project/location in
        // the URL. Missing those only surfaces as error.VertexProjectMissing
        // on the first request, far from the config that caused it. A
        // credential file is optional at load: minting also reads gcloud ADC.
        if (p.kind == .vertex_anthropic or p.kind == .vertex) {
            if (p.project.len == 0 or p.location.len == 0) {
                log.log(.error_, "provider '{s}': kind \"{s}\" requires \"project\" and \"location\"", .{ name, @tagName(p.kind) });
                return error.VertexProjectMissing;
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
            const provider_name = try jsonStr(try required(entry_obj, "provider", "models.<name>.provider", "provider = \"provider-name\""), "models.<name>.provider");
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
            var model_it = p.models.iterator();
            while (model_it.next()) |mkv| {
                try validateModelParams(name, mkv.key_ptr.*, mkv.value_ptr.*);
            }
        }
    }

    /// Fill unset model specs from the models.dev snapshot in `dir`. A
    /// written `context_window` / `max_tokens` / cost / capabilities /
    /// display wins. Missing snapshot is a no-op: load never downloads.
    fn applyCatalogSpecs(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir, cfg: *Config) void {
        const body = models_dev.readLocal(io, dir, arena) orelse return;
        const catalog = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{ .ignore_unknown_fields = true }) catch return;
        var it = cfg.providers.iterator();
        while (it.next()) |pkv| {
            const p = pkv.value_ptr;
            const cat_p = models_dev.findProvider(catalog, p.name, p.base_url, p.api_key_env) orelse continue;
            var mit = p.models.iterator();
            while (mit.next()) |mkv| {
                const key = mkv.key_ptr.*;
                const m = mkv.value_ptr;
                const sku = m.wireName(key);
                const cat_m = models_dev.findModel(cat_p, sku) orelse models_dev.findModel(cat_p, key) orelse continue;
                const spec = models_dev.specs(arena, cat_m) catch continue;
                if (!m.context_window_set) {
                    if (spec.context_window) |c| m.context_window = c;
                }
                if (!m.max_tokens_set) {
                    if (spec.max_tokens) |t| m.max_tokens = t;
                }
                if (m.cost_per_1m_input == null) m.cost_per_1m_input = spec.cost_per_1m_input;
                if (m.cost_per_1m_output == null) m.cost_per_1m_output = spec.cost_per_1m_output;
                if (m.display == null) m.display = spec.display;
                if (m.capabilities.len == 0 and spec.capabilities.len > 0) m.capabilities = spec.capabilities;
            }
        }
    }

    fn validateModelParams(provider_name: []const u8, model_name: []const u8, m: Model) !void {
        if (m.temperature) |t| {
            if (t < 0 or t > 2) {
                log.log(.error_, "models[\"{s}/{s}\"]: temperature {d} is outside 0..2", .{ provider_name, model_name, t });
                return error.ModelTemperatureOutOfRange;
            }
        }
        if (m.top_p) |p| {
            if (p < 0 or p > 1) {
                log.log(.error_, "models[\"{s}/{s}\"]: top_p {d} is outside 0..1", .{ provider_name, model_name, p });
                return error.ModelTopPOutOfRange;
            }
        }
        if (m.cost_per_1m_input) |c| {
            if (c < 0) {
                log.log(.error_, "models[\"{s}/{s}\"]: cost_per_1m_input must be >= 0", .{ provider_name, model_name });
                return error.ModelCostOutOfRange;
            }
        }
        if (m.cost_per_1m_output) |c| {
            if (c < 0) {
                log.log(.error_, "models[\"{s}/{s}\"]: cost_per_1m_output must be >= 0", .{ provider_name, model_name });
                return error.ModelCostOutOfRange;
            }
        }
    }

    fn parseModel(arena: std.mem.Allocator, name: []const u8, v: json.Value) !Model {
        const prior_scope = diagnostic_scope;
        diagnostic_scope = "models";
        defer diagnostic_scope = prior_scope;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.ModelNotObject,
        };
        var m = Model{};
        warnUnknownKeys(obj, &.{
            // "provider" is consumed by distributeModels (which provider this
            // entry belongs to, before the table-key prefix is stripped down
            // to the bare model name passed in here), accepted, not unknown.
            "provider",
            "id",
            "context_window",
            "max_tokens",
            "temperature",
            "top_p",
            "reasoning_effort",
            "display",
            "cost_per_1m_input",
            "cost_per_1m_output",
            "capabilities",
            "category",
            "rpm",
        }, name);
        if (obj.get("id")) |k| m.id = try jsonStr(k, "id");
        if (obj.get("context_window")) |k| {
            m.context_window = try jsonUnsigned(u32, k, "context_window");
            m.context_window_set = true;
        }
        if (obj.get("max_tokens")) |k| {
            m.max_tokens = try jsonUnsigned(u32, k, "max_tokens");
            m.max_tokens_set = true;
        }
        if (obj.get("temperature")) |k| m.temperature = try jsonFloat(k, "temperature");
        if (obj.get("top_p")) |k| m.top_p = try jsonFloat(k, "top_p");
        if (obj.get("reasoning_effort")) |k| {
            const s = try jsonStr(k, "reasoning_effort");
            m.reasoning_effort = ReasoningEffort.fromStr(s) orelse {
                log.log(.error_, "models[\"{s}\"]: reasoning_effort \"{s}\" is not one of \"none\", \"low\", \"medium\", \"high\", \"max\"", .{ name, s });
                return error.UnknownReasoningEffort;
            };
        }
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
        if (obj.get("category")) |k| m.category = try jsonStr(k, "category");
        if (obj.get("rpm")) |k| m.rpm = try jsonUnsigned(u32, k, "rpm");
        return m;
    }

    fn parseInstance(arena: std.mem.Allocator, v: json.Value) !Instance {
        const prior_scope = diagnostic_scope;
        diagnostic_scope = "instance";
        defer diagnostic_scope = prior_scope;
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

    fn parseServe(arena: std.mem.Allocator, v: json.Value) !struct { serve: Serve, fields: ServeFields } {
        const prior_scope = diagnostic_scope;
        diagnostic_scope = "serve";
        defer diagnostic_scope = prior_scope;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.ServeNotObject,
        };
        var s = Serve{};
        var f = ServeFields{};
        warnUnknownKeys(obj, &.{
            "host",
            "webui_port",
            "serve_as",
            "proxy",
            "proxy_port",
            "proxy_token_env",
            "proxy_aliases",
            "proxy_first_byte_timeout_s",
            "proxy_idle_timeout_s",
        }, "serve");
        if (obj.get("host")) |k| {
            s.host = try jsonStr(k, "host");
            f.host = true;
        }
        if (obj.get("webui_port")) |k| {
            const n = try jsonInt(k, "webui_port");
            // Caught here rather than at bind time: a config that cannot be
            // honoured should say so while it is being read, naming the key.
            if (n < 1 or n > 65535) return error.ServePortOutOfRange;
            s.webui_port = @intCast(n);
            f.webui_port = true;
        }
        if (obj.get("serve_as")) |k| {
            const arr = switch (k) {
                .array => |a| a,
                else => return error.ServeAsNotArray,
            };
            var names: std.ArrayList([]const u8) = .empty;
            for (arr.items) |item| {
                const name = std.mem.trim(u8, try jsonStr(item, "serve_as[]"), " \t");
                if (name.len > 0) try names.append(arena, name);
            }
            s.serve_as = try names.toOwnedSlice(arena);
            f.serve_as = true;
        }
        if (obj.get("proxy")) |k| {
            s.proxy = try jsonBool(k, "proxy");
            f.proxy = true;
        }
        if (obj.get("proxy_port")) |k| {
            const n = try jsonInt(k, "proxy_port");
            if (n < 1 or n > 65535) return error.ServePortOutOfRange;
            s.proxy_port = @intCast(n);
            f.proxy_port = true;
        }
        if (obj.get("proxy_token_env")) |k| {
            s.proxy_token_env = try jsonStr(k, "proxy_token_env");
            f.proxy_token_env = true;
        }
        if (obj.get("proxy_aliases")) |k| {
            const o = switch (k) {
                .object => |m| m,
                else => return error.ProxyAliasesNotObject,
            };
            var map: std.json.ArrayHashMap([]const u8) = .{};
            var it = o.iterator();
            while (it.next()) |kv| {
                try map.map.put(arena, kv.key_ptr.*, try jsonStr(kv.value_ptr.*, "proxy_aliases"));
            }
            s.proxy_aliases = map;
            f.proxy_aliases = true;
        }
        if (obj.get("proxy_first_byte_timeout_s")) |k| {
            s.proxy_first_byte_timeout_s = try jsonUnsigned(u32, k, "proxy_first_byte_timeout_s");
            f.proxy_first_byte_timeout_s = true;
        }
        if (obj.get("proxy_idle_timeout_s")) |k| {
            s.proxy_idle_timeout_s = try jsonUnsigned(u32, k, "proxy_idle_timeout_s");
            f.proxy_idle_timeout_s = true;
        }
        return .{ .serve = s, .fields = f };
    }

    fn applyServeFields(dst: *Serve, src: Serve, fields: ServeFields) void {
        if (fields.host) dst.host = src.host;
        if (fields.webui_port) dst.webui_port = src.webui_port;
        if (fields.serve_as) dst.serve_as = src.serve_as;
        if (fields.proxy) dst.proxy = src.proxy;
        if (fields.proxy_port) dst.proxy_port = src.proxy_port;
        if (fields.proxy_token_env) dst.proxy_token_env = src.proxy_token_env;
        if (fields.proxy_aliases) dst.proxy_aliases = src.proxy_aliases;
        if (fields.proxy_first_byte_timeout_s) dst.proxy_first_byte_timeout_s = src.proxy_first_byte_timeout_s;
        if (fields.proxy_idle_timeout_s) dst.proxy_idle_timeout_s = src.proxy_idle_timeout_s;
    }

    fn parsePeers(arena: std.mem.Allocator, v: json.Value) ![]const Peer {
        const prior_scope = diagnostic_scope;
        diagnostic_scope = "peers[]";
        defer diagnostic_scope = prior_scope;
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
            warnUnknownKeys(obj, &.{ "name", "url", "id" }, "peers[]");
            try out.append(arena, .{
                .name = try jsonStr(try required(obj, "name", "peers[].name", "name = \"peer-name\""), "peers[].name"),
                .url = try jsonStr(try required(obj, "url", "peers[].url", "url = \"https://peer.example.com\""), "peers[].url"),
                .id = if (obj.get("id")) |iv| try jsonStr(iv, "peers[].id") else "",
            });
        }
        return out.toOwnedSlice(arena);
    }

    fn parseWeb(arena: std.mem.Allocator, v: json.Value) !Web {
        const prior_scope = diagnostic_scope;
        diagnostic_scope = "web";
        defer diagnostic_scope = prior_scope;
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
                if (!isBareHost(host)) {
                    log.log(.error_, "web.allow entry \"{s}\" must be a bare hostname or glob (no scheme, path, port, or spaces)", .{host});
                    return error.WebAllowHostInvalid;
                }
                try allow.append(arena, host);
            }
            web.allow = try allow.toOwnedSlice(arena);
        }
        return web;
    }

    /// `ck_http` compares this string (possibly a glob pattern) with the
    /// parsed URL hostname, so a URL, path, or host:port entry would never
    /// grant the intended access. `*` and `?` are wildcards (any run / single
    /// character), so patterns like `*.example.com` and the catch-all `*` are
    /// valid.
    fn isBareHost(host: []const u8) bool {
        return host.len > 0 and std.mem.findAny(u8, host, ":/#@% \t\r\n") == null;
    }

    fn parseNotify(arena: std.mem.Allocator, v: json.Value) !Notify {
        const prior_scope = diagnostic_scope;
        diagnostic_scope = "notify";
        defer diagnostic_scope = prior_scope;
        _ = arena;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.NotifyNotObject,
        };
        var n = Notify{};
        warnUnknownKeys(obj, &.{ "on", "topic" }, "notify");
        if (obj.get("on")) |k| n.on = try jsonBool(k, "on");
        if (obj.get("topic")) |k| n.topic = try jsonStr(k, "topic");
        return n;
    }

    fn parseTui(arena: std.mem.Allocator, v: json.Value) !Tui {
        const prior_scope = diagnostic_scope;
        diagnostic_scope = "tui";
        defer diagnostic_scope = prior_scope;
        _ = arena;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.TuiNotObject,
        };
        var t = Tui{};
        warnUnknownKeys(obj, &.{ "mascot", "mascot_size", "mascot_facing", "mascot_speed" }, "tui");
        if (obj.get("mascot")) |k| t.mascot = try jsonStr(k, "mascot");
        if (obj.get("mascot_size")) |k| t.mascot_size = try jsonStr(k, "mascot_size");
        if (obj.get("mascot_facing")) |k| t.mascot_facing = try jsonStr(k, "mascot_facing");
        if (obj.get("mascot_speed")) |k| {
            const speed = try jsonUnsigned(u8, k, "mascot_speed");
            if (speed > 10) return error.MascotSpeedOutOfRange;
            t.mascot_speed = speed;
        }
        return t;
    }

    fn parseChatrooms(arena: std.mem.Allocator, v: json.Value) !Chatrooms {
        const prior_scope = diagnostic_scope;
        diagnostic_scope = "chatrooms";
        defer diagnostic_scope = prior_scope;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.ChatroomsNotObject,
        };
        var c = Chatrooms{};
        warnUnknownKeys(obj, &.{ "on", "rooms", "max_history" }, "chatrooms");
        if (obj.get("on")) |k| c.on = try jsonBool(k, "on");
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
        if (obj.get("max_history")) |k| c.max_history = try jsonUnsigned(u32, k, "max_history");
        return c;
    }

    fn defaultInstName(arena: std.mem.Allocator) ![]const u8 {
        var seed: u64 = @as(u64, @intCast(std.c.getpid())) *% 0x9e3779b97f4a7c15;
        var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        if (std.posix.gethostname(&host_buf)) |host| {
            for (host) |ch| seed ^= std.hash.Wyhash.hash(0, &[_]u8{ch});
        } else |_| {}
        seed ^= std.hash.Wyhash.hash(0, std.mem.asBytes(&seed));
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
        const prior_scope = diagnostic_scope;
        diagnostic_scope = "agent";
        defer diagnostic_scope = prior_scope;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.AgentNotObject,
        };
        var a = Agent{};
        var f = AgentFields{};
        warnUnknownKeys(obj, &.{
            "max_iterations",               "max_goal_turns",                 "compact_threshold_bytes",        "tool_result_prune_bytes",
            "tool_result_prune_head_bytes", "tool_result_prune_tail_bytes",   "repeat_tool_thresholds",         "repeat_tool_exclude",
            "max_total_tokens",             "max_tokens_per_turn",            "max_history_tokens",             "tool_catalog",
            "hot_tools",                    "tools_dir",                      "skills_dir",                     "system_prompt_file",
            "learnings_file",               "global_instructions_file",       "state_dir",                      "sandbox_root",
            "workflows_dir",                "chains_dir",                     "git_commit",                     "git_remote_ops",
            "exec_pattern_allow",           "repl_exec_allow",                "seed",                           "ask_timeout_seconds",
            "confirm_writes",               "provider_check_timeout_seconds", "fallback_provider",              "fallback_providers",
            "auto_thinking",                "thinking_classifier_model",      "thinking_classifier_timeout_ms", "worktree",
            "goal_worktree",                "git_worktree_on",                "isolated_cli",                   "isolated_tui",
            "isolated_webui",
        }, "agent");
        if (obj.get("max_iterations")) |k| {
            a.max_iterations = try jsonUnsigned(u32, k, "max_iterations");
            f.max_iterations = true;
        }
        if (obj.get("max_goal_turns")) |k| {
            a.max_goal_turns = try jsonUnsigned(u32, k, "max_goal_turns");
            f.max_goal_turns = true;
        }
        if (obj.get("compact_threshold_bytes")) |k| {
            a.compact_threshold_bytes = try jsonUnsigned(usize, k, "compact_threshold_bytes");
            f.compact_threshold_bytes = true;
        }
        if (obj.get("tool_result_prune_bytes")) |k| {
            a.tool_result_prune_bytes = try jsonUnsigned(usize, k, "tool_result_prune_bytes");
            f.tool_result_prune_bytes = true;
        }
        if (obj.get("tool_result_prune_head_bytes")) |k| {
            a.tool_result_prune_head_bytes = try jsonUnsigned(usize, k, "tool_result_prune_head_bytes");
            f.tool_result_prune_head_bytes = true;
        }
        if (obj.get("tool_result_prune_tail_bytes")) |k| {
            a.tool_result_prune_tail_bytes = try jsonUnsigned(usize, k, "tool_result_prune_tail_bytes");
            f.tool_result_prune_tail_bytes = true;
        }
        if (obj.get("repeat_tool_thresholds")) |k| {
            const values = switch (k) {
                .array => |items| items,
                else => return error.RepeatToolThresholdsNotArray,
            };
            var thresholds: std.ArrayList(u32) = .empty;
            for (values.items) |item| {
                const n = switch (item) {
                    .integer => |value| value,
                    .number_string => |value| std.fmt.parseInt(i64, value, 10) catch return error.RepeatToolThresholdNotInteger,
                    else => return error.RepeatToolThresholdNotInteger,
                };
                if (n < 0 or n > std.math.maxInt(u32)) return error.RepeatToolThresholdNotInteger;
                try thresholds.append(arena, @intCast(n));
            }
            a.repeat_tool_thresholds = try thresholds.toOwnedSlice(arena);
            f.repeat_tool_thresholds = true;
        }
        if (obj.get("repeat_tool_exclude")) |k| {
            a.repeat_tool_exclude = try jsonNameList(arena, k, "repeat_tool_exclude");
            f.repeat_tool_exclude = true;
        }
        if (obj.get("max_total_tokens")) |k| {
            a.max_total_tokens = try jsonUnsigned(u32, k, "max_total_tokens");
            f.max_total_tokens = true;
        }
        if (obj.get("max_tokens_per_turn")) |k| {
            a.max_tokens_per_turn = try jsonUnsigned(u32, k, "max_tokens_per_turn");
            f.max_tokens_per_turn = true;
        }
        if (obj.get("max_history_tokens")) |k| {
            a.max_history_tokens = try jsonUnsigned(u32, k, "max_history_tokens");
            f.max_history_tokens = true;
        }
        if (obj.get("tools_dir")) |k| {
            a.tools_dir = try jsonToolsDir(arena, k);
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
            a.git_commit = try jsonBool(k, "git_commit");
            f.git_commit = true;
        }
        if (obj.get("git_remote_ops")) |k| {
            a.git_remote_ops = try jsonBool(k, "git_remote_ops");
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
        if (obj.get("repl_exec_allow")) |k| {
            const arr = switch (k) {
                .array => |ar| ar,
                else => return error.ReplExecAllowNotArray,
            };
            var cmds: std.ArrayList([]const u8) = .empty;
            for (arr.items) |item| {
                const cmd = try jsonStr(item, "repl_exec_allow[]");
                if (cmd.len == 0) return error.ReplExecAllowEmpty;
                try cmds.append(arena, cmd);
            }
            a.repl_exec_allow = try cmds.toOwnedSlice(arena);
            f.repl_exec_allow = true;
        }
        if (obj.get("tool_catalog")) |k| {
            a.tool_catalog = try jsonBool(k, "tool_catalog");
            f.tool_catalog = true;
        }
        if (obj.get("hot_tools")) |k| {
            a.hot_tools = try jsonUnsigned(u32, k, "hot_tools");
            f.hot_tools = true;
        }
        if (obj.get("seed")) |k| {
            a.seed = try jsonUnsigned(u64, k, "seed");
            f.seed = true;
        }
        if (obj.get("ask_timeout_seconds")) |k| {
            a.ask_timeout_seconds = try jsonUnsigned(u32, k, "ask_timeout_seconds");
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
        if (obj.get("fallback_providers") orelse obj.get("fallback_provider")) |k| {
            a.fallback_providers = try jsonNameList(arena, k, "fallback_provider");
            f.fallback_provider = true;
        }
        if (obj.get("auto_thinking")) |k| {
            a.auto_thinking = try jsonBool(k, "auto_thinking");
            f.auto_thinking = true;
        }
        if (obj.get("thinking_classifier_model")) |k| {
            a.thinking_classifier_model = try jsonStr(k, "thinking_classifier_model");
            f.thinking_classifier_model = true;
        }
        if (obj.get("thinking_classifier_timeout_ms")) |k| {
            a.thinking_classifier_timeout_ms = try jsonUnsigned(u32, k, "thinking_classifier_timeout_ms");
            f.thinking_classifier_timeout_ms = true;
        }
        if (obj.get("worktree")) |k| {
            const s = try jsonStr(k, "worktree");
            a.worktree = std.meta.stringToEnum(WorktreeDefault, s) orelse
                return error.WorktreeDefaultInvalid;
            f.worktree = true;
        }
        if (obj.get("goal_worktree")) |k| {
            const s = try jsonStr(k, "goal_worktree");
            a.goal_worktree = std.meta.stringToEnum(WorktreeDefault, s) orelse
                return error.GoalWorktreeDefaultInvalid;
            f.goal_worktree = true;
        }
        if (obj.get("git_worktree_on")) |k| {
            const names = try jsonNameList(arena, k, "git_worktree_on");
            const modes = try arena.alloc(WorktreeMode, names.len);
            for (names, 0..) |s, i| {
                modes[i] = std.meta.stringToEnum(WorktreeMode, s) orelse
                    return error.WorktreeModeInvalid;
            }
            a.git_worktree_on = modes;
            f.git_worktree_on = true;
        }
        if (obj.get("isolated_cli")) |k| {
            a.isolated_cli = try jsonBool(k, "isolated_cli");
            f.isolated_cli = true;
        }
        if (obj.get("isolated_tui")) |k| {
            a.isolated_tui = try jsonBool(k, "isolated_tui");
            f.isolated_tui = true;
        }
        if (obj.get("isolated_webui")) |k| {
            a.isolated_webui = try jsonBool(k, "isolated_webui");
            f.isolated_webui = true;
        }
        return .{ .agent = a, .fields = f };
    }

    fn applyAgentFields(dst: *Agent, src: Agent, fields: AgentFields) void {
        if (fields.max_iterations) dst.max_iterations = src.max_iterations;
        if (fields.max_goal_turns) dst.max_goal_turns = src.max_goal_turns;
        if (fields.compact_threshold_bytes) dst.compact_threshold_bytes = src.compact_threshold_bytes;
        if (fields.tool_result_prune_bytes) dst.tool_result_prune_bytes = src.tool_result_prune_bytes;
        if (fields.tool_result_prune_head_bytes) dst.tool_result_prune_head_bytes = src.tool_result_prune_head_bytes;
        if (fields.tool_result_prune_tail_bytes) dst.tool_result_prune_tail_bytes = src.tool_result_prune_tail_bytes;
        if (fields.repeat_tool_thresholds) dst.repeat_tool_thresholds = src.repeat_tool_thresholds;
        if (fields.repeat_tool_exclude) dst.repeat_tool_exclude = src.repeat_tool_exclude;
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
        if (fields.repl_exec_allow) dst.repl_exec_allow = src.repl_exec_allow;
        if (fields.seed) dst.seed = src.seed;
        if (fields.ask_timeout_seconds) dst.ask_timeout_seconds = src.ask_timeout_seconds;
        if (fields.provider_check_timeout_seconds) dst.provider_check_timeout_seconds = src.provider_check_timeout_seconds;
        if (fields.confirm_writes) dst.confirm_writes = src.confirm_writes;
        if (fields.fallback_provider) dst.fallback_providers = src.fallback_providers;
        if (fields.auto_thinking) dst.auto_thinking = src.auto_thinking;
        if (fields.thinking_classifier_model) dst.thinking_classifier_model = src.thinking_classifier_model;
        if (fields.thinking_classifier_timeout_ms) dst.thinking_classifier_timeout_ms = src.thinking_classifier_timeout_ms;
        if (fields.worktree) dst.worktree = src.worktree;
        if (fields.goal_worktree) dst.goal_worktree = src.goal_worktree;
        if (fields.git_worktree_on) dst.git_worktree_on = src.git_worktree_on;
        if (fields.isolated_cli) dst.isolated_cli = src.isolated_cli;
        if (fields.isolated_tui) dst.isolated_tui = src.isolated_tui;
        if (fields.isolated_webui) dst.isolated_webui = src.isolated_webui;
    }

    fn applyModulesFields(dst: *Modules, src: Modules, fields: ModulesFields) void {
        if (fields.mcp) dst.mcp = src.mcp;
        if (fields.acp) dst.acp = src.acp;
        if (fields.peers) dst.peers = src.peers;
        if (fields.a2a) dst.a2a = src.a2a;
        if (fields.webui) dst.webui = src.webui;
        if (fields.graphs) dst.graphs = src.graphs;
        if (fields.sessions) dst.sessions = src.sessions;
        if (fields.goal) dst.goal = src.goal;
        if (fields.goal_auto_steer) dst.goal_auto_steer = src.goal_auto_steer;
        if (fields.token_budget) dst.token_budget = src.token_budget;
        if (fields.streaming) dst.streaming = src.streaming;
        if (fields.dotenv) dst.dotenv = src.dotenv;
        if (fields.hot_reload) dst.hot_reload = src.hot_reload;
        if (fields.autolearn) dst.autolearn = src.autolearn;
        if (fields.subagents) dst.subagents = src.subagents;
        if (fields.rlm) dst.rlm = src.rlm;
        if (fields.multimodal) dst.multimodal = src.multimodal;
        if (fields.chatrooms) dst.chatrooms = src.chatrooms;
        if (fields.token_stats) dst.token_stats = src.token_stats;
        if (fields.mesh) dst.mesh = src.mesh;
    }

    fn parseKernel(v: json.Value) !Kernel {
        const prior_scope = diagnostic_scope;
        diagnostic_scope = "kernel";
        defer diagnostic_scope = prior_scope;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.KernelNotObject,
        };
        var k = Kernel{};
        warnUnknownKeys(obj, &.{
            "enabled",                "max_output_bytes",             "cleanup_delay_ms",
            "python_wasi_binary",     "python_wasi_stdlib",           "python_wasi_fuel",
            "python_wasi_timeout_ms", "python_wasi_max_memory_bytes",
        }, "kernel");
        if (obj.get("enabled")) |e| k.enabled = try jsonBool(e, "enabled");
        if (obj.get("max_output_bytes")) |n| k.max_output_bytes = try jsonUnsigned(u32, n, "kernel.max_output_bytes");
        if (obj.get("cleanup_delay_ms")) |n| k.cleanup_delay_ms = try jsonUnsigned(u32, n, "kernel.cleanup_delay_ms");
        if (obj.get("python_wasi_binary")) |s| k.python_wasi_binary = try jsonStr(s, "kernel.python_wasi_binary");
        if (obj.get("python_wasi_stdlib")) |s| k.python_wasi_stdlib = try jsonStr(s, "kernel.python_wasi_stdlib");
        if (obj.get("python_wasi_fuel")) |n| k.python_wasi_fuel = try jsonUnsigned(u64, n, "kernel.python_wasi_fuel");
        if (obj.get("python_wasi_timeout_ms")) |n| k.python_wasi_timeout_ms = try jsonUnsigned(u32, n, "kernel.python_wasi_timeout_ms");
        if (obj.get("python_wasi_max_memory_bytes")) |n| k.python_wasi_max_memory_bytes = try jsonUnsigned(u64, n, "kernel.python_wasi_max_memory_bytes");
        return k;
    }

    fn parseDebug(arena: std.mem.Allocator, v: json.Value) !Debug {
        const prior_scope = diagnostic_scope;
        diagnostic_scope = "debug";
        defer diagnostic_scope = prior_scope;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.DebugNotObject,
        };
        var d = Debug{};
        warnUnknownKeys(obj, &.{
            "enabled", "disconnect_timeout_ms", "launch_timeout_ms", "adapters",
        }, "debug");
        if (obj.get("enabled")) |e| d.enabled = try jsonBool(e, "enabled");
        if (obj.get("disconnect_timeout_ms")) |n| d.disconnect_timeout_ms = try jsonUnsigned(u32, n, "debug.disconnect_timeout_ms");
        if (obj.get("launch_timeout_ms")) |n| d.launch_timeout_ms = try jsonUnsigned(u32, n, "debug.launch_timeout_ms");
        if (obj.get("adapters")) |av| {
            const aobj = switch (av) {
                .object => |o| o,
                else => return error.DebugAdaptersNotObject,
            };
            var list: std.ArrayList(DebugAdapter) = .empty;
            var it = aobj.iterator();
            while (it.next()) |kv| {
                const entry = switch (kv.value_ptr.*) {
                    .object => |o| o,
                    else => return error.DebugAdapterNotObject,
                };
                warnUnknownKeys(entry, &.{"command"}, "debug.adapters");
                var adapter = DebugAdapter{ .name = kv.key_ptr.* };
                if (entry.get("command")) |c| adapter.command = try jsonNameList(arena, c, "debug.adapters.command");
                if (adapter.command.len == 0) return error.DebugAdapterEmptyCommand;
                try list.append(arena, adapter);
            }
            d.adapters = try list.toOwnedSlice(arena);
        }
        return d;
    }

    fn parseMesh(v: json.Value) !Mesh {
        const obj = switch (v) {
            .object => |o| o,
            else => return error.MeshNotObject,
        };
        var m = Mesh{};
        warnUnknownKeys(obj, &.{
            "listen_host",            "listen_port",     "ping_interval_seconds",
            "admission",              "max_members",     "max_pending_joins",
            "prompt_timeout_seconds", "max_frame_bytes", "max_file_bytes",
            "file_chunk_bytes",
        }, "mesh");
        if (obj.get("listen_host")) |s| m.listen_host = try jsonStr(s, "mesh.listen_host");
        if (obj.get("listen_port")) |n| m.listen_port = try jsonUnsigned(u16, n, "mesh.listen_port");
        if (obj.get("ping_interval_seconds")) |n| m.ping_interval_seconds = try jsonUnsigned(u32, n, "mesh.ping_interval_seconds");
        if (obj.get("admission")) |s| {
            m.admission = try jsonStr(s, "mesh.admission");
            if (!std.mem.eql(u8, m.admission, "allowlist") and
                !std.mem.eql(u8, m.admission, "prompt") and
                !std.mem.eql(u8, m.admission, "open"))
                return error.MeshAdmissionInvalid;
        }
        if (obj.get("max_members")) |n| m.max_members = try jsonUnsigned(u16, n, "mesh.max_members");
        if (obj.get("max_pending_joins")) |n| m.max_pending_joins = try jsonUnsigned(u16, n, "mesh.max_pending_joins");
        if (obj.get("prompt_timeout_seconds")) |n| m.prompt_timeout_seconds = try jsonUnsigned(u32, n, "mesh.prompt_timeout_seconds");
        if (obj.get("max_frame_bytes")) |n| m.max_frame_bytes = try jsonUnsigned(u32, n, "mesh.max_frame_bytes");
        if (obj.get("max_file_bytes")) |n| m.max_file_bytes = try jsonUnsigned(u32, n, "mesh.max_file_bytes");
        if (obj.get("file_chunk_bytes")) |n| m.file_chunk_bytes = try jsonUnsigned(u32, n, "mesh.file_chunk_bytes");
        return m;
    }

    fn parseTtsr(arena: std.mem.Allocator, v: json.Value) !Ttsr {
        const prior_scope = diagnostic_scope;
        diagnostic_scope = "ttsr";
        defer diagnostic_scope = prior_scope;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.TtsrNotObject,
        };
        var t = Ttsr{};
        warnUnknownKeys(obj, &.{ "max_retries_per_turn", "buffer_bytes", "rules" }, "ttsr");
        if (obj.get("max_retries_per_turn")) |k| {
            t.max_retries_per_turn = try jsonUnsigned(u32, k, "ttsr.max_retries_per_turn");
        }
        if (obj.get("buffer_bytes")) |k| {
            t.buffer_bytes = try jsonUnsigned(u32, k, "ttsr.buffer_bytes");
            if (t.buffer_bytes == 0) t.buffer_bytes = 4096;
        }
        if (obj.get("rules")) |k| {
            const arr = switch (k) {
                .array => |a| a,
                else => return error.TtsrRulesNotArray,
            };
            var out: std.ArrayList(TtsrRule) = .empty;
            for (arr.items) |item| {
                const ro = switch (item) {
                    .object => |o| o,
                    else => return error.TtsrRuleNotObject,
                };
                var rule = TtsrRule{};
                if (ro.get("name")) |n| rule.name = try jsonStr(n, "rules[].name");
                if (ro.get("pattern")) |p| rule.pattern = try jsonStr(p, "rules[].pattern");
                if (ro.get("inject")) |inj| rule.inject = try jsonStr(inj, "rules[].inject");
                if (ro.get("max_fires")) |mf| {
                    const n = try jsonInt(mf, "rules[].max_fires");
                    if (n <= 0) return error.TtsrMaxFiresZero;
                    rule.max_fires = @intCast(n);
                }
                if (rule.name.len == 0) return error.TtsrRuleNameEmpty;
                if (rule.pattern.len == 0) return error.TtsrRulePatternEmpty;
                try out.append(arena, rule);
            }
            t.rules = try out.toOwnedSlice(arena);
        }
        return t;
    }

    fn parseAdvisor(v: json.Value) !Advisor {
        const prior_scope = diagnostic_scope;
        diagnostic_scope = "advisor";
        defer diagnostic_scope = prior_scope;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.AdvisorNotObject,
        };
        var a = Advisor{};
        warnUnknownKeys(obj, &.{ "enabled", "provider", "model", "scope", "context_turns", "timeout_ms" }, "advisor");
        if (obj.get("enabled")) |k| a.enabled = try jsonBool(k, "enabled");
        if (obj.get("provider")) |k| a.provider = try jsonStr(k, "advisor.provider");
        if (obj.get("model")) |k| a.model = try jsonStr(k, "advisor.model");
        if (obj.get("scope")) |k| a.scope = try jsonStr(k, "advisor.scope");
        if (obj.get("context_turns")) |k| {
            const n = try jsonInt(k, "advisor.context_turns");
            a.context_turns = if (n <= 0) 1 else @intCast(n);
        }
        if (obj.get("timeout_ms")) |k| {
            const n = try jsonInt(k, "advisor.timeout_ms");
            a.timeout_ms = if (n <= 0) 0 else @intCast(n);
        }
        return a;
    }

    fn parseHooks(v: json.Value) !Hooks {
        const prior_scope = diagnostic_scope;
        diagnostic_scope = "hooks";
        defer diagnostic_scope = prior_scope;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.HooksNotObject,
        };
        var hooks = Hooks{};
        warnUnknownKeys(obj, &.{ "enabled", "config_path", "default_timeout_ms" }, "hooks");
        if (obj.get("enabled")) |value| hooks.enabled = try jsonBool(value, "enabled");
        if (obj.get("config_path")) |value| hooks.config_path = try jsonStr(value, "hooks.config_path");
        if (obj.get("default_timeout_ms")) |value| hooks.default_timeout_ms = try jsonUnsigned(u32, value, "hooks.default_timeout_ms");
        return hooks;
    }

    fn parseImprove(arena: std.mem.Allocator, v: json.Value) !Improve {
        const prior_scope = diagnostic_scope;
        diagnostic_scope = "improve";
        defer diagnostic_scope = prior_scope;
        _ = arena;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.ImproveNotObject,
        };
        var im = Improve{};
        warnUnknownKeys(obj, &.{ "max_context_bytes", "capability_gate", "arena_advisory", "max_cache_bytes", "max_context_requests", "inert_gate", "max_consecutive_test_only", "eval_provider", "plan_phase" }, "improve");
        if (obj.get("max_context_bytes")) |k| {
            const n = try jsonInt(k, "max_context_bytes");
            im.max_context_bytes = if (n <= 0) null else @intCast(n);
        }
        if (obj.get("capability_gate")) |k| im.capability_gate = switch (k) {
            .bool => |b| b,
            else => return error.FieldNotBool,
        };
        if (obj.get("arena_advisory")) |k| im.arena_advisory = try jsonBool(k, "arena_advisory");
        if (obj.get("max_cache_bytes")) |k| im.max_cache_bytes = try jsonUnsigned(u64, k, "max_cache_bytes");
        if (obj.get("max_context_requests")) |k| {
            const n = try jsonInt(k, "max_context_requests");
            im.max_context_requests = if (n <= 0) 0 else @intCast(n);
        }
        if (obj.get("inert_gate")) |k| im.inert_gate = switch (k) {
            .bool => |b| b,
            else => return error.FieldNotBool,
        };
        if (obj.get("max_consecutive_test_only")) |k| {
            const n = try jsonInt(k, "max_consecutive_test_only");
            im.max_consecutive_test_only = if (n <= 0) 0 else @intCast(n);
        }
        if (obj.get("eval_provider")) |k| im.eval_provider = try jsonStr(k, "eval_provider");
        if (obj.get("plan_phase")) |k| im.plan_phase = switch (k) {
            .bool => |b| b,
            else => return error.FieldNotBool,
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
        // must not reset tools_dir (and the rest) to Agent{} defaults, that
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
        // Field-merged rather than whole-section: every field is optional, so
        // a local file that only moves the port must leave a host set by the
        // base file alone instead of resetting it to "unset".
        if (src.serve_present) applyServeFields(&dst.serve, src.serve, src.serve_fields);
        if (src.notify_present) dst.notify = src.notify;
        if (src.tui_present) dst.tui = src.tui;
        if (src.chatrooms_present) dst.chatrooms = src.chatrooms;
        if (src.memory_present) dst.memory = src.memory;
        if (src.advisor_present) dst.advisor = src.advisor;
        if (src.hooks_present) dst.hooks = src.hooks;
        if (src.ttsr_present) dst.ttsr = src.ttsr;
        if (src.kernel_present) dst.kernel = src.kernel;
        if (src.debug_present) dst.debug = src.debug;
        if (src.mesh_present) dst.mesh = src.mesh;
        if (src.modules_present) applyModulesFields(&dst.modules, src.modules, src.modules_fields);
    }

    fn parseModules(arena: std.mem.Allocator, v: json.Value) !struct { modules: Modules, fields: ModulesFields } {
        const prior_scope = diagnostic_scope;
        diagnostic_scope = "modules";
        defer diagnostic_scope = prior_scope;
        _ = arena;
        const obj = switch (v) {
            .object => |o| o,
            else => return error.ModulesNotObject,
        };
        var m = Modules{};
        var mf = ModulesFields{};
        const fields = [_]struct { key: []const u8, ptr: *bool, present: *bool }{
            .{ .key = "mcp", .ptr = &m.mcp, .present = &mf.mcp },
            .{ .key = "acp", .ptr = &m.acp, .present = &mf.acp },
            .{ .key = "peers", .ptr = &m.peers, .present = &mf.peers },
            .{ .key = "a2a", .ptr = &m.a2a, .present = &mf.a2a },
            .{ .key = "webui", .ptr = &m.webui, .present = &mf.webui },
            .{ .key = "graphs", .ptr = &m.graphs, .present = &mf.graphs },
            .{ .key = "sessions", .ptr = &m.sessions, .present = &mf.sessions },
            .{ .key = "goal", .ptr = &m.goal, .present = &mf.goal },
            .{ .key = "goal_auto_steer", .ptr = &m.goal_auto_steer, .present = &mf.goal_auto_steer },
            .{ .key = "token_budget", .ptr = &m.token_budget, .present = &mf.token_budget },
            .{ .key = "streaming", .ptr = &m.streaming, .present = &mf.streaming },
            .{ .key = "dotenv", .ptr = &m.dotenv, .present = &mf.dotenv },
            .{ .key = "hot_reload", .ptr = &m.hot_reload, .present = &mf.hot_reload },
            .{ .key = "autolearn", .ptr = &m.autolearn, .present = &mf.autolearn },
            .{ .key = "subagents", .ptr = &m.subagents, .present = &mf.subagents },
            .{ .key = "rlm", .ptr = &m.rlm, .present = &mf.rlm },
            .{ .key = "multimodal", .ptr = &m.multimodal, .present = &mf.multimodal },
            .{ .key = "chatrooms", .ptr = &m.chatrooms, .present = &mf.chatrooms },
            .{ .key = "token_stats", .ptr = &m.token_stats, .present = &mf.token_stats },
            .{ .key = "mesh", .ptr = &m.mesh, .present = &mf.mesh },
        };
        warnUnknownKeys(obj, &.{
            "mcp",         "acp",       "peers",           "a2a",          "webui",      "graphs",
            "sessions",    "goal",      "goal_auto_steer", "token_budget", "streaming",  "dotenv",
            "hot_reload",  "autolearn", "subagents",       "rlm",          "multimodal", "chatrooms",
            "token_stats", "mesh",
        }, "modules");
        for (fields) |f| {
            if (obj.get(f.key)) |val| {
                f.ptr.* = try jsonBool(val, f.key);
                f.present.* = true;
            }
        }
        return .{ .modules = m, .fields = mf };
    }

    fn parseMemory(arena: std.mem.Allocator, v: json.Value) !Memory {
        const prior_scope = diagnostic_scope;
        diagnostic_scope = "memory";
        defer diagnostic_scope = prior_scope;
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
            if (co.get("size")) |x| m.chunk_size = try jsonUnsigned(u32, x, "chunk.size");
            if (co.get("overlap")) |x| m.chunk_overlap = try jsonUnsigned(u32, x, "chunk.overlap");
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
            if (vo.get("top_k")) |x| m.vector_top_k = try jsonUnsigned(u32, x, "vector.top_k");
            if (vo.get("threshold")) |x| m.vector_threshold = @floatCast(try jsonFloat(x, "vector.threshold"));
        }
        return m;
    }

    // --- helpers -----------------------------------------------------------

    fn logTomlSyntaxError(file_name: []const u8, line: ?usize, err: anyerror) void {
        if (diagnostics_suppressed) return;
        last_load_diagnostic = true;
        if (line) |n| {
            log.log(.error_, "{s}:{d}: invalid TOML syntax ({s}); correct the statement on this line", .{ file_name, n, @errorName(err) });
        } else {
            log.log(.error_, "{s}: invalid TOML syntax ({s}); correct the TOML statement", .{ file_name, @errorName(err) });
        }
    }

    fn lineForSetting(raw: []const u8, path: []const u8) usize {
        const leaf_start = if (std.mem.lastIndexOfScalar(u8, path, '.')) |index| index + 1 else 0;
        var leaf = path[leaf_start..];
        if (std.mem.indexOfScalar(u8, leaf, '[')) |index| leaf = leaf[0..index];
        var lines = std.mem.splitScalar(u8, raw, '\n');
        var line: usize = 1;
        while (lines.next()) |source_line| : (line += 1) {
            const trimmed = std.mem.trimStart(u8, source_line, " \t");
            if (!std.mem.startsWith(u8, trimmed, leaf)) continue;
            const rest = trimmed[leaf.len..];
            if (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t' or rest[0] == '=')) return line;
        }
        return 1;
    }

    fn logDiagnostic(path: []const u8, expected: []const u8, actual: ?json.Value, example: []const u8) void {
        if (diagnostics_suppressed) return;
        const source = diagnostic_source orelse return;
        last_load_diagnostic = true;
        var full_path_buf: [512]u8 = undefined;
        const full_path = if (diagnostic_scope.len > 0 and !std.mem.startsWith(u8, path, diagnostic_scope))
            std.fmt.bufPrint(&full_path_buf, "{s}.{s}", .{ diagnostic_scope, path }) catch path
        else
            path;
        diagnostic_emitted = true;
        const line = lineForSetting(source.raw, full_path);
        var corrected_example_buf: [512]u8 = undefined;
        const corrected_example = if (std.mem.startsWith(u8, example, "setting =")) blk: {
            const leaf_start: usize = if (std.mem.lastIndexOfScalar(u8, full_path, '.')) |index| index + 1 else 0;
            var leaf = full_path[leaf_start..];
            if (std.mem.indexOfScalar(u8, leaf, '[')) |index| leaf = leaf[0..index];
            break :blk std.fmt.bufPrint(&corrected_example_buf, "{s}{s}", .{ leaf, example["setting".len..] }) catch example;
        } else example;
        if (actual) |value| switch (value) {
            .string => |text| {
                const sensitive = std.mem.indexOf(u8, full_path, "key") != null or std.mem.indexOf(u8, full_path, "token") != null or std.mem.indexOf(u8, full_path, "secret") != null;
                if (sensitive) {
                    log.log(.error_, "{s}:{d}: configuration setting {s}: expected {s}; got string (value redacted); correct it with {s}", .{ source.file_name, line, full_path, expected, corrected_example });
                } else {
                    log.log(.error_, "{s}:{d}: configuration setting {s}: expected {s}; got string \"{s}\"; correct it with {s}", .{ source.file_name, line, full_path, expected, text, corrected_example });
                }
            },
            .integer => |n| log.log(.error_, "{s}:{d}: configuration setting {s}: expected {s}; got integer {d}; correct it with {s}", .{ source.file_name, line, full_path, expected, n, corrected_example }),
            .float => |n| log.log(.error_, "{s}:{d}: configuration setting {s}: expected {s}; got float {d}; correct it with {s}", .{ source.file_name, line, full_path, expected, n, corrected_example }),
            .bool => |b| log.log(.error_, "{s}:{d}: configuration setting {s}: expected {s}; got boolean {}; correct it with {s}", .{ source.file_name, line, full_path, expected, b, corrected_example }),
            .array => |items| log.log(.error_, "{s}:{d}: configuration setting {s}: expected {s}; got array with {d} items; correct it with {s}", .{ source.file_name, line, full_path, expected, items.items.len, corrected_example }),
            .object => log.log(.error_, "{s}:{d}: configuration setting {s}: expected {s}; got table; correct it with {s}", .{ source.file_name, line, full_path, expected, corrected_example }),
            .number_string => |text| log.log(.error_, "{s}:{d}: configuration setting {s}: expected {s}; got number string \"{s}\"; correct it with {s}", .{ source.file_name, line, full_path, expected, text, corrected_example }),
            .null => log.log(.error_, "{s}:{d}: configuration setting {s}: expected {s}; got null; correct it with {s}", .{ source.file_name, line, full_path, expected, corrected_example }),
        };
    }

    fn invalid(path: []const u8, expected: []const u8, actual: ?json.Value, example: []const u8, err: anyerror) anyerror {
        logDiagnostic(path, expected, actual, example);
        return err;
    }

    fn logUndiagnosedError(err: anyerror) void {
        if (diagnostics_suppressed) return;
        // `invalid` has already printed an actionable report.  This catches
        // future direct returns so they cannot silently reintroduce bare
        // errors such as FieldNotString.
        if (diagnostic_source) |source| {
            last_load_diagnostic = true;
            log.log(.error_, "{s}: configuration validation failed ({s}); inspect the setting named by the preceding diagnostic", .{ source.file_name, @errorName(err) });
        }
    }

    fn required(obj: json.ObjectMap, key: []const u8, path: []const u8, example: []const u8) !json.Value {
        return obj.get(key) orelse invalid(path, "a required value", null, example, error.MissingField);
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
                log.log(.warn, "config: unknown key '{s}' in {s} (ignored, check spelling)", .{ key, context });
            }
        }
    }

    fn jsonStr(v: json.Value, key: []const u8) ![]const u8 {
        return switch (v) {
            .string => |s| s,
            else => invalid(key, "a string", v, "setting = \"value\"", error.FieldNotString),
        };
    }

    fn jsonBool(v: json.Value, key: []const u8) !bool {
        return switch (v) {
            .bool => |b| b,
            else => invalid(key, "a boolean", v, "setting = true", error.FieldNotBool),
        };
    }

    fn jsonArray(v: json.Value, key: []const u8, example: []const u8) !json.Array {
        return switch (v) {
            .array => |items| items,
            else => invalid(key, "an array", v, example, error.NameListInvalid),
        };
    }

    fn jsonObject(v: json.Value, key: []const u8, example: []const u8) !json.ObjectMap {
        return switch (v) {
            .object => |object| object,
            else => invalid(key, "a table", v, example, error.ConfigNotObject),
        };
    }

    /// A string or an array of strings. A bare string becomes a one-element
    /// slice so every consumer only ever sees a list.
    fn jsonNameList(arena: std.mem.Allocator, v: json.Value, key: []const u8) ![]const []const u8 {
        switch (v) {
            .string => |s| {
                if (s.len == 0) return &.{};
                const one = try arena.alloc([]const u8, 1);
                one[0] = s;
                return one;
            },
            .array => |arr| {
                var out: std.ArrayList([]const u8) = .empty;
                for (arr.items) |item| {
                    const s = try jsonStr(item, key);
                    if (s.len == 0) continue;
                    try out.append(arena, s);
                }
                return try out.toOwnedSlice(arena);
            },
            else => return invalid(key, "a string or array of strings", v, "setting = [\"value\"]", error.NameListInvalid),
        }
    }

    /// `agent.tools_dir` is a string or an array of strings. A bare string
    /// becomes a one-element slice so every consumer only ever sees a list.
    fn jsonToolsDir(arena: std.mem.Allocator, v: json.Value) ![]const []const u8 {
        return jsonNameList(arena, v, "tools_dir") catch |err| switch (err) {
            error.FieldNotString, error.NameListInvalid => error.ToolsDirInvalid,
            else => err,
        };
    }

    fn jsonInt(v: json.Value, key: []const u8) !i64 {
        return switch (v) {
            .integer => |i| i,
            .float => |f| @trunc(f),
            .number_string => |s| std.fmt.parseInt(i64, s, 10) catch return invalid(key, "an integer", v, "setting = 1", error.FieldNotInt),
            else => invalid(key, "an integer", v, "setting = 1", error.FieldNotInt),
        };
    }

    /// Unsigned config integers. `@intCast` of a negative `jsonInt` wraps
    /// into a huge value in ReleaseFast (a `max_tokens = -1` became a 4G
    /// completion cap) and panics in Debug; reject it by name instead.
    fn jsonUnsigned(comptime T: type, v: json.Value, key: []const u8) !T {
        const n = try jsonInt(v, key);
        if (n < 0 or n > std.math.maxInt(T)) {
            return invalid(key, "an unsigned integer in 0..", v, "setting = 1", error.FieldNotUint);
        }
        return @intCast(n);
    }

    fn jsonFloat(v: json.Value, key: []const u8) !f64 {
        return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            .number_string => |s| std.fmt.parseFloat(f64, s) catch return invalid(key, "a number", v, "setting = 0.5", error.FieldNotNumber),
            else => invalid(key, "a number", v, "setting = 0.5", error.FieldNotNumber),
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

test "repeat tool thresholds reject empty low duplicate and non-integer values" {
    try std.testing.expectError(error.InvalidRepeatToolThresholds, Config.validateRepeatToolThresholds(&.{}));
    try std.testing.expectError(error.InvalidRepeatToolThresholds, Config.validateRepeatToolThresholds(&.{ 1, 3 }));
    try std.testing.expectError(error.InvalidRepeatToolThresholds, Config.validateRepeatToolThresholds(&.{ 3, 3 }));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"repeat_tool_thresholds\":[3,5.5]}", .{});
    try std.testing.expectError(error.RepeatToolThresholdNotInteger, Config.parseAgent(arena, value));
}

test "tui mascot speed is an integer from zero through ten" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const valid = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"tui":{"mascot_speed":3}}
    , .{});
    const cfg = try Config.parseConfig(arena, valid);
    try std.testing.expectEqual(@as(?u8, 3), cfg.tui.mascot_speed);

    const quoted = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"tui":{"mascot_speed":"3"}}
    , .{});
    try std.testing.expectError(error.FieldNotInt, Config.parseConfig(arena, quoted));

    const out_of_range = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"tui":{"mascot_speed":11}}
    , .{});
    try std.testing.expectError(error.MascotSpeedOutOfRange, Config.parseConfig(arena, out_of_range));
}

test "config errors retain base and local TOML source paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A nested base-table setting is rejected at its exact TOML line rather
    // than becoming the old context-free FieldNotString startup error.
    const base_bad =
        \\default_provider = "test"
        \\
        \\[providers.test]
        \\base_url = "http://127.0.0.1:1"
        \\
        \\[models."test/model"]
        \\provider = "test"
        \\
        \\[agent]
        \\max_iterations = "many"
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data = base_bad });
    try std.testing.expectEqual(@as(usize, 10), Config.lineForSetting(base_bad, "agent.max_iterations"));
    try std.testing.expectError(error.FieldNotInt, Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml"));
    try std.testing.expect(Config.takeLoadDiagnostic());

    // The local layer is parsed independently. An invalid array item there
    // must identify config.local.toml instead of attributing it to the base.
    const base_ok =
        \\default_provider = "test"
        \\
        \\[providers.test]
        \\base_url = "http://127.0.0.1:1"
        \\
        \\[models."test/model"]
        \\provider = "test"
        \\
    ;
    const local_bad =
        \\[[ttsr.rules]]
        \\name = "retry"
        \\pattern = 7
        \\inject = "retry"
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data = base_ok });
    try tmp.dir.writeFile(io, .{ .sub_path = "config.local.toml", .data = local_bad });
    try std.testing.expectEqual(@as(usize, 3), Config.lineForSetting(local_bad, "ttsr.rules[].pattern"));
    try std.testing.expectError(error.FieldNotString, Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml"));
    try std.testing.expect(Config.takeLoadDiagnostic());
}

test "hooks default off and parse explicit lifecycle settings" {
    try std.testing.expect(!(Hooks{}).enabled);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"hooks":{"enabled":true,"config_path":".claude/settings.json","default_timeout_ms":2500}}
    , .{});
    const cfg = try Config.parseConfig(arena, root);
    try std.testing.expect(cfg.hooks.enabled);
    try std.testing.expectEqualStrings(".claude/settings.json", cfg.hooks.config_path);
    try std.testing.expectEqual(@as(u32, 2500), cfg.hooks.default_timeout_ms);
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

test "config.local.toml can add a model without repeating providers" {
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
        \\base_url = "https://api.deepseek.com"
        \\api_key_env = "DEEPSEEK_API_KEY"
        \\
        \\[models."deepseek/deepseek-v4-flash"]
        \\provider = "deepseek"
        \\
        ,
    });
    try dir.writeFile(io, .{
        .sub_path = "config.local.toml",
        .data =
        \\[models."deepseek/deepseek-chat"]
        \\provider = "deepseek"
        \\max_tokens = 2048
        \\
        ,
    });
    const cfg = try Config.load(io, arena, dir, "config.toml", "config.local.toml");
    const ds = cfg.providers.getPtr("deepseek").?;
    try std.testing.expectEqual(@as(usize, 2), ds.models.count());
    try std.testing.expect(ds.models.get("deepseek-chat") != null);
    try std.testing.expect(ds.models.get("deepseek-v4-flash") != null);
    try std.testing.expectEqual(@as(u32, 2048), ds.models.get("deepseek-chat").?.max_tokens);
}

test "model temperature outside 0..2 fails at load" {
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
        \\base_url = "https://api.deepseek.com"
        \\api_key_env = "DEEPSEEK_API_KEY"
        \\
        \\[models."deepseek/deepseek-chat"]
        \\provider = "deepseek"
        \\temperature = 3.0
        \\
        ,
    });
    try std.testing.expectError(error.ModelTemperatureOutOfRange, Config.load(io, arena, dir, "config.toml", "config.local.toml"));
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

test "web.allow accepts glob patterns and the catch-all" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try json.parseFromSliceLeaky(json.Value, arena,
        \\{"web":{"allow":["*.example.org","sub?.example","*"]}}
    , .{ .ignore_unknown_fields = true });
    const cfg = try Config.parseConfig(arena, root);
    try std.testing.expectEqual(@as(usize, 3), cfg.web.allow.len);
    try std.testing.expectEqualStrings("*.example.org", cfg.web.allow[0]);
    try std.testing.expectEqualStrings("sub?.example", cfg.web.allow[1]);
    try std.testing.expectEqualStrings("*", cfg.web.allow[2]);
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

test "config.local.toml can clear serve_as" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data =
        \\serve = { host = "127.0.0.1", serve_as = ["base.example"] }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "config.local.toml", .data =
        \\serve = { serve_as = [] }
    });
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
    try std.testing.expectEqualStrings("127.0.0.1", cfg.serve.host.?);
    try std.testing.expectEqual(@as(usize, 0), cfg.serve.serve_as.len);
}

test "config.local.toml that only sets host does not clear a base proxy = true" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data =
        \\serve = { host = "127.0.0.1", proxy = true }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "config.local.toml", .data =
        \\serve = { host = "0.0.0.0" }
    });
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
    try std.testing.expectEqualStrings("0.0.0.0", cfg.serve.host.?);
    try std.testing.expect(cfg.serve.proxy);

    try tmp.dir.writeFile(io, .{ .sub_path = "config.local.toml", .data =
        \\serve = { proxy = false }
    });
    const off = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
    try std.testing.expect(!off.serve.proxy);
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

test "worktree and goal_worktree parse and default to auto" {
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
        \\worktree = "yes"
        \\goal_worktree = "no"
        \\
        ,
    });
    const cfg = try Config.load(io, arena, dir, "config.toml", "config.local.toml");
    try std.testing.expectEqual(WorktreeDefault.yes, cfg.agent.worktree);
    try std.testing.expectEqual(WorktreeDefault.no, cfg.agent.goal_worktree);

    // Left out, both default to auto (the historical per-run-kind behaviour).
    try std.testing.expectEqual(WorktreeDefault.auto, (Agent{}).worktree);
    try std.testing.expectEqual(WorktreeDefault.auto, (Agent{}).goal_worktree);

    // A typo must fail the load rather than silently isolate differently.
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
        \\worktree = "sometimes"
        \\
        ,
    });
    try std.testing.expectError(error.WorktreeDefaultInvalid, Config.load(io, arena, dir, "bad.toml", "config.local.toml"));
}

test "agent.git_worktree_on and isolated defaults parse" {
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
        \\git_worktree_on = ["goal", "webui"]
        \\isolated_cli = true
        \\isolated_tui = false
        \\isolated_webui = true
        \\
        ,
    });
    const cfg = try Config.load(io, arena, dir, "config.toml", "config.local.toml");
    try std.testing.expectEqualSlices(WorktreeMode, &.{ .goal, .webui }, cfg.agent.git_worktree_on);
    try std.testing.expect(cfg.agent.isolated_cli);
    try std.testing.expect(!cfg.agent.isolated_tui);
    try std.testing.expect(cfg.agent.isolated_webui);

    // Left out, the list defaults to empty (the historical per-run-kind behaviour).
    try std.testing.expectEqualSlices(WorktreeMode, &.{}, (Agent{}).git_worktree_on);
    try std.testing.expect(!(Agent{}).isolated_cli);

    // An unknown mode fails the load rather than being silently ignored.
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
        \\git_worktree_on = ["goal", "nope"]
        \\
        ,
    });
    try std.testing.expectError(error.WorktreeModeInvalid, Config.load(io, arena, dir, "bad.toml", "config.local.toml"));
}

test "agent.fallback_provider parses and is not reset by a partial local override" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try dir.writeFile(io, .{ .sub_path = "config.toml", .data =
        \\default_provider = "deepseek"
        \\
        \\[providers.deepseek]
        \\base_url = "https://api.deepseek.com"
        \\default_model = "deepseek-v4-flash"
        \\
        \\[models."deepseek/deepseek-v4-flash"]
        \\provider = "deepseek"
        \\capabilities = ["thinking", "tool_use"]
        \\
        \\[agent]
        \\fallback_provider = "ollama"
        \\
    });
    const cfg = try Config.load(io, arena, dir, "config.toml", "config.local.toml");
    try std.testing.expectEqual(@as(usize, 1), cfg.agent.fallback_providers.len);
    try std.testing.expectEqualStrings("ollama", cfg.agent.fallback_providers[0]);
    try std.testing.expectEqualStrings("ollama", firstFallbackProvider(cfg.agent.fallback_providers));
}

test "agent.fallback_providers accepts an array" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try dir.writeFile(io, .{ .sub_path = "config.toml", .data =
        \\default_provider = "deepseek"
        \\
        \\[providers.deepseek]
        \\base_url = "https://api.deepseek.com"
        \\default_model = "deepseek-v4-flash"
        \\
        \\[models."deepseek/deepseek-v4-flash"]
        \\provider = "deepseek"
        \\capabilities = ["thinking", "tool_use"]
        \\
        \\[agent]
        \\fallback_providers = ["ollama", "kimi-k3"]
        \\
    });
    const cfg = try Config.load(io, arena, dir, "config.toml", "config.local.toml");
    try std.testing.expectEqual(@as(usize, 2), cfg.agent.fallback_providers.len);
    try std.testing.expectEqualStrings("ollama", cfg.agent.fallback_providers[0]);
    try std.testing.expectEqualStrings("kimi-k3", cfg.agent.fallback_providers[1]);
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
    // null, which is what tells `providers check` to say so out loud.
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

test "a model id is the wire SKU; the table key is the local name" {
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
        \\default_provider = "xai"
        \\providers = { xai = { base_url = "https://api.x.ai/v1", default_model = "grok4.6-coding" } }
        \\[models."xai/grok4.6-coding"]
        \\provider = "xai"
        \\id = "grok-4.6"
        \\temperature = 0.2
        \\[models."xai/grok4.6-general"]
        \\provider = "xai"
        \\id = "grok-4.6"
        \\temperature = 0.7
        ,
    });
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "missing.toml");
    const xai = cfg.providers.getPtr("xai").?;
    try std.testing.expectEqual(@as(usize, 2), xai.models.count());
    try std.testing.expectEqualStrings("grok4.6-coding", xai.activeModelName());
    try std.testing.expectEqualStrings("grok-4.6", xai.wireModelName());
    try std.testing.expectEqual(@as(f64, 0.2), xai.activeModel().temperature.?);
    try std.testing.expectEqual(@as(f64, 0.7), xai.models.get("grok4.6-general").?.temperature.?);
    try std.testing.expectEqualStrings("grok-4.6", xai.modelSku("grok4.6-general"));
    // No id: the table key is what goes on the wire.
    try std.testing.expectEqualStrings("only", (Model{}).wireName("only"));

    const picked = try cfg.resolveProvider(null, "xai/grok4.6-general");
    try std.testing.expectEqualStrings("grok4.6-general", picked.activeModelName());
    try std.testing.expectEqualStrings("grok-4.6", picked.wireModelName());
    try std.testing.expectEqual(@as(f64, 0.7), picked.activeModel().temperature.?);
}

test "unset model specs fill from the models.dev snapshot; written values win" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.writeFile(io, .{
        .sub_path = "state/models-dev.json",
        .data =
        \\{
        \\  "xai": {
        \\    "api": "https://api.x.ai/v1",
        \\    "models": {
        \\      "grok-4.6": {
        \\        "name": "Grok 4.6",
        \\        "limit": {"context": 500000, "output": 250000},
        \\        "cost": {"input": 2, "output": 6},
        \\        "reasoning": true,
        \\        "tool_call": true
        \\      }
        \\    }
        \\  }
        \\}
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.toml",
        .data =
        \\default_provider = "xai"
        \\[providers.xai]
        \\base_url = "https://api.x.ai/v1"
        \\default_model = "grok4.6-coding"
        \\[models."xai/grok4.6-coding"]
        \\provider = "xai"
        \\id = "grok-4.6"
        \\temperature = 0.2
        \\[models."xai/grok4.6-capped"]
        \\provider = "xai"
        \\id = "grok-4.6"
        \\max_tokens = 8192
        ,
    });
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "missing.toml");
    const coding = cfg.providers.getPtr("xai").?.models.get("grok4.6-coding").?;
    try std.testing.expectEqual(@as(u32, 500000), coding.context_window);
    try std.testing.expectEqual(@as(u32, 250000), coding.max_tokens);
    try std.testing.expectEqual(@as(f64, 2), coding.cost_per_1m_input.?);
    try std.testing.expectEqual(@as(f64, 6), coding.cost_per_1m_output.?);
    try std.testing.expectEqualStrings("Grok 4.6", coding.display.?);
    try std.testing.expectEqual(@as(usize, 2), coding.capabilities.len);
    try std.testing.expectEqual(@as(f64, 0.2), coding.temperature.?);

    const capped = cfg.providers.getPtr("xai").?.models.get("grok4.6-capped").?;
    try std.testing.expectEqual(@as(u32, 500000), capped.context_window);
    try std.testing.expectEqual(@as(u32, 8192), capped.max_tokens);
    try std.testing.expect(capped.max_tokens_set);
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

test "tool-result pruning config rejects retained bytes at the threshold" {
    try Config.validateToolResultPrune(.{});
    try Config.validateToolResultPrune(.{ .tool_result_prune_bytes = 0, .tool_result_prune_head_bytes = 999999 });
    try std.testing.expectError(error.InvalidToolResultPruneConfig, Config.validateToolResultPrune(.{
        .tool_result_prune_bytes = 100,
        .tool_result_prune_head_bytes = 60,
        .tool_result_prune_tail_bytes = 10,
    }));
}

test "advisor section parses and stays off by default" {
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
        \\[advisor]
        \\enabled = true
        \\provider = "a"
        \\model = "m"
        \\scope = "session"
        \\timeout_ms = 2500
        ,
    });
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
    try std.testing.expect(cfg.advisor.enabled);
    try std.testing.expectEqualStrings("a", cfg.advisor.provider);
    try std.testing.expectEqualStrings("session", cfg.advisor.scope);
    try std.testing.expectEqual(@as(u32, 2500), cfg.advisor.timeout_ms);
    try std.testing.expect(!(Advisor{}).enabled);
}

test "config.local.toml replaces advisor, ttsr, and kernel wholesale" {
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
        \\[advisor]
        \\enabled = false
        \\[ttsr]
        \\max_retries_per_turn = 1
        \\[kernel]
        \\enabled = false
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "config.local.toml",
        .data =
        \\[advisor]
        \\enabled = true
        \\provider = "a"
        \\model = "m"
        \\[ttsr]
        \\max_retries_per_turn = 5
        \\[kernel]
        \\enabled = true
        ,
    });
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
    try std.testing.expect(cfg.advisor.enabled);
    try std.testing.expectEqualStrings("a", cfg.advisor.provider);
    try std.testing.expectEqual(@as(u32, 5), cfg.ttsr.max_retries_per_turn);
    try std.testing.expect(cfg.kernel.enabled);
}

test "debug adapters parse from nested tables" {
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
        \\[debug]
        \\enabled = true
        \\disconnect_timeout_ms = 1000
        \\[debug.adapters.lldb]
        \\command = ["lldb-dap"]
        \\[debug.adapters.python]
        \\command = ["python3", "-m", "debugpy.adapter"]
        ,
    });
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
    try std.testing.expect(cfg.debug.enabled);
    try std.testing.expectEqual(@as(u32, 1000), cfg.debug.disconnect_timeout_ms);
    try std.testing.expectEqual(@as(usize, 2), cfg.debug.adapters.len);
    var saw_lldb = false;
    for (cfg.debug.adapters) |a| {
        if (std.mem.eql(u8, a.name, "lldb")) {
            saw_lldb = true;
            try std.testing.expectEqualStrings("lldb-dap", a.command[0]);
        }
    }
    try std.testing.expect(saw_lldb);
    try std.testing.expect(!(Debug{}).enabled);
}

test "first boot with no [instance] anywhere persists a name to the local file" {
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

    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
    try std.testing.expect(cfg.instance.name.len > 0);

    const written = try tmp.dir.readFileAlloc(io, "config.local.toml", std.testing.allocator, .limited(1 << 16));
    defer std.testing.allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "[instance]") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, cfg.instance.name) != null);

    // Second boot: the persisted name must survive unchanged rather than
    // being re-rolled on every launch.
    const cfg2 = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
    try std.testing.expectEqualStrings(cfg.instance.name, cfg2.instance.name);
}

test "persisting an instance name appends to an existing local file without clobbering it" {
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
        \\[agent]
        \\max_iterations = 7
        ,
    });

    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
    try std.testing.expectEqual(@as(u32, 7), cfg.agent.max_iterations);

    const written = try tmp.dir.readFileAlloc(io, "config.local.toml", std.testing.allocator, .limited(1 << 16));
    defer std.testing.allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "max_iterations = 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "[instance]") != null);
}

test "mesh section and peer id parse" {
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
        \\[[peers]]
        \\name = "alice"
        \\url = "http://127.0.0.1:1"
        \\id = "aaa"
        \\[modules]
        \\mesh = true
        \\[mesh]
        \\listen_port = 7421
        \\admission = "open"
        ,
    });
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
    try std.testing.expect(cfg.modules.mesh);
    try std.testing.expectEqual(@as(u16, 7421), cfg.mesh.listen_port);
    try std.testing.expectEqualStrings("open", cfg.mesh.admission);
    try std.testing.expectEqual(@as(usize, 1), cfg.peers.len);
    try std.testing.expectEqualStrings("aaa", cfg.peers[0].id);
    try std.testing.expect(!(Modules{}).mesh);
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
    try std.testing.expectEqual(@as(usize, 1), cfg.agent.tools_dir.len);
    try std.testing.expectEqualStrings("tools/manifests", cfg.agent.tools_dir[0]);
    try std.testing.expectEqualStrings(".", cfg.agent.sandbox_root);
    try std.testing.expectEqual(@as(u32, 30), cfg.agent.max_iterations);
}

test "agent.tools_dir accepts a string or an array" {
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
        \\agent = { tools_dir = ["tools/manifests", "/home/user/.config/clanker/plugins"] }
        ,
    });
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
    try std.testing.expectEqual(@as(usize, 2), cfg.agent.tools_dir.len);
    try std.testing.expectEqualStrings("tools/manifests", cfg.agent.tools_dir[0]);
    try std.testing.expectEqualStrings("/home/user/.config/clanker/plugins", cfg.agent.tools_dir[1]);

    try std.testing.expectEqual(@as(usize, 1), (Agent{}).tools_dir.len);
    try std.testing.expectEqualStrings("tools/manifests", (Agent{}).tools_dir[0]);
    try std.testing.expectEqualStrings("tools/manifests", firstToolsDir(&.{}));
    try std.testing.expectEqualStrings("a", firstToolsDir(&.{ "a", "b" }));
    try std.testing.expectEqualStrings("(empty)", try toolsDirDisplay(arena, &.{}));
    try std.testing.expectEqualStrings("only", try toolsDirDisplay(arena, &.{"only"}));
    try std.testing.expectEqualStrings("a, b", try toolsDirDisplay(arena, &.{ "a", "b" }));
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

test "a negative max_tokens is rejected instead of wrapping into a huge cap" {
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
        \\models = { "a/m" = { provider = "a", max_tokens = -1 } }
        ,
    });
    try std.testing.expectError(error.FieldNotUint, Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml"));
}

test "reasoning_effort parses supported values and null when absent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const supported = [_]struct { toml: []const u8, want: ReasoningEffort }{
        .{ .toml = "none", .want = .none },
        .{ .toml = "low", .want = .low },
        .{ .toml = "medium", .want = .medium },
        .{ .toml = "high", .want = .high },
        .{ .toml = "max", .want = .max },
    };
    for (supported) |c| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(io, .{
            .sub_path = "config.toml",
            .data = try std.fmt.allocPrint(arena,
                \\default_provider = "a"
                \\providers = {{ a = {{ base_url = "https://a.test" }} }}
                \\models = {{ "a/m" = {{ provider = "a", reasoning_effort = "{s}" }} }}
            , .{c.toml}),
        });
        const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
        try std.testing.expectEqual(c.want, cfg.providers.get("a").?.activeModel().reasoning_effort.?);
    }

    // Absent field stays null (wire omits it).
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
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
    try std.testing.expect(cfg.providers.get("a").?.activeModel().reasoning_effort == null);
}

test "an invalid reasoning_effort is rejected" {
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
        \\models = { "a/m" = { provider = "a", reasoning_effort = "turbo" } }
        ,
    });
    try std.testing.expectError(error.UnknownReasoningEffort, Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml"));
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

test "agent.repl_exec_allow parses, defaults empty, and rejects a non-array" {
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
        \\agent = { repl_exec_allow = ["ls", "cat"] }
        ,
    });
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
    try std.testing.expectEqual(@as(usize, 2), cfg.agent.repl_exec_allow.len);
    try std.testing.expectEqualStrings("ls", cfg.agent.repl_exec_allow[0]);
    try std.testing.expectEqualStrings("cat", cfg.agent.repl_exec_allow[1]);

    // Absent: the `!` escape is limited to what the tool registry already allows.
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
    try std.testing.expectEqual(@as(usize, 0), cfg2.agent.repl_exec_allow.len);

    var arena3 = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena3.deinit();
    var tmp3 = std.testing.tmpDir(.{});
    defer tmp3.cleanup();
    try tmp3.dir.writeFile(io, .{
        .sub_path = "config.toml",
        .data =
        \\default_provider = "a"
        \\providers = { a = { base_url = "https://a.test" } }
        \\models = { "a/m" = { provider = "a" } }
        \\agent = { repl_exec_allow = "ls" }
        ,
    });
    try std.testing.expectError(
        error.ReplExecAllowNotArray,
        Config.load(io, arena3.allocator(), tmp3.dir, "config.toml", "config.local.toml"),
    );
}

test "agent.worktree and goal_worktree parse and reject bad values" {
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
        \\agent = { worktree = "yes", goal_worktree = "no" }
        ,
    });
    const cfg = try Config.load(io, arena, tmp.dir, "config.toml", "config.local.toml");
    try std.testing.expectEqual(WorktreeDefault.yes, cfg.agent.worktree);
    try std.testing.expectEqual(WorktreeDefault.no, cfg.agent.goal_worktree);

    // Absent: both default to auto (run off, goal/scheduled on).
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
    const cfg2 = try Config.load(
        io,
        arena2.allocator(),
        tmp2.dir,
        "config.toml",
        "config.local.toml",
    );
    try std.testing.expectEqual(WorktreeDefault.auto, cfg2.agent.goal_worktree);

    // A bad value fails loudly rather than silently falling back.
    var arena3 = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena3.deinit();
    var tmp3 = std.testing.tmpDir(.{});
    defer tmp3.cleanup();
    try tmp3.dir.writeFile(io, .{
        .sub_path = "config.toml",
        .data =
        \\default_provider = "a"
        \\providers = { a = { base_url = "https://a.test" } }
        \\models = { "a/m" = { provider = "a" } }
        \\agent = { worktree = "sometimes" }
        ,
    });
    try std.testing.expectError(
        error.WorktreeDefaultInvalid,
        Config.load(io, arena3.allocator(), tmp3.dir, "config.toml", "config.local.toml"),
    );
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

test "the auth strategy is optional, parsed by name, and rejected when misspelt" {
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
        \\default_provider = "xai"
        \\providers = { xai = { base_url = "https://api.x.ai/v1", api_key_env = "XAI_TOKEN", auth = "oauth_static" }, plain = { base_url = "https://y.test" } }
        \\models = { "xai/m" = { provider = "xai" }, "plain/m" = { provider = "plain" } }
        ,
    });
    var cfg = try Config.load(io, arena_state.allocator(), tmp.dir, "config.toml", "missing.toml");
    try std.testing.expectEqual(AuthStrategy.oauth_static, cfg.providers.get("xai").?.auth.?);
    // Unset is the norm: the wire kind auto-detects, which is what keeps
    // every existing config working untouched.
    try std.testing.expect(cfg.providers.get("plain").?.auth == null);

    try tmp.dir.writeFile(io, .{
        .sub_path = "bad.toml",
        .data =
        \\default_provider = "p"
        \\providers = { p = { base_url = "https://y.test", auth = "oauth" } }
        \\models = { "p/m" = { provider = "p" } }
        ,
    });
    // A typo must fail loudly: silently falling back would send the secret on
    // whichever header the default happened to pick.
    try std.testing.expectError(
        error.UnknownAuthStrategy,
        Config.load(io, arena_state.allocator(), tmp.dir, "bad.toml", "missing.toml"),
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

test "a vertex_anthropic provider without a credential file still loads" {
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
    // ADC / GAC are resolved at request time, not at load.
    const cfg = try Config.load(io, arena_state.allocator(), tmp.dir, "config.toml", "missing.toml");
    const p = cfg.providers.get("v").?;
    try std.testing.expectEqualStrings("", p.service_account_file);
    try std.testing.expect(p.api_key_env == null);
}

test "an azure_openai provider keeps api_version" {
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
        \\default_provider = "azure"
        \\providers = { azure = { kind = "azure_openai", base_url = "https://contoso.openai.azure.com", api_key_env = "AZURE_API_KEY", api_version = "2024-12-01-preview" } }
        \\models = { "azure/gpt-4o" = { provider = "azure" } }
        ,
    });
    const cfg = try Config.load(io, arena_state.allocator(), tmp.dir, "config.toml", "missing.toml");
    const p = cfg.providers.get("azure").?;
    try std.testing.expectEqual(ProviderKind.azure_openai, p.kind);
    try std.testing.expectEqualStrings("2024-12-01-preview", p.api_version);
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
    try std.testing.expectEqual(@as(u32, 50), cfg.agent.max_iterations);
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
test "improve bool fields reject non-bool values instead of silently defaulting" {
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
        \\[improve]
        \\capability_gate = "yes"
        ,
    });
    try std.testing.expectError(
        error.FieldNotBool,
        Config.load(io, arena_state.allocator(), tmp.dir, "config.toml", "missing.toml"),
    );
}

test "modules flags reject non-bool values instead of silently defaulting" {
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
        \\[modules]
        \\streaming = "false"
        ,
    });
    try std.testing.expectError(
        error.FieldNotBool,
        Config.load(io, arena_state.allocator(), tmp.dir, "config.toml", "missing.toml"),
    );
}

/// Whether `config.toml` documents `key`: a line that sets it, live or
/// commented out, or a table header that names it (`[[ttsr.rules]]`).
///
/// Line-anchored rather than a substring search, or `allow` would be
/// "documented" by `exec_pattern_allow` and the whole check would pass on
/// coincidences.
fn documentsKey(text: []const u8, key: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        // `# # proxy_port = 17922`: a key commented out inside an
        // already-commented block is still documented, so strip every layer
        // rather than one.
        const line = std.mem.trim(u8, raw, " \t#");
        if (std.mem.startsWith(u8, line, key)) {
            const rest = std.mem.trimStart(u8, line[key.len..], " \t");
            if (rest.len > 0 and rest[0] == '=') return true;
        }
        // `[memory.chunk]`, `[[ttsr.rules]]`: the key names a table.
        if (std.mem.startsWith(u8, line, "[")) {
            if (std.mem.find(u8, line, key)) |at| {
                const before = line[at - 1];
                const after = line[at + key.len ..];
                if ((before == '.' or before == '[') and (after.len > 0 and after[0] == ']')) return true;
            }
        }
    }
    return false;
}

test "config.toml documents every key the loader accepts" {
    // Grows with the schema; the full struct walk plus memory-key pass can
    // exceed Zig's default comptime branch quota when compiled with the
    // rest of the harness tests.
    @setEvalBranchQuota(200_000);
    // The committed config is the only place most of these keys are written
    // down at all: a key added to the schema and not to the file is one
    // nobody outside this source file will ever find. Reflection over the
    // structs rather than a hand-kept list, so the guard cannot go stale the
    // same way the file did. Resolved relative to this source file (src/),
    // so it reaches the committed config.toml at the repo root. Plain
    // @embedFile of a repo-root path keeps the file out of the exe: test
    // blocks are only evaluated when the test artifact is built, never when
    // the harness is.
    const text = @embedFile("../config.toml");

    // Fields that are not config keys. `shared_root` is set by `run
    // --worktree` at runtime and deliberately unreadable from a file; the
    // rest are the parsed *results* of keys rather than keys themselves.
    const not_keys = [_][]const u8{ "shared_root", "name", "models", "context_window_set", "max_tokens_set" };
    inline for (.{ Agent, Improve, Modules, Web, Notify, Chatrooms, Kernel, Debug, Mesh, Ttsr, TtsrRule, Advisor, Instance, Tui, Serve, Model, Provider }) |T| {
        inline for (@typeInfo(T).@"struct".fields) |f| {
            comptime var skip = false;
            inline for (not_keys) |n| {
                if (comptime std.mem.eql(u8, f.name, n)) skip = true;
            }
            // Provider.name and Instance.name are different things: the
            // instance really does take a `name =` key.
            if (comptime std.mem.eql(u8, f.name, "name") and (T == Instance or T == TtsrRule)) skip = false;
            if (!skip and !documentsKey(text, f.name)) {
                std.debug.print("config.toml does not document {s}.{s}\n", .{ @typeName(T), f.name });
                const probe = std.fmt.allocPrint(std.heap.page_allocator, "{s}.{s}\n", .{ @typeName(T), f.name }) catch "?";
                std.fs.cwd().writeFile(.{ .sub_path = "state/probe_undoc.txt", .data = probe }) catch {};
                return error.UndocumentedConfigKey;
            }
        }
    }

    // `[memory]`'s keys are nested tables, so its field names (chunk_size,
    // vector_top_k, ...) are not the spellings a file uses. Check those.
    inline for ([_][]const u8{ "memory", "chunk", "embedding", "vector", "size", "overlap", "strategy", "top_k", "threshold", "backend" }) |key| {
        if (!documentsKey(text, key)) {
            std.debug.print("config.toml does not document memory key {s}\n", .{key});
            return error.UndocumentedConfigKey;
        }
    }

    // And the alternate spelling the loader accepts for one-entry chains.
    try std.testing.expect(documentsKey(text, "fallback_provider"));
}

test "documentsKey does not accept a coincidental substring" {
    const text =
        \\exec_pattern_allow = []
        \\# [memory.chunk]
        \\# size = 800
    ;
    try std.testing.expect(!documentsKey(text, "allow"));
    try std.testing.expect(documentsKey(text, "exec_pattern_allow"));
    try std.testing.expect(documentsKey(text, "size"));
    try std.testing.expect(documentsKey(text, "chunk"));
    try std.testing.expect(!documentsKey(text, "vector"));
}
// --- memory helpers (appended via patch) ---
