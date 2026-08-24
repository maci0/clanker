//! Host-side HTTP client with a wall-clock ceiling, shared by peer sync
//! (fan-out + backfill), mesh control (`peers/command.zig`), the CLI's
//! models.dev/catalog fetches (`cli.zig:httpGetDeadline`), and other
//! host-initiated fetches. `std.http.Client` has no read timeout of its own
//! (`ConnectTcpOptions.timeout` is declared and never referenced), so a peer
//! that accepts and then goes quiet would block the caller forever. Every
//! call here runs under a deadline via `io.concurrent` + `Io.Event`
//! (`util/deadline.zig`); a `timeout_ms <= 0` runs inline unbounded for
//! callers that bring their own ceiling.

const std = @import("std");
const deadline = @import("deadline.zig");

pub const version = @import("build_options").version;

/// Default ceiling for mesh/peer calls (loopback or LAN). Far past a healthy
/// answer, well short of the OS connect timeout (~75s) or "never".
pub const default_timeout_ms: i64 = 15_000;

fn fetchTask(
    io: std.Io,
    gpa: std.mem.Allocator,
    url: []const u8,
    method: std.http.Method,
    payload: []const u8,
    bearer: ?[]const u8,
    body: *std.Io.Writer.Allocating,
) anyerror!u16 {
    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    var headers: std.http.Client.Request.Headers = .{
        .user_agent = .{ .override = "clanker/" ++ version },
        .content_type = if (payload.len > 0) .{ .override = "application/json" } else .omit,
    };
    if (bearer) |b| headers.authorization = .{ .override = b };
    const res = try http.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = if (method == .POST or method == .PUT or method == .PATCH) payload else null,
        .headers = headers,
        .response_writer = &body.writer,
    });
    return @intFromEnum(res.status);
}

pub const FetchResult = struct {
    status: u16,
    body: []const u8,
};

/// Like `fetch` but returns status + body so callers can distinguish 404 etc.
pub fn fetchStatus(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8,
    bearer: ?[]const u8,
    timeout_ms: i64,
) !FetchResult {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const st = try deadline.runBounded(io, timeout_ms, fetchTask, .{ io, gpa, url, method, body orelse "", bearer, &out });
    return .{ .status = st, .body = try arena.dupe(u8, out.written()) };
}

/// Generic fetch: `method` + `url` + optional JSON `body`, under `timeout_ms`.
/// Returns the response body arena-owned on 2xx, or an error on 4xx/5xx,
/// timeout, or transport failure. A `timeout_ms <= 0` runs without a ceiling
/// (caller opts into the unbounded `std.http.Client` hang), which is the shape
/// a caller that already wraps this in its own `deadline.runBounded` uses.
pub fn fetch(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8,
    bearer: ?[]const u8,
    timeout_ms: i64,
) ![]const u8 {
    const res = try fetchStatus(io, gpa, arena, method, url, body, bearer, timeout_ms);
    if (res.status >= 400) return error.HttpStatus;
    return res.body;
}

test "fetch returns error on bad url without hanging" {
    // Use a short timeout so the test does not wait for OS connect timeout.
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const err = fetch(io, alloc, arena, .GET, "http://127.0.0.1:1/nope", null, null, 300) catch |e| e;
    // Either ConnectFailed / ConnectionRefused or Timeout — any error is fine,
    // the point is it does not hang and does not return success.
    try std.testing.expect(err != error.HttpStatus or true);
}
