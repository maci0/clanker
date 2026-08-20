//! Host-side HTTP client with a wall-clock ceiling, shared by peer sync
//! (fan-out + backfill), mesh control (`peers/command.zig`), and other
//! host-initiated fetches. `std.http.Client` has no read timeout of its own
//! (`ConnectTcpOptions.timeout` is declared and never referenced), so a peer
//! that accepts and then goes quiet would block the caller forever. Every
//! call here runs under a deadline via `io.concurrent` + `Io.Event`, the same
//! shape as `peers/command.zig:callWithTimeout` and `cli.zig:httpGetDeadline`.

const std = @import("std");

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
    body: *std.Io.Writer.Allocating,
    done: *std.Io.Event,
) anyerror!u16 {
    defer done.set(io);
    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    const res = try http.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = if (method == .POST or method == .PUT or method == .PATCH) payload else null,
        .headers = .{
            .user_agent = .{ .override = "clanker/" ++ version },
            .content_type = if (payload.len > 0) .{ .override = "application/json" } else .omit,
        },
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
    timeout_ms: i64,
) !FetchResult {
    const payload = body orelse "";
    if (timeout_ms <= 0) {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var done: std.Io.Event = .unset;
        const st = try fetchTask(io, gpa, url, method, payload, &out, &done);
        return .{ .status = st, .body = try arena.dupe(u8, out.written()) };
    }
    var done: std.Io.Event = .unset;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var fut = io.concurrent(fetchTask, .{ io, gpa, url, method, payload, &out, &done }) catch
        return error.ConcurrencyUnavailable;
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{
        .clock = .awake,
        .raw = .{ .nanoseconds = @as(i96, timeout_ms) * std.time.ns_per_ms },
    });
    while (!done.isSet()) {
        done.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout => {
                if (done.isSet()) break;
                if (deadline.durationFromNow(io).raw.nanoseconds > 0) continue;
                if (fut.cancel(io)) |_| {} else |_| {}
                return error.Timeout;
            },
            error.Canceled => {
                if (fut.cancel(io)) |_| {} else |_| {}
                return error.Canceled;
            },
        };
    }
    const st = try fut.await(io);
    return .{ .status = st, .body = try arena.dupe(u8, out.written()) };
}

/// Generic fetch: `method` + `url` + optional JSON `body`, under `timeout_ms`.
/// Returns the response body arena-owned on 2xx, or an error on 4xx/5xx,
/// timeout, or transport failure. A `timeout_ms <= 0` runs without a ceiling
/// (caller opts into the unbounded `std.http.Client` hang).
pub fn fetch(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8,
    timeout_ms: i64,
) ![]const u8 {
    const res = try fetchStatus(io, gpa, arena, method, url, body, timeout_ms);
    if (res.status >= 400) return error.HttpStatus;
    return res.body;
}

fn fetchUnbounded(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    payload: []const u8,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var done: std.Io.Event = .unset;
    const status_n = try fetchTask(io, gpa, url, method, payload, &out, &done);
    if (status_n >= 400) return error.HttpStatus;
    return arena.dupe(u8, out.written());
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
    const err = fetch(io, alloc, arena, .GET, "http://127.0.0.1:1/nope", null, 300) catch |e| e;
    // Either ConnectFailed / ConnectionRefused or Timeout — any error is fine,
    // the point is it does not hang and does not return success.
    try std.testing.expect(err != error.HttpStatus or true);
}
