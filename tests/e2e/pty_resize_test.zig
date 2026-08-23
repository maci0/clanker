//! Operator journey: `clanker repl` on a real pty must survive a SIGWINCH
//! flood — a drag-resize of the terminal window.
//!
//! This is the regression test for the crash in
//! docs/reports/investigations/2026-08-16-tui-resize-crash.md. vaxis used to
//! run its winsize callbacks inside the SIGWINCH handler; those callbacks take
//! a `std.Io.Mutex` and push onto the event queue, and issuing a `std.Io`
//! operation from a signal that interrupted an `Io.Threaded` pool thread mid
//! syscall hits `.blocked => unreachable` in `Syscall.start`. The read thread
//! sits in `readv` on the tty for the process's whole life, so it is the thread
//! the signal lands on.
//!
//! Nothing short of a pty reproduces it: the defect needs a real controlling
//! terminal (vaxis opens `/dev/tty`), a real `TIOCSWINSZ` so the kernel raises
//! the signal, and enough event-queue traffic for the mutex to be contended
//! when it does. Measured on the unfixed build, the crash arrives at roughly
//! 1500 resizes; the flood below runs well past that. A control that sets the
//! *same* size every tick — no size change, so no SIGWINCH — survived 3000
//! ticks unharmed, which is what pins the cause on the signal rather than on
//! the redraw load.

const std = @import("std");
const harness = @import("harness.zig");
const pty_mod = @import("pty.zig");
const posix = std.posix;

fn describe(status: c_int) []const u8 {
    // WIFSIGNALED: low 7 bits hold the signal, and are neither 0 nor 0x7f.
    const sig = status & 0x7f;
    return if (sig != 0 and sig != 0x7f) "killed by a signal" else "exited";
}

test "operator journey: repl survives a SIGWINCH flood on a pty" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try harness.writeMockConfig(io, tmp.dir, gpa, 9);
    try harness.linkZigOut(io, tmp.dir);

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try tmp.dir.realPath(io, cwd_buf[0 .. cwd_buf.len - 1]);
    cwd_buf[cwd_len] = 0;
    const cwd_z: [:0]const u8 = cwd_buf[0..cwd_len :0];

    var pty = try pty_mod.openPty();
    defer pty.close();
    try pty_mod.setWinsize(pty.master, 40, 120);

    const pid = try pty_mod.spawnRepl(&pty, cwd_z, &.{
        "--mascot=loop",
        "--mascot-size=large",
        "--mascot-speed=7",
    });
    defer pty_mod.killAndReap(&pty, pid);

    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(gpa);

    // Query phase: geometry first, then DA1.
    try std.testing.expect(try pty_mod.answerQueries(pty.master, &seen, gpa));

    // Let the repl finish its first paint before touching the size. Answering
    // DA1 ends the *query* phase, not startup; a winsize arriving while the
    // initial layout is still being built gets overwritten by it, and the
    // check below then reads a screen that never grew.
    var warm: usize = 0;
    while (warm < 75) : (warm += 1) {
        if (!try pty_mod.pump(pty.master, &seen, gpa, 20)) break;
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }

    // Prove SIGWINCH reaches the app at all before leaning on the flood. The
    // repl started on a 40-row screen; growing to 60 must make it draw down
    // into rows that did not exist before.
    seen.clearRetainingCapacity();
    try pty_mod.setWinsize(pty.master, 60, 200);
    // Sample for up to ~3s of wall clock. `pump` returns the moment bytes are
    // available and the mascot animates continuously, so a bare iteration
    // count burns through in a fraction of a second and reads the screen
    // before the repl has repainted at the new size.
    var settle_tall: usize = 0;
    while (settle_tall < 150) : (settle_tall += 1) {
        if (!try pty_mod.pump(pty.master, &seen, gpa, 20)) break;
        if (maxRowAddressed(seen.items) > 45) break;
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
    const tall = maxRowAddressed(seen.items);
    if (tall <= 45) std.debug.print(
        "no resize reached the repl: tallest row drawn was {d} after growing to 60 rows\n",
        .{tall},
    );
    try std.testing.expect(tall > 45);

    // Flood. The unfixed build dies around 1500; 4000 leaves clear headroom
    // without making the journey long.
    const sizes = [_][2]u16{
        .{ 40, 120 }, .{ 24, 80 }, .{ 50, 200 }, .{ 30, 100 }, .{ 60, 240 }, .{ 20, 60 },
    };
    var i: usize = 0;
    // Consecutive flood iterations in which the repl accepted none of the
    // typed bytes. A wedged repl -- one that crashed into the recursive-panic
    // hang, say (docs/reports/bugs/2026-08-23-panic-recurses-forever-instead-of-aborting.md)
    // -- stops draining its tty while staying unreapable, so `reapIfDead`
    // below reports it healthy forever and the journey used to hang rather
    // than fail. Each give-up costs `pty.write_timeout_ms`, so this is seconds
    // of the child accepting nothing, not a momentary stall under load.
    var unread: usize = 0;
    while (i < 4000) : (i += 1) {
        const size = sizes[i % sizes.len];
        pty_mod.setWinsize(pty.master, size[0], size[1]) catch break;
        // Keystrokes that never submit a turn: the composer re-lays-out on
        // each one, which is what keeps the event queue contended.
        if (pty_mod.writeAll(pty.master, "abc\x7f")) {
            unread = 0;
        } else {
            unread += 1;
            if (unread >= 5) {
                std.debug.print(
                    "repl stopped reading its tty after {d} resizes (still unreaped, so not a clean crash); " ++
                        "{d} bytes drawn. If this tree has not had scripts/apply-patches.sh run, " ++
                        "vaxis still services SIGWINCH inside the signal handler and this is that crash. " ++
                        "Trace tail:\n{s}\n",
                    .{ i, seen.items.len, tailOf(seen.items) },
                );
                return error.ReplStoppedReadingTty;
            }
        }

        // Pace the flood. SIGWINCH is a standard signal, so a second one
        // raised while the first is still pending is *coalesced*, not queued:
        // resizing as fast as the loop can spin collapses thousands of
        // `TIOCSWINSZ` calls into a handful of deliveries and proves nothing.
        // Leaving ~2ms between changes is what makes each one its own signal.
        var drains: usize = 0;
        while (drains < 8) : (drains += 1) {
            if (!try pty_mod.pump(pty.master, &seen, gpa, 0)) break;
        }
        std.Io.sleep(io, .fromMilliseconds(2), .awake) catch {};
        if (pty_mod.reapIfDead(pid)) |status| {
            std.debug.print(
                "repl died after {d} resizes ({s}); {d} bytes drawn. " ++
                    "CHECK THIS FIRST: `zig-pkg/` is gitignored and therefore " ++
                    "per-worktree, so a fresh worktree runs pristine vaxis, which " ++
                    "still services SIGWINCH inside the signal handler — the exact " ++
                    "crash this journey exists to catch. Run " ++
                    "`scripts/apply-patches.sh` (it reports how many it applied) and " ++
                    "re-run before reading this as a regression; a death within the " ++
                    "first few dozen resizes is that, not a code change. " ++
                    "Trace tail:\n{s}\n",
                .{ i, describe(status), seen.items.len, tailOf(seen.items) },
            );
            return error.ReplCrashedOnResize;
        }
        // The transcript is not what this test asserts on; cap it so a long
        // flood cannot grow the buffer without bound.
        if (seen.items.len > 1 << 20) seen.clearRetainingCapacity();
    }

    try std.testing.expect(pty_mod.reapIfDead(pid) == null);
    std.debug.print("pass: operator journey: repl survives a SIGWINCH flood on a pty\n", .{});
}

fn tailOf(bytes: []const u8) []const u8 {
    const want = 2000;
    return if (bytes.len > want) bytes[bytes.len - want ..] else bytes;
}

/// Highest row any `CSI row;col H` cursor move addresses. This is how the test
/// reads back which geometry the app believes it is on: a handler that silently
/// dropped every resize would survive the flood just as happily as a fixed one,
/// so "it did not crash" is only meaningful next to "and it saw the resizes".
///
/// Rows, not columns: the repl anchors its composer to the bottom of the
/// screen, so the tallest row it addresses tracks the height on every frame.
/// Columns do not work — with an empty transcript nothing is drawn out at the
/// right edge, so the widest column stays where the mascot ends no matter how
/// wide the window gets.
fn maxRowAddressed(bytes: []const u8) u32 {
    var best: u32 = 0;
    var i: usize = 0;
    while (i + 2 < bytes.len) : (i += 1) {
        if (bytes[i] != 0x1b or bytes[i + 1] != '[') continue;
        var j = i + 2;
        var row: u32 = 0;
        while (j < bytes.len and std.ascii.isDigit(bytes[j])) : (j += 1)
            row = row * 10 + (bytes[j] - '0');
        if (j >= bytes.len or bytes[j] != ';' or j == i + 2) continue;
        j += 1;
        const col_start = j;
        var col: u32 = 0;
        while (j < bytes.len and std.ascii.isDigit(bytes[j])) : (j += 1)
            col = col * 10 + (bytes[j] - '0');
        if (j >= bytes.len or bytes[j] != 'H' or j == col_start) continue;
        if (row > best) best = row;
    }
    return best;
}
