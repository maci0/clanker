//! Deterministic gate checks for the self-improvement loop. This module is
//! deliberately OUTSIDE the protected surface (src/improve/, src/evals/,
//! src/tools/builder.zig) so clanker can keep strengthening these checks.
//! The engine in src/improve/engine.zig calls these and promotes only when
//! every check passes.

const std = @import("std");
const build_options = @import("build_options");
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
    const forbidden = [_][]const u8{ "TO" ++ "DO", "FIX" ++ "ME", "HA" ++ "CK", "XX" ++ "X" };
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

    // The other two debt markers must trip the gate too. Split the same way
    // as the forbidden array above: spelled whole, they match this file's
    // own bytes and lintGate fails on itself every run.
    try tmp.dir.writeFile(io, .{ .sub_path = "hacky.zig", .data = "// HA" ++ "CK: quick fix\nconst x = 1;\n" });
    const hacky = try lintGate(gpa, io, tmp.dir, &.{"hacky.zig"});
    try std.testing.expect(!hacky.ok);
    try std.testing.expectEqualStrings("lint", hacky.label);
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

/// The zig-spawning tests must hand their Io the real process environment:
/// `Threaded.init` defaults to an empty environ, which strips PATH (so a bare
/// "zig" argv[0] cannot be resolved) and HOME (which version-manager shims
/// like anyzig need to locate their installs). The production Io from
/// `std.process.Init` always carries the process environ, so an empty one
/// tests a child environment the gates never actually run with.
fn testProcessEnviron() std.process.Environ {
    const c_environ = std.c.environ;
    var n: usize = 0;
    while (c_environ[n] != null) : (n += 1) {}
    return .{ .block = .{ .slice = @ptrCast(c_environ[0..n :null]) } };
}

test "astCheckGate fails on a syntax error with a precise diagnostic" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = testProcessEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "bad.zig", .data = "const x = ;\n" });
    // Needs a spawnable compiler; skip where there is none (see
    // skipIfNoSpawnableZig) rather than failing on every other machine.
    var result = astCheckGate(gpa, io, tmp.dir, &.{"bad.zig"}) catch |err|
        return skipIfNoSpawnableZig(err);
    defer result.deinit(gpa);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("zig ast-check", result.label);
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

/// Verifies that each `old` text actually appears in the corresponding file.
/// A mismatch means the LLM hallucinated or used stale file content, and the
/// change would either silently fail to apply or corrupt the file.
pub fn matchGate(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, files: []const []const u8, old_texts: []const []const u8) !GateResult {
    if (files.len != old_texts.len) return .{ .ok = false, .label = "match", .detail = "mismatched file/old-text count" };
    for (files, old_texts) |f, old| {
        if (old.len == 0) continue; // append-mode change, no match needed
        const content = dir.readFileAlloc(io, f, gpa, .limited(4 << 20)) catch |err| {
            return .{ .ok = false, .label = "match", .detail = if (err == error.FileNotFound) "target file does not exist" else "could not read target file" };
        };
        defer gpa.free(content);
        if (std.mem.indexOf(u8, content, old) == null) {
            return .{ .ok = false, .label = "match", .detail = f };
        }
    }
    return .{ .ok = true, .label = "match" };
}

test "matchGate rejects when old text is not in the file" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "const x = 1;\n" });

    // old text present: pass
    const ok = try matchGate(io, gpa, tmp.dir, &.{"a.zig"}, &.{"const x = 1;"});
    try std.testing.expect(ok.ok);

    // old text absent: fail
    const bad = try matchGate(io, gpa, tmp.dir, &.{"a.zig"}, &.{"const y = 2;"});
    try std.testing.expect(!bad.ok);
    try std.testing.expectEqualStrings("match", bad.label);

    // missing file: fail
    const missing = try matchGate(io, gpa, tmp.dir, &.{"nope.zig"}, &.{"x"});
    try std.testing.expect(!missing.ok);

    // empty old (append): pass
    const append = try matchGate(io, gpa, tmp.dir, &.{"a.zig"}, &.{""});
    try std.testing.expect(append.ok);
}

/// Rejects changes where old and new differ only in whitespace. These waste
/// a full gate cycle and are almost always an LLM formatting artefact rather
/// than an intentional change.
pub fn whitespaceOnlyGate(old_texts: []const []const u8, new_texts: []const []const u8) GateResult {
    if (old_texts.len != new_texts.len) return .{ .ok = false, .label = "whitespace-only", .detail = "mismatched old/new count" };
    for (old_texts, new_texts) |old, new| {
        const old_trimmed = std.mem.trim(u8, old, " \t\r\n");
        const new_trimmed = std.mem.trim(u8, new, " \t\r\n");
        if (std.mem.eql(u8, old_trimmed, new_trimmed) and !std.mem.eql(u8, old, new)) {
            return .{ .ok = false, .label = "whitespace-only", .detail = "a change differs only in whitespace" };
        }
    }
    return .{ .ok = true, .label = "whitespace-only" };
}

/// Rejects proposals where a changed .zig file would end up with unbalanced
/// braces, parentheses, or square brackets. Operates on the *new* content
/// that would be written, so it catches a malformed edit before it lands.
pub fn bracketBalanceGate(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, files: []const []const u8, old_texts: []const []const u8, new_texts: []const []const u8) !GateResult {
    if (files.len != old_texts.len or files.len != new_texts.len)
        return .{ .ok = false, .label = "bracket-balance", .detail = "mismatched change counts" };
    for (files, old_texts, new_texts) |f, old, new| {
        if (!std.mem.endsWith(u8, f, ".zig")) continue;
        // Build the file content as it would look after applying the change.
        const content = blk: {
            if (old.len == 0) {
                // Append-mode: read existing content and append new.
                const existing = dir.readFileAlloc(io, f, gpa, .limited(4 << 20)) catch break :blk new;
                defer gpa.free(existing);
                const combined = gpa.alloc(u8, existing.len + new.len) catch break :blk new;
                @memcpy(combined[0..existing.len], existing);
                @memcpy(combined[existing.len..], new);
                break :blk combined;
            }
            const existing = dir.readFileAlloc(io, f, gpa, .limited(4 << 20)) catch break :blk new;
            defer gpa.free(existing);
            if (std.mem.indexOf(u8, existing, old)) |pos| {
                const combined = gpa.alloc(u8, existing.len - old.len + new.len) catch break :blk new;
                @memcpy(combined[0..pos], existing[0..pos]);
                @memcpy(combined[pos..][0..new.len], new);
                @memcpy(combined[pos + new.len ..], existing[pos + old.len ..]);
                break :blk combined;
            }
            break :blk new;
        };
        const must_free = content.ptr != new.ptr;
        defer if (must_free) gpa.free(@constCast(content));
        if (!bracketsBalanced(content)) {
            return .{ .ok = false, .label = "bracket-balance", .detail = f };
        }
    }
    return .{ .ok = true, .label = "bracket-balance" };
}

fn bracketsBalanced(src: []const u8) bool {
    var braces: i64 = 0;
    var parens: i64 = 0;
    var squares: i64 = 0;
    var in_line_comment = false;
    var in_string = false;
    var in_char = false;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c == '\n') {
            in_line_comment = false;
            in_string = false;
            in_char = false;
            continue;
        }
        if (in_line_comment) continue;
        if (c == '"' and !in_string and !in_char) {
            in_string = true;
            continue;
        }
        if (c == '"' and in_string) {
            in_string = false;
            continue;
        }
        if (in_string) {
            if (c == '\\' and i + 1 < src.len) i += 1;
            continue;
        }
        // A Zig char literal ('{', '\'', ...) can hold a bracket byte, which
        // must not be counted: it never opens or closes anything.
        if (c == '\'' and !in_char) {
            in_char = true;
            continue;
        }
        if (in_char) {
            if (c == '\\' and i + 1 < src.len) {
                i += 1;
                continue;
            }
            if (c == '\'') in_char = false;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            in_line_comment = true;
            continue;
        }
        switch (c) {
            '{' => braces += 1,
            '}' => braces -= 1,
            '(' => parens += 1,
            ')' => parens -= 1,
            '[' => squares += 1,
            ']' => squares -= 1,
            else => {},
        }
        if (braces < 0 or parens < 0 or squares < 0) return false;
    }
    return braces == 0 and parens == 0 and squares == 0;
}

test "bracketBalanceGate rejects unbalanced braces in new content" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "const x = 1;\n" });

    // Balanced replacement: pass
    const ok = try bracketBalanceGate(io, gpa, tmp.dir, &.{"a.zig"}, &.{"const x = 1;"}, &.{"fn foo() void {\n    return;\n}"});
    try std.testing.expect(ok.ok);

    // Unbalanced replacement: fail
    const bad = try bracketBalanceGate(io, gpa, tmp.dir, &.{"a.zig"}, &.{"const x = 1;"}, &.{"fn foo() void {\n    return;\n"});
    try std.testing.expect(!bad.ok);
    try std.testing.expectEqualStrings("bracket-balance", bad.label);

    // Non-zig files are skipped
    const json_ok = try bracketBalanceGate(io, gpa, tmp.dir, &.{"config.json"}, &.{"old"}, &.{"{unbalanced"});
    try std.testing.expect(json_ok.ok);
}

test "bracketsBalanced handles strings and comments" {
    try std.testing.expect(bracketsBalanced("const s = \"}{\";"));
    try std.testing.expect(bracketsBalanced("// }\nconst x = 1;"));
    try std.testing.expect(!bracketsBalanced("const x = {;"));
    try std.testing.expect(bracketsBalanced("fn f() void {}\n"));
}

test "bracketsBalanced handles char literals" {
    try std.testing.expect(bracketsBalanced("const c: u8 = '{';"));
    try std.testing.expect(bracketsBalanced("const c: u8 = '\\'';"));
    try std.testing.expect(bracketsBalanced("if (c == '(') n += 1;"));
    try std.testing.expect(!bracketsBalanced("const x = {'a';"));
}

test "whitespaceOnlyGate rejects whitespace-only diffs" {
    // Pure whitespace change: fail
    const ws = whitespaceOnlyGate(&.{"const x = 1;"}, &.{"  const x = 1;  \n"});
    try std.testing.expect(!ws.ok);

    // Real change: pass
    const real = whitespaceOnlyGate(&.{"const x = 1;"}, &.{"const x = 2;"});
    try std.testing.expect(real.ok);

    // Identical (caught by proposalDiffGate, not this one): pass here
    const same = whitespaceOnlyGate(&.{"x"}, &.{"x"});
    try std.testing.expect(same.ok);
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

test "proposalDiffGate accepts an append-style change where old text is empty" {
    // An empty `old` is the append convention in the improvement protocol:
    // the change inserts `new` at the end of the file. It differs from new,
    // so it must pass — unlike an empty proposal, which has no changes at all
    // and must be rejected as a no-op. Pinning this keeps the two callers'
    // (opposite) failure modes from being confused by a future refactor.
    const append = proposalDiffGate(&.{""}, &.{"const x = 1;\n"});
    try std.testing.expect(append.ok);

    // But old="" with new="" is still a no-op.
    const empty_append = proposalDiffGate(&.{""}, &.{""});
    try std.testing.expect(!empty_append.ok);
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

test "fmtGate catches unformatted code and formatFiles fixes it" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = testProcessEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Deliberately unformatted: zig fmt would insert a space before `1`.
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.zig", .data = "const x =1;\n" });

    // Needs a spawnable compiler; skip where there is none (see
    // skipIfNoSpawnableZig) rather than failing on every other machine. The
    // later gate calls don't need the guard: if the first spawn worked, so
    // will the rest.
    var check = fmtGate(gpa, io, tmp.dir, &.{"bad.zig"}) catch |err|
        return skipIfNoSpawnableZig(err);
    defer check.deinit(gpa);
    try std.testing.expect(!check.ok);

    var formatted = try formatFiles(gpa, io, tmp.dir, &.{"bad.zig"});
    defer formatted.deinit(gpa);
    try std.testing.expect(formatted.ok);

    var check2 = try fmtGate(gpa, io, tmp.dir, &.{"bad.zig"});
    defer check2.deinit(gpa);
    try std.testing.expect(check2.ok);
}

/// Rejects a proposal that would add a git command to `exec_pattern_allow` in
/// config files. The config loader refuses such patterns at load time, but a
/// proposal that only touches config.json is still allowed into the staged
/// tree; this gate prevents a config change from silently widening the git
/// deny list.
pub fn gitDenyGuardGate(
    gpa: std.mem.Allocator,
    files: []const []const u8,
    new_texts: []const []const u8,
) GateResult {
    if (files.len != new_texts.len) return .{ .ok = false, .label = "git-deny-guard", .detail = "mismatched files/new_text count" };
    for (files, new_texts) |f, new| {
        if (std.mem.eql(u8, f, "tools/manifests/git.tool.json")) {
            return .{ .ok = false, .label = "git-deny-guard", .detail = "proposals must not modify the git tool manifest" };
        }
        if (!std.mem.eql(u8, f, "config.json") and !std.mem.eql(u8, f, "config.local.json")) continue;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, new, .{}) catch {
            return .{ .ok = false, .label = "git-deny-guard", .detail = "config change is not valid JSON" };
        };
        if (std.mem.indexOf(u8, new, "\"exec_pattern_allow\"") == null) continue;
        const obj = switch (parsed) {
            .object => |o| o,
            else => continue,
        };
        const agent = obj.get("agent") orelse continue;
        const agent_obj = switch (agent) {
            .object => |o| o,
            else => continue,
        };
        const epa = agent_obj.get("exec_pattern_allow") orelse continue;
        const arr = switch (epa) {
            .array => |a| a,
            else => continue,
        };
        for (arr.items) |item| {
            const s = switch (item) {
                .string => |str| str,
                else => continue,
            };
            if (std.mem.eql(u8, s, "git") or std.mem.startsWith(u8, s, "git ") or std.mem.startsWith(u8, s, "git\t")) {
                return .{ .ok = false, .label = "git-deny-guard", .detail = "exec_pattern_allow must not name git commands" };
            }
        }
    }
    return .{ .ok = true, .label = "git-deny-guard" };
}

test "gitDenyGuardGate rejects git patterns in exec_pattern_allow" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"config.json"};
    const new_texts = [_][]const u8{
        \\{"agent":{"exec_pattern_allow":["gh pr create*","git checkout*"]}}
    };
    const result = gitDenyGuardGate(gpa, &files, &new_texts);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("git-deny-guard", result.label);
    try std.testing.expectEqualStrings("exec_pattern_allow must not name git commands", result.detail);
}

test "gitDenyGuardGate allows non-git patterns and non-config files" {
    const gpa = std.testing.allocator;
    // Non-git pattern passes.
    const files = [_][]const u8{"config.json"};
    const new_texts = [_][]const u8{
        \\{"agent":{"exec_pattern_allow":["gh pr create*"]}}
    };
    const result = gitDenyGuardGate(gpa, &files, &new_texts);
    try std.testing.expect(result.ok);

    // A file that is not config is ignored.
    const files2 = [_][]const u8{"src/main.zig"};
    const new_texts2 = [_][]const u8{"const x = 1;"};
    const result2 = gitDenyGuardGate(gpa, &files2, &new_texts2);
    try std.testing.expect(result2.ok);

    // config.local.json is checked too.
    const files3 = [_][]const u8{"config.local.json"};
    const new_texts3 = [_][]const u8{
        \\{"agent":{"exec_pattern_allow":["git push"]}}
    };
    const result3 = gitDenyGuardGate(gpa, &files3, &new_texts3);
    try std.testing.expect(!result3.ok);
}

/// The absolute path of the zig binary the gates shell out to, or null to fall
/// back to a bare "zig".
///
/// `build_options.zig_exe` — the interpreter that built this binary — comes
/// first: it is the right version by construction, and it is absolute, which is
/// what matters here. Every gate runs with `cwd` set to a staging or temp
/// directory, and a bare "zig" is not reliably found from there: on macOS the
/// fmt and ast-check gates failed at *spawn*, before zig ever saw the code they
/// were meant to check, and both of this file's tests failed with it.
///
/// The two fixed paths behind it are where zig lives on the machine this loop
/// usually runs on, kept as a fallback for a binary whose build cache has since
/// been cleared.
fn resolveZigBin(gpa: std.mem.Allocator, io: std.Io) ?[]u8 {
    const known_first = [_][]const u8{ build_options.zig_exe, "/home/maci/.local/bin/zig", "/home/maci/.zvm/0.16.0/zig" };
    for (known_first) |k| {
        // Relative, or empty on a build that predates the option: `cwd` is not
        // this process's, so it could not be resolved against anything useful.
        if (k.len == 0 or k[0] != '/') continue;
        std.Io.Dir.accessAbsolute(io, k, .{ .execute = true }) catch continue;
        return gpa.dupe(u8, k) catch null;
    }
    return null;
}

test "resolveZigBin finds the zig that built this binary" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Something has to be found, or every gate that shells out is running on
    // the bare-"zig" fallback that does not survive a changed cwd — which is
    // the condition skipIfNoSpawnableZig below exists to tolerate, and which
    // this option is meant to stop happening in the first place.
    const bin = resolveZigBin(gpa, io) orelse return error.TestExpectedZigBin;
    defer gpa.free(bin);
    try std.testing.expect(bin[0] == '/');
}

/// Turns "the compiler could not even be spawned" into a test skip. The
/// tests that exercise a real `zig ast-check`/`zig fmt` run can only do so
/// where resolveZigBin finds a binary: everywhere else the bare "zig" argv
/// is not spawnable (std.process.run resolves it against the gate's cwd, a
/// test tmp dir — there is no PATH search), so the gate cannot run at all
/// and the test should skip, not fail the suite on a machine that was never
/// able to run it. Any other error is a real failure and passes through.
///
/// Retained as the backstop it was written to be: with `build_options.zig_exe`
/// in the list above, resolveZigBin now answers on any machine that still has
/// the build's compiler, so these skips stop firing and the gates they cover
/// are actually exercised.
fn skipIfNoSpawnableZig(err: anyerror) anyerror {
    return switch (err) {
        error.FileNotFound, error.AccessDenied => error.SkipZigTest,
        else => err,
    };
}

fn runZig(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, args: []const []const u8, label: []const u8) !GateResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    const zig_bin = resolveZigBin(gpa, io);
    defer if (zig_bin) |p| gpa.free(p);
    try argv.append(gpa, zig_bin orelse "zig");
    for (args) |a| try argv.append(gpa, a);
    return runZigArgs(gpa, io, dir, argv.items, label);
}

fn runZigArgs(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, argv: []const []const u8, label: []const u8) !GateResult {
    var owned_argv: ?[]const []const u8 = null;
    var owned_zig: ?[]u8 = null;
    defer if (owned_zig) |p| gpa.free(p);
    defer if (owned_argv) |a| gpa.free(a);
    var effective_argv = argv;
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "zig")) {
        if (resolveZigBin(gpa, io)) |abs| {
            owned_zig = abs;
            const copy = gpa.dupe([]const u8, argv) catch null;
            if (copy) |c| {
                c[0] = owned_zig.?;
                owned_argv = c;
                effective_argv = c;
            } else {
                effective_argv = argv;
            }
        }
    }
    const result = try std.process.run(gpa, io, .{
        .argv = effective_argv,
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

test "gitDenyGuardGate rejects changes to the git tool manifest" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"tools/manifests/git.tool.json"};
    const new_texts = [_][]const u8{"{}"};
    const result = gitDenyGuardGate(gpa, &files, &new_texts);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("git-deny-guard", result.label);
    try std.testing.expectEqualStrings("proposals must not modify the git tool manifest", result.detail);
}

test "gitDenyGuardGate rejects a tab-separated git pattern" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"config.json"};
    const new_texts = [_][]const u8{
        \\{"agent":{"exec_pattern_allow":["git\tcheckout"]}}
    };
    const result = gitDenyGuardGate(gpa, &files, &new_texts);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("git-deny-guard", result.label);
    try std.testing.expectEqualStrings("exec_pattern_allow must not name git commands", result.detail);
}

test "gitDenyGuardGate allows a git-prefixed tool that is not the git command" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"config.json"};
    const new_texts = [_][]const u8{
        \\{"agent":{"exec_pattern_allow":["git-gh pr create*","git-status"]}}
    };
    const result = gitDenyGuardGate(gpa, &files, &new_texts);
    try std.testing.expect(result.ok);
}

test "gitDenyGuardGate rejects invalid JSON in config files" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"config.json"};
    const new_texts = [_][]const u8{"{ this is not json"};
    const result = gitDenyGuardGate(gpa, &files, &new_texts);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("git-deny-guard", result.label);
    try std.testing.expect(std.mem.indexOf(u8, result.detail, "valid JSON") != null);
}
