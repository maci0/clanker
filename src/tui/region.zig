//! A small fixed-height region at the bottom of the terminal (status bar +
//! input box, later a palette/approval overlay) that repaints itself in
//! place: only rows whose content actually changed are rewritten, using
//! relative cursor moves that never touch what has scrolled above it.
//!
//! This generalizes the REPL's old single-line `\r\x1b[K` redraw to N rows
//! with real diffing instead of a full repaint every time. The transcript
//! above this region is never redrawn by this module — it is print-once
//! text that scrolls with the terminal, which is why this region only needs
//! to know its own previous frame, not the whole screen.

const std = @import("std");

/// Rewrites exactly the rows that differ between `prev` and `next`, then
/// parks the cursor at (cursor_row, cursor_col) — a display-column offset
/// from the start of that row. Assumes the terminal cursor is currently at
/// row `prev_cursor_row` of this same region (wherever the last call to
/// `diff`, or the region's own start, left it); a caller that prints
/// anything else in between (a cleared screen, a printed line) must treat
/// the next call as a fresh region (`prev = &.{}`, `prev_cursor_row = 0`)
/// rather than diffing against stale content.
///
/// No allocation: this is pure enough to unit-test without a terminal.
pub fn diff(
    w: *std.Io.Writer,
    prev: []const []const u8,
    next: []const []const u8,
    prev_cursor_row: usize,
    cursor_row: usize,
    cursor_col: usize,
) !void {
    if (prev_cursor_row > 0) try w.print("\x1b[{d}A", .{prev_cursor_row});
    try w.writeAll("\r");

    const total = @max(prev.len, next.len);
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const old: ?[]const u8 = if (i < prev.len) prev[i] else null;
        const new: []const u8 = if (i < next.len) next[i] else "";
        const changed = old == null or !std.mem.eql(u8, old.?, new);
        if (changed) {
            try w.writeAll("\x1b[K");
            try w.writeAll(new);
        }
        // Moves within the region only (never a bare `\n`, which can scroll
        // the whole terminal if the region sits on its last row).
        if (i + 1 < total) try w.writeAll("\x1b[1B\r");
    }

    const last = if (total == 0) 0 else total - 1;
    if (last > cursor_row) try w.print("\x1b[{d}A", .{last - cursor_row});
    try w.writeAll("\r");
    if (cursor_col > 0) try w.print("\x1b[{d}C", .{cursor_col});
}

/// Owns the previous frame so callers don't have to: pass the new frame's
/// lines to `render` every time and it figures out what changed.
pub const BottomRegion = struct {
    gpa: std.mem.Allocator,
    prev_lines: std.ArrayList([]u8) = .empty,
    prev_cursor_row: usize = 0,

    pub fn deinit(self: *BottomRegion) void {
        for (self.prev_lines.items) |l| self.gpa.free(l);
        self.prev_lines.deinit(self.gpa);
    }

    /// Forgets the previous frame: the next `render` draws every row fresh
    /// instead of diffing against content the terminal no longer shows
    /// (e.g. after `\x1b[2J`, or after printing a line above the region).
    pub fn reset(self: *BottomRegion) void {
        for (self.prev_lines.items) |l| self.gpa.free(l);
        self.prev_lines.clearRetainingCapacity();
        self.prev_cursor_row = 0;
    }

    /// How many rows the last `render` call drew — for a caller that needs
    /// to move the cursor past the region before printing something outside
    /// it (e.g. a final result line after a shrinking/growing prompt).
    pub fn lineCount(self: *const BottomRegion) usize {
        return self.prev_lines.items.len;
    }

    pub fn render(self: *BottomRegion, w: *std.Io.Writer, lines: []const []const u8, cursor_row: usize, cursor_col: usize) !void {
        try diff(w, self.prev_lines.items, lines, self.prev_cursor_row, cursor_row, cursor_col);

        for (self.prev_lines.items) |l| self.gpa.free(l);
        self.prev_lines.clearRetainingCapacity();
        for (lines) |l| try self.prev_lines.append(self.gpa, try self.gpa.dupe(u8, l));
        self.prev_cursor_row = cursor_row;
    }
};

// ------------------------------------------------------------------- tests --

fn captured(a: *std.Io.Writer.Allocating) []const u8 {
    return a.written();
}

test "first frame draws every row, nothing skipped" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try diff(&out.writer, &.{}, &.{ "status", "input" }, 0, 1, 0);
    const bytes = captured(&out);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "status") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "input") != null);
}

test "unchanged row is not rewritten" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const prev = [_][]const u8{ "status", "input" };
    try diff(&out.writer, &prev, &.{ "status", "input2" }, 0, 1, 0);
    const bytes = captured(&out);
    // The unchanged row's content shouldn't be re-emitted with a clear
    // before it — only the changed row gets an erase-to-EOL + rewrite.
    var clears: usize = 0;
    var it = std.mem.window(u8, bytes, 3, 1);
    while (it.next()) |w| {
        if (std.mem.eql(u8, w, "\x1b[K")) clears += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), clears);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "input2") != null);
}

test "shrinking to fewer rows clears the leftover row" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const prev = [_][]const u8{ "status", "row one", "row two" };
    try diff(&out.writer, &prev, &.{ "status", "row one" }, 0, 1, 0);
    const bytes = captured(&out);
    // Three rows still get visited (total = max(3,2)=3): the leftover third
    // row is cleared even though `next` has nothing for it.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[2A") != null or std.mem.indexOf(u8, bytes, "\x1b[K") != null);
}

test "cursor parks at the requested row and column" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try diff(&out.writer, &.{}, &.{ "status", "clanker> hi" }, 0, 1, 11);
    const bytes = captured(&out);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[11C") != null);
}

test "BottomRegion.render diffs against its own remembered previous frame" {
    var region = BottomRegion{ .gpa = std.testing.allocator };
    defer region.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try region.render(&out.writer, &.{ "status: idle", "clanker> " }, 1, 9);
    out.clearRetainingCapacity();
    try region.render(&out.writer, &.{ "status: idle", "clanker> a" }, 1, 10);
    const bytes = captured(&out);
    // Second render only touches the input row, not the unchanged status row.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "clanker> a") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "status: idle") == null);
}

test "reset forgets the previous frame so the next render starts fresh" {
    var region = BottomRegion{ .gpa = std.testing.allocator };
    defer region.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try region.render(&out.writer, &.{"one"}, 0, 0);
    region.reset();
    out.clearRetainingCapacity();
    try region.render(&out.writer, &.{"one"}, 0, 0);
    // Same content as before reset, but reset forces a full redraw of it.
    const bytes = captured(&out);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "one") != null);
}
