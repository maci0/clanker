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
    _ = @import("llm/client.zig");
    _ = @import("sandbox/protocol.zig");
    _ = @import("sandbox/host.zig");
    _ = @import("sandbox/runtime.zig");
    _ = @import("tools/registry.zig");
    _ = @import("tools/builder.zig");
    _ = @import("agent/system_prompt.zig");
    _ = @import("agent/loop.zig");
    _ = @import("agent/session.zig");
    _ = @import("agent/graph.zig");
    _ = @import("util/dotenv.zig");
    _ = @import("util/atomic_write.zig");
    _ = @import("util/filelock.zig");
    _ = @import("agent/autolearn.zig");
    _ = @import("memory/chunk.zig");
    _ = @import("memory/vector.zig");
    _ = @import("memory/embedder.zig");
    _ = @import("memory/hash_embed.zig");
    _ = @import("evals/scorers.zig");
    _ = @import("evals/runner.zig");
    _ = @import("improve/proposal.zig");
    _ = @import("improve/history.zig");
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
    _ = @import("tui/repl_vaxis.zig");
    _ = @import("cli.zig");
    _ = @import("doctor.zig");
    _ = @import("janitor.zig");
    _ = @import("research/engine.zig");
    _ = @import("research/ledger.zig");
    _ = @import("research/harness.zig");
    _ = @import("research/autoresearch.zig");
    _ = @import("workflows.zig");
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
        if (std.mem.indexOf(u8, trimmed, ".lib_dir =")) |idx| {
            const rest = trimmed[idx + ".lib_dir =".len ..];
            const after = std.mem.trimStart(u8, rest, " \t\"");
            var end: usize = after.len;
            if (std.mem.indexOfScalar(u8, after, '"')) |q| end = q;
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
            error.MissingTask => log.log(.error_, "`clanker run` needs a task text argument", .{}),
            error.UnknownCommand => log.log(.error_, "unknown command '{s}' (see the command list below)", .{diag}),
            error.UnknownArg => log.log(.error_, "unrecognized argument '{s}'", .{diag}),
            error.MissingArg => log.log(.error_, "'{s}' needs a value", .{diag}),
            error.BadIters => log.log(.error_, "--iters wants a non-negative integer, got '{s}'", .{diag}),
            error.BadPort => log.log(.error_, "--port wants a 16-bit port number, got '{s}'", .{diag}),
            error.BadDirection => log.log(.error_, "--direction wants 'min' or 'max', got '{s}'", .{diag}),
            error.FlagNotForCommand => log.log(.error_, "{s} is not an option for this command (see `clanker <command> --help`)", .{diag}),
            error.BadSubcommand => log.log(.error_, "unrecognized subcommand '{s}' (see `clanker <command> --help`)", .{diag}),
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
    // a key, so there is no reason for either to read config.json/.env off
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
        // A command failed after argument parsing succeeded: this is a
        // runtime/general error (exit 1), distinct from the usage errors
        // above (exit 2). Report it the same way every other clanker error
        // is reported (log.log(.error_, ...)) instead of letting it fall
        // through to Zig's default top-level handler, which would dump a
        // raw stack trace with source paths and memory addresses.
        log.log(.error_, "{s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

comptime {
    _ = @import("agent/graph.zig");
}
