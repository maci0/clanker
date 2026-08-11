//! libvaxis-backed REPL (docs/ROADMAP.md migration). Reachable via
//! `clanker repl-vaxis`, separate from the hand-rolled `clanker repl`
//! (src/tui/*) while this is proven out.
//!
//! Architecture: a single root `vxfw.Widget` ("Model") drives everything.
//! `vxfw.App.run` already handles SIGWINCH (`.winsize` events resize and
//! redraw automatically — no self-pipe needed, unlike src/tui/term.zig)
//! and owns the render loop. A submitted task runs `Agent.run` on a
//! background thread (LLM calls and tool execution are blocking); the
//! callbacks it takes (`on_token`/`on_tool_call`/`on_tool_result`) are bare
//! function pointers with no userdata slot, so they write into module-level,
//! mutex-guarded state, and the Model's `.tick` handler re-schedules itself
//! every 50ms *only while a turn is in flight* to pick up new streamed
//! content — idle, there is no timer running and the app is purely
//! event-driven, same principle as this session's KeyReader poll() fix in
//! the old REPL.
//!
//! Deliberately not yet built (documented gaps, not oversights): slash
//! command palette/tab-complete (only a hardcoded `/quit` is handled),
//! inline ask_user/approval prompts (falls back to the same "nobody
//! attached" default a headless run gets), manual scroll-back (the
//! transcript always shows its tail), and the left-bar tool-card styling
//! from the old transcript.zig (tool calls render as plain dim lines here).

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const config = @import("../config.zig");
const client = @import("../llm/client.zig");
const types = @import("../llm/types.zig");
const providers = @import("../llm/providers.zig");
const registry = @import("../tools/registry.zig");
const agent_loop = @import("../agent/loop.zig");
const Agent = agent_loop.Agent;
const log = @import("../util/log.zig");

/// A C0 control or DEL that must not reach the terminal, mirroring
/// src/tui/transcript.zig's writeSanitized (CWE-150): everything rendered
/// here is text clanker didn't generate itself.
fn stripControls(gpa: std.mem.Allocator, bytes: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (bytes) |c| {
        const drop = (c < 0x20 and c != '\n' and c != '\t') or c == 0x7F;
        if (!drop) out.append(gpa, c) catch return bytes;
    }
    return out.toOwnedSlice(gpa) catch bytes;
}

// ---------------------------------------------------------------------
// Module-level bridge state: Agent's callbacks are bare `*const fn(...)`
// with no captured context, so the background run thread and the render
// thread meet here instead, guarded by one mutex.
// ---------------------------------------------------------------------

var g_mutex: std.Io.Mutex = .init;
var g_io: std.Io = undefined;
var g_gpa: std.mem.Allocator = undefined;
var g_streaming: bool = false;
var g_stream_buf: std.ArrayList(u8) = .empty;
var g_tool_lines: std.ArrayList([]const u8) = .empty;
var g_stop_flag: std.atomic.Value(bool) = .init(false);

fn onToken(delta: []const u8) void {
    g_mutex.lockUncancelable(g_io);
    defer g_mutex.unlock(g_io);
    const clean = stripControls(g_gpa, delta);
    defer if (clean.ptr != delta.ptr) g_gpa.free(clean);
    g_stream_buf.appendSlice(g_gpa, clean) catch {};
}

fn onToolCall(calls: []const types.ToolCall) void {
    g_mutex.lockUncancelable(g_io);
    defer g_mutex.unlock(g_io);
    for (calls) |c| {
        const line = std.fmt.allocPrint(g_gpa, "\xe2\x9a\x99 {s}", .{c.name}) catch continue;
        g_tool_lines.append(g_gpa, line) catch {};
    }
}

fn onToolResult(elapsed_ms: u64) void {
    g_mutex.lockUncancelable(g_io);
    defer g_mutex.unlock(g_io);
    const line = std.fmt.allocPrint(g_gpa, "  \xe2\x86\xb3 done in {d}ms", .{elapsed_ms}) catch return;
    g_tool_lines.append(g_gpa, line) catch {};
}

const RunThreadArgs = struct {
    model: *Model,
    task: []const u8,
};

fn runThreadMain(args: RunThreadArgs) void {
    const self = args.model;
    const messages = &self.messages;
    var err_detail: ?[]const u8 = null;

    var a = Agent.init(&self.ctx, self.arena, &self.provider, &self.cfg, &self.reg, self.tool_defs) catch |err| {
        self.finishTurn(std.fmt.allocPrint(self.arena, "[error: {s}]", .{@errorName(err)}) catch "[error]");
        return;
    };
    a.on_token = onToken;
    a.on_tool_call = onToolCall;
    a.on_tool_result = onToolResult;
    a.stop_flag = &g_stop_flag;

    const resp = a.run(messages, args.task, &err_detail) catch |err| {
        const text = if (err_detail) |d|
            std.fmt.allocPrint(self.arena, "[error: {s}]", .{d}) catch "[error]"
        else
            std.fmt.allocPrint(self.arena, "[error: {s}]", .{@errorName(err)}) catch "[error]";
        self.finishTurn(text);
        return;
    };
    self.finishTurn(resp.message.content orelse "");
}

/// One rendered line of session-permanent transcript (a completed turn's
/// text, or a tool-call/result line).
const Line = struct {
    text: []const u8,
    dim: bool = false,
};

const Model = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.mem.Allocator,
    ctx: client.Ctx,
    cfg: config.Config,
    provider: config.Provider,
    reg: registry.Registry,
    tool_defs: []const types.ToolDef,
    messages: std.ArrayList(types.Message) = .empty,

    lines: std.ArrayList(Line) = .empty,
    text_field: vxfw.TextField,
    thread: ?std.Thread = null,
    status_buf: [160]u8 = undefined,

    fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    /// Called from the background run thread once Agent.run returns
    /// (success or error alike): folds the streamed buffer and any tool
    /// lines into permanent `lines`, clears the live streaming state.
    fn finishTurn(self: *Model, final_text: []const u8) void {
        g_mutex.lockUncancelable(g_io);
        defer g_mutex.unlock(g_io);
        for (g_tool_lines.items) |l| self.lines.append(self.arena, .{ .text = l, .dim = true }) catch {};
        g_tool_lines.clearRetainingCapacity();
        const answer = if (final_text.len > 0) final_text else g_stream_buf.items;
        const owned = self.arena.dupe(u8, answer) catch answer;
        self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "\xe2\x80\xba {s}", .{owned}) catch owned }) catch {};
        g_stream_buf.clearRetainingCapacity();
        g_streaming = false;
        if (self.thread) |t| {
            t.detach();
            self.thread = null;
        }
    }

    fn submit(self: *Model, ctx: *vxfw.EventContext) !void {
        const task = try self.text_field.toOwnedSlice();
        defer self.gpa.free(task);
        if (task.len == 0) return;
        self.text_field.reset();

        if (std.mem.eql(u8, task, "/quit")) {
            ctx.quit = true;
            return;
        }

        self.lines.append(self.arena, .{ .text = try std.fmt.allocPrint(self.arena, "clanker> {s}", .{task}) }) catch {};

        g_mutex.lockUncancelable(g_io);
        g_streaming = true;
        g_stream_buf.clearRetainingCapacity();
        g_tool_lines.clearRetainingCapacity();
        g_stop_flag.store(false, .release);
        g_mutex.unlock(g_io);

        const owned_task = try self.arena.dupe(u8, task);
        self.thread = try std.Thread.spawn(.{}, runThreadMain, .{RunThreadArgs{ .model = self, .task = owned_task }});

        // Kick off the tick heartbeat that picks up streamed deltas.
        try ctx.tick(50, self.widget());
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => try ctx.requestFocus(self.text_field.widget()),
            .tick => {
                g_mutex.lockUncancelable(g_io);
                const still_streaming = g_streaming;
                g_mutex.unlock(g_io);
                if (still_streaming) try ctx.tick(50, self.widget());
                ctx.redraw = true;
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    g_mutex.lockUncancelable(g_io);
                    const streaming = g_streaming;
                    g_mutex.unlock(g_io);
                    if (streaming) {
                        g_stop_flag.store(true, .release);
                    } else {
                        ctx.quit = true;
                    }
                    return;
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    try self.submit(ctx);
                    return;
                }
                try self.text_field.handleEvent(ctx, event);
            },
            else => try self.text_field.handleEvent(ctx, event),
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();

        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), max);
        const dim: vaxis.Style = .{ .dim = true };
        @memset(surface.buffer, .{ .style = .{}, .default = true });

        // Row 0: status line.
        g_mutex.lockUncancelable(g_io);
        const streaming = g_streaming;
        const stream_snapshot = ctx.arena.dupe(u8, g_stream_buf.items) catch "";
        g_mutex.unlock(g_io);

        const status = std.fmt.bufPrint(&self.status_buf, "clanker (vaxis) \xc2\xb7 {s}/{s} \xc2\xb7 {s} \xc2\xb7 /quit or Ctrl-C to exit", .{
            self.provider.name,
            self.provider.activeModelName(),
            if (streaming) "thinking\xe2\x80\xa6" else "ready",
        }) catch "clanker (vaxis)";
        writeRow(surface, 0, status, dim);

        // Bottom: bordered input box (3 rows).
        const box_h: u16 = 3;
        const box_y = max.height -| box_h;
        drawBox(surface, 0, box_y, max.width, box_h);
        const input_surf = try self.text_field.draw(ctx.withConstraints(.{}, .{ .width = max.width -| 4, .height = 1 }));
        var children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = box_y + 1, .col = 2 }, .surface = input_surf };

        // Middle: transcript tail, most recent content last.
        const top: u16 = 1;
        const bottom = box_y -| 1;
        const avail_rows: u16 = if (bottom > top) bottom - top else 0;
        var row: u16 = top;
        const start = tailStart(self.lines.items, avail_rows);
        var i: usize = start;
        while (i < self.lines.items.len and row < bottom) : (i += 1) {
            const l = self.lines.items[i];
            writeRow(surface, row, l.text, if (l.dim) dim else .{});
            row += 1;
        }
        if (streaming and row < bottom and stream_snapshot.len > 0) {
            writeWrapped(surface, &row, bottom, max.width, stream_snapshot, .{});
        }

        surface.children = children;
        return surface;
    }
};

/// How many trailing entries of `lines` to start from so the transcript
/// shows its tail, not its head, once history exceeds the visible height.
/// A rough heuristic (one line of history per visible row) — long entries
/// still wrap past that during draw, so this under- rather than
/// over-estimates what fits, which just means the top of the visible
/// region can be blank rather than truncating the newest content.
fn tailStart(lines: []const Line, avail_rows: u16) usize {
    const n = lines.len;
    const want: usize = avail_rows;
    return if (n > want) n - want else 0;
}

fn writeRow(surface: vxfw.Surface, row: u16, text: []const u8, style: vaxis.Style) void {
    var col: u16 = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepointSlice()) |cp| {
        if (col >= surface.size.width) break;
        surface.writeCell(col, row, .{ .char = .{ .grapheme = cp, .width = 1 }, .style = style });
        col += 1;
    }
}

/// Writes `text` wrapped at `width`, advancing `*row` a line at a time,
/// stopping at `bottom`. Simple hard-wrap (no word-break) — good enough for
/// a live streaming tail; MdStream-quality wrapping is follow-up work.
fn writeWrapped(surface: vxfw.Surface, row: *u16, bottom: u16, width: u16, text: []const u8, style: vaxis.Style) void {
    var col: u16 = 0;
    var i: usize = 0;
    while (i < text.len and row.* < bottom) {
        const c = text[i];
        if (c == '\n' or col >= width) {
            row.* += 1;
            col = 0;
            i += 1;
            continue;
        }
        if (row.* < bottom) surface.writeCell(col, row.*, .{ .char = .{ .grapheme = text[i .. i + 1], .width = 1 }, .style = style });
        col += 1;
        i += 1;
    }
}

fn drawBox(surface: vxfw.Surface, x: u16, y: u16, w: u16, h: u16) void {
    const style: vaxis.Style = .{};
    if (w == 0 or h == 0) return;
    surface.writeCell(x, y, .{ .char = .{ .grapheme = "\xe2\x95\xad", .width = 1 }, .style = style });
    surface.writeCell(x + w -| 1, y, .{ .char = .{ .grapheme = "\xe2\x95\xae", .width = 1 }, .style = style });
    surface.writeCell(x, y + h -| 1, .{ .char = .{ .grapheme = "\xe2\x95\xb0", .width = 1 }, .style = style });
    surface.writeCell(x + w -| 1, y + h -| 1, .{ .char = .{ .grapheme = "\xe2\x95\xaf", .width = 1 }, .style = style });
    var i: u16 = x + 1;
    while (i < x + w -| 1) : (i += 1) {
        surface.writeCell(i, y, .{ .char = .{ .grapheme = "\xe2\x94\x80", .width = 1 }, .style = style });
        surface.writeCell(i, y + h -| 1, .{ .char = .{ .grapheme = "\xe2\x94\x80", .width = 1 }, .style = style });
    }
    var r: u16 = y + 1;
    while (r < y + h -| 1) : (r += 1) {
        surface.writeCell(x, r, .{ .char = .{ .grapheme = "\xe2\x94\x82", .width = 1 }, .style = style });
        surface.writeCell(x + w -| 1, r, .{ .char = .{ .grapheme = "\xe2\x94\x82", .width = 1 }, .style = style });
    }
}

pub fn cmdReplVaxis(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    g_gpa = gpa;
    g_io = io;
    // log.log writes straight to stderr with no coordination with vaxis's
    // owned alt-screen buffer, unlike the old REPL where stray stderr text
    // just scrolled by harmlessly. Any stray write here corrupts the
    // screen, so raise the threshold for this command's whole lifetime.
    log.setLevel(.error_);

    var cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    std.Io.Dir.cwd().createDirPath(io, cfg.agent.sandbox_root) catch {};
    var reg = try registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir);
    const tool_defs = try reg.toToolDefs(arena);
    const provider = (try cfg.provider(null)).*;
    const ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = init.environ_map, .cfg = &cfg };

    var buffer: [1024]u8 = undefined;
    var app: vxfw.App = try .init(io, gpa, init.environ_map, &buffer);
    defer app.deinit();

    const model = try arena.create(Model);
    model.* = .{
        .gpa = gpa,
        .io = io,
        .arena = arena,
        .ctx = ctx,
        .cfg = cfg,
        .provider = provider,
        .reg = reg,
        .tool_defs = tool_defs,
        .text_field = vxfw.TextField.init(gpa),
    };

    try app.run(model.widget(), .{});
}
