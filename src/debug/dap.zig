//! DAP framing and adapter session (PRD 0017). Length-prefixed JSON-RPC
//! over stdio; adapter processes live in the 0016 session registry.

const std = @import("std");
const subprocess = @import("../agent/subprocess.zig");
const config_mod = @import("../config.zig");

pub fn encodeFrame(alloc: std.mem.Allocator, payload: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n\r\n{s}", .{ payload.len, payload });
}

/// Hard cap on one buffered DAP frame. A real adapter's messages are at most
/// a few MiB (a large `variables` response); a `Content-Length` declaring
/// more than this can never complete, so `readFrame` fails fast instead of
/// growing its buffer by one chunk per read until the process runs out of
/// memory (the frame length is adapter-controlled and unchecked).
const max_frame_bytes: usize = 16 << 20;

pub const Decoded = struct {
    payload: []const u8,
    consumed: usize,
};

/// Match a DAP string field regardless of the spaces `json.dumps` inserts.
fn frameIs(payload: []const u8, key: []const u8, want: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload, .{}) catch return false;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return false,
    };
    const v = obj.get(key) orelse return false;
    return switch (v) {
        .string => |s| std.mem.eql(u8, s, want),
        else => false,
    };
}

fn frameRequestSeq(payload: []const u8) ?u32 {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get("request_seq") orelse return null;
    return switch (v) {
        .integer => |n| if (n < 0) null else @intCast(@min(n, std.math.maxInt(u32))),
        else => null,
    };
}

pub fn decodeFrame(buf: []const u8) ?Decoded {
    const sep = std.mem.find(u8, buf, "\r\n\r\n") orelse return null;
    const headers = buf[0..sep];
    const body_start = sep + 4;
    var content_len: ?usize = null;
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |h| {
        if (h.len >= 15 and std.ascii.startsWithIgnoreCase(h, "content-length:")) {
            const v = std.mem.trim(u8, h[15..], " \t");
            content_len = std.fmt.parseInt(usize, v, 10) catch return null;
        }
    }
    const n = content_len orelse return null;
    if (n > max_frame_bytes) return null;
    if (buf.len < body_start + n) return null;
    return .{ .payload = buf[body_start .. body_start + n], .consumed = body_start + n };
}

pub const PendingBreakpoint = struct {
    source: []const u8,
    lines: []const i64,
    condition: ?[]const u8 = null,
    hit_condition: ?[]const u8 = null,
};

pub const Adapter = struct {
    name: []const u8,
    command: []const []const u8,
};

pub const Session = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    reg: *subprocess.Registry,
    session_id: []const u8,
    kind: []const u8 = "dap",
    seq: u32 = 1,
    events: std.ArrayList([]const u8) = .empty,
    pending_bps: ?PendingBreakpoint = null,
    adapter_name: []const u8 = "",
    buf: std.ArrayList(u8) = .empty,
    launch_timeout_ms: u32 = 15_000,
    request_timeout_ms: u32 = 15_000,
    disconnect_timeout_ms: u32 = 3_000,

    pub fn deinit(self: *Session) void {
        self.clearPendingBreakpoints();
        for (self.events.items) |e| self.gpa.free(e);
        self.events.deinit(self.gpa);
        self.buf.deinit(self.gpa);
    }

    fn clearPendingBreakpoints(self: *Session) void {
        const bp = self.pending_bps orelse return;
        self.gpa.free(bp.source);
        self.gpa.free(bp.lines);
        if (bp.condition) |c| self.gpa.free(c);
        if (bp.hit_condition) |h| self.gpa.free(h);
        self.pending_bps = null;
    }

    pub fn takeEvents(self: *Session, arena: std.mem.Allocator) ![][]const u8 {
        self.drainAvailable(arena) catch {};
        const out = try arena.alloc([]const u8, self.events.items.len);
        for (self.events.items, 0..) |e, i| {
            out[i] = try arena.dupe(u8, e);
            self.gpa.free(e);
        }
        self.events.clearRetainingCapacity();
        return out;
    }

    fn nextSeq(self: *Session) u32 {
        const n = self.seq;
        self.seq += 1;
        return n;
    }

    fn writePayload(self: *Session, arena: std.mem.Allocator, payload: []const u8) !void {
        const frame = try encodeFrame(arena, payload);
        try self.reg.writeStdin(self.session_id, self.kind, frame);
    }

    fn readFrame(self: *Session, arena: std.mem.Allocator) ![]const u8 {
        while (true) {
            if (decodeFrame(self.buf.items)) |d| {
                const payload = try arena.dupe(u8, d.payload);
                const rest = self.buf.items[d.consumed..];
                std.mem.copyForwards(u8, self.buf.items, rest);
                self.buf.shrinkRetainingCapacity(rest.len);
                return payload;
            }
            const chunk = self.reg.readStdout(arena, self.session_id, self.kind, 4096) catch |err| {
                return err;
            };
            try self.buf.appendSlice(self.gpa, chunk);
            // The buffer holds only the pending frame's prefix (complete
            // frames are consumed above), so this caps the declared length an
            // adapter can make us accumulate.
            if (self.buf.items.len > max_frame_bytes) return error.FrameTooLarge;
        }
    }

    fn drainAvailable(self: *Session, arena: std.mem.Allocator) !void {
        // Non-blocking-ish: if a full frame is already buffered, take it.
        while (decodeFrame(self.buf.items)) |d| {
            try self.noteFrame(try arena.dupe(u8, d.payload));
            const rest = self.buf.items[d.consumed..];
            std.mem.copyForwards(u8, self.buf.items, rest);
            self.buf.shrinkRetainingCapacity(rest.len);
        }
    }

    fn noteFrame(self: *Session, payload: []const u8) !void {
        if (frameIs(payload, "type", "event")) {
            try self.events.append(self.gpa, try self.gpa.dupe(u8, payload));
        }
    }

    fn sendRequest(self: *Session, arena: std.mem.Allocator, command: []const u8, args_json: []const u8) !u32 {
        const id = self.nextSeq();
        const payload = try std.fmt.allocPrint(
            arena,
            "{{\"seq\":{d},\"type\":\"request\",\"command\":\"{s}\",\"arguments\":{s}}}",
            .{ id, command, args_json },
        );
        try self.writePayload(arena, payload);
        return id;
    }

    fn waitResponse(self: *Session, arena: std.mem.Allocator, id: u32) ![]const u8 {
        var spins: usize = 0;
        while (spins < 256) : (spins += 1) {
            const frame = self.readFrame(arena) catch |err| return err;
            if (frameIs(frame, "type", "event")) {
                try self.events.append(self.gpa, try self.gpa.dupe(u8, frame));
                continue;
            }
            if (frameRequestSeq(frame) == id) return frame;
        }
        return error.Timeout;
    }

    fn waitEvent(self: *Session, arena: std.mem.Allocator, event: []const u8) !void {
        for (self.events.items) |e| {
            if (frameIs(e, "event", event)) return;
        }
        var spins: usize = 0;
        while (spins < 256) : (spins += 1) {
            const frame = self.readFrame(arena) catch |err| return err;
            try self.events.append(self.gpa, try self.gpa.dupe(u8, frame));
            if (frameIs(frame, "event", event)) return;
        }
        return error.Timeout;
    }

    pub fn spawnAdapter(self: *Session, argv: []const []const u8, cwd: std.process.Child.Cwd) !void {
        if (self.reg.get(self.session_id, self.kind) != null) {
            var tmp_arena = std.heap.ArenaAllocator.init(self.gpa);
            defer tmp_arena.deinit();
            _ = self.disconnect(tmp_arena.allocator()) catch {};
        }
        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = cwd,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.AdapterNotFound,
            else => return err,
        };
        _ = self.reg.adopt(self.session_id, self.kind, child) catch |err| {
            child.kill(self.io);
            return err;
        };
        self.seq = 1;
        for (self.events.items) |e| self.gpa.free(e);
        self.events.clearRetainingCapacity();
        self.buf.clearRetainingCapacity();
    }

    pub fn initialize(self: *Session, arena: std.mem.Allocator) ![]const u8 {
        const id = try self.sendRequest(arena, "initialize", "{\"clientID\":\"clanker\",\"adapterID\":\"clanker\",\"linesStartAt1\":true,\"columnsStartAt1\":true,\"pathFormat\":\"path\"}");
        return self.waitResponse(arena, id);
    }

    pub fn launch(self: *Session, arena: std.mem.Allocator, args_json: []const u8) ![]const u8 {
        const id = try self.sendRequest(arena, "launch", args_json);
        var saw_init = false;
        var resp: ?[]const u8 = null;
        var spins: usize = 0;
        while (spins < 64 and (resp == null or !saw_init)) : (spins += 1) {
            const frame = self.readFrame(arena) catch break;
            if (frameIs(frame, "event", "initialized") or frameIs(frame, "type", "event")) {
                try self.events.append(self.gpa, try self.gpa.dupe(u8, frame));
                if (frameIs(frame, "event", "initialized")) saw_init = true;
                continue;
            }
            if (frameRequestSeq(frame) == id) resp = frame;
        }
        if (self.pending_bps) |bp| {
            _ = self.setBreakpoints(arena, bp.source, bp.lines, bp.condition, bp.hit_condition) catch {};
            self.clearPendingBreakpoints();
        }
        return resp orelse "{\"ok\":true}";
    }

    pub fn attach(self: *Session, arena: std.mem.Allocator, args_json: []const u8) ![]const u8 {
        const id = try self.sendRequest(arena, "attach", args_json);
        self.waitEvent(arena, "initialized") catch {};
        return self.waitResponse(arena, id) catch "{\"ok\":true}";
    }

    pub fn setBreakpoints(
        self: *Session,
        arena: std.mem.Allocator,
        source: []const u8,
        lines: []const i64,
        condition: ?[]const u8,
        hit_condition: ?[]const u8,
    ) ![]const u8 {
        if (self.reg.get(self.session_id, self.kind) == null) {
            self.clearPendingBreakpoints();
            self.pending_bps = .{
                .source = try self.gpa.dupe(u8, source),
                .lines = try self.gpa.dupe(i64, lines),
                .condition = if (condition) |c| try self.gpa.dupe(u8, c) else null,
                .hit_condition = if (hit_condition) |c| try self.gpa.dupe(u8, c) else null,
            };
            return "{\"ok\":true,\"queued\":true}";
        }
        var args: std.Io.Writer.Allocating = .init(arena);
        var s = std.json.Stringify{ .writer = &args.writer };
        try s.beginObject();
        try s.objectField("source");
        try s.write(.{ .path = source });
        try s.objectField("breakpoints");
        try s.beginArray();
        for (lines) |ln| {
            try s.beginObject();
            try s.objectField("line");
            try s.write(ln);
            if (condition) |c| {
                try s.objectField("condition");
                try s.write(c);
            }
            if (hit_condition) |c| {
                try s.objectField("hitCondition");
                try s.write(c);
            }
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
        const id = try self.sendRequest(arena, "setBreakpoints", args.written());
        return self.waitResponse(arena, id);
    }

    pub fn simple(self: *Session, arena: std.mem.Allocator, command: []const u8, args_json: []const u8) ![]const u8 {
        const id = try self.sendRequest(arena, command, args_json);
        return self.waitResponse(arena, id);
    }

    pub fn disconnect(self: *Session, arena: std.mem.Allocator) ![]const u8 {
        if (self.reg.get(self.session_id, self.kind) == null) return "{\"ok\":true}";
        const id = self.sendRequest(arena, "disconnect", "{\"terminateDebuggee\":true}") catch 0;
        if (id != 0) _ = self.waitResponse(arena, id) catch {};
        // The adapter was just told to shut down; give it
        // disconnect_timeout_ms to exit on its own before the SIGTERM.
        _ = self.reg.terminateWithin(self.session_id, self.kind, self.disconnect_timeout_ms);
        return "{\"ok\":true}";
    }

    pub fn terminate(self: *Session, arena: std.mem.Allocator) ![]const u8 {
        if (self.reg.get(self.session_id, self.kind) == null) return "{\"ok\":true}";
        const id = self.sendRequest(arena, "terminate", "{}") catch 0;
        if (id != 0) _ = self.waitResponse(arena, id) catch {};
        self.reg.terminate(self.session_id, self.kind);
        return "{\"ok\":true}";
    }
};

pub const HandleOpts = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    reg: *subprocess.Registry,
    session_id: []const u8,
    enabled: bool,
    adapters: []const config_mod.DebugAdapter,
    launch_timeout_ms: u32 = 15_000,
    request_timeout_ms: u32 = 15_000,
    disconnect_timeout_ms: u32 = 3_000,
    /// Test hook: when set, launch uses this argv instead of config.
    override_argv: ?[]const []const u8 = null,
    override_cwd: std.process.Child.Cwd = .inherit,
};

pub fn handle(sess: *Session, opts: HandleOpts, input: []const u8) ![]u8 {
    if (!opts.enabled) return error.DebugDisabled;
    // HandleOpts is the one writer of the session's timeout knobs, so a test
    // can inject them and a live session picks up a config change per call.
    sess.launch_timeout_ms = opts.launch_timeout_ms;
    sess.request_timeout_ms = opts.request_timeout_ms;
    sess.disconnect_timeout_ms = opts.disconnect_timeout_ms;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, opts.arena, input, .{});
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.InvalidInput,
    };
    const op = switch (obj.get("op") orelse return error.MissingOp) {
        .string => |s| s,
        else => return error.MissingOp,
    };

    if (std.mem.eql(u8, op, "launch") or std.mem.eql(u8, op, "attach")) {
        const adapter = switch (obj.get("adapter") orelse return error.MissingAdapter) {
            .string => |s| s,
            else => return error.MissingAdapter,
        };
        const argv = if (opts.override_argv) |a| a else blk: {
            break :blk findAdapter(opts.adapters, adapter) orelse return error.UnknownAdapter;
        };
        try sess.spawnAdapter(argv, opts.override_cwd);
        sess.adapter_name = adapter;
        var args: std.Io.Writer.Allocating = .init(opts.arena);
        var s = std.json.Stringify{ .writer = &args.writer };
        try s.beginObject();
        if (obj.get("program")) |p| {
            if (p == .string) {
                try s.objectField("program");
                try s.write(p.string);
            }
        }
        if (obj.get("args")) |a| {
            try s.objectField("args");
            try s.write(a);
        }
        try s.endObject();
        const body = try runBounded(sess, opts, sess.launch_timeout_ms, .{ .launch = .{ .is_attach = std.mem.eql(u8, op, "attach"), .args_json = args.written() } });
        return wrap(opts.arena, sess, body);
    }

    if (std.mem.eql(u8, op, "set_breakpoints")) {
        const source = switch (obj.get("source") orelse return error.MissingSource) {
            .string => |s| s,
            else => return error.MissingSource,
        };
        var lines: std.ArrayList(i64) = .empty;
        if (obj.get("lines")) |lv| {
            if (lv == .array) {
                for (lv.array.items) |it| {
                    if (it == .integer) try lines.append(opts.arena, it.integer);
                }
            }
        }
        const cond = switch (obj.get("condition") orelse std.json.Value{ .null = {} }) {
            .string => |s| s,
            else => null,
        };
        const hit = switch (obj.get("hitCondition") orelse std.json.Value{ .null = {} }) {
            .string => |s| s,
            else => null,
        };
        const body = try runBounded(sess, opts, sess.request_timeout_ms, .{ .set_breakpoints = .{ .source = source, .lines = lines.items, .condition = cond, .hit_condition = hit } });
        return wrap(opts.arena, sess, body);
    }

    if (std.mem.eql(u8, op, "continue")) return wrap(opts.arena, sess, try boundedSimple(sess, opts, "continue", "{\"threadId\":1}"));
    if (std.mem.eql(u8, op, "step_in")) return wrap(opts.arena, sess, try boundedSimple(sess, opts, "stepIn", "{\"threadId\":1}"));
    if (std.mem.eql(u8, op, "step_out")) return wrap(opts.arena, sess, try boundedSimple(sess, opts, "stepOut", "{\"threadId\":1}"));
    if (std.mem.eql(u8, op, "next")) return wrap(opts.arena, sess, try boundedSimple(sess, opts, "next", "{\"threadId\":1}"));
    if (std.mem.eql(u8, op, "pause")) return wrap(opts.arena, sess, try boundedSimple(sess, opts, "pause", "{\"threadId\":1}"));
    if (std.mem.eql(u8, op, "stack_trace")) {
        const body = try boundedSimple(sess, opts, "stackTrace", "{\"threadId\":1}");
        return flattenStack(opts.arena, sess, body);
    }
    if (std.mem.eql(u8, op, "scopes")) {
        const frame_id = jsonInt(obj, "frame_id") orelse 0;
        var args_buf: [64]u8 = undefined;
        const args = std.fmt.bufPrint(&args_buf, "{{\"frameId\":{d}}}", .{frame_id}) catch "{\"frameId\":0}";
        return wrap(opts.arena, sess, try boundedSimple(sess, opts, "scopes", args));
    }
    if (std.mem.eql(u8, op, "variables")) {
        const ref = jsonInt(obj, "variables_reference") orelse 0;
        var args_buf: [80]u8 = undefined;
        const args = std.fmt.bufPrint(&args_buf, "{{\"variablesReference\":{d}}}", .{ref}) catch "{\"variablesReference\":0}";
        return flattenVars(opts.arena, sess, try boundedSimple(sess, opts, "variables", args));
    }
    if (std.mem.eql(u8, op, "evaluate")) {
        const expr = switch (obj.get("expression") orelse return error.MissingExpression) {
            .string => |s| s,
            else => return error.MissingExpression,
        };
        const frame_id = jsonInt(obj, "frame_id") orelse 0;
        var args: std.Io.Writer.Allocating = .init(opts.arena);
        var s = std.json.Stringify{ .writer = &args.writer };
        try s.beginObject();
        try s.objectField("expression");
        try s.write(expr);
        try s.objectField("frameId");
        try s.write(frame_id);
        try s.objectField("context");
        try s.write("repl");
        try s.endObject();
        return flattenEval(opts.arena, sess, try boundedSimple(sess, opts, "evaluate", args.written()));
    }
    if (std.mem.eql(u8, op, "disconnect")) {
        const out = try wrap(opts.arena, sess, try boundedTeardown(sess, opts, .disconnect));
        dropLive(opts.session_id);
        return out;
    }
    if (std.mem.eql(u8, op, "terminate")) {
        const out = try wrap(opts.arena, sess, try boundedTeardown(sess, opts, .terminate));
        dropLive(opts.session_id);
        return out;
    }
    return error.UnknownOp;
}

fn boundedSimple(sess: *Session, opts: HandleOpts, command: []const u8, args_json: []const u8) ![]const u8 {
    return runBounded(sess, opts, sess.request_timeout_ms, .{ .simple = .{ .command = command, .args_json = args_json } });
}

/// Teardown wants the adapter gone either way: when the op times out, the
/// expiry path has already killed and reaped it, which is that outcome, so
/// the caller gets a success with a note rather than an error.
fn boundedTeardown(sess: *Session, opts: HandleOpts, spec: OpSpec) ![]const u8 {
    return runBounded(sess, opts, sess.request_timeout_ms, spec) catch |err| switch (err) {
        error.RequestTimeout => "{\"ok\":true,\"note\":\"adapter unresponsive; killed\"}",
        else => err,
    };
}

/// One DAP operation as data, so `runBounded` can execute any of them on a
/// watchdogged worker. `launch` covers the whole handshake (initialize, then
/// launch/attach); the rest map 1:1 onto the Session methods.
const OpSpec = union(enum) {
    launch: struct { is_attach: bool, args_json: []const u8 },
    simple: struct { command: []const u8, args_json: []const u8 },
    set_breakpoints: struct { source: []const u8, lines: []const i64, condition: ?[]const u8, hit_condition: ?[]const u8 },
    disconnect,
    terminate,
};

/// The operation on the caller's thread, unbounded. The worker body of
/// `runBounded`, and the fallback when no bound is configured or no
/// concurrency is available.
fn opInline(sess: *Session, arena: std.mem.Allocator, spec: OpSpec) ![]const u8 {
    return switch (spec) {
        .launch => |l| blk: {
            _ = try sess.initialize(arena);
            break :blk if (l.is_attach)
                sess.attach(arena, l.args_json)
            else
                sess.launch(arena, l.args_json);
        },
        .simple => |c| sess.simple(arena, c.command, c.args_json),
        .set_breakpoints => |b| sess.setBreakpoints(arena, b.source, b.lines, b.condition, b.hit_condition),
        .disconnect => sess.disconnect(arena),
        .terminate => sess.terminate(arena),
    };
}

const OpOutcome = struct {
    body: ?[]const u8 = null,
    err: ?anyerror = null,
};

fn opWorker(sess: *Session, arena: std.mem.Allocator, spec: OpSpec, out: *OpOutcome, done: *std.Io.Event) void {
    defer done.set(sess.io);
    out.body = opInline(sess, arena, spec) catch |err| {
        out.err = err;
        return;
    };
}

/// Bounds one DAP operation: `debug.launch_timeout_ms` for the launch
/// handshake, `debug.request_timeout_ms` for everything after it. The spin
/// counts in the wait loops cannot do it: a silent adapter leaves the worker
/// *blocked* inside one `readStreaming` on the stdout pipe, which is not a
/// cancelable syscall — the adapter's exit closing the pipe is what unblocks
/// it (same ordering as `subprocess.waitChildWithin`). So on expiry the
/// adapter is SIGTERMed first, escalating to SIGKILL when the worker is
/// still blocked after a short grace, and only then awaited and reaped.
fn runBounded(sess: *Session, opts: HandleOpts, timeout_ms: u32, spec: OpSpec) ![]const u8 {
    if (timeout_ms == 0) return opInline(sess, opts.arena, spec);
    var outcome: OpOutcome = .{};
    var done: std.Io.Event = .unset;
    var fut = opts.io.concurrent(opWorker, .{ sess, opts.arena, spec, &outcome, &done }) catch {
        // No spare unit of concurrency for the watchdog; run unbounded
        // rather than refuse an operation that would likely have succeeded.
        return opInline(sess, opts.arena, spec);
    };
    const deadline: std.Io.Clock.Timestamp = .fromNow(opts.io, .{
        .clock = .awake,
        .raw = .{ .nanoseconds = @as(i96, timeout_ms) * std.time.ns_per_ms },
    });
    var expired = false;
    while (!done.isSet()) {
        done.waitTimeout(opts.io, .{ .deadline = deadline }) catch |err| switch (err) {
            // Spurious wakeups report Timeout too; the deadline decides.
            error.Timeout => {
                if (done.isSet()) break;
                if (deadline.durationFromNow(opts.io).raw.nanoseconds > 0) continue;
                expired = true;
                break;
            },
            error.Canceled => {
                expired = true;
                break;
            },
        };
    }
    if (expired) {
        if (sess.reg.get(sess.session_id, sess.kind)) |pid| {
            std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        }
        const grace: std.Io.Clock.Timestamp = .fromNow(opts.io, .{
            .clock = .awake,
            .raw = .{ .nanoseconds = @as(i96, 2_000) * std.time.ns_per_ms },
        });
        while (!done.isSet()) {
            done.waitTimeout(opts.io, .{ .deadline = grace }) catch |err| switch (err) {
                error.Timeout => {
                    if (done.isSet()) break;
                    if (grace.durationFromNow(opts.io).raw.nanoseconds > 0) continue;
                    // Still blocked: the adapter ignored SIGTERM, so it still
                    // holds the pipe open. SIGKILL closes it unconditionally.
                    if (sess.reg.get(sess.session_id, sess.kind)) |pid| {
                        std.posix.kill(pid, std.posix.SIG.KILL) catch {};
                    }
                    break;
                },
                error.Canceled => break,
            };
        }
        fut.await(opts.io);
        // Reap and drop the row so the guest sees a clean timeout, not a
        // half-dead session a later op trips over.
        sess.reg.terminate(sess.session_id, sess.kind);
        return switch (spec) {
            .launch => error.LaunchTimeout,
            else => error.RequestTimeout,
        };
    }
    fut.await(opts.io);
    if (outcome.err) |err| return err;
    return outcome.body orelse "{\"ok\":true}";
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        else => null,
    };
}

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |n| n,
        else => null,
    };
}

fn findAdapter(adapters: []const config_mod.DebugAdapter, name: []const u8) ?[]const []const u8 {
    for (adapters) |a| {
        if (std.mem.eql(u8, a.name, name)) return a.command;
    }
    return null;
}

fn wrap(arena: std.mem.Allocator, sess: *Session, body: []const u8) ![]u8 {
    return renderResult(arena, body, try sess.takeEvents(arena));
}

fn renderResult(arena: std.mem.Allocator, body: []const u8, events: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("{\"ok\":true,\"body\":");
    if (body.len > 0 and (body[0] == '{' or body[0] == '[')) {
        try out.writer.writeAll(body);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"events\":[");
    for (events, 0..) |e, i| {
        if (i != 0) try out.writer.writeByte(',');
        if (e.len > 0 and e[0] == '{') try out.writer.writeAll(e) else try out.writer.writeAll("null");
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

// The adapter answers with a DAP envelope around the payload, but a bare body
// is also accepted; the flatteners want the payload object either way.
fn replyBodyObject(arena: std.mem.Allocator, body: []const u8) ?std.json.ObjectMap {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    const body_obj = switch (parsed) {
        .object => |o| o.get("body") orelse parsed,
        else => parsed,
    };
    return switch (body_obj) {
        .object => |o| o,
        else => null,
    };
}

fn flattenStack(arena: std.mem.Allocator, sess: *Session, body: []const u8) ![]u8 {
    const events = try sess.takeEvents(arena);
    const obj = replyBodyObject(arena, body) orelse return renderResult(arena, body, events);
    const frames_v = obj.get("stackFrames") orelse return renderResult(arena, body, events);
    var out: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("frames");
    try s.beginArray();
    if (frames_v == .array) {
        for (frames_v.array.items) |f| {
            if (f != .object) continue;
            const fo = f.object;
            try s.beginObject();
            try s.objectField("id");
            try s.write(jsonInt(fo, "id") orelse 0);
            try s.objectField("name");
            try s.write(jsonStr(fo, "name") orelse "");
            if (fo.get("source")) |src| {
                if (src == .object) {
                    if (src.object.get("path") orelse src.object.get("name")) |p| {
                        if (p == .string) {
                            try s.objectField("source");
                            try s.write(p.string);
                        }
                    }
                }
            }
            try s.objectField("line");
            try s.write(jsonInt(fo, "line") orelse 0);
            try s.endObject();
        }
    }
    try s.endArray();
    try s.objectField("events");
    try writeEvents(&s, events);
    try s.endObject();
    return out.toOwnedSlice();
}

fn flattenVars(arena: std.mem.Allocator, sess: *Session, body: []const u8) ![]u8 {
    const events = try sess.takeEvents(arena);
    const obj = replyBodyObject(arena, body) orelse return renderResult(arena, body, events);
    const vars_v = obj.get("variables") orelse return renderResult(arena, body, events);
    var out: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("variables");
    try s.beginArray();
    if (vars_v == .array) {
        for (vars_v.array.items) |v| {
            if (v != .object) continue;
            const vo = v.object;
            try s.beginObject();
            try s.objectField("name");
            try s.write(jsonStr(vo, "name") orelse "");
            try s.objectField("value");
            try s.write(jsonStr(vo, "value") orelse "");
            try s.objectField("type");
            try s.write(jsonStr(vo, "type") orelse "");
            try s.objectField("variables_reference");
            try s.write(jsonInt(vo, "variablesReference") orelse 0);
            try s.endObject();
        }
    }
    try s.endArray();
    try s.objectField("events");
    try writeEvents(&s, events);
    try s.endObject();
    return out.toOwnedSlice();
}

fn flattenEval(arena: std.mem.Allocator, sess: *Session, body: []const u8) ![]u8 {
    const events = try sess.takeEvents(arena);
    const obj = replyBodyObject(arena, body) orelse return renderResult(arena, body, events);
    var out: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("result");
    try s.write(jsonStr(obj, "result") orelse "");
    try s.objectField("type");
    try s.write(jsonStr(obj, "type") orelse "");
    try s.objectField("events");
    try writeEvents(&s, events);
    try s.endObject();
    return out.toOwnedSlice();
}

fn writeEvents(s: *std.json.Stringify, events: []const []const u8) !void {
    try s.beginArray();
    for (events, 0..) |e, i| {
        if (i != 0) try s.writer.*.writeByte(',');
        // Events are raw JSON objects; embed them directly, matching renderResult,
        // so the events array carries objects, never double-encoded strings.
        if (e.len > 0 and e[0] == '{') try s.writer.*.writeAll(e) else try s.writer.*.writeAll("null");
    }
    try s.endArray();
}

pub fn errorJson(arena: std.mem.Allocator, msg: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{{\"ok\":false,\"error\":{f}}}", .{std.json.fmt(msg, .{})}) catch
        "{\"ok\":false,\"error\":\"debug failed\"}";
}

const Live = struct {
    mu: std.atomic.Mutex = .unlocked,
    map: std.StringHashMapUnmanaged(*Session) = .empty,
    gpa: std.mem.Allocator = undefined,
    ready: bool = false,

    fn lock(self: *Live) void {
        while (!self.mu.tryLock()) {
            std.Thread.yield() catch {};
        }
    }
};

var live: Live = .{};

/// One DAP session object per clanker session, so seq / leftover bytes /
/// queued events survive across tool calls. Tests should pass their own
/// `Session` to `handle` instead.
pub fn liveSession(gpa: std.mem.Allocator, io: std.Io, reg: *subprocess.Registry, session_id: []const u8) !*Session {
    live.lock();
    defer live.mu.unlock();
    if (!live.ready) {
        live.gpa = gpa;
        live.ready = true;
    }
    if (live.map.get(session_id)) |s| return s;
    const s = try gpa.create(Session);
    s.* = .{
        .io = io,
        .gpa = gpa,
        .reg = reg,
        .session_id = try gpa.dupe(u8, session_id),
    };
    try live.map.put(gpa, s.session_id, s);
    return s;
}

pub fn dropLive(session_id: []const u8) void {
    live.lock();
    defer live.mu.unlock();
    if (live.map.fetchRemove(session_id)) |kv| {
        kv.value.deinit();
        live.gpa.free(kv.value.session_id);
        live.gpa.destroy(kv.value);
    }
}

pub const fake_adapter_src =
    \\import json, sys
    \\
    \\def read_frame():
    \\    headers = {}
    \\    while True:
    \\        line = sys.stdin.buffer.readline()
    \\        if not line:
    \\            return None
    \\        if line in (b"\r\n", b"\n"):
    \\            break
    \\        if b":" in line:
    \\            k, v = line.decode().split(":", 1)
    \\            headers[k.strip().lower()] = v.strip()
    \\    n = int(headers.get("content-length", "0"))
    \\    body = sys.stdin.buffer.read(n)
    \\    return json.loads(body.decode())
    \\
    \\def send(obj):
    \\    raw = json.dumps(obj).encode()
    \\    sys.stdout.buffer.write(f"Content-Length: {len(raw)}\r\n\r\n".encode() + raw)
    \\    sys.stdout.buffer.flush()
    \\
    \\seq = 1
    \\while True:
    \\    req = read_frame()
    \\    if req is None:
    \\        break
    \\    cmd = req.get("command")
    \\    rid = req.get("seq", 0)
    \\    seq += 1
    \\    if cmd == "initialize":
    \\        send({"seq": seq, "type": "response", "request_seq": rid, "command": cmd, "success": True, "body": {"supportsConfigurationDoneRequest": True}})
    \\    elif cmd in ("launch", "attach"):
    \\        send({"seq": seq, "type": "event", "event": "initialized", "body": {}})
    \\        seq += 1
    \\        send({"seq": seq, "type": "response", "request_seq": rid, "command": cmd, "success": True, "body": {}})
    \\    elif cmd == "setBreakpoints":
    \\        args = req.get("arguments") or {}
    \\        bps = []
    \\        for i, bp in enumerate(args.get("breakpoints") or []):
    \\            bps.append({"id": i + 1, "verified": True, "line": bp.get("line"), "condition": bp.get("condition"), "hitCondition": bp.get("hitCondition")})
    \\        send({"seq": seq, "type": "response", "request_seq": rid, "command": cmd, "success": True, "body": {"breakpoints": bps}})
    \\    elif cmd == "continue":
    \\        send({"seq": seq, "type": "response", "request_seq": rid, "command": cmd, "success": True, "body": {"allThreadsContinued": True}})
    \\        seq += 1
    \\        send({"seq": seq, "type": "event", "event": "stopped", "body": {"reason": "breakpoint", "threadId": 1}})
    \\    elif cmd == "stackTrace":
    \\        send({"seq": seq, "type": "response", "request_seq": rid, "command": cmd, "success": True, "body": {"stackFrames": [{"id": 1, "name": "main", "source": {"path": "src/main.c"}, "line": 42}], "totalFrames": 1}})
    \\    elif cmd == "scopes":
    \\        send({"seq": seq, "type": "response", "request_seq": rid, "command": cmd, "success": True, "body": {"scopes": [{"name": "Locals", "variablesReference": 3, "expensive": False}]}})
    \\    elif cmd == "variables":
    \\        send({"seq": seq, "type": "response", "request_seq": rid, "command": cmd, "success": True, "body": {"variables": [{"name": "x", "value": "10", "type": "int", "variablesReference": 0}]}})
    \\    elif cmd == "evaluate":
    \\        expr = (req.get("arguments") or {}).get("expression", "")
    \\        send({"seq": seq, "type": "response", "request_seq": rid, "command": cmd, "success": True, "body": {"result": "11" if expr == "x + 1" else expr, "type": "int"}})
    \\    elif cmd in ("disconnect", "terminate", "configurationDone", "stepIn", "stepOut", "next", "pause"):
    \\        send({"seq": seq, "type": "response", "request_seq": rid, "command": cmd, "success": True, "body": {}})
    \\        if cmd in ("disconnect", "terminate"):
    \\            break
    \\    else:
    \\        send({"seq": seq, "type": "response", "request_seq": rid, "command": cmd, "success": False, "message": "unknown"})
;

fn testIo() std.Io.Threaded {
    return std.Io.Threaded.init(std.testing.allocator, .{});
}

test "DAP framing encodes Content-Length and decodes it back" {
    const payload = "{\"seq\":1,\"type\":\"request\"}";
    const frame = try encodeFrame(std.testing.allocator, payload);
    defer std.testing.allocator.free(frame);
    try std.testing.expect(std.mem.startsWith(u8, frame, "Content-Length: "));
    const dec = decodeFrame(frame) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(payload, dec.payload);
    try std.testing.expectEqual(frame.len, dec.consumed);
}

test "DAP decode waits until the full body is present" {
    const partial = "Content-Length: 10\r\n\r\n{\"x\":";
    try std.testing.expect(decodeFrame(partial) == null);
    const full = "Content-Length: 7\r\n\r\n{\"a\":1}extra";
    const dec = decodeFrame(full).?;
    try std.testing.expectEqualStrings("{\"a\":1}", dec.payload);
    try std.testing.expectEqual(@as(usize, 28), dec.consumed);
}

test "debug.enabled = false refuses without spawning" {
    var threaded = testIo();
    defer threaded.deinit();
    var reg = subprocess.Registry.init(std.testing.allocator, threaded.io());
    defer reg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var sess = Session{
        .io = threaded.io(),
        .gpa = std.testing.allocator,
        .reg = &reg,
        .session_id = "dbg-off",
    };
    defer sess.deinit();
    try std.testing.expectError(error.DebugDisabled, handle(&sess, .{
        .io = threaded.io(),
        .gpa = std.testing.allocator,
        .arena = arena_state.allocator(),
        .reg = &reg,
        .session_id = "dbg-off",
        .enabled = false,
        .adapters = &.{},
    }, "{\"op\":\"launch\",\"adapter\":\"lldb\"}"));
    try std.testing.expectEqual(@as(usize, 0), reg.count());
}

test "missing adapter is an error listing nothing to spawn" {
    var threaded = testIo();
    defer threaded.deinit();
    var reg = subprocess.Registry.init(std.testing.allocator, threaded.io());
    defer reg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var sess = Session{
        .io = threaded.io(),
        .gpa = std.testing.allocator,
        .reg = &reg,
        .session_id = "dbg-miss",
    };
    defer sess.deinit();
    try std.testing.expectError(error.MissingAdapter, handle(&sess, .{
        .io = threaded.io(),
        .gpa = std.testing.allocator,
        .arena = arena_state.allocator(),
        .reg = &reg,
        .session_id = "dbg-miss",
        .enabled = true,
        .adapters = &.{},
    }, "{\"op\":\"launch\"}"));
    try std.testing.expectError(error.UnknownAdapter, handle(&sess, .{
        .io = threaded.io(),
        .gpa = std.testing.allocator,
        .arena = arena_state.allocator(),
        .reg = &reg,
        .session_id = "dbg-miss",
        .enabled = true,
        .adapters = &.{},
    }, "{\"op\":\"launch\",\"adapter\":\"nope\"}"));
}

test "fake adapter: launch, breakpoint, continue, stack, variables, evaluate" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    var reg = subprocess.Registry.init(std.testing.allocator, io);
    defer reg.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(io, .{ .sub_path = "fake_dap.py", .data = fake_adapter_src }) catch return error.SkipZigTest;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sess = Session{
        .io = io,
        .gpa = std.testing.allocator,
        .reg = &reg,
        .session_id = "dbg-1",
    };
    defer sess.deinit();

    const argv = [_][]const u8{ "python3", "fake_dap.py" };
    const opts = HandleOpts{
        .io = io,
        .gpa = std.testing.allocator,
        .arena = arena,
        .reg = &reg,
        .session_id = "dbg-1",
        .enabled = true,
        .adapters = &.{},
        .override_argv = &argv,
        .override_cwd = .{ .dir = tmp.dir },
    };

    const launched = handle(&sess, opts, "{\"op\":\"launch\",\"adapter\":\"fake\",\"program\":\"./myapp\"}") catch |err| switch (err) {
        error.AdapterNotFound, error.FileNotFound => return error.SkipZigTest,
        else => {
            std.debug.print("fake adapter launch failed: {s}\n", .{@errorName(err)});
            return err;
        },
    };
    try std.testing.expect(std.mem.find(u8, launched, "\"ok\":true") != null);

    const bps = try handle(&sess, opts,
        \\{"op":"set_breakpoints","source":"src/main.c","lines":[42],"condition":"x > 0","hitCondition":"3"}
    );
    try std.testing.expect(std.mem.find(u8, bps, "\"ok\":true") != null);

    const cont = try handle(&sess, opts, "{\"op\":\"continue\"}");
    try std.testing.expect(std.mem.find(u8, cont, "\"ok\":true") != null);

    const stack = try handle(&sess, opts, "{\"op\":\"stack_trace\"}");
    try std.testing.expect(std.mem.find(u8, stack, "\"name\":\"main\"") != null);
    try std.testing.expect(std.mem.find(u8, stack, "src/main.c") != null);
    try std.testing.expect(std.mem.find(u8, stack, "42") != null);

    const vars = try handle(&sess, opts, "{\"op\":\"variables\",\"variables_reference\":3}");
    try std.testing.expect(std.mem.find(u8, vars, "\"name\":\"x\"") != null);
    try std.testing.expect(std.mem.find(u8, vars, "\"value\":\"10\"") != null);

    const ev = try handle(&sess, opts, "{\"op\":\"evaluate\",\"expression\":\"x + 1\",\"frame_id\":1}");
    try std.testing.expect(std.mem.find(u8, ev, "\"result\":\"11\"") != null);

    // Same sequence a second time on a fresh launch: consistent, not a flake.
    const launched2 = try handle(&sess, opts, "{\"op\":\"launch\",\"adapter\":\"fake\",\"program\":\"./myapp\"}");
    try std.testing.expect(std.mem.find(u8, launched2, "\"ok\":true") != null);
    const stack2 = try handle(&sess, opts, "{\"op\":\"stack_trace\"}");
    try std.testing.expect(std.mem.find(u8, stack2, "\"name\":\"main\"") != null);

    const disc = try handle(&sess, opts, "{\"op\":\"disconnect\"}");
    try std.testing.expect(std.mem.find(u8, disc, "\"ok\":true") != null);
    try std.testing.expect(reg.get("dbg-1", "dap") == null);
}

test "silent adapter: launch is bounded by launch_timeout_ms and reaped" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    var reg = subprocess.Registry.init(std.testing.allocator, io);
    defer reg.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Reads requests but never answers one: without the bound, launch blocks
    // forever inside readStreaming on the stdout pipe.
    tmp.dir.writeFile(io, .{ .sub_path = "silent_dap.py", .data = "import sys\nwhile sys.stdin.buffer.read(4096):\n    pass\n" }) catch return error.SkipZigTest;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var sess = Session{
        .io = io,
        .gpa = std.testing.allocator,
        .reg = &reg,
        .session_id = "dbg-silent",
    };
    defer sess.deinit();

    const argv = [_][]const u8{ "python3", "silent_dap.py" };
    const got = handle(&sess, .{
        .io = io,
        .gpa = std.testing.allocator,
        .arena = arena_state.allocator(),
        .reg = &reg,
        .session_id = "dbg-silent",
        .enabled = true,
        .adapters = &.{},
        .launch_timeout_ms = 300,
        .override_argv = &argv,
        .override_cwd = .{ .dir = tmp.dir },
    }, "{\"op\":\"launch\",\"adapter\":\"fake\",\"program\":\"./myapp\"}");
    if (got) |_| return error.TestExpectedEqual else |err| switch (err) {
        error.LaunchTimeout => {},
        error.AdapterNotFound, error.FileNotFound => return error.SkipZigTest,
        else => return err,
    }
    // The expired launch reaped the adapter and dropped the registry row.
    try std.testing.expect(reg.get("dbg-silent", "dap") == null);
}

test "mute-after-launch adapter: post-launch ops are bounded by request_timeout_ms" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    var reg = subprocess.Registry.init(std.testing.allocator, io);
    defer reg.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Answers initialize and launch, then keeps reading but never answers
    // again: without the bound, `continue` blocks forever in readStreaming.
    const mute_src =
        \\import json, sys
        \\def rf():
        \\    h = {}
        \\    while True:
        \\        line = sys.stdin.buffer.readline()
        \\        if not line: return None
        \\        if line in (b"\r\n", b"\n"): break
        \\        if b":" in line:
        \\            k, v = line.decode().split(":", 1); h[k.strip().lower()] = v.strip()
        \\    return json.loads(sys.stdin.buffer.read(int(h.get("content-length", "0"))).decode())
        \\def send(o):
        \\    raw = json.dumps(o).encode()
        \\    sys.stdout.buffer.write(f"Content-Length: {len(raw)}\r\n\r\n".encode() + raw); sys.stdout.buffer.flush()
        \\seq = 1
        \\while True:
        \\    r = rf()
        \\    if r is None: break
        \\    c = r.get("command"); rid = r.get("seq", 0); seq += 1
        \\    if c == "initialize":
        \\        send({"seq": seq, "type": "response", "request_seq": rid, "command": c, "success": True, "body": {}})
        \\    elif c == "launch":
        \\        send({"seq": seq, "type": "event", "event": "initialized", "body": {}}); seq += 1
        \\        send({"seq": seq, "type": "response", "request_seq": rid, "command": c, "success": True, "body": {}})
    ;
    tmp.dir.writeFile(io, .{ .sub_path = "mute_dap.py", .data = mute_src }) catch return error.SkipZigTest;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var sess = Session{
        .io = io,
        .gpa = std.testing.allocator,
        .reg = &reg,
        .session_id = "dbg-mute",
    };
    defer sess.deinit();

    const argv = [_][]const u8{ "python3", "mute_dap.py" };
    const opts = HandleOpts{
        .io = io,
        .gpa = std.testing.allocator,
        .arena = arena_state.allocator(),
        .reg = &reg,
        .session_id = "dbg-mute",
        .enabled = true,
        .adapters = &.{},
        .request_timeout_ms = 300,
        .override_argv = &argv,
        .override_cwd = .{ .dir = tmp.dir },
    };

    const launched = handle(&sess, opts, "{\"op\":\"launch\",\"adapter\":\"fake\",\"program\":\"./myapp\"}") catch |err| switch (err) {
        error.AdapterNotFound, error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expect(std.mem.find(u8, launched, "\"ok\":true") != null);

    const got = handle(&sess, opts, "{\"op\":\"continue\"}");
    if (got) |_| return error.TestExpectedEqual else |err| switch (err) {
        error.RequestTimeout => {},
        else => return err,
    }
    // The expired request reaped the adapter and dropped the registry row.
    try std.testing.expect(reg.get("dbg-mute", "dap") == null);
}

test "seq numbers increase across requests" {
    var sess = Session{
        .io = undefined,
        .gpa = std.testing.allocator,
        .reg = undefined,
        .session_id = "seq",
    };
    defer sess.deinit();
    try std.testing.expectEqual(@as(u32, 1), sess.nextSeq());
    try std.testing.expectEqual(@as(u32, 2), sess.nextSeq());
    try std.testing.expectEqual(@as(u32, 3), sess.nextSeq());
}

test "pending breakpoints are freed on deinit and on re-queue" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    var reg = subprocess.Registry.init(std.testing.allocator, io);
    defer reg.deinit();

    var sess = Session{
        .io = io,
        .gpa = std.testing.allocator,
        .reg = &reg,
        .session_id = "dbg-pending",
    };
    defer sess.deinit();

    const lines = [_]i64{ 42, 43 };
    const queued = try sess.setBreakpoints(std.testing.allocator, "src/main.zig", lines[0..], "x > 0", "2");
    try std.testing.expect(std.mem.find(u8, queued, "\"queued\":true") != null);

    // Re-queue replaces the earlier pending breakpoints without leaking them.
    const requeued = try sess.setBreakpoints(std.testing.allocator, "src/debug/dap.zig", lines[0..], null, null);
    try std.testing.expect(std.mem.find(u8, requeued, "\"queued\":true") != null);
}

test "writeEvents embeds raw event objects instead of stringifying them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{} };
    try writeEvents(&s, &.{"{\"seq\":2,\"type\":\"event\",\"event\":\"stopped\"}"});
    try std.testing.expectEqualStrings("[{\"seq\":2,\"type\":\"event\",\"event\":\"stopped\"}]", out.written());
}

test "DAP decode refuses an oversized declared frame before arithmetic" {
    var evil_buf: [64]u8 = undefined;
    const evil = try std.fmt.bufPrint(&evil_buf, "Content-Length: {d}\r\n\r\n", .{std.math.maxInt(usize)});
    try std.testing.expect(decodeFrame(evil) == null);
}
