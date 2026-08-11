//! Deterministic gate checks for the self-improvement loop. This module is
//! deliberately OUTSIDE the protected surface (src/improve/, src/evals/,
//! src/tools/builder.zig) so clanker can keep strengthening these checks.
//! The engine in src/improve/engine.zig calls these and promotes only when
//! every check passes.

const std = @import("std");
const log = @import("../util/log.zig");

/// A cold `zig build test` can print more than one MiB while rebuilding its
/// dependency graph. Gate output is retained only until the result is logged
/// or reduced to an error tail, so this ceiling must accommodate a clean
/// checkout instead of making a healthy gate fail with `StreamTooLong`.
const max_captured_gate_output = 16 << 20;

pub const GateResult = struct {
    ok: bool,
    label: []const u8,
    detail: []const u8 = "",
    stdout: []u8 = &.{},
    stderr: []u8 = &.{},

    pub fn deinit(self: *GateResult, gpa: std.mem.Allocator) void {
        if (self.stdout.len > 0) gpa.free(self.stdout);
        if (self.stderr.len > 0) gpa.free(self.stderr);
    }
};

/// Runs `zig build` (plus `build_args`) in `dir`.
pub fn buildGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, build_args: []const []const u8) !GateResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "zig");
    try argv.append(gpa, "build");
    try argv.append(gpa, "--summary");
    try argv.append(gpa, "all");
    for (build_args) |a| try argv.append(gpa, a);
    return runZigArgs(gpa, io, dir, argv.items, "zig build");
}

/// Runs `zig build test` in `dir`.
pub fn testGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !GateResult {
    return runZig(gpa, io, dir, &.{ "build", "test", "--summary", "all" }, "zig build test");
}

/// Runs `zig build tools` in `dir`.
pub fn toolsGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !GateResult {
    return runZig(gpa, io, dir, &.{ "build", "tools", "--summary", "all" }, "zig build tools");
}

/// Runs `zig fmt --check` on exactly the files changed by a proposal, so
/// pre-existing formatting debt in untouched files cannot block promotion.
pub fn fmtGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, changed_files: []const []const u8) !GateResult {
    if (changed_files.len == 0) return .{ .ok = true, .label = "zig fmt --check" };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "zig");
    try argv.append(gpa, "fmt");
    try argv.append(gpa, "--check");
    // Only .zig files can be formatted; json/config descriptors are not Zig.
    for (changed_files) |f| {
        if (std.mem.endsWith(u8, f, ".zig")) try argv.append(gpa, f);
    }
    if (argv.items.len == 3) return .{ .ok = true, .label = "zig fmt --check" };
    return runZigArgs(gpa, io, dir, argv.items, "zig fmt --check");
}

/// Runs `zig fmt` (in place) on the changed .zig files in `dir`, so promoted
/// code is always formatted and the fmt check below is deterministic.
pub fn formatFiles(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, changed_files: []const []const u8) !GateResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "zig");
    try argv.append(gpa, "fmt");
    var any = false;
    for (changed_files) |f| {
        if (std.mem.endsWith(u8, f, ".zig")) {
            try argv.append(gpa, f);
            any = true;
        }
    }
    if (!any) return .{ .ok = true, .label = "zig fmt" };
    return runZigArgs(gpa, io, dir, argv.items, "zig fmt");
}

/// Source-hygiene scan of exactly the files changed by a proposal.
pub fn lintGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, changed_files: []const []const u8) !GateResult {
    // Split so this file does not match its own scan: spelled whole, the
    // needles make lintGate fail on checks.zig every single run.
    const forbidden = [_][]const u8{ "TO" ++ "DO", "FIX" ++ "ME" };
    var hits: usize = 0;
    for (changed_files) |f| {
        if (!std.mem.endsWith(u8, f, ".zig")) continue;
        const content = dir.readFileAlloc(io, f, gpa, .limited(1 << 20)) catch |err| {
            // A file the scan cannot read must not pass as clean: a proposal
            // could otherwise promote a change whose forbidden-marker check
            // silently never ran.
            log.log(.warn, "lint: could not read {s}: {s}", .{ f, @errorName(err) });
            return .{ .ok = false, .label = "lint", .detail = "a changed file could not be scanned" };
        };
        defer gpa.free(content);
        for (forbidden) |marker| {
            if (std.mem.indexOf(u8, content, marker) != null) {
                log.log(.warn, "lint: {s} found in {s}", .{ marker, f });
                hits += 1;
            }
        }
    }
    if (hits > 0) {
        return .{ .ok = false, .label = "lint", .detail = "forbidden markers found in changed files" };
    }
    return .{ .ok = true, .label = "lint" };
}

test "lintGate flags forbidden markers only in changed .zig files" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "dirty.zig", .data = "// TO" ++ "DO: finish this\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "clean.zig", .data = "const x = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dirty.md", .data = "TO" ++ "DO markers in non-zig files don't count" });

    const clean = try lintGate(gpa, io, tmp.dir, &.{ "clean.zig", "dirty.md" });
    try std.testing.expect(clean.ok);

    const dirty = try lintGate(gpa, io, tmp.dir, &.{"dirty.zig"});
    try std.testing.expect(!dirty.ok);
    try std.testing.expectEqualStrings("lint", dirty.label);
}

test "fmtGate and formatFiles short-circuit when there is nothing to format" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var empty_result = try fmtGate(gpa, io, tmp.dir, &.{});
    defer empty_result.deinit(gpa);
    try std.testing.expect(empty_result.ok);

    var non_zig_result = try fmtGate(gpa, io, tmp.dir, &.{"config.json"});
    defer non_zig_result.deinit(gpa);
    try std.testing.expect(non_zig_result.ok);

    var format_result = try formatFiles(gpa, io, tmp.dir, &.{"config.json"});
    defer format_result.deinit(gpa);
    try std.testing.expect(format_result.ok);
}

fn runZig(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, args: []const []const u8, label: []const u8) !GateResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "zig");
    for (args) |a| try argv.append(gpa, a);
    return runZigArgs(gpa, io, dir, argv.items, label);
}

fn runZigArgs(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, argv: []const []const u8, label: []const u8) !GateResult {
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .dir = dir },
        .stdout_limit = .limited(max_captured_gate_output),
        .stderr_limit = .limited(max_captured_gate_output),
    });
    const ok = switch (result.term) {
        .exited => |c| c == 0,
        else => false,
    };
    // Ownership: stdout/stderr move into the GateResult; detail aliases stderr.
    const detail: []const u8 = if (ok) "" else if (result.stderr.len > 0) result.stderr else result.stdout;
    return .{ .ok = ok, .label = label, .detail = detail, .stdout = result.stdout, .stderr = result.stderr };
}
