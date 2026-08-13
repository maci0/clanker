//! The TUI mascot: a little robot that runs around the input box.
//!
//! Off unless asked for (`--mascot`, or `tui.mascot` in config) -- it is an
//! easter egg, not a status indicator, and it costs real transcript rows.
//!
//! Two renderers for the same artwork:
//!
//!   - **kitty graphics**, when the terminal answered the capability query.
//!     The actual drawing, transmitted once as pngs and then placed by id, so a
//!     frame change costs one escape sequence.
//!   - **half-blocks**, everywhere else. `mascot_frames.zig` holds the same
//!     eleven frames quantized to a grid of upper/lower half cells, at three
//!     sizes.
//!
//! Both paths share all the position, size and mirroring arithmetic below,
//! which is deliberately free of any vaxis types so it can be tested without a
//! terminal.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const frames = @import("mascot_frames.zig");
const log = @import("../util/log.zig");

pub const frame_count = frames.frame_count;
pub const Variant = frames.Variant;

/// Width of the source pngs in pixels. Needed to convert a column clip into
/// the source-pixel rectangle kitty's `x`/`w` placement keys expect.
const png_px = 192;

/// Which way the robot faces. A mirrored copy of the same artwork, not a
/// second drawing.
pub const Facing = enum {
    right,
    left,

    pub fn parse(text: []const u8) ?Facing {
        if (std.ascii.eqlIgnoreCase(text, "right")) return .right;
        if (std.ascii.eqlIgnoreCase(text, "left")) return .left;
        return null;
    }
};

/// How the artwork is mirrored for one particular frame.
///
/// Not a bitfield of two independent flags, because the two never combine:
/// `facing` only applies to the modes that travel or run on the spot, and the
/// upside-down flip only happens in `typing` mode, whose facing is fixed. That
/// matters beyond tidiness -- a kitty placement cannot mirror what it draws, so
/// every orientation here costs its own set of transmitted pngs, and a fourth
/// (mirrored both ways) would be transmitted for a combination nothing asks
/// for.
pub const Flip = enum {
    none,
    horizontal,
    vertical,

    /// Index into the per-orientation png sets and transmitted-id arrays.
    fn idx(self: Flip) usize {
        return @intFromEnum(self);
    }
};

pub const Size = enum {
    /// The floor, not a preference: below roughly 8x4 the robot stops reading
    /// as a robot at all. See the sweep documented in `gen_frames.py`.
    small,
    medium,
    large,

    pub fn variant(self: Size) Variant {
        return switch (self) {
            .small => frames.small,
            .medium => frames.medium,
            .large => frames.large,
        };
    }

    pub fn parse(text: []const u8) ?Size {
        const table = .{
            .{ "small", Size.small },
            .{ "s", Size.small },
            .{ "medium", Size.medium },
            .{ "m", Size.medium },
            .{ "normal", Size.medium },
            .{ "large", Size.large },
            .{ "l", Size.large },
            .{ "big", Size.large },
        };
        inline for (table) |entry| {
            if (std.ascii.eqlIgnoreCase(text, entry[0])) return entry[1];
        }
        return null;
    }
};

pub const Mode = enum {
    /// No mascot, no rows claimed. The default.
    off,
    /// Position tracks the input field: the robot runs right as you type and
    /// stands still when you stop.
    typing,
    /// Runs continuously left to right, off the right edge, back in from the
    /// left. Ignores what you are doing entirely.
    loop,
    /// Runs on the spot in the bottom-right corner above the input box,
    /// facing left by default so it reads as running against the scroll
    /// rather than being stuck.
    place,
    /// Runs on the spot inside the input box, at its bottom-right. The box
    /// grows to make room and the text field is narrowed, so the robot never
    /// sits on top of what is being typed.
    input,

    /// What a bare `--mascot` means. `loop` rather than `typing` on purpose:
    /// a mascot that only moves when a key is pressed looks broken on a fresh
    /// screen, and "I turned it on and nothing happened" is a worse first
    /// impression than a robot running past unbidden.
    pub const bare_default: Mode = .loop;

    /// Spellings accepted from `--mascot=<x>` and from `tui.mascot`. "type" is
    /// the spelling documented for users; `typing` is only the field name,
    /// because `type` cannot be one.
    pub fn parse(text: []const u8) ?Mode {
        const table = .{
            .{ "off", Mode.off },
            .{ "false", Mode.off },
            .{ "none", Mode.off },
            .{ "type", Mode.typing },
            .{ "typing", Mode.typing },
            .{ "loop", Mode.loop },
            .{ "run", Mode.loop },
            .{ "place", Mode.place },
            .{ "spot", Mode.place },
            .{ "in-place", Mode.place },
            .{ "input", Mode.input },
            .{ "box", Mode.input },
            .{ "in-input", Mode.input },
            // What `cli.zig` substitutes for a bare `--mascot`.
            .{ "on", bare_default },
            .{ "true", bare_default },
        };
        inline for (table) |entry| {
            if (std.ascii.eqlIgnoreCase(text, entry[0])) return entry[1];
        }
        return null;
    }

    /// Whether this mode travels across the screen. The others hold a corner,
    /// which is what lets the caller reserve a fixed box for them.
    pub fn travels(self: Mode) bool {
        return self == .typing or self == .loop;
    }

    /// Whether the mode animates on its own clock and so needs a timer while
    /// the REPL is otherwise idle. `typing` is the exception: a keystroke is
    /// already a redraw, and standing still between them is the point.
    pub fn selfDriven(self: Mode) bool {
        return switch (self) {
            .loop, .place, .input => true,
            .off, .typing => false,
        };
    }

    /// Which way the robot faces when the user did not say. Only `place`
    /// differs: running on the spot facing right, directly above a left-to-
    /// right input box, reads as walking into a wall.
    pub fn defaultFacing(self: Mode) Facing {
        return switch (self) {
            .place => .left,
            else => .right,
        };
    }
};

/// What the terminal turned out to support. Resolved once, on the first draw
/// that has a live vaxis handle to ask, because the capability query is still
/// in flight while the model is being built.
const Graphics = union(enum) {
    /// Not yet asked.
    unknown,
    /// Transmitted image ids, one row per `Flip` and one column per frame.
    kitty: [3][frame_count]u32,
    /// Either no kitty support or a transmit that failed. Half-blocks from
    /// here on; never retried, so a broken terminal cannot make every frame
    /// re-attempt a megabyte of base64.
    cells,
};

/// The embedded pngs, `[orientation][frame]`, ordered to match `Flip`.
/// Embedded rather than loaded from disk so a copied binary keeps its mascot.
const png_frames = [3][frame_count][]const u8{
    .{
        @embedFile("mascot/frame-00.png"), @embedFile("mascot/frame-01.png"),
        @embedFile("mascot/frame-02.png"), @embedFile("mascot/frame-03.png"),
        @embedFile("mascot/frame-04.png"), @embedFile("mascot/frame-05.png"),
        @embedFile("mascot/frame-06.png"), @embedFile("mascot/frame-07.png"),
        @embedFile("mascot/frame-08.png"), @embedFile("mascot/frame-09.png"),
        @embedFile("mascot/frame-10.png"),
    },
    .{
        @embedFile("mascot/frame-00-h.png"), @embedFile("mascot/frame-01-h.png"),
        @embedFile("mascot/frame-02-h.png"), @embedFile("mascot/frame-03-h.png"),
        @embedFile("mascot/frame-04-h.png"), @embedFile("mascot/frame-05-h.png"),
        @embedFile("mascot/frame-06-h.png"), @embedFile("mascot/frame-07-h.png"),
        @embedFile("mascot/frame-08-h.png"), @embedFile("mascot/frame-09-h.png"),
        @embedFile("mascot/frame-10-h.png"),
    },
    .{
        @embedFile("mascot/frame-00-v.png"), @embedFile("mascot/frame-01-v.png"),
        @embedFile("mascot/frame-02-v.png"), @embedFile("mascot/frame-03-v.png"),
        @embedFile("mascot/frame-04-v.png"), @embedFile("mascot/frame-05-v.png"),
        @embedFile("mascot/frame-06-v.png"), @embedFile("mascot/frame-07-v.png"),
        @embedFile("mascot/frame-08-v.png"), @embedFile("mascot/frame-09-v.png"),
        @embedFile("mascot/frame-10-v.png"),
    },
};

pub const State = struct {
    mode: Mode = .off,
    size: Size = .medium,
    facing: Facing = .right,
    /// Index into the animation. Advances with movement, so a robot standing
    /// still does not run in place -- except in the modes whose whole point is
    /// running in place, which advance every tick.
    frame: u8 = 0,
    /// Columns travelled in `loop` mode. Monotonic, wrapped when read.
    travel: u32 = 0,
    /// `typing` mode: the input length the last advance was computed from, so
    /// a redraw that changes nothing does not advance the legs.
    last_len: usize = 0,
    /// `typing` mode: whether the last input change removed text. Drives the
    /// upside-down flip while backspacing.
    deleting: bool = false,
    graphics: Graphics = .unknown,

    pub fn enabled(self: State) bool {
        return self.mode != .off;
    }

    pub fn variant(self: State) Variant {
        return self.size.variant();
    }

    /// How the current frame is mirrored. See `Flip` for why these cannot
    /// combine.
    pub fn flip(self: State) Flip {
        return switch (self.mode) {
            .off, .input => .none,
            // Deliberately the upside-down mirror rather than the left-facing
            // one: backspacing is the robot being *undone*, not the robot
            // walking backwards, and the left-facing mirror is already what
            // `facing` means everywhere else.
            .typing => if (self.deleting) .vertical else .none,
            .loop, .place => switch (self.facing) {
                .right => .none,
                .left => .horizontal,
            },
        };
    }

    /// Advance one animation tick. `typed_len` is the current input length,
    /// used only by `typing`.
    ///
    /// `loop`, `place` and `input` advance every tick; `typing` only when the
    /// input length actually changed, which is what makes the robot look like
    /// it is running *because* you are typing rather than merely while you
    /// are.
    pub fn advance(self: *State, typed_len: usize) void {
        switch (self.mode) {
            .off => {},
            .loop => {
                self.travel +%= 1;
                self.step();
            },
            .place, .input => self.step(),
            .typing => {
                if (typed_len == self.last_len) return;
                self.deleting = typed_len < self.last_len;
                self.last_len = typed_len;
                self.step();
            },
        }
    }

    fn step(self: *State) void {
        self.frame = @intCast((self.frame + 1) % frame_count);
    }

    /// Leftmost column of the mascot, which may be negative (part-way in from
    /// the left edge) or past `width` (part-way out the right).
    ///
    /// `width` is the width of whatever the mascot is anchored to -- the whole
    /// surface for the travelling modes, the input box's interior for
    /// `.input`.
    pub fn column(self: State, width: u16, typed_len: usize) i32 {
        const v = self.variant();
        return switch (self.mode) {
            .off => 0,
            .loop => loopColumn(v, self.travel, width),
            .typing => typeColumn(v, typed_len, width),
            // Parked against the right edge, one column short of it so the
            // robot is not welded to the frame.
            .place, .input => cornerColumn(v, width),
        };
    }

    /// Transmits every frame, in every orientation, once, and remembers the
    /// ids.
    ///
    /// Called from the draw path because that is the first place with both a
    /// live `*vaxis.Vaxis` and a settled capability answer -- `queryTerminal`
    /// is still in flight when the model is constructed, so asking earlier
    /// reliably reports no kitty support. Any failure latches to `.cells`, so
    /// this runs at most once either way.
    ///
    /// All three orientations are sent up front rather than on demand: the
    /// flip can change between one frame and the next (a backspace does it),
    /// and transmitting a few hundred kilobytes mid-animation would stall the
    /// redraw exactly when the user is typing.
    pub fn ensureGraphics(
        self: *State,
        gpa: std.mem.Allocator,
        vx: *vaxis.Vaxis,
        tty: *std.Io.Writer,
    ) void {
        if (self.graphics != .unknown) return;
        if (!vx.caps.kitty_graphics) {
            self.graphics = .cells;
            return;
        }
        var ids: [3][frame_count]u32 = undefined;
        for (png_frames, 0..) |orientation, o| {
            for (orientation, 0..) |bytes, i| {
                const img = vx.loadImage(gpa, tty, .{ .mem = bytes }) catch |err| {
                    // Partial transmits are not unwound: the ids already sent
                    // are abandoned, and the terminal drops them when it next
                    // clears images. Cheaper than tracking them to free on a
                    // path that only runs when the terminal is already
                    // misbehaving.
                    log.log(.debug, "mascot: kitty transmit failed ({t}), using half-blocks", .{err});
                    self.graphics = .cells;
                    return;
                };
                ids[o][i] = img.id;
            }
        }
        self.graphics = .{ .kitty = ids };
    }

    /// Draws the mascot with whichever renderer the terminal earned.
    pub fn draw(self: State, surface: vxfw.Surface, col0: i32, row0: u16) void {
        const v = self.variant();
        const f = self.flip();
        switch (self.graphics) {
            .kitty => |ids| drawKitty(v, surface, ids[f.idx()], self.frame, col0, row0),
            // `.unknown` should have been resolved by `ensureGraphics` before
            // the first draw, but half-blocks are the safe answer if not.
            .cells, .unknown => drawCells(v, surface, self.frame, col0, row0, f),
        }
    }
};

/// Wraps through `[-cols, width)`, so the robot walks fully on from the left
/// edge and fully off the right before reappearing rather than popping in and
/// out at the boundaries.
pub fn loopColumn(v: Variant, travel: u32, width: u16) i32 {
    const span: u32 = @as(u32, width) + v.cols;
    return @as(i32, @intCast(travel % span)) - @as(i32, v.cols);
}

/// One column per character typed, parked at the right margin once the input
/// is longer than the space available. Clamped rather than wrapped: a long
/// task should leave the robot waiting at the edge, not teleporting back to
/// the start mid-sentence.
pub fn typeColumn(v: Variant, typed_len: usize, width: u16) i32 {
    const limit: i32 = @as(i32, @intCast(width)) - @as(i32, v.cols);
    if (limit <= 0) return 0;
    const want: i32 = @intCast(@min(typed_len, @as(usize, @intCast(limit))));
    return want;
}

/// Hard against the right-hand end of `width`, with a one-column margin when
/// there is room to spare for one.
pub fn cornerColumn(v: Variant, width: u16) i32 {
    if (width <= v.cols) return 0;
    const margin: u16 = if (width > v.cols + 1) 1 else 0;
    return @intCast(width - v.cols - margin);
}

/// Rows of transcript that must survive underneath the mascot. Three is
/// enough to still read a streaming reply.
const min_transcript_rows: u16 = 3;

/// Whether there is actually room to draw. A terminal too narrow for the
/// robot, or too short to spare its rows on top of a usable transcript, gets
/// no mascot rather than a clipped one shoving the transcript off screen.
///
/// `avail_rows` is the height of the **transcript region**, not of the
/// terminal: the status row and the input box are already spent by the time
/// this is asked. So the terminal-height equivalent is five rows more than the
/// figure here (`1 status + 3 box + 1`). Quoting `rows + min_transcript_rows`
/// straight at users is the mistake to avoid; it understates the requirement.
/// `minTerminal` below is what the help text and config should quote.
pub fn fits(v: Variant, width: u16, avail_rows: u16) bool {
    return width >= v.cols + 2 and avail_rows >= v.rows + min_transcript_rows;
}

/// The smallest terminal this size will actually draw in, as `.{ cols, rows }`
/// of *terminal*, ready to be quoted at a user.
///
/// `.input` is excluded on purpose: it grows the box instead of reserving
/// transcript, so it has its own budget (see `inputBoxHeight`).
pub fn minTerminal(v: Variant) struct { cols: u16, rows: u16 } {
    // 1 status row + 3-row input box + 1 for the transcript's own top offset.
    const chrome: u16 = 5;
    return .{ .cols = v.cols + 2, .rows = v.rows + min_transcript_rows + chrome };
}

/// Height of the input box in `.input` mode: the robot plus its two borders,
/// never shorter than the ordinary three-row box.
pub fn inputBoxHeight(v: Variant) u16 {
    return @max(3, v.rows + 2);
}

/// The visible slice of a mascot whose leftmost column is `col0`, in cells.
pub const Clip = struct {
    /// First column on screen the mascot occupies.
    screen_col: u16,
    /// How many of the mascot's own columns are hidden off the left edge.
    skip_cols: u16,
    /// Visible width in columns.
    width: u16,
};

/// Resolves `col0` (possibly off either edge) against the available width.
/// Null when the mascot is entirely off screen this frame.
pub fn clip(v: Variant, col0: i32, width: u16) ?Clip {
    if (col0 >= @as(i32, @intCast(width))) return null;
    if (col0 + @as(i32, v.cols) <= 0) return null;
    const skip: u16 = if (col0 < 0) @intCast(-col0) else 0;
    const screen_col: u16 = if (col0 < 0) 0 else @intCast(col0);
    const visible = @min(v.cols - skip, width - screen_col);
    if (visible == 0) return null;
    return .{ .screen_col = screen_col, .skip_cols = skip, .width = visible };
}

/// One cell of one frame, with mirroring applied on read.
///
/// The vertical case is the subtle one: a cell packs two stacked half-pixels,
/// so mirroring top-to-bottom has to reverse the row order *and* swap each
/// cell's own nibbles. Reversing rows alone leaves every cell internally
/// upside down, which shows up as a one-pixel shear rather than an obvious
/// bug.
fn cellAt(v: Variant, frame: u8, row: u16, col: u16, f: Flip) u8 {
    const base = @as(usize, frame % frame_count) * @as(usize, v.rows) * @as(usize, v.cols);
    const r = switch (f) {
        .vertical => v.rows - 1 - row,
        else => row,
    };
    const c = switch (f) {
        .horizontal => v.cols - 1 - col,
        else => col,
    };
    const byte = v.cells[base + @as(usize, r) * @as(usize, v.cols) + c];
    return switch (f) {
        .vertical => (byte << 4) | (byte >> 4),
        else => byte,
    };
}

fn rgb(packed_rgb: u24) vaxis.Cell.Color {
    return .{ .rgb = .{
        @intCast((packed_rgb >> 16) & 0xFF),
        @intCast((packed_rgb >> 8) & 0xFF),
        @intCast(packed_rgb & 0xFF),
    } };
}

const upper_half = "\xe2\x96\x80"; // U+2580
const lower_half = "\xe2\x96\x84"; // U+2584

/// Paints one frame as half-block cells into `surface`, top-left at
/// (`col0`, `row0`). Cells where both halves are transparent are left
/// untouched, so whatever is underneath shows through around the robot instead
/// of being boxed out by a rectangle of background.
pub fn drawCells(
    v: Variant,
    surface: vxfw.Surface,
    frame: u8,
    col0: i32,
    row0: u16,
    f: Flip,
) void {
    const c = clip(v, col0, surface.size.width) orelse return;
    for (0..v.rows) |r| {
        const row: u16 = row0 + @as(u16, @intCast(r));
        if (row >= surface.size.height) break;
        for (0..c.width) |i| {
            const src_col = c.skip_cols + @as(u16, @intCast(i));
            const byte = cellAt(v, frame, @intCast(r), src_col, f);
            const top = byte >> 4;
            const bot = byte & 0x0F;
            const cell: vaxis.Cell = if (top != frames.transparent and bot != frames.transparent)
                .{
                    .char = .{ .grapheme = upper_half, .width = 1 },
                    .style = .{ .fg = rgb(frames.palette[top]), .bg = rgb(frames.palette[bot]) },
                }
            else if (top != frames.transparent)
                .{
                    .char = .{ .grapheme = upper_half, .width = 1 },
                    .style = .{ .fg = rgb(frames.palette[top]) },
                }
            else if (bot != frames.transparent)
                .{
                    .char = .{ .grapheme = lower_half, .width = 1 },
                    .style = .{ .fg = rgb(frames.palette[bot]) },
                }
            else
                continue;
            surface.writeCell(c.screen_col + @as(u16, @intCast(i)), row, cell);
        }
    }
}

/// Places one transmitted frame as a kitty image. The placement lands on the
/// mascot's top-left cell; the terminal scales the png into `width` x `rows`
/// cells itself.
///
/// Mirroring is baked into which id is passed, not applied here: a kitty
/// placement has no mirror operation, so each orientation is its own
/// transmitted image.
///
/// A partly-off-screen robot is handled with kitty's source clip rather than
/// by hiding it, so the left-edge entry matches what the half-block path does.
/// The clip rectangle is in *source png pixels*, not cells, and is applied
/// before the row/col scaling.
pub fn drawKitty(
    v: Variant,
    surface: vxfw.Surface,
    ids: [frame_count]u32,
    frame: u8,
    col0: i32,
    row0: u16,
) void {
    const c = clip(v, col0, surface.size.width) orelse return;
    if (row0 >= surface.size.height) return;
    const clip_x: u16 = @intCast(@divTrunc(@as(u32, c.skip_cols) * png_px, v.cols));
    const clip_w: u16 = @intCast(@divTrunc(@as(u32, c.width) * png_px, v.cols));
    surface.writeCell(c.screen_col, row0, .{
        .image = .{
            .img_id = ids[frame % frame_count],
            .options = .{
                .clip_region = .{ .x = clip_x, .width = clip_w },
                .size = .{ .rows = v.rows, .cols = c.width },
            },
        },
    });
}

const testing = std.testing;
const med = frames.medium;

test "Mode.parse accepts the documented spellings and rejects junk" {
    try testing.expectEqual(Mode.off, Mode.parse("off").?);
    try testing.expectEqual(Mode.typing, Mode.parse("type").?);
    try testing.expectEqual(Mode.typing, Mode.parse("typing").?);
    try testing.expectEqual(Mode.loop, Mode.parse("loop").?);
    try testing.expectEqual(Mode.place, Mode.parse("place").?);
    try testing.expectEqual(Mode.input, Mode.parse("input").?);
    // Case-insensitive, because config files and flags disagree about case.
    try testing.expectEqual(Mode.loop, Mode.parse("LOOP").?);
    // The stand-in cli.zig uses for a bare `--mascot`.
    try testing.expectEqual(Mode.bare_default, Mode.parse("on").?);
    try testing.expectEqual(@as(?Mode, null), Mode.parse("sideways"));
    try testing.expectEqual(@as(?Mode, null), Mode.parse(""));
}

test "Size and Facing parse their spellings" {
    try testing.expectEqual(Size.small, Size.parse("small").?);
    try testing.expectEqual(Size.medium, Size.parse("MEDIUM").?);
    try testing.expectEqual(Size.large, Size.parse("big").?);
    try testing.expectEqual(@as(?Size, null), Size.parse("huge"));
    try testing.expectEqual(Facing.left, Facing.parse("left").?);
    try testing.expectEqual(Facing.right, Facing.parse("Right").?);
    try testing.expectEqual(@as(?Facing, null), Facing.parse("up"));
}

test "every baked size is well formed and distinct" {
    var seen: [3]struct { cols: u16, rows: u16 } = undefined;
    for ([_]Size{ .small, .medium, .large }, 0..) |s, i| {
        const v = s.variant();
        try testing.expect(v.cols > 0 and v.rows > 0);
        // The whole animation, concatenated: one frame's worth per frame.
        try testing.expectEqual(
            @as(usize, v.cols) * @as(usize, v.rows) * frame_count,
            v.cells.len,
        );
        for (v.cells) |byte| {
            for ([_]u8{ byte >> 4, byte & 0x0F }) |nib| {
                if (nib == frames.transparent) continue;
                try testing.expect(nib < frames.palette.len);
            }
        }
        seen[i] = .{ .cols = v.cols, .rows = v.rows };
    }
    // Strictly increasing, or "small" and "large" are not doing anything.
    try testing.expect(seen[0].cols < seen[1].cols and seen[0].rows < seen[1].rows);
    try testing.expect(seen[1].cols < seen[2].cols and seen[1].rows < seen[2].rows);
}

test "the baked frames are not all identical" {
    // Guards the generator: a resampling bug that collapsed every frame to the
    // same cells would still round-trip and still animate, silently.
    for ([_]Size{ .small, .medium, .large }) |s| {
        const v = s.variant();
        const span = @as(usize, v.cols) * @as(usize, v.rows);
        const first = v.cells[0..span];
        var differs = false;
        for (1..frame_count) |i| {
            if (!std.mem.eql(u8, first, v.cells[i * span ..][0..span])) differs = true;
        }
        try testing.expect(differs);
    }
}

test "loopColumn enters from off-left and exits fully off-right" {
    const width: u16 = 80;
    try testing.expectEqual(@as(i32, -@as(i32, med.cols)), loopColumn(med, 0, width));
    try testing.expectEqual(@as(i32, -@as(i32, med.cols) + 1), loopColumn(med, 1, width));
    try testing.expectEqual(@as(i32, 0), loopColumn(med, med.cols, width));
    try testing.expectEqual(@as(i32, width - 1), loopColumn(med, width + med.cols - 1, width));
    try testing.expectEqual(loopColumn(med, 0, width), loopColumn(med, width + med.cols, width));
}

test "loopColumn is always somewhere on the wrap span, at every size" {
    for ([_]Size{ .small, .medium, .large }) |s| {
        const v = s.variant();
        const width: u16 = 40;
        for (0..500) |t| {
            const col = loopColumn(v, @intCast(t), width);
            try testing.expect(col >= -@as(i32, v.cols));
            try testing.expect(col < width);
        }
    }
}

test "typeColumn tracks input length then parks at the right margin" {
    const width: u16 = 80;
    try testing.expectEqual(@as(i32, 0), typeColumn(med, 0, width));
    try testing.expectEqual(@as(i32, 5), typeColumn(med, 5, width));
    const limit: i32 = @as(i32, width) - @as(i32, med.cols);
    try testing.expectEqual(limit, typeColumn(med, @intCast(limit), width));
    try testing.expectEqual(limit, typeColumn(med, @intCast(limit + 1), width));
    try testing.expectEqual(limit, typeColumn(med, 10_000, width));
}

test "typeColumn pins to zero when the terminal is narrower than the mascot" {
    try testing.expectEqual(@as(i32, 0), typeColumn(med, 50, med.cols));
    try testing.expectEqual(@as(i32, 0), typeColumn(med, 50, 4));
}

test "cornerColumn parks against the right edge with a margin" {
    try testing.expectEqual(@as(i32, 80 - med.cols - 1), cornerColumn(med, 80));
    // Exactly wide enough for the robot plus its margin: one blank column on
    // each side.
    try testing.expectEqual(@as(i32, 1), cornerColumn(med, med.cols + 2));
    // Room for the robot but not the margin: give up the margin, not the
    // robot, which leaves it flush against the right edge rather than sliding
    // back to column 0.
    try testing.expectEqual(@as(i32, 1), cornerColumn(med, med.cols + 1));
    // No room at all: start at 0 and let `clip` truncate.
    try testing.expectEqual(@as(i32, 0), cornerColumn(med, med.cols));
    try testing.expectEqual(@as(i32, 0), cornerColumn(med, 2));
}

test "cornerColumn keeps the whole robot on screen at every size" {
    for ([_]Size{ .small, .medium, .large }) |s| {
        const v = s.variant();
        var width: u16 = v.cols;
        while (width < v.cols + 40) : (width += 1) {
            const col = cornerColumn(v, width);
            try testing.expect(col >= 0);
            try testing.expect(col + @as(i32, v.cols) <= @as(i32, @intCast(width)));
        }
    }
}

test "advance only moves the legs in typing mode when the input changed" {
    var st: State = .{ .mode = .typing };
    try testing.expectEqual(@as(u8, 0), st.frame);
    st.advance(0);
    try testing.expectEqual(@as(u8, 0), st.frame);
    st.advance(1);
    try testing.expectEqual(@as(u8, 1), st.frame);
    st.advance(1);
    try testing.expectEqual(@as(u8, 1), st.frame);
    st.advance(0);
    try testing.expectEqual(@as(u8, 2), st.frame);
}

test "typing mode flips upside down while deleting and rights itself on input" {
    var st: State = .{ .mode = .typing };
    try testing.expectEqual(Flip.none, st.flip());
    // Adding text: upright.
    st.advance(4);
    try testing.expectEqual(Flip.none, st.flip());
    // Backspacing: upside down.
    st.advance(3);
    try testing.expect(st.deleting);
    try testing.expectEqual(Flip.vertical, st.flip());
    // Still deleting.
    st.advance(1);
    try testing.expectEqual(Flip.vertical, st.flip());
    // Typing again rights it immediately.
    st.advance(2);
    try testing.expect(!st.deleting);
    try testing.expectEqual(Flip.none, st.flip());
    // A redraw that changes nothing must not right it either way.
    st.advance(1);
    st.advance(1);
    try testing.expectEqual(Flip.vertical, st.flip());
}

test "advance runs every tick in the on-the-spot modes" {
    for ([_]Mode{ .place, .input }) |m| {
        var st: State = .{ .mode = m };
        // Input length is irrelevant to these: they run regardless.
        for (0..frame_count) |_| st.advance(0);
        try testing.expectEqual(@as(u8, 0), st.frame);
        st.advance(0);
        try testing.expectEqual(@as(u8, 1), st.frame);
        // And they never travel.
        try testing.expectEqual(@as(u32, 0), st.travel);
        try testing.expect(!m.travels());
    }
}

test "advance runs every tick in loop mode and wraps the frame index" {
    var st: State = .{ .mode = .loop };
    for (0..frame_count) |_| st.advance(0);
    try testing.expectEqual(@as(u8, 0), st.frame);
    try testing.expectEqual(@as(u32, frame_count), st.travel);
    st.advance(0);
    try testing.expectEqual(@as(u8, 1), st.frame);
}

test "advance is inert when off" {
    var st: State = .{ .mode = .off };
    for (0..50) |i| st.advance(i);
    try testing.expectEqual(@as(u8, 0), st.frame);
    try testing.expectEqual(@as(u32, 0), st.travel);
    try testing.expect(!st.enabled());
    try testing.expectEqual(Flip.none, st.flip());
}

test "facing decides the mirror for the travelling and on-the-spot modes" {
    for ([_]Mode{ .loop, .place }) |m| {
        var st: State = .{ .mode = m, .facing = .right };
        try testing.expectEqual(Flip.none, st.flip());
        st.facing = .left;
        try testing.expectEqual(Flip.horizontal, st.flip());
    }
    // `input` is never mirrored, whatever facing says.
    var boxed: State = .{ .mode = .input, .facing = .left };
    try testing.expectEqual(Flip.none, boxed.flip());
    // `place` faces left unless told otherwise; nothing else does.
    try testing.expectEqual(Facing.left, Mode.place.defaultFacing());
    try testing.expectEqual(Facing.right, Mode.loop.defaultFacing());
    try testing.expectEqual(Facing.right, Mode.typing.defaultFacing());
    try testing.expectEqual(Facing.right, Mode.input.defaultFacing());
}

test "horizontal flip mirrors columns and leaves each cell's halves alone" {
    const v = med;
    for (0..frame_count) |fi| {
        const f: u8 = @intCast(fi);
        for (0..v.rows) |r| {
            for (0..v.cols) |c| {
                const plain = cellAt(v, f, @intCast(r), @intCast(v.cols - 1 - c), .none);
                const flipped = cellAt(v, f, @intCast(r), @intCast(c), .horizontal);
                try testing.expectEqual(plain, flipped);
            }
        }
    }
}

test "vertical flip mirrors rows and swaps each cell's halves" {
    const v = med;
    for (0..frame_count) |fi| {
        const f: u8 = @intCast(fi);
        for (0..v.rows) |r| {
            for (0..v.cols) |c| {
                const plain = cellAt(v, f, @intCast(v.rows - 1 - r), @intCast(c), .none);
                const want: u8 = (plain << 4) | (plain >> 4);
                const flipped = cellAt(v, f, @intCast(r), @intCast(c), .vertical);
                try testing.expectEqual(want, flipped);
            }
        }
    }
}

test "flipping twice is the identity" {
    // Catches an off-by-one in either mirror: a flip that reversed
    // `rows - row` instead of `rows - 1 - row` still looks plausible frame by
    // frame but does not round-trip.
    const v = frames.small;
    for (0..v.rows) |r| {
        for (0..v.cols) |c| {
            const h = cellAt(v, 0, @intCast(r), @intCast(v.cols - 1 - c), .horizontal);
            try testing.expectEqual(cellAt(v, 0, @intCast(r), @intCast(c), .none), h);
            const raw = cellAt(v, 0, @intCast(v.rows - 1 - r), @intCast(c), .vertical);
            const undone: u8 = (raw << 4) | (raw >> 4);
            try testing.expectEqual(cellAt(v, 0, @intCast(r), @intCast(c), .none), undone);
        }
    }
}

test "clip resolves both edges and reports fully-hidden frames" {
    const width: u16 = 40;
    const mid = clip(med, 10, width).?;
    try testing.expectEqual(@as(u16, 10), mid.screen_col);
    try testing.expectEqual(@as(u16, 0), mid.skip_cols);
    try testing.expectEqual(med.cols, mid.width);
    const left = clip(med, -5, width).?;
    try testing.expectEqual(@as(u16, 0), left.screen_col);
    try testing.expectEqual(@as(u16, 5), left.skip_cols);
    try testing.expectEqual(med.cols - 5, left.width);
    const right = clip(med, width - 4, width).?;
    try testing.expectEqual(width - 4, right.screen_col);
    try testing.expectEqual(@as(u16, 0), right.skip_cols);
    try testing.expectEqual(@as(u16, 4), right.width);
    try testing.expectEqual(@as(?Clip, null), clip(med, -@as(i32, med.cols), width));
    try testing.expectEqual(@as(?Clip, null), clip(med, width, width));
    try testing.expectEqual(@as(?Clip, null), clip(med, width + 100, width));
}

test "clip never describes a region outside the surface, at every size" {
    for ([_]Size{ .small, .medium, .large }) |s| {
        const v = s.variant();
        const width: u16 = 24;
        var col: i32 = -@as(i32, v.cols) - 2;
        while (col <= @as(i32, width) + 2) : (col += 1) {
            const c = clip(v, col, width) orelse continue;
            try testing.expect(c.skip_cols < v.cols);
            try testing.expect(c.width > 0);
            try testing.expect(c.skip_cols + c.width <= v.cols);
            try testing.expect(c.screen_col + c.width <= width);
        }
    }
}

test "fits refuses terminals with no room to spare" {
    try testing.expect(fits(med, 80, med.rows + 3));
    try testing.expect(!fits(med, 80, med.rows + 2));
    try testing.expect(!fits(med, med.cols + 1, 40));
    try testing.expect(fits(med, med.cols + 2, 40));
}

test "minTerminal is the real minimum, at every size" {
    // The help text and config quote a *terminal* size, while `fits` takes the
    // transcript region; the gap is the chrome the REPL has already claimed.
    // Stating it wrongly is the easy mistake -- the first version of this
    // feature shipped a figure five rows short -- so derive it in one place
    // and pin that one place here.
    const chrome: u16 = 5;
    for ([_]Size{ .small, .medium, .large }) |s| {
        const v = s.variant();
        const min = minTerminal(v);
        try testing.expect(fits(v, min.cols, min.rows - chrome));
        // One smaller in either direction must actually be refused, or the
        // figure is merely sufficient rather than minimal.
        try testing.expect(!fits(v, min.cols - 1, min.rows - chrome));
        try testing.expect(!fits(v, min.cols, min.rows - 1 - chrome));
    }
    // The medium figures are the ones the docs quote verbatim.
    try testing.expectEqual(@as(u16, 12), minTerminal(med).cols);
    try testing.expectEqual(@as(u16, 13), minTerminal(med).rows);
}

test "inputBoxHeight makes room for the robot without ever shrinking the box" {
    try testing.expectEqual(frames.small.rows + 2, inputBoxHeight(frames.small));
    try testing.expectEqual(med.rows + 2, inputBoxHeight(med));
    try testing.expectEqual(frames.large.rows + 2, inputBoxHeight(frames.large));
    for ([_]Size{ .small, .medium, .large }) |s| {
        try testing.expect(inputBoxHeight(s.variant()) >= 3);
    }
}

fn testSurface(gpa: std.mem.Allocator, size: vxfw.Size) !vxfw.Surface {
    return .{
        .size = size,
        .widget = undefined,
        .buffer = try vxfw.Surface.createBuffer(gpa, size),
        .children = &.{},
    };
}

test "drawCells paints inside the surface and leaves transparent cells alone" {
    const gpa = testing.allocator;
    const size: vxfw.Size = .{ .width = 40, .height = 14 };
    const surface = try testSurface(gpa, size);
    defer gpa.free(surface.buffer);
    drawCells(med, surface, 0, 8, 2, .none);

    var painted: usize = 0;
    for (0..size.height) |r| {
        for (0..size.width) |c| {
            if (surface.readCell(c, r).default) continue;
            painted += 1;
            try testing.expect(r >= 2 and r < 2 + med.rows);
            try testing.expect(c >= 8 and c < 8 + med.cols);
        }
    }
    // A sanity band rather than an exact count: the robot is not a solid
    // rectangle, and the real frames paint 14 to 19 of the 50 cells.
    try testing.expect(painted > 8);
    try testing.expect(painted < med.rows * med.cols);
}

test "a flipped draw paints the same number of cells, mirrored" {
    const gpa = testing.allocator;
    const size: vxfw.Size = .{ .width = 40, .height = 14 };
    for ([_]Flip{ .horizontal, .vertical }) |f| {
        const plain = try testSurface(gpa, size);
        defer gpa.free(plain.buffer);
        const flipped = try testSurface(gpa, size);
        defer gpa.free(flipped.buffer);
        drawCells(med, plain, 3, 8, 2, .none);
        drawCells(med, flipped, 3, 8, 2, f);

        var a: usize = 0;
        var b: usize = 0;
        for (plain.buffer) |cell| a += @intFromBool(!cell.default);
        for (flipped.buffer) |cell| b += @intFromBool(!cell.default);
        // Mirroring moves ink, it does not create or destroy it.
        try testing.expectEqual(a, b);
        // ...and it really did move: the frames are not symmetric.
        var same = true;
        for (plain.buffer, flipped.buffer) |p, q| {
            if (p.default != q.default) same = false;
        }
        try testing.expect(!same);

        // Exactly mirrored, not merely different. A drawCells that mirrored
        // the *data* but indexed the destination the same way would still
        // move ink and still fail to be symmetric, so the count and
        // difference checks above both pass while the robot comes out
        // scrambled.
        for (0..med.rows) |r| {
            for (0..med.cols) |c| {
                const src_r = switch (f) {
                    .vertical => med.rows - 1 - r,
                    else => r,
                };
                const src_c = switch (f) {
                    .horizontal => med.cols - 1 - c,
                    else => c,
                };
                const want = plain.readCell(8 + src_c, 2 + src_r).default;
                const got = flipped.readCell(8 + c, 2 + r).default;
                try testing.expectEqual(want, got);
            }
        }
    }
}

test "drawCells clipped to the left edge stays in bounds" {
    const gpa = testing.allocator;
    const size: vxfw.Size = .{ .width = 30, .height = 12 };
    const surface = try testSurface(gpa, size);
    defer gpa.free(surface.buffer);
    // Four columns off the left edge, so six remain visible. Not `-cols`,
    // which would be entirely off screen and make the assertions vacuous.
    drawCells(med, surface, 0, -4, 6, .none);
    var painted: usize = 0;
    for (0..size.height) |r| {
        for (0..size.width) |c| {
            if (surface.readCell(c, r).default) continue;
            painted += 1;
            try testing.expect(c < med.cols - 4);
            try testing.expect(r >= 6);
        }
    }
    try testing.expect(painted > 0);
}

test "drawCells off screen paints nothing at all" {
    const gpa = testing.allocator;
    const size: vxfw.Size = .{ .width = 30, .height = 12 };
    const surface = try testSurface(gpa, size);
    defer gpa.free(surface.buffer);
    drawCells(med, surface, 0, 30, 0, .none);
    drawCells(med, surface, 0, -@as(i32, med.cols), 0, .none);
    for (surface.buffer) |cell| try testing.expect(cell.default);
}

test "drawKitty places one image cell with a clip matching the visible columns" {
    const gpa = testing.allocator;
    const surface = try testSurface(gpa, .{ .width = 40, .height = 14 });
    defer gpa.free(surface.buffer);
    var ids: [frame_count]u32 = undefined;
    for (&ids, 0..) |*id, i| id.* = @intCast(100 + i);

    drawKitty(med, surface, ids, 3, 5, 1);
    const placement = surface.readCell(5, 1).image.?;
    try testing.expectEqual(@as(u32, 103), placement.img_id);
    try testing.expectEqual(med.rows, placement.options.size.?.rows.?);
    try testing.expectEqual(med.cols, placement.options.size.?.cols.?);
    try testing.expectEqual(@as(u16, 0), placement.options.clip_region.?.x.?);
    try testing.expectEqual(@as(u16, png_px), placement.options.clip_region.?.width.?);

    var images: usize = 0;
    for (surface.buffer) |c| images += @intFromBool(c.image != null);
    try testing.expectEqual(@as(usize, 1), images);
}

test "drawKitty clips the source in proportion to the hidden columns" {
    const gpa = testing.allocator;
    const surface = try testSurface(gpa, .{ .width = 40, .height = 14 });
    defer gpa.free(surface.buffer);
    const ids: [frame_count]u32 = [_]u32{7} ** frame_count;

    // Five of ten columns hidden off the left: half the source pixels are
    // skipped, and the placement is half as wide.
    drawKitty(med, surface, ids, 0, -5, 0);
    const placement = surface.readCell(0, 0).image.?;
    try testing.expectEqual(@as(u16, png_px / 2), placement.options.clip_region.?.x.?);
    try testing.expectEqual(@as(u16, png_px / 2), placement.options.clip_region.?.width.?);
    try testing.expectEqual(med.cols - 5, placement.options.size.?.cols.?);
}

test "draw falls back to half-blocks when graphics are unresolved or refused" {
    const gpa = testing.allocator;
    for ([_]Graphics{ .unknown, .cells }) |g| {
        const surface = try testSurface(gpa, .{ .width = 40, .height = 14 });
        defer gpa.free(surface.buffer);
        const st: State = .{ .mode = .loop, .graphics = g };
        st.draw(surface, 4, 1);
        var painted: usize = 0;
        for (surface.buffer) |cell| {
            try testing.expect(cell.image == null);
            painted += @intFromBool(!cell.default);
        }
        try testing.expect(painted > 8);
    }
}

test "draw picks the kitty id set matching the current flip" {
    const gpa = testing.allocator;
    var ids: [3][frame_count]u32 = undefined;
    for (&ids, 0..) |*set, o| {
        for (set) |*id| id.* = @intCast(10 * (o + 1));
    }
    // Right-facing loop uses the unmirrored set...
    {
        const surface = try testSurface(gpa, .{ .width = 40, .height = 14 });
        defer gpa.free(surface.buffer);
        const st: State = .{ .mode = .loop, .facing = .right, .graphics = .{ .kitty = ids } };
        st.draw(surface, 4, 1);
        try testing.expectEqual(@as(u32, 10), surface.readCell(4, 1).image.?.img_id);
    }
    // ...left-facing uses the horizontally mirrored one...
    {
        const surface = try testSurface(gpa, .{ .width = 40, .height = 14 });
        defer gpa.free(surface.buffer);
        const st: State = .{ .mode = .loop, .facing = .left, .graphics = .{ .kitty = ids } };
        st.draw(surface, 4, 1);
        try testing.expectEqual(@as(u32, 20), surface.readCell(4, 1).image.?.img_id);
    }
    // ...and a backspacing typist uses the upside-down one.
    {
        const surface = try testSurface(gpa, .{ .width = 40, .height = 14 });
        defer gpa.free(surface.buffer);
        const st: State = .{ .mode = .typing, .deleting = true, .graphics = .{ .kitty = ids } };
        st.draw(surface, 4, 1);
        try testing.expectEqual(@as(u32, 30), surface.readCell(4, 1).image.?.img_id);
    }
}

test "every size draws without escaping its box" {
    const gpa = testing.allocator;
    for ([_]Size{ .small, .medium, .large }) |s| {
        const v = s.variant();
        const size: vxfw.Size = .{ .width = v.cols + 10, .height = v.rows + 4 };
        for ([_]Flip{ .none, .horizontal, .vertical }) |f| {
            const surface = try testSurface(gpa, size);
            defer gpa.free(surface.buffer);
            drawCells(v, surface, 2, 3, 1, f);
            var painted: usize = 0;
            for (0..size.height) |r| {
                for (0..size.width) |c| {
                    if (surface.readCell(c, r).default) continue;
                    painted += 1;
                    try testing.expect(r >= 1 and r < 1 + v.rows);
                    try testing.expect(c >= 3 and c < 3 + v.cols);
                }
            }
            try testing.expect(painted > 0);
        }
    }
}
