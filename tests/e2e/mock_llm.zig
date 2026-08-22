//! Scriptable mock LLM server for black-box e2e tests. `src/llm/mock_server.zig`
//! answers every request with the same fixed body, which is enough to unit-test
//! the client's parsing but not to drive a real multi-turn agent run (a tool
//! call, then a final answer once the tool result comes back). This one hands
//! out one scripted response per request, in order, and records every request
//! body so a test can assert on what the real agent loop actually sent back
//! (e.g. that a tool's real output made it into the next turn's messages).
//!
//! Network plumbing (bind-with-retry, accept loop, self-connect to unblock a
//! pending accept on stop) mirrors mock_server.zig's proven approach.

const std = @import("std");
const raw_http = @import("raw_http");

pub const Server = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    server: std.Io.net.Server,
    thread: std.Thread,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: std.Io.Mutex = .init,
    /// SSE response bodies, one per request in order. A request past the end
    /// of the script repeats the last entry rather than hanging, so a test
    /// bug (one scripted turn short) fails on a wrong assertion instead of a
    /// timeout.
    script: []const []const u8,
    next: usize = 0,
    requests: std.ArrayList([]const u8) = .empty,
    port: u16,

    pub fn start(io: std.Io, gpa: std.mem.Allocator, script: []const []const u8) !*Server {
        std.debug.assert(script.len > 0);
        var seed_ctr: std.atomic.Value(u64) = .init(0);
        const seed = std.hash.Wyhash.hash(0x9E3779B97F4A7C15, std.mem.asBytes(&@intFromPtr(&seed_ctr))) +% seed_ctr.fetchAdd(1, .monotonic);
        var rng = std.Random.DefaultPrng.init(seed);
        var server: ?std.Io.net.Server = null;
        var port: u16 = 0;
        for (0..64) |_| {
            port = 20000 + @as(u16, @intCast(rng.random().intRangeLessThan(u32, 0, 30000)));
            const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
            server = std.Io.net.IpAddress.listen(&addr, io, .{}) catch continue;
            break;
        }
        if (server == null) return error.CannotBindMockPort;

        const self = try gpa.create(Server);
        self.* = .{
            .io = io,
            .gpa = gpa,
            .server = server.?,
            .thread = undefined,
            .script = script,
            .port = port,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    pub fn stop(self: *Server) void {
        self.stop_flag.store(true, .release);
        self.server.socket.close(self.io);
        const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port) catch return;
        if (addr.connect(self.io, .{ .mode = .stream })) |c| {
            c.close(self.io);
        } else |_| {}
        self.thread.join();
        for (self.requests.items) |r| self.gpa.free(r);
        self.requests.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// The nth request body this server received (0-indexed), or null if it
    /// hasn't arrived yet. Lets a test assert on what the agent loop actually
    /// sent — e.g. that turn 2 carries the tool's real result.
    pub fn request(self: *Server, index: usize) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (index >= self.requests.items.len) return null;
        return self.requests.items[index];
    }

    pub fn requestCount(self: *Server) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.requests.items.len;
    }

    fn serve(self: *Server) void {
        while (!self.stop_flag.load(.acquire)) {
            const stream = self.server.accept(self.io) catch break;
            self.handle(stream);
            stream.close(self.io);
        }
    }

    fn handle(self: *Server, stream: std.Io.net.Stream) void {
        var total: std.ArrayList(u8) = .empty;
        defer total.deinit(self.gpa);
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(stream.socket.handle, &tmp) catch break;
            if (n == 0) break;
            total.appendSlice(self.gpa, tmp[0..n]) catch break;
            if (total.items.len > (1 << 20)) break;
            if (raw_http.requestComplete(total.items)) break;
        }
        var body: []const u8 = &.{};
        if (std.mem.find(u8, total.items, "\r\n\r\n")) |hdr_end| body = total.items[hdr_end + 4 ..];
        const index = self.record(body);
        self.respond(stream, index);
    }

    fn record(self: *Server, body: []const u8) usize {
        const copy = self.gpa.dupe(u8, body) catch body;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.requests.append(self.gpa, copy) catch {};
        return self.requests.items.len - 1;
    }

    fn respond(self: *Server, stream: std.Io.net.Stream, index: usize) void {
        const turn = self.script[@min(index, self.script.len - 1)];
        var hbuf: [4096]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{turn.len}) catch return;
        raw_http.writeAllFd(stream.socket.handle, hdr);
        raw_http.writeAllFd(stream.socket.handle, turn);
    }
};

/// An OpenAI-compat streaming SSE body carrying one final text answer, no
/// tool calls — the shape client.zig's parser expects a completed turn to be.
pub fn textTurn(gpa: std.mem.Allocator, text: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try w.writer.print(
        "data: {{\"choices\":[{{\"index\":0,\"delta\":{{\"content\":{f}}},\"finish_reason\":null}}]}}\n\n",
        .{std.json.fmt(text, .{})},
    );
    try w.writer.writeAll("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n");
    try w.writer.writeAll("data: [DONE]\n\n");
    return w.toOwnedSlice();
}

/// An OpenAI-compat streaming SSE body whose reply hit the completion-token
/// cap before emitting any text: no content delta, `finish_reason:"length"`.
/// The shape a truncated-to-empty answer really arrives in (observed live:
/// docs/reports/bugs/2026-08-17-run-reports-success-on-empty-length-stop.md).
pub fn emptyLengthTurn(gpa: std.mem.Allocator) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try w.writer.writeAll("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"length\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":4096,\"total_tokens\":4106}}\n\n");
    try w.writer.writeAll("data: [DONE]\n\n");
    return w.toOwnedSlice();
}

/// An OpenAI-compat *non-streaming* completion body carrying one text answer.
/// A guest's `ck_llm` goes through `client.chat`, not `chatStream`, so an SSE
/// body reaches it as `SyntaxError` and the guest takes its fallback path
/// instead of the one under test.
pub fn jsonTurn(gpa: std.mem.Allocator, text: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try w.writer.print(
        "{{\"id\":\"e2e\",\"object\":\"chat.completion\",\"choices\":[{{\"index\":0,\"message\":{{\"role\":\"assistant\",\"content\":{f}}},\"finish_reason\":\"stop\"}}],\"usage\":{{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}}}",
        .{std.json.fmt(text, .{})},
    );
    return w.toOwnedSlice();
}

/// An OpenAI-compat *non-streaming* completion body whose `content` is empty
/// and whose entire output lives in `reasoning_content`, ending `finish_reason:
/// \"stop\"` -- the shape a thinking model that never closed its think block
/// returns (observed on qwen3-family models via llama.cpp). The improve engine
/// must answer this by retrying without reasoning, not by failing the attempt.
pub fn reasoningOnlyTurn(gpa: std.mem.Allocator, reasoning: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try w.writer.print(
        "{{\"id\":\"e2e\",\"object\":\"chat.completion\",\"choices\":[{{\"index\":0,\"message\":{{\"role\":\"assistant\",\"content\":\"\",\"reasoning_content\":{f}}},\"finish_reason\":\"stop\"}}],\"usage\":{{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}}}",
        .{std.json.fmt(reasoning, .{})},
    );
    return w.toOwnedSlice();
}

/// An OpenAI-compat streaming SSE body carrying a single tool call, whole
/// (arguments in one delta fragment rather than split across chunks — the
/// client folds fragments by index either way, so one fragment is a faithful
/// simplification, not a shortcut around real parsing).
pub fn toolCallTurn(gpa: std.mem.Allocator, call_id: []const u8, tool_name: []const u8, args_json: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try w.writer.print(
        "data: {{\"choices\":[{{\"index\":0,\"delta\":{{\"tool_calls\":[{{\"index\":0,\"id\":{f},\"function\":{{\"name\":{f},\"arguments\":{f}}}}}]}},\"finish_reason\":null}}]}}\n\n",
        .{ std.json.fmt(call_id, .{}), std.json.fmt(tool_name, .{}), std.json.fmt(args_json, .{}) },
    );
    try w.writer.writeAll("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n");
    try w.writer.writeAll("data: [DONE]\n\n");
    return w.toOwnedSlice();
}

test "textTurn and toolCallTurn produce parseable SSE frames" {
    const gpa = std.testing.allocator;
    const text = try textTurn(gpa, "hi \"there\"");
    defer gpa.free(text);
    try std.testing.expect(std.mem.find(u8, text, "hi \\\"there\\\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "data: [DONE]\n\n"));

    const call = try toolCallTurn(gpa, "call_1", "list_files", "{\"path\":\".\"}");
    defer gpa.free(call);
    try std.testing.expect(std.mem.find(u8, call, "\"name\":\"list_files\"") != null);
    try std.testing.expect(std.mem.find(u8, call, "\"finish_reason\":\"tool_calls\"") != null);

    const plain = try jsonTurn(gpa, "{\"commits\":[]}");
    defer gpa.free(plain);
    try std.testing.expect(std.mem.find(u8, plain, "data: ") == null);
    try std.testing.expect(std.mem.find(u8, plain, "\"content\":\"{\\\"commits\\\":[]}\"") != null);
}
