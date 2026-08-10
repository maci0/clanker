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
const log = @import("util/log.zig");

pub const Command = enum {
    help,
    init,
    providers_check,
    run,
    tools_list,
    eval,
    improve_self,
    revert,
    git,
};

pub const Options = struct {
    command: Command = .help,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    task: ?[]const u8 = null,
    eval_name: ?[]const u8 = null,
    iters: u32 = 3,
    dry_run: bool = false,
    verbose: bool = false,
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
        if (opts.command == .git) {
            const joined = if (opts.task) |t| std.fmt.allocPrint(std.heap.page_allocator, "{s} {s}", .{ t, a }) catch t else a;
            opts.task = joined;
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
            } else {
                return error.UnknownArg;
            }
            continue;
        }

        // Non-flag token.
        if (!cmd_seen) {
            cmd_seen = true;
            if (std.mem.eql(u8, a, "init")) {
                opts.command = .init;
            } else if (std.mem.eql(u8, a, "providers")) {
                opts.command = .providers_check;
                pending_sub = "check";
            } else if (std.mem.eql(u8, a, "run")) {
                opts.command = .run;
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
            } else if (std.mem.eql(u8, a, "repl")) {
                return error.NotYetImplemented;
            } else {
                return error.UnknownCommand;
            }
        } else if (pending_sub) |sub| {
            if (std.mem.eql(u8, a, sub)) {
                pending_sub = null;
            } else {
                return error.BadSubcommand;
            }
        } else if (opts.command == .eval and opts.eval_name == null) {
            opts.eval_name = a;
        } else if (opts.command == .revert and opts.task == null) {
            opts.task = a;
        } else if (opts.command == .improve_self and opts.task == null) {
            opts.task = a;
        } else if (opts.command == .providers_check and opts.provider == null) {
            opts.provider = a;
        } else if (opts.command == .run and opts.task == null) {
            opts.task = a;
        } else {
            return error.UnknownArg;
        }
    }

    if (pending_sub != null) return error.BadSubcommand;
    if (opts.command == .run and opts.task == null) return error.MissingTask;
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
    \\  clanker --verbose               enable debug logging
    \\
;

pub fn run(init: std.process.Init, opts: Options) !void {
    switch (opts.command) {
        .help => try writeStdErr(init.io, usage_text),
        .init => try cmdInit(init),
        .providers_check => try cmdProvidersCheck(init, opts),
        .run => try cmdRun(init, opts),
        .tools_list => try cmdToolsList(init, opts),
        .eval => try cmdEval(init, opts),
        .improve_self => try cmdImproveSelf(init, opts),
        .revert => try cmdRevert(init, opts),
        .git => try cmdGit(init, opts),
    }
}

fn writeStdErr(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
}

// -------------------------------------------------------------------- init --

const local_template =
    \\{
    \\  "default_provider": "deepseek",
    \\  "providers": {
    \\    "deepseek": { "kind": "openai_compat", "base_url": "https://api.deepseek.com", "api_key_env": "DEEPSEEK_API_KEY", "model": "deepseek-chat", "max_tokens": 2048 }
    \\  },
    \\  "agent": { "max_iterations": 12 },
    \\  "improve": { "min_delta": 0.05 }
    \\}
    \\
;

fn cmdInit(init: std.process.Init) !void {
    const io = init.io;
    const dir = std.Io.Dir.cwd();
    const local = "config.local.json";
    _ = dir.openFile(io, local, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try dir.writeFile(io, .{ .sub_path = local, .data = local_template });
            log.log(.info, "wrote {s}", .{local});
        },
        else => return err,
    };
    dir.createDirPath(io, "state") catch {};
    log.log(.info, "clanker initialized. Export DEEPSEEK_API_KEY, then run: clanker run \"hello\"", .{});
}

// --------------------------------------------------------- providers check --

fn cmdProvidersCheck(init: std.process.Init, opts: Options) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    var ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = init.environ_map };

    var it = cfg.providers.iterator();
    var checked_any = false;
    while (it.next()) |kv| {
        const name = kv.key_ptr.*;
        if (opts.provider) |want| {
            if (!std.mem.eql(u8, want, name)) continue;
        }
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
        log.log(.info, "{s}: OK — {s} — {d}ms ({d} tok)", .{ name, p.model, ms, tok });
        checked_any = true;
    }
    if (opts.provider != null and !checked_any) return error.UnknownProvider;
}

// ---------------------------------------------------------------------- run --

fn cmdRun(init: std.process.Init, opts: Options) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    var ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = init.environ_map };

    var provider = try cfg.provider(opts.provider);
    var provider_copy = provider.*;
    if (opts.model) |m| provider_copy.model = m;
    provider = &provider_copy;

    // Make sure the sandbox root exists.
    std.Io.Dir.cwd().createDirPath(io, cfg.agent.sandbox_root) catch {};

    var reg = try registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir);
    const tool_defs = try reg.toToolDefs(arena);

    var a = try agent.Agent.init(&ctx, arena, provider, &cfg, &reg, tool_defs);
    var messages: std.ArrayList(types.Message) = .empty;
    var err_detail: ?[]const u8 = null;
    const resp = a.run(&messages, opts.task.?, &err_detail) catch |err| {
        log.log(.error_, "{s}", .{err_detail orelse @errorName(err)});
        return err;
    };

    if (resp.message.content) |c| {
        try std.Io.File.stdout().writeStreamingAll(io, c);
        try std.Io.File.stdout().writeStreamingAll(io, "\n");
    }
}

fn cmdToolsList(init: std.process.Init, opts: Options) !void {
    _ = opts;
    const io = init.io;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    var reg = try registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir);
    const out = std.Io.File.stdout();
    var names = reg.tools.iterator();
    var count: usize = 0;
    while (names.next()) |kv| {
        count += 1;
        try out.writeStreamingAll(io, kv.key_ptr.*);
        try out.writeStreamingAll(io, "\n");
    }
    const summary = try std.fmt.allocPrint(arena, "{d} tool(s) registered\n", .{count});
    try out.writeStreamingAll(io, summary);
}

fn cmdEval(init: std.process.Init, opts: Options) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    var ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = init.environ_map };

    var provider = try cfg.provider(opts.provider);
    var provider_copy = provider.*;
    if (opts.model) |m| provider_copy.model = m;
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
        try list.append(arena, e);
    }
    if (list.items.len == 0) return error.UnknownEval;

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
    var ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = init.environ_map };

    var provider = try cfg.provider(opts.provider);
    var provider_copy = provider.*;
    if (opts.model) |m| provider_copy.model = m;
    provider = &provider_copy;

    std.Io.Dir.cwd().createDirPath(io, cfg.agent.sandbox_root) catch {};
    std.Io.Dir.cwd().createDirPath(io, "state") catch {};
    std.Io.Dir.cwd().createDirPath(io, "state/staging") catch {};

    log.log(.debug, "improve.max_context_bytes = {d}", .{cfg.improve.max_context_bytes});
    var eng = improve.Engine{ .ctx = &ctx, .arena = arena, .provider = provider, .cfg = &cfg, .hist = undefined, .instructions = undefined };
    try eng.run(.{
        .instructions = opts.task orelse return error.MissingTask,
        .iters = opts.iters,
        .dry_run = opts.dry_run,
        .max_context_bytes = cfg.improve.max_context_bytes,
    });
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
