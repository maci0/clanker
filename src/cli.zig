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
const rawhttp = @import("util/rawhttp.zig");
// tui/transcript.zig's MdStream is still used by cmdRun's own run_md; the
// rest of tui/* (input, region, statusbar, palette, approval, term) was
// exclusive to the REPL that's now src/tui/repl_vaxis.zig, and was
// removed with it.
const tui_transcript = @import("tui/transcript.zig");
const repl_vaxis = @import("tui/repl_vaxis.zig");
const chatrooms = @import("peers/chatrooms.zig");
const phonebook = @import("peers/phonebook.zig");
const doctor_mod = @import("doctor.zig");
const janitor_mod = @import("janitor.zig");
const token_stats = @import("stats/tokens.zig");
const log = @import("util/log.zig");
const atomic_write = @import("util/atomic_write.zig");
const diskcap = @import("util/diskcap.zig");
const runlock = @import("util/runlock.zig");
const filelock = @import("util/filelock.zig");
const gate_checks = @import("gate/checks.zig");

// Web UI vendor assets: served as plain static files (not routed through the
// WASM "webui" tool — its shared output buffer, lib.zig's out_cap, is 64 KiB,
// far smaller than these). Vendored rather than CDN-loaded so the page has
// zero runtime network dependencies and needs no change to the webui CSP.
const webui_vendor_van = @embedFile("webui_vendor/van.js");
const webui_vendor_vanui = @embedFile("webui_vendor/van-ui.js");
const webui_vendor_d3dag = @embedFile("webui_vendor/d3-dag.min.js");
const webui_vendor_hljs = @embedFile("webui_vendor/hljs.min.js");

/// Sourced from build.zig.zon's `.version` field via the `build_options`
/// module (see build.zig), so the two can no longer drift apart.
pub const version = @import("build_options").version;

pub const Command = enum {
    help,
    version,
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
    /// The libvaxis-backed REPL (docs/ROADMAP.md migration). `src/tui/repl_vaxis.zig`.
    repl,
    graph,
    gate,
    autolearn,
    doctor,
    setup,
    prune,
};

pub const Options = struct {
    /// No command given means the interactive REPL: a bare `clanker` should
    /// drop the user into a session, the way every other coding agent does,
    /// not print usage at them.
    command: Command = .repl,
    /// Sub-command for `providers`: "check" (default), "models", "catalog" or
    /// "fill". `provider` doubles as the catalog search query for "catalog"
    /// and the provider name for "fill".
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
    /// `prune --yes`: actually delete. Absent, it only reports, because a
    /// recursive delete is not undoable.
    apply: bool = false,
    verbose: bool = false,
    port: u16 = 17921,
    /// Set when `--help` followed a command: print that command's help rather
    /// than the whole list.
    help_for: ?Command = null,
    /// `--continue`/`-c`: pick up the most recently updated session instead of
    /// naming it with `--session`. Every other agent CLI has this; reaching for
    /// `clanker sessions`, reading an id and pasting it back is the workaround
    /// it replaces.
    continue_last: bool = false,
};

/// Optional out-param for `parse`: on a parse error, holds the offending
/// token/flag/value so the caller can report *what* was wrong, not just the
/// bare error name (e.g. "unknown command: 'relp'" instead of "UnknownCommand").
fn setDiag(diag: ?*[]const u8, token: []const u8) void {
    if (diag) |d| d.* = token;
}

/// The value belonging to `flag`, taken from `--flag=value` when that is how it
/// was written and from the next argument otherwise.
fn takeValue(
    args: []const []const u8,
    idx: *usize,
    inline_value: ?[]const u8,
    flag: []const u8,
    diag: ?*[]const u8,
) ![]const u8 {
    if (inline_value) |v| {
        if (v.len == 0) {
            setDiag(diag, flag);
            return error.MissingArg;
        }
        return v;
    }
    idx.* += 1;
    if (idx.* >= args.len) {
        setDiag(diag, flag);
        return error.MissingArg;
    }
    return args[idx.*];
}

pub fn parse(args: []const []const u8, diag: ?*[]const u8) !Options {
    var opts = Options{};
    var idx: usize = 1;
    var cmd_seen = false;
    var pending_sub: ?[]const u8 = null;
    var seen_flags: [8]Flag = undefined;
    var seen_flags_len: usize = 0;

    // `--flag=value` is written as often as `--flag value`; the parser only
    // understood the second. Split here so every flag below sees the value the
    // same way, whichever form was typed.
    var split_buf: [2][]const u8 = undefined;
    var inline_value: ?[]const u8 = null;

    while (idx < args.len) : (idx += 1) {
        var a = args[idx];
        if (inline_value == null and a.len > 2 and a[0] == '-' and a[1] == '-') {
            if (std.mem.indexOfScalar(u8, a, '=')) |eq| {
                split_buf[0] = a[0..eq];
                split_buf[1] = a[eq + 1 ..];
                a = split_buf[0];
                inline_value = split_buf[1];
            }
        }
        defer inline_value = null;

        // Once git is the active command, every remaining token — including
        // dash-prefixed ones like git's own flags/options — passes through to
        // git verbatim, so `clanker git status --porcelain` keeps its args.
        // cmdGit re-reads the raw argv itself; recording the token here only
        // absorbs it so it never reaches the flag parser below (no alloc).
        if (opts.command == .git) {
            opts.task = a;
            continue;
        }

        // Help/version flags act as their own command regardless of position.
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            // After a command, --help asks about that command rather than
            // being an unrecognized argument, which is the least useful thing
            // a --help can do.
            if (cmd_seen) opts.help_for = opts.command;
            opts.command = .help;
            cmd_seen = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--version")) {
            if (cmd_seen) {
                setDiag(diag, a);
                return error.UnknownArg;
            }
            opts.command = .version;
            cmd_seen = true;
            continue;
        }

        // Flags may appear before or after the command; which command they
        // are legal for is checked once the command is known.
        if (a.len > 0 and a[0] == '-') {
            var used: ?Flag = null;
            if (std.mem.eql(u8, a, "--verbose") or std.mem.eql(u8, a, "-v")) {
                opts.verbose = true;
            } else if (std.mem.eql(u8, a, "--dry-run")) {
                opts.dry_run = true;
                used = .dry_run;
            } else if (std.mem.eql(u8, a, "--yes")) {
                opts.apply = true;
                used = .yes;
            } else if (std.mem.eql(u8, a, "--tasks")) {
                opts.eval_tasks_only = true;
                used = .tasks;
            } else if (std.mem.eql(u8, a, "--provider")) {
                opts.provider = try takeValue(args, &idx, inline_value, a, diag);
                used = .provider;
            } else if (std.mem.eql(u8, a, "--continue") or std.mem.eql(u8, a, "-c")) {
                opts.continue_last = true;
                used = .session;
            } else if (std.mem.eql(u8, a, "--model") or std.mem.eql(u8, a, "-m")) {
                opts.model = try takeValue(args, &idx, inline_value, a, diag);
                used = .model;
            } else if (std.mem.eql(u8, a, "--session")) {
                opts.session = try takeValue(args, &idx, inline_value, a, diag);
                used = .session;
            } else if (std.mem.eql(u8, a, "--goal")) {
                opts.goal = try takeValue(args, &idx, inline_value, a, diag);
                used = .goal;
            } else if (std.mem.eql(u8, a, "--iters")) {
                const v = try takeValue(args, &idx, inline_value, a, diag);
                opts.iters = std.fmt.parseInt(u32, v, 10) catch {
                    setDiag(diag, v);
                    return error.BadIters;
                };
                used = .iters;
            } else if (std.mem.eql(u8, a, "--port")) {
                const v = try takeValue(args, &idx, inline_value, a, diag);
                opts.port = std.fmt.parseInt(u16, v, 10) catch {
                    setDiag(diag, v);
                    return error.BadPort;
                };
                used = .port;
            } else {
                setDiag(diag, a);
                return error.UnknownArg;
            }
            if (used) |f| {
                if (seen_flags_len < seen_flags.len) {
                    seen_flags[seen_flags_len] = f;
                    seen_flags_len += 1;
                }
            }
            continue;
        }

        // Non-flag token. The first one names the command; with no command
        // at all the default (the REPL) stands.
        if (!cmd_seen) {
            cmd_seen = true;
            if (std.mem.eql(u8, a, "init")) {
                opts.command = .init;
            } else if (std.mem.eql(u8, a, "doctor")) {
                opts.command = .doctor;
            } else if (std.mem.eql(u8, a, "janitor") or std.mem.eql(u8, a, "prune")) {
                opts.command = .prune;
            } else if (std.mem.eql(u8, a, "setup")) {
                opts.command = .setup;
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
            } else if (std.mem.eql(u8, a, "repl-vaxis")) {
                // Compatibility alias from when the vaxis REPL was a
                // separate opt-in command; now `repl` itself.
                opts.command = .repl;
            } else if (std.mem.eql(u8, a, "gate")) {
                opts.command = .gate;
            } else if (a.len > 0 and !std.mem.eql(u8, a, "help")) {
                // Not a command: treat it as the task, the way every other
                // agent CLI takes a bare prompt (`clanker "fix the bug"`).
                // Only when it cannot be a command name, so a typo'd command
                // is still reported rather than silently run as a prompt.
                if (std.mem.indexOfScalar(u8, a, ' ') == null and a.len < 24) {
                    setDiag(diag, a);
                    return error.UnknownCommand;
                }
                opts.command = .run;
                opts.task = a;
            } else {
                setDiag(diag, a);
                return error.UnknownCommand;
            }
        } else if (pending_sub) |sub| {
            if (std.mem.eql(u8, a, sub)) {
                pending_sub = null;
            } else if (opts.command == .providers_check and sub.len == 0 and (std.mem.eql(u8, a, "check") or std.mem.eql(u8, a, "models") or std.mem.eql(u8, a, "catalog") or std.mem.eql(u8, a, "fill"))) {
                opts.providers_sub = a;
                pending_sub = null; // sub consumed; next token is the provider name
            } else if (opts.command == .chat and sub.len == 0 and (std.mem.eql(u8, a, "send") or std.mem.eql(u8, a, "history") or std.mem.eql(u8, a, "rooms") or std.mem.eql(u8, a, "subscribe"))) {
                opts.chat_sub = a;
                pending_sub = null; // sub consumed; next tokens are room etc.
            } else {
                setDiag(diag, a);
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
            setDiag(diag, a);
            return error.UnknownArg;
        }
    }

    // `clanker chat --help` asks what the subcommands are, so a missing
    // subcommand is the question rather than the error.
    if (pending_sub != null and opts.command != .help) {
        setDiag(diag, "<subcommand>");
        return error.BadSubcommand;
    }
    // A flag the chosen command does not take is refused rather than ignored.
    // `clanker stats --model x` used to exit 0 having done nothing with it,
    // which reads as "the model was honoured" to whoever typed it.
    if (opts.command != .help and opts.command != .version and opts.command != .git) {
        for (seen_flags[0..seen_flags_len]) |f| {
            if (!commandAccepts(opts.command, f)) {
                setDiag(diag, f.name());
                return error.FlagNotForCommand;
            }
        }
    }

    if (opts.command == .run and opts.task == null) return error.MissingTask;
    if (opts.command == .notify and opts.peer == null) {
        setDiag(diag, "<peer>");
        return error.MissingArg;
    }
    if (opts.command == .notify and opts.message == null) {
        setDiag(diag, "<message>");
        return error.MissingArg;
    }
    if (opts.command == .chat) {
        const needs_room = !std.mem.eql(u8, opts.chat_sub, "rooms");
        if (needs_room and opts.room == null) {
            setDiag(diag, "<room>");
            return error.MissingArg;
        }
        if (std.mem.eql(u8, opts.chat_sub, "send") and opts.message == null) {
            setDiag(diag, "<message>");
            return error.MissingArg;
        }
    }
    return opts;
}

/// The whole command list, grouped. Rendered from `specs` so a new command
/// cannot be added without appearing here.
pub fn printUsage(io: std.Io) void {
    var buf: [8192]u8 = undefined;
    writeStdErr(io, renderUsage(&buf)) catch {};
}

fn renderUsage(buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("clanker - self-improving AI agent harness\n\nusage: clanker [command] [options]\n       clanker            with no command, starts the REPL\n") catch {};
    for (std.enums.values(Group)) |g| {
        w.print("\n{s}\n", .{g.title()}) catch {};
        for (&specs) |*s| {
            if (s.group != g) continue;
            // A usage string that fills or overruns the 34-wide column would
            // otherwise butt straight into the blurb with no separating
            // space (e.g. "...fill] [name]verify connectivity..."); wrap the
            // blurb onto its own aligned line instead.
            if (s.usage.len >= 32) {
                w.print("  {s}\n  {s: <34}{s}\n", .{ s.usage, "", s.blurb }) catch {};
            } else {
                w.print("  {s: <34}{s}\n", .{ s.usage, s.blurb }) catch {};
            }
        }
    }
    w.writeAll("\nEverywhere\n  --verbose, -v                     log what it is doing\n  --help, -h                        this text, or a command's own help\n  --version                         print the version\n\nclanker <command> --help for a command's options.\n") catch {};
    return buf[0..w.end];
}

/// `clanker <command> --help`: what that one command takes, rather than the
/// whole list. Previously this errored with "unrecognized argument '--help'",
/// which is the least helpful thing a --help can do.
fn printCommandHelp(io: std.Io, cmd: Command) void {
    const s = specFor(cmd) orelse return printUsage(io);
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("usage: clanker {s}\n\n{s}\n", .{ s.usage, s.blurb }) catch {};
    if (s.detail.len > 0) w.print("\n{s}\n", .{s.detail}) catch {};
    if (s.flags.len > 0) {
        w.writeAll("\noptions:\n") catch {};
        for (s.flags) |f| {
            w.print("  {s}\n", .{f.name()}) catch {};
        }
    }
    w.writeAll("\nAlso: --verbose, --help, --version.\n") catch {};
    writeStdOut(io, buf[0..w.end]) catch {};
}

/// Every flag the parser knows. A command declares the ones it accepts, so
/// `clanker stats --model x` is refused instead of silently ignored: a flag
/// that does nothing is worse than one that is rejected, because the user
/// believes it took effect.
const Flag = enum {
    provider,
    model,
    session,
    goal,
    iters,
    dry_run,
    tasks,
    port,
    yes,

    fn name(self: Flag) []const u8 {
        return switch (self) {
            .provider => "--provider",
            .model => "--model",
            .session => "--session",
            .goal => "--goal",
            .iters => "--iters",
            .dry_run => "--dry-run",
            .tasks => "--tasks",
            .port => "--port",
            .yes => "--yes",
        };
    }
};

/// Which section of `--help` a command is listed under. A flat list of 22
/// commands makes the reader scan all of them to find the one they want.
const Group = enum {
    work,
    inspect,
    peers,
    maintain,

    fn title(self: Group) []const u8 {
        return switch (self) {
            .work => "Working with the agent",
            .inspect => "Looking at what happened",
            .peers => "Talking to other instances",
            .maintain => "Setting up and maintaining",
        };
    }
};

const Spec = struct {
    command: Command,
    /// How it is typed, including positional arguments.
    usage: []const u8,
    blurb: []const u8,
    group: Group,
    flags: []const Flag = &.{},
    /// Longer help shown by `clanker <command> --help`, when the blurb alone
    /// leaves a real question unanswered.
    detail: []const u8 = "",
};

/// `--verbose`/`-v`, `--help`/`-h` and `--version` are accepted everywhere and
/// so are not listed per command.
const specs = [_]Spec{
    .{ .command = .run, .usage = "run \"<task>\"", .blurb = "run the agent on one task", .group = .work, .flags = &.{ .provider, .model, .session, .goal }, .detail = "A bare prompt works too: clanker \"fix the failing eval\".\n\n--session <id>   continue that saved conversation\n--continue, -c   continue the most recently touched one\n--goal <id>      run against a persisted goal\n--model, -m      <model>, or <provider>/<model> (--model zai/glm-5.2)" },
    .{ .command = .repl, .usage = "repl", .blurb = "interactive multi-turn chat, streaming", .group = .work, .flags = &.{ .provider, .model, .session }, .detail = "--continue, -c picks up the most recently touched session." },
    .{ .command = .goal, .usage = "goal \"<intent>\"", .blurb = "design and persist a structured goal", .group = .work, .flags = &.{ .provider, .model } },
    .{ .command = .improve_self, .usage = "improve-self \"<instructions>\"", .blurb = "self-improvement loop over this codebase", .group = .work, .flags = &.{ .provider, .model, .iters, .dry_run }, .detail = "--dry-run proposes patches without applying them; --iters caps the attempts (default 3)." },
    .{ .command = .serve, .usage = "serve", .blurb = "HTTP API + web UI", .group = .work, .flags = &.{.port}, .detail = "Binds 127.0.0.1 only. Default port 17921." },
    .{ .command = .mcp, .usage = "mcp", .blurb = "serve tools over MCP (stdio)", .group = .work },

    .{ .command = .sessions, .usage = "sessions", .blurb = "list saved conversations", .group = .inspect },
    .{ .command = .graph, .usage = "graph [run-id]", .blurb = "list runs, or draw one as a timeline", .group = .inspect },
    .{ .command = .stats, .usage = "stats", .blurb = "token usage per provider and model", .group = .inspect },
    .{ .command = .tools_list, .usage = "tools list", .blurb = "list the registered WASM tools", .group = .inspect },
    .{ .command = .providers_check, .usage = "providers <check|models|catalog|fill> [name]", .blurb = "verify connectivity, list models, or query the models.dev catalog", .group = .inspect, .detail = "check [name]    ping each provider (or one) and report latency/cost\nmodels [name]   list a provider's models (openrouter pulls its own DB)\ncatalog <query> search the public models.dev directory by id/family\nfill <name>     print models.dev specs for a configured provider's models" },

    .{ .command = .chat, .usage = "chat <subcommand> ...", .blurb = "chatrooms shared with other instances", .group = .peers, .detail = "chat send <room> \"<text>\"\nchat history <room> [after-ts]\nchat rooms\nchat subscribe <room> [on|off]" },
    .{ .command = .notify, .usage = "notify <peer> \"<message>\"", .blurb = "send a notification to a peer", .group = .peers },
    .{ .command = .phonebook, .usage = "phonebook", .blurb = "list peer agent cards", .group = .peers },

    .{ .command = .setup, .usage = "setup", .blurb = "guided first run: check config, keys and tools", .group = .maintain, .detail = "Scaffolds what is missing, says which provider this environment can actually reach,\nand finishes with the same checks `clanker doctor` runs." },
    .{ .command = .prune, .usage = "janitor [--yes]", .blurb = "sweep up what old runs left behind", .group = .maintain, .flags = &.{.yes}, .detail = "Also reachable as `clanker prune`.\n\nReports by default and deletes nothing. --yes removes: staging copies left by\nimprove runs that were killed, run graphs beyond the newest 200, and improve logs\nbeyond the newest 20. Sessions, goals, learnings and chat history are never touched." },
    .{ .command = .doctor, .usage = "doctor", .blurb = "diagnose config, credentials and build outputs", .group = .maintain, .detail = "Read-only and offline. Exits non-zero when something is broken, so it can guard a\nscript or a CI step. Connectivity is `clanker providers check`." },
    .{ .command = .init, .usage = "init", .blurb = "create config.local.json and state/", .group = .maintain },
    .{ .command = .gate, .usage = "gate", .blurb = "run the build/test/tools/fmt/lint gates", .group = .maintain },
    .{ .command = .eval, .usage = "eval [name]", .blurb = "run evals: all, or one by name", .group = .maintain, .flags = &.{.tasks}, .detail = "--tasks runs only the agent-driven evals, skipping the selfhost build gates." },
    .{ .command = .revert, .usage = "revert <id>", .blurb = "undo a previously applied improvement", .group = .maintain },
    .{ .command = .autolearn, .usage = "autolearn", .blurb = "fold recent runs into learnings", .group = .maintain },
    .{ .command = .git, .usage = "git <args...>", .blurb = "passthrough to git in the repo root", .group = .maintain },
};

fn specFor(cmd: Command) ?*const Spec {
    for (&specs) |*s| {
        if (s.command == cmd) return s;
    }
    return null;
}

fn commandAccepts(cmd: Command, flag: Flag) bool {
    const s = specFor(cmd) orelse return false;
    for (s.flags) |f| {
        if (f == flag) return true;
    }
    return false;
}

pub fn run(init: std.process.Init, opts: Options) !void {
    switch (opts.command) {
        // Requested output (--help, --version), not an error: stdout, exit 0.
        .help => {
            if (opts.help_for) |c| {
                printCommandHelp(init.io, c);
            } else {
                var buf: [8192]u8 = undefined;
                try writeStdOut(init.io, renderUsage(&buf));
            }
        },
        .version => try writeStdOut(init.io, "clanker " ++ version ++ "\n"),
        .init => try cmdInit(init, true),
        .doctor => try doctor_mod.cmdDoctor(init),
        .prune => try janitor_mod.cmdPrune(init, opts.apply),
        .setup => {
            // Scaffolding first: setup is the one command a new checkout runs,
            // and sending them to `init` and back is a step that exists only
            // because the code was split that way.
            try cmdInit(init, false);
            try doctor_mod.cmdSetup(init);
        },
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
        .phonebook => try phonebook.cmdPhonebook(init),
        .serve => try cmdServe(init, opts),
        .repl => try repl_vaxis.cmdReplVaxis(init, .{
            .provider = opts.provider,
            .model = opts.model,
            .session = opts.session,
            .continue_last = opts.continue_last,
        }),
        .graph => try cmdGraph(init, opts),
        .autolearn => try cmdAutolearn(init, opts),
        .gate => try cmdGate(init, opts),
    }
}

fn writeStdErr(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
}

fn writeStdOut(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
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
    \\    "deepseek": {{ "kind": "openai_compat", "base_url": "https://api.deepseek.com", "api_key_env": "DEEPSEEK_API_KEY", "default_model": "deepseek-chat", "models": {{ "deepseek-chat": {{ "max_tokens": 2048 }} }} }}
    \\  }},
    \\  "instance": {{ "name": "{s}", "id": "{s}" }},
    \\  "agent": {{ "max_iterations": 12 }}
    \\}}
    \\
;

fn cmdInit(init: std.process.Init, announce: bool) !void {
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
    if (announce) log.log(.info, "clanker initialized. Run `clanker setup` to check it over.", .{});
}

// --------------------------------------------------------- providers check --

fn cmdProvidersCheck(init: std.process.Init, opts: Options) !void {
    if (std.mem.eql(u8, opts.providers_sub, "models")) {
        return cmdProvidersModels(init, opts);
    }
    if (std.mem.eql(u8, opts.providers_sub, "catalog")) {
        return cmdProvidersCatalog(init, opts);
    }
    if (std.mem.eql(u8, opts.providers_sub, "fill")) {
        return cmdProvidersFill(init, opts);
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
            log.log(.error_, "{s}: {s}", .{ name, err_detail orelse @errorName(err) });
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

/// Public, unauthenticated directory of provider/model specs (context window,
/// pricing, capabilities) maintained outside this repo. Used so a model's
/// metadata does not have to be hand-typed into config.json and kept in sync
/// by hand.
const models_dev_url = "https://models.dev/api.json";

/// `clanker providers catalog <query>` — search the models.dev directory for
/// provider or model ids/families containing `query` (case-insensitive) and
/// print what it knows about each match. Read-only; nothing here touches
/// config.json.
fn cmdProvidersCatalog(init: std.process.Init, opts: Options) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const query = opts.provider orelse {
        log.log(.error_, "usage: clanker providers catalog <query>  (e.g. \"kimi\", \"deepseek\")", .{});
        return error.MissingCatalogQuery;
    };

    const body = try httpGet(io, gpa, arena, models_dev_url, null);
    const catalog = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{ .ignore_unknown_fields = true });
    if (catalog != .object) return error.CatalogNotObject;

    const out = std.Io.File.stdout();
    try out.writeStreamingAll(io, "provider/model\tctx\tout\tin $/1M\tout $/1M\treasoning\n");
    var it = catalog.object.iterator();
    while (it.next()) |kv| {
        const provider_id = kv.key_ptr.*;
        const provider_entry = kv.value_ptr.*;
        if (provider_entry != .object) continue;
        const models_v = provider_entry.object.get("models") orelse continue;
        if (models_v != .object) continue;
        var mit = models_v.object.iterator();
        while (mit.next()) |mkv| {
            const model_id = mkv.key_ptr.*;
            const family = if (mkv.value_ptr.* == .object) fieldStr(mkv.value_ptr.object, "family") orelse "" else "";
            if (std.ascii.indexOfIgnoreCase(provider_id, query) == null and
                std.ascii.indexOfIgnoreCase(model_id, query) == null and
                std.ascii.indexOfIgnoreCase(family, query) == null) continue;
            try out.writeStreamingAll(io, try renderCatalogRow(arena, provider_id, model_id, mkv.value_ptr.*));
        }
    }
}

/// One `provider/model\tctx\tout\tin $/1M\tout $/1M\treasoning\n` line for the
/// catalog table.
fn renderCatalogRow(arena: std.mem.Allocator, provider_id: []const u8, model_id: []const u8, m: std.json.Value) ![]const u8 {
    if (m != .object) return std.fmt.allocPrint(arena, "{s}/{s}\t?\t?\t?\t?\t?\n", .{ provider_id, model_id });
    var ctx: f64 = 0;
    var out_limit: f64 = 0;
    if (m.object.get("limit")) |l| if (l == .object) {
        ctx = jsonNum(l.object, "context") orelse 0;
        out_limit = jsonNum(l.object, "output") orelse 0;
    };
    var cost_in: f64 = 0;
    var cost_out: f64 = 0;
    if (m.object.get("cost")) |c| if (c == .object) {
        cost_in = jsonNum(c.object, "input") orelse 0;
        cost_out = jsonNum(c.object, "output") orelse 0;
    };
    const reasoning = if (m.object.get("reasoning")) |r| (r == .bool and r.bool) else false;
    return std.fmt.allocPrint(arena, "{s}/{s}\t{d}\t{d}\t{d:.2}\t{d:.2}\t{s}\n", .{
        provider_id, model_id, @as(i64, @trunc(ctx)),          @as(i64, @trunc(out_limit)),
        cost_in,     cost_out, if (reasoning) "yes" else "no",
    });
}

/// `clanker providers fill <name>` — for a provider already declared in
/// config.json, print each of its configured models' specs as known by the
/// models.dev catalog, ready to paste into `models.<name>`. Never writes
/// config.json itself: reformatting the whole file to insert a few fields
/// risks losing whatever hand structure/comments-adjacent ordering it had,
/// so the human stays in the loop for the merge.
fn cmdProvidersFill(init: std.process.Init, opts: Options) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const provider_name = opts.provider orelse {
        log.log(.error_, "usage: clanker providers fill <provider>", .{});
        return error.MissingCatalogQuery;
    };
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    const p = try cfg.provider(provider_name);

    const body = try httpGet(io, gpa, arena, models_dev_url, null);
    const catalog = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{ .ignore_unknown_fields = true });
    const cat_provider = findCatalogProvider(catalog, p) orelse {
        log.log(.warn, "{s}: no models.dev entry matches base_url {s}", .{ provider_name, p.base_url });
        return;
    };

    const out = std.Io.File.stdout();
    var it = p.models.iterator();
    while (it.next()) |kv| {
        const model_name = kv.key_ptr.*;
        const cat_model = findCatalogModel(cat_provider, model_name) orelse {
            try out.writeStreamingAll(io, try std.fmt.allocPrint(arena, "// {s}: no catalog match\n", .{model_name}));
            continue;
        };
        try out.writeStreamingAll(io, try renderModelSnippet(arena, model_name, cat_model));
    }
}

/// The models.dev provider entry whose API this clanker provider talks to:
/// an exact `base_url` match first (most precise), then same host, then (for
/// providers with no fixed public host, e.g. a local relay) a shared
/// `api_key_env` name. Ambiguous on env alone — several models.dev entries
/// can share one vendor's env var name — so it is only the last resort.
fn findCatalogProvider(catalog: std.json.Value, p: *const config.Provider) ?std.json.Value {
    if (catalog != .object) return null;
    const want_base = std.mem.trimEnd(u8, p.base_url, "/");
    const want_host = config.hostOf(p.base_url);
    var env_fallback: ?std.json.Value = null;
    var it = catalog.object.iterator();
    while (it.next()) |kv| {
        const entry = kv.value_ptr.*;
        if (entry != .object) continue;
        const api = fieldStr(entry.object, "api") orelse "";
        if (api.len > 0 and std.mem.eql(u8, std.mem.trimEnd(u8, api, "/"), want_base)) return entry;
        if (want_host) |wh| {
            if (config.hostOf(api)) |eh| {
                if (std.mem.eql(u8, eh, wh)) return entry;
            }
        }
        if (env_fallback == null) {
            if (p.api_key_env) |want_env| {
                if (entry.object.get("env")) |envs| {
                    if (envs == .array) {
                        for (envs.array.items) |e| {
                            if (e == .string and std.mem.eql(u8, e.string, want_env)) {
                                env_fallback = entry;
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
    return env_fallback;
}

/// A catalog provider's model matching `model_name`, trying the exact key
/// first and then the part after the last `/` — config model names are
/// sometimes written OpenRouter-style (`moonshotai/kimi-k3`) even against a
/// vendor's own API, which the catalog keys bare (`kimi-k3`).
fn findCatalogModel(provider_entry: std.json.Value, model_name: []const u8) ?std.json.Value {
    if (provider_entry != .object) return null;
    const models_v = provider_entry.object.get("models") orelse return null;
    if (models_v != .object) return null;
    if (models_v.object.get(model_name)) |m| return m;
    if (std.mem.lastIndexOfScalar(u8, model_name, '/')) |slash| {
        return models_v.object.get(model_name[slash + 1 ..]);
    }
    return null;
}

/// A pastable `"<name>": { ... }` block for `models.<provider>.<name>` in
/// config.json, built from a models.dev model entry.
fn renderModelSnippet(arena: std.mem.Allocator, name: []const u8, m: std.json.Value) ![]const u8 {
    if (m != .object) return std.fmt.allocPrint(arena, "// {s}: malformed catalog entry\n", .{name});
    var fields: std.ArrayList([]const u8) = .empty;
    if (m.object.get("limit")) |l| if (l == .object) {
        if (jsonNum(l.object, "context")) |c| try fields.append(arena, try std.fmt.allocPrint(arena, "  \"context_window\": {d}", .{@as(i64, @trunc(c))}));
        if (jsonNum(l.object, "output")) |o| try fields.append(arena, try std.fmt.allocPrint(arena, "  \"max_tokens\": {d}", .{@as(i64, @trunc(o))}));
    };
    if (m.object.get("cost")) |c| if (c == .object) {
        if (jsonNum(c.object, "input")) |v| try fields.append(arena, try std.fmt.allocPrint(arena, "  \"cost_per_1m_input\": {d}", .{v}));
        if (jsonNum(c.object, "output")) |v| try fields.append(arena, try std.fmt.allocPrint(arena, "  \"cost_per_1m_output\": {d}", .{v}));
    };
    if (fieldStr(m.object, "name")) |disp| try fields.append(arena, try std.fmt.allocPrint(arena, "  \"display\": \"{s}\"", .{disp}));

    var w: std.Io.Writer.Allocating = .init(arena);
    try w.writer.print("\"{s}\": {{\n", .{name});
    for (fields.items, 0..) |f, i| {
        try w.writer.writeAll(f);
        if (i < fields.items.len - 1) try w.writer.writeAll(",");
        try w.writer.writeAll("\n");
    }
    try w.writer.writeAll("}\n");
    return w.toOwnedSlice();
}

/// A JSON number field, accepting the string-encoded numbers some catalog
/// entries use. Absent or non-numeric reads as `null`, distinct from a
/// legitimate `0` (which no context window or price ever is in practice).
fn jsonNum(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer, .float, .number_string, .string => numToF64(v),
        else => null,
    };
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
    // Growable: a fixed buffer here used to cap every response at 1 MiB,
    // which silently truncated (or outright failed) anything past it — the
    // models.dev catalog alone runs to several MiB.
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    var headers: std.http.Client.Request.Headers = .{
        .user_agent = .{ .override = "clanker/" ++ version },
    };
    if (bearer) |b| headers.authorization = .{ .override = b };
    const res = try http.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = headers,
        .response_writer = &body.writer,
    });
    if (@intFromEnum(res.status) >= 400) return error.HttpError;
    return arena.dupe(u8, body.written());
}

/// `clanker autolearn` — review usage observations, refresh the roadmap
/// Autolearn section, and print the generated items. The aggregate-and-write
/// logic lives in the cmd_autolearn tool (fs-scoped read/aggregate/write,
/// same shape as roadmap/history/learnings); this just runs it and reports.
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
    const section = try toolText(io, gpa, arena, &cfg, init.environ_map, "cmd_autolearn", "");
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

/// The id `--continue` means: the session touched most recently. Returns null
/// when there are none, so a first `clanker -c "..."` starts a session rather
/// than failing at someone who has not made one yet.
fn latestSessionId(io: std.Io, arena: std.mem.Allocator) ?[]const u8 {
    const metas = session.listSessions(io, arena, std.Io.Dir.cwd()) catch return null;
    var best: ?session.SessionMeta = null;
    for (metas) |m| {
        if (best == null or m.updated > best.?.updated) best = m;
    }
    return if (best) |b| b.id else null;
}

/// The provider named by `--provider` (or the config default), with
/// `--model` applied as a one-off override of its `default_model`.
///
/// `--model <provider>/<model>` picks both at once, so `--model zai/glm-5.2`
/// needs no separate `--provider`. The prefix is only read as a provider when
/// config actually has one by that name and `--provider` was not given: a
/// model id can contain a slash of its own (`moonshotai/kimi-k3` is a model,
/// served by the provider named `kimi-k3`), and splitting those would send a
/// request for a model that does not exist to a provider that does not either.
fn resolveProvider(cfg: *const config.Config, opts: Options) !config.Provider {
    var want_provider = opts.provider;
    var want_model = opts.model;
    if (want_provider == null) {
        if (want_model) |m| {
            if (std.mem.indexOfScalar(u8, m, '/')) |slash| {
                const head = m[0..slash];
                const tail = m[slash + 1 ..];
                if (head.len > 0 and tail.len > 0 and cfg.providers.getPtr(head) != null) {
                    want_provider = head;
                    want_model = tail;
                }
            }
        }
    }
    var provider = (try cfg.provider(want_provider)).*;
    if (want_model) |m| provider.default_model = m;
    return provider;
}

/// One goal loaded from `state/goals.json` and ready to steer a run.
const GoalContext = struct {
    id: []const u8,
    objective: []const u8,
    completion_criterion: []const u8,
    boundaries: []const u8,
    /// Task-prompt preamble (`## Active goal` …). Arena-owned.
    section: []const u8,
};

/// Formats goal fields as the preamble prepended to a run task.
fn formatGoalSection(
    arena: std.mem.Allocator,
    objective: []const u8,
    completion: []const u8,
    boundaries: []const u8,
) ![]const u8 {
    return try std.fmt.allocPrint(
        arena,
        "## Active goal\n\nobjective: {s}\ncompletion_criterion: {s}\nboundaries: {s}\n\n",
        .{ objective, completion, boundaries },
    );
}

fn goalField(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    if (obj.get(key)) |v| if (v == .string) return v.string;
    return "";
}

fn goalUpdated(obj: std.json.ObjectMap) i64 {
    if (obj.get("updated")) |v| switch (v) {
        .integer => |n| return n,
        .float => |f| return @intFromFloat(f),
        // Web UI / goal tool write timestamps as JSON numbers that may arrive
        // as strings when the file was hand-edited.
        .string => |s| return std.fmt.parseInt(i64, s, 10) catch 0,
        else => {},
    };
    return 0;
}

fn goalFromObject(arena: std.mem.Allocator, obj: std.json.ObjectMap) !?GoalContext {
    const idv = obj.get("id") orelse return null;
    if (idv != .string or idv.string.len == 0) return null;
    const objective = goalField(obj, "objective");
    if (objective.len == 0) return null;
    const completion = goalField(obj, "completion_criterion");
    const boundaries = goalField(obj, "boundaries");
    return .{
        .id = idv.string,
        .objective = objective,
        .completion_criterion = completion,
        .boundaries = boundaries,
        .section = try formatGoalSection(arena, objective, completion, boundaries),
    };
}

/// Looks up `goal_id` in `dir`/`state/goals.json`. Returns null if the file,
/// the entry, or the JSON shape is missing.
fn findGoalSectionIn(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, goal_id: []const u8) !?[]const u8 {
    const g = try loadGoalById(arena, io, dir, goal_id) orelse return null;
    return g.section;
}

fn findGoalSection(arena: std.mem.Allocator, io: std.Io, goal_id: []const u8) !?[]const u8 {
    return findGoalSectionIn(arena, io, std.Io.Dir.cwd(), goal_id);
}

fn loadGoalById(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, goal_id: []const u8) !?GoalContext {
    const goals_raw = dir.readFileAlloc(io, "state/goals.json", arena, .limited(1 << 20)) catch return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, goals_raw, .{}) catch return null;
    if (root != .array) return null;
    for (root.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const idv = obj.get("id") orelse continue;
        if (idv != .string or !std.mem.eql(u8, idv.string, goal_id)) continue;
        return try goalFromObject(arena, obj);
    }
    return null;
}

/// Newest `status=active` goal in `dir`/`state/goals.json`, by `updated`
/// then array order. This is what "the goal most recently set is steering
/// runs" means in the web UI copy.
fn findNewestActiveGoalIn(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !?GoalContext {
    const goals_raw = dir.readFileAlloc(io, "state/goals.json", arena, .limited(1 << 20)) catch return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, goals_raw, .{}) catch return null;
    if (root != .array) return null;
    var best: ?GoalContext = null;
    var best_updated: i64 = std.math.minInt(i64);
    var best_index: usize = 0;
    for (root.array.items, 0..) |item, i| {
        if (item != .object) continue;
        const obj = item.object;
        const status = goalField(obj, "status");
        // Default status is active when the field is missing (older files).
        if (status.len > 0 and !std.mem.eql(u8, status, "active")) continue;
        const g = try goalFromObject(arena, obj) orelse continue;
        const updated = goalUpdated(obj);
        if (best == null or updated > best_updated or (updated == best_updated and i >= best_index)) {
            best = g;
            best_updated = updated;
            best_index = i;
        }
    }
    return best;
}

fn findNewestActiveGoal(arena: std.mem.Allocator, io: std.Io) !?GoalContext {
    return findNewestActiveGoalIn(arena, io, std.Io.Dir.cwd());
}

/// Prepends a goal preamble to `task`. When `task` is empty, builds a default
/// work order from the goal's objective and completion criterion so a web UI
/// "Work on this" click (or a goal-only POST) can execute without inventing text.
fn taskWithGoal(arena: std.mem.Allocator, task: []const u8, g: GoalContext) ![]const u8 {
    const body = if (std.mem.trim(u8, task, " \t\r\n").len > 0)
        task
    else
        try std.fmt.allocPrint(
            arena,
            "Work on this goal until the completion criterion is met.\n\nObjective: {s}\nDone when: {s}\n",
            .{ g.objective, g.completion_criterion },
        );
    return try std.fmt.allocPrint(arena, "{s}{s}", .{ g.section, body });
}

/// Resolves which goal steers this run: explicit id, else newest active when
/// `auto` is true. Returns the task text with the preamble applied (or the
/// original task when no goal applies).
fn resolveRunTask(
    arena: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    task: []const u8,
    goal_id: ?[]const u8,
    auto: bool,
) ![]const u8 {
    if (goal_id) |id| {
        if (try loadGoalById(arena, io, dir, id)) |g| {
            return try taskWithGoal(arena, task, g);
        }
        log.log(.warn, "goal '{s}' not found in state/goals.json — running without goal context", .{id});
        return task;
    }
    if (!auto) return task;
    if (try findNewestActiveGoalIn(arena, io, dir)) |g| {
        log.log(.info, "steering run with active goal {s}", .{g.id});
        return try taskWithGoal(arena, task, g);
    }
    return task;
}

fn cmdRun(init: std.process.Init, opts: Options) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    var ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = init.environ_map, .cfg = &cfg };

    var provider_val = try resolveProvider(&cfg, opts);
    const provider = &provider_val;

    // Make sure the sandbox root exists.
    std.Io.Dir.cwd().createDirPath(io, cfg.agent.sandbox_root) catch {};

    var reg = try registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir);
    const tool_defs = try reg.toToolDefs(arena);

    var a = try agent.Agent.init(&ctx, arena, provider, &cfg, &reg, tool_defs);
    defer a.deinit();
    a.subagent_runner = if (cfg.modules.subagents) &subagent.runNested else null;
    var messages: std.ArrayList(types.Message) = .empty;
    var created: i64 = 0;
    var opts_session = opts.session;
    if (opts_session == null and opts.continue_last) {
        opts_session = latestSessionId(io, arena);
        if (opts_session) |sid| log.log(.info, "continuing session {s}", .{sid});
    }
    if (opts_session) |sid| {
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
    // Explicit `--goal <id>` wins; otherwise the newest active goal steers
    // the run automatically when the goal module is on (same rule the web UI
    // describes: the goal most recently set is what runs are steered toward).
    const task_text = try resolveRunTask(
        arena,
        io,
        std.Io.Dir.cwd(),
        opts.task.?,
        opts.goal,
        cfg.modules.goal and opts.goal == null,
    );
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
    // NO_COLOR (https://no-color.org) is the standard opt-out; honour it
    // ahead of the isTty check rather than requiring a clanker-specific flag.
    run_stdout_color = init.environ_map.get("NO_COLOR") == null and (stdout_file.isTty(io) catch false);
    a.on_token = &runDelta;

    // The spinner and the live tool-status line belong to the REPL. `run` is
    // a one-shot command that gets piped, redirected and read by scripts, so
    // it stays plain: streamed answer on stdout, log lines on stderr, no
    // animation to clean up out of a captured log.
    run_answer_started = false;
    run_md = .{};
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

const ToolResult = struct { ok: bool = false, text: []const u8 = "", err: []const u8 = "" };

/// Parses the `{"ok":bool,"text":string}` / `{"ok":false,"error":string}`
/// envelope every internal tool's response follows. On unparseable JSON,
/// `text` becomes the raw bytes so a caller that just echoes `text` still
/// shows the caller something instead of silently swallowing it.
fn parseToolResult(arena: std.mem.Allocator, raw: []const u8) ToolResult {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{ .ignore_unknown_fields = true }) catch {
        return .{ .text = raw };
    };
    var r = ToolResult{};
    if (parsed == .object) {
        if (parsed.object.get("ok")) |k| if (k == .bool) {
            r.ok = k.bool;
        };
        if (parsed.object.get("text")) |t| if (t == .string) {
            r.text = t.string;
        };
        if (parsed.object.get("error")) |e| if (e == .string) {
            r.err = e.string;
        };
    }
    return r;
}

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
    const n = f.readPositionalAll(io, &magic, 0) catch return false;
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

fn buildServeArgvTail(arena: std.mem.Allocator, port: u16) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "serve");
    try argv.append(arena, "--port");
    try argv.append(arena, try std.fmt.allocPrint(arena, "{d}", .{port}));
    return argv.items;
}

/// The streaming markdown renderer now lives in tui/transcript.zig, next to
/// the tool-call card renderer it shares a "print-once transcript element"
/// role with. Still used by `cmdRun`'s own `run_md` below even though the
/// REPL that used to also use this type is gone.
const MdStream = tui_transcript.MdStream;

/// True once the current turn's assistant text has started streaming, so the
/// colored "›" gutter is only printed once, right before the first token.
/// Shared with `cmdRun` (see `runDelta`), not REPL-exclusive despite the name.
var run_answer_started = false;

/// `clanker run`'s stdout content writer: kept separate from `repl_out`
/// (which, in `run`, points at stderr for the spinner/tool-status line) so
/// streamed answer bytes never share a stream with status noise — piping
/// stdout stays byte-identical to a plain, non-streamed run.
var run_out: ?*std.Io.File.Writer = null;
var run_stdout_color = false;
var run_md: MdStream = .{};

fn runDelta(delta: []const u8) void {
    const w = run_out orelse return;
    if (run_stdout_color and !run_answer_started) {
        run_answer_started = true;
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
/// 4096 and 8192 was a budget for a model with an 8K window, and it made the
/// REPL single-turn without saying so: one turn that read a large file spent
/// 190K tokens, and the next turn opened by discarding every message down to
/// 4K, so the model answered "you asked me to implement these" with no idea
/// what "these" was. Sized for the windows actually in use now (the smallest
/// configured provider here is 128K); a turn still compacts, just not down to
/// nothing.
const max_turn_tokens = 96 * 1024;
const max_session_tokens = 128 * 1024;

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
/// Runs a tool whose input is a JSON object rather than a command string, and
/// returns its raw JSON output including a refusal.
///
/// toolText exists for the `cmd_*` tools, which take {"args": "<string>"} and
/// answer with {"text": "..."}. A tool that models an API takes the request
/// object itself and answers with the resource, and its refusals are part of
/// what the caller has to relay, so they are returned rather than logged and
/// swallowed.
fn toolJson(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    cfg: *const config.Config,
    environ_map: *std.process.Environ.Map,
    tool_name: []const u8,
    input: []const u8,
) ![]const u8 {
    var reg = try registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir);
    var ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = environ_map, .cfg = cfg };
    const mod = runtime.loadNamedTool(gpa, io, arena, environ_map, cfg, &reg, tool_name, &ctx) catch |err| {
        if (err == error.UnknownTool) {
            // Descriptor missing from tools_dir — not a missing .wasm rebuild.
            log.log(.error_, "internal tool '{s}' not found in {s}", .{ tool_name, cfg.agent.tools_dir });
        } else {
            log.log(.error_, "'{s}' tool load failed: {s} (run `zig build tools`)", .{ tool_name, @errorName(err) });
        }
        return error.ToolWasmMissing;
    };
    defer mod.deinit();
    const raw = try mod.executeTool(if (input.len > 0) input else "{}");
    defer gpa.free(raw);
    return arena.dupe(u8, raw);
}

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
    var ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = environ_map, .cfg = cfg };
    const mod = runtime.loadNamedTool(gpa, io, arena, environ_map, cfg, &reg, tool_name, &ctx) catch |err| {
        if (err == error.UnknownTool) {
            log.log(.error_, "internal tool '{s}' not found in {s}", .{ tool_name, cfg.agent.tools_dir });
        } else {
            log.log(.error_, "'{s}' tool load failed: {s} (run `zig build tools`)", .{ tool_name, @errorName(err) });
        }
        return error.ToolWasmMissing;
    };
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

    var provider_val = try resolveProvider(&cfg, opts);
    const provider = &provider_val;

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

    var provider_val = try resolveProvider(&cfg, opts);
    const provider = &provider_val;

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

/// `clanker notify <peer> <message>` sends through the same sandboxed
/// `peers` WASM tool the model uses, rather than a second hand-rolled HTTP
/// client: one code path for "POST a notify to a peer", gated by that
/// tool's own `network_from_config` allowlist instead of an unrestricted
/// `std.http.Client`.
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

    var reg = try registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir);
    const mod = runtime.loadNamedTool(gpa, io, arena, init.environ_map, &cfg, &reg, "peers", null) catch |err| {
        if (err == error.UnknownTool) {
            log.log(.error_, "internal tool 'peers' not found in {s}", .{cfg.agent.tools_dir});
        } else {
            log.log(.error_, "'peers' tool load failed: {s} (run `zig build tools`)", .{@errorName(err)});
        }
        return error.ToolWasmMissing;
    };
    defer mod.deinit();

    var ibuf: [4096]u8 = undefined;
    var iw: std.Io.Writer = .fixed(&ibuf);
    var is = std.json.Stringify{ .writer = &iw, .options = .{} };
    try is.beginObject();
    try is.objectField("action");
    try is.write("notify");
    try is.objectField("peer");
    try is.write(peer_name);
    try is.objectField("message");
    try is.write(message);
    try is.endObject();

    const raw = try mod.executeTool(ibuf[0..iw.end]);
    defer gpa.free(raw);
    const result = parseToolResult(arena, raw);
    if (!result.ok) {
        log.log(.error_, "notify to '{s}' failed: {s}", .{ peer_name, result.err });
        return error.ToolFailed;
    }
    log.log(.info, "notify {s}: sent", .{peer_name});
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
    defer hist.deinit();
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

    // Parked for serveConfirm, which frees answers that connection threads
    // duped with this same allocator (see handleAsk).
    serve_gpa = gpa;

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
        if (rawhttp.requestComplete(total.items)) break;
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
        // Routes match the path, never the whole target. Comparing the target
        // meant any URL carrying a query string missed its route and 404'd —
        // "/" was fine but "/?v=3" was not, and the board could not name its
        // room until this was special-cased for one endpoint.
        const path = target[0..(std.mem.indexOfScalar(u8, target, '?') orelse target.len)];
        // The listen socket is 127.0.0.1-only, but any page open in the
        // user's browser can still reach it: every non-GET route here either
        // runs the agent, execs sandboxed tools, or writes state, so a
        // cross-origin POST from an unrelated site the user happens to have
        // open is CSRF, not a hypothetical. A request with no Origin header
        // (curl, or the raw API used directly) is not a browser cross-site
        // request and is let through.
        if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "HEAD") and crossOriginRequest(headers_raw, port)) {
            respond(stream, 403, "Forbidden", "{\"error\":\"cross-origin request refused\"}");
            return;
        }
        const is_webui = std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/webui") or
            std.mem.eql(u8, path, "/webui/app.css") or std.mem.eql(u8, path, "/webui/app.js") or
            std.mem.eql(u8, path, "/webui/van-boot.js") or
            std.mem.eql(u8, path, "/webui/vendor/van.js") or std.mem.eql(u8, path, "/webui/vendor/van-ui.js") or
            std.mem.startsWith(u8, path, "/webui/plugins/") or
            std.mem.eql(u8, path, "/webui/vendor/d3-dag.min.js") or std.mem.eql(u8, path, "/webui/vendor/hljs.min.js");
        const is_a2a = std.mem.eql(u8, path, "/.well-known/agent.json") or (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/a2a/message"));
        const is_notify = std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/notify");
        const is_chat_message = std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/chat/message");
        const is_chat_messages = std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, path, "/api/chat/messages");
        const is_chat_rooms = std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/chat/rooms");
        const is_chat_send = std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/chat/send");
        const is_chat_subscribe = std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/chat/subscribe");
        const is_stats = std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/stats");
        const is_plugins = std.mem.eql(u8, path, "/api/plugins") and (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "POST"));
        const is_goals = std.mem.eql(u8, path, "/api/goals") and
            (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "POST"));
        const is_providers = std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/providers");
        const is_janitor = std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/janitor");
        const is_board = std.mem.eql(u8, path, "/api/board") and
            (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "POST"));
        const is_webui_plugins = std.mem.eql(u8, path, "/api/webui/plugins") and
            (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "POST"));
        const is_webui_plugin_asset = std.mem.eql(u8, method, "GET") and
            std.mem.startsWith(u8, path, "/webui/plugins/");
        const is_logs = std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, path, "/api/logs");
        const is_plugin_config = std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/plugins/config");
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
        } else if (std.mem.eql(u8, method, "GET") and (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/webui"))) {
            handleWebui(io, gpa, cfg, environ_map, acceptsGzip(headers_raw), headers_raw, stream);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/webui/vendor/van.js")) {
            respondJs(gpa, stream, webui_vendor_van, &gzip_van, acceptsGzip(headers_raw), headers_raw);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/webui/vendor/van-ui.js")) {
            respondJs(gpa, stream, webui_vendor_vanui, &gzip_vanui, acceptsGzip(headers_raw), headers_raw);
        } else if (std.mem.eql(u8, method, "GET") and
            (std.mem.eql(u8, path, "/webui/app.css") or std.mem.eql(u8, path, "/webui/app.js") or
                std.mem.eql(u8, path, "/webui/van-boot.js")))
        {
            // Same tool, same comptime size guard, one file per language.
            handleWebuiAsset(io, gpa, cfg, environ_map, target, acceptsGzip(headers_raw), headers_raw, stream);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/webui/vendor/d3-dag.min.js")) {
            respondJs(gpa, stream, webui_vendor_d3dag, &gzip_d3dag, acceptsGzip(headers_raw), headers_raw);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/webui/vendor/hljs.min.js")) {
            respondJs(gpa, stream, webui_vendor_hljs, &gzip_hljs, acceptsGzip(headers_raw), headers_raw);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/.well-known/agent.json")) {
            handleAgentCard(gpa, cfg, port, stream);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/status")) {
            handleStatus(cfg, stream);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, path, "/api/runs")) {
            handleRuns(io, gpa, cfg, environ_map, target, acceptsGzip(headers_raw), stream);
        } else if (std.mem.startsWith(u8, path, "/api/sessions") and
            (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "POST") or std.mem.eql(u8, method, "DELETE")))
        {
            handleSessions(io, gpa, cfg, method, target, body, acceptsGzip(headers_raw), stream);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/notify")) {
            handleNotify(io, gpa, body) catch |err| {
                log.log(.error_, "POST /api/notify: {s}", .{@errorName(err)});
                respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"notify failed\"}");
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
            handleGoals(io, gpa, cfg, method, body, stream);
        } else if (is_providers) {
            handleProviders(cfg, stream);
        } else if (is_janitor) {
            handleJanitor(io, gpa, cfg, stream);
        } else if (is_board) {
            handleBoard(io, gpa, cfg, environ_map, method, target, body, stream);
        } else if (is_webui_plugins) {
            handleWebuiPlugins(io, gpa, method, body, stream);
        } else if (is_webui_plugin_asset) {
            handleWebuiPluginAsset(io, gpa, target, acceptsGzip(headers_raw), stream);
        } else if (is_logs) {
            handleLogs(io, gpa, target, acceptsGzip(headers_raw), stream);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/a2a/message")) {
            handleA2AMessage(io, gpa, cfg, environ_map, stream, body);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/ask")) {
            handleAsk(gpa, stream, body);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/run")) {
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
        respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"bad request\"}");
        return;
    };
    const room = parsed.room orelse {
        respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"missing room\"}");
        return;
    };
    const text = parsed.text orelse "";
    if (text.len > chatrooms.max_text_len) {
        respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"text too long\"}");
        return;
    }
    const msg = chatrooms.Message{
        .room = room,
        .from = parsed.from orelse "unknown",
        .text = text,
        .ts = parsed.ts orelse 0,
        // Empty, not a shared sentinel: a fixed placeholder for every id-less
        // sender would make chatrooms.append's dedup treat unrelated messages
        // from old peers as duplicates of each other. Empty id skips dedup.
        .id = parsed.id orelse "",
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
        respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"missing room\"}");
        return;
    }
    const msgs = chatrooms.readHistory(std.Io.Dir.cwd(), io, gpa, arena, cfg.agent.state_dir, room, after, 50) catch |err| {
        log.log(.error_, "GET /api/chat/messages room={s}: {s}", .{ room, @errorName(err) });
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"history read failed\"}");
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
        chatrooms.subscribe(std.Io.Dir.cwd(), io, gpa, arena, cfg.agent.state_dir, room, true) catch |err| {
            log.log(.error_, "POST /api/chat/send room={s}: auto-join failed: {s}", .{ room, @errorName(err) });
            respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"could not join room\"}");
            return;
        };
    }
    const msg = chatrooms.sendMessage(std.Io.Dir.cwd(), io, gpa, arena, cfg.agent.state_dir, cfg, room, text) catch |err| {
        log.log(.error_, "POST /api/chat/send room={s}: {s}", .{ room, @errorName(err) });
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
    chatrooms.subscribe(std.Io.Dir.cwd(), io, gpa, arena, cfg.agent.state_dir, room, parsed.on) catch |err| {
        log.log(.error_, "POST /api/chat/subscribe room={s}: {s}", .{ room, @errorName(err) });
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"subscribe failed\"}");
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

    const rooms = chatrooms.listRooms(std.Io.Dir.cwd(), io, gpa, arena, cfg.agent.state_dir) catch |err| {
        log.log(.error_, "GET /api/chat/rooms: {s}", .{@errorName(err)});
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"room list failed\"}");
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

    const stats = token_stats.aggregate(std.Io.Dir.cwd(), io, gpa, arena, cfg.agent.state_dir) catch |err| {
        log.log(.error_, "GET /api/stats: aggregate failed: {s}", .{@errorName(err)});
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"stats aggregate failed\"}");
        return;
    };
    const json_out = token_stats.statsJSON(arena, stats, token_stats.totals(stats)) catch |err| {
        log.log(.error_, "GET /api/stats: encode failed: {s}", .{@errorName(err)});
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"stats encode failed\"}");
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
    s.write(version) catch return;
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

fn handleA2AMessage(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, environ_map: *std.process.Environ.Map, stream: std.Io.net.Stream, body: []const u8) void {
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

    // Run the incoming message through the agent model instead of echoing
    // it back. The agent card advertises real skills; echoing raw input
    // makes the peer receive its own message as the "answer".
    if (text.len == 0) {
        respond(stream, 400, "Bad Request", "{\"error\":\"empty message\"}");
        return;
    }
    var ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = environ_map, .cfg = cfg };
    var provider = cfg.provider(null) catch {
        respond(stream, 500, "Internal Server Error", "{\"error\":\"provider unavailable\"}");
        return;
    };
    var provider_copy = provider.*;
    provider = &provider_copy;
    std.Io.Dir.cwd().createDirPath(io, cfg.agent.sandbox_root) catch {};
    var reg = registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir) catch |err| {
        log.log(.error_, "POST /api/a2a/message: registry load failed: {s}", .{@errorName(err)});
        respond(stream, 500, "Internal Server Error", "{\"error\":\"tools registry unavailable\"}");
        return;
    };
    const tool_defs = reg.toToolDefs(arena) catch {
        respond(stream, 500, "Internal Server Error", "{\"error\":\"tool defs failed\"}");
        return;
    };
    var a = agent.Agent.init(&ctx, arena, provider, cfg, &reg, tool_defs) catch |err| {
        log.log(.error_, "POST /api/a2a/message: agent init failed: {s}", .{@errorName(err)});
        respond(stream, 500, "Internal Server Error", "{\"error\":\"agent init failed\"}");
        return;
    };
    defer a.deinit();
    a.subagent_runner = if (cfg.modules.subagents) &subagent.runNested else null;
    var messages: std.ArrayList(types.Message) = .empty;
    var err_detail: ?[]const u8 = null;
    const resp = a.run(&messages, text, &err_detail) catch |err| {
        const detail = err_detail orelse @errorName(err);
        log.log(.error_, "POST /api/a2a/message: agent run failed: {s}", .{detail});
        respond(stream, 500, "Internal Server Error", "{\"error\":\"agent run failed\"}");
        return;
    };
    const content = resp.message.content orelse "";

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
    s.write(content) catch return;
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
    /// Optional goal id from `state/goals.json`. When set, that goal's
    /// preamble is prepended and an empty `task` becomes a work order for
    /// the goal. When empty and the goal module is on, the newest active
    /// goal steers the run automatically.
    goal: []const u8 = "",
    /// Images the composer attached to this task (multimodal runs).
    images: []const RunImage = &.{},
    /// Optional per-run overrides, the request-shaped equivalent of
    /// `--provider` and the model's sampling settings in config.json. Empty or
    /// null means "use what the config says".
    provider: []const u8 = "",
    model: []const u8 = "",
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    /// Plan mode (webui-plan 2.2): the run researches and proposes but the
    /// harness refuses write-capable tools, so nothing changes until the
    /// user applies the plan as a follow-up run.
    plan: bool = false,
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
        rawhttp.writeAllFd(fd, delta);
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
    rawhttp.writeAllFd(fd, buf[0..w.end]);
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

// ---- ask bridge: ask_user over the /api/run stream ------------------------
//
// The REPL answers ask_user at the terminal; a streaming web run answers it
// through the browser. The question travels down the run's own stream as an
// `ask` control event, the run's connection thread blocks here, and
// `POST /api/ask` (a different connection, hence a different thread) delivers
// the pick and wakes it. Nothing is allocated to hold a pending question:
// a question exists only while a connection thread is blocked inside
// serveAsk, and those threads are capped at max_connection_threads, so a
// fixed table of that many slots can never be too small.

/// One question a streaming run has put to the browser and is blocked on.
const PendingAsk = struct {
    /// 0 marks a free slot; live ids start at 1 and are never reused, so a
    /// stale POST cannot answer a later question by accident.
    id: u64 = 0,
    /// The options offered, borrowed from the asking thread's call frame.
    /// Valid for exactly as long as the entry is registered: serveAsk blocks
    /// until it frees the slot, and its caller keeps the memory alive while
    /// it blocks.
    options: []const []const u8 = &.{},
    /// The picked option, duped with the server gpa on the answering thread.
    /// Ownership passes to the waiter, which returns it to ckAsk (who frees).
    answer: ?[]u8 = null,
    /// Distinguishes "answered" from a timeout when the waiter wakes.
    answered: bool = false,
};

// pthread primitives via std.c rather than std.Io.Mutex/Condition: AskFn is
// a bare function pointer, so serveAsk has no `Io` to wait through — and the
// Io condition has no timed wait, which the bounded block below cannot do
// without. Both types' zero-default is their static initializer.
var ask_mutex: std.c.pthread_mutex_t = .{};
var ask_cond: std.c.pthread_cond_t = .{};
var ask_slots: [max_connection_threads]PendingAsk = @splat(.{});
var ask_next_id: u64 = 1;

/// Nanoseconds serveAsk waits for the browser before giving up. Set from
/// agent.ask_timeout_seconds when a streaming run starts; a global rather
/// than a parameter because AskFn is a bare function pointer.
var serve_ask_timeout_ns: u64 = 120 * std.time.ns_per_s;

/// Registers a question and returns its id, or null when every slot is taken
/// (only possible when every connection thread is already blocked on an ask).
fn askRegister(options: []const []const u8) ?u64 {
    _ = std.c.pthread_mutex_lock(&ask_mutex);
    defer _ = std.c.pthread_mutex_unlock(&ask_mutex);
    for (&ask_slots) |*slot| {
        if (slot.id != 0) continue;
        const id = ask_next_id;
        ask_next_id += 1;
        slot.* = .{ .id = id, .options = options };
        return id;
    }
    return null;
}

const AskResolve = enum { ok, not_found, bad_option, out_of_memory };

/// Delivers the browser's answer to the waiting run. The answer must match
/// one of the offered options byte for byte — anything else is refused, so a
/// hand-written request cannot inject free text into a tool that promised
/// the model a multiple-choice pick.
fn askResolve(gpa: std.mem.Allocator, id: u64, answer: []const u8) AskResolve {
    _ = std.c.pthread_mutex_lock(&ask_mutex);
    defer _ = std.c.pthread_mutex_unlock(&ask_mutex);
    for (&ask_slots) |*slot| {
        if (slot.id != id) continue;
        if (slot.answered) return .not_found;
        for (slot.options) |opt| {
            if (std.mem.eql(u8, opt, answer)) {
                slot.answer = gpa.dupe(u8, opt) catch return .out_of_memory;
                slot.answered = true;
                _ = std.c.pthread_cond_broadcast(&ask_cond);
                return .ok;
            }
        }
        return .bad_option;
    }
    return .not_found;
}

/// Blocks until the ask is answered or `timeout_ns` passes; either way the
/// slot is freed before returning, so a late POST gets not_found instead of
/// writing into a question nobody is waiting on. Returns the gpa-owned
/// answer, or null on timeout.
fn askAwait(id: u64, timeout_ns: u64) ?[]u8 {
    _ = std.c.pthread_mutex_lock(&ask_mutex);
    defer _ = std.c.pthread_mutex_unlock(&ask_mutex);
    const slot = for (&ask_slots) |*s| {
        if (s.id == id) break s;
    } else return null;
    // pthread_cond_timedwait takes an absolute CLOCK_REALTIME deadline, so a
    // broadcast that wakes this waiter without answering it (or a spurious
    // wakeup) re-waits on what is left of the budget for free.
    var now: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(.REALTIME, &now);
    const deadline_total = @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec)) + timeout_ns;
    const deadline: std.c.timespec = .{
        .sec = @intCast(deadline_total / std.time.ns_per_s),
        .nsec = @intCast(deadline_total % std.time.ns_per_s),
    };
    while (!slot.answered) {
        if (std.c.pthread_cond_timedwait(&ask_cond, &ask_mutex, &deadline) == .TIMEDOUT) break;
    }
    const answer = if (slot.answered) slot.answer else null;
    slot.* = .{};
    return answer;
}

/// The serve-side AskFn: forwards ask_user's question to the browser as an
/// `ask` control event on the run's own stream, then blocks this connection
/// thread until POST /api/ask delivers a pick or the timeout fires. On
/// timeout it returns error.NoUser, which ckAsk maps to the same "nobody
/// attached" answer a headless run gets — a closed tab degrades to the model
/// deciding for itself rather than hanging the run forever.
fn serveAsk(question: []const u8, options: []const []const u8) anyerror![]const u8 {
    const fd = run_stream_socket orelse return error.NoUser;
    const id = askRegister(options) orelse return error.NoUser;
    writeStreamEvent(fd, "ask", .{ .id = id, .question = question, .options = options });
    return askAwait(id, serve_ask_timeout_ns) orelse error.NoUser;
}

/// The two answers a confirm question offers. Static, so a pending confirm
/// borrows nothing from the asking frame and POST /api/ask's byte-for-byte
/// option check applies unchanged.
const confirm_options: []const []const u8 = &.{ "allow", "deny" };

/// The server's allocator, parked for serveConfirm: ConfirmFn is a bare
/// function pointer (same shape as AskFn), and the answer askAwait hands
/// back was duped on the answering thread with this same gpa.
var serve_gpa: ?std.mem.Allocator = null;

/// The serve-side ConfirmFn: puts one write-capable tool call to the browser
/// as a `confirm` control event on the run's own stream, then blocks this
/// connection thread until POST /api/ask answers "allow" or "deny", riding
/// the ask machinery above unchanged. Everything that fails to produce an
/// explicit "allow" — no stream, no free slot, a timeout, "deny" — refuses
/// the call: an unattended gate that waves writes through protects nothing,
/// and the model is told to take another path rather than left hanging.
fn serveConfirm(tool_name: []const u8, args_preview: []const u8) bool {
    const fd = run_stream_socket orelse return false;
    const id = askRegister(confirm_options) orelse return false;
    writeStreamEvent(fd, "confirm", .{ .id = id, .tool = tool_name, .args_preview = args_preview, .options = confirm_options });
    const answer = askAwait(id, serve_ask_timeout_ns) orelse return false;
    defer if (serve_gpa) |gpa| gpa.free(answer);
    return std.mem.eql(u8, answer, "allow");
}

const AskAnswerBody = struct { id: u64 = 0, answer: []const u8 = "" };

/// `POST /api/ask` answers a question a streaming run raised through
/// ask_user (see serveAsk). Body: {"id": n, "answer": "<one of the options>"}.
fn handleAsk(gpa: std.mem.Allocator, stream: std.Io.net.Stream, body: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const req = std.json.parseFromSliceLeaky(AskAnswerBody, arena_state.allocator(), body, .{ .ignore_unknown_fields = true }) catch {
        respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"bad request body\"}");
        return;
    };
    if (req.id == 0 or req.answer.len == 0) {
        respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"missing id or answer\"}");
        return;
    }
    switch (askResolve(gpa, req.id, req.answer)) {
        .ok => respond(stream, 200, "OK", "{\"ok\":true}"),
        .not_found => respond(stream, 404, "Not Found", "{\"ok\":false,\"error\":\"no such pending question (already answered, timed out, or never existed)\"}"),
        .bad_option => respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"answer must be one of the offered options\"}"),
        .out_of_memory => respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"out of memory\"}"),
    }
}

/// JSON `{"error":...}` body when the webui *descriptor* is absent from the
/// tools registry (wrong/empty `tools_dir`, zero manifests). Distinct from a
/// missing guest `.wasm`, which still wants `zig build tools`.
fn webuiMissingRegistryError(allocator: std.mem.Allocator, tools_dir: []const u8) ![]const u8 {
    const detail = try std.fmt.allocPrint(
        allocator,
        "webui tool not found in registry (tools_dir={s}). Check agent.tools_dir points at the *.tool.json manifests directory.",
        .{tools_dir},
    );
    defer allocator.free(detail);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("error");
    try s.write(detail);
    try s.endObject();
    return try out.toOwnedSlice();
}

/// JSON body when the webui descriptor exists but its wasm module cannot be read.
fn webuiMissingWasmError() []const u8 {
    return "{\"error\":\"webui wasm missing (run zig build tools)\"}";
}

/// Renders the web UI by calling the internal `webui` WASM tool and serves the
/// resulting HTML page.
/// Renders one of the page's files through the webui tool. Returns the body,
/// or responds with the failure and returns null: the caller only has to
/// decide how a successful body is sent.
fn renderWebui(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    cfg: *const config.Config,
    environ_map: *std.process.Environ.Map,
    path: []const u8,
    stream: std.Io.net.Stream,
) ?[]const u8 {
    const reg = registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir) catch |err| {
        log.log(.error_, "renderWebui path={s}: registry load failed: {s}", .{ path, @errorName(err) });
        respond(stream, 500, "Internal Server Error", "{\"error\":\"tools registry unavailable\"}");
        return null;
    };
    const tool = reg.get("webui") orelse {
        const body = webuiMissingRegistryError(arena, cfg.agent.tools_dir) catch {
            respond(stream, 500, "Internal Server Error", "{\"error\":\"webui tool not found in registry\"}");
            return null;
        };
        respond(stream, 500, "Internal Server Error", body);
        return null;
    };
    const wasm_bytes = std.Io.Dir.cwd().readFileAlloc(io, tool.wasm, gpa, .limited(1 << 20)) catch |err| {
        log.log(.error_, "renderWebui path={s}: wasm read failed: {s}", .{ path, @errorName(err) });
        respond(stream, 500, "Internal Server Error", webuiMissingWasmError());
        return null;
    };
    defer gpa.free(wasm_bytes);

    var sb = host.Sandbox{
        .gpa = gpa,
        .io = io,
        .root_dir = cfg.agent.sandbox_root,
        .network_allow = tool.network_allow,
        .environ_map = environ_map,
    };
    const mod = runtime.ToolModule.load(gpa, io, &sb, wasm_bytes) catch |err| {
        log.log(.error_, "renderWebui path={s}: wasm load failed: {s}", .{ path, @errorName(err) });
        respond(stream, 500, "Internal Server Error", "{\"error\":\"webui load failed\"}");
        return null;
    };
    defer mod.deinit();

    // The path is one of this server's own route literals, never anything a
    // request supplied, so it needs no escaping to sit inside this JSON.
    const req = std.fmt.allocPrint(arena, "{{\"path\":\"{s}\"}}", .{path}) catch {
        respond(stream, 500, "Internal Server Error", "{\"error\":\"out of memory\"}");
        return null;
    };
    const out = mod.executeTool(req) catch |err| {
        log.log(.error_, "renderWebui path={s}: wasm exec failed: {s}", .{ path, @errorName(err) });
        respond(stream, 500, "Internal Server Error", "{\"error\":\"webui render failed\"}");
        return null;
    };
    defer gpa.free(out);

    // Output: {"ok":true,"content_type":"...","body":"..."}
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, out, .{ .ignore_unknown_fields = true }) catch {
        respond(stream, 500, "Internal Server Error", "{\"error\":\"webui bad output\"}");
        return null;
    };
    const body = switch (parsed) {
        .object => |o| if (o.get("body")) |b| switch (b) {
            .string => |s| s,
            else => {
                respond(stream, 500, "Internal Server Error", "{\"error\":\"webui bad body\"}");
                return null;
            },
        } else {
            respond(stream, 500, "Internal Server Error", "{\"error\":\"webui no body\"}");
            return null;
        },
        else => {
            respond(stream, 500, "Internal Server Error", "{\"error\":\"webui bad output\"}");
            return null;
        },
    };
    // Copied into the arena: `parsed` borrows from `out`, which is freed on
    // the way out of this function.
    return arena.dupe(u8, body) catch null;
}

/// Renders through the tool once and keeps the bytes. Returns null only when
/// the render itself failed, in which case the caller has already responded.
fn renderWebuiCached(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    cfg: *const config.Config,
    environ_map: *std.process.Environ.Map,
    path: []const u8,
    cache: *RenderCache,
    stream: std.Io.net.Stream,
) ?[]const u8 {
    switch (cache.state.load(.acquire)) {
        .ready => return cache.body,
        .failed => {},
        .idle, .rendering => {},
    }
    const body = renderWebui(io, gpa, arena, cfg, environ_map, path, stream) orelse return null;
    // Only one thread publishes; the rest just used their own copy, which is
    // identical because the source is compiled in.
    if (cache.state.cmpxchgStrong(.idle, .rendering, .acq_rel, .acquire) == null) {
        if (gpa.dupe(u8, body)) |owned| {
            cache.body = owned;
            cache.state.store(.ready, .release);
        } else |_| {
            cache.state.store(.failed, .release);
        }
    }
    return body;
}

/// The page's stylesheet and script. Same tool, same sandbox, same size guard
/// as the markup; only the content type and the caching differ.
fn handleWebuiAsset(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: *const config.Config,
    environ_map: *std.process.Environ.Map,
    target: []const u8,
    accepts_gzip: bool,
    headers_raw: []const u8,
    stream: std.Io.net.Stream,
) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const is_css = std.mem.endsWith(u8, target, ".css");
    const is_boot = std.mem.endsWith(u8, target, "van-boot.js");
    const cache = if (is_css) &render_css else if (is_boot) &render_van_boot else &render_js;
    const gz = if (is_css) &gzip_css else if (is_boot) &gzip_van_boot else &gzip_js;
    const body = renderWebuiCached(io, gpa, arena, cfg, environ_map, target, cache, stream) orelse return;
    const content_type: []const u8 = if (is_css) "text/css; charset=utf-8" else "text/javascript; charset=utf-8";

    // These are compiled into the binary and change with every rebuild, so
    // they cannot carry a far-future cache lifetime — but re-sending the same
    // 187 KB of script on every single page load when nothing changed is the
    // other extreme. ETag lets a returning visitor confirm "still current" in
    // a bodyless 304 instead of paying for either side's mistake.
    var etag_buf: [16]u8 = undefined;
    const etag = etagFor(&etag_buf, body);
    if (ifNoneMatchHits(headers_raw, etag)) {
        var hbuf: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 304 Not Modified\r\nETag: {s}\r\nVary: Accept-Encoding\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n", .{etag}) catch return;
        rawhttp.writeAllFd(stream.socket.handle, hdr);
        return;
    }
    // 187 KB of script over a connection that closes afterwards is the single
    // largest cost of a first draw; compressed it is a fifth of that.
    const gzipped = if (accepts_gzip) gzipCached(gpa, gz, body) else null;
    const out = gzipped orelse body;
    const encoding: []const u8 = if (gzipped != null) "Content-Encoding: gzip\r\n" else "";
    var hbuf: [512]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n{s}ETag: {s}\r\nVary: Accept-Encoding\r\nCache-Control: no-cache\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n", .{ content_type, out.len, encoding, etag }) catch return;
    rawhttp.writeAllFd(stream.socket.handle, hdr);
    rawhttp.writeAllFd(stream.socket.handle, out);
}

fn handleWebui(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, environ_map: *std.process.Environ.Map, accepts_gzip: bool, headers_raw: []const u8, stream: std.Io.net.Stream) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = renderWebuiCached(io, gpa, arena, cfg, environ_map, "/", &render_page, stream) orelse return;
    respondHtmlGz(gpa, stream, body, accepts_gzip, headers_raw);
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
    accepts_gzip: bool,
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

    const body = toolText(io, gpa, arena, cfg, environ_map, "cmd_graph", args) catch |err| {
        log.log(.error_, "GET /api/runs args={s}: {s}", .{ args, @errorName(err) });
        respond(stream, 500, "Internal Server Error", "{\"error\":\"graph read failed\"}");
        return;
    };
    respondCompressible(arena, stream, accepts_gzip, body);
}

/// `GET /api/sessions` lists saved conversations; `GET /api/sessions/<id>`
/// returns one whole transcript. Answered natively rather than through a
/// plugin (the way `/api/runs` reaches cmd_graph) because session.zig already
/// owns this store on the native side, and a long transcript exceeds the
/// 64 KiB host arena a WASM tool reads through.
/// Byte weight of a transcript.
///
/// Must match what `session.listSessions` reports, because that is the number
/// the picker shows and the number the owner is looking at when they decide to
/// compact. Counting only `content` here meant Compact aimed at a smaller
/// figure than the one on screen and reported a result in a different unit: a
/// transcript full of tool calls could be "compacted" and barely move.
fn transcriptBytes(msgs: []const types.Message) usize {
    var n: usize = 0;
    for (msgs) |m| {
        if (m.content) |c| n += c.len;
        if (m.tool_calls) |calls| {
            for (calls) |tc| n += tc.arguments.len;
        }
    }
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

test "transcriptBytes counts tool call arguments, like the session listing" {
    // A turn that called a tool carries most of its weight in the arguments;
    // ignoring them made Compact aim at a number nobody was shown.
    const calls = [_]types.ToolCall{.{ .id = "1", .name = "read_file", .arguments = "x" ** 500 }};
    const msgs = [_]types.Message{
        .{ .role = .user, .content = "a" ** 10 },
        .{ .role = .assistant, .content = null, .tool_calls = &calls },
    };
    try std.testing.expectEqual(@as(usize, 510), transcriptBytes(&msgs));
}

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
            if (m.value_ptr.display) |disp| {
                s.objectField("display") catch return;
                s.write(disp) catch return;
            }
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
            if (m.value_ptr.cost_per_1m_input) |c| {
                s.objectField("cost_per_1m_input") catch return;
                s.write(c) catch return;
            }
            if (m.value_ptr.cost_per_1m_output) |c| {
                s.objectField("cost_per_1m_output") catch return;
                s.write(c) catch return;
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

const webui_plugins_dir = "tools/webui-plugins";
const webui_plugins_state = "state/webui_plugins.json";

const WebuiPlugin = struct {
    name: []const u8 = "",
    title: []const u8 = "",
    description: []const u8 = "",
    group: []const u8 = "Watch",
};

const WebuiPluginState = struct {
    enabled: []const []const u8 = &.{},
};

const WebuiPluginPost = struct {
    name: ?[]const u8 = null,
    enabled: ?bool = null,
};

/// Shared shape check for filesystem-facing identifiers (plugin names,
/// session ids): non-empty, bounded, and limited to characters that cannot
/// traverse a path. Traversal is refused outright, not sanitised.
fn isSlug(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

fn validPluginName(name: []const u8) bool {
    return isSlug(name);
}

test validPluginName {
    try std.testing.expect(validPluginName("activity"));
    try std.testing.expect(validPluginName("board-burndown"));
    try std.testing.expect(!validPluginName("../../etc/passwd"));
    try std.testing.expect(!validPluginName("a/b"));
    try std.testing.expect(!validPluginName("a.b"));
    try std.testing.expect(!validPluginName(""));
    try std.testing.expect(!validPluginName("x" ** 65));
}

/// Only these files are served from a plugin directory. Anything else it
/// happens to contain — notes, sources, a stray key — stays on disk. The list
/// is exact names rather than extensions on purpose: a plugin cannot serve
/// arbitrary files by naming them well, and adding a kind of asset is a
/// deliberate edit here.
fn pluginAssetType(file: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, file, "app.js")) return "text/javascript; charset=utf-8";
    if (std.mem.eql(u8, file, "app.css")) return "text/css; charset=utf-8";
    // A view that draws needs its art. The handler already reads the file as
    // bytes and writes them through verbatim, so nothing else has to change;
    // the page's CSP allows img-src 'self'.
    if (std.mem.eql(u8, file, "sprites.png")) return "image/png";
    return null;
}

test pluginAssetType {
    try std.testing.expect(pluginAssetType("app.js") != null);
    try std.testing.expect(pluginAssetType("app.css") != null);
    try std.testing.expectEqualStrings("image/png", pluginAssetType("sprites.png").?);
    try std.testing.expect(pluginAssetType("plugin.json") == null);
    try std.testing.expect(pluginAssetType("../app.js") == null);
    try std.testing.expect(pluginAssetType("secrets.env") == null);
    // Named exactly, so a lookalike is still refused.
    try std.testing.expect(pluginAssetType("other.png") == null);
    try std.testing.expect(pluginAssetType("../sprites.png") == null);
}

fn pluginEnabled(state: WebuiPluginState, name: []const u8) bool {
    for (state.enabled) |e| {
        if (std.mem.eql(u8, e, name)) return true;
    }
    return false;
}

/// Which plugins exist and which are turned on. A plugin is off until someone
/// turns it on: it contributes script to the page, so its presence on disk is
/// not consent to run it.
fn handleWebuiPlugins(
    io: std.Io,
    gpa: std.mem.Allocator,
    method: []const u8,
    body: []const u8,
    stream: std.Io.net.Stream,
) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw_state = std.Io.Dir.cwd().readFileAlloc(io, webui_plugins_state, arena, .limited(1 << 16)) catch "{}";
    var state = std.json.parseFromSliceLeaky(WebuiPluginState, arena, raw_state, .{ .ignore_unknown_fields = true }) catch WebuiPluginState{};

    if (std.mem.eql(u8, method, "POST")) {
        const req = std.json.parseFromSliceLeaky(WebuiPluginPost, arena, body, .{ .ignore_unknown_fields = true }) catch {
            respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"bad request\"}");
            return;
        };
        const name = req.name orelse {
            respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"missing name\"}");
            return;
        };
        if (!validPluginName(name)) {
            respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"bad plugin name\"}");
            return;
        }
        const on = req.enabled orelse !pluginEnabled(state, name);
        var next: std.ArrayList([]const u8) = .empty;
        for (state.enabled) |e| {
            if (std.mem.eql(u8, e, name)) continue;
            next.append(arena, e) catch {};
        }
        if (on) next.append(arena, name) catch {};
        state.enabled = next.items;

        var enc: std.Io.Writer.Allocating = .init(arena);
        std.json.Stringify.value(state, .{}, &enc.writer) catch {
            respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"out of memory\"}");
            return;
        };
        atomic_write.writeFile(io, std.Io.Dir.cwd(), webui_plugins_state, enc.written()) catch {
            respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"write failed\"}");
            return;
        };
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    s.beginObject() catch return;
    s.objectField("ok") catch return;
    s.write(true) catch return;
    s.objectField("plugins") catch return;
    s.beginArray() catch return;

    var dir = std.Io.Dir.cwd().openDir(io, webui_plugins_dir, .{ .iterate = true }) catch {
        s.endArray() catch return;
        s.endObject() catch return;
        respond(stream, 200, "OK", out.written());
        return;
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (!validPluginName(entry.name)) continue;
        const manifest_path = std.fmt.allocPrint(arena, "{s}/{s}/plugin.json", .{ webui_plugins_dir, entry.name }) catch continue;
        const manifest_raw = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, arena, .limited(1 << 16)) catch continue;
        var plugin = std.json.parseFromSliceLeaky(WebuiPlugin, arena, manifest_raw, .{ .ignore_unknown_fields = true }) catch continue;
        // The directory is the identity: a manifest naming itself something
        // else would serve assets from a path that does not exist.
        plugin.name = entry.name;
        const css_path = std.fmt.allocPrint(arena, "{s}/{s}/app.css", .{ webui_plugins_dir, entry.name }) catch continue;
        const has_css = std.Io.Dir.cwd().statFile(io, css_path, .{}) catch null;

        s.beginObject() catch return;
        s.objectField("name") catch return;
        s.write(plugin.name) catch return;
        s.objectField("title") catch return;
        s.write(if (plugin.title.len > 0) plugin.title else plugin.name) catch return;
        s.objectField("description") catch return;
        s.write(plugin.description) catch return;
        s.objectField("group") catch return;
        s.write(plugin.group) catch return;
        s.objectField("enabled") catch return;
        s.write(pluginEnabled(state, entry.name)) catch return;
        s.objectField("has_css") catch return;
        s.write(has_css != null) catch return;
        s.endObject() catch return;
    }
    s.endArray() catch return;
    s.endObject() catch return;
    respond(stream, 200, "OK", out.written());
}

/// `GET /webui/plugins/<name>/app.js|app.css`. Served from disk rather than
/// embedded: a plugin can be dropped in without rebuilding clanker, which is
/// the point of it being a plugin. Only an enabled plugin's assets are served,
/// so turning one off actually stops its code reaching the browser.
fn handleWebuiPluginAsset(io: std.Io, gpa: std.mem.Allocator, target: []const u8, accepts_gzip: bool, stream: std.Io.net.Stream) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rest = target["/webui/plugins/".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse {
        respond(stream, 404, "Not Found", "{\"error\":\"no such plugin asset\"}");
        return;
    };
    const name = rest[0..slash];
    const file = rest[slash + 1 ..];
    if (!validPluginName(name)) {
        respond(stream, 400, "Bad Request", "{\"error\":\"bad plugin name\"}");
        return;
    }
    const content_type = pluginAssetType(file) orelse {
        respond(stream, 404, "Not Found", "{\"error\":\"no such plugin asset\"}");
        return;
    };

    const raw_state = std.Io.Dir.cwd().readFileAlloc(io, webui_plugins_state, arena, .limited(1 << 16)) catch "{}";
    const state = std.json.parseFromSliceLeaky(WebuiPluginState, arena, raw_state, .{ .ignore_unknown_fields = true }) catch WebuiPluginState{};
    if (!pluginEnabled(state, name)) {
        respond(stream, 404, "Not Found", "{\"error\":\"plugin is not enabled\"}");
        return;
    }

    const path = std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ webui_plugins_dir, name, file }) catch {
        respond(stream, 500, "Internal Server Error", "{\"error\":\"out of memory\"}");
        return;
    };
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch {
        respond(stream, 404, "Not Found", "{\"error\":\"no such plugin asset\"}");
        return;
    };
    // Re-read from disk on every request (see the comment above), so there is
    // nothing stable to key a compression cache on. Compressed fresh each
    // time instead, same as respondCompressible, and skipped below a
    // packet's worth where gzip's overhead would outweigh the saving. sprites.png
    // is already compressed, so gzipping it again would only cost CPU.
    const is_image = std.mem.eql(u8, content_type, "image/png");
    const worth_it = accepts_gzip and !is_image and bytes.len >= 1024;
    const gzipped = if (worth_it) gzipAlloc(arena, bytes, .default) else null;
    const out = gzipped orelse bytes;
    const encoding: []const u8 = if (gzipped != null) "Content-Encoding: gzip\r\n" else "";
    var hbuf: [512]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n{s}Vary: Accept-Encoding\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n", .{ content_type, out.len, encoding }) catch return;
    rawhttp.writeAllFd(stream.socket.handle, hdr);
    rawhttp.writeAllFd(stream.socket.handle, out);
}

/// `GET /api/janitor` — how much litter is lying around, so the office view can
/// show the janitor working when there is work and sitting down when there is
/// not. Read-only: it never deletes. `clanker janitor --yes` is the only thing
/// that removes anything.
fn handleJanitor(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, stream: std.Io.net.Stream) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const candidates = janitor_mod.scan(io, arena, cfg.agent.state_dir) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"could not scan\"}");
        return;
    };
    var total: u64 = 0;
    for (candidates) |c| total += c.bytes;

    var out: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &out.writer };
    s.beginObject() catch return;
    s.objectField("ok") catch return;
    s.write(true) catch return;
    s.objectField("items") catch return;
    s.write(candidates.len) catch return;
    s.objectField("bytes") catch return;
    s.write(total) catch return;
    s.endObject() catch return;
    respond(stream, 200, "OK", out.written());
}

/// The shared Kanban board.
///
/// The logic lives in the `board` WASM tool, not here. It used to be four
/// hundred lines of application code in this file, which meant the board was a
/// thing only this HTTP endpoint could touch: an agent could not read its own
/// board or move a card on it. Delegating is the same shape /api/runs uses for
/// cmd_graph, and it leaves one implementation for the page and the agent to
/// share.
fn handleBoard(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: *const config.Config,
    environ_map: *std.process.Environ.Map,
    method: []const u8,
    target: []const u8,
    body: []const u8,
    stream: std.Io.net.Stream,
) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A GET is the tool's "list", and it names the room the same way the chat
    // endpoints do; a POST passes the request body through as the tool's input,
    // so the op set is the tool's and this file does not get a second opinion
    // about what a valid board operation is.
    var room: []const u8 = "";
    if (std.mem.indexOfScalar(u8, target, '?')) |q| {
        var params = std.mem.splitScalar(u8, target[q + 1 ..], '&');
        while (params.next()) |pair| {
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                if (std.mem.eql(u8, pair[0..eq], "room"))
                    room = percentDecode(arena, pair[eq + 1 ..]) catch pair[eq + 1 ..];
            }
        }
    }
    const list_args = if (room.len == 0) "{\"op\":\"list\"}" else blk: {
        var w: std.Io.Writer.Allocating = .init(arena);
        var s = std.json.Stringify{ .writer = &w.writer };
        s.beginObject() catch break :blk "{\"op\":\"list\"}";
        s.objectField("op") catch break :blk "{\"op\":\"list\"}";
        s.write("list") catch break :blk "{\"op\":\"list\"}";
        s.objectField("room") catch break :blk "{\"op\":\"list\"}";
        s.write(room) catch break :blk "{\"op\":\"list\"}";
        s.endObject() catch break :blk "{\"op\":\"list\"}";
        break :blk w.written();
    };
    const args = if (std.mem.eql(u8, method, "POST")) body else list_args;
    const out = toolJson(io, gpa, arena, cfg, environ_map, "board", args) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"board tool unavailable\"}");
        return;
    };
    // The tool reports its own refusals as {"ok":false,...}; a refusal is a bad
    // request, not a server error.
    const status: u16 = if (std.mem.startsWith(u8, std.mem.trimStart(u8, out, " \t\r\n"), "{\"ok\":false")) 400 else 200;
    respond(stream, status, if (status == 200) "OK" else "Bad Request", out);
}

const goals_path = "state/goals.json";

/// Adding a goal and changing one's status, the two things the `goal` tool and
/// `clanker run --goal` already assume someone can do. One POST shape covers
/// both: an objective creates, an id updates.
fn handleGoalWrite(io: std.Io, arena: std.mem.Allocator, body: []const u8, stream: std.Io.net.Stream) void {
    const req = std.json.parseFromSliceLeaky(GoalPost, arena, body, .{ .ignore_unknown_fields = true }) catch {
        respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"bad request\"}");
        return;
    };
    const raw = std.Io.Dir.cwd().readFileAlloc(io, goals_path, arena, .limited(1 << 20)) catch "[]";
    var list: std.ArrayList(StoredGoal) = .empty;
    if (std.json.parseFromSliceLeaky([]StoredGoal, arena, raw, .{ .ignore_unknown_fields = true }) catch null) |existing| {
        list.appendSlice(arena, existing) catch {
            respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"out of memory\"}");
            return;
        };
    }

    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    if (req.objective) |objective| {
        const obj = std.mem.trim(u8, objective, " \t\r\n");
        const crit = std.mem.trim(u8, req.completion_criterion orelse "", " \t\r\n");
        if (obj.len == 0 or obj.len > 2000) {
            respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"objective must be 1-2000 characters\"}");
            return;
        }
        if (crit.len == 0) {
            // A goal with no way to tell it is met is a wish; the tool that
            // writes this file requires one too.
            respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"a completion criterion is required\"}");
            return;
        }
        const id = std.fmt.allocPrint(arena, "{d}", .{std.Io.Timestamp.now(io, .real).nanoseconds}) catch {
            respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"out of memory\"}");
            return;
        };
        list.append(arena, .{
            .id = id,
            .objective = obj,
            .completion_criterion = crit,
            .created = now,
            .updated = now,
        }) catch {
            respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"out of memory\"}");
            return;
        };
    } else if (req.id) |id| {
        var kept: std.ArrayList(StoredGoal) = .empty;
        var hit = false;
        for (list.items) |g| {
            if (!std.mem.eql(u8, g.id, id)) {
                kept.append(arena, g) catch continue;
                continue;
            }
            hit = true;
            if (req.remove orelse false) continue;
            var updated = g;
            if (req.status) |s| {
                if (!validGoalStatus(s)) {
                    respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"status must be active, done or abandoned\"}");
                    return;
                }
                updated.status = s;
            }
            updated.updated = now;
            kept.append(arena, updated) catch continue;
        }
        if (!hit) {
            respond(stream, 404, "Not Found", "{\"ok\":false,\"error\":\"no such goal\"}");
            return;
        }
        list = kept;
    } else {
        respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"need an objective or an id\"}");
        return;
    }

    var enc: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(list.items, .{}, &enc.writer) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"out of memory\"}");
        return;
    };
    atomic_write.writeFile(io, std.Io.Dir.cwd(), goals_path, enc.written()) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"write failed\"}");
        return;
    };

    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.writeAll("{\"ok\":true,\"goals\":") catch return;
    std.json.Stringify.value(list.items, .{}, &out.writer) catch return;
    out.writer.writeAll("}") catch return;
    respond(stream, 200, "OK", out.written());
}

/// `GET /api/logs` lists the log files; `GET /api/logs/<name>` returns the tail
/// of one. Names are matched against the listing rather than sanitised, so a
/// crafted name cannot describe a path at all.
fn handleLogs(io: std.Io, gpa: std.mem.Allocator, target: []const u8, accepts_gzip: bool, stream: std.Io.net.Stream) void {
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
        respondCompressible(arena, stream, accepts_gzip, out.written());
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
    accepts_gzip: bool,
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
            // Moving between folders and renaming are the same kind of edit,
            // so they share the endpoint; a body may carry either or both.
            if (req.workspace) |ws| {
                if (!validWorkspace(ws)) {
                    respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"workspace must be 0-64 characters and contain no separators\"}");
                    return;
                }
                session.setWorkspace(io, gpa, arena, std.Io.Dir.cwd(), id, ws) catch {
                    respond(stream, 404, "Not Found", "{\"ok\":false,\"error\":\"no such session\"}");
                    return;
                };
                if (req.title == null) {
                    respond(stream, 200, "OK", "{\"ok\":true}");
                    return;
                }
            }
            const title = req.title orelse {
                respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"missing title or workspace\"}");
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
        respondCompressible(arena, stream, accepts_gzip, one);
        return;
    }
    if (rest.len != 0) {
        respond(stream, 404, "Not Found", "{\"error\":\"no such endpoint\"}");
        return;
    }

    const list = session.listSessions(io, arena, std.Io.Dir.cwd()) catch |err| {
        log.log(.error_, "GET /api/sessions: list failed: {s}", .{@errorName(err)});
        respond(stream, 500, "Internal Server Error", "{\"error\":\"session list failed\"}");
        return;
    };
    const listing = sessionListJSON(arena, list) catch |err| {
        log.log(.error_, "GET /api/sessions: encode failed: {s}", .{@errorName(err)});
        respond(stream, 500, "Internal Server Error", "{\"error\":\"session encode failed\"}");
        return;
    };
    respondCompressible(arena, stream, accepts_gzip, listing);
}

/// Session ids reach the filesystem as a path fragment, so they are restricted
/// to the shapes this server itself mints: a UUID from the browser, or the
/// `sess-<base36>` fallback. Anything with a separator or a dot is refused
/// before it can be used to walk out of `state/sessions/`.
fn validSessionId(id: []const u8) bool {
    return isSlug(id);
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
        try s.objectField("workspace");
        try s.write(m.workspace);
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
            respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"out of memory\"}");
            return;
        };
    }

    const out = toolText(io, gpa, arena, cfg, environ_map, "cmd_plugins", args) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"plugin read failed\"}");
        return;
    };
    respond(stream, 200, "OK", out);
}

/// A workspace is a folder name shown in the rail and stored in the session
/// file, so it is restricted the way a session id is. It is never a path —
/// nothing joins it to the filesystem — but it is displayed, sorted and
/// compared, and a name carrying separators or control characters would make
/// the rail lie about what is nested in what.
fn validWorkspace(name: []const u8) bool {
    if (name.len > 64) return false;
    for (name) |c| {
        if (c < 0x20 or c == 0x7f) return false;
        if (c == '/' or c == '\\') return false;
    }
    return true;
}

test validWorkspace {
    try std.testing.expect(validWorkspace(""));
    try std.testing.expect(validWorkspace("research"));
    try std.testing.expect(validWorkspace("web ui"));
    try std.testing.expect(!validWorkspace("a/b"));
    try std.testing.expect(!validWorkspace("a\\b"));
    try std.testing.expect(!validWorkspace("a\nb"));
    try std.testing.expect(!validWorkspace("x" ** 65));
}

const SessionPatchBody = struct {
    title: ?[]const u8 = null,
    /// Absent means "leave it where it is"; "" means the default folder.
    workspace: ?[]const u8 = null,
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

    var reg = registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir) catch |err| {
        log.log(.error_, "POST /api/plugins/config: registry load failed: {s}", .{@errorName(err)});
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
            respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"out of memory\"}");
            return;
        };
    }
    var out_store = store.object.clone(arena) catch store.object;
    out_store.put(arena, name, .{ .object = merged }) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"out of memory\"}");
        return;
    };

    var doc: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &doc.writer, .options = .{} };
    s.write(std.json.Value{ .object = out_store }) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"out of memory\"}");
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
const GoalPost = struct {
    objective: ?[]const u8 = null,
    completion_criterion: ?[]const u8 = null,
    id: ?[]const u8 = null,
    status: ?[]const u8 = null,
    remove: ?bool = null,
};

const StoredGoal = struct {
    id: []const u8,
    objective: []const u8,
    completion_criterion: []const u8 = "",
    proof: []const u8 = "",
    boundaries: []const u8 = "",
    stop_rule: []const u8 = "",
    status: []const u8 = "active",
    created: i64 = 0,
    updated: i64 = 0,
};

/// A goal's status is one of three words. Anything else is refused rather
/// than written, so the file cannot grow states nothing knows how to read.
fn validGoalStatus(s: []const u8) bool {
    return std.mem.eql(u8, s, "active") or std.mem.eql(u8, s, "done") or std.mem.eql(u8, s, "abandoned");
}

test validGoalStatus {
    try std.testing.expect(validGoalStatus("active"));
    try std.testing.expect(validGoalStatus("done"));
    try std.testing.expect(validGoalStatus("abandoned"));
    try std.testing.expect(!validGoalStatus("Active"));
    try std.testing.expect(!validGoalStatus(""));
    try std.testing.expect(!validGoalStatus("deleted; drop table"));
}

fn handleGoals(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, method: []const u8, body: []const u8, stream: std.Io.net.Stream) void {
    if (!cfg.modules.goal) {
        respond(stream, 404, "Not Found", "{\"error\":\"goal module disabled\"}");
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (std.mem.eql(u8, method, "POST")) {
        handleGoalWrite(io, arena, body, stream);
        return;
    }

    const raw = std.Io.Dir.cwd().readFileAlloc(io, "state/goals.json", arena, .limited(1 << 20)) catch {
        // No file yet is the ordinary state on a fresh checkout, not an error.
        respond(stream, 200, "OK", "{\"ok\":true,\"goals\":[]}");
        return;
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.writeAll("{\"ok\":true,\"goals\":") catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"out of memory\"}");
        return;
    };
    // Passed through verbatim: it is already the array this endpoint returns,
    // and re-encoding it would only add a way for the two to drift.
    out.writer.writeAll(std.mem.trim(u8, raw, " \t\r\n")) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"out of memory\"}");
        return;
    };
    out.writer.writeAll("}") catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"out of memory\"}");
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
    // A goal-only POST is enough to start work: taskWithGoal fills the body.
    if (req.task.len == 0 and req.goal.len == 0) {
        respond(stream, 400, "Bad Request", "{\"ok\":false,\"error\":\"missing task\"}");
        return;
    }

    const goal_id: ?[]const u8 = if (req.goal.len > 0) req.goal else null;
    const task_text = resolveRunTask(
        arena,
        io,
        std.Io.Dir.cwd(),
        req.task,
        goal_id,
        cfg.modules.goal and goal_id == null,
    ) catch {
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"goal resolve failed\"}");
        return;
    };
    if (std.mem.trim(u8, task_text, " \t\r\n").len == 0) {
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
    var reg = registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir) catch |err| {
        log.log(.error_, "POST /api/run: registry load failed: {s}", .{@errorName(err)});
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"tools registry unavailable\"}");
        return;
    };
    const tool_defs = reg.toToolDefs(arena) catch |err| {
        log.log(.error_, "POST /api/run: tool defs failed: {s}", .{@errorName(err)});
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"tool defs failed\"}");
        return;
    };

    var a = agent.Agent.init(&ctx, arena, provider, cfg, &reg, tool_defs) catch |err| {
        log.log(.error_, "POST /api/run: agent init failed: {s}", .{@errorName(err)});
        respond(stream, 500, "Internal Server Error", "{\"ok\":false,\"error\":\"agent init failed\"}");
        return;
    };
    defer a.deinit();
    a.subagent_runner = if (cfg.modules.subagents) &subagent.runNested else null;
    // Plan mode makes the run a proposal: the agent loop refuses
    // write-capable tools and the system prompt says why, so the answer is
    // a plan the browser renders with an Apply action.
    a.plan_mode = req.plan;
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
    // Held from the load below through both saveSession calls further down:
    // serve runs one thread per connection, so two requests naming the same
    // session (a double-submit, two tabs) would otherwise both load the same
    // messages, both append their own turn, and the second save would
    // silently discard the first turn's messages (a lost update). The lock
    // is per session id, so unrelated sessions never contend.
    var session_lock: filelock.Guard = .{ .io = io };
    defer session_lock.release();
    if (has_session) {
        std.Io.Dir.cwd().createDirPath(io, "state/sessions") catch {};
        session_lock = filelock.acquire(io, std.Io.Dir.cwd(), "state/sessions", req.session, gpa);
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
        rawhttp.writeAllFd(stream.socket.handle, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n");
        run_stream_socket = stream.socket.handle;
        defer run_stream_socket = null;
        // With a browser on the other end of this stream, ask_user has
        // somebody to ask: the question goes down as an `ask` control event
        // and the answer comes back through POST /api/ask. Streaming runs
        // only — without the stream there is no channel to carry a question.
        serve_ask_timeout_ns = @as(u64, cfg.agent.ask_timeout_seconds) * std.time.ns_per_s;
        a.ask_fn = &serveAsk;
        // Confirm-before-write: with a browser on the stream, write-capable
        // tool calls wait for its allow/deny (`browser` and `always` both
        // cover this surface). Non-streaming runs stay ungated like ask —
        // without the stream there is no channel to carry the question.
        if (cfg.agent.confirm_writes != .never) a.confirm_fn = &serveConfirm;
        a.on_token = &runStreamDelta;
        a.on_tool_call = &runStreamToolCall;
        a.on_tool_result = &runStreamToolResult;
        const t0 = std.Io.Timestamp.now(io, .awake);
        const resp = a.run(&messages, task_text, &err_detail) catch |err| {
            const detail = err_detail orelse @errorName(err);
            writeStreamEvent(stream.socket.handle, "error", .{ .message = detail });
            return;
        };
        // When modules.streaming is off the agent never invokes on_token,
        // so nothing was streamed — write the answer directly or the client
        // would receive an empty body (just the trailer) for a successful run.
        if (!cfg.modules.streaming) {
            if (resp.message.content) |c| rawhttp.writeAllFd(stream.socket.handle, c);
        }
        if (has_session) {
            const title_src = if (req.task.len > 0) req.task else task_text;
            const title = title_src[0..@min(title_src.len, 60)];
            const updated: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
            session.saveSession(io, gpa, arena, std.Io.Dir.cwd(), .{
                .id = req.session,
                .title = title,
                .messages = messages.items,
                .created = created,
                .updated = updated,
            }) catch |err| log.log(.error_, "session '{s}' not saved: {s}", .{ req.session, @errorName(err) });
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

    const resp = a.run(&messages, task_text, &err_detail) catch |err| {
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
        const title_src = if (req.task.len > 0) req.task else task_text;
        const title = title_src[0..@min(title_src.len, 60)];
        const updated: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
        session.saveSession(io, gpa, arena, std.Io.Dir.cwd(), .{
            .id = req.session,
            .title = title,
            .messages = messages.items,
            .created = created,
            .updated = updated,
        }) catch |err| log.log(.error_, "session '{s}' not saved: {s}", .{ req.session, @errorName(err) });
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
    rawhttp.writeAllFd(stream.socket.handle, hdr);
    rawhttp.writeAllFd(stream.socket.handle, body);
}

/// The web UI ships its CSS and JS inline in one embedded file, so the policy
/// allows inline styles and scripts but no external origin: a page fronting
/// `/api/run` (which executes agent tools) must never be able to pull code from
/// a third party.
// No inline script or style survives in the page, so neither needs
// 'unsafe-inline'. style-src-attr keeps the one thing that still sets styles
// from script (the composer's auto-grow) working without reopening inline
// <style> blocks.
const webui_csp = "default-src 'none'; script-src 'self'; style-src 'self'; style-src-attr 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

/// The page, compressed when the client will take it. This is the response
/// that blocks the first draw, so the 21 KB it used to send uncompressed was
/// paid before anything could be painted.
///
/// `no-store` meant refetching and recompressing that same body on every
/// single visit, even seconds apart, since the page cannot be cached at all.
/// ETag lets an unchanged reload confirm freshness with a 304 instead of a
/// full response, while still picking up a rebuild immediately: the hash is
/// taken from the actual served body, which hot-reload replaces process-wide.
fn respondHtmlGz(gpa: std.mem.Allocator, stream: std.Io.net.Stream, body: []const u8, accepts_gzip: bool, headers_raw: []const u8) void {
    var etag_buf: [16]u8 = undefined;
    const etag = etagFor(&etag_buf, body);
    if (ifNoneMatchHits(headers_raw, etag)) {
        var hbuf: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 304 Not Modified\r\nETag: {s}\r\nVary: Accept-Encoding\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n", .{etag}) catch return;
        rawhttp.writeAllFd(stream.socket.handle, hdr);
        return;
    }
    const gzipped = if (accepts_gzip) gzipCached(gpa, &gzip_page, body) else null;
    const out = gzipped orelse body;
    const encoding: []const u8 = if (gzipped != null) "Content-Encoding: gzip\r\n" else "";
    var hbuf: [4096]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\n{s}ETag: {s}\r\nVary: Accept-Encoding\r\nContent-Security-Policy: {s}\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n", .{ out.len, encoding, etag, webui_csp }) catch return;
    rawhttp.writeAllFd(stream.socket.handle, hdr);
    rawhttp.writeAllFd(stream.socket.handle, out);
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

/// A rendered web UI asset, kept for the life of the process.
///
/// The markup, stylesheet and script are compiled into this binary, so they
/// cannot change while it runs — and when a rebuild changes them, hot reload
/// replaces the process, so a stale entry is not reachable. Without this every
/// request paid for reading the tool's wasm off disk, instantiating a zwasm
/// module, and JSON-decoding the result: 348ms and 187 KB for app.js on this
/// machine, on a connection the server closes immediately afterwards.
///
/// Races are resolved the way GzipCache resolves them: whoever moves the state
/// out of `idle` publishes, and a thread arriving meanwhile renders it the slow
/// way for that one request rather than blocking. Rendering twice is wasteful,
/// never wrong.
const RenderCache = struct {
    state: std.atomic.Value(State) = .init(.idle),
    /// Only read after `state` reads `.ready`.
    body: []const u8 = &.{},

    const State = enum(u8) { idle, rendering, ready, failed };
};

var render_page: RenderCache = .{};
var render_css: RenderCache = .{};
var render_js: RenderCache = .{};
var render_van_boot: RenderCache = .{};

var gzip_page: GzipCache = .{};
var gzip_css: GzipCache = .{};
var gzip_js: GzipCache = .{};
var gzip_van_boot: GzipCache = .{};
var gzip_van: GzipCache = .{};
var gzip_vanui: GzipCache = .{};
var gzip_d3dag: GzipCache = .{};
var gzip_hljs: GzipCache = .{};

/// A JSON body, gzipped when the client takes it and the saving is worth the
/// work. Uncached on purpose: these bodies are per-request (a session list, a
/// run graph), so a cache keyed on nothing would serve one caller's answer to
/// another. Compression failure is not an error, it just sends the bytes.
fn respondCompressible(arena: std.mem.Allocator, stream: std.Io.net.Stream, accepts_gzip: bool, body: []const u8) void {
    // Below roughly a packet's worth, gzip costs more than it saves.
    const worth_it = accepts_gzip and body.len >= 1024;
    // .default, not .best: this body is unique to this request (a session
    // list, a run graph) and thrown away right after, so extra compression
    // effort here is paid on every single request rather than once.
    const gzipped = if (worth_it) gzipAlloc(arena, body, .default) else null;
    const out = gzipped orelse body;
    const encoding: []const u8 = if (gzipped != null) "Content-Encoding: gzip\r\n" else "";
    var hbuf: [4096]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n{s}Vary: Accept-Encoding\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n", .{ out.len, encoding }) catch return;
    rawhttp.writeAllFd(stream.socket.handle, hdr);
    rawhttp.writeAllFd(stream.socket.handle, out);
}

fn gzipCached(gpa: std.mem.Allocator, cache: *GzipCache, raw: []const u8) ?[]const u8 {
    switch (cache.state.load(.acquire)) {
        .ready => return cache.body,
        .failed, .compressing => return null,
        .idle => {},
    }
    if (cache.state.cmpxchgStrong(.idle, .compressing, .acq_rel, .acquire) != null) return null;

    // .best, not .default: this runs once per process and the result is
    // reused for every request after, so the extra CPU here is paid once
    // while the smaller body is what every visitor actually downloads.
    const compressed = gzipAlloc(gpa, raw, .best) orelse {
        cache.state.store(.failed, .release);
        return null;
    };
    // Published in this order so a thread that reads `.ready` is guaranteed to
    // see the finished slice.
    cache.body = compressed;
    cache.state.store(.ready, .release);
    return compressed;
}

fn gzipAlloc(gpa: std.mem.Allocator, raw: []const u8, level: std.compress.flate.Compress.Options) ?[]const u8 {
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
    var compress = std.compress.flate.Compress.init(&out, window, .gzip, level) catch {
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

/// Serves a vendored, build-time-embedded JS asset (webui/vendor/*). They are
/// gzipped when the client asks — they are the two largest bodies this server
/// sends, and the page is routinely opened from another machine on the LAN.
///
/// Cached for an hour and revalidated by ETag after that, rather than the
/// `immutable, max-age=31536000` this used to send: that path is not content-
/// hashed, so a vendored library upgrade would have left a returning browser
/// serving the old file, unvalidated, for up to a year.
fn respondJs(gpa: std.mem.Allocator, stream: std.Io.net.Stream, body: []const u8, cache: *GzipCache, accepts_gzip: bool, headers_raw: []const u8) void {
    var etag_buf: [16]u8 = undefined;
    const etag = etagFor(&etag_buf, body);
    if (ifNoneMatchHits(headers_raw, etag)) {
        var hbuf: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 304 Not Modified\r\nETag: {s}\r\nVary: Accept-Encoding\r\nCache-Control: public, max-age=3600, must-revalidate\r\nConnection: close\r\n\r\n", .{etag}) catch return;
        rawhttp.writeAllFd(stream.socket.handle, hdr);
        return;
    }
    var hbuf: [4096]u8 = undefined;
    const gzipped = if (accepts_gzip) gzipCached(gpa, cache, body) else null;
    const out = gzipped orelse body;
    const encoding = if (gzipped != null) "Content-Encoding: gzip\r\n" else "";
    const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\nContent-Type: text/javascript; charset=utf-8\r\nContent-Length: {d}\r\n{s}ETag: {s}\r\nVary: Accept-Encoding\r\nCache-Control: public, max-age=3600, must-revalidate\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n", .{ out.len, encoding, etag }) catch return;
    rawhttp.writeAllFd(stream.socket.handle, hdr);
    rawhttp.writeAllFd(stream.socket.handle, out);
}

/// True when the request's Accept-Encoding lists gzip. Scoped to that header's
/// own line so a request target that happens to contain "gzip" cannot flip it.
/// The (trimmed) value of the first header line named `name`, matched
/// case-insensitively on the header name only.
fn headerValue(headers_raw: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers_raw, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

/// True when the request carries an `Origin` header naming something other
/// than this server itself. Browsers attach `Origin` to every cross-site
/// fetch/XHR/form submission (and to same-origin ones too, which is why a
/// same-host origin is accepted alongside the missing-header case rather than
/// rejected as "not GET/HEAD").
fn crossOriginRequest(headers_raw: []const u8, port: u16) bool {
    const origin = headerValue(headers_raw, "origin") orelse return false;
    var buf: [40]u8 = undefined;
    const want_ip = std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}", .{port}) catch return true;
    if (std.mem.eql(u8, origin, want_ip)) return false;
    var buf2: [40]u8 = undefined;
    const want_host = std.fmt.bufPrint(&buf2, "http://localhost:{d}", .{port}) catch return true;
    if (std.mem.eql(u8, origin, want_host)) return false;
    return true;
}

test "crossOriginRequest allows same-origin and no-Origin requests, refuses others" {
    try std.testing.expect(!crossOriginRequest("POST /api/run HTTP/1.1\r\nHost: x\r\n", 4173));
    try std.testing.expect(!crossOriginRequest("POST /api/run HTTP/1.1\r\nOrigin: http://127.0.0.1:4173\r\n", 4173));
    try std.testing.expect(!crossOriginRequest("POST /api/run HTTP/1.1\r\nOrigin: http://localhost:4173\r\n", 4173));
    try std.testing.expect(crossOriginRequest("POST /api/run HTTP/1.1\r\nOrigin: http://evil.example:4173\r\n", 4173));
    try std.testing.expect(crossOriginRequest("POST /api/run HTTP/1.1\r\nOrigin: http://127.0.0.1:9999\r\n", 4173));
    try std.testing.expect(crossOriginRequest("POST /api/run HTTP/1.1\r\nOrigin: null\r\n", 4173));
}

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

/// A weak content hash formatted as a quoted ETag value. Cheap enough (CRC32
/// over at most ~200 KB) to compute fresh per request instead of caching it:
/// it is orders of magnitude faster than the gzip pass already paid for above.
fn etagFor(buf: []u8, body: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "\"{x}\"", .{std.hash.Crc32.hash(body)}) catch unreachable;
}

/// True when the request's If-None-Match lists this exact ETag, meaning the
/// client already has this body cached and a 304 can skip resending it.
fn ifNoneMatchHits(headers_raw: []const u8, etag: []const u8) bool {
    var lines = std.mem.splitSequence(u8, headers_raw, "\r\n");
    while (lines.next()) |line| {
        if (!std.ascii.startsWithIgnoreCase(line, "if-none-match:")) continue;
        var values = std.mem.tokenizeAny(u8, line["if-none-match:".len..], " ,");
        while (values.next()) |v| {
            if (std.mem.eql(u8, v, etag)) return true;
        }
    }
    return false;
}

test "ifNoneMatchHits matches only its own header line and exact value" {
    try std.testing.expect(ifNoneMatchHits("GET / HTTP/1.1\r\nIf-None-Match: \"abc\", \"def\"\r\n", "\"def\""));
    try std.testing.expect(!ifNoneMatchHits("GET / HTTP/1.1\r\nIf-None-Match: \"abc\"\r\n", "\"def\""));
    try std.testing.expect(!ifNoneMatchHits("GET /x HTTP/1.1\r\nHost: If-None-Match: \"def\"\r\n", "\"def\""));
    try std.testing.expect(!ifNoneMatchHits("", "\"def\""));
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

test "a turn that read a large file does not wipe the conversation" {
    // The REPL's own budget, against a turn the size of one read_file call on
    // this project's largest source file. Under the old 4K budget this left
    // nothing but the system message and the next turn started blind.
    const allocator = std.testing.allocator;
    const big = try allocator.alloc(u8, 250 * 1024);
    defer allocator.free(big);
    @memset(big, 'x');

    var messages: std.ArrayList(types.Message) = .empty;
    defer messages.deinit(allocator);
    try messages.append(allocator, .{ .role = .system, .content = "system" });
    try messages.append(allocator, .{ .role = .user, .content = "implement the plan" });
    try messages.append(allocator, .{ .role = .tool, .content = big });
    try messages.append(allocator, .{ .role = .assistant, .content = "here is the plan" });

    compactMessages(&messages, max_turn_tokens);
    try std.testing.expectEqual(types.Role.system, messages.items[0].role);
    try std.testing.expectEqualStrings("here is the plan", messages.items[messages.items.len - 1].content.?);
    try std.testing.expect(messages.items.len >= 3);
}

test "flags take their value in either form" {
    const a = try parse(&.{ "clanker", "serve", "--port=9099" }, null);
    try std.testing.expectEqual(@as(u16, 9099), a.port);
    const b = try parse(&.{ "clanker", "serve", "--port", "9099" }, null);
    try std.testing.expectEqual(@as(u16, 9099), b.port);
    // An empty value is missing, not empty.
    try std.testing.expectError(error.MissingArg, parse(&.{ "clanker", "serve", "--port=" }, null));
}

test "a flag the command does not take is refused, not ignored" {
    var diag: []const u8 = "";
    try std.testing.expectError(error.FlagNotForCommand, parse(&.{ "clanker", "stats", "--model", "x" }, &diag));
    try std.testing.expectEqualStrings("--model", diag);
    // The same flag on a command that does take it is fine.
    const ok = try parse(&.{ "clanker", "run", "--model", "x", "do a thing" }, null);
    try std.testing.expectEqualStrings("x", ok.model.?);
}

test "--help after a command asks about that command" {
    const opts = try parse(&.{ "clanker", "run", "--help" }, null);
    try std.testing.expectEqual(Command.help, opts.command);
    try std.testing.expectEqual(Command.run, opts.help_for.?);
    // Alone, it is the whole list.
    const all = try parse(&.{ "clanker", "--help" }, null);
    try std.testing.expectEqual(Command.help, all.command);
    try std.testing.expect(all.help_for == null);
}

test "a bare prompt runs, a mistyped command does not" {
    const opts = try parse(&.{ "clanker", "fix the failing eval please" }, null);
    try std.testing.expectEqual(Command.run, opts.command);
    try std.testing.expectEqualStrings("fix the failing eval please", opts.task.?);
    // A single short word is a command that does not exist, not a prompt:
    // silently running "relp" as a task would hide the typo.
    try std.testing.expectError(error.UnknownCommand, parse(&.{ "clanker", "relp" }, null));
}

test "-m and -c are the short forms every other agent CLI uses" {
    const opts = try parse(&.{ "clanker", "run", "-m", "zai/glm-5.2", "-c", "keep going" }, null);
    try std.testing.expectEqualStrings("zai/glm-5.2", opts.model.?);
    try std.testing.expect(opts.continue_last);
}

test "every command is listed in the help table" {
    // A command with no spec would be invisible in --help; the table is the
    // only place the list lives, so this is what keeps it honest.
    for (std.enums.values(Command)) |c| {
        if (c == .help or c == .version) continue;
        if (specFor(c) == null) {
            std.debug.print("command {s} has no spec entry\n", .{@tagName(c)});
            return error.TestUnexpectedResult;
        }
    }
}

test "--model provider/model picks both, and leaves a slashed model id alone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try tmp.dir.writeFile(io, .{
        .sub_path = "config.json",
        .data =
        \\{
        \\  "default_provider": "zai",
        \\  "providers": {
        \\    "zai": { "base_url": "http://x/v1", "models": { "glm-5.2": {} } },
        \\    "kimi-k3": { "base_url": "http://y/v1", "models": { "moonshotai/kimi-k3": {} } }
        \\  }
        \\}
        ,
    });
    const cfg = try config.Config.load(io, arena, tmp.dir, "config.json", "absent.json");

    // The prefix names a provider, so it selects one.
    const split = try resolveProvider(&cfg, .{ .model = "zai/glm-5.2" });
    try std.testing.expectEqualStrings("zai", split.name);
    try std.testing.expectEqualStrings("glm-5.2", split.default_model);

    // The prefix does not name a provider: this is a model id that contains a
    // slash, and splitting it would ask a provider that does not exist for a
    // model that does not either.
    const whole = try resolveProvider(&cfg, .{ .provider = "kimi-k3", .model = "moonshotai/kimi-k3" });
    try std.testing.expectEqualStrings("kimi-k3", whole.name);
    try std.testing.expectEqualStrings("moonshotai/kimi-k3", whole.default_model);

    // Same, without --provider: the default provider keeps the whole string.
    const bare = try resolveProvider(&cfg, .{ .model = "moonshotai/kimi-k3" });
    try std.testing.expectEqualStrings("zai", bare.name);
    try std.testing.expectEqualStrings("moonshotai/kimi-k3", bare.default_model);

    // An explicit --provider always wins; the model is never split then.
    const explicit = try resolveProvider(&cfg, .{ .provider = "kimi-k3", .model = "zai/glm-5.2" });
    try std.testing.expectEqualStrings("kimi-k3", explicit.name);
    try std.testing.expectEqualStrings("zai/glm-5.2", explicit.default_model);
}

test "a bare invocation starts the REPL, and --help still asks for help" {
    // parse() takes the raw argv, so every case here starts with the program
    // name the shell passes.
    try std.testing.expectEqual(Command.repl, (try parse(&.{"clanker"}, null)).command);
    // Global flags alone are still a REPL start, not a usage error.
    const with_flags = try parse(&.{ "clanker", "--provider", "vertex-opus" }, null);
    try std.testing.expectEqual(Command.repl, with_flags.command);
    try std.testing.expectEqualStrings("vertex-opus", with_flags.provider.?);
    // An explicit command still wins, and help stays reachable.
    try std.testing.expectEqual(Command.run, (try parse(&.{ "clanker", "run", "hi" }, null)).command);
    try std.testing.expectEqual(Command.help, (try parse(&.{ "clanker", "--help" }, null)).command);
    try std.testing.expectEqual(Command.version, (try parse(&.{ "clanker", "--version" }, null)).command);
    // A typo is still a typo, not a silent REPL start.
    try std.testing.expectError(error.UnknownCommand, parse(&.{ "clanker", "runn" }, null));
}

test "parse reports the offending token via the diag out-param" {
    var diag: []const u8 = "";
    try std.testing.expectError(error.UnknownCommand, parse(&.{ "clanker", "runn" }, &diag));
    try std.testing.expectEqualStrings("runn", diag);

    try std.testing.expectError(error.UnknownArg, parse(&.{ "clanker", "--bogus" }, &diag));
    try std.testing.expectEqualStrings("--bogus", diag);

    try std.testing.expectError(error.MissingArg, parse(&.{ "clanker", "--provider" }, &diag));
    try std.testing.expectEqualStrings("--provider", diag);

    try std.testing.expectError(error.BadIters, parse(&.{ "clanker", "improve-self", "--iters", "abc", "x" }, &diag));
    try std.testing.expectEqualStrings("abc", diag);
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

    // Plan mode is opt-in per request and absent means off.
    try std.testing.expect(!bare.plan);
    const plan = try std.json.parseFromSliceLeaky(RunRequestBody, arena, "{\"task\":\"hi\",\"plan\":true}", .{ .ignore_unknown_fields = true });
    try std.testing.expect(plan.plan);

    // Goal id is optional and empty by default so older clients keep working.
    try std.testing.expectEqualStrings("", bare.goal);
    const with_goal = try std.json.parseFromSliceLeaky(RunRequestBody, arena, "{\"task\":\"\",\"goal\":\"g1\"}", .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("g1", with_goal.goal);
}

test "resolveRunTask attaches explicit and newest-active goals from real goals.json" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state");
    // Two active goals; the higher `updated` must win auto-steer. One done
    // goal must never be selected.
    const goals_json =
        \\[
        \\  {"id":"old","objective":"old objective","completion_criterion":"old done","status":"active","updated":10},
        \\  {"id":"done","objective":"finished work","completion_criterion":"done when","status":"done","updated":99},
        \\  {"id":"new","objective":"ship the feature","completion_criterion":"tests green","boundaries":"docs only","status":"active","updated":50}
        \\]
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "state/goals.json", .data = goals_json });

    // Explicit id: that goal only, even if not the newest.
    const explicit = try resolveRunTask(arena, io, tmp.dir, "do the thing", "old", false);
    try std.testing.expect(std.mem.indexOf(u8, explicit, "## Active goal") != null);
    try std.testing.expect(std.mem.indexOf(u8, explicit, "old objective") != null);
    try std.testing.expect(std.mem.indexOf(u8, explicit, "do the thing") != null);
    try std.testing.expect(std.mem.indexOf(u8, explicit, "ship the feature") == null);

    // Auto: newest active (updated=50), not the done goal with updated=99.
    const auto = try resolveRunTask(arena, io, tmp.dir, "chat task", null, true);
    try std.testing.expect(std.mem.indexOf(u8, auto, "ship the feature") != null);
    try std.testing.expect(std.mem.indexOf(u8, auto, "tests green") != null);
    try std.testing.expect(std.mem.indexOf(u8, auto, "chat task") != null);
    try std.testing.expect(std.mem.indexOf(u8, auto, "finished work") == null);

    // Goal-only: empty task becomes a work order for that goal.
    const goal_only = try resolveRunTask(arena, io, tmp.dir, "", "new", false);
    try std.testing.expect(std.mem.indexOf(u8, goal_only, "Work on this goal until the completion criterion is met.") != null);
    try std.testing.expect(std.mem.indexOf(u8, goal_only, "ship the feature") != null);

    // Missing id leaves the task alone (warns on stderr via log).
    const missing = try resolveRunTask(arena, io, tmp.dir, "plain", "no-such", false);
    try std.testing.expectEqualStrings("plain", missing);

    // Auto with no active goals leaves the task alone.
    try tmp.dir.writeFile(io, .{ .sub_path = "state/goals.json", .data = "[]" });
    const none = try resolveRunTask(arena, io, tmp.dir, "plain", null, true);
    try std.testing.expectEqualStrings("plain", none);
}

test "an ask accepts only its own options and hands the pick to the waiter" {
    const gpa = std.testing.allocator;
    const options = [_][]const u8{ "red", "green" };
    const id = askRegister(&options) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(AskResolve.bad_option, askResolve(gpa, id, "blue"));
    try std.testing.expectEqual(AskResolve.not_found, askResolve(gpa, id + 999, "red"));
    try std.testing.expectEqual(AskResolve.ok, askResolve(gpa, id, "red"));
    // Already answered: a second POST must not overwrite the first pick.
    try std.testing.expectEqual(AskResolve.not_found, askResolve(gpa, id, "green"));

    const answer = askAwait(id, 0) orelse return error.TestUnexpectedResult;
    defer gpa.free(answer);
    try std.testing.expectEqualStrings("red", answer);
    // The slot was freed on the way out; a late answer has nothing to hit.
    try std.testing.expectEqual(AskResolve.not_found, askResolve(gpa, id, "red"));
}

test "an unanswered ask times out, frees its slot, and reports no answer" {
    const options = [_][]const u8{ "a", "b" };
    const id = askRegister(&options) orelse return error.TestUnexpectedResult;
    try std.testing.expect(askAwait(id, 1) == null);
    try std.testing.expectEqual(AskResolve.not_found, askResolve(std.testing.allocator, id, "a"));
}

test "the browser's answer crosses threads to the waiting run" {
    const gpa = std.testing.allocator;
    const options = [_][]const u8{ "ship it", "hold" };
    const id = askRegister(&options) orelse return error.TestUnexpectedResult;

    const answerer = try std.Thread.spawn(.{}, struct {
        fn answer(alloc: std.mem.Allocator, ask_id: u64) void {
            _ = askResolve(alloc, ask_id, "hold");
        }
    }.answer, .{ gpa, id });
    defer answerer.join();

    // Whichever side runs first, `answered` persists until the waiter reads
    // it, so this cannot race into a lost wakeup.
    const answer = askAwait(id, 10 * std.time.ns_per_s) orelse return error.TestUnexpectedResult;
    defer gpa.free(answer);
    try std.testing.expectEqualStrings("hold", answer);
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

// ------------------------------------------------------- providers catalog --

const fake_models_dev_catalog =
    \\{
    \\  "moonshotai": {
    \\    "id": "moonshotai", "name": "Moonshot AI", "api": "https://api.moonshot.ai/v1",
    \\    "env": ["MOONSHOT_API_KEY"],
    \\    "models": {
    \\      "kimi-k3": {
    \\        "id": "kimi-k3", "name": "Kimi K3", "family": "kimi-k3", "reasoning": true,
    \\        "limit": {"context": 1048576, "output": 131072},
    \\        "cost": {"input": 3, "output": 15}
    \\      }
    \\    }
    \\  },
    \\  "moonshotai-cn": {
    \\    "id": "moonshotai-cn", "name": "Moonshot AI (China)", "api": "https://api.moonshot.cn/v1",
    \\    "env": ["MOONSHOT_API_KEY"],
    \\    "models": { "kimi-k3": { "limit": {"context": 1048576, "output": 131072}, "cost": {"input": 3, "output": 15} } }
    \\  },
    \\  "local-relay": {
    \\    "id": "local-relay", "name": "Local Relay", "api": "http://127.0.0.1:9/v1",
    \\    "env": ["RELAY_API_KEY"],
    \\    "models": { "solo": {} }
    \\  }
    \\}
;

test "findCatalogProvider prefers an exact base_url match over a shared env var" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const catalog = try std.json.parseFromSliceLeaky(std.json.Value, arena, fake_models_dev_catalog, .{});
    // Both moonshotai and moonshotai-cn share the MOONSHOT_API_KEY env var;
    // only the .ai host matches this provider's base_url exactly.
    const p = try config.Provider.single(arena, "kimi-k3", "https://api.moonshot.ai/v1", .openai_compat, "kimi-k3", .{});
    var p_env = p;
    p_env.api_key_env = "MOONSHOT_API_KEY";
    const found = findCatalogProvider(catalog, &p_env) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Moonshot AI", found.object.get("name").?.string);
}

test "findCatalogProvider falls back to the env var when no host matches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const catalog = try std.json.parseFromSliceLeaky(std.json.Value, arena, fake_models_dev_catalog, .{});
    var p = try config.Provider.single(arena, "relay", "http://10.0.0.5:8000/v1", .openai_compat, "solo", .{});
    p.api_key_env = "RELAY_API_KEY";
    const found = findCatalogProvider(catalog, &p) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Local Relay", found.object.get("name").?.string);
}

test "findCatalogProvider returns null with neither a host nor an env match" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const catalog = try std.json.parseFromSliceLeaky(std.json.Value, arena, fake_models_dev_catalog, .{});
    const p = try config.Provider.single(arena, "mystery", "https://example.test/v1", .openai_compat, "m", .{});
    try std.testing.expect(findCatalogProvider(catalog, &p) == null);
}

test "findCatalogModel tries the bare id when the config name carries an OpenRouter-style prefix" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const catalog = try std.json.parseFromSliceLeaky(std.json.Value, arena, fake_models_dev_catalog, .{});
    const provider_entry = catalog.object.get("moonshotai").?;
    try std.testing.expect(findCatalogModel(provider_entry, "kimi-k3") != null);
    try std.testing.expect(findCatalogModel(provider_entry, "moonshotai/kimi-k3") != null);
    try std.testing.expect(findCatalogModel(provider_entry, "no-such-model") == null);
}

test "renderModelSnippet emits valid, pasteable JSON with no trailing comma" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const catalog = try std.json.parseFromSliceLeaky(std.json.Value, arena, fake_models_dev_catalog, .{});
    const model = catalog.object.get("moonshotai").?.object.get("models").?.object.get("kimi-k3").?;
    const snippet = try renderModelSnippet(arena, "kimi-k3", model);

    // The point of the test: a naive "one field per line, always trailing
    // comma" writer produces `..."display": "Kimi K3",\n}`, which is not
    // valid JSON and fails to paste back into config.json.
    const wrapped = try std.fmt.allocPrint(arena, "{{{s}}}", .{snippet});
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, wrapped, .{});
    const entry = parsed.object.get("kimi-k3").?;
    try std.testing.expectEqual(@as(i64, 1048576), entry.object.get("context_window").?.integer);
    try std.testing.expectEqual(@as(i64, 131072), entry.object.get("max_tokens").?.integer);
    try std.testing.expectEqualStrings("Kimi K3", entry.object.get("display").?.string);
}

test "webui registry-miss error names tools_dir and does not sole-blame zig build tools" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Drive the real helper renderWebui uses for the HTTP error body when
    // reg.get("webui") is null — not a reimplementation of the string.
    const body = try webuiMissingRegistryError(arena, "tools/no-such-manifests");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    const err_msg = parsed.object.get("error").?.string;
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "tools/no-such-manifests") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "registry") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "tools_dir") != null);
    // Sole-blaming guest rebuilds is the bug this test locks out.
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "zig build tools") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "zig build tools") == null);
}

test "webui wasm-miss error still points at zig build tools" {
    const body = webuiMissingWasmError();
    try std.testing.expect(std.mem.indexOf(u8, body, "wasm") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "zig build tools") != null);
}
