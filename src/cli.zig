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
const log = @import("util/log.zig");

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
    serve,
};

pub const Options = struct {
    command: Command = .help,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    task: ?[]const u8 = null,
    session: ?[]const u8 = null,
    goal: ?[]const u8 = null,
    eval_name: ?[]const u8 = null,
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
            } else if (std.mem.eql(u8, a, "serve")) {
                opts.command = .serve;
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
    \\  clanker run --goal <id> "<task>"  run with an active goal
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
        .serve => try cmdServe(init, opts),
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
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    var err_detail: ?[]const u8 = null;
    const resp = a.run(&messages, task_text, &err_detail) catch |err| {
        log.log(.error_, "{s}", .{err_detail orelse @errorName(err)});
        return err;
    };

    if (resp.message.content) |c| {
        try std.Io.File.stdout().writeStreamingAll(io, c);
        try std.Io.File.stdout().writeStreamingAll(io, "\n");
    }

    if (opts.session) |sid| {
        const title = try std.fmt.allocPrint(arena, "{s}", .{opts.task.?[0..@min(opts.task.?.len, 60)]});
        const updated: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
        try session.saveSession(io, init.gpa, arena, std.Io.Dir.cwd(), .{
            .id = sid,
            .title = title,
            .messages = messages.items,
            .created = created,
            .updated = updated,
        });
    }
}

fn cmdSessions(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const metas = try session.listSessions(io, init.gpa, arena, std.Io.Dir.cwd());
    const out = std.Io.File.stdout();
    for (metas) |m| {
        try out.writeStreamingAll(io, m.id);
        try out.writeStreamingAll(io, "\t");
        try out.writeStreamingAll(io, m.title);
        try out.writeStreamingAll(io, "\t");
        try out.writeStreamingAll(io, try std.fmt.allocPrint(arena, "{d}", .{m.updated}));
        try out.writeStreamingAll(io, "\n");
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

fn cmdGoal(init: std.process.Init, opts: Options) !void {
    const arena = init.arena.allocator();
    const intent = opts.task orelse return error.MissingTask;
    const task = try std.fmt.allocPrint(arena, "Design and persist a structured goal for: {s}\n\nDefine all five fields (objective, completion_criterion, proof, boundaries, stop_rule) and call the goal tool to persist it.", .{intent});
    var goal_opts = opts;
    goal_opts.task = task;
    try cmdRun(init, goal_opts);
}

fn cmdMcp(init: std.process.Init, opts: Options) !void {
    _ = opts;
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    try mcp.serve(io, gpa, arena, &cfg);
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

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.socket.close(io);

    log.log(.info, "serve listening on 127.0.0.1:{d}", .{port});

    while (true) {
        const stream = server.accept(io) catch |err| {
            log.log(.error_, "accept error: {s}", .{@errorName(err)});
            continue;
        };
        handleConnection(io, gpa, stream);
    }
}

fn handleConnection(io: std.Io, gpa: std.mem.Allocator, stream: std.Io.net.Stream) void {
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
        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, target, "/api/notify")) {
            handleNotify(io, gpa, body) catch {
                respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
                return;
            };
            respond(stream, 200, "OK", "{\"ok\":true}");
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
    const received_at: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000));
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
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = out_list.items });
}

fn respond(stream: std.Io.net.Stream, status: u16, reason: []const u8, body: []const u8) void {
    var hbuf: [4096]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, reason, body.len }) catch return;
    writeAllFd(stream.socket.handle, hdr);
    writeAllFd(stream.socket.handle, body);
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
