//! Standalone OpenAI/Anthropic compatibility proxy: `zig build proxy` builds
//! `clanker-proxy` with only the provider/auth/proxy code — no web UI, agent
//! loop, TUI, or WASM tool host. The binary reads the same `config.toml` /
//! `config.local.toml` pair (only `[providers.*]`, `[models.*]`, and
//! `[serve]`'s proxy keys matter) and mounts `/v1` at the root, exactly like
//! `clanker serve --proxy-port` does on its dedicated listener. Besides `/v1`
//! it serves `GET /health/live` and `GET /metrics` (process-local RED
//! counters, same fields and buckets as the full server's `/api/metrics`).
//!
//! Every connection logs a completion line with method/path/status/duration
//! for failed requests (and per-request `proxy method=...` lines for
//! forwarded calls) under a `request_id` that is also echoed in the
//! `X-Request-ID` response header, so a client-provided id traces through.
//!
//! Flags: `--host <addr>` (default 127.0.0.1) and `--port <port>` (default
//! 17922), plus `--version` and `--help`/`-h`. `CLANKER_HOST` /
//! `CLANKER_PROXY_PORT` fill in when flags are absent. `[serve]
//! proxy_token_env` guards the endpoint the same way it does on the full
//! binary.

const std = @import("std");
const config = @import("config.zig");
const proxy = @import("serve/proxy.zig");
const log = @import("util/log.zig");
const dotenv = @import("util/dotenv.zig");
const raw_http = @import("util/raw_http.zig");
const diag = @import("util/diag.zig");
const vertex_token = @import("llm/vertex_token.zig");
const rate_limit = @import("llm/rate_limit.zig");
const build_options = @import("build_options");

const default_host = "127.0.0.1";
const default_port: u16 = 17922;

/// Small enough for any /v1 request this proxy forwards; a body larger than
/// this (whole-repo prompt stuffing) is refused rather than buffered.
const max_request_bytes = 32 * 1024 * 1024;

var conn_gpa: std.mem.Allocator = undefined;

/// Monotonic per-connection request id, the fallback correlation id when the
/// caller sends no `X-Request-ID`. Mirrors the full server's `http-{d}`
/// sequence in handleConnection.
var request_sequence = std.atomic.Value(u64).init(1);

/// Thread-local request accounting, filled in by `handleRequest` and read by
/// its completion defer (and by `respond`). Thread-local because connection
/// threads run concurrently and a plain global would interleave requests.
threadlocal var request_status: u16 = 0;
threadlocal var request_method: []const u8 = "unknown";
threadlocal var request_path: []const u8 = "unknown";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    defer vertex_token.deinit(io, gpa);
    defer rate_limit.deinit(io, gpa);
    conn_gpa = gpa;

    // Mirrors resolveListen's CLANKER_HOST handling: trimmed, and an empty
    // value is skipped rather than sent to the address parser.
    var host: []const u8 = blk: {
        const raw = init.environ_map.get("CLANKER_HOST") orelse break :blk default_host;
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len == 0) break :blk default_host;
        break :blk trimmed;
    };
    // A malformed CLANKER_PROXY_PORT warns and is skipped rather than
    // aborting: the default is still a usable answer, matching the full
    // binary's resolveListen and the documented rule in docs/README.md
    // ("A CLANKER_WEBUI_PORT or CLANKER_PROXY_PORT that is not a 16-bit
    // number (or is 0) warns and is ignored").
    var port: u16 = blk: {
        const raw = init.environ_map.get("CLANKER_PROXY_PORT") orelse break :blk default_port;
        const trimmed = std.mem.trim(u8, raw, " \t");
        const p = std.fmt.parseInt(u16, trimmed, 10) catch {
            log.log(.warn, "CLANKER_PROXY_PORT '{s}' is not a 16-bit port number; ignoring", .{raw});
            break :blk default_port;
        };
        if (p == 0) {
            log.log(.warn, "CLANKER_PROXY_PORT '{s}' is not a usable port; ignoring", .{raw});
            break :blk default_port;
        }
        break :blk p;
    };

    var args_it = init.minimal.args.iterate();
    _ = args_it.next(); // argv[0]
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host")) {
            host = args_it.next() orelse usageError("--host needs an address, for example --host 0.0.0.0", .{});
        } else if (std.mem.eql(u8, arg, "--port")) {
            const raw = args_it.next() orelse usageError("--port needs a port number", .{});
            port = std.fmt.parseInt(u16, raw, 10) catch usageError("--port wants a 16-bit port number, got '{s}'", .{raw});
        } else if (std.mem.eql(u8, arg, "--version")) {
            try std.Io.File.stdout().writeStreamingAll(io, "clanker-proxy " ++ build_options.version ++ "\n");
            return;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            // Asked-for help is the command's output, so stdout and exit 0,
            // matching `clanker --help`.
            try std.Io.File.stdout().writeStreamingAll(io, usage_text);
            return;
        } else {
            usageError("unrecognized argument '{s}'", .{arg});
        }
    }

    dotenv.load(io, gpa, init.environ_map);
    const cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.toml", "config.local.toml");

    if (!isLoopback(host) and cfg.serve.proxy_token_env == null) {
        log.log(.warn, "proxy on {s} has no proxy_token_env; anyone who can reach the port spends the configured provider keys", .{host});
    }

    const addr = try std.Io.net.IpAddress.parse(host, port);
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true });
    defer server.socket.close(io);

    log.log(.info, "clanker-proxy listening on {s}:{d}", .{ host, port });
    // The endpoint URL is this command's one line of output, so it goes to
    // stdout; `std.debug.print` sent it to stderr, where a script capturing
    // the URL never saw it.
    var url_buf: [128]u8 = undefined;
    if (std.fmt.bufPrint(&url_buf, "http://{s}:{d}/v1\n", .{ host, port })) |line| {
        std.Io.File.stdout().writeStreamingAll(io, line) catch {};
    } else |_| {}

    while (true) {
        const stream = server.accept(io) catch |err| {
            log.log(.error_, "accept error: {s}", .{@errorName(err)});
            continue;
        };
        const conn = gpa.create(Conn) catch {
            stream.close(io);
            continue;
        };
        conn.* = .{ .io = io, .cfg = &cfg, .environ_map = init.environ_map, .stream = stream };
        const t = std.Thread.spawn(.{}, serveConn, .{conn}) catch {
            stream.close(io);
            gpa.destroy(conn);
            continue;
        };
        t.detach();
    }
}

const usage_text =
    \\usage: clanker-proxy [--host <addr>] [--port <port>]
    \\
    \\OpenAI/Anthropic compatibility proxy, mounting /v1 at the root. Reads the
    \\same config.toml / config.local.toml pair as clanker.
    \\
    \\  --host <addr>   interface to bind (default 127.0.0.1, or CLANKER_HOST)
    \\  --port <port>   port to listen on (default 17922, or CLANKER_PROXY_PORT)
    \\  --version       print the version
    \\  --help, -h      this text
    \\
    \\A flag always wins over the matching environment variable.
    \\
;

/// One `error: ...` line plus the usage block on stderr, then exit 2.
///
/// The old `return usage()` printed the usage and let `main` return, so the
/// process exited **0**: `clanker-proxy --prot 9000 && curl ...` read a
/// refused invocation as a started server. Usage errors exit 2 here, the same
/// code `clanker` itself uses, so a caller can tell "you typed it wrong" from
/// "the machine could not do it" (1).
fn usageError(comptime fmt: []const u8, args: anytype) noreturn {
    diag.errorLine(fmt, args);
    std.debug.print("{s}", .{usage_text});
    std.process.exit(2);
}

const Conn = struct {
    io: std.Io,
    cfg: *const config.Config,
    environ_map: *std.process.Environ.Map,
    stream: std.Io.net.Stream,
};

fn serveConn(conn: *Conn) void {
    defer conn_gpa.destroy(conn);
    defer conn.stream.close(conn.io);
    handleRequest(conn) catch |err| {
        log.log(.debug, "connection dropped: {s}", .{@errorName(err)});
    };
}

fn handleRequest(conn: *Conn) !void {
    const io = conn.io;
    var request_id_buf: [24]u8 = undefined;
    const request_id = std.fmt.bufPrint(&request_id_buf, "proxy-{d}", .{request_sequence.fetchAdd(1, .monotonic)}) catch "proxy-unknown";
    log.setContext(request_id);
    // Defers run LIFO: clearContext last, so the completion log below still
    // carries this request's id. `data` is declared and its free defer placed
    // before the completion defer so `request_path` (a slice into
    // `data.items`) is still allocated when the completion line reads it —
    // the same ordering handleConnection relies on in cli.zig.
    defer log.clearContext();
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(conn_gpa);
    const started_at = std.Io.Timestamp.now(io, .awake);
    request_status = 0;
    request_method = "unknown";
    request_path = "unknown";
    // A connection that closes before completing a request line (EOF, or a
    // read error) is the protocol winding down, not a request that failed:
    // only log and count the connections that actually produced one.
    var saw_request = false;
    defer {
        if (saw_request) {
            const elapsed_ms = proxy.elapsedMs(io, started_at);
            proxy.recordRequestMetrics(request_status, elapsed_ms);
            if (proxy.requestLogLevel(request_status)) |level| {
                log.log(level, "proxy request complete method={s} path={s} status={d} duration_ms={d}", .{ request_method, request_path, request_status, elapsed_ms });
            }
        }
    }
    var chunk: [16 * 1024]u8 = undefined;
    while (!raw_http.requestComplete(data.items)) {
        // Residual posix: raw proxy socket pump, same hand-rolled HTTP family
        // as the webui server in cli.zig.
        const n = try std.posix.read(conn.stream.socket.handle, &chunk);
        if (n == 0) return;
        saw_request = true;
        if (data.items.len + n > max_request_bytes) {
            respond(conn.stream, 413, "Payload Too Large", "{\"ok\":false,\"error\":\"request too large\"}");
            return;
        }
        try data.appendSlice(conn_gpa, chunk[0..n]);
    }

    const head_end = std.mem.find(u8, data.items, "\r\n\r\n") orelse return;
    const head = data.items[0..head_end];
    const line_end = std.mem.find(u8, head, "\r\n") orelse head.len;
    var line_it = std.mem.tokenizeScalar(u8, head[0..line_end], ' ');
    const method = line_it.next() orelse return;
    const target = line_it.next() orelse return;
    const headers_raw = head[@min(line_end + 2, head.len)..];
    const body = data.items[head_end + 4 ..];

    const qmark = std.mem.findScalar(u8, target, '?');
    const path = if (qmark) |i| target[0..i] else target;
    const query = if (qmark) |i| target[i + 1 ..] else "";
    request_method = method;
    request_path = path;
    // Preserve a caller's correlation id across proxies and peer agents: it
    // lands in the completion logs and the `X-Request-ID` response header,
    // mirroring the full server's handleConnection.
    if (proxy.correlationId(headers_raw)) |upstream_id| log.setContext(upstream_id);

    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/health/live")) {
        respond(conn.stream, 200, "OK", "{\"ok\":true,\"status\":\"live\"}");
        return;
    }
    // Process-local RED counters, same field names and buckets as the full
    // server's `/api/metrics`, so one collector parses both binaries.
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/metrics")) {
        var mbuf: [1024]u8 = undefined;
        const mbody = proxy.snapshotRequestMetrics(&mbuf) orelse "{\"ok\":false,\"error\":\"metrics unavailable\"}";
        respond(conn.stream, 200, "OK", mbody);
        return;
    }
    if (!proxy.isProxyPath(path, .proxy)) {
        respond(conn.stream, 404, "Not Found", "{\"ok\":false,\"error\":\"only /v1 is served\"}");
        return;
    }
    if (conn.cfg.serve.proxy_token_env) |env_name| {
        if (conn.environ_map.get(env_name)) |expected| {
            switch (proxy.authorize(headers_raw, expected)) {
                .ok => {},
                .missing, .mismatch => {
                    request_status = proxy.writeAuthError(conn.stream, path, headers_raw);
                    return;
                },
            }
        }
    }

    request_status = proxy.handle(.{
        .io = io,
        .gpa = conn_gpa,
        .cfg = conn.cfg,
        .environ_map = conn.environ_map,
        .method = method,
        .path = path,
        .query = query,
        .headers_raw = headers_raw,
        .body = body,
        .stream = conn.stream,
    });
}

fn respond(stream: std.Io.net.Stream, status: u16, reason: []const u8, body: []const u8) void {
    request_status = status;
    var hbuf: [256]u8 = undefined;
    const request_id = log.getContext();
    const hdr = if (request_id.len > 0)
        std.fmt.bufPrint(&hbuf, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nX-Request-ID: {s}\r\nConnection: close\r\n\r\n", .{ status, reason, body.len, request_id }) catch return
    else
        std.fmt.bufPrint(&hbuf, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, reason, body.len }) catch return;
    raw_http.writeAllFd(stream.socket.handle, hdr);
    raw_http.writeAllFd(stream.socket.handle, body);
}

fn isLoopback(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "::1") or std.mem.eql(u8, host, "localhost");
}
