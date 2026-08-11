//! A small raw-mode line editor for the REPL: arrow keys, history recall and
//! the usual control-key edits.
//!
//! A cooked terminal hands the program whole lines and swallows nothing, which
//! is why arrow keys did nothing but leave `^[[A` in the buffer. Raw mode
//! means every keystroke arrives here instead, and this module is what turns
//! them back into a line.
//!
//! Only used when stdin is a TTY. Piped input keeps the plain read loop, so
//! scripts and the improvement loop are unaffected.

const std = @import("std");

pub const max_line = 8192;
/// Kept small deliberately: this is recall, not an audit log.
pub const max_history = 500;

/// What a keystroke means to the editor. Parsing bytes into this is the part
/// worth testing; drawing and terminal modes are not.
pub const Key = union(enum) {
    char: u8,
    enter,
    backspace,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
    kill_to_end,
    kill_to_start,
    kill_word,
    interrupt,
    eof,
    /// A byte sequence this editor has no meaning for.
    ignored,
};

/// A decoded key and the bytes it consumed.
pub const Decoded = struct { key: Key, len: usize };

/// Decodes the next key from `buf`. A partial escape sequence consumes nothing
/// and reports `null`, so the caller can read more bytes and try again.
pub fn decode(buf: []const u8) ?Decoded {
    if (buf.len == 0) return null;
    const c = buf[0];
    return switch (c) {
        '\r', '\n' => .{ .key = .enter, .len = 1 },
        0x7f, 0x08 => .{ .key = .backspace, .len = 1 },
        0x01 => .{ .key = .home, .len = 1 }, // Ctrl-A
        0x03 => .{ .key = .interrupt, .len = 1 }, // Ctrl-C
        0x04 => .{ .key = .eof, .len = 1 }, // Ctrl-D
        0x05 => .{ .key = .end, .len = 1 }, // Ctrl-E
        0x0b => .{ .key = .kill_to_end, .len = 1 }, // Ctrl-K
        0x15 => .{ .key = .kill_to_start, .len = 1 }, // Ctrl-U
        0x17 => .{ .key = .kill_word, .len = 1 }, // Ctrl-W
        0x1b => decodeEscape(buf),
        else => if (c >= 0x20) .{ .key = .{ .char = c }, .len = 1 } else .{ .key = .ignored, .len = 1 },
    };
}

fn decodeEscape(buf: []const u8) ?Decoded {
    // ESC alone may still become a sequence: wait for more bytes.
    if (buf.len < 3) return null;
    if (buf[1] != '[' and buf[1] != 'O') return .{ .key = .ignored, .len = 2 };
    return switch (buf[2]) {
        'A' => .{ .key = .up, .len = 3 },
        'B' => .{ .key = .down, .len = 3 },
        'C' => .{ .key = .right, .len = 3 },
        'D' => .{ .key = .left, .len = 3 },
        'H' => .{ .key = .home, .len = 3 },
        'F' => .{ .key = .end, .len = 3 },
        // "ESC [ <n> ~": Home/End/Delete on the other common encoding.
        '1'...'8' => {
            if (buf.len < 4) return null;
            if (buf[3] != '~') return .{ .key = .ignored, .len = 4 };
            return switch (buf[2]) {
                '1', '7' => .{ .key = .home, .len = 4 },
                '3' => .{ .key = .delete, .len = 4 },
                '4', '8' => .{ .key = .end, .len = 4 },
                else => .{ .key = .ignored, .len = 4 },
            };
        },
        else => .{ .key = .ignored, .len = 3 },
    };
}

/// The editable line plus the history it can recall.
pub const Editor = struct {
    gpa: std.mem.Allocator,
    buf: [max_line]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
    history: std.ArrayList([]u8) = .empty,
    /// Index into history while browsing; `history.items.len` means "the line
    /// being typed", which is restored when the user comes back down.
    hist_pos: usize = 0,
    /// The in-progress line, parked while browsing history.
    pending: [max_line]u8 = undefined,
    pending_len: usize = 0,

    pub fn deinit(self: *Editor) void {
        for (self.history.items) |h| self.gpa.free(h);
        self.history.deinit(self.gpa);
    }

    pub fn line(self: *const Editor) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn reset(self: *Editor) void {
        self.len = 0;
        self.cursor = 0;
        self.hist_pos = self.history.items.len;
        self.pending_len = 0;
    }

    /// Adds a line to history unless it repeats the previous one — recall is
    /// useless when ten entries in a row are the same command.
    pub fn remember(self: *Editor, text: []const u8) void {
        if (text.len == 0) return;
        if (self.history.items.len > 0) {
            const last = self.history.items[self.history.items.len - 1];
            if (std.mem.eql(u8, last, text)) return;
        }
        const owned = self.gpa.dupe(u8, text) catch return;
        self.history.append(self.gpa, owned) catch {
            self.gpa.free(owned);
            return;
        };
        if (self.history.items.len > max_history) {
            self.gpa.free(self.history.orderedRemove(0));
        }
        self.hist_pos = self.history.items.len;
    }

    fn setLine(self: *Editor, text: []const u8) void {
        const n = @min(text.len, max_line);
        @memcpy(self.buf[0..n], text[0..n]);
        self.len = n;
        self.cursor = n;
    }

    /// Applies one key. Returns true when the line is finished (Enter).
    pub fn apply(self: *Editor, key: Key) bool {
        switch (key) {
            .char => |c| {
                if (self.len + 1 > max_line) return false;
                std.mem.copyBackwards(u8, self.buf[self.cursor + 1 .. self.len + 1], self.buf[self.cursor..self.len]);
                self.buf[self.cursor] = c;
                self.len += 1;
                self.cursor += 1;
            },
            .backspace => {
                if (self.cursor == 0) return false;
                std.mem.copyForwards(u8, self.buf[self.cursor - 1 .. self.len - 1], self.buf[self.cursor..self.len]);
                self.len -= 1;
                self.cursor -= 1;
            },
            .delete => {
                if (self.cursor >= self.len) return false;
                std.mem.copyForwards(u8, self.buf[self.cursor .. self.len - 1], self.buf[self.cursor + 1 .. self.len]);
                self.len -= 1;
            },
            .left => if (self.cursor > 0) {
                self.cursor -= 1;
            },
            .right => if (self.cursor < self.len) {
                self.cursor += 1;
            },
            .home => self.cursor = 0,
            .end => self.cursor = self.len,
            .kill_to_end => self.len = self.cursor,
            .kill_to_start => {
                std.mem.copyForwards(u8, self.buf[0 .. self.len - self.cursor], self.buf[self.cursor..self.len]);
                self.len -= self.cursor;
                self.cursor = 0;
            },
            .kill_word => {
                var i = self.cursor;
                while (i > 0 and self.buf[i - 1] == ' ') i -= 1;
                while (i > 0 and self.buf[i - 1] != ' ') i -= 1;
                const removed = self.cursor - i;
                std.mem.copyForwards(u8, self.buf[i .. self.len - removed], self.buf[self.cursor..self.len]);
                self.len -= removed;
                self.cursor = i;
            },
            .up => {
                if (self.history.items.len == 0 or self.hist_pos == 0) return false;
                // Stepping off the live line parks it, so coming back down
                // returns what was being typed rather than an empty prompt.
                if (self.hist_pos == self.history.items.len) {
                    self.pending_len = self.len;
                    @memcpy(self.pending[0..self.len], self.buf[0..self.len]);
                }
                self.hist_pos -= 1;
                self.setLine(self.history.items[self.hist_pos]);
            },
            .down => {
                if (self.hist_pos >= self.history.items.len) return false;
                self.hist_pos += 1;
                if (self.hist_pos == self.history.items.len) {
                    self.setLine(self.pending[0..self.pending_len]);
                } else {
                    self.setLine(self.history.items[self.hist_pos]);
                }
            },
            .enter => return true,
            .interrupt, .eof, .ignored => return false,
        }
        return false;
    }
};

// ------------------------------------------------------------------- tests --

test "decode recognizes arrows, control keys and partial escapes" {
    try std.testing.expectEqual(Key.up, decode("\x1b[A").?.key);
    try std.testing.expectEqual(Key.down, decode("\x1b[B").?.key);
    try std.testing.expectEqual(Key.right, decode("\x1b[C").?.key);
    try std.testing.expectEqual(Key.left, decode("\x1b[D").?.key);
    try std.testing.expectEqual(@as(usize, 3), decode("\x1b[A").?.len);
    // Delete arrives as a four-byte sequence on most terminals.
    try std.testing.expectEqual(Key.delete, decode("\x1b[3~").?.key);
    // A sequence still arriving consumes nothing, so no byte is misread as ESC.
    try std.testing.expect(decode("\x1b") == null);
    try std.testing.expect(decode("\x1b[") == null);
    try std.testing.expectEqual(Key.enter, decode("\r").?.key);
    try std.testing.expectEqual(Key.kill_to_start, decode("\x15").?.key);
    try std.testing.expectEqual(@as(u8, 'a'), decode("a").?.key.char);
}

test "history recall walks up and restores the line being typed" {
    var ed = Editor{ .gpa = std.testing.allocator };
    defer ed.deinit();

    ed.remember("first task");
    ed.remember("second task");
    ed.reset();

    for ("half typed") |c| _ = ed.apply(.{ .char = c });
    try std.testing.expectEqualStrings("half typed", ed.line());

    _ = ed.apply(.up);
    try std.testing.expectEqualStrings("second task", ed.line());
    _ = ed.apply(.up);
    try std.testing.expectEqualStrings("first task", ed.line());
    // Already at the oldest entry: staying put beats wrapping around.
    _ = ed.apply(.up);
    try std.testing.expectEqualStrings("first task", ed.line());

    _ = ed.apply(.down);
    try std.testing.expectEqualStrings("second task", ed.line());
    _ = ed.apply(.down);
    try std.testing.expectEqualStrings("half typed", ed.line());
}

test "editing keys insert, delete and kill at the cursor" {
    var ed = Editor{ .gpa = std.testing.allocator };
    defer ed.deinit();
    ed.reset();

    for ("hello world") |c| _ = ed.apply(.{ .char = c });
    _ = ed.apply(.kill_word);
    try std.testing.expectEqualStrings("hello ", ed.line());

    _ = ed.apply(.home);
    _ = ed.apply(.{ .char = 'X' });
    try std.testing.expectEqualStrings("Xhello ", ed.line());

    _ = ed.apply(.end);
    _ = ed.apply(.backspace);
    try std.testing.expectEqualStrings("Xhello", ed.line());

    _ = ed.apply(.home);
    _ = ed.apply(.delete);
    try std.testing.expectEqualStrings("hello", ed.line());

    _ = ed.apply(.end);
    _ = ed.apply(.kill_to_start);
    try std.testing.expectEqualStrings("", ed.line());
    try std.testing.expect(ed.apply(.enter));
}

test "duplicate consecutive entries are not remembered twice" {
    var ed = Editor{ .gpa = std.testing.allocator };
    defer ed.deinit();
    ed.remember("same");
    ed.remember("same");
    ed.remember("other");
    try std.testing.expectEqual(@as(usize, 2), ed.history.items.len);
}
