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
    var hit_buf: [2048]u8 = undefined;
    var hit_w: std.Io.Writer = .fixed(&hit_buf);
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
                hit_w.print("{s} in {s}; ", .{ marker, f }) catch {};
                hits += 1;
            }
        }
    }
    if (hits > 0) {
        const written = hit_buf[0..hit_w.end];
        const detail_str = if (written.len > 0) written else "forbidden markers found in changed files";
        return .{ .ok = false, .label = "lint", .detail = detail_str };
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

/// Runs `zig ast-check` on each changed `.zig` file individually. A syntax
/// error caught here gives a precise file + line, whereas `zig build` reports
/// the same error buried in a dependency trace. Short-circuits when no `.zig`
/// files were changed.
pub fn astCheckGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, changed_files: []const []const u8) !GateResult {
    var zig_files: std.ArrayList([]const u8) = .empty;
    defer zig_files.deinit(gpa);
    for (changed_files) |f| {
        if (std.mem.endsWith(u8, f, ".zig")) try zig_files.append(gpa, f);
    }
    if (zig_files.items.len == 0) return .{ .ok = true, .label = "zig ast-check" };

    for (zig_files.items) |f| {
        var r = try runZigArgs(gpa, io, dir, &.{ "zig", "ast-check", f }, "zig ast-check");
        if (!r.ok) {
            r.label = "zig ast-check";
            r.detail = if (r.stderr.len > 0) r.stderr else r.stdout;
            return r;
        }
        r.deinit(gpa);
    }
    return .{ .ok = true, .label = "zig ast-check" };
}

test "astCheckGate short-circuits when there are no .zig files" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var empty_result = try astCheckGate(gpa, io, tmp.dir, &.{});
    defer empty_result.deinit(gpa);
    try std.testing.expect(empty_result.ok);
    try std.testing.expectEqualStrings("zig ast-check", empty_result.label);

    var non_zig_result = try astCheckGate(gpa, io, tmp.dir, &.{ "config.json", "README.md" });
    defer non_zig_result.deinit(gpa);
    try std.testing.expect(non_zig_result.ok);
}

/// Convenience: auto-format changed files, then run the fmt check.
/// Returns the fmt gate result; if formatting itself fails, returns that
/// failure instead. This is the single call an improve pipeline makes
/// instead of separate formatFiles + fmtGate.
pub fn autoFormatAndCheck(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, changed_files: []const []const u8) !GateResult {
    var fmt_result = try formatFiles(gpa, io, dir, changed_files);
    if (!fmt_result.ok) {
        fmt_result.label = "zig fmt (auto-format)";
        return fmt_result;
    }
    fmt_result.deinit(gpa);
    return fmtGate(gpa, io, dir, changed_files);
}

test "autoFormatAndCheck short-circuits when there is nothing to format" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var empty_result = try autoFormatAndCheck(gpa, io, tmp.dir, &.{});
    defer empty_result.deinit(gpa);
    try std.testing.expect(empty_result.ok);

    var non_zig_result = try autoFormatAndCheck(gpa, io, tmp.dir, &.{"config.json"});
    defer non_zig_result.deinit(gpa);
    try std.testing.expect(non_zig_result.ok);
}

/// Rejects a proposal that lists the same file path more than once.
/// Multiple changes to one file risk the second edit's `old` text no longer
/// matching after the first edit is applied, causing a silent misapply or a
/// confusing "old text not found" error. Catching it here gives a clear
/// diagnostic before any file I/O.
pub fn duplicateFileGate(files: []const []const u8) GateResult {
    for (files, 0..) |f, i| {
        for (files[i + 1 ..]) |g| {
            if (std.mem.eql(u8, f, g)) {
                return .{ .ok = false, .label = "duplicate-file", .detail = f };
            }
        }
    }
    return .{ .ok = true, .label = "duplicate-file" };
}

test "duplicateFileGate rejects repeated files and accepts distinct ones" {
    const dup = duplicateFileGate(&.{ "src/a.zig", "src/b.zig", "src/a.zig" });
    try std.testing.expect(!dup.ok);
    try std.testing.expectEqualStrings("duplicate-file", dup.label);
    try std.testing.expectEqualStrings("src/a.zig", dup.detail);

    const ok = duplicateFileGate(&.{ "src/a.zig", "src/b.zig", "src/c.zig" });
    try std.testing.expect(ok.ok);

    const empty = duplicateFileGate(&.{});
    try std.testing.expect(empty.ok);

    const single = duplicateFileGate(&.{"src/x.zig"});
    try std.testing.expect(single.ok);
}

/// Validates that a set of proposed changes are semantically meaningful:
/// every (old, new) pair must differ, and at least one change must exist.
/// Returns ok=false with a diagnostic when the proposal is a no-op.
pub fn proposalDiffGate(old_texts: []const []const u8, new_texts: []const []const u8) GateResult {
    if (old_texts.len == 0) return .{ .ok = false, .label = "proposal-diff", .detail = "proposal contains no changes" };
    if (old_texts.len != new_texts.len) return .{ .ok = false, .label = "proposal-diff", .detail = "mismatched old/new change count" };
    for (old_texts, new_texts) |old, new| {
        if (std.mem.eql(u8, old, new)) return .{ .ok = false, .label = "proposal-diff", .detail = "a change has identical old and new text (no-op)" };
    }
    return .{ .ok = true, .label = "proposal-diff" };
}

test "proposalDiffGate rejects no-op and empty proposals" {
    // Empty proposal.
    const empty = proposalDiffGate(&.{}, &.{});
    try std.testing.expect(!empty.ok);
    try std.testing.expectEqualStrings("proposal-diff", empty.label);

    // Identical old/new is a no-op.
    const noop = proposalDiffGate(&.{"const x = 1;"}, &.{"const x = 1;"});
    try std.testing.expect(!noop.ok);

    // A real change passes.
    const real = proposalDiffGate(&.{"const x = 1;"}, &.{"const x = 2;"});
    try std.testing.expect(real.ok);

    // Mixed: one real change and one no-op fails.
    const mixed = proposalDiffGate(
        &.{ "const a = 1;", "const b = 2;" },
        &.{ "const a = 99;", "const b = 2;" },
    );
    try std.testing.expect(!mixed.ok);

    // Mismatched lengths.
    const mismatch = proposalDiffGate(&.{"x"}, &.{ "y", "z" });
    try std.testing.expect(!mismatch.ok);
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
