//! libvaxis-backed REPL (docs/ROADMAP.md migration). This is `clanker repl`,
//! the default REPL; the hand-rolled src/tui REPL was removed once this
//! proved out (the `repl-vaxis` spelling is kept as a compatibility alias in
//! cli.zig).
//!
//! Architecture: a single root `vxfw.Widget` ("Model") drives everything.
//! `vxfw.App.run` already handles SIGWINCH (`.winsize` events resize and
//! redraw automatically, no self-pipe needed, unlike src/tui/term.zig)
//! and owns the render loop. A submitted task runs `Agent.run` on a
//! background thread (LLM calls and tool execution are blocking); the
//! callbacks it takes (`on_token`/`on_tool_call`/`on_tool_result`) are bare
//! function pointers with no userdata slot, so they write into module-level,
//! mutex-guarded state, and the Model's `.tick` handler re-schedules itself
//! every 50ms *only while a turn is in flight* to pick up new streamed
//! content, idle, there is no timer running and the app is purely
//! event-driven, same principle as this session's KeyReader poll() fix in
//! the old REPL.
//!
//! Deliberately not yet built (documented gaps, not oversights): inline
//! ask_user/approval prompts (falls back to the same "nobody attached"
//! default a headless run gets). Full list, with what a fix looks like for
//! each: docs/ROADMAP.md's "vaxis REPL parity" entry under Planned. Tool
//! calls render as the established left-bar cards, built as plain strings by
//! transcript.zig's card helpers and styled into cells at draw time.
//!
//! A submitted line is one of three things, decided in `submit` in this
//! order: a `!`-prefixed shell escape (runs here and now through the ck_exec
//! gate, see `parseShellEscape`), a `/`-prefixed command from
//! `command_registry`, or a task for the agent. Only the third reaches the
//! LLM.
//!
//! Tab-complete over `command_registry` (`completeSlashCommand`) is the one
//! completion UI that isn't a modal picker: it edits the TextField in place
//! (single match, or several completing to a shared prefix) rather than
//! opening `/model`'s `picker_open`/`handlePickerKey` loop, since there is
//! nothing to navigate, just a line to finish or list.

const std = @import("std");
const edit_distance = @import("../util/edit_distance.zig");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const config = @import("../config.zig");
const client = @import("../llm/client.zig");
const types = @import("../llm/types.zig");
const providers = @import("../llm/registry.zig");
const registry = @import("../toolhost/registry.zig");
const session_mod = @import("../agent/session.zig");
const subprocess = @import("../agent/subprocess.zig");
const dap = @import("../debug/dap.zig");
const goal_prompt = @import("../agent/goal_prompt.zig");
const goal_loop = @import("../agent/goal_loop.zig");
const research_cmd = @import("../records/research.zig");
const rfc_cmd = @import("../records/rfc.zig");
const runtime = @import("../sandbox/runtime.zig");
const sandbox_host = @import("../sandbox/host.zig");
const agent_loop = @import("../agent/loop.zig");
const workflows_mod = @import("../agent/workflows.zig");
const Agent = agent_loop.Agent;
const json_util = @import("../util/json.zig");
const log = @import("../util/log.zig");
const utf8 = @import("../util/utf8.zig");
const syntax = @import("syntax.zig");
const theme_mod = @import("theme.zig");
const width_mod = @import("width.zig");
const sanitize = @import("sanitize.zig");
const preset_mod = @import("../preset/preset.zig");
const sampling = @import("../llm/sampling_profiles.zig");
// `_mod` because saveConversation has a local named `transcript`.
const transcript_mod = @import("transcript.zig");
const stats_mod = @import("turn_stats.zig");
const mascot = @import("mascot.zig");
const clipboard = @import("clipboard.zig");
const worktree_mod = @import("../improve/worktree.zig");
const slash_plugins = @import("slash_plugins.zig");

/// Redraw cadence while a turn is streaming: ~30fps, so streamed tokens land
/// smoothly instead of in visible 50ms (20fps) batches. Idle, no timer runs.
const stream_tick_ms: u32 = 33;

/// Redraw cadence the mascot's `loop` mode runs at, ~20fps: one animation
/// frame and one column of travel per tick, so it crosses a 100-column
/// terminal in about five seconds. Slower than `stream_tick_ms` on purpose --
/// this timer runs while the REPL is otherwise *idle*, so every wakeup here is
/// one the app would not otherwise make, and 20fps is already smooth for an
/// eleven-frame run cycle.
const mascot_tick_ms: u32 = 50;

/// Control-strips untrusted text before it can reach a cell (CWE-150).
///
/// Thin wrapper over `sanitize.sanitizeAlloc` so every call site in this file
/// reads the same and none of them can forget the failure policy: on an
/// allocation failure the text is **dropped**, not passed through. Rendering
/// unsanitized bytes is the one outcome this function exists to prevent, so
/// "render it raw" is not an acceptable fallback for it.
///
/// Like `sanitizeAlloc`, the common case (no control bytes) returns the input
/// slice and allocates nothing, which is what keeps the per-token `onToken`
/// path free of allocation.
///
/// This replaced a local `stripControls` that reused only `sanitize.isControl`
/// and therefore dropped C0 and DEL but *not* the UTF-8-encoded C1 range
/// (U+0080..U+009F). U+009B is CSI: terminals that decode C1 from UTF-8 would
/// have taken a two-byte `\xc2\x9b` in model output as the start of an escape
/// sequence. sanitize.zig already handled that and says it owns the single
/// definition; this file was the copy that had drifted.
fn clean(gpa: std.mem.Allocator, bytes: []const u8) ?[]const u8 {
    return sanitize.sanitizeAlloc(gpa, bytes) catch null;
}

fn errorRecoveryHint(err: anyerror, detail: ?[]const u8) []const u8 {
    if (err == error.MaxIterationsExceeded) return " (hit iteration limit; try a simpler task or raise agent.max_iterations)";
    if (err == error.SessionTokenBudgetExceeded) return " (ran out of token budget)";
    if (err == error.CompactionStalled) return " (history cannot be compacted below agent.max_history_tokens; raise it or trim the system prompt)";
    if (detail) |d| {
        const find = std.ascii.findIgnoreCase;
        if (find(d, "401") != null or find(d, "unauthorized") != null or find(d, "authentication") != null)
            return " (check API key; run `clanker doctor`)";
        if (find(d, "429") != null or find(d, "rate limit") != null or find(d, "rate_limit") != null)
            return " (rate limited; wait or /model to switch)";
        if (find(d, "http 400") != null or find(d, "bad request") != null)
            return " (provider rejected the request; the model may not exist here, or the request body is invalid; /model to switch)";
        if (find(d, "not found") != null or find(d, "model_not_found") != null)
            return " (model not found; /model to pick another)";
        if (find(d, "timeout") != null or find(d, "timed out") != null)
            return " (request timed out)";
        if (find(d, "onnection refused") != null or find(d, "onnection reset") != null)
            return " (cannot reach provider; check network)";
        if (find(d, "max_iterations") != null or find(d, "iteration limit") != null)
            return " (hit iteration limit; try a simpler task or raise agent.max_iterations)";
        if (find(d, "token_budget") != null or find(d, "token budget") != null)
            return " (ran out of token budget)";
    }
    return "";
}

/// Parse `/plan on`, `/research off`, or a bare toggle. Returns null when the
/// argument is not one of on/off/empty.
fn parseModeToggle(args: []const u8) ?bool {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(trimmed, "on") or std.ascii.eqlIgnoreCase(trimmed, "enable") or std.ascii.eqlIgnoreCase(trimmed, "true"))
        return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "off") or std.ascii.eqlIgnoreCase(trimmed, "disable") or std.ascii.eqlIgnoreCase(trimmed, "false"))
        return false;
    return null;
}

const ModeToggleResult = enum { ok, bad_usage };

fn toggleSessionMode(
    self: *Model,
    args: []const u8,
    mode: *bool,
    comptime usage: []const u8,
    comptime notice_fmt: []const u8,
) ModeToggleResult {
    if (parseModeToggle(args)) |want| {
        mode.* = want;
    } else if (args.len > 0) {
        self.lines.append(self.arena, .{ .text = usage, .dim = true }) catch {};
        return .bad_usage;
    } else {
        mode.* = !mode.*;
    }
    const state: []const u8 = if (mode.*) "on" else "off";
    self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, notice_fmt, .{state}) catch "notice: mode toggled", .dim = true }) catch {};
    return .ok;
}

fn idlePhaseLabel(self: *const Model, buf: []u8) []const u8 {
    const preset_suffix: []const u8 = if (self.preset_name) |pn| std.fmt.allocPrint(self.arena, " · {s}", .{pn}) catch "" else "";
    if (!self.plan_mode and !self.research_mode) {
        if (preset_suffix.len > 0) return std.fmt.bufPrint(buf, "ready{s}", .{preset_suffix}) catch "ready";
        return "ready";
    }
    if (self.plan_mode and self.research_mode) {
        if (preset_suffix.len > 0) return std.fmt.bufPrint(buf, "ready · plan · research{s}", .{preset_suffix}) catch "ready";
        return std.fmt.bufPrint(buf, "ready · plan · research", .{}) catch "ready";
    }
    if (self.plan_mode) {
        if (preset_suffix.len > 0) return std.fmt.bufPrint(buf, "ready · plan{s}", .{preset_suffix}) catch "ready";
        return std.fmt.bufPrint(buf, "ready · plan", .{}) catch "ready";
    }
    if (preset_suffix.len > 0) return std.fmt.bufPrint(buf, "ready · research{s}", .{preset_suffix}) catch "ready";
    return std.fmt.bufPrint(buf, "ready · research", .{}) catch "ready";
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
/// Mid-run steering queue: messages the user typed in the composer while a
/// turn runs, bridge_gpa-owned, drained oldest-first by tuiSteerPoll on the
/// run thread (the same seam POST /api/steer uses for the web). Filled by the
/// render thread's composer-as-steer-box; freed by tuiSteerPoll as it drains.
var bridge_steer: std.ArrayListUnmanaged([]u8) = .empty;
/// `.error_` log records emitted while the alt screen is up (the LLM
/// client's "request to 'x' failed" lines, sandbox refusals) previously
/// wrote straight to stderr and painted over the frame the draw loop had
/// just written, even on turns the fallback chain then recovered. They are
/// routed here by `logSinkWrite` and drained into the transcript as dim
/// lines under the bridge lock, so the record reaches the operator without
/// tearing the screen. bridge_gpa-owned; drained (and freed) by
/// `drainLogLines`. `bridge_log_mutex` guards the list alone: `drainLogLines`
/// runs with `bridge_mutex` already held (finishTurn, the draw loop), so a
/// separate lock keeps a log record emitted from inside a bridge-mutex
/// section from deadlocking on a non-recursive mutex.
var bridge_log_lines: std.ArrayListUnmanaged([]const u8) = .empty;
var bridge_log_mutex: std.c.pthread_mutex_t = .{};
var bridge_stop_flag: std.atomic.Value(bool) = .init(false);
/// Published only after runThreadMain has finished all deferred Agent cleanup.
/// The UI thread consumes this and joins the worker before making the model
/// idle, so the model arena cannot be destroyed while cleanup still uses it.
var bridge_turn_done: std.atomic.Value(bool) = .init(false);
/// The name of the tool currently executing (set on onToolCall, cleared on
/// onToolResult), so the status line can show what work is in flight instead
/// of a bare "thinking".
var bridge_active_tool: [64]u8 = undefined;
var bridge_active_tool_len: usize = 0;
/// Live session-strip counters for the in-flight turn. Folded into Model
/// totals in finishTurn. Guarded by bridge_mutex.
var bridge_live_started_ns: i128 = 0;
var bridge_live_tool_ms: u64 = 0;
var bridge_live_steps: u64 = 0;
var bridge_live_prompt: u64 = 0;
var bridge_live_completion: u64 = 0;
var bridge_live_cache_hit: u64 = 0;
var bridge_live_cache_miss: u64 = 0;
var bridge_live_ttft_ms: ?u64 = null;
var bridge_live_ttft_total: u64 = 0;
var bridge_live_ttft_samples: u32 = 0;

fn resetBridgeLive() void {
    bridge_live_started_ns = 0;
    bridge_live_tool_ms = 0;
    bridge_live_steps = 0;
    bridge_live_prompt = 0;
    bridge_live_completion = 0;
    bridge_live_cache_hit = 0;
    bridge_live_cache_miss = 0;
    bridge_live_ttft_ms = null;
    bridge_live_ttft_total = 0;
    bridge_live_ttft_samples = 0;
}

fn liveElapsedMs() u64 {
    if (bridge_live_started_ns == 0) return 0;
    const now = std.Io.Timestamp.now(bridge_io, .awake);
    const d = now.nanoseconds - bridge_live_started_ns;
    if (d <= 0) return 0;
    return @intCast(@divTrunc(d, std.time.ns_per_ms));
}

fn onToken(delta: []const u8) void {
    bridge_mutex.lockUncancelable(bridge_io);
    defer bridge_mutex.unlock(bridge_io);
    const safe = clean(bridge_gpa, delta) orelse return;
    defer if (safe.ptr != delta.ptr) bridge_gpa.free(safe);
    if (bridge_live_ttft_ms == null and bridge_live_started_ns != 0) {
        bridge_live_ttft_ms = liveElapsedMs();
    }
    bridge_stream_buf.appendSlice(bridge_gpa, safe) catch {};
}

/// Each batch of calls becomes one left-bar card (transcript.zig's card
/// builders): the first call opens it, the rest of the batch joins the body,
/// each call's arguments follow as a truncated one-line preview, and
/// onToolResult closes it, the agent reports one timing per batch, so
/// per-call cards would draw open corners nothing ever closes. Name and
/// arguments are untrusted; the builders control-strip them (CWE-150).
fn onToolCall(calls: []const types.ToolCall) void {
    bridge_mutex.lockUncancelable(bridge_io);
    defer bridge_mutex.unlock(bridge_io);
    for (calls, 0..) |c, i| {
        const header = transcript_mod.toolCardHeader(bridge_gpa, c.name, i == 0) catch continue;
        bridge_tool_lines.append(bridge_gpa, header) catch bridge_gpa.free(header);
        const body = transcript_mod.toolCardArgs(bridge_gpa, c.arguments) catch null;
        if (body) |b| bridge_tool_lines.append(bridge_gpa, b) catch bridge_gpa.free(b);
    }
    if (calls.len > 0) {
        const name = calls[calls.len - 1].name;
        const n = @min(name.len, bridge_active_tool.len);
        @memcpy(bridge_active_tool[0..n], name[0..n]);
        bridge_active_tool_len = n;
        bridge_live_steps += 1;
    }
}

fn onToolResult(elapsed_ms: u64) void {
    bridge_mutex.lockUncancelable(bridge_io);
    defer bridge_mutex.unlock(bridge_io);
    bridge_active_tool_len = 0;
    bridge_live_tool_ms +|= elapsed_ms;
    const line = transcript_mod.toolCardFooter(bridge_gpa, elapsed_ms) catch return;
    bridge_tool_lines.append(bridge_gpa, line) catch bridge_gpa.free(line);
}

fn onUsage(stats: agent_loop.RunStats) void {
    bridge_mutex.lockUncancelable(bridge_io);
    defer bridge_mutex.unlock(bridge_io);
    bridge_live_prompt = stats.total_prompt_tokens;
    bridge_live_completion = stats.total_completion_tokens;
    bridge_live_cache_hit = stats.total_cache_hit_tokens;
    bridge_live_cache_miss = stats.total_cache_miss_tokens;
    if (stats.ttft_samples > 0) {
        bridge_live_ttft_total = stats.total_ttft_ms;
        bridge_live_ttft_samples = stats.ttft_samples;
    }
}

/// Frees and empties the mid-run steering queue. Called at turn start (so a
/// message typed against a run that just ended never leaks into the next
/// one) and at app exit. Caller must hold the bridge lock.
fn clearBridgeSteer() void {
    for (bridge_steer.items) |m| bridge_gpa.free(m);
    bridge_steer.clearRetainingCapacity();
}

/// `log.Sink.write` for the REPL: buffers one record for the transcript
/// instead of letting it reach stderr. Runs on whatever thread logged (the
/// run thread, an HTTP poll), so it takes the log buffer's own lock and
/// never touches `bridge_mutex`; drainers hold that.
fn logSinkWrite(ctx: *const anyopaque, line: []const u8) void {
    _ = ctx;
    var body = line;
    if (body.len > 0 and body[body.len - 1] == '\n') body = body[0 .. body.len - 1];
    if (body.len == 0) return;
    // The record is one physical line, but its content (a provider error
    // string, an exec refusal) is untrusted, so control-strip like every
    // other tool-sourced transcript line (CWE-150).
    const safe = clean(bridge_gpa, body) orelse return;
    _ = std.c.pthread_mutex_lock(&bridge_log_mutex);
    defer _ = std.c.pthread_mutex_unlock(&bridge_log_mutex);
    bridge_log_lines.append(bridge_gpa, safe) catch bridge_gpa.free(safe);
}

/// Moves buffered log records into the transcript as dim lines. Caller
/// holds `bridge_mutex`: the render-thread draw loop drains every frame and
/// the run thread's finishTurn drains at turn end, so a record emitted
/// between turns (an idle-time diagnostic from a background poll) still
/// reaches the screen.
fn drainLogLines(self: *Model) void {
    _ = std.c.pthread_mutex_lock(&bridge_log_mutex);
    defer _ = std.c.pthread_mutex_unlock(&bridge_log_mutex);
    if (bridge_log_lines.items.len == 0) return;
    for (bridge_log_lines.items) |l| {
        const copy = self.arena.dupe(u8, l) catch l;
        self.lines.append(self.arena, .{ .text = copy, .dim = true }) catch {};
        if (copy.ptr != l.ptr) bridge_gpa.free(l);
    }
    bridge_log_lines.clearRetainingCapacity();
}

/// Agent.steer_fn for the REPL: pops the next steering message the user typed
/// in the composer while this turn runs, hands back an arena copy. Runs on
/// the run thread; takes the bridge lock. The message is already framed by
/// the composer, so the agent reads it as the same mid-run course correction
/// the web POST /api/steer delivers.
fn tuiSteerPoll(arena: std.mem.Allocator) ?[]const u8 {
    bridge_mutex.lockUncancelable(bridge_io);
    defer bridge_mutex.unlock(bridge_io);
    if (bridge_steer.items.len == 0) return null;
    const msg = bridge_steer.orderedRemove(0);
    defer bridge_gpa.free(msg);
    return arena.dupe(u8, msg) catch null;
}

// ---------------------------------------------------------------------
// Ask/confirm bridge: ask_user questions and confirm-before-write gates
// raised on the run thread, answered by the render thread's modal
// (handleAskKey/drawAskModal). pthread primitives rather than
// std.Io.Mutex/Condition for the same reason cli.zig's serve bridge uses
// them: AskFn/ConfirmFn are bare function pointers with no `Io` to wait
// through, and the bounded block needs a timed wait the Io condition does
// not have. Both types' zero-default is their static initializer.
// ---------------------------------------------------------------------

var ask_mutex: std.c.pthread_mutex_t = .{};
var ask_cond: std.c.pthread_cond_t = .{};
/// Set from agent.ask_timeout_seconds at REPL startup: the backstop that
/// unparks the run if the question is never answered, the same budget the
/// serve bridge gives a closed browser tab.
var ask_timeout_ns: u64 = 120 * std.time.ns_per_s;

const AskKind = enum { ask, confirm };
const PendingAsk = struct {
    active: bool = false,
    kind: AskKind = .ask,
    /// bridge_gpa-owned, control-stripped copies: question and options are
    /// model-chosen text, so CWE-150 applies before they can reach a cell,
    /// and the render thread must never touch the run thread's arena.
    question: []const u8 = "",
    options: []const []const u8 = &.{},
    answered: bool = false,
    /// Index into `options`, or null for declined (Escape, timeout, stop).
    picked: ?usize = null,
};
var pending_ask: PendingAsk = .{};

/// An always-owned, control-stripped copy of `bytes` (sanitizeAlloc returns
/// the input slice unchanged when it is already clean, which would leave the
/// bridge holding arena memory the run thread is about to reuse).
fn dupSanitized(bytes: []const u8) ?[]u8 {
    const safe = sanitize.sanitizeAlloc(bridge_gpa, bytes) catch return null;
    if (safe.ptr != bytes.ptr) return @constCast(safe);
    return bridge_gpa.dupe(u8, bytes) catch null;
}

/// Publishes a question and parks the run thread until the modal answers,
/// the deadline passes, or the turn is abandoned. Returns the picked option
/// index, null meaning declined. Runs on the run thread.
fn askOnRunThread(kind: AskKind, question: []const u8, options: []const []const u8) ?usize {
    // A stop requested before the question was raised means nobody will
    // answer or cancel it; decline immediately instead of parking until
    // the timeout.
    if (bridge_stop_flag.load(.acquire)) return null;
    const q = dupSanitized(question) orelse return null;
    const opts = bridge_gpa.alloc([]const u8, options.len) catch {
        bridge_gpa.free(q);
        return null;
    };
    var made: usize = 0;
    while (made < options.len) : (made += 1) {
        opts[made] = dupSanitized(options[made]) orelse break;
    }
    _ = std.c.pthread_mutex_lock(&ask_mutex);
    // One question at a time: the agent's tool path is sequential, so a
    // second concurrent asker is a bug somewhere else; refuse, don't queue.
    const refused = made < options.len or pending_ask.active;
    if (!refused) {
        pending_ask = .{ .active = true, .kind = kind, .question = q, .options = opts };
        // Absolute CLOCK_REALTIME deadline, serve's pattern: a broadcast
        // that wakes this waiter without answering re-waits on what is
        // left of the budget for free.
        var now: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.c.clock_gettime(.REALTIME, &now);
        const total = @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec)) + ask_timeout_ns;
        const deadline: std.c.timespec = .{
            .sec = @intCast(total / std.time.ns_per_s),
            .nsec = @intCast(total % std.time.ns_per_s),
        };
        while (!pending_ask.answered) {
            if (std.c.pthread_cond_timedwait(&ask_cond, &ask_mutex, &deadline) == .TIMEDOUT) break;
        }
    }
    const picked = if (pending_ask.answered) pending_ask.picked else null;
    pending_ask = .{};
    _ = std.c.pthread_mutex_unlock(&ask_mutex);
    for (opts[0..made]) |o| bridge_gpa.free(@constCast(o));
    bridge_gpa.free(opts);
    bridge_gpa.free(q);
    return if (refused) null else picked;
}

/// Wakes a run thread parked in askOnRunThread with "declined". The render
/// thread calls this wherever it stops or abandons a turn; without it the
/// Ctrl-C stop flag would leave the worker on the condition until the
/// timeout, and the join after it hanging that long too.
fn askCancelPending() void {
    _ = std.c.pthread_mutex_lock(&ask_mutex);
    if (pending_ask.active and !pending_ask.answered) {
        pending_ask.answered = true;
        pending_ask.picked = null;
        _ = std.c.pthread_cond_broadcast(&ask_cond);
    }
    _ = std.c.pthread_mutex_unlock(&ask_mutex);
}

/// Agent.ask_fn for this REPL: ask_user's question becomes the modal, and
/// the answer is the picked option — gpa-owned, as ckAsk's contract
/// requires (it frees with sandbox.gpa, which is bridge_gpa here).
fn tuiAsk(question: []const u8, options: []const []const u8) anyerror![]const u8 {
    const idx = askOnRunThread(.ask, question, options) orelse return error.NoUser;
    if (idx >= options.len) return error.NoUser;
    return bridge_gpa.dupe(u8, options[idx]);
}

/// The two answers a confirm offers; static, matching serveConfirm.
const tui_confirm_options: []const []const u8 = &.{ "allow", "deny" };

/// Agent.confirm_fn: one write-capable tool call shown with its truncated
/// args preview. Anything short of an explicit "allow" — deny, Escape,
/// timeout, an abandoned turn — refuses the call, exactly like the serve
/// gate: an unattended gate that waves writes through protects nothing.
fn tuiConfirm(tool_name: []const u8, args_preview: []const u8) bool {
    var buf: [512]u8 = undefined;
    const q = std.fmt.bufPrint(&buf, "{s}  {s}", .{ tool_name, args_preview }) catch tool_name;
    const idx = askOnRunThread(.confirm, q, tui_confirm_options) orelse return false;
    return idx == 0;
}

const RunThreadArgs = struct {
    model: *Model,
    task: []const u8,
    pending_images: ?[]types.ImagePart = null,
    goal_condition: ?[]const u8 = null,
};

const TuiGoalLoopContext = struct {
    model: *Model,
    agent: *Agent,
    condition: []const u8,
    last_err_detail: ?[]const u8 = null,
};

fn tuiGoalLoopRunTurn(context: *anyopaque, _: u32, task: []const u8) anyerror![]const u8 {
    // goal_loop.run boxed this TuiGoalLoopContext as Callbacks.context.
    const loop_ctx: *TuiGoalLoopContext = @ptrCast(@alignCast(context));
    const self = loop_ctx.model;
    const started = std.Io.Timestamp.now(self.io, .awake);
    const resp = loop_ctx.agent.run(&self.messages, task, &loop_ctx.last_err_detail) catch |err| return err;
    const answer = resp.message.content orelse "";
    // Goal-loop turns build their own agent; capture its prompt so the save
    // after the loop records what the evaluator's target actually saw.
    self.session_system_prompt = loop_ctx.agent.system_prompt_text;
    self.finishTurn(answer, self.turnStats(loop_ctx.agent, started, self.messages.items));
    return answer;
}

fn tuiGoalLoopEvaluate(context: *anyopaque, _: u32, answer: []const u8) anyerror!goal_loop.Decision {
    // goal_loop.run boxed this TuiGoalLoopContext as Callbacks.context.
    const loop_ctx: *TuiGoalLoopContext = @ptrCast(@alignCast(context));
    const self = loop_ctx.model;
    const prompt = try goal_loop.evaluatorTask(self.arena, loop_ctx.condition, answer);
    const messages = [_]types.Message{
        .{ .role = .system, .content = goal_loop.evaluator_system_prompt },
        .{ .role = .user, .content = prompt },
    };
    var err_detail: ?[]const u8 = null;
    const resp = try client.chat(&self.ctx, self.arena, .{
        .provider = &self.provider,
        .messages = &messages,
        .max_tokens = goal_loop.evaluator_max_tokens,
    }, &err_detail);
    return goal_loop.parseDecision(self.arena, resp.message.content orelse "");
}

fn tuiGoalLoopDecision(context: *anyopaque, turn: u32, decision: goal_loop.Decision) void {
    // goal_loop.run boxed this TuiGoalLoopContext as Callbacks.context.
    const loop_ctx: *TuiGoalLoopContext = @ptrCast(@alignCast(context));
    const self = loop_ctx.model;
    bridge_mutex.lockUncancelable(bridge_io);
    defer bridge_mutex.unlock(bridge_io);
    const reason = utf8.cap(decision.reason, goal_loop.reason_log_bytes);
    const line = std.fmt.allocPrint(self.arena, "goal loop turn {d}: {s}: {s}", .{ turn, @tagName(decision.verdict), reason }) catch return;
    self.lines.append(self.arena, .{ .text = line, .dim = true }) catch {};
}

fn runThreadMain(args: RunThreadArgs) void {
    defer bridge_turn_done.store(true, .release);
    const self = args.model;
    const messages = &self.messages;
    var err_detail: ?[]const u8 = null;

    var a = Agent.init(&self.ctx, self.arena, &self.provider, &self.cfg, &self.reg, self.tool_defs) catch |err| {
        // No agent, so no usage to report: the turn line is skipped rather
        // than printed as a row of zeroes.
        self.finishTurn(std.fmt.allocPrint(self.arena, "error: {s}", .{@errorName(err)}) catch "error: out of memory", null);
        return;
    };
    defer a.deinit();
    a.session_id = self.session_id orelse "default";
    a.on_token = onToken;
    a.on_tool_call = onToolCall;
    a.on_tool_result = onToolResult;
    a.on_usage = onUsage;
    a.stop_flag = &bridge_stop_flag;
    // Mid-run steering: messages typed into the composer while this turn
    // runs are drained between iterations, exactly as POST /api/steer feeds
    // a streaming web run.
    a.steer_fn = &tuiSteerPoll;
    // The ask bridge: ask_user reaches the human as a modal instead of the
    // "nobody attached" default, and with agent.confirm_writes = "always"
    // the same modal gates write-capable tool calls. ("browser" keeps
    // gating only serve's streaming runs, as documented.)
    a.ask_fn = &tuiAsk;
    if (self.cfg.agent.confirm_writes == .always) a.confirm_fn = &tuiConfirm;
    a.plan_mode = self.plan_mode;
    if (self.preset_name) |pn| {
        var dir = std.Io.Dir.cwd().openDir(self.io, "presets", .{}) catch null;
        if (dir) |*d| {
            defer d.close(self.io);
            if (preset_mod.loadFromFile(self.io, self.arena, d.*, pn) catch null) |preset| {
                const stored = self.arena.create(preset_mod.Preset) catch null;
                if (stored) |s| {
                    // Names leak via parseString dupes; keep stored for gate predicate.
                    s.* = preset;
                    a.preset = s;
                    if (preset.system_prompt_append.len > 0) {
                        a.system_prompt_text = std.fmt.allocPrint(self.arena, "{s}\n\n{s}", .{ a.system_prompt_text, preset.system_prompt_append }) catch a.system_prompt_text;
                    }
                }
            }
        }
    }
    a.research_mode = self.research_mode;
    if (args.pending_images) |imgs| a.pending_images = imgs;
    // Capture what the model will see so persistSession can record it: the
    // system prompt, preset persona included. Arena-owned (the agent borrows
    // self.arena), so the slice stays valid for the Model's lifetime.
    self.session_system_prompt = a.system_prompt_text;

    if (args.goal_condition) |condition| {
        var goal_ctx = TuiGoalLoopContext{ .model = self, .agent = &a, .condition = condition };
        const outcome = goal_loop.run(self.arena, condition, args.task, self.cfg.agent.max_goal_turns, .{
            .context = &goal_ctx,
            .run_turn = tuiGoalLoopRunTurn,
            .evaluate = tuiGoalLoopEvaluate,
            .on_decision = tuiGoalLoopDecision,
        }) catch |err| {
            const hint = errorRecoveryHint(err, goal_ctx.last_err_detail);
            const detail = goal_ctx.last_err_detail orelse @errorName(err);
            self.finishTurn(std.fmt.allocPrint(self.arena, "goal loop blocked: {s}{s}", .{ detail, hint }) catch "goal loop blocked", null);
            return;
        };
        bridge_mutex.lockUncancelable(bridge_io);
        defer bridge_mutex.unlock(bridge_io);
        const line = std.fmt.allocPrint(self.arena, "goal loop {s} after {d} turn(s): {s}", .{ @tagName(outcome.verdict), outcome.turns, outcome.reason }) catch return;
        self.lines.append(self.arena, .{ .text = line, .dim = true }) catch {};
        return;
    }

    // Wall time spans the whole turn, tool rounds included, because that is
    // the wait the person at the keyboard actually sat through.
    const started = std.Io.Timestamp.now(self.io, .awake);
    const resp = a.run(messages, args.task, &err_detail) catch |err| {
        const hint = errorRecoveryHint(err, err_detail);
        // `err_detail` is the provider's own error string, echoed verbatim
        // into the transcript: untrusted text on the same footing as the
        // answer, and a failing request is exactly when a hostile or merely
        // broken endpoint gets to choose what bytes clanker prints.
        const text = if (if (err_detail) |d| clean(self.arena, d) else null) |d|
            std.fmt.allocPrint(self.arena, "error: {s}{s}", .{ d, hint }) catch "error: out of memory"
        else
            std.fmt.allocPrint(self.arena, "error: {s}{s}", .{ @errorName(err), hint }) catch "error: out of memory";
        // A turn that ran out of iterations or budget still spent real
        // tokens and real money; report them the same as a turn that
        // finished. `Agent.run`'s own defer has already folded its stats by
        // the time it returns, error path included.
        self.finishTurn(text, self.turnStats(&a, started, messages.items));
        return;
    };
    self.finishTurn(resp.message.content orelse "", self.turnStats(&a, started, messages.items));
}

/// One rendered line of session-permanent transcript (a completed turn's
/// text, or a tool-call/result line). `fence_lang` is non-null for lines
/// inside a fenced code block: they render through the syntax highlighter
/// instead of getting the dim fence style.
const Line = struct {
    text: []const u8,
    dim: bool = false,
    fence_lang: ?[]const u8 = null,
    /// The user's own echoed prompt ("clanker> ..."), rendered in the accent
    /// prompt colour so each turn's starting point is scannable on scrollback.
    user: bool = false,
};

/// A foldable region: one long assistant reply, collapsed behind a `▸` header
/// row. The header persists (as `▾`) while the reply is open and is the
/// toggle in both directions. `start`/`count` name the reply's
/// contiguous run in `Model.lines` (lines are only ever appended, so the range
/// is stable once created). `expanded` is the user's intent; the animation
/// drives `anim` toward it, and rendering reads `anim`, so a fold round-trips
/// to exactly its collapsed/open layout — no drift.
const Fold = struct {
    start: usize,
    count: usize,
    expanded: bool,
    /// 0 = collapsed (header only), 1 = fully open. Monotonically eased toward
    /// `expanded` by the tick loop.
    anim: f32,
};

/// The "› " turn arrow marking where a completed reply's prose begins.
const turn_arrow = "\xe2\x80\xba ";

/// A reply at least this many wrapped terminal rows tall is worth folding.
const FOLD_MIN_ROWS: usize = 8;
/// Steps a fold takes to travel from collapsed to open. At `fold_tick_ms` a
/// side, that is roughly a quarter second.
const FOLD_ANIM_RATE: u32 = 12;
/// Frame interval while a fold is animating. Shares the one `ctx.tick` the
/// model owns (see `timer_armed`); nothing here arms a second timer.
const fold_tick_ms: u32 = 16;

/// Errors use the same stable prefix as the non-interactive CLI. Keeping the
/// classifier separate from drawing prevents a new TUI error path from
/// silently falling back to the dim notice style.
fn isErrorLine(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "error:");
}

const KillKind = enum { start, end, word };

/// Apply one readline kill operation and retain exactly what it removed for
/// Ctrl-Y. Kept independent of Model so cursor boundaries and UTF-8 text are
/// unit-testable without a terminal event loop.
fn killText(field: *vxfw.TextField, ring: *std.ArrayList(u8), alloc: std.mem.Allocator, kind: KillKind) !void {
    ring.clearRetainingCapacity();
    switch (kind) {
        .start => {
            try ring.appendSlice(alloc, field.buf.firstHalf());
            field.deleteToStart();
        },
        .end => {
            try ring.appendSlice(alloc, field.buf.secondHalf());
            field.deleteToEnd();
        },
        .word => {
            const before = try field.buf.dupe();
            defer field.buf.allocator.free(before);
            const old_cursor = field.byteOffsetToCursor();
            field.deleteWordBeforeWhitespace();
            const new_cursor = field.byteOffsetToCursor();
            try ring.appendSlice(alloc, before[new_cursor..old_cursor]);
        },
    }
}

test "readline kill operations feed Ctrl-Y's private ring" {
    var field = vxfw.TextField.init(std.testing.allocator);
    defer field.deinit();
    var ring: std.ArrayList(u8) = .empty;
    defer ring.deinit(std.testing.allocator);

    try field.insertSliceAtCursor("alpha βeta");
    try killText(&field, &ring, std.testing.allocator, .word);
    const shortened = try field.buf.dupe();
    defer field.buf.allocator.free(shortened);
    try std.testing.expectEqualStrings("alpha ", shortened);
    try std.testing.expectEqualStrings("βeta", ring.items);
    try field.insertSliceAtCursor(ring.items);
    const restored = try field.buf.dupe();
    defer field.buf.allocator.free(restored);
    try std.testing.expectEqualStrings("alpha βeta", restored);

    field.cursorLeft();
    try killText(&field, &ring, std.testing.allocator, .start);
    try std.testing.expectEqualStrings("alpha βet", ring.items);
    try killText(&field, &ring, std.testing.allocator, .end);
    try std.testing.expectEqualStrings("a", ring.items);
}

/// Recovery text for failures returned by the REPL's shared internal tools.
/// A generic "not found" cannot imply sessions: graph, plugin, and tool
/// failures use the same result envelope and need their own destination.
fn internalToolFailureHint(tool_name: []const u8, detail: []const u8) []const u8 {
    if (std.mem.eql(u8, tool_name, "graph") and std.mem.eql(u8, detail, "no such run"))
        return "; /graph lists recorded runs";
    if (std.mem.eql(u8, tool_name, "sessions") and std.ascii.findIgnoreCase(detail, "not found") != null)
        return "; /sessions lists saved conversations";
    return "";
}

/// Internal descriptor names are useful in logs, not in a command transcript.
/// Name the surface the operator can actually retry.
fn internalToolDisplayName(tool_name: []const u8) []const u8 {
    if (std.mem.eql(u8, tool_name, "sessions")) return "/sessions";
    if (std.mem.eql(u8, tool_name, "graph")) return "/graph";
    if (std.mem.eql(u8, tool_name, "status")) return "/status";
    if (std.mem.eql(u8, tool_name, "tools")) return "/tools";
    if (std.mem.eql(u8, tool_name, "plugins")) return "/plugins";
    if (std.mem.eql(u8, tool_name, "compare")) return "/compare";
    return tool_name;
}

fn appendDimBlock(arena: std.mem.Allocator, lines: *std.ArrayList(Line), text: []const u8) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| lines.append(arena, .{ .text = line, .dim = true }) catch {};
}

test "TUI error lines use the CLI error prefix" {
    try std.testing.expect(isErrorLine("error: unknown command: /modle"));
    try std.testing.expect(isErrorLine("error: ProviderRefused"));
    try std.testing.expect(!isErrorLine("usage: /model [query]"));
    try std.testing.expect(!isErrorLine("[turn: 12 in / 3 out]"));
}

test "internal tool recovery hints point to the command that failed" {
    try std.testing.expectEqualStrings("; /graph lists recorded runs", internalToolFailureHint("graph", "no such run"));
    try std.testing.expectEqualStrings("; /sessions lists saved conversations", internalToolFailureHint("sessions", "conversation not found"));
    try std.testing.expectEqualStrings("", internalToolFailureHint("plugins", "manifest not found"));
    try std.testing.expectEqualStrings("", internalToolFailureHint("tools", "descriptor not found"));
}

test "internal tool errors name public commands" {
    try std.testing.expectEqualStrings("/graph", internalToolDisplayName("graph"));
    try std.testing.expectEqualStrings("/plugins", internalToolDisplayName("plugins"));
    try std.testing.expectEqualStrings("/compare", internalToolDisplayName("compare"));
    try std.testing.expectEqualStrings("custom", internalToolDisplayName("custom"));
}

/// Folds one completed answer into transcript lines: control-stripped, split
/// on '\n', fence markers consumed and their language carried on the lines
/// they open, and the first visible line marked with the "› " turn arrow.
///
/// Pure over (arena, out, answer) so the sanitizing is testable without a
/// terminal, a provider or a Model. It is the single place a turn's prose
/// becomes transcript, which is what makes the control-strip below hold for
/// every path into it.
///
/// **This is the sanitising seam that was missing.** `onToken` stripped each
/// streamed delta, but `finishTurn` renders `resp.message.content` whenever
/// the provider sent one (`chatStream` always assembles it), and that
/// whole-message text had never been through any strip at all — the streamed
/// copy it displaced was the only sanitized one.
///
/// What kept that from being an exploitable hole *for this particular path*
/// is worth stating plainly, because it is luck rather than design: answer
/// lines render through `writeWrappedSegments`, which skips graphemes of
/// display width 0, and a control byte measures 0. So an ESC in prose is
/// dropped by a wrapping guard that exists for layout reasons and would stop
/// doing this job the moment a line took any other branch. `writeWrapped`,
/// the branch every dim line uses, has no such guard and writes each
/// codepoint unconditionally — which is why the two untrusted strings that
/// *do* land there (`err_detail` and internal-tool `text`) were live
/// injections, not theoretical ones. Sanitizing at the seam makes the
/// guarantee independent of which draw branch a line happens to take.
fn appendAnswerLines(arena: std.mem.Allocator, out: *std.ArrayList(Line), answer: []const u8) void {
    const safe = clean(arena, answer) orelse {
        out.append(arena, .{ .text = "error: answer dropped: out of memory", .dim = true }) catch {};
        return;
    };
    // `answer` is often `bridge_stream_buf.items`, cleared by the caller the
    // moment this returns, so an unmodified slice still has to be copied. A
    // slice `clean` allocated is already arena-owned and needs no second copy.
    const owned = if (safe.ptr == answer.ptr) (arena.dupe(u8, safe) catch return) else safe;

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
            std.fmt.allocPrint(arena, turn_arrow ++ "{s}", .{src_line}) catch src_line
        else
            src_line;
        first = false;
        out.append(arena, .{ .text = prefixed, .fence_lang = lang }) catch {};
    }
}

/// One entry in the `/model` picker: a provider/model pair flattened out of
/// `Config.providers` so the picker can filter and sort without walking the
/// nested map on every keystroke.
/// Which list the shared modal picker is showing.
const PickerKind = enum { model, theme, command, effort, preset };

const ModelCandidate = struct {
    provider: []const u8,
    model: []const u8,
    display: []const u8,
    /// Preformatted once into session-lifetime memory. Vaxis cells borrow
    /// grapheme slices until the frame is flushed, so picker rows must not
    /// point into a draw function's stack buffer.
    label: []const u8,
    context_window: u32,
    cost_in: ?f64,
    cost_out: ?f64,
    category: []const u8,
};

/// Flattens every configured provider's models into one list, in config
/// order (providers, then models within a provider), which is what makes the
/// picker's unfiltered list read as grouped-by-provider without a separate
/// sort pass. A provider this process cannot call is skipped entirely
/// (`providers.unusableReason`: the offline credential gate plus the
/// loopback probe), so the picker never offers a model the operator cannot
/// call on this machine.
fn buildModelCandidates(arena: std.mem.Allocator, cfg: *const config.Config, environ_map: *std.process.Environ.Map, io: ?std.Io) ![]const ModelCandidate {
    var out: std.ArrayList(ModelCandidate) = .empty;
    var pit = cfg.providers.iterator();
    while (pit.next()) |pentry| {
        // The combined gate: the credential check plus, when io is present, a
        // loopback TCP probe for keyless local providers (vllm/ollama), since
        // those pass the credential gate whether or not their server runs.
        // Null io skips the probe (unit tests exercise the flattening, not
        // the machine). The web UI's `GET /api/providers` annotation applies
        // this same function, so both pickers offer the same set.
        if (providers.unusableReason(arena, environ_map, pentry.value_ptr, io) != null) continue;
        const provider_start = out.items.len;
        var mit = pentry.value_ptr.models.iterator();
        while (mit.next()) |mentry| {
            const display = mentry.value_ptr.display orelse mentry.key_ptr.*;
            // The row label carries the whole spec inline (the picker has no
            // separate detail line for models); category joins it when set.
            const base = if (mentry.value_ptr.cost_per_1m_input != null or mentry.value_ptr.cost_per_1m_output != null)
                try std.fmt.allocPrint(arena, "{s}/{s}  {d} ctx  ${d}/${d} per 1M", .{
                    pentry.key_ptr.*,
                    display,
                    mentry.value_ptr.context_window,
                    mentry.value_ptr.cost_per_1m_input orelse 0,
                    mentry.value_ptr.cost_per_1m_output orelse 0,
                })
            else
                try std.fmt.allocPrint(arena, "{s}/{s}  {d} ctx", .{ pentry.key_ptr.*, display, mentry.value_ptr.context_window });
            const label = if (mentry.value_ptr.category.len > 0)
                try std.fmt.allocPrint(arena, "{s}  {s}", .{ base, mentry.value_ptr.category })
            else
                base;
            try out.append(arena, .{
                .provider = pentry.key_ptr.*,
                .model = mentry.key_ptr.*,
                .display = display,
                .label = label,
                .context_window = mentry.value_ptr.context_window,
                .cost_in = mentry.value_ptr.cost_per_1m_input,
                .cost_out = mentry.value_ptr.cost_per_1m_output,
                .category = mentry.value_ptr.category,
            });
        }
        // Sorted within this provider only, grouped-by-provider stays the
        // outer shape, category just orders the models inside each group.
        // Empty category sorts last (uncategorized models keep falling to
        // the bottom rather than jumping ahead of every categorized peer).
        std.mem.sort(ModelCandidate, out.items[provider_start..], {}, struct {
            fn lt(_: void, a: ModelCandidate, b: ModelCandidate) bool {
                const a_empty = a.category.len == 0;
                const b_empty = b.category.len == 0;
                if (a_empty != b_empty) return b_empty;
                if (!std.mem.eql(u8, a.category, b.category)) return std.mem.lessThan(u8, a.category, b.category);
                return std.mem.lessThan(u8, a.model, b.model);
            }
        }.lt);
    }
    return out.toOwnedSlice(arena);
}

/// Case-insensitive subsequence match ("kc3" finds "kimi-k3"): the same
/// forgiving-order fuzzy match the web UI's command palette and saved-prompt
/// list already use (`fuzzyMatch` in `ui/app/app.js`), so `/model`
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
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

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

    const cands = try buildModelCandidates(arena, &cfg, &env, null);
    try std.testing.expectEqual(@as(usize, 2), cands.len);
    try std.testing.expectEqualStrings("kimi-k3", cands[0].provider);
    try std.testing.expectEqualStrings("moonshotai/kimi-k3", cands[0].display); // display overrides the bare model id
    try std.testing.expectEqualStrings("kimi-k3/moonshotai/kimi-k3  1048576 ctx  $3/$15 per 1M", cands[0].label);
    try std.testing.expectEqual(@as(?f64, 3), cands[0].cost_in);
    try std.testing.expectEqualStrings("deepseek", cands[1].provider);
    try std.testing.expectEqualStrings("deepseek-chat", cands[1].display); // no display set: falls back to the model id
    try std.testing.expectEqual(@as(?f64, null), cands[1].cost_in);
}

test "buildModelCandidates excludes providers with no usable credentials" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("SET_KEY", "x");

    var cfg = config.Config{};
    var keyed = try config.Provider.single(arena, "keyed", "https://api.keyed.test/v1", .openai_compat, "m", .{});
    keyed.api_key_env = "SET_KEY";
    try cfg.providers.put(arena, "keyed", keyed);
    var missing = try config.Provider.single(arena, "missing", "https://api.missing.test/v1", .openai_compat, "m", .{});
    missing.api_key_env = "UNSET_KEY";
    try cfg.providers.put(arena, "missing", missing);
    try cfg.providers.put(arena, "local", try config.Provider.single(arena, "local", "http://127.0.0.1:11434/v1", .openai_compat, "m", .{}));

    const cands = try buildModelCandidates(arena, &cfg, &env, null);
    try std.testing.expectEqual(@as(usize, 2), cands.len);
    try std.testing.expectEqualStrings("keyed", cands[0].provider);
    try std.testing.expectEqualStrings("local", cands[1].provider);
}

// ---------------------------------------------------------------------
// Reasoning-effort picker: the five wire levels plus a `default` choice
// that clears the session pin. The effective level and its source are
// resolved with the same precedence `Agent.classifyEffort` plus
// `writeSamplingParams` apply, so the picker marks what the *next* turn
// will actually use, not just what `[agent] reasoning_effort` says.
// ---------------------------------------------------------------------

/// Where the currently effective effort comes from, in descending precedence.
const EffortSource = enum {
    /// `[agent] reasoning_effort` (set by `--reasoning-effort` or `/effort`).
    pin,
    /// `agent.auto_thinking` runs the per-turn classifier; no single level.
    classifier,
    /// The active model's own `reasoning_effort` config.
    per_model,
    /// The use-case table in `sampling_profiles.zig` (thinking models only).
    sampling_profile,
    /// Nothing names an effort; the provider default wins.
    none,
};

const EffortResolution = struct {
    /// The deterministic level, when one is known before a turn runs. Null
    /// for the classifier (it decides per turn) and for "nothing set".
    level: ?config.ReasoningEffort,
    source: EffortSource,
};

/// The same precedence `classifyEffort` (pin, then classifier) and
/// `writeSamplingParams` (per-run, then model, then table) apply. Pure, so
/// the picker header is unit-testable without a terminal or a turn.
fn resolveEffort(cfg: *const config.Config, provider: *const config.Provider) EffortResolution {
    if (cfg.agent.reasoning_effort) |re| return .{ .level = re, .source = .pin };
    if (cfg.agent.auto_thinking) return .{ .level = null, .source = .classifier };
    const model = provider.activeModel();
    if (model.reasoning_effort) |re| return .{ .level = re, .source = .per_model };
    // The use-case table only names an effort for thinking models, and a
    // normal turn offers tools, so `.tool_use` is the representative row.
    const rec = sampling.profile(.tool_use, model.capabilities);
    if (rec.reasoning_effort) |re| {
        return .{ .level = config.ReasoningEffort.fromStr(re), .source = .sampling_profile };
    }
    return .{ .level = null, .source = .none };
}

fn effortSourceLabel(source: EffortSource) []const u8 {
    return switch (source) {
        .pin => "pinned (agent.reasoning_effort)",
        .classifier => "auto_thinking classifier",
        .per_model => "per-model config",
        .sampling_profile => "sampling profile",
        .none => "unset (provider default)",
    };
}

/// The six rows `/effort` shows: the five wire levels in order, then
/// `default`, which clears the pin back to null. Descriptions are static
/// string literals (read-only memory, never draw-stack), so the picker can
/// borrow them straight into cells.
const EffortChoice = union(enum) {
    level: config.ReasoningEffort,
    default,
};

const EffortOption = struct {
    choice: EffortChoice,
    /// Row text, static: "none", "low", "medium", "high", "max", "default".
    label: []const u8,
    /// Preview/detail line for the row. Static.
    description: []const u8,
};

const effort_options = [_]EffortOption{
    .{ .choice = .{ .level = .none }, .label = "none", .description = "no reasoning; fastest, cheapest answer" },
    .{ .choice = .{ .level = .low }, .label = "low", .description = "a short reasoning pass before answering" },
    .{ .choice = .{ .level = .medium }, .label = "medium", .description = "balanced reasoning depth" },
    .{ .choice = .{ .level = .high }, .label = "high", .description = "thorough reasoning for hard problems" },
    .{ .choice = .{ .level = .max }, .label = "max", .description = "maximum reasoning; slowest, most expensive" },
    .{ .choice = .default, .label = "default", .description = "clear the pin; back to classifier/model/profile" },
};

/// Which row `/effort` marks as current: a deterministic level when the
/// resolution names one, otherwise `default` (nothing is pinned). The pin
/// itself is cleared by the `default` choice, so an unpinned session always
/// highlights `default` unless a lower-precedence source still yields a
/// concrete level.
fn effortCurrentOption(res: EffortResolution) EffortChoice {
    if (res.level) |re| return .{ .level = re };
    return .default;
}

test "resolveEffort honours the classifyEffort precedence" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var p = try config.Provider.single(arena, "p", "https://p.test", .openai_compat, "m", .{});

    var cfg = config.Config{};
    try std.testing.expectEqual(EffortSource.none, (resolveEffort(&cfg, &p)).source);

    cfg.agent.reasoning_effort = .high;
    const pinned = resolveEffort(&cfg, &p);
    try std.testing.expectEqual(EffortSource.pin, pinned.source);
    try std.testing.expectEqual(config.ReasoningEffort.high, pinned.level.?);

    cfg.agent.reasoning_effort = null;
    cfg.agent.auto_thinking = true;
    try std.testing.expectEqual(EffortSource.classifier, (resolveEffort(&cfg, &p)).source);

    cfg.agent.auto_thinking = false;
    var it = p.models.iterator();
    it.next().?.value_ptr.reasoning_effort = .low;
    const per_model = resolveEffort(&cfg, &p);
    try std.testing.expectEqual(EffortSource.per_model, per_model.source);
    try std.testing.expectEqual(config.ReasoningEffort.low, per_model.level.?);
}

test "effort picker marks the resolved level, or default when unpinned" {
    const high = EffortResolution{ .level = .high, .source = .pin };
    try std.testing.expectEqual(EffortChoice{ .level = .high }, effortCurrentOption(high));

    const auto = EffortResolution{ .level = null, .source = .classifier };
    try std.testing.expectEqual(EffortChoice.default, effortCurrentOption(auto));
}

/// One row of the `/preset` picker: a `presets/<name>.toml` bundle plus its
/// `description` line. Built once at picker-open time into session-lifetime
/// arena memory (the same lifetime the model/command candidates already
/// have), so rows never borrow draw-stack cells.
const PresetCandidate = struct {
    name: []const u8,
    description: []const u8,
};

/// Lists `presets/*.toml` the same way the CLI's `preset list` does (every
/// `.toml` name, sorted), then loads each preset's `description` for the
/// picker preview line. A missing/unparseable file is skipped rather than
/// making the whole picker fail; the operator still sees the valid presets.
fn buildPresetCandidates(arena: std.mem.Allocator, io: std.Io) ![]const PresetCandidate {
    var list_dir = std.Io.Dir.cwd().openDir(io, "presets", .{ .iterate = true }) catch return &.{};
    defer list_dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = list_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;
        const name = entry.name[0 .. entry.name.len - 5];
        try names.append(arena, try arena.dupe(u8, name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    // The iterate handle and the read handle are separate capabilities; load
    // through a fresh read-only open the way the CLI's direct `/preset` path
    // does.
    var read_dir = std.Io.Dir.cwd().openDir(io, "presets", .{}) catch return &.{};
    defer read_dir.close(io);
    var out: std.ArrayList(PresetCandidate) = .empty;
    for (names.items) |name| {
        const preset = preset_mod.loadFromFile(io, arena, read_dir, name) catch continue;
        try out.append(arena, .{ .name = name, .description = preset.description });
    }
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------
// Slash-command registry: the single source of truth for what `submit`
// dispatches and what `/help` prints. Adding an entry here is the whole
// job, dispatch and the generated help list both derive from it, so a
// command can no longer ship undocumented (the hazard docs/prds/0005-repl-tui.md
// tracked against the old hand-maintained `printHelp` prose).
// ---------------------------------------------------------------------

/// What a matched command does. Commands with bespoke UI or plumbing get
/// their own arm that `runCommand` switches on; the internal `cmd_*` WASM
/// tools (the same ones the CLI subcommands invoke) share one `.tool` arm
/// carrying the tool name and its fixed argument string.
const CommandAction = union(enum) {
    quit,
    help,
    /// Opens the fuzzy provider/model picker, seeded with any args given.
    model,
    workflows,
    workflow,
    /// Starts a continuing goal loop (see `runGoalTask`).
    goal,
    /// Invokes the draft-only goal_write tool directly (see `runWriteGoal`).
    write_goal,
    /// Persists a structured goal without starting a run (see `runAddGoal`).
    add_goal,
    /// Prints usage, or runs the measurement loop as a normal agent task.
    autoresearch,
    /// Prints usage, or runs one judged debate as a normal agent task.
    arena,
    /// Prints usage, starts a blind comparison as an agent task, or reads a
    /// stored one back through the tool directly (see `runCompare`).
    compare,
    /// Lists themes (no args) or switches the active color theme for this
    /// session (with a name).
    theme,
    /// Toggle proposal-only runs for subsequent tasks (`/plan [on|off]`).
    plan,
    /// Switch preset bundle for next task (`/preset <name>`), blank-session only.
    preset,
    /// Pin the per-turn reasoning effort for this session (`/effort [level]`).
    effort,
    /// Toggle web-research runs for subsequent tasks (`/websearch [on|off]`).
    websearch,
    /// The research note store, same subcommands as `clanker research`.
    research,
    /// The RFC store, same subcommands as `clanker rfc`.
    rfc,
    /// Queue an image path for the next task submit (`/attach <path>`).
    attach,
    /// List TUI slash-command plugins, or enable/disable one in
    /// state/tui_plugins.json (PRD 0012). A plugin is off until enabled.
    tui_plugins,
    /// Runs the named internal `cmd_*` tool via `runInternalTool`.
    tool: struct {
        name: []const u8,
        args: []const u8,
        /// Forward non-empty slash-command arguments; the fixed args remain
        /// the no-argument default.
        forward_args: bool = false,
    },
};

/// One slash command the REPL understands.
const CommandSpec = struct {
    /// Primary spelling, leading slash included, matched exactly.
    name: []const u8,
    /// Alternate spellings, matched the same way ("?", bare "exit").
    aliases: []const []const u8 = &.{},
    /// Whether "<spelling> <args>" also matches, with the trimmed
    /// remainder handed to the action.
    takes_args: bool = false,
    /// Shown after the spellings in /help ("[query]", "<intent>"); purely
    /// documentation, not parsed.
    arg_hint: []const u8 = "",
    /// One line for the generated /help list. Never empty (tested).
    help: []const u8,
    action: CommandAction,
};

const command_registry = [_]CommandSpec{
    .{ .name = "/help", .aliases = &.{"?"}, .help = "show this help", .action = .help },
    .{ .name = "/model", .takes_args = true, .arg_hint = "[query]", .help = "switch provider/model (fuzzy picker; Enter picks, Esc cancels)", .action = .model },
    .{ .name = "/workflows", .help = "list reusable prompt workflows", .action = .workflows },
    .{ .name = "/workflow", .takes_args = true, .arg_hint = "<name> [args]", .help = "run a workflow (expands {{args}} then runs as a task)", .action = .workflow },
    .{ .name = "/sessions", .aliases = &.{"/history"}, .help = "list saved conversations", .action = .{ .tool = .{ .name = "sessions", .args = "" } } },
    .{ .name = "/search", .takes_args = true, .arg_hint = "<query>", .help = "search saved conversations (resume with --session)", .action = .{ .tool = .{ .name = "session_search", .args = "", .forward_args = true } } },
    .{ .name = "/graph", .takes_args = true, .arg_hint = "[run-id]", .help = "list runs or draw one as a timeline (same as clanker graph)", .action = .{ .tool = .{ .name = "graph", .args = "list", .forward_args = true } } },
    .{ .name = "/status", .help = "show instance identity and configured peers", .action = .{ .tool = .{ .name = "status", .args = "" } } },
    .{ .name = "/tools", .help = "list registered tools (same as clanker tools)", .action = .{ .tool = .{ .name = "tools", .args = "" } } },
    .{ .name = "/plugins", .aliases = &.{"/plugin"}, .takes_args = true, .arg_hint = "[on|off <name>]", .help = "list plugins or switch an optional one on or off", .action = .{ .tool = .{ .name = "plugins", .args = "", .forward_args = true } } },
    .{ .name = "/goal", .takes_args = true, .arg_hint = "<completion condition>", .help = "start a goal loop until achieved or blocked", .action = .goal },
    .{ .name = "/write-goal", .takes_args = true, .arg_hint = "<intent>", .help = "draft a structured goal without saving it", .action = .write_goal },
    .{ .name = "/add-goal", .takes_args = true, .arg_hint = "<objective> :: <completion criterion>", .help = "persist a structured goal without running it", .action = .add_goal },
    .{ .name = "/autoresearch", .takes_args = true, .arg_hint = "...", .help = "measurement loop (see /autoresearch --help)", .action = .autoresearch },
    .{ .name = "/arena", .takes_args = true, .arg_hint = "...", .help = "judged debate between two positions (see /arena --help)", .action = .arena },
    .{ .name = "/compare", .takes_args = true, .arg_hint = "...", .help = "one prompt to several models at once, answers unlabeled (see /compare --help)", .action = .compare },
    .{ .name = "/theme", .takes_args = true, .arg_hint = "[name]", .help = "list or switch color theme (mocha, latte, tokyonight, ...)", .action = .theme },
    .{ .name = "/plan", .takes_args = true, .arg_hint = "[on|off]", .help = "toggle plan mode (proposal only; write tools refused)", .action = .plan },
    .{ .name = "/preset", .takes_args = true, .arg_hint = "<name>", .help = "switch preset bundle (allowed tools + persona) for next task", .action = .preset },
    .{ .name = "/effort", .takes_args = true, .arg_hint = "[none|low|medium|high|max|default]", .help = "pin reasoning effort for every turn (picker with previews; default clears)", .action = .effort },
    .{ .name = "/websearch", .takes_args = true, .arg_hint = "[on|off]", .help = "toggle web-research mode (prefer web_search/web_fetch for current facts)", .action = .websearch },
    .{ .name = "/research", .takes_args = true, .arg_hint = "<sub> [args]", .help = "research notes, same store as clanker research: list, search, open, plan, sweep, create, append, update, status", .action = .research },
    .{ .name = "/rfc", .takes_args = true, .arg_hint = "<sub> [args]", .help = "open decisions, same store as clanker rfc: list, search, open, checklist, create, append, update, recommend, status", .action = .rfc },
    .{ .name = "/attach", .takes_args = true, .arg_hint = "<path>", .help = "queue an image for the next task submit", .action = .attach },
    .{ .name = "/quit", .aliases = &.{ "/exit", "/q", "exit", "quit" }, .help = "leave the REPL", .action = .quit },
    .{ .name = "/tui-plugins", .takes_args = true, .arg_hint = "[on|off <name>]", .help = "list TUI slash-command plugins, or enable/disable one (PRD 0012)", .action = .tui_plugins },
};

/// Slash commands appended from tui-plugins/*.json at REPL startup (PRD 0012
/// Goal 2). Each dispatches to a sandboxed tool, so there is no new trust
/// surface; see slash_plugins.zig. Empty (comptime-known) in tests, so every
/// existing registry test keeps its exact expectations.
var plugin_command_specs: []const CommandSpec = &.{};

const arena_command_help =
    \\usage: /arena "<question>" --for "<stance>" --against "<stance>"
    \\       [--rounds N] [--judge self|third]
    \\       /arena "<question>" --position "<stance>" --position "<stance>"
    \\       [--position "<stance>"]...
    \\       /arena "<question>" --defend <text|file> --alternative <text|file>
    \\  pairwise debates accept --for-provider, --against-provider, and
    \\  --judge-provider
    \\  battle royale repeats --position 3-8 times; HP loss eliminates
    \\  combatants until one remains
    \\  design review reads file arguments and preserves their paths in the verdict
    \\  each round is one model call per survivor, plus judge calls with
    \\  --judge third
;

const compare_command_help =
    \\usage: /compare "<prompt>" [--with <provider[@model]>]...
    \\       [--judge <p>|auto|none] [--synthesize] [--reveal]
    \\  every model answers the same prompt at once; the answers come back as A, B, C
    \\  with nothing saying which model wrote which, so the pick is on the answer
    \\  --with repeats 2-8 times; with none, every configured provider enters
    \\  --synthesize adds a merged answer; --reveal prints the label-to-model key
    \\  /compare --list                    past comparisons
    \\  /compare --show <id> [--pick <A>]  read one back, and record your pick
    \\  example: /compare "rewrite this error message" --with deepseek --with kimi-k3
;

test "TUI arena and compare help cover their CLI modes" {
    const arena_flags = [_][]const u8{ "--position", "--defend", "--alternative", "--judge-provider" };
    for (arena_flags) |flag| {
        try std.testing.expect(std.mem.find(u8, arena_command_help, flag) != null);
    }
    const compare_flags = [_][]const u8{ "--synthesize", "--reveal", "--show", "--pick" };
    for (compare_flags) |flag| {
        try std.testing.expect(std.mem.find(u8, compare_command_help, flag) != null);
    }
}

test "static REPL help blocks stay within 80 display columns" {
    for ([_][]const u8{ arena_command_help, compare_command_help, shell_escape_help, keys_help }) |block| {
        var lines = std.mem.splitScalar(u8, block, '\n');
        while (lines.next()) |line| {
            const width = width_mod.displayWidth(line);
            if (width > 80) {
                std.debug.print("static REPL help line is {d} columns: {s}\n", .{ width, line });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "key help documents discovery search scroll and editing" {
    for ([_][]const u8{ "Tab", "Ctrl-P", "Ctrl-R", "PgUp/PgDn", "Ctrl-C", "Ctrl-Shift-C", "Ctrl-Shift-V", "Ctrl-U/K/W" }) |key| {
        try std.testing.expect(std.mem.find(u8, keys_help, key) != null);
    }
}

/// One row of the command palette: a registry entry with its display row and
/// the text the fuzzy filter matches against, both built once at startup.
///
/// `haystack` is deliberately wider than the label: it carries every
/// spelling *and* the help text, so the palette answers "what was the
/// command for switching models" as readily as "/mod". That is the whole
/// point of having it next to Tab-complete, which can only ever extend a
/// prefix of a name you already remember.
const CommandCandidate = struct {
    spec: *const CommandSpec,
    label: []const u8,
    haystack: []const u8,
};

/// Flattens `command_registry` into palette rows, in registry order (the
/// same order `/help` lists them, so the unfiltered palette reads as the
/// help screen it is drawn from).
///
/// Built once into session-lifetime memory rather than per keystroke: vaxis
/// cells borrow the label slices until the frame is flushed, so a row must
/// not point into a draw function's stack, and the registry cannot change at
/// runtime.
fn buildCommandCandidates(arena: std.mem.Allocator) ![]const CommandCandidate {
    var out: std.ArrayList(CommandCandidate) = .empty;
    for (&command_registry) |*spec| try appendCommandCandidate(arena, &out, spec);
    for (plugin_command_specs) |*spec| try appendCommandCandidate(arena, &out, spec);
    return out.toOwnedSlice(arena);
}

/// One palette row, shared by the static registry and TUI plugin commands so
/// a plugin row is byte-identical in shape to a built-in one.
fn appendCommandCandidate(arena: std.mem.Allocator, out: *std.ArrayList(CommandCandidate), spec: *const CommandSpec) !void {
    var names: std.ArrayList(u8) = .empty;
    try names.appendSlice(arena, spec.name);
    for (spec.aliases) |alias| {
        try names.appendSlice(arena, ", ");
        try names.appendSlice(arena, alias);
    }
    if (spec.arg_hint.len > 0) {
        try names.append(arena, ' ');
        try names.appendSlice(arena, spec.arg_hint);
    }
    var label: std.ArrayList(u8) = .empty;
    try label.appendSlice(arena, names.items);
    var col = width_mod.displayWidth(names.items);
    while (col < help_names_width + 2) : (col += 1) try label.append(arena, ' ');
    try label.appendSlice(arena, spec.help);
    try out.append(arena, .{
        .spec = spec,
        .label = try label.toOwnedSlice(arena),
        .haystack = try std.fmt.allocPrint(arena, "{s} {s}", .{ names.items, spec.help }),
    });
}

test "buildCommandCandidates covers the registry and matches on name or description" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cands = try buildCommandCandidates(arena);
    try std.testing.expectEqual(command_registry.len, cands.len);

    // Every row shows its spelling and its help line, so the palette is
    // readable without cross-referencing /help.
    for (cands, 0..) |c, i| {
        try std.testing.expect(std.mem.find(u8, c.label, command_registry[i].name) != null);
        try std.testing.expect(std.mem.find(u8, c.label, command_registry[i].help) != null);
    }

    // Find by name, the way Tab-complete already can...
    const model = for (cands) |c| {
        if (c.spec.action == .model) break c;
    } else return error.TestExpectedModel;
    try std.testing.expect(fuzzyMatch("model", model.haystack));
    // ...by a mid-word fragment, which Tab-complete cannot...
    try std.testing.expect(fuzzyMatch("mdl", model.haystack));
    // ...and by what the command does, which is the reason for the palette.
    try std.testing.expect(fuzzyMatch("switch", model.haystack));

    // An alias is matchable too: /quit carries "exit".
    const quit = for (cands) |c| {
        if (c.spec.action == .quit) break c;
    } else return error.TestExpectedQuit;
    try std.testing.expect(fuzzyMatch("exit", quit.haystack));

    // Nonsense still matches nothing.
    for (cands) |c| try std.testing.expect(!fuzzyMatch("zzqqxx", c.haystack));
}

/// A registry hit: which entry matched, plus whatever followed the
/// matched spelling (trimmed; empty when nothing did).
const ParsedCommand = struct {
    spec: *const CommandSpec,
    args: []const u8,
};

/// Matches `input` against one spelling of `spec`: exact, or
/// "<spelling> <args>" when the spec takes arguments. Returns the trimmed
/// remainder on a match, null otherwise ("/modelx" must not match "/model").
fn matchSpelling(spec: *const CommandSpec, spelling: []const u8, input: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, input, spelling)) return "";
    if (spec.takes_args and input.len > spelling.len and
        std.mem.startsWith(u8, input, spelling) and input[spelling.len] == ' ')
    {
        return std.mem.trim(u8, input[spelling.len..], " ");
    }
    return null;
}

/// Registry lookup for a submitted line: trims, then tries every spelling
/// of every entry. Null means "not a command", bare text is a task for the
/// agent, and `submit` reports unrecognized /slash input instead of sending
/// it (see `looksLikeSlashCommand`).
fn parseCommand(task: []const u8) ?ParsedCommand {
    const input = std.mem.trim(u8, task, " \t");
    for (&command_registry) |*spec| {
        if (matchSpelling(spec, spec.name, input)) |args| return .{ .spec = spec, .args = args };
        for (spec.aliases) |alias| {
            if (matchSpelling(spec, alias, input)) |args| return .{ .spec = spec, .args = args };
        }
    }
    // TUI plugin commands (PRD 0012) are matched after the built-ins, so a
    // plugin can never shadow one; dispatch needs no new arm, it rides the
    // same `.tool` action a built-in tool-dispatching command uses.
    for (plugin_command_specs) |*spec| {
        if (matchSpelling(spec, spec.name, input)) |args| return .{ .spec = spec, .args = args };
    }
    return null;
}

const AddGoalArgs = struct {
    objective: []const u8,
    completion_criterion: []const u8,
};

/// Splits `/add-goal`'s two required fields without pretending the rest of the
/// TUI input is a shell command. The spaced delimiter makes an objective that
/// contains `::` unambiguous unless the user deliberately types the delimiter.
fn splitAddGoalArgs(args: []const u8) ?AddGoalArgs {
    const delimiter = " :: ";
    const at = std.mem.find(u8, args, delimiter) orelse return null;
    const objective = std.mem.trim(u8, args[0..at], " \t");
    const completion_criterion = std.mem.trim(u8, args[at + delimiter.len ..], " \t");
    if (objective.len == 0 or completion_criterion.len == 0) return null;
    return .{ .objective = objective, .completion_criterion = completion_criterion };
}

// ---------------------------------------------------------------------
// `/compare`, which is two commands wearing one name.
//
// Starting a comparison is N model calls that want to stream, so it goes
// through an agent turn the way `/arena` does. Reading one back is a
// read of state/compare/<id>.json and nothing else: routing that through
// the model would cost a completion, take seconds, and put a paraphraser
// between the reader and a document whose whole point is that its
// wording was not chosen by any of the models in it. So the read paths
// call the tool directly and print what it returns.
// ---------------------------------------------------------------------

/// Which half of `/compare` a line asked for.
const CompareCommand = union(enum) {
    /// No arguments, or an explicit --help.
    usage,
    /// `--list`: every stored comparison.
    list,
    /// `--show <id>`, optionally with `--pick <letter>` to record a pick.
    show: struct { id: []const u8, pick: []const u8 = "" },
    /// Anything else: a prompt (plus flags) to put to several models.
    run,
};

/// Sorts a `/compare` line into the four cases above. Pure, so the routing
/// is testable without a terminal, a config or a provider. Slices borrow
/// from `argv`. A `--show` or `--pick` with nothing after it falls back to
/// usage rather than guessing: `--show` alone would otherwise become a run
/// whose prompt is the word "--show", which is a paid model call for a typo.
fn parseCompareCommand(argv: []const []const u8) CompareCommand {
    if (argv.len == 0) return .usage;
    if (std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "-h")) return .usage;

    var id: []const u8 = "";
    var pick: []const u8 = "";
    var saw_list = false;
    var saw_show = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--list")) {
            saw_list = true;
        } else if (std.mem.eql(u8, argv[i], "--show")) {
            saw_show = true;
            if (i + 1 >= argv.len) return .usage;
            i += 1;
            id = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--pick")) {
            if (i + 1 >= argv.len) return .usage;
            i += 1;
            pick = argv[i];
        }
    }
    // --show wins over --list: it is the more specific of the two, and asking
    // for one comparison by id while also asking for the listing is a line
    // that cannot mean the listing.
    if (saw_show) return .{ .show = .{ .id = id, .pick = pick } };
    if (saw_list) return .list;
    // `--pick` on its own has no comparison to record against.
    if (pick.len > 0) return .usage;
    return .run;
}

// ---------------------------------------------------------------------
// `!cmd`, the inline shell escape. A third input mode next to the
// slash commands above and a task for the agent: the line runs locally,
// right now, and nothing about it is sent to the LLM.
//
// It is not a shell. `!` builds one fixed argv and hands it to
// `host.execUnderPolicy`, the non-WASM entry point to the same ck_exec
// gate every tool goes through, the command must be on an allowlist,
// the deny tokens still apply, and the child gets the filtered
// environment a guest gets rather than this process's (which holds the
// API keys). Nothing expands globs, `$VAR`, pipes or redirections,
// because no shell is ever spawned to expand them.
// ---------------------------------------------------------------------

/// The text after a leading `!`, or null when the line is not a shell escape.
/// Whitespace is trimmed on both sides of the `!`, so `  !  git status  ` and
/// `!git status` are the same command. A bare `!` (or one followed only by
/// spaces) returns an empty slice rather than null: it *is* a shell escape,
/// just one with nothing to run, and `runShellEscape` answers it with usage
/// plus the list of commands the escape may run. A `!` anywhere but the first
/// column is ordinary text and stays a task.
fn parseShellEscape(task: []const u8) ?[]const u8 {
    const input = std.mem.trim(u8, task, " \t");
    if (input.len == 0 or input[0] != '!') return null;
    return std.mem.trim(u8, input[1..], " \t");
}

/// Comfortably more arguments than a hand-typed command line carries. Past
/// this the line is refused rather than silently truncated, a command run
/// with half its arguments is worse than one that did not run.
const max_escape_args = 64;

const ShellSplitError = error{ TooManyArgs, UnterminatedQuote };

/// Splits a `!` line into argv without a shell. Whitespace separates
/// arguments; an argument that *starts* with `'` or `"` runs to the matching
/// quote, so `!rg "foo bar" src` is three arguments. A quote inside an
/// otherwise unquoted argument is literal, and there are no backslash escapes
///, the grammar is deliberately the smallest one that lets a quoted argument
/// hold a space, not a re-implementation of shell word splitting that would
/// invite the expansions this path does not do.
///
/// Every returned slice borrows from `line`.
fn splitShellArgs(line: []const u8, out: *[max_escape_args][]const u8) ShellSplitError![]const []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i >= line.len) break;
        if (n == out.len) return error.TooManyArgs;
        if (line[i] == '\'' or line[i] == '"') {
            const quote = line[i];
            i += 1;
            const end = std.mem.findScalarPos(u8, line, i, quote) orelse return error.UnterminatedQuote;
            out[n] = line[i..end];
            i = end + 1;
        } else {
            const start = i;
            while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
            out[n] = line[start..i];
        }
        n += 1;
    }
    return out[0..n];
}

/// Output a `!` command may produce before it is cut, matching what ck_exec
/// gives a guest, the escape has no reason to be more or less generous than
/// the tools.
const escape_stdout_limit = 1 << 20;
const escape_stderr_limit = 64 * 1024;

/// Transcript lines one local command may contribute. Both `!git log` and
/// shared internal tools such as `/graph` can otherwise push the conversation
/// off the top of a scrollback nobody asked to page through.
const command_output_max_lines = 200;

fn fullCliCommand(tool_name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, tool_name, "sessions")) return "clanker sessions";
    if (std.mem.eql(u8, tool_name, "graph")) return "clanker graph";
    if (std.mem.eql(u8, tool_name, "tools")) return "clanker tools";
    if (std.mem.eql(u8, tool_name, "plugins")) return "clanker plugins";
    return null;
}

/// Adds sanitized internal-tool text to the transcript under the same line
/// budget as `!` output. Returns whether anything was omitted.
fn appendInternalToolOutput(arena: std.mem.Allocator, lines: *std.ArrayList(Line), tool_name: []const u8, text: []const u8) bool {
    const normalized = std.mem.trimEnd(u8, text, "\r\n");
    if (normalized.len == 0) {
        lines.append(arena, .{ .text = "notice: command returned no output", .dim = true }) catch {};
        return false;
    }
    var it = std.mem.splitScalar(u8, normalized, '\n');
    var count: usize = 0;
    while (it.next()) |line| {
        if (count == command_output_max_lines) {
            const notice = if (fullCliCommand(tool_name)) |cmd|
                std.fmt.allocPrint(arena, "notice: output truncated after {d} lines; run `{s}` for complete output", .{ command_output_max_lines, cmd }) catch "notice: output truncated"
            else
                std.fmt.allocPrint(arena, "notice: output truncated after {d} lines", .{command_output_max_lines}) catch "notice: output truncated";
            lines.append(arena, .{ .text = notice, .dim = true }) catch {};
            return true;
        }
        const trimmed = std.mem.trim(u8, line, " \t\r");
        lines.append(arena, .{ .text = arena.dupe(u8, trimmed) catch trimmed, .dim = true }) catch {};
        count += 1;
    }
    return false;
}

test "internal slash-command output is bounded and names the full CLI escape hatch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    for (0..command_output_max_lines + 1) |i| {
        if (i > 0) try source.append(std.testing.allocator, '\n');
        try source.appendSlice(std.testing.allocator, "row");
    }
    var lines: std.ArrayList(Line) = .empty;
    try std.testing.expect(appendInternalToolOutput(arena, &lines, "graph", source.items));
    try std.testing.expectEqual(command_output_max_lines + 1, lines.items.len);
    try std.testing.expectEqualStrings("row", lines.items[command_output_max_lines - 1].text);
    try std.testing.expectEqualStrings("notice: output truncated after 200 lines; run `clanker graph` for complete output", lines.items[command_output_max_lines].text);

    var empty: std.ArrayList(Line) = .empty;
    try std.testing.expect(!appendInternalToolOutput(arena, &empty, "status", "\n"));
    try std.testing.expectEqualStrings("notice: command returned no output", empty.items[0].text);
}

fn lessThanCmd(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The `!` escape's line in `/help`. Hand-written rather than a
/// `command_registry` entry on purpose: a `CommandSpec` matches a spelling
/// either exactly or followed by a space, and `!git status` has no space after
/// the `!`, so no registry entry can express it. Keeping it out of the
/// registry also keeps `buildCommandHelp`'s "every entry is a `/command`"
/// shape intact.
const shell_escape_help =
    \\Shell escape:
    \\  !<command>        run it here, now, under the same ck_exec policy the
    \\                    tools run under, not a shell, so no pipes, globs,
    \\                    redirections or $VAR expansion
    \\  !                 list the commands the escape may run
;

const keys_help =
    \\Keys:
    \\  Shift-Enter       insert a line break; the box grows one row per
    \\                    line (keypad Enter does the same)
    \\  Tab               complete a /command (typing / already previews
    \\                    the matches above the box, with their help)
    \\  Ctrl-P            command palette (matches names and descriptions)
    \\  Ctrl-R            search transcript; Up/Down step through matches
    \\                    Enter stays on a match; Esc returns to the tail
    \\  Up/Down           move between draft lines, then recall history
    \\                    at the edges
    \\  PgUp/PgDn         page transcript (Home: top; End/Esc: tail)
    \\  Ctrl-C            stop the current turn, or quit when idle
    \\  Ctrl-Shift-C      copy the selection (or the input line)
    \\                    the hosting terminal may intercept Ctrl-Shift-C
    \\  Ctrl-Shift-V, Shift-Insert   paste from the system clipboard
    \\  Ctrl-U/K/W, Ctrl-Y   kill to start/end/word, then yank
    \\  mouse wheel       scroll the transcript, or the draft when the
    \\                    pointer is over the input box
    \\  mouse drag        select text, transcript or input box (copies on
    \\                    release)
    \\  click ▸/▾ reply   fold a long reply out or back in
    \\  Shift+drag        the terminal's own selection (bypasses clanker)
;

/// True for a submitted line with no content: empty, or only whitespace.
/// The whitespace set matches the one `steerWhileRunning` uses, so the same
/// line is refused whether it is typed against an idle prompt or a running
/// turn, rather than being a task in one case and nothing in the other.
fn isBlankSubmission(task: []const u8) bool {
    return std.mem.trim(u8, task, " \t\r\n").len == 0;
}

test "isBlankSubmission refuses empty and whitespace-only lines" {
    try std.testing.expect(isBlankSubmission(""));
    try std.testing.expect(isBlankSubmission(" "));
    try std.testing.expect(isBlankSubmission("   \t  "));
    try std.testing.expect(isBlankSubmission("\r\n"));

    // Anything with content is a task, including lines that merely start or
    // end with whitespace: those still had something typed on them.
    try std.testing.expect(!isBlankSubmission("hi"));
    try std.testing.expect(!isBlankSubmission("  indented task  "));
    try std.testing.expect(!isBlankSubmission("/help"));
    try std.testing.expect(!isBlankSubmission("!"));
    // A bare punctuation mark is content, not blank: `!` alone is the shell
    // escape's own usage listing and must still reach runShellEscape.
    try std.testing.expect(!isBlankSubmission("  !  "));
}

test "parseModeToggle accepts on/off and rejects unknown tokens" {
    try std.testing.expectEqual(@as(?bool, true), parseModeToggle("on"));
    try std.testing.expectEqual(@as(?bool, false), parseModeToggle("off"));
    try std.testing.expectEqual(@as(?bool, true), parseModeToggle(" ON "));
    try std.testing.expectEqual(@as(?bool, true), parseModeToggle("enable"));
    try std.testing.expectEqual(@as(?bool, false), parseModeToggle("disable"));
    try std.testing.expectEqual(@as(?bool, null), parseModeToggle(""));
    try std.testing.expectEqual(@as(?bool, null), parseModeToggle("maybe"));
}

/// True for input that was clearly meant as a slash command (leading '/'):
/// when the registry lookup missed, this is what keeps a typo'd command out
/// of the LLM conversation. Bare text without the slash stays a task.
fn looksLikeSlashCommand(task: []const u8) bool {
    const input = std.mem.trim(u8, task, " \t");
    return input.len > 0 and input[0] == '/';
}

fn suggestSlashCommand(input: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t");
    if (trimmed.len == 0) return null;
    var best: ?[]const u8 = null;
    var best_distance: usize = 3;
    for (&command_registry) |*spec| {
        const d = edit_distance.typoDistance(trimmed, spec.name);
        if (d < best_distance) {
            best = spec.name;
            best_distance = d;
        }
        for (spec.aliases) |alias| {
            const da = edit_distance.typoDistance(trimmed, alias);
            if (da < best_distance) {
                best = alias;
                best_distance = da;
            }
        }
    }
    for (plugin_command_specs) |*spec| {
        const d = edit_distance.typoDistance(trimmed, spec.name);
        if (d < best_distance) {
            best = spec.name;
            best_distance = d;
        }
    }
    return best;
}

/// Matches the CLI diagnostic grammar while keeping the recovery action
/// native to this surface (`/help` rather than `clanker --help`).
fn unknownSlashCommandText(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
    const typed = std.mem.trim(u8, input, " \t");
    if (suggestSlashCommand(typed)) |suggestion| {
        return std.fmt.allocPrint(alloc, "error: unknown command '{s}'; did you mean `{s}`?", .{ typed, suggestion });
    }
    return std.fmt.allocPrint(alloc, "error: unknown command '{s}'; try `/help`", .{typed});
}

/// One registry spelling that matched a Tab-complete prefix, paired with
/// the spec it belongs to (needed to know `takes_args` when a single match
/// completes the line).
const SpellingMatch = struct { spelling: []const u8, spec: *const CommandSpec };

/// Comfortably above the registry's total spelling count (name + aliases,
/// currently under 20); completion is a UI nicety, so silently truncating
/// past this is fine rather than worth an allocator.
const max_completions = 32;

/// Every registry spelling (name or alias) starting with `prefix`, in
/// registry order. Written into `out`; returns the matched slice.
fn matchingSpellings(prefix: []const u8, out: *[max_completions]SpellingMatch) []const SpellingMatch {
    var n: usize = 0;
    for (&command_registry) |*spec| {
        if (n < out.len and std.mem.startsWith(u8, spec.name, prefix)) {
            out[n] = .{ .spelling = spec.name, .spec = spec };
            n += 1;
        }
        for (spec.aliases) |alias| {
            if (n < out.len and std.mem.startsWith(u8, alias, prefix)) {
                out[n] = .{ .spelling = alias, .spec = spec };
                n += 1;
            }
        }
    }
    for (plugin_command_specs) |*spec| {
        if (n < out.len and std.mem.startsWith(u8, spec.name, prefix)) {
            out[n] = .{ .spelling = spec.name, .spec = spec };
            n += 1;
        }
    }
    return out[0..n];
}

/// The longest prefix shared by every match, for completing "/s" toward
/// "/sessions" without picking one of several candidates arbitrarily.
fn longestCommonPrefix(matches: []const SpellingMatch) []const u8 {
    if (matches.len == 0) return "";
    var prefix = matches[0].spelling;
    for (matches[1..]) |m| {
        var i: usize = 0;
        while (i < prefix.len and i < m.spelling.len and prefix[i] == m.spelling[i]) : (i += 1) {}
        prefix = prefix[0..i];
    }
    return prefix;
}

/// How many rows the inline command preview may claim above the composer.
/// The panel is a glance at what the draft could become, not a browser —
/// the full list lives behind Ctrl-P — so past the cap the last row turns
/// into a "more" pointer instead of the panel growing.
const max_preview_rows = 8;

/// The inline command preview: which registry entries the composer's current
/// draft could become, recomputed from the draft text every frame so `/go`
/// shows `/goal` and its help before Tab or Enter is pressed. Two modes:
/// a bare `/prefix` lists every command with a spelling starting with it,
/// deduplicated by entry (`/q` matches both `/quit` and its `/q` alias, one
/// row), and `/command <args...>` keeps that one command's row on screen as
/// a signature hint while its arguments are being typed. A draft holding a
/// line break is a task in the making, never a command (`submit` would not
/// dispatch it), so it previews nothing.
fn commandPreviewSpecs(input: []const u8, out: *[max_completions]*const CommandSpec) []const *const CommandSpec {
    if (std.mem.find(u8, input, newline_marker) != null) return out[0..0];
    const trimmed = std.mem.trimStart(u8, input, " \t");
    if (!looksLikeSlashCommand(trimmed)) return out[0..0];
    if (std.mem.findScalar(u8, trimmed, ' ')) |sp| {
        const pc = parseCommand(trimmed[0..sp]) orelse return out[0..0];
        out[0] = pc.spec;
        return out[0..1];
    }
    var buf: [max_completions]SpellingMatch = undefined;
    var n: usize = 0;
    for (matchingSpellings(trimmed, &buf)) |m| {
        const seen = for (out[0..n]) |prev| {
            if (prev == m.spec) break true;
        } else false;
        if (!seen and n < out.len) {
            out[n] = m.spec;
            n += 1;
        }
    }
    return out[0..n];
}

/// Widest "spellings [hint]" cell in the registry, computed at comptime so
/// the generated help columns stay aligned no matter what gets added.
const help_names_width = blk: {
    var w: usize = 0;
    for (command_registry) |spec| {
        var n = spec.name.len;
        for (spec.aliases) |a| n += 2 + a.len;
        if (spec.arg_hint.len > 0) n += 1 + spec.arg_hint.len;
        if (n > w) w = n;
    }
    break :blk w;
};

/// The command section of `/help`, generated from `command_registry`: one
/// line per entry, every spelling comma-separated, the arg hint, then the
/// help text in a common column. Returned as one newline-joined slice the
/// caller owns.
fn buildCommandHelp(alloc: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "Commands:");
    // A plugin command's wider name must not misalign the help column, so the
    // width is the max over built-ins *and* loaded plugins, not the comptime
    // built-in-only constant. Cheaper than it looks: once per /help.
    var help_width = help_names_width;
    for (plugin_command_specs) |spec| {
        var n = spec.name.len;
        for (spec.aliases) |a| n += 2 + a.len;
        if (spec.arg_hint.len > 0) n += 1 + spec.arg_hint.len;
        if (n > help_width) help_width = n;
    }
    for (&command_registry) |*spec| try appendHelpRow(alloc, &out, spec, help_width);
    for (plugin_command_specs) |*spec| try appendHelpRow(alloc, &out, spec, help_width);
    return out.toOwnedSlice(alloc);
}

/// One /help row, shared by the static registry and TUI plugin commands.
fn appendHelpRow(alloc: std.mem.Allocator, out: *std.ArrayList(u8), spec: *const CommandSpec, help_width: usize) !void {
    try out.appendSlice(alloc, "\n  ");
    // Include the row's two-space indent in the display-column budget;
    // omitting it let nominally 80-column rows render at 82.
    var col: usize = 2 + spec.name.len;
    try out.appendSlice(alloc, spec.name);
    for (spec.aliases) |alias| {
        try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, alias);
        col += 2 + alias.len;
    }
    if (spec.arg_hint.len > 0) {
        try out.append(alloc, ' ');
        try out.appendSlice(alloc, spec.arg_hint);
        col += 1 + spec.arg_hint.len;
    }
    while (col < 2 + help_width + 2) : (col += 1) try out.append(alloc, ' ');
    var words = std.mem.tokenizeScalar(u8, spec.help, ' ');
    var first = true;
    while (words.next()) |word| {
        const word_width = width_mod.displayWidth(word);
        const gap: usize = if (first) 0 else 1;
        if (!first and col + gap + word_width > 80) {
            // Continuations use a shallow hanging indent rather than the
            // full command column. On a 40-column terminal this leaves
            // 36 useful columns instead of wrapping prose eight columns
            // at a time beneath the wide spelling column.
            try out.appendSlice(alloc, "\n    ");
            col = 4;
            first = true;
        }
        if (!first) {
            try out.append(alloc, ' ');
            col += 1;
        }
        try out.appendSlice(alloc, word);
        col += word_width;
        first = false;
    }
}

test "every command registry entry is documented" {
    for (command_registry) |spec| {
        try std.testing.expect(spec.name.len > 0);
        try std.testing.expect(spec.help.len > 0);
    }
}

test "generated help mentions every command spelling and help line" {
    const text = try buildCommandHelp(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "Commands:\n"));
    for (command_registry) |spec| {
        try std.testing.expect(std.mem.find(u8, text, spec.name) != null);
        for (spec.aliases) |alias| {
            try std.testing.expect(std.mem.find(u8, text, alias) != null);
        }
        var words = std.mem.tokenizeScalar(u8, spec.help, ' ');
        while (words.next()) |word| try std.testing.expect(std.mem.find(u8, text, word) != null);
    }
}

test "generated command help stays within 80 columns" {
    const text = try buildCommandHelp(std.testing.allocator);
    defer std.testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const width = width_mod.displayWidth(line);
        if (width > 80) {
            std.debug.print("REPL help line is {d} columns: {s}\n", .{ width, line });
            return error.TestUnexpectedResult;
        }
    }
}

test "tools command routes through the same internal tool as the CLI" {
    const pc = parseCommand("/tools") orelse return error.TestExpectedCommand;
    switch (pc.spec.action) {
        .tool => |tool| {
            try std.testing.expectEqualStrings("tools", tool.name);
            try std.testing.expectEqualStrings("", tool.args);
        },
        else => return error.TestExpectedToolCommand,
    }
}

test "REPL accepts the CLI aliases for sessions and plugins" {
    const cases = [_]struct { input: []const u8, tool: []const u8 }{
        .{ .input = "/history", .tool = "sessions" },
        .{ .input = "/plugin", .tool = "plugins" },
    };
    for (cases) |case| {
        const pc = parseCommand(case.input) orelse return error.TestExpectedCommand;
        switch (pc.spec.action) {
            .tool => |tool| try std.testing.expectEqualStrings(case.tool, tool.name),
            else => return error.TestExpectedToolCommand,
        }
    }
}

/// Splits one REPL command line into words, honoring double quotes ("a b" is
/// one token) so `/research create slug "A title" "The question?"` carries
/// multi-word arguments the way the shell does for the CLI. No escape
/// syntax: the composer is one line, and a quote inside a word ends the
/// group. Pure and arena-allocated, so the picker/test can call it directly.
fn splitCommandLine(arena: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i >= line.len) break;
        if (line[i] == '"') {
            const start = i + 1;
            var end = start;
            while (end < line.len and line[end] != '"') end += 1;
            try out.append(arena, line[start..end]);
            i = if (end < line.len) end + 1 else end;
        } else {
            const start = i;
            while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
            try out.append(arena, line[start..i]);
        }
    }
    return out.items;
}

test "splitCommandLine honors double quotes and collapses whitespace" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plain = try splitCommandLine(arena, "search embedded kv");
    try std.testing.expectEqual(@as(usize, 3), plain.len);
    try std.testing.expectEqualStrings("search", plain[0]);

    const quoted = try splitCommandLine(arena, "create embedded-kv \"Embedded KV stores\" \"Which one fits?\"");
    try std.testing.expectEqual(@as(usize, 4), quoted.len);
    try std.testing.expectEqualStrings("Embedded KV stores", quoted[2]);
    try std.testing.expectEqualStrings("Which one fits?", quoted[3]);

    const empty_quote = try splitCommandLine(arena, "update p \"old\" \"\"");
    try std.testing.expectEqual(@as(usize, 4), empty_quote.len);
    try std.testing.expectEqualStrings("", empty_quote[3]);

    const unterminated = try splitCommandLine(arena, "search \"half open");
    try std.testing.expectEqual(@as(usize, 2), unterminated.len);
    try std.testing.expectEqualStrings("half open", unterminated[1]);

    try std.testing.expectEqual(@as(usize, 0), (try splitCommandLine(arena, "   ")).len);
}

test "/research is the record store and /websearch is the mode toggle" {
    const store = parseCommand("/research search embedded") orelse return error.TestExpectedCommand;
    try std.testing.expect(store.spec.action == .research);
    try std.testing.expectEqualStrings("search embedded", store.args);

    const toggle = parseCommand("/websearch on") orelse return error.TestExpectedCommand;
    try std.testing.expect(toggle.spec.action == .websearch);
}

test "/rfc is the RFC store, same surface as clanker rfc" {
    const store = parseCommand("/rfc search \"http client\"") orelse return error.TestExpectedCommand;
    try std.testing.expect(store.spec.action == .rfc);
    try std.testing.expectEqualStrings("search \"http client\"", store.args);

    const bare = parseCommand("/rfc") orelse return error.TestExpectedCommand;
    try std.testing.expect(bare.spec.action == .rfc);
    try std.testing.expectEqualStrings("", bare.args);
}

test "plugins command forwards its documented toggle arguments" {
    const pc = parseCommand("/plugins off translate") orelse return error.TestExpectedCommand;
    try std.testing.expectEqualStrings("off translate", pc.args);
    switch (pc.spec.action) {
        .tool => |tool| {
            try std.testing.expectEqualStrings("plugins", tool.name);
            try std.testing.expect(tool.forward_args);
        },
        else => return error.TestExpectedToolCommand,
    }
}

test "graph command accepts the CLI run-id shape and keeps list as its default" {
    const listed = parseCommand("/graph") orelse return error.TestExpectedCommand;
    switch (listed.spec.action) {
        .tool => |tool| {
            try std.testing.expectEqualStrings("graph", tool.name);
            try std.testing.expectEqualStrings("list", tool.args);
            try std.testing.expect(tool.forward_args);
        },
        else => return error.TestExpectedToolCommand,
    }

    const rendered = parseCommand("/graph run-123") orelse return error.TestExpectedCommand;
    try std.testing.expectEqualStrings("run-123", rendered.args);
}

test "parseCommand recognizes the REPL quit set" {
    const quit_spellings = [_][]const u8{ "/quit", "/exit", "/q", "exit", "quit", "  /q  " };
    for (quit_spellings) |s| {
        const pc = parseCommand(s) orelse return error.TestExpectedCommand;
        try std.testing.expect(pc.spec.action == .quit);
    }
    // A leading slash distinguishes a command from the same word as a task;
    // a bare word that is not a quit command is a task.
    try std.testing.expect(parseCommand("/quitnow") == null);
    try std.testing.expect(parseCommand("exit handling is next") == null);
    try std.testing.expect(parseCommand("") == null);
    try std.testing.expect(parseCommand("please exit") == null);
    // Quit takes no arguments, so "/quit now" is not a quit command.
    try std.testing.expect(parseCommand("/quit now") == null);
}

test "parseCommand matches names, aliases, and arguments" {
    const help = parseCommand("/help") orelse return error.TestExpectedCommand;
    try std.testing.expect(help.spec.action == .help);
    const qmark = parseCommand("?") orelse return error.TestExpectedCommand;
    try std.testing.expect(qmark.spec.action == .help);
    // "?" takes no args: "? something" is a task, not a help request.
    try std.testing.expect(parseCommand("? something") == null);

    const bare_model = parseCommand("/model") orelse return error.TestExpectedCommand;
    try std.testing.expect(bare_model.spec.action == .model);
    try std.testing.expectEqualStrings("", bare_model.args);
    const seeded = parseCommand("/model kimi k3 ") orelse return error.TestExpectedCommand;
    try std.testing.expectEqualStrings("kimi k3", seeded.args);

    const goal = parseCommand("/goal fix the failing eval") orelse return error.TestExpectedCommand;
    try std.testing.expect(goal.spec.action == .goal);
    try std.testing.expectEqualStrings("fix the failing eval", goal.args);

    const write_goal = parseCommand("/write-goal fix the failing eval") orelse return error.TestExpectedCommand;
    try std.testing.expect(write_goal.spec.action == .write_goal);
    try std.testing.expectEqualStrings("fix the failing eval", write_goal.args);

    const add_goal = parseCommand("/add-goal fix the failing eval :: zig build test passes") orelse return error.TestExpectedCommand;
    try std.testing.expect(add_goal.spec.action == .add_goal);
    const pair = splitAddGoalArgs(add_goal.args) orelse return error.TestExpectedCommand;
    try std.testing.expectEqualStrings("fix the failing eval", pair.objective);
    try std.testing.expectEqualStrings("zig build test passes", pair.completion_criterion);
    try std.testing.expect(splitAddGoalArgs("only an objective") == null);

    const sessions = parseCommand("/sessions") orelse return error.TestExpectedCommand;
    try std.testing.expectEqualStrings("sessions", sessions.spec.action.tool.name);
    // Sessions remains a listing rather than accepting an arbitrary id.
    try std.testing.expect(parseCommand("/sessions foo") == null);

    try std.testing.expect(parseCommand("hello world") == null);
    try std.testing.expect(parseCommand("/nope") == null);
}

/// Splits like the REPL does before handing the pieces to the parser, so the
/// tests below exercise the same path a typed line takes.
fn compareCommandFor(line: []const u8) CompareCommand {
    var buf: [max_escape_args][]const u8 = undefined;
    const argv = splitShellArgs(line, &buf) catch return .usage;
    return parseCompareCommand(argv);
}

test "/compare separates starting a comparison from reading one back" {
    // Nothing to do, and the two spellings of asking what this is.
    try std.testing.expect(compareCommandFor("") == .usage);
    try std.testing.expect(compareCommandFor("--help") == .usage);
    try std.testing.expect(compareCommandFor("-h") == .usage);

    // A prompt, with or without flags, is a run: several model calls, so it
    // goes through an agent turn.
    try std.testing.expect(compareCommandFor("\"rewrite this error\"") == .run);
    try std.testing.expect(compareCommandFor("\"which sort?\" --with deepseek --with kimi-k3 --synthesize") == .run);

    // Reading one back is a local file read and never reaches the model.
    const shown = compareCommandFor("--show compare-123-abc");
    try std.testing.expectEqualStrings("compare-123-abc", shown.show.id);
    try std.testing.expectEqualStrings("", shown.show.pick);

    const picked = compareCommandFor("--show compare-123-abc --pick B");
    try std.testing.expectEqualStrings("compare-123-abc", picked.show.id);
    try std.testing.expectEqualStrings("B", picked.show.pick);
    // Order is not significant: the flags are scanned, not positional.
    const reordered = compareCommandFor("--pick B --show compare-123-abc");
    try std.testing.expectEqualStrings("B", reordered.show.pick);

    try std.testing.expect(compareCommandFor("--list") == .list);
    // --show names one comparison, which the listing cannot also mean.
    try std.testing.expect(compareCommandFor("--list --show compare-1") == .show);

    // A flag with nothing after it is a typo, not a prompt. Sending it on as
    // a run would spend a model call per entrant on the word "--show".
    try std.testing.expect(compareCommandFor("--show") == .usage);
    try std.testing.expect(compareCommandFor("--show compare-1 --pick") == .usage);
    try std.testing.expect(compareCommandFor("--pick B") == .usage);
}

test "/compare is in the registry and routes to its own action" {
    const bare = parseCommand("/compare") orelse return error.TestExpectedCommand;
    try std.testing.expect(bare.spec.action == .compare);
    try std.testing.expectEqualStrings("", bare.args);

    const with_args = parseCommand("/compare \"which sort?\" --with deepseek") orelse return error.TestExpectedCommand;
    try std.testing.expect(with_args.spec.action == .compare);
    try std.testing.expectEqualStrings("\"which sort?\" --with deepseek", with_args.args);

    // Prefix, not substring: a longer name of its own is not /compare.
    try std.testing.expect(parseCommand("/compared") == null);
}

test "parseShellEscape claims a leading bang and nothing else" {
    try std.testing.expectEqualStrings("git status", parseShellEscape("!git status").?);
    // Whitespace either side of the bang, and after the command, is noise.
    try std.testing.expectEqualStrings("git status", parseShellEscape("  !  git status  ").?);
    try std.testing.expectEqualStrings("git status", parseShellEscape("!\tgit status\t").?);

    // A bare bang is an escape with nothing to run, not a task: it prints
    // usage. Distinguishing it from "not an escape" is the whole reason this
    // returns an optional of a possibly-empty slice.
    try std.testing.expectEqualStrings("", parseShellEscape("!").?);
    try std.testing.expectEqualStrings("", parseShellEscape("   !   ").?);

    // A bang anywhere but the first column is ordinary text.
    try std.testing.expect(parseShellEscape("say hello!") == null);
    try std.testing.expect(parseShellEscape("what does ! do?") == null);
    try std.testing.expect(parseShellEscape("") == null);
    try std.testing.expect(parseShellEscape("   ") == null);
    // Slash commands and tasks are untouched by the interception.
    try std.testing.expect(parseShellEscape("/help") == null);
    try std.testing.expect(parseShellEscape("summarize the diff") == null);
}

test "splitShellArgs splits on whitespace and groups quoted arguments" {
    var buf: [max_escape_args][]const u8 = undefined;

    const plain = try splitShellArgs("git log --oneline -5", &buf);
    try std.testing.expectEqual(@as(usize, 4), plain.len);
    try std.testing.expectEqualStrings("git", plain[0]);
    try std.testing.expectEqualStrings("--oneline", plain[2]);
    try std.testing.expectEqualStrings("-5", plain[3]);

    // Runs of whitespace collapse; tabs count as whitespace.
    const spaced = try splitShellArgs("  rg \t needle   src  ", &buf);
    try std.testing.expectEqual(@as(usize, 3), spaced.len);
    try std.testing.expectEqualStrings("rg", spaced[0]);
    try std.testing.expectEqualStrings("needle", spaced[1]);
    try std.testing.expectEqualStrings("src", spaced[2]);

    // A quoted argument keeps its spaces and loses its quotes.
    const quoted = try splitShellArgs("rg \"foo bar\" src", &buf);
    try std.testing.expectEqual(@as(usize, 3), quoted.len);
    try std.testing.expectEqualStrings("foo bar", quoted[1]);
    const single = try splitShellArgs("rg 'foo bar'", &buf);
    try std.testing.expectEqualStrings("foo bar", single[1]);
    // An empty quoted argument survives as an empty argument.
    const empty_arg = try splitShellArgs("rg ''", &buf);
    try std.testing.expectEqual(@as(usize, 2), empty_arg.len);
    try std.testing.expectEqualStrings("", empty_arg[1]);

    // A quote that does not start an argument is literal: no shell here means
    // no shell quoting rules to emulate.
    const inner = try splitShellArgs("rg foo\"bar", &buf);
    try std.testing.expectEqual(@as(usize, 2), inner.len);
    try std.testing.expectEqualStrings("foo\"bar", inner[1]);

    try std.testing.expectEqual(@as(usize, 0), (try splitShellArgs("", &buf)).len);
    try std.testing.expectEqual(@as(usize, 0), (try splitShellArgs("   ", &buf)).len);

    try std.testing.expectError(error.UnterminatedQuote, splitShellArgs("rg \"foo bar", &buf));
    try std.testing.expectError(error.UnterminatedQuote, splitShellArgs("rg 'foo", &buf));
}

test "splitShellArgs refuses a line with more arguments than it can hold" {
    var buf: [max_escape_args][]const u8 = undefined;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(std.testing.allocator);
    for (0..max_escape_args) |_| try line.appendSlice(std.testing.allocator, "a ");
    // Exactly at the cap is fine; one more is refused rather than truncated.
    try std.testing.expectEqual(@as(usize, max_escape_args), (try splitShellArgs(line.items, &buf)).len);
    try line.appendSlice(std.testing.allocator, "a");
    try std.testing.expectError(error.TooManyArgs, splitShellArgs(line.items, &buf));
}

test "the shell escape is documented in help and stays out of the registry" {
    try std.testing.expect(std.mem.find(u8, shell_escape_help, "!<command>") != null);
    // No registry entry may claim a bang spelling: dispatch intercepts `!`
    // before parseCommand runs, so one there would be dead weight that /help
    // would nonetheless advertise.
    for (command_registry) |spec| {
        try std.testing.expect(spec.name[0] != '!');
        for (spec.aliases) |alias| try std.testing.expect(alias.len == 0 or alias[0] != '!');
    }
}

test "looksLikeSlashCommand separates typo'd commands from tasks" {
    try std.testing.expect(looksLikeSlashCommand("/nope"));
    try std.testing.expect(looksLikeSlashCommand("  /nope  "));
    try std.testing.expect(!looksLikeSlashCommand("hello /world"));
    try std.testing.expect(!looksLikeSlashCommand(""));
}

test "commandPreviewSpecs previews prefix matches, dedupes spellings, and hints signatures" {
    var buf: [max_completions]*const CommandSpec = undefined;

    // "/go" narrows to /goal alone, carrying its spec (and so its help).
    const go = commandPreviewSpecs("/go", &buf);
    try std.testing.expectEqual(@as(usize, 1), go.len);
    try std.testing.expect(go[0].action == .goal);

    // A command whose name and alias both match the prefix previews once.
    const q = commandPreviewSpecs("/q", &buf);
    try std.testing.expectEqual(@as(usize, 1), q.len);
    try std.testing.expect(q[0].action == .quit);

    // Bare "/" is discovery: every command, in registry (/help) order.
    const all = commandPreviewSpecs("/", &buf);
    try std.testing.expectEqual(command_registry.len, all.len);
    try std.testing.expect(all[0].action == .help);

    // Once arguments are being typed the matched command's row stays on
    // screen as a signature hint, alias spellings included.
    const sig = commandPreviewSpecs("/goal build the parser", &buf);
    try std.testing.expectEqual(@as(usize, 1), sig.len);
    try std.testing.expect(sig[0].action == .goal);
    const alias_sig = commandPreviewSpecs("/history 3", &buf);
    try std.testing.expectEqual(@as(usize, 1), alias_sig.len);

    // Leading whitespace is tolerated the way parseCommand tolerates it.
    try std.testing.expectEqual(@as(usize, 1), commandPreviewSpecs("  /go", &buf).len);

    // Nothing previews for: a plain task, an unknown spelling (with or
    // without arguments), or a multi-line draft.
    try std.testing.expectEqual(@as(usize, 0), commandPreviewSpecs("fix the tests", &buf).len);
    try std.testing.expectEqual(@as(usize, 0), commandPreviewSpecs("/xyzzy", &buf).len);
    try std.testing.expectEqual(@as(usize, 0), commandPreviewSpecs("/xyzzy now", &buf).len);
    try std.testing.expectEqual(@as(usize, 0), commandPreviewSpecs("/goal fix" ++ newline_marker ++ "more", &buf).len);
    try std.testing.expectEqual(@as(usize, 0), commandPreviewSpecs("", &buf).len);
}

test "suggestSlashCommand offers did-you-mean for close misspellings" {
    try std.testing.expectEqualStrings("/help", suggestSlashCommand("/halp").?);
    try std.testing.expectEqualStrings("/model", suggestSlashCommand("/modle").?);
    try std.testing.expectEqualStrings("/quit", suggestSlashCommand("/qit").?);
    try std.testing.expect(suggestSlashCommand("/xyzzy") == null);
}

test "unknown slash command diagnostics match CLI grammar" {
    const suggested = try unknownSlashCommandText(std.testing.allocator, "  /modle  ");
    defer std.testing.allocator.free(suggested);
    try std.testing.expectEqualStrings("error: unknown command '/modle'; did you mean `/model`?", suggested);

    const unknown = try unknownSlashCommandText(std.testing.allocator, "/xyzzy");
    defer std.testing.allocator.free(unknown);
    try std.testing.expectEqualStrings("error: unknown command '/xyzzy'; try `/help`", unknown);
}

test "matchingSpellings finds a unique prefix and every ambiguous one" {
    var buf: [max_completions]SpellingMatch = undefined;

    const unique = matchingSpellings("/hel", &buf);
    try std.testing.expectEqual(@as(usize, 1), unique.len);
    try std.testing.expectEqualStrings("/help", unique[0].spelling);

    // "/s" hits /sessions, /search, and /status.
    const ambiguous = matchingSpellings("/s", &buf);
    try std.testing.expectEqual(@as(usize, 3), ambiguous.len);
    try std.testing.expectEqualStrings("/sessions", ambiguous[0].spelling);
    try std.testing.expectEqualStrings("/search", ambiguous[1].spelling);
    try std.testing.expectEqualStrings("/status", ambiguous[2].spelling);

    try std.testing.expectEqual(@as(usize, 0), matchingSpellings("/nope", &buf).len);
}

test "longestCommonPrefix completes toward the shared stem or nowhere" {
    var buf: [max_completions]SpellingMatch = undefined;
    const s_matches = matchingSpellings("/s", &buf);
    // /sessions vs /status share only "/s", no further completion possible.
    try std.testing.expectEqualStrings("/s", longestCommonPrefix(s_matches));

    var buf2: [max_completions]SpellingMatch = undefined;
    const wo_matches = matchingSpellings("/wo", &buf2);
    // /workflows vs /workflow share the full shorter spelling.
    try std.testing.expectEqualStrings("/workflow", longestCommonPrefix(wo_matches));

    try std.testing.expectEqualStrings("", longestCommonPrefix(&.{}));
}

/// `CLANKER_THEME` picks a palette by name ("mocha"/"catppuccin", "latte",
/// "frappe", "macchiato", "tokyonight", "storm", "day", "mono", "default").
/// The environment provides the persistent terminal default; `--theme`
/// overrides it for one invocation and `/theme` for the current session.
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
    /// Unix seconds when this conversation was first created, preserved
    /// across resume so a continued session keeps its original birth date.
    session_created: i64 = 0,
    /// First task of the conversation, trimmed, the line `clanker sessions`
    /// shows. Kept from a loaded session; set once on the first submit.
    session_title: []const u8 = "",
    /// The system prompt the agent last built (with the preset persona
    /// appended), captured after each turn so `persistSession` can record
    /// what the model actually saw. Arena-owned, same lifetime as the Model.
    session_system_prompt: ?[]const u8 = null,

    lines: std.ArrayList(Line) = .empty,
    /// Foldable replies (see `Fold`), sorted by `.start` (creation order).
    folds: std.ArrayList(Fold) = .empty,
    /// Clickable `>` header rows from the last draw, in widget-local rows,
    /// so a mouse release can map back to a fold.
    fold_hits: std.ArrayList(struct { row: u16, fold: usize }) = .empty,
    /// Transcript width from the last draw; used to decide foldability when a
    /// reply lands on the worker thread in `finishTurn`.
    last_text_width: u16 = 0,
    text_field: vxfw.TextField,
    thread: ?std.Thread = null,
    spinner_frame: u8 = 0,
    /// Counts stream-redraw ticks so the spinner advances every third one
    /// while the transcript itself repaints at the full ~30fps tick rate.
    tick_count: u32 = 0,
    /// The opt-in mascot (`--mascot`, `tui.mascot`). `.off` claims no rows and
    /// costs nothing; see `src/tui/mascot.zig`.
    mascot: mascot.State = .{},
    /// Whether this model already has a `ctx.tick` pending.
    ///
    /// Exists because two things now want a heartbeat -- a streaming turn and
    /// the mascot's `loop` mode -- and vxfw's timer list holds every tick
    /// scheduled, with no way to ask whether one is already there. Arming a
    /// second while the first is pending is not self-correcting: each delivery
    /// re-arms one, so two pending timers stay two, and the animation runs at
    /// double speed for the rest of the session. Submitting a task while the
    /// mascot was already ticking did exactly that.
    ///
    /// So: cleared on delivery, set on arm, and consulted by every site that
    /// might arm one that is already there.
    timer_armed: bool = false,
    /// The vaxis handle, for the kitty-graphics transmit. Borrowed from the
    /// `vxfw.App` that outlives this model; null until `cmdReplVaxis` sets it,
    /// and null forever when the mascot is off (nothing else needs it).
    app: ?*vxfw.App = null,
    status_buf: [192]u8 = undefined,
    scroll_buf: [32]u8 = undefined,
    /// The status line's " running <tool>" phase text. A field rather than a
    /// draw-local buffer because vaxis cells borrow the slices written into
    /// them until the frame is flushed, which is after `draw` has returned.
    phase_buf: [80]u8 = undefined,
    meter_buf: [64]u8 = undefined,
    cost_buf: [32]u8 = undefined,
    tok_buf: [32]u8 = undefined,
    /// Tokens spent across every turn of this session, accumulated here
    /// rather than read off `Agent.session_stats` because the REPL builds a
    /// fresh `Agent` for every turn, so the agent's own session counters
    /// start from zero each time. Distinct from the context meter beside it:
    /// this is everything the session has ever sent and received, that is how
    /// much of it the model can still see.
    session_tokens: u64 = 0,
    session_turns: u64 = 0,
    session_steps: u64 = 0,
    session_llm_ms: u64 = 0,
    session_tool_ms: u64 = 0,
    session_ttft_ms: u64 = 0,
    session_ttft_n: u32 = 0,
    session_prompt: u64 = 0,
    session_completion: u64 = 0,
    session_cache_hit: u64 = 0,
    session_cache_miss: u64 = 0,
    metrics_buf: [256]u8 = undefined,
    /// Null until a turn on a priced model lands, so an unpriced session
    /// shows no cost at all rather than a running $0.00.
    session_cost: ?f64 = null,
    /// Estimated tokens of conversation history, refreshed once per completed
    /// turn. Cached rather than recomputed in `draw`: the status bar repaints
    /// ~30 times a second while a turn streams, and re-weighing a 100k-token
    /// history on every frame is real work for a number that only moves when
    /// a turn ends.
    context_tokens: usize = 0,
    /// Mid-turn compaction detector: the summary-marker state as it stood
    /// when the current turn was submitted (see `stats.summaryState`).
    summary_before: stats_mod.SummaryState = .{},
    /// `/theme <name>` sets this for the session, overriding `CLANKER_THEME`.
    /// Arena-owned. Null = fall back to the env var (then the default).
    theme_override: ?[]const u8 = null,
    /// `/plan` toggles proposal-only runs (write-capable tools refused), matching
    /// the web UI's Plan checkbox for this session.
    plan_mode: bool = false,
    /// Active preset name for this session (filtered Registry). Null = full.
    preset_name: ?[]const u8 = null,
    /// `/research` toggles web-research runs, matching the web UI's Research checkbox.
    research_mode: bool = false,
    /// Pending images for the next submit, shown in the status bar and
    /// sliced into `Agent.pending_images` by `submitTask`. Mirrors the web
    /// composer's `attachments` (PRD 0041).
    pending_attach_paths: std.ArrayList([]const u8) = .empty,
    /// Between a bracketed-paste start/end pair. `vxfw.TextField` is a
    /// single-line widget (Enter either submits or is a no-op, there is no
    /// way to insert a literal newline into one), so a multi-line paste's
    /// embedded Enters would otherwise submit the task early, mid-paste.
    /// While true, Enter is folded to a space and inserted instead.
    in_paste: bool = false,
    /// vxfw.App.run() unconditionally enables mouse reporting (setMouseMode),
    /// which takes click-drag away from the terminal's own text selection in
    /// most emulators (Konsole included), so this app owes its own
    /// selection + clipboard copy in exchange for grabbing the mouse.
    /// Row-major, drag-to-select over the transcript region only (not the
    /// status line or input box); copies via OSC 52 on release.
    mouse_down: bool = false,
    has_selection: bool = false,
    sel_start: vxfw.Point = .{ .row = 0, .col = 0 },
    sel_end: vxfw.Point = .{ .row = 0, .col = 0 },
    /// Screen region of the composer's interior text cells (borders
    /// excluded); `bottom`/`right` exclusive. Refreshed every draw so mouse
    /// selection can tell the composer from the transcript.
    composer_top: u16 = 0,
    composer_bottom: u16 = 0,
    composer_left: u16 = 0,
    composer_right: u16 = 0,
    /// Whether the live selection anchors in the composer, decided at press.
    /// A selection never spans both regions: they scroll independently, so a
    /// mixed span would not name any coherent text.
    sel_in_composer: bool = false,
    /// The composer child surface from the last frame, same lifetime as
    /// `last_surface`. Selection highlight and extraction must use the child:
    /// the parent's cells underneath it are blank, and at composite time the
    /// child covers anything painted on the parent.
    last_input_surface: ?vxfw.Surface = null,
    /// The last frame's rendered cells, kept only to read back the plain
    /// text under a selection (surface.readCell), its backing arena is the
    /// draw arena, valid until the next redraw actually runs, which is
    /// after event handling in vxfw.App's own loop.
    last_surface: ?vxfw.Surface = null,
    transcript_top: u16 = 0,
    transcript_bottom: u16 = 0,
    /// Manual scrollback anchor: null while the transcript follows its tail
    /// (the default, new output scrolls into view as it arrives). Non-null
    /// pins the visible window to end at this absolute line index
    /// (exclusive), so a streaming turn can append to `lines` without
    /// yanking a reader back down. PgUp/PgDn/Home/End/Esc drive it; the
    /// draw re-clamps it every frame (a resize changes what fits).
    view_end: ?usize = null,

    /// Submitted-task history for the Up/Down recall every REPL has.
    /// `hist_idx == history.len` means "editing a fresh line", and the
    /// in-progress draft is parked in `hist_draft` while browsing so Esc
    /// (which clears the field) can't destroy unsent text.
    history: std.ArrayList([]const u8) = .empty,
    hist_idx: usize = 0,
    hist_draft: []const u8 = "",
    /// Readline-style text removed by Ctrl-U, Ctrl-K, or Ctrl-W. Ctrl-Y
    /// reinserts it at the cursor; this is deliberately separate from the
    /// system clipboard used by Ctrl-Shift-C/V.
    kill_ring: std.ArrayList(u8) = .empty,

    /// Non-null while an OSC 52 clipboard read is awaited (some terminals
    /// answer on a delay, some never answer). A second paste shortcut while
    /// pending re-sends the request, which is harmless.
    awaiting_clipboard: bool = false,

    /// Every configured provider/model, flattened once at startup (config
    /// does not change mid-session). `/model` opens `picker_open`, and while
    /// it's true every key press is routed to `handlePickerKey` instead of
    /// the normal input handling below, a small modal, not a second widget.
    model_candidates: []const ModelCandidate = &.{},
    /// Every slash command, flattened once at startup for the Ctrl-P palette.
    command_candidates: []const CommandCandidate = &.{},
    /// Every `presets/<name>.toml`, loaded at `/preset` picker-open time (the
    /// directory can change mid-session when the operator scaffolds a new one).
    preset_candidates: []const PresetCandidate = &.{},
    picker_open: bool = false,
    /// What the open picker is choosing: a provider/model or a color theme.
    /// Both share the one modal (query line + arrow-select + Enter/Esc); the
    /// list source and what Enter does branch on this.
    picker_kind: PickerKind = .model,
    picker_query: std.ArrayList(u8) = .empty,
    picker_selected: usize = 0,
    /// "<n>/<total>" for the picker's guide row, formatted into a field for
    /// the same reason `status_buf` is one: cells borrow the slice until the
    /// frame flushes, which is after `drawModelPicker` has returned.
    picker_pos_buf: [32]u8 = undefined,
    /// Detail line under the picker rows (model spec / effort source). A
    /// Model field for the same reason as `picker_pos_buf`: vaxis cells
    /// borrow the slice until the frame flushes.
    picker_detail_buf: [192]u8 = undefined,
    /// The theme active when the theme picker opened, restored on Escape so a
    /// cancelled live-preview does not stick.
    theme_saved: ?[]const u8 = null,

    /// An ask_user/confirm question from the run thread is on screen
    /// (`pending_ask` owns the strings; these are only the modal's cursor).
    /// While true every key routes to `handleAskKey`: the run is parked on
    /// the answer, so no other binding may fire blind over the question.
    ask_open: bool = false,
    ask_selected: usize = 0,

    /// Transcript search (Ctrl-R). Like the pickers this is a modal that owns
    /// the keyboard while open, but it drives `view_end` rather than
    /// committing a selection, so paging and searching cannot disagree about
    /// where the transcript is looking.
    search_open: bool = false,
    search_query: std.ArrayList(u8) = .empty,
    /// Line indices matching the query, oldest first. gpa-owned (not arena):
    /// it is rebuilt on every keystroke, so arena allocation would grow the
    /// session arena by a whole hit list per character typed.
    search_hits: std.ArrayList(usize) = .empty,
    search_idx: usize = 0,
    /// The scroll anchor in force when search opened, restored on Escape so a
    /// cancelled search leaves the reader where it found them.
    search_saved_view: ?usize = null,
    /// "<n>/<total>" for the search bar; a field because vaxis cells borrow
    /// the slice until the frame flushes.
    search_pos_buf: [32]u8 = undefined,

    fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    /// Snapshots what the turn just cost. Called on the run thread once
    /// `Agent.run` has returned, so `a.stats` is final (its own defer folds
    /// the run's totals before returning, on the error path too).
    ///
    /// Cost is deliberately read from the model catalogue rather than from
    /// `a.stats.cost`: the agent only accumulates cost when the model has
    /// pricing, so a plain `cost > 0` test cannot tell "this model is free to
    /// call" from "nobody wrote down what this model charges". Unpriced
    /// models get null and the segment disappears.
    fn turnStats(self: *Model, a: *const Agent, started: std.Io.Timestamp, messages: []const types.Message) stats_mod.TurnStats {
        const elapsed = started.durationTo(std.Io.Timestamp.now(self.io, .awake));
        const m = self.provider.activeModel();
        const priced = m.cost_per_1m_input != null or m.cost_per_1m_output != null;
        return .{
            .prompt_tokens = a.stats.total_prompt_tokens,
            .completion_tokens = a.stats.total_completion_tokens,
            .cache_hit_tokens = a.stats.total_cache_hit_tokens,
            .cache_miss_tokens = a.stats.total_cache_miss_tokens,
            .wall_ms = @intCast(@max(0, @divTrunc(elapsed.nanoseconds, std.time.ns_per_ms))),
            .cost_usd = if (priced) a.stats.cost else null,
            .context_tokens = stats_mod.historyTokens(messages),
            .context_window = m.context_window,
        };
    }

    /// Called from the background run thread once Agent.run returns
    /// (success or error alike): folds the streamed buffer and any tool
    /// lines into permanent `lines`, clears the live streaming state, and
    /// closes the turn with its stats line (`null` when the turn never
    /// reached the provider and there is nothing to report).
    fn finishTurn(self: *Model, final_text: []const u8, turn: ?stats_mod.TurnStats) void {
        bridge_mutex.lockUncancelable(bridge_io);
        defer bridge_mutex.unlock(bridge_io);
        // Log records emitted while the turn was in flight land before the
        // tool lines, in arrival order.
        drainLogLines(self);
        // Tool lines are allocated from bridge_gpa by the worker callbacks;
        // the transcript owns arena copies so the originals can be freed
        // here instead of living (and leaking) for the process lifetime.
        for (bridge_tool_lines.items) |l| {
            const copy = self.arena.dupe(u8, l) catch l;
            self.lines.append(self.arena, .{ .text = copy, .dim = true }) catch {};
            if (copy.ptr != l.ptr) bridge_gpa.free(l);
        }
        bridge_tool_lines.clearRetainingCapacity();
        const answer = if (final_text.len > 0) final_text else bridge_stream_buf.items;
        const reply_start = self.lines.items.len;
        appendAnswerLines(self.arena, &self.lines, answer);
        // A long reply becomes a foldable region (see `Fold`): it renders as
        // a single `>` header row until the user clicks it open. Only the
        // prose is folded; the tool lines and the turn receipt above/below
        // are untouched. Foldability is judged on wrapped height at the last
        // transcript width so short replies never fold.
        self.maybeFoldReply(reply_start);
        bridge_stream_buf.clearRetainingCapacity();

        // Fold live session-strip counters before resetting them. finishTurn
        // runs while `bridge_streaming` is still true (the UI thread clears
        // that after join); draw treats `bridge_live_started_ns == 0` as
        // idle so the same numbers are not added twice in that window.
        const official = if (turn) |t| t.accounted() else false;
        const wall_ms: u64 = if (turn) |t| t.wall_ms else liveElapsedMs();
        self.session_steps +|= bridge_live_steps +| 1;
        self.session_tool_ms +|= bridge_live_tool_ms;
        self.session_llm_ms +|= wall_ms -| bridge_live_tool_ms;
        if (official) {
            const t = turn.?;
            self.session_tokens +|= t.prompt_tokens +| t.completion_tokens;
            if (t.cost_usd) |c| self.session_cost = (self.session_cost orelse 0) + c;
            self.session_prompt +|= t.prompt_tokens;
            self.session_completion +|= t.completion_tokens;
            self.session_cache_hit +|= t.cache_hit_tokens;
            self.session_cache_miss +|= t.cache_miss_tokens;
        } else {
            self.session_tokens +|= bridge_live_prompt +| bridge_live_completion;
            self.session_prompt +|= bridge_live_prompt;
            self.session_completion +|= bridge_live_completion;
            self.session_cache_hit +|= bridge_live_cache_hit;
            self.session_cache_miss +|= bridge_live_cache_miss;
        }
        if (bridge_live_ttft_samples > 0) {
            self.session_ttft_ms +|= bridge_live_ttft_total;
            self.session_ttft_n +|= bridge_live_ttft_samples;
        } else if (bridge_live_ttft_ms) |ttft| {
            self.session_ttft_ms +|= ttft;
            self.session_ttft_n +|= 1;
        }
        resetBridgeLive();

        // The turn's receipt, last line of the turn: tokens, wall time,
        // tok/s, cache hit rate, cost and how full the context now is. Same
        // formatter `clanker run` prints on stderr (`tui/turn_stats.zig`).
        if (official) {
            if (stats_mod.formatTurn(self.arena, turn.?)) |line| {
                self.lines.append(self.arena, .{ .text = line, .dim = true }) catch {};
            } else |_| {}
        }
    }

    /// Completed totals plus the in-flight turn. Caller holds `bridge_mutex`.
    fn sessionStrip(self: *const Model) stats_mod.SessionStats {
        const live = bridge_live_started_ns != 0;
        const live_ms: u64 = if (live) liveElapsedMs() else 0;
        const est: u64 = if (live and bridge_live_completion == 0)
            @as(u64, @intCast(bridge_stream_buf.items.len / 4))
        else
            0;
        return .{
            .turns = self.session_turns,
            .steps = self.session_steps +| bridge_live_steps +| if (live) @as(u64, 1) else 0,
            .llm_ms = self.session_llm_ms +| (if (live) live_ms -| bridge_live_tool_ms else 0),
            .tool_ms = self.session_tool_ms +| bridge_live_tool_ms,
            .ttft_ms_total = self.session_ttft_ms +| bridge_live_ttft_total,
            .ttft_samples = self.session_ttft_n +| bridge_live_ttft_samples,
            .live_ttft_ms = if (bridge_live_ttft_samples == 0) bridge_live_ttft_ms else null,
            .prompt_tokens = self.session_prompt +| bridge_live_prompt,
            .completion_tokens = self.session_completion +| bridge_live_completion +| est,
            .cache_hit_tokens = self.session_cache_hit +| bridge_live_cache_hit,
            .cache_miss_tokens = self.session_cache_miss +| bridge_live_cache_miss,
        };
    }

    /// If the reply that begins at `reply_start` is long enough, mark it as a
    /// foldable region, starting collapsed. Runs under `bridge_mutex` from the
    /// worker thread (`finishTurn`); the draw/tick loop reads the same list
    /// under the same lock.
    fn maybeFoldReply(self: *Model, reply_start: usize) void {
        const width = if (self.last_text_width > 0) self.last_text_width else 80;
        const fold = foldForReply(self.lines.items, reply_start, width) orelse return;
        self.folds.append(self.arena, fold) catch {};
    }

    /// Index into `self.folds` of the fold whose region begins at `line_idx`,
    /// or null.
    ///
    /// `folds` is appended in session order (`maybeFoldReply` runs once per
    /// finished turn and each reply starts after every earlier one), so it
    /// stays sorted ascending by `start` and `start` never mutates after the
    /// append (only `expanded` does). The linear scan this replaced ran once
    /// per drawn line per frame — O(visible rows × folds) on every keystroke
    /// and animation tick, which is a long session's quadratic draw. Starts
    /// are unique, so an exact-match binary search is correct.
    fn foldIndexAtStart(self: *const Model, line_idx: usize) ?usize {
        const S = struct {
            fn cmp(context: usize, f: Fold) std.math.Order {
                return std.math.order(context, f.start);
            }
        };
        return std.sort.binarySearch(Fold, self.folds.items, line_idx, S.cmp);
    }

    /// The `▸ N lines` / `▾` header standing in for a collapsed reply. Arena
    /// allocated per draw; vaxis borrows the bytes only until the frame flushes.
    fn foldHeader(self: *const Model, arena: std.mem.Allocator, fold: Fold) []const u8 {
        _ = self;
        const hidden = fold.count - foldShownLines(fold);
        if (hidden == 0) return "\xe2\x96\xbe reply (click to fold)";
        return std.fmt.allocPrint(arena, "\xe2\x96\xb8 reply, {d} more line{s} (click to expand)", .{
            hidden,
            if (hidden == 1) "" else "s",
        }) catch "\xe2\x96\xb8 reply (click to expand)";
    }

    /// Flip the fold at `idx` open or closed. The animation carries it the
    /// rest of the way; `anim` is never snapped, so a mid-animation toggle
    /// reverses from where it is instead of jumping.
    fn toggleFold(self: *Model, idx: usize) void {
        if (idx >= self.folds.items.len) return;
        self.folds.items[idx].expanded = !self.folds.items[idx].expanded;
    }

    /// Start the animation heartbeat if it is not already running. The `.tick`
    /// arm owns re-arming from then on, so this only ever adds the *first*
    /// timer: two pending ticks never converge back into one, they just double
    /// every animation rate for the rest of the session.
    fn armTimer(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.timer_armed) return;
        self.timer_armed = true;
        try ctx.tick(fold_tick_ms, self.widget());
    }

    /// Advance every animating fold one step toward its target and report
    /// whether any fold is still mid-animation (needs another tick). Called
    /// from the tick handler under `bridge_mutex`.
    fn advanceFolds(self: *Model) bool {
        const step: f32 = 1.0 / @as(f32, @floatFromInt(FOLD_ANIM_RATE));
        var any = false;
        for (self.folds.items) |*f| {
            const target: f32 = if (f.expanded) 1 else 0;
            if (f.anim == target) continue;
            const delta = step;
            if (target > f.anim) {
                f.anim = @min(1, f.anim + delta);
            } else {
                f.anim = @max(0, f.anim - delta);
            }
            if (f.anim != target) any = true;
        }
        return any;
    }

    /// Reports the *other* compaction: the one `Agent.maybeCompactMessages`
    /// performs inside a turn once the history passes
    /// `agent.compact_threshold_bytes`, replacing the middle of the
    /// conversation with an LLM-written summary. That one is not a call this
    /// file makes, and `Agent` offers no hook for it, so it is detected after
    /// the fact from the summary message it leaves behind
    /// (`stats.summaryState`) against the baseline `submitTask` took. Called
    /// on the UI thread with the worker already joined.
    fn reportMidTurnCompaction(self: *Model) void {
        const after = stats_mod.summaryState(self.messages.items);
        const notice = stats_mod.formatSummaryNotice(self.arena, self.summary_before, after) catch return;
        if (notice) |line| self.lines.append(self.arena, .{ .text = line, .dim = true }) catch {};
        self.summary_before = after;
    }

    /// Writes the conversation to `state/sessions/<id>.json`, called after
    /// every completed turn (never mid-turn: the caller joins the worker
    /// first, so `self.messages` is stable). A failed write is reported at
    /// error level, the only log level this REPL leaves enabled, and the
    /// next turn's save retries; it must not kill the session over a disk
    /// hiccup.
    fn persistSession(self: *Model) void {
        const sid = self.session_id orelse return;
        if (!self.cfg.modules.sessions) return;
        // Compaction is not a save-time detail: it drops the oldest exchanges
        // out of what the model can still see, permanently, and it used to
        // happen here with nothing on screen. Weigh the conversation either
        // side of the call and say so when it actually took something.
        const before: stats_mod.Compaction = .{
            .messages_before = self.messages.items.len,
            .bytes_before = stats_mod.historyBytes(self.messages.items),
        };
        session_mod.compactMessages(&self.messages, session_mod.max_session_tokens);
        const measured: stats_mod.Compaction = .{
            .messages_before = before.messages_before,
            .messages_after = self.messages.items.len,
            .bytes_before = before.bytes_before,
            .bytes_after = stats_mod.historyBytes(self.messages.items),
        };
        if (stats_mod.formatCompaction(self.arena, measured)) |maybe_line| {
            if (maybe_line) |line| self.lines.append(self.arena, .{ .text = line, .dim = true }) catch {};
        } else |_| {}
        const updated: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .real).nanoseconds, 1_000_000_000));
        session_mod.saveSession(self.io, self.gpa, self.arena, "state/sessions", .{
            .id = sid,
            .title = self.session_title,
            .messages = self.messages.items,
            .created = self.session_created,
            .updated = updated,
            .system_prompt = self.session_system_prompt,
        }) catch |err| {
            log.log(.error_, "session '{s}' save failed: {s}", .{ sid, @errorName(err) });
        };
    }

    fn submit(self: *Model, ctx: *vxfw.EventContext) !void {
        // One turn at a time: runThreadMain's finishTurn touches self.lines
        // and self.arena from the background thread. self.arena is a plain
        // ArenaAllocator (no internal locking) and self.lines is a plain
        // ArrayList, so a second in-flight turn spawned here would race the
        // first turn's background thread on both, not just contend for
        // bridge_mutex-guarded state, but corrupt the arena's free-list and the
        // transcript's backing storage. Leaving typed input untouched (no
        // toOwnedSlice yet) is a no-op keystroke while the picker is modal
        // for the same reason: nothing to submit into.
        bridge_mutex.lockUncancelable(bridge_io);
        const already_streaming = bridge_streaming;
        bridge_mutex.unlock(bridge_io);
        // While a turn runs the composer is a steering box, not a task box:
        // the typed line is queued as a mid-run course correction instead of
        // being dropped (the old no-op). A second turn can never start
        // anyway, one turn at a time, so this is the only useful thing to
        // type into it.
        if (already_streaming) {
            self.steerWhileRunning(ctx);
            return;
        }

        const task = try self.takeComposerText();
        defer self.gpa.free(task);
        self.text_field.reset();
        // A line with nothing on it is not a task. The idle path only tested
        // `len == 0`, so whitespace fell through every dispatch below —
        // `parseShellEscape` and `parseCommand` both trim and decline it —
        // and reached `submitTask`, which echoed a bare `clanker>` prompt and
        // spawned a real `Agent.run` on a prompt with no content in it. That
        // is a billed round trip for a keystroke that should do nothing, and
        // it is easy to hit: a stray space, an indented paste, or Enter held
        // a moment too long. `steerWhileRunning` had trimmed all along; this
        // is the same test on the other branch.
        if (isBlankSubmission(task)) return;

        // `!cmd` is intercepted first: it never reaches the registry (no
        // CommandSpec can match it, see shell_escape_help) and it must never
        // reach the LLM, which is what a bare `!ls` used to do.
        if (parseShellEscape(task)) |line| {
            self.runShellEscape(line);
            return;
        }

        // Slash commands dispatch through `command_registry`, one lookup
        // covering every spelling, instead of literal matches strewn about.
        // An unrecognized /command is reported in the transcript rather than
        // sent to the LLM (a typo'd command is not a task); bare text without
        // the slash is still a task, bare "exit"/"quit" included (they are
        // registry aliases of /quit).
        if (parseCommand(task)) |pc| {
            try self.runCommand(ctx, pc, task);
            return;
        }
        if (looksLikeSlashCommand(task)) {
            const text = unknownSlashCommandText(self.arena, task) catch "error: unknown command; try `/help`";
            self.lines.append(self.arena, .{
                .text = text,
                .dim = true,
            }) catch {};
            return;
        }

        try self.submitTask(ctx, task);
    }

    /// While a turn runs, the composer submits a mid-run steering message
    /// rather than a new task. Takes the bridge lock before touching either
    /// the steer queue or self.lines, because the run thread's finishTurn /
    /// tuiSteerPoll touch the same two under that same lock.
    fn steerWhileRunning(self: *Model, ctx: *vxfw.EventContext) void {
        const task = self.takeComposerText() catch return;
        defer self.gpa.free(task);
        if (std.mem.trim(u8, task, " \t\r\n").len == 0) return;
        self.text_field.reset();
        bridge_mutex.lockUncancelable(bridge_io);
        defer bridge_mutex.unlock(bridge_io);
        if (!bridge_streaming) {
            self.lines.append(self.arena, .{ .text = "notice: no run to steer; the turn already ended", .dim = true }) catch {};
            return;
        }
        // Same framing POST /api/steer applies server-side, so the model reads
        // a TUI steer as the same mid-run course correction it reads a web one.
        const framed = std.fmt.allocPrint(bridge_gpa, "[The user interjected while this run was in progress; take the message into account and adjust course.]\n\n{s}", .{task}) catch {
            self.lines.append(self.arena, .{ .text = "error: steer failed: out of memory", .dim = true }) catch {};
            return;
        };
        bridge_steer.append(bridge_gpa, framed) catch {
            bridge_gpa.free(framed);
            self.lines.append(self.arena, .{ .text = "error: steer failed: out of memory", .dim = true }) catch {};
            return;
        };
        const echo = std.fmt.allocPrint(bridge_gpa, "notice: steering queued: {s}", .{task}) catch "notice: steering queued";
        bridge_tool_lines.append(bridge_gpa, echo) catch {
            if (echo.ptr != "notice: steering queued".ptr) bridge_gpa.free(echo);
        };
        ctx.redraw = true;
    }

    /// Executes one registry command from `submit`. `task` is the raw
    /// submitted line, which /autoresearch re-submits as an agent task when
    /// given real arguments.
    fn runCommand(self: *Model, ctx: *vxfw.EventContext, pc: ParsedCommand, task: []const u8) !void {
        // Park the raw line in history like chat and `!` escapes so Up/Down
        // can recall and re-run slash commands too. `task` is gpa-owned and
        // freed when `submit` returns, so own a copy in the arena.
        if (self.arena.dupe(u8, task)) |owned| {
            self.history.append(self.arena, owned) catch {};
            self.hist_idx = self.history.items.len;
            self.hist_draft = "";
        } else |_| {}
        switch (pc.spec.action) {
            // A quit command has to set `ctx.quit`, rather than merely stop
            // the input handler: App.run returns on that flag and its
            // caller's defer then restores the alternate screen, raw input,
            // mouse mode, and bracketed paste before the shell regains the
            // terminal.
            .quit => ctx.quit = true,
            .help => self.printHelp(),
            // "/model" alone opens the picker on the full list; "/model kimi"
            // seeds it with a starting query, so a remembered partial name is
            // one Enter away instead of a blank list to type into again.
            .model => try self.openModelPicker(ctx, pc.args),
            // /goal <prompt> executes the supplied goal directly, matching
            // `clanker goal "<prompt>"`. Drafting and persistence are
            // optional separate capabilities, never a prerequisite here.
            .goal => {
                if (pc.args.len == 0) {
                    self.lines.append(self.arena, .{ .text = "usage: /goal <intent> (e.g. /goal fix the failing eval)", .dim = true }) catch {};
                    return;
                }
                _ = self.runGoalTask(ctx, pc.args);
            },
            .write_goal => {
                if (pc.args.len == 0) {
                    self.lines.append(self.arena, .{ .text = "usage: /write-goal <intent> (e.g. /write-goal fix the failing eval)", .dim = true }) catch {};
                    return;
                }
                _ = self.runWriteGoal(pc.args);
            },
            .add_goal => {
                if (pc.args.len == 0) {
                    self.lines.append(self.arena, .{ .text = "usage: /add-goal <objective> :: <completion criterion>", .dim = true }) catch {};
                    return;
                }
                _ = self.runAddGoal(pc.args);
            },
            .autoresearch => {
                if (pc.args.len == 0 or std.mem.eql(u8, pc.args, "--help") or std.mem.eql(u8, pc.args, "-h")) {
                    self.lines.append(self.arena, .{ .text = "usage: /autoresearch --target <file> --harness \"<cmd>\" [--iters N] [--dry-run]", .dim = true }) catch {};
                    self.lines.append(self.arena, .{ .text = "  runs the measurement loop; use --dry-run to validate without LLM", .dim = true }) catch {};
                    self.lines.append(self.arena, .{ .text = "  example: /autoresearch --target tools/zig/calculator.zig --harness \"sh -c 'echo score: 1.0'\" --dry-run", .dim = true }) catch {};
                    return;
                }
                try self.submitTask(ctx, task);
            },
            // Runs as an ordinary agent turn so each round streams as it
            // happens: a match is several multi-second model calls, and doing
            // it synchronously here would freeze the REPL for its whole
            // duration with nothing on screen. The tool's own rendered
            // transcript is what lands in the turn, verdict block included.
            .arena => {
                if (pc.args.len == 0 or std.mem.eql(u8, pc.args, "--help") or std.mem.eql(u8, pc.args, "-h")) {
                    appendDimBlock(self.arena, &self.lines, arena_command_help);
                    return;
                }
                const prompt = std.fmt.allocPrint(
                    self.arena,
                    "Run one arena match with these arguments: {s}\n\n" ++
                        "Call the `arena` tool exactly once, mapping the flags onto its input fields " ++
                        "(--for -> \"for\", --against -> \"against\", --rounds -> \"max_rounds\", " ++
                        "--judge -> \"judge\", --for-provider -> \"provider_for\", " ++
                        "--against-provider -> \"provider_against\", --judge-provider -> \"judge_provider\", " ++
                        "repeated --position -> the \"positions\" array, --defend -> \"defend\", and " ++
                        "--alternative -> \"alternative\"). For --defend/--alternative, when a value is an " ++
                        "existing file, read it into the field and also pass its path as \"defend_path\" or " ++
                        "\"alternative_path\". Do not combine pairwise, positions, and design-review modes. " ++
                        "Use the quoted text before the first flag as \"question\". Then print the tool's " ++
                        "\"text\" field verbatim as your whole answer. Do not summarize it, re-score the " ++
                        "match, or add commentary; the transcript and verdict are the result.",
                    .{pc.args},
                ) catch {
                    self.lines.append(self.arena, .{ .text = "error: arena: out of memory", .dim = true }) catch {};
                    return;
                };
                try self.submitTask(ctx, prompt);
            },
            .compare => try self.runCompare(ctx, pc.args),
            .theme => {
                // Bare `/theme` (or a fuzzy seed) opens the live-preview
                // picker menu; `/theme <exact-name>` still switches directly.
                if (pc.args.len == 0 or !theme_mod.isKnown(pc.args)) {
                    try self.openThemePicker(ctx, pc.args);
                    return;
                }
                self.theme_override = self.arena.dupe(u8, pc.args) catch pc.args;
                self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "notice: theme switched to {s}", .{pc.args}) catch "notice: theme switched", .dim = true }) catch {};
            },
            .plan => {
                if (toggleSessionMode(
                    self,
                    pc.args,
                    &self.plan_mode,
                    "usage: /plan [on|off] (bare /plan toggles)",
                    "notice: plan mode {s} (write-capable tools refused while on)",
                ) == .bad_usage) return;
            },
            .websearch => {
                if (toggleSessionMode(
                    self,
                    pc.args,
                    &self.research_mode,
                    "usage: /websearch [on|off] (bare /websearch toggles)",
                    "notice: web-research mode {s} (web_search/web_fetch preferred for current facts)",
                ) == .bad_usage) return;
            },
            .research => self.runResearchCommand(pc.args),
            .rfc => self.runRfcCommand(pc.args),
            .preset => {
                const name = std.mem.trim(u8, pc.args, " \t");
                // Blank-session-only guard, checked before either path so a
                // bare `/preset` never opens a picker the guard would refuse.
                if (self.messages.items.len > 1 or self.thread != null) {
                    self.lines.append(self.arena, .{ .text = "preset: only before any tool call or assistant message (blank session only)", .dim = true }) catch {};
                    return;
                }
                if (name.len == 0) {
                    try self.openPresetPicker(ctx);
                    return;
                }
                // Validate preset exists under presets/ (same helper CLI uses).
                var dir = std.Io.Dir.cwd().openDir(self.io, "presets", .{}) catch {
                    self.lines.append(self.arena, .{ .text = "preset: no presets/ directory", .dim = true }) catch {};
                    return;
                };
                defer dir.close(self.io);
                const preset = preset_mod.loadFromFile(self.io, self.arena, dir, name) catch |err| {
                    self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "preset '{s}' not found: {s}", .{ name, @errorName(err) }) catch "preset not found", .dim = true }) catch {};
                    return;
                };
                self.preset_name = self.arena.dupe(u8, name) catch name;
                _ = preset;
                self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "notice: preset switched to {s}", .{name}) catch "notice: preset switched", .dim = true }) catch {};
            },
            .effort => {
                const arg = std.mem.trim(u8, pc.args, " \t");
                if (std.mem.eql(u8, arg, "default")) {
                    self.cfg.agent.reasoning_effort = null;
                    self.lines.append(self.arena, .{ .text = "notice: reasoning effort back to default (pin cleared)", .dim = true }) catch {};
                    return;
                }
                if (config.ReasoningEffort.fromStr(arg)) |re| {
                    self.cfg.agent.reasoning_effort = re;
                    self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "notice: reasoning effort pinned to {s}", .{arg}) catch "notice: reasoning effort set", .dim = true }) catch {};
                    return;
                }
                // Bare `/effort` or an unrecognised spelling opens the picker
                // seeded with the spelling, so `high` is one Enter away.
                try self.openEffortPicker(ctx, arg);
            },
            .attach => {
                const path = std.mem.trim(u8, pc.args, " \t");
                if (path.len == 0) {
                    self.lines.append(self.arena, .{ .text = "usage: /attach <path>  (image queued for next submit)", .dim = true }) catch {};
                    return;
                }
                const max_images: usize = 4;
                const max_bytes: usize = 4 * 1024 * 1024;
                if (self.pending_attach_paths.items.len >= max_images) {
                    self.lines.append(self.arena, .{ .text = "attach: at most 4 images per message", .dim = true }) catch {};
                    return;
                }
                // Validate by opening and sizing — mirrors web limits.
                var file = std.Io.Dir.cwd().openFile(self.io, path, .{ .mode = .read_only }) catch {
                    self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "attach: cannot open '{s}'", .{path}) catch "attach: cannot open file", .dim = true }) catch {};
                    return;
                };
                defer file.close(self.io);
                const stat = file.stat(self.io) catch {
                    self.lines.append(self.arena, .{ .text = "attach: cannot stat file", .dim = true }) catch {};
                    return;
                };
                if (stat.size > max_bytes) {
                    self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "attach: file too large ({d} bytes, limit {d})", .{ stat.size, max_bytes }) catch "attach: file too large", .dim = true }) catch {};
                    return;
                }
                if (stat.kind == .directory) {
                    self.lines.append(self.arena, .{ .text = "attach: path is a directory", .dim = true }) catch {};
                    return;
                }
                const owned = self.arena.dupe(u8, path) catch return;
                self.pending_attach_paths.append(self.arena, owned) catch return;
                self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "attached: {s} ({d} queued)", .{ path, self.pending_attach_paths.items.len }) catch "attached", .dim = true }) catch {};
            },
            .workflows => {
                _ = self.runWorkflowsTool("");
            },
            .tui_plugins => {
                self.runTuiPlugins(pc.args);
            },
            .workflow => {
                if (pc.args.len == 0) {
                    self.lines.append(self.arena, .{ .text = "usage: /workflow <name> [args]: try /workflows to list", .dim = true }) catch {};
                    return;
                }
                const space = std.mem.findScalar(u8, pc.args, ' ');
                const wf_name = if (space) |i| std.mem.trim(u8, pc.args[0..i], " \t") else pc.args;
                const wf_args = if (space) |i| std.mem.trim(u8, pc.args[i + 1 ..], " \t") else "";
                const prompt = self.expandWorkflow(wf_name, wf_args) catch |err| {
                    self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "error: workflow '{s}': {s}", .{ wf_name, @errorName(err) }) catch "error: workflow failed", .dim = true }) catch {};
                    return;
                } orelse {
                    self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "error: no workflow named '{s}'; try /workflows", .{wf_name}) catch "error: unknown workflow", .dim = true }) catch {};
                    return;
                };
                defer self.gpa.free(prompt);
                try self.submitTask(ctx, prompt);
            },
            // /sessions, /graph, /status, /tools, and /plugins run the same internal
            // `cmd_*` WASM tools the CLI subcommands invoke, so the REPL is
            // not a walled-off corner of clanker. Output is folded into the
            // transcript as dim lines, exactly like a tool result.
            .tool => |t| _ = self.runInternalTool(t.name, if (t.forward_args and pc.args.len > 0) pc.args else t.args),
        }
    }

    /// `/compare`: put one prompt to several models at once and read the
    /// answers back with nothing saying which model wrote which.
    ///
    /// Starting one runs as an ordinary agent turn, for the reason `/arena`
    /// does — several multi-second calls that would otherwise freeze the REPL
    /// with nothing on screen. Reading one back calls the tool here and now:
    /// it is a file read, and a completion spent paraphrasing it would be slow,
    /// billed, and free to name the models the blind view is withholding.
    fn runCompare(self: *Model, ctx: *vxfw.EventContext, args: []const u8) !void {
        var argv_buf: [max_escape_args][]const u8 = undefined;
        const argv = splitShellArgs(args, &argv_buf) catch |err| {
            const msg = switch (err) {
                error.UnterminatedQuote => "error: compare: unbalanced quote in the arguments",
                error.TooManyArgs => "error: compare: too many arguments",
            };
            self.lines.append(self.arena, .{ .text = msg, .dim = true }) catch {};
            return;
        };

        switch (parseCompareCommand(argv)) {
            .usage => {
                appendDimBlock(self.arena, &self.lines, compare_command_help);
            },
            // No fields at all is the compare tool's own listing input.
            .list => _ = self.runToolJson("compare", "{}", false),
            .show => |s| {
                var buf: [1024]u8 = undefined;
                var w: std.Io.Writer = .fixed(&buf);
                var js = std.json.Stringify{ .writer = &w, .options = .{} };
                js.beginObject() catch return;
                js.objectField("id") catch return;
                js.write(s.id) catch return;
                if (s.pick.len > 0) {
                    js.objectField("pick") catch return;
                    js.write(s.pick) catch return;
                }
                js.endObject() catch return;
                _ = self.runToolJson("compare", buf[0..w.end], false);
            },
            .run => {
                const prompt = std.fmt.allocPrint(
                    self.arena,
                    "Run one blind model comparison with these arguments: {s}\n\n" ++
                        "Call the `compare` tool exactly once, mapping the flags onto its input fields " ++
                        "(each --with <provider> or --with <provider@model> becomes one entry in " ++
                        "\"targets\" as {{\"provider\": ..., \"model\": ...}} with \"model\" left out when " ++
                        "no @ was given, --judge -> \"judge\", --synthesize -> \"synthesize\": true, " ++
                        "--reveal -> \"reveal\": true), with the quoted text before the first flag as " ++
                        "\"prompt\". Then print the tool's \"text\" field verbatim as your whole answer. " ++
                        "Do not summarize it, re-rank the answers, or add commentary, and do not say " ++
                        "which model wrote which answer: the answers are shown unlabeled on purpose, " ++
                        "and naming them is the one thing that undoes the comparison.",
                    .{args},
                ) catch {
                    self.lines.append(self.arena, .{ .text = "error: compare: out of memory", .dim = true }) catch {};
                    return;
                };
                try self.submitTask(ctx, prompt);
            },
        }
    }

    /// Runs one internal `cmd_*` WASM tool ({"args":"<text>"} -> {"text":"..."})
    /// and folds its output into the transcript as dim lines. Returns true so
    /// submit treats it as handled.
    /// `/research <sub> [args...]`: the same store, subcommands and rendering
    /// as `clanker research`, folded into the transcript instead of stdout.
    /// The line is tokenized into the CLI's own Options and handed to
    /// `research_cmd.run`, so the tool input and the rendering stay one
    /// implementation across both surfaces.
    fn runResearchCommand(self: *Model, args_line: []const u8) void {
        const tokens = splitCommandLine(self.arena, args_line) catch {
            self.lines.append(self.arena, .{ .text = "error: /research: out of memory", .dim = true }) catch {};
            return;
        };
        var opts: research_cmd.Options = .{};
        if (tokens.len > 0) opts.sub = tokens[0];
        if (tokens.len > 1) opts.arg1 = tokens[1];
        if (tokens.len > 2) opts.arg2 = tokens[2];
        if (tokens.len > 3) opts.arg3 = tokens[3];
        if (tokens.len > 4) opts.arg4 = tokens[4];
        const text = research_cmd.run(self.arena, opts, .{ .ctx = self, .call = &researchToolCall }) catch |err| {
            const hint: []const u8 = switch (err) {
                research_cmd.Error.BadSubcommand, research_cmd.Error.MissingArg => "; same subcommands as clanker research",
                else => "",
            };
            self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "error: /research: {s}{s}", .{ @errorName(err), hint }) catch "error: /research failed", .dim = true }) catch {};
            return;
        };
        // Transcript entries hold one logical row each; never store '\n'.
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        while (it.next()) |line| self.lines.append(self.arena, .{ .text = line, .dim = true }) catch break;
    }

    fn researchToolCall(ctx: *anyopaque, input: []const u8) anyerror![]const u8 {
        const self: *Model = @ptrCast(@alignCast(ctx));
        const mod = try runtime.loadNamedTool(self.gpa, self.io, self.arena, self.ctx.environ_map, &self.cfg, &self.reg, "research", null);
        defer mod.deinit();
        const raw = try mod.executeTool(input);
        defer self.gpa.free(raw);
        return try self.arena.dupe(u8, raw);
    }

    /// `/rfc <sub> [args...]`: the same store, subcommands and rendering as
    /// `clanker rfc`, folded into the transcript instead of stdout. The line
    /// is tokenized into the CLI's own Options and handed to `rfc_cmd.run`,
    /// so the tool input and the rendering stay one implementation across
    /// both surfaces.
    fn runRfcCommand(self: *Model, args_line: []const u8) void {
        const tokens = splitCommandLine(self.arena, args_line) catch {
            self.lines.append(self.arena, .{ .text = "error: /rfc: out of memory", .dim = true }) catch {};
            return;
        };
        var opts: rfc_cmd.Options = .{};
        if (tokens.len > 0) opts.sub = tokens[0];
        if (tokens.len > 1) opts.arg1 = tokens[1];
        if (tokens.len > 2) opts.arg2 = tokens[2];
        if (tokens.len > 3) opts.arg3 = tokens[3];
        if (tokens.len > 4) opts.arg4 = tokens[4];
        const text = rfc_cmd.run(self.arena, opts, .{ .ctx = self, .call = &rfcToolCall }) catch |err| {
            const hint: []const u8 = switch (err) {
                rfc_cmd.Error.BadSubcommand, rfc_cmd.Error.MissingArg => "; same subcommands as clanker rfc",
                else => "",
            };
            self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "error: /rfc: {s}{s}", .{ @errorName(err), hint }) catch "error: /rfc failed", .dim = true }) catch {};
            return;
        };
        // Transcript entries hold one logical row each; never store '\n'.
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        while (it.next()) |line| self.lines.append(self.arena, .{ .text = line, .dim = true }) catch break;
    }

    fn rfcToolCall(ctx: *anyopaque, input: []const u8) anyerror![]const u8 {
        const self: *Model = @ptrCast(@alignCast(ctx));
        const mod = try runtime.loadNamedTool(self.gpa, self.io, self.arena, self.ctx.environ_map, &self.cfg, &self.reg, "rfc", null);
        defer mod.deinit();
        const raw = try mod.executeTool(input);
        defer self.gpa.free(raw);
        return try self.arena.dupe(u8, raw);
    }

    fn runInternalTool(self: *Model, tool_name: []const u8, args: []const u8) bool {
        var ibuf: [8192]u8 = undefined;
        var iw: std.Io.Writer = .fixed(&ibuf);
        var is = std.json.Stringify{ .writer = &iw, .options = .{} };
        is.beginObject() catch return true;
        is.objectField("args") catch return true;
        is.write(args) catch return true;
        is.endObject() catch return true;
        return self.runToolJson(tool_name, ibuf[0..iw.end], std.mem.eql(u8, tool_name, "plugins") and args.len > 0);
    }

    /// Runs any registered tool on a caller-built JSON input and folds its
    /// `text` into the transcript as dim lines. Split out of
    /// `runInternalTool` for the tools whose input is a structure rather than
    /// the `cmd_*` convention's one `args` string — `/compare --show <id>`
    /// sends `{"id": "..."}`, which no amount of `args` text expresses.
    ///
    /// Returns true so submit treats it as handled. A failure is reported in
    /// the transcript rather than bubbling: a broken tool should not take
    /// down the REPL, just be visible.
    fn runToolJson(self: *Model, tool_name: []const u8, input: []const u8, reload_plugins: bool) bool {
        const display_name = internalToolDisplayName(tool_name);
        const mod = runtime.loadNamedTool(
            self.gpa,
            self.io,
            self.arena,
            self.ctx.environ_map,
            &self.cfg,
            &self.reg,
            tool_name,
            null,
        ) catch |err| {
            const hint: []const u8 = if (err == error.ToolWasmMissing) "; run `zig build tools`" else "";
            self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "error: {s}: {s}{s}", .{ display_name, @errorName(err), hint }) catch "error: internal tool failed", .dim = true }) catch {};
            return true;
        };
        defer mod.deinit();

        const raw = mod.executeTool(input) catch |err| {
            self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "error: {s}: {s}", .{ display_name, @errorName(err) }) catch "error: internal tool failed", .dim = true }) catch {};
            return true;
        };
        defer self.gpa.free(raw);

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, self.arena, raw, .{ .ignore_unknown_fields = true }) catch {
            self.lines.append(self.arena, .{ .text = "error: internal tool returned unparseable output", .dim = true }) catch {};
            return true;
        };
        if (parsed != .object) {
            self.lines.append(self.arena, .{ .text = "error: internal tool returned an empty result", .dim = true }) catch {};
            return true;
        }
        var ok = false;
        if (parsed.object.get("ok")) |k| {
            if (k == .bool) ok = k.bool;
        }
        if (!ok) {
            const raw_detail = json_util.strFieldOrNull(parsed.object, "error") orelse "unknown";
            const detail = clean(self.arena, raw_detail) orelse "unknown";
            const extra = internalToolFailureHint(tool_name, detail);
            self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "error: {s}: {s}{s}", .{ display_name, detail, extra }) catch "error: internal tool failed", .dim = true }) catch {};
            return true;
        }
        const text = parsed.object.get("text") orelse parsed.object.get("markdown") orelse {
            self.lines.append(self.arena, .{ .text = "error: internal tool returned no text", .dim = true }) catch {};
            return true;
        };
        if (text != .string) {
            self.lines.append(self.arena, .{ .text = "error: internal tool returned no text", .dim = true }) catch {};
            return true;
        }
        // A tool's `text` is untrusted for the same reason a model's answer
        // is: `cmd_*` tools render file contents, session titles and plugin
        // manifests, none of which clanker wrote. Stripped once for the whole
        // block rather than per line, so a control byte cannot hide in the
        // split.
        const safe = clean(self.arena, text.string) orelse {
            self.lines.append(self.arena, .{ .text = "error: internal tool output dropped: out of memory", .dim = true }) catch {};
            return true;
        };
        _ = appendInternalToolOutput(self.arena, &self.lines, tool_name, safe);
        if (reload_plugins) {
            self.reg = registry.Registry.load(self.io, self.arena, std.Io.Dir.cwd(), self.cfg.agent.tools_dir) catch |err| {
                self.lines.append(self.arena, .{
                    .text = std.fmt.allocPrint(self.arena, "error: plugin state changed, but the REPL could not reload tools: {s}; restart `clanker repl`", .{@errorName(err)}) catch "error: plugin state changed, but the REPL could not reload tools; restart `clanker repl`",
                    .dim = true,
                }) catch {};
                return true;
            };
            self.tool_defs = self.reg.toToolDefs(self.arena) catch |err| {
                self.lines.append(self.arena, .{
                    .text = std.fmt.allocPrint(self.arena, "error: plugin state changed, but the REPL could not rebuild its tool catalog: {s}; restart `clanker repl`", .{@errorName(err)}) catch "error: plugin state changed, but the REPL could not rebuild its tool catalog; restart `clanker repl`",
                    .dim = true,
                }) catch {};
                return true;
            };
        }
        return true;
    }

    /// The command allowlist the `!` escape runs under: the union of every
    /// registered tool's manifest `exec_allow`, plus anything named in
    /// `agent.repl_exec_allow`. Derived rather than invented, so `!` starts
    /// with exactly the exec authority clanker already grants itself and not a
    /// byte more; widening it is one explicit config line, not a hidden
    /// default. Sorted so `!` on its own lists it readably, and rebuilt per
    /// call because `/plugins` can reload the registry mid-session.
    fn escapeExecAllow(self: *Model) []const []const u8 {
        return self.reg.execAllowUnion(self.arena, self.cfg.agent.repl_exec_allow) catch &.{};
    }

    /// Runs one `!` line and folds the result into the transcript. Never
    /// fails outward: a refused, broken or noisy command is a transcript line,
    /// not something that takes the session down.
    fn runShellEscape(self: *Model, line: []const u8) void {
        // Like submitting a task, this snaps a scrolled-up view back to the
        // tail, the output lands there and hiding it reads as a no-op Enter.
        self.view_end = null;
        const allow = self.escapeExecAllow();

        if (line.len == 0) {
            self.lines.append(self.arena, .{ .text = "usage: !<command> [args]: runs here under the ck_exec policy, not in a shell", .dim = true }) catch {};
            if (allow.len == 0) {
                self.lines.append(self.arena, .{ .text = "  nothing is allowed: no registered tool declares exec_allow, and agent.repl_exec_allow is empty", .dim = true }) catch {};
                return;
            }
            var list: std.ArrayList(u8) = .empty;
            list.appendSlice(self.arena, "  allowed: ") catch {};
            for (allow, 0..) |cmd, i| {
                if (i > 0) list.appendSlice(self.arena, ", ") catch {};
                list.appendSlice(self.arena, cmd) catch {};
            }
            self.lines.append(self.arena, .{ .text = list.items, .dim = true }) catch {};
            self.lines.append(self.arena, .{ .text = "  add more with agent.repl_exec_allow in config.local.toml", .dim = true }) catch {};
            return;
        }

        // Echoed, and recalled by Up, exactly as typed: a screenful of command
        // output with nothing above it saying what produced it is unreadable
        // on scrollback.
        const typed = std.fmt.allocPrint(self.arena, "!{s}", .{line}) catch "!";
        self.lines.append(self.arena, .{
            .text = std.fmt.allocPrint(self.arena, "clanker> {s}", .{typed}) catch "clanker> !",
            .user = true,
        }) catch {};
        self.history.append(self.arena, typed) catch {};
        self.hist_idx = self.history.items.len;
        self.hist_draft = "";

        var argv_buf: [max_escape_args][]const u8 = undefined;
        const argv = splitShellArgs(line, &argv_buf) catch |err| {
            self.lines.append(self.arena, .{ .text = switch (err) {
                error.UnterminatedQuote => "error: !: unterminated quote; quote a whole argument, e.g. !rg \"foo bar\"",
                error.TooManyArgs => "error: !: too many arguments",
            }, .dim = true }) catch {};
            return;
        };
        if (argv.len == 0) return;

        // The escape's own sandbox: no filesystem prefixes and no network,
        // because `execUnderPolicy` uses neither, what it does use is
        // exec_allow, the deny tokens, git's verb allowlist, and the filtered
        // child environment, which is why an allowed binary still cannot read
        // this project's API keys out of the process env.
        var sb: sandbox_host.Sandbox = .{
            .gpa = self.gpa,
            .io = self.io,
            .root_dir = self.cfg.agent.sandbox_root,
            .shared_root = self.cfg.agent.shared_root,
            .network_allow = &.{},
            .fs_prefixes = &.{},
            .environ_map = self.ctx.environ_map,
            .exec_allow = allow,
            .git_remote_ops = self.cfg.agent.git_remote_ops,
            .exec_pattern_allow = self.cfg.agent.exec_pattern_allow,
            .cfg = &self.cfg,
        };

        switch (sandbox_host.execUnderPolicy(&sb, argv, escape_stdout_limit, escape_stderr_limit)) {
            .not_allowed => self.lines.append(self.arena, .{
                .text = std.fmt.allocPrint(
                    self.arena,
                    "error: ! '{s}' is not on the exec allowlist; type ! on its own to see what is, or add it to agent.repl_exec_allow",
                    .{argv[0]},
                ) catch "error: ! not allowed",
                .dim = true,
            }) catch {},
            .denied => |d| {
                const msg = switch (d) {
                    .git_verb => std.fmt.allocPrint(self.arena, "error: ! git: only the local verbs are allowed (status, diff, log, show, add, commit, ls-files, rev-parse, branch, worktree)", .{}),
                    .zig_verb => std.fmt.allocPrint(self.arena, "error: ! zig: only ast-check, fmt --check, test, and build are allowed", .{}),
                    .uv_verb => std.fmt.allocPrint(self.arena, "error: ! uv: only `uv run` of tools/py/opencv.py is allowed", .{}),
                    .no_pattern_match => std.fmt.allocPrint(self.arena, "error: ! '{s}': agent.exec_pattern_allow makes this command strict and no pattern matches", .{argv[0]}),
                    .deny_token => |x| std.fmt.allocPrint(self.arena, "error: ! '{s}': denied, '{s}' in '{s}' is on the sandbox deny list", .{ argv[0], x.token, x.arg }),
                    .shell_operator => |x| std.fmt.allocPrint(self.arena, "error: ! '{s}': denied, shell operator '{s}' in '{s}'; ! does not run a shell", .{ argv[0], x.token, x.arg }),
                    .foreign_worktree => |a| std.fmt.allocPrint(self.arena, "error: ! '{s}': denied, '{s}' reaches into another run's worktree; this run's tree is '.'", .{ argv[0], a }),
                    .host_path => |a| std.fmt.allocPrint(self.arena, "error: ! '{s}': denied, '{s}' is a path outside the sandbox", .{ argv[0], a }),
                    .git_config => |a| std.fmt.allocPrint(self.arena, "error: ! '{s}': denied, '{s}' would make git run guest-chosen code (config injection / alternate git dir); -C and --work-tree are the supported forms", .{ argv[0], a }),
                };
                self.lines.append(self.arena, .{ .text = msg catch "error: ! denied", .dim = true }) catch {};
            },
            .failed => |err| self.lines.append(self.arena, .{
                .text = std.fmt.allocPrint(self.arena, "error: ! '{s}': {s}", .{ argv[0], @errorName(err) }) catch "error: ! failed",
                .dim = true,
            }) catch {},
            .ran => |out| {
                defer out.deinit(self.gpa);
                var budget: usize = command_output_max_lines;
                self.appendEscapeOutput(out.stdout, &budget);
                self.appendEscapeOutput(out.stderr, &budget);
                // A silent non-zero exit reads as "it worked"; say it. Zero
                // with no output stays silent, which is what a successful
                // `!git add x` should look like.
                if (out.code != 0) {
                    self.lines.append(self.arena, .{
                        .text = std.fmt.allocPrint(self.arena, "error: ! exited with status {d}", .{out.code}) catch "error: ! failed",
                        .dim = true,
                    }) catch {};
                }
            },
        }
    }

    /// Folds one output stream into the transcript, one line per source line,
    /// spending from a shared line budget so a chatty command cannot bury the
    /// conversation. Untrusted text, exactly like a tool result: control bytes
    /// are stripped before anything reaches the terminal (CWE-150), the same
    /// rule `transcript.zig` applies everywhere else.
    fn appendEscapeOutput(self: *Model, text: []const u8, budget: *usize) void {
        if (text.len == 0) return;
        // One trailing newline is a line terminator, not an empty last line.
        const body = if (text[text.len - 1] == '\n') text[0 .. text.len - 1] else text;
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |raw| {
            if (budget.* == 0) {
                self.lines.append(self.arena, .{ .text = "notice: ! output truncated", .dim = true }) catch {};
                return;
            }
            budget.* -= 1;
            const safe = clean(self.gpa, raw) orelse continue;
            defer if (safe.ptr != raw.ptr) self.gpa.free(safe);
            const owned = self.arena.dupe(u8, safe) catch continue;
            self.lines.append(self.arena, .{ .text = owned, .dim = true }) catch {};
        }
    }

    fn runWorkflowsTool(self: *Model, name: []const u8) bool {
        const wfs = workflows_mod.loadAllMerged(self.arena, self.io, self.cfg.agent.workflows_dir) catch |err| {
            self.lines.append(self.arena, .{
                .text = std.fmt.allocPrint(self.arena, "error: could not list workflows from {s}: {s}; check agent.workflows_dir", .{ self.cfg.agent.workflows_dir, @errorName(err) }) catch "error: could not list workflows; check agent.workflows_dir",
                .dim = true,
            }) catch {};
            return true;
        };
        if (name.len == 0) {
            if (wfs.len == 0) {
                self.lines.append(self.arena, .{
                    .text = std.fmt.allocPrint(self.arena, "notice: no workflows found; add Markdown files to {s}", .{self.cfg.agent.workflows_dir}) catch "notice: no workflows found",
                    .dim = true,
                }) catch {};
                return true;
            }
            for (wfs) |wf| {
                const line = if (wf.arg_hint.len > 0)
                    std.fmt.allocPrint(self.arena, "  {s} {s}: {s}", .{ wf.name, wf.arg_hint, wf.description }) catch continue
                else
                    std.fmt.allocPrint(self.arena, "  {s}: {s}", .{ wf.name, wf.description }) catch continue;
                self.lines.append(self.arena, .{ .text = line, .dim = true }) catch {};
            }
            self.lines.append(self.arena, .{ .text = "  (run one with /workflow <name> [args])", .dim = true }) catch {};
            return true;
        }
        return true;
    }

    /// (Re)builds plugin_command_specs from agent.tui_plugins_dir, honoring
    /// the enabled-list in state/tui_plugins.json (PRD 0012). Called at REPL
    /// startup and after every /tui-plugins toggle, so a plugin's commands
    /// appear and disappear live, without a restart.
    fn reloadTuiPlugins(self: *Model) void {
        plugin_command_specs = &.{};
        // The built-in spellings (leading slash included) a plugin may not
        // shadow; a manifest colliding with one is refused at scan time.
        var builtin_names: std.ArrayList([]const u8) = .empty;
        for (&command_registry) |*spec| {
            builtin_names.append(self.arena, spec.name) catch return;
            for (spec.aliases) |alias| builtin_names.append(self.arena, alias) catch return;
        }
        const enabled = slash_plugins.loadEnabled(self.io, self.arena);
        const manifests = slash_plugins.loadEnabledManifests(
            self.io,
            self.arena,
            std.Io.Dir.cwd(),
            self.cfg.agent.tui_plugins_dir,
            enabled,
            builtin_names.items,
        ) catch |err| {
            log.log(.warn, "repl: could not load TUI plugins from {s}: {s}", .{ self.cfg.agent.tui_plugins_dir, @errorName(err) });
            return;
        };
        var specs: std.ArrayList(CommandSpec) = .empty;
        for (manifests) |m| {
            const name = std.fmt.allocPrint(self.arena, "/{s}", .{m.command}) catch continue;
            // The same .tool action a built-in tool-dispatching command uses:
            // fixed args when the user typed none, forwarded args otherwise.
            // Dispatch needs no new arm.
            specs.append(self.arena, .{
                .name = name,
                .help = m.help,
                .takes_args = true,
                .arg_hint = "[args]",
                .action = .{ .tool = .{ .name = m.tool, .args = m.args, .forward_args = true } },
            }) catch continue;
        }
        plugin_command_specs = specs.toOwnedSlice(self.arena) catch return;
    }

    /// /tui-plugins: list every discovered plugin with its on/off state, or
    /// toggle one in state/tui_plugins.json and reload the command set.
    fn runTuiPlugins(self: *Model, args: []const u8) void {
        const trimmed = std.mem.trim(u8, args, " \t");
        if (trimmed.len == 0) {
            var builtin_names: std.ArrayList([]const u8) = .empty;
            for (&command_registry) |*spec| {
                builtin_names.append(self.arena, spec.name) catch return;
                for (spec.aliases) |alias| builtin_names.append(self.arena, alias) catch return;
            }
            const enabled = slash_plugins.loadEnabled(self.io, self.arena);
            const all = slash_plugins.scanAll(
                self.io,
                self.arena,
                std.Io.Dir.cwd(),
                self.cfg.agent.tui_plugins_dir,
                builtin_names.items,
            ) catch |err| {
                self.lines.append(self.arena, .{
                    .text = std.fmt.allocPrint(self.arena, "error: could not scan {s}: {s}", .{ self.cfg.agent.tui_plugins_dir, @errorName(err) }) catch "error: could not scan TUI plugins",
                    .dim = true,
                }) catch {};
                return;
            };
            if (all.len == 0) {
                self.lines.append(self.arena, .{
                    .text = std.fmt.allocPrint(self.arena, "notice: no TUI plugins in {s}; drop a JSON manifest (command, help, tool keys) there and enable it with /tui-plugins on <name>", .{self.cfg.agent.tui_plugins_dir}) catch "notice: no TUI plugins found",
                    .dim = true,
                }) catch {};
                return;
            }
            for (all) |m| {
                const state: []const u8 = if (slash_plugins.isEnabled(enabled, m.command)) "on" else "off";
                self.lines.append(self.arena, .{
                    .text = std.fmt.allocPrint(self.arena, "  /{s} [{s}] -> {s}  {s}", .{ m.command, state, m.tool, m.help }) catch continue,
                    .dim = true,
                }) catch {};
            }
            self.lines.append(self.arena, .{ .text = "  toggle with /tui-plugins on|off <name>", .dim = true }) catch {};
            return;
        }
        const space = std.mem.findScalar(u8, trimmed, ' ');
        const verb = if (space) |i| trimmed[0..i] else trimmed;
        const name = if (space) |i| std.mem.trim(u8, trimmed[i + 1 ..], " \t") else "";
        const want: ?bool = if (std.mem.eql(u8, verb, "on"))
            true
        else if (std.mem.eql(u8, verb, "off"))
            false
        else
            null;
        if (want == null or name.len == 0) {
            self.lines.append(self.arena, .{ .text = "usage: /tui-plugins [on|off <name>]  (bare lists plugins)", .dim = true }) catch {};
            return;
        }
        var enabled_list: std.ArrayList([]const u8) = .empty;
        const current = slash_plugins.loadEnabled(self.io, self.arena);
        for (current) |n| enabled_list.append(self.arena, n) catch return;
        if (want.?) {
            if (!slash_plugins.isEnabled(current, name))
                enabled_list.append(self.arena, self.arena.dupe(u8, name) catch return) catch return;
        } else {
            var i: usize = 0;
            while (i < enabled_list.items.len) {
                if (std.mem.eql(u8, enabled_list.items[i], name)) {
                    _ = enabled_list.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }
        slash_plugins.saveEnabled(self.io, self.gpa, enabled_list.items) catch |err| {
            self.lines.append(self.arena, .{
                .text = std.fmt.allocPrint(self.arena, "error: could not write state/tui_plugins.json: {s}", .{@errorName(err)}) catch "error: could not write TUI plugin state",
                .dim = true,
            }) catch {};
            return;
        };
        self.reloadTuiPlugins();
        // The palette was built at startup; rebuild it so Ctrl-P reflects the
        // change without a restart.
        self.command_candidates = buildCommandCandidates(self.arena) catch self.command_candidates;
        self.lines.append(self.arena, .{
            .text = std.fmt.allocPrint(self.arena, "tui plugin /{s}: {s}", .{ name, if (want.?) "on" else "off" }) catch "tui plugin toggled",
            .dim = true,
        }) catch {};
    }

    fn expandWorkflow(self: *Model, name: []const u8, args: []const u8) !?[]u8 {
        const wfs = try workflows_mod.loadAllMerged(self.arena, self.io, self.cfg.agent.workflows_dir);
        const wf = workflows_mod.findByName(wfs, name) orelse return null;
        const expanded = try workflows_mod.instantiate(self.arena, wf.body, args);
        return try self.gpa.dupe(u8, expanded);
    }

    /// Starts a continuing goal loop through the agent, exactly like
    /// `clanker goal "<prompt>"`. Only this path creates a board goal —
    /// ordinary chat never does. The Ready card is persisted before the loop
    /// starts so the board mirror has a source; the kanban Ready card is
    /// created here too so the board shows it even without the web mirror.
    /// Calls `goal_add` and returns the id of the record it wrote.
    ///
    /// Every step is an error rather than a null: this write is what makes
    /// `/goal` a goal rather than an ordinary run, so the caller has to be
    /// able to tell the operator which part of it did not happen. It used to
    /// be a stack of `catch null` and `if (...) |x|` that ended in nothing.
    fn persistGoal(self: *Model, intent: []const u8) ![]const u8 {
        const input = try std.fmt.allocPrint(self.arena, "{{\"objective\":{f}}}", .{std.json.fmt(intent, .{})});
        const mod = try runtime.loadNamedTool(self.gpa, self.io, self.arena, self.ctx.environ_map, &self.cfg, &self.reg, "goal_add", null);
        defer mod.deinit();
        const raw = try mod.executeTool(input);
        defer self.gpa.free(raw);

        const val = std.json.parseFromSliceLeaky(std.json.Value, self.arena, raw, .{ .ignore_unknown_fields = true }) catch
            return error.GoalAddReplyNotJson;
        if (val != .object) return error.GoalAddReplyNotJson;
        const ok = val.object.get("ok") orelse return error.GoalAddRefused;
        if (ok != .bool or !ok.bool) return error.GoalAddRefused;
        const goal = val.object.get("goal") orelse return error.GoalAddReplyNotJson;
        if (goal != .object) return error.GoalAddReplyNotJson;
        const id = goal.object.get("id") orelse return error.GoalAddReplyNotJson;
        if (id != .string or id.string.len == 0) return error.GoalAddReplyNotJson;
        return id.string;
    }

    /// The Ready card mirroring a goal already written by `persistGoal`. The
    /// goal record survives without it, so a failure here is a warning and not
    /// a refusal — but the board is where the operator looks for the goal, so
    /// it is not a silent one either.
    fn createGoalCard(self: *Model, intent: []const u8, goal_id: []const u8) void {
        const title = utf8.cap(intent, 512);
        const input = std.fmt.allocPrint(
            self.arena,
            "{{\"op\":\"create\",\"title\":{f},\"column\":\"ready\",\"goal\":{f}}}",
            .{ std.json.fmt(title, .{}), std.json.fmt(goal_id, .{}) },
        ) catch |err| return self.noteGoalFailure("board card not created", err);
        const mod = runtime.loadNamedTool(self.gpa, self.io, self.arena, self.ctx.environ_map, &self.cfg, &self.reg, "kanban", null) catch |err|
            return self.noteGoalFailure("board card not created", err);
        defer mod.deinit();
        const raw = mod.executeTool(input) catch |err| return self.noteGoalFailure("board card not created", err);
        self.gpa.free(raw);
    }

    /// The REPL owns the screen and raises the log threshold to `.error_`
    /// before the alt screen exists, so anything the operator has to see about
    /// a failed write goes in the transcript rather than to stderr.
    fn noteGoalFailure(self: *Model, what: []const u8, err: anyerror) void {
        const line = std.fmt.allocPrint(self.arena, "warning: {s} ({s})", .{ what, @errorName(err) }) catch what;
        self.lines.append(self.arena, .{ .text = line, .dim = true }) catch {};
    }

    fn runGoalTask(self: *Model, ctx: *vxfw.EventContext, intent: []const u8) bool {
        if (self.persistGoal(intent)) |gid| {
            self.createGoalCard(intent, gid);
        } else |err| {
            // The loop still starts -- the operator asked for the work, not
            // for the bookkeeping -- but saying nothing left them watching a
            // goal run with no goal on the board and no way to know why.
            self.noteGoalFailure("goal not saved", err);
        }
        const task = goal_prompt.task(self.arena, intent) catch return true;
        self.submitTaskWithGoal(ctx, task, intent) catch |err| {
            self.lines.append(self.arena, .{
                .text = std.fmt.allocPrint(self.arena, "error: could not start goal task: {s}", .{@errorName(err)}) catch "error: could not start goal task",
                .dim = true,
            }) catch {};
            return true;
        };
        return true;
    }

    /// Runs the draft-only goal writer locally. The TUI has no inline
    /// ask_user UI yet, so the tool records any unanswered forks as explicit
    /// assumptions rather than silently persisting or inventing a goal.
    fn runWriteGoal(self: *Model, intent: []const u8) bool {
        const input = std.fmt.allocPrint(self.arena, "{{\"intent\":{f}}}", .{std.json.fmt(intent, .{})}) catch {
            self.lines.append(self.arena, .{ .text = "error: could not prepare write-goal draft", .dim = true }) catch {};
            return true;
        };
        return self.runToolJson("goal_write", input, false);
    }

    /// `/add-goal` persists an explicitly structured goal and deliberately
    /// does not submit an agent task. ` :: ` keeps the two required strings
    /// unambiguous in a single TUI command line.
    fn runAddGoal(self: *Model, args: []const u8) bool {
        const pair = splitAddGoalArgs(args) orelse {
            self.lines.append(self.arena, .{ .text = "usage: /add-goal <objective> :: <completion criterion>", .dim = true }) catch {};
            return true;
        };
        const input = std.fmt.allocPrint(
            self.arena,
            "{{\"objective\":{f},\"completion_criterion\":{f}}}",
            .{ std.json.fmt(pair.objective, .{}), std.json.fmt(pair.completion_criterion, .{}) },
        ) catch {
            self.lines.append(self.arena, .{ .text = "error: could not prepare add-goal input", .dim = true }) catch {};
            return true;
        };
        return self.runToolJson("goal_add", input, false);
    }

    /// The tail of `submit` that runs a task: echoes it, records it in
    /// history, and spawns the worker thread. Extracted so slash commands like
    /// /goal can submit a synthesized task without duplicating the plumbing.
    ///
    /// self.thread is assigned here and read by finishTurn on the background
    /// thread (to detach itself); spawning and storing the handle under the
    /// same lock finishTurn locks before reading it gives that read a
    /// happens-after relationship to this write. Doing the assignment outside
    /// the lock let a background thread that fails fast in Agent.init race
    /// finishTurn's read of self.thread against this store, seeing it still
    /// null and leaking the handle.
    fn submitTask(self: *Model, ctx: *vxfw.EventContext, task: []const u8) !void {
        return self.submitTaskWithGoal(ctx, task, null);
    }

    /// Shared task-submission plumbing. A non-null `goal_condition` turns
    /// the spawned worker into a continuing goal loop; ordinary chat tasks
    /// remain one agent turn.
    fn submitTaskWithGoal(self: *Model, ctx: *vxfw.EventContext, task: []const u8, goal_condition: ?[]const u8) !void {
        // Submitting snaps a scrolled-up view back to the tail: the echoed
        // task and the streamed reply land there, and hiding them behind a
        // frozen window would make Enter look like it did nothing.
        self.view_end = null;
        // One transcript entry per line of the task: each Line is one logical
        // row (see the draw loop), and an embedded '\n' in an entry is a
        // control byte the cell writers must never see.
        {
            var task_lines = std.mem.splitScalar(u8, task, '\n');
            var first_line = true;
            while (task_lines.next()) |seg| {
                const text = if (first_line)
                    try std.fmt.allocPrint(self.arena, "clanker> {s}", .{seg})
                else
                    try self.arena.dupe(u8, seg);
                self.lines.append(self.arena, .{ .text = text, .user = true }) catch {};
                first_line = false;
            }
        }
        self.history.append(self.arena, try self.arena.dupe(u8, task)) catch {};
        self.hist_idx = self.history.items.len;
        self.hist_draft = "";

        bridge_mutex.lockUncancelable(bridge_io);
        defer bridge_mutex.unlock(bridge_io);
        bridge_streaming = true;
        bridge_stream_buf.clearRetainingCapacity();
        bridge_tool_lines.clearRetainingCapacity();
        resetBridgeLive();
        bridge_live_started_ns = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        self.session_turns +|= 1;
        // A steering message typed against the turn that just ended must not
        // leak into this one, the composer-as-steer-box only queues while
        // streaming, but a message can land between the last poll and here.
        clearBridgeSteer();
        bridge_stop_flag.store(false, .release);
        bridge_turn_done.store(false, .release);
        errdefer bridge_streaming = false;
        // Baseline for the mid-turn compaction check the tick handler makes
        // once the worker is joined.
        self.summary_before = stats_mod.summaryState(self.messages.items);

        const owned_task = try self.arena.dupe(u8, task);
        // Drain pending image attachments for this run; submit clears them so
        // a later turn never re-sends an old attachment. Mirrors the web path
        // where the composer clears after submit.
        const attach_len = self.pending_attach_paths.items.len;
        var pending_images: ?[]types.ImagePart = null;
        if (attach_len > 0) {
            var parts: std.ArrayList(types.ImagePart) = .empty;
            for (self.pending_attach_paths.items) |apath| {
                // Raw bytes are gpa-owned and freed here: only the base64 is
                // sent, so keeping the original in the session arena held a
                // second full copy of every attachment for the rest of the
                // session (up to 4 MiB apiece, on top of the ~1.33x encoding).
                const buf = std.Io.Dir.cwd().readFileAlloc(self.io, apath, self.gpa, .limited(4 * 1024 * 1024 + 1)) catch continue;
                defer self.gpa.free(buf);
                if (buf.len == 0 or buf.len > 4 * 1024 * 1024) continue;
                const mime = if (std.mem.endsWith(u8, apath, ".png")) "image/png" else if (std.mem.endsWith(u8, apath, ".jpg") or std.mem.endsWith(u8, apath, ".jpeg")) "image/jpeg" else if (std.mem.endsWith(u8, apath, ".webp")) "image/webp" else "image/png";
                const enc = std.base64.standard.Encoder;
                const b64_buf = self.arena.alloc(u8, enc.calcSize(buf.len)) catch continue;
                const b64 = enc.encode(b64_buf, buf);
                parts.append(self.arena, .{ .mime = mime, .b64 = b64 }) catch continue;
            }
            if (parts.items.len > 0) pending_images = parts.items;
            self.pending_attach_paths.clearRetainingCapacity();
        }
        if (self.session_title.len == 0) {
            var title_buf: [session_mod.title_max]u8 = undefined;
            const t = session_mod.titleFromTask(&title_buf, owned_task);
            self.session_title = try self.arena.dupe(u8, t);
        }
        self.thread = try std.Thread.spawn(.{}, runThreadMain, .{RunThreadArgs{
            .model = self,
            .task = owned_task,
            .pending_images = pending_images,
            .goal_condition = if (goal_condition) |condition| try self.arena.dupe(u8, condition) else null,
        }});

        // Kick off the tick heartbeat that picks up streamed deltas -- unless
        // the mascot's own heartbeat is already running, in which case the
        // tick arm re-aims it at `stream_tick_ms` on its next delivery. Arming
        // a second one here is what left two timers running forever.
        if (!self.timer_armed) {
            self.timer_armed = true;
            try ctx.tick(stream_tick_ms, self.widget());
        }
    }

    /// Writes the conversation to `state/sessions/<id>.json` so a later
    /// `--session <id>` or `--continue` resumes it. Called once when the app
    /// is about to return (every quit path, /quit, Ctrl-C while idle, ends
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

        // `.error_` and not `.warn` on every failure below: this runs from the
        // exit path, past `log.setLevel(.error_)`, so a `.warn` is dropped and
        // the operator is told nothing at all while the whole conversation is
        // lost. That is the same bug the comment above that `setLevel` call
        // records for the mint failure.
        const id = self.session_id orelse (mintSessionId(self.io, self.arena) catch {
            log.log(.error_, "repl: could not mint a session id; conversation not saved", .{});
            return;
        });
        if (!session_mod.validSessionId(id)) {
            log.log(.error_, "repl: refusing to save under invalid session id '{s}'", .{id});
            return;
        }

        // The system prompt and the tool-call plumbing are internal; the
        // saved transcript is the user/assistant conversation, the same shape
        // `clanker run` writes and `loadSession` reads back (tool-call records
        // stay so a resumed session replays them into the model's history).
        var transcript: std.ArrayList(types.Message) = .empty;
        for (self.messages.items) |m| {
            if (m.role == .system) continue;
            // Swallowing this wrote a *shorter* transcript over the session
            // file and reported nothing: the turns that failed to append were
            // gone from disk with the file still looking saved. A partial
            // conversation is worse than the one already on disk.
            transcript.append(self.arena, m) catch |err| {
                log.log(.error_, "repl: session '{s}' not saved: transcript incomplete ({s})", .{ id, @errorName(err) });
                return;
            };
        }
        const title = if (self.session_title.len > 0) self.session_title else blk: {
            var title_buf: [session_mod.title_max]u8 = undefined;
            break :blk self.arena.dupe(u8, session_mod.titleFromTask(&title_buf, session_mod.titleSource(transcript.items, ""))) catch "";
        };
        const updated: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .real).nanoseconds, 1_000_000_000));
        session_mod.saveSession(self.io, self.gpa, self.arena, "state/sessions", .{
            .id = id,
            .title = title,
            .messages = transcript.items,
            .created = if (self.session_created != 0) self.session_created else updated,
            .updated = updated,
            .system_prompt = self.session_system_prompt,
        }) catch |err| {
            log.log(.error_, "repl: session '{s}' not saved: {s}", .{ id, @errorName(err) });
            return;
        };
        self.session_id = id;
    }

    /// The command list is generated from `command_registry`
    /// (`buildCommandHelp`), so a registry entry can never go undocumented:
    /// the property the deleted REPL's generated `:help` had
    /// (docs/prds/0005-repl-tui.md). The `!` escape and the key bindings stay
    /// hand-written here for the same reason as each other: neither is
    /// dispatched through the registry (the escape is intercepted ahead of it,
    /// the keys are wired in the event handler), so neither has a registry
    /// entry to generate a line from.
    fn printHelp(self: *Model) void {
        const commands = buildCommandHelp(self.arena) catch return;
        var it = std.mem.splitScalar(u8, commands, '\n');
        while (it.next()) |line| self.lines.append(self.arena, .{ .text = line, .dim = !isSectionHeader(line) }) catch {};
        var eit = std.mem.splitScalar(u8, shell_escape_help, '\n');
        while (eit.next()) |line| self.lines.append(self.arena, .{ .text = line, .dim = !isSectionHeader(line) }) catch {};
        var kit = std.mem.splitScalar(u8, keys_help, '\n');
        while (kit.next()) |line| self.lines.append(self.arena, .{ .text = line, .dim = !isSectionHeader(line) }) catch {};
    }

    /// A help section header: "Commands:", "Keys:", "Shell escape:" (no leading
    /// whitespace, trailing colon). Rendered at normal weight so the three
    /// sections are visually distinct from their dim content lines.
    fn isSectionHeader(line: []const u8) bool {
        return line.len > 1 and line[0] != ' ' and line[line.len - 1] == ':';
    }

    /// Takes keyboard focus for the modal.
    ///
    /// `vxfw` delivers a key press to the focused widget, and the composer
    /// (`text_field`) has held focus since `.init`. `TextField` consumes
    /// every printable key, so while it stayed focused the root Model's
    /// `handlePickerKey` only ever saw the keys the field ignores — arrows,
    /// Enter, Escape. Typed characters and Backspace went into the composer
    /// behind the modal instead of into `picker_query`, so the query line
    /// every picker draws could not be typed into at all, and the fuzzy
    /// filter was unreachable except through a seed argument
    /// (`/model kimi`). Moving focus to the Model for the life of the modal
    /// is what makes the picker a picker; `closeModelPicker` hands it back.
    fn focusPicker(self: *Model, ctx: *vxfw.EventContext) !void {
        try ctx.requestFocus(self.widget());
    }

    fn openModelPicker(self: *Model, ctx: *vxfw.EventContext, seed_query: []const u8) !void {
        try self.focusPicker(ctx);
        self.picker_kind = .model;
        self.picker_open = true;
        self.picker_query.clearRetainingCapacity();
        self.picker_query.appendSlice(self.arena, seed_query) catch {};
        self.picker_selected = 0;
    }

    /// The theme picker: same modal, but the list is the theme names and the
    /// selection previews live (the whole REPL repaints in the highlighted
    /// theme as you arrow through it). Escape restores what was active before.
    fn openThemePicker(self: *Model, ctx: *vxfw.EventContext, seed_query: []const u8) !void {
        try self.focusPicker(ctx);
        self.picker_kind = .theme;
        self.picker_open = true;
        self.theme_saved = self.theme_override;
        self.picker_query.clearRetainingCapacity();
        self.picker_query.appendSlice(self.arena, seed_query) catch {};
        self.picker_selected = 0;
        self.previewSelectedTheme();
    }

    /// The command palette: the same modal, listing every slash command and
    /// filtering it with the same subsequence match `/model` uses. Distinct
    /// from Tab-complete, which extends a prefix of a name already typed;
    /// this finds a command mid-word ("mdl") or by what it does ("switch"),
    /// which is what the fuzzy-palette gap in docs/prds/0005-repl-tui.md
    /// asked for.
    fn openCommandPalette(self: *Model, ctx: *vxfw.EventContext, seed_query: []const u8) !void {
        try self.focusPicker(ctx);
        self.picker_kind = .command;
        self.picker_open = true;
        self.picker_query.clearRetainingCapacity();
        self.picker_query.appendSlice(self.arena, seed_query) catch {};
        self.picker_selected = 0;
    }

    /// The effort picker: same modal over the five wire levels plus `default`.
    /// The header names where the current effort comes from, and the current
    /// level (or `default`, when nothing is pinned) is marked. No live preview:
    /// an effort change only lands in the next turn's `classifyEffort`, so
    /// there is nothing to repaint until Enter.
    fn openEffortPicker(self: *Model, ctx: *vxfw.EventContext, seed_query: []const u8) !void {
        try self.focusPicker(ctx);
        self.picker_kind = .effort;
        self.picker_open = true;
        self.picker_query.clearRetainingCapacity();
        self.picker_query.appendSlice(self.arena, seed_query) catch {};
        self.picker_selected = 0;
    }

    /// The preset picker: same modal over `presets/*.toml`, name plus its
    /// `description` line as the preview. Loads the directory at open time so
    /// a preset scaffolded mid-session appears without a restart.
    fn openPresetPicker(self: *Model, ctx: *vxfw.EventContext) !void {
        try self.focusPicker(ctx);
        self.picker_kind = .preset;
        self.picker_open = true;
        self.picker_query.clearRetainingCapacity();
        self.picker_selected = 0;
        self.preset_candidates = buildPresetCandidates(self.arena, self.io) catch &.{};
    }

    /// Commands whose spelling or help text matches the query, in registry
    /// order. Same per-keystroke rescan as `filteredCandidates`, for the same
    /// reason: the list is a dozen entries, so bookkeeping to avoid the scan
    /// would cost more than the scan.
    fn filteredCommands(self: *Model) []const CommandCandidate {
        var out: std.ArrayList(CommandCandidate) = .empty;
        for (self.command_candidates) |c| {
            if (fuzzyMatch(self.picker_query.items, c.haystack)) out.append(self.arena, c) catch break;
        }
        return out.items;
    }

    /// Enter on a palette row. A command that takes no arguments runs now —
    /// there is nothing more to say about `/help`, and making the user press
    /// Enter twice for it would be worse than useless. One that takes
    /// arguments loads `"<name> "` into the composer instead, because
    /// running `/goal` or `/workflow` with no arguments only prints its own
    /// usage; this leaves the cursor exactly where the arguments go. That is
    /// the same split Tab-complete already makes on a unique match.
    fn runPaletteSelection(self: *Model, ctx: *vxfw.EventContext, spec: *const CommandSpec) !void {
        if (spec.takes_args) {
            self.loadInputFrom(std.fmt.allocPrint(self.arena, "{s} ", .{spec.name}) catch spec.name);
            return;
        }
        try self.runCommand(ctx, .{ .spec = spec, .args = "" }, spec.name);
    }

    // ----------------------------------------------------------------- search

    /// Ctrl-R: open the search bar. Takes focus for the same reason a picker
    /// does — the composer would otherwise swallow every typed character.
    fn openSearch(self: *Model, ctx: *vxfw.EventContext) !void {
        try self.focusPicker(ctx);
        self.search_open = true;
        self.search_saved_view = self.view_end;
        self.search_query.clearRetainingCapacity();
        self.search_hits.clearRetainingCapacity();
        self.search_idx = 0;
    }

    /// Leaves search. `keep_view` distinguishes Enter (stay where the match
    /// is, which is the point of having searched) from Escape (put the
    /// reader back where they were, because they changed their mind).
    fn closeSearch(self: *Model, ctx: *vxfw.EventContext, keep_view: bool) !void {
        if (!keep_view) self.view_end = self.search_saved_view;
        self.search_open = false;
        self.search_query.clearRetainingCapacity();
        self.search_hits.clearRetainingCapacity();
        self.search_idx = 0;
        try ctx.requestFocus(self.text_field.widget());
    }

    /// Recomputes hits for the current query and jumps to the first one.
    /// Called on every edit of the query, so search is incremental: the view
    /// follows the query as it is typed rather than waiting for Enter.
    fn refreshSearch(self: *Model) void {
        bridge_mutex.lockUncancelable(bridge_io);
        defer bridge_mutex.unlock(bridge_io);
        findHits(self.lines.items, self.search_query.items, self.gpa, &self.search_hits);
        self.search_idx = 0;
        self.jumpToCurrentHitLocked();
    }

    /// Anchors the view on the current hit. Caller holds the bridge lock:
    /// `finishTurn` appends to `self.lines` from the run thread, and the
    /// line count is what the anchor is clamped against.
    fn jumpToCurrentHitLocked(self: *Model) void {
        if (self.search_hits.items.len == 0) return;
        const hit = self.search_hits.items[@min(self.search_idx, self.search_hits.items.len - 1)];
        // Inline rather than `scrollBounds()`: the caller already holds the
        // bridge lock and the mutex is not reentrant.
        const width = if (self.last_text_width > 0) self.last_text_width else 80;
        const floor = topWindowEnd(self.lines.items, self.folds.items, self.availRows(), width);
        self.view_end = searchViewEnd(hit, self.lines.items.len, self.availRows(), floor);
    }

    /// Down/Up (and Ctrl-N/Ctrl-P) step through hits, wrapping at both ends
    /// so a long transcript does not dead-end at its newest match.
    fn stepSearch(self: *Model, forward: bool) void {
        bridge_mutex.lockUncancelable(bridge_io);
        defer bridge_mutex.unlock(bridge_io);
        const n = self.search_hits.items.len;
        if (n == 0) return;
        if (forward) {
            self.search_idx = if (self.search_idx + 1 >= n) 0 else self.search_idx + 1;
        } else {
            self.search_idx = if (self.search_idx == 0) n - 1 else self.search_idx - 1;
        }
        self.jumpToCurrentHitLocked();
    }

    /// The transcript line the current hit sits on, for the draw to tint.
    fn currentHitLine(self: *const Model) ?usize {
        if (!self.search_open or self.search_hits.items.len == 0) return null;
        return self.search_hits.items[@min(self.search_idx, self.search_hits.items.len - 1)];
    }

    fn handleSearchKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        // Ctrl+C closes search like Escape, and with a turn streaming it
        // also stops the turn — the modal must not swallow the interrupt
        // (modalCtrlCAction).
        const ctrl_c = blk: {
            bridge_mutex.lockUncancelable(bridge_io);
            const streaming = bridge_streaming;
            bridge_mutex.unlock(bridge_io);
            break :blk modalCtrlCAction(key, streaming);
        };
        if (ctrl_c != .none) {
            try self.closeSearch(ctx, false);
            if (ctrl_c == .close_and_stop) {
                bridge_stop_flag.store(true, .release);
                askCancelPending();
            }
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.escape, .{})) {
            try self.closeSearch(ctx, false);
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            try self.closeSearch(ctx, true);
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
            self.stepSearch(true);
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
            self.stepSearch(false);
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (popUtf8Codepoint(&self.search_query)) {
                self.refreshSearch();
            }
            return ctx.consumeAndRedraw();
        }
        if (key.text) |t| {
            self.search_query.appendSlice(self.gpa, t) catch {};
            self.refreshSearch();
            return ctx.consumeAndRedraw();
        }
        return ctx.consumeAndRedraw();
    }

    fn closeModelPicker(self: *Model, ctx: *vxfw.EventContext) !void {
        self.picker_open = false;
        self.picker_query.clearRetainingCapacity();
        // Hand keystrokes back to the composer.
        try ctx.requestFocus(self.text_field.widget());
    }

    /// Theme names matching the query, in `theme_mod.names` order.
    fn filteredThemes(self: *Model) []const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (theme_mod.names) |n| {
            if (fuzzyMatch(self.picker_query.items, n)) out.append(self.arena, n) catch break;
        }
        return out.items;
    }

    /// Live-preview the highlighted theme by pointing `theme_override` at it,
    /// so the next draw paints in it. No allocation: `theme_mod.names` entries
    /// are static, so the slice is safe to hold.
    fn previewSelectedTheme(self: *Model) void {
        const matches = self.filteredThemes();
        if (matches.len == 0) return;
        self.theme_override = matches[@min(self.picker_selected, matches.len - 1)];
    }

    /// Candidates whose "provider display" matches the current query, in
    /// `model_candidates` order (config order, so unfiltered is grouped by
    /// provider). Filters into `self.arena` on every keystroke rather than
    /// caching: the candidate list itself is small (one provider's worth of
    /// models, times however many providers are configured, tens, not
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

    /// Switches the active provider/model for the *next* turn onward, the
    /// conversation (`self.messages`) is untouched, so the switch lands
    /// mid-session exactly like `--model` does at startup, just later.
    fn applyModelSelection(self: *Model, cand: ModelCandidate) void {
        if (self.cfg.provider(cand.provider)) |p| {
            var np = p.*;
            np.default_model = cand.model;
            self.provider = np;
            self.lines.append(self.arena, .{
                .text = std.fmt.allocPrint(self.arena, "notice: model switched to {s}/{s}", .{ cand.provider, cand.model }) catch "notice: model switched",
                .dim = true,
            }) catch {};
        } else |_| {
            // Can't happen: cand.provider always came from cfg.providers in
            // buildModelCandidates, but a config reload mid-session (not
            // currently possible) would make this reachable, so fail quiet
            // rather than unreachable().
            self.lines.append(self.arena, .{ .text = "error: model: provider no longer configured", .dim = true }) catch {};
        }
    }

    /// Effort rows matching the query, in `effort_options` order (none →
    /// max → default). The table is static and the descriptions are read-only
    /// literals, so rows never borrow draw-stack memory.
    fn filteredEffortOptions(self: *Model) []const EffortOption {
        var out: std.ArrayList(EffortOption) = .empty;
        for (&effort_options) |*o| {
            var buf: [96]u8 = undefined;
            const haystack = std.fmt.bufPrint(&buf, "{s} {s}", .{ o.label, o.description }) catch o.label;
            if (fuzzyMatch(self.picker_query.items, haystack)) out.append(self.arena, o.*) catch break;
        }
        return out.items;
    }

    /// Presets whose name or description matches the query, in sorted name
    /// order (the same order the CLI's `preset list` prints).
    fn filteredPresets(self: *Model) []const PresetCandidate {
        var out: std.ArrayList(PresetCandidate) = .empty;
        for (self.preset_candidates) |c| {
            var buf: [192]u8 = undefined;
            const haystack = std.fmt.bufPrint(&buf, "{s} {s}", .{ c.name, c.description }) catch c.name;
            if (fuzzyMatch(self.picker_query.items, haystack)) out.append(self.arena, c) catch break;
        }
        return out.items;
    }

    /// Enter on an effort row: pin the session (or clear it for `default`).
    /// The pin lives in `self.cfg.agent.reasoning_effort`, the same field
    /// `--reasoning-effort` sets, so `Agent.classifyEffort` honours it on the
    /// next turn.
    fn applyEffortSelection(self: *Model, choice: EffortChoice) void {
        switch (choice) {
            .default => {
                self.cfg.agent.reasoning_effort = null;
                self.lines.append(self.arena, .{ .text = "notice: reasoning effort back to default (pin cleared)", .dim = true }) catch {};
            },
            .level => |re| {
                self.cfg.agent.reasoning_effort = re;
                self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "notice: reasoning effort pinned to {s}", .{@tagName(re)}) catch "notice: reasoning effort set", .dim = true }) catch {};
            },
        }
    }

    /// Enter on a preset row: set the session preset name (the same field the
    /// direct `/preset <name>` path sets) and confirm in the transcript.
    fn applyPresetSelection(self: *Model, cand: PresetCandidate) void {
        self.preset_name = cand.name;
        self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "notice: preset switched to {s}", .{cand.name}) catch "notice: preset switched", .dim = true }) catch {};
    }

    /// Count of entries in the open picker's filtered list.
    fn pickerLen(self: *Model) usize {
        return switch (self.picker_kind) {
            .model => self.filteredCandidates().len,
            .theme => self.filteredThemes().len,
            .command => self.filteredCommands().len,
            .effort => self.filteredEffortOptions().len,
            .preset => self.filteredPresets().len,
        };
    }

    /// Keys while the ask/confirm modal is open. Up/Down (or j/k) move,
    /// 1-9 pick directly, Enter answers, Escape declines. Ctrl-C declines
    /// *and* stops the turn — the one shortcut that keeps its meaning here,
    /// because a parked run must stay stoppable. Everything else is
    /// swallowed: the modal owns the keyboard.
    fn handleAskKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        _ = std.c.pthread_mutex_lock(&ask_mutex);
        const live = pending_ask.active and !pending_ask.answered;
        const count = pending_ask.options.len;
        _ = std.c.pthread_mutex_unlock(&ask_mutex);
        if (!live or count == 0) {
            self.ask_open = false;
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            self.ask_selected = if (self.ask_selected == 0) count - 1 else self.ask_selected - 1;
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{}) or key.matches(vaxis.Key.tab, .{})) {
            self.ask_selected = (self.ask_selected + 1) % count;
            return ctx.consumeAndRedraw();
        }
        if (key.text) |t| {
            if (t.len == 1 and t[0] >= '1' and t[0] <= '9') {
                const idx: usize = t[0] - '1';
                if (idx < count) {
                    self.answerAsk(idx);
                    return ctx.consumeAndRedraw();
                }
            }
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            self.answerAsk(@min(self.ask_selected, count - 1));
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.escape, .{})) {
            self.answerAsk(null);
            return ctx.consumeAndRedraw();
        }
        if (key.matches('c', .{ .ctrl = true })) {
            self.answerAsk(null);
            bridge_stop_flag.store(true, .release);
            return ctx.consumeAndRedraw();
        }
        return ctx.consumeEvent();
    }

    /// Delivers the modal's verdict to the parked run thread and records it
    /// in the transcript, so the decision survives the modal vanishing.
    /// `picked` null means declined. The transcript line is built under the
    /// ask lock (the option bytes are freed the moment the run thread wakes)
    /// and appended under the bridge lock — never nested.
    fn answerAsk(self: *Model, picked: ?usize) void {
        var line: ?[]const u8 = null;
        _ = std.c.pthread_mutex_lock(&ask_mutex);
        if (pending_ask.active and !pending_ask.answered) {
            pending_ask.answered = true;
            pending_ask.picked = picked;
            line = switch (pending_ask.kind) {
                .ask => if (picked) |i|
                    std.fmt.allocPrint(bridge_gpa, "notice: selected \"{s}\"", .{pending_ask.options[i]}) catch null
                else
                    bridge_gpa.dupe(u8, "notice: question declined") catch null,
                .confirm => if (picked != null and picked.? == 0)
                    bridge_gpa.dupe(u8, "notice: confirmation allowed") catch null
                else
                    bridge_gpa.dupe(u8, "notice: confirmation denied") catch null,
            };
            _ = std.c.pthread_cond_broadcast(&ask_cond);
        }
        _ = std.c.pthread_mutex_unlock(&ask_mutex);
        self.ask_open = false;
        if (line) |l| {
            bridge_mutex.lockUncancelable(bridge_io);
            bridge_tool_lines.append(bridge_gpa, l) catch bridge_gpa.free(l);
            bridge_mutex.unlock(bridge_io);
        }
    }

    fn handlePickerKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        // Ctrl+C must not be swallowed by the modal: it closes the picker
        // like Escape, and with a turn streaming it also stops the turn —
        // same rationale as the ask modal, a run must stay stoppable no
        // matter which modal holds the keyboard (modalCtrlCAction).
        const ctrl_c = blk: {
            bridge_mutex.lockUncancelable(bridge_io);
            const streaming = bridge_streaming;
            bridge_mutex.unlock(bridge_io);
            break :blk modalCtrlCAction(key, streaming);
        };
        if (ctrl_c != .none) {
            if (self.picker_kind == .theme) self.theme_override = self.theme_saved;
            try self.closeModelPicker(ctx);
            if (ctrl_c == .close_and_stop) {
                bridge_stop_flag.store(true, .release);
                askCancelPending();
            }
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.escape, .{})) {
            // Theme preview is undone; a model pick has no preview to undo.
            if (self.picker_kind == .theme) self.theme_override = self.theme_saved;
            try self.closeModelPicker(ctx);
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            switch (self.picker_kind) {
                .model => {
                    const matches = self.filteredCandidates();
                    if (matches.len > 0) self.applyModelSelection(matches[@min(self.picker_selected, matches.len - 1)]);
                },
                .theme => {
                    // The live preview already set theme_override to the
                    // highlighted theme; Enter just keeps it.
                    const matches = self.filteredThemes();
                    if (matches.len > 0) self.theme_override = matches[@min(self.picker_selected, matches.len - 1)];
                },
                .command => {
                    const matches = self.filteredCommands();
                    if (matches.len > 0) {
                        const picked = matches[@min(self.picker_selected, matches.len - 1)].spec;
                        // Closed before dispatching: a command may print into
                        // the transcript (or quit), and doing that with the
                        // modal still flagged open would draw the palette on
                        // top of its own output.
                        try self.closeModelPicker(ctx);
                        try self.runPaletteSelection(ctx, picked);
                        return ctx.consumeAndRedraw();
                    }
                },
                .effort => {
                    const matches = self.filteredEffortOptions();
                    if (matches.len > 0) self.applyEffortSelection(matches[@min(self.picker_selected, matches.len - 1)].choice);
                },
                .preset => {
                    const matches = self.filteredPresets();
                    if (matches.len > 0) self.applyPresetSelection(matches[@min(self.picker_selected, matches.len - 1)]);
                },
            }
            try self.closeModelPicker(ctx);
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.up, .{})) {
            if (self.picker_selected > 0) self.picker_selected -= 1;
            if (self.picker_kind == .theme) self.previewSelectedTheme();
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.down, .{})) {
            const n = self.pickerLen();
            if (n > 0 and self.picker_selected + 1 < n) self.picker_selected += 1;
            if (self.picker_kind == .theme) self.previewSelectedTheme();
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (popUtf8Codepoint(&self.picker_query)) {
                self.picker_selected = 0;
                if (self.picker_kind == .theme) self.previewSelectedTheme();
            }
            return ctx.consumeAndRedraw();
        }
        if (key.text) |t| {
            try self.picker_query.appendSlice(self.arena, t);
            self.picker_selected = 0;
            if (self.picker_kind == .theme) self.previewSelectedTheme();
            return ctx.consumeAndRedraw();
        }
        return ctx.consumeAndRedraw();
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        // vxfw stores the Model as *anyopaque on the widget.
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {
                try ctx.requestFocus(self.text_field.widget());
                // `loop` animates with nothing else going on, so it needs the
                // first tick of its heartbeat from here; the `.tick` arm
                // re-arms it after that. `typing` deliberately gets no timer:
                // a keystroke is already a redraw, and the robot is supposed
                // to stand still between them.
                if (self.mascot.mode.selfDriven()) {
                    self.timer_armed = true;
                    try ctx.tick(mascot_tick_ms, self.widget());
                }
            },
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
                    // report any compaction the agent did mid-turn, then
                    // persist the conversation as it stands after this turn
                    // (which may compact it again, and says so too).
                    self.reportMidTurnCompaction();
                    self.persistSession();
                    self.context_tokens = stats_mod.historyTokens(self.messages.items);
                }
                bridge_mutex.lockUncancelable(bridge_io);
                const still_streaming = bridge_streaming;
                bridge_mutex.unlock(bridge_io);
                // Surface a pending ask/confirm the run thread raised since
                // the last frame, and drop the modal if the question expired
                // under it (timeout, stop). The ~30fps streaming tick is
                // always live while a turn — and therefore an ask — is in
                // flight, so polling here needs no extra timer.
                _ = std.c.pthread_mutex_lock(&ask_mutex);
                const ask_pending = pending_ask.active and !pending_ask.answered;
                _ = std.c.pthread_mutex_unlock(&ask_mutex);
                if (ask_pending and !self.ask_open) {
                    self.ask_open = true;
                    self.ask_selected = 0;
                } else if (!ask_pending and self.ask_open) {
                    self.ask_open = false;
                }
                // This delivery consumed the pending timer. Anything below that
                // still wants one has to arm it again.
                self.timer_armed = false;
                if (still_streaming) {
                    // Redraw at ~30fps so streamed text lands smoothly instead
                    // of in visible 50ms (20fps) batches, but advance the
                    // spinner only every third frame so it still animates at a
                    // readable ~100ms/step rather than a blur.
                    self.tick_count +%= 1;
                    if (self.tick_count % 3 == 0) self.spinner_frame +%= 1;
                }
                // The self-driven modes advance here. `typing` advances in the
                // draw path instead, off the redraw a keystroke already causes
                // -- advancing it here as well would step it twice per frame
                // during a streaming turn and not at all when idle.
                if (self.mascot.mode.selfDriven()) self.mascot.advance(self.inputLen());
                // A fold mid-open or mid-close steps here too, and reports
                // whether it still needs frames.
                const folds_animating = self.advanceFolds();
                // Exactly one timer, at the faster of the rates anything wants:
                // a streaming turn needs ~30fps for smooth text, the mascot
                // only 20, and while both are live the stream's rate serves
                // both (the robot simply runs a little faster while the model
                // is working, which is not a bad look for it).
                const want_tick: ?u32 = if (still_streaming)
                    stream_tick_ms
                else if (folds_animating)
                    fold_tick_ms
                else if (self.mascot.mode.selfDriven())
                    mascot_tick_ms
                else
                    null;
                if (want_tick) |ms| {
                    self.timer_armed = true;
                    try ctx.tick(ms, self.widget());
                }
                ctx.redraw = true;
            },
            .key_press => |key| {
                // The ask/confirm modal outranks even the picker: a run is
                // parked on the answer. Ctrl-C inside declines and stops.
                if (self.ask_open) return self.handleAskKey(ctx, key);
                // The picker is modal: every key goes to it, none of the
                // clipboard/history/quit shortcuts below apply while it's open.
                if (self.picker_open) return self.handlePickerKey(ctx, key);
                // Search is modal for the same reason, and must be tested
                // *here* rather than further down: the scrollback bindings
                // immediately below claim Escape whenever `view_end` is set,
                // and jumping to a hit always sets it. Tested after them,
                // Escape only cancelled the scroll and left search open with
                // the keyboard still captured.
                if (self.search_open) return self.handleSearchKey(ctx, key);
                // Manual scrollback. PgUp/PgDn page the transcript by a
                // screenful (one line of overlap); Home jumps to the top and
                // End/Esc return to the tail, but Home/End only act on the
                // scroll while already scrolled up, so at the tail they keep
                // their TextField cursor-motion meaning (aliases of
                // Ctrl-A/Ctrl-E there). The paging math is pure
                // (`scrollUpEnd` and friends, below `tailWindow`); this just
                // feeds it the current anchor and last-drawn height.
                if (key.matches(vaxis.Key.page_up, .{})) {
                    const b = self.scrollBounds();
                    self.view_end = scrollUpEnd(self.view_end, b.count, self.availRows(), b.floor);
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.page_down, .{})) {
                    const b = self.scrollBounds();
                    self.view_end = scrollDownEnd(self.view_end, b.count, self.availRows(), b.floor);
                    return ctx.consumeAndRedraw();
                }
                if (self.view_end != null and key.matches(vaxis.Key.home, .{})) {
                    const b = self.scrollBounds();
                    self.view_end = scrollHomeEnd(b.count, b.floor);
                    return ctx.consumeAndRedraw();
                }
                if (self.view_end != null and (key.matches(vaxis.Key.end, .{}) or key.matches(vaxis.Key.escape, .{}))) {
                    self.view_end = null;
                    return ctx.consumeAndRedraw();
                }
                // Ctrl-R opens it. Scrollback paging finds a place you can
                // already point at; search finds one you can only describe.
                //
                // Ctrl-R rather than the more obvious Ctrl-F because the
                // composer is a `vxfw.TextField` and it holds focus: it
                // claims Ctrl-F for forward-char and consumes it before the
                // root Model sees anything, so a Ctrl-F binding here would
                // simply never fire. TextField's chord list (Ctrl-A/B/D/E/F/
                // J/K/U/W plus the Alt- word motions) is the set that cannot
                // be bound at this level. Ctrl-R is free, and is what a
                // reader coming from readline reaches for to search anyway.
                if (key.matches('r', .{ .ctrl = true })) {
                    try self.openSearch(ctx);
                    return ctx.consumeAndRedraw();
                }
                // Ctrl-P opens the command palette. A separate mechanism from
                // Tab-complete on purpose: Tab extends a prefix of a name you
                // already remember, the palette finds a command you don't
                // ("mdl" -> /model, "switch" -> /model). Bound on Ctrl-P
                // rather than a slash spelling so it is reachable with a line
                // already half-typed, and because a `/palette` command would
                // itself need to be looked up in the thing it opens.
                if (key.matches('p', .{ .ctrl = true })) {
                    try self.openCommandPalette(ctx, "");
                    return ctx.consumeAndRedraw();
                }
                // Terminal convention: Ctrl+Shift+C copies the current
                // selection (mouse-drag, same path as a drag release),
                // falling back to the whole input line. Plain Ctrl+C keeps
                // its readline meaning (interrupt the turn, quit when idle).
                if (key.matches('c', .{ .ctrl = true, .shift = true })) {
                    try self.copySelectionOrInput(ctx);
                    return ctx.consumeAndRedraw();
                }
                // Terminals without kitty-keyboard support collapse
                // Ctrl+Shift+C to the same 0x03 byte as plain Ctrl+C and
                // drop the shift bit, so the branch above never fires for
                // them. Recover the copy intent from a live mouse selection
                // when no turn is streaming (isCopyChord), so a genuine
                // Ctrl+C can still interrupt; with no selection the byte is
                // indistinguishable from plain Ctrl+C and falls through to
                // that handler's quit, untouched.
                if (self.has_selection and key.matches('c', .{ .ctrl = true })) {
                    bridge_mutex.lockUncancelable(bridge_io);
                    const copy_streaming = bridge_streaming;
                    bridge_mutex.unlock(bridge_io);
                    if (isCopyChord(key, copy_streaming, self.has_selection)) {
                        try self.copySelectionOrInput(ctx);
                        return ctx.consumeAndRedraw();
                    }
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
                // Keep readline editing separate from the system clipboard:
                // Ctrl-U/K/W replace this session's kill ring, and Ctrl-Y
                // yanks it at the cursor. TextField implements the deletions
                // but has no kill ring of its own, so intercept them here.
                if (key.matches('u', .{ .ctrl = true })) {
                    try killText(&self.text_field, &self.kill_ring, self.gpa, .start);
                    return ctx.consumeAndRedraw();
                }
                if (key.matches('k', .{ .ctrl = true })) {
                    try killText(&self.text_field, &self.kill_ring, self.gpa, .end);
                    return ctx.consumeAndRedraw();
                }
                if (key.matches('w', .{ .ctrl = true })) {
                    try killText(&self.text_field, &self.kill_ring, self.gpa, .word);
                    return ctx.consumeAndRedraw();
                }
                if (key.matches('y', .{ .ctrl = true })) {
                    try self.text_field.insertSliceAtCursor(self.kill_ring.items);
                    return ctx.consumeAndRedraw();
                }
                if (key.matches('c', .{ .ctrl = true })) {
                    bridge_mutex.lockUncancelable(bridge_io);
                    const streaming = bridge_streaming;
                    bridge_mutex.unlock(bridge_io);
                    if (streaming) {
                        bridge_stop_flag.store(true, .release);
                        // A worker parked on an unanswered ask never sees the
                        // stop flag; wake it declined so the stop lands now.
                        askCancelPending();
                    } else {
                        ctx.quit = true;
                    }
                    return;
                }
                // In a multi-line draft, Up/Down move the cursor between
                // lines first (which also scrolls a draft taller than the
                // box, since drawComposer follows the cursor's line); at the
                // top/bottom edge they fall through to history recall.
                if (key.matches(vaxis.Key.up, .{})) {
                    if (!self.composerCursorVertical(true)) self.historyPrev();
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.down, .{})) {
                    if (!self.composerCursorVertical(false)) self.historyNext();
                    return ctx.consumeAndRedraw();
                }
                // Slash-command completion, styled after readline: one match
                // completes the line, several complete to their shared
                // prefix and list the rest. Only intercepted for `/`-prefixed
                // input; otherwise Tab falls through to the TextField like
                // any other key, unchanged from before this existed.
                if (key.matches(vaxis.Key.tab, .{}) and try self.completeSlashCommand(ctx)) {
                    return ctx.consumeAndRedraw();
                }
                // Shift+Enter inserts a line break instead of submitting.
                // Terminals speaking the kitty keyboard protocol report the
                // chord as enter + shift; Konsole's default keytab sends
                // SS3 M (`\EOM`), which vaxis parses as kp_enter
                // (patches/vaxis-ss3-keypad-enter.patch), so keypad Enter
                // lands here too. The break is stored and drawn as ⏎ and
                // becomes a real newline at submit (see newline_marker).
                if (key.matches(vaxis.Key.enter, .{ .shift = true }) or
                    key.matches(vaxis.Key.kp_enter, .{}) or
                    key.matches(vaxis.Key.kp_enter, .{ .shift = true }))
                {
                    try self.text_field.insertSliceAtCursor(newline_marker);
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.in_paste) {
                        // A bracketed paste delivers its newlines as raw
                        // Enter presses; fold each to a ⏎ marker so the
                        // pasted structure survives to submit.
                        try self.text_field.insertSliceAtCursor(newline_marker);
                        ctx.redraw = true;
                        return;
                    }
                    try self.submit(ctx);
                    // Every submitted line repaints, here, once. `submit`
                    // fans out to a dozen places that append to `self.lines`
                    // (the generated /help, each `cmd_*` tool's output, the
                    // per-command usage blocks, the unknown-command notice,
                    // the whole `!` escape path) and asking each of them to
                    // remember `ctx.redraw` is the bug this replaces: only
                    // `.theme` and `/compare` ever did. vxfw redraws when the
                    // flag is set and not otherwise, so everything else
                    // printed into a buffer nobody repainted, and the output
                    // surfaced later, attached to whatever unrelated
                    // keystroke happened next. `submitTask` looked fine only
                    // because `ctx.tick` schedules a tick that redraws.
                    return ctx.consumeAndRedraw();
                }
                try self.text_field.handleEvent(ctx, event);
            },
            .paste_start => self.in_paste = true,
            .paste_end => self.in_paste = false,
            // Answer to our OSC 52 clipboard request (Ctrl+Shift+V). The
            // payload is terminal-supplied text; its newlines become ⏎
            // markers (the TextField is single-line, a raw newline would
            // otherwise submit mid-paste) and turn back into real newlines
            // at submit, so a multi-line paste survives intact.
            .paste => |text| {
                defer ctx.alloc.free(text);
                self.in_paste = false;
                self.awaiting_clipboard = false;
                const flat = encodeComposerNewlines(ctx.alloc, text);
                defer if (flat.ptr != text.ptr) ctx.alloc.free(flat);
                // Clipboard content is untrusted too, and it is the one
                // untrusted source the user cannot preview first: whatever
                // put it there chose the bytes, and the TextField renders
                // them into cells like anything else.
                const safe = clean(ctx.alloc, flat) orelse return;
                defer if (safe.ptr != flat.ptr) ctx.alloc.free(safe);
                try self.text_field.insertSliceAtCursor(safe);
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
        // The wheel scrolls the transcript. This is owed rather than optional:
        // `vxfw.App.run` enables mouse reporting unconditionally, which takes
        // the terminal's own wheel handling away, and the guard below then
        // dropped every non-left button — so the wheel did nothing in either
        // layer and the transcript could only be moved from the keyboard.
        // Handled before that guard, and only on `.press`, because a terminal
        // that also reports a release for a wheel notch would otherwise
        // scroll twice per notch.
        if (m.type == .press) {
            switch (m.button) {
                .wheel_up, .wheel_down => {
                    // Over the composer, a notch walks the cursor one draft
                    // line — the box follows the cursor's line, so this
                    // scrolls a tall draft without a second scroll state.
                    // At the draft's edge (or in a single-line buffer) the
                    // move refuses and the notch is spent, never leaked into
                    // transcript scrolling: the pointer says which surface
                    // the user is scrolling.
                    const wheel_row: u16 = @intCast(@max(0, m.row));
                    if (self.composer_bottom > self.composer_top and
                        wheel_row >= self.composer_top and wheel_row < self.composer_bottom)
                    {
                        if (self.composerCursorVertical(m.button == .wheel_up))
                            ctx.redraw = true;
                        return;
                    }
                    const b = self.scrollBounds();
                    self.view_end = scrollWheelEnd(
                        self.view_end,
                        b.count,
                        b.floor,
                        m.button == .wheel_up,
                    );
                    ctx.redraw = true;
                    return;
                },
                else => {},
            }
        }
        if (m.button != .left and m.type != .release) return;
        const raw_row: u16 = @intCast(@max(0, m.row));
        const raw_col: u16 = @intCast(@max(0, m.col));
        // The press decides which region the selection lives in — composer
        // or transcript — and the whole drag stays clamped to that region.
        // The two scroll independently, so a span across both would not name
        // any coherent text.
        if (m.type == .press) {
            self.sel_in_composer = self.composer_bottom > self.composer_top and
                raw_row >= self.composer_top and raw_row < self.composer_bottom;
        }
        const row = if (self.sel_in_composer)
            std.math.clamp(raw_row, self.composer_top, self.composer_bottom -| 1)
        else
            std.math.clamp(
                raw_row,
                self.transcript_top,
                if (self.transcript_bottom > 0) self.transcript_bottom - 1 else 0,
            );
        const col = if (self.sel_in_composer)
            std.math.clamp(raw_col, self.composer_left, self.composer_right -| 1)
        else
            raw_col;
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
                self.has_selection = self.sel_start.row != self.sel_end.row or
                    self.sel_start.col != self.sel_end.col;
                ctx.redraw = true;
            },
            .release => {
                if (!self.mouse_down) return;
                self.mouse_down = false;
                // A click (press and release on the same row, no drag) on a
                // fold header opens or closes that reply. Checked before the
                // selection path so a plain click is a toggle, not an empty
                // copy of a zero-width selection.
                if (!self.has_selection and !self.sel_in_composer) {
                    for (self.fold_hits.items) |hit| {
                        if (hit.row == row) {
                            self.toggleFold(hit.fold);
                            self.armTimer(ctx) catch {};
                            ctx.redraw = true;
                            return;
                        }
                    }
                }
                if (!self.has_selection) return;
                // A composer selection reads the composer child surface (the
                // parent's cells under it are blank), translated to child
                // coordinates.
                if (self.sel_in_composer) {
                    const child = self.last_input_surface orelse return;
                    const a: vxfw.Point = .{
                        .row = self.sel_start.row -| self.composer_top,
                        .col = self.sel_start.col -| self.composer_left,
                    };
                    const b: vxfw.Point = .{
                        .row = self.sel_end.row -| self.composer_top,
                        .col = self.sel_end.col -| self.composer_left,
                    };
                    if (a.row >= child.size.height or b.row >= child.size.height) return;
                    const text = extractSelectionText(ctx.alloc, child, a, b) catch return;
                    defer ctx.alloc.free(text);
                    try ctx.copyToClipboard(text);
                    clipboard.copyBestEffort(self.gpa, self.io, self.ctx.environ_map, text);
                    ctx.redraw = true;
                    return;
                }
                const surface = self.last_surface orelse return;
                const text = extractSelectionText(ctx.alloc, surface, self.sel_start, self.sel_end) catch return;
                defer ctx.alloc.free(text);
                try ctx.copyToClipboard(text);
                clipboard.copyBestEffort(self.gpa, self.io, self.ctx.environ_map, text);
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
                if (text.len > 0) clipboard.copyBestEffort(self.gpa, self.io, self.ctx.environ_map, text);
            }
            self.has_selection = false;
            ctx.redraw = true;
            return;
        }
        const raw = self.text_field.buf.dupe() catch return;
        defer self.text_field.buf.allocator.free(raw);
        // The clipboard gets what submit would send: ⏎ markers decode to
        // real newlines (on OOM the marker text is still a faithful copy).
        const input = std.mem.replaceOwned(u8, self.gpa, raw, newline_marker, "\n") catch raw;
        defer if (input.ptr != raw.ptr) self.gpa.free(input);
        if (input.len > 0) try ctx.copyToClipboard(input);
        if (input.len > 0) clipboard.copyBestEffort(self.gpa, self.io, self.ctx.environ_map, input);
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
        // History entries hold what was submitted — real newlines included —
        // so restoring one re-encodes them as ⏎ markers for the field.
        const shown = encodeComposerNewlines(self.gpa, text);
        defer if (shown.ptr != text.ptr) self.gpa.free(shown);
        self.text_field.insertSliceAtCursor(shown) catch {};
    }

    /// Draws the composer as one row per ⏎-separated line, replacing the
    /// single-row `TextField.draw` whenever the buffer holds a line break.
    /// The marker grapheme is never written to a cell — some terminals
    /// render U+23CE at a different width than the width table says
    /// (Konsole draws it wide), and a width disagreement in the input row
    /// garbles everything after it. The surface carries
    /// `text_field.widget()` so focus keeps the terminal cursor here.
    ///
    /// The cursor's line scrolls horizontally to keep the cursor visible;
    /// every other line truncates with an ellipsis, like the TextField.
    /// With more lines than rows the block scrolls to the cursor's line.
    fn drawComposer(self: *Model, ctx: vxfw.DrawContext, text: []const u8, width: u16, rows: u16) !vxfw.Surface {
        var surface = try vxfw.Surface.init(ctx.arena, self.text_field.widget(), .{ .width = width, .height = rows });
        const style = self.text_field.style;
        @memset(surface.buffer, .{ .style = style });
        if (width == 0 or rows == 0) return surface;
        const layout = composerLayout(text, self.text_field.buf.firstHalf().len);
        var first: u16 = if (layout.line_count > rows) layout.line_count - rows else 0;
        if (layout.cursor_line < first) first = layout.cursor_line;

        var it = std.mem.splitSequence(u8, text, newline_marker);
        var idx: u16 = 0;
        var cursor_screen_col: u16 = 0;
        while (it.next()) |seg| : (idx += 1) {
            if (idx < first or idx >= first + rows) continue;
            const row: u16 = idx - first;
            const on_cursor_line = idx == layout.cursor_line;
            const offset_cols: u16 = if (on_cursor_line and layout.cursor_cols >= width)
                layout.cursor_cols - width + 1
            else
                0;
            var skipped: u16 = 0;
            var col: u16 = 0;
            var i: usize = 0;
            while (nextCell(seg, &i)) |c| {
                if (skipped < offset_cols) {
                    skipped += c.width;
                    continue;
                }
                if (col + c.width >= width) {
                    surface.writeCell(width - 1, row, .{ .char = .{ .grapheme = "…", .width = 1 }, .style = style });
                    break;
                }
                surface.writeCell(col, row, .{ .char = .{ .grapheme = c.bytes, .width = @intCast(c.width) }, .style = style });
                col += c.width;
            }
            if (offset_cols > 0) surface.writeCell(0, row, .{ .char = .{ .grapheme = "…", .width = 1 }, .style = style });
            if (on_cursor_line) cursor_screen_col = layout.cursor_cols - offset_cols;
        }
        surface.cursor = .{ .col = @min(cursor_screen_col, width - 1), .row = layout.cursor_line - first };
        return surface;
    }

    /// Moves the cursor one composer line up or down, keeping the display
    /// column. Returns false at the first/last line (or in a single-line
    /// buffer) so Up/Down fall through to history recall — the readline
    /// convention for multi-line editing.
    fn composerCursorVertical(self: *Model, up: bool) bool {
        const first = self.text_field.buf.firstHalf();
        const text = std.mem.concat(self.gpa, u8, &.{ first, self.text_field.buf.secondHalf() }) catch return false;
        defer self.gpa.free(text);
        const target = composerVerticalMove(text, first.len, up) orelse return false;
        if (target < first.len)
            self.text_field.buf.moveGapLeft(first.len - target)
        else
            self.text_field.buf.moveGapRight(target - first.len);
        return true;
    }

    /// `TextField.toOwnedSlice` plus marker decoding: every path that takes
    /// text out of the composer (task submit, mid-run steering) goes through
    /// here so a drawn ⏎ and a submitted '\n' can never disagree. Returned
    /// slice is gpa-owned either way.
    fn takeComposerText(self: *Model) ![]const u8 {
        const raw = try self.text_field.toOwnedSlice();
        if (std.mem.find(u8, raw, newline_marker) == null) return raw;
        defer self.gpa.free(raw);
        return std.mem.replaceOwned(u8, self.gpa, raw, newline_marker, "\n");
    }

    /// Tab: complete the input line against `command_registry`, readline
    /// style. Returns whether it did anything, false (input isn't a
    /// `/`-prefixed line, or no spelling matches it) means the caller should
    /// let Tab fall through to the TextField as usual. A single match
    /// completes to the full spelling, adding a trailing space when the
    /// command takes arguments so the next keystroke lands on them; several
    /// matches complete to their longest shared prefix, or, once that stops
    /// advancing the line, get listed in the transcript instead of eating
    /// the keystroke silently.
    /// Completes a command argument (the text after "<command> ") against a
    /// known set: one match completes it (with a trailing space), several
    /// complete to their shared prefix or, once that stops advancing, get
    /// listed. Returns whether it did anything.
    fn completeArg(self: *Model, ctx: *vxfw.EventContext, cmd: []const u8, partial: []const u8, candidates: []const []const u8) bool {
        var hits: [max_completions][]const u8 = undefined;
        var n: usize = 0;
        for (candidates) |c| {
            if (n < hits.len and std.mem.startsWith(u8, c, partial)) {
                hits[n] = c;
                n += 1;
            }
        }
        if (n == 0) return false;
        if (n == 1) {
            self.loadInputFrom(std.fmt.allocPrint(self.arena, "{s} {s} ", .{ cmd, hits[0] }) catch return true);
            ctx.redraw = true;
            return true;
        }
        // Longest common prefix of the hits.
        var lcp = hits[0];
        for (hits[1..n]) |h| {
            var i: usize = 0;
            while (i < lcp.len and i < h.len and lcp[i] == h[i]) : (i += 1) {}
            lcp = lcp[0..i];
        }
        if (lcp.len > partial.len) {
            self.loadInputFrom(std.fmt.allocPrint(self.arena, "{s} {s}", .{ cmd, lcp }) catch return true);
            ctx.redraw = true;
            return true;
        }
        var line: std.ArrayList(u8) = .empty;
        line.appendSlice(self.arena, "completions:") catch return true;
        for (hits[0..n]) |h| {
            line.appendSlice(self.arena, "  ") catch break;
            line.appendSlice(self.arena, h) catch break;
        }
        self.lines.append(self.arena, .{ .text = line.toOwnedSlice(self.arena) catch "completions:", .dim = true }) catch {};
        ctx.redraw = true;
        return true;
    }

    fn completeSlashCommand(self: *Model, ctx: *vxfw.EventContext) !bool {
        const input = self.text_field.buf.dupe() catch return false;
        defer self.text_field.buf.allocator.free(input);
        if (!looksLikeSlashCommand(input)) return false;

        // Argument completion: once a command name and a space are typed,
        // complete the argument against the command's known value set (theme
        // names, workflow names). Commands whose argument is free text (goal,
        // arena, ...) have no set and fall through to nothing.
        if (std.mem.findScalar(u8, input, ' ')) |sp| {
            const cmd = std.mem.trimEnd(u8, input[0..sp], " ");
            const partial = std.mem.trimStart(u8, input[sp + 1 ..], " ");
            const pc = parseCommand(cmd) orelse return false;
            switch (pc.spec.action) {
                .theme => return self.completeArg(ctx, cmd, partial, &theme_mod.names),
                .workflow => {
                    const wfs = workflows_mod.loadAllMerged(self.arena, self.io, self.cfg.agent.workflows_dir) catch return false;
                    var names: std.ArrayList([]const u8) = .empty;
                    for (wfs) |w| names.append(self.arena, w.name) catch break;
                    return self.completeArg(ctx, cmd, partial, names.items);
                },
                .tool => |tool| if (std.mem.eql(u8, tool.name, "plugins")) {
                    const verbs = [_][]const u8{ "on", "off" };
                    const sep = std.mem.findScalar(u8, partial, ' ') orelse
                        return self.completeArg(ctx, cmd, partial, &verbs);
                    const verb = partial[0..sep];
                    if (!std.mem.eql(u8, verb, "on") and !std.mem.eql(u8, verb, "off")) return false;
                    const name_partial = std.mem.trimStart(u8, partial[sep + 1 ..], " ");
                    var names: std.ArrayList([]const u8) = .empty;
                    var tools = self.reg.tools.iterator();
                    while (tools.next()) |entry| {
                        const t = entry.value_ptr;
                        // plugins treats internal non-transforms as core.
                        if (!t.internal or t.transform != null) names.append(self.arena, t.name) catch break;
                    }
                    std.mem.sort([]const u8, names.items, {}, lessThanCmd);
                    const prefix = std.fmt.allocPrint(self.arena, "{s} {s}", .{ cmd, verb }) catch return true;
                    return self.completeArg(ctx, prefix, name_partial, names.items);
                } else return false,
                else => return false,
            }
        }

        var buf: [max_completions]SpellingMatch = undefined;
        const matches = matchingSpellings(input, &buf);
        if (matches.len == 0) return false;

        if (matches.len == 1) {
            const m = matches[0];
            if (m.spec.takes_args) {
                var out: [128]u8 = undefined;
                const completed = std.fmt.bufPrint(&out, "{s} ", .{m.spelling}) catch return true;
                self.loadInputFrom(completed);
            } else {
                self.loadInputFrom(m.spelling);
            }
            ctx.redraw = true;
            return true;
        }

        const lcp = longestCommonPrefix(matches);
        if (lcp.len > input.len) {
            self.loadInputFrom(lcp);
            ctx.redraw = true;
            return true;
        }

        self.lines.append(self.arena, .{ .text = "matching commands:", .dim = true }) catch {};
        var line: std.ArrayList(u8) = .empty;
        for (matches, 0..) |m, i| {
            if (i > 0 and i % 2 == 0) {
                self.lines.append(self.arena, .{ .text = line.toOwnedSlice(self.arena) catch "", .dim = true }) catch {};
                line = .empty;
            }
            if (line.items.len > 0) line.appendSlice(self.arena, "    ") catch break;
            line.appendSlice(self.arena, m.spelling) catch break;
        }
        if (line.items.len > 0)
            self.lines.append(self.arena, .{ .text = line.toOwnedSlice(self.arena) catch "", .dim = true }) catch {};
        ctx.redraw = true;
        return true;
    }

    /// Line count plus the row-aware scroll floor (`topWindowEnd`) for the
    /// key/wheel handlers, read together under the bridge lock so both
    /// describe the same transcript. Uses the width of the last draw — the
    /// wrap the reader is actually looking at.
    fn scrollBounds(self: *Model) struct { count: usize, floor: usize } {
        bridge_mutex.lockUncancelable(bridge_io);
        defer bridge_mutex.unlock(bridge_io);
        const width = if (self.last_text_width > 0) self.last_text_width else 80;
        return .{
            .count = self.lines.items.len,
            .floor = topWindowEnd(self.lines.items, self.folds.items, self.availRows(), width),
        };
    }

    /// The transcript height as of the last draw, what one "page" means.
    /// Zero before the first frame, which the scroll math treats as a
    /// one-line page.
    fn availRows(self: *const Model) u16 {
        return self.transcript_bottom -| self.transcript_top;
    }

    /// Bytes currently in the composer. Read straight off the gap buffer's two
    /// halves rather than via `buf.dupe()`, because the mascot asks for this on
    /// every frame and does not need to own the text -- only its length.
    ///
    /// Bytes, not graphemes: this only feeds the mascot's position, where the
    /// difference is invisible (a multi-byte character advances the robot a
    /// little further) and not worth a grapheme walk per frame.
    fn inputLen(self: *const Model) usize {
        return self.text_field.buf.firstHalf().len + self.text_field.buf.secondHalf().len;
    }

    /// Paints the mascot at `row`, anchored within `[left, left + width)`.
    ///
    /// The window is the whole surface for the modes that live above the box,
    /// and the input box's interior for `.input` -- which is the only reason
    /// this takes a window at all: `cornerColumn` has to park the robot
    /// against the *box's* right edge, not the screen's.
    ///
    /// The kitty transmit is resolved here rather than at startup because the
    /// capability answer to `queryTerminal` is still in flight while the model
    /// is being built: asking earlier reliably reports no graphics support and
    /// latches the fallback for the whole session. `ensureGraphics` is a no-op
    /// after the first call, so this costs one branch per frame.
    fn drawMascot(self: *Model, surface: vxfw.Surface, row: u16, left: u16, width: u16) void {
        if (self.app) |app| {
            self.mascot.ensureGraphics(self.gpa, &app.vx, app.tty.writer());
        }
        const typed = self.inputLen();
        // `typing` mode's whole animation clock: it is a no-op unless the
        // input length changed since the last frame, which is exactly "a key
        // was pressed". The other live modes are stepped by the tick handler
        // instead, and `advance` ignores this call for them.
        if (self.mascot.mode == .typing) self.mascot.advance(typed);
        const col = self.mascot.column(width, typed) + @as(i32, left);
        self.mascot.draw(surface, col, row);
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        // vxfw stores the Model as *anyopaque on the widget.
        const self: *Model = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();

        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), max);
        // Computed up front (draw order used to put this after the box/status
        // were already painted in the theme-less default style, so a chosen
        // CLANKER_THEME only ever showed up inside fenced code, everywhere
        // else in the vaxis REPL's chrome ignored it).
        const active = theme_mod.select(self.theme_override orelse themeName(self.ctx.environ_map), self.ctx.environ_map);
        const dim: vaxis.Style = if (active.rgb) |c| .{ .dim = true, .fg = .{ .rgb = c.dim } } else .{ .dim = true };
        const rule_style: vaxis.Style = if (active.rgb) |c| .{ .fg = .{ .rgb = c.rule } } else .{};
        const tool_style: vaxis.Style = if (active.rgb) |c| .{ .dim = true, .fg = .{ .rgb = c.tool } } else dim;
        const err_style: vaxis.Style = if (active.rgb) |c| .{ .fg = .{ .rgb = c.err } } else .{};
        const prompt_style: vaxis.Style = if (active.rgb) |c| .{ .bold = true, .fg = .{ .rgb = c.prompt } } else .{ .bold = true };
        const accent_style: vaxis.Style = if (active.rgb) |c| .{ .fg = .{ .rgb = c.accent } } else .{};
        const brand_style: vaxis.Style = if (active.rgb) |c| .{ .bold = true, .fg = .{ .rgb = c.accent } } else .{ .bold = true };
        // The fold header's own style: bold + underline, hyperlink-shaped.
        // Prominence can't come from color alone — a theme's accent may sit
        // arbitrarily close to body text (bold accent proved invisible on
        // one), and dim buried it among the tool lines. The underline holds
        // in every theme, and with the "(click to …)" wording the header
        // reads as the link it is.
        const fold_style: vaxis.Style = if (active.rgb) |c| .{ .bold = true, .ul_style = .single, .fg = .{ .rgb = c.accent } } else .{ .bold = true, .ul_style = .single };
        @memset(surface.buffer, .{ .style = .{}, .default = true });

        // Held through the self.lines read loop below, not just the
        // streaming snapshot: finishTurn appends to self.lines from the
        // background thread while a turn is in flight (this same draw runs
        // on every 50ms tick during that window), so reading self.lines.items
        // without the lock is a torn read against a concurrent append/resize.
        bridge_mutex.lockUncancelable(bridge_io);
        defer bridge_mutex.unlock(bridge_io);
        // Idle-time log records (background polls, mesh chatter) are drained
        // here, before the read loop takes a snapshot of self.lines, so the
        // append cannot reallocate the backing storage mid-iteration.
        drainLogLines(self);
        const streaming = bridge_streaming;
        const stream_snapshot = ctx.arena.dupe(u8, bridge_stream_buf.items) catch "";
        var tool_snap: [64]u8 = undefined;
        const tool_snap_len = bridge_active_tool_len;
        if (tool_snap_len > 0) @memcpy(tool_snap[0..tool_snap_len], bridge_active_tool[0..tool_snap_len]);

        // Layout numbers before the status line: its scroll indicator needs
        // the transcript height, which is only known once the input box has
        // claimed its rows.
        const mascot_v = self.mascot.variant();
        // `.input` puts the robot *inside* the composer, so the box grows to
        // hold it and the transcript is left alone. Every other mode reserves
        // transcript rows above the box instead.
        const mascot_in_box = self.mascot.mode == .input and
            max.width >= mascot_v.cols + 4 and
            // The taller box must still leave a transcript worth reading.
            max.height >= mascot.inputBoxHeight(mascot_v) + 5;
        // One composer row per ⏎-separated line. The marker glyph itself is
        // never drawn: terminals disagree with the width table about U+23CE
        // (Konsole renders it wide where the table says one column), and a
        // width disagreement inside the input row garbles everything after
        // it. Instead a buffer holding line breaks grows the box upward and
        // each line gets its own row (`drawComposer`). Growth is capped so
        // the transcript keeps at least a handful of rows; past the cap the
        // block scrolls to keep the cursor's line visible.
        const composer_text = blk: {
            const fh = self.text_field.buf.firstHalf();
            const sh = self.text_field.buf.secondHalf();
            break :blk std.mem.concat(ctx.arena, u8, &.{ fh, sh }) catch fh;
        };
        const composer_total = composerLayout(composer_text, self.text_field.buf.firstHalf().len).line_count;
        const base_box_h: u16 = if (mascot_in_box) mascot.inputBoxHeight(mascot_v) else 3;
        const composer_extra: u16 = @min(composer_total - 1, @min(5, max.height -| (base_box_h + 5)));
        const box_h: u16 = base_box_h + composer_extra;
        // Same session strip as the web UI's `#run-metrics`. One row under
        // the composer once a turn has started; skipped when the terminal
        // cannot hold status + box + this line without overlapping.
        const metrics_h: u16 = if (self.session_turns > 0 and max.height > box_h + 1) 1 else 0;
        const box_y = max.height -| box_h -| metrics_h;
        const top: u16 = 1;
        const frame_bottom = box_y -| 1;
        // Above-the-box modes claim the rows directly above the composer, so
        // the robot runs along the box's top border. Rows are *reserved*
        // rather than drawn over: the transcript ends where the robot begins,
        // so nothing is occluded and a selection can still reach every visible
        // line.
        const mascot_above = self.mascot.enabled() and !mascot_in_box and
            self.mascot.mode != .input and
            mascot.fits(mascot_v, max.width, frame_bottom -| top);
        const mascot_row: u16 = frame_bottom -| mascot_v.rows;
        // Inline command preview: while the draft is a single line starting
        // with `/`, the rows above the frame list which commands it could
        // become — spelling, argument hint, and help — so `/go` answers
        // "what is /goal" before anything is run. The rows are *reserved*
        // from the transcript the same way the robot's are, never drawn
        // over it, and they reuse the palette's session-lifetime labels
        // because vaxis cells borrow their slices past this frame's return.
        // Suppressed while a modal picker owns the screen; capped so a
        // short terminal keeps a readable transcript.
        var preview_buf: [max_completions]*const CommandSpec = undefined;
        const preview_specs: []const *const CommandSpec = if (self.picker_open)
            preview_buf[0..0]
        else
            commandPreviewSpecs(composer_text, &preview_buf);
        const preview_room: u16 = (frame_bottom -| top) -| 4;
        const preview_h: u16 = @min(@as(u16, @intCast(@min(preview_specs.len, max_preview_rows))), preview_room);
        const bottom = (if (mascot_above) mascot_row else frame_bottom) -| preview_h;
        self.transcript_top = top;
        self.transcript_bottom = bottom;
        const avail_rows: u16 = if (bottom > top) bottom - top else 0;
        if (preview_h > 0) {
            for (0..preview_h) |i| {
                const row_y: u16 = bottom + @as(u16, @intCast(i));
                var col: u16 = 2;
                if (i + 1 == preview_h and preview_specs.len > preview_h) {
                    writeRowAt(surface, row_y, &col, "  \xe2\x80\xa6 more \xe2\x80\x94 Ctrl-P opens the full palette", dim);
                    break;
                }
                const spec = preview_specs[i];
                // Registry order is candidate order, but a pointer walk is
                // cheaper to keep correct than an index equation.
                const cand = for (self.command_candidates) |*c| {
                    if (c.spec == spec) break c;
                } else continue;
                const split = cand.label.len - spec.help.len;
                writeRowAt(surface, row_y, &col, cand.label[0..split], if (preview_specs.len == 1) accent_style else .{});
                writeRowAt(surface, row_y, &col, cand.label[split..], dim);
            }
        }

        // Manual scrollback: while `view_end` is set the visible window is
        // anchored to an absolute line index, so a streaming turn appends to
        // `lines` without yanking the reader back to the tail. Re-clamped
        // every frame, a resize changes `avail_rows`, and once everything
        // fits on screen the anchor dissolves back to tail-following.
        const line_count = self.lines.items.len;
        // Overflow, the scrollbar, and the scroll bounds are all row
        // questions, so they are answered by the row-aware walk
        // (`topWindowEnd`), not by comparing line counts against row
        // counts. The bar's column narrows the wrap width, so overflow is
        // judged at full width first and the floor at the width the
        // transcript actually wraps to.
        const show_bar = topWindowEnd(self.lines.items, self.folds.items, avail_rows, max.width) < line_count;
        const text_width: u16 = if (show_bar) max.width -| 1 else max.width;
        // Recorded for the paths that need "the width of the last draw":
        // the key/wheel handlers' `scrollBounds` and `maybeFoldReply`'s
        // foldability judgement (which had been stuck on its 80-column
        // fallback — this field was never assigned anywhere).
        self.last_text_width = text_width;
        const scroll_floor = topWindowEnd(self.lines.items, self.folds.items, avail_rows, text_width);
        if (self.view_end != null and scroll_floor >= line_count) self.view_end = null;
        if (self.view_end) |ve| self.view_end = clampViewEnd(ve, line_count, scroll_floor);
        const view_end = self.view_end orelse line_count;

        const spinner_glyphs = [_][]const u8{ "\xe2\xa0\x8b", "\xe2\xa0\x99", "\xe2\xa0\xb9", "\xe2\xa0\xb8", "\xe2\xa0\xbc", "\xe2\xa0\xb4", "\xe2\xa0\xa6", "\xe2\xa0\xa7", "\xe2\xa0\x87", "\xe2\xa0\x8f" };
        const activity = if (streaming) spinner_glyphs[self.spinner_frame % spinner_glyphs.len] else "";
        // "-N" is how many transcript lines sit below the frozen window:
        // the reader's distance from the tail, and the cue that the view is
        // not following new output right now.
        const scroll_hint: []const u8 = if (self.view_end != null)
            std.fmt.bufPrint(&self.scroll_buf, " \xc2\xb7 [scroll -{d}]", .{line_count - view_end}) catch " \xc2\xb7 [scroll]"
        else
            "";
        // A Model field, not a local, for the same reason `status_buf` and
        // `scroll_buf` are: vaxis cells borrow the grapheme slices written
        // into them until the frame is flushed, which happens after this
        // function has returned and its stack frame is gone. The literal
        // arms below are static strings, but " running <tool>" is formatted
        // here, and that one was pointing at dead stack by render time.
        const phase: []const u8 = if (!streaming)
            idlePhaseLabel(self, &self.phase_buf)
        else if (tool_snap_len > 0)
            std.fmt.bufPrint(&self.phase_buf, " running {s}", .{tool_snap[0..tool_snap_len]}) catch " tool"
        else
            " thinking";
        // The status line is written in coloured segments rather than one
        // flat string: the brand and the active provider/model are the two
        // things the eye looks for, and the phase word carries the run state
        // in colour (green idle, accent while a turn is in flight).
        const dot = " \xc2\xb7 ";
        const model = std.fmt.bufPrint(&self.status_buf, "{s}/{s}", .{ self.provider.name, self.provider.activeModelName() }) catch "";
        var scol: u16 = 0;
        const full_prefix_width = width_mod.displayWidth("clanker") + width_mod.displayWidth(dot) * 2 +
            width_mod.displayWidth(model) + width_mod.displayWidth(activity) + width_mod.displayWidth(phase);
        if (full_prefix_width <= @as(usize, max.width)) {
            // Wide layout preserves the familiar identity-first hierarchy.
            writeRowAt(surface, 0, &scol, "clanker", brand_style);
            writeRowAt(surface, 0, &scol, dot, dim);
            writeRowAt(surface, 0, &scol, model, accent_style);
            writeRowAt(surface, 0, &scol, dot, dim);
            if (activity.len > 0) writeRowAt(surface, 0, &scol, activity, accent_style);
            writeRowAt(surface, 0, &scol, phase, if (streaming) accent_style else prompt_style);
        } else {
            // On a constrained terminal the current state must survive before
            // identity. Optional fields are whole-or-omitted, never clipped
            // into misleading fragments such as a partial model id.
            if (activity.len > 0) writeRowAt(surface, 0, &scol, activity, accent_style);
            writeRowAt(surface, 0, &scol, phase, if (streaming) accent_style else prompt_style);
            _ = writeStatusPairIfFits(surface, &scol, dot, dim, "clanker", brand_style);
            _ = writeStatusPairIfFits(surface, &scol, dot, dim, model, accent_style);
        }
        if (scroll_hint.len > 0 and statusTextFits(max.width, scol, scroll_hint))
            writeRowAt(surface, 0, &scol, scroll_hint, dim);
        // How full the model's window is, what the session has spent, and
        // what that cost: the numbers that decide whether to keep going in
        // this conversation or start a fresh one. Each is omitted when there
        // is nothing honest to say (no configured context window, no turn
        // yet, no priced model) rather than shown as a zero.
        if (stats_mod.contextMeter(&self.meter_buf, self.context_tokens, self.provider.activeModel().context_window)) |meter| {
            _ = writeStatusPairIfFits(surface, &scol, dot, dim, meter, dim);
        }
        if (self.session_tokens > 0) {
            // Scratch only: `compactCount`'s slice is consumed by the
            // bufPrint below, whose result lands in the session-lifetime
            // `tok_buf` the cells actually borrow.
            var scratch: [32]u8 = undefined;
            const tok_text = std.fmt.bufPrint(&self.tok_buf, "{s} tok", .{stats_mod.compactCount(&scratch, self.session_tokens)}) catch "";
            if (tok_text.len > 0) {
                _ = writeStatusPairIfFits(surface, &scol, dot, dim, tok_text, dim);
            }
        }
        if (self.session_cost) |cost| {
            // Session-lifetime total, not a single turn: $200.00 reads
            // better than $200.0000. A sub-dollar session keeps the extra
            // precision, same threshold as the webui's fmtCost.
            const cost_text = if (@abs(cost) >= 1.0)
                std.fmt.bufPrint(&self.cost_buf, "${d:.2}", .{cost}) catch ""
            else
                std.fmt.bufPrint(&self.cost_buf, "${d:.4}", .{cost}) catch "";
            if (cost_text.len > 0) {
                _ = writeStatusPairIfFits(surface, &scol, dot, dim, cost_text, dim);
            }
        }
        if (self.session_id) |sid| {
            _ = writeStatusPairIfFits(surface, &scol, dot, dim, sid, dim);
        }

        if (metrics_h > 0) {
            if (stats_mod.formatSession(&self.metrics_buf, self.sessionStrip())) |line| {
                var mcol: u16 = 0;
                writeRowAt(surface, max.height - 1, &mcol, line, dim);
            }
        }

        drawBox(surface, 0, box_y, max.width, box_h, rule_style);
        // In `.input` mode the robot occupies the right-hand end of the box,
        // so the field is narrowed to leave it alone. Reserving the width
        // rather than drawing over it is what keeps a long line from running
        // underneath the robot, and keeps the caret reachable.
        const input_reserve: u16 = if (mascot_in_box) mascot_v.cols + 1 else 0;
        const input_w = max.width -| 4 -| input_reserve;
        // A break-free buffer keeps the plain single-row TextField (its own
        // horizontal scroll state included); one holding ⏎ markers is drawn
        // by `drawComposer`, one row per line with no marker glyph.
        const input_surf = if (composer_extra == 0)
            try self.text_field.draw(ctx.withConstraints(.{}, .{ .width = input_w, .height = 1 }))
        else
            try self.drawComposer(ctx, composer_text, input_w, composer_extra + 1);
        var children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        // The field ends on the box's *last* interior row, so a taller box
        // grows upward around the robot and the prompt stays where the eye
        // expects it rather than floating at the top of a tall frame.
        const input_row = box_y + box_h -| 2 -| composer_extra;
        children[0] = .{ .origin = .{ .row = input_row, .col = 2 }, .surface = input_surf };
        self.composer_top = input_row;
        self.composer_bottom = input_row + composer_extra + 1;
        self.composer_left = 2;
        self.composer_right = 2 + input_w;
        self.last_input_surface = input_surf;

        // The scrollbar claims the rightmost column whenever the transcript
        // is taller than the region, so text wraps one column short of it.

        var row: u16 = top;
        if (line_count == 0 and !streaming) {
            // Empty state hugs the bottom, just above the input, the way a
            // chat client opens rather than pinning a banner to the top.
            row = bottom -| 7;
            writeWrapped(surface, &row, bottom, text_width, "Type a task to begin, or try:", vaxis.Style{});
            if (row < bottom) row += 1;
            const examples = [_][]const u8{
                "  \"fix the failing test\"",
                "  \"explain src/main.zig\"",
                "  \"refactor the parser\"",
            };
            for (examples) |ex| {
                if (row < bottom) writeWrapped(surface, &row, bottom, text_width, ex, dim);
                if (row < bottom) row += 1;
            }
            if (row < bottom) row += 1;
            if (row < bottom) {
                writeWrapped(surface, &row, bottom, text_width, "Type / to preview commands; Tab completes. Ctrl-P opens the palette. Ctrl-C quits when idle.", dim);
            }
        }
        // Transcript layout: the visible block is bottom-aligned, chat-style,
        // so it hugs the input instead of floating at the top. While a turn
        // streams at the tail, the growing live buffer is reserved space at the
        // bottom and the completed lines fill above it, so the newest text
        // always sits against the input rather than the whole view jumping to
        // the top. Scrolled back (view_end set), the anchored window is frozen.
        // One window computation for every case. Scrolled back during a
        // stream used to take a branch of its own that called `tailStart` — a
        // one-line-per-row guess that ignores wrapping — and top-aligned the
        // result. So the same anchor showed one window while the turn was
        // streaming and a different one the moment it ended: wrapped lines
        // were miscounted, and the block jumped from the top of the region to
        // the bottom. That branch was also redundant. `reserved` is only
        // non-zero when `stream_at_tail`, which requires `view_end == null`,
        // so in the frozen case `for_completed` is already the full height
        // and this general path computes exactly what the special case was
        // reaching for, only wrap-accurately.
        const stream_at_tail = streaming and self.view_end == null;
        const reserved: u16 = if (stream_at_tail)
            @intCast(@min(streamRows(stream_snapshot, text_width), avail_rows))
        else
            0;
        const for_completed: u16 = avail_rows -| reserved;
        const win = tailWindow(self.lines.items[0..view_end], self.folds.items, view_end, for_completed, text_width);
        const start = win.start;
        row = top + (avail_rows -| (win.used_rows + reserved));
        // Lines carry fence_lang when they came out of a code fence; the
        // highlighter state is rebuilt per draw from the tagged lines.
        const fence_on = active.reset.len > 0;
        var syn_style = syntax.Style.fromTheme(&active);
        const hit_line = self.currentHitLine();
        self.fold_hits.clearRetainingCapacity();
        var i: usize = start;
        while (i < view_end and row < bottom) : (i += 1) {
            // A folded reply draws its header row, then only the lines the
            // animation has revealed, and the loop jumps the rest. The header
            // row is recorded so a click can map back to the fold.
            if (self.foldIndexAtStart(i)) |fk| {
                const f = self.folds.items[fk];
                const shown = foldShownLines(f);
                // The header is the toggle, so it is drawn (and its hit
                // registered) in every state — `▸` collapsed, `▾` open. It
                // used to disappear once the fold was fully expanded, which
                // left the reply with no way back to collapsed, and made the
                // draw disagree with `tailWindow`, which counts the header
                // row unconditionally.
                //
                // `self.arena`, not `ctx.arena`: the hit list outlives the
                // frame (a click arrives after the draw that built it) and
                // `clearRetainingCapacity` would otherwise keep appending
                // into a buffer the previous frame's arena already freed.
                self.fold_hits.append(self.arena, .{ .row = row, .fold = fk }) catch {};
                writeWrapped(surface, &row, bottom, text_width, self.foldHeader(ctx.arena, f), fold_style);
                row += 1;
                if (shown < f.count) {
                    // In scrollback the fold may straddle the anchored `view_end`
                    // (start < view_end < start+count); only its body lines inside
                    // the visible window may be drawn, else rows past the anchor
                    // leak onto the screen. `view_end <= self.lines.items.len` and
                    // `i == f.start < view_end`, so the clamp is always in range.
                    const body_limit = @min(shown, view_end - f.start);
                    var k: usize = 0;
                    while (k < body_limit and row < bottom) : (k += 1) {
                        writeWrapped(surface, &row, bottom, text_width, self.lines.items[f.start + k].text, vaxis.Style{});
                        row += 1;
                    }
                    // `i` lands on the last line of the region; the loop's own
                    // increment steps past it.
                    i = f.start + f.count - 1;
                    continue;
                }
                // Fully open: fall through so the body lines keep their rich
                // rendering (markdown, fences, tool cards) — only the
                // partially-revealed animation frames draw plain.
            }
            const l = self.lines.items[i];
            // Each Line is one logical row (finishTurn/printHelp store the
            // transcript pre-split on '\n'). The write helpers advance `row`
            // for their own internal wraps but not past the line, so the loop
            // steps to the next row itself: without this every short line
            // (e.g. the whole /help block) overprints the same row.
            if (hit_line == i) {
                // The line search is currently sitting on, drawn reversed so
                // it is findable at a glance. Taken before the type branches
                // below rather than blended into each of them: a hit can be
                // any kind of line, and "which line am I on" is the only
                // thing that matters while the search bar is up.
                writeWrapped(surface, &row, bottom, text_width, l.text, .{ .reverse = true });
            } else if (l.fence_lang) |lang| {
                var state = syntax.State.init(lang);
                var segs: std.ArrayList(vaxis.Segment) = .empty;
                if (syntax.spansVaxis(&state, &syn_style, ctx.arena, l.text, &segs)) {
                    writeWrappedSegments(ctx, surface, &row, bottom, text_width, segs.items);
                } else |_| {
                    writeWrapped(surface, &row, bottom, text_width, l.text, dim);
                }
            } else if (l.dim and transcript_mod.isToolCardLine(l.text)) {
                // Tool cards (dim, left-bar shaped) get their own tint and a
                // bar-preserving wrap.
                writeWrappedCard(surface, &row, bottom, text_width, l.text, tool_style);
            } else if (l.user) {
                // The user's echoed prompt line: accent, no markdown (it is
                // literal input, not model prose).
                writeWrapped(surface, &row, bottom, text_width, l.text, prompt_style);
            } else if (isErrorLine(l.text)) {
                writeWrapped(surface, &row, bottom, text_width, l.text, err_style);
            } else if (l.dim) {
                // System notices, usage hints, tool output: plain dim.
                writeWrapped(surface, &row, bottom, text_width, l.text, dim);
            } else {
                // Model prose: inline markdown (bold/italic/code, headings,
                // bullets). Falls back to plain on any parse failure.
                var segs: std.ArrayList(vaxis.Segment) = .empty;
                if (mdLineSegments(&active, ctx.arena, l.text, &segs)) {
                    writeWrappedSegments(ctx, surface, &row, bottom, text_width, segs.items);
                } else |_| {
                    writeWrapped(surface, &row, bottom, text_width, l.text, vaxis.Style{});
                }
            }
            row += 1;
        }
        // The live stream renders only at the tail: a scrolled-up window is
        // frozen history, and painting fresh tokens under it would both lie
        // about where they belong and shove the anchored lines around.
        if (streaming and self.view_end == null and row < bottom and stream_snapshot.len > 0) {
            self.writeStream(ctx, surface, &row, bottom, text_width, stream_snapshot, fence_on, &syn_style, &active);
        }

        if (show_bar) drawScrollbar(surface, max.width - 1, top, bottom, start, view_end, line_count, rule_style, accent_style);

        if (self.has_selection) {
            if (self.sel_in_composer) {
                // Painted into the child, translated to its coordinates: the
                // composer surface is composited over the parent, so a
                // highlight painted on the parent would be covered.
                highlightSelection(input_surf, .{
                    .row = self.sel_start.row -| self.composer_top,
                    .col = self.sel_start.col -| self.composer_left,
                }, .{
                    .row = self.sel_end.row -| self.composer_top,
                    .col = self.sel_end.col -| self.composer_left,
                });
            } else {
                highlightSelection(surface, self.sel_start, self.sel_end);
            }
        }
        if (self.search_open) self.drawSearchBar(surface, rule_style, accent_style);
        if (self.picker_open) self.drawModelPicker(surface, rule_style, tool_style);
        if (self.ask_open) self.drawAskModal(surface, rule_style, tool_style);
        // Last, and only into rows the transcript was already shortened out
        // of: drawn earlier, the wrapped-text writers above would paint over
        // it on any frame where the transcript happened to reach this far.
        // Last, and only into space the transcript or the composer was already
        // shortened out of: drawn earlier, the wrapped-text writers above
        // would paint over it on any frame where the transcript reached this
        // far.
        if (mascot_above) {
            self.drawMascot(surface, mascot_row, 0, max.width);
        } else if (mascot_in_box) {
            // Bottom-right of the box interior: one row above the bottom
            // border, inside the left/right borders. Anchoring to the box
            // rather than the screen is what keeps the robot in the corner
            // when the box grows.
            const inner_left: u16 = 1;
            const inner_width = max.width -| 2;
            const inner_bottom = box_y + box_h -| 1;
            self.drawMascot(surface, inner_bottom -| mascot_v.rows, inner_left, inner_width);
        }
        self.last_surface = surface;

        surface.children = children;
        return surface;
    }

    /// The search bar: one bordered row above the input, in the same box
    /// style as the input and the pickers. Deliberately smaller than a
    /// picker — search has no list to choose from, the transcript itself is
    /// the result, so a tall modal would only cover the thing being searched.
    fn drawSearchBar(self: *Model, surface: vxfw.Surface, rule_style: vaxis.Style, accent: vaxis.Style) void {
        if (surface.size.width < 12) return;
        const h: u16 = 4;
        const y = self.transcript_bottom -| h;
        clearBoxInterior(surface, 0, y, surface.size.width, h);
        drawBox(surface, 0, y, surface.size.width, h, rule_style);

        var col: u16 = 2;
        writeRowAt(surface, y + 1, &col, "search ", .{ .bold = true });
        writeRowAt(surface, y + 1, &col, self.search_query.items, .{ .bold = true });
        writeRowAt(surface, y + 1, &col, "\xe2\x96\x8f", .{ .bold = true });

        const guide = searchGuide(
            &self.search_pos_buf,
            self.search_query.items.len == 0,
            self.search_idx,
            self.search_hits.items.len,
            surface.size.width,
        );
        writeRow(surface, y + 2, guide, if (self.search_hits.items.len == 0 and self.search_query.items.len > 0) rule_style else accent);
    }

    /// Draws the ask/confirm modal, same box style and position as the
    /// `/model` picker so it reads as part of this REPL. Held under the ask
    /// lock for the whole draw: the option strings are freed the moment the
    /// run thread wakes (timeout included), and a borrow across that would
    /// paint freed bytes. The critical section is a few rows of cells.
    fn drawAskModal(self: *Model, surface: vxfw.Surface, rule_style: vaxis.Style, sel_style: vaxis.Style) void {
        _ = std.c.pthread_mutex_lock(&ask_mutex);
        defer _ = std.c.pthread_mutex_unlock(&ask_mutex);
        if (!pending_ask.active or pending_ask.answered) return;
        const opts = pending_ask.options;
        if (opts.len == 0 or surface.size.width < 8) return;
        const max_rows: u16 = 8;
        const rows_shown: u16 = @intCast(@min(opts.len, max_rows));
        const h: u16 = rows_shown + 4; // border + question + rows + key guide + border
        const y = self.transcript_bottom -| h;
        clearBoxInterior(surface, 0, y, surface.size.width, h);
        drawBox(surface, 0, y, surface.size.width, h, rule_style);

        const label: []const u8 = switch (pending_ask.kind) {
            .ask => "ask  ",
            .confirm => "confirm write  ",
        };
        writeRow(surface, y + 1, label, .{ .bold = true });
        var col: u16 = @intCast(label.len);
        writeRowAt(surface, y + 1, &col, pending_ask.question, .{});

        const sel = @min(self.ask_selected, opts.len - 1);
        const first = pickerWindowStart(sel, opts.len, max_rows);
        var row: u16 = y + 2;
        var i: usize = 0;
        while (i < rows_shown) : (i += 1) {
            const idx = first + i;
            const marker: []const u8 = if (idx == sel) "\xe2\x80\xba " else "  ";
            const style = if (idx == sel) sel_style else vaxis.Style{};
            writeRow(surface, row, marker, style);
            var ocol: u16 = 2;
            writeRowAt(surface, row, &ocol, opts[idx], style);
            row += 1;
        }
        writeRow(surface, row, askGuide(pending_ask.kind, surface.size.width), .{ .dim = true });
    }

    /// Draws the `/model` picker as a modal box over the tail of the
    /// transcript, just above the input, same left-bar box style as the
    /// input itself (`drawBox`), so it reads as part of this REPL rather
    /// than a bolted-on popup.
    fn drawModelPicker(self: *Model, surface: vxfw.Surface, rule_style: vaxis.Style, sel_style: vaxis.Style) void {
        const is_theme = self.picker_kind == .theme;
        const is_command = self.picker_kind == .command;
        // Row count for whichever list is open; theme labels come from a
        // static names list, model and command labels from their candidates.
        const theme_matches = if (is_theme) self.filteredThemes() else &[_][]const u8{};
        const model_matches = if (self.picker_kind == .model) self.filteredCandidates() else &[_]ModelCandidate{};
        const command_matches = if (is_command) self.filteredCommands() else &[_]CommandCandidate{};
        const effort_matches = if (self.picker_kind == .effort) self.filteredEffortOptions() else &[_]EffortOption{};
        const preset_matches = if (self.picker_kind == .preset) self.filteredPresets() else &[_]PresetCandidate{};
        const current_effort: EffortChoice = if (self.picker_kind == .effort)
            effortCurrentOption(resolveEffort(&self.cfg, &self.provider))
        else
            .default;
        const count = switch (self.picker_kind) {
            .theme => theme_matches.len,
            .model => model_matches.len,
            .command => command_matches.len,
            .effort => effort_matches.len,
            .preset => preset_matches.len,
        };
        const max_rows: u16 = 8;
        const rows_shown: u16 = @intCast(@min(count, max_rows));
        // Effort gets one extra row above the guide: where the effective
        // effort comes from, which no row shows. Model rows already carry
        // their whole spec inline, so a detail row there would repeat the
        // highlighted row in grey and read as a second highlight.
        const detail_extra: u16 = if (count > 0 and self.picker_kind == .effort) 1 else 0;
        // The picker commits on Enter, so teach its controls at the decision
        // point instead of expecting the user to remember the /help prose.
        const h = pickerHeight(count, max_rows) + detail_extra; // border + query + rows/empty + [detail] + guide + border
        if (surface.size.width < 8) return;
        const y = self.transcript_bottom -| h;
        clearBoxInterior(surface, 0, y, surface.size.width, h);
        drawBox(surface, 0, y, surface.size.width, h, rule_style);

        const prompt: []const u8 = switch (self.picker_kind) {
            .theme => "/theme ",
            .model => "/model ",
            .command => "> ",
            .effort => "/effort ",
            .preset => "/preset ",
        };
        writeRow(surface, y + 1, prompt, .{ .bold = true });
        var query_col: u16 = @intCast(prompt.len);
        writeRowAt(surface, y + 1, &query_col, self.picker_query.items, .{ .bold = true });
        writeRowAt(surface, y + 1, &query_col, "\xe2\x96\x8f", .{ .bold = true });

        if (count == 0) {
            writeRow(surface, y + 2, switch (self.picker_kind) {
                .theme => "  no matching theme",
                .model => "  no matching provider/model",
                .command => "  no matching command",
                .effort => "  no matching effort level",
                .preset => "  no matching preset",
            }, .{ .dim = true });
        } else {
            const sel = @min(self.picker_selected, count - 1);
            // The window scrolls with the selection. `i` used to index the list
            // directly, so only entries 0..7 were ever drawn while Up/Down walked
            // `picker_selected` across the whole list: past the eighth match the
            // highlight left the box and the picker committed on Enter to a row
            // that had never been on screen. Any real config reaches this — the
            // repo's own has well over eight models.
            const first = pickerWindowStart(sel, count, max_rows);
            var row: u16 = y + 2;
            var i: usize = 0;
            while (i < rows_shown) : (i += 1) {
                const idx = first + i;
                const marker: []const u8 = if (idx == sel) "\xe2\x80\xba " else "  ";
                const style = if (idx == sel) sel_style else vaxis.Style{};
                writeRow(surface, row, marker, style);
                var col: u16 = 2;
                const label = switch (self.picker_kind) {
                    .theme => theme_matches[idx],
                    .model => model_matches[idx].label,
                    .command => command_matches[idx].label,
                    .effort => effort_matches[idx].label,
                    .preset => preset_matches[idx].name,
                };
                writeRowAt(surface, row, &col, label, style);
                // Effort and preset rows carry their one-line description
                // inline (static/arena memory, never draw-stack); the active
                // model and preset and the current effort are marked in place.
                switch (self.picker_kind) {
                    .effort => {
                        if (std.meta.eql(effort_matches[idx].choice, current_effort))
                            writeRowAt(surface, row, &col, "  (current)", style);
                        writeRowAt(surface, row, &col, "  ", style);
                        writeRowAt(surface, row, &col, effort_matches[idx].description, .{ .dim = true });
                    },
                    .preset => {
                        if (self.preset_name) |pn| {
                            if (std.mem.eql(u8, pn, preset_matches[idx].name))
                                writeRowAt(surface, row, &col, "  (active)", style);
                        }
                        if (preset_matches[idx].description.len > 0) {
                            writeRowAt(surface, row, &col, "  ", style);
                            writeRowAt(surface, row, &col, preset_matches[idx].description, .{ .dim = true });
                        }
                    },
                    .theme => {
                        // A twelve-block palette swatch after the name, so the
                        // live preview is not the only colour on screen: each
                        // row shows its full palette before it is applied.
                        writeRowAt(surface, row, &col, "  ", style);
                        _ = writeThemePalette(surface, row, &col, theme_matches[idx]);
                    },
                    .model => {
                        const c = model_matches[idx];
                        if (std.mem.eql(u8, c.provider, self.provider.name) and std.mem.eql(u8, c.model, self.provider.default_model))
                            writeRowAt(surface, row, &col, "  (active)", style);
                    },
                    else => {},
                }
                row += 1;
            }
        }
        if (detail_extra == 1) {
            // Only the source: the level itself is already the row wearing
            // the (current) marker, and repeating it here in grey was the
            // same double-highlight confusion the /model detail row had.
            const res = resolveEffort(&self.cfg, &self.provider);
            const detail = std.fmt.bufPrint(&self.picker_detail_buf, "  source: {s}", .{effortSourceLabel(res.source)}) catch "";
            if (detail.len > 0) writeRow(surface, y + h - 3, detail, .{ .dim = true });
        }
        const sel = if (count > 0) @min(self.picker_selected, count - 1) else 0;
        const pos = if (count > max_rows)
            std.fmt.bufPrint(&self.picker_pos_buf, "{d}/{d}", .{ sel + 1, count }) catch ""
        else
            "";
        const guide_width = surface.size.width -| @as(u16, @intCast(if (pos.len > 0) pos.len + 3 else 0));
        const guide = pickerGuide(self.picker_kind, count == 0, guide_width);
        writeRow(surface, y + h - 2, guide, .{ .dim = true });
        // Position within the list, right-aligned on the guide row: with a
        // scrolling window the eight visible rows no longer say how much list
        // there is or where in it you are. Only shown when something is off
        // screen. A Model field because vaxis cells borrow the slice until
        // the frame flushes, which is after this function has returned.
        if (pos.len > 0) {
            if (pos.len > 0 and surface.size.width > pos.len + 3) {
                var pos_col: u16 = @intCast(surface.size.width - pos.len - 2);
                writeRowAt(surface, y + h - 2, &pos_col, pos, .{ .dim = true });
            }
        }
    }

    /// Renders the live streaming buffer with the same fence-aware syntax
    /// highlighting the completed transcript gets, so a code block looks the
    /// same while it streams as it does once folded in (it used to render as
    /// flat unstyled text with the ``` markers showing). `fence_on` is whether
    /// the theme has colour at all; with it off everything falls back to plain.
    fn writeStream(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface, row: *u16, bottom: u16, width: u16, text: []const u8, fence_on: bool, syn_style: *const syntax.Style, active: *const theme_mod.Theme) void {
        _ = self;
        var in_fence = false;
        var fence_lang: []const u8 = "";
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (row.* >= bottom) return;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "```")) {
                if (in_fence) {
                    in_fence = false;
                } else {
                    in_fence = true;
                    fence_lang = std.mem.trim(u8, trimmed[3..], " ");
                }
                continue; // markers themselves are not shown, same as finishTurn
            }
            if (in_fence and fence_on) {
                var state = syntax.State.init(fence_lang);
                var segs: std.ArrayList(vaxis.Segment) = .empty;
                if (syntax.spansVaxis(&state, syn_style, ctx.arena, line, &segs)) {
                    writeWrappedSegments(ctx, surface, row, bottom, width, segs.items);
                } else |_| {
                    writeWrapped(surface, row, bottom, width, line, .{});
                }
            } else if (fence_on) {
                // Live prose: same inline markdown the completed transcript
                // gets, so bold/italic/code render as they stream in. A marker
                // still opening (a `**` with no close yet) stays literal until
                // the rest arrives.
                var segs: std.ArrayList(vaxis.Segment) = .empty;
                if (mdLineSegments(active, ctx.arena, line, &segs)) {
                    writeWrappedSegments(ctx, surface, row, bottom, width, segs.items);
                } else |_| {
                    writeWrapped(surface, row, bottom, width, line, .{});
                }
            } else {
                writeWrapped(surface, row, bottom, width, line, .{});
            }
            row.* += 1;
        }
    }
};

/// How many terminal rows one transcript line occupies at `width`: its
/// display width divided up by the wrap column, at least one. Embedded
/// newlines are rare (finishTurn/printHelp pre-split on '\n') but counted so
/// a line that does carry one still reserves its rows.
fn lineRows(text: []const u8, width: u16) usize {
    if (width == 0) return 1;
    var rows: usize = 1;
    var col: usize = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepointSlice()) |cp| {
        if (std.mem.eql(u8, cp, "\n")) {
            rows += 1;
            col = 0;
            continue;
        }
        const w = width_mod.displayWidth(cp);
        if (col + w > width) {
            rows += 1;
            col = 0;
        }
        col += w;
    }
    return rows;
}

/// Rows the live stream buffer will occupy, mirroring writeStream's line
/// handling (fence-marker lines are skipped, everything else wraps), so the
/// bottom-anchor math can reserve exactly the space the stream renders into.
fn streamRows(text: []const u8, width: u16) usize {
    if (text.len == 0) return 0;
    var rows: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "```")) continue;
        rows += lineRows(line, width);
    }
    return rows;
}

/// The bottom-aligned window: walk backward from `view_end` accumulating
/// wrapped rows until the next line would overflow `avail_rows`, so the
/// newest line always lands at the bottom edge and nothing is clipped there
/// (unlike a plain line-count guess). Returns the first visible line and
/// the rows it and its successors occupy; `avail_rows - used_rows` is the
/// blank offset that pins short transcripts to the bottom, chat-style.
///
/// Folds (see `Fold`) are atomic blocks: any line inside a reply's range
/// contributes that reply's folded height (1 header row + the currently
/// revealed body rows) and the walk jumps the whole block in one step, so a
/// reply is treated as a unit. In scrollback the block can straddle the
/// anchored `view_end` (start < view_end < start+count); only its body lines
/// inside `[start, view_end)` are counted, since the draw loop renders no
/// more than those (see its `body_limit` clamp). `lines` here is
/// `self.lines.items[0..view_end]`, so slicing past `view_end` would panic.
fn tailWindow(
    lines: []const Line,
    folds: []const Fold,
    view_end: usize,
    avail_rows: u16,
    width: u16,
) struct { start: usize, used_rows: u16 } {
    var used: usize = 0;
    var start = view_end;
    while (start > 0) {
        const i = start - 1;
        var rows: usize = lineRows(lines[i].text, width);
        var block_start = i;
        // The fold whose region contains `i`, if any. `folds` is sorted by
        // `start` (see `foldIndexAtStart`), so the candidate is the last fold
        // that starts at or before `i`, checked for containment; the scan of
        // every fold per candidate line this replaced made `tailWindow`
        // O(scrolled rows × folds) per frame.
        const idx = std.sort.upperBound(Fold, folds, i, struct {
            fn cmp(context: usize, f: Fold) std.math.Order {
                return std.math.order(context, f.start);
            }
        }.cmp);
        if (idx > 0) {
            const f = folds[idx - 1];
            if (i >= f.start and i < f.start + f.count) {
                const shown = foldShownLines(f);
                // A fully open fold renders per-line (the draw loop falls
                // through to rich rendering), so it must scroll per-line
                // too: only the header row is extra, on the fold's first
                // line. Treating it as a block pinned the window at the
                // header for every anchor inside the fold, so a
                // screen-taller reply could not be scrolled through.
                if (shown >= f.count) {
                    if (i == f.start) rows += 1;
                } else {
                    // Collapsed or animating, drawn rows differ from line rows,
                    // so the block stays atomic: header row plus exactly the
                    // lines the draw loop will render, counted the same way it
                    // counts them (`foldShownLines`, clamped to the visible
                    // window). `f.start < view_end` here because
                    // `i == start - 1 >= f.start` and `start <= view_end`, so
                    // the clamped range never starts past `lines.len`.
                    rows = 1;
                    const body_end = @min(f.start + shown, view_end);
                    for (lines[f.start..body_end]) |l| {
                        rows += lineRows(l.text, width);
                    }
                    block_start = f.start;
                }
            }
        }
        if (used + rows > avail_rows and used > 0) break;
        used += rows;
        start = block_start;
        if (used >= avail_rows) break;
    }
    return .{ .start = start, .used_rows = @intCast(@min(used, avail_rows)) };
}

/// Decide whether the reply occupying `lines[reply_start..]` is tall enough
/// to fold, judged on wrapped rows at `width` so short replies never fold.
/// Pure over its arguments so the decision is testable without a Model.
///
/// A reply that folds loses the `turn_arrow` from its first line: the fold
/// header row is the turn marker from then on, and keeping both rendered
/// the arrow as a stray prompt glyph on the first body line of an expanded
/// fold. An unfolded reply keeps the arrow — it is its only marker.
fn foldForReply(lines: []Line, reply_start: usize, width: u16) ?Fold {
    const count = lines.len - reply_start;
    if (count == 0) return null;
    var rows: usize = 0;
    for (lines[reply_start..]) |l| {
        rows += lineRows(l.text, width);
        if (rows > FOLD_MIN_ROWS) break;
    }
    if (rows <= FOLD_MIN_ROWS) return null;
    const first = &lines[reply_start];
    if (std.mem.startsWith(u8, first.text, turn_arrow))
        first.text = first.text[turn_arrow.len..];
    return .{ .start = reply_start, .count = count, .expanded = false, .anim = 0 };
}

/// How many of a fold's lines are currently revealed. Quantised to whole
/// *lines* rather than wrapped rows because the draw loop can only stop
/// between lines: measuring the layout in rows while rendering in lines let
/// the two disagree, and the transcript was then bottom-aligned for a height
/// it did not draw, clipping the tail of every folded reply.
fn foldShownLines(fold: Fold) usize {
    if (fold.anim >= 1) return fold.count;
    if (fold.anim <= 0) return 0;
    const eased = foldEase(fold.anim) * @as(f32, @floatFromInt(fold.count));
    return @min(fold.count, @as(usize, @round(eased)));
}

/// Ease curve for the fold animation (smoothstep): fast middle, eased ends.
fn foldEase(t: f32) f32 {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    return t * t * (3 - 2 * t);
}

// ---------------------------------------------------------------------
// Manual-scrollback math. All pure over (anchor, line_count, avail_rows)
// so the paging behaviour is unit-testable without a terminal: the anchor
// is Model.view_end, null means "follow the tail", non-null is the
// absolute line index (exclusive) the visible window ends at. Counted in
// `lines` entries; `tailWindow` turns that into wrap-accurate rows.
// ---------------------------------------------------------------------

/// First list index the picker's visible window shows, given the selected
/// index, how many entries there are, and how many rows fit.
///
/// Stateless: derived from the selection every frame rather than carried as
/// a scroll offset, so there is no second piece of state to keep in sync with
/// `picker_selected` (filtering already resets that to 0 on every keystroke,
/// and an offset that did not reset with it would strand the window). While
/// the selection is within the first page the window stays at the top, which
/// is what makes the common case — a query narrowed to a handful of matches —
/// look exactly as it did before; past that the selection rides the bottom
/// row. Always returns a start whose full window fits inside `count`.
fn pickerWindowStart(selected: usize, count: usize, max_rows: u16) usize {
    if (count <= max_rows or max_rows == 0) return 0;
    if (selected < max_rows) return 0;
    const start = selected + 1 - max_rows;
    return @min(start, count - max_rows);
}

/// Key guide that fits as a whole. Recovery (`Esc cancel`) is never the
/// clipped suffix: constrained pickers progressively drop navigation detail
/// while retaining the way out, including when a filter has zero results.
fn pickerGuide(kind: PickerKind, empty: bool, width: u16) []const u8 {
    const full: []const u8 = if (empty)
        "  no match · type or Backspace to edit · Esc cancel"
    else switch (kind) {
        .theme => "  Up/Down preview · Enter keep · Esc cancel",
        .model => "  Up/Down move · Enter select · Esc cancel",
        .command => "  Up/Down move · Enter run or fill args · Esc cancel",
        .effort => "  Up/Down move · Enter pin (default clears) · Esc cancel",
        .preset => "  Up/Down move · Enter apply · Esc cancel",
    };
    const compact: []const u8 = if (empty)
        "  edit query · Esc cancel"
    else switch (kind) {
        .theme => "  Enter keep · Esc cancel",
        .model => "  Enter select · Esc cancel",
        .command => "  Enter run · Esc cancel",
        .effort => "  Enter pin · Esc cancel",
        .preset => "  Enter apply · Esc cancel",
    };
    if (width_mod.displayWidth(full) <= width) return full;
    if (width_mod.displayWidth(compact) <= width) return compact;
    return if (width >= width_mod.displayWidth("  Esc cancel")) "  Esc cancel" else "";
}

/// The safe exit stays visible even when the decision modal is only eight
/// columns wide. Detail returns progressively; no variant is clipped into a
/// misleading partial action such as "Enter ans" with denial off-screen.
fn askGuide(kind: AskKind, width: u16) []const u8 {
    const full: []const u8 = switch (kind) {
        .ask => "  Up/Down or 1-9 pick · Enter answer · Esc decline",
        .confirm => "  Up/Down pick · Enter answer · Esc deny · Ctrl-C deny and stop",
    };
    const compact: []const u8 = switch (kind) {
        .ask => "  Enter answer · Esc decline",
        .confirm => "  Enter answer · Esc deny",
    };
    const recovery: []const u8 = switch (kind) {
        .ask => " Esc decline",
        .confirm => "  Esc deny",
    };
    if (width_mod.displayWidth(full) <= width) return full;
    if (width_mod.displayWidth(compact) <= width) return compact;
    if (width_mod.displayWidth(recovery) <= width) return recovery;
    return if (width >= 3) "Esc" else "";
}

fn searchGuide(buf: []u8, query_empty: bool, hit_index: usize, hit_count: usize, width: u16) []const u8 {
    const full = if (query_empty)
        "  type to search · Up/Down step · Enter stay · Esc back"
    else if (hit_count == 0)
        "  no match · type or Backspace to edit · Esc back"
    else
        std.fmt.bufPrint(buf, "  {d}/{d} · Up/Down step · Enter stay · Esc back", .{ hit_index + 1, hit_count }) catch "";
    if (width_mod.displayWidth(full) <= width) return full;
    const compact = if (query_empty)
        "  type to search · Esc back"
    else if (hit_count == 0)
        "  no match · Esc back"
    else
        std.fmt.bufPrint(buf, "  {d}/{d} · Esc back", .{ hit_index + 1, hit_count }) catch "";
    if (width_mod.displayWidth(compact) <= width) return compact;
    return if (width >= width_mod.displayWidth("  Esc back")) "  Esc back" else "";
}

/// Backspace for modal query buffers. Key events may carry a multi-byte UTF-8
/// codepoint; removing one byte leaves an invalid query that display-width
/// and fuzzy matching cannot interpret consistently. A malformed tail is
/// repaired conservatively one byte at a time.
fn popUtf8Codepoint(text: *std.ArrayList(u8)) bool {
    if (text.items.len == 0) return false;
    var start = text.items.len - 1;
    while (start > 0 and text.items[start] & 0xc0 == 0x80) start -= 1;
    const new_len = if (std.unicode.utf8ValidateSlice(text.items[start..])) start else text.items.len - 1;
    text.shrinkRetainingCapacity(new_len);
    return true;
}

fn pickerHeight(count: usize, max_rows: u16) u16 {
    const rows_shown: u16 = @intCast(@min(count, max_rows));
    return @max(rows_shown, 1) + 4;
}

test "pickerWindowStart keeps the selection on screen and the window in range" {
    // Everything fits: no scrolling, ever.
    try std.testing.expectEqual(@as(usize, 0), pickerWindowStart(0, 5, 8));
    try std.testing.expectEqual(@as(usize, 0), pickerWindowStart(4, 5, 8));
    try std.testing.expectEqual(@as(usize, 0), pickerWindowStart(7, 8, 8));

    // Longer list: the first page stays pinned to the top...
    try std.testing.expectEqual(@as(usize, 0), pickerWindowStart(0, 24, 8));
    try std.testing.expectEqual(@as(usize, 0), pickerWindowStart(7, 24, 8));
    // ...then the selection rides the bottom row.
    try std.testing.expectEqual(@as(usize, 1), pickerWindowStart(8, 24, 8));
    try std.testing.expectEqual(@as(usize, 9), pickerWindowStart(16, 24, 8));

    // The last entry never scrolls past the end of the list: the window is
    // full, not short, so no blank rows appear under the final match.
    try std.testing.expectEqual(@as(usize, 16), pickerWindowStart(23, 24, 8));
    try std.testing.expectEqual(@as(usize, 16), pickerWindowStart(99, 24, 8));

    // The window always fits: start + max_rows never runs past count.
    for (0..24) |sel| {
        const start = pickerWindowStart(sel, 24, 8);
        try std.testing.expect(start + 8 <= 24);
        try std.testing.expect(sel >= start and sel < start + 8);
    }

    // Degenerate inputs stay in range rather than underflowing.
    try std.testing.expectEqual(@as(usize, 0), pickerWindowStart(3, 24, 0));
    try std.testing.expectEqual(@as(usize, 0), pickerWindowStart(0, 0, 8));
}

test "picker guides preserve recovery at constrained widths" {
    for ([_]PickerKind{ .model, .theme, .command }) |kind| {
        for ([_]u16{ 12, 24, 40, 80 }) |width| {
            for ([_]bool{ false, true }) |empty| {
                const guide = pickerGuide(kind, empty, width);
                try std.testing.expect(width_mod.displayWidth(guide) <= width);
                try std.testing.expect(std.mem.find(u8, guide, "Esc cancel") != null);
            }
        }
    }
}

test "ask and confirmation guides preserve a safe exit" {
    for ([_]AskKind{ .ask, .confirm }) |kind| {
        for ([_]u16{ 8, 10, 12, 24, 40, 80 }) |width| {
            const guide = askGuide(kind, width);
            try std.testing.expect(width_mod.displayWidth(guide) <= width);
            try std.testing.expect(std.mem.find(u8, guide, "Esc") != null);
        }
    }
    try std.testing.expect(std.mem.find(u8, askGuide(.confirm, 80), "Ctrl-C deny and stop") != null);
}

test "search guides preserve state and recovery at constrained widths" {
    for ([_]u16{ 12, 20, 32, 48, 80 }) |width| {
        var buf: [96]u8 = undefined;
        for ([_]struct { empty: bool, index: usize, count: usize }{
            .{ .empty = true, .index = 0, .count = 0 },
            .{ .empty = false, .index = 0, .count = 0 },
            .{ .empty = false, .index = 2, .count = 7 },
        }) |state| {
            const guide = searchGuide(&buf, state.empty, state.index, state.count, width);
            try std.testing.expect(width_mod.displayWidth(guide) <= width);
            try std.testing.expect(std.mem.find(u8, guide, "Esc back") != null);
        }
    }
    var buf: [96]u8 = undefined;
    try std.testing.expect(std.mem.find(u8, searchGuide(&buf, false, 2, 7, 80), "3/7") != null);
    try std.testing.expect(std.mem.find(u8, searchGuide(&buf, false, 0, 0, 32), "no match") != null);
}

test "modal query Backspace removes one UTF-8 codepoint" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try text.appendSlice(std.testing.allocator, "aé🙂");
    try std.testing.expect(popUtf8Codepoint(&text));
    try std.testing.expectEqualStrings("aé", text.items);
    try std.testing.expect(popUtf8Codepoint(&text));
    try std.testing.expectEqualStrings("a", text.items);
    try std.testing.expect(popUtf8Codepoint(&text));
    try std.testing.expectEqualStrings("", text.items);
    try std.testing.expect(!popUtf8Codepoint(&text));

    // Invalid external key text cannot cause Backspace to eat the preceding
    // valid codepoint; each press removes one malformed trailing byte.
    try text.appendSlice(std.testing.allocator, "ok\x80\x80");
    try std.testing.expect(popUtf8Codepoint(&text));
    try std.testing.expectEqualSlices(u8, "ok\x80", text.items);
    try std.testing.expect(popUtf8Codepoint(&text));
    try std.testing.expectEqualStrings("ok", text.items);
}

test "empty picker reserves separate result and guide rows" {
    try std.testing.expectEqual(@as(u16, 5), pickerHeight(0, 8));
    try std.testing.expectEqual(@as(u16, 5), pickerHeight(1, 8));
    try std.testing.expectEqual(@as(u16, 12), pickerHeight(8, 8));
    try std.testing.expectEqual(@as(u16, 12), pickerHeight(20, 8));
}

// ---------------------------------------------------------------------
// Transcript search. Scrollback paging (PgUp/PgDn/Home/End) finds a place
// you can already point at; this finds one you can only describe. Both
// drive the same `view_end` anchor, so a search hit and a paged-to line are
// the same kind of thing to everything downstream — the draw, the
// scrollbar, the bottom-alignment math — rather than a second notion of
// "where the transcript is looking".
// ---------------------------------------------------------------------

/// Case-insensitive substring test. Deliberately not `fuzzyMatch`: a
/// subsequence match over a long transcript matches almost every line
/// (`abc` would hit any line containing an a, then a b, then a c), which is
/// useful for picking one of a dozen commands and useless for finding one
/// line in a thousand. Search wants the literal thing you remember reading.
fn lineContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Indices of every transcript line matching `needle`, oldest first.
/// Written into `out` (cleared first) so the caller owns the storage.
fn findHits(lines: []const Line, needle: []const u8, gpa: std.mem.Allocator, out: *std.ArrayList(usize)) void {
    out.clearRetainingCapacity();
    if (needle.len == 0) return;
    for (lines, 0..) |l, i| {
        if (lineContains(l.text, needle)) out.append(gpa, i) catch return;
    }
}

/// The `view_end` anchor that puts hit line `hit` on screen with roughly
/// half a screen of context below it, so a match lands mid-view rather than
/// hard against the bottom edge where its surroundings are invisible.
/// Clamped exactly like every other anchor, so a hit near either end of the
/// transcript still yields a full window.
fn searchViewEnd(hit: usize, line_count: usize, avail_rows: u16, floor: usize) ?usize {
    if (floor >= line_count) return null; // everything already visible
    const half: usize = @max(1, avail_rows / 2);
    return clampViewEnd(hit + half, line_count, floor);
}

test "lineContains is a case-insensitive substring, not a subsequence" {
    try std.testing.expect(lineContains("the quick brown fox", "quick"));
    try std.testing.expect(lineContains("the QUICK brown fox", "quick"));
    try std.testing.expect(lineContains("the quick brown fox", "QUICK"));
    try std.testing.expect(lineContains("abc", "abc"));

    // A subsequence is not a match: this is the whole reason search does not
    // reuse fuzzyMatch, which would call "qbf" a hit on the line above.
    try std.testing.expect(!lineContains("the quick brown fox", "qbf"));
    try std.testing.expect(!lineContains("short", "much longer needle"));
    // An empty query matches nothing rather than everything, so an
    // open-but-untyped search bar does not claim every line is a hit.
    try std.testing.expect(!lineContains("anything", ""));
}

test "findHits reports matching line indices oldest first" {
    const lines = [_]Line{
        .{ .text = "clanker> build the parser" },
        .{ .text = "the PARSER is in src/parse.zig" },
        .{ .text = "unrelated" },
        .{ .text = "parser again" },
    };
    var hits: std.ArrayList(usize) = .empty;
    defer hits.deinit(std.testing.allocator);

    findHits(&lines, "parser", std.testing.allocator, &hits);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 3 }, hits.items);

    // Re-running replaces the previous result rather than appending to it.
    findHits(&lines, "unrelated", std.testing.allocator, &hits);
    try std.testing.expectEqualSlices(usize, &.{2}, hits.items);

    findHits(&lines, "nothing here", std.testing.allocator, &hits);
    try std.testing.expectEqual(@as(usize, 0), hits.items.len);

    findHits(&lines, "", std.testing.allocator, &hits);
    try std.testing.expectEqual(@as(usize, 0), hits.items.len);
}

test "searchViewEnd centres a hit and clamps at both ends" {
    // 200 lines, 24 visible: a hit in the middle lands with ~half a screen
    // of context below it.
    try std.testing.expectEqual(@as(?usize, 112), searchViewEnd(100, 200, 24, 24));
    // A hit near the top still fills a whole window rather than showing
    // blank rows above line 0.
    try std.testing.expectEqual(@as(?usize, 24), searchViewEnd(0, 200, 24, 24));
    try std.testing.expectEqual(@as(?usize, 24), searchViewEnd(5, 200, 24, 24));
    // A hit near the bottom stops at the end of the transcript.
    try std.testing.expectEqual(@as(?usize, 200), searchViewEnd(199, 200, 24, 24));
    // Nothing to scroll (floor at the line count): stay following the tail.
    try std.testing.expectEqual(@as(?usize, null), searchViewEnd(3, 10, 24, 10));
}

/// One PgUp/PgDn stride: a screenful less one line of overlap so the reader
/// keeps a continuity line across pages, never less than one row.
fn scrollPage(avail_rows: u16) usize {
    return if (avail_rows > 1) avail_rows - 1 else 1;
}

/// The lowest anchor worth scrolling to: the largest `view_end` whose
/// window still reaches line 0. Rows are counted forward from the top,
/// wrap-aware and fold-aware exactly as `tailWindow` counts them (a
/// collapsed or animating fold is an atomic block, a fully open one is
/// per-line plus its header row), until the screen is full. Returns
/// `lines.len` when the whole transcript fits — nothing to scroll then.
///
/// This is what the scroll guards and `clampViewEnd`'s floor must use.
/// They used to compare the *line* count against the screen's *row*
/// count, which are only the same thing when nothing wraps and no fold
/// exists; an expanded fold adds a header row (and its wraps), so a
/// transcript could overflow the screen in rows while the guards saw it
/// fitting in lines and refused to scroll at all — with the anchor floor
/// stranded mid-fold when they did.
fn topWindowEnd(lines: []const Line, folds: []const Fold, avail_rows: u16, width: u16) usize {
    var rows: usize = 0;
    var i: usize = 0;
    while (i < lines.len) {
        var line_rows: usize = lineRows(lines[i].text, width);
        var next: usize = i + 1;
        for (folds) |f| {
            if (i >= f.start and i < f.start + f.count) {
                const shown = foldShownLines(f);
                if (shown >= f.count) {
                    if (i == f.start) line_rows += 1;
                } else {
                    line_rows = 1;
                    for (lines[f.start .. f.start + shown]) |l| line_rows += lineRows(l.text, width);
                    next = f.start + f.count;
                }
                break;
            }
        }
        if (rows + line_rows > avail_rows) return @max(1, i);
        rows += line_rows;
        i = next;
    }
    return lines.len;
}

/// Clamps an anchored window end to what can actually be shown: no earlier
/// than `floor` (`topWindowEnd` — below it the window gains no line) and
/// no later than the transcript's end.
fn clampViewEnd(view_end: usize, line_count: usize, floor: usize) usize {
    const min_end = @min(line_count, floor);
    return @max(min_end, @min(view_end, line_count));
}

/// PgUp: one page up from `cur` (null = following the tail). Returns null:
/// stay at the tail, when the whole transcript already fits on screen
/// (`floor` at the line count), so PgUp in a short session is a no-op
/// rather than a stuck anchor.
fn scrollUpEnd(cur: ?usize, line_count: usize, avail_rows: u16, floor: usize) ?usize {
    if (floor >= line_count) return null;
    const end = cur orelse line_count;
    return clampViewEnd(end -| scrollPage(avail_rows), line_count, floor);
}

/// PgDn: one page down; reaching (or crossing) the tail dissolves the
/// anchor back to tail-following rather than pinning at the last line.
fn scrollDownEnd(cur: ?usize, line_count: usize, avail_rows: u16, floor: usize) ?usize {
    const end = cur orelse return null;
    const new_end = end + scrollPage(avail_rows);
    if (new_end >= line_count) return null;
    return clampViewEnd(new_end, line_count, floor);
}

/// Lines one wheel notch moves. Three is the de-facto terminal default, and
/// deliberately not `scrollPage`: a notch is a nudge, and paging a whole
/// screen per notch makes a wheel unusable for reading.
const wheel_lines: usize = 3;

/// One wheel notch, up or down. Same contract as `scrollUpEnd` /
/// `scrollDownEnd` — null means "follow the tail" — so the wheel and the
/// paging keys leave `view_end` in states that are indistinguishable
/// afterwards, and a reader can mix the two freely.
fn scrollWheelEnd(cur: ?usize, line_count: usize, floor: usize, up: bool) ?usize {
    if (floor >= line_count) return null;
    const end = cur orelse line_count;
    if (up) return clampViewEnd(end -| wheel_lines, line_count, floor);
    const new_end = end + wheel_lines;
    // Reaching the tail dissolves the anchor rather than pinning just short
    // of it, so scrolling down to the bottom resumes following new output.
    if (new_end >= line_count) return null;
    return clampViewEnd(new_end, line_count, floor);
}

test "scrollWheelEnd nudges by a few lines and shares the paging contract" {
    // Short transcript: nothing to scroll, in either direction.
    try std.testing.expectEqual(@as(?usize, null), scrollWheelEnd(null, 10, 24, true));
    try std.testing.expectEqual(@as(?usize, null), scrollWheelEnd(null, 24, 24, true));

    // From the tail, one notch up moves three lines, not a page.
    try std.testing.expectEqual(@as(?usize, 97), scrollWheelEnd(null, 100, 24, true));
    // And keeps going, three at a time.
    try std.testing.expectEqual(@as(?usize, 94), scrollWheelEnd(97, 100, 24, true));

    // Down returns toward the tail and dissolves the anchor on arrival, so
    // the transcript resumes following new output.
    try std.testing.expectEqual(@as(?usize, 97), scrollWheelEnd(94, 100, 24, false));
    try std.testing.expectEqual(@as(?usize, null), scrollWheelEnd(98, 100, 24, false));
    // Already at the tail: down is a no-op, same as PgDn.
    try std.testing.expectEqual(@as(?usize, null), scrollWheelEnd(null, 100, 24, false));

    // Scrolling up clamps so the window still fills from line 0.
    var end: ?usize = null;
    for (0..100) |_| end = scrollWheelEnd(end, 100, 24, true);
    try std.testing.expectEqual(@as(?usize, 24), end);
}

/// Home: jump to the very top (the `topWindowEnd` floor, whose window
/// reaches line 0); null when there is no history above the first screen.
fn scrollHomeEnd(line_count: usize, floor: usize) ?usize {
    if (floor >= line_count) return null;
    return floor;
}

test "scrollPage is a screenful minus one line of overlap, never zero" {
    try std.testing.expectEqual(@as(usize, 23), scrollPage(24));
    try std.testing.expectEqual(@as(usize, 1), scrollPage(2));
    try std.testing.expectEqual(@as(usize, 1), scrollPage(1));
    try std.testing.expectEqual(@as(usize, 1), scrollPage(0));
}

test "scrollUpEnd pages up and clamps at the top" {
    // 100 one-row lines, 24 visible (floor 24): the first PgUp anchors a
    // page above the tail.
    try std.testing.expectEqual(@as(?usize, 77), scrollUpEnd(null, 100, 24, 24));
    // Walking further up clamps at the floor, whose window reaches line 0.
    var end: ?usize = null;
    for (0..10) |_| end = scrollUpEnd(end, 100, 24, 24);
    try std.testing.expectEqual(@as(?usize, 24), end);
    // Nothing above the first screen: stays following the tail.
    try std.testing.expectEqual(@as(?usize, null), scrollUpEnd(null, 10, 24, 10));
    try std.testing.expectEqual(@as(?usize, null), scrollUpEnd(null, 24, 24, 24));
}

test "scrollDownEnd pages down and dissolves at the tail" {
    try std.testing.expectEqual(@as(?usize, 47), scrollDownEnd(24, 100, 24, 24));
    // A page that reaches past the last line returns to tail-following.
    try std.testing.expectEqual(@as(?usize, null), scrollDownEnd(90, 100, 24, 24));
    // Already at the tail (null anchor): PgDn stays there.
    try std.testing.expectEqual(@as(?usize, null), scrollDownEnd(null, 100, 24, 24));
}

test "scrollHomeEnd jumps to the top only when there is history above" {
    try std.testing.expectEqual(@as(?usize, 24), scrollHomeEnd(100, 24));
    try std.testing.expectEqual(@as(?usize, null), scrollHomeEnd(24, 24));
    try std.testing.expectEqual(@as(?usize, null), scrollHomeEnd(3, 24));
}

test "an anchored view end holds its lines while the transcript grows" {
    // Frozen view: the anchor is an absolute index, so appended lines (a
    // growing line_count) leave the visible window exactly where it was;
    // the stick-to-tail behaviour lives entirely in the null anchor.
    try std.testing.expectEqual(@as(usize, 50), clampViewEnd(50, 200, 24));
    try std.testing.expectEqual(@as(usize, 50), clampViewEnd(50, 500, 24));
    // A shrunk transcript (or one shorter than the anchor) re-clamps it in.
    try std.testing.expectEqual(@as(usize, 40), clampViewEnd(50, 40, 24));
    // And a taller terminal pulls a too-high anchor down to a full window.
    try std.testing.expectEqual(@as(usize, 30), clampViewEnd(10, 200, 30));
}

test "lineRows counts wrapped rows and honours embedded newlines" {
    try std.testing.expectEqual(@as(usize, 1), lineRows("", 80));
    try std.testing.expectEqual(@as(usize, 1), lineRows("short", 80));
    try std.testing.expectEqual(@as(usize, 2), lineRows("0123456789", 5)); // 10 cols / 5
    try std.testing.expectEqual(@as(usize, 3), lineRows("aa\nbb\ncc", 80)); // two newlines
    try std.testing.expectEqual(@as(usize, 1), lineRows("anything", 0)); // zero width is one row
}

test "inline markdown splits into styled segments and leaves plain text whole" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const theme = theme_mod.Theme.mocha; // a 24-bit theme, so styles carry colour

    // Bold, italic, and inline code each become their own segment, with the
    // markers stripped and the surrounding text kept as plain segments.
    var segs: std.ArrayList(vaxis.Segment) = .empty;
    try mdLineSegments(&theme, arena, "a **b** c `d` e", &segs);
    var joined: std.ArrayList(u8) = .empty;
    var bold_seen = false;
    var code_seen = false;
    for (segs.items) |s| {
        try joined.appendSlice(arena, s.text);
        if (std.mem.eql(u8, s.text, "b")) bold_seen = s.style.bold;
        if (std.mem.eql(u8, s.text, "d")) code_seen = s.style.fg != .default;
    }
    try std.testing.expectEqualStrings("a b c d e", joined.items); // markers gone
    try std.testing.expect(bold_seen);
    try std.testing.expect(code_seen);

    // A heading collapses to one bold segment with the # marker stripped.
    var head: std.ArrayList(vaxis.Segment) = .empty;
    try mdLineSegments(&theme, arena, "## Title", &head);
    try std.testing.expectEqual(@as(usize, 1), head.items.len);
    try std.testing.expectEqualStrings("Title", head.items[0].text);
    try std.testing.expect(head.items[0].style.bold);

    // A bullet emits a marker segment then the inline body.
    var bul: std.ArrayList(vaxis.Segment) = .empty;
    try mdLineSegments(&theme, arena, "- item", &bul);
    try std.testing.expectEqualStrings("\xe2\x80\xa2 ", bul.items[0].text);

    // Plain prose with an unmatched marker stays literal, one plain segment.
    var plain: std.ArrayList(vaxis.Segment) = .empty;
    try mdLineSegments(&theme, arena, "just text with a * star", &plain);
    try std.testing.expectEqual(@as(usize, 1), plain.items.len);
    try std.testing.expectEqualStrings("just text with a * star", plain.items[0].text);

    // Block quote renders a left rule segment then inline body
    var quote: std.ArrayList(vaxis.Segment) = .empty;
    try mdLineSegments(&theme, arena, "> quoted **bold**", &quote);
    try std.testing.expect(quote.items.len >= 2);
    try std.testing.expectEqualStrings("▎ ", quote.items[0].text);
    var qbold = false;
    for (quote.items) |s| {
        if (std.mem.eql(u8, s.text, "bold")) qbold = s.style.bold;
    }
    try std.testing.expect(qbold);

    // Nested quote depth 2 renders two rules
    var q2: std.ArrayList(vaxis.Segment) = .empty;
    try mdLineSegments(&theme, arena, ">> deep", &q2);
    try std.testing.expectEqualStrings("▎ ", q2.items[0].text);
    try std.testing.expectEqualStrings("▎ ", q2.items[1].text);

    // Table row splits into cells with separator
    var tbl: std.ArrayList(vaxis.Segment) = .empty;
    try mdLineSegments(&theme, arena, "| a | b |", &tbl);
    var has_sep = false;
    for (tbl.items) |s| {
        if (std.mem.eql(u8, s.text, " │ ")) has_sep = true;
    }
    try std.testing.expect(has_sep);

    // Ordered list renders marker then body
    var ol: std.ArrayList(vaxis.Segment) = .empty;
    try mdLineSegments(&theme, arena, "1. first", &ol);
    try std.testing.expectEqualStrings("1. ", ol.items[0].text);

    // Nested bullet indents and uses bullet marker
    var nest: std.ArrayList(vaxis.Segment) = .empty;
    try mdLineSegments(&theme, arena, "  - nested", &nest);
    try std.testing.expectEqualStrings("• ", nest.items[1].text);
}

test "a collapsed fold reserves exactly the rows the draw loop will use" {
    // The bug this pins: `tailWindow` measured a fold in wrapped *rows* while
    // the draw loop rendered whole *lines*, so the transcript was bottom-
    // aligned for a height it never drew and the tail fell off the bottom.
    // Both sides now count through `foldShownLines`.
    const lines = [_]Line{
        .{ .text = "clanker> ask" },
        .{ .text = "a1" },
        .{ .text = "a2" },
        .{ .text = "a3" },
        .{ .text = "a4" },
        .{ .text = "receipt" },
    };
    const collapsed = [_]Fold{.{ .start = 1, .count = 4, .expanded = false, .anim = 0 }};

    // Collapsed: prompt + header + receipt == 3 rows, and no body lines shown.
    try std.testing.expectEqual(@as(usize, 0), foldShownLines(collapsed[0]));
    const win = tailWindow(&lines, &collapsed, lines.len, 20, 80);
    try std.testing.expectEqual(@as(usize, 0), win.start);
    try std.testing.expectEqual(@as(u16, 3), win.used_rows);

    // Fully open: every line is drawn, so the reservation is the full height
    // (prompt + header + 4 body + receipt).
    const open = [_]Fold{.{ .start = 1, .count = 4, .expanded = true, .anim = 1 }};
    try std.testing.expectEqual(@as(usize, 4), foldShownLines(open[0]));
    const win_open = tailWindow(&lines, &open, lines.len, 20, 80);
    try std.testing.expectEqual(@as(u16, 7), win_open.used_rows);
}

test "a fold reveals whole lines as it animates, never a fraction" {
    const f = Fold{ .start = 0, .count = 10, .expanded = true, .anim = 0.5 };
    const shown = foldShownLines(f);
    // Mid-animation reveals some but not all, and always a whole number of
    // lines: the draw loop can only stop between lines.
    try std.testing.expect(shown > 0 and shown < f.count);
    // The ends are exact, so a fold round-trips to precisely open or closed
    // rather than drifting a line each time it is toggled.
    try std.testing.expectEqual(@as(usize, 0), foldShownLines(.{ .start = 0, .count = 10, .expanded = false, .anim = 0 }));
    try std.testing.expectEqual(@as(usize, 10), foldShownLines(.{ .start = 0, .count = 10, .expanded = true, .anim = 1 }));
}

test "tailWindow bottom-aligns a short transcript and fills a tall one" {
    const lines = [_]Line{
        .{ .text = "one" },  .{ .text = "two" },  .{ .text = "three" },
        .{ .text = "four" }, .{ .text = "five" },
    };
    // All five fit in ten rows: start at 0, used == the five short lines.
    const short = tailWindow(&lines, &[_]Fold{}, lines.len, 10, 80);
    try std.testing.expectEqual(@as(usize, 0), short.start);
    try std.testing.expectEqual(@as(u16, 5), short.used_rows);
    // Only three rows available: the window drops the two oldest lines and
    // fills, so the newest line is never clipped.
    const tall = tailWindow(&lines, &[_]Fold{}, lines.len, 3, 80);
    try std.testing.expectEqual(@as(usize, 2), tall.start);
    try std.testing.expectEqual(@as(u16, 3), tall.used_rows);
}

test "tailWindow counts wrapped rows, which the old line-count guess did not" {
    // Three entries, each three rows wide at width 10. A guess of one row per
    // entry would say all three fit in four rows; they need nine.
    const lines = [_]Line{
        .{ .text = "aaaaaaaaaaaaaaaaaaaaaaaaa" }, // 25 cols -> 3 rows at 10
        .{ .text = "bbbbbbbbbbbbbbbbbbbbbbbbb" },
        .{ .text = "ccccccccccccccccccccccccc" },
    };

    // Four rows available: only the newest entry fits, and it is not clipped.
    const win = tailWindow(&lines, &[_]Fold{}, lines.len, 4, 10);
    try std.testing.expectEqual(@as(usize, 2), win.start);
    try std.testing.expectEqual(@as(u16, 3), win.used_rows);
    // The plain line-count heuristic this replaced would have started at 0
    // here (3 entries <= 4 rows), asking the draw to fit nine rows of text
    // into four and clipping the newest content off the bottom.
    try std.testing.expect(win.start != 0);

    // Ten rows: everything fits, and used_rows is the wrapped total, not the
    // entry count, so the bottom-alignment offset is right.
    const all = tailWindow(&lines, &[_]Fold{}, lines.len, 10, 10);
    try std.testing.expectEqual(@as(usize, 0), all.start);
    try std.testing.expectEqual(@as(u16, 9), all.used_rows);
    try std.testing.expect(all.used_rows != lines.len);

    // An anchored (scrolled-back) window is the same computation with a
    // smaller end, which is what lets the frozen-scroll case share this path
    // instead of guessing: end at 2, four rows, so only entry 1 is shown.
    const anchored = tailWindow(lines[0..2], &[_]Fold{}, 2, 4, 10);
    try std.testing.expectEqual(@as(usize, 1), anchored.start);
    try std.testing.expectEqual(@as(u16, 3), anchored.used_rows);
}

test "tailWindow clamps a fold that straddles the anchored view_end" {
    // Regression: scrolled back so `view_end` falls inside an open fold
    // (start < view_end < start+count). The fold branch used to slice
    // `lines[f.start .. f.start + shown]`, but `lines` is `items[0..view_end]`,
    // so a fold reaching past the anchor read out of bounds and panicked
    // ("index 102, len 100").
    const lines = [_]Line{
        .{ .text = "clanker> ask" },
        .{ .text = "a1" },
        .{ .text = "a2" },
        .{ .text = "a3" },
        .{ .text = "a4" },
        .{ .text = "receipt" },
    };
    // Fold covers lines 1..5; anchor at 3 leaves body lines a1..a3 visible
    // (a3 is past the anchor and must not be counted).
    const open = [_]Fold{.{ .start = 1, .count = 4, .expanded = true, .anim = 1 }};
    // avail_rows of 3 stops the walk right at the fold start, so the result
    // isolates the clamp: header + a1 + a2 (a3 is past the anchor, uncounted).
    const win = tailWindow(lines[0..3], &open, 3, 3, 80);
    try std.testing.expectEqual(@as(usize, 1), win.start);
    try std.testing.expectEqual(@as(u16, 3), win.used_rows);

    // Collapsed folds straddle the anchor too: just the header, no body.
    const collapsed = [_]Fold{.{ .start = 1, .count = 4, .expanded = false, .anim = 0 }};
    const win_c = tailWindow(lines[0..3], &collapsed, 3, 1, 80);
    try std.testing.expectEqual(@as(usize, 1), win_c.start);
    try std.testing.expectEqual(@as(u16, 1), win_c.used_rows);
}

test "an expanded fold does not disable scrolling on a tall terminal" {
    // Regression: every scroll guard compared the transcript's *line*
    // count against the screen's *row* count. An expanded fold draws one
    // header row on top of its lines, and wrapped lines draw several, so
    // a transcript can overflow the screen in rows while staying under it
    // in lines — the guards then answered "everything fits" and refused
    // to scroll at all, which is how an expanded reply froze the view.
    //
    // 13 lines on a 13-row screen, but the open fold's header makes it
    // 14 drawn rows: scrolling must be possible.
    const lines = [_]Line{
        .{ .text = "clanker> ask" },
        .{ .text = "note" },
        .{ .text = "L1" },
        .{ .text = "L2" },
        .{ .text = "L3" },
        .{ .text = "L4" },
        .{ .text = "L5" },
        .{ .text = "L6" },
        .{ .text = "L7" },
        .{ .text = "L8" },
        .{ .text = "L9" },
        .{ .text = "L10" },
        .{ .text = "receipt" },
    };
    const open = [_]Fold{.{ .start = 2, .count = 10, .expanded = true, .anim = 1 }};
    const floor = topWindowEnd(&lines, &open, 13, 80);
    // The largest anchor whose window still reaches line 0: 12 of the 13
    // lines fit beside the header row.
    try std.testing.expectEqual(@as(usize, 12), floor);
    // One wheel notch up from the tail moves — it must not return null.
    try std.testing.expect(scrollWheelEnd(null, lines.len, floor, true) != null);
    // And the floor anchor's window reaches the very first line.
    const win = tailWindow(lines[0..floor], &open, floor, 13, 80);
    try std.testing.expectEqual(@as(usize, 0), win.start);

    // Wholly fits (14 rows on a 14-row screen): floor is the line count
    // and scrolling stays disabled.
    try std.testing.expectEqual(@as(usize, 13), topWindowEnd(&lines, &open, 14, 80));
    try std.testing.expectEqual(@as(?usize, null), scrollWheelEnd(null, lines.len, 13, true));
}

test "topWindowEnd is wrap- and fold-aware" {
    // Plain one-row lines: same answer the old line-unit floor gave.
    const plain = [_]Line{
        .{ .text = "a" },
        .{ .text = "b" },
        .{ .text = "c" },
        .{ .text = "d" },
    };
    try std.testing.expectEqual(@as(usize, 2), topWindowEnd(&plain, &[_]Fold{}, 2, 80));
    try std.testing.expectEqual(@as(usize, 4), topWindowEnd(&plain, &[_]Fold{}, 9, 80));

    // A wrapped line counts its rows: 25 cells at width 10 is 3 rows, so
    // only it and one more line fit in 4 rows.
    const wrapped = [_]Line{
        .{ .text = "aaaaaaaaaaaaaaaaaaaaaaaaa" },
        .{ .text = "b" },
        .{ .text = "c" },
        .{ .text = "d" },
    };
    try std.testing.expectEqual(@as(usize, 2), topWindowEnd(&wrapped, &[_]Fold{}, 4, 10));

    // A collapsed fold is one header row and is jumped as a block: the
    // floor never lands inside it.
    const with_fold = [_]Line{
        .{ .text = "a" },
        .{ .text = "f1" },
        .{ .text = "f2" },
        .{ .text = "f3" },
        .{ .text = "b" },
    };
    const collapsed = [_]Fold{.{ .start = 1, .count = 3, .expanded = false, .anim = 0 }};
    // 3 rows: line a + header + line b — the whole list fits.
    try std.testing.expectEqual(@as(usize, 5), topWindowEnd(&with_fold, &collapsed, 3, 80));
    // 2 rows: line a + header fit; b does not. Floor is the block end.
    try std.testing.expectEqual(@as(usize, 4), topWindowEnd(&with_fold, &collapsed, 2, 80));
    // 1 row: the block does not fit; floor stops at its start but is
    // never less than one line.
    try std.testing.expectEqual(@as(usize, 1), topWindowEnd(&with_fold, &collapsed, 1, 80));
}

test "tailWindow scrolls line-by-line through a fully expanded fold" {
    // Regression: the atomic-block jump is right for a collapsed or
    // animating fold, where drawn rows differ from line rows — but a fully
    // open fold renders per-line (the draw loop falls through to rich
    // rendering), and treating it as a block pinned the window at the
    // header for every anchor inside the fold. Wheel and PgDn then
    // repeated the identical frame until the anchor passed the whole
    // reply, and the view jumped past it in one step.
    const lines = [_]Line{
        .{ .text = "clanker> ask" },
        .{ .text = "L1" },
        .{ .text = "L2" },
        .{ .text = "L3" },
        .{ .text = "L4" },
        .{ .text = "L5" },
        .{ .text = "L6" },
        .{ .text = "L7" },
        .{ .text = "L8" },
        .{ .text = "L9" },
        .{ .text = "L10" },
        .{ .text = "receipt" },
    };
    const open = [_]Fold{.{ .start = 1, .count = 10, .expanded = true, .anim = 1 }};
    // Anchor mid-fold with a 4-row window: the window ends at the anchor
    // (start = view_end - rows), it does not snap back to the fold header.
    const win = tailWindow(lines[0..8], &open, 8, 4, 80);
    try std.testing.expectEqual(@as(usize, 4), win.start);
    try std.testing.expectEqual(@as(u16, 4), win.used_rows);
    // The header still costs its row when the window reaches the fold's
    // first line: anchor at 3 fits header + L1 + L2 plus the ask line.
    const at_start = tailWindow(lines[0..3], &open, 3, 4, 80);
    try std.testing.expectEqual(@as(usize, 0), at_start.start);
    try std.testing.expectEqual(@as(u16, 4), at_start.used_rows);
}

test "a reply that folds drops its turn arrow: the header is the turn marker" {
    // Regression: appendAnswerLines arrows the first line of every reply,
    // and folding the same range kept it, so an expanded fold showed the
    // `▾ reply` header and a `› ` first body line — two turn markers, the
    // second reading as a stray prompt glyph.
    var lines = [_]Line{
        .{ .text = turn_arrow ++ "Line 1" },
        .{ .text = "Line 2" },
        .{ .text = "Line 3" },
        .{ .text = "Line 4" },
        .{ .text = "Line 5" },
        .{ .text = "Line 6" },
        .{ .text = "Line 7" },
        .{ .text = "Line 8" },
        .{ .text = "Line 9" },
        .{ .text = "Line 10" },
    };
    const fold = foldForReply(&lines, 0, 80) orelse return error.TestExpectedFold;
    try std.testing.expectEqual(@as(usize, 0), fold.start);
    try std.testing.expectEqual(@as(usize, 10), fold.count);
    try std.testing.expectEqualStrings("Line 1", lines[0].text);

    // A short reply never folds, so the arrow stays: it is then the only
    // turn marker the reply has.
    var short = [_]Line{.{ .text = turn_arrow ++ "hi" }};
    try std.testing.expect(foldForReply(&short, 0, 80) == null);
    try std.testing.expectEqualStrings(turn_arrow ++ "hi", short[0].text);
}

fn writeRow(surface: vxfw.Surface, row: u16, text: []const u8, style: vaxis.Style) void {
    var col: u16 = 0;
    writeRowAt(surface, row, &col, text, style);
}

/// A vertical scrollbar in column `col`, rows [top, bottom): a dim track with
/// a brighter thumb whose position and length track the visible window
/// (`start`..`view_end`) against the whole transcript (`line_count`). Drawn
/// only when the transcript overflows, so an idle short session shows none.
fn drawScrollbar(surface: vxfw.Surface, col: u16, top: u16, bottom: u16, start: usize, view_end: usize, line_count: usize, track: vaxis.Style, thumb: vaxis.Style) void {
    if (bottom <= top or line_count == 0) return;
    const track_h: usize = bottom - top;
    // Thumb size and offset in track rows, proportional to the fraction of the
    // transcript on screen. `min 1` keeps the thumb visible in a huge scroll.
    const visible = view_end - start;
    var thumb_h: usize = (visible * track_h + line_count - 1) / line_count;
    if (thumb_h < 1) thumb_h = 1;
    if (thumb_h > track_h) thumb_h = track_h;
    var thumb_top: usize = (start * track_h) / line_count;
    if (thumb_top + thumb_h > track_h) thumb_top = track_h - thumb_h;
    var r: u16 = top;
    while (r < bottom) : (r += 1) {
        const in_thumb = (r - top) >= thumb_top and (r - top) < thumb_top + thumb_h;
        const glyph = if (in_thumb) "\xe2\x96\x88" else "\xe2\x94\x82"; // full block / light vertical
        surface.writeCell(col, r, .{ .char = .{ .grapheme = glyph, .width = 1 }, .style = if (in_thumb) thumb else track });
    }
}

/// One screen cell's worth of text: a base codepoint plus any zero-width
/// codepoints that follow it, and the columns it occupies.
const Cell = struct { bytes: []const u8, width: u16 };

/// Walks `text` one cell at a time from `i`, which is advanced past the cell.
///
/// Two things the plain codepoint loop this replaces got wrong. A CJK
/// ideograph is two columns, not one, so writing it as `.width = 1` told
/// vaxis the terminal's cursor had advanced one column when it had advanced
/// two; vaxis's frame diff then addressed every later cell on the row one
/// column off, which is visible as smeared or duplicated text rather than a
/// tidy misalignment. And a combining mark is zero columns, so emitting it as
/// its own cell pushed the rest of the line right and left the accent
/// floating over a space instead of over its base letter.
///
/// Both are fixed by measuring with `width_mod` (the same table `lineRows`
/// already reserves rows with, so layout and render finally agree) and by
/// absorbing trailing zero-width codepoints into the preceding cell. The
/// absorbed slice is contiguous in `text`, so this stays allocation-free and
/// borrows the caller's buffer, which is what `writeWrapped` and friends need.
///
/// A stray leading mark with no base gets a cell of its own rather than being
/// dropped: losing bytes is worse than one odd-looking column.
fn nextCell(text: []const u8, i: *usize) ?Cell {
    if (i.* >= text.len) return null;
    const start = i.*;
    var it: std.unicode.Utf8Iterator = .{ .bytes = text, .i = i.* };
    const base = it.nextCodepointSlice() orelse return null;
    i.* = it.i;
    var w: u16 = @intCast(width_mod.displayWidth(base));
    if (w == 0) w = 1;
    while (i.* < text.len) {
        var peek: std.unicode.Utf8Iterator = .{ .bytes = text, .i = i.* };
        const next = peek.nextCodepointSlice() orelse break;
        if (width_mod.displayWidth(next) != 0) break;
        // Control bytes are zero-width too, but absorbing one hides it inside
        // the previous cell: a '\n' riding along as "4\n" slips past
        // writeWrapped's newline check and reaches the terminal raw, walking
        // the cursor off the row (the multi-line task echo staircase).
        if (next.len == 1 and (next[0] < 0x20 or next[0] == 0x7F)) break;
        i.* = peek.i;
    }
    return .{ .bytes = text[start..i.*], .width = w };
}

test "nextCell never absorbs a control byte into the preceding cell" {
    // '\n' is zero-width; absorbed into "a"'s cell it would reach the
    // terminal raw and walk the cursor off the row.
    var i: usize = 0;
    const first = nextCell("a\nb", &i).?;
    try std.testing.expectEqualStrings("a", first.bytes);
    const second = nextCell("a\nb", &i).?;
    try std.testing.expectEqualStrings("\n", second.bytes);
    const third = nextCell("a\nb", &i).?;
    try std.testing.expectEqualStrings("b", third.bytes);
}

test "nextCell measures wide codepoints and keeps combining marks with their base" {
    var i: usize = 0;
    // ASCII: one cell, one column.
    const ascii = nextCell("ab", &i).?;
    try std.testing.expectEqualStrings("a", ascii.bytes);
    try std.testing.expectEqual(@as(u16, 1), ascii.width);
    try std.testing.expectEqual(@as(usize, 1), i);

    // CJK: one cell, two columns. This is the case that desynced vaxis.
    i = 0;
    const cjk = nextCell("\xe4\xb8\xad", &i).?; // 中
    try std.testing.expectEqual(@as(u16, 2), cjk.width);
    try std.testing.expectEqualStrings("\xe4\xb8\xad", cjk.bytes);
    try std.testing.expectEqual(@as(usize, 3), i);

    // "e" + U+0301 combining acute is one cell of one column, carrying both
    // codepoints, so the accent lands on the letter and nothing shifts right.
    i = 0;
    const accented = nextCell("e\xcc\x81x", &i).?;
    try std.testing.expectEqual(@as(u16, 1), accented.width);
    try std.testing.expectEqualStrings("e\xcc\x81", accented.bytes);
    // ...and the walk resumes at the next base letter.
    const after = nextCell("e\xcc\x81x", &i).?;
    try std.testing.expectEqualStrings("x", after.bytes);

    // A mark with no base still gets a cell rather than vanishing.
    i = 0;
    const orphan = nextCell("\xcc\x81", &i).?;
    try std.testing.expectEqual(@as(u16, 1), orphan.width);

    // Walking to the end terminates.
    i = 0;
    var seen: usize = 0;
    while (nextCell("a\xe4\xb8\xadb", &i)) |_| seen += 1;
    try std.testing.expectEqual(@as(usize, 3), seen);
    try std.testing.expectEqual(@as(?Cell, null), nextCell("abc", &i));
}

test "a row of CJK occupies the columns lineRows reserved for it" {
    // The invariant the old renderer broke: what nextCell reports summed over
    // a line must equal what lineRows measured when reserving space for it.
    const line = "\xe4\xb8\xad\xe6\x96\x87 mixed \xe4\xb8\xad"; // 中文 mixed 中
    var i: usize = 0;
    var cols: usize = 0;
    while (nextCell(line, &i)) |c| cols += c.width;
    try std.testing.expectEqual(width_mod.displayWidth(line), cols);
    // 3 CJK glyphs at 2 columns each, plus " mixed " at 7.
    try std.testing.expectEqual(@as(usize, 13), cols);
    // Wide enough for the whole line: one row. Narrower: it wraps, and the
    // wrap point is the same one the renderer will use.
    try std.testing.expectEqual(@as(usize, 1), lineRows(line, 20));
    try std.testing.expectEqual(@as(usize, 2), lineRows(line, 10));
}

fn writeRowAt(surface: vxfw.Surface, row: u16, col: *u16, text: []const u8, style: vaxis.Style) void {
    var i: usize = 0;
    while (nextCell(text, &i)) |c| {
        // A wide glyph needs both its columns inside the surface; half of one
        // in the last column would be written as a truncated cell.
        if (col.* + c.width > surface.size.width) break;
        surface.writeCell(col.*, row, .{ .char = .{ .grapheme = c.bytes, .width = @intCast(c.width) }, .style = style });
        col.* += c.width;
    }
}

/// A `/theme` palette swatch: twelve single-cell blocks, one per role in the
/// theme's `Rgb` (fenced-code token colours first, then the chrome roles), so
/// a full palette is visible before it is applied. Writes nothing and returns
/// false when the theme has no RGB palette (`default`/`mono`), which keeps
/// those rows aligned with the palette rows; a narrow terminal clips the tail
/// blocks rather than wrapping.
fn writeThemePalette(surface: vxfw.Surface, row: u16, col: *u16, name: []const u8) bool {
    const rgb = theme_mod.palette(name) orelse return false;
    const colors = [_]theme_mod.Rgb24{
        rgb.keyword,
        rgb.string,
        rgb.number,
        rgb.builtin,
        rgb.preproc,
        rgb.comment,
        rgb.dim,
        rgb.tool,
        rgb.err,
        rgb.rule,
        rgb.prompt,
        rgb.accent,
    };
    inline for (colors) |c| {
        if (col.* + 1 > surface.size.width) return true;
        surface.writeCell(col.*, row, .{ .char = .{ .grapheme = "\xe2\x96\x88", .width = 1 }, .style = .{ .fg = .{ .rgb = c } } });
        col.* += 1;
    }
    return true;
}

fn statusTextFits(width: u16, col: u16, text: []const u8) bool {
    return width_mod.displayWidth(text) <= @as(usize, width -| col);
}

/// Add one optional status field atomically. A clipped context count or model
/// id is worse than omission because its visible fragment still looks valid.
fn writeStatusPairIfFits(surface: vxfw.Surface, col: *u16, prefix: []const u8, prefix_style: vaxis.Style, text: []const u8, text_style: vaxis.Style) bool {
    if (!statusTextFits(surface.size.width, col.*, prefix) or
        width_mod.displayWidth(prefix) + width_mod.displayWidth(text) > @as(usize, surface.size.width -| col.*)) return false;
    writeRowAt(surface, 0, col, prefix, prefix_style);
    writeRowAt(surface, 0, col, text, text_style);
    return true;
}

test "status fields fit atomically at constrained widths" {
    try std.testing.expect(statusTextFits(20, 5, " · clanker"));
    try std.testing.expect(!statusTextFits(12, 5, " · clanker"));
    try std.testing.expect(statusTextFits(12, 0, "ready"));
    // Display columns, not bytes: the spinner occupies one cell.
    try std.testing.expect(statusTextFits(2, 0, "⠋ "));
    try std.testing.expect(!statusTextFits(1, 0, "⠋ "));
}

/// The styles inline markdown renders with, resolved once from the active
/// theme. A 24-bit theme names exact colours; a 16-colour theme falls back to
/// the nearest index; `mono` stays attributes-only (bold/italic still read).
const MdStyles = struct {
    bold: vaxis.Style,
    italic: vaxis.Style,
    code: vaxis.Style,
    heading: vaxis.Style,
    bullet: vaxis.Style,
    quote: vaxis.Style,
    plain: vaxis.Style,
};

fn mdStyles(active: *const theme_mod.Theme) MdStyles {
    if (active.rgb) |c| return .{
        .bold = .{ .bold = true },
        .italic = .{ .italic = true },
        .code = .{ .fg = .{ .rgb = c.builtin } },
        .heading = .{ .bold = true, .fg = .{ .rgb = c.accent } },
        .bullet = .{ .fg = .{ .rgb = c.accent } },
        .quote = .{ .fg = .{ .rgb = c.accent }, .dim = true },
        .plain = .{},
    };
    const on = active.reset.len > 0;
    return .{
        .bold = .{ .bold = true },
        .italic = .{ .italic = true },
        .code = if (on) .{ .fg = .{ .index = 6 } } else .{},
        .heading = .{ .bold = true },
        .bullet = if (on) .{ .fg = .{ .index = 2 } } else .{},
        .quote = .{ .dim = true },
        .plain = .{},
    };
}

/// Parses one line's inline markdown (`**bold**`, `*italic*`/`_italic_`,
/// `` `code` ``) into styled segments. Text slices point into `text` (the
/// caller's arena-owned line), so they stay valid until the frame flushes.
/// An unmatched marker is left literal.
fn appendInline(arena: std.mem.Allocator, text: []const u8, st: MdStyles, out: *std.ArrayList(vaxis.Segment)) !void {
    var i: usize = 0;
    var seg_start: usize = 0;
    const flush = struct {
        fn f(a: std.mem.Allocator, o: *std.ArrayList(vaxis.Segment), s: []const u8, style: vaxis.Style) !void {
            if (s.len > 0) try o.append(a, .{ .text = s, .style = style });
        }
    }.f;
    while (i < text.len) {
        const c = text[i];
        if (c == '`') {
            if (std.mem.findScalarPos(u8, text, i + 1, '`')) |end| {
                try flush(arena, out, text[seg_start..i], st.plain);
                try out.append(arena, .{ .text = text[i + 1 .. end], .style = st.code });
                i = end + 1;
                seg_start = i;
                continue;
            }
        } else if (c == '*' and i + 1 < text.len and text[i + 1] == '*') {
            if (std.mem.findPos(u8, text, i + 2, "**")) |end| {
                if (end > i + 2) {
                    try flush(arena, out, text[seg_start..i], st.plain);
                    try out.append(arena, .{ .text = text[i + 2 .. end], .style = st.bold });
                    i = end + 2;
                    seg_start = i;
                    continue;
                }
            }
        } else if (c == '*' or c == '_') {
            if (std.mem.findScalarPos(u8, text, i + 1, c)) |end| {
                if (end > i + 1) {
                    try flush(arena, out, text[seg_start..i], st.plain);
                    try out.append(arena, .{ .text = text[i + 1 .. end], .style = st.italic });
                    i = end + 1;
                    seg_start = i;
                    continue;
                }
            }
        }
        i += 1;
    }
    try flush(arena, out, text[seg_start..], st.plain);
}

fn quoteDepthAndRest(line: []const u8) struct { depth: usize, rest: []const u8 } {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    var depth: usize = 0;
    while (i < line.len and line[i] == '>') {
        depth += 1;
        i += 1;
        if (i < line.len and line[i] == ' ') i += 1;
    }
    if (depth == 0) return .{ .depth = 0, .rest = line };
    return .{ .depth = depth, .rest = line[i..] };
}

fn isTableRow(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len < 2) return false;
    if (t[0] != '|' or t[t.len - 1] != '|') return false;
    return std.mem.findScalar(u8, t[1 .. t.len - 1], '|') != null or std.mem.count(u8, t, "|") >= 2;
}

fn orderedMarkerLen(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and s[n] >= '0' and s[n] <= '9') n += 1;
    if (n == 0 or n > 4) return 0;
    if (n + 1 >= s.len) return 0;
    if (s[n] != '.' and s[n] != ')') return 0;
    if (s[n + 1] != ' ') return 0;
    return n + 2;
}

/// Renders one transcript line as inline markdown segments: a `# heading`
/// becomes bold-accent, a `-`/`*`/`+` bullet gets an accent dot then inline
/// body, `> quote` gets a left rule, `| a | b |` renders as aligned table
/// cells (when part of a table block the caller should pre-detect), ordered
/// lists (`1. `) and nested bullets (indent depth) get nesting-aware markers.
/// Line-level only; the block callers detect multi-line constructs by
/// peeking at neighbours.
fn mdLineSegments(active: *const theme_mod.Theme, arena: std.mem.Allocator, text: []const u8, out: *std.ArrayList(vaxis.Segment)) !void {
    const st = mdStyles(active);
    // Block quote: `> ` / `>> ` with nesting → left rule per depth
    const q = quoteDepthAndRest(text);
    if (q.depth > 0) {
        for (0..q.depth) |_| try out.append(arena, .{ .text = "▎ ", .style = st.quote });
        try appendInline(arena, q.rest, st, out);
        return;
    }
    // Table row: render cells inline, header row in heading style when caller
    // flagged it; line-level fallback just joins cells with ` │ `.
    if (isTableRow(text)) {
        // Split on `|` and inline-parse each cell; header handled by `mdTableRow` when whole block is known.
        // Here keep the raw `|` separators with quote-dim style so a lone row still reads as a table.
        const trimmed = std.mem.trim(u8, text, " \t");
        var first = true;
        var it = std.mem.splitScalar(u8, trimmed, '|');
        while (it.next()) |cell| {
            const c = std.mem.trim(u8, cell, " \t");
            if (c.len == 0 and first) {
                first = false;
                continue;
            }
            if (c.len == 0 and it.peek() == null) break;
            if (!first) try out.append(arena, .{ .text = " │ ", .style = st.quote });
            first = false;
            if (isTableSeparator(c)) {
                try out.append(arena, .{ .text = "───", .style = st.quote });
            } else {
                try appendInline(arena, c, st, out);
            }
        }
        return;
    }
    var h: usize = 0;
    while (h < text.len and text[h] == '#') h += 1;
    if (h >= 1 and h <= 6 and h < text.len and text[h] == ' ') {
        try out.append(arena, .{ .text = std.mem.trimStart(u8, text[h..], " "), .style = st.heading });
        return;
    }
    var indent: usize = 0;
    while (indent < text.len and text[indent] == ' ') indent += 1;
    // Ordered list: `1. ` / `1) ` with nesting via indent
    const mlen = orderedMarkerLen(text[indent..]);
    if (mlen != 0) {
        if (indent > 0) try out.append(arena, .{ .text = text[0..indent], .style = st.plain });
        const level = indent / 2;
        for (0..level) |_| try out.append(arena, .{ .text = "  ", .style = st.plain });
        const marker = text[indent .. indent + mlen];
        try out.append(arena, .{ .text = marker, .style = st.bullet });
        try appendInline(arena, text[indent + mlen ..], st, out);
        return;
    }
    if (indent + 1 < text.len and (text[indent] == '-' or text[indent] == '*' or text[indent] == '+') and text[indent + 1] == ' ') {
        const level = indent / 2;
        if (level > 0) {
            for (0..level) |_| try out.append(arena, .{ .text = "  ", .style = st.plain });
        } else if (indent > 0) {
            try out.append(arena, .{ .text = text[0..indent], .style = st.plain });
        }
        try out.append(arena, .{ .text = "• ", .style = st.bullet });
        try appendInline(arena, text[indent + 2 ..], st, out);
        return;
    }
    try appendInline(arena, text, st, out);
}

fn isTableSeparator(cell: []const u8) bool {
    if (cell.len < 3) return false;
    for (cell) |ch| if (ch != '-' and ch != ':' and ch != ' ') return false;
    return std.mem.findScalar(u8, cell, '-') != null;
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

/// writeWrapped for a tool-card line: continuation rows re-open with the
/// card's left bar ("\u{2502}  ") so a long args preview wraps inside the
/// card instead of spilling flush-left and breaking the shape the card
/// builders drew. Terminals too narrow for bar + indent + a few glyphs fall
/// back to the plain wrap rather than filling every row with prefix.
fn writeWrappedCard(surface: vxfw.Surface, row: *u16, bottom: u16, width: u16, text: []const u8, style: vaxis.Style) void {
    if (width < 8) return writeWrapped(surface, row, bottom, width, text, style);
    var col: u16 = 0;
    var i: usize = 0;
    while (nextCell(text, &i)) |c| {
        if (row.* >= bottom) break;
        if (std.mem.eql(u8, c.bytes, "\n")) {
            // Card lines are single-line by construction (cardPreview
            // flattens newlines); handled anyway so a stray one degrades
            // like writeWrapped instead of overprinting.
            row.* += 1;
            col = 0;
            continue;
        }
        if (col + c.width > width) {
            row.* += 1;
            col = 0;
            if (row.* >= bottom) break;
            var pit = std.unicode.Utf8Iterator{ .bytes = "\u{2502}  ", .i = 0 };
            while (pit.nextCodepointSlice()) |pcp| {
                surface.writeCell(col, row.*, .{ .char = .{ .grapheme = pcp, .width = 1 }, .style = style });
                col += 1;
            }
        }
        surface.writeCell(col, row.*, .{ .char = .{ .grapheme = c.bytes, .width = @intCast(c.width) }, .style = style });
        col += c.width;
    }
}

/// Writes `text` wrapped at `width`, advancing `*row` a line at a time,
/// stopping at `bottom`. Simple hard-wrap (no word-break), good enough for
/// a live streaming tail and for completed turns (which must not be clipped
/// to a single row); MdStream-quality wrapping is follow-up work.
fn writeWrapped(surface: vxfw.Surface, row: *u16, bottom: u16, width: u16, text: []const u8, style: vaxis.Style) void {
    var col: u16 = 0;
    var i: usize = 0;
    while (nextCell(text, &i)) |c| {
        if (row.* >= bottom) break;
        if (std.mem.eql(u8, c.bytes, "\n")) {
            row.* += 1;
            col = 0;
            continue;
        }
        // `col + c.width > width`, not `col >= width`: a two-column glyph
        // that only half fits wraps whole rather than being written across
        // the boundary. This is the same wrap point `lineRows` counts with.
        if (col + c.width > width) {
            row.* += 1;
            col = 0;
            if (row.* >= bottom) break;
        }
        surface.writeCell(col, row.*, .{ .char = .{ .grapheme = c.bytes, .width = @intCast(c.width) }, .style = style });
        col += c.width;
    }
}

/// Blanks the interior rows of a box before anything is written into them.
///
/// `drawBox` draws a border and nothing else, so a modal opened over the
/// transcript inherited whatever text was already in those cells and showed
/// it through the gaps its own content did not cover — a search bar reading
/// `search workflow▏.  measurement loop (see /autoresear1/2 · Up/Down step`,
/// with two unrelated lines interleaved. The pickers have always had this
/// too. Interior only: the border is drawn separately, and the composer's
/// `TextField` is a child surface composited after this, so blanking the
/// cells underneath it is harmless.
fn clearBoxInterior(surface: vxfw.Surface, x: u16, y: u16, w: u16, h: u16) void {
    if (w <= 2 or h <= 2) return;
    var r: u16 = y + 1;
    while (r < y + h - 1 and r < surface.size.height) : (r += 1) {
        var c: u16 = x + 1;
        while (c < x + w - 1 and c < surface.size.width) : (c += 1) {
            surface.writeCell(c, r, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{} });
        }
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

/// True when a key event should trigger the Ctrl+Shift+C copy action.
/// Most terminals report the chord with the shift modifier set. Terminals
/// that lack kitty-keyboard support collapse it to the same 0x03 byte as
/// plain Ctrl+C and drop the shift bit; such a byte is only recovered as
/// copy when a mouse selection is live (the copy intent the user signalled)
/// and the REPL is not streaming (so a genuine Ctrl+C can still interrupt
/// the running turn). With no selection the collapsed byte is
/// indistinguishable from plain Ctrl+C and must reach that handler's quit.
fn isCopyChord(key: vaxis.Key, streaming: bool, has_selection: bool) bool {
    if (key.matches('c', .{ .ctrl = true, .shift = true })) return true;
    return !streaming and has_selection and key.matches('c', .{ .ctrl = true });
}

/// What Ctrl+C means inside a keyboard-owning modal (picker, search). The
/// ask modal has its own handler because it must also wake the parked run
/// thread; the other two must not swallow the interrupt: with a turn
/// streaming the chord closes the modal *and* stops the turn (a run must
/// stay stoppable no matter which modal holds the keyboard), idle it closes
/// the modal like Escape. Ctrl+Shift+C is the copy chord, not an interrupt,
/// and every other key belongs to the modal.
const ModalCtrlC = enum { none, close, close_and_stop };

fn modalCtrlCAction(key: vaxis.Key, streaming: bool) ModalCtrlC {
    if (!key.matches('c', .{ .ctrl = true })) return .none;
    return if (streaming) .close_and_stop else .close;
}

test "modalCtrlCAction stops a streaming turn from inside picker/search and closes when idle" {
    const ctrl_c = vaxis.Key{ .codepoint = 'c', .mods = .{ .ctrl = true } };
    try std.testing.expectEqual(ModalCtrlC.close_and_stop, modalCtrlCAction(ctrl_c, true));
    try std.testing.expectEqual(ModalCtrlC.close, modalCtrlCAction(ctrl_c, false));
    // Ctrl+Shift+C is the copy chord; a bare 'c' is modal input.
    const shift = vaxis.Key{ .codepoint = 'c', .mods = .{ .ctrl = true, .shift = true } };
    try std.testing.expectEqual(ModalCtrlC.none, modalCtrlCAction(shift, true));
    try std.testing.expectEqual(ModalCtrlC.none, modalCtrlCAction(.{ .codepoint = 'c' }, true));
}

test "isCopyChord recovers the collapsed Ctrl+Shift+C byte only with a selection and no stream" {
    const shift = vaxis.Key{ .codepoint = 'c', .mods = .{ .ctrl = true, .shift = true } };
    // Terminal-reported chord (kitty protocol): shift modifier present,
    // copied regardless of streaming or selection state.
    try std.testing.expect(isCopyChord(shift, false, false));
    try std.testing.expect(isCopyChord(shift, true, false));
    try std.testing.expect(isCopyChord(shift, true, true));

    // Collapsed to plain 0x03 (no kitty protocol): the shift bit is dropped.
    const dropped = vaxis.Key{ .codepoint = 'c', .mods = .{ .ctrl = true } };
    // Recovered as copy only with a live selection and nothing streaming.
    try std.testing.expect(isCopyChord(dropped, false, true));
    // Otherwise it is indistinguishable from plain Ctrl+C and must not copy.
    try std.testing.expect(!isCopyChord(dropped, false, false));
    try std.testing.expect(!isCopyChord(dropped, true, true));
    try std.testing.expect(!isCopyChord(dropped, true, false));

    // No other key is the chord.
    try std.testing.expect(!isCopyChord(.{ .codepoint = 'x', .mods = .{ .ctrl = true } }, false, true));
    try std.testing.expect(!isCopyChord(.{ .codepoint = 'c' }, false, true));
}

/// The composer's on-screen stand-in for a line break. `vxfw.TextField` is a
/// single-line widget: a raw '\n' in its buffer would be written into a
/// terminal cell at render time and walk the cursor off the row. So a line
/// break is stored and drawn as this one visible grapheme and swapped for a
/// real newline only when text leaves the composer (`takeComposerText`). A
/// literal U+23CE typed or pasted into the field is indistinguishable and
/// becomes a newline too; the character exists to mean exactly that.
const newline_marker = "\u{23CE}"; // ⏎

/// Rewrites "\r\n", '\r' and '\n' each to one `newline_marker` so multi-line
/// text can enter the single-line composer without corrupting the render or
/// submitting early. Returns the input unchanged when there is nothing to
/// encode (or on OOM, when the text is at worst shown with raw breaks
/// folded by the sanitizer); caller frees only when the pointer differs.
fn encodeComposerNewlines(alloc: std.mem.Allocator, text: []const u8) []const u8 {
    if (std.mem.findAny(u8, text, "\r\n") == null) return text;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\r' or c == '\n') {
            if (c == '\r' and i + 1 < text.len and text[i + 1] == '\n') i += 1;
            out.appendSlice(alloc, newline_marker) catch return text;
        } else {
            out.append(alloc, c) catch return text;
        }
    }
    return out.toOwnedSlice(alloc) catch text;
}

/// Where the cursor of a marker-separated composer buffer lands when each
/// line is drawn on its own row. `cursor_byte` is the TextField gap position;
/// the gap moves by whole graphemes, so it never splits a marker.
const ComposerLayout = struct {
    /// Marker-separated line count, at least 1.
    line_count: u16,
    /// Line the cursor sits on, 0-based.
    cursor_line: u16,
    /// Display columns from that line's start to the cursor.
    cursor_cols: u16,
};

fn composerLayout(text: []const u8, cursor_byte: usize) ComposerLayout {
    var out: ComposerLayout = .{ .line_count = 1, .cursor_line = 0, .cursor_cols = 0 };
    var it = std.mem.splitSequence(u8, text, newline_marker);
    var idx: u16 = 0;
    var off: usize = 0;
    var found = false;
    while (it.next()) |seg| : (idx += 1) {
        const end = off + seg.len;
        if (!found and cursor_byte <= end) {
            found = true;
            out.cursor_line = idx;
            const upto = @max(off, @min(cursor_byte, end));
            out.cursor_cols = @intCast(width_mod.displayWidth(text[off..upto]));
        }
        off = end + newline_marker.len;
        out.line_count = idx + 1;
    }
    return out;
}

/// Byte position of the cursor moved one composer line up or down, keeping
/// the display column (clamped to the target line's width); null when the
/// cursor is already on the first/last line, which is the caller's cue to
/// fall through to history recall.
fn composerVerticalMove(text: []const u8, cursor_byte: usize, up: bool) ?usize {
    const layout = composerLayout(text, cursor_byte);
    if (up and layout.cursor_line == 0) return null;
    if (!up and layout.cursor_line + 1 >= layout.line_count) return null;
    const target_line = if (up) layout.cursor_line - 1 else layout.cursor_line + 1;

    var it = std.mem.splitSequence(u8, text, newline_marker);
    var idx: u16 = 0;
    var off: usize = 0;
    while (it.next()) |seg| : (idx += 1) {
        if (idx == target_line) {
            var i: usize = 0;
            var cols: u16 = 0;
            while (i < seg.len) {
                var j = i;
                const c = nextCell(seg, &j) orelse break;
                if (cols + c.width > layout.cursor_cols) break;
                cols += c.width;
                i = j;
            }
            return off + i;
        }
        off += seg.len + newline_marker.len;
    }
    return null;
}

test "composerVerticalMove keeps the column and stops at the edges" {
    const text = "abcd" ++ newline_marker ++ "xy" ++ newline_marker ++ "12345";
    const line2 = 4 + newline_marker.len;
    const line3 = line2 + 2 + newline_marker.len;

    // Down from "ab|cd" lands after "xy" (target line shorter than the column).
    try std.testing.expectEqual(@as(?usize, line2 + 2), composerVerticalMove(text, 2, false));
    // Down from "xy|" keeps column 2 into "12|345".
    try std.testing.expectEqual(@as(?usize, line3 + 2), composerVerticalMove(text, line2 + 2, false));
    // Up from "123|45" keeps what fits of column 3.
    try std.testing.expectEqual(@as(?usize, line2 + 2), composerVerticalMove(text, line3 + 3, true));
    // The edges yield null so history recall still works.
    try std.testing.expectEqual(@as(?usize, null), composerVerticalMove(text, 2, true));
    try std.testing.expectEqual(@as(?usize, null), composerVerticalMove(text, line3 + 1, false));
    // A single-line buffer never captures the keys.
    try std.testing.expectEqual(@as(?usize, null), composerVerticalMove("abc", 1, true));
    try std.testing.expectEqual(@as(?usize, null), composerVerticalMove("abc", 1, false));
}

test "composerLayout maps the cursor through markers to a line and column" {
    // Empty buffer: one line, origin.
    try std.testing.expectEqual(ComposerLayout{ .line_count = 1, .cursor_line = 0, .cursor_cols = 0 }, composerLayout("", 0));

    const text = "ab" ++ newline_marker ++ "cde" ++ newline_marker ++ "f";
    // Three lines.
    try std.testing.expectEqual(@as(u16, 3), composerLayout(text, 0).line_count);
    // End of the first line, just before its marker.
    try std.testing.expectEqual(ComposerLayout{ .line_count = 3, .cursor_line = 0, .cursor_cols = 2 }, composerLayout(text, 2));
    // Start of the second line, just after the marker.
    try std.testing.expectEqual(ComposerLayout{ .line_count = 3, .cursor_line = 1, .cursor_cols = 0 }, composerLayout(text, 2 + newline_marker.len));
    // Middle of the second line.
    try std.testing.expectEqual(ComposerLayout{ .line_count = 3, .cursor_line = 1, .cursor_cols = 2 }, composerLayout(text, 4 + newline_marker.len));
    // End of the buffer.
    try std.testing.expectEqual(ComposerLayout{ .line_count = 3, .cursor_line = 2, .cursor_cols = 1 }, composerLayout(text, text.len));

    // A trailing marker yields an empty last line the cursor can sit on.
    const trailing = "x" ++ newline_marker;
    try std.testing.expectEqual(ComposerLayout{ .line_count = 2, .cursor_line = 1, .cursor_cols = 0 }, composerLayout(trailing, trailing.len));
}

test "newline markers round-trip: what encode shows, submit's decode returns" {
    const alloc = std.testing.allocator;
    const original = "line one\nline two\n\nline four";
    const shown = encodeComposerNewlines(alloc, original);
    defer if (shown.ptr != original.ptr) alloc.free(shown);
    const back = try std.mem.replaceOwned(u8, alloc, shown, newline_marker, "\n");
    defer alloc.free(back);
    try std.testing.expectEqualStrings(original, back);
}

test "encodeComposerNewlines folds every break spelling to one marker" {
    const alloc = std.testing.allocator;
    // No breaks: the same pointer comes back, nothing to free.
    const plain = "one line";
    try std.testing.expectEqual(plain.ptr, encodeComposerNewlines(alloc, plain).ptr);

    const mixed = encodeComposerNewlines(alloc, "a\nb\r\nc\rd");
    defer alloc.free(mixed);
    try std.testing.expectEqualStrings("a" ++ newline_marker ++ "b" ++ newline_marker ++ "c" ++ newline_marker ++ "d", mixed);
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
    /// `--reasoning-effort`: pin every turn's effort for this session,
    /// applied to `agent.reasoning_effort` after config load. Null means the
    /// config decides.
    reasoning_effort: ?config.ReasoningEffort = null,
    session: ?[]const u8 = null,
    continue_last: bool = false,
    /// `--mascot[=<mode>]`, unparsed. Null means the flag was absent, which is
    /// what lets `tui.mascot` be a real default rather than something the flag
    /// always overrides with "off".
    mascot: ?[]const u8 = null,
    /// `--mascot-size=<small|medium|large>`, unparsed, same null convention.
    mascot_size: ?[]const u8 = null,
    /// `--mascot-facing=<default|inverted>`, unparsed, same null convention.
    mascot_facing: ?[]const u8 = null,
    /// `--mascot-speed=<0..10>`, unparsed, same null convention.
    mascot_speed: ?[]const u8 = null,
    /// Initial palette for this invocation, overriding `CLANKER_THEME`.
    theme: ?[]const u8 = null,
};

/// One resolved setting plus the spelling that failed to parse, if any.
fn Picked(comptime T: type) type {
    return struct { value: T, bad: ?[]const u8 };
}

/// Flag beats config beats `fallback`, and an unparseable spelling from either
/// falls back rather than failing.
///
/// A typo is *not* an error here: this is an easter egg, and refusing to open
/// the REPL over one would be a worse trade than starting without it. The
/// spelling is handed back so the caller can say so on the transcript, which
/// is the only reason a user ever finds out.
fn pickSetting(
    comptime T: type,
    comptime parse: fn ([]const u8) ?T,
    flag: ?[]const u8,
    configured: []const u8,
    fallback: T,
) Picked(T) {
    if (flag) |text| {
        return if (parse(text)) |v| .{ .value = v, .bad = null } else .{ .value = fallback, .bad = text };
    }
    if (configured.len == 0) return .{ .value = fallback, .bad = null };
    return if (parse(configured)) |v|
        .{ .value = v, .bad = null }
    else
        .{ .value = fallback, .bad = configured };
}

const MascotChoice = struct {
    mode: mascot.Mode,
    size: mascot.Size,
    facing: mascot.Facing,
    speed: u8,
    bad_mode: ?[]const u8,
    bad_size: ?[]const u8,
    bad_facing: ?[]const u8,
    bad_speed: ?[]const u8,
};

/// Resolves every mascot setting from its flag and its config key.
///
/// Size is not a plain two-way pick: `input` is the only mode whose size
/// changes the shape of the composer, so it defaults to the one that fits
/// inside it (Mode.defaultSize). Facing and speed default independently.
fn resolveMascot(
    mode_flag: ?[]const u8,
    mode_cfg: []const u8,
    size_flag: ?[]const u8,
    size_cfg: []const u8,
    facing_flag: ?[]const u8,
    facing_cfg: []const u8,
    speed_flag: ?[]const u8,
    speed_cfg: ?u8,
) MascotChoice {
    const mode = pickSetting(mascot.Mode, mascot.Mode.parse, mode_flag, mode_cfg, .off);
    const size = pickSetting(mascot.Size, mascot.Size.parse, size_flag, size_cfg, mode.value.defaultSize());
    const facing = pickSetting(mascot.Facing, mascot.Facing.parse, facing_flag, facing_cfg, .default);
    // Config is parsed as an integer before the REPL starts. The flag remains
    // text because command-line arguments are text, so only it can be invalid
    // at this point.
    const speed: Picked(u8) = if (speed_flag) |text|
        if (mascot.parseSpeed(text)) |value|
            .{ .value = value, .bad = null }
        else
            .{ .value = speed_cfg orelse 5, .bad = text }
    else
        .{ .value = speed_cfg orelse 5, .bad = null };
    return .{
        .mode = mode.value,
        .size = size.value,
        .facing = facing.value,
        .speed = speed.value,
        .bad_mode = mode.bad,
        .bad_size = size.bad,
        .bad_facing = facing.bad,
        .bad_speed = speed.bad,
    };
}

fn resolveMode(flag: ?[]const u8, configured: []const u8) MascotChoice {
    return resolveMascot(flag, configured, null, "", null, "", null, null);
}

test "resolveMascot prefers the flag and tolerates junk from either side" {
    // Neither set: off, quietly.
    try std.testing.expectEqual(mascot.Mode.off, resolveMode(null, "off").mode);
    try std.testing.expectEqual(mascot.Mode.off, resolveMode(null, "").mode);
    // Config alone decides when the flag is absent.
    try std.testing.expectEqual(mascot.Mode.typing, resolveMode(null, "type").mode);
    // The flag wins, in both directions.
    try std.testing.expectEqual(mascot.Mode.loop, resolveMode("loop", "off").mode);
    try std.testing.expectEqual(mascot.Mode.off, resolveMode("off", "loop").mode);
    // Bare `--mascot` still beats a config that says off.
    try std.testing.expectEqual(mascot.Mode.bare_default, resolveMode("on", "off").mode);
    // The new modes are reachable from both sides.
    try std.testing.expectEqual(mascot.Mode.place, resolveMode("place", "off").mode);
    try std.testing.expectEqual(mascot.Mode.input, resolveMode(null, "input").mode);
    // Junk falls back to off and is reported, not swallowed.
    const bad_flag = resolveMode("sideways", "loop");
    try std.testing.expectEqual(mascot.Mode.off, bad_flag.mode);
    try std.testing.expectEqualStrings("sideways", bad_flag.bad_mode.?);
    const bad_cfg = resolveMode(null, "backwards");
    try std.testing.expectEqual(mascot.Mode.off, bad_cfg.mode);
    try std.testing.expectEqualStrings("backwards", bad_cfg.bad_mode.?);
    // A good value reports nothing.
    try std.testing.expectEqual(@as(?[]const u8, null), resolveMode("loop", "off").bad_mode);
}

test "resolveMascot takes size from the flag, the config, then the mode" {
    try std.testing.expectEqual(mascot.Size.medium, resolveMode("loop", "").size);
    const small = resolveMascot("loop", "", "small", "", null, "", null, null);
    try std.testing.expectEqual(mascot.Size.small, small.size);
    // Config supplies it when the flag does not, and the flag wins when both do.
    try std.testing.expectEqual(
        mascot.Size.large,
        resolveMascot("loop", "", null, "large", null, "", null, null).size,
    );
    try std.testing.expectEqual(
        mascot.Size.small,
        resolveMascot("loop", "", "small", "large", null, "", null, null).size,
    );
    // Junk keeps the default and is reported.
    const bad = resolveMascot("loop", "", "gigantic", "", null, "", null, null);
    try std.testing.expectEqual(mascot.Size.medium, bad.size);
    try std.testing.expectEqualStrings("gigantic", bad.bad_size.?);
    // A bad size must not take the mode down with it.
    try std.testing.expectEqual(mascot.Mode.loop, bad.mode);
}

test "input mode defaults to the size that fits the composer" {
    // `--mascot=input` with nothing else said must not make the box taller
    // than it is with the mascot off, so its unasked-for size is `mini`.
    try std.testing.expectEqual(mascot.Size.mini, resolveMode("input", "").size);
    try std.testing.expectEqual(mascot.Size.mini, resolveMode(null, "input").size);
    try std.testing.expectEqual(
        @as(u16, 3),
        mascot.inputBoxHeight(resolveMode("input", "").size.variant()),
    );

    // Asking for a bigger one still gets it, from either side, and that is
    // when the box is allowed to grow.
    const asked = resolveMascot("input", "", "small", "", null, "", null, null);
    try std.testing.expectEqual(mascot.Size.small, asked.size);
    try std.testing.expect(mascot.inputBoxHeight(asked.size.variant()) > 3);
    try std.testing.expectEqual(
        mascot.Size.xsmall,
        resolveMascot("input", "", null, "xsmall", null, "", null, null).size,
    );

    // The default is per mode, not global: nothing else shrinks.
    try std.testing.expectEqual(mascot.Size.medium, resolveMode("place", "").size);
    try std.testing.expectEqual(mascot.Size.medium, resolveMode("on", "").size);
    // A junk size under `input` falls back to mini, not to medium: falling
    // back must not be the thing that resizes the box either.
    const junk = resolveMascot("input", "", "gigantic", "", null, "", null, null);
    try std.testing.expectEqual(mascot.Size.mini, junk.size);
    try std.testing.expectEqualStrings("gigantic", junk.bad_size.?);
}

test "facing defaults to the mode's natural pose and is invertible" {
    // Every mode defaults to `.default` (the natural orientation); only an
    // explicit request inverts it, and either source can, flag winning.
    try std.testing.expectEqual(mascot.Facing.default, resolveMode("place", "").facing);
    try std.testing.expectEqual(mascot.Facing.default, resolveMode("loop", "").facing);
    try std.testing.expectEqual(
        mascot.Facing.inverted,
        resolveMascot("place", "", null, "", "inverted", "", null, null).facing,
    );
    try std.testing.expectEqual(
        mascot.Facing.inverted,
        resolveMascot("loop", "", null, "", null, "inverted", null, null).facing,
    );
    try std.testing.expectEqual(
        mascot.Facing.default,
        resolveMascot("loop", "", null, "", "default", "inverted", null, null).facing,
    );
    // Junk falls back to `.default` and is reported.
    const bad = resolveMascot("place", "", null, "", "sideways", "", null, null);
    try std.testing.expectEqual(mascot.Facing.default, bad.facing);
    try std.testing.expectEqualStrings("sideways", bad.bad_facing.?);
}

test "resolveMascot takes speed from the flag, the config, then 5" {
    // 5 is the regular pace; 0 and 10 are the bounds.
    try std.testing.expectEqual(@as(u8, 5), resolveMode("loop", "").speed);
    const fast = resolveMascot("loop", "", null, "", null, "", "10", null);
    try std.testing.expectEqual(@as(u8, 10), fast.speed);
    // Config supplies it when the flag does not, and the flag wins when both do.
    try std.testing.expectEqual(
        @as(u8, 2),
        resolveMascot("loop", "", null, "", null, "", null, 2).speed,
    );
    try std.testing.expectEqual(
        @as(u8, 8),
        resolveMascot("loop", "", null, "", null, "", "8", 2).speed,
    );
    // Out of range or junk keeps the default and is reported.
    const high = resolveMascot("loop", "", null, "", null, "", "11", null);
    try std.testing.expectEqual(@as(u8, 5), high.speed);
    try std.testing.expectEqualStrings("11", high.bad_speed.?);
    const junk = resolveMascot("loop", "", null, "", null, "", "zoom", null);
    try std.testing.expectEqual(@as(u8, 5), junk.speed);
    try std.testing.expectEqualStrings("zoom", junk.bad_speed.?);
}

/// The id `--continue` means: the saved session touched most recently.
/// Returns null when there are none, so a first `--continue` starts a fresh
/// session rather than failing at someone who has not made one yet.
fn latestSessionId(io: std.Io, arena: std.mem.Allocator) ?[]const u8 {
    return session_mod.latestSessionId(io, arena, "state/sessions");
}

/// A fresh conversation's id, minted the first time it is saved. The
/// nanosecond suffix keeps rapid successive sessions distinct and stays
/// within the slug alphabet `session.validSessionId` accepts, like the server's
/// `sess-<base36>` fallback.
fn mintSessionId(io: std.Io, arena: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(arena, "sess-{d}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
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
    try std.testing.expect(session_mod.validSessionId(a));
    try std.testing.expect(session_mod.validSessionId(b));
    try std.testing.expect(std.mem.startsWith(u8, a, "sess-"));
    // Nanosecond-resolution ids of two consecutive mints are not equal.
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "clean returns the input slice unchanged when nothing to drop" {
    const untouched = "hello\nworld\t!";
    try std.testing.expectEqual(untouched.ptr, clean(std.testing.allocator, untouched).?.ptr);
}

test "the stats and compaction lines route down the plain dim draw branch" {
    // `draw` picks a style per transcript line by inspecting the text: a tool
    // card gets the tool tint and a bar-preserving wrap, an "error:" prefix
    // gets the error tint, everything else is plain dim. The turn line and
    // the compaction notices are meant to be that last case, and they are
    // bracketed strings, so pin it rather than discover it as a wrong colour.
    const turn = try stats_mod.formatTurn(std.testing.allocator, .{
        .prompt_tokens = 1234,
        .completion_tokens = 567,
        .wall_ms = 4200,
    });
    defer std.testing.allocator.free(turn);
    const compacted = (try stats_mod.formatCompaction(std.testing.allocator, .{
        .messages_before = 20,
        .messages_after = 8,
        .bytes_before = 100_000,
        .bytes_after = 50_672,
    })).?;
    defer std.testing.allocator.free(compacted);

    for ([_][]const u8{ turn, compacted }) |line| {
        try std.testing.expect(!transcript_mod.isToolCardLine(line));
        try std.testing.expect(!std.mem.startsWith(u8, line, "error:"));
        // And nothing here can be mistaken for input the user typed.
        try std.testing.expect(parseCommand(line) == null);
        try std.testing.expect(parseShellEscape(line) == null);
    }
}

test "clean drops control bytes but keeps newline and tab" {
    const dirty = "a\x01b\nc\x7Fd\te";
    const got = clean(std.testing.allocator, dirty).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("ab\ncd\te", got);
}

test "clean drops UTF-8 encoded C1 controls the old local strip let through" {
    // U+009B is CSI. A terminal that decodes C1 from UTF-8 reads the two
    // bytes \xc2\x9b as the start of an escape sequence, so model output
    // carrying them was an injection the previous `stripControls` (which
    // tested single bytes against sanitize.isControl only) did not catch.
    const csi = "before\xc2\x9b31mafter";
    const got = clean(std.testing.allocator, csi).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("before31mafter", got);

    // A legitimate multi-byte codepoint whose tail lands in the same numeric
    // range is untouched: U+20AC (Euro) is \xe2\x82\xac.
    const euro = "\xe2\x82\xac 5";
    try std.testing.expectEqual(euro.ptr, clean(std.testing.allocator, euro).?.ptr);
}

test "a completed answer is control-stripped before it becomes transcript" {
    // The regression this guards: `finishTurn` renders the provider's whole
    // `message.content` when there is one, which displaces the per-delta
    // strip `onToken` does. An ESC in the answer therefore reached a cell on
    // the ordinary success path. Assert at the seam every answer goes
    // through, so the guarantee cannot be lost again by a new caller.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lines: std.ArrayList(Line) = .empty;
    appendAnswerLines(arena, &lines, "here is \x1b[31mred\x1b[0m and \xc2\x9bcsi");
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    // The turn arrow is prepended; the escapes are gone, their payload text
    // stays (dropping bytes, not whole sequences, is sanitize.zig's contract).
    try std.testing.expectEqualStrings("\xe2\x80\xba here is [31mred[0m and csi", lines.items[0].text);
    for (lines.items) |l| {
        try std.testing.expect(std.mem.findScalar(u8, l.text, 0x1B) == null);
    }
}

test "appendAnswerLines splits on newlines, tags fences, and arrows only the first line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lines: std.ArrayList(Line) = .empty;
    appendAnswerLines(arena, &lines, "intro\n```zig\nconst x = 1;\n```\noutro");
    // Fence markers are consumed, so: intro, the code line, outro.
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("\xe2\x80\xba intro", lines.items[0].text);
    try std.testing.expect(lines.items[0].fence_lang == null);
    try std.testing.expectEqualStrings("const x = 1;", lines.items[1].text);
    try std.testing.expectEqualStrings("zig", lines.items[1].fence_lang.?);
    try std.testing.expectEqualStrings("outro", lines.items[2].text);
    try std.testing.expect(lines.items[2].fence_lang == null);
}

test "appendAnswerLines copies the answer instead of borrowing it" {
    // finishTurn calls this with `bridge_stream_buf.items` and clears that
    // buffer on the next statement, so a borrowed slice would leave the
    // transcript pointing at reused memory.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(std.testing.allocator);
    try scratch.appendSlice(std.testing.allocator, "borrowed answer");

    var lines: std.ArrayList(Line) = .empty;
    appendAnswerLines(arena, &lines, scratch.items);
    @memset(scratch.items, 'X');
    try std.testing.expectEqualStrings("\xe2\x80\xba borrowed answer", lines.items[0].text);
}

pub fn cmdReplVaxis(init: std.process.Init, opts: ReplOptions) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    // `vxfw.App` owns the terminal through `init.io`, including its alternate
    // screen writer. Agent requests can in turn use `Io.concurrent` for HTTP
    // timeouts (and a goal may make many of those). Sharing that cancellable
    // dispatcher with the terminal writer lets its SIGIO cancellation path
    // interrupt a frame write; Zig then panics trying to print that panic via
    // the same writer, producing the recursive File.Writer trace and leaving
    // the terminal in the alternate screen. Give the worker its own threaded
    // dispatcher. The bridge still uses `io`: it only coordinates in-memory
    // transcript state and the render thread remains the sole terminal owner.
    var agent_threaded = std.Io.Threaded.init(gpa, .{});
    defer agent_threaded.deinit();
    const agent_io = agent_threaded.io();
    bridge_gpa = gpa;
    bridge_io = io;
    var cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.toml", "config.local.toml");
    // `--reasoning-effort` is the config key for one session; the agent loop
    // reads only cfg, so apply it before anything captures the config.
    if (opts.reasoning_effort) |re| cfg.agent.reasoning_effort = re;
    // A REPL owns the terminal and has one live conversation, so it is safe
    // to move this standalone process into its worktree before anything else
    // opens a cwd-relative file. (The concurrent Web UI cannot do that and
    // instead passes an absolute sandbox root per request.)
    var wt: ?worktree_mod.Worktree = null;
    defer if (wt) |*w| w.deinit(gpa);
    var harness_root: ?[]const u8 = null;
    if (cfg.agent.isolated_tui or cfg.agent.worktreeOn(.tui)) {
        const root_z = try std.process.currentPathAlloc(io, gpa);
        defer gpa.free(root_z);
        const root = try arena.dupe(u8, root_z);
        const inst_id = if (cfg.instance.id.len > 0) cfg.instance.id else if (cfg.instance.name.len > 0) cfg.instance.name else "self";
        var tag_buf: [48]u8 = undefined;
        const wt_id = try std.fmt.allocPrint(gpa, "tui-{d}-{s}", .{ std.Io.Timestamp.now(io, .real).nanoseconds, worktree_mod.branchInstanceTag(&tag_buf, inst_id) });
        defer gpa.free(wt_id);
        if (worktree_mod.createOn(gpa, io, wt_id, "clanker/tui-", .run)) |created| {
            if (std.process.setCurrentPath(io, created.path)) {
                cfg.agent.shared_root = root;
                harness_root = root;
                wt = created;
                log.log(.info, "repl: isolated in {s} on branch {s}", .{ created.path, created.branch });
            } else |err| {
                log.log(.warn, "repl: could not switch into isolated worktree: {s}", .{@errorName(err)});
                var failed = created;
                failed.deinit(gpa);
            }
        } else |err| {
            log.log(.warn, "repl: could not create isolated worktree ({s}); using the checkout", .{@errorName(err)});
        }
    }
    // The ask/confirm modal's timeout backstop, same knob serve uses.
    ask_timeout_ns = @as(u64, cfg.agent.ask_timeout_seconds) * std.time.ns_per_s;
    std.Io.Dir.cwd().createDirPath(io, cfg.agent.sandbox_root) catch {};
    var reg = try registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir);
    if (harness_root) |root| try reg.rebaseWasmPaths(arena, root);
    const tool_defs = try reg.toToolDefs(arena);
    // `--provider`/`--model` pick the starting provider/model; `--model
    // <provider>/<model>` picks both at once, resolved by the same
    // Config.resolveProvider rule `clanker run` uses.
    const provider = try cfg.resolveProvider(opts.provider, opts.model);
    const ctx = client.Ctx{ .io = agent_io, .gpa = gpa, .environ_map = init.environ_map, .cfg = &cfg };

    // Which conversation this is: `--session <id>` names one, `--continue`
    // picks up the most recently touched one, and otherwise (sessions module
    // on) a fresh `repl-<ts>` id is minted so the conversation is findable in
    // `clanker sessions` afterwards, the same contract the deleted REPL and
    // `clanker run` honor. With the module off, nothing is read or written.
    const now_s: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    var session_id: ?[]const u8 = opts.session;
    if (session_id == null and opts.continue_last) {
        session_id = session_mod.latestSessionId(io, arena, "state/sessions");
    }
    // The id becomes a path fragment under state/sessions/, so the shared
    // session-store validator rejects it before it could walk out of the store.
    if (session_id) |sid| {
        if (!session_mod.validSessionId(sid)) return error.InvalidSessionId;
    }
    if (session_id == null and cfg.modules.sessions) {
        session_id = try std.fmt.allocPrint(arena, "repl-{d}", .{now_s});
    }
    var session_created: i64 = now_s;
    var session_title: []const u8 = "";
    var loaded_messages: []const types.Message = &.{};
    var loaded_system_prompt: ?[]const u8 = null;
    if (session_id) |sid| {
        const maybe_s: ?session_mod.Session = session_mod.loadSession(io, gpa, arena, "state/sessions", sid) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (maybe_s) |s| {
            session_created = s.created;
            session_title = s.title;
            loaded_messages = s.messages;
            loaded_system_prompt = s.system_prompt;
        }
    }

    var buffer: [1024]u8 = undefined;
    var app: vxfw.App = try .init(io, gpa, init.environ_map, &buffer);
    defer app.deinit();
    // Some pseudo-terminals briefly report 0x0. vxfw derives cell dimensions
    // from this initial size and cannot lay out such a surface, so fail with
    // an operator-facing diagnostic instead of reaching its divide-by-zero.
    const initial_size = try app.tty.getWinsize();
    if (initial_size.cols == 0 or initial_size.rows == 0) {
        return error.TerminalSizeUnavailable;
    }

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
        .session_system_prompt = loaded_system_prompt,
        .theme_override = opts.theme,
    };
    // The easter egg. `--mascot` beats `tui.mascot`; both off is the default
    // and costs nothing beyond one `.off` branch per frame.
    const mascot_choice = resolveMascot(
        opts.mascot,
        cfg.tui.mascot,
        opts.mascot_size,
        cfg.tui.mascot_size,
        opts.mascot_facing,
        cfg.tui.mascot_facing,
        opts.mascot_speed,
        cfg.tui.mascot_speed,
    );
    model.mascot = .{
        .mode = mascot_choice.mode,
        .size = mascot_choice.size,
        .facing = mascot_choice.facing,
        .speed = mascot_choice.speed,
    };
    // Only borrowed when there is something to draw, so nothing else in this
    // model can quietly start depending on a live app handle.
    if (mascot_choice.mode != .off) model.app = &app;
    for (loaded_messages) |m| {
        // The agent rebuilds its own system prompt per run; a stored one
        // would fight it (same rule as `clanker run --session`).
        if (m.role == .system) continue;
        try model.messages.append(arena, m);
    }
    if (session_id) |sid| {
        // Say which conversation was resumed, so re-entering `--continue` is
        // not indistinguishable from a fresh REPL. Only when it actually
        // loaded something, a brand-new minted id has nothing to announce.
        var non_system: usize = 0;
        for (model.messages.items) |m| {
            if (m.role != .system) non_system += 1;
        }
        if (non_system > 0) {
            model.lines.append(arena, .{
                .text = std.fmt.allocPrint(arena, "notice: resumed conversation {s} ({d} messages)", .{ sid, non_system }) catch "notice: resumed conversation",
                .dim = true,
            }) catch {};
        }
    }
    // Fresh session leaves `lines` empty so draw's empty-state hero (examples
    // + Tab/Ctrl-P) can show. A seed transcript line used to hide that
    // forever, and was never removed after the first task. A resume already
    // has the resumed-conversation notice; a bad mascot spelling is appended
    // below and takes the same slot.
    if (mascot_choice.bad_mode) |bad| {
        model.lines.append(arena, .{
            .text = std.fmt.allocPrint(
                arena,
                "error: mascot mode '{s}' is not one of off, type, loop, place, input; mascot is off",
                .{bad},
            ) catch "error: unknown mascot mode; mascot is off",
        }) catch {};
    }
    if (mascot_choice.bad_size) |bad| {
        model.lines.append(arena, .{
            .text = std.fmt.allocPrint(
                arena,
                "error: mascot size '{s}' is not one of mini, xsmall, small, medium, large; using {s}",
                .{ bad, @tagName(mascot_choice.size) },
            ) catch "error: unknown mascot size; using the mode's default",
        }) catch {};
    }
    if (mascot_choice.bad_facing) |bad| {
        model.lines.append(arena, .{
            .text = std.fmt.allocPrint(
                arena,
                "error: mascot facing '{s}' is not one of default, inverted; using the mode's default",
                .{bad},
            ) catch "error: unknown mascot facing; using the mode's default",
        }) catch {};
    }
    if (mascot_choice.bad_speed) |bad| {
        model.lines.append(arena, .{
            .text = std.fmt.allocPrint(
                arena,
                "error: mascot speed '{s}' is not an integer 0..10; using 5",
                .{bad},
            ) catch "error: unknown mascot speed; using 5",
        }) catch {};
    }
    if (opts.theme) |name| {
        if (!theme_mod.isKnown(name)) {
            model.theme_override = null;
            model.lines.append(arena, .{
                .text = std.fmt.allocPrint(arena, "error: unknown theme '{s}'; type /theme to list available themes", .{name}) catch "error: unknown theme; type /theme to list available themes",
            }) catch {};
        }
    } else if (themeName(init.environ_map)) |name| {
        // --theme above is checked; the persistent default must be too, or a
        // typo'd CLANKER_THEME silently renders the default palette with no
        // hint that the env var was read and rejected.
        if (!theme_mod.isKnown(name)) {
            model.lines.append(arena, .{
                .text = std.fmt.allocPrint(arena, "error: CLANKER_THEME '{s}' is not a known theme; type /theme to list available themes", .{name}) catch "error: unknown CLANKER_THEME; type /theme to list available themes",
            }) catch {};
        }
    }
    model.model_candidates = buildModelCandidates(arena, &model.cfg, init.environ_map, init.io) catch &.{};
    // TUI plugin commands must load before the palette is built, or Ctrl-P
    // would never see them; a plugin toggled mid-session reloads here via
    // /tui-plugins and rebuilds the candidates on its own.
    model.reloadTuiPlugins();
    model.command_candidates = buildCommandCandidates(arena) catch &.{};
    // A resumed conversation already occupies part of the window, so the
    // meter and the mid-turn compaction baseline start from what was loaded
    // rather than from zero.
    model.context_tokens = stats_mod.historyTokens(model.messages.items);
    model.summary_before = stats_mod.summaryState(model.messages.items);
    defer model.text_field.deinit();
    // Search state is gpa-owned rather than arena-owned (it is rebuilt on
    // every keystroke, so the arena would grow by a hit list per character),
    // which means it has to be released explicitly.
    defer model.search_query.deinit(gpa);
    defer model.search_hits.deinit(gpa);
    defer model.kill_ring.deinit(gpa);

    // From here on, log.log writes straight to stderr with no coordination
    // with vaxis's owned alt-screen buffer, unlike the old REPL where stray
    // stderr text just scrolled by harmlessly: any write during the session
    // corrupts the screen. So the threshold is raised here, at the last
    // moment before the alt screen exists, rather than at the top of this
    // function.
    //
    // Raising it at the top silenced startup diagnostics that have no screen
    // to corrupt yet, and had made one of them a lie: the
    // `confirm_writes = "always"` warning below is logged at `.warn`, so
    // `log.log` returned early and the operator was told nothing at all,
    // while the comment above it still claimed it was "said once ... so the
    // operator is not left believing they are protected". Config parse
    // warnings and a failed session mint were being dropped the same way.
    log.setLevel(.error_);

    // An `.error_` record would still write straight to stderr from here on
    // (the LLM client logs retry exhaustion at error level even when the
    // fallback chain then recovers), painting `[ERROR] ts_ms=...` over the
    // frame the draw loop just wrote. Route records into the transcript as
    // dim lines instead; the draw loop and finishTurn drain them.
    log.setSink(.{ .ctx = model, .write = logSinkWrite });
    defer log.setSink(null);

    // Save on every exit path: app.run returns for /quit and for Ctrl-C while
    // idle alike, so persisting here (rather than in submit) is what makes the
    // conversation survive. Save even if the run loop errored out.
    const run_result = app.run(model.widget(), .{});
    // If app.run errored out while a turn was in flight, signal it to stop
    // and join it before touching self.messages or freeing bridge buffers.
    if (model.thread) |t| {
        bridge_stop_flag.store(true, .release);
        // The worker may be parked on an unanswered ask; wake it declined
        // or this join waits out the whole ask timeout.
        askCancelPending();
        t.join();
        model.thread = null;
    }
    model.saveConversation();
    {
        const sid = model.session_id orelse "default";
        subprocess.endSession(sid);
        dap.dropLive(sid);
    }
    // Worker is joined (either was idle or we joined above), safe to free.
    {
        for (bridge_tool_lines.items) |l| bridge_gpa.free(l);
        bridge_tool_lines.deinit(bridge_gpa);
        bridge_stream_buf.deinit(bridge_gpa);
        bridge_mutex.lockUncancelable(bridge_io);
        clearBridgeSteer();
        bridge_steer.deinit(bridge_gpa);
        bridge_mutex.unlock(bridge_io);
    }
    try run_result;
}
