//! First-party headless spawn for a vendor CLI (RFC 0020 option B).
//!
//! `claude -p`, `codex exec`, `grok -p`. Native harness spawn — not ck_exec,
//! not ck_job. Used when the vendor has no ACP path, ACP hangs, or a vendor
//! update breaks ACP.

const std = @import("std");
const log = @import("../util/log.zig");
const vendor = @import("vendor.zig");

pub const Result = struct {
    stdout: []const u8,
    term_ok: bool,
    argv: []const []const u8,
};

/// Pure argv for tests that must not require a vendor binary on PATH.
pub const headlessArgv = vendor.headlessArgv;

pub fn spawn(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    name: vendor.Name,
    prompt: []const u8,
    cwd: []const u8,
    argv_override: []const []const u8,
) !Result {
    const argv = if (argv_override.len > 0) argv_override else try vendor.headlessArgv(arena, name, prompt);
    return spawnArgv(io, gpa, arena, argv, cwd);
}

pub fn spawnArgv(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
) !Result {
    if (argv.len == 0) return error.MissingCommand;
    // Log the program name and arity, never the environment. A vendor token
    // in the child env (its own login store) must not appear here.
    log.log(.info, "backend-headless: spawning {s} ({d} arg(s)); credentials stay in the child", .{ argv[0], argv.len });
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd.len > 0) .{ .path = cwd } else .inherit,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.AdapterNotFound,
        else => return err,
    };
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(gpa);
    if (child.stdout) |f| {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = f.readStreaming(io, &.{&buf}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (n == 0) break;
            try stdout.appendSlice(gpa, buf[0..n]);
        }
    }
    const term = child.wait(io) catch return error.SpawnFailed;
    const ok = switch (term) {
        .exited => |c| c == 0,
        else => false,
    };
    return .{
        .stdout = try arena.dupe(u8, std.mem.trim(u8, stdout.items, " \t\r\n")),
        .term_ok = ok,
        .argv = argv,
    };
}

/// What the harness logs about a spawn: program + arity, never env values.
pub fn spawnLogLine(buf: []u8, argv: []const []const u8) []const u8 {
    if (argv.len == 0) return "backend-headless: spawning (0 arg(s)); credentials stay in the child";
    return std.fmt.bufPrint(buf, "backend-headless: spawning {s} ({d} arg(s)); credentials stay in the child", .{ argv[0], argv.len }) catch buf[0..0];
}

test "headless argv is claude -p / codex exec / grok -p" {
    const g = try vendor.headlessArgv(std.testing.allocator, .grok, "p");
    defer std.testing.allocator.free(g);
    try std.testing.expectEqualStrings("grok", g[0]);
    try std.testing.expectEqualStrings("-p", g[1]);

    const c = try vendor.headlessArgv(std.testing.allocator, .claude, "p");
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("claude", c[0]);
    try std.testing.expectEqualStrings("-p", c[1]);

    const x = try vendor.headlessArgv(std.testing.allocator, .codex, "p");
    defer std.testing.allocator.free(x);
    try std.testing.expectEqualStrings("codex", x[0]);
    try std.testing.expectEqualStrings("exec", x[1]);
}

test "spawn log and argv never contain a vendor token from the child environment" {
    const token = "sekrit-token-xyz";
    const argv = [_][]const u8{ "grok", "-p", "hello" };
    var buf: [256]u8 = undefined;
    const line = spawnLogLine(&buf, &argv);
    try std.testing.expect(std.mem.find(u8, line, token) == null);
    for (argv) |a| try std.testing.expect(std.mem.find(u8, a, token) == null);
    // The token may exist in the environment we would inherit; it must not
    // be copied into argv or the log line.
    try std.testing.expect(std.mem.find(u8, line, "spawning grok") != null);
}

test "spawnArgv captures stdout from a helper process, not a vendor CLI" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const argv = [_][]const u8{ "printf", "fake-headless-answer" };
    const result = try spawnArgv(io, std.testing.allocator, arena_state.allocator(), &argv, "");
    try std.testing.expect(result.term_ok);
    try std.testing.expectEqualStrings("fake-headless-answer", result.stdout);
}

test "unknown vendor is not a Name and cannot build argv" {
    try std.testing.expect(vendor.Name.parse("unknown") == null);
    try std.testing.expect(vendor.Name.parse("anthropic") == null);
}
