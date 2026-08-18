//! Entry point: process setup, config/dotenv bootstrap, then hand off to cli.run.

const std = @import("std");
const vaxis = @import("vaxis");
const cli = @import("cli.zig");
const log = @import("util/log.zig");
const dotenv = @import("util/dotenv.zig");
const auto_learn = @import("agent/auto_learn.zig");
const subprocess = @import("agent/subprocess.zig");
const host = @import("sandbox/host.zig");
const vertex_token = @import("llm/vertex_token.zig");
const rate_limit = @import("llm/rate_limit.zig");
const config = @import("config.zig");

// `clanker repl` (src/tui/repl.zig) puts the terminal in raw mode with
// an alt-screen buffer. Without this, a panic there leaves the terminal
// broken (raw mode, alt-screen, mouse tracking all still on) with the panic
// message invisible inside the alt-screen that never gets popped, so the
// operator sees a hung, garbled terminal instead of the crash. This resets
// terminal state first, then falls through to the normal panic handler.
// (vaxis.Panic itself targets an older 3-arg std.builtin panic ABI than this
// Zig version's 2-arg one, so it can't be used directly here.)
pub const panic = std.debug.FullPanic(handlePanic);

/// One-shot claim on the terminal reset, so a panic raised *by the reset
/// itself* cannot recurse. `vaxis.recover()` writes to the tty, and on a
/// `std.Io` panic (a signal landing on a pool thread already inside a syscall
/// makes the nested `Io.Threaded.Syscall.start` hit `.blocked => unreachable`)
/// that write raises the very same panic from inside this handler. Unguarded
/// that recursed ~6900 times and overflowed the stack, printing 10001 frames
/// and never reaching `std.debug.defaultPanic` — whose own panic-during-panic
/// handling would have stopped it. See
/// docs/reports/investigations/2026-08-16-tui-resize-crash.md.
var recovery_claimed: std.atomic.Value(bool) = .init(false);

/// True for the first caller only. Kept separate from `handlePanic` because
/// `handlePanic` is `noreturn` and so cannot be called from a test.
fn claimTerminalRecovery() bool {
    return !recovery_claimed.swap(true, .seq_cst);
}

fn handlePanic(msg: []const u8, ret_addr: ?usize) noreturn {
    if (claimTerminalRecovery()) vaxis.recover();
    std.debug.defaultPanic(msg, ret_addr);
}

test "terminal recovery is claimed once, so a panic inside recover falls through" {
    defer recovery_claimed.store(false, .seq_cst);

    try std.testing.expect(claimTerminalRecovery());
    // A panic raised by `vaxis.recover()` re-enters `handlePanic`; every
    // re-entry must decline the reset and fall through to `defaultPanic`.
    try std.testing.expect(!claimTerminalRecovery());
    try std.testing.expect(!claimTerminalRecovery());
}

// clanker's own code logs through util/log.zig, but vendored dependencies
// (vaxis, its `.vaxis_parser` scope included) log through `std.log`, whose
// default handler writes raw multi-line text to stderr with no level control
// from us. During `clanker repl` that tears up the alt-screen: every
// unparsed key sequence painted a `warning(vaxis_parser)` line over the UI.
// Routing std.log into util/log.zig makes dependency logs honor the same
// runtime threshold (the repl raises it to `.error_` before the alt-screen
// exists) and the same one-physical-line format. `log_level = .debug`
// compiles every level in so the runtime threshold is the only filter.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = stdLogFn,
};

fn stdLogFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const mapped: log.Level = switch (level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .error_,
    };
    log.log(mapped, "({s}) " ++ fmt, .{@tagName(scope)} ++ args);
}

// Zig 0.16 only runs test blocks in the root file; reference every module
// containing tests so `zig build test` picks them all up.
comptime {
    _ = @import("hooks/config.zig");
    _ = @import("hooks/runner.zig");
    _ = @import("agent/loop_guard.zig");
    _ = @import("config.zig");
    _ = @import("llm/types.zig");
    _ = @import("llm/registry.zig");
    _ = @import("llm/catalog.zig");
    _ = @import("llm/models_dev.zig");
    _ = @import("llm/rate_limit.zig");
    _ = @import("llm/providers/api.zig");
    _ = @import("llm/providers/common.zig");
    _ = @import("llm/sampling_profiles.zig");
    _ = @import("llm/providers/openai.zig");
    _ = @import("llm/providers/anthropic.zig");
    _ = @import("llm/providers/vertex.zig");
    _ = @import("llm/providers/vertex_ai.zig");
    _ = @import("llm/providers/azure.zig");
    _ = @import("llm/providers/gemini.zig");
    _ = @import("llm/auth.zig");
    _ = @import("llm/client.zig");
    _ = @import("sandbox/protocol.zig");
    _ = @import("sandbox/host.zig");
    _ = @import("sandbox/runtime.zig");
    _ = @import("sandbox/python_wasi.zig");
    _ = @import("toolhost/registry.zig");
    _ = @import("toolhost/manifest.zig");
    _ = @import("toolhost/usage.zig");
    _ = @import("agent/system_prompt.zig");
    _ = @import("agent/loop.zig");
    _ = @import("agent/advisor.zig");
    _ = @import("agent/thinking.zig");
    _ = @import("agent/ttsr.zig");
    _ = @import("agent/subprocess.zig");
    _ = @import("sandbox/kernel.zig");
    _ = @import("debug/dap.zig");
    _ = @import("peers/mesh.zig");
    _ = @import("peers/command.zig");
    _ = @import("serve/live.zig");
    _ = @import("serve/mesh_net.zig");
    _ = @import("serve/webui_assets.zig");
    _ = @import("agent/session.zig");
    _ = @import("agent/workspace.zig");
    _ = @import("agent/prune.zig");
    _ = @import("agent/spill.zig");
    _ = @import("sandbox/jobs.zig");
    _ = @import("agent/graph.zig");
    _ = @import("agent/subagent.zig");
    _ = @import("util/dotenv.zig");
    _ = @import("util/log.zig");
    _ = @import("util/redact.zig");
    _ = @import("util/append_line.zig");
    _ = @import("util/atomic_write.zig");
    _ = @import("util/file_lock.zig");
    _ = @import("util/disk_cap.zig");
    _ = @import("util/edit_distance.zig");
    _ = @import("util/no_color.zig");
    _ = @import("util/ensure_dir.zig");
    _ = @import("util/json.zig");
    _ = @import("util/raw_http.zig");
    _ = @import("util/run_lock.zig");
    _ = @import("util/toml_bridge.zig");
    _ = @import("util/toml_edit.zig");
    _ = @import("util/tool_out.zig");
    _ = @import("util/glob.zig");
    _ = @import("util/utf8.zig");
    _ = @import("agent/auto_learn.zig");
    _ = @import("evals/scorers.zig");
    _ = @import("improve/proposal.zig");
    _ = @import("improve/plan.zig");
    _ = @import("improve/history.zig");
    _ = @import("improve/reverts.zig");
    _ = @import("improve/inert_check.zig");
    _ = @import("improve/engine.zig");
    _ = @import("improve/retire.zig");
    _ = @import("improve/worktree.zig");
    _ = @import("gate/checks.zig");
    _ = @import("mcp/server.zig");
    _ = @import("acp/server.zig");
    _ = @import("llm/gcp_jwt.zig");
    _ = @import("llm/vertex_token.zig");
    _ = @import("peers/chatrooms.zig");
    _ = @import("peers/notifications.zig");
    _ = @import("peers/phonebook.zig");
    _ = @import("agent/private_todos.zig");
    _ = @import("stats/tokens.zig");
    _ = @import("tui/width.zig");
    _ = @import("tui/sanitize.zig");
    _ = @import("tui/transcript.zig");
    _ = @import("tui/theme.zig");
    _ = @import("tui/syntax.zig");
    _ = @import("tui/turn_stats.zig");
    _ = @import("tui/mascot.zig");
    _ = @import("tui/clipboard.zig");
    _ = @import("tui/repl.zig");
    _ = @import("serve/proxy.zig");
    _ = @import("serve/proxy_transcode.zig");
    _ = @import("cli.zig");
    _ = @import("doctor.zig");
    _ = @import("autoresearch/harness.zig");
    _ = @import("autoresearch/loop.zig");
    _ = @import("agent/workflows.zig");
    _ = @import("agent/goal_prompt.zig");
    _ = @import("agent/goal_loop.zig");
    _ = @import("schedule/store.zig");
    _ = @import("schedule/runner.zig");
    _ = @import("schedule/command.zig");
    _ = @import("preset/preset.zig");
    _ = @import("records/common.zig");
    _ = @import("records/reports.zig");
    _ = @import("records/research.zig");
    _ = @import("records/rfc.zig");
    _ = @import("records/adr.zig");
    _ = @import("records/prd.zig");
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    // The Zig lib dir is resolved on first use (`host.zigLibDir`), not here:
    // it costs a fork+exec of the compiler and only `zig_std` and the improve
    // engine's std-symbol help ever read it.
    //
    // These live for the whole process, but freeing them keeps the debug
    // allocator's leak report meaningful: a real leak should not hide behind a
    // known one.
    defer subprocess.deinitProcessRegistry();
    defer vertex_token.deinit(init.io, gpa);
    defer rate_limit.deinit(init.io, gpa);
    std.posix.setrlimit(.STACK, .{ .cur = std.math.maxInt(u64), .max = std.math.maxInt(u64) }) catch {};
    const arena = init.arena.allocator();

    var arg_list: std.ArrayList([]const u8) = .empty;
    defer arg_list.deinit(gpa);
    var args_it = init.minimal.args.iterate();
    while (args_it.next()) |arg| try arg_list.append(gpa, arg);

    var diag: []const u8 = "";
    var cmd_out: cli.Command = .help;
    const opts = cli.parseWithCommand(arg_list.items, &diag, &cmd_out) catch |err| {
        // Out of memory here is a system failure, not a malformed
        // invocation: exit 1 (general error), not 2 (usage error), so
        // scripts can tell "you typed it wrong" apart from "the machine
        // could not do it".
        if (err == error.OutOfMemory) {
            log.log(.error_, "out of memory", .{});
            std.process.exit(1);
        }
        // The rejected argument is quoted back in most of these, and it is
        // whatever the caller typed: a mistyped flag, or a whole task prompt
        // the shell split on a stray quote. Elide it once here so no arm has
        // to think about length. `diag` itself stays intact for the
        // comparisons and the suggestion lookups below, which key off the
        // real spelling.
        var shown_buf: [128]u8 = undefined;
        const shown = cli.elideArg(&shown_buf, diag);
        switch (err) {
            error.MissingTask => cli.printUsageError(init.io, "`clanker run` needs a task: clanker run \"fix the build\" (or just clanker \"fix the build\")", .{}),
            error.ExtraTask => cli.printUsageError(init.io, "`clanker run` takes one task but got a second argument: '{s}'. If that is part of the same task, the shell split it: a `\"` inside the task ends the quoted string, so quote the whole task and escape any inner ones as \\\"", .{shown}),
            error.UnknownCommand => if (cli.suggestCommand(diag)) |suggestion|
                cli.printUsageError(init.io, "unknown command '{s}'; did you mean `clanker {s}`?", .{ shown, suggestion })
            else
                // No "(see the list below)": no list follows, only the
                // printUsageHint line naming `clanker --help`.
                cli.printUsageError(init.io, "unknown command '{s}'", .{shown}),
            error.UnknownArg => if (cli.suggestFlag(diag)) |suggestion|
                cli.printUsageError(init.io, "unrecognized argument '{s}'; did you mean `{s}`?", .{ shown, suggestion })
            else
                cli.printUsageError(init.io, "unrecognized argument '{s}'", .{shown}),
            error.MissingArg => if (std.mem.eql(u8, diag, "export"))
                cli.printUsageError(init.io, "clanker session needs `export <id>`; to list conversations run `clanker sessions`", .{})
            else if (std.mem.eql(u8, diag, "conversation id"))
                cli.printUsageError(init.io, "clanker session export needs a conversation id; run `clanker sessions` for the list", .{})
            else if (std.mem.eql(u8, diag, "improvement id"))
                cli.printUsageError(init.io, "clanker revert needs an improvement id", .{})
            else if (std.mem.eql(u8, diag, "<intent>"))
                cli.printUsageError(init.io, "`clanker goal` needs an intent: clanker goal \"improve the REPL\"", .{})
            else if (std.mem.eql(u8, diag, "<write-goal intent>"))
                cli.printUsageError(init.io, "`clanker write-goal` needs an intent: clanker write-goal \"improve the REPL\"", .{})
            else if (std.mem.eql(u8, diag, "<instructions>"))
                cli.printUsageError(init.io, "`clanker improve-self` needs instructions", .{})
            else if (std.mem.eql(u8, diag, "<peer>"))
                cli.printUsageError(init.io, "`clanker notify` needs a peer name", .{})
            else if (std.mem.eql(u8, diag, "<host:port>"))
                cli.printUsageError(init.io, "`clanker mesh join` needs a host:port: clanker mesh join 127.0.0.1:7420", .{})
            else if (std.mem.eql(u8, diag, "<peer-id>"))
                cli.printUsageError(init.io, "`clanker mesh admit`/`deny` needs a peer id", .{})
            else if (std.mem.eql(u8, diag, "<message>"))
                cli.printUsageError(init.io, "`clanker notify` needs a message", .{})
            else if (std.mem.eql(u8, diag, "<question>"))
                cli.printUsageError(init.io, "`clanker arena` needs a question", .{})
            else
                cli.printUsageError(init.io, "'{s}' needs a value", .{shown}),
            error.BadIters => cli.printUsageError(init.io, "--iters wants a non-negative integer, got '{s}'", .{shown}),
            error.BadReasoningEffort => cli.printUsageError(init.io, "--reasoning-effort wants none, low, medium, high, or max, got '{s}'", .{shown}),
            error.BadBudget => cli.printUsageError(init.io, "--budget wants a non-negative integer, got '{s}'", .{shown}),
            error.BadRounds => cli.printUsageError(init.io, "--rounds wants a non-negative integer, got '{s}'", .{shown}),
            error.BadPort => cli.printUsageError(init.io, "--webui-port wants a 16-bit port number, got '{s}'", .{shown}),
            error.BadDirection => cli.printUsageError(init.io, "--direction wants 'min' or 'max', got '{s}'", .{shown}),
            error.BadJudge => cli.printUsageError(init.io, "--judge wants 'self' or 'third', got '{s}'", .{shown}),
            error.BadSessionId => cli.printUsageError(init.io, "invalid session id '{s}'; use 1-64 letters, numbers, dashes, or underscores", .{shown}),
            error.ArenaMixedPositions => cli.printUsageError(init.io, "use --for/--against for a two-way match or repeated --position for a battle royale, not both", .{}),
            error.ArenaTooFewPositions => cli.printUsageError(init.io, "a battle royale needs at least 2 --position flags (3 to 8 is the interesting range)", .{}),
            error.CompareTooFewModels => cli.printUsageError(init.io, "a comparison needs at least 2 --with flags, or none at all to compare every configured provider", .{}),
            error.FlagNotForCommand => cli.printUsageError(init.io, "{s} is not an option for this command; run `clanker {s} --help`", .{ diag, cli.commandName(cmd_out) }),
            error.BadSubcommand => cli.printUsageError(init.io, "unrecognized subcommand '{s}'; run `clanker {s} --help`", .{ shown, cli.commandName(cmd_out) }),
            error.PromptLooksLikeCommand => cli.printUsageError(init.io, "'{s}' looks like a quoted command; drop the quotes to run it, or use `clanker run \"{s}\"` to submit it as a task", .{ shown, shown }),
            error.OutOfMemory => unreachable,
        }
        // These messages already name the next keystroke or the command's
        // own help. Repeating `clanker --help` after them restates the list.
        const skip_hint = switch (err) {
            error.MissingTask, error.ExtraTask, error.MissingArg, error.BadSessionId, error.FlagNotForCommand, error.BadSubcommand, error.PromptLooksLikeCommand => true,
            error.UnknownCommand => cli.suggestCommand(diag) != null,
            error.UnknownArg => cli.suggestFlag(diag) != null,
            else => false,
        };
        if (!skip_hint) {
            if (err == error.UnknownCommand or arg_list.items.len < 2) {
                cli.printUsageHint(init.io);
            } else {
                cli.printUsageHintFor(init.io, arg_list.items[1]);
            }
        }
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
    if (opts.profile) |p| log.log(.info, "profile '{s}' requested via --profile (overlay between local and env)", .{p});
    if (opts.dump_config) {
        const merged: ?config.Config = if (opts.profile) |p| blk: {
            break :blk config.Config.loadWithProfile(init.io, arena, std.Io.Dir.cwd(), "config.toml", "config.local.toml", p) catch null;
        } else config.Config.load(init.io, arena, std.Io.Dir.cwd(), "config.toml", "config.local.toml") catch null;
        if (merged) |c| {
            var buf: [65536]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            w.print("{any}\n", .{c}) catch |err| log.log(.warn, "config dump truncated ({s}); output is incomplete", .{@errorName(err)});
            cli.writeStdOut(init.io, w.buffered()) catch {};
        } else {
            cli.printUsageError(init.io, "could not load configuration; check config.toml syntax or run `clanker setup` to create one", .{});
            std.process.exit(1);
        }
        std.process.exit(0);
    }
    // Order is the precedence: `--quiet` overrides CLANKER_LOG_LEVEL above,
    // and `--verbose` overrides both. Two flags on one invocation asking for
    // opposite things resolves toward more output rather than refusing.
    if (opts.quiet) log.setLevel(.error_);
    if (opts.verbose) log.setLevel(.debug);

    // Load API keys and other secrets from $CLANKER_ENV_FILE or ./.env
    // (existing real env vars always win). Gated by the modules.dotenv flag,
    // and skipped for --help/--version: neither touches a provider or reads
    // a key, so there is no reason for either to read config.toml/.env off
    // disk or print the "loaded N key(s)" line ahead of its own output.
    if (opts.command != .help and opts.command != .version) {
        const early_cfg = config.Config.loadQuiet(init.io, arena, std.Io.Dir.cwd(), "config.toml", "config.local.toml") catch null;
        if (early_cfg) |c| {
            if (c.modules.dotenv) dotenv.load(init.io, gpa, init.environ_map);
        } else {
            dotenv.load(init.io, gpa, init.environ_map); // no config: still try .env
        }
    }
    cli.run(init, opts) catch |err| {
        // A downstream reader such as `head` closing early is successful
        // pipeline control, not an operator-facing clanker failure. Every
        // list/table command writes through this boundary, so handle it once.
        if (err == error.BrokenPipe) std.process.exit(0);
        // Common failures get a human line with a recovery hint, not a
        // timestamped log record: this is an interactive moment, not a log
        // collector ingest path.
        const hint: ?[]const u8 = if (config.Config.takeLoadDiagnostic())
            "configuration is invalid; correct the setting reported above"
        else switch (err) {
            error.MissingConfig => "config.toml not found; run `clanker setup` to create one",
            error.DefaultProviderUnknown => "default_provider names a provider not in config; run `clanker doctor`",
            error.ToolWasmMissing => "a tool's .wasm module is missing; run `zig build tools`",
            error.ModuleDisabled => "this module is disabled in config.toml",
            error.UnknownProvider => "no provider by that name in config.toml; run `clanker providers check` for the list",
            error.ProviderCheckFailed => "provider check failed; run `clanker doctor` to diagnose",
            error.InvalidSessionId => "invalid session id; use 1-64 letters, numbers, dashes, or underscores",
            error.TerminalSizeUnavailable => "terminal size is unavailable; resize the terminal and try again",
            error.SessionNotFound => "no saved conversation by that id; run `clanker sessions` for the list",
            error.GoalNotFound => "the requested saved goal does not exist; add it with `clanker add-goal` or choose an id from the goal board",
            error.ImprovementNotFound => "no improvement by that id; they look like imp-... in state/improvements.jsonl",
            error.ToolFailed => "the internal tool returned an error; run `clanker doctor` to check the build",
            error.ToolBadOutput => "the internal tool returned unreadable output; run `clanker doctor` to check the build",
            error.GateFailed => "one or more gates failed (see output above)",
            error.EvalsFailed => "one or more evals failed (see output above)",
            error.UnknownEval => "no eval by that name; run `clanker eval` with no argument to list them",
            error.PresetsDirUnusable => "presets/ could not be created or opened; check permissions in the working directory",
            error.HttpError => "the HTTP request failed; check the provider's status and your network",
            error.ArenaRefused => "the arena match was refused (see output above)",
            error.CompareRefused => "the comparison was refused (see output above)",
            else => null,
        };
        if (hint) |h| {
            cli.printUsageError(init.io, "{s}", .{h});
        } else {
            cli.printUsageError(init.io, "{s}", .{@errorName(err)});
        }
        std.process.exit(1);
    };
}
