//! CLI argument parsing and command implementations.

const std = @import("std");
const config = @import("config.zig");
const client = @import("llm/client.zig");
const providers = @import("llm/providers.zig");
const types = @import("llm/types.zig");
const agent = @import("agent/loop.zig");
const registry = @import("tools/registry.zig");
const scorers = @import("evals/scorers.zig");
const eval_runner = @import("evals/runner.zig");
const improve = @import("improve/engine.zig");
const history = @import("improve/history.zig");
const mcp = @import("mcp/server.zig");
const session = @import("agent/session.zig");
const autolearn = @import("agent/autolearn.zig");
const subagent = @import("agent/subagent.zig");
const graph = @import("agent/graph.zig");
const runtime = @import("sandbox/runtime.zig");
const host = @import("sandbox/host.zig");
const lineedit = @import("util/lineedit.zig");
const chatrooms = @import("peers/chatrooms.zig");
const token_stats = @import("stats/tokens.zig");
const log = @import("util/log.zig");
const atomic_write = @import("util/atomic_write.zig");
const diskcap = @import("util/diskcap.zig");
const runlock = @import("util/runlock.zig");
const gate_checks = @import("gate/checks.zig");

// Web UI vendor assets: served as plain static files (not routed through the
// WASM "webui" tool — its shared output buffer, lib.zig's out_cap, is 64 KiB,
// far smaller than these). Vendored rather than CDN-loaded so the page has
// zero runtime network dependencies and needs no change to the webui CSP.
const webui_vendor_d3dag = @embedFile("webui_vendor/d3-dag.min.js");
const webui_vendor_hljs = @embedFile("webui_vendor/hljs.min.js");

pub const Command = enum {
    help,
    init,
    providers_check,
    run,
    sessions,
    tools_list,
    eval,
    improve_self,
    revert,
    git,
    mcp,
    goal,
    notify,
    chat,
    stats,
    phonebook,
    serve,
    repl,
    graph,
    gate,
    autolearn,
};

pub const Options = struct {
    /// No command given means the interactive REPL: a bare `clanker` should
    /// drop the user into a session, the way every other coding agent does,
    /// not print usage at them.
    command: Command = .repl,
    /// Sub-command for `providers`: "check" (default) or "models".
    providers_sub: []const u8 = "check",
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    task: ?[]const u8 = null,
    session: ?[]const u8 = null,
    goal: ?[]const u8 = null,
    peer: ?[]const u8 = null,
    message: ?[]const u8 = null,
    /// Sub-command for `chat`: "send", "history", "rooms" (default) or
    /// "subscribe". `room` holds the room name; `message` holds the text (send),
    /// an `after` ts (history) or an on/off token (subscribe).
    chat_sub: []const u8 = "rooms",
    room: ?[]const u8 = null,
    eval_name: ?[]const u8 = null,
    /// `eval --tasks`: only the agent-driven evals, skipping the selfhost
    /// build gates. What a capability check wants; the build gates are already
    /// covered on their own.
    eval_tasks_only: bool = false,
    iters: u32 = 3,
    dry_run: bool = false,
    verbose: bool = false,
    port: u16 = 17921,
};

pub fn parse(args: []const []const u8) !Options {
    var opts = Options{};
    var idx: usize = 1;
    var cmd_seen = false;
    var pending_sub: ?[]const u8 = null;

    while (idx < args.len) : (idx += 1) {
        const a = args[idx];

        // Once git is the active command, every remaining token — including
        // dash-prefixed ones like git's own flags/options — passes through to
        // git verbatim, so `clanker git status --porcelain` keeps its args.
        // cmdGit re-reads the raw argv itself; recording the token here only
        // absorbs it so it never reaches the flag parser below (no alloc).
        if (opts.command == .git) {
            opts.task = a;
            continue;
        }

        // Help flags act as the help command regardless of position.
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            if (cmd_seen) return error.UnknownArg;
            opts.command = .help;
            cmd_seen = true;
            continue;
        }

        // Known global flags may appear anywhere.
        if (a.len > 0 and a[0] == '-') {
            if (std.mem.eql(u8, a, "--verbose") or std.mem.eql(u8, a, "-v")) {
                opts.verbose = true;
            } else if (std.mem.eql(u8, a, "--dry-run")) {
                opts.dry_run = true;
            } else if (std.mem.eql(u8, a, "--tasks")) {
                opts.eval_tasks_only = true;
            } else if (std.mem.eql(u8, a, "--provider")) {
                idx += 1;
                if (idx >= args.len) return error.MissingArg;
                opts.provider = args[idx];
            } else if (std.mem.eql(u8, a, "--model")) {
                idx += 1;
                if (idx >= args.len) return error.MissingArg;
                opts.model = args[idx];
            } else if (std.mem.eql(u8, a, "--iters")) {
                idx += 1;
                if (idx >= args.len) return error.MissingArg;
                opts.iters = std.fmt.parseInt(u32, args[idx], 10) catch return error.BadIters;
            } else if (std.mem.eql(u8, a, "--session")) {
                idx += 1;
                if (idx >= args.len) return error.MissingArg;
                opts.session = args[idx];
            } else if (std.mem.eql(u8, a, "--goal")) {
                idx += 1;
                if (idx >= args.len) return error.MissingArg;
                opts.goal = args[idx];
            } else if (std.mem.eql(u8, a, "--port")) {
                idx += 1;
                if (idx >= args.len) return error.MissingArg;
                opts.port = std.fmt.parseInt(u16, args[idx], 10) catch return error.BadPort;
            } else {
                return error.UnknownArg;
            }
            continue;
        }

        // Non-flag token. The first one names the command; with no command
        // at all the default (the REPL) stands.
        if (!cmd_seen) {
            cmd_seen = true;
            if (std.mem.eql(u8, a, "init")) {
                opts.command = .init;
            } else if (std.mem.eql(u8, a, "provide") or std.mem.eql(u8, a, "providers")) {
                opts.command = .providers_check;
                pending_sub = "";
            } else if (std.mem.eql(u8, a, "run")) {
                opts.command = .run;
            } else if (std.mem.eql(u8, a, "sessions")) {
                opts.command = .sessions;
            } else if (std.mem.eql(u8, a, "tools")) {
                opts.command = .tools_list;
                pending_sub = "list";
            } else if (std.mem.eql(u8, a, "eval")) {
                opts.command = .eval;
            } else if (std.mem.eql(u8, a, "improve-self")) {
                opts.command = .improve_self;
            } else if (std.mem.eql(u8, a, "revert")) {
                opts.command = .revert;
            } else if (std.mem.eql(u8, a, "git")) {
                opts.command = .git;
            } else if (std.mem.eql(u8, a, "mcp")) {
                opts.command = .mcp;
            } else if (std.mem.eql(u8, a, "goal")) {
                opts.command = .goal;
            } else if (std.mem.eql(u8, a, "notify")) {
                opts.command = .notify;
            } else if (std.mem.eql(u8, a, "chat")) {
                opts.command = .chat;
                pending_sub = "";
            } else if (std.mem.eql(u8, a, "stats")) {
                opts.command = .stats;
            } else if (std.mem.eql(u8, a, "phonebook")) {
                opts.command = .phonebook;
            } else if (std.mem.eql(u8, a, "serve")) {
                opts.command = .serve;
            } else if (std.mem.eql(u8, a, "graph")) {
                opts.command = .graph;
            } else if (std.mem.eql(u8, a, "autolearn")) {
                opts.command = .autolearn;
            } else if (std.mem.eql(u8, a, "repl")) {
                opts.command = .repl;
            } else if (std.mem.eql(u8, a, "gate")) {
                opts.command = .gate;
            } else {
                return error.UnknownCommand;
            }
        } else if (pending_sub) |sub| {
            if (std.mem.eql(u8, a, sub)) {
                pending_sub = null;
            } else if (opts.command == .providers_check and sub.len == 0 and (std.mem.eql(u8, a, "check") or std.mem.eql(u8, a, "models"))) {
                opts.providers_sub = a;
                pending_sub = null; // sub consumed; next token is the provider name
            } else if (opts.command == .chat and sub.len == 0 and (std.mem.eql(u8, a, "send") or std.mem.eql(u8, a, "history") or std.mem.eql(u8, a, "rooms") or std.mem.eql(u8, a, "subscribe"))) {
                opts.chat_sub = a;
                pending_sub = null; // sub consumed; next tokens are room etc.
            } else {
                return error.BadSubcommand;
            }
        } else if (opts.command == .eval and opts.eval_name == null) {
            opts.eval_name = a;
        } else if (opts.command == .goal and opts.task == null) {
            opts.task = a;
        } else if (opts.command == .revert and opts.task == null) {
            opts.task = a;
        } else if (opts.command == .improve_self and opts.task == null) {
            opts.task = a;
        } else if (opts.command == .providers_check and opts.provider == null) {
            opts.provider = a;
        } else if (opts.command == .run and opts.task == null) {
            opts.task = a;
        } else if (opts.command == .graph and opts.task == null) {
            opts.task = a;
        } else if (opts.command == .notify and opts.peer == null) {
            opts.peer = a;
        } else if (opts.command == .notify and opts.message == null) {
            opts.message = a;
        } else if (opts.command == .chat and opts.room == null) {
            opts.room = a;
        } else if (opts.command == .chat and opts.message == null) {
            opts.message = a;
        } else {
            return error.UnknownArg;
        }
    }

    if (pending_sub != null) return error.BadSubcommand;
    if (opts.command == .run and opts.task == null) return error.MissingTask;
    if (opts.command == .notify and (opts.peer == null or opts.message == null)) return error.MissingArg;
    if (opts.command == .chat) {
        const needs_room = !std.mem.eql(u8, opts.chat_sub, "rooms");
        if (needs_room and opts.room == null) return error.MissingArg;
        if (std.mem.eql(u8, opts.chat_sub, "send") and opts.message == null) return error.MissingArg;
    }
    return opts;
}

pub fn printUsage(io: std.Io) void {
    writeStdErr(io, usage_text) catch {};
}

const usage_text =
    \\clanker — self-improving AI agent harness
    \\
    \\usage:
    \\  clanker init                    create config.local.json + state/
    \\  clanker providers check [name]  verify provider connectivity
    \\  clanker run "<task>"            run the agent on a task
    \\  clanker run --goal <id> "<task>"  run with an active goal
    \\  clanker run --session <id> "<task>"  continue a saved session
    \\  clanker repl                    interactive multi-turn chat (streams tokens)
    \\  clanker sessions                list saved sessions
    \\  clanker tools list              list registered WASM tools
    \\  clanker eval [name] [--tasks]   run evals (all, one by name, --tasks = capability only)
    \\  clanker improve-self [--iters N] [--dry-run] "<instructions>"  self-improvement loop
    \\  clanker revert <id>             revert a previously applied improvement
    \\  clanker goal "<intent>"         design and persist a structured goal
    \\  clanker graph [run-id]          list runs or render one as an ASCII timeline
    \\  clanker gate                    run deterministic gates (build/test/tools/fmt/lint)
    \\  clanker mcp                     serve tools over MCP (stdio)
    \\  clanker serve [--port N]        HTTP API + web UI (default port 17921)
    \\  clanker notify <peer> "<message>" send a notification to a peer
    \\  clanker chat send <room> "<text>"  send a message to a chatroom
    \\  clanker chat history <room> [after]  read chatroom history (newest first)
    \\  clanker chat rooms              list chatrooms + subscriptions
    \\  clanker chat subscribe <room> [on]  join/leave a chatroom (on = true/false)
    \\  clanker stats                   token usage per provider/model
    \\  clanker phonebook               list peer agent cards
    \\  clanker git <args...>           passthrough to git (e.g. clanker git status)
    \\  clanker --verbose               enable debug logging
    \\
;

pub fn run(init: std.process.Init, opts: Options) !void {
    switch (opts.command) {
        .help => try writeStdErr(init.io, usage_text),
        .init => try cmdInit(init),
        .providers_check => try cmdProvidersCheck(init, opts),
        .run => try cmdRun(init, opts),
        .sessions => try cmdSessions(init),
        .tools_list => try cmdToolsList(init, opts),
        .eval => try cmdEval(init, opts),
        .improve_self => try cmdImproveSelf(init, opts),
        .revert => try cmdRevert(init, opts),
        .git => try cmdGit(init, opts),
        .mcp => try cmdMcp(init, opts),
        .goal => try cmdGoal(init, opts),
        .notify => try cmdNotify(init, opts),
        .chat => try cmdChat(init, opts),
        .stats => try cmdStats(init),
        .phonebook => try cmdPhonebook(init),
        .serve => try cmdServe(init, opts),
        .repl => try cmdRepl(init, opts),
        .graph => try cmdGraph(init, opts),
        .autolearn => try cmdAutolearn(init, opts),
        .gate => try cmdGate(init, opts),
    }
}

fn writeStdErr(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
}

// -------------------------------------------------------------------- gate --

/// Runs the deterministic gates (build, test, tools, fmt, lint) in the
/// current directory. This wires the gate/checks.zig module into the CLI so
/// operators can verify the repo independently of the improve loop.
fn cmdGate(init: std.process.Init, opts: Options) !void {
    _ = opts;
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    // The other place that compiles repeatedly, and so the other place the
    // build cache grows without bound.
    const cfg = config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json") catch config.Config{};
    _ = diskcap.capBuildCache(gpa, io, std.Io.Dir.cwd(), ".zig-cache", cfg.improve.max_cache_bytes);
    try verifyGates(gpa, io, arena);
}

/// Runs all deterministic gates (build, test, tools, fmt, lint) against the
/// current checkout. Throws error.GateFailed on the first failure.
fn verifyGates(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator) !void {
    var build = try gate_checks.buildGate(gpa, io, std.Io.Dir.cwd(), &.{});
    defer build.deinit(gpa);
    log.log(.info, "build: {s}", .{if (build.ok) "PASS" else "FAIL"});
    if (!build.ok) return error.GateFailed;

    var test_gate = try gate_checks.testGate(gpa, io, std.Io.Dir.cwd());
    defer test_gate.deinit(gpa);
    log.log(.info, "tests: {s}", .{if (test_gate.ok) "PASS" else "FAIL"});
    if (!test_gate.ok) return error.GateFailed;

    var tools = try gate_checks.toolsGate(gpa, io, std.Io.Dir.cwd());
    defer tools.deinit(gpa);
    log.log(.info, "tools: {s}", .{if (tools.ok) "PASS" else "FAIL"});
    if (!tools.ok) return error.GateFailed;

    const files = try collectZigFiles(io, arena);
    var fmt = try gate_checks.fmtGate(gpa, io, std.Io.Dir.cwd(), files);
    defer fmt.deinit(gpa);
    log.log(.info, "fmt: {s}", .{if (fmt.ok) "PASS" else "FAIL"});
    if (!fmt.ok) return error.GateFailed;

    var lint = try gate_checks.lintGate(gpa, io, std.Io.Dir.cwd(), files);
    defer lint.deinit(gpa);
    log.log(.info, "lint: {s}", .{if (lint.ok) "PASS" else "FAIL"});
    if (!lint.ok) return error.GateFailed;

    log.log(.info, "all gates passed", .{});
}

/// Recursively collects all .zig file paths under the current directory.
fn collectZigFiles(io: std.Io, arena: std.mem.Allocator) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try walkZig(io, arena, &list, ".");
    return list.toOwnedSlice(arena);
}

fn walkZig(io: std.Io, arena: std.mem.Allocator, list: *std.ArrayList([]const u8), dir_path: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const sub = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        switch (entry.kind) {
            .directory => {
                // Only this project's own sources are gated. Dot-directories
                // cover .git and .zig-cache (whose generated options.zig and
                // dependencies.zig are not formatted, and are not ours to
                // format); zig-pkg is 1800 files of fetched dependencies.
                if (entry.name.len > 0 and entry.name[0] == '.') continue;
                if (std.mem.eql(u8, entry.name, "zig-out") or
                    std.mem.eql(u8, entry.name, "zig-pkg") or
                    std.mem.eql(u8, entry.name, "state")) continue;
                try walkZig(io, arena, list, sub);
            },
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".zig")) {
                    try list.append(arena, sub);
                }
            },
            else => {},
        }
    }
}

// -------------------------------------------------------------------- init --

/// Memorable auto-generated instance names (adjective-noun), so multi-instance
/// setups identify each other by names like "clanker-cobalt-otter" instead of
/// opaque ids.
const name_adjectives = [_][]const u8{ "amber", "azure", "cobalt", "crimson", "ember", "frost", "golden", "jade", "misty", "onyx", "rustic", "sage", "silver", "stormy", "swift", "velvet" };
const name_nouns = [_][]const u8{ "badger", "cactus", "dolphin", "falcon", "gecko", "heron", "jaguar", "koala", "lemur", "manta", "narwhal", "otter", "panda", "quokka", "raven", "sloth", "tiger", "viper", "wolf", "zebra" };

fn friendlyInstanceName(arena: std.mem.Allocator, io: std.Io) !struct { name: []const u8, id: []const u8 } {
    const ts: u64 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
    var prng = std.Random.DefaultPrng.init(ts ^ (ts >> 32));
    const r = prng.random();
    const adj = name_adjectives[r.uintLessThan(usize, name_adjectives.len)];
    const noun = name_nouns[r.uintLessThan(usize, name_nouns.len)];
    const id = try std.fmt.allocPrint(arena, "{s}-{s}", .{ adj, noun });
    const name = try std.fmt.allocPrint(arena, "clanker-{s}", .{id});
    return .{ .name = name, .id = id };
}

const local_template =
    \\{{
    \\  "default_provider": "deepseek",
    \\  "providers": {{
    \\    "deepseek": {{ "kind": "openai_compat", "base_url": "https://api.deepseek.com", "api_key_env": "DEEPSEEK_API_KEY", "model": "deepseek-chat", "max_tokens": 2048 }}
    \\  }},
    \\  "instance": {{ "name": "{s}", "id": "{s}" }},
    \\  "agent": {{ "max_iterations": 12 }},
    \\  "improve": {{ "min_delta": 0.05 }}
    \\}}
    \\
;

fn cmdInit(init: std.process.Init) !void {
    const io = init.io;
    const dir = std.Io.Dir.cwd();
    const arena = init.arena.allocator();
    const local = "config.local.json";
    _ = dir.openFile(io, local, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const ident = try friendlyInstanceName(arena, io);
            const content = try std.fmt.allocPrint(arena, local_template, .{ ident.name, ident.id });
            try atomic_write.writeFile(io, dir, local, content);
            log.log(.info, "wrote {s} (instance '{s}')", .{ local, ident.name });
        },
        else => return err,
    };
    dir.createDirPath(io, "state") catch {};
    log.log(.info, "clanker initialized. Export DEEPSEEK_API_KEY, then run: clanker run \"hello\"", .{});
}

// --------------------------------------------------------- providers check --

fn cmdProvidersCheck(init: std.process.Init, opts: Options) !void {
    if (std.mem.eql(u8, opts.providers_sub, "models")) {
        return cmdProvidersModels(init, opts);
    }
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    var ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = init.environ_map };

    var it = cfg.providers.iterator();
    var found_any = false;
    var checked_any = false;
    while (it.next()) |kv| {
        const name = kv.key_ptr.*;
        if (opts.provider) |want| {
            if (!std.mem.eql(u8, want, name)) continue;
        }
        found_any = true;
        const p = kv.value_ptr.*;

        if (p.api_key_env) |env_name| {
            if (init.environ_map.get(env_name) == null) {
                log.log(.warn, "{s}: skipped — env var {s} not set", .{ name, env_name });
                continue;
            }
        }

        const messages = [_]types.Message{.{ .role = .user, .content = "ping" }};
        var err_detail: ?[]const u8 = null;
        const t0 = std.Io.Timestamp.now(io, .awake);
        const resp = client.chat(&ctx, arena, .{ .provider = &p, .messages = &messages, .max_tokens = 1 }, &err_detail) catch |err| {
            switch (err) {
                error.ApiError => log.log(.error_, "{s}: {s}", .{ name, err_detail orelse "API error" }),
                else => log.log(.error_, "{s}: {s}", .{ name, @errorName(err) }),
            }
            continue;
        };
        const t1 = std.Io.Timestamp.now(io, .awake);
        const ms = @divTrunc(t0.durationTo(t1).nanoseconds, std.time.ns_per_ms);
        const tok = if (resp.usage) |u| u.total_tokens else 0;
        checked_any = true;
        log.log(.info, "{s}: OK — {s} — {d}ms ({d} tok) cost={any}", .{ name, p.activeModelName(), ms, tok, p.activeModel().cost_per_1m_input });
    }
    if (opts.provider != null and !found_any) return error.UnknownProvider;
    if (opts.provider != null and !checked_any) return error.ProviderCheckFailed;
}

/// `clanker providers models [provider]` — list a provider's models with their
/// context window. With provider name "openrouter", pulls OpenRouter's model
/// database (context_length + per-1M pricing) filtered to our providers'
/// model families.
fn cmdProvidersModels(init: std.process.Init, opts: Options) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");

    const provider_name = opts.provider orelse cfg.default_provider;
    const out = std.Io.File.stdout();

    if (std.mem.eql(u8, provider_name, "openrouter")) {
        // Pull OpenRouter's public model database.
        const body = try httpGet(io, gpa, arena, "https://openrouter.ai/api/v1/models", null);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{ .ignore_unknown_fields = true });
        try out.writeStreamingAll(io, "id\tctx\tin $/1M\tout $/1M\n");
        const families = [_][]const u8{ "kimi", "moonshot", "deepseek", "muse" };
        if (parsed == .object) {
            if (parsed.object.get("data")) |data| {
                if (data == .array) {
                    for (data.array.items) |item| {
                        if (item != .object) continue;
                        const id = fieldStr(item.object, "id") orelse continue;
                        var relevant = false;
                        for (families) |f| {
                            if (std.ascii.indexOfIgnoreCase(id, f) != null) {
                                relevant = true;
                                break;
                            }
                        }
                        if (!relevant) continue;
                        const ctx = if (item.object.get("context_length")) |c| switch (c) {
                            .integer => |i| i,
                            else => 0,
                        } else 0;
                        var in_rate: f64 = 0;
                        var out_rate: f64 = 0;
                        if (item.object.get("pricing")) |p| {
                            if (p == .object) {
                                if (p.object.get("prompt")) |v| {
                                    switch (v) {
                                        .integer, .float, .number_string, .string => in_rate = numToF64(v),
                                        else => {},
                                    }
                                }
                                if (p.object.get("completion")) |v| {
                                    switch (v) {
                                        .integer, .float, .number_string, .string => out_rate = numToF64(v),
                                        else => {},
                                    }
                                }
                            }
                        }
                        const line = try std.fmt.allocPrint(arena, "{s}\t{d}\t{d:.2}\t{d:.2}\n", .{ id, ctx, in_rate * 1_000_000, out_rate * 1_000_000 });
                        try out.writeStreamingAll(io, line);
                    }
                }
            }
        }
        return;
    }

    // Provider's own OpenAI-compat /models endpoint.
    const provider = try cfg.provider(provider_name);
    const url = try std.fmt.allocPrint(arena, "{s}/models", .{std.mem.trimEnd(u8, provider.base_url, "/")});
    const bearer = if (provider.api_key_env) |env_name| blk: {
        const key = init.environ_map.get(env_name) orelse break :blk null;
        break :blk try std.fmt.allocPrint(arena, "Bearer {s}", .{key});
    } else null;
    const body = try httpGet(io, gpa, arena, url, bearer);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{ .ignore_unknown_fields = true });
    try out.writeStreamingAll(io, "id\tctx\n");
    if (parsed == .object) {
        if (parsed.object.get("data")) |data| {
            if (data == .array) {
                for (data.array.items) |item| {
                    if (item != .object) continue;
                    const id = fieldStr(item.object, "id") orelse continue;
                    const ctx = if (item.object.get("context_length")) |c| switch (c) {
                        .integer => |i| i,
                        else => 0,
                    } else 0;
                    const line = try std.fmt.allocPrint(arena, "{s}\t{d}\n", .{ id, ctx });
                    try out.writeStreamingAll(io, line);
                }
            }
        }
    }
}

fn fieldStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |v| {
        if (v == .string) return v.string;
    }
    return null;
}

fn numToF64(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch 0,
        .string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => 0,
    };
}

fn httpGet(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, url: []const u8, bearer: ?[]const u8) ![]const u8 {
    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    var buf: [1 << 20]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var headers: std.http.Client.Request.Headers = .{
        .user_agent = .{ .override = "clanker/0.1.0" },
    };
    if (bearer) |b| headers.authorization = .{ .override = b };
    const res = try http.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = headers,
        .response_writer = &w,
    });
    if (@intFromEnum(res.status) >= 400) return error.HttpError;
    return arena.dupe(u8, buf[0..w.end]);
}

/// `clanker autolearn` — review usage observations, refresh the roadmap
/// Autolearn section, and print the generated items.
fn cmdAutolearn(init: std.process.Init, opts: Options) !void {
    _ = opts;
    const io = init.io;
    const gpa = init.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    if (!cfg.modules.autolearn) {
        log.log(.error_, "autolearn module is disabled (modules.autolearn=false in config)", .{});
        return error.ModuleDisabled;
    }
    const section = try autolearn.review(io, gpa, arena);
    try autolearn.applyRoadmap(io, gpa, arena, section);
    const out = std.Io.File.stdout();
    try out.writeStreamingAll(io, "Autolearn section updated in docs/ROADMAP.md\n\n");
    try out.writeStreamingAll(io, section);
}

// ---------------------------------------------------------------------- run --

/// Reports a run that stopped at a limit instead of finishing.
///
/// The point is that the work is not lost. The conversation is the caller's,
/// so the last thing the model actually said is still here even though `run`
/// returned an error, and the execution graph for the attempt is already on
/// disk. Printing those beats a stack trace: it tells the operator what was
/// reached, what it cost, and which knob to turn.
fn reportUnfinishedRun(
    out_w: *std.Io.File.Writer,
    messages: *const std.ArrayList(types.Message),
    a: *const agent.Agent,
    err: anyerror,
) !void {
    // Walk back to the last thing the assistant said with words in it. The
    // final turns of a capped run are usually tool calls with no prose.
    var partial: ?[]const u8 = null;
    var i = messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = messages.items[i];
        if (m.role != .assistant) continue;
        if (m.content) |c| {
            if (std.mem.trim(u8, c, " \t\r\n").len > 0) {
                partial = c;
                break;
            }
        }
    }

    if (partial) |c| {
        try out_w.interface.writeAll(c);
        if (!std.mem.endsWith(u8, c, "\n")) try out_w.interface.writeAll("\n");
        try out_w.interface.flush();
    }

    const why = switch (err) {
        error.MaxIterationsExceeded => "hit the iteration limit",
        error.SessionTokenBudgetExceeded => "hit the session token budget",
        else => "stopped early",
    };
    log.log(.error_, "run {s} after {d} iterations and did not produce a final answer", .{ why, a.max_iterations });
    if (partial != null) {
        log.log(.info, "the assistant's last message is printed above; it is partial work, not an answer", .{});
    } else {
        log.log(.info, "the assistant produced no prose before stopping; `clanker graph` replays what it did", .{});
    }
    if (err == error.MaxIterationsExceeded) {
        log.log(.info, "raise agent.max_iterations in config.json (currently {d}) if the task needs more steps", .{a.max_iterations});
    }
}

fn cmdRun(init: std.process.Init, opts: Options) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    var ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = init.environ_map, .cfg = &cfg };

    var provider = try cfg.provider(opts.provider);
    var provider_copy = provider.*;
    if (opts.model) |m| provider_copy.default_model = m;
    provider = &provider_copy;

    // Make sure the sandbox root exists.
    std.Io.Dir.cwd().createDirPath(io, cfg.agent.sandbox_root) catch {};

    var reg = try registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir);
    const tool_defs = try reg.toToolDefs(arena);

    var a = try agent.Agent.init(&ctx, arena, provider, &cfg, &reg, tool_defs);
    a.subagent_runner = if (cfg.modules.subagents) &subagent.runNested else null;
    var messages: std.ArrayList(types.Message) = .empty;
    var created: i64 = 0;
    if (opts.session) |sid| {
        const maybe_s = session.loadSession(io, init.gpa, arena, std.Io.Dir.cwd(), sid) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (maybe_s) |s| {
            created = s.created;
            for (s.messages) |m| {
                if (m.role == .system) continue;
                try messages.append(arena, m);
            }
        } else {
            log.log(.info, "no existing session '{s}', starting fresh", .{sid});
            created = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
        }
    }
    var task_text = opts.task.?;
    if (opts.goal) |goal_id| {
        var goal_found = false;
        const goals_raw = std.Io.Dir.cwd().readFileAlloc(io, "state/goals.json", arena, .limited(1 << 20)) catch null;
        if (goals_raw) |raw| {
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch null;
            if (parsed) |root| {
                if (root == .array) {
                    for (root.array.items) |item| {
                        if (item == .object) {
                            const obj = item.object;
                            if (obj.get("id")) |idv| {
                                if (idv == .string and std.mem.eql(u8, idv.string, goal_id)) {
                                    const objective = if (obj.get("objective")) |v| if (v == .string) v.string else "" else "";
                                    const completion = if (obj.get("completion_criterion")) |v| if (v == .string) v.string else "" else "";
                                    const boundaries = if (obj.get("boundaries")) |v| if (v == .string) v.string else "" else "";
                                    const goal_section = try std.fmt.allocPrint(arena, "## Active goal\n\nobjective: {s}\ncompletion_criterion: {s}\nboundaries: {s}\n\n", .{ objective, completion, boundaries });
                                    task_text = try std.fmt.allocPrint(arena, "{s}{s}", .{ goal_section, opts.task.? });
                                    goal_found = true;
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }
        if (!goal_found) log.log(.warn, "goal '{s}' not found in state/goals.json — running without goal context", .{goal_id});
    }
    compactMessages(&messages, max_turn_tokens);
    var err_detail: ?[]const u8 = null;

    // Answer text streams to stdout as it arrives (identical bytes to the
    // old at-once write, just delivered incrementally); on a real terminal
    // the wait for the LLM/tools is covered by a spinner + tool status line
    // on stderr, so piping stdout to a file or another process still gets
    // clean, tool-free content.
    const stdout_file = std.Io.File.stdout();
    var out_buf: [4096]u8 = undefined;
    var out_w = stdout_file.writerStreaming(io, &out_buf);
    run_out = &out_w;
    run_stdout_color = stdout_file.isTty(io) catch false;
    a.on_token = &runDelta;

    // The spinner and the live tool-status line belong to the REPL. `run` is
    // a one-shot command that gets piped, redirected and read by scripts, so
    // it stays plain: streamed answer on stdout, log lines on stderr, no
    // animation to clean up out of a captured log.
    repl_answer_started = false;
    repl_md = .{};
    const resp = a.run(&messages, task_text, &err_detail) catch |err| {
        // Running out of iterations or budget is an outcome, not a crash. The
        // run did real work — often minutes of it and a measurable amount of
        // money — and returning the error threw all of it away behind a Zig
        // stack trace that points at loop.zig internals and reads like a bug
        // in the harness.
        switch (err) {
            error.MaxIterationsExceeded, error.SessionTokenBudgetExceeded => {
                try reportUnfinishedRun(&out_w, &messages, &a, err);
                std.process.exit(1);
            },
            else => {},
        }
        log.log(.error_, "{s}", .{err_detail orelse @errorName(err)});
        return err;
    };

    const streamed = a.on_token != null and cfg.modules.streaming;
    if (!streamed) {
        if (run_stdout_color) try out_w.interface.writeAll("\x1b[1;35m\xe2\x80\xba \x1b[0m");
        if (resp.message.content) |c| {
            if (run_stdout_color) {
                run_md.feed(&out_w.interface, c);
            } else {
                try out_w.interface.writeAll(c);
            }
        }
    }
    if (run_stdout_color) run_md.flush(&out_w.interface);
    try out_w.interface.writeAll("\n");
    try out_w.interface.flush();

    if (opts.session) |sid| {
        const title = std.mem.trim(u8, opts.task.?[0..@min(opts.task.?.len, 60)], " \t\r\n");
        const updated: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
        if (!cfg.modules.sessions) return;
        compactMessages(&messages, max_session_tokens);
        try session.saveSession(io, init.gpa, arena, std.Io.Dir.cwd(), .{
            .id = sid,
            .title = title,
            .messages = messages.items,
            .created = created,
            .updated = updated,
        });
    }
}

fn cmdRepl(init: std.process.Init, opts: Options) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    var ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = init.environ_map, .cfg = &cfg };

    var provider = try cfg.provider(opts.provider);
    var provider_copy = provider.*;
    if (opts.model) |m| provider_copy.default_model = m;
    provider = &provider_copy;

    // Make sure the sandbox root exists.
    std.Io.Dir.cwd().createDirPath(io, cfg.agent.sandbox_root) catch {};

    var reg = try registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir);
    const tool_defs = try reg.toToolDefs(arena);

    var a = try agent.Agent.init(&ctx, arena, provider, &cfg, &reg, tool_defs);
    a.subagent_runner = if (cfg.modules.subagents) &subagent.runNested else null;
    var messages: std.ArrayList(types.Message) = .empty;

    const exe_path = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe_path);

    var created: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    var sid: []const u8 = undefined;
    if (opts.session) |sid_arg| {
        // Resuming a hot-reloaded session: load its transcript.
        if (session.loadSession(io, gpa, arena, std.Io.Dir.cwd(), sid_arg)) |s| {
            created = s.created;
            for (s.messages) |m| {
                if (m.role == .system) continue;
                try messages.append(arena, m);
            }
        } else |_| {}
        sid = sid_arg;
    } else {
        sid = try std.fmt.allocPrint(arena, "repl-{d}", .{created});
    }

    // Hot-reload: a background thread watches the binary and re-execs into
    // `repl --session <sid>` (resuming this exact session) once a rebuild
    // lands and it's safe to do so (see HotReload doc comment).
    if (cfg.modules.hot_reload) {
        hot_reload_active = HotReload.start(arena, io, gpa, exe_path, try buildReplArgvTail(arena, sid, opts));
    }

    const stdin_file = std.Io.File.stdin();
    var stdout_file = std.Io.File.stdout();
    var out_buf: [4096]u8 = undefined;
    var out_w = stdout_file.writerStreaming(io, &out_buf);

    // Stream the model's tokens to stdout as they arrive.
    repl_out = &out_w;
    repl_io = io;
    ask_out = &out_w;
    ask_stdin = stdin_file;
    ask_gpa = gpa;
    // Only a terminal can answer; a piped session would block forever on a
    // prompt nobody sees.
    ask_interactive = stdin_file.isTty(io) catch false;
    if (ask_interactive) a.ask_fn = &replAsk;
    a.on_token = &replDelta;
    a.on_tool_call = &replToolCall;
    a.on_tool_result = &replToolResult;

    try out_w.interface.print(
        "\x1b[1;35m\xe2\x9a\xa1 clanker\x1b[0m \x1b[2mrepl \xc2\xb7 {s}/{s}\x1b[0m\n\x1b[2mtype a task \xc2\xb7 :help for commands \xc2\xb7 :quit to leave\x1b[0m\n\n",
        .{ provider.name, provider.activeModelName() },
    );
    try out_w.interface.flush();

    // On a terminal, keystrokes go through the line editor: a cooked TTY hands
    // over whole lines and leaves arrow keys as literal escape bytes in the
    // buffer, which is why history recall did nothing. Piped input keeps the
    // plain read loop below, so scripts and the improvement loop are
    // unaffected by any of this.
    var editor = lineedit.Editor{ .gpa = gpa };
    defer editor.deinit();
    const interactive = (stdin_file.isTty(io) catch false) and (stdout_file.isTty(io) catch false);
    if (interactive) {
        loadReplHistory(io, gpa, &editor);
        while (true) {
            const entered = readLineRaw(io, stdin_file, &out_w, &editor) catch |err| {
                if (err == error.EndOfStream) break;
                log.log(.error_, "repl read error: {s}", .{@errorName(err)});
                break;
            } orelse break;
            const trimmed = std.mem.trim(u8, entered, " \t\r\n");
            if (trimmed.len == 0) continue;
            editor.remember(trimmed);
            saveReplHistory(io, gpa, &editor);
            const owned = try arena.dupe(u8, trimmed);
            if (try replHandleLine(io, gpa, arena, &out_w, &a, &messages, &cfg, init.environ_map, &reg, owned, created, sid)) return;
        }
        try out_w.interface.writeAll("\n");
        try out_w.interface.flush();
        return;
    }

    // Accumulate raw stdin and split on newlines: readSliceShort can return
    // several lines at once (piped input), and each task line must be copied
    // into the arena before the accumulator buffer is shifted (messages keep
    // referencing it across turns).
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(gpa);
    var tmp: [4096]u8 = undefined;

    while (true) {
        try out_w.interface.writeAll("\x1b[32mclanker> \x1b[0m");
        try out_w.interface.flush();

        // Short read on the raw fd: readSliceShort blocks until the buffer is
        // full or EOF, which never happens on an interactive TTY (it reads the
        // first line, then blocks for more) — the REPL would silently swallow
        // input. posix.read returns whatever is available (one canonical line
        // on a TTY), retrying on EINTR.
        const n = std.posix.read(stdin_file.handle, &tmp) catch |err| {
            log.log(.error_, "repl read error: {s}", .{@errorName(err)});
            return err;
        };
        if (n == 0) {
            // EOF: flush a trailing partial line, then exit.
            const last = std.mem.trim(u8, acc.items, " \t\r\n");
            if (last.len > 0) {
                const owned = try arena.dupe(u8, last);
                const quit = try replRunTurn(io, &out_w, &a, &messages, owned, created, sid);
                if (quit) return;
            }
            try out_w.interface.writeAll("\n");
            try out_w.interface.flush();
            return;
        }
        try acc.appendSlice(gpa, tmp[0..n]);
        while (std.mem.indexOfScalar(u8, acc.items, '\n')) |nl| {
            const line = std.mem.trim(u8, acc.items[0..nl], " \t\r\n");
            // Use `line` only before the buffer is shifted below: it is a
            // view into acc.items, so the copyForwards would overwrite it.
            if (line.len == 0) {
                const rest0 = acc.items[nl + 1 ..];
                std.mem.copyForwards(u8, acc.items[0..rest0.len], rest0);
                acc.items.len = rest0.len;
                continue;
            }
            if (std.mem.eql(u8, line, ":quit") or std.mem.eql(u8, line, ":q") or std.mem.eql(u8, line, ":exit")) {
                try out_w.interface.writeAll("\n");
                try out_w.interface.flush();
                return;
            }
            if (std.mem.eql(u8, line, ":help")) {
                try out_w.interface.writeAll("REPL commands: :quit  :help  /goal <intent>  /<cmd> [args]  (any other text is a task)\nWhen an answer offers numbered options, reply with just the number.\n");
                try out_w.interface.flush();
                const rest1 = acc.items[nl + 1 ..];
                std.mem.copyForwards(u8, acc.items[0..rest1.len], rest1);
                acc.items.len = rest1.len;
                continue;
            }
            if (line[0] == '/') {
                // Slash commands: /quit|/exit leave the REPL, /goal runs the
                // agent (which persists via the goal WASM tool), everything
                // else dispatches to an internal cmd_<name> WASM tool.
                // NOTE: `line` is a view into acc.items and must be fully
                // consumed BEFORE the buffer is shifted below.
                if (std.mem.eql(u8, line, "/quit") or std.mem.eql(u8, line, "/q") or std.mem.eql(u8, line, "/exit")) {
                    try out_w.interface.writeAll("\n");
                    try out_w.interface.flush();
                    return;
                }
                if (std.mem.startsWith(u8, line, "/autolearn")) {
                    const arg = std.mem.trimStart(u8, line["/autolearn".len..], " ");
                    if (std.mem.eql(u8, arg, "on") or std.mem.eql(u8, arg, "off")) {
                        const on = std.mem.eql(u8, arg, "on");
                        cfg.modules.autolearn = on;
                        persistModules(io, gpa, arena, &cfg);
                        try out_w.interface.writeAll(if (on) "autolearn enabled\n" else "autolearn disabled\n");
                        try out_w.interface.flush();
                    } else {
                        try out_w.interface.writeAll(if (cfg.modules.autolearn) "autolearn is ON\n" else "autolearn is OFF\n");
                        try out_w.interface.flush();
                    }
                    const al_rest = acc.items[nl + 1 ..];
                    std.mem.copyForwards(u8, acc.items[0..al_rest.len], al_rest);
                    acc.items.len = al_rest.len;
                    continue;
                }
                var goal_task: ?[]const u8 = null;
                if (std.mem.startsWith(u8, line, "/goal")) {
                    const intent = std.mem.trimStart(u8, line["/goal".len..], " ");
                    if (intent.len == 0) {
                        try out_w.interface.writeAll("usage: /goal <intent>\n");
                        try out_w.interface.flush();
                    } else {
                        goal_task = try std.fmt.allocPrint(arena, "Design and persist a structured goal for: {s}\n\nDefine all five fields (objective, completion_criterion, proof, boundaries, stop_rule) and call the goal tool to persist it.", .{intent});
                    }
                } else {
                    const toggled = std.mem.startsWith(u8, line, "/plugins ");
                    try replSlashTool(io, gpa, arena, &cfg, init.environ_map, &reg, line, &out_w);
                    if (toggled) {
                        // /plugins rewrote state/plugins.json; reload so the
                        // next turn's tool catalog reflects it without a restart.
                        reg = try registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir);
                        a.tool_defs = try reg.toToolDefs(arena);
                    }
                }
                const slash_rest = acc.items[nl + 1 ..];
                std.mem.copyForwards(u8, acc.items[0..slash_rest.len], slash_rest);
                acc.items.len = slash_rest.len;
                if (goal_task) |gt| {
                    const owned = try arena.dupe(u8, gt);
                    const quit = try replRunTurn(io, &out_w, &a, &messages, owned, created, sid);
                    if (quit) return;
                }
                continue;
            }
            // A bare number answers the last multiple-choice question: send
            // the option's own words, so the model reads an answer rather
            // than a digit with no referent.
            const picked: ?[]const u8 = blk: {
                if (repl_choices.items.len == 0) break :blk null;
                const digits = std.mem.trimEnd(u8, line, ".)");
                const idx = std.fmt.parseInt(usize, digits, 10) catch break :blk null;
                if (idx < 1 or idx > repl_choices.items.len) break :blk null;
                break :blk repl_choices.items[idx - 1];
            };
            // Copy the task text into the arena BEFORE shifting the buffer:
            // messages keep referencing it across turns.
            const owned = try arena.dupe(u8, picked orelse line);
            if (picked) |choice| {
                a.pending_decision = .{ .question = repl_last_question, .answer = owned };
                const echo = try std.fmt.allocPrint(arena, "\x1b[2m→ {s}\x1b[0m\n", .{choice});
                try out_w.interface.writeAll(echo);
                try out_w.interface.flush();
            }
            const rest = acc.items[nl + 1 ..];
            std.mem.copyForwards(u8, acc.items[0..rest.len], rest);
            acc.items.len = rest.len;
            const quit = try replRunTurn(io, &out_w, &a, &messages, owned, created, sid);
            if (quit) return;
        }
    }
}

/// One line typed at the interactive prompt. Returns true when the REPL should
/// exit. The buffered (piped) path keeps its own inline handling; this covers
/// the same commands for the raw-mode path.
fn replHandleLine(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out_w: *std.Io.File.Writer,
    a: *agent.Agent,
    messages: *std.ArrayList(types.Message),
    cfg: *config.Config,
    environ_map: *std.process.Environ.Map,
    reg: *registry.Registry,
    line: []const u8,
    created: i64,
    sid: []const u8,
) !bool {
    if (std.mem.eql(u8, line, ":quit") or std.mem.eql(u8, line, ":q") or std.mem.eql(u8, line, ":exit")) return true;
    if (std.mem.eql(u8, line, ":help")) {
        try out_w.interface.writeAll("REPL commands: :quit  :help  /goal <intent>  /<cmd> [args]  (any other text is a task)\nWhen an answer offers numbered options, reply with just the number.\nUp/Down recall history; Ctrl-A/E move, Ctrl-U/K/W delete.\n");
        try out_w.interface.flush();
        return false;
    }
    if (line.len > 0 and line[0] == '/') {
        if (std.mem.startsWith(u8, line, "/quit") or std.mem.startsWith(u8, line, "/exit")) return true;
        if (std.mem.startsWith(u8, line, "/goal")) {
            const intent = std.mem.trimStart(u8, line["/goal".len..], " ");
            if (intent.len == 0) {
                try out_w.interface.writeAll("usage: /goal <intent>\n");
                try out_w.interface.flush();
                return false;
            }
            const task = try std.fmt.allocPrint(arena, "Design and persist a structured goal for: {s}\n\nDefine all five fields (objective, completion_criterion, proof, boundaries, stop_rule) and call the goal tool to persist it.", .{intent});
            return replRunTurn(io, out_w, a, messages, task, created, sid);
        }
        const toggled = std.mem.startsWith(u8, line, "/plugins ");
        try replSlashTool(io, gpa, arena, cfg, environ_map, reg, line, out_w);
        if (toggled) {
            reg.* = try registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir);
            a.tool_defs = try reg.toToolDefs(arena);
        }
        return false;
    }
    // A bare number answers the last multiple-choice question.
    var task = line;
    if (repl_choices.items.len > 0) {
        const digits = std.mem.trimEnd(u8, line, ".)");
        if (std.fmt.parseInt(usize, digits, 10) catch null) |idx| {
            if (idx >= 1 and idx <= repl_choices.items.len) {
                task = try arena.dupe(u8, repl_choices.items[idx - 1]);
                const echo = try std.fmt.allocPrint(arena, "\x1b[2m\xe2\x86\x92 {s}\x1b[0m\n", .{task});
                try out_w.interface.writeAll(echo);
                try out_w.interface.flush();
                // The run this starts exists because of that pick; the graph
                // says so instead of showing a task with no visible cause.
                a.pending_decision = .{ .question = repl_last_question, .answer = task };
            }
        }
    }
    return replRunTurn(io, out_w, a, messages, task, created, sid);
}

/// REPL history file: recall survives restarts, which is most of the point.
const repl_history_path = "state/repl_history";

fn loadReplHistory(io: std.Io, gpa: std.mem.Allocator, editor: *lineedit.Editor) void {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, repl_history_path, gpa, .limited(1 << 20)) catch return;
    defer gpa.free(raw);
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |l| {
        const t = std.mem.trim(u8, l, " \t\r");
        if (t.len > 0) editor.remember(t);
    }
    editor.reset();
}

fn saveReplHistory(io: std.Io, gpa: std.mem.Allocator, editor: *const lineedit.Editor) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (editor.history.items) |h| {
        buf.appendSlice(gpa, h) catch return;
        buf.append(gpa, '\n') catch return;
    }
    std.Io.Dir.cwd().createDirPath(io, "state") catch {};
    atomic_write.writeFile(io, std.Io.Dir.cwd(), repl_history_path, buf.items) catch {};
}

/// Reads one line in raw mode, redrawing as it is edited. Returns null on EOF
/// or Ctrl-C, so the caller can leave.
fn readLineRaw(
    io: std.Io,
    stdin_file: std.Io.File,
    out_w: *std.Io.File.Writer,
    editor: *lineedit.Editor,
) !?[]const u8 {
    const original = std.posix.tcgetattr(stdin_file.handle) catch return error.NotATerminal;
    var raw = original;
    // Character-at-a-time, no echo: the editor draws the line itself.
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    std.posix.tcsetattr(stdin_file.handle, .FLUSH, raw) catch return error.NotATerminal;
    defer std.posix.tcsetattr(stdin_file.handle, .FLUSH, original) catch {};
    // Bracketed paste: the terminal wraps a pasted block in ESC[200~/201~,
    // which the line editor reads as literal newlines instead of submits, so
    // a multi-line paste lands as one input rather than one turn per line.
    try out_w.interface.writeAll("\x1b[?2004h");
    try out_w.interface.flush();
    defer {
        out_w.interface.writeAll("\x1b[?2004l") catch {};
        out_w.interface.flush() catch {};
    }
    _ = io;

    editor.reset();
    try redraw(out_w, editor);

    var pending: [64]u8 = undefined;
    var pending_len: usize = 0;
    while (true) {
        var byte: [1]u8 = undefined;
        const n = std.posix.read(stdin_file.handle, &byte) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return null;
        if (pending_len == pending.len) pending_len = 0; // never seen; stay safe
        pending[pending_len] = byte[0];
        pending_len += 1;

        // An escape sequence arrives in pieces; decode() reports null until
        // it has enough bytes to be sure what the key was.
        const decoded = lineedit.decode(pending[0..pending_len]) orelse continue;
        pending_len = 0;

        switch (decoded.key) {
            .interrupt => {
                try out_w.interface.writeAll("^C\n");
                try out_w.interface.flush();
                editor.reset();
                try redraw(out_w, editor);
                continue;
            },
            .eof => if (editor.len == 0) return null,
            .clear_screen => {
                // Ctrl-L: wipe the screen and repaint the prompt with the
                // line being edited, as every cooked shell does.
                try out_w.interface.writeAll("\x1b[2J\x1b[H");
                try redraw(out_w, editor);
                continue;
            },
            else => {},
        }
        const done = editor.apply(decoded.key);
        try redraw(out_w, editor);
        if (done) {
            try out_w.interface.writeAll("\n");
            try out_w.interface.flush();
            return editor.line();
        }
    }
}

/// Repaints the prompt and the line, then parks the cursor where the editor
/// thinks it is.
fn redraw(out_w: *std.Io.File.Writer, editor: *const lineedit.Editor) !void {
    try out_w.interface.writeAll("\r\x1b[K\x1b[32mclanker> \x1b[0m");
    try out_w.interface.writeAll(editor.line());
    if (editor.cursor < editor.len) {
        const back = editor.len - editor.cursor;
        try out_w.interface.print("\x1b[{d}D", .{back});
    }
    try out_w.interface.flush();
}

/// Set for the duration of a REPL session so the ask_user tool can reach the
/// terminal. A tool call runs deep inside the sandbox with no writer of its
/// own, so the pieces it needs are parked here.
var ask_out: ?*std.Io.File.Writer = null;
var ask_stdin: ?std.Io.File = null;
var ask_gpa: ?std.mem.Allocator = null;
var ask_interactive = false;

/// ask_user's terminal side: print the question, wait for a number, return the
/// chosen option. The returned slice is gpa-owned; ckAsk frees it.
fn replAsk(question: []const u8, options: []const []const u8) anyerror![]const u8 {
    const gpa = ask_gpa orelse return error.NoUser;
    const out_w = ask_out orelse return error.NoUser;
    const stdin_file = ask_stdin orelse return error.NoUser;

    replClearThinking();
    try out_w.interface.print("\n\x1b[1;33m? \x1b[0m{s}\n", .{question});
    for (options, 1..) |o, n| {
        try out_w.interface.print("  \x1b[1;36m{d}\x1b[0m \x1b[2m·\x1b[0m {s}\n", .{ n, o });
    }
    try out_w.interface.writeAll("  \x1b[2mpick a number\x1b[0m ");
    try out_w.interface.flush();

    // Read the pick directly: the agent is mid-turn, so the REPL's own input
    // loop is not running to do it for us.
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        var byte: [1]u8 = undefined;
        const n = std.posix.read(stdin_file.handle, &byte) catch break;
        if (n == 0) break;
        if (byte[0] == '\n' or byte[0] == '\r') break;
        buf[len] = byte[0];
        len += 1;
    }
    const typed = std.mem.trim(u8, buf[0..len], " \t\r\n.)");
    const idx = std.fmt.parseInt(usize, typed, 10) catch 0;
    // An unreadable or out-of-range answer takes the first option rather than
    // failing the tool call: the model asked because it needed *an* answer.
    const chosen = if (idx >= 1 and idx <= options.len) options[idx - 1] else options[0];
    try out_w.interface.print("\x1b[2m\xe2\x86\x92 {s}\x1b[0m\n", .{chosen});
    try out_w.interface.flush();
    replShowThinking();
    return gpa.dupe(u8, chosen);
}

/// Dispatches a `/cmd [args]` line to the internal WASM tool `cmd_<cmd>` and
/// prints its `{"ok":true,"text":"..."}` output.
fn replSlashTool(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: *const config.Config, environ_map: *std.process.Environ.Map, reg: *const registry.Registry, line: []const u8, out_w: *std.Io.File.Writer) !void {
    const rest_start = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
    const name = line[1..rest_start];
    const args = std.mem.trimStart(u8, line[rest_start..], " ");

    const tool_name = try std.fmt.allocPrint(arena, "cmd_{s}", .{name});
    const tool = reg.get(tool_name) orelse {
        try out_w.interface.writeAll("unknown command: /");
        try out_w.interface.writeAll(name);
        try out_w.interface.writeAll("   (try :help)\n");
        try out_w.interface.flush();
        return;
    };

    const wasm_bytes = std.Io.Dir.cwd().readFileAlloc(io, tool.wasm, gpa, .limited(1 << 20)) catch {
        try out_w.interface.writeAll("slash tool wasm missing (run zig build tools)\n");
        try out_w.interface.flush();
        return;
    };
    defer gpa.free(wasm_bytes);

    var sb = host.Sandbox{
        .gpa = gpa,
        .io = io,
        .root_dir = cfg.agent.sandbox_root,
        .network_allow = tool.network_allow,
        .fs_prefixes = tool.fs_prefixes,
        .environ_map = environ_map,
        .seed = cfg.agent.seed,
    };
    const mod = runtime.ToolModule.load(gpa, io, &sb, wasm_bytes) catch {
        try out_w.interface.writeAll("slash tool load failed\n");
        try out_w.interface.flush();
        return;
    };
    defer mod.deinit();

    var ibuf: [8192]u8 = undefined;
    var iw: std.Io.Writer = .fixed(&ibuf);
    var is = std.json.Stringify{ .writer = &iw, .options = .{} };
    try is.beginObject();
    try is.objectField("args");
    try is.write(args);
    try is.endObject();

    const out = mod.executeTool(ibuf[0..iw.end]) catch {
        try out_w.interface.writeAll("slash tool execution failed\n");
        try out_w.interface.flush();
        return;
    };
    defer gpa.free(out);

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, out, .{ .ignore_unknown_fields = true }) catch {
        try out_w.interface.writeAll(out);
        try out_w.interface.writeAll("\n");
        try out_w.interface.flush();
        return;
    };
    var text: []const u8 = "";
    var ok = false;
    if (parsed == .object) {
        if (parsed.object.get("ok")) |k| {
            if (k == .bool) ok = k.bool;
        }
        if (parsed.object.get("text")) |t| {
            if (t == .string) text = t.string;
        }
    }
    if (!ok) {
        if (parsed == .object) {
            if (parsed.object.get("error")) |e| {
                if (e == .string) {
                    try out_w.interface.writeAll("error: ");
                    try out_w.interface.writeAll(e.string);
                    try out_w.interface.writeAll("\n");
                    try out_w.interface.flush();
                    return;
                }
            }
        }
    }
    try out_w.interface.writeAll(text);
    try out_w.interface.writeAll("\n");
    try out_w.interface.flush();
}

/// Writes the effective modules set (from the merged cfg) into
/// config.local.json so runtime toggles like `/autolearn on|off` survive
/// restarts. Local modules fully override the base, so we persist the whole
/// effective set.
fn persistModules(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, cfg: *const config.Config) void {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, "config.local.json", arena, .limited(1 << 20)) catch return;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{ .ignore_unknown_fields = true }) catch return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const wbuf = gpa.alloc(u8, 1 << 20) catch return;
    defer gpa.free(wbuf);
    var w: std.Io.Writer = .fixed(wbuf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    if (root == .object) {
        s.beginObject() catch return;
        var it = root.object.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.key_ptr.*, "modules")) continue;
            s.objectField(kv.key_ptr.*) catch return;
            s.write(kv.value_ptr.*) catch return;
        }
        s.objectField("modules") catch return;
        s.beginObject() catch return;
        const fields = [_]struct { key: []const u8, v: bool }{
            .{ .key = "mcp", .v = cfg.modules.mcp },
            .{ .key = "peers", .v = cfg.modules.peers },
            .{ .key = "a2a", .v = cfg.modules.a2a },
            .{ .key = "webui", .v = cfg.modules.webui },
            .{ .key = "graphs", .v = cfg.modules.graphs },
            .{ .key = "sessions", .v = cfg.modules.sessions },
            .{ .key = "goal", .v = cfg.modules.goal },
            .{ .key = "token_budget", .v = cfg.modules.token_budget },
            .{ .key = "streaming", .v = cfg.modules.streaming },
            .{ .key = "dotenv", .v = cfg.modules.dotenv },
            .{ .key = "hot_reload", .v = cfg.modules.hot_reload },
            .{ .key = "autolearn", .v = cfg.modules.autolearn },
        };
        for (fields) |f| {
            s.objectField(f.key) catch return;
            s.write(f.v) catch return;
        }
        s.endObject() catch return;
        s.endObject() catch return;
    }
    atomic_write.writeFile(io, std.Io.Dir.cwd(), "config.local.json", w.buffer[0..w.end]) catch |err| log.log(.warn, "failed to persist config.local.json: {s}", .{@errorName(err)});
}

/// True if `exe_path`'s mtime differs from `start_mtime` and the file has
/// settled into a stable, valid ELF. The binary may be mid-write (e.g.
/// clanker's own improve loop rebuilds it constantly); exec'ing a
/// half-written file kills the process silently, so this only reports an
/// update once the file has been stable for a moment AND looks like a valid
/// ELF. Shared by the REPL and `clanker serve` hot-reload checks.
fn binaryUpdated(io: std.Io, exe_path: []const u8, start_mtime: i128) bool {
    const st1 = std.Io.Dir.cwd().statFile(io, exe_path, .{}) catch return false;
    if (st1.mtime.nanoseconds == start_mtime) return false;
    std.Io.sleep(io, .{ .nanoseconds = 400 * std.time.ns_per_ms }, .awake) catch {};
    const st2 = std.Io.Dir.cwd().statFile(io, exe_path, .{}) catch return false;
    if (st2.mtime.nanoseconds != st1.mtime.nanoseconds) return false; // still being written
    const f = std.Io.Dir.cwd().openFile(io, exe_path, .{}) catch return false;
    defer f.close(io);
    var magic: [4]u8 = undefined;
    const n = std.posix.read(f.handle, &magic) catch return false;
    return n >= 4 and magic[0] == 0x7f and magic[1] == 'E' and magic[2] == 'L' and magic[3] == 'F';
}

/// Replaces the current process image with `exe_path argv_tail...`. On
/// success this never returns (the process is gone); on failure it returns
/// so the caller can log and keep running on the current build.
fn execSelf(gpa: std.mem.Allocator, exe_path: [:0]const u8, argv_tail: []const []const u8) void {
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer argv.deinit(gpa);
    const exe_z: [*:0]const u8 = exe_path.ptr;
    argv.append(gpa, exe_z) catch return;
    for (argv_tail) |a| {
        argv.append(gpa, @as([*:0]const u8, @ptrCast(gpa.dupeZ(u8, a) catch return))) catch return;
    }
    argv.append(gpa, null) catch return;
    // Mark every fd above stderr close-on-exec. The re-exec'd image reopens
    // everything it needs (listener via reuse_address, inotify, sockets), so
    // an inherited fd is purely a leak: one listener per reload until EMFILE.
    // SETFD only acts at exec time, so if the execve below fails the current
    // image keeps running with nothing closed.
    const nofile = std.posix.getrlimit(.NOFILE) catch std.posix.rlimit{ .cur = 1024, .max = 1024 };
    // ponytail: linear fcntl sweep; parse /proc/self/fd if the limit is ever huge
    const fd_max: i32 = @intCast(@min(nofile.cur, 65536));
    var fd: i32 = 3;
    while (fd < fd_max) : (fd += 1) {
        _ = std.os.linux.fcntl(@intCast(fd), std.os.linux.F.SETFD, std.os.linux.FD_CLOEXEC);
    }
    const path_z: [*:0]const u8 = exe_path.ptr;
    const argv_z: [*:null]const ?[*:0]const u8 = @ptrCast(argv.items.ptr);
    _ = std.os.linux.execve(path_z, argv_z, @ptrCast(std.c.environ));
}

/// Watches the running binary for a rebuild and restarts the process with
/// `argv_tail` once it's safe to do so. "Safe" means not mid-request/
/// mid-turn: `begin()`/`end()` bracket the unsafe window (wrap exactly the
/// `a.run()` turn in the REPL, or exactly `handleConnection` in `serve`) so
/// a reload never drops a client mid-response or loses an in-progress REPL
/// turn before its session save — sessions always resume cleanly because
/// nothing that mutates them is ever interrupted.
///
/// While idle (the common case: blocked in `accept()` or the stdin read),
/// the watcher thread restarts immediately on the inotify event instead of
/// waiting for the next request/line to arrive and poll for it.
const HotReload = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Owned by this struct, not the caller: the watcher thread is detached and
    /// outlives `cmdRepl`/`cmdServe`, whose `exe_path` is freed on return.
    exe_path: [:0]const u8,
    start_mtime: i128,
    argv_tail: []const []const u8,
    /// Held shared for the whole unsafe window. A flag plus a check would be a
    /// race: the watcher could read "not busy" and then exec while `begin()`
    /// runs. Taking the lock makes "is it safe to exec" and "start the turn"
    /// one atomic decision.
    ///
    /// A reader-writer lock rather than a plain mutex because `serve` now runs
    /// one thread per connection: any number of requests may be in flight at
    /// once (shared), while the watcher's exec needs all of them finished
    /// (exclusive).
    turn: std.Io.RwLock = .init,
    /// Set by the watcher when a rebuild lands mid-turn; `end()` checks it so a
    /// rebuild is never missed, only deferred to the end of the turn.
    pending: std.atomic.Value(bool) = .init(false),

    fn begin(self: *HotReload) void {
        self.turn.lockSharedUncancelable(self.io);
    }

    fn end(self: *HotReload) void {
        self.turn.unlockShared(self.io);
        if (!self.pending.load(.acquire)) return;
        // Only the request that leaves the server idle performs the deferred
        // reload; with concurrent connections the others are still mid-
        // response. Failing to take it leaves `pending` set, so the next
        // request to finish retries.
        if (!self.turn.tryLock(self.io)) return;
        defer self.turn.unlock(self.io);
        if (!self.pending.swap(false, .acq_rel)) return;
        self.restartIfUpdated();
    }

    fn restartIfUpdated(self: *HotReload) void {
        if (!binaryUpdated(self.io, self.exe_path, self.start_mtime)) return;
        std.debug.print("\n\x1b[33m[hot-reload]\x1b[0m binary updated, restarting with the new build\n", .{});
        execSelf(self.gpa, self.exe_path, self.argv_tail);
        std.debug.print("[hot-reload] exec failed, continuing with the current build\n", .{});
    }

    /// Blocks forever watching the binary's directory for `CLOSE_WRITE` /
    /// `MOVED_TO` on its basename (covers both write-in-place and
    /// atomic-rename-replace build outputs). Run on its own thread; returns
    /// (silently giving up) if inotify is unavailable, e.g. an overlay/
    /// network filesystem that doesn't support it — the process just never
    /// gets an idle-triggered reload in that case.
    fn watch(self: *HotReload) void {
        const dir_path = std.fs.path.dirname(self.exe_path) orelse ".";
        const base_name = std.fs.path.basename(self.exe_path);

        var dir_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        const dir_z = std.fmt.bufPrintZ(&dir_buf, "{s}", .{dir_path}) catch return;

        const init_rc = std.os.linux.inotify_init1(std.os.linux.IN.CLOEXEC);
        if (@as(isize, @bitCast(init_rc)) < 0) return;
        const fd: i32 = @intCast(init_rc);
        defer _ = std.os.linux.close(fd);

        const watch_rc = std.os.linux.inotify_add_watch(fd, dir_z, std.os.linux.IN.CLOSE_WRITE | std.os.linux.IN.MOVED_TO);
        if (@as(isize, @bitCast(watch_rc)) < 0) return;

        var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
        while (true) {
            const n = std.posix.read(fd, &buf) catch return;
            if (n == 0) return;
            var relevant = false;
            var i: usize = 0;
            while (i + @sizeOf(std.os.linux.inotify_event) <= n) {
                const ev: *const std.os.linux.inotify_event = @ptrCast(@alignCast(&buf[i]));
                if (ev.getName()) |name| {
                    if (std.mem.eql(u8, name, base_name)) relevant = true;
                }
                i += @sizeOf(std.os.linux.inotify_event) + ev.len;
            }
            if (!relevant) continue;
            if (!binaryUpdated(self.io, self.exe_path, self.start_mtime)) continue;
            // Never exec inside a turn: if one is running, defer to `end()`.
            if (!self.turn.tryLock(self.io)) {
                self.pending.store(true, .release);
                // The turn may have ended between the failed tryLock and the
                // store above, in which case end() already ran its pending
                // check and found nothing: retry once so that reload is not
                // stranded until the next event.
                if (!self.turn.tryLock(self.io)) continue;
                if (!self.pending.swap(false, .acq_rel)) {
                    self.turn.unlock(self.io);
                    continue;
                }
            }
            defer self.turn.unlock(self.io);
            std.debug.print("\n\x1b[33m[hot-reload]\x1b[0m binary updated, restarting with the new build\n", .{});
            execSelf(self.gpa, self.exe_path, self.argv_tail);
            std.debug.print("[hot-reload] exec failed, continuing with the current build\n", .{});
        }
    }

    /// Spawns the watcher thread; returns null (caller keeps running on the
    /// current build with no hot-reload) if it could not be started.
    fn start(arena: std.mem.Allocator, io: std.Io, gpa: std.mem.Allocator, exe_path: []const u8, argv_tail: []const []const u8) ?*HotReload {
        const st = std.Io.Dir.cwd().statFile(io, exe_path, .{}) catch return null;
        const self = arena.create(HotReload) catch return null;
        // Copied, and deliberately never freed: the watcher thread is detached
        // and reads this until the process is replaced or exits.
        const owned_path = arena.dupeZ(u8, exe_path) catch return null;
        self.* = .{ .io = io, .gpa = gpa, .exe_path = owned_path, .start_mtime = st.mtime.nanoseconds, .argv_tail = argv_tail };
        _ = std.Thread.spawn(.{}, HotReload.watch, .{self}) catch return null;
        return self;
    }
};

/// Shared by `cmdRepl` and `cmdServe` (mutually exclusive: only one command
/// runs per process), matching the `repl_out`/`repl_io`-style globals
/// already used for other REPL cross-cutting state.
var hot_reload_active: ?*HotReload = null;

fn buildReplArgvTail(arena: std.mem.Allocator, sid: []const u8, opts: Options) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "repl");
    try argv.append(arena, "--session");
    try argv.append(arena, sid);
    if (opts.provider) |p| {
        try argv.append(arena, "--provider");
        try argv.append(arena, p);
    }
    if (opts.model) |m| {
        try argv.append(arena, "--model");
        try argv.append(arena, m);
    }
    return argv.items;
}

fn buildServeArgvTail(arena: std.mem.Allocator, port: u16) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "serve");
    try argv.append(arena, "--port");
    try argv.append(arena, try std.fmt.allocPrint(arena, "{d}", .{port}));
    return argv.items;
}

/// Streams REPL output: the model's content deltas land here (via
/// Agent.on_token) while the run is still in flight.
var repl_out: ?*std.Io.File.Writer = null;

/// Braille spinner frames, animated on a background thread while waiting on
/// the LLM or a tool: covers the otherwise silent gap with visible motion.
const spinner_frames = [_][]const u8{ "\xe2\xa0\x8b", "\xe2\xa0\x99", "\xe2\xa0\xb9", "\xe2\xa0\xb8", "\xe2\xa0\xbc", "\xe2\xa0\xb4", "\xe2\xa0\xa6", "\xe2\xa0\xa7", "\xe2\xa0\x87", "\xe2\xa0\x8f" };
const spinner_interval_ns = 80 * std.time.ns_per_ms;

var spinner_thread: ?std.Thread = null;
var spinner_stop = std.atomic.Value(bool).init(false);
/// Set once in cmdRepl; the spinner thread needs an Io handle to sleep with
/// (std.Thread has no sleep of its own in std.Io-based Zig).
var repl_io: std.Io = undefined;
/// Live spinner state: when the current turn started and what it is doing.
var repl_turn_start_ns: i128 = 0;
var repl_activity: []const u8 = "thinking";
/// Scratch for a batch label like "read_file +2" (see replToolCall): the
/// status line names the first tool and counts the rest of the batch.
var repl_activity_buf: [256]u8 = undefined;
/// True while the spinner is on screen; only touched from the REPL's single
/// main thread (show/clear calls never overlap with the spinner thread,
/// which is always joined before the writer is touched again).
var repl_thinking_shown = false;

fn spinnerLoop() callconv(.c) void {
    var i: usize = 0;
    while (!spinner_stop.load(.acquire)) {
        const w = repl_out orelse return;
        const elapsed_ns = std.Io.Timestamp.now(repl_io, .awake).nanoseconds - repl_turn_start_ns;
        const secs: u64 = if (elapsed_ns <= 0) 0 else @intCast(@divTrunc(elapsed_ns, 1_000_000_000));
        const activity = repl_activity;
        const verb: []const u8 = if (std.mem.eql(u8, activity, "thinking")) "" else "running ";
        w.interface.print("\r\x1b[35m{s}\x1b[0m \x1b[2m{d}s · {s}{s}\xe2\x80\xa6\x1b[0m", .{ spinner_frames[i % spinner_frames.len], secs, verb, activity }) catch return;
        w.interface.flush() catch {};
        i += 1;
        std.Io.sleep(repl_io, .{ .nanoseconds = spinner_interval_ns }, .awake) catch return;
    }
}

fn replShowThinking() void {
    if (repl_thinking_shown) return;
    repl_thinking_shown = true;
    spinner_stop.store(false, .release);
    spinner_thread = std.Thread.spawn(.{}, spinnerLoop, .{}) catch {
        repl_thinking_shown = false;
        return;
    };
}

fn replClearThinking() void {
    if (!repl_thinking_shown) return;
    repl_thinking_shown = false;
    spinner_stop.store(true, .release);
    if (spinner_thread) |t| t.join();
    spinner_thread = null;
    const w = repl_out orelse return;
    w.interface.writeAll("\r\x1b[K") catch {};
}

/// Renders the same markdown subset as the `format` WASM tool (bold,
/// italic, inline code, fenced blocks, "- " bullets) straight into ANSI as
/// content streams in, one delta at a time. A marker can split across two
/// deltas (e.g. "**" arriving as two separate one-byte chunks), so up to 2
/// bytes are held back whenever the tail of a chunk could still be the start
/// of a longer marker, and resolved once the next chunk arrives.
const MdStream = struct {
    in_fence: bool = false,
    in_bold: bool = false,
    in_italic: bool = false,
    in_code: bool = false,
    /// Styling opened by a line construct (heading, quote) and closed at the
    /// newline that ends it.
    line_style: bool = false,
    at_line_start: bool = true,
    /// Longest marker needing lookahead: "###### " (7 bytes).
    hold: [7]u8 = undefined,
    hold_len: usize = 0,

    fn at(self: *const MdStream, chunk: []const u8, idx: usize) u8 {
        return if (idx < self.hold_len) self.hold[idx] else chunk[idx - self.hold_len];
    }

    /// Bytes from `i` that are the same character `c`, capped at `max`.
    fn runOf(self: *const MdStream, chunk: []const u8, i: usize, total: usize, c: u8, max: usize) usize {
        var n: usize = 0;
        while (i + n < total and n < max and self.at(chunk, i + n) == c) n += 1;
        return n;
    }

    fn feed(self: *MdStream, w: *std.Io.Writer, chunk: []const u8) void {
        const total = self.hold_len + chunk.len;
        var i: usize = 0;
        while (i < total) {
            const remaining = total - i;
            const c = self.at(chunk, i);

            // Inside a fence everything is literal: a code block full of *,
            // _ and ` must not toggle emphasis on its way to the terminal.
            if (self.in_fence) {
                if (c == '`') {
                    if (remaining < 3) break;
                    if (self.at(chunk, i + 1) == '`' and self.at(chunk, i + 2) == '`') {
                        self.in_fence = false;
                        w.writeAll("\x1b[0m") catch {};
                        i += 3;
                        self.at_line_start = false;
                        continue;
                    }
                }
                w.writeAll(&[_]u8{c}) catch {};
                self.at_line_start = (c == '\n');
                i += 1;
                continue;
            }

            // ---- line-start constructs ----
            if (self.at_line_start) {
                // Heading: "# " .. "###### ". Rendered by weight, not by
                // repeating the hashes back at the reader.
                if (c == '#') {
                    const hashes = self.runOf(chunk, i, total, '#', 6);
                    if (i + hashes >= total) break; // need the char after them
                    if (hashes <= 6 and self.at(chunk, i + hashes) == ' ') {
                        w.writeAll(if (hashes == 1) "\x1b[1;4m" else "\x1b[1m") catch {};
                        self.line_style = true;
                        i += hashes + 1;
                        self.at_line_start = false;
                        continue;
                    }
                }
                // Horizontal rule: a line of --- or ***.
                if (c == '-' or c == '*') {
                    const rule_run = self.runOf(chunk, i, total, c, 4);
                    if (rule_run >= 3) {
                        if (i + rule_run >= total) break; // the line may continue
                        if (self.at(chunk, i + rule_run) == '\n') {
                            w.writeAll("\x1b[2m\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\x1b[0m") catch {};
                            i += rule_run;
                            continue;
                        }
                    }
                }
                // Block quote.
                if (c == '>') {
                    if (remaining < 2) break;
                    if (self.at(chunk, i + 1) == ' ') {
                        w.writeAll("\x1b[2m\xe2\x94\x82 ") catch {};
                        self.line_style = true;
                        i += 2;
                        self.at_line_start = false;
                        continue;
                    }
                }
                // Ordered list: "1. " / "1) ", marker in cyan.
                if (c >= '0' and c <= '9') {
                    var d: usize = 0;
                    while (i + d < total and d < 3 and self.at(chunk, i + d) >= '0' and self.at(chunk, i + d) <= '9') d += 1;
                    if (i + d + 1 >= total) break;
                    const sep = self.at(chunk, i + d);
                    if ((sep == '.' or sep == ')') and self.at(chunk, i + d + 1) == ' ') {
                        w.writeAll("\x1b[36m") catch {};
                        var k: usize = 0;
                        while (k < d) : (k += 1) w.writeAll(&[_]u8{self.at(chunk, i + k)}) catch {};
                        w.writeAll(&[_]u8{sep}) catch {};
                        w.writeAll("\x1b[0m ") catch {};
                        i += d + 2;
                        self.at_line_start = false;
                        continue;
                    }
                }
                // Bullet: "- " or "* ".
                if (c == '-' or c == '*') {
                    if (remaining < 2) break;
                    if (self.at(chunk, i + 1) == ' ') {
                        w.writeAll("\xe2\x80\xa2 ") catch {};
                        i += 2;
                        self.at_line_start = false;
                        continue;
                    }
                }
            }

            // ---- inline constructs ----
            if (c == '`' and remaining < 3) break; // could still become ```
            if (c == '`' and self.at(chunk, i + 1) == '`' and self.at(chunk, i + 2) == '`') {
                self.in_fence = true;
                w.writeAll("\x1b[2m") catch {};
                i += 3;
                self.at_line_start = false;
                continue;
            }
            if (c == '*' and remaining < 2) break; // could still become **
            if (c == '*' and self.at(chunk, i + 1) == '*') {
                self.in_bold = !self.in_bold;
                w.writeAll(if (self.in_bold) "\x1b[1m" else "\x1b[0m") catch {};
                i += 2;
                self.at_line_start = false;
                continue;
            }
            if (c == '`') {
                self.in_code = !self.in_code;
                w.writeAll(if (self.in_code) "\x1b[36m" else "\x1b[0m") catch {};
                i += 1;
                self.at_line_start = false;
                continue;
            }
            if (c == '*') {
                self.in_italic = !self.in_italic;
                w.writeAll(if (self.in_italic) "\x1b[3m" else "\x1b[0m") catch {};
                i += 1;
                self.at_line_start = false;
                continue;
            }

            // A heading or quote's styling ends with its line.
            if (c == '\n' and self.line_style) {
                w.writeAll("\x1b[0m") catch {};
                self.line_style = false;
            }
            w.writeAll(&[_]u8{c}) catch {};
            self.at_line_start = (c == '\n');
            i += 1;
        }
        const left = total - i;
        var j: usize = 0;
        while (j < left) : (j += 1) self.hold[j] = self.at(chunk, i + j);
        self.hold_len = left;
    }

    /// Flushes any still-held bytes as literal text (no more input is
    /// coming, so a trailing lone "*" or "`" was never a real marker) and
    /// closes any formatting left open, then resets for the next turn.
    fn flush(self: *MdStream, w: *std.Io.Writer) void {
        if (self.hold_len > 0) {
            w.writeAll(self.hold[0..self.hold_len]) catch {};
        }
        if (self.in_code) w.writeAll("\x1b[0m") catch {};
        if (self.in_italic) w.writeAll("\x1b[0m") catch {};
        if (self.in_bold) w.writeAll("\x1b[0m") catch {};
        if (self.in_fence) w.writeAll("\x1b[0m") catch {};
        if (self.line_style) w.writeAll("\x1b[0m") catch {};
        self.* = .{};
    }
};

/// True once the current turn's assistant text has started streaming, so the
/// colored "›" gutter is only printed once, right before the first token.
var repl_answer_started = false;
var repl_md: MdStream = .{};

/// Options offered by the last answer, so the next line can be a bare number.
/// gpa-owned: replaced (and freed) on every turn that ends in a question.
var repl_choices: std.ArrayList([]u8) = .empty;
/// The question those options answered, for the graph's decision node.
var repl_last_question: []const u8 = "";

fn replClearChoices(gpa: std.mem.Allocator) void {
    for (repl_choices.items) |c| gpa.free(c);
    repl_choices.clearRetainingCapacity();
}

/// The last line of an answer, which is the question its options belong to.
fn lastQuestion(text: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, " \t\r\n");
    const start = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |nl| nl + 1 else 0;
    return std.mem.trim(u8, trimmed[start..], " \t");
}

/// The options a multiple-choice answer offers, or null when the answer does
/// not end in a question.
///
/// Two shapes cover what models actually produce: an enumerated list under a
/// question ("1. ... 2. ..."), and the inline form ("do X, or dig into Y?").
/// Anything else is left alone — a wrong guess here would put words in the
/// user's mouth on the next turn.
fn parseChoices(arena: std.mem.Allocator, text: []const u8) !?[]const []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, " \t\r\n");
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != '?') return null;

    // The question is the last non-empty line.
    const q_start = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |nl| nl + 1 else 0;
    const question = std.mem.trim(u8, trimmed[q_start..], " \t\r\n");

    var out: std.ArrayList([]const u8) = .empty;

    // Enumerated options anywhere above the question: "1. foo" / "2) bar".
    var lines = std.mem.splitScalar(u8, trimmed[0..q_start], '\n');
    var want: u8 = '1';
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len < 3) continue;
        if (line[0] != want) continue;
        if (line[1] != '.' and line[1] != ')') continue;
        const body = std.mem.trim(u8, line[2..], " \t");
        if (body.len == 0) continue;
        try out.append(arena, body);
        if (want == '9') break;
        want += 1;
    }
    if (out.items.len >= 2) return try out.toOwnedSlice(arena);
    out.clearRetainingCapacity();

    // Inline: "... A, or B?" — split the question itself.
    const body = std.mem.trim(u8, question[0 .. question.len - 1], " \t");
    var it = std.mem.splitSequence(u8, body, ", or ");
    while (it.next()) |part| {
        const opt = std.mem.trim(u8, part, " \t");
        // A fragment this short is punctuation, not an option worth offering.
        if (opt.len < 3) return null;
        try out.append(arena, opt);
        if (out.items.len > 4) return null;
    }
    if (out.items.len >= 2) return try out.toOwnedSlice(arena);
    return null;
}

fn replDelta(delta: []const u8) void {
    replClearThinking();
    const w = repl_out orelse return;
    if (!repl_answer_started) {
        repl_answer_started = true;
        w.interface.writeAll("\x1b[1;35m\xe2\x80\xba \x1b[0m") catch return;
    }
    repl_md.feed(&w.interface, delta);
    w.interface.flush() catch {};
}

/// Prints a compact status line per tool call about to run, showing the
/// tool name and a truncated preview of its arguments so the user can see
/// what is being searched / read / written.
fn replToolCall(calls: []const types.ToolCall) void {
    replClearThinking();
    const w = repl_out orelse return;
    const arg_preview_cap = 80;
    if (calls.len == 1) {
        repl_activity = calls[0].name;
    } else if (calls.len > 1) {
        repl_activity = std.fmt.bufPrint(&repl_activity_buf, "{s} +{d}", .{ calls[0].name, calls.len - 1 }) catch calls[0].name;
    }
    for (calls) |tc| {
        w.interface.writeAll("\x1b[36m  \xe2\x9a\x99 ") catch return;
        w.interface.writeAll(tc.name) catch {};
        // Show a dim, truncated preview of arguments so the user knows
        // *what* is being searched / read / written, not just which tool.
        if (tc.arguments.len > 0 and !std.mem.eql(u8, tc.arguments, "{}")) {
            w.interface.writeAll("\x1b[0m\x1b[2m  ") catch {};
            if (tc.arguments.len <= arg_preview_cap) {
                w.interface.writeAll(tc.arguments) catch {};
            } else {
                w.interface.writeAll(tc.arguments[0..arg_preview_cap]) catch {};
                w.interface.writeAll("\xe2\x80\xa6") catch {};
            }
        }
        w.interface.writeAll("\x1b[0m\n") catch {};
    }
    w.interface.flush() catch {};
    replShowThinking();
}

/// Prints the elapsed time for the tool batch that just finished, dim and
/// indented under the tool status line, then resumes the spinner while the
/// next LLM call is in flight.
fn replToolResult(ms: u64) void {
    replClearThinking();
    repl_activity = "thinking";
    const w = repl_out orelse return;
    var buf: [48]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "\x1b[2m    \xe2\x86\xb3 {d}ms\x1b[0m\n", .{ms}) catch return;
    w.interface.writeAll(line) catch return;
    w.interface.flush() catch {};
    replShowThinking();
}

/// `clanker run`'s stdout content writer: kept separate from `repl_out`
/// (which, in `run`, points at stderr for the spinner/tool-status line) so
/// streamed answer bytes never share a stream with status noise — piping
/// stdout stays byte-identical to a plain, non-streamed run.
var run_out: ?*std.Io.File.Writer = null;
var run_stdout_color = false;
var run_md: MdStream = .{};

fn runDelta(delta: []const u8) void {
    replClearThinking();
    const w = run_out orelse return;
    if (run_stdout_color and !repl_answer_started) {
        repl_answer_started = true;
        w.interface.writeAll("\x1b[1;35m\xe2\x80\xba \x1b[0m") catch return;
    }
    if (run_stdout_color) {
        run_md.feed(&w.interface, delta);
    } else {
        w.interface.writeAll(delta) catch {};
    }
    w.interface.flush() catch {};
}

/// Runs one REPL turn for `task` (arena-owned): appends the user message, runs
/// the agent, prints the answer, appends the assistant message, and persists
/// the session. Returns true if the loop should exit (only on :quit).
/// Per-turn cap keeps the transcript small before each LLM call; the session
/// cap bounds the persisted history so long sessions auto-compact instead of
/// exceeding the context window.
const max_turn_tokens = 4096;
const max_session_tokens = 8192;

/// Drops oldest non-system messages until the estimated token count fits under
/// `max_tokens` so long sessions auto-compact instead of exceeding the context
/// window. Token count is estimated as chars/4 (a rough heuristic).
fn compactMessages(messages: *std.ArrayList(types.Message), max_tokens: usize) void {
    var total: usize = 0;
    for (messages.items) |m| {
        total += if (m.content) |c| c.len / 4 else 0;
    }
    if (total <= max_tokens) return;
    var i: usize = 0;
    while (i < messages.items.len and total > max_tokens) {
        const m = messages.items[i];
        if (m.role != .system) {
            total -|= if (m.content) |c| c.len / 4 else 0;
            _ = messages.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn replRunTurn(io: std.Io, out_w: *std.Io.File.Writer, a: *agent.Agent, messages: *std.ArrayList(types.Message), task: []const u8, created: i64, sid: []const u8) !bool {
    // A hot-reload must never interrupt a turn in progress (would lose the
    // response before its session save below); see HotReload's doc comment.
    if (hot_reload_active) |hr| hr.begin();
    defer if (hot_reload_active) |hr| hr.end();

    compactMessages(messages, max_turn_tokens);
    const gpa = a.ctx.gpa;
    // NOTE: a.run() appends the user task (and each assistant reply) to
    // `messages` itself; appending here would duplicate them in the
    // transcript and the persisted session.
    const t0 = std.Io.Timestamp.now(io, .awake);
    var err_detail: ?[]const u8 = null;
    // stats are cumulative across turns; capture per-turn counters before.
    const prev_prompt = a.stats.total_prompt_tokens;
    const prev_completion = a.stats.total_completion_tokens;
    const prev_cost = a.stats.cost;
    const prev_cache_hit = a.stats.total_cache_hit_tokens;
    const prev_cache_miss = a.stats.total_cache_miss_tokens;
    repl_answer_started = false;
    repl_turn_start_ns = t0.nanoseconds;
    repl_activity = "thinking";
    replShowThinking();
    const resp = a.run(messages, task, &err_detail) catch |err| {
        replClearThinking();
        log.log(.error_, "{s}", .{err_detail orelse @errorName(err)});
        return false;
    };
    const ms: u64 = @intCast(@divTrunc(t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds, std.time.ns_per_ms));

    replClearThinking();
    const streamed = a.on_token != null and a.cfg.modules.streaming;
    const content = resp.message.content orelse "";
    if (!streamed) {
        try out_w.interface.writeAll("\x1b[1;35m\xe2\x80\xba \x1b[0m");
        repl_md.feed(&out_w.interface, content);
    }
    repl_md.flush(&out_w.interface);
    try out_w.interface.writeAll("\n\n");
    // Dim turn stats (tokens + wall time) so each turn reports its cost.
    const turn_prompt = a.stats.total_prompt_tokens -| prev_prompt;
    const turn_completion = a.stats.total_completion_tokens -| prev_completion;
    const turn_cost = a.stats.cost - prev_cost;
    const turn_cache_hit = a.stats.total_cache_hit_tokens -| prev_cache_hit;
    const turn_cache_miss = a.stats.total_cache_miss_tokens -| prev_cache_miss;
    const tps: f64 = if (ms > 0) @as(f64, @floatFromInt(turn_completion)) / (@as(f64, @floatFromInt(ms)) / 1000.0) else 0;
    const cache_total = turn_cache_hit + turn_cache_miss;
    const hit_rate: f64 = if (cache_total > 0) @as(f64, @floatFromInt(turn_cache_hit)) / @as(f64, @floatFromInt(cache_total)) * 100.0 else 0;
    const stats = if (turn_prompt + turn_completion > 0)
        try std.fmt.allocPrint(a.arena, "\x1b[2m  [{d} prompt + {d} completion \xc2\xb7 {d}ms \xc2\xb7 {d:.1} tok/s \xc2\xb7 cache {d:.0}% \xc2\xb7 ${d:.4}]\x1b[0m\n", .{ turn_prompt, turn_completion, ms, tps, hit_rate, turn_cost })
    else
        try std.fmt.allocPrint(a.arena, "\x1b[2m  [{d}ms]\x1b[0m\n", .{ms});
    try out_w.interface.writeAll(stats);

    // A turn that ends in a multiple-choice question gets numbered options,
    // so the reply can be "2" instead of retyping the option.
    replClearChoices(gpa);
    if (try parseChoices(a.arena, content)) |choices| {
        repl_last_question = lastQuestion(content);
        for (choices, 1..) |c, n| {
            const line = try std.fmt.allocPrint(a.arena, "  \x1b[1;36m{d}\x1b[0m \x1b[2m·\x1b[0m {s}\n", .{ n, c });
            try out_w.interface.writeAll(line);
            repl_choices.append(gpa, try gpa.dupe(u8, c)) catch {};
        }
        try out_w.interface.writeAll("  \x1b[2mreply with a number, or type anything else\x1b[0m\n");
    }
    try out_w.interface.flush();
    // run() already appended (and finish()-cleaned) the assistant message.

    const updated: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    if (!a.cfg.modules.sessions) return false;
    compactMessages(messages, max_session_tokens);
    const title = try std.fmt.allocPrint(a.arena, "repl: {s}", .{task[0..@min(task.len, 60)]});
    try session.saveSession(io, gpa, a.arena, std.Io.Dir.cwd(), .{
        .id = sid,
        .title = title,
        .messages = messages.items,
        .created = created,
        .updated = updated,
    });
    return false;
}

fn cmdSessions(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(init.io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    if (!cfg.modules.sessions) {
        log.log(.error_, "sessions module is disabled...", .{});
        return error.ModuleDisabled;
    }
    try printInternalTool(init, &cfg, "cmd_sessions", "");
}

/// `clanker graph [run-id]` — list persisted execution graphs, or render one
/// as an ASCII timeline of LLM calls and tool invocations.
/// Runs an internal `cmd_*` WASM tool and returns its `text` (arena-owned).
/// The CLI subcommands that render persisted state go through here, so the
/// plugin is the single implementation and the CLI is only a caller.
fn toolText(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    cfg: *const config.Config,
    environ_map: *std.process.Environ.Map,
    tool_name: []const u8,
    args: []const u8,
) ![]const u8 {
    var reg = try registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir);
    const tool = reg.get(tool_name) orelse {
        log.log(.error_, "internal tool '{s}' not found in {s}", .{ tool_name, cfg.agent.tools_dir });
        return error.UnknownTool;
    };
    const wasm_bytes = std.Io.Dir.cwd().readFileAlloc(io, tool.wasm, gpa, .limited(1 << 20)) catch {
        log.log(.error_, "'{s}' wasm missing: {s} (run `zig build tools`)", .{ tool_name, tool.wasm });
        return error.ToolWasmMissing;
    };
    defer gpa.free(wasm_bytes);

    var ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = environ_map, .cfg = cfg };
    var sb = try host.sandboxFor(gpa, io, arena, environ_map, cfg, tool, &ctx);
    const mod = try runtime.ToolModule.load(gpa, io, &sb, wasm_bytes);
    defer mod.deinit();

    var ibuf: [8192]u8 = undefined;
    var iw: std.Io.Writer = .fixed(&ibuf);
    var is = std.json.Stringify{ .writer = &iw, .options = .{} };
    try is.beginObject();
    try is.objectField("args");
    try is.write(args);
    try is.endObject();

    const raw = try mod.executeTool(ibuf[0..iw.end]);
    defer gpa.free(raw);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{ .ignore_unknown_fields = true });
    if (parsed != .object) return error.ToolBadOutput;
    var ok = false;
    if (parsed.object.get("ok")) |k| {
        if (k == .bool) ok = k.bool;
    }
    if (!ok) {
        const detail = if (parsed.object.get("error")) |e| (if (e == .string) e.string else "unknown") else "unknown";
        log.log(.error_, "{s}: {s}", .{ tool_name, detail });
        return error.ToolFailed;
    }
    const text = parsed.object.get("text") orelse return error.ToolBadOutput;
    if (text != .string) return error.ToolBadOutput;
    return text.string;
}

/// Prints an internal tool's text to stdout, newline-terminated.
fn printInternalTool(init: std.process.Init, cfg: *const config.Config, tool_name: []const u8, args: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const text = try toolText(init.io, init.gpa, arena_state.allocator(), cfg, init.environ_map, tool_name, args);
    const out = std.Io.File.stdout();
    try out.writeStreamingAll(init.io, text);
    if (!std.mem.endsWith(u8, text, "\n")) try out.writeStreamingAll(init.io, "\n");
}

fn cmdGraph(init: std.process.Init, opts: Options) !void {
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(init.io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    if (!cfg.modules.graphs) {
        log.log(.error_, "graphs module is disabled...", .{});
        return error.ModuleDisabled;
    }
    // No run id lists the recorded runs; a run id renders that one. Both are
    // implemented once, in the cmd_graph plugin.
    try printInternalTool(init, &cfg, "cmd_graph", opts.task orelse "list");
}

fn cmdToolsList(init: std.process.Init, opts: Options) !void {
    _ = opts;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(init.io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    try printInternalTool(init, &cfg, "cmd_tools", "");
}

fn cmdEval(init: std.process.Init, opts: Options) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    var ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = init.environ_map, .cfg = &cfg };

    var provider = try cfg.provider(opts.provider);
    var provider_copy = provider.*;
    if (opts.model) |m| provider_copy.default_model = m;
    provider = &provider_copy;

    std.Io.Dir.cwd().createDirPath(io, cfg.agent.sandbox_root) catch {};

    const evals = try scorers.Eval.loadAll(arena, io, "evals");
    var reg = try registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir);

    var r = eval_runner.Runner{ .ctx = &ctx, .arena = arena, .provider = provider, .cfg = &cfg, .reg = &reg };

    var list: std.ArrayList(scorers.Eval) = .empty;
    for (evals) |e| {
        if (opts.eval_name) |want| {
            if (!std.mem.eql(u8, want, e.name)) continue;
        }
        if (opts.eval_tasks_only and e.kind != .task) continue;
        try list.append(arena, e);
    }
    // No task evals at all is a valid, if sad, answer for --tasks: it means
    // nothing capability-level is being checked, not that the caller asked for
    // an eval that does not exist.
    if (list.items.len == 0) {
        if (opts.eval_tasks_only) return;
        return error.UnknownEval;
    }

    const results = try r.runAll(list.items);
    var all_ok = true;
    const out = std.Io.File.stdout();
    for (results) |res| {
        try out.writeStreamingAll(io, try std.fmt.allocPrint(arena, "{s}: {d:.2} {s}\n", .{ res.name, res.score, if (res.ok) "PASS" else "FAIL" }));
        if (!res.ok) all_ok = false;
    }
    if (!all_ok) return error.EvalsFailed;
}

fn cmdImproveSelf(init: std.process.Init, opts: Options) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    var ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = init.environ_map, .cfg = &cfg };

    var provider = try cfg.provider(opts.provider);
    var provider_copy = provider.*;
    if (opts.model) |m| provider_copy.default_model = m;
    provider = &provider_copy;

    std.Io.Dir.cwd().createDirPath(io, cfg.agent.sandbox_root) catch {};
    std.Io.Dir.cwd().createDirPath(io, "state") catch {};
    std.Io.Dir.cwd().createDirPath(io, "state/staging") catch {};

    // Before any staging or gate work: two runs against one tree gate each
    // other's half-applied patches and promote over each other.
    var holder: ?u32 = null;
    var lock = runlock.acquire(io, gpa, std.Io.Dir.cwd(), "state/improve.lock", &holder) catch |err| switch (err) {
        runlock.Error.Busy => {
            if (holder) |pid| {
                log.log(.warn, "another improve-self is already running (process {d}); nothing was changed", .{pid});
            } else {
                log.log(.warn, "another improve-self is already running; nothing was changed", .{});
            }
            return;
        },
        else => return err,
    };
    defer lock.release();

    if (cfg.improve.max_context_bytes) |n| log.log(.debug, "improve.max_context_bytes = {d} (config override)", .{n});
    var eng = improve.Engine{ .ctx = &ctx, .arena = arena, .provider = provider, .cfg = &cfg, .hist = undefined, .instructions = undefined };
    try eng.run(.{
        .instructions = opts.task orelse return error.MissingTask,
        .iters = opts.iters,
        .dry_run = opts.dry_run,
        .max_context_bytes = cfg.improve.max_context_bytes,
    });
    // Verify that any applied improvement still passes all deterministic gates
    // (build/test/tools/fmt/lint). In dry-run no changes are written, so skip.
    if (!opts.dry_run) {
        try verifyGates(gpa, io, arena);
    }
}

fn cmdGoal(init: std.process.Init, opts: Options) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    if (!cfg.modules.goal) {
        log.log(.error_, "goal module is disabled...", .{});
        return error.ModuleDisabled;
    }
    const intent = opts.task orelse return error.MissingTask;
    const task = try std.fmt.allocPrint(arena, "Design and persist a structured goal for: {s}\n\nDefine all five fields (objective, completion_criterion, proof, boundaries, stop_rule) and call the goal tool to persist it.", .{intent});
    var goal_opts = opts;
    goal_opts.task = task;
    try cmdRun(init, goal_opts);
}

fn cmdNotify(init: std.process.Init, opts: Options) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    if (!cfg.modules.peers) {
        log.log(.error_, "peers module is disabled...", .{});
        return error.ModuleDisabled;
    }
    const peer_name = opts.peer orelse return error.MissingPeer;
    const message = opts.message orelse return error.MissingMessage;

    var found: ?*const config.Peer = null;
    for (cfg.peers) |*p| {
        if (std.mem.eql(u8, p.name, peer_name)) {
            found = p;
            break;
        }
    }
    const peer = found orelse {
        log.log(.error_, "unknown peer '{s}'", .{peer_name});
        return error.UnknownPeer;
    };

    const url = try std.fmt.allocPrint(arena, "{s}/api/notify", .{std.mem.trimEnd(u8, peer.url, "/")});

    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));

    var body_buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&body_buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("from");
    try s.write(cfg.instance.name);
    try s.objectField("kind");
    try s.write("notify");
    try s.objectField("topic");
    try s.write(cfg.notify.topic);
    try s.objectField("payload");
    try s.write(message);
    try s.objectField("ts");
    try s.print("{d}", .{ts});
    try s.endObject();
    const payload = body_buf[0..w.end];

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var response_buf: [64 * 1024]u8 = undefined;
    var rw: std.Io.Writer = .fixed(&response_buf);
    const result = http_client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .headers = .{ .content_type = .{ .override = "application/json" }, .user_agent = .{ .override = "clanker/0.1.0" } },
        .response_writer = &rw,
    }) catch |err| {
        log.log(.error_, "notify to '{s}' failed: {s}", .{ peer.name, @errorName(err) });
        return err;
    };
    const status = result.status;
    const response = response_buf[0..rw.end];
    log.log(.info, "notify {s}: HTTP {d} ({s})", .{ peer.name, @intFromEnum(status), response });
}

fn cmdMcp(init: std.process.Init, opts: Options) !void {
    _ = opts;
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    if (!cfg.modules.mcp) {
        log.log(.error_, "mcp module is disabled...", .{});
        return error.ModuleDisabled;
    }
    try mcp.serve(io, gpa, arena, &cfg, init.environ_map);
}

fn cmdChat(init: std.process.Init, opts: Options) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    if (!cfg.modules.chatrooms or !cfg.chatrooms.on) {
        log.log(.error_, "chatrooms module is disabled...", .{});
        return error.ModuleDisabled;
    }
    const base = std.Io.Dir.cwd();
    const state_dir = cfg.agent.state_dir;
    const out = std.Io.File.stdout();

    if (std.mem.eql(u8, opts.chat_sub, "rooms")) {
        const rooms = try chatrooms.listRooms(base, io, gpa, arena, state_dir);
        const subs = try chatrooms.subscribedRooms(base, io, arena, state_dir, &cfg);
        try out.writeStreamingAll(io, "room\tmsgs\tlast_ts\tlast_from\tlast_text\n");
        var buf: [16 * 1024]u8 = undefined;
        for (rooms) |r| {
            const line = std.fmt.bufPrint(&buf, "{s}\t{d}\t{d}\t{s}\t{s}\n", .{ r.room, r.messages, r.last_ts, r.last_from, r.last_text }) catch continue;
            try out.writeStreamingAll(io, line);
        }
        try out.writeStreamingAll(io, "subscribed: ");
        var first = true;
        for (subs) |s| {
            if (!first) try out.writeStreamingAll(io, ", ");
            try out.writeStreamingAll(io, s);
            first = false;
        }
        try out.writeStreamingAll(io, "\n");
    } else if (std.mem.eql(u8, opts.chat_sub, "send")) {
        const msg = try chatrooms.sendMessage(base, io, gpa, arena, state_dir, &cfg, opts.room.?, opts.message.?);
        const line = try std.fmt.allocPrint(arena, "sent to #{s} as {s} (ts {d}, id {s})\n", .{ msg.room, msg.from, msg.ts, msg.id });
        try out.writeStreamingAll(io, line);
    } else if (std.mem.eql(u8, opts.chat_sub, "history")) {
        const after: i64 = if (opts.message) |m| (std.fmt.parseInt(i64, m, 10) catch 0) else 0;
        const msgs = try chatrooms.readHistory(base, io, gpa, arena, state_dir, opts.room.?, after, 50);
        var buf: [16 * 1024]u8 = undefined;
        for (msgs) |m| {
            const line = std.fmt.bufPrint(&buf, "[{d}] {s}: {s}\n", .{ m.ts, m.from, m.text }) catch continue;
            try out.writeStreamingAll(io, line);
        }
        if (msgs.len == 0) try out.writeStreamingAll(io, "(no messages)\n");
    } else if (std.mem.eql(u8, opts.chat_sub, "subscribe")) {
        const on = if (opts.message) |m|
            (std.mem.eql(u8, m, "true") or std.mem.eql(u8, m, "on") or std.mem.eql(u8, m, "1") or std.mem.eql(u8, m, "yes"))
        else
            true;
        try chatrooms.subscribe(base, io, gpa, arena, state_dir, opts.room.?, on);
        const line = try std.fmt.allocPrint(arena, "{s} {s}\n", .{ if (on) "subscribed to" else "unsubscribed from", opts.room.? });
        try out.writeStreamingAll(io, line);
    } else {
        return error.BadSubcommand;
    }
}

fn cmdStats(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    if (!cfg.modules.token_stats) {
        log.log(.error_, "token_stats module is disabled...", .{});
        return error.ModuleDisabled;
    }
    const base = std.Io.Dir.cwd();
    const state_dir = cfg.agent.state_dir;
    const stats = try token_stats.aggregate(base, io, gpa, arena, state_dir);
    const total = token_stats.totals(stats);
    const out = std.Io.File.stdout();

    if (stats.len == 0) {
        try out.writeStreamingAll(io, "no token usage recorded yet (run an agent task first)\n");
        return;
    }

    var buf: [2048]u8 = undefined;
    try out.writeStreamingAll(io, "provider        model                 calls   prompt  complet   total  cache%  tok/s       cost$\n");
    for (stats) |st| {
        const line = std.fmt.bufPrint(&buf, "{s:<15} {s:<20} {d:>5} {d:>7} {d:>7} {d:>8} {d:>5.1} {d:>7.1} {d:>10.4}\n", .{
            st.provider,          st.model,
            st.calls,             st.prompt_tokens,
            st.completion_tokens, st.total_tokens,
            st.cacheHitRate(),    st.tokensPerSec(),
            st.cost,
        }) catch continue;
        try out.writeStreamingAll(io, line);
    }
    const tline = std.fmt.bufPrint(&buf, "{s:<15} {s:<20} {d:>5} {d:>7} {d:>7} {d:>8} {d:>5.1} {d:>7.1} {d:>10.4}\n", .{
        "totals",                "",
        total.calls,             total.prompt_tokens,
        total.completion_tokens, total.total_tokens,
        total.cacheHitRate(),    total.tokensPerSec(),
        total.cost,
    }) catch return;
    try out.writeStreamingAll(io, tline);
}

fn cmdGit(init: std.process.Init, opts: Options) !void {
    _ = opts;
    // Convenience passthrough (unrestricted — this is the user's own shell).
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(init.gpa);
    try argv.append(init.gpa, "git");
    var it = init.minimal.args.iterate();
    var seen_git = false;
    while (it.next()) |arg| {
        if (!seen_git) {
            if (std.mem.eql(u8, arg, "git")) {
                seen_git = true;
                continue;
            }
            continue;
        }
        try argv.append(init.gpa, arg);
    }
    const result = try std.process.run(init.gpa, init.io, .{ .argv = argv.items });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    try std.Io.File.stdout().writeStreamingAll(init.io, result.stdout);
    try std.Io.File.stderr().writeStreamingAll(init.io, result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.GitFailed;
}

fn cmdRevert(init: std.process.Init, opts: Options) !void {
    const gpa = init.gpa;
    const io = init.io;
    const id = opts.task orelse return error.MissingArg;
    var hist = history.History.init(gpa, io, std.Io.Dir.cwd(), "state");
    try hist.revert(id);
}

// ------------------------------------------------------------ serve ------

fn cmdServe(init: std.process.Init, opts: Options) !void {
    const io = init.io;
    const gpa = init.gpa;
    const port = opts.port;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    // reuse_address lets a restarted `clanker serve` rebind immediately even
    // if a stale socket from a previous instance lingers (AddressInUse).
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true });
    defer server.socket.close(io);

    log.log(.info, "serve listening on 127.0.0.1:{d}", .{port});
    // Bare clickable URL (no log prefix) so terminals render it as a link.
    std.debug.print("http://127.0.0.1:{d}/webui\n", .{port});

    // Hot-reload: a background thread watches the binary and re-execs into
    // `serve --port <port>` once a rebuild lands and no request is in
    // flight (see HotReload doc comment). `reuse_address` on the listen
    // socket above lets the new process rebind immediately.
    const exe_path = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe_path);
    if (cfg.modules.hot_reload) {
        hot_reload_active = HotReload.start(arena, io, gpa, exe_path, try buildServeArgvTail(arena, port));
    }

    while (true) {
        const stream = server.accept(io) catch |err| {
            log.log(.error_, "accept error: {s}", .{@errorName(err)});
            continue;
        };
        serveConnection(io, gpa, &cfg, init.environ_map, port, stream);
    }
}

/// Everything a connection thread needs; heap-allocated because the thread
/// outlives the accept-loop iteration that spawned it.
const Connection = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: *const config.Config,
    environ_map: *std.process.Environ.Map,
    port: u16,
    stream: std.Io.net.Stream,
};

/// One accepted connection previously ran to completion inside the accept
/// loop, so a single `/api/run` — an agent turn that can take minutes — stalled
/// every other client, including a `/api/status` poll from the same page. Each
/// connection now gets its own detached thread.
///
/// The shared state this exposes is deliberately small: `cfg` is read-only for
/// the lifetime of the process, `environ_map` is only read (writes happen once
/// at startup in dotenv.load), `gpa` and the `Io` implementation are threadsafe
/// per std.process.Init, and the two pieces of genuinely mutable server state —
/// the streaming socket and the gzip cache — are made per-thread and mutex-
/// guarded respectively.
const max_connection_threads = 64;
var connection_threads = std.atomic.Value(u32).init(0);

fn serveConnection(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, environ_map: *std.process.Environ.Map, port: u16, stream: std.Io.net.Stream) void {
    // A bound, so a flood of slow clients cannot make the process spawn
    // threads without limit. Over it, say so and close rather than queueing:
    // a client that waits behind 64 in-flight agent turns has already lost.
    const in_flight = connection_threads.fetchAdd(1, .acq_rel);
    if (in_flight >= max_connection_threads) {
        _ = connection_threads.fetchSub(1, .acq_rel);
        respond(stream, 503, "Service Unavailable", "{\"error\":\"too many concurrent connections\"}");
        stream.close(io);
        return;
    }

    const conn = gpa.create(Connection) catch {
        _ = connection_threads.fetchSub(1, .acq_rel);
        handleConnectionGuarded(io, gpa, cfg, environ_map, port, stream);
        return;
    };
    conn.* = .{ .io = io, .gpa = gpa, .cfg = cfg, .environ_map = environ_map, .port = port, .stream = stream };

    const thread = std.Thread.spawn(.{}, connectionThread, .{conn}) catch {
        // Out of threads: serving it on the accept loop is slower than a
        // dedicated thread but still correct, and beats dropping the client.
        gpa.destroy(conn);
        _ = connection_threads.fetchSub(1, .acq_rel);
        handleConnectionGuarded(io, gpa, cfg, environ_map, port, stream);
        return;
    };
    thread.detach();
}

fn connectionThread(conn: *Connection) void {
    defer {
        const gpa = conn.gpa;
        gpa.destroy(conn);
        _ = connection_threads.fetchSub(1, .acq_rel);
    }
    handleConnectionGuarded(conn.io, conn.gpa, conn.cfg, conn.environ_map, conn.port, conn.stream);
}

fn handleConnectionGuarded(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, environ_map: *std.process.Environ.Map, port: u16, stream: std.Io.net.Stream) void {
    // A hot-reload must never fire mid-request (would drop the client
    // mid-response); see HotReload's doc comment.
    if (hot_reload_active) |hr| hr.begin();
    defer if (hot_reload_active) |hr| hr.end();
    handleConnection(io, gpa, cfg, environ_map, port, stream);
}

fn handleConnection(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, environ_map: *std.process.Environ.Map, port: u16, stream: std.Io.net.Stream) void {
    defer stream.close(io);
    var total: std.ArrayList(u8) = .empty;
    defer total.deinit(gpa);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(stream.socket.handle, &tmp) catch return;
        if (n == 0) return;
        total.appendSlice(gpa, tmp[0..n]) catch return;
        if (total.items.len > (1 << 20)) return;
        if (requestComplete(total.items)) break;
    }
    if (std.mem.indexOf(u8, total.items, "\r\n\r\n")) |hdr_end| {
        const headers_raw = total.items[0..hdr_end];
        const body = total.items[hdr_end + 4 ..];
        var method: []const u8 = "";
        var target: []const u8 = "";
        if (std.mem.indexOf(u8, headers_raw, "\r\n")) |line_end| {
            var it = std.mem.tokenizeAny(u8, headers_raw[0..line_end], " ");
            method = it.next() orelse "";
            target = it.next() orelse "";
        }
        const is_webui = std.mem.eql(u8, target, "/") or std.mem.eql(u8, target, "/webui") or
            std.mem.eql(u8, target, "/webui/vendor/d3-dag.min.js") or std.mem.eql(u8, target, "/webui/vendor/hljs.min.js");
        const is_a2a = std.mem.eql(u8, target, "/.well-known/agent.json") or (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, target, "/api/a2a/message"));
        const is_notify = std.mem.eql(u8, method, "POST") and std.mem.eql(u8, target, "/api/notify");
        const is_chat_message = std.mem.eql(u8, method, "POST") and std.mem.eql(u8, target, "/api/chat/message");
        const is_chat_messages = std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, target, "/api/chat/messages");
        const is_chat_rooms = std.mem.eql(u8, method, "GET") and std.mem.eql(u8, target, "/api/chat/rooms");
        const is_chat_send = std.mem.eql(u8, method, "POST") and std.mem.eql(u8, target, "/api/chat/send");
        const is_chat_subscribe = std.mem.eql(u8, method, "POST") and std.mem.eql(u8, target, "/api/chat/subscribe");
        const is_stats = std.mem.eql(u8, method, "GET") and std.mem.eql(u8, target, "/api/stats");
        const is_plugins = std.mem.eql(u8, target, "/api/plugins") and (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "POST"));
        const is_goals = std.mem.eql(u8, method, "GET") and std.mem.eql(u8, target, "/api/goals");
        const is_providers = std.mem.eql(u8, method, "GET") and std.mem.eql(u8, target, "/api/providers");
        const is_todos = std.mem.eql(u8, target, "/api/todos") and (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "POST"));
        const is_logs = std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, target, "/api/logs");
        const is_plugin_config = std.mem.eql(u8, method, "POST") and std.mem.eql(u8, target, "/api/plugins/config");
        if (is_webui and !cfg.modules.webui) {
            respond(stream, 404, "Not Found", "{\"error\":\"webui module disabled\"}");
        } else if (is_a2a and !cfg.modules.a2a) {
            respond(stream, 404, "Not Found", "{\"error\":\"a2a module disabled\"}");
        } else if (is_notify and !cfg.modules.peers) {
            respond(stream, 404, "Not Found", "{\"error\":\"peers module disabled\"}");
        } else if ((is_chat_message or is_chat_messages or is_chat_rooms or is_chat_send or is_chat_subscribe) and !cfg.modules.chatrooms) {
            respond(stream, 404, "Not Found", "{\"error\":\"chatrooms module disabled\"}");
        } else if (is_stats and !cfg.modules.token_stats) {
            respond(stream, 404, "Not Found", "{\"error\":\"token_stats module disabled\"}");
        } else if (std.mem.eql(u8, method, "GET") and (std.mem.eql(u8, target, "/") or std.mem.eql(u8, target, "/webui"))) {
            handleWebui(io, gpa, cfg, environ_map, stream);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, target, "/webui/vendor/d3-dag.min.js")) {
            respondJs(gpa, stream, webui_vendor_d3dag, &gzip_d3dag, acceptsGzip(headers_raw));
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, target, "/webui/vendor/hljs.min.js")) {
            respondJs(gpa, stream, webui_vendor_hljs, &gzip_hljs, acceptsGzip(headers_raw));
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, target, "/.well-known/agent.json")) {
            handleAgentCard(gpa, cfg, port, stream);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, target, "/api/status")) {
            handleStatus(cfg, stream);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, target, "/api/runs")) {
            handleRuns(io, gpa, cfg, environ_map, target, stream);
        } else if (std.mem.startsWith(u8, target, "/api/sessions") and
            (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "POST") or std.mem.eql(u8, method, "DELETE")))
        {
            handleSessions(io, gpa, cfg, method, target, body, stream);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, target, "/api/notify")) {
            handleNotify(io, gpa, body) catch {
                respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
                return;
            };
            respond(stream, 200, "OK", "{\"ok\":true}");
        } else if (is_chat_message) {
            handleChatMessage(io, gpa, cfg, body, stream);
        } else if (is_chat_messages) {
            handleChatMessages(io, gpa, cfg, target, stream);
        } else if (is_chat_rooms) {
            handleChatRooms(io, gpa, cfg, stream);
        } else if (is_chat_send) {
            handleChatSend(io, gpa, cfg, body, stream);
        } else if (is_chat_subscribe) {
            handleChatSubscribe(io, gpa, cfg, body, stream);
        } else if (is_stats) {
            handleStats(io, gpa, cfg, stream);
        } else if (is_plugin_config) {
            handlePluginConfig(io, gpa, cfg, body, stream);
        } else if (is_plugins) {
            handlePlugins(io, gpa, cfg, environ_map, method, body, stream);
        } else if (is_goals) {
            handleGoals(io, gpa, cfg, stream);
        } else if (is_providers) {
            handleProviders(cfg, stream);
        } else if (is_todos) {
            handleTodos(io, gpa, method, body, stream);
        } else if (is_logs) {
            handleLogs(io, gpa, target, stream);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, target, "/api/a2a/message")) {
            handleA2AMessage(gpa, stream, body);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, target, "/api/run")) {
            handleRun(io, gpa, cfg, environ_map, stream, body);
        } else {
            respond(stream, 404, "Not Found", "{\"error\":\"not found\"}");
        }
    } else {
        respond(stream, 400, "Bad Request", "{}");
    }
}

const NotifyRequestBody = struct {
    from: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    topic: ?[]const u8 = null,
    payload: ?std.json.Value = null,
    ts: ?i64 = null,
};

const NotificationRecord = struct {
    from: []const u8,
    kind: []const u8,
    topic: []const u8,
    payload: std.json.Value,
    ts: i64,
    received_at: i64,
};

const A2ARequest = struct {
    id: ?std.json.Value = null,
    method: ?[]const u8 = null,
    params: ?std.json.Value = null,
};

fn handleNotify(io: std.Io, gpa: std.mem.Allocator, body: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSliceLeaky(NotifyRequestBody, arena, body, .{ .ignore_unknown_fields = true });
    const from = parsed.from orelse "";
    const kind = parsed.kind orelse "";
    const topic = parsed.topic orelse "";
    const ts = parsed.ts orelse 0;
    const payload = parsed.payload orelse .null;
    // Seconds since epoch, matching the `ts` field cmdNotify sends and the
    // units used for session created/updated timestamps elsewhere.
    const received_at: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    const record = NotificationRecord{ .from = from, .kind = kind, .topic = topic, .payload = payload, .ts = ts, .received_at = received_at };

    std.Io.Dir.cwd().createDirPath(io, "state") catch {};
    const file_path = "state/notifications.jsonl";
    const maybe_existing = std.Io.Dir.cwd().readFileAlloc(io, file_path, gpa, .limited(1 << 20)) catch null;
    defer if (maybe_existing) |e| gpa.free(e);
    const existing = maybe_existing orelse &[_]u8{};

    var line_buf: [1 << 20]u8 = undefined;
    var w: std.Io.Writer = .fixed(&line_buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.write(record);
    const line = line_buf[0..w.end];

    var out_list = std.ArrayList(u8).empty;
    defer out_list.deinit(gpa);
    try out_list.appendSlice(gpa, existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') try out_list.append(gpa, '\n');
    try out_list.appendSlice(gpa, line);
    try out_list.append(gpa, '\n');
    try atomic_write.writeFile(io, std.Io.Dir.cwd(), file_path, out_list.items);
}

const ChatMessageBody = struct {
    room: ?[]const u8 = null,
    from: ?[]const u8 = null,
    text: ?[]const u8 = null,
    ts: ?i64 = null,
    id: ?[]const u8 = null,
};

/// POST /api/chat/message — a peer clanker delivering a chatroom message.
/// Appends it only when this instance subscribes to the room and answers
/// {"ok":true,"subscribed":bool} so the sender knows delivery succeeded.
fn handleChatMessage(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, body: []const u8, stream: std.Io.net.Stream) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSliceLeaky(ChatMessageBody, arena, body, .{ .ignore_unknown_fields = true }) catch {
        respond(stream, 400, "Bad Request", "{\"error\":\"bad request\"}");
        return;
    };
    const room = parsed.room orelse {
        respond(stream, 400, "Bad Request", "{\"error\":\"missing room\"}");
        return;
    };
    const text = parsed.text orelse "";
    if (text.len > chatrooms.max_text_len) {
        respond(stream, 400, "Bad Request", "{\"error\":\"text too long\"}");
        return;
    }
    const msg = chatrooms.Message{
        .room = room,
        .from = parsed.from orelse "unknown",
        .text = text,
        .ts = parsed.ts orelse 0,
        .id = parsed.id orelse "peer",
    };
    const accepted = chatrooms.receive(std.Io.Dir.cwd(), io, gpa, arena, cfg.agent.state_dir, cfg, msg) catch false;
    var buf: [64]u8 = undefined;
    const body_out = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"subscribed\":{}}}", .{accepted}) catch return;
    respond(stream, 200, "OK", body_out);
}

/// GET /api/chat/messages?room=dev&after=123 — room history (newest first).
fn handleChatMessages(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, target: []const u8, stream: std.Io.net.Stream) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var room: []const u8 = "";
    var after: i64 = 0;
    if (std.mem.indexOfScalar(u8, target, '?')) |q| {
        var params = std.mem.splitScalar(u8, target[q + 1 ..], '&');
        while (params.next()) |pair| {
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                const k = pair[0..eq];
                const v = pair[eq + 1 ..];
                // Decoded, not taken raw: a direct-message room is named
                // `dm:<a>|<b>`, and both of those characters have to travel
                // percent-encoded through the query string. Comparing the
                // encoded form against the stored name matched nothing.
                if (std.mem.eql(u8, k, "room")) room = percentDecode(arena, v) catch v;
                if (std.mem.eql(u8, k, "after")) after = std.fmt.parseInt(i64, v, 10) catch 0;
            }
        }
    }
    if (room.len == 0) {
        respond(stream, 400, "Bad Request", "{\"error\":\"missing room\"}");
        return;
    }
    const msgs = chatrooms.readHistory(std.Io.Dir.cwd(), io, gpa, arena, cfg.agent.state_dir, room, after, 50) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
        return;
    };
    var buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    s.beginObject() catch return;
    s.objectField("ok") catch return;
    s.write(true) catch return;
    s.objectField("messages") catch return;
    s.beginArray() catch return;
    for (msgs) |m| {
        s.beginObject() catch return;
        s.objectField("room") catch return;
        s.write(m.room) catch return;
        s.objectField("from") catch return;
        s.write(m.from) catch return;
        s.objectField("text") catch return;
        s.write(m.text) catch return;
        s.objectField("ts") catch return;
        s.print("{d}", .{m.ts}) catch return;
        s.objectField("id") catch return;
        s.write(m.id) catch return;
        s.endObject() catch return;
    }
    s.endArray() catch return;
    s.endObject() catch return;
    respond(stream, 200, "OK", buf[0..w.end]);
}

/// `POST /api/chat/send` — this instance speaking, as opposed to
/// `/api/chat/message`, which is the inbound endpoint peers post to. The
/// difference matters: sending appends locally *and* fans the message out to
/// every configured peer, while the inbound path deliberately refuses rooms
/// this instance has not joined.
fn handleChatSend(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, body: []const u8, stream: std.Io.net.Stream) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSliceLeaky(ChatSendBody, arena, body, .{ .ignore_unknown_fields = true }) catch {
        respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"bad request\"}");
        return;
    };
    const room = parsed.room orelse {
        respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"missing room\"}");
        return;
    };
    const text = parsed.text orelse "";
    if (text.len == 0) {
        respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"empty message\"}");
        return;
    }
    if (text.len > chatrooms.max_text_len) {
        respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"text too long\"}");
        return;
    }
    // Speaking in a room implies belonging to it. Without this a direct
    // message would be silently dropped by `append`, which only logs rooms
    // this instance has joined — and a DM room has no reason to exist in the
    // config before someone opens it.
    if (!chatrooms.isSubscribed(std.Io.Dir.cwd(), io, arena, cfg.agent.state_dir, cfg, room)) {
        chatrooms.subscribe(std.Io.Dir.cwd(), io, gpa, arena, cfg.agent.state_dir, room, true) catch {
            respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"could not join room\"}");
            return;
        };
    }
    const msg = chatrooms.sendMessage(std.Io.Dir.cwd(), io, gpa, arena, cfg.agent.state_dir, cfg, room, text) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"send failed\"}");
        return;
    };
    var buf: [8 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    s.beginObject() catch return;
    s.objectField("ok") catch return;
    s.write(true) catch return;
    s.objectField("id") catch return;
    s.write(msg.id) catch return;
    s.objectField("ts") catch return;
    s.write(msg.ts) catch return;
    s.endObject() catch return;
    respond(stream, 200, "OK", buf[0..w.end]);
}

/// `POST /api/chat/subscribe` — join or leave a room, so the web UI can open a
/// direct message that no config file has ever mentioned.
fn handleChatSubscribe(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, body: []const u8, stream: std.Io.net.Stream) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSliceLeaky(ChatSubscribeBody, arena, body, .{ .ignore_unknown_fields = true }) catch {
        respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"bad request\"}");
        return;
    };
    const room = parsed.room orelse {
        respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"missing room\"}");
        return;
    };
    chatrooms.subscribe(std.Io.Dir.cwd(), io, gpa, arena, cfg.agent.state_dir, room, parsed.on) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
        return;
    };
    respond(stream, 200, "OK", "{\"ok\":true}");
}

/// Decodes `%XX` escapes and `+` in a query-string value. Invalid escapes are
/// left as the literal characters they are rather than rejected: this feeds a
/// room-name comparison, and a name that fails to decode simply fails to match.
fn percentDecode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(arena, s.len);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(arena, c);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(arena, c);
                i += 1;
                continue;
            };
            try out.append(arena, hi * 16 + lo);
            i += 3;
            continue;
        }
        try out.append(arena, if (c == '+') ' ' else c);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

test "percentDecode handles dm room names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("dm:a|b", try percentDecode(arena, "dm%3Aa%7Cb"));
    try std.testing.expectEqualStrings("dev", try percentDecode(arena, "dev"));
    try std.testing.expectEqualStrings("a b", try percentDecode(arena, "a+b"));
    // A stray percent is data, not an error.
    try std.testing.expectEqualStrings("100%", try percentDecode(arena, "100%"));
    try std.testing.expectEqualStrings("%zz", try percentDecode(arena, "%zz"));
}

const ChatSendBody = struct {
    room: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

const ChatSubscribeBody = struct {
    room: ?[]const u8 = null,
    on: bool = true,
};

/// GET /api/chat/rooms — room stats + this instance's subscriptions.
fn handleChatRooms(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, stream: std.Io.net.Stream) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rooms = chatrooms.listRooms(std.Io.Dir.cwd(), io, gpa, arena, cfg.agent.state_dir) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
        return;
    };
    const subs = chatrooms.subscribedRooms(std.Io.Dir.cwd(), io, arena, cfg.agent.state_dir, cfg) catch &[_][]const u8{};
    var buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    s.beginObject() catch return;
    s.objectField("ok") catch return;
    s.write(true) catch return;
    s.objectField("rooms") catch return;
    s.beginArray() catch return;
    for (rooms) |r| {
        s.beginObject() catch return;
        s.objectField("room") catch return;
        s.write(r.room) catch return;
        s.objectField("messages") catch return;
        s.print("{d}", .{r.messages}) catch return;
        s.objectField("last_ts") catch return;
        s.print("{d}", .{r.last_ts}) catch return;
        s.objectField("last_from") catch return;
        s.write(r.last_from) catch return;
        s.objectField("last_text") catch return;
        s.write(r.last_text) catch return;
        s.endObject() catch return;
    }
    s.endArray() catch return;
    s.objectField("subscribed") catch return;
    s.beginArray() catch return;
    for (subs) |sub| s.write(sub) catch return;
    s.endArray() catch return;
    s.endObject() catch return;
    respond(stream, 200, "OK", buf[0..w.end]);
}

/// GET /api/stats — aggregated token usage per provider/model.
fn handleStats(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, stream: std.Io.net.Stream) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const stats = token_stats.aggregate(std.Io.Dir.cwd(), io, gpa, arena, cfg.agent.state_dir) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
        return;
    };
    const json_out = token_stats.statsJSON(arena, stats, token_stats.totals(stats)) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
        return;
    };
    respond(stream, 200, "OK", json_out);
}

fn handleAgentCard(gpa: std.mem.Allocator, cfg: *const config.Config, port: u16, stream: std.Io.net.Stream) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const url = std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{port}) catch return;
    var buf: [1 << 20]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    s.beginObject() catch return;
    s.objectField("name") catch return;
    s.write(cfg.instance.name) catch return;
    s.objectField("description") catch return;
    s.write("clanker self-improving agent") catch return;
    s.objectField("url") catch return;
    s.write(url) catch return;
    s.objectField("skills") catch return;
    s.beginArray() catch return;
    s.write("self-improve") catch return;
    s.write("tools") catch return;
    s.write("mcp") catch return;
    s.write("goals") catch return;
    s.endArray() catch return;
    s.objectField("version") catch return;
    s.write("0.1.0") catch return;
    s.objectField("capabilities") catch return;
    s.beginObject() catch return;
    s.objectField("streaming") catch return;
    s.write(false) catch return;
    s.objectField("pushNotifications") catch return;
    s.write(true) catch return;
    s.endObject() catch return;
    s.endObject() catch return;
    respond(stream, 200, "OK", buf[0..w.end]);
}

fn handleA2AMessage(gpa: std.mem.Allocator, stream: std.Io.net.Stream, body: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSliceLeaky(A2ARequest, arena, body, .{ .ignore_unknown_fields = true }) catch {
        respond(stream, 400, "Bad Request", "{\"error\":\"bad request\"}");
        return;
    };
    const id = parsed.id orelse .null;
    var text: []const u8 = "";
    if (parsed.params) |p| {
        if (p == .object) {
            if (p.object.get("message")) |m| {
                if (m == .object) {
                    if (m.object.get("parts")) |parts| {
                        if (parts == .array and parts.array.items.len > 0) {
                            if (parts.array.items[0] == .object) {
                                if (parts.array.items[0].object.get("text")) |t| {
                                    if (t == .string) text = t.string;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    var buf: [1 << 20]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    s.beginObject() catch return;
    s.objectField("jsonrpc") catch return;
    s.write("2.0") catch return;
    // JSON-RPC 2.0: the response id belongs at the top level so callers can
    // correlate it with their request (it was previously nested in result).
    s.objectField("id") catch return;
    s.write(id) catch return;
    s.objectField("result") catch return;
    s.beginObject() catch return;
    s.objectField("message") catch return;
    s.beginObject() catch return;
    // A2A: messages produced by the agent must carry role "agent";
    // role "user" makes peers treat our reply as new user input.
    s.objectField("role") catch return;
    s.write("agent") catch return;
    s.objectField("parts") catch return;
    s.beginArray() catch return;
    s.beginObject() catch return;
    s.objectField("text") catch return;
    s.write(text) catch return;
    s.endObject() catch return;
    s.endArray() catch return;
    s.endObject() catch return;
    s.objectField("context") catch return;
    s.beginObject() catch return;
    s.endObject() catch return;
    s.endObject() catch return;
    s.endObject() catch return;
    respond(stream, 200, "OK", buf[0..w.end]);
}

/// One image pasted or dropped into the web composer, sent with a run.
const RunImage = struct {
    mime: []const u8 = "",
    b64: []const u8 = "",
};

const RunRequestBody = struct {
    task: []const u8 = "",
    /// When true, the answer is streamed back as plain text chunks as the
    /// agent produces it (Connection: close terminates the stream).
    stream: bool = false,
    /// Optional session id: when set (and modules.sessions is on), the prior
    /// transcript is loaded before the turn and the updated transcript is
    /// saved after, so the web UI can hold a real multi-turn conversation
    /// instead of one-shot, context-free requests.
    session: []const u8 = "",
    /// Images the composer attached to this task (multimodal runs).
    images: []const RunImage = &.{},
    /// Optional per-run overrides, the request-shaped equivalent of
    /// `--provider` and the model's sampling settings in config.json. Empty or
    /// null means "use what the config says".
    provider: []const u8 = "",
    model: []const u8 = "",
    temperature: ?f64 = null,
    top_p: ?f64 = null,
};

/// The composer refuses images over 4 MB; the server enforces the same cap on
/// each attachment's decoded size, since a hand-written request is not the page.
const max_image_bytes = 4 * 1024 * 1024;

/// The decoded length of a base64 payload without decoding it, so the 4 MB
/// image cap is enforced on bytes, not on the encoding.
fn b64DecodedLen(b64: []const u8) usize {
    if (b64.len == 0) return 0;
    var n = (b64.len / 4) * 3;
    if (b64.len % 4 != 0) n += 3;
    if (b64[b64.len - 1] == '=') n -= 1;
    if (b64.len >= 2 and b64[b64.len - 2] == '=') n -= 1;
    return n;
}

/// Socket for streaming /api/run output. The agent's `on_token`/`on_tool_call`
/// hooks are bare function pointers with no context argument, so the
/// destination has to live outside the call. `threadlocal` rather than a plain
/// global because each connection runs on its own thread: two concurrent
/// streaming runs would otherwise write into whichever socket was assigned
/// last, splicing one client's answer into the other's response.
threadlocal var run_stream_socket: ?std.posix.fd_t = null;

fn runStreamDelta(delta: []const u8) void {
    if (run_stream_socket) |fd| {
        writeAllFd(fd, delta);
    }
}

/// Out-of-band control lines in the /api/run stream are prefixed with this
/// byte (never valid at the start of a UTF-8 text run) so the client can tell
/// "tool ran" / "turn finished" events apart from literal answer text without
/// a second connection or a heavier framing format.
const stream_event_prefix = "\x01";

fn writeStreamEvent(fd: std.posix.fd_t, event_type: []const u8, extra: anytype) void {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.writeAll(stream_event_prefix) catch return;
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    s.beginObject() catch return;
    s.objectField("type") catch return;
    s.write(event_type) catch return;
    inline for (@typeInfo(@TypeOf(extra)).@"struct".fields) |f| {
        s.objectField(f.name) catch return;
        s.write(@field(extra, f.name)) catch return;
    }
    s.endObject() catch return;
    w.writeAll("\n") catch return;
    writeAllFd(fd, buf[0..w.end]);
}

fn runStreamToolCall(calls: []const types.ToolCall) void {
    const fd = run_stream_socket orelse return;
    var names_buf: [512]u8 = undefined;
    var names_w: std.Io.Writer = .fixed(&names_buf);
    for (calls, 0..) |tc, i| {
        if (i > 0) names_w.writeAll(", ") catch break;
        names_w.writeAll(tc.name) catch break;
    }
    writeStreamEvent(fd, "tool_call", .{ .names = names_buf[0..names_w.end] });
}

fn runStreamToolResult(ms: u64) void {
    const fd = run_stream_socket orelse return;
    writeStreamEvent(fd, "tool_result", .{ .ms = ms });
}

/// Renders the web UI by calling the internal `webui` WASM tool and serves the
/// resulting HTML page.
fn handleWebui(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, environ_map: *std.process.Environ.Map, stream: std.Io.net.Stream) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const reg = registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir) catch {
        respond(stream, 500, "Internal Server Error", "{\"error\":\"tools registry unavailable\"}");
        return;
    };
    const tool = reg.get("webui") orelse {
        respond(stream, 500, "Internal Server Error", "{\"error\":\"webui tool not found (run zig build tools)\"}");
        return;
    };
    const wasm_bytes = std.Io.Dir.cwd().readFileAlloc(io, tool.wasm, gpa, .limited(1 << 20)) catch {
        respond(stream, 500, "Internal Server Error", "{\"error\":\"webui wasm missing (run zig build tools)\"}");
        return;
    };
    defer gpa.free(wasm_bytes);

    var sb = host.Sandbox{
        .gpa = gpa,
        .io = io,
        .root_dir = cfg.agent.sandbox_root,
        .network_allow = tool.network_allow,
        .environ_map = environ_map,
    };
    const mod = runtime.ToolModule.load(gpa, io, &sb, wasm_bytes) catch {
        respond(stream, 500, "Internal Server Error", "{\"error\":\"webui load failed\"}");
        return;
    };
    defer mod.deinit();
    const out = mod.executeTool("{\"path\":\"/\"}") catch {
        respond(stream, 500, "Internal Server Error", "{\"error\":\"webui render failed\"}");
        return;
    };
    defer gpa.free(out);

    // Output: {"ok":true,"content_type":"text/html","body":"..."}
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, out, .{ .ignore_unknown_fields = true }) catch {
        respond(stream, 500, "Internal Server Error", "{\"error\":\"webui bad output\"}");
        return;
    };
    const body = switch (parsed) {
        .object => |o| if (o.get("body")) |b| switch (b) {
            .string => |s| s,
            else => return respond(stream, 500, "Internal Server Error", "{\"error\":\"webui bad body\"}"),
        } else return respond(stream, 500, "Internal Server Error", "{\"error\":\"webui no body\"}"),
        else => return respond(stream, 500, "Internal Server Error", "{\"error\":\"webui bad output\"}"),
    };
    respondHtml(stream, 200, "OK", body);
}

/// `GET /api/runs` lists recorded runs; `GET /api/runs/<id>` returns one whole
/// graph. Both are answered by the cmd_graph plugin's json modes, so reading
/// `state/runs/` stays on the plugin side of the split.
fn handleRuns(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: *const config.Config,
    environ_map: *std.process.Environ.Map,
    target: []const u8,
    stream: std.Io.net.Stream,
) void {
    if (!cfg.modules.graphs) {
        respond(stream, 404, "Not Found", "{\"error\":\"graphs module disabled\"}");
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rest = target["/api/runs".len..];
    var args: []const u8 = "json";
    if (rest.len > 1 and rest[0] == '/') {
        const id = rest[1..];
        // Run ids are `run-<digits>`; anything else is refused before it can
        // reach the filesystem as a path fragment.
        if (!std.mem.startsWith(u8, id, "run-") or id.len > 64) {
            respond(stream, 400, "Bad Request", "{\"error\":\"bad run id\"}");
            return;
        }
        for (id["run-".len..]) |c| {
            if (!std.ascii.isDigit(c)) {
                respond(stream, 400, "Bad Request", "{\"error\":\"bad run id\"}");
                return;
            }
        }
        args = std.fmt.allocPrint(arena, "json {s}", .{id}) catch {
            respond(stream, 500, "Internal Server Error", "{\"error\":\"out of memory\"}");
            return;
        };
    } else if (rest.len != 0) {
        respond(stream, 404, "Not Found", "{\"error\":\"no such endpoint\"}");
        return;
    }

    const body = toolText(io, gpa, arena, cfg, environ_map, "cmd_graph", args) catch {
        respond(stream, 500, "Internal Server Error", "{\"error\":\"graph read failed\"}");
        return;
    };
    respond(stream, 200, "OK", body);
}

/// `GET /api/sessions` lists saved conversations; `GET /api/sessions/<id>`
/// returns one whole transcript. Answered natively rather than through a
/// plugin (the way `/api/runs` reaches cmd_graph) because session.zig already
/// owns this store on the native side, and a long transcript exceeds the
/// 64 KiB host arena a WASM tool reads through.
/// Byte weight of a transcript, the same measure
/// `agent.compact_threshold_bytes` is compared against.
fn transcriptBytes(msgs: []const types.Message) usize {
    var n: usize = 0;
    for (msgs) |m| n += if (m.content) |c| c.len else 0;
    return n;
}

/// Drop the oldest messages until the transcript fits under half the configured
/// threshold. Whole messages only, and the most recent exchange always stays:
/// a compaction that left a tool result without its call would corrupt the
/// conversation rather than shorten it.
fn compactSession(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    id: []const u8,
    threshold: usize,
) !usize {
    var s = try session.loadSession(io, gpa, arena, std.Io.Dir.cwd(), id);
    const target = threshold / 2;
    var first: usize = 0;
    // Never touch the last two messages: that is the most recent exchange.
    const floor = if (s.messages.len > 2) s.messages.len - 2 else 0;
    while (first < floor and transcriptBytes(s.messages[first..]) > target) : (first += 1) {}
    // A tool result whose call was just dropped is orphaned; drop it too.
    while (first < floor and s.messages[first].tool_call_id != null) : (first += 1) {}
    if (first > 0) {
        s.messages = s.messages[first..];
        s.updated = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
        try session.saveSession(io, gpa, arena, std.Io.Dir.cwd(), s);
    }
    return transcriptBytes(s.messages);
}

test "compactSession keeps whole messages and the last exchange" {
    // Exercised through the pure part: the trimming rule, not the file I/O.
    const msgs = [_]types.Message{
        .{ .role = .user, .content = "a" ** 100 },
        .{ .role = .assistant, .content = "b" ** 100 },
        .{ .role = .user, .content = "c" ** 100 },
        .{ .role = .assistant, .content = "d" ** 100 },
    };
    try std.testing.expectEqual(@as(usize, 400), transcriptBytes(&msgs));
    try std.testing.expectEqual(@as(usize, 200), transcriptBytes(msgs[2..]));
}

const TodoPost = struct {
    text: ?[]const u8 = null,
    id: ?[]const u8 = null,
    done: ?bool = null,
    remove: ?bool = null,
};

const Todo = struct {
    id: []const u8,
    text: []const u8,
    done: bool = false,
    created: i64 = 0,
};

/// A shared checklist at `state/todos.json`, readable and writable by the page
/// and by anything else that opens the file. One POST shape covers add, toggle
/// and remove: which one it is follows from which fields are present.
/// Every configured provider and its models, so the composer can offer the
/// same choice `--provider` does instead of always running the default.
fn handleProviders(cfg: *const config.Config, stream: std.Io.net.Stream) void {
    var buf: [1 << 16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    s.beginObject() catch return;
    s.objectField("ok") catch return;
    s.write(true) catch return;
    s.objectField("default") catch return;
    s.write(cfg.default_provider) catch return;
    s.objectField("providers") catch return;
    s.beginArray() catch return;
    var it = cfg.providers.iterator();
    while (it.next()) |entry| {
        const prov = entry.value_ptr;
        s.beginObject() catch return;
        s.objectField("name") catch return;
        s.write(entry.key_ptr.*) catch return;
        s.objectField("default_model") catch return;
        s.write(prov.default_model) catch return;
        s.objectField("models") catch return;
        s.beginArray() catch return;
        var mit = prov.models.iterator();
        while (mit.next()) |m| {
            s.beginObject() catch return;
            s.objectField("name") catch return;
            s.write(m.key_ptr.*) catch return;
            s.objectField("context_window") catch return;
            s.write(m.value_ptr.context_window) catch return;
            s.objectField("max_tokens") catch return;
            s.write(m.value_ptr.max_tokens) catch return;
            if (m.value_ptr.temperature) |t| {
                s.objectField("temperature") catch return;
                s.write(t) catch return;
            }
            if (m.value_ptr.top_p) |t| {
                s.objectField("top_p") catch return;
                s.write(t) catch return;
            }
            s.endObject() catch return;
        }
        s.endArray() catch return;
        s.endObject() catch return;
    }
    s.endArray() catch return;
    s.endObject() catch return;
    respond(stream, 200, "OK", buf[0..w.end]);
}

fn handleTodos(
    io: std.Io,
    gpa: std.mem.Allocator,
    method: []const u8,
    body: []const u8,
    stream: std.Io.net.Stream,
) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = std.Io.Dir.cwd().readFileAlloc(io, todos_path, arena, .limited(1 << 20)) catch "[]";
    var list: std.ArrayList(Todo) = .empty;
    if (std.json.parseFromSliceLeaky([]Todo, arena, raw, .{ .ignore_unknown_fields = true }) catch null) |existing| {
        list.appendSlice(arena, existing) catch {
            respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
            return;
        };
    }

    if (std.mem.eql(u8, method, "POST")) {
        const req = std.json.parseFromSliceLeaky(TodoPost, arena, body, .{ .ignore_unknown_fields = true }) catch {
            respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"bad request\"}");
            return;
        };
        if (req.text) |text| {
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (trimmed.len == 0 or trimmed.len > 500) {
                respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"text must be 1-500 characters\"}");
                return;
            }
            const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
            const id = std.fmt.allocPrint(arena, "t-{d}-{d}", .{ now, list.items.len }) catch {
                respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
                return;
            };
            list.append(arena, .{ .id = id, .text = trimmed, .created = now }) catch {
                respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
                return;
            };
        } else if (req.id) |id| {
            var kept: std.ArrayList(Todo) = .empty;
            var hit = false;
            for (list.items) |t| {
                if (!std.mem.eql(u8, t.id, id)) {
                    kept.append(arena, t) catch continue;
                    continue;
                }
                hit = true;
                if (req.remove orelse false) continue;
                var updated = t;
                updated.done = req.done orelse !t.done;
                kept.append(arena, updated) catch continue;
            }
            if (!hit) {
                respond(stream, 404, "Not Found", "{\"ok\":false,\"error\":\"no such todo\"}");
                return;
            }
            list = kept;
        } else {
            respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"need text or id\"}");
            return;
        }
        var enc: std.Io.Writer.Allocating = .init(arena);
        std.json.Stringify.value(list.items, .{}, &enc.writer) catch {
            respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
            return;
        };
        atomic_write.writeFile(io, std.Io.Dir.cwd(), todos_path, enc.written()) catch {
            respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"write failed\"}");
            return;
        };
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.writeAll("{\"ok\":true,\"todos\":") catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
        return;
    };
    std.json.Stringify.value(list.items, .{}, &out.writer) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
        return;
    };
    out.writer.writeAll("}") catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
        return;
    };
    respond(stream, 200, "OK", out.written());
}

const todos_path = "state/todos.json";

/// `GET /api/logs` lists the log files; `GET /api/logs/<name>` returns the tail
/// of one. Names are matched against the listing rather than sanitised, so a
/// crafted name cannot describe a path at all.
fn handleLogs(io: std.Io, gpa: std.mem.Allocator, target: []const u8, stream: std.Io.net.Stream) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rest = target["/api/logs".len..];
    var dir = std.Io.Dir.cwd().openDir(io, "state/logs", .{ .iterate = true }) catch {
        respond(stream, 200, "OK", "{\"ok\":true,\"logs\":[]}");
        return;
    };
    defer dir.close(io);

    if (rest.len > 1 and rest[0] == '/') {
        const want = percentDecode(arena, rest[1..]) catch {
            respond(stream, 400, "Bad Request", "{\"error\":\"bad log name\"}");
            return;
        };
        var it = dir.iterate();
        var found = false;
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.eql(u8, entry.name, want)) found = true;
        }
        if (!found) {
            respond(stream, 404, "Not Found", "{\"error\":\"no such log\"}");
            return;
        }
        const raw = dir.readFileAlloc(io, want, arena, .limited(log_tail_bytes * 8)) catch {
            respond(stream, 500, "Internal Server Error", "{\"error\":\"log read failed\"}");
            return;
        };
        // Tail only, cut at a line boundary so the view never opens mid-line.
        var tail = if (raw.len > log_tail_bytes) raw[raw.len - log_tail_bytes ..] else raw;
        if (raw.len > log_tail_bytes) {
            if (std.mem.indexOfScalar(u8, tail, '\n')) |nl| tail = tail[nl + 1 ..];
        }
        var out: std.Io.Writer.Allocating = .init(arena);
        var s = std.json.Stringify{ .writer = &out.writer };
        s.beginObject() catch return;
        s.objectField("ok") catch return;
        s.write(true) catch return;
        s.objectField("name") catch return;
        s.write(want) catch return;
        s.objectField("bytes") catch return;
        s.write(raw.len) catch return;
        s.objectField("text") catch return;
        s.write(tail) catch return;
        s.endObject() catch return;
        respond(stream, 200, "OK", out.written());
        return;
    }
    if (rest.len != 0) {
        respond(stream, 404, "Not Found", "{\"error\":\"no such endpoint\"}");
        return;
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &out.writer };
    s.beginObject() catch return;
    s.objectField("ok") catch return;
    s.write(true) catch return;
    s.objectField("logs") catch return;
    s.beginArray() catch return;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        s.beginObject() catch return;
        s.objectField("name") catch return;
        s.write(entry.name) catch return;
        s.objectField("bytes") catch return;
        s.write(stat.size) catch return;
        s.endObject() catch return;
    }
    s.endArray() catch return;
    s.endObject() catch return;
    respond(stream, 200, "OK", out.written());
}

const log_tail_bytes = 64 * 1024;

fn handleSessions(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: *const config.Config,
    method: []const u8,
    target: []const u8,
    body: []const u8,
    stream: std.Io.net.Stream,
) void {
    if (!cfg.modules.sessions) {
        respond(stream, 404, "Not Found", "{\"error\":\"sessions module disabled\"}");
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rest = target["/api/sessions".len..];
    if (rest.len > 1 and rest[0] == '/') {
        const id = rest[1..];
        // `POST /api/sessions/<id>/fork` branches a conversation. The fork
        // suffix is handled before the id validation below because
        // "<id>/fork" itself contains a separator and would never pass it.
        if (std.mem.eql(u8, method, "POST") and std.mem.endsWith(u8, id, "/fork")) {
            const src_id = id[0 .. id.len - "/fork".len];
            if (!validSessionId(src_id)) {
                respond(stream, 400, "Bad Request", "{\"error\":\"bad session id\"}");
                return;
            }
            const new_id = session.forkSession(io, gpa, arena, std.Io.Dir.cwd(), src_id) catch {
                respond(stream, 404, "Not Found", "{\"ok\":false,\"error\":\"no such session\"}");
                return;
            };
            var fork_buf: [256]u8 = undefined;
            const fork_body = std.fmt.bufPrint(&fork_buf, "{{\"ok\":true,\"id\":\"{s}\"}}", .{new_id}) catch return;
            respond(stream, 200, "OK", fork_body);
            return;
        }
        // `POST /api/sessions/<id>/compact` drops the oldest exchanges by hand,
        // the same thing agent.compact_threshold_bytes does on its own once a
        // transcript grows past it. Suffix first, for the reason fork gives.
        if (std.mem.eql(u8, method, "POST") and std.mem.endsWith(u8, id, "/compact")) {
            const src_id = id[0 .. id.len - "/compact".len];
            if (!validSessionId(src_id)) {
                respond(stream, 400, "Bad Request", "{\"error\":\"bad session id\"}");
                return;
            }
            const bytes = compactSession(io, gpa, arena, src_id, cfg.agent.compact_threshold_bytes) catch {
                respond(stream, 404, "Not Found", "{\"ok\":false,\"error\":\"no such session\"}");
                return;
            };
            var cbuf: [128]u8 = undefined;
            const cbody = std.fmt.bufPrint(&cbuf, "{{\"ok\":true,\"bytes\":{d}}}", .{bytes}) catch return;
            respond(stream, 200, "OK", cbody);
            return;
        }
        if (!validSessionId(id)) {
            respond(stream, 400, "Bad Request", "{\"error\":\"bad session id\"}");
            return;
        }
        if (std.mem.eql(u8, method, "DELETE")) {
            session.deleteSession(io, arena, std.Io.Dir.cwd(), id) catch {
                respond(stream, 404, "Not Found", "{\"ok\":false,\"error\":\"no such session\"}");
                return;
            };
            respond(stream, 200, "OK", "{\"ok\":true}");
            return;
        }
        if (std.mem.eql(u8, method, "POST")) {
            const req = std.json.parseFromSliceLeaky(SessionPatchBody, arena, body, .{ .ignore_unknown_fields = true }) catch {
                respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"bad request\"}");
                return;
            };
            const title = req.title orelse {
                respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"missing title\"}");
                return;
            };
            session.renameSession(io, gpa, arena, std.Io.Dir.cwd(), id, title) catch {
                respond(stream, 404, "Not Found", "{\"ok\":false,\"error\":\"no such session\"}");
                return;
            };
            respond(stream, 200, "OK", "{\"ok\":true}");
            return;
        }
        const s = session.loadSession(io, gpa, arena, std.Io.Dir.cwd(), id) catch {
            respond(stream, 404, "Not Found", "{\"error\":\"no such session\"}");
            return;
        };
        const one = sessionJSON(arena, s) catch {
            respond(stream, 500, "Internal Server Error", "{\"error\":\"session encode failed\"}");
            return;
        };
        respond(stream, 200, "OK", one);
        return;
    }
    if (rest.len != 0) {
        respond(stream, 404, "Not Found", "{\"error\":\"no such endpoint\"}");
        return;
    }

    const list = session.listSessions(io, arena, std.Io.Dir.cwd()) catch {
        respond(stream, 500, "Internal Server Error", "{\"error\":\"session list failed\"}");
        return;
    };
    const listing = sessionListJSON(arena, list) catch {
        respond(stream, 500, "Internal Server Error", "{\"error\":\"session encode failed\"}");
        return;
    };
    respond(stream, 200, "OK", listing);
}

/// Session ids reach the filesystem as a path fragment, so they are restricted
/// to the shapes this server itself mints: a UUID from the browser, or the
/// `sess-<base36>` fallback. Anything with a separator or a dot is refused
/// before it can be used to walk out of `state/sessions/`.
fn validSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

test "validSessionId refuses path traversal" {
    try std.testing.expect(validSessionId("7f3a1c2e-0b44-4a91-9d3e-1c2b3a4d5e6f"));
    try std.testing.expect(validSessionId("sess-m1x2y3-ab12cd"));
    try std.testing.expect(!validSessionId("../../etc/passwd"));
    try std.testing.expect(!validSessionId("a/b"));
    try std.testing.expect(!validSessionId("a.json"));
    try std.testing.expect(!validSessionId(""));
    try std.testing.expect(!validSessionId("x" ** 65));
}

test "fork route suffix parsing yields a valid source id and refuses traversal" {
    // POST /api/sessions/<id>/fork strips the suffix before validating.
    const id = "sess-abc/fork";
    try std.testing.expect(std.mem.endsWith(u8, id, "/fork"));
    try std.testing.expect(validSessionId(id[0 .. id.len - "/fork".len]));
    // A traversal attempt in the source id is refused, not sanitised.
    const bad = "../../etc/fork";
    try std.testing.expect(!validSessionId(bad[0 .. bad.len - "/fork".len]));
    // A real session id never ends in the fork marker, so the rename POST
    // for a plain id cannot be shadowed by the fork branch.
    try std.testing.expect(!std.mem.endsWith(u8, "sess-abc", "/fork"));
}

test "forkSession mints an id that still passes validSessionId" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try session.saveSession(io, std.testing.allocator, arena, tmp.dir, .{
        .id = "sess-1",
        .title = "t",
        .messages = &.{.{ .role = .user, .content = "hi" }},
        .created = 1,
        .updated = 2,
    });
    const forked = try session.forkSession(io, std.testing.allocator, arena, tmp.dir, "sess-1");
    // The fork id is returned to the client and must itself stay addressable
    // through the id-validated session endpoints.
    try std.testing.expect(validSessionId(forked));
}

fn sessionListJSON(arena: std.mem.Allocator, list: []const session.SessionMeta) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("sessions");
    try s.beginArray();
    for (list) |m| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(m.id);
        try s.objectField("title");
        try s.write(m.title);
        try s.objectField("created");
        try s.write(m.created);
        try s.objectField("updated");
        try s.write(m.updated);
        try s.objectField("messages");
        try s.write(m.messages);
        try s.objectField("bytes");
        try s.write(m.bytes);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    return out.written();
}

/// Only the roles the transcript actually renders: system prompts are internal
/// and tool-call plumbing is already shown by the run graph, so shipping them
/// here would just be noise the UI has to filter again.
fn sessionJSON(arena: std.mem.Allocator, s_in: session.Session) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("id");
    try s.write(s_in.id);
    try s.objectField("title");
    try s.write(s_in.title);
    try s.objectField("created");
    try s.write(s_in.created);
    try s.objectField("updated");
    try s.write(s_in.updated);
    try s.objectField("messages");
    try s.beginArray();
    for (s_in.messages) |m| {
        if (m.role != .user and m.role != .assistant) continue;
        if (m.content == null or m.content.?.len == 0) continue;
        try s.beginObject();
        try s.objectField("role");
        try s.write(if (m.role == .user) "user" else "assistant");
        try s.objectField("content");
        try s.write(m.content.?);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    return out.written();
}

/// `GET /api/plugins` lists every WASM tool with its on/off state;
/// `POST /api/plugins {"name":…,"on":bool}` switches an optional one. Both go
/// through the cmd_plugins tool, which already owns reading the descriptors and
/// writing `state/plugins.json`, so the HTTP surface and `/plugins` in the REPL
/// can never disagree about what is enabled.
fn handlePlugins(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: *const config.Config,
    environ_map: *std.process.Environ.Map,
    method: []const u8,
    body: []const u8,
    stream: std.Io.net.Stream,
) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args: []const u8 = "json";
    if (std.mem.eql(u8, method, "POST")) {
        const req = std.json.parseFromSliceLeaky(PluginToggleBody, arena, body, .{ .ignore_unknown_fields = true }) catch {
            respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"bad request\"}");
            return;
        };
        const name = req.name orelse {
            respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"missing name\"}");
            return;
        };
        // The name becomes a word in the tool's argument string, so anything
        // with whitespace in it would silently become a different command.
        if (name.len == 0 or name.len > 64 or std.mem.indexOfAny(u8, name, " \t\r\n") != null) {
            respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"bad plugin name\"}");
            return;
        }
        args = std.fmt.allocPrint(arena, "{s} {s}", .{ if (req.on) "on" else "off", name }) catch {
            respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
            return;
        };
    }

    const out = toolText(io, gpa, arena, cfg, environ_map, "cmd_plugins", args) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"plugin read failed\"}");
        return;
    };
    respond(stream, 200, "OK", out);
}

const SessionPatchBody = struct {
    title: ?[]const u8 = null,
};

const PluginToggleBody = struct {
    name: ?[]const u8 = null,
    on: bool = true,
};

/// `POST /api/plugins/config {"name":…,"config":{…}}` — change a plugin's
/// tunable settings.
///
/// Written to `state/plugin_config.json` rather than the descriptor: the
/// manifest is committed project configuration and the improve loop rewrites
/// it, so a machine-local preference does not belong there. The registry
/// layers this file over the descriptor at load, and drops any key the
/// descriptor did not list in `config_editable`, so a tool's structural
/// settings cannot be reached from here. This endpoint refuses them outright
/// too, rather than accepting a write it knows will be ignored.
fn handlePluginConfig(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, body: []const u8, stream: std.Io.net.Stream) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch {
        respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"bad request\"}");
        return;
    };
    if (parsed != .object) {
        respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"bad request\"}");
        return;
    }
    const name = switch (parsed.object.get("name") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => {
            respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"missing name\"}");
            return;
        },
    };
    const wanted = switch (parsed.object.get("config") orelse std.json.Value{ .null = {} }) {
        .object => |o| o,
        else => {
            respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"config must be an object\"}");
            return;
        },
    };

    var reg = registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"registry unavailable\"}");
        return;
    };
    const tool = reg.get(name) orelse {
        respond(stream, 404, "Not Found", "{\"ok\":false,\"error\":\"no such tool\"}");
        return;
    };
    var it = wanted.iterator();
    while (it.next()) |entry| {
        if (!tool.configKeyEditable(entry.key_ptr.*)) {
            respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"that setting is not editable\"}");
            return;
        }
    }

    // Read-modify-write of the whole file: other plugins' overrides live here
    // too and must survive an edit to this one.
    var store: std.json.Value = .{ .object = .{} };
    if (std.Io.Dir.cwd().readFileAlloc(io, registry.plugin_config_state_path, arena, .limited(256 * 1024)) catch null) |raw| {
        if (std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch null) |existing| {
            if (existing == .object) store = existing;
        }
    }
    var merged: std.json.ObjectMap = .empty;
    if (store.object.get(name)) |prev| {
        if (prev == .object) merged = prev.object.clone(arena) catch .empty;
    }
    var set = wanted.iterator();
    while (set.next()) |entry| {
        merged.put(arena, entry.key_ptr.*, entry.value_ptr.*) catch {
            respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
            return;
        };
    }
    var out_store = store.object.clone(arena) catch store.object;
    out_store.put(arena, name, .{ .object = merged }) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
        return;
    };

    var doc: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &doc.writer, .options = .{} };
    s.write(std.json.Value{ .object = out_store }) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
        return;
    };
    atomic_write.writeFile(io, std.Io.Dir.cwd(), registry.plugin_config_state_path, doc.written()) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"could not save\"}");
        return;
    };
    respond(stream, 200, "OK", "{\"ok\":true}");
}

/// `GET /api/goals` — the structured goals that steer runs, straight from
/// `state/goals.json`. Read natively rather than through the goal tool, which
/// only writes: it appends a new goal and has no read mode.
fn handleGoals(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, stream: std.Io.net.Stream) void {
    if (!cfg.modules.goal) {
        respond(stream, 404, "Not Found", "{\"error\":\"goal module disabled\"}");
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = std.Io.Dir.cwd().readFileAlloc(io, "state/goals.json", arena, .limited(1 << 20)) catch {
        // No file yet is the ordinary state on a fresh checkout, not an error.
        respond(stream, 200, "OK", "{\"ok\":true,\"goals\":[]}");
        return;
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.writeAll("{\"ok\":true,\"goals\":") catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
        return;
    };
    // Passed through verbatim: it is already the array this endpoint returns,
    // and re-encoding it would only add a way for the two to drift.
    out.writer.writeAll(std.mem.trim(u8, raw, " \t\r\n")) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
        return;
    };
    out.writer.writeAll("}") catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
        return;
    };
    respond(stream, 200, "OK", out.written());
}

/// Instance + configured peers, consumed by the web UI status panel.
fn handleStatus(cfg: *const config.Config, stream: std.Io.net.Stream) void {
    var buf: [1 << 16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    s.beginObject() catch return;
    s.objectField("instance") catch return;
    s.beginObject() catch return;
    s.objectField("name") catch return;
    s.write(cfg.instance.name) catch return;
    s.objectField("id") catch return;
    s.write(cfg.instance.id) catch return;
    s.endObject() catch return;
    s.objectField("peers") catch return;
    s.beginArray() catch return;
    for (cfg.peers) |p| {
        s.beginObject() catch return;
        s.objectField("name") catch return;
        s.write(p.name) catch return;
        s.objectField("url") catch return;
        s.write(p.url) catch return;
        s.endObject() catch return;
    }
    s.endArray() catch return;
    s.endObject() catch return;
    respond(stream, 200, "OK", buf[0..w.end]);
}

/// Runs one agent task synchronously and returns the final answer as JSON:
/// {"ok":true,"content":"..."} or {"ok":false,"error":"..."}.
fn handleRun(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, environ_map: *std.process.Environ.Map, stream: std.Io.net.Stream, body: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const req = std.json.parseFromSliceLeaky(RunRequestBody, arena, body, .{ .ignore_unknown_fields = true }) catch {
        respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"bad request body\"}");
        return;
    };
    if (req.task.len == 0) {
        respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"missing task\"}");
        return;
    }

    var ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = environ_map, .cfg = cfg };
    var provider = cfg.provider(if (req.provider.len > 0) req.provider else null) catch {
        respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"no such provider\"}");
        return;
    };
    var provider_copy = provider.*;
    provider = &provider_copy;
    // A model the provider does not define is refused rather than silently
    // falling back: running the wrong model quietly is worse than a 400.
    if (req.model.len > 0) {
        if (provider_copy.models.get(req.model) == null) {
            respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"no such model for that provider\"}");
            return;
        }
        provider_copy.default_model = req.model;
    }
    if (req.temperature != null or req.top_p != null) {
        var m = provider_copy.activeModel();
        if (req.temperature) |t| m.temperature = std.math.clamp(t, 0.0, 2.0);
        if (req.top_p) |t| m.top_p = std.math.clamp(t, 0.0, 1.0);
        provider_copy.models.put(arena, provider_copy.default_model, m) catch {};
    }

    std.Io.Dir.cwd().createDirPath(io, cfg.agent.sandbox_root) catch {};
    var reg = registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"tools registry unavailable\"}");
        return;
    };
    const tool_defs = reg.toToolDefs(arena) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"tool defs failed\"}");
        return;
    };

    var a = agent.Agent.init(&ctx, arena, provider, cfg, &reg, tool_defs) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"agent init failed\"}");
        return;
    };
    a.subagent_runner = if (cfg.modules.subagents) &subagent.runNested else null;
    // Multimodal attachments from the composer: hand them to the agent, which
    // attaches them to the task message exactly as the tool-result image path
    // does. Same module flag as the agent's own image handling, and the 4 MB
    // per-image cap the page promises is enforced here on decoded bytes.
    if (cfg.modules.multimodal and req.images.len > 0) {
        var imgs: std.ArrayList(types.ImagePart) = .empty;
        for (req.images) |im| {
            if (im.mime.len == 0 or im.b64.len == 0) continue;
            if (b64DecodedLen(im.b64) > max_image_bytes) {
                respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"an image exceeds the 4 MB limit\"}");
                return;
            }
            imgs.append(arena, .{ .mime = im.mime, .b64 = im.b64 }) catch {};
        }
        if (imgs.items.len > 0) a.pending_images = imgs.items;
    }
    var messages: std.ArrayList(types.Message) = .empty;
    var err_detail: ?[]const u8 = null;

    // Optional conversation continuity: a session id turns this from a
    // one-shot, context-free request into a real multi-turn chat, mirroring
    // `clanker run --session` / the REPL.
    const has_session = cfg.modules.sessions and req.session.len > 0;
    var created: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    if (has_session) {
        if (session.loadSession(io, gpa, arena, std.Io.Dir.cwd(), req.session)) |s| {
            created = s.created;
            for (s.messages) |m| {
                if (m.role == .system) continue;
                messages.append(arena, m) catch {};
            }
        } else |_| {}
    }

    if (req.stream) {
        // Streaming mode: send headers up front, then the agent's tokens as
        // they are produced; the final newline + Connection: close ends the
        // stream on the client side.
        writeAllFd(stream.socket.handle, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n");
        run_stream_socket = stream.socket.handle;
        defer run_stream_socket = null;
        a.on_token = &runStreamDelta;
        a.on_tool_call = &runStreamToolCall;
        a.on_tool_result = &runStreamToolResult;
        const t0 = std.Io.Timestamp.now(io, .awake);
        const resp = a.run(&messages, req.task, &err_detail) catch |err| {
            const detail = err_detail orelse @errorName(err);
            writeStreamEvent(stream.socket.handle, "error", .{ .message = detail });
            return;
        };
        // When modules.streaming is off the agent never invokes on_token,
        // so nothing was streamed — write the answer directly or the client
        // would receive an empty body (just the trailer) for a successful run.
        if (!cfg.modules.streaming) {
            if (resp.message.content) |c| writeAllFd(stream.socket.handle, c);
        }
        if (has_session) {
            const title = req.task[0..@min(req.task.len, 60)];
            const updated: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
            session.saveSession(io, gpa, arena, std.Io.Dir.cwd(), .{
                .id = req.session,
                .title = title,
                .messages = messages.items,
                .created = created,
                .updated = updated,
            }) catch {};
        }
        const ms: u64 = @intCast(@divTrunc(t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds, std.time.ns_per_ms));
        // Otherwise the answer was already streamed via runStreamDelta; a
        // structured "done" event carries the turn's stats, then the
        // trailing Connection: close ends the client-side stream.
        writeStreamEvent(stream.socket.handle, "done", .{
            .prompt_tokens = a.stats.total_prompt_tokens,
            .completion_tokens = a.stats.total_completion_tokens,
            .cost = a.stats.cost,
            .ms = ms,
        });
        return;
    }

    const resp = a.run(&messages, req.task, &err_detail) catch |err| {
        const detail = err_detail orelse @errorName(err);
        // Escape `detail` through the JSON stringifier: provider error text
        // can contain quotes, backslashes, or newlines that plain bufPrint
        // interpolation would turn into malformed JSON clients cannot parse.
        var ebuf: [8192]u8 = undefined;
        var ew: std.Io.Writer = .fixed(&ebuf);
        var es = std.json.Stringify{ .writer = &ew, .options = .{ .emit_null_optional_fields = false } };
        const built = err_body: {
            es.beginObject() catch break :err_body false;
            es.objectField("ok") catch break :err_body false;
            es.write(false) catch break :err_body false;
            es.objectField("error") catch break :err_body false;
            es.write(detail) catch break :err_body false;
            es.endObject() catch break :err_body false;
            break :err_body true;
        };
        respond(stream, 500, "Internal Server Error", if (built) ebuf[0..ew.end] else "{\"ok\":false,\"error\":\"run failed\"}");
        return;
    };

    if (has_session) {
        const title = req.task[0..@min(req.task.len, 60)];
        const updated: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
        session.saveSession(io, gpa, arena, std.Io.Dir.cwd(), .{
            .id = req.session,
            .title = title,
            .messages = messages.items,
            .created = created,
            .updated = updated,
        }) catch {};
    }

    const content = resp.message.content orelse "";
    var rbuf: [1 << 20]u8 = undefined;
    var w: std.Io.Writer = .fixed(&rbuf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    s.beginObject() catch return;
    s.objectField("ok") catch return;
    s.write(true) catch return;
    s.objectField("content") catch return;
    s.write(content) catch return;
    s.endObject() catch return;
    respond(stream, 200, "OK", rbuf[0..w.end]);
}

fn respond(stream: std.Io.net.Stream, status: u16, reason: []const u8, body: []const u8) void {
    var hbuf: [4096]u8 = undefined;
    // nosniff on every response, not just the HTML one: these bodies carry peer
    // names, provider error text, and model output, and none of it should ever
    // be content-sniffed into markup.
    const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n", .{ status, reason, body.len }) catch return;
    writeAllFd(stream.socket.handle, hdr);
    writeAllFd(stream.socket.handle, body);
}

/// The web UI ships its CSS and JS inline in one embedded file, so the policy
/// allows inline styles and scripts but no external origin: a page fronting
/// `/api/run` (which executes agent tools) must never be able to pull code from
/// a third party.
const webui_csp = "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

fn respondHtml(stream: std.Io.net.Stream, status: u16, reason: []const u8, body: []const u8) void {
    var hbuf: [4096]u8 = undefined;
    // The page is compiled into the binary and changes on every rebuild, so
    // a cached copy is always a stale one: no-store, unlike the vendored
    // assets below, which are immutable and cached hard.
    const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 {d} {s}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nContent-Security-Policy: {s}\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{ status, reason, body.len, webui_csp }) catch return;
    writeAllFd(stream.socket.handle, hdr);
    writeAllFd(stream.socket.handle, body);
}

/// A gzipped vendor asset, compressed on first request and kept for the rest of
/// the process. The inputs are embedded at build time and identical for every
/// visitor, so compressing per request would burn CPU for the same bytes; the
/// buffer is intentionally never freed, being a two-entry cache that lives as
/// long as the server. A failed attempt (OOM, or output that didn't shrink) is
/// remembered too, so it is not retried on every hit.
const GzipCache = struct {
    /// Connection threads race for this. Whoever moves it out of `idle`
    /// compresses; anyone arriving meanwhile serves the file uncompressed for
    /// that one request instead of blocking behind a ~100ms compression. A
    /// lock would be the other option, but nothing here is worth waiting for:
    /// the identity encoding is always a correct answer.
    state: std.atomic.Value(State) = .init(.idle),
    /// Only read after `state` reads `.ready`, which is stored with release
    /// ordering after this is written.
    body: []const u8 = &.{},

    const State = enum(u8) { idle, compressing, ready, failed };
};

var gzip_d3dag: GzipCache = .{};
var gzip_hljs: GzipCache = .{};

fn gzipCached(gpa: std.mem.Allocator, cache: *GzipCache, raw: []const u8) ?[]const u8 {
    switch (cache.state.load(.acquire)) {
        .ready => return cache.body,
        .failed, .compressing => return null,
        .idle => {},
    }
    if (cache.state.cmpxchgStrong(.idle, .compressing, .acq_rel, .acquire) != null) return null;

    const compressed = gzipAlloc(gpa, raw) orelse {
        cache.state.store(.failed, .release);
        return null;
    };
    // Published in this order so a thread that reads `.ready` is guaranteed to
    // see the finished slice.
    cache.body = compressed;
    cache.state.store(.ready, .release);
    return compressed;
}

fn gzipAlloc(gpa: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    // Sized to the input: a compressed form that needs more room than the
    // original is not worth serving, and running out of space here just means
    // falling back to the identity encoding.
    const dest = gpa.alloc(u8, raw.len) catch return null;
    const window = gpa.alloc(u8, std.compress.flate.max_window_len) catch {
        gpa.free(dest);
        return null;
    };
    defer gpa.free(window);

    var out: std.Io.Writer = .fixed(dest);
    var compress = std.compress.flate.Compress.init(&out, window, .gzip, .default) catch {
        gpa.free(dest);
        return null;
    };
    compress.writer.writeAll(raw) catch {
        gpa.free(dest);
        return null;
    };
    compress.finish() catch {
        gpa.free(dest);
        return null;
    };

    return dest[0..out.end];
}

/// Serves a vendored, build-time-embedded JS asset (webui/vendor/*). These
/// never change without a rebuild, so they get a long, immutable cache
/// lifetime instead of the no-cache posture of the rest of the API, and are
/// gzipped when the client asks — they are the two largest bodies this server
/// sends, and the page is routinely opened from another machine on the LAN.
fn respondJs(gpa: std.mem.Allocator, stream: std.Io.net.Stream, body: []const u8, cache: *GzipCache, accepts_gzip: bool) void {
    var hbuf: [4096]u8 = undefined;
    const gzipped = if (accepts_gzip) gzipCached(gpa, cache, body) else null;
    const out = gzipped orelse body;
    const encoding = if (gzipped != null) "Content-Encoding: gzip\r\n" else "";
    const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\nContent-Type: text/javascript; charset=utf-8\r\nContent-Length: {d}\r\n{s}Vary: Accept-Encoding\r\nCache-Control: public, max-age=31536000, immutable\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n", .{ out.len, encoding }) catch return;
    writeAllFd(stream.socket.handle, hdr);
    writeAllFd(stream.socket.handle, out);
}

/// True when the request's Accept-Encoding lists gzip. Scoped to that header's
/// own line so a request target that happens to contain "gzip" cannot flip it.
fn acceptsGzip(headers_raw: []const u8) bool {
    var lines = std.mem.splitSequence(u8, headers_raw, "\r\n");
    while (lines.next()) |line| {
        if (!std.ascii.startsWithIgnoreCase(line, "accept-encoding:")) continue;
        var values = std.mem.tokenizeAny(u8, line["accept-encoding:".len..], " ,;");
        while (values.next()) |v| {
            if (std.ascii.eqlIgnoreCase(v, "gzip")) return true;
        }
    }
    return false;
}

test "acceptsGzip only matches the header's own line" {
    try std.testing.expect(acceptsGzip("GET / HTTP/1.1\r\nAccept-Encoding: gzip, deflate\r\n"));
    try std.testing.expect(acceptsGzip("GET / HTTP/1.1\r\naccept-encoding:gzip\r\n"));
    try std.testing.expect(!acceptsGzip("GET /gzip.js HTTP/1.1\r\nHost: x\r\n"));
    try std.testing.expect(!acceptsGzip("GET / HTTP/1.1\r\nAccept-Encoding: br, zstd\r\n"));
    try std.testing.expect(!acceptsGzip(""));
}

fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.os.linux.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n > std.math.maxInt(usize) - 4096) return; // errno
        off += n;
    }
}

fn requestComplete(data: []const u8) bool {
    if (std.mem.indexOf(u8, data, "\r\n\r\n")) |hdr_end| {
        const content_length = parseContentLength(data[0..hdr_end]) orelse 0;
        return data.len >= hdr_end + 4 + content_length;
    }
    return false;
}

fn parseContentLength(headers: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        const prefix = "content-length:";
        if (trimmed.len >= prefix.len and std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix)) {
            const value = std.mem.trim(u8, trimmed[prefix.len..], " \t");
            return std.fmt.parseInt(usize, value, 10) catch null;
        }
    }
    return null;
}

// -------------------------------------------------------------- phonebook --

const AgentCard = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    url: ?[]const u8 = null,
    skills: ?[]const []const u8 = null,
    version: ?[]const u8 = null,
};

const PeerScan = struct {
    card: ?AgentCard = null,
    status: []const u8 = "ok",
};

fn fetchAgentCard(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, url: []const u8) PeerScan {
    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var response_buf: [1 << 20]u8 = undefined;
    var rw: std.Io.Writer = .fixed(&response_buf);
    const result = http_client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = .{ .user_agent = .{ .override = "clanker/0.1.0" } },
        .response_writer = &rw,
    }) catch |err| {
        return .{ .status = @errorName(err) };
    };
    if (@intFromEnum(result.status) >= 400) return .{ .status = "http_error" };
    const body = response_buf[0..rw.end];
    const card = std.json.parseFromSliceLeaky(AgentCard, arena, body, .{ .ignore_unknown_fields = true }) catch |err| {
        return .{ .status = @errorName(err) };
    };
    return .{ .card = card };
}

fn cmdPhonebook(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    if (!cfg.modules.peers) {
        log.log(.error_, "peers module is disabled...", .{});
        return error.ModuleDisabled;
    }
    const out = std.Io.File.stdout();
    try out.writeStreamingAll(io, "name\turl\tskills\tstatus\n");

    for (cfg.peers) |peer| {
        const base = std.mem.trimEnd(u8, peer.url, "/");
        const url = try std.fmt.allocPrint(arena, "{s}/.well-known/agent.json", .{base});
        const scan = fetchAgentCard(io, gpa, arena, url);

        const name = if (scan.card) |c| c.name orelse peer.name else peer.name;
        var skills_joined: []const u8 = "";
        if (scan.card) |c| {
            if (c.skills) |skills| {
                var buf: std.ArrayList(u8) = .empty;
                for (skills, 0..) |s, i| {
                    if (i > 0) try buf.append(arena, ',');
                    try buf.appendSlice(arena, s);
                }
                if (buf.items.len > 0) skills_joined = try buf.toOwnedSlice(arena);
            }
        }
        const line = try std.fmt.allocPrint(arena, "{s}\t{s}\t{s}\t{s}\n", .{ name, peer.url, skills_joined, scan.status });
        try out.writeStreamingAll(io, line);
    }
}

test "compactMessages drops oldest non-system messages over token budget" {
    const allocator = std.testing.allocator;
    var messages: std.ArrayList(types.Message) = .empty;
    defer messages.deinit(allocator);
    try messages.append(allocator, .{ .role = .user, .content = "aaaa" });
    try messages.append(allocator, .{ .role = .user, .content = "bbbb" });
    try messages.append(allocator, .{ .role = .user, .content = "cccc" });
    compactMessages(&messages, 2);
    try std.testing.expect(messages.items.len == 2);
}

fn mdStreamRender(allocator: std.mem.Allocator, chunks: []const []const u8) ![]u8 {
    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    var md: MdStream = .{};
    for (chunks) |c| md.feed(&w.writer, c);
    md.flush(&w.writer);
    return allocator.dupe(u8, w.written());
}

test "MdStream renders bold, italic, inline code, and bullets" {
    const allocator = std.testing.allocator;
    const out = try mdStreamRender(allocator, &.{"**bold** *italic* `code` and:\n- one\n- two"});
    defer allocator.free(out);
    try std.testing.expectEqualStrings(
        "\x1b[1mbold\x1b[0m \x1b[3mitalic\x1b[0m \x1b[36mcode\x1b[0m and:\n\xe2\x80\xa2 one\n\xe2\x80\xa2 two",
        out,
    );
}

test "MdStream resolves a marker split across two feeds" {
    const allocator = std.testing.allocator;
    // "**bold**" fed one byte at a time must match the whole-chunk render.
    var chunks: [8][]const u8 = undefined;
    const text = "**bold**";
    for (text, 0..) |_, i| chunks[i] = text[i .. i + 1];
    const out = try mdStreamRender(allocator, &chunks);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("\x1b[1mbold\x1b[0m", out);
}

test "MdStream flushes a trailing unterminated marker as literal text" {
    const allocator = std.testing.allocator;
    const out = try mdStreamRender(allocator, &.{"looks like a footnote*"});
    defer allocator.free(out);
    try std.testing.expectEqualStrings("looks like a footnote*", out);
}

test "MdStream only treats a leading dash-space as a bullet at line start" {
    const allocator = std.testing.allocator;
    const out = try mdStreamRender(allocator, &.{"a - b\n- c"});
    defer allocator.free(out);
    try std.testing.expectEqualStrings("a - b\n\xe2\x80\xa2 c", out);
}

test "parseChoices reads an inline 'A, or B?' question" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const answer =
        \\Here is the snapshot.
        \\
        \\Want me to draft the eval definition for chatrooms, or dig into the Vertex caching issue?
    ;
    const choices = (try parseChoices(arena, answer)).?;
    try std.testing.expectEqual(@as(usize, 2), choices.len);
    try std.testing.expectEqualStrings("Want me to draft the eval definition for chatrooms", choices[0]);
    try std.testing.expectEqualStrings("dig into the Vertex caching issue", choices[1]);
}

test "parseChoices prefers an enumerated list over splitting the question" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const answer =
        \\Three options:
        \\
        \\1. Prune the stale learnings
        \\2) Add an eval for chat_send
        \\3. Audit the Vertex cache hit rate
        \\
        \\Which one, or something else?
    ;
    const choices = (try parseChoices(arena, answer)).?;
    try std.testing.expectEqual(@as(usize, 3), choices.len);
    try std.testing.expectEqualStrings("Prune the stale learnings", choices[0]);
    try std.testing.expectEqualStrings("Add an eval for chat_send", choices[1]);
    try std.testing.expectEqualStrings("Audit the Vertex cache hit rate", choices[2]);
}

test "parseChoices stays quiet when the answer is not a choice question" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // No question at all.
    try std.testing.expect((try parseChoices(arena, "Done. The eval passes.")) == null);
    // A question with a single answer is not a menu.
    try std.testing.expect((try parseChoices(arena, "Should I start on the eval?")) == null);
    // A numbered list with no closing question is a report, not a prompt.
    const report =
        \\1. built the tool
        \\2. ran the gate
    ;
    try std.testing.expect((try parseChoices(arena, report)) == null);
}

test "MdStream renders headings, rules, quotes and ordered lists" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var md: MdStream = .{};
    md.feed(&w, "# Title\nbody\n## Sub\n> quoted\n---\n1. first\n2) second\n");
    md.flush(&w);
    const out = buf[0..w.end];

    // Headings are styled, and the hashes themselves are not echoed.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1;4mTitle") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1mSub") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# ") == null);
    // Quote gets a gutter, the rule becomes a line, list markers keep numbers.
    try std.testing.expect(std.mem.indexOf(u8, out, "\u{2502} quoted") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\u{2500}\u{2500}\u{2500}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[36m1.\x1b[0m first") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[36m2)\x1b[0m second") != null);
}

test "MdStream leaves fenced code untouched" {
    // Emphasis markers inside a code block are code, not formatting: toggling
    // on them corrupted every snippet containing * or `.
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var md: MdStream = .{};
    md.feed(&w, "```zig\nconst p: *u8 = x; // **not bold**\n```\nafter\n");
    md.flush(&w);
    const out = buf[0..w.end];

    try std.testing.expect(std.mem.indexOf(u8, out, "const p: *u8 = x; // **not bold**") != null);
    // And the fence closes, so following text is not left dim.
    try std.testing.expect(std.mem.endsWith(u8, out, "after\n"));
}

test "MdStream does not mistake a hyphen mid-sentence for a rule" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var md: MdStream = .{};
    md.feed(&w, "well-known --- inline\n");
    md.flush(&w);
    try std.testing.expectEqualStrings("well-known --- inline\n", buf[0..w.end]);
}

test "a bare invocation starts the REPL, and --help still asks for help" {
    // parse() takes the raw argv, so every case here starts with the program
    // name the shell passes.
    try std.testing.expectEqual(Command.repl, (try parse(&.{"clanker"})).command);
    // Global flags alone are still a REPL start, not a usage error.
    const with_flags = try parse(&.{ "clanker", "--provider", "vertex-opus" });
    try std.testing.expectEqual(Command.repl, with_flags.command);
    try std.testing.expectEqualStrings("vertex-opus", with_flags.provider.?);
    // An explicit command still wins, and help stays reachable.
    try std.testing.expectEqual(Command.run, (try parse(&.{ "clanker", "run", "hi" })).command);
    try std.testing.expectEqual(Command.help, (try parse(&.{ "clanker", "--help" })).command);
    // A typo is still a typo, not a silent REPL start.
    try std.testing.expectError(error.UnknownCommand, parse(&.{ "clanker", "runn" }));
}

test "the run request body carries optional images, and the cap counts decoded bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A request without images parses to an empty list, not an error.
    const bare = try std.json.parseFromSliceLeaky(RunRequestBody, arena, "{\"task\":\"hi\"}", .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 0), bare.images.len);

    const with_img = try std.json.parseFromSliceLeaky(RunRequestBody, arena, "{\"task\":\"look\",\"images\":[{\"mime\":\"image/png\",\"b64\":\"aGk=\"}]}", .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), with_img.images.len);
    try std.testing.expectEqualStrings("image/png", with_img.images[0].mime);
    try std.testing.expectEqualStrings("aGk=", with_img.images[0].b64);

    // Decoded-length math: "aGk=" is "hi" (2 bytes), "aGVsbG8=" is "hello" (5).
    try std.testing.expectEqual(@as(usize, 2), b64DecodedLen("aGk="));
    try std.testing.expectEqual(@as(usize, 5), b64DecodedLen("aGVsbG8="));
    try std.testing.expectEqual(@as(usize, 0), b64DecodedLen(""));
}

test "sessionListJSON carries each conversation's byte weight" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const list = [_]session.SessionMeta{
        .{ .id = "s1", .title = "one", .created = 1, .updated = 2, .messages = 2, .bytes = 13 },
    };
    const out = try sessionListJSON(arena, &list);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out, .{});
    const first = parsed.object.get("sessions").?.array.items[0];
    try std.testing.expectEqual(@as(i64, 13), first.object.get("bytes").?.integer);
    try std.testing.expectEqual(@as(i64, 2), first.object.get("messages").?.integer);
}
