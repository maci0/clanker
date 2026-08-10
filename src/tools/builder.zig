//! Spawns `zig build` / `zig build test` as child processes — the compile and
//! test gates used by the eval harness and the self-improvement engine.

const std = @import("std");
const log = @import("../util/log.zig");

pub const GateResult = struct {
    ok: bool,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *GateResult, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

pub fn runZig(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    args: []const []const u8,
    out_cap: usize,
) !GateResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "zig");
    for (args) |a| try argv.append(gpa, a);

    const result = try std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(out_cap),
        .stderr_limit = .limited(out_cap),
    });
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        log.log(.debug, "zig {s} exited non-zero", .{args[0]});
    }
    return .{ .ok = ok, .stdout = result.stdout, .stderr = result.stderr };
}

/// Runs `zig build` (with `build_args` after `--`) in `dir`; returns whether
/// the build succeeded and a trimmed error tail for feeding back to the model.
pub fn buildGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, build_args: []const []const u8) !GateResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "build");
    try argv.append(gpa, "--summary");
    try argv.append(gpa, "all");
    for (build_args) |a| try argv.append(gpa, a);
    return runZig(gpa, io, dir, argv.items, 1 << 20);
}

pub fn testGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !GateResult {
    return runZig(gpa, io, dir, &.{ "build", "test", "--summary", "all" }, 1 << 20);
}
