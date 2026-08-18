//! Background jobs: exec children in the 0016 registry, plus continuable
//! subagent threads. The `jobs` guest talks to this through ck_job, and the
//! `ck_job` channel in sandbox/host.zig is the only caller, so the channel's
//! code sits with the channel the way `ck_kernel`'s does in sandbox/kernel.zig.
//! Only the session-keyed process table stays in agent/subprocess.zig, which
//! the DAP shares.
//!
//! Exec children ignore stdio (a pipe nobody drains deadlocks once the
//! kernel buffer fills) and are reaped on a waiter thread. The registry
//! holds the pid only so session end can SIGTERM; after wait, forget the
//! row so a recycled pid is never signalled.

const std = @import("std");
const session = @import("../agent/session.zig");
const subprocess = @import("../agent/subprocess.zig");

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

pub const SubJob = struct {
    id: []const u8,
    session_id: []const u8,
    task: []const u8,
    result: ?[]const u8 = null,
    err_name: ?[]const u8 = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
};

const ExecJob = struct {
    id: []const u8,
    session_id: []const u8,
    child: std.process.Child,
    pid: std.posix.pid_t,
    term: ?std.process.Child.Term = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
};

var mu: SpinMutex = .{};
var subs: std.ArrayList(*SubJob) = .empty;
var execs: std.ArrayList(*ExecJob) = .empty;
var gpa_ref: ?std.mem.Allocator = null;
var id_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);

pub fn makeId(now_ns: u64, buf: []u8) []const u8 {
    const mixed = now_ns ^ (id_seq.fetchAdd(1, .monotonic) << 8);
    const hex = "0123456789abcdef";
    var n = mixed;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        if (i >= buf.len) continue;
        // Hex digit: only the low nibble is used, high bits are dropped on purpose.
        buf[i] = hex[@as(u4, @truncate(n))];
        n >>= 4;
    }
    const nlen = @min(16, buf.len);
    return buf[0..nlen];
}

fn waitExecThread(job: *ExecJob, io: std.Io, reg: *subprocess.Registry) void {
    const term = job.child.wait(io) catch {
        job.done.store(true, .release);
        reg.forget(job.session_id, job.id);
        return;
    };
    job.term = term;
    job.done.store(true, .release);
    reg.forget(job.session_id, job.id);
}

fn findExec(id: []const u8) ?*ExecJob {
    for (execs.items) |j| {
        if (std.mem.eql(u8, j.id, id)) return j;
    }
    return null;
}

pub fn startExec(
    io: std.Io,
    gpa: std.mem.Allocator,
    reg: *subprocess.Registry,
    session_id: []const u8,
    root_dir: []const u8,
    argv: []const []const u8,
) ![]const u8 {
    if (argv.len == 0) return error.InvalidArg;
    var id_buf: [16]u8 = undefined;
    const now_ns: u64 = @intCast(@max(std.Io.Timestamp.now(io, .awake).nanoseconds, 0));
    const id = makeId(now_ns, &id_buf);
    var kind_buf: [24]u8 = undefined;
    const kind = try std.fmt.bufPrint(&kind_buf, "job-{s}", .{id});
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (root_dir.len > 0 and !std.mem.eql(u8, root_dir, "."))
            .{ .path = root_dir }
        else
            .inherit,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.InvalidArg;
    const pid = child.id orelse {
        child.kill(io);
        return error.InvalidArg;
    };
    const sid = if (session.validSessionId(session_id)) session_id else "default";
    reg.register(sid, kind, pid) catch {
        child.kill(io);
        return error.InvalidArg;
    };

    gpa_ref = gpa;
    const id_owned = gpa.dupe(u8, kind) catch {
        child.kill(io);
        reg.forget(sid, kind);
        return error.InvalidArg;
    };
    const sid_owned = gpa.dupe(u8, sid) catch {
        child.kill(io);
        reg.forget(sid, kind);
        gpa.free(id_owned);
        return error.InvalidArg;
    };
    const job = gpa.create(ExecJob) catch {
        child.kill(io);
        reg.forget(sid, kind);
        gpa.free(id_owned);
        gpa.free(sid_owned);
        return error.InvalidArg;
    };
    job.* = .{
        .id = id_owned,
        .session_id = sid_owned,
        .child = child,
        .pid = pid,
    };
    job.thread = std.Thread.spawn(.{}, waitExecThread, .{ job, io, reg }) catch {
        job.child.kill(io);
        reg.forget(sid, kind);
        gpa.free(job.id);
        gpa.free(job.session_id);
        gpa.destroy(job);
        return error.InvalidArg;
    };
    {
        mu.lock();
        defer mu.unlock();
        execs.append(gpa, job) catch {
            // Residual posix: signal delivery has no std.Io equivalent.
            std.posix.kill(pid, std.posix.SIG.TERM) catch {};
            if (job.thread) |th| th.join();
            gpa.free(job.id);
            gpa.free(job.session_id);
            gpa.destroy(job);
            return error.InvalidArg;
        };
    }
    return try gpa.dupe(u8, kind);
}

fn termFields(term: std.process.Child.Term) struct { exit: ?u8, signaled: bool } {
    return switch (term) {
        .exited => |code| .{ .exit = code, .signaled = false },
        else => .{ .exit = null, .signaled = true },
    };
}

pub fn waitExec(arena: std.mem.Allocator, id: []const u8) ![]const u8 {
    var found: ?*ExecJob = null;
    {
        mu.lock();
        defer mu.unlock();
        found = findExec(id);
    }
    const job = found orelse return error.NotFound;
    if (job.thread) |th| {
        th.join();
        job.thread = null;
    }
    if (job.term) |term| {
        const fields = termFields(term);
        if (fields.exit) |code| {
            return std.fmt.allocPrint(arena, "{{\"ok\":true,\"id\":{f},\"done\":true,\"exit\":{d}}}", .{
                std.json.fmt(id, .{}),
                code,
            });
        }
        return std.fmt.allocPrint(arena, "{{\"ok\":true,\"id\":{f},\"done\":true,\"signaled\":true}}", .{
            std.json.fmt(id, .{}),
        });
    }
    return std.fmt.allocPrint(arena, "{{\"ok\":false,\"id\":{f},\"error\":\"wait failed\"}}", .{
        std.json.fmt(id, .{}),
    });
}

pub fn registerSub(gpa: std.mem.Allocator, id: []const u8, session_id: []const u8, task: []const u8, thread: std.Thread) !void {
    mu.lock();
    defer mu.unlock();
    gpa_ref = gpa;
    const job = try gpa.create(SubJob);
    job.* = .{
        .id = try gpa.dupe(u8, id),
        .session_id = try gpa.dupe(u8, session_id),
        .task = try gpa.dupe(u8, task),
        .thread = thread,
    };
    try subs.append(gpa, job);
}

pub fn finishSub(id: []const u8, result: ?[]const u8, err_name: ?[]const u8) void {
    mu.lock();
    defer mu.unlock();
    const gpa = gpa_ref orelse return;
    for (subs.items) |j| {
        if (!std.mem.eql(u8, j.id, id)) continue;
        if (result) |r| j.result = gpa.dupe(u8, r) catch null;
        if (err_name) |e| j.err_name = gpa.dupe(u8, e) catch null;
        j.done.store(true, .release);
        return;
    }
}

pub fn waitSub(arena: std.mem.Allocator, id: []const u8) ![]const u8 {
    var found: ?*SubJob = null;
    {
        mu.lock();
        defer mu.unlock();
        for (subs.items) |j| {
            if (std.mem.eql(u8, j.id, id)) {
                found = j;
                break;
            }
        }
    }
    const job = found orelse return error.NotFound;
    if (job.thread) |th| {
        th.join();
        job.thread = null;
    }
    if (job.err_name) |e| {
        return std.fmt.allocPrint(arena, "{{\"ok\":false,\"job\":{f},\"error\":{f}}}", .{
            std.json.fmt(id, .{}),
            std.json.fmt(e, .{}),
        });
    }
    const text = job.result orelse "";
    return std.fmt.allocPrint(arena, "{{\"ok\":true,\"job\":{f},\"text\":{f}}}", .{
        std.json.fmt(id, .{}),
        std.json.fmt(text, .{}),
    });
}

pub fn listJson(arena: std.mem.Allocator, reg: ?*subprocess.Registry, session_id: []const u8) ![]const u8 {
    _ = reg;
    var w: std.Io.Writer.Allocating = .init(arena);
    try w.writer.writeAll("{\"ok\":true,\"jobs\":[");
    var first = true;
    {
        mu.lock();
        defer mu.unlock();
        for (execs.items) |j| {
            if (session_id.len > 0 and !std.mem.eql(u8, j.session_id, session_id)) continue;
            if (!first) try w.writer.writeByte(',');
            first = false;
            try w.writer.print("{{\"id\":{f},\"kind\":\"exec\",\"session\":{f},\"pid\":{d},\"done\":{}}}", .{
                std.json.fmt(j.id, .{}),
                std.json.fmt(j.session_id, .{}),
                j.pid,
                j.done.load(.acquire),
            });
        }
        for (subs.items) |j| {
            if (session_id.len > 0 and !std.mem.eql(u8, j.session_id, session_id)) continue;
            if (!first) try w.writer.writeByte(',');
            first = false;
            try w.writer.print("{{\"id\":{f},\"kind\":\"subagent\",\"session\":{f},\"done\":{}}}", .{
                std.json.fmt(j.id, .{}),
                std.json.fmt(j.session_id, .{}),
                j.done.load(.acquire),
            });
        }
    }
    try w.writer.writeAll("]}");
    return w.written();
}

pub fn kill(reg: ?*subprocess.Registry, session_id: []const u8, id: []const u8) bool {
    var found: ?*ExecJob = null;
    {
        mu.lock();
        defer mu.unlock();
        found = findExec(id);
    }
    if (found) |job| {
        if (!job.done.load(.acquire)) {
            // Residual posix: signal delivery has no std.Io equivalent.
            std.posix.kill(job.pid, std.posix.SIG.TERM) catch {};
        }
        if (job.thread) |th| {
            th.join();
            job.thread = null;
        }
        if (reg) |r| r.forget(session_id, id);
        return true;
    }
    if (reg) |r| {
        if (std.mem.startsWith(u8, id, "job-")) {
            r.terminate(session_id, id);
            return true;
        }
    }
    return false;
}

/// Test-only: join leftover waiter threads and free the tables so a
/// testing allocator does not see the process-global lists as leaks.
pub fn testingClear(gpa: std.mem.Allocator) void {
    while (true) {
        const job: ?*ExecJob = blk: {
            mu.lock();
            defer mu.unlock();
            break :blk execs.pop();
        };
        const j = job orelse break;
        if (j.thread) |th| th.join();
        gpa.free(j.id);
        gpa.free(j.session_id);
        gpa.destroy(j);
    }
    execs.deinit(gpa);
    execs = .empty;
}

test "makeId is 16 hex and unique at the same timestamp" {
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    const id_a = makeId(0xdeadbeefcafebabe, &a);
    const id_b = makeId(0xdeadbeefcafebabe, &b);
    try std.testing.expectEqual(@as(usize, 16), id_a.len);
    try std.testing.expect(!std.mem.eql(u8, id_a, id_b));
    for (id_a) |c| {
        const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(hex);
    }
}

test "startExec reaps true and wait returns exit 0" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var reg = subprocess.Registry.init(std.testing.allocator, io);
    defer reg.deinit();
    const id = startExec(io, std.testing.allocator, &reg, "sess-job", ".", &.{"true"}) catch |err| switch (err) {
        error.InvalidArg => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(id);
    defer testingClear(std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try waitExec(arena_state.allocator(), id);
    try std.testing.expect(std.mem.find(u8, got, "\"done\":true") != null);
    try std.testing.expect(std.mem.find(u8, got, "\"exit\":0") != null);
    try std.testing.expect(reg.get("sess-job", id) == null);
}
