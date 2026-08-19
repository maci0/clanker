//! Test-only mock HTTP server speaking OpenAI-compat / Anthropic chat
//! responses. Used by integration tests to exercise the full client path
//! without an external API key.

const std = @import("std");
const raw_http = @import("../util/raw_http.zig");

/// Mirror of `client.http_scratch_buf_bytes`, kept here so this test-only
/// server does not import the module under test. Only `.stream_then_stall`
/// needs it: the client's reads complete on a full buffer, so a stream that
/// starts has to deliver at least that much before it can go quiet.
const client_read_buffer_bytes: usize = 8192;

pub const Mode = enum {
    openai_stream,
    anthropic_text,
    /// Anthropic/Vertex SSE carrying a tool call that takes no arguments, and
    /// ending without the terminating blank line (as a truncated or
    /// close-delimited stream does).
    anthropic_stream,
    /// Always 503. Used to exhaust `client.chat`'s same-provider retries so
    /// a fallback-chain test can assert the next provider is reached.
    http_503,
    /// First response is 429 with Retry-After: 0; later responses are the
    /// OpenAI SSE stream. Exercises `chatStream`'s same-provider retry.
    openai_stream_after_429,
    /// First response is 429 with Retry-After: 0; later responses are a
    /// plain OpenAI chat completion. Exercises `chat`'s same-provider retry
    /// honoring the header on the non-streaming path.
    openai_after_429,
    /// Reads the request and deliberately never sends a response. Timeout
    /// tests stop the server after the client has aborted its socket.
    stall,
    /// Sends the SSE head and one content frame, then goes quiet forever
    /// without the terminating `[DONE]`. This is the failure a whole-call
    /// ceiling cannot tell from a slow answer: bytes did arrive.
    stream_then_stall,
};

pub const Captured = struct {
    target: []const u8,
    headers_raw: []const u8,
    body: []const u8,
};

pub const MockServer = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    server: std.Io.net.Server,
    thread: std.Thread,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: std.Io.Mutex = .init,
    captured: std.ArrayList(Captured) = .empty,
    mode: Mode,
    port: u16,
    /// Responses written so far. `openai_stream_after_429` uses this to
    /// flip from the 429 to the stream after the first hit.
    served: std.atomic.Value(u32) = .init(0),

    pub fn start(io: std.Io, gpa: std.mem.Allocator, mode: Mode) !*MockServer {
        // Port 0: the kernel picks a free ephemeral port, so concurrent test
        // processes cannot collide on a probed range. The old code seeded a
        // deterministic sequence from a fresh local counter, so every server
        // in a process probed the same first port and walked the same 64-port
        // walk on every collision.
        var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        var server = std.Io.net.IpAddress.listen(&addr, io, .{}) catch return error.CannotBindMockPort;
        const port = server.socket.address.getPort();

        const self = try gpa.create(MockServer);
        self.* = .{
            .io = io,
            .gpa = gpa,
            .server = server,
            .thread = undefined,
            .mode = mode,
            .port = port,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    pub fn stop(self: *MockServer) void {
        self.stop_flag.store(true, .release);
        self.server.socket.close(self.io);
        // close() alone does not reliably interrupt a blocked accept() on
        // Linux, so wake it with a self-connection: the serve thread accepts
        // the connection, its handler sees EOF, and the loop checks the stop
        // flag and exits.
        const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port) catch return;
        if (addr.connect(self.io, .{ .mode = .stream })) |c| {
            c.close(self.io);
        } else |_| {}
        self.thread.join();
        for (self.captured.items) |c| {
            self.gpa.free(c.target);
            self.gpa.free(c.headers_raw);
            self.gpa.free(c.body);
        }
        self.captured.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn lastCaptured(self: *MockServer) ?Captured {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.captured.items.len == 0) return null;
        return self.captured.items[self.captured.items.len - 1];
    }

    fn serve(self: *MockServer) void {
        while (!self.stop_flag.load(.acquire)) {
            const stream = self.server.accept(self.io) catch {
                break;
            };
            self.handle(stream);
            stream.close(self.io);
        }
    }

    fn handle(self: *MockServer, stream: std.Io.net.Stream) void {
        // posix.read returns as soon as *any* bytes are available (short read),
        // unlike the stream Reader which blocks until its buffer is full.
        var total: std.ArrayList(u8) = .empty;
        defer total.deinit(self.gpa);
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(stream.socket.handle, &tmp) catch break;
            if (n == 0) break; // EOF
            total.appendSlice(self.gpa, tmp[0..n]) catch break;
            if (total.items.len > (1 << 20)) break;
            if (raw_http.requestComplete(total.items)) break;
        }
        if (std.mem.find(u8, total.items, "\r\n\r\n")) |hdr_end| {
            const headers_raw = total.items[0..hdr_end];
            const body = total.items[hdr_end + 4 ..];
            var target: []const u8 = "";
            if (std.mem.find(u8, headers_raw, "\r\n")) |line_end| {
                var it = std.mem.tokenizeAny(u8, headers_raw[0..line_end], " ");
                _ = it.next(); // HTTP method, unused
                target = it.next() orelse "";
            }
            self.record(target, headers_raw, body);
        }
        self.respond(stream);
    }

    fn record(self: *MockServer, target: []const u8, headers_raw: []const u8, body: []const u8) void {
        const cap = Captured{
            .target = self.gpa.dupe(u8, target) catch return,
            .headers_raw = self.gpa.dupe(u8, headers_raw) catch return,
            .body = self.gpa.dupe(u8, body) catch return,
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.captured.append(self.gpa, cap) catch {};
    }

    fn respond(self: *MockServer, stream: std.Io.net.Stream) void {
        if (self.mode == .stall) {
            while (!self.stop_flag.load(.acquire)) {
                std.Io.sleep(self.io, .fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch return;
            }
            return;
        }
        if (self.mode == .stream_then_stall) {
            const frame =
                \\data: {"id":"chatcmpl-mock3","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello "},"finish_reason":null}]}
                \\
                \\
            ;
            // The client reads with `readSliceShort`, which returns only when
            // its buffer is full or the stream ends -- so a handful of frames
            // would leave that call blocked and look identical to a provider
            // that never said anything. Sending more than one read buffer's
            // worth is what makes this "the stream started" rather than "the
            // stream never began", which is the distinction under test.
            const reps = (2 * client_read_buffer_bytes) / frame.len + 1;
            var hbuf: [4096]u8 = undefined;
            const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n", .{}) catch return;
            raw_http.writeAllFd(stream.socket.handle, hdr);
            var cbuf: [32]u8 = undefined;
            const chunk_size = std.fmt.bufPrint(&cbuf, "{x}\r\n", .{frame.len * reps}) catch return;
            raw_http.writeAllFd(stream.socket.handle, chunk_size);
            for (0..reps) |_| raw_http.writeAllFd(stream.socket.handle, frame);
            raw_http.writeAllFd(stream.socket.handle, "\r\n");
            // No terminating chunk and no [DONE]: the connection stays open
            // and silent, which is the failure only an idle clock can name.
            while (!self.stop_flag.load(.acquire)) {
                std.Io.sleep(self.io, .fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch return;
            }
            return;
        }
        const n = self.served.fetchAdd(1, .monotonic);
        if (self.mode == .openai_stream_after_429 and n == 0) {
            const limited =
                \\{"error":{"message":"rate limited","type":"rate_limit_error"}}
            ;
            var lbuf: [4096]u8 = undefined;
            const lhdr = std.fmt.bufPrint(&lbuf, "HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nRetry-After: 0\r\nConnection: close\r\n\r\n", .{limited.len}) catch return;
            raw_http.writeAllFd(stream.socket.handle, lhdr);
            raw_http.writeAllFd(stream.socket.handle, limited);
            return;
        }
        if (self.mode == .openai_after_429 and n == 0) {
            const limited =
                \\{"error":{"message":"rate limited","type":"rate_limit_error"}}
            ;
            var lbuf: [4096]u8 = undefined;
            const lhdr = std.fmt.bufPrint(&lbuf, "HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nRetry-After: 0\r\nConnection: close\r\n\r\n", .{limited.len}) catch return;
            raw_http.writeAllFd(stream.socket.handle, lhdr);
            raw_http.writeAllFd(stream.socket.handle, limited);
            return;
        }
        const pair = switch (self.mode) {
            .openai_stream, .openai_stream_after_429 => .{
                \\data: {"id":"chatcmpl-mock2","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello "},"finish_reason":null}]}
                \\
                \\data: {"id":"chatcmpl-mock2","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"from the "},"finish_reason":null}]}
                \\
                \\data: {"id":"chatcmpl-mock2","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"mock stream"},"finish_reason":null}]}
                \\
                \\data: [DONE]
                \\
                ,
                @as(u16, 200),
                @as([]const u8, "OK"),
                @as([]const u8, "text/event-stream"),
            },
            .openai_after_429 => .{
                \\{"id":"chatcmpl-mock4","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"Hello from the mock"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":5,"total_tokens":10}}
                ,
                @as(u16, 200),
                @as([]const u8, "OK"),
                @as([]const u8, "application/json"),
            },
            .anthropic_text => .{
                \\{"id":"msg_mock","type":"message","role":"assistant","model":"mock","content":[{"type":"text","text":"Hello from Anthropic-mock"}],"stop_reason":"end_turn","usage":{"input_tokens":7,"output_tokens":6}}
                ,
                @as(u16, 200),
                @as([]const u8, "OK"),
                @as([]const u8, "application/json"),
            },
            .anthropic_stream => .{
                \\data: {"type":"message_start","message":{"usage":{"input_tokens":40,"cache_read_input_tokens":10,"output_tokens":1}}}
                \\
                \\data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
                \\
                \\data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Checking the roadmap"}}
                \\
                \\data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_mock","name":"roadmap","input":{}}}
                \\
                \\data: {"type":"content_block_stop","index":1}
                \\
                \\data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":35}}
                ,
                @as(u16, 200),
                @as([]const u8, "OK"),
                @as([]const u8, "text/event-stream"),
            },
            .http_503 => .{
                \\{"error":{"message":"overloaded","type":"overloaded_error"}}
                ,
                @as(u16, 503),
                @as([]const u8, "Service Unavailable"),
                @as([]const u8, "application/json"),
            },
            .stall, .stream_then_stall => unreachable,
        };
        const body = pair[0];
        const status = pair[1];
        const reason = pair[2];
        const content_type = pair[3];
        var hbuf: [4096]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, reason, content_type, body.len }) catch return;
        raw_http.writeAllFd(stream.socket.handle, hdr);
        raw_http.writeAllFd(stream.socket.handle, body);
    }
};
