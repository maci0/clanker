//! Multiline input box: wraps `lineedit.Editor` with terminal-width-aware
//! row wrapping and a redraw that repaints exactly the rows the box
//! occupies, generalizing the REPL's old single-line `\r\x1b[K` trick to N
//! rows. `lineedit.Editor` itself is unchanged — this module only adds the
//! rendering the editor deliberately has none of.
//!
//! Wrapping is hard (mid-word) rather than word-aware: this is a fixed-width
//! input box, not a prose editor, and the line being typed is usually a
//! task description or a slash command, not prose that needs to read well
//! wrapped. Word-wrap can be added later if it's ever missed.

const std = @import("std");
const lineedit = @import("../util/lineedit.zig");
const width = @import("width.zig");

/// Used when the terminal size can't be queried (should not happen once
/// `readLineRaw` is only entered on a real tty, but a safe fallback beats a
/// crash if it ever is).
pub const default_cols: usize = 80;

/// Reads raw bytes from `stdin_file` until `lineedit.decode` resolves a
/// whole key, holding onto partial escape sequences across reads the same
/// way the main input loop always has. Shared by the main input loop and
/// any other raw-mode reader (e.g. the approval prompt) so there is exactly
/// one place that turns bytes into keys, not one per caller. `null` means
/// the stream ended (fd EOF, not the decoded `.eof` key).
pub fn readKey(stdin_file: std.Io.File) !?lineedit.Key {
    var pending: [64]u8 = undefined;
    var pending_len: usize = 0;
    while (true) {
        var byte: [1]u8 = undefined;
        const n = std.posix.read(stdin_file.handle, &byte) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return null;
        if (pending_len == pending.len) pending_len = 0; // never seen; stay safe
        pending[pending_len] = byte[0];
        pending_len += 1;

        const decoded = lineedit.decode(pending[0..pending_len]) orelse continue;
        return decoded.key;
    }
}

pub const Wrapped = struct {
    rows: []const []const u8,
    cursor_row: usize,
    cursor_col: usize,
};

/// Splits `text` (which may contain literal `\n` from a bracketed paste)
/// into the display rows it occupies at `cols` columns, and locates the
/// cursor (a byte offset into `text`) as a (row, col) pair in display
/// columns. `first_row_extra` is the width already spent on row 0 before any
/// text (the prompt), so the first row wraps sooner than the rest.
pub fn wrap(arena: std.mem.Allocator, text: []const u8, cursor: usize, cols: usize, first_row_extra: usize) !Wrapped {
    var rows: std.ArrayList([]const u8) = .empty;
    var cursor_row: usize = 0;
    var cursor_col: usize = 0;
    var found_cursor = false;
    var row_idx: usize = 0;
    var byte_off: usize = 0;

    var logical_it = std.mem.splitScalar(u8, text, '\n');
    while (logical_it.next()) |logical| {
        var row_start: usize = 0;
        var row_width: usize = 0;
        var avail: usize = if (row_idx == 0 and cols > first_row_extra) cols - first_row_extra else if (row_idx == 0) 1 else cols;
        if (avail == 0) avail = 1;
        var i: usize = 0;
        while (i < logical.len) {
            const cp_len = std.unicode.utf8ByteSequenceLength(logical[i]) catch 1;
            const end = @min(i + cp_len, logical.len);
            const cp = std.unicode.utf8Decode(logical[i..end]) catch 0;
            const w = if (cp == 0) 1 else width.codepointWidth(cp);
            const abs = byte_off + i;
            if (!found_cursor and abs == cursor) {
                cursor_row = row_idx;
                cursor_col = row_width;
                found_cursor = true;
            }
            if (row_width + w > avail and row_width > 0) {
                try rows.append(arena, logical[row_start..i]);
                row_idx += 1;
                row_start = i;
                row_width = 0;
                avail = cols;
            }
            row_width += w;
            i = end;
        }
        if (!found_cursor and byte_off + logical.len == cursor) {
            cursor_row = row_idx;
            cursor_col = row_width;
            found_cursor = true;
        }
        try rows.append(arena, logical[row_start..]);
        row_idx += 1;
        byte_off += logical.len + 1;
    }
    if (rows.items.len == 0) try rows.append(arena, "");
    return .{ .rows = rows.items, .cursor_row = cursor_row, .cursor_col = cursor_col };
}

pub const Frame = struct {
    rows: []const []const u8,
    cursor_row: usize,
    cursor_col: usize,
};

/// Builds the rows the input box occupies at `cols` columns, with `prompt`
/// printed literally before row 0's text. `prompt_width` is the prompt's
/// display width and is passed separately from `prompt` because `prompt`
/// carries ANSI styling bytes that aren't visible columns — measuring the
/// raw string would overcount by the length of the escape codes.
///
/// Returns rows ready to hand to `region.BottomRegion.render` alongside a
/// status bar's rows; this module has no terminal I/O of its own.
pub fn frame(arena: std.mem.Allocator, editor: *const lineedit.Editor, cols: usize, prompt: []const u8, prompt_width: usize) !Frame {
    const w = try wrap(arena, editor.line(), editor.cursor, cols, prompt_width);
    var rows = try arena.alloc([]const u8, w.rows.len);
    rows[0] = try std.mem.concat(arena, u8, &.{ prompt, w.rows[0] });
    for (w.rows[1..], 1..) |r, i| rows[i] = r;
    const cursor_col = if (w.cursor_row == 0) w.cursor_col + prompt_width else w.cursor_col;
    return .{ .rows = rows, .cursor_row = w.cursor_row, .cursor_col = cursor_col };
}

test "frame prepends the prompt to row 0 only, and offsets its cursor column" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ed = lineedit.Editor{ .gpa = std.testing.allocator };
    defer ed.deinit();
    for ("hi") |c| _ = ed.apply(.{ .char = c });

    const f = try frame(arena_state.allocator(), &ed, 80, "\x1b[32m$ \x1b[0m", 2);
    try std.testing.expectEqual(@as(usize, 1), f.rows.len);
    try std.testing.expectEqualStrings("\x1b[32m$ \x1b[0mhi", f.rows[0]);
    try std.testing.expectEqual(@as(usize, 0), f.cursor_row);
    try std.testing.expectEqual(@as(usize, 4), f.cursor_col); // 2 (prompt) + 2 (cursor after "hi")
}

test "short line fits on one row" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const w = try wrap(arena_state.allocator(), "hello", 5, 80, 9);
    try std.testing.expectEqual(@as(usize, 1), w.rows.len);
    try std.testing.expectEqualStrings("hello", w.rows[0]);
    try std.testing.expectEqual(@as(usize, 0), w.cursor_row);
    try std.testing.expectEqual(@as(usize, 5), w.cursor_col);
}

test "long line wraps at the available width" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // cols=10, first_row_extra=9 -> row 0 has 1 col available, rest 10.
    const w = try wrap(arena_state.allocator(), "abcdefghijk", 0, 10, 9);
    try std.testing.expectEqual(@as(usize, 2), w.rows.len);
    try std.testing.expectEqualStrings("a", w.rows[0]);
    try std.testing.expectEqualStrings("bcdefghijk", w.rows[1]);
}

test "embedded newline from a paste starts a new row" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const w = try wrap(arena_state.allocator(), "line one\nline two", 0, 80, 9);
    try std.testing.expectEqual(@as(usize, 2), w.rows.len);
    try std.testing.expectEqualStrings("line one", w.rows[0]);
    try std.testing.expectEqualStrings("line two", w.rows[1]);
}

test "cursor position lands on the row and column it visually sits on" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // "line one\nline two", cursor at byte 12 -> "line " into row 1, col 3 ('e' of "line").
    const w = try wrap(arena_state.allocator(), "line one\nline two", 12, 80, 9);
    try std.testing.expectEqual(@as(usize, 1), w.cursor_row);
    try std.testing.expectEqual(@as(usize, 3), w.cursor_col);
}

test "cursor at the very end of the text is still located" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const w = try wrap(arena_state.allocator(), "abc", 3, 80, 9);
    try std.testing.expectEqual(@as(usize, 0), w.cursor_row);
    try std.testing.expectEqual(@as(usize, 3), w.cursor_col);
}

test "wide codepoints consume two columns when wrapping" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // Five CJK ideographs (2 cols each = 10) at cols=8, first_row_extra=0:
    // row 0 fits 4 (8 cols), the 5th spills to row 1.
    const w = try wrap(arena_state.allocator(), "\xe4\xb8\xad\xe4\xb8\xad\xe4\xb8\xad\xe4\xb8\xad\xe4\xb8\xad", 0, 8, 0);
    try std.testing.expectEqual(@as(usize, 2), w.rows.len);
}
