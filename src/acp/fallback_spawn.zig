//! First-party headless spawn for a vendor CLI (RFC 0020 option B).
//!
//! `claude -p`, `codex exec`, `grok -p`. Native harness spawn — not ck_exec,
//! not ck_job. Used when the vendor has no ACP path, ACP hangs, or a vendor
//! update breaks ACP.

const std = @import("std");
const builtin = @import("builtin");
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
    // Every exit from here reaps the child, not only the happy one: an early
    // return on a copy or read error used to skip `wait`, leaving the helper
    // alive (blocked writing into a full pipe this process still holds open)
    // or zombied until process exit. `kill` signals and reaps in one call,
    // and a child that already exited takes a harmless SIGKILL on the way to
    // its wait.
    var waited = false;
    defer if (!waited) child.kill(io);
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
    waited = true;
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

test "spawnArgv does not log a token present in the child environment" {
    var tenv: @import("../util/test_env.zig").Env = .init();
    defer tenv.deinit();
    const io = tenv.io();
    const arena = tenv.arena();
    const token = "sekrit-token-xyz-headless";
    const script = try std.fmt.allocPrint(arena,
        \\#!/bin/sh
        \\export SEKRIT_VENDOR_TOKEN={s}
        \\printf %s "$SEKRIT_VENDOR_TOKEN" > "$1"
        \\printf ok
        \\
    , .{token});
    try tenv.tmp.dir.writeFile(io, .{ .sub_path = "wrap.sh", .data = script });
    const wrap = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/wrap.sh", .{tenv.tmp.sub_path});
    const probe = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/probe", .{tenv.tmp.sub_path});

    const LogBuf = struct {
        mu: std.atomic.Mutex = .unlocked,
        bytes: std.ArrayList(u8) = .empty,
        alloc: std.mem.Allocator,
        fn write(ctx: *const anyopaque, line: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(@constCast(ctx)));
            while (!self.mu.tryLock()) {
                std.Thread.yield() catch {};
            }
            defer self.mu.unlock();
            self.bytes.appendSlice(self.alloc, line) catch {};
        }
    };
    var logs = LogBuf{ .alloc = std.testing.allocator };
    defer logs.bytes.deinit(std.testing.allocator);
    log.setSink(.{ .ctx = @ptrCast(&logs), .write = LogBuf.write });
    defer log.setSink(null);

    const argv = [_][]const u8{ "sh", wrap, probe };
    const result = try spawnArgv(io, std.testing.allocator, arena, &argv, "");
    try std.testing.expect(result.term_ok);
    try std.testing.expect(std.mem.find(u8, logs.bytes.items, token) == null);
    for (argv) |a| try std.testing.expect(std.mem.find(u8, a, token) == null);
    const inherited = try tenv.tmp.dir.readFileAlloc(io, "probe", std.testing.allocator, .limited(256));
    defer std.testing.allocator.free(inherited);
    try std.testing.expectEqualStrings(token, inherited);
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

test "spawnArgv reaps the child when copying its output fails" {
    // The no-survivors assertion reads /proc, which is Linux-only.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    // Fails the first allocation it sees. In spawnArgv that is the first
    // output-chunk copy, exactly the path that used to return before the
    // child was waited: the helper stayed alive (blocked writing into a full
    // pipe this process still held open) or unreaped until process exit.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const argv = [_][]const u8{ "sh", "-c", "printf 'x%.0s' $(seq 1 40000)" };

    const result = spawnArgv(io, failing.allocator(), arena_state.allocator(), &argv, "");
    try std.testing.expectError(error.OutOfMemory, result);

    // No child of this process survives the failed copy, alive or zombied.
    const self_pid = std.os.linux.getpid();
    var survivors: usize = 0;
    var proc = std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch return error.SkipZigTest;
    defer proc.close(io);
    var it = proc.iterate();
    while (it.next(io) catch null) |entry| {
        // No kind filter: /proc entries come back DT_UNKNOWN, not .directory.
        _ = std.fmt.parseInt(i32, entry.name, 10) catch continue;
        var sb: [64]u8 = undefined;
        const sp = std.fmt.bufPrint(&sb, "{s}/stat", .{entry.name}) catch continue;
        var f = proc.openFile(io, sp, .{}) catch continue;
        defer f.close(io);
        // readFileAlloc is wrong here: /proc files report st_size 0 and it
        // comes back empty. Read to EOF into a fixed buffer instead.
        var raw: [512]u8 = undefined;
        var end: usize = 0;
        while (end < raw.len) {
            const got = f.readStreaming(io, &.{raw[end..]}) catch break;
            if (got == 0) break;
            end += got;
        }
        const stat = raw[0..end];
        // comm can carry spaces and parens; fields resume after the last ')'.
        const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse continue;
        var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
        _ = fields.next() orelse continue; // state
        const ppid_text = fields.next() orelse continue;
        const ppid = std.fmt.parseInt(i32, ppid_text, 10) catch continue;
        if (ppid == self_pid) survivors += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), survivors);
}
