//! `clanker mesh <sub>`: the operator surface over local serve's mesh
//! control plane (`/api/mesh/*`).
//!
//! The CLI never opens a mesh socket. PRD 0011: only `clanker serve` owns
//! those; this command is a loopback HTTP client, the same shape as
//! `ck_mesh`. `--webui-port` selects which local serve when several run on
//! one host.

const std = @import("std");
const diag = @import("../util/diag.zig");
const json_util = @import("../util/json.zig");

pub const version = @import("build_options").version;

pub const Options = struct {
    /// "status" (default), "join", "leave", "pending", "admit", or "deny".
    sub: []const u8 = "status",
    /// `join`: host:port. `leave`/`admit`/`deny`: peer id. Absent leave is
    /// self-leave.
    arg1: ?[]const u8 = null,
};

pub const Error = error{
    BadSubcommand,
    MissingArg,
    ServeNotRunning,
    MeshOff,
    RequestFailed,
};

/// Bind host → the address the CLI actually dials. Wildcard binds are not
/// connectable; loopback is.
pub fn controlHost(bind_host: []const u8) []const u8 {
    if (std.mem.eql(u8, bind_host, "0.0.0.0") or std.mem.eql(u8, bind_host, "*"))
        return "127.0.0.1";
    if (std.mem.eql(u8, bind_host, "::") or std.mem.eql(u8, bind_host, "[::]"))
        return "::1";
    return bind_host;
}

pub fn controlUrl(arena: std.mem.Allocator, host: []const u8, port: u16, path: []const u8) ![]const u8 {
    const h = controlHost(host);
    if (std.mem.findScalar(u8, h, ':') != null)
        return std.fmt.allocPrint(arena, "http://[{s}]:{d}{s}", .{ h, port, path });
    return std.fmt.allocPrint(arena, "http://{s}:{d}{s}", .{ h, port, path });
}

pub fn cmd(init: std.process.Init, opts: Options, host: []const u8, port: u16) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const sub = opts.sub;

    if (std.mem.eql(u8, sub, "status")) return status(init, host, port);
    if (std.mem.eql(u8, sub, "join")) {
        const address = opts.arg1 orelse {
            diag.errorLine("mesh join needs a host:port: clanker mesh join 127.0.0.1:7420", .{});
            return Error.MissingArg;
        };
        const body = try std.fmt.allocPrint(arena, "{{\"address\":{f}}}", .{std.json.fmt(address, .{})});
        const out = try call(io, gpa, arena, host, port, .POST, "/api/mesh/join", body);
        try writeOk(io, out, "joined {s}\n", .{address});
        return;
    }
    if (std.mem.eql(u8, sub, "leave")) {
        const body = if (opts.arg1) |id|
            try std.fmt.allocPrint(arena, "{{\"peer_id\":{f}}}", .{std.json.fmt(id, .{})})
        else
            "{}";
        const out = try call(io, gpa, arena, host, port, .POST, "/api/mesh/leave", body);
        if (opts.arg1) |id| {
            try writeOk(io, out, "left {s}\n", .{id});
        } else {
            try writeOk(io, out, "left the mesh\n", .{});
        }
        return;
    }
    if (std.mem.eql(u8, sub, "pending")) return pending(init, host, port);
    if (std.mem.eql(u8, sub, "admit") or std.mem.eql(u8, sub, "deny")) {
        const id = opts.arg1 orelse {
            diag.errorLine("mesh {s} needs a peer id: clanker mesh {s} <id>", .{ sub, sub });
            return Error.MissingArg;
        };
        const allow = std.mem.eql(u8, sub, "admit");
        const body = try std.fmt.allocPrint(
            arena,
            "{{\"id\":{f},\"allow\":{}}}",
            .{ std.json.fmt(id, .{}), allow },
        );
        const out = try call(io, gpa, arena, host, port, .POST, "/api/mesh/pending", body);
        try writeOk(io, out, "{s} {s}\n", .{ if (allow) "admitted" else "denied", id });
        return;
    }

    diag.errorLine("unknown mesh subcommand '{s}' (expected status, join, leave, pending, admit or deny)", .{sub});
    return Error.BadSubcommand;
}

fn status(init: std.process.Init, host: []const u8, port: u16) !void {
    const arena = init.arena.allocator();
    const raw = try call(init.io, init.gpa, arena, host, port, .GET, "/api/mesh/status", "");
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch
        return Error.RequestFailed;
    if (parsed != .object) return Error.RequestFailed;
    try writeStdOut(init.io, try renderStatus(arena, parsed.object));
}

fn pending(init: std.process.Init, host: []const u8, port: u16) !void {
    const arena = init.arena.allocator();
    const raw = try call(init.io, init.gpa, arena, host, port, .GET, "/api/mesh/pending", "");
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch
        return Error.RequestFailed;
    if (parsed != .object) return Error.RequestFailed;
    try writeStdOut(init.io, try renderPending(arena, parsed.object));
}

fn writeOk(io: std.Io, raw: []const u8, comptime fmt: []const u8, args: anytype) !void {
    if (raw.len > 0) {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "{\"ok\":true}")) {
            // Serve already named the outcome; still print a short line.
        }
    }
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch return error.RequestFailed;
    try writeStdOut(io, line);
}

/// Wall-clock ceiling for one mesh control call.
///
/// `std.http.Client` has no read timeout of its own (`ConnectTcpOptions.timeout`
/// is declared and never referenced -- see `llm/client.zig`'s `Abort`), so a
/// local `clanker serve` that accepts the connection and then goes quiet
/// blocks this command forever, with nothing printed and no error to report.
/// Every call here is loopback to a process on the same host, so 15s is far
/// past a healthy answer and well short of "never".
const call_timeout_ms: i64 = 15_000;

/// The fetch half of `call`, as a concurrent task so the caller can put a
/// deadline on it. Every exit sets `done`, cancelation included, or the waiter
/// is never woken. `body` outlives the task: `call` only returns after the
/// future is awaited or cancelled (which joins).
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
        .payload = if (method == .POST) payload else null,
        .headers = .{
            .user_agent = .{ .override = "clanker/" ++ version },
            .content_type = .{ .override = "application/json" },
        },
        .response_writer = &body.writer,
    });
    return @intFromEnum(res.status);
}

fn call(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    host: []const u8,
    port: u16,
    method: std.http.Method,
    path: []const u8,
    payload: []const u8,
) ![]const u8 {
    return callWithTimeout(io, gpa, arena, host, port, method, path, payload, call_timeout_ms);
}

fn callWithTimeout(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    host: []const u8,
    port: u16,
    method: std.http.Method,
    path: []const u8,
    payload: []const u8,
    timeout_ms: i64,
) ![]const u8 {
    const url = try controlUrl(arena, host, port, path);
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();

    var done: std.Io.Event = .unset;
    var fut = io.concurrent(fetchTask, .{ io, gpa, url, method, payload, &body, &done }) catch {
        // Waiting without a ceiling is the thing being avoided, so a missing
        // worker is a refusal rather than a fall back to an unbounded call.
        diag.errorLine("mesh: no spare worker to run the request under a timeout", .{});
        return Error.RequestFailed;
    };
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{
        .clock = .awake,
        .raw = .{ .nanoseconds = @as(i96, timeout_ms) * std.time.ns_per_ms },
    });
    while (!done.isSet()) {
        done.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
            // Spurious wakeups report Timeout too, so the deadline decides
            // whether the budget is really spent, not this return.
            error.Timeout => {
                if (done.isSet()) break;
                if (deadline.durationFromNow(io).raw.nanoseconds > 0) continue;
                // cancel() interrupts the blocking syscall and joins the task,
                // so nothing is left writing into `body` after this returns.
                if (fut.cancel(io)) |_| {} else |_| {}
                diag.errorLine("clanker serve at {s} accepted the connection and did not answer within {d}ms", .{ url, timeout_ms });
                return Error.ServeNotRunning;
            },
            error.Canceled => {
                if (fut.cancel(io)) |_| {} else |_| {}
                return Error.RequestFailed;
            },
        };
    }
    const status_n = fut.await(io) catch |err| {
        diag.errorLine("clanker serve is not reachable at {s} ({s}); start `clanker serve` with modules.mesh = true", .{ url, @errorName(err) });
        return Error.ServeNotRunning;
    };
    const text = try arena.dupe(u8, body.written());
    if (status_n == 404) {
        diag.errorLine("modules.mesh is off; set it and restart `clanker serve`", .{});
        return Error.MeshOff;
    }
    if (status_n >= 400) {
        if (jsonError(arena, text)) |msg| {
            diag.errorLine("{s}", .{msg});
        } else {
            diag.errorLine("mesh request failed (HTTP {d})", .{status_n});
        }
        return Error.RequestFailed;
    }
    return text;
}

fn jsonError(arena: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return null;
    if (parsed != .object) return null;
    const err = parsed.object.get("error") orelse return null;
    return if (err == .string) err.string else null;
}

pub fn renderStatus(arena: std.mem.Allocator, obj: std.json.ObjectMap) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const listening = if (obj.get("listening")) |v| (v == .bool and v.bool) else false;
    const listen = strField(obj, "listen");
    const admission = strField(obj, "admission");
    const id = strField(obj, "id");
    try out.writer.print("mesh  {s}", .{if (listening) "listening" else "not listening"});
    if (listen.len > 0) try out.writer.print("  {s}", .{listen});
    if (admission.len > 0) try out.writer.print("  admission={s}", .{admission});
    if (id.len > 0) try out.writer.print("  id={s}", .{id});
    try out.writer.writeByte('\n');

    const members = if (obj.get("members")) |v| (if (v == .array) v.array.items else &.{}) else &.{};
    if (members.len == 0) {
        try out.writer.writeAll("  (no members)\n");
        return out.toOwnedSlice();
    }
    for (members) |item| {
        if (item != .object) continue;
        const mid = strField(item.object, "id");
        const name = strField(item.object, "name");
        const up = json_util.boolFieldOrFalse(item.object, "up");
        const label = if (name.len > 0 and !std.mem.eql(u8, name, mid)) name else mid;
        try out.writer.print("  {s}", .{label});
        if (mid.len > 0 and !std.mem.eql(u8, label, mid)) try out.writer.print("  {s}", .{mid});
        try out.writer.print("  {s}\n", .{if (up) "up" else "down"});
    }
    return out.toOwnedSlice();
}

pub fn renderPending(arena: std.mem.Allocator, obj: std.json.ObjectMap) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const rows = if (obj.get("pending")) |v| (if (v == .array) v.array.items else &.{}) else &.{};
    if (rows.len == 0) {
        try out.writer.writeAll("  (no pending joins)\n");
        return out.toOwnedSlice();
    }
    for (rows) |item| {
        if (item != .object) continue;
        const id = strField(item.object, "id");
        const name = strField(item.object, "name");
        const age = if (item.object.get("age_s")) |v| switch (v) {
            .integer => v.integer,
            .float => @as(i64, @trunc(v.float)),
            else => 0,
        } else 0;
        try out.writer.print("  {s}", .{if (id.len > 0) id else "?"});
        if (name.len > 0 and !std.mem.eql(u8, name, id)) try out.writer.print("  {s}", .{name});
        try out.writer.print("  {d}s\n", .{age});
    }
    return out.toOwnedSlice();
}

fn strField(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

fn writeStdOut(io: std.Io, text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

test "controlHost maps wildcard binds to loopback" {
    try std.testing.expectEqualStrings("127.0.0.1", controlHost("0.0.0.0"));
    try std.testing.expectEqualStrings("::1", controlHost("::"));
    try std.testing.expectEqualStrings("127.0.0.1", controlHost("127.0.0.1"));
    try std.testing.expectEqualStrings("10.0.0.4", controlHost("10.0.0.4"));
}

test "controlUrl brackets v6 and leaves v4 bare" {
    const url4 = try controlUrl(std.testing.allocator, "0.0.0.0", 17921, "/api/mesh/status");
    defer std.testing.allocator.free(url4);
    try std.testing.expectEqualStrings("http://127.0.0.1:17921/api/mesh/status", url4);
    const url6 = try controlUrl(std.testing.allocator, "::", 17922, "/api/mesh/join");
    defer std.testing.allocator.free(url6);
    try std.testing.expectEqualStrings("http://[::1]:17922/api/mesh/join", url6);
}

test "a serve that accepts and never answers ends on the budget, not never" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    // The failure this exists to prevent: a local `clanker serve` that
    // completes the TCP handshake and then sends nothing. The kernel backlog
    // accepts for us, so `fetch` gets a live connection and blocks in a read.
    // Never accepting is deliberate: an accept loop would only add a thread
    // that has to be joined.
    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    const started = std.Io.Timestamp.now(io, .awake);
    const outcome = callWithTimeout(io, allocator, arena_state.allocator(), "127.0.0.1", port, .GET, "/api/mesh/status", "", 300);
    const elapsed_ms = @divTrunc(started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds, std.time.ns_per_ms);

    try std.testing.expectError(Error.ServeNotRunning, outcome);
    // On the budget rather than on the OS connect timeout (~75s) an unbounded
    // call used to wait out, or never at all.
    try std.testing.expect(elapsed_ms < 30_000);
}

test "renderStatus lists members and the listen line" {
    const raw =
        \\{"ok":true,"listening":true,"listen":"127.0.0.1:7420","admission":"allowlist","id":"main","members":[{"id":"side","name":"side","up":true},{"id":"laptop","name":"mac","up":false}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const text = try renderStatus(std.testing.allocator, parsed.value.object);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "listening  127.0.0.1:7420") != null);
    try std.testing.expect(std.mem.find(u8, text, "admission=allowlist") != null);
    try std.testing.expect(std.mem.find(u8, text, "id=main") != null);
    try std.testing.expect(std.mem.find(u8, text, "side  up") != null);
    try std.testing.expect(std.mem.find(u8, text, "mac  laptop  down") != null);
}

test "renderPending empty and one row" {
    const empty_raw = "{\"ok\":true,\"pending\":[]}";
    const empty = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, empty_raw, .{});
    defer empty.deinit();
    const empty_text = try renderPending(std.testing.allocator, empty.value.object);
    defer std.testing.allocator.free(empty_text);
    try std.testing.expectEqualStrings("  (no pending joins)\n", empty_text);

    const one_raw = "{\"ok\":true,\"pending\":[{\"id\":\"side\",\"name\":\"side\",\"age_s\":12}]}";
    const one = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, one_raw, .{});
    defer one.deinit();
    const one_text = try renderPending(std.testing.allocator, one.value.object);
    defer std.testing.allocator.free(one_text);
    try std.testing.expectEqualStrings("  side  12s\n", one_text);
}
