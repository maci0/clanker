//! Session-scoped subprocess registry. Kernel (PRD 0016) and DAP (PRD 0017)
//! share this: register by `<session-id>/<kind>`, SIGTERM the group on
//! session end. Callers own spawn; the registry stores the live Child (pipes
//! included) so later tool calls can talk to the same process.

const std = @import("std");
const session = @import("session.zig");

/// Blocking lock around `std.atomic.Mutex` for structures that do not carry
/// an `std.Io` handle (the process-global registry is touched at first use).
/// Bounds each pipe read; the leftover assembly above handles arbitrary
/// line lengths, so this only caps how much is read per syscall.
const stdout_chunk_bytes: usize = 4096;

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

pub const Handle = struct {
    session_id: []const u8,
    kind: []const u8,
    pid: std.posix.pid_t,
    child: ?std.process.Child = null,
    leftover: std.ArrayList(u8) = .empty,
};

pub const Registry = struct {
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(Handle) = .empty,
    gpa: std.mem.Allocator,
    io: std.Io,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Registry {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *Registry) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.items.items.len > 0) {
            self.killAtLocked(0);
        }
        self.items.deinit(self.gpa);
    }

    pub fn key(session_id: []const u8, kind: []const u8, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ session_id, kind });
    }

    /// Replaces any existing handle for the same session+kind. PID-only:
    /// tests and callers that do not need pipes. Prefer `adopt` when the
    /// process must stay open across tool calls.
    pub fn register(self: *Registry, session_id: []const u8, kind: []const u8, pid: std.posix.pid_t) !void {
        if (!session.validSessionId(session_id)) return error.InvalidSessionId;
        if (kind.len == 0) return error.EmptyKind;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.removeMatchingLocked(session_id, kind);
        try self.items.append(self.gpa, .{
            .session_id = try self.gpa.dupe(u8, session_id),
            .kind = try self.gpa.dupe(u8, kind),
            .pid = pid,
        });
    }

    /// Takes ownership of a spawned Child (stdio pipes stay open). Replaces
    /// any existing handle for the same session+kind and SIGTERMs it.
    pub fn adopt(self: *Registry, session_id: []const u8, kind: []const u8, child: std.process.Child) !std.posix.pid_t {
        if (!session.validSessionId(session_id)) return error.InvalidSessionId;
        if (kind.len == 0) return error.EmptyKind;
        const pid = child.id orelse return error.DeadChild;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.removeMatchingLocked(session_id, kind);
        try self.items.append(self.gpa, .{
            .session_id = try self.gpa.dupe(u8, session_id),
            .kind = try self.gpa.dupe(u8, kind),
            .pid = pid,
            .child = child,
        });
        return pid;
    }

    pub fn get(self: *Registry, session_id: []const u8, kind: []const u8) ?std.posix.pid_t {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.findLocked(session_id, kind)) |h| return h.pid;
        return null;
    }

    pub fn writeStdin(self: *Registry, session_id: []const u8, kind: []const u8, bytes: []const u8) !void {
        const f = self.stdinFile(session_id, kind) orelse return error.NoStdin;
        try f.writeStreamingAll(self.io, bytes);
    }

    /// Reads one newline-terminated line from the child's stdout. The newline
    /// is not included. Blocks until a line arrives or the pipe closes.
    pub fn readStdoutLine(self: *Registry, arena: std.mem.Allocator, session_id: []const u8, kind: []const u8) ![]u8 {
        while (true) {
            if (try self.takeLine(arena, session_id, kind)) |line| return line;
            var tmp: [stdout_chunk_bytes]u8 = undefined;
            const n = try self.readStdoutInto(session_id, kind, &tmp);
            if (n == 0) return error.KernelExited;
            try self.appendLeftover(session_id, kind, tmp[0..n]);
        }
    }

    /// Reads up to `max` bytes from leftover or the pipe. Blocks until at
    /// least one byte or EOF. Used by DAP framing, which is not line-oriented.
    pub fn readStdout(self: *Registry, arena: std.mem.Allocator, session_id: []const u8, kind: []const u8, max: usize) ![]u8 {
        if (try self.takeLeftover(arena, session_id, kind, max)) |got| return got;
        var tmp: [stdout_chunk_bytes]u8 = undefined;
        const n = try self.readStdoutInto(session_id, kind, tmp[0..@min(max, tmp.len)]);
        if (n == 0) return error.KernelExited;
        return arena.dupe(u8, tmp[0..n]);
    }

    fn stdinFile(self: *Registry, session_id: []const u8, kind: []const u8) ?std.Io.File {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const h = self.findLocked(session_id, kind) orelse return null;
        const child = if (h.child) |*c| c else return null;
        return child.stdin;
    }

    fn stdoutFile(self: *Registry, session_id: []const u8, kind: []const u8) ?std.Io.File {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const h = self.findLocked(session_id, kind) orelse return null;
        const child = if (h.child) |*c| c else return null;
        return child.stdout;
    }

    fn readStdoutInto(self: *Registry, session_id: []const u8, kind: []const u8, dest: []u8) !usize {
        const f = self.stdoutFile(session_id, kind) orelse return error.NoStdout;
        return f.readStreaming(self.io, &.{dest}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
    }

    fn takeLine(self: *Registry, arena: std.mem.Allocator, session_id: []const u8, kind: []const u8) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const h = self.findLocked(session_id, kind) orelse return null;
        const nl = std.mem.findScalar(u8, h.leftover.items, '\n') orelse return null;
        const line = arena.dupe(u8, std.mem.trimEnd(u8, h.leftover.items[0..nl], "\r")) catch |err| return err;
        const rest = h.leftover.items[nl + 1 ..];
        std.mem.copyForwards(u8, h.leftover.items, rest);
        h.leftover.shrinkRetainingCapacity(rest.len);
        return line;
    }

    fn takeLeftover(self: *Registry, arena: std.mem.Allocator, session_id: []const u8, kind: []const u8, max: usize) !?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const h = self.findLocked(session_id, kind) orelse return null;
        if (h.leftover.items.len == 0) return null;
        const n = @min(h.leftover.items.len, max);
        const out = arena.dupe(u8, h.leftover.items[0..n]) catch |err| return err;
        const rest = h.leftover.items[n..];
        std.mem.copyForwards(u8, h.leftover.items, rest);
        h.leftover.shrinkRetainingCapacity(rest.len);
        return out;
    }

    fn appendLeftover(self: *Registry, session_id: []const u8, kind: []const u8, bytes: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const h = self.findLocked(session_id, kind) orelse return error.NotRegistered;
        try h.leftover.appendSlice(self.gpa, bytes);
    }

    /// Drops a pid-only row without signalling. Used after a waiter has
    /// already reaped the child, so a later session cleanup cannot SIGTERM
    /// a recycled pid. Missing keys are a no-op. Must not be used on an
    /// adopted Child (that would leak the pipes); jobs register pids only.
    pub fn forget(self: *Registry, session_id: []const u8, kind: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var i: usize = 0;
        while (i < self.items.items.len) {
            const h = self.items.items[i];
            if (std.mem.eql(u8, h.session_id, session_id) and std.mem.eql(u8, h.kind, kind)) {
                var removed = self.items.orderedRemove(i);
                removed.leftover.deinit(self.gpa);
                self.gpa.free(removed.session_id);
                self.gpa.free(removed.kind);
                return;
            }
            i += 1;
        }
    }

    /// SIGTERM + wait one process. Missing keys are a no-op.
    pub fn terminate(self: *Registry, session_id: []const u8, kind: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var i: usize = 0;
        while (i < self.items.items.len) {
            const h = self.items.items[i];
            if (std.mem.eql(u8, h.session_id, session_id) and std.mem.eql(u8, h.kind, kind)) {
                self.killAtLocked(i);
                return;
            }
            i += 1;
        }
    }

    /// SIGTERM every process for this session. Missing pids are ignored.
    pub fn terminateSession(self: *Registry, session_id: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var i: usize = 0;
        while (i < self.items.items.len) {
            const h = self.items.items[i];
            if (std.mem.eql(u8, h.session_id, session_id)) {
                self.killAtLocked(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn count(self: *Registry) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.items.items.len;
    }

    pub const Row = struct {
        session_id: []const u8,
        kind: []const u8,
        pid: std.posix.pid_t,
    };

    /// Copies identity rows under the lock. Caller owns the strings.
    pub fn snapshot(self: *Registry, arena: std.mem.Allocator) ![]Row {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var out: std.ArrayList(Row) = .empty;
        for (self.items.items) |h| {
            try out.append(arena, .{
                .session_id = try arena.dupe(u8, h.session_id),
                .kind = try arena.dupe(u8, h.kind),
                .pid = h.pid,
            });
        }
        return out.toOwnedSlice(arena);
    }

    fn findLocked(self: *Registry, session_id: []const u8, kind: []const u8) ?*Handle {
        for (self.items.items) |*h| {
            if (std.mem.eql(u8, h.session_id, session_id) and std.mem.eql(u8, h.kind, kind))
                return h;
        }
        return null;
    }

    fn removeMatchingLocked(self: *Registry, session_id: []const u8, kind: []const u8) void {
        var i: usize = 0;
        while (i < self.items.items.len) {
            const h = self.items.items[i];
            if (std.mem.eql(u8, h.session_id, session_id) and std.mem.eql(u8, h.kind, kind)) {
                self.killAtLocked(i);
            } else {
                i += 1;
            }
        }
    }

    fn killAtLocked(self: *Registry, i: usize) void {
        var h = self.items.orderedRemove(i);
        if (h.child) |*c| {
            c.kill(self.io);
        } else {
            // Residual posix: signal delivery has no std.Io equivalent.
            std.posix.kill(h.pid, std.posix.SIG.TERM) catch {};
        }
        h.leftover.deinit(self.gpa);
        self.gpa.free(h.session_id);
        self.gpa.free(h.kind);
    }
};

var process_mu: SpinMutex = .{};
var process_reg: ?Registry = null;

/// Process-wide registry so a REPL (new Agent per turn) keeps kernel/DAP
/// processes across turns. Tests should construct a local Registry instead.
pub fn processRegistry(gpa: std.mem.Allocator, io: std.Io) !*Registry {
    process_mu.lock();
    defer process_mu.unlock();
    if (process_reg == null) process_reg = Registry.init(gpa, io);
    return &process_reg.?;
}

/// Ends a session only when a privileged kernel or DAP call actually created
/// the process registry. Ordinary runs must not allocate a process-global
/// registry merely to discover there is nothing to clean up.
pub fn endSession(session_id: []const u8) void {
    process_mu.lock();
    defer process_mu.unlock();
    if (process_reg) |*reg| reg.terminateSession(session_id);
}

/// Releases the process-global registry before its backing allocator exits.
/// This also SIGTERMs any process that survived a caller forgetting to close
/// its session, rather than reporting the registry itself as a debug leak.
pub fn deinitProcessRegistry() void {
    process_mu.lock();
    defer process_mu.unlock();
    if (process_reg) |*reg| reg.deinit();
    process_reg = null;
}

fn testIo() std.Io.Threaded {
    return std.Io.Threaded.init(std.testing.allocator, .{});
}

test "register and get by session+kind" {
    var threaded = testIo();
    defer threaded.deinit();
    var reg = Registry.init(std.testing.allocator, threaded.io());
    defer reg.deinit();
    try reg.register("sess-1", "python", 42);
    try std.testing.expectEqual(@as(std.posix.pid_t, 42), reg.get("sess-1", "python").?);
    try std.testing.expect(reg.get("sess-1", "js") == null);
    try std.testing.expectEqual(@as(usize, 1), reg.count());
    var snap_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer snap_arena.deinit();
    const rows = try reg.snapshot(snap_arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("sess-1", rows[0].session_id);
    try std.testing.expectEqualStrings("python", rows[0].kind);
}

test "register replaces the previous pid for the same key" {
    var threaded = testIo();
    defer threaded.deinit();
    var reg = Registry.init(std.testing.allocator, threaded.io());
    defer reg.deinit();
    try reg.register("sess-1", "python", 1);
    try reg.register("sess-1", "python", 2);
    try std.testing.expectEqual(@as(std.posix.pid_t, 2), reg.get("sess-1", "python").?);
    try std.testing.expectEqual(@as(usize, 1), reg.count());
}

test "terminateSession drops every kind for that session" {
    var threaded = testIo();
    defer threaded.deinit();
    var reg = Registry.init(std.testing.allocator, threaded.io());
    defer reg.deinit();
    try reg.register("a", "python", 1);
    try reg.register("a", "js", 2);
    try reg.register("b", "python", 3);
    reg.terminateSession("a");
    try std.testing.expect(reg.get("a", "python") == null);
    try std.testing.expectEqual(@as(std.posix.pid_t, 3), reg.get("b", "python").?);
}

test "forget removes a pid-only row without requiring the process" {
    var threaded = testIo();
    defer threaded.deinit();
    var reg = Registry.init(std.testing.allocator, threaded.io());
    defer reg.deinit();
    try reg.register("sess-1", "job-abc", 1);
    try std.testing.expectEqual(@as(usize, 1), reg.count());
    reg.forget("sess-1", "job-abc");
    try std.testing.expectEqual(@as(usize, 0), reg.count());
    reg.forget("sess-1", "job-abc");
}

test "invalid session id is refused" {
    var threaded = testIo();
    defer threaded.deinit();
    var reg = Registry.init(std.testing.allocator, threaded.io());
    defer reg.deinit();
    try std.testing.expectError(error.InvalidSessionId, reg.register("../x", "python", 1));
}

test "adopt a live process, write/read a line, SIGTERM on session end" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    var reg = Registry.init(std.testing.allocator, io);
    defer reg.deinit();

    const script =
        \\import sys
        \\for line in sys.stdin:
        \\    sys.stdout.write(line)
        \\    sys.stdout.flush()
    ;
    const child = std.process.spawn(io, .{
        .argv = &.{ "python3", "-c", script },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    const pid = try reg.adopt("live-1", "echo", child);
    try std.testing.expect(pid > 1);
    try std.testing.expectEqual(pid, reg.get("live-1", "echo").?);

    try reg.writeStdin("live-1", "echo", "hello-registry\n");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const line = try reg.readStdoutLine(arena_state.allocator(), "live-1", "echo");
    try std.testing.expectEqualStrings("hello-registry", line);

    reg.terminateSession("live-1");
    try std.testing.expect(reg.get("live-1", "echo") == null);
    try std.testing.expectEqual(@as(usize, 0), reg.count());
    // A second terminate is a no-op, not a crash on a stale pid.
    reg.terminateSession("live-1");
}
