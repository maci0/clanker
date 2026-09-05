//! Leveled logging to stderr: single-write-per-line prefixed output.

const std = @import("std");

pub const Level = enum {
    debug,
    info,
    warn,
    error_,
    /// Above every real level: `log.log` drops everything. The REPL sets
    /// this once the alt screen exists and `providers check` during its
    /// sweep, so record-emitting worker threads cannot paint timestamped
    /// machinery text over an interactive surface. Never accepted from
    /// config strings.
    none,

    pub fn fromStr(s: []const u8) ?Level {
        // Closed set; the stored tag is `error_` so stringToEnum cannot
        // accept the operator-facing spelling "error" on its own.
        const names = std.StaticStringMap(Level).initComptime(.{
            .{ "debug", .debug },
            .{ "info", .info },
            .{ "warn", .warn },
            .{ "error", .error_ },
        });
        return names.get(s);
    }
};

test "Level.fromStr accepts operator spellings" {
    try std.testing.expectEqual(Level.debug, Level.fromStr("debug").?);
    try std.testing.expectEqual(Level.info, Level.fromStr("info").?);
    try std.testing.expectEqual(Level.warn, Level.fromStr("warn").?);
    try std.testing.expectEqual(Level.error_, Level.fromStr("error").?);
    try std.testing.expect(Level.fromStr("error_") == null);
    try std.testing.expect(Level.fromStr("nope") == null);
}

var current_level = std.atomic.Value(u8).init(@intFromEnum(Level.info));

/// Serialises the final stderr write. Each call formats into a thread-local
/// buffer first, but without this two connection threads can still interleave
/// their `write(2)` calls and produce unreadable log lines.
var log_mutex: std.c.pthread_mutex_t = .{};

/// Correlation context is thread-local so concurrent HTTP connections can
/// attach their request id to logs emitted deep in the agent/sandbox stack.
/// Keep this deliberately small and opaque: callers must not put request
/// bodies, credentials, or other user-controlled data here.
threadlocal var context: []const u8 = "";

/// Optional alternate destination for log records, replacing the stderr
/// write. The REPL installs one so `.error_` records emitted while the alt
/// screen is up land in the transcript as dim lines instead of painting raw
/// `[ERROR] ts_ms=...` text over the UI; `providers check` installs a drop
/// sink so a failing probe's records do not interleave with its report.
/// `write` runs on the logging thread (any thread may log), so the callback
/// must be safe to call from any thread. It receives one already-formatted
/// record, newline-terminated, with `\n`/`\r` already collapsed to spaces.
pub const Sink = struct {
    ctx: *const anyopaque,
    write: *const fn (ctx: *const anyopaque, line: []const u8) void,
};

var sink_storage: Sink = undefined;
/// The active sink, published as an atomic pointer (`0` = none) so a logging
/// thread reads the same value setSink stored: the log level, which does
/// share across threads, is an atomic too, and a plain global was observed
/// to read back as its zero-initialized self on worker threads. setSink
/// overwrites `sink_storage` before publishing, so a reader can never
/// observe a torn pair.
var sink_ptr = std.atomic.Value(usize).init(0);

/// One log record's stack buffer. A longer message is truncated to this and
/// still written as a single newline-terminated line.
const record_buf_bytes: usize = 4096;

pub fn setSink(s: ?Sink) void {
    if (s) |v| {
        sink_storage = v;
        sink_ptr.store(@intFromPtr(&sink_storage), .seq_cst);
    } else {
        sink_ptr.store(0, .seq_cst);
    }
}

pub fn setLevel(l: Level) void {
    current_level.store(@intFromEnum(l), .release);
}

pub fn getLevel() Level {
    return @enumFromInt(current_level.load(.acquire));
}

pub fn setContext(value: []const u8) void {
    context = value;
}

pub fn clearContext() void {
    context = "";
}

pub fn getContext() []const u8 {
    return context;
}

pub fn unixMilliseconds() i128 {
    // Residual std.c clock: std.log's logFn carries no `std.Io` handle.
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * std.time.ms_per_s + @divTrunc(@as(i128, ts.nsec), std.time.ns_per_ms);
}

pub fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) < current_level.load(.acquire)) return;
    const prefix = switch (level) {
        .debug => "DEBUG",
        .info => "INFO",
        .warn => "WARN",
        .error_ => "ERROR",
        // Nothing is ever logged at this level; the enum only gives
        // setLevel a value above error_ to silence records.
        .none => unreachable,
    };
    // One write per line: tools run on worker threads and the model's tokens
    // stream to stdout at the same time, so a line split across several prints
    // interleaves with them mid-word.
    var buf: [record_buf_bytes]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("[{s}] ts_ms={d}", .{ prefix, unixMilliseconds() }) catch {};
    if (context.len > 0) w.print(" request_id={s}", .{context}) catch {};
    w.writeByte(' ') catch {};
    w.print(fmt, args) catch {};
    // A tool/provider error may contain newlines. Preserve the information
    // while keeping one physical line per event for log collectors.
    for (buf[0..w.end]) |*byte| {
        if (byte.* == '\n' or byte.* == '\r') byte.* = ' ';
    }
    w.writeByte('\n') catch {
        // Message longer than the buffer: keep the truncated head and still
        // terminate the line.
        buf[buf.len - 1] = '\n';
        w.end = buf.len;
    };
    const p = sink_ptr.load(.acquire);
    if (p != 0) {
        const s: *const Sink = @ptrFromInt(p);
        s.write(s.ctx, buf[0..w.end]);
        return;
    }
    _ = std.c.pthread_mutex_lock(&log_mutex);
    defer _ = std.c.pthread_mutex_unlock(&log_mutex);
    std.debug.print("{s}", .{buf[0..w.end]});
}

/// The panic path's log line, formatted like every other record but written
/// without taking `log_mutex`.
///
/// A panic can land on a thread that is already inside `log`, holding that
/// mutex; taking it again would deadlock and turn a crash into a hang, which
/// is strictly worse to operate. Interleaving with a concurrent log line is
/// the accepted cost, and the process is about to die anyway. The level
/// threshold is deliberately not consulted either: a crash is reportable at
/// any configured level.
///
/// Nothing here may touch `std.Io`. This used to end in `std.debug.print`,
/// whose stderr flush goes `Io.Threaded.unlockStderr` -> `File.writeStreaming`
/// -> `Io.Threaded.operate` -> `Syscall.start`. When the panic *came from*
/// that dispatcher (`Syscall.start`'s `.blocked => unreachable`, which a
/// signal landing on a pool thread mid-syscall reaches) the flush re-entered
/// the same `unreachable` and panicked again, forever: no message, no exit
/// status, nothing to reap. The panic reporter cannot depend on the subsystem
/// most likely to be the thing that failed, so the line goes out with a raw
/// `write(2)`.
/// See docs/reports/bugs/2026-08-23-panic-recurses-forever-instead-of-aborting.md.
pub fn logPanic(msg: []const u8) void {
    writePanicLine(std.posix.STDERR_FILENO, msg);
}

/// `logPanic`'s body with the destination named, so a test can capture the
/// bytes off a pipe and prove they came from the raw write rather than from
/// `std.Io`.
pub fn writePanicLine(fd: std.posix.fd_t, msg: []const u8) void {
    var buf: [record_buf_bytes]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("[ERROR] ts_ms={d}", .{unixMilliseconds()}) catch {};
    if (context.len > 0) w.print(" request_id={s}", .{context}) catch {};
    w.print(" panic: {s}", .{msg}) catch {};
    for (buf[0..w.end]) |*byte| {
        if (byte.* == '\n' or byte.* == '\r') byte.* = ' ';
    }
    w.writeByte('\n') catch {
        buf[buf.len - 1] = '\n';
        w.end = buf.len;
    };
    // Best effort and bounded: a short write is retried, anything else gives
    // up rather than spin. A panic that cannot report itself must still reach
    // the caller's `abort()`.
    const line = buf[0..w.end];
    var off: usize = 0;
    while (off < line.len) {
        const n = std.c.write(fd, line[off..].ptr, line.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

test "writePanicLine reaches the fd without going through std.Io" {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.NoPipe;
    defer _ = std.c.close(fds[0]);
    writePanicLine(fds[1], "reached unreachable code");
    // Closed before the read so the read cannot block waiting for more.
    _ = std.c.close(fds[1]);
    var buf: [record_buf_bytes]u8 = undefined;
    const n = try std.posix.read(fds[0], &buf);
    const got = buf[0..n];
    try std.testing.expect(std.mem.find(u8, got, "[ERROR] ts_ms=") != null);
    try std.testing.expect(std.mem.find(u8, got, "panic: reached unreachable code") != null);
    try std.testing.expectEqual(@as(u8, '\n'), got[got.len - 1]);
}

test "writePanicLine keeps a panic message on one physical line" {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.NoPipe;
    defer _ = std.c.close(fds[0]);
    writePanicLine(fds[1], "first\nsecond\rthird");
    _ = std.c.close(fds[1]);
    var buf: [record_buf_bytes]u8 = undefined;
    const n = try std.posix.read(fds[0], &buf);
    const got = buf[0..n];
    try std.testing.expect(std.mem.find(u8, got, "panic: first second third") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, got, "\n"));
}
