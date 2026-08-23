//! Operator journey: typing a `/` prefix into the repl composer previews the
//! matching commands — spelling, argument hint, and help — above the input
//! box, before Tab or Enter is pressed. `/go` must put `/goal` and its help
//! on screen; a bare `/` must open the discovery list with its "more" pointer
//! at the palette.
//!
//! The assertions read the *screen*, not internal state: the pty byte stream
//! is stripped of escape sequences and searched for the preview's text. The
//! composer only ever echoes what was typed (`/go`), so the full spelling
//! `/goal` and its help line can only have come from the preview rows.

const std = @import("std");
const harness = @import("harness.zig");
const pty_mod = @import("pty.zig");
const posix = std.posix;

/// Strips ANSI escape sequences (CSI, OSC, DCS, and lone ESC pairs), keeping
/// printable bytes. vaxis writes each cell's grapheme with cursor moves and
/// style changes in between; row-major diff order keeps a row's text in
/// stream order, so after stripping, a drawn string is a contiguous match.
fn plainText(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b != 0x1b) {
            if (b >= 0x20 or b == '\n') try out.append(gpa, b);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= bytes.len) break;
        switch (bytes[i]) {
            '[' => {
                // CSI: parameters and intermediates, then one final byte in
                // 0x40..0x7e.
                i += 1;
                while (i < bytes.len and (bytes[i] < 0x40 or bytes[i] > 0x7e)) : (i += 1) {}
                if (i < bytes.len) i += 1;
            },
            ']', 'P', '_', '^', 'X' => {
                // OSC/DCS/APC/PM/SOS: run to BEL or ST (ESC \).
                i += 1;
                while (i < bytes.len) : (i += 1) {
                    if (bytes[i] == 0x07) {
                        i += 1;
                        break;
                    }
                    if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
            },
            else => i += 1,
        }
    }
    return out.toOwnedSlice(gpa);
}

test "plainText strips CSI, OSC and DCS but keeps drawn text" {
    const gpa = std.testing.allocator;
    const stripped = try plainText(gpa, "\x1b[2;3H/go\x1b[0mal\x1b]0;title\x07 rest\x1bP0;1q...\x1b\\!");
    defer gpa.free(stripped);
    try std.testing.expectEqualStrings("/goal rest!", stripped);
}

/// Removes every space. vaxis is free to *skip* blank cells and cursor-jump
/// across them instead of writing them, so the stripped stream drops word
/// gaps unpredictably ("Type a task" arrives as "Typeatask" on some frames).
/// Matching with both sides despaced is what stays stable across that choice.
fn despace(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (s) |b| if (b != ' ') try out.append(gpa, b);
    return out.toOwnedSlice(gpa);
}

/// Pumps the pty until the stripped, despaced screen contains `needle`
/// (also despaced), or ~`ticks` * 20ms of wall clock pass. Returns whether
/// it was found.
fn pumpUntilShown(
    io: std.Io,
    master: posix.fd_t,
    seen: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    needle: []const u8,
    ticks: usize,
) !bool {
    const needle_ns = try despace(gpa, needle);
    defer gpa.free(needle_ns);
    var i: usize = 0;
    while (i < ticks) : (i += 1) {
        if (!try pty_mod.pump(master, seen, gpa, 20)) return false;
        const plain = try plainText(gpa, seen.items);
        defer gpa.free(plain);
        const plain_ns = try despace(gpa, plain);
        defer gpa.free(plain_ns);
        if (std.mem.find(u8, plain_ns, needle_ns) != null) return true;
        std.Io.sleep(io, .fromMilliseconds(20), .awake) catch {};
    }
    return false;
}

test "operator journey: typing a / prefix previews matching commands with their help" {
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
    // Wide enough that a preview row's name + help fit without clipping.
    try pty_mod.setWinsize(pty.master, 40, 160);

    const pid = try pty_mod.spawnRepl(&pty, cwd_z, &.{"--mascot=off"});
    defer pty_mod.killAndReap(&pty, pid);

    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(gpa);

    try std.testing.expect(try pty_mod.answerQueries(pty.master, &seen, gpa));

    // First paint done = the empty-state hint is on screen.
    try std.testing.expect(try pumpUntilShown(io, pty.master, &seen, gpa, "Type a task to begin", 250));

    // Each step below types, then *resizes by one row* before asserting.
    // vaxis diffs cell-by-cell, so a preview row replacing an earlier one
    // reaches the stream as fragments (only the changed cells are written);
    // a resize forces the full repaint that makes the row's text contiguous
    // in the stream. The preview itself survives the resize because it is
    // re-derived from the composer text on every frame.
    var rows: u16 = 40;

    // Bare "/" opens the discovery list: the first registry rows and the
    // "more" pointer at the palette (24 commands never fit the cap).
    _ = pty_mod.writeAll(pty.master, "/");
    rows += 1;
    try pty_mod.setWinsize(pty.master, rows, 160);
    try std.testing.expect(try pumpUntilShown(io, pty.master, &seen, gpa, "show this help", 250));
    try std.testing.expect(try pumpUntilShown(io, pty.master, &seen, gpa, "Ctrl-P opens the full palette", 50));

    // "/go" narrows the preview to /goal: full spelling, argument hint, and
    // help, none of which the composer echo could have produced.
    seen.clearRetainingCapacity();
    _ = pty_mod.writeAll(pty.master, "go");
    rows -= 1;
    try pty_mod.setWinsize(pty.master, rows, 160);
    try std.testing.expect(try pumpUntilShown(io, pty.master, &seen, gpa, "/goal <completion condition>", 250));
    try std.testing.expect(try pumpUntilShown(io, pty.master, &seen, gpa, "start a goal loop until achieved or blocked", 50));

    // Typed arguments keep the matched command's row on screen as a
    // signature hint (a different command than /goal, so a stale frame
    // cannot satisfy the assertion).
    seen.clearRetainingCapacity();
    _ = pty_mod.writeAll(pty.master, "\x15/search embedded cache"); // Ctrl-U clears the draft first
    rows += 1;
    try pty_mod.setWinsize(pty.master, rows, 160);
    try std.testing.expect(try pumpUntilShown(io, pty.master, &seen, gpa, "search saved conversations", 250));

    // A row wider than the terminal is clipped with an ellipsis at the last
    // whole word, not stopped dead mid-word: /model's help no longer fits a
    // 60-column terminal, so the tail after the cut must not appear and the
    // mark must.
    seen.clearRetainingCapacity();
    _ = pty_mod.writeAll(pty.master, "\x15/model");
    rows += 1;
    try pty_mod.setWinsize(pty.master, rows, 60);
    try std.testing.expect(try pumpUntilShown(io, pty.master, &seen, gpa, "/model [query]", 250));
    {
        const plain = try plainText(gpa, seen.items);
        defer gpa.free(plain);
        const plain_ns = try despace(gpa, plain);
        defer gpa.free(plain_ns);
        try std.testing.expect(std.mem.find(u8, plain_ns, "Esc cancels") == null);
        try std.testing.expect(std.mem.find(u8, plain_ns, "\xe2\x80\xa6") != null);
    }

    try std.testing.expect(pty_mod.reapIfDead(pid) == null);
    std.debug.print("pass: operator journey: typing a / prefix previews matching commands with their help\n", .{});
}
