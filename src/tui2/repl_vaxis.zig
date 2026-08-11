//! libvaxis-backed REPL (docs/ROADMAP.md migration). This is `clanker repl`,
//! the default REPL; the hand-rolled src/tui REPL was removed once this
//! proved out (the `repl-vaxis` spelling is kept as a compatibility alias in
//! cli.zig).
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
//! command palette/tab-complete (only a fixed set of quit commands is
//! handled),
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
const syntax = @import("syntax.zig");
const theme_mod = @import("../tui/theme.zig");

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
/// text, or a tool-call/result line). `fence_lang` is non-null for lines
/// inside a fenced code block: they render through the syntax highlighter
/// instead of getting the dim fence style.
const Line = struct {
    text: []const u8,
    dim: bool = false,
    fence_lang: ?[]const u8 = null,
};

/// `CLANKER_THEME` picks a palette by name ("mocha"/"catppuccin", "mono",
/// "default"). An env var rather than a flag because the REPL is also reached
/// through `clanker` with no arguments, and a theme is a property of the
/// terminal you are sitting at rather than of one invocation.
fn themeName(environ_map: *const std.process.Environ.Map) ?[]const u8 {
    const v = environ_map.get("CLANKER_THEME") orelse return null;
    return if (v.len > 0) v else null;
}

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
    spinner_frame: u8 = 0,
    status_buf: [160]u8 = undefined,
    /// Between a bracketed-paste start/end pair. `vxfw.TextField` is a
    /// single-line widget (Enter either submits or is a no-op — there is no
    /// way to insert a literal newline into one), so a multi-line paste's
    /// embedded Enters would otherwise submit the task early, mid-paste.
    /// While true, Enter is folded to a space and inserted instead.
    in_paste: bool = false,
    /// vxfw.App.run() unconditionally enables mouse reporting (setMouseMode),
    /// which takes click-drag away from the terminal's own text selection in
    /// most emulators (Konsole included) — so this app owes its own
    /// selection + clipboard copy in exchange for grabbing the mouse.
    /// Row-major, drag-to-select over the transcript region only (not the
    /// status line or input box); copies via OSC 52 on release.
    mouse_down: bool = false,
    has_selection: bool = false,
    sel_start: vxfw.Point = .{ .row = 0, .col = 0 },
    sel_end: vxfw.Point = .{ .row = 0, .col = 0 },
    /// The last frame's rendered cells, kept only to read back the plain
    /// text under a selection (surface.readCell) — its backing arena is the
    /// draw arena, valid until the next redraw actually runs, which is
    /// after event handling in vxfw.App's own loop.
    last_surface: ?vxfw.Surface = null,
    transcript_top: u16 = 0,
    transcript_bottom: u16 = 0,

    /// Submitted-task history for the Up/Down recall every REPL has.
    /// `hist_idx == history.len` means "editing a fresh line", and the
    /// in-progress draft is parked in `hist_draft` while browsing so Esc
    /// (which clears the field) can't destroy unsent text.
    history: std.ArrayList([]const u8) = .empty,
    hist_idx: usize = 0,
    hist_draft: []const u8 = "",

    /// Non-null while an OSC 52 clipboard read is awaited (some terminals
    /// answer on a delay, some never answer). A second paste shortcut while
    /// pending re-sends the request, which is harmless.
    awaiting_clipboard: bool = false,

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
        // Fold the answer's markdown into one transcript line per source
        // line: the fence is where highlighting attaches, so lines must
        // know which fence (if any) they came from.
        var in_fence = false;
        var fence_lang: []const u8 = "";
        var first = true;
        var it = std.mem.splitScalar(u8, owned, '\n');
        while (it.next()) |src_line| {
            const trimmed = std.mem.trim(u8, src_line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "```")) {
                if (in_fence) {
                    in_fence = false;
                } else {
                    in_fence = true;
                    fence_lang = std.mem.trim(u8, trimmed[3..], " ");
                }
                continue; // fence markers themselves are not shown
            }
            const lang: ?[]const u8 = if (in_fence) fence_lang else null;
            const prefixed = if (first)
                std.fmt.allocPrint(self.arena, "\xe2\x80\xba {s}", .{src_line}) catch src_line
            else
                src_line;
            first = false;
            self.lines.append(self.arena, .{ .text = prefixed, .fence_lang = lang }) catch {};
        }
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

        // A quit command has to set `ctx.quit`, rather than merely stop the
        // input handler: App.run returns on that flag and its caller's defer
        // then restores the alternate screen, raw input, mouse mode, and
        // bracketed paste before the shell regains the terminal.
        if (isQuitCommand(task)) {
            ctx.quit = true;
            return;
        }

        self.lines.append(self.arena, .{ .text = try std.fmt.allocPrint(self.arena, "clanker> {s}", .{task}) }) catch {};
        self.history.append(self.arena, try self.arena.dupe(u8, task)) catch {};
        self.hist_idx = self.history.items.len;
        self.hist_draft = "";

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
                if (still_streaming) {
                    self.spinner_frame +%= 1;
                    try ctx.tick(50, self.widget());
                }
                ctx.redraw = true;
            },
            .key_press => |key| {
                // Terminal convention: Ctrl+Shift+C copies the current
                // selection (mouse-drag, same path as a drag release),
                // falling back to the whole input line. Plain Ctrl+C keeps
                // its readline meaning (interrupt the turn, quit when idle).
                if (key.matches('c', .{ .ctrl = true, .shift = true })) {
                    try self.copySelectionOrInput(ctx);
                    return ctx.consumeAndRedraw();
                }
                // Paste from the system clipboard. Two routes, tried in
                // order: Ctrl+Shift+V asks the terminal for its OSC 52
                // clipboard (arrives as a .paste event, which is handled
                // below), and Shift+Insert additionally forces a bracketed
                // paste so terminals that answer neither still do something
                // paste-like. Ctrl+V is deliberately not bound: it is the
                // readline "quote next character" prefix and the TextField
                // treats it that way.
                if (key.matches('v', .{ .ctrl = true, .shift = true })) {
                    try ctx.requestSystemClipboard();
                    self.awaiting_clipboard = true;
                    return ctx.consumeEvent();
                }
                if (key.matches(vaxis.Key.insert, .{ .shift = true })) {
                    self.in_paste = true;
                    try ctx.requestSystemClipboard();
                    self.awaiting_clipboard = true;
                    return ctx.consumeEvent();
                }
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
                // Readline-style line kill, including what Ctrl+U removes:
                // yanked by Ctrl+Y, the one emacs chord TextField doesn't
                // already implement.
                if (key.matches('y', .{ .ctrl = true })) {
                    self.yankInputToClipboard(ctx) catch {};
                    return ctx.consumeAndRedraw();
                }
                // REPL history recall.
                if (key.matches(vaxis.Key.up, .{})) {
                    self.historyPrev();
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.down, .{})) {
                    self.historyNext();
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.in_paste) {
                        try self.text_field.insertSliceAtCursor(" ");
                        ctx.redraw = true;
                        return;
                    }
                    try self.submit(ctx);
                    return;
                }
                try self.text_field.handleEvent(ctx, event);
            },
            .paste_start => self.in_paste = true,
            .paste_end => self.in_paste = false,
            // Answer to our OSC 52 clipboard request (Ctrl+Shift+V). The
            // payload is terminal-supplied text, so newlines are folded to
            // spaces — the TextField is single-line and a raw newline would
            // otherwise submit mid-paste.
            .paste => |text| {
                defer ctx.alloc.free(text);
                self.in_paste = false;
                self.awaiting_clipboard = false;
                const flat = singleLinePaste(ctx.alloc, text);
                defer if (flat.ptr != text.ptr) ctx.alloc.free(flat);
                try self.text_field.insertSliceAtCursor(flat);
                ctx.redraw = true;
            },
            .mouse => |m| try self.handleMouse(ctx, m),
            else => try self.text_field.handleEvent(ctx, event),
        }
    }

    /// Row-major drag-to-select over the transcript region. `row`/`col` are
    /// already in this widget's local coordinates (vxfw translates before
    /// dispatch), clamped to the transcript so dragging into the status
    /// line or input box can't select outside what's actually copyable.
    fn handleMouse(self: *Model, ctx: *vxfw.EventContext, m: vaxis.Mouse) !void {
        if (m.button != .left and m.type != .release) return;
        const row = std.math.clamp(
            @as(u16, @intCast(@max(0, m.row))),
            self.transcript_top,
            if (self.transcript_bottom > 0) self.transcript_bottom - 1 else 0,
        );
        const col: u16 = @intCast(@max(0, m.col));
        switch (m.type) {
            .press => {
                self.mouse_down = true;
                self.has_selection = false;
                self.sel_start = .{ .row = row, .col = col };
                self.sel_end = self.sel_start;
                ctx.redraw = true;
            },
            .drag => {
                if (!self.mouse_down) return;
                self.sel_end = .{ .row = row, .col = col };
                self.has_selection = !std.meta.eql(self.sel_start, self.sel_end);
                ctx.redraw = true;
            },
            .release => {
                if (!self.mouse_down) return;
                self.mouse_down = false;
                if (!self.has_selection) return;
                const surface = self.last_surface orelse return;
                const text = extractSelectionText(ctx.alloc, surface, self.sel_start, self.sel_end) catch return;
                defer ctx.alloc.free(text);
                try ctx.copyToClipboard(text);
                ctx.redraw = true;
            },
            .motion => {},
        }
    }

    /// Ctrl+Shift+C: copy the active mouse-drag selection if there is one
    /// (identical to what a drag release copies), else the current input
    /// line, so the keychord is never a no-op. Clears the selection
    /// afterwards, mirroring how terminal emulators drop the highlight on
    /// copy.
    fn copySelectionOrInput(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.has_selection) {
            if (self.last_surface) |surface| {
                const text = extractSelectionText(ctx.alloc, surface, self.sel_start, self.sel_end) catch "";
                defer if (text.len > 0) ctx.alloc.free(text);
                if (text.len > 0) try ctx.copyToClipboard(text);
            }
            self.has_selection = false;
            ctx.redraw = true;
            return;
        }
        const input = self.text_field.buf.dupe() catch return;
        defer self.text_field.buf.allocator.free(input);
        if (input.len > 0) try ctx.copyToClipboard(input);
    }

    /// Ctrl+Y: send the whole input line to the system clipboard, so the
    /// kill ring TextField already maintains (Ctrl+U/Ctrl+K/Ctrl+W deletions)
    /// and any typed-but-unsent text is one OSC 52 away from the outside
    /// world.
    fn yankInputToClipboard(self: *Model, ctx: *vxfw.EventContext) !void {
        const input = self.text_field.buf.dupe() catch return;
        defer self.text_field.buf.allocator.free(input);
        if (input.len > 0) try ctx.copyToClipboard(input);
    }

    /// Up: walk one entry older in the history. First step parks the live
    /// input as the draft to come back to.
    fn historyPrev(self: *Model) void {
        const n = self.history.items.len;
        if (n == 0 or self.hist_idx == 0) return;
        if (self.hist_idx == n) {
            const draft = self.text_field.buf.dupe() catch return;
            self.arena.free(self.hist_draft);
            self.hist_draft = self.arena.dupe(u8, draft) catch return;
            self.text_field.buf.allocator.free(draft);
        }
        self.hist_idx -= 1;
        self.loadInputFrom(self.history.items[self.hist_idx]);
    }

    /// Down: walk one entry newer; past the newest entry restores the draft
    /// that was parked when browsing began.
    fn historyNext(self: *Model) void {
        const n = self.history.items.len;
        if (self.hist_idx >= n) return;
        self.hist_idx += 1;
        if (self.hist_idx == n) {
            self.loadInputFrom(self.hist_draft);
        } else {
            self.loadInputFrom(self.history.items[self.hist_idx]);
        }
    }

    fn loadInputFrom(self: *Model, text: []const u8) void {
        self.text_field.clearRetainingCapacity();
        self.text_field.insertSliceAtCursor(text) catch {};
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();

        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), max);
        const dim: vaxis.Style = .{ .dim = true };
        @memset(surface.buffer, .{ .style = .{}, .default = true });

        g_mutex.lockUncancelable(g_io);
        const streaming = g_streaming;
        const stream_snapshot = ctx.arena.dupe(u8, g_stream_buf.items) catch "";
        g_mutex.unlock(g_io);

        const spinner_glyphs = [_][]const u8{ "\xe2\xa0\x8b", "\xe2\xa0\x99", "\xe2\xa0\xb9", "\xe2\xa0\xb8", "\xe2\xa0\xbc", "\xe2\xa0\xb4", "\xe2\xa0\xa6", "\xe2\xa0\xa7", "\xe2\xa0\x87", "\xe2\xa0\x8f" };
        const activity = if (streaming) spinner_glyphs[self.spinner_frame % spinner_glyphs.len] else "";
        const status = std.fmt.bufPrint(&self.status_buf, "clanker (vaxis) \xc2\xb7 {s}/{s} \xc2\xb7 {s}{s} \xc2\xb7 /quit /exit /q exit quit \xc2\xb7 Ctrl-C to exit", .{
            self.provider.name,
            self.provider.activeModelName(),
            activity,
            if (streaming) " thinking" else "ready",
        }) catch "clanker (vaxis)";
        writeRow(surface, 0, status, dim);

        const box_h: u16 = 3;
        const box_y = max.height -| box_h;
        drawBox(surface, 0, box_y, max.width, box_h);
        const input_surf = try self.text_field.draw(ctx.withConstraints(.{}, .{ .width = max.width -| 4, .height = 1 }));
        var children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = box_y + 1, .col = 2 }, .surface = input_surf };

        const top: u16 = 1;
        const bottom = box_y -| 1;
        self.transcript_top = top;
        self.transcript_bottom = bottom;
        const avail_rows: u16 = if (bottom > top) bottom - top else 0;
        var row: u16 = top;
        const start = tailStart(self.lines.items, avail_rows);
        // Lines carry fence_lang when they came out of a code fence; the
        // highlighter state is rebuilt per draw from the tagged lines.
        // One theme decides both. The style was built from Theme.default
        // regardless of what select() returned, so NO_COLOR (and any chosen
        // theme) reached the fence check and then got ignored by the
        // highlighter that actually draws the colours.
        const active = theme_mod.select(themeName(self.ctx.environ_map), self.ctx.environ_map);
        const fence_on = active.reset.len > 0;
        var syn_style = syntax.Style.fromTheme(&active);
        var i: usize = start;
        while (i < self.lines.items.len and row < bottom) : (i += 1) {
            const l = self.lines.items[i];
            if (l.fence_lang) |lang| {
                var state = syntax.State.init(lang);
                var segs: std.ArrayList(vaxis.Segment) = .empty;
                syntax.spansVaxis(&state, &syn_style, ctx.arena, l.text, &segs) catch {
                    writeWrapped(surface, &row, bottom, max.width, l.text, dim);
                    continue;
                };
                writeWrappedSegments(ctx, surface, &row, bottom, max.width, segs.items);
            } else {
                // Completed lines wrap like the live stream does; writeRow
                // would clip a long turn's reply to a single terminal row.
                writeWrapped(surface, &row, bottom, max.width, l.text, if (l.dim) dim else .{});
            }
        }
        if (streaming and row < bottom and stream_snapshot.len > 0) {
            self.writeStream(ctx, surface, &row, bottom, stream_snapshot, fence_on, &syn_style);
        }

        if (self.has_selection) highlightSelection(surface, self.sel_start, self.sel_end);
        self.last_surface = surface;

        surface.children = children;
        return surface;
    }

    /// Renders the live streaming buffer as plain wrapped text. The buffer
    /// is raw model output without fence tags (unlike `lines`), so there's
    /// no per-line language to highlight against — `writeWrapped` is the
    /// right call. The `fence_on`/`syn_style` params are carried for a
    /// future highlight pass but not used yet.
    fn writeStream(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface, row: *u16, bottom: u16, text: []const u8, fence_on: bool, syn_style: *const syntax.Style) void {
        _ = self;
        _ = ctx;
        _ = fence_on;
        _ = syn_style;
        writeWrapped(surface, row, bottom, surface.size.width, text, .{});
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

/// Writes styled segments with grapheme-accurate widths, wrapping at the
/// surface edge and stopping at `bottom`. Segment text borrows the caller's
/// buffer.
fn writeWrappedSegments(ctx: vxfw.DrawContext, surface: vxfw.Surface, row: *u16, bottom: u16, width: u16, segs: []const vaxis.Segment) void {
    var col: u16 = 0;
    for (segs) |seg| {
        var it = ctx.graphemeIterator(seg.text);
        while (it.next()) |g| {
            if (row.* >= bottom) return;
            const bytes = g.bytes(seg.text);
            if (std.mem.eql(u8, bytes, "\n")) {
                row.* += 1;
                col = 0;
                continue;
            }
            if (std.mem.eql(u8, bytes, "\t")) {
                const tab_width = 8 - col % 8;
                if (col + tab_width > width) {
                    row.* += 1;
                    col = 0;
                    if (row.* >= bottom) return;
                }
                col += tab_width;
                continue;
            }
            const w: u16 = @intCast(@min(ctx.stringWidth(bytes), 2));
            if (col + w > width) {
                row.* += 1;
                col = 0;
                if (row.* >= bottom) return;
            }
            if (w > 0) surface.writeCell(col, row.*, .{ .char = .{ .grapheme = bytes, .width = @intCast(w) }, .style = seg.style });
            col += w;
        }
    }
}

/// Writes `text` wrapped at `width`, advancing `*row` a line at a time,
/// stopping at `bottom`. Simple hard-wrap (no word-break) — good enough for
/// a live streaming tail and for completed turns (which must not be clipped
/// to a single row); MdStream-quality wrapping is follow-up work.
fn writeWrapped(surface: vxfw.Surface, row: *u16, bottom: u16, width: u16, text: []const u8, style: vaxis.Style) void {
    var col: u16 = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepointSlice()) |cp| {
        if (row.* >= bottom) break;
        if (std.mem.eql(u8, cp, "\n")) {
            row.* += 1;
            col = 0;
            continue;
        }
        if (col >= width) {
            row.* += 1;
            col = 0;
            if (row.* >= bottom) break;
        }
        surface.writeCell(col, row.*, .{ .char = .{ .grapheme = cp, .width = 1 }, .style = style });
        col += 1;
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

/// Row-major order: dragging can go in any direction, so this puts
/// whichever of `a`/`b` comes first on screen first.
fn normalizeSelection(a: vxfw.Point, b: vxfw.Point) struct { first: vxfw.Point, last: vxfw.Point } {
    if (a.row < b.row or (a.row == b.row and a.col <= b.col)) return .{ .first = a, .last = b };
    return .{ .first = b, .last = a };
}

/// Reverse-video over the selected cells, drawn last so it wins over
/// whatever style the content underneath already had.
fn highlightSelection(surface: vxfw.Surface, a: vxfw.Point, b: vxfw.Point) void {
    const n = normalizeSelection(a, b);
    var row = n.first.row;
    while (row <= n.last.row and row < surface.size.height) : (row += 1) {
        const col_start: u16 = if (row == n.first.row) n.first.col else 0;
        const col_end: u16 = if (row == n.last.row) n.last.col else surface.size.width -| 1;
        var col = col_start;
        while (col <= col_end and col < surface.size.width) : (col += 1) {
            var cell = surface.readCell(col, row);
            cell.style.reverse = true;
            surface.writeCell(col, row, cell);
        }
    }
}

/// Reads the plain text back out of the selected cells (works uniformly
/// across plain, wrapped, and syntax-highlighted rows since it reads the
/// final rendered buffer, not any one code path's own text). Trailing
/// padding spaces on each row are trimmed; rows join with '\n'.
fn extractSelectionText(alloc: std.mem.Allocator, surface: vxfw.Surface, a: vxfw.Point, b: vxfw.Point) ![]const u8 {
    const n = normalizeSelection(a, b);
    var out: std.ArrayList(u8) = .empty;
    var row = n.first.row;
    while (row <= n.last.row and row < surface.size.height) : (row += 1) {
        const col_start: u16 = if (row == n.first.row) n.first.col else 0;
        const col_end: u16 = if (row == n.last.row) n.last.col else surface.size.width -| 1;
        var col = col_start;
        while (col <= col_end and col < surface.size.width) : (col += 1) {
            const cell = surface.readCell(col, row);
            try out.appendSlice(alloc, cell.char.grapheme);
        }
        while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
        if (row < n.last.row) try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

/// The commands that leave the REPL rather than being submitted to the
/// agent. `clanker repl` is a shell: /quit, /exit, /q and a bare exit/quit
/// all end the session; anything else is a task. The legacy REPL handled the
/// same set in-process; this matches it.
fn isQuitCommand(task: []const u8) bool {
    const t = std.mem.trim(u8, task, " \t");
    return std.mem.eql(u8, t, "/quit") or
        std.mem.eql(u8, t, "/exit") or
        std.mem.eql(u8, t, "/q") or
        std.mem.eql(u8, t, "exit") or
        std.mem.eql(u8, t, "quit");
}

test "isQuitCommand recognizes the REPL quit set" {
    try std.testing.expect(isQuitCommand("/quit"));
    try std.testing.expect(isQuitCommand("/exit"));
    try std.testing.expect(isQuitCommand("/q"));
    try std.testing.expect(isQuitCommand("exit"));
    try std.testing.expect(isQuitCommand("quit"));
    try std.testing.expect(isQuitCommand("  /q  "));
    // A leading slash distinguishes a command from the same word as a task;
    // a bare word that is not a quit command is a task.
    try std.testing.expect(!isQuitCommand("/quitnow"));
    try std.testing.expect(!isQuitCommand("exit handling is next"));
    try std.testing.expect(!isQuitCommand(""));
    try std.testing.expect(!isQuitCommand("please exit"));
}

/// Folds CR/LF runs in clipboard text to single spaces so a multi-line
/// paste lands on one line of the single-line TextField instead of
/// submitting early (Enter submits). Returns the input unchanged when
/// there's nothing to fold — caller frees only when the pointer differs.
fn singleLinePaste(alloc: std.mem.Allocator, text: []const u8) []const u8 {
    var out: ?[]u8 = null;
    defer if (out) |o| alloc.free(o);
    for (text, 0..) |c, i| {
        if (c != '\r' and c != '\n') continue;
        if (out == null) {
            const buf = alloc.dupe(u8, text) catch return text;
            out = buf;
        }
        out.?[i] = ' ';
    }
    return if (out) |o| o else text;
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
    defer model.text_field.deinit();

    try app.run(model.widget(), .{});
}
