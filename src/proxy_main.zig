//! Standalone OpenAI/Anthropic compatibility proxy: `zig build proxy` builds
//! `clanker-proxy` with only the provider/auth/proxy code — no web UI, agent
//! loop, TUI, or WASM tool host. The binary reads the same `config.toml` /
//! `config.local.toml` pair (only `[providers.*]`, `[models.*]`, and
//! `[serve]`'s proxy keys matter) and mounts `/v1` at the root, exactly like
//! `clanker serve --proxy-port` does on its dedicated listener.
//!
//! Flags: `--host <addr>` (default 127.0.0.1) and `--port <port>` (default
//! 17922). `CLANKER_HOST` / `CLANKER_PROXY_PORT` fill in when flags are
//! absent. `[serve] proxy_token_env` guards the endpoint the same way it
//! does on the full binary.

const std = @import("std");
const config = @import("config.zig");
const proxy = @import("serve/proxy.zig");
const log = @import("util/log.zig");
const dotenv = @import("util/dotenv.zig");
const raw_http = @import("util/raw_http.zig");
const vertex_token = @import("llm/vertex_token.zig");
const rate_limit = @import("llm/rate_limit.zig");
const build_options = @import("build_options");

const default_host = "127.0.0.1";
const default_port: u16 = 17922;

/// Small enough for any /v1 request this proxy forwards; a body larger than
/// this (whole-repo prompt stuffing) is refused rather than buffered.
const max_request_bytes = 32 * 1024 * 1024;

var conn_gpa: std.mem.Allocator = undefined;

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
            host = args_it.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--port")) {
            const raw = args_it.next() orelse return usage();
            port = std.fmt.parseInt(u16, raw, 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--version")) {
            try std.Io.File.stdout().writeStreamingAll(io, "clanker-proxy " ++ build_options.version ++ "\n");
            return;
        } else {
            return usage();
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
    std.debug.print("http://{s}:{d}/v1\n", .{ host, port });

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

fn usage() void {
    std.debug.print("usage: clanker-proxy [--host <addr>] [--port <port>]\n", .{});
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
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(conn_gpa);
    var chunk: [16 * 1024]u8 = undefined;
    while (!raw_http.requestComplete(data.items)) {
        const n = try std.posix.read(conn.stream.socket.handle, &chunk);
        if (n == 0) return;
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

    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/health/live")) {
        respond(conn.stream, 200, "OK", "{\"ok\":true,\"status\":\"live\"}");
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
                    _ = proxy.writeAuthError(conn.stream, path, headers_raw);
                    return;
                },
            }
        }
    }

    _ = proxy.handle(.{
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
    var hbuf: [256]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, reason, body.len }) catch return;
    raw_http.writeAllFd(stream.socket.handle, hdr);
    raw_http.writeAllFd(stream.socket.handle, body);
}

fn isLoopback(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "::1") or std.mem.eql(u8, host, "localhost");
}
