//! ACP v1 *client*: clanker drives a vendor agent over stdio (ADR 0032).
//!
//! The inverse of `server.zig` (`clanker acp`). One JSON-RPC 2.0 message per
//! line. The client sends initialize → authenticate (when the agent lists
//! methods) → session/new → session/prompt, consumes session/update, and
//! answers session/request_permission. fs/* and terminal/* are refused.
//!
//! Transport is a vtable so tests can drive the shipped client against an
//! in-process fake agent (pipes / mailboxes) without a live vendor CLI.

const std = @import("std");
const json = std.json;
const log = @import("../util/log.zig");
const subprocess = @import("../agent/subprocess.zig");
const vendor = @import("vendor.zig");

const protocol_version: u32 = 1;
const client_name = "clanker";

pub const Transport = struct {
    ptr: *anyopaque,
    writeLineFn: *const fn (ptr: *anyopaque, line: []const u8) anyerror!void,
    readLineFn: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator) anyerror![]u8,
    cancelFn: *const fn (ptr: *anyopaque) void,

    pub fn writeLine(self: Transport, line: []const u8) !void {
        return self.writeLineFn(self.ptr, line);
    }

    pub fn readLine(self: Transport, alloc: std.mem.Allocator) ![]u8 {
        return self.readLineFn(self.ptr, alloc);
    }

    pub fn cancel(self: Transport) void {
        self.cancelFn(self.ptr);
    }
};

pub const Update = struct {
    kind: []const u8,
    text: []const u8 = "",
    tool_name: []const u8 = "",
};

pub const PromptResult = struct {
    session_id: []const u8,
    answer: []const u8,
    stop_reason: []const u8,
    updates: []Update,
    methods: []const []const u8,
    permission_replies: u32,
};

pub const Error = error{
    Hang,
    HandshakeFailed,
    CapabilityRefused,
    Protocol,
    Closed,
};

pub const Client = struct {
    alloc: std.mem.Allocator,
    transport: Transport,
    timeout_ms: u64 = 120_000,
    next_id: i64 = 1,
    /// Request methods sent, in order. Tests assert initialize → session/new
    /// → session/prompt (authenticate is inserted when the agent requires it).
    methods_sent: std.ArrayList([]const u8) = .empty,
    updates: std.ArrayList(Update) = .empty,
    permission_replies: u32 = 0,
    answer_buf: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Client) void {
        self.methods_sent.deinit(self.alloc);
        self.updates.deinit(self.alloc);
        self.answer_buf.deinit(self.alloc);
    }

    /// Full session: initialize, optional authenticate, session/new, prompt.
    pub fn prompt(self: *Client, cwd: []const u8, text: []const u8) !PromptResult {
        const init_result = try self.rpc("initialize", try self.initializeParams());
        const needs_auth = authRequired(self.alloc, init_result);
        if (needs_auth) {
            const method_id = firstAuthMethodId(self.alloc, init_result) orelse "default";
            const auth_params = try std.fmt.allocPrint(self.alloc, "{{\"methodId\":{f}}}", .{std.json.fmt(method_id, .{})});
            _ = try self.rpc("authenticate", auth_params);
        }
        const new_params = try std.fmt.allocPrint(
            self.alloc,
            "{{\"cwd\":{f},\"mcpServers\":[]}}",
            .{std.json.fmt(cwd, .{})},
        );
        const new_result = try self.rpc("session/new", new_params);
        const session_id = sessionIdOf(self.alloc, new_result) orelse return Error.HandshakeFailed;
        const prompt_params = try std.fmt.allocPrint(
            self.alloc,
            "{{\"sessionId\":{f},\"prompt\":[{{\"type\":\"text\",\"text\":{f}}}]}}",
            .{ std.json.fmt(session_id, .{}), std.json.fmt(text, .{}) },
        );
        const prompt_result = self.rpc("session/prompt", prompt_params) catch |err| switch (err) {
            error.Timeout, Error.Hang => return Error.Hang,
            else => return err,
        };
        const stop = stopReasonOf(self.alloc, prompt_result) orelse "end_turn";
        return .{
            .session_id = try self.alloc.dupe(u8, session_id),
            .answer = self.answer_buf.items,
            .stop_reason = try self.alloc.dupe(u8, stop),
            .updates = self.updates.items,
            .methods = self.methods_sent.items,
            .permission_replies = self.permission_replies,
        };
    }

    fn initializeParams(self: *Client) ![]const u8 {
        return std.fmt.allocPrint(self.alloc,
            \\{{"protocolVersion":{d},"clientInfo":{{"name":"{s}","version":"0"}},"clientCapabilities":{{"fs":{{"readTextFile":false,"writeTextFile":false}},"terminal":false}}}}
        , .{ protocol_version, client_name });
    }

    fn rpc(self: *Client, method: []const u8, params: []const u8) ![]const u8 {
        const id = self.next_id;
        self.next_id += 1;
        const line = try std.fmt.allocPrint(
            self.alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":{f},\"params\":{s}}}",
            .{ id, std.json.fmt(method, .{}), params },
        );
        try self.methods_sent.append(self.alloc, try self.alloc.dupe(u8, method));
        try self.transport.writeLine(line);
        return self.waitResponse(id);
    }

    fn waitResponse(self: *Client, want_id: i64) ![]const u8 {
        const deadline = nowMs() + @as(i64, @intCast(self.timeout_ms));
        while (true) {
            if (nowMs() >= deadline) {
                self.transport.cancel();
                return Error.Hang;
            }
            const raw = self.transport.readLine(self.alloc) catch |err| switch (err) {
                error.Timeout, Error.Hang => {
                    self.transport.cancel();
                    return Error.Hang;
                },
                error.Closed, error.EndOfStream, error.KernelExited => return Error.Closed,
                else => return err,
            };
            const parsed = json.parseFromSliceLeaky(json.Value, self.alloc, raw, .{ .ignore_unknown_fields = true }) catch
                return Error.Protocol;
            if (parsed != .object) return Error.Protocol;
            const obj = parsed.object;
            if (obj.get("method")) |m| if (m == .string) {
                try self.handleIncoming(obj, m.string, obj.get("id"));
                continue;
            };
            const id_val = obj.get("id") orelse continue;
            if (idAsInt(id_val) != want_id) continue;
            if (obj.get("error")) |_| return Error.HandshakeFailed;
            if (obj.get("result")) |r| return try encodeValue(self.alloc, r);
            return Error.Protocol;
        }
    }

    fn handleIncoming(self: *Client, obj: json.ObjectMap, method: []const u8, id: ?json.Value) !void {
        if (std.mem.eql(u8, method, "session/update")) {
            try self.consumeUpdate(obj.get("params"));
            return;
        }
        if (id == null) return;
        if (std.mem.eql(u8, method, "session/request_permission")) {
            try self.replyPermission(id.?, obj.get("params"));
            return;
        }
        if (std.mem.startsWith(u8, method, "fs/") or std.mem.startsWith(u8, method, "terminal/")) {
            try self.replyError(id.?, -32601, "capability not supported");
            return Error.CapabilityRefused;
        }
        try self.replyError(id.?, -32601, "Method not found");
    }

    fn consumeUpdate(self: *Client, params: ?json.Value) !void {
        const p = params orelse return;
        if (p != .object) return;
        const update = p.object.get("update") orelse return;
        if (update != .object) return;
        const kind_val = update.object.get("sessionUpdate") orelse return;
        const kind = if (kind_val == .string) kind_val.string else return;
        var text: []const u8 = "";
        var tool_name: []const u8 = "";
        if (update.object.get("content")) |c| {
            text = textOf(c);
        }
        if (update.object.get("title")) |t| if (t == .string) {
            tool_name = t.string;
        };
        if (text.len > 0) try self.answer_buf.appendSlice(self.alloc, text);
        try self.updates.append(self.alloc, .{
            .kind = try self.alloc.dupe(u8, kind),
            .text = try self.alloc.dupe(u8, text),
            .tool_name = try self.alloc.dupe(u8, tool_name),
        });
    }

    fn replyPermission(self: *Client, id: json.Value, params: ?json.Value) !void {
        const option_id = pickAllowOption(params) orelse "allow-once";
        var id_buf: [64]u8 = undefined;
        var id_w: std.Io.Writer = .fixed(&id_buf);
        try json.Stringify.value(id, .{}, &id_w);
        const line = try std.fmt.allocPrint(
            self.alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"outcome\":{{\"outcome\":\"selected\",\"optionId\":{f}}}}}}}",
            .{ id_buf[0..id_w.end], std.json.fmt(option_id, .{}) },
        );
        try self.transport.writeLine(line);
        self.permission_replies += 1;
    }

    fn replyError(self: *Client, id: json.Value, code: i64, message: []const u8) !void {
        var id_buf: [64]u8 = undefined;
        var id_w: std.Io.Writer = .fixed(&id_buf);
        try json.Stringify.value(id, .{}, &id_w);
        const line = try std.fmt.allocPrint(
            self.alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":{f}}}}}",
            .{ id_buf[0..id_w.end], code, std.json.fmt(message, .{}) },
        );
        try self.transport.writeLine(line);
    }
};

fn idAsInt(v: json.Value) i64 {
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch -1,
        else => -1,
    };
}

fn encodeValue(alloc: std.mem.Allocator, v: json.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    var s = json.Stringify{ .writer = &out.writer, .options = .{} };
    try s.write(v);
    return out.toOwnedSlice();
}

fn authRequired(alloc: std.mem.Allocator, result_json: []const u8) bool {
    const parsed = json.parseFromSliceLeaky(json.Value, alloc, result_json, .{ .ignore_unknown_fields = true }) catch return false;
    if (parsed != .object) return false;
    const methods = parsed.object.get("authMethods") orelse return false;
    return methods == .array and methods.array.items.len > 0;
}

fn firstAuthMethodId(alloc: std.mem.Allocator, result_json: []const u8) ?[]const u8 {
    const parsed = json.parseFromSliceLeaky(json.Value, alloc, result_json, .{ .ignore_unknown_fields = true }) catch return null;
    if (parsed != .object) return null;
    const methods = parsed.object.get("authMethods") orelse return null;
    if (methods != .array or methods.array.items.len == 0) return null;
    const first = methods.array.items[0];
    if (first != .object) return null;
    const id = first.object.get("id") orelse return null;
    return if (id == .string) id.string else null;
}

fn sessionIdOf(alloc: std.mem.Allocator, result_json: []const u8) ?[]const u8 {
    const parsed = json.parseFromSliceLeaky(json.Value, alloc, result_json, .{ .ignore_unknown_fields = true }) catch return null;
    if (parsed != .object) return null;
    const sid = parsed.object.get("sessionId") orelse return null;
    return if (sid == .string) sid.string else null;
}

fn stopReasonOf(alloc: std.mem.Allocator, result_json: []const u8) ?[]const u8 {
    const parsed = json.parseFromSliceLeaky(json.Value, alloc, result_json, .{ .ignore_unknown_fields = true }) catch return null;
    if (parsed != .object) return null;
    const sr = parsed.object.get("stopReason") orelse return null;
    return if (sr == .string) sr.string else null;
}

fn textOf(v: json.Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        .object => |o| blk: {
            if (o.get("text")) |t| if (t == .string) break :blk t.string;
            break :blk "";
        },
        else => "",
    };
}

fn pickAllowOption(params: ?json.Value) ?[]const u8 {
    const p = params orelse return null;
    if (p != .object) return null;
    const options = p.object.get("options") orelse return null;
    if (options != .array) return null;
    var fallback: ?[]const u8 = null;
    for (options.array.items) |item| {
        if (item != .object) continue;
        const oid = item.object.get("optionId") orelse continue;
        if (oid != .string) continue;
        if (fallback == null) fallback = oid.string;
        const kind = item.object.get("kind");
        if (kind) |k| if (k == .string) {
            if (std.mem.startsWith(u8, k.string, "allow")) return oid.string;
        };
        if (std.mem.startsWith(u8, oid.string, "allow")) return oid.string;
    }
    return fallback;
}

/// Spawn a vendor ACP agent over stdio and adopt it into the process table.
/// Native harness spawn — not ck_exec, not ck_job.
pub fn spawnTransport(
    io: std.Io,
    gpa: std.mem.Allocator,
    reg: *subprocess.Registry,
    session_id: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
) !ChildTransport {
    _ = vendor;
    if (argv.len == 0) return error.MissingCommand;
    log.log(.info, "acp-client: spawning {s} ({d} arg(s)); credentials stay in the child", .{ argv[0], argv.len });
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd.len > 0) .{ .path = cwd } else .inherit,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.AdapterNotFound,
        else => return err,
    };
    _ = reg.adopt(session_id, "acp", child) catch |err| {
        child.kill(io);
        return err;
    };
    return .{
        .io = io,
        .gpa = gpa,
        .reg = reg,
        .session_id = session_id,
    };
}

pub const ChildTransport = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    reg: *subprocess.Registry,
    session_id: []const u8,

    pub fn transport(self: *ChildTransport) Transport {
        return .{
            .ptr = self,
            .writeLineFn = writeLine,
            .readLineFn = readLine,
            .cancelFn = cancel,
        };
    }

    fn writeLine(ptr: *anyopaque, line: []const u8) anyerror!void {
        const self: *ChildTransport = @ptrCast(@alignCast(ptr));
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        try buf.appendSlice(self.gpa, line);
        try buf.append(self.gpa, '\n');
        try self.reg.writeStdin(self.session_id, "acp", buf.items);
    }

    fn readLine(ptr: *anyopaque, alloc: std.mem.Allocator) anyerror![]u8 {
        const self: *ChildTransport = @ptrCast(@alignCast(ptr));
        return self.reg.readStdoutLine(alloc, self.session_id, "acp");
    }

    fn cancel(ptr: *anyopaque) void {
        const self: *ChildTransport = @ptrCast(@alignCast(ptr));
        self.reg.terminate(self.session_id, "acp");
    }
};

// ---------------------------------------------------------------------------
// In-process fake ACP agent used by the unit tests. Not a second client.
// ---------------------------------------------------------------------------

fn nowMs() i64 {
    return @intCast(log.unixMilliseconds());
}

fn pauseNs(ns: u64) void {
    var req = std.c.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&req, null);
}

const FakeMode = enum { happy, auth, permission, hang, demand_fs };

const FakeJob = struct {
    pair: *Pair,
    mode: FakeMode,
};

const SpinMutex = struct {
    raw: std.atomic.Mutex = .unlocked,
    fn lock(self: *SpinMutex) void {
        while (!self.raw.tryLock()) {
            std.Thread.yield() catch {};
        }
    }
    fn unlock(self: *SpinMutex) void {
        self.raw.unlock();
    }
};

const Mailbox = struct {
    mutex: SpinMutex = .{},
    lines: std.ArrayList([]const u8) = .empty,
    alloc: std.mem.Allocator,
    closed: bool = false,

    fn push(self: *Mailbox, line: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.lines.append(self.alloc, try self.alloc.dupe(u8, line));
    }

    fn pop(self: *Mailbox, alloc: std.mem.Allocator, timeout_ms: u64) ![]u8 {
        const deadline = nowMs() + @as(i64, @intCast(timeout_ms));
        while (true) {
            self.mutex.lock();
            if (self.lines.items.len > 0) {
                const owned = self.lines.orderedRemove(0);
                self.mutex.unlock();
                defer self.alloc.free(owned);
                return alloc.dupe(u8, owned);
            }
            const closed = self.closed;
            self.mutex.unlock();
            if (closed) return Error.Closed;
            if (nowMs() >= deadline) return Error.Hang;
            pauseNs(2 * std.time.ns_per_ms);
        }
    }

    fn close(self: *Mailbox) void {
        self.mutex.lock();
        self.closed = true;
        self.mutex.unlock();
    }

    fn deinit(self: *Mailbox) void {
        for (self.lines.items) |l| self.alloc.free(l);
        self.lines.deinit(self.alloc);
    }
};

const Pair = struct {
    to_agent: Mailbox,
    to_client: Mailbox,
    alloc: std.mem.Allocator,
    replies: std.ArrayList([]const u8) = .empty,
    mutex: SpinMutex = .{},
    job: FakeJob = undefined,

    fn init(alloc: std.mem.Allocator) Pair {
        return .{
            .to_agent = .{ .alloc = alloc },
            .to_client = .{ .alloc = alloc },
            .alloc = alloc,
        };
    }

    fn deinit(self: *Pair) void {
        self.to_agent.deinit();
        self.to_client.deinit();
        for (self.replies.items) |r| self.alloc.free(r);
        self.replies.deinit(self.alloc);
    }

    fn recordReply(self: *Pair, line: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const d = self.alloc.dupe(u8, line) catch return;
        self.replies.append(self.alloc, d) catch self.alloc.free(d);
    }

    fn clientTransport(self: *Pair) Transport {
        return .{
            .ptr = self,
            .writeLineFn = clientWrite,
            .readLineFn = clientRead,
            .cancelFn = clientCancel,
        };
    }

    fn clientWrite(ptr: *anyopaque, line: []const u8) anyerror!void {
        const self: *Pair = @ptrCast(@alignCast(ptr));
        self.recordReply(line);
        try self.to_agent.push(line);
    }

    fn clientRead(ptr: *anyopaque, alloc: std.mem.Allocator) anyerror![]u8 {
        const self: *Pair = @ptrCast(@alignCast(ptr));
        return self.to_client.pop(alloc, 2_000);
    }

    fn clientCancel(ptr: *anyopaque) void {
        const self: *Pair = @ptrCast(@alignCast(ptr));
        self.to_agent.close();
        self.to_client.close();
    }
};

fn fakeAgentMain(job: *FakeJob) void {
    var arena_state = std.heap.ArenaAllocator.init(job.pair.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const session_id: []const u8 = "fake-1";
    while (true) {
        const line = job.pair.to_agent.pop(arena, 3_000) catch break;
        const parsed = json.parseFromSliceLeaky(json.Value, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        if (parsed != .object) continue;
        const method_v = parsed.object.get("method") orelse continue;
        if (method_v != .string) continue;
        const method = method_v.string;
        const id = parsed.object.get("id");
        if (std.mem.eql(u8, method, "initialize")) {
            const auth = if (job.mode == .auth)
                "[{\"id\":\"login\",\"name\":\"login\"}]"
            else
                "[]";
            const body = std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"protocolVersion\":1,\"agentCapabilities\":{{}},\"authMethods\":{s}}}}}", .{ idAsInt(id orelse .null), auth }) catch break;
            job.pair.to_client.push(body) catch break;
        } else if (std.mem.eql(u8, method, "authenticate")) {
            const body = std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{}}}}", .{idAsInt(id orelse .null)}) catch break;
            job.pair.to_client.push(body) catch break;
        } else if (std.mem.eql(u8, method, "session/new")) {
            const body = std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"sessionId\":\"{s}\"}}}}", .{ idAsInt(id orelse .null), session_id }) catch break;
            job.pair.to_client.push(body) catch break;
        } else if (std.mem.eql(u8, method, "session/prompt")) {
            if (job.mode == .hang) {
                // Never reply: the client must time out and cancel.
                continue;
            }
            if (job.mode == .demand_fs) {
                const req = std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"fs/read_text_file\",\"params\":{{\"path\":\"/tmp/x\"}}}}", .{}) catch break;
                job.pair.to_client.push(req) catch break;
                continue;
            }
            const upd = std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{{\"sessionId\":\"{s}\",\"update\":{{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{{\"type\":\"text\",\"text\":\"fake-acp-answer\"}}}}}}}}", .{session_id}) catch break;
            job.pair.to_client.push(upd) catch break;
            if (job.mode == .permission) {
                const perm = std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":77,\"method\":\"session/request_permission\",\"params\":{{\"sessionId\":\"{s}\",\"toolCall\":{{\"toolCallId\":\"t1\",\"title\":\"echo\"}},\"options\":[{{\"optionId\":\"allow-once\",\"name\":\"Allow once\",\"kind\":\"allow_once\"}},{{\"optionId\":\"reject-once\",\"name\":\"Reject\",\"kind\":\"reject_once\"}}]}}}}", .{session_id}) catch break;
                job.pair.to_client.push(perm) catch break;
            }
            const done = std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"stopReason\":\"end_turn\"}}}}", .{idAsInt(id orelse .null)}) catch break;
            job.pair.to_client.push(done) catch break;
        }
    }
}

fn runAgainst(mode: FakeMode, timeout_ms: u64) !struct { result: PromptResult, pair: *Pair, client: *Client, arena: *std.heap.ArenaAllocator } {
    const gpa = std.testing.allocator;
    const pair = try gpa.create(Pair);
    pair.* = Pair.init(gpa);
    pair.job = .{ .pair = pair, .mode = mode };
    const thread = try std.Thread.spawn(.{}, fakeAgentMain, .{&pair.job});
    thread.detach();
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    const client = try gpa.create(Client);
    client.* = .{
        .alloc = arena.allocator(),
        .transport = pair.clientTransport(),
        .timeout_ms = timeout_ms,
    };
    const result = try client.prompt("/tmp", "hello");
    return .{ .result = result, .pair = pair, .client = client, .arena = arena };
}

fn cleanupRun(run: anytype) void {
    run.pair.to_agent.close();
    run.pair.to_client.close();
    pauseNs(20 * std.time.ns_per_ms);
    run.client.deinit();
    std.testing.allocator.destroy(run.client);
    run.arena.deinit();
    std.testing.allocator.destroy(run.arena);
    run.pair.deinit();
    std.testing.allocator.destroy(run.pair);
}

test "ACP client sends initialize, session/new, session/prompt and consumes session/update" {
    const run = try runAgainst(.happy, 2_000);
    defer cleanupRun(run);
    try std.testing.expectEqual(@as(usize, 3), run.result.methods.len);
    try std.testing.expectEqualStrings("initialize", run.result.methods[0]);
    try std.testing.expectEqualStrings("session/new", run.result.methods[1]);
    try std.testing.expectEqualStrings("session/prompt", run.result.methods[2]);
    try std.testing.expect(run.result.updates.len >= 1);
    try std.testing.expectEqualStrings("agent_message_chunk", run.result.updates[0].kind);
    try std.testing.expect(std.mem.find(u8, run.result.answer, "fake-acp-answer") != null);
}

test "ACP client authenticates when the agent lists an auth method" {
    const run = try runAgainst(.auth, 2_000);
    defer cleanupRun(run);
    try std.testing.expectEqual(@as(usize, 4), run.result.methods.len);
    try std.testing.expectEqualStrings("initialize", run.result.methods[0]);
    try std.testing.expectEqualStrings("authenticate", run.result.methods[1]);
    try std.testing.expectEqualStrings("session/new", run.result.methods[2]);
    try std.testing.expectEqualStrings("session/prompt", run.result.methods[3]);
}

test "ACP client answers session/request_permission with a JSON-RPC result" {
    const run = try runAgainst(.permission, 2_000);
    defer cleanupRun(run);
    try std.testing.expect(run.result.permission_replies >= 1);
    var saw_reply = false;
    for (run.pair.replies.items) |line| {
        if (std.mem.find(u8, line, "\"outcome\"") != null and std.mem.find(u8, line, "allow-once") != null) {
            saw_reply = true;
            break;
        }
    }
    try std.testing.expect(saw_reply);
}

test "ACP client times out a hung prompt as Hang and cancels" {
    const gpa = std.testing.allocator;
    const pair = try gpa.create(Pair);
    pair.* = Pair.init(gpa);
    defer {
        pair.to_agent.close();
        pair.to_client.close();
        pauseNs(20 * std.time.ns_per_ms);
        pair.deinit();
        gpa.destroy(pair);
    }
    pair.job = .{ .pair = pair, .mode = .hang };
    const thread = try std.Thread.spawn(.{}, fakeAgentMain, .{&pair.job});
    thread.detach();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var client = Client{
        .alloc = arena_state.allocator(),
        .transport = pair.clientTransport(),
        .timeout_ms = 80,
    };
    defer client.deinit();
    try std.testing.expectError(Error.Hang, client.prompt("/tmp", "hello"));
}

test "ACP client refuses fs/* from the agent" {
    const gpa = std.testing.allocator;
    const pair = try gpa.create(Pair);
    pair.* = Pair.init(gpa);
    defer {
        pair.to_agent.close();
        pair.to_client.close();
        pauseNs(20 * std.time.ns_per_ms);
        pair.deinit();
        gpa.destroy(pair);
    }
    pair.job = .{ .pair = pair, .mode = .demand_fs };
    const thread = try std.Thread.spawn(.{}, fakeAgentMain, .{&pair.job});
    thread.detach();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var client = Client{
        .alloc = arena_state.allocator(),
        .transport = pair.clientTransport(),
        .timeout_ms = 500,
    };
    defer client.deinit();
    try std.testing.expectError(Error.CapabilityRefused, client.prompt("/tmp", "hello"));
    var saw_error = false;
    for (pair.replies.items) |line| {
        if (std.mem.find(u8, line, "capability not supported") != null) saw_error = true;
    }
    try std.testing.expect(saw_error);
}

test "spawn argv logging never includes a credential" {
    const argv = [_][]const u8{ "grok", "agent", "stdio" };
    const token = "sekrit-token-xyz";
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "acp-client: spawning {s} ({d} arg(s)); credentials stay in the child", .{ argv[0], argv.len });
    try std.testing.expect(std.mem.find(u8, line, token) == null);
    try std.testing.expect(std.mem.find(u8, line, "grok") != null);
    for (argv) |a| try std.testing.expect(std.mem.find(u8, a, token) == null);
}
