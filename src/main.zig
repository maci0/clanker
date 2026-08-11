//! Entry point: process setup, config/dotenv bootstrap, then hand off to cli.run.

const std = @import("std");
const cli = @import("cli.zig");
const log = @import("util/log.zig");
const dotenv = @import("util/dotenv.zig");
const autolearn = @import("agent/autolearn.zig");
const host = @import("sandbox/host.zig");
const vertex_token = @import("llm/vertex_token.zig");
const config = @import("config.zig");

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
    _ = @import("util/lineedit.zig");
    _ = @import("tools/builder.zig");
    _ = @import("agent/system_prompt.zig");
    _ = @import("agent/loop.zig");
    _ = @import("agent/session.zig");
    _ = @import("agent/graph.zig");
    _ = @import("util/dotenv.zig");
    _ = @import("util/atomic_write.zig");
    _ = @import("agent/autolearn.zig");
    _ = @import("evals/scorers.zig");
    _ = @import("evals/runner.zig");
    _ = @import("improve/proposal.zig");
    _ = @import("improve/history.zig");
    _ = @import("improve/engine.zig");
    _ = @import("patch/apply.zig");
    _ = @import("gate/checks.zig");
    _ = @import("mcp/server.zig");
    _ = @import("llm/gcp_jwt.zig");
    _ = @import("llm/vertex_token.zig");
    _ = @import("peers/chatrooms.zig");
    _ = @import("peers/todos.zig");
    _ = @import("stats/tokens.zig");
    _ = @import("tui/term.zig");
    _ = @import("tui/width.zig");
    _ = @import("tui/input.zig");
    _ = @import("tui/region.zig");
    _ = @import("tui/statusbar.zig");
    _ = @import("tui/transcript.zig");
    _ = @import("tui/palette.zig");
    _ = @import("tui/approval.zig");
    _ = @import("tui/theme.zig");
    _ = @import("cli.zig");
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
    // Load API keys and other secrets from $CLANKER_ENV_FILE or ./.env
    // (existing real env vars always win). Gated by the modules.dotenv flag.
    const arena = init.arena.allocator();
    const early_cfg = config.Config.load(init.io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json") catch null;
    if (early_cfg) |c| {
        if (c.modules.dotenv) dotenv.load(init.io, gpa, init.environ_map);
    } else {
        dotenv.load(init.io, gpa, init.environ_map); // no config: still try .env
    }

    var arg_list: std.ArrayList([]const u8) = .empty;
    defer arg_list.deinit(gpa);
    var args_it = init.minimal.args.iterate();
    while (args_it.next()) |arg| try arg_list.append(gpa, arg);

    const opts = cli.parse(arg_list.items) catch |err| {
        switch (err) {
            error.MissingTask => log.log(.error_, "`clanker run` needs a task text argument", .{}),
            error.BadSubcommand => log.log(.error_, "usage: clanker providers check [name]", .{}),
            else => log.log(.error_, "{s}", .{@errorName(err)}),
        }
        cli.printUsage(init.io);
        return;
    };

    if (opts.verbose) log.setLevel(.debug);
    try cli.run(init, opts);
}

comptime {
    _ = @import("agent/graph.zig");
}
