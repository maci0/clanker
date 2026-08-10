//! Test-only mock HTTP server speaking OpenAI-compat / Anthropic chat
//! responses. Used by integration tests to exercise the full client path
//! without an external API key.

const std = @import("std");

pub const Mode = enum {
    openai_text,
    openai_tool_call,
    openai_stream,
    anthropic_text,
    error_401,
};

pub const Captured = struct {
    method: []const u8,
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

    pub fn start(io: std.Io, gpa: std.mem.Allocator, mode: Mode) !*MockServer {
        var seed_ctr: std.atomic.Value(u64) = .init(0);
        const seed = std.hash.Wyhash.hash(0x6A09E667F3BCC909, std.mem.asBytes(&@intFromPtr(&seed_ctr))) +% seed_ctr.fetchAdd(1, .monotonic);
        var rng = std.Random.DefaultPrng.init(seed);
        var server: ?std.Io.net.Server = null;
        var port: u16 = 0;
        for (0..64) |_| {
            port = 20000 + @as(u16, @intCast(rng.random().intRangeLessThan(u32, 0, 30000)));
            const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
            server = std.Io.net.IpAddress.listen(&addr, io, .{}) catch {
                continue;
            };
            break;
        }
        if (server == null) return error.CannotBindMockPort;

        const self = try gpa.create(MockServer);
        self.* = .{
            .io = io,
            .gpa = gpa,
            .server = server.?,
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
            self.gpa.free(c.method);
            self.gpa.free(c.target);
            self.gpa.free(c.headers_raw);
            self.gpa.free(c.body);
        }
        self.captured.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn lastCaptured(self: *MockServer) ?Captured {
        self.mutex.lock(self.io) catch {};
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
            if (requestComplete(total.items)) break;
        }
        if (std.mem.indexOf(u8, total.items, "\r\n\r\n")) |hdr_end| {
            const headers_raw = total.items[0..hdr_end];
            const body = total.items[hdr_end + 4 ..];
            var method: []const u8 = "";
            var target: []const u8 = "";
            if (std.mem.indexOf(u8, headers_raw, "\r\n")) |line_end| {
                var it = std.mem.tokenizeAny(u8, headers_raw[0..line_end], " ");
                method = it.next() orelse "";
                target = it.next() orelse "";
            }
            self.record(method, target, headers_raw, body);
        }
        self.respond(stream);
    }

    fn record(self: *MockServer, method: []const u8, target: []const u8, headers_raw: []const u8, body: []const u8) void {
        const cap = Captured{
            .method = self.gpa.dupe(u8, method) catch return,
            .target = self.gpa.dupe(u8, target) catch return,
            .headers_raw = self.gpa.dupe(u8, headers_raw) catch return,
            .body = self.gpa.dupe(u8, body) catch return,
        };
        self.mutex.lock(self.io) catch {};
        defer self.mutex.unlock(self.io);
        self.captured.append(self.gpa, cap) catch {};
    }

    fn respond(self: *MockServer, stream: std.Io.net.Stream) void {
        const pair = switch (self.mode) {
            .openai_text => .{
                \\{"id":"chatcmpl-mock0","object":"chat.completion","created":1,"model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":"Hello from the mock provider"},"finish_reason":"stop"}],"usage":{"prompt_tokens":7,"completion_tokens":6,"total_tokens":13}}
                ,
                @as(u16, 200),
                @as([]const u8, "OK"),
                @as([]const u8, "application/json"),
            },
            .openai_tool_call => .{
                \\{"id":"chatcmpl-mock1","object":"chat.completion","created":1,"model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_mock","type":"function","function":{"name":"calculator","arguments":"{\"a\":2,\"b\":3}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":8,"completion_tokens":3,"total_tokens":11}}
                ,
                @as(u16, 200),
                @as([]const u8, "OK"),
                @as([]const u8, "application/json"),
            },
            .openai_stream => .{
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
            .anthropic_text => .{
                \\{"id":"msg_mock","type":"message","role":"assistant","model":"mock","content":[{"type":"text","text":"Hello from Anthropic-mock"}],"stop_reason":"end_turn","usage":{"input_tokens":7,"output_tokens":6}}
                ,
                @as(u16, 200),
                @as([]const u8, "OK"),
                @as([]const u8, "application/json"),
            },
            .error_401 => .{
                \\{"error":{"message":"Invalid API key provided","type":"invalid_request_error"}}
                ,
                @as(u16, 401),
                @as([]const u8, "Unauthorized"),
                @as([]const u8, "application/json"),
            },
        };
        const body = pair[0];
        const status = pair[1];
        const reason = pair[2];
        const content_type = pair[3];
        var hbuf: [4096]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, reason, content_type, body.len }) catch return;
        writeAllFd(stream.socket.handle, hdr);
        writeAllFd(stream.socket.handle, body);
    }
};

fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.os.linux.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n > std.math.maxInt(usize) - 4096) return; // errno
        off += n;
    }
}

fn requestComplete(data: []const u8) bool {
    if (std.mem.indexOf(u8, data, "\r\n\r\n")) |hdr_end| {
        const content_length = parseContentLength(data[0..hdr_end]) orelse 0;
        return data.len >= hdr_end + 4 + content_length;
    }
    return false;
}

fn parseContentLength(headers: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        const prefix = "content-length:";
        if (trimmed.len >= prefix.len and std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix)) {
            const value = std.mem.trim(u8, trimmed[prefix.len..], " \t");
            return std.fmt.parseInt(usize, value, 10) catch null;
        }
    }
    return null;
}
