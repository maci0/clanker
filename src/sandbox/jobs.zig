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
const log = @import("../util/log.zig");

/// Process-local counters for background jobs. `ck_job` is start-and-forget,
/// so without these a job that dies leaves no trace anywhere: nobody is
/// obliged to call `wait`, and `reapDone` drops the row once it is old. No
/// per-job, per-session, or per-argv labels -- those live in the correlated
/// log lines below, keeping cardinality bounded the way the HTTP, tool, and
/// schedule counters already do.
var job_starts_total = std.atomic.Value(u64).init(0);
var job_completions_total = std.atomic.Value(u64).init(0);
var job_errors_total = std.atomic.Value(u64).init(0);
/// Gauge, not a counter: started minus finished. Saturation and stuck-job
/// signal, so it must go down again, which is why it is not derived from the
/// two totals above.
var jobs_active = std.atomic.Value(u64).init(0);

pub const JobMetrics = struct {
    starts_total: u64,
    completions_total: u64,
    errors_total: u64,
    active: u64,
};

pub fn snapshotJobMetrics() JobMetrics {
    return .{
        .starts_total = job_starts_total.load(.monotonic),
        .completions_total = job_completions_total.load(.monotonic),
        .errors_total = job_errors_total.load(.monotonic),
        .active = jobs_active.load(.monotonic),
    };
}

/// The log context of whoever started a job, copied at start.
///
/// `log`'s correlation context is threadlocal and does not cross
/// `std.Thread.spawn`, so a waiter thread reading it would report the empty
/// string and the job's completion would be uncorrelatable with the request
/// or run that asked for it. Stored inline rather than allocated so the start
/// path's allocation-failure unwinding stays as it is.
const Origin = struct {
    buf: [32]u8 = undefined,
    len: u8 = 0,

    fn capture() Origin {
        var o: Origin = .{};
        const ctx = log.getContext();
        const n = @min(ctx.len, o.buf.len);
        @memcpy(o.buf[0..n], ctx[0..n]);
        o.len = @intCast(n);
        return o;
    }

    fn slice(self: *const Origin) []const u8 {
        return self.buf[0..self.len];
    }
};

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
    origin: Origin = .{},
    result: ?[]const u8 = null,
    err_name: ?[]const u8 = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    /// Callers currently inside `waitSub` for this job. Read and written
    /// only under `mu`; a reap skips any job a waiter still points at.
    waiting: u32 = 0,
};

const ExecJob = struct {
    id: []const u8,
    session_id: []const u8,
    child: std.process.Child,
    pid: std.posix.pid_t,
    origin: Origin = .{},
    term: ?std.process.Child.Term = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    /// Callers currently inside `waitExec`/`kill` for this job. Read and
    /// written only under `mu`; a reap skips any job a waiter points at.
    waiting: u32 = 0,
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
    // This thread carries the starter's correlation id, not its own: see
    // `Origin`. Set it once so every line below is attributable even though
    // nothing here runs on the request thread.
    log.setContext(job.origin.slice());
    defer log.clearContext();
    const term = job.child.wait(io) catch |err| {
        // Reaping failed, so the job's exit status is now unknowable. This
        // used to return silently, leaving a job that reads `done` with no
        // term and a `wait` that answers a bare "wait failed" -- with nothing
        // anywhere naming the reason.
        _ = job_errors_total.fetchAdd(1, .monotonic);
        _ = job_completions_total.fetchAdd(1, .monotonic);
        _ = jobs_active.fetchSub(1, .monotonic);
        log.log(.warn, "job reap failed job={s} session={s} pid={d} err={s}", .{
            job.id, job.session_id, job.pid, @errorName(err),
        });
        job.done.store(true, .release);
        reg.forget(job.session_id, job.id);
        return;
    };
    job.term = term;
    const fields = termFields(term);
    _ = job_completions_total.fetchAdd(1, .monotonic);
    _ = jobs_active.fetchSub(1, .monotonic);
    if (fields.exit) |code| {
        if (code == 0) {
            log.log(.debug, "job exited job={s} session={s} pid={d} exit=0", .{ job.id, job.session_id, job.pid });
        } else {
            _ = job_errors_total.fetchAdd(1, .monotonic);
            log.log(.warn, "job exited nonzero job={s} session={s} pid={d} exit={d}", .{
                job.id, job.session_id, job.pid, code,
            });
        }
    } else {
        // Signalled: `kill` does this deliberately at session end, but so
        // does an OOM kill, and the two are indistinguishable from the row
        // alone. Count it as an error so a run of them is visible.
        _ = job_errors_total.fetchAdd(1, .monotonic);
        log.log(.warn, "job signaled job={s} session={s} pid={d}", .{ job.id, job.session_id, job.pid });
    }
    job.done.store(true, .release);
    reg.forget(job.session_id, job.id);
}

/// Completed jobs kept for a later `wait` or `list`. `ck_job` is
/// start-and-forget, so a finished job has to stay retrievable; without a
/// bound the tables only grow, and in a long-lived `clanker serve` that
/// retains every background subagent's task and result text (kilobytes
/// apiece) for the life of the process, plus a linear scan over the lot on
/// every lookup.
const max_retained_done = 64;

/// Frees one job and joins its waiter thread. Caller must have removed it
/// from its table first, so nothing else can reach it.
fn destroyJob(comptime T: type, job: *T, gpa: std.mem.Allocator) void {
    if (job.thread) |th| th.join();
    gpa.free(job.id);
    gpa.free(job.session_id);
    if (T == SubJob) {
        gpa.free(job.task);
        if (job.result) |r| gpa.free(r);
        if (job.err_name) |e| gpa.free(e);
    }
    gpa.destroy(job);
}

/// Drops the oldest completed jobs past `max_retained_done`. Callers hold
/// `mu`; the joins here are on threads that already stored `done`, so they
/// return at once and cannot re-enter the lock.
fn reapDone(comptime T: type, list: *std.ArrayList(*T), gpa: std.mem.Allocator) void {
    var done_count: usize = 0;
    for (list.items) |j| {
        if (j.done.load(.acquire) and j.waiting == 0) done_count += 1;
    }
    if (done_count <= max_retained_done) return;
    var to_drop = done_count - max_retained_done;
    var i: usize = 0;
    while (i < list.items.len and to_drop > 0) {
        const j = list.items[i];
        if (!j.done.load(.acquire) or j.waiting != 0) {
            i += 1;
            continue;
        }
        _ = list.orderedRemove(i);
        to_drop -= 1;
        destroyJob(T, j, gpa);
    }
}

/// Hands this job's thread handle to exactly one caller. Under `mu` so a
/// reap and a concurrent `wait` on the same job never both join it.
fn takeThreadLocked(job: anytype) ?std.Thread {
    const th = job.thread;
    job.thread = null;
    return th;
}

/// When two callers `wait` the same job, exactly one takes the thread handle.
/// The other must not read the job's result yet: the owner is about to join
/// the thread that sets it. Spinning on `done` (set after result/term) makes
/// the second waiter observe the same completed job instead of a spurious
/// "wait failed" / empty text.
fn awaitJobDone(job: anytype) void {
    while (!job.done.load(.acquire)) std.Thread.yield() catch {};
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
        .origin = Origin.capture(),
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
        reapDone(ExecJob, &execs, gpa);
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
    _ = job_starts_total.fetchAdd(1, .monotonic);
    _ = jobs_active.fetchAdd(1, .monotonic);
    // argv[0] only: the rest can carry paths and prompt text, and the full
    // command is already recoverable from the run graph.
    log.log(.info, "job started kind=exec job={s} session={s} pid={d} cmd={s}", .{
        kind, sid, pid, argv[0],
    });
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
    var thread: ?std.Thread = null;
    {
        mu.lock();
        defer mu.unlock();
        found = findExec(id);
        // Claim the job before releasing the lock: a concurrent `startExec`
        // reaps completed jobs, and without the claim it could free this one
        // out from under the read below.
        if (found) |j| {
            j.waiting += 1;
            thread = takeThreadLocked(j);
        }
    }
    const job = found orelse return error.NotFound;
    defer {
        mu.lock();
        job.waiting -= 1;
        mu.unlock();
    }
    if (thread) |th| th.join();
    awaitJobDone(job);
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
        .origin = Origin.capture(),
        .thread = thread,
    };
    reapDone(SubJob, &subs, gpa);
    try subs.append(gpa, job);
    _ = job_starts_total.fetchAdd(1, .monotonic);
    _ = jobs_active.fetchAdd(1, .monotonic);
    log.log(.info, "job started kind=subagent job={s} session={s}", .{ id, session_id });
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
        _ = job_completions_total.fetchAdd(1, .monotonic);
        _ = jobs_active.fetchSub(1, .monotonic);
        // A background subagent's failure reaches nobody unless the model
        // happens to call `wait` on it, and it is under no obligation to.
        // This is the only place the error name is guaranteed to be seen.
        log.setContext(j.origin.slice());
        defer log.clearContext();
        if (err_name) |e| {
            _ = job_errors_total.fetchAdd(1, .monotonic);
            log.log(.warn, "job failed kind=subagent job={s} session={s} err={s}", .{ id, j.session_id, e });
        } else {
            log.log(.debug, "job finished kind=subagent job={s} session={s} bytes={d}", .{
                id, j.session_id, if (result) |r| r.len else 0,
            });
        }
        return;
    }
    // No row for this id. The thread is spawned before `registerSub` runs, so
    // a subagent that finishes first lands here: its result is dropped and the
    // row it is about to create will read `running` for the life of the
    // process, never reaped and never decrementing `jobs_active`. Silent
    // before; the drifting gauge and this line are what make it visible.
    log.log(.warn, "job completion has no registered row job={s} result_dropped={}", .{
        id, result != null or err_name != null,
    });
}

pub fn waitSub(arena: std.mem.Allocator, id: []const u8) ![]const u8 {
    var found: ?*SubJob = null;
    var thread: ?std.Thread = null;
    {
        mu.lock();
        defer mu.unlock();
        for (subs.items) |j| {
            if (std.mem.eql(u8, j.id, id)) {
                found = j;
                break;
            }
        }
        if (found) |j| {
            j.waiting += 1;
            thread = takeThreadLocked(j);
        }
    }
    const job = found orelse return error.NotFound;
    defer {
        mu.lock();
        job.waiting -= 1;
        mu.unlock();
    }
    if (thread) |th| th.join();
    awaitJobDone(job);
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
    var thread: ?std.Thread = null;
    {
        mu.lock();
        defer mu.unlock();
        found = findExec(id);
        if (found) |j| {
            j.waiting += 1;
            thread = takeThreadLocked(j);
        }
    }
    if (found) |job| {
        defer {
            mu.lock();
            job.waiting -= 1;
            mu.unlock();
        }
        if (!job.done.load(.acquire)) {
            // Residual posix: signal delivery has no std.Io equivalent.
            std.posix.kill(job.pid, std.posix.SIG.TERM) catch {};
        }
        if (thread) |th| th.join();
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
        destroyJob(ExecJob, job orelse break, gpa);
    }
    while (true) {
        const job: ?*SubJob = blk: {
            mu.lock();
            defer mu.unlock();
            break :blk subs.pop();
        };
        destroyJob(SubJob, job orelse break, gpa);
    }
    mu.lock();
    defer mu.unlock();
    execs.deinit(gpa);
    execs = .empty;
    subs.deinit(gpa);
    subs = .empty;
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

test "completed background jobs are reaped past the retention cap" {
    const gpa = std.testing.allocator;
    defer testingClear(gpa);

    // Twice the cap, each finished before the next registers, so every one
    // of them is reapable by the time the table is due a sweep.
    const total = max_retained_done * 2;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        var id_buf: [16]u8 = undefined;
        const id = makeId(@intCast(i), &id_buf);
        const th = try std.Thread.spawn(.{}, struct {
            fn run() void {}
        }.run, .{});
        try registerSub(gpa, id, "sess-reap", "task text", th);
        finishSub(id, "result text", null);
    }

    mu.lock();
    defer mu.unlock();
    // The cap bounds what is retained; the newest job has not been swept
    // yet (a sweep runs at the *next* registration), hence the +1.
    try std.testing.expect(subs.items.len <= max_retained_done + 1);
    try std.testing.expect(subs.items.len > 0);
}

test "Origin.capture copies the starter's log context and bounds it" {
    log.clearContext();
    try std.testing.expectEqualStrings("", Origin.capture().slice());

    log.setContext("http-42");
    defer log.clearContext();
    try std.testing.expectEqualStrings("http-42", Origin.capture().slice());

    // A context longer than the inline buffer is truncated, never overflowed.
    const long = "run-" ++ ("9" ** 64);
    log.setContext(long);
    const capped = Origin.capture();
    try std.testing.expectEqual(@as(usize, 32), capped.slice().len);
    try std.testing.expectEqualStrings(long[0..32], capped.slice());
}

test "snapshotJobMetrics reports the live counters" {
    const before = snapshotJobMetrics();
    _ = job_starts_total.fetchAdd(1, .monotonic);
    _ = jobs_active.fetchAdd(1, .monotonic);
    defer {
        _ = job_starts_total.fetchSub(1, .monotonic);
        _ = jobs_active.fetchSub(1, .monotonic);
    }
    const after = snapshotJobMetrics();
    try std.testing.expectEqual(before.starts_total + 1, after.starts_total);
    try std.testing.expectEqual(before.active + 1, after.active);
}
