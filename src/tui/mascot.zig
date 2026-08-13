//! The TUI mascot: a little robot that runs along above the input box.
//!
//! Off unless asked for (`--mascot`, or `tui.mascot` in config) -- it is an
//! easter egg, not a status indicator, and it costs real transcript rows.
//!
//! Two renderers for the same artwork:
//!
//!   - **kitty graphics**, when the terminal answered the capability query.
//!     The actual drawing, transmitted once at startup as eleven pngs and then
//!     placed by id, so a frame change costs one escape sequence.
//!   - **half-blocks**, everywhere else. `mascot_frames.zig` holds the same
//!     eleven frames quantized to a 21x10 grid of upper/lower half cells.
//!
//! Both paths share all the position and frame arithmetic below, which is
//! deliberately free of any vaxis types so it can be tested without a
//! terminal.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const frames = @import("mascot_frames.zig");
const log = @import("../util/log.zig");

pub const cols = frames.cols;
pub const rows = frames.rows;
pub const frame_count = frames.frame_count;

/// The source pngs, one per animation frame, for the kitty path. Embedded
/// rather than loaded from disk so a copied binary keeps its mascot.
const png_frames = [frame_count][]const u8{
    @embedFile("mascot/frame-00.png"),
    @embedFile("mascot/frame-01.png"),
    @embedFile("mascot/frame-02.png"),
    @embedFile("mascot/frame-03.png"),
    @embedFile("mascot/frame-04.png"),
    @embedFile("mascot/frame-05.png"),
    @embedFile("mascot/frame-06.png"),
    @embedFile("mascot/frame-07.png"),
    @embedFile("mascot/frame-08.png"),
    @embedFile("mascot/frame-09.png"),
    @embedFile("mascot/frame-10.png"),
};

/// Width of the source pngs in pixels. Needed to convert a column clip into
/// the source-pixel rectangle kitty's `x`/`w` placement keys expect.
const png_px = 192;

pub const Mode = enum {
    /// No mascot, no rows claimed. The default.
    off,
    /// Position tracks the input field: the robot runs right as you type and
    /// stands still when you stop.
    typing,
    /// Runs continuously left to right, off the right edge, back in from the
    /// left. Ignores what you are doing entirely.
    loop,

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
            // What `cli.zig` substitutes for a bare `--mascot`.
            .{ "on", bare_default },
            .{ "true", bare_default },
        };
        inline for (table) |entry| {
            if (std.ascii.eqlIgnoreCase(text, entry[0])) return entry[1];
        }
        return null;
    }
};

/// What the terminal turned out to support. Resolved once, on the first draw
/// that has a live vaxis handle to ask, because the capability query is still
/// in flight while the model is being built.
const Graphics = union(enum) {
    /// Not yet asked.
    unknown,
    /// One transmitted image id per animation frame.
    kitty: [frame_count]u32,
    /// Either no kitty support or a transmit that failed. Half-blocks from
    /// here on; never retried, so a broken terminal cannot make every frame
    /// re-attempt a megabyte of base64.
    cells,
};

pub const State = struct {
    mode: Mode = .off,
    /// Index into the animation. Advances with movement, so a robot standing
    /// still does not run in place.
    frame: u8 = 0,
    /// Columns travelled in `loop` mode. Monotonic, wrapped when read.
    travel: u32 = 0,
    /// `typing` mode: the input length the last advance was computed from, so
    /// a redraw that changes nothing does not advance the legs.
    last_len: usize = 0,
    graphics: Graphics = .unknown,

    pub fn enabled(self: State) bool {
        return self.mode != .off;
    }

    /// Advance one animation tick. `typed_len` is the current input length,
    /// ignored in `loop` mode.
    ///
    /// `loop` advances every tick; `typing` only when the input length
    /// actually changed, which is what makes the robot look like it is
    /// running *because* you are typing rather than merely while you are.
    pub fn advance(self: *State, typed_len: usize) void {
        switch (self.mode) {
            .off => {},
            .loop => {
                self.travel +%= 1;
                self.frame = @intCast((self.frame + 1) % frame_count);
            },
            .typing => {
                if (typed_len == self.last_len) return;
                self.last_len = typed_len;
                self.frame = @intCast((self.frame + 1) % frame_count);
            },
        }
    }

    /// Leftmost column of the mascot, which may be negative (part-way in from
    /// the left edge) or past `width` (part-way out the right).
    pub fn column(self: State, width: u16, typed_len: usize) i32 {
        return switch (self.mode) {
            .off => 0,
            .loop => loopColumn(self.travel, width),
            .typing => typeColumn(typed_len, width),
        };
    }

    /// Transmits every frame to the terminal, once, and remembers the ids.
    ///
    /// Called from the draw path because that is the first place with both a
    /// live `*vaxis.Vaxis` and a settled capability answer -- `queryTerminal`
    /// is still in flight when the model is constructed, so asking earlier
    /// reliably reports no kitty support. Any failure (no support, a refused
    /// transmit, an allocation failure) latches to `.cells`, so this runs at
    /// most once either way and a misbehaving terminal cannot make every frame
    /// re-attempt a few hundred kilobytes of base64.
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
        var ids: [frame_count]u32 = undefined;
        for (png_frames, 0..) |bytes, i| {
            const img = vx.loadImage(gpa, tty, .{ .mem = bytes }) catch |err| {
                // Partial transmits are not unwound: the ids already sent are
                // abandoned, and the terminal drops them when it next clears
                // images. Cheaper than tracking them to free on a path that
                // only runs when the terminal is already misbehaving.
                log.log(.debug, "mascot: kitty transmit failed ({t}), using half-blocks", .{err});
                self.graphics = .cells;
                return;
            };
            ids[i] = img.id;
        }
        self.graphics = .{ .kitty = ids };
    }

    /// Draws the mascot with whichever renderer the terminal earned.
    pub fn draw(self: State, surface: vxfw.Surface, col0: i32, row0: u16) void {
        switch (self.graphics) {
            .kitty => |ids| drawKitty(surface, ids, self.frame, col0, row0),
            // `.unknown` should have been resolved by `ensureGraphics` before
            // the first draw, but half-blocks are the safe answer if not.
            .cells, .unknown => drawCells(surface, self.frame, col0, row0),
        }
    }
};

/// Wraps through `[-cols, width)`, so the robot walks fully on from the left
/// edge and fully off the right before reappearing rather than popping in and
/// out at the boundaries.
pub fn loopColumn(travel: u32, width: u16) i32 {
    const span: u32 = @as(u32, width) + cols;
    return @as(i32, @intCast(travel % span)) - @as(i32, cols);
}

/// One column per character typed, parked at the right margin once the input
/// is longer than the space available. Clamped rather than wrapped: a long
/// task should leave the robot waiting at the edge, not teleporting back to
/// the start mid-sentence.
pub fn typeColumn(typed_len: usize, width: u16) i32 {
    const limit: i32 = @as(i32, @intCast(width)) - @as(i32, cols);
    if (limit <= 0) return 0;
    const want: i32 = @intCast(@min(typed_len, @as(usize, @intCast(limit))));
    return want;
}

/// Whether there is actually room to draw. A terminal too narrow for the
/// robot, or too short to spare `rows` on top of a usable transcript, gets no
/// mascot rather than a clipped one shoving the transcript off screen.
pub fn fits(width: u16, avail_rows: u16) bool {
    return width >= cols + 2 and avail_rows >= rows + min_transcript_rows;
}

/// Rows of transcript that must survive underneath the mascot. Three is
/// enough to still read a streaming reply.
const min_transcript_rows: u16 = 3;

/// The visible slice of a mascot whose leftmost column is `col0`, in cells.
pub const Clip = struct {
    /// First column on screen the mascot occupies.
    screen_col: u16,
    /// How many of the mascot's own columns are hidden off the left edge.
    skip_cols: u16,
    /// Visible width in columns.
    width: u16,
};

/// Resolves `col0` (possibly off either edge) against the surface width.
/// Null when the mascot is entirely off screen this frame.
pub fn clip(col0: i32, width: u16) ?Clip {
    if (col0 >= @as(i32, @intCast(width))) return null;
    if (col0 + @as(i32, cols) <= 0) return null;
    const skip: u16 = if (col0 < 0) @intCast(-col0) else 0;
    const screen_col: u16 = if (col0 < 0) 0 else @intCast(col0);
    const visible = @min(cols - skip, width - screen_col);
    if (visible == 0) return null;
    return .{ .screen_col = screen_col, .skip_cols = skip, .width = visible };
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
/// untouched, so the transcript shows through around the robot instead of
/// being boxed out by a rectangle of background.
pub fn drawCells(surface: vxfw.Surface, frame: u8, col0: i32, row0: u16) void {
    const c = clip(col0, surface.size.width) orelse return;
    const data = &frames.frames[frame % frame_count];
    for (0..rows) |r| {
        const row: u16 = row0 + @as(u16, @intCast(r));
        if (row >= surface.size.height) break;
        for (0..c.width) |i| {
            const src_col = c.skip_cols + @as(u16, @intCast(i));
            const byte = data[r * cols + src_col];
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
/// A partly-off-screen robot is handled with kitty's source clip rather than
/// by hiding it, so the left-edge entry matches what the half-block path
/// does. The clip rectangle is in *source png pixels*, not cells, and is
/// applied before the row/col scaling.
pub fn drawKitty(surface: vxfw.Surface, ids: [frame_count]u32, frame: u8, col0: i32, row0: u16) void {
    const c = clip(col0, surface.size.width) orelse return;
    if (row0 >= surface.size.height) return;
    const clip_x: u16 = @intCast(@divTrunc(@as(u32, c.skip_cols) * png_px, cols));
    const clip_w: u16 = @intCast(@divTrunc(@as(u32, c.width) * png_px, cols));
    surface.writeCell(c.screen_col, row0, .{
        .image = .{
            .img_id = ids[frame % frame_count],
            .options = .{
                .clip_region = .{ .x = clip_x, .width = clip_w },
                .size = .{ .rows = rows, .cols = c.width },
            },
        },
    });
}

test "Mode.parse accepts the documented spellings and rejects junk" {
    try std.testing.expectEqual(Mode.off, Mode.parse("off").?);
    try std.testing.expectEqual(Mode.typing, Mode.parse("type").?);
    try std.testing.expectEqual(Mode.typing, Mode.parse("typing").?);
    try std.testing.expectEqual(Mode.loop, Mode.parse("loop").?);
    // Case-insensitive, because config files and flags disagree about case.
    try std.testing.expectEqual(Mode.loop, Mode.parse("LOOP").?);
    // The stand-in cli.zig uses for a bare `--mascot`.
    try std.testing.expectEqual(Mode.bare_default, Mode.parse("on").?);
    try std.testing.expectEqual(@as(?Mode, null), Mode.parse("sideways"));
    try std.testing.expectEqual(@as(?Mode, null), Mode.parse(""));
}

test "loopColumn enters from off-left and exits fully off-right" {
    const width: u16 = 80;
    // Starts fully hidden to the left of the screen.
    try std.testing.expectEqual(@as(i32, -@as(i32, cols)), loopColumn(0, width));
    // One tick in, one column of robot is showing.
    try std.testing.expectEqual(@as(i32, -@as(i32, cols) + 1), loopColumn(1, width));
    // Reaches the left edge exactly `cols` ticks in.
    try std.testing.expectEqual(@as(i32, 0), loopColumn(cols, width));
    // Last position before the wrap is one column shy of fully off-right.
    try std.testing.expectEqual(@as(i32, width - 1), loopColumn(width + cols - 1, width));
    // And then it starts over.
    try std.testing.expectEqual(loopColumn(0, width), loopColumn(width + cols, width));
}

test "loopColumn is always somewhere on the wrap span" {
    const width: u16 = 40;
    for (0..500) |t| {
        const col = loopColumn(@intCast(t), width);
        try std.testing.expect(col >= -@as(i32, cols));
        try std.testing.expect(col < width);
    }
}

test "typeColumn tracks input length then parks at the right margin" {
    const width: u16 = 80;
    try std.testing.expectEqual(@as(i32, 0), typeColumn(0, width));
    try std.testing.expectEqual(@as(i32, 5), typeColumn(5, width));
    const limit: i32 = @as(i32, width) - @as(i32, cols);
    try std.testing.expectEqual(limit, typeColumn(@intCast(limit), width));
    // Past the margin it stops rather than wrapping or running off screen.
    try std.testing.expectEqual(limit, typeColumn(@intCast(limit + 1), width));
    try std.testing.expectEqual(limit, typeColumn(10_000, width));
}

test "typeColumn pins to zero when the terminal is narrower than the mascot" {
    try std.testing.expectEqual(@as(i32, 0), typeColumn(50, cols));
    try std.testing.expectEqual(@as(i32, 0), typeColumn(50, 4));
}

test "advance only moves the legs in typing mode when the input changed" {
    var st: State = .{ .mode = .typing };
    try std.testing.expectEqual(@as(u8, 0), st.frame);
    // A redraw with the same input must not animate: an idle robot stands.
    st.advance(0);
    try std.testing.expectEqual(@as(u8, 0), st.frame);
    st.advance(1);
    try std.testing.expectEqual(@as(u8, 1), st.frame);
    st.advance(1);
    try std.testing.expectEqual(@as(u8, 1), st.frame);
    // Backspacing is movement too.
    st.advance(0);
    try std.testing.expectEqual(@as(u8, 2), st.frame);
}

test "advance runs every tick in loop mode and wraps the frame index" {
    var st: State = .{ .mode = .loop };
    for (0..frame_count) |_| st.advance(0);
    try std.testing.expectEqual(@as(u8, 0), st.frame);
    try std.testing.expectEqual(@as(u32, frame_count), st.travel);
    st.advance(0);
    try std.testing.expectEqual(@as(u8, 1), st.frame);
}

test "advance is inert when off" {
    var st: State = .{ .mode = .off };
    for (0..50) |i| st.advance(i);
    try std.testing.expectEqual(@as(u8, 0), st.frame);
    try std.testing.expectEqual(@as(u32, 0), st.travel);
    try std.testing.expect(!st.enabled());
}

test "clip resolves both edges and reports fully-hidden frames" {
    const width: u16 = 40;
    // Fully on screen.
    const mid = clip(10, width).?;
    try std.testing.expectEqual(@as(u16, 10), mid.screen_col);
    try std.testing.expectEqual(@as(u16, 0), mid.skip_cols);
    try std.testing.expectEqual(cols, mid.width);
    // Part-way in from the left: the hidden columns are skipped in the source.
    const left = clip(-5, width).?;
    try std.testing.expectEqual(@as(u16, 0), left.screen_col);
    try std.testing.expectEqual(@as(u16, 5), left.skip_cols);
    try std.testing.expectEqual(cols - 5, left.width);
    // Part-way off the right: truncated to what is left of the row.
    const right = clip(width - 4, width).?;
    try std.testing.expectEqual(width - 4, right.screen_col);
    try std.testing.expectEqual(@as(u16, 0), right.skip_cols);
    try std.testing.expectEqual(@as(u16, 4), right.width);
    // Entirely off either side.
    try std.testing.expectEqual(@as(?Clip, null), clip(-@as(i32, cols), width));
    try std.testing.expectEqual(@as(?Clip, null), clip(width, width));
    try std.testing.expectEqual(@as(?Clip, null), clip(width + 100, width));
}

test "clip never describes a region outside the surface" {
    const width: u16 = 24;
    var col: i32 = -@as(i32, cols) - 2;
    while (col <= @as(i32, width) + 2) : (col += 1) {
        const c = clip(col, width) orelse continue;
        try std.testing.expect(c.skip_cols < cols);
        try std.testing.expect(c.width > 0);
        try std.testing.expect(c.skip_cols + c.width <= cols);
        try std.testing.expect(c.screen_col + c.width <= width);
    }
}

test "fits refuses terminals with no room to spare" {
    try std.testing.expect(fits(80, rows + 3));
    try std.testing.expect(!fits(80, rows + 2));
    try std.testing.expect(!fits(cols + 1, 40));
    try std.testing.expect(fits(cols + 2, 40));
}

test "every baked frame is fully populated and in-palette" {
    for (frames.frames) |frame| {
        try std.testing.expectEqual(@as(usize, rows * cols), frame.len);
        for (frame) |byte| {
            for ([_]u8{ byte >> 4, byte & 0x0F }) |nib| {
                if (nib == frames.transparent) continue;
                try std.testing.expect(nib < frames.palette.len);
            }
        }
    }
}

test "the baked frames are not all identical" {
    // Guards the generator: a resampling bug that collapsed every frame to
    // the same cells would still round-trip and still animate, silently.
    var differs = false;
    for (frames.frames[1..]) |frame| {
        if (!std.mem.eql(u8, &frames.frames[0], &frame)) differs = true;
    }
    try std.testing.expect(differs);
}

test "drawCells paints inside the surface and leaves transparent cells alone" {
    const gpa = std.testing.allocator;
    const size: vxfw.Size = .{ .width = 40, .height = 14 };
    const buffer = try vxfw.Surface.createBuffer(gpa, size);
    defer gpa.free(buffer);
    const surface: vxfw.Surface = .{
        .size = size,
        .widget = undefined,
        .buffer = buffer,
        .children = &.{},
    };
    drawCells(surface, 0, 8, 2);

    var painted: usize = 0;
    for (0..size.height) |r| {
        for (0..size.width) |c| {
            const cell = surface.readCell(c, r);
            if (cell.default) continue;
            painted += 1;
            // Nothing may land outside the mascot's own box.
            try std.testing.expect(r >= 2 and r < 2 + rows);
            try std.testing.expect(c >= 8 and c < 8 + cols);
        }
    }
    // The robot is not a solid rectangle, so this is a sanity band rather
    // than an exact count: it must draw something substantial, and it must
    // leave some of its bounding box see-through.
    try std.testing.expect(painted > 20);
    try std.testing.expect(painted < rows * cols);
}

test "drawCells clipped to the left edge stays in bounds" {
    const gpa = std.testing.allocator;
    const size: vxfw.Size = .{ .width = 30, .height = 12 };
    const buffer = try vxfw.Surface.createBuffer(gpa, size);
    defer gpa.free(buffer);
    const surface: vxfw.Surface = .{
        .size = size,
        .widget = undefined,
        .buffer = buffer,
        .children = &.{},
    };
    // Half off the left edge, and low enough that the last rows fall off the
    // bottom of the surface too.
    drawCells(surface, 0, -10, 6);
    for (0..size.height) |r| {
        for (0..size.width) |c| {
            if (surface.readCell(c, r).default) continue;
            try std.testing.expect(c < cols - 10);
            try std.testing.expect(r >= 6);
        }
    }
}

test "drawCells off screen paints nothing at all" {
    const gpa = std.testing.allocator;
    const size: vxfw.Size = .{ .width = 30, .height = 12 };
    const buffer = try vxfw.Surface.createBuffer(gpa, size);
    defer gpa.free(buffer);
    const surface: vxfw.Surface = .{
        .size = size,
        .widget = undefined,
        .buffer = buffer,
        .children = &.{},
    };
    drawCells(surface, 0, 30, 0);
    drawCells(surface, 0, -@as(i32, cols), 0);
    for (buffer) |cell| try std.testing.expect(cell.default);
}

test "drawKitty places one image cell with a clip matching the visible columns" {
    const gpa = std.testing.allocator;
    const size: vxfw.Size = .{ .width = 40, .height = 14 };
    const buffer = try vxfw.Surface.createBuffer(gpa, size);
    defer gpa.free(buffer);
    const surface: vxfw.Surface = .{
        .size = size,
        .widget = undefined,
        .buffer = buffer,
        .children = &.{},
    };
    var ids: [frame_count]u32 = undefined;
    for (&ids, 0..) |*id, i| id.* = @intCast(100 + i);

    drawKitty(surface, ids, 3, 5, 1);
    const cell = surface.readCell(5, 1);
    const placement = cell.image.?;
    try std.testing.expectEqual(@as(u32, 103), placement.img_id);
    try std.testing.expectEqual(rows, placement.options.size.?.rows.?);
    try std.testing.expectEqual(cols, placement.options.size.?.cols.?);
    // Fully visible, so nothing is clipped off the left and the full source
    // width is used.
    try std.testing.expectEqual(@as(u16, 0), placement.options.clip_region.?.x.?);
    try std.testing.expectEqual(@as(u16, png_px), placement.options.clip_region.?.width.?);

    // Exactly one cell carries the image; the rest of the box is untouched.
    var images: usize = 0;
    for (buffer) |c| {
        if (c.image != null) images += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), images);
}

test "drawKitty clips the source in proportion to the hidden columns" {
    const gpa = std.testing.allocator;
    const size: vxfw.Size = .{ .width = 40, .height = 14 };
    const buffer = try vxfw.Surface.createBuffer(gpa, size);
    defer gpa.free(buffer);
    const surface: vxfw.Surface = .{
        .size = size,
        .widget = undefined,
        .buffer = buffer,
        .children = &.{},
    };
    const ids: [frame_count]u32 = [_]u32{7} ** frame_count;

    // Seven of twenty-one columns hidden off the left: a third of the source
    // pixels are skipped, and the placement is two thirds as wide.
    drawKitty(surface, ids, 0, -7, 0);
    const placement = surface.readCell(0, 0).image.?;
    try std.testing.expectEqual(@as(u16, png_px / 3), placement.options.clip_region.?.x.?);
    try std.testing.expectEqual(@as(u16, png_px / 3 * 2), placement.options.clip_region.?.width.?);
    try std.testing.expectEqual(cols - 7, placement.options.size.?.cols.?);
}

test "draw falls back to half-blocks when graphics are unresolved or refused" {
    const gpa = std.testing.allocator;
    const size: vxfw.Size = .{ .width = 40, .height = 14 };
    for ([_]Graphics{ .unknown, .cells }) |g| {
        const buffer = try vxfw.Surface.createBuffer(gpa, size);
        defer gpa.free(buffer);
        const surface: vxfw.Surface = .{
            .size = size,
            .widget = undefined,
            .buffer = buffer,
            .children = &.{},
        };
        const st: State = .{ .mode = .loop, .graphics = g };
        st.draw(surface, 4, 1);
        var painted: usize = 0;
        for (buffer) |cell| {
            try std.testing.expect(cell.image == null);
            if (!cell.default) painted += 1;
        }
        try std.testing.expect(painted > 20);
    }
}

test "draw uses the kitty placement once graphics resolved that way" {
    const gpa = std.testing.allocator;
    const size: vxfw.Size = .{ .width = 40, .height = 14 };
    const buffer = try vxfw.Surface.createBuffer(gpa, size);
    defer gpa.free(buffer);
    const surface: vxfw.Surface = .{
        .size = size,
        .widget = undefined,
        .buffer = buffer,
        .children = &.{},
    };
    const st: State = .{ .mode = .loop, .graphics = .{ .kitty = [_]u32{42} ** frame_count } };
    st.draw(surface, 4, 1);
    try std.testing.expectEqual(@as(u32, 42), surface.readCell(4, 1).image.?.img_id);
}
