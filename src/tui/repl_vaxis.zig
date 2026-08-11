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
//! Deliberately not yet built (documented gaps, not oversights): a general
//! slash-command palette/tab-complete (only quit, `/model`, and `/help` are
//! handled by name in `submit` — `/model` opens a fuzzy provider/model
//! picker, `handlePickerKey`, styled like Kimi Code's; `/help`/`?` prints
//! `printHelp`'s hand-maintained command list, not a generated one), inline
//! ask_user/approval prompts (falls back to the same "nobody attached"
//! default a headless run gets), manual scroll-back (the transcript always
//! shows its tail), and the left-bar tool-card styling from the old
//! transcript.zig (tool calls render as plain dim lines here). Full list,
//! with what a fix looks like for each: docs/ROADMAP.md's "vaxis REPL
//! parity" entry under Planned.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const config = @import("../config.zig");
const client = @import("../llm/client.zig");
const types = @import("../llm/types.zig");
const providers = @import("../llm/providers.zig");
const registry = @import("../tools/registry.zig");
const session_mod = @import("../agent/session.zig");
const agent_loop = @import("../agent/loop.zig");
const Agent = agent_loop.Agent;
const log = @import("../util/log.zig");
const syntax = @import("syntax.zig");
const theme_mod = @import("theme.zig");

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

var bridge_mutex: std.Io.Mutex = .init;
var bridge_io: std.Io = undefined;
var bridge_gpa: std.mem.Allocator = undefined;
var bridge_streaming: bool = false;
var bridge_stream_buf: std.ArrayList(u8) = .empty;
var bridge_tool_lines: std.ArrayList([]const u8) = .empty;
var bridge_stop_flag: std.atomic.Value(bool) = .init(false);
/// Published only after runThreadMain has finished all deferred Agent cleanup.
/// The UI thread consumes this and joins the worker before making the model
/// idle, so the model arena cannot be destroyed while cleanup still uses it.
var bridge_turn_done: std.atomic.Value(bool) = .init(false);

fn onToken(delta: []const u8) void {
    bridge_mutex.lockUncancelable(bridge_io);
    defer bridge_mutex.unlock(bridge_io);
    const clean = stripControls(bridge_gpa, delta);
    defer if (clean.ptr != delta.ptr) bridge_gpa.free(clean);
    bridge_stream_buf.appendSlice(bridge_gpa, clean) catch {};
}

fn onToolCall(calls: []const types.ToolCall) void {
    bridge_mutex.lockUncancelable(bridge_io);
    defer bridge_mutex.unlock(bridge_io);
    for (calls) |c| {
        const line = std.fmt.allocPrint(bridge_gpa, "\xe2\x9a\x99 {s}", .{c.name}) catch continue;
        bridge_tool_lines.append(bridge_gpa, line) catch {};
    }
}

fn onToolResult(elapsed_ms: u64) void {
    bridge_mutex.lockUncancelable(bridge_io);
    defer bridge_mutex.unlock(bridge_io);
    const line = std.fmt.allocPrint(bridge_gpa, "  \xe2\x86\xb3 done in {d}ms", .{elapsed_ms}) catch return;
    bridge_tool_lines.append(bridge_gpa, line) catch {};
}

const RunThreadArgs = struct {
    model: *Model,
    task: []const u8,
};

fn runThreadMain(args: RunThreadArgs) void {
    defer bridge_turn_done.store(true, .release);
    const self = args.model;
    const messages = &self.messages;
    var err_detail: ?[]const u8 = null;

    var a = Agent.init(&self.ctx, self.arena, &self.provider, &self.cfg, &self.reg, self.tool_defs) catch |err| {
        self.finishTurn(std.fmt.allocPrint(self.arena, "[error: {s}]", .{@errorName(err)}) catch "[error]");
        return;
    };
    defer a.deinit();
    a.on_token = onToken;
    a.on_tool_call = onToolCall;
    a.on_tool_result = onToolResult;
    a.stop_flag = &bridge_stop_flag;

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

/// One entry in the `/model` picker: a provider/model pair flattened out of
/// `Config.providers` so the picker can filter and sort without walking the
/// nested map on every keystroke.
const ModelCandidate = struct {
    provider: []const u8,
    model: []const u8,
    display: []const u8,
    context_window: u32,
    cost_in: ?f64,
    cost_out: ?f64,
};

/// Flattens every configured provider's models into one list, in config
/// order (providers, then models within a provider), which is what makes the
/// picker's unfiltered list read as grouped-by-provider without a separate
/// sort pass.
fn buildModelCandidates(arena: std.mem.Allocator, cfg: *const config.Config) ![]const ModelCandidate {
    var out: std.ArrayList(ModelCandidate) = .empty;
    var pit = cfg.providers.iterator();
    while (pit.next()) |pentry| {
        var mit = pentry.value_ptr.models.iterator();
        while (mit.next()) |mentry| {
            try out.append(arena, .{
                .provider = pentry.key_ptr.*,
                .model = mentry.key_ptr.*,
                .display = mentry.value_ptr.display orelse mentry.key_ptr.*,
                .context_window = mentry.value_ptr.context_window,
                .cost_in = mentry.value_ptr.cost_per_1m_input,
                .cost_out = mentry.value_ptr.cost_per_1m_output,
            });
        }
    }
    return out.toOwnedSlice(arena);
}

/// Case-insensitive subsequence match ("kc3" finds "kimi-k3"): the same
/// forgiving-order fuzzy match the web UI's command palette and saved-prompt
/// list already use (`fuzzyMatch` in `tools/zig/webui/app.js`), so `/model`
/// behaves like the picker it is modeled on rather than inventing a second
/// notion of "fuzzy" for the terminal.
fn fuzzyMatch(query: []const u8, haystack: []const u8) bool {
    if (query.len == 0) return true;
    var qi: usize = 0;
    for (haystack) |c| {
        if (qi >= query.len) break;
        if (std.ascii.toLower(c) == std.ascii.toLower(query[qi])) qi += 1;
    }
    return qi == query.len;
}

test "fuzzyMatch is a case-insensitive subsequence match" {
    try std.testing.expect(fuzzyMatch("", "kimi-k3"));
    try std.testing.expect(fuzzyMatch("kk3", "kimi-k3"));
    try std.testing.expect(fuzzyMatch("K3", "kimi-k3"));
    try std.testing.expect(fuzzyMatch("moon k3", "moonshot k3-code"));
    try std.testing.expect(!fuzzyMatch("xyz", "kimi-k3"));
    try std.testing.expect(!fuzzyMatch("3k", "kimi-k3")); // order matters
}

test "buildModelCandidates flattens providers in config order, one entry per model" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cfg = config.Config{};
    try cfg.providers.put(arena, "kimi-k3", try config.Provider.single(arena, "kimi-k3", "https://api.moonshot.ai/v1", .openai_compat, "kimi-k3", .{
        .context_window = 1048576,
        .cost_per_1m_input = 3,
        .cost_per_1m_output = 15,
        .display = "moonshotai/kimi-k3",
    }));
    try cfg.providers.put(arena, "deepseek", try config.Provider.single(arena, "deepseek", "https://api.deepseek.com", .openai_compat, "deepseek-chat", .{
        .context_window = 65536,
    }));

    const cands = try buildModelCandidates(arena, &cfg);
    try std.testing.expectEqual(@as(usize, 2), cands.len);
    try std.testing.expectEqualStrings("kimi-k3", cands[0].provider);
    try std.testing.expectEqualStrings("moonshotai/kimi-k3", cands[0].display); // display overrides the bare model id
    try std.testing.expectEqual(@as(?f64, 3), cands[0].cost_in);
    try std.testing.expectEqualStrings("deepseek", cands[1].provider);
    try std.testing.expectEqualStrings("deepseek-chat", cands[1].display); // no display set: falls back to the model id
    try std.testing.expectEqual(@as(?f64, null), cands[1].cost_in);
}

/// `CLANKER_THEME` picks a palette by name ("mocha"/"catppuccin", "latte",
/// "frappe", "macchiato", "tokyonight", "storm", "day", "mono", "default").
/// An env var rather than a flag because the REPL is also reached
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
    /// Where this conversation persists (`state/sessions/<id>.json`), written
    /// after every completed turn; null only when the sessions module is off
    /// and no `--session` was given.
    session_id: ?[]const u8 = null,
    /// Unix seconds when this conversation was first created — preserved
    /// across resume so a continued session keeps its original birth date.
    session_created: i64 = 0,
    /// First task of the conversation, trimmed — the line `clanker sessions`
    /// shows. Kept from a loaded session; set once on the first submit.
    session_title: []const u8 = "",

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

    /// Every configured provider/model, flattened once at startup (config
    /// does not change mid-session). `/model` opens `picker_open`, and while
    /// it's true every key press is routed to `handlePickerKey` instead of
    /// the normal input handling below — a small modal, not a second widget.
    model_candidates: []const ModelCandidate = &.{},
    picker_open: bool = false,
    picker_query: std.ArrayList(u8) = .empty,
    picker_selected: usize = 0,

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
        bridge_mutex.lockUncancelable(bridge_io);
        defer bridge_mutex.unlock(bridge_io);
        for (bridge_tool_lines.items) |l| self.lines.append(self.arena, .{ .text = l, .dim = true }) catch {};
        bridge_tool_lines.clearRetainingCapacity();
        const answer = if (final_text.len > 0) final_text else bridge_stream_buf.items;
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
        bridge_stream_buf.clearRetainingCapacity();
    }

    /// Writes the conversation to `state/sessions/<id>.json`, called after
    /// every completed turn (never mid-turn: the caller joins the worker
    /// first, so `self.messages` is stable). A failed write is reported at
    /// error level — the only log level this REPL leaves enabled — and the
    /// next turn's save retries; it must not kill the session over a disk
    /// hiccup.
    fn persistSession(self: *Model) void {
        const sid = self.session_id orelse return;
        if (!self.cfg.modules.sessions) return;
        session_mod.compactMessages(&self.messages, session_mod.max_session_tokens);
        const updated: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .real).nanoseconds, 1_000_000_000));
        session_mod.saveSession(self.io, self.gpa, self.arena, std.Io.Dir.cwd(), .{
            .id = sid,
            .title = self.session_title,
            .messages = self.messages.items,
            .created = self.session_created,
            .updated = updated,
        }) catch |err| {
            log.log(.error_, "session '{s}' save failed: {s}", .{ sid, @errorName(err) });
        };
    }

    fn submit(self: *Model, ctx: *vxfw.EventContext) !void {
        // One turn at a time: runThreadMain's finishTurn touches self.lines
        // and self.arena from the background thread. self.arena is a plain
        // ArenaAllocator (no internal locking) and self.lines is a plain
        // ArrayList, so a second in-flight turn spawned here would race the
        // first turn's background thread on both — not just contend for
        // bridge_mutex-guarded state, but corrupt the arena's free-list and the
        // transcript's backing storage. Leaving typed input untouched (no
        // toOwnedSlice yet) is a no-op keystroke while the picker is modal
        // for the same reason: nothing to submit into.
        bridge_mutex.lockUncancelable(bridge_io);
        const already_streaming = bridge_streaming;
        bridge_mutex.unlock(bridge_io);
        if (already_streaming) return;

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

        // "/model" alone opens the picker on the full list; "/model kimi"
        // seeds it with a starting query, so a remembered partial name is
        // one Enter away instead of a blank list to type into again.
        if (std.mem.eql(u8, task, "/model") or std.mem.startsWith(u8, task, "/model ")) {
            self.openModelPicker(if (task.len > 6) std.mem.trim(u8, task[6..], " ") else "");
            return;
        }

        if (std.mem.eql(u8, task, "/help") or std.mem.eql(u8, task, "?")) {
            self.printHelp();
            return;
        }

        if (std.mem.eql(u8, task, "/autoresearch") or std.mem.startsWith(u8, task, "/autoresearch ")) {
            const args = if (task.len > 14) std.mem.trim(u8, task[14..], " ") else "";
            if (args.len == 0 or std.mem.eql(u8, args, "--help") or std.mem.eql(u8, args, "-h")) {
                self.lines.append(self.arena, .{ .text = "usage: /autoresearch --target <file> --harness \"<cmd>\" [--iters N] [--dry-run]", .dim = true }) catch {};
                self.lines.append(self.arena, .{ .text = "  runs the measurement loop; use --dry-run to validate without LLM", .dim = true }) catch {};
                self.lines.append(self.arena, .{ .text = "  example: /autoresearch --target tools/zig/calculator.zig --harness \"sh -c 'echo score: 1.0'\" --dry-run", .dim = true }) catch {};
                return;
            }
            // Run as a normal agent task so /autoresearch benefits from the same streaming/history as any other task.
            // The prompt tells the agent which CLI to invoke; the old stub just echoed a hint.
        }

        self.lines.append(self.arena, .{ .text = try std.fmt.allocPrint(self.arena, "clanker> {s}", .{task}) }) catch {};
        self.history.append(self.arena, try self.arena.dupe(u8, task)) catch {};
        self.hist_idx = self.history.items.len;
        self.hist_draft = "";

        // self.thread is assigned here and read by finishTurn on the
        // background thread (to detach itself); spawning and storing the
        // handle under the same lock finishTurn locks before reading it
        // gives that read a happens-after relationship to this write. Doing
        // the assignment outside the lock let a background thread that
        // fails fast in Agent.init race finishTurn's read of self.thread
        // against this store, seeing it still null and leaking the handle.
        bridge_mutex.lockUncancelable(bridge_io);
        defer bridge_mutex.unlock(bridge_io);
        bridge_streaming = true;
        bridge_stream_buf.clearRetainingCapacity();
        bridge_tool_lines.clearRetainingCapacity();
        bridge_stop_flag.store(false, .release);
        bridge_turn_done.store(false, .release);
        errdefer bridge_streaming = false;

        const owned_task = try self.arena.dupe(u8, task);
        if (self.session_title.len == 0) {
            self.session_title = std.mem.trim(u8, owned_task[0..@min(owned_task.len, 60)], " \t\r\n");
        }
        self.thread = try std.Thread.spawn(.{}, runThreadMain, .{RunThreadArgs{ .model = self, .task = owned_task }});

        // Kick off the tick heartbeat that picks up streamed deltas.
        try ctx.tick(50, self.widget());
    }

    /// Writes the conversation to `state/sessions/<id>.json` so a later
    /// `--session <id>` or `--continue` resumes it. Called once when the app
    /// is about to return (every quit path — /quit, Ctrl-C while idle — ends
    /// in `app.run` returning). A fresh conversation gets an id minted here;
    /// a resumed one keeps the id it was loaded under. Nothing is written
    /// when the sessions module is off, the id is invalid, or there is no
    /// conversation yet.
    fn saveConversation(self: *Model) void {
        if (!self.cfg.modules.sessions) return;
        var has_turn = false;
        for (self.messages.items) |m| {
            if (m.role != .system) {
                has_turn = true;
                break;
            }
        }
        // A freshly opened REPL quit before its first turn has nothing worth
        // persisting (at most the injected system prompt).
        if (!has_turn) return;

        const id = self.session_id orelse (mintSessionId(self.io, self.arena) catch {
            log.log(.warn, "repl: could not mint a session id; conversation not saved", .{});
            return;
        });
        if (!validSessionId(id)) {
            log.log(.warn, "repl: refusing to save under invalid session id '{s}'", .{id});
            return;
        }

        // The system prompt and the tool-call plumbing are internal; the
        // saved transcript is the user/assistant conversation, the same shape
        // `clanker run` writes and `loadSession` reads back (tool-call records
        // stay so a resumed session replays them into the model's history).
        var transcript: std.ArrayList(types.Message) = .empty;
        for (self.messages.items) |m| {
            if (m.role == .system) continue;
            transcript.append(self.arena, m) catch {};
        }
        const title = if (self.session_title.len > 0) self.session_title else blk: {
            var t: []const u8 = "";
            for (transcript.items) |m| {
                if (m.role == .user) {
                    if (m.content) |c| {
                        t = std.mem.trim(u8, c[0..@min(c.len, 60)], " \t\r\n");
                        break;
                    }
                }
            }
            break :blk t;
        };
        const updated: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .real).nanoseconds, 1_000_000_000));
        session.saveSession(self.io, self.gpa, self.arena, std.Io.Dir.cwd(), .{
            .id = id,
            .title = title,
            .messages = transcript.items,
            .created = if (self.session_created != 0) self.session_created else updated,
            .updated = updated,
        }) catch |err| {
            log.log(.warn, "repl: session '{s}' not saved: {s}", .{ id, @errorName(err) });
            return;
        };
        self.session_id = id;
    }

    /// The full command set is exactly what `submit` recognizes, so this is
    /// hand-maintained rather than generated — unlike the deleted REPL's
    /// `cmd_*` catalog (docs/tui-feature-checklist.md item 4), there is no
    /// registry here yet to generate it from. Keep in sync by hand until
    /// there is.
    fn printHelp(self: *Model) void {
        const text =
            \\commands:
            \\  /help, ?          show this help
            \\  /model [query]    switch provider/model (fuzzy picker; Enter picks, Esc cancels)
            \\  /autoresearch ... measurement loop (see /autoresearch --help)
            \\  /quit, /exit, /q  leave the REPL (bare "exit"/"quit" also work)
            \\keys:
            \\  Up/Down           recall previous input
            \\  Ctrl-C            stop the current turn, or quit when idle
            \\  Ctrl-Shift-C      copy the selection (or the input line)
            \\  Ctrl-Shift-V, Shift-Insert   paste from the system clipboard
        ;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| self.lines.append(self.arena, .{ .text = line, .dim = true }) catch {};
    }

    fn openModelPicker(self: *Model, seed_query: []const u8) void {
        self.picker_open = true;
        self.picker_query.clearRetainingCapacity();
        self.picker_query.appendSlice(self.arena, seed_query) catch {};
        self.picker_selected = 0;
    }

    fn closeModelPicker(self: *Model) void {
        self.picker_open = false;
        self.picker_query.clearRetainingCapacity();
    }

    /// Candidates whose "provider display" matches the current query, in
    /// `model_candidates` order (config order, so unfiltered is grouped by
    /// provider). Filters into `self.arena` on every keystroke rather than
    /// caching: the candidate list itself is small (one provider's worth of
    /// models, times however many providers are configured — tens, not
    /// thousands), so re-scanning it is cheaper than the bookkeeping to
    /// avoid doing so.
    fn filteredCandidates(self: *Model) []const ModelCandidate {
        var out: std.ArrayList(ModelCandidate) = .empty;
        for (self.model_candidates) |c| {
            var buf: [192]u8 = undefined;
            const haystack = std.fmt.bufPrint(&buf, "{s} {s}", .{ c.provider, c.display }) catch c.display;
            if (fuzzyMatch(self.picker_query.items, haystack)) out.append(self.arena, c) catch break;
        }
        return out.items;
    }

    /// Switches the active provider/model for the *next* turn onward — the
    /// conversation (`self.messages`) is untouched, so the switch lands
    /// mid-session exactly like `--model` does at startup, just later.
    fn applyModelSelection(self: *Model, cand: ModelCandidate) void {
        if (self.cfg.provider(cand.provider)) |p| {
            var np = p.*;
            np.default_model = cand.model;
            self.provider = np;
            self.lines.append(self.arena, .{
                .text = std.fmt.allocPrint(self.arena, "[model: {s}/{s}]", .{ cand.provider, cand.model }) catch "[model switched]",
                .dim = true,
            }) catch {};
        } else |_| {
            // Can't happen: cand.provider always came from cfg.providers in
            // buildModelCandidates, but a config reload mid-session (not
            // currently possible) would make this reachable, so fail quiet
            // rather than unreachable().
            self.lines.append(self.arena, .{ .text = "[model: provider no longer configured]", .dim = true }) catch {};
        }
    }

    fn handlePickerKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        if (key.matches(vaxis.Key.escape, .{})) {
            self.closeModelPicker();
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            const matches = self.filteredCandidates();
            if (matches.len > 0) self.applyModelSelection(matches[@min(self.picker_selected, matches.len - 1)]);
            self.closeModelPicker();
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.up, .{})) {
            if (self.picker_selected > 0) self.picker_selected -= 1;
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.down, .{})) {
            const n = self.filteredCandidates().len;
            if (n > 0 and self.picker_selected + 1 < n) self.picker_selected += 1;
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.picker_query.items.len > 0) {
                _ = self.picker_query.pop();
                self.picker_selected = 0;
            }
            return ctx.consumeAndRedraw();
        }
        if (key.text) |t| {
            try self.picker_query.appendSlice(self.arena, t);
            self.picker_selected = 0;
            return ctx.consumeAndRedraw();
        }
        return ctx.consumeAndRedraw();
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => try ctx.requestFocus(self.text_field.widget()),
            .tick => {
                // finishTurn only publishes transcript state. The worker may
                // still be running Agent.deinit after that, so reclaim it on
                // the UI thread before advertising an idle model.
                if (bridge_turn_done.swap(false, .acq_rel)) {
                    if (self.thread) |t| {
                        t.join();
                        self.thread = null;
                    }
                    bridge_mutex.lockUncancelable(bridge_io);
                    bridge_streaming = false;
                    bridge_mutex.unlock(bridge_io);
                    // The worker is joined, so self.messages is stable:
                    // persist the conversation as it stands after this turn.
                    self.persistSession();
                }
                bridge_mutex.lockUncancelable(bridge_io);
                const still_streaming = bridge_streaming;
                bridge_mutex.unlock(bridge_io);
                if (still_streaming) {
                    self.spinner_frame +%= 1;
                    try ctx.tick(50, self.widget());
                }
                ctx.redraw = true;
            },
            .key_press => |key| {
                // The picker is modal: every key goes to it, none of the
                // clipboard/history/quit shortcuts below apply while it's open.
                if (self.picker_open) return self.handlePickerKey(ctx, key);
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
                    requestSystemClipboard(ctx.io);
                    self.awaiting_clipboard = true;
                    return ctx.consumeEvent();
                }
                if (key.matches(vaxis.Key.insert, .{ .shift = true })) {
                    self.in_paste = true;
                    requestSystemClipboard(ctx.io);
                    self.awaiting_clipboard = true;
                    return ctx.consumeEvent();
                }
                if (key.matches('c', .{ .ctrl = true })) {
                    bridge_mutex.lockUncancelable(bridge_io);
                    const streaming = bridge_streaming;
                    bridge_mutex.unlock(bridge_io);
                    if (streaming) {
                        bridge_stop_flag.store(true, .release);
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

    /// Asks the terminal for its OSC 52 clipboard contents; the answer (if
    /// any) arrives later as a `.paste` event. vxfw's `EventContext` only
    /// exposes a `copy_to_clipboard` command, not a request one, so this
    /// writes the raw control sequence straight to the tty itself, the same
    /// bytes `Vaxis.requestSystemClipboard` sends internally.
    fn requestSystemClipboard(io: std.Io) void {
        std.Io.File.stdout().writeStreamingAll(io, vaxis.ctlseqs.osc52_clipboard_request) catch {};
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
        // Computed up front (draw order used to put this after the box/status
        // were already painted in the theme-less default style, so a chosen
        // CLANKER_THEME only ever showed up inside fenced code — everywhere
        // else in the vaxis REPL's chrome ignored it).
        const active = theme_mod.select(themeName(self.ctx.environ_map), self.ctx.environ_map);
        const dim: vaxis.Style = if (active.rgb) |c| .{ .dim = true, .fg = .{ .rgb = c.dim } } else .{ .dim = true };
        const rule_style: vaxis.Style = if (active.rgb) |c| .{ .fg = .{ .rgb = c.rule } } else .{};
        const tool_style: vaxis.Style = if (active.rgb) |c| .{ .dim = true, .fg = .{ .rgb = c.tool } } else dim;
        const err_style: vaxis.Style = if (active.rgb) |c| .{ .fg = .{ .rgb = c.err } } else .{};
        @memset(surface.buffer, .{ .style = .{}, .default = true });

        // Held through the self.lines read loop below, not just the
        // streaming snapshot: finishTurn appends to self.lines from the
        // background thread while a turn is in flight (this same draw runs
        // on every 50ms tick during that window), so reading self.lines.items
        // without the lock is a torn read against a concurrent append/resize.
        bridge_mutex.lockUncancelable(bridge_io);
        defer bridge_mutex.unlock(bridge_io);
        const streaming = bridge_streaming;
        const stream_snapshot = ctx.arena.dupe(u8, bridge_stream_buf.items) catch "";

        const spinner_glyphs = [_][]const u8{ "\xe2\xa0\x8b", "\xe2\xa0\x99", "\xe2\xa0\xb9", "\xe2\xa0\xb8", "\xe2\xa0\xbc", "\xe2\xa0\xb4", "\xe2\xa0\xa6", "\xe2\xa0\xa7", "\xe2\xa0\x87", "\xe2\xa0\x8f" };
        const activity = if (streaming) spinner_glyphs[self.spinner_frame % spinner_glyphs.len] else "";
        const status = std.fmt.bufPrint(&self.status_buf, "clanker (vaxis) \xc2\xb7 {s}/{s} \xc2\xb7 {s}{s}{s}{s} \xc2\xb7 /help for commands \xc2\xb7 Ctrl-C to exit", .{
            self.provider.name,
            self.provider.activeModelName(),
            activity,
            if (streaming) " thinking" else "ready",
            if (self.session_id != null) " \xc2\xb7 " else "",
            self.session_id orelse "",
        }) catch "clanker (vaxis)";
        writeRow(surface, 0, status, dim);

        const box_h: u16 = 3;
        const box_y = max.height -| box_h;
        drawBox(surface, 0, box_y, max.width, box_h, rule_style);
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
                // Tool-call/result lines (dim) and an error turn's "[error: "
                // prefix each get their own tint instead of sharing one grey.
                const style = if (std.mem.startsWith(u8, l.text, "[error:"))
                    err_style
                else if (l.dim)
                    (if (std.mem.startsWith(u8, l.text, "\xe2\x9a\x99") or std.mem.startsWith(u8, l.text, "  \xe2\x86\xb3")) tool_style else dim)
                else
                    vaxis.Style{};
                writeWrapped(surface, &row, bottom, max.width, l.text, style);
            }
        }
        if (streaming and row < bottom and stream_snapshot.len > 0) {
            self.writeStream(ctx, surface, &row, bottom, stream_snapshot, fence_on, &syn_style);
        }

        if (self.has_selection) highlightSelection(surface, self.sel_start, self.sel_end);
        if (self.picker_open) self.drawModelPicker(surface, rule_style, tool_style);
        self.last_surface = surface;

        surface.children = children;
        return surface;
    }

    /// Draws the `/model` picker as a modal box over the tail of the
    /// transcript, just above the input — same left-bar box style as the
    /// input itself (`drawBox`), so it reads as part of this REPL rather
    /// than a bolted-on popup.
    fn drawModelPicker(self: *Model, surface: vxfw.Surface, rule_style: vaxis.Style, sel_style: vaxis.Style) void {
        const matches = self.filteredCandidates();
        const max_rows: u16 = 8;
        const rows_shown: u16 = @intCast(@min(matches.len, max_rows));
        const h: u16 = rows_shown + 3; // top border + query line + rows + bottom border
        if (surface.size.width < 8) return;
        const y = self.transcript_bottom -| h;
        drawBox(surface, 0, y, surface.size.width, h, rule_style);

        var qbuf: [256]u8 = undefined;
        const qline = std.fmt.bufPrint(&qbuf, "/model {s}\xe2\x96\x8f", .{self.picker_query.items}) catch "/model";
        writeRow(surface, y + 1, qline, .{ .bold = true });

        if (matches.len == 0) {
            writeRow(surface, y + 2, "  no matching provider/model", .{ .dim = true });
            return;
        }
        const sel = @min(self.picker_selected, matches.len - 1);
        var row: u16 = y + 2;
        for (matches[0..rows_shown], 0..) |cand, i| {
            var lbuf: [256]u8 = undefined;
            const marker: []const u8 = if (i == sel) "\xe2\x80\xba " else "  ";
            const line = if (cand.cost_in != null or cand.cost_out != null)
                std.fmt.bufPrint(&lbuf, "{s}{s}/{s}  {d} ctx  ${d}/${d} per 1M", .{
                    marker,                cand.provider,          cand.display, cand.context_window,
                    cand.cost_in orelse 0, cand.cost_out orelse 0,
                }) catch continue
            else
                std.fmt.bufPrint(&lbuf, "{s}{s}/{s}  {d} ctx", .{ marker, cand.provider, cand.display, cand.context_window }) catch continue;
            writeRow(surface, row, line, if (i == sel) sel_style else .{});
            row += 1;
        }
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

fn drawBox(surface: vxfw.Surface, x: u16, y: u16, w: u16, h: u16, style: vaxis.Style) void {
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

/// The subset of `cli.Options` the REPL honors. `--provider`/`--model` pick
/// the starting provider/model, `--session <id>` resumes a saved conversation
/// and `--continue` resumes the most recently touched one. Passing this narrow
/// struct instead of all of `cli.Options` keeps the REPL from importing all of
/// cli.zig (which would pull the whole CLI into this module) while making
/// every declared flag real.
pub const ReplOptions = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    session: ?[]const u8 = null,
    continue_last: bool = false,
};

/// Session ids become path fragments under `state/sessions/`, so only the
/// same slug shape the rest of clanker accepts is allowed here (alphanumeric,
/// `-`, `_`, length 1..64). Anything with a separator or a dot is refused
/// before it could walk out of the store — this mirrors `cli.zig`'s
/// `validSessionId`, restated locally because the REPL deliberately does not
/// import cli.zig.
fn validSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

/// The id `--continue` means: the saved session touched most recently.
/// Returns null when there are none, so a first `--continue` starts a fresh
/// session rather than failing at someone who has not made one yet.
fn latestSessionId(io: std.Io, arena: std.mem.Allocator) ?[]const u8 {
    const metas = session.listSessions(io, arena, std.Io.Dir.cwd()) catch return null;
    var best: ?session.SessionMeta = null;
    for (metas) |m| {
        if (best == null or m.updated > best.?.updated) best = m;
    }
    return if (best) |b| b.id else null;
}

/// A fresh conversation's id, minted the first time it is saved. The
/// nanosecond suffix keeps rapid successive sessions distinct and stays
/// within the slug alphabet `validSessionId` accepts, like the server's
/// `sess-<base36>` fallback.
fn mintSessionId(io: std.Io, arena: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(arena, "sess-{d}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
}

test "validSessionId refuses path traversal and accepts the minted shape" {
    try std.testing.expect(validSessionId("sess-123"));
    try std.testing.expect(validSessionId("7f3a1c2e-0b44-4a91-9d3e-1c2b3a4d5e6f"));
    try std.testing.expect(validSessionId("sess-m1x2y3_ab12cd"));
    try std.testing.expect(!validSessionId("../../etc/passwd"));
    try std.testing.expect(!validSessionId("a/b"));
    try std.testing.expect(!validSessionId("a.json"));
    try std.testing.expect(!validSessionId(""));
    try std.testing.expect(!validSessionId("x" ** 65));
}

test "mintSessionId produces a distinct valid id each call" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const a = try mintSessionId(io, arena);
    const b = try mintSessionId(io, arena);
    try std.testing.expect(validSessionId(a));
    try std.testing.expect(validSessionId(b));
    try std.testing.expect(std.mem.startsWith(u8, a, "sess-"));
    // Nanosecond-resolution ids of two consecutive mints are not equal.
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

pub fn cmdReplVaxis(init: std.process.Init, opts: ReplOptions) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    bridge_gpa = gpa;
    bridge_io = io;
    // log.log writes straight to stderr with no coordination with vaxis's
    // owned alt-screen buffer, unlike the old REPL where stray stderr text
    // just scrolled by harmlessly. Any stray write here corrupts the
    // screen, so raise the threshold for this command's whole lifetime.
    log.setLevel(.error_);

    var cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json");
    // `always` has no prompt-rendering path in this REPL yet (see the module
    // doc comment and docs/ROADMAP.md): write-capable tools run ungated here
    // regardless of this setting. Said once, before the alt-screen takes
    // over stderr, so the operator is not left believing they are protected.
    if (cfg.agent.confirm_writes == .always) {
        std.debug.print("warning: agent.confirm_writes=\"always\" does not gate this REPL yet — write-capable tool calls run without confirmation here. Only `clanker serve` honors it today.\n", .{});
    }
    std.Io.Dir.cwd().createDirPath(io, cfg.agent.sandbox_root) catch {};
    var reg = try registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir);
    const tool_defs = try reg.toToolDefs(arena);
    // `--provider`/`--model` pick the starting provider/model; `--model
    // <provider>/<model>` picks both at once, resolved by the same
    // Config.resolveProvider rule `clanker run` uses.
    const provider = try cfg.resolveProvider(opts.provider, opts.model);
    const ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = init.environ_map, .cfg = &cfg };

    // Which conversation this is: `--session <id>` names one, `--continue`
    // picks up the most recently touched one, and otherwise (sessions module
    // on) a fresh `repl-<ts>` id is minted so the conversation is findable in
    // `clanker sessions` afterwards — the same contract the deleted REPL and
    // `clanker run` honor. With the module off, nothing is read or written.
    const now_s: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    var session_id: ?[]const u8 = opts.session;
    if (session_id == null and opts.continue_last) {
        session_id = session_mod.latestSessionId(io, arena, std.Io.Dir.cwd());
    }
    if (session_id == null and cfg.modules.sessions) {
        session_id = try std.fmt.allocPrint(arena, "repl-{d}", .{now_s});
    }
    var session_created: i64 = now_s;
    var session_title: []const u8 = "";
    var loaded_messages: []const types.Message = &.{};
    if (session_id) |sid| {
        const maybe_s: ?session_mod.Session = session_mod.loadSession(io, gpa, arena, std.Io.Dir.cwd(), sid) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (maybe_s) |s| {
            session_created = s.created;
            session_title = s.title;
            loaded_messages = s.messages;
        }
    }

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
        .session_id = session_id,
        .session_created = session_created,
        .session_title = session_title,
    };
    for (loaded_messages) |m| {
        // The agent rebuilds its own system prompt per run; a stored one
        // would fight it (same rule as `clanker run --session`).
        if (m.role == .system) continue;
        try model.messages.append(arena, m);
    }
    model.model_candidates = buildModelCandidates(arena, &model.cfg) catch &.{};
    defer model.text_field.deinit();

    // Session persistence: `--session <id>` resumes that conversation, else
    // `--continue` resumes the most recently touched one, else a fresh
    // conversation whose id is minted on its first save. The id becomes a
    // path fragment under state/sessions/, so it is validated before either
    // load or save.
    model.session_created = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    var session_id = opts.session;
    if (session_id == null and opts.continue_last) session_id = latestSessionId(io, arena);
    if (session_id) |sid| {
        if (!validSessionId(sid)) {
            log.log(.warn, "repl: ignoring invalid --session id '{s}'", .{sid});
            session_id = null;
        }
    }
    model.session_id = session_id;
    if (cfg.modules.sessions) {
        if (session_id) |sid| {
            const loaded = session.loadSession(io, gpa, arena, std.Io.Dir.cwd(), sid) catch |err| switch (err) {
                error.FileNotFound => null,
                else => blk: {
                    log.log(.warn, "repl: could not load session '{s}': {s}", .{ sid, @errorName(err) });
                    break :blk null;
                },
            };
            if (loaded) |s| {
                model.session_created = s.created;
                model.session_title = s.title;
                var loaded_count: usize = 0;
                for (s.messages) |m| {
                    if (m.role == .system) continue;
                    model.messages.append(arena, m) catch {};
                    loaded_count += 1;
                }
                model.lines.append(arena, .{
                    .text = std.fmt.allocPrint(arena, "[resumed session {s}: {d} messages]", .{ sid, loaded_count }) catch "[resumed session]",
                    .dim = true,
                }) catch {};
            } else {
                log.log(.info, "repl: no existing session '{s}', starting fresh", .{sid});
            }
        }
    }

    // Save on every exit path: app.run returns for /quit and for Ctrl-C while
    // idle alike, so persisting here (rather than in submit) is what makes the
    // conversation survive. Save even if the run loop errored out.
    const run_result = app.run(model.widget(), .{});
    model.saveConversation();
    try run_result;
}
