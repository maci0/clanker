const std = @import("std");
const cli = @import("cli.zig");
const log = @import("util/log.zig");

// Zig 0.16 only runs test blocks in the root file; reference every module
// containing tests so `zig build test` picks them all up.
comptime {
    _ = @import("config.zig");
    _ = @import("llm/types.zig");
    _ = @import("llm/providers.zig");
    _ = @import("llm/client.zig");
    _ = @import("llm/mock_server.zig");
    _ = @import("sandbox/protocol.zig");
    _ = @import("sandbox/host.zig");
    _ = @import("sandbox/runtime.zig");
    _ = @import("tools/registry.zig");
    _ = @import("tools/builder.zig");
    _ = @import("agent/system_prompt.zig");
    _ = @import("agent/loop.zig");
    _ = @import("agent/session.zig");
    _ = @import("evals/scorers.zig");
    _ = @import("evals/runner.zig");
    _ = @import("improve/proposal.zig");
    _ = @import("improve/history.zig");
    _ = @import("improve/engine.zig");
    _ = @import("patch/apply.zig");
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var arg_list: std.ArrayList([]const u8) = .empty;
    defer arg_list.deinit(gpa);
    var args_it = init.minimal.args.iterate();
    while (args_it.next()) |arg| try arg_list.append(gpa, arg);

    const opts = cli.parse(arg_list.items) catch |err| {
        switch (err) {
            error.NotYetImplemented => log.log(.error_, "that command is not implemented in this build yet", .{}),
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
