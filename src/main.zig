//! Entry point: process setup, config/dotenv bootstrap, then hand off to cli.run.

const std = @import("std");
const vaxis = @import("vaxis");
const cli = @import("cli.zig");
const log = @import("util/log.zig");
const dotenv = @import("util/dotenv.zig");
const autolearn = @import("agent/autolearn.zig");
const host = @import("sandbox/host.zig");
const vertex_token = @import("llm/vertex_token.zig");
const config = @import("config.zig");

// `clanker repl` (src/tui/repl_vaxis.zig) puts the terminal in raw mode with
// an alt-screen buffer. Without this, a panic there leaves the terminal
// broken (raw mode, alt-screen, mouse tracking all still on) with the panic
// message invisible inside the alt-screen that never gets popped, so the
// operator sees a hung, garbled terminal instead of the crash. This resets
// terminal state first, then falls through to the normal panic handler.
// (vaxis.Panic itself targets an older 3-arg std.builtin panic ABI than this
// Zig version's 2-arg one, so it can't be used directly here.)
pub const panic = std.debug.FullPanic(handlePanic);

fn handlePanic(msg: []const u8, ret_addr: ?usize) noreturn {
    vaxis.recover();
    std.debug.defaultPanic(msg, ret_addr);
}

// Zig 0.16 only runs test blocks in the root file; reference every module
// containing tests so `zig build test` picks them all up.
comptime {
    _ = @import("config.zig");
    _ = @import("llm/types.zig");
    _ = @import("llm/providers.zig");
    _ = @import("llm/providers/api.zig");
    _ = @import("llm/providers/common.zig");
    _ = @import("llm/providers/openai.zig");
    _ = @import("llm/providers/anthropic.zig");
    _ = @import("llm/providers/vertex.zig");
    _ = @import("llm/auth.zig");
    _ = @import("llm/client.zig");
    _ = @import("sandbox/protocol.zig");
    _ = @import("sandbox/host.zig");
    _ = @import("sandbox/runtime.zig");
    _ = @import("tools/registry.zig");
    _ = @import("tools/manifest.zig");
    _ = @import("tools/builder.zig");
    _ = @import("tools/usage.zig");
    _ = @import("agent/system_prompt.zig");
    _ = @import("agent/loop.zig");
    _ = @import("agent/session.zig");
    _ = @import("agent/graph.zig");
    _ = @import("agent/subagent.zig");
    _ = @import("util/dotenv.zig");
    _ = @import("util/atomic_write.zig");
    _ = @import("util/filelock.zig");
    _ = @import("util/diskcap.zig");
    _ = @import("util/json.zig");
    _ = @import("util/rawhttp.zig");
    _ = @import("util/runlock.zig");
    _ = @import("util/toml_bridge.zig");
    _ = @import("util/toolout.zig");
    _ = @import("agent/autolearn.zig");
    _ = @import("evals/scorers.zig");
    _ = @import("evals/runner.zig");
    _ = @import("improve/proposal.zig");
    _ = @import("improve/plan.zig");
    _ = @import("improve/history.zig");
    _ = @import("improve/reverts.zig");
    _ = @import("improve/inert.zig");
    _ = @import("improve/engine.zig");
    _ = @import("gate/checks.zig");
    _ = @import("mcp/server.zig");
    _ = @import("llm/gcp_jwt.zig");
    _ = @import("llm/vertex_token.zig");
    _ = @import("peers/chatrooms.zig");
    _ = @import("agent/private_todos.zig");
    _ = @import("stats/tokens.zig");
    _ = @import("tui/width.zig");
    _ = @import("tui/transcript.zig");
    _ = @import("tui/theme.zig");
    _ = @import("tui/syntax.zig");
    _ = @import("tui/stats.zig");
    _ = @import("tui/repl_vaxis.zig");
    _ = @import("cli.zig");
    _ = @import("doctor.zig");
    _ = @import("research/engine.zig");
    _ = @import("research/ledger.zig");
    _ = @import("research/harness.zig");
    _ = @import("research/autoresearch.zig");
    _ = @import("agent/workflows.zig");
    _ = @import("schedule/cron.zig");
    _ = @import("schedule/store.zig");
    _ = @import("schedule/runner.zig");
    _ = @import("schedule/command.zig");
}

/// Resolves the Zig standard library directory at startup (via `zig env`),
/// used by the std_api tool to look up symbol signatures.
fn resolveZigLibDir(io: std.Io, gpa: std.mem.Allocator) void {
    const argv = [_][]const u8{ "zig", "env" };
    const res = std.process.run(gpa, io, .{ .argv = &argv }) catch return;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    // zig env prints Zig struct syntax: .lib_dir = "/path/to/lib"
    var it = std.mem.splitScalar(u8, res.stdout, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.find(u8, trimmed, ".lib_dir =")) |idx| {
            const rest = trimmed[idx + ".lib_dir =".len ..];
            const after = std.mem.trimStart(u8, rest, " \t\"");
            var end: usize = after.len;
            if (std.mem.findScalar(u8, after, '"')) |q| end = q;
            const dir = after[0..end];
            if (dir.len > 0) host.zig_lib_dir = gpa.dupe(u8, dir) catch return;
            return;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    resolveZigLibDir(init.io, gpa);
    // Both live for the whole process, but freeing them keeps the debug
    // allocator's leak report meaningful: a real leak should not hide behind a
    // known one.
    defer if (host.zig_lib_dir.len > 0) gpa.free(host.zig_lib_dir);
    defer vertex_token.deinit(gpa);
    std.posix.setrlimit(.STACK, .{ .cur = std.math.maxInt(u64), .max = std.math.maxInt(u64) }) catch {};
    const arena = init.arena.allocator();

    var arg_list: std.ArrayList([]const u8) = .empty;
    defer arg_list.deinit(gpa);
    var args_it = init.minimal.args.iterate();
    while (args_it.next()) |arg| try arg_list.append(gpa, arg);

    var diag: []const u8 = "";
    const opts = cli.parse(arg_list.items, &diag) catch |err| {
        // Out of memory here is a system failure, not a malformed
        // invocation: exit 1 (general error), not 2 (usage error), so
        // scripts can tell "you typed it wrong" apart from "the machine
        // could not do it".
        if (err == error.OutOfMemory) {
            log.log(.error_, "out of memory", .{});
            std.process.exit(1);
        }
        switch (err) {
            error.MissingTask => cli.printUsageError(init.io, "`clanker run` needs a task: clanker run \"fix the build\" (or just clanker \"fix the build\")", .{}),
            error.UnknownCommand => if (cli.suggestCommand(diag)) |suggestion|
                cli.printUsageError(init.io, "unknown command '{s}'; did you mean `clanker {s}`?", .{ diag, suggestion })
            else
                cli.printUsageError(init.io, "unknown command '{s}' (see the command list below)", .{diag}),
            error.UnknownArg => cli.printUsageError(init.io, "unrecognized argument '{s}'", .{diag}),
            error.MissingArg => cli.printUsageError(init.io, "'{s}' needs a value", .{diag}),
            error.BadIters => cli.printUsageError(init.io, "--iters wants a non-negative integer, got '{s}'", .{diag}),
            error.BadBudget => cli.printUsageError(init.io, "--budget wants a non-negative integer, got '{s}'", .{diag}),
            error.BadRounds => cli.printUsageError(init.io, "--rounds wants a non-negative integer, got '{s}'", .{diag}),
            error.BadPort => cli.printUsageError(init.io, "--port wants a 16-bit port number, got '{s}'", .{diag}),
            error.BadDirection => cli.printUsageError(init.io, "--direction wants 'min' or 'max', got '{s}'", .{diag}),
            error.BadJudge => cli.printUsageError(init.io, "--judge wants 'self' or 'third', got '{s}'", .{diag}),
            error.ArenaMixedPositions => cli.printUsageError(init.io, "use --for/--against for a two-way match or repeated --position for a battle royale, not both", .{}),
            error.ArenaTooFewPositions => cli.printUsageError(init.io, "a battle royale needs at least 2 --position flags (3 to 8 is the interesting range)", .{}),
            error.CompareTooFewModels => cli.printUsageError(init.io, "a comparison needs at least 2 --with flags, or none at all to compare every configured provider", .{}),
            error.FlagNotForCommand => cli.printUsageError(init.io, "{s} is not an option for this command (see `clanker <command> --help`)", .{diag}),
            error.BadSubcommand => cli.printUsageError(init.io, "unrecognized subcommand '{s}' (see `clanker <command> --help`)", .{diag}),
            error.PromptLooksLikeCommand => cli.printUsageError(init.io, "'{s}' looks like a quoted command; drop the quotes to run it, or use `clanker run \"{s}\"` to submit it as a task", .{ diag, diag }),
            error.OutOfMemory => unreachable,
        }
        cli.printUsageHint(init.io);
        // Usage errors (bad/missing args) are the caller's fault, not
        // clanker's: exit nonzero so scripts and `&&` chains don't mistake a
        // rejected invocation for success.
        std.process.exit(2);
    };

    // CLANKER_LOG_LEVEL externalizes the log level for headless/service
    // deployments (systemd, docker) that cannot pass --verbose on the
    // invocation. --verbose still wins when both are given: it is the
    // explicit, in-the-moment ask.
    if (init.environ_map.get("CLANKER_LOG_LEVEL")) |lvl| {
        if (log.Level.fromStr(lvl)) |level|
            log.setLevel(level)
        else
            log.log(.warn, "CLANKER_LOG_LEVEL '{s}' is not one of debug|info|warn|error; ignoring", .{lvl});
    }
    if (opts.verbose) log.setLevel(.debug);

    // Load API keys and other secrets from $CLANKER_ENV_FILE or ./.env
    // (existing real env vars always win). Gated by the modules.dotenv flag,
    // and skipped for --help/--version: neither touches a provider or reads
    // a key, so there is no reason for either to read config.toml/.env off
    // disk or print the "loaded N key(s)" line ahead of its own output.
    if (opts.command != .help and opts.command != .version) {
        const early_cfg = config.Config.load(init.io, arena, std.Io.Dir.cwd(), "config.toml", "config.local.toml") catch null;
        if (early_cfg) |c| {
            if (c.modules.dotenv) dotenv.load(init.io, gpa, init.environ_map);
        } else {
            dotenv.load(init.io, gpa, init.environ_map); // no config: still try .env
        }
    }
    cli.run(init, opts) catch |err| {
        // Common failures get a human line with a recovery hint, not a
        // timestamped log record: this is an interactive moment, not a log
        // collector ingest path.
        const hint: ?[]const u8 = switch (err) {
            error.MissingConfig => "config.toml not found; run `clanker setup` to create one",
            error.DefaultProviderUnknown => "default_provider names a provider not in config; run `clanker doctor`",
            error.ToolWasmMissing => "a tool's .wasm module is missing; run `zig build tools`",
            error.ModuleDisabled => "this module is disabled in config.toml",
            else => null,
        };
        if (hint) |h| {
            cli.printUsageError(init.io, "{s}", .{h});
        } else {
            log.log(.error_, "{s}", .{@errorName(err)});
        }
        std.process.exit(1);
    };
}

