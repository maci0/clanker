//! Scripted, deterministic end-to-end sessions against the real
//! `zig-out/bin/clanker repl` binary over a real pty (see pty.zig). This is
//! the layer above the pure unit tests everywhere else in `src/tui/`: those
//! prove the logic (wrap math, region diffing, completion) in isolation,
//! this proves the actual terminal I/O wiring — raw mode, key decoding,
//! redraw — end to end, the same way a human typing at a real terminal
//! would exercise it.
//!
//! Only for `zig build tui-test`. None of this runs under `zig build test`:
//! spawning a real process over a real pty is slow and POSIX-only in a way
//! the fast, always-green unit-test gate must not depend on.
//!
//! No LLM calls: every scripted line here is answered entirely inside the
//! REPL's own input handling (a bad `/session switch`, a Tab completion, an
//! unrecognized command) — never a task that would trigger `a.run()` and
//! spend real API credits just to prove the terminal renders correctly.

const std = @import("std");
const posix = std.posix;
const pty_mod = @import("pty.zig");
const Pty = pty_mod.Pty;

const clanker_bin = "./zig-out/bin/clanker";
const overall_deadline_ms: i32 = 15000;

/// Polls and reads from `pty` until `accum` contains `needle` or the
/// deadline elapses. Bounded so a stuck child fails the test instead of
/// hanging the whole `zig build tui-test` run.
fn readUntilContains(pty: *Pty, accum: *std.ArrayList(u8), gpa: std.mem.Allocator, needle: []const u8) !void {
    if (std.mem.indexOf(u8, accum.items, needle) != null) return;
    var fds = [_]posix.pollfd{.{ .fd = pty.master, .events = posix.POLL.IN, .revents = 0 }};
    var waited_ms: i32 = 0;
    var buf: [4096]u8 = undefined;
    while (waited_ms < overall_deadline_ms) {
        const step_ms: i32 = 200;
        const n = posix.poll(&fds, step_ms) catch break;
        waited_ms += step_ms;
        if (n == 0) continue;
        const read_n = pty.read(&buf) catch break;
        if (read_n == 0) break;
        try accum.appendSlice(gpa, buf[0..read_n]);
        if (std.mem.indexOf(u8, accum.items, needle) != null) return;
    }
    std.debug.print("NeedleNotFound: {any}\naccum so far: {s}\n", .{ needle, accum.items });
    return error.NeedleNotFound;
}

fn spawnRepl(arena: std.mem.Allocator, envp: [*:null]const ?[*:0]const u8) !Pty {
    // This suite drives src/tui/*'s specific behaviors (cards, palette,
    // approval widget) — "repl-legacy" now that "repl" is the vaxis REPL
    // (src/tui2/repl_vaxis.zig), which none of that exists in yet.
    const argv = try pty_mod.buildArgv(arena, &.{ clanker_bin, "repl-legacy" });
    return Pty.spawn(clanker_bin, argv, envp, 80, 24);
}

test "a spawned session shows the REPL banner" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var pty = try spawnRepl(arena_state.allocator(), std.testing.environ.block.slice.ptr);
    defer pty.close();

    var accum: std.ArrayList(u8) = .empty;
    defer accum.deinit(gpa);
    try readUntilContains(&pty, &accum, gpa, "clanker> ");

    _ = try pty.signal(posix.SIG.KILL);
    _ = try pty.wait();
}

test "Tab completes a unique slash command" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var pty = try spawnRepl(arena_state.allocator(), std.testing.environ.block.slice.ptr);
    defer pty.close();

    var accum: std.ArrayList(u8) = .empty;
    defer accum.deinit(gpa);
    try readUntilContains(&pty, &accum, gpa, "clanker> ");

    _ = try pty.write("/he\t");
    accum.clearRetainingCapacity();
    try readUntilContains(&pty, &accum, gpa, "help ");

    _ = try pty.signal(posix.SIG.KILL);
    _ = try pty.wait();
}

test "an invalid /session switch reports the error and keeps the prompt usable" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var pty = try spawnRepl(arena_state.allocator(), std.testing.environ.block.slice.ptr);
    defer pty.close();

    var accum: std.ArrayList(u8) = .empty;
    defer accum.deinit(gpa);
    try readUntilContains(&pty, &accum, gpa, "clanker> ");

    _ = try pty.write("/session switch this-session-does-not-exist\r");
    accum.clearRetainingCapacity();
    try readUntilContains(&pty, &accum, gpa, "no such session");

    // The prompt must still be usable after the error — type something and
    // see it echoed back by the input box, proving the loop kept running.
    _ = try pty.write("x");
    accum.clearRetainingCapacity();
    // Not "clanker> x": the prompt's color reset (`\x1b[0m`) sits between
    // the prompt text and the typed character in the real byte stream.
    try readUntilContains(&pty, &accum, gpa, "\x1b[0mx");

    _ = try pty.signal(posix.SIG.KILL);
    _ = try pty.wait();
}

test "Ctrl-C clears the line instead of killing the process" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var pty = try spawnRepl(arena_state.allocator(), std.testing.environ.block.slice.ptr);
    defer pty.close();

    var accum: std.ArrayList(u8) = .empty;
    defer accum.deinit(gpa);
    try readUntilContains(&pty, &accum, gpa, "clanker> ");

    _ = try pty.write("unfinished");
    accum.clearRetainingCapacity();
    try readUntilContains(&pty, &accum, gpa, "unfinished");

    _ = try pty.write("\x03"); // Ctrl-C
    accum.clearRetainingCapacity();
    try readUntilContains(&pty, &accum, gpa, "^C");

    // Still alive: another keystroke gets a normal redraw, not a dead pty.
    _ = try pty.write("y");
    accum.clearRetainingCapacity();
    try readUntilContains(&pty, &accum, gpa, "\x1b[0my");

    _ = try pty.signal(posix.SIG.KILL);
    _ = try pty.wait();
}
