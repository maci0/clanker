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
const graph = @import("agent/graph.zig");
const runtime = @import("sandbox/runtime.zig");
const host = @import("sandbox/host.zig");
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
    notify,
    phonebook,
    serve,
    repl,
    graph,
};

pub const Options = struct {
    command: Command = .help,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    task: ?[]const u8 = null,
    session: ?[]const u8 = null,
    goal: ?[]const u8 = null,
    peer: ?[]const u8 = null,
    message: ?[]const u8 = null,
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
            } else if (std.mem.eql(u8, a, "notify")) {
                opts.command = .notify;
            } else if (std.mem.eql(u8, a, "phonebook")) {
                opts.command = .phonebook;
            } else if (std.mem.eql(u8, a, "serve")) {
                opts.command = .serve;
            } else if (std.mem.eql(u8, a, "graph")) {
                opts.command = .graph;
            } else if (std.mem.eql(u8, a, "repl")) {
                opts.command = .repl;
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
        } else if (opts.command == .graph and opts.task == null) {
            opts.task = a;
        } else if (opts.command == .notify and opts.peer == null) {
            opts.peer = a;
        } else if (opts.command == .notify and opts.message == null) {
            opts.message = a;
        } else {
            return error.UnknownArg;
        }
    }

    if (pending_sub != null) return error.BadSubcommand;
    if (opts.command == .run and opts.task == null) return error.MissingTask;
    if (opts.command == .notify and (opts.peer == null or opts.message == null)) return error.MissingArg;
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
    \\  clanker notify <peer> "<message>" send a notification to a peer
    \\  clanker phonebook               list peer agent cards
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
        .phonebook => try cmdPhonebook(init),
        .serve => try cmdServe(init, opts),
        .repl => try cmdRepl(init, opts),
        .graph => try cmdGraph(init, opts),
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

fn cmdRepl(init: std.process.Init, opts: Options) !void {
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

    const created: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    const sid = try std.fmt.allocPrint(arena, "repl-{d}", .{created});

    var stdin_file = std.Io.File.stdin();
    var read_buf: [4096]u8 = undefined;
    var stdin_reader = stdin_file.reader(io, &read_buf);
    var stdout_file = std.Io.File.stdout();
    var out_buf: [4096]u8 = undefined;
    var out_w = stdout_file.writer(io, &out_buf);

    // Stream the model's tokens to stdout as they arrive.
    repl_out = &out_w;
    a.on_token = &replDelta;

    // Accumulate raw stdin and split on newlines: readSliceShort can return
    // several lines at once (piped input), and each task line must be copied
    // into the arena before the accumulator buffer is shifted (messages keep
    // referencing it across turns).
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(gpa);
    var tmp: [4096]u8 = undefined;

    while (true) {
        try out_w.interface.writeAll("clanker> ");
        try out_w.interface.flush();

        const n = stdin_reader.interface.readSliceShort(&tmp) catch |err| {
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
                try out_w.interface.writeAll("REPL commands: :quit  :help  /help  (any other text is a task)\n");
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
                    try replSlashTool(io, gpa, arena, &cfg, init.environ_map, &reg, line, &out_w);
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
            // Copy the task text into the arena BEFORE shifting the buffer:
            // messages keep referencing it across turns.
            const owned = try arena.dupe(u8, line);
            const rest = acc.items[nl + 1 ..];
            std.mem.copyForwards(u8, acc.items[0..rest.len], rest);
            acc.items.len = rest.len;
            const quit = try replRunTurn(io, &out_w, &a, &messages, owned, created, sid);
            if (quit) return;
        }
    }
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
        try out_w.interface.writeAll("   (try /help)\n");
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
        .environ_map = environ_map,
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

/// Streams REPL output: the model's content deltas land here (via
/// Agent.on_token) while the run is still in flight.
var repl_out: ?*std.Io.File.Writer = null;

fn replDelta(delta: []const u8) void {
    if (repl_out) |w| {
        w.interface.writeAll(delta) catch {};
        w.interface.flush() catch {};
    }
}

/// Runs one REPL turn for `task` (arena-owned): appends the user message, runs
/// the agent, prints the answer, appends the assistant message, and persists
/// the session. Returns true if the loop should exit (only on :quit).
fn replRunTurn(io: std.Io, out_w: *std.Io.File.Writer, a: *agent.Agent, messages: *std.ArrayList(types.Message), task: []const u8, created: i64, sid: []const u8) !bool {
    const gpa = a.ctx.gpa;
    try messages.append(a.arena, .{ .role = .user, .content = task });
    var err_detail: ?[]const u8 = null;
    const resp = a.run(messages, task, &err_detail) catch |err| {
        log.log(.error_, "{s}", .{err_detail orelse @errorName(err)});
        return false;
    };

    const streamed = a.on_token != null;
    const content = resp.message.content orelse "";
    if (!streamed) {
        try out_w.interface.writeAll(content);
    }
    try out_w.interface.writeAll("\n\n");
    try out_w.interface.flush();
    try messages.append(a.arena, resp.message);

    const updated: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
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

/// `clanker graph [run-id]` — list persisted execution graphs, or render one
/// as an ASCII timeline of LLM calls and tool invocations.
fn cmdGraph(init: std.process.Init, opts: Options) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = std.Io.File.stdout();

    if (opts.task) |run_id| {
        var loaded = graph.load(io, gpa, run_id) catch |err| {
            log.log(.error_, "cannot load run '{s}': {s}", .{ run_id, @errorName(err) });
            return err;
        };
        defer graph.deinitLoaded(&loaded);
        const g = &loaded.graph;

        try out.writeStreamingAll(io, g.run_id);
        try out.writeStreamingAll(io, " — ");
        try out.writeStreamingAll(io, g.task);
        try out.writeStreamingAll(io, try std.fmt.allocPrint(arena, "  ({s}, {d}ms, prompt={d} completion={d})\n", .{ g.provider, g.duration_ms, g.totalPromptTokens(), g.totalCompletionTokens() }));

        var iter_note: u32 = 0;
        for (g.nodes.items) |n| {
            const new_iter = n.iteration != iter_note;
            if (new_iter) {
                iter_note = n.iteration;
                if (iter_note > 1) try out.writeStreamingAll(io, "\n");
                try out.writeStreamingAll(io, try std.fmt.allocPrint(arena, "iter {d}\n", .{n.iteration}));
            }
            switch (n.kind) {
                .llm => try out.writeStreamingAll(io, try std.fmt.allocPrint(arena, "  llm  {s}  {d}/{d} tok, {d}ms\n", .{ n.label, n.prompt_tokens, n.completion_tokens, n.duration_ms })),
                .tool => try out.writeStreamingAll(io, try std.fmt.allocPrint(arena, "  tool {s}  {d} B{s}{s}\n", .{ n.label, n.result_bytes, if (n.ok) "" else " FAILED", if (n.detail.len > 0) try std.fmt.allocPrint(arena, " ({s})", .{n.detail}) else "" })),
                .final => try out.writeStreamingAll(io, try std.fmt.allocPrint(arena, "  done {d} B, {s}, {d}ms\n", .{ n.result_bytes, n.detail, n.duration_ms })),
            }
        }
        try out.writeStreamingAll(io, "\n");
        return;
    }

    // No run-id: list persisted runs, newest first.
    const runs = try graph.listRuns(io, gpa, arena);
    for (runs) |id| {
        var loaded = graph.load(io, gpa, id) catch continue;
        try out.writeStreamingAll(io, id);
        try out.writeStreamingAll(io, "\t");
        try out.writeStreamingAll(io, loaded.graph.task);
        try out.writeStreamingAll(io, try std.fmt.allocPrint(arena, "\t{d}ms\t{d} node(s)\n", .{ loaded.graph.duration_ms, loaded.graph.nodes.items.len }));
        graph.deinitLoaded(&loaded);
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

    const evals = try scorers.Eval.loadAll(arena, io, "eval-tasks");
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

fn cmdNotify(init: std.process.Init, opts: Options) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
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
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.socket.close(io);

    log.log(.info, "serve listening on 127.0.0.1:{d}", .{port});

    while (true) {
        const stream = server.accept(io) catch |err| {
            log.log(.error_, "accept error: {s}", .{@errorName(err)});
            continue;
        };
        handleConnection(io, gpa, &cfg, init.environ_map, port, stream);
    }
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
        if (std.mem.eql(u8, method, "GET") and (std.mem.eql(u8, target, "/") or std.mem.eql(u8, target, "/webui"))) {
            handleWebui(io, gpa, cfg, environ_map, stream);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, target, "/.well-known/agent.json")) {
            handleAgentCard(io, gpa, cfg, port, stream);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, target, "/api/status")) {
            handleStatus(io, gpa, cfg, stream);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, target, "/api/notify")) {
            handleNotify(io, gpa, body) catch {
                respond(stream, 500, "Internal Server Error", "{\"ok\":false}");
                return;
            };
            respond(stream, 200, "OK", "{\"ok\":true}");
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, target, "/api/a2a/message")) {
            handleA2AMessage(io, gpa, stream, body);
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

fn handleAgentCard(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, port: u16, stream: std.Io.net.Stream) void {
    _ = io;
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

fn handleA2AMessage(io: std.Io, gpa: std.mem.Allocator, stream: std.Io.net.Stream, body: []const u8) void {
    _ = io;
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
    s.objectField("result") catch return;
    s.beginObject() catch return;
    s.objectField("id") catch return;
    s.write(id) catch return;
    s.objectField("message") catch return;
    s.beginObject() catch return;
    s.objectField("role") catch return;
    s.write("user") catch return;
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

const RunRequestBody = struct {
    task: []const u8 = "",
};

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

/// Instance + configured peers, consumed by the web UI status panel.
fn handleStatus(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, stream: std.Io.net.Stream) void {
    _ = io;
    _ = gpa;
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

    var ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = environ_map };
    var provider = cfg.provider(null) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"no default provider\"}");
        return;
    };
    var provider_copy = provider.*;
    provider = &provider_copy;

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
    var messages: std.ArrayList(types.Message) = .empty;
    var err_detail: ?[]const u8 = null;
    const resp = a.run(&messages, req.task, &err_detail) catch |err| {
        const detail = err_detail orelse @errorName(err);
        var ebuf: [8192]u8 = undefined;
        const ebody = std.fmt.bufPrint(&ebuf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{detail}) catch {
            respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"run failed\"}");
            return;
        };
        respond(stream, 500, "Internal Server Error", ebody);
        return;
    };

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
    const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, reason, body.len }) catch return;
    writeAllFd(stream.socket.handle, hdr);
    writeAllFd(stream.socket.handle, body);
}

fn respondHtml(stream: std.Io.net.Stream, status: u16, reason: []const u8, body: []const u8) void {
    var hbuf: [4096]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 {d} {s}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, reason, body.len }) catch return;
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
