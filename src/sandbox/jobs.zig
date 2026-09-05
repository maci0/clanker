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

/// Records the allocator `finishSub` copies a held completion with, for a
/// starter that spawns its worker before it registers the row. The
/// background subagent path does exactly that, so a worker finishing before
/// `registerSub` reached `finishSub` with no allocator recorded yet on the
/// process's first job: the completion was dropped, the row was born
/// `running` and stayed so for the life of the process, and `waitSub` spun
/// on `done` forever at 100% of a core. `startExec` and `registerSub` record
/// it too; this is the same store, reachable before the spawn.
pub fn rememberAllocator(gpa: std.mem.Allocator) void {
    mu.lock();
    defer mu.unlock();
    gpa_ref = gpa;
}

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
        subActive();
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
    subActive();
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

/// Ceiling on jobs running at the same time, exec children and background
/// subagents together (a swarm's own per-call bound is `max_swarm_tasks` in
/// host.zig). Every accepted job holds one child process or one 128 MiB-stack
/// nested-agent thread for its whole runtime, so without an admission gate a
/// guest loop of start calls scales live jobs until fd/pid pressure kills the
/// harness. Checked before anything is spawned; a race between concurrent
/// starts can overshoot by a handful, never by unbounded.
pub const max_active_jobs: usize = 16;

fn activeLocked() usize {
    var n: usize = 0;
    for (execs.items) |j| {
        if (!j.done.load(.acquire)) n += 1;
    }
    for (subs.items) |j| {
        if (!j.done.load(.acquire)) n += 1;
    }
    return n;
}

/// Live-job count for admission checks made before the caller has spawned
/// anything worth unwinding (the background-subagent thread). The
/// authoritative check runs again under `mu` in `startExec`/`registerSub`.
pub fn activeJobCount() usize {
    mu.lock();
    defer mu.unlock();
    return activeLocked();
}

/// Decrements `jobs_active` without wrapping: one failure path (the append
/// unwind in `startExec`) decrements from a start that was never added, and a
/// plain fetchSub there read ~2^64 active jobs for the rest of the process.
fn subActive() void {
    while (true) {
        const cur = jobs_active.load(.monotonic);
        if (cur == 0) return;
        if (jobs_active.cmpxchgWeak(cur, cur - 1, .acq_rel, .monotonic) == null) return;
    }
}

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

/// Same-session rule for every per-job verb. `list` filters rows by the
/// caller's session (listJson), and the registry half of `kill` matches the
/// session key too; kill/wait used to look ids up globally instead, so one
/// session's guest could terminate or read another session's job by naming
/// its id. A job id is 16 hex chars mixed from a nanosecond timestamp -- a
/// label, not a capability. Empty caller scope owns nothing: absence of a
/// session is not authority over every row.
fn sessionOwned(job_session: []const u8, caller_session: []const u8) bool {
    return caller_session.len > 0 and std.mem.eql(u8, job_session, caller_session);
}

pub fn startExec(
    io: std.Io,
    gpa: std.mem.Allocator,
    reg: *subprocess.Registry,
    session_id: []const u8,
    root_dir: []const u8,
    environ_map: *const std.process.Environ.Map,
    argv: []const []const u8,
) ![]const u8 {
    if (argv.len == 0) return error.InvalidArg;
    // Refuse before anything is spawned, so a saturated harness owes no
    // child, no registry row, and no waiter thread.
    if (activeJobCount() >= max_active_jobs) {
        log.log(.warn, "job refused kind=exec session={s}: {d} job(s) already running at the active cap {d}", .{ session_id, activeJobCount(), max_active_jobs });
        return error.JobBusy;
    }
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
        // Explicit, never inherited: a job child would otherwise carry the
        // harness's whole environment, API keys included. ck_job hands over
        // the same envAllowed-filtered map ck_exec uses, so a job process
        // holds no credential the guest itself could not read.
        .environ_map = environ_map,
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
        // The allocator behind `finishSub`'s copies: every writer sets it
        // under `mu` (`registerSub` does the same below), because background
        // subagent threads read it under `mu` in `finishSub`. A store outside
        // the lock was a plain data race with that locked read.
        gpa_ref = gpa;
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

pub fn waitExec(arena: std.mem.Allocator, session_id: []const u8, id: []const u8) ![]const u8 {
    var found: ?*ExecJob = null;
    var thread: ?std.Thread = null;
    {
        mu.lock();
        defer mu.unlock();
        for (execs.items) |j| {
            if (std.mem.eql(u8, j.id, id) and sessionOwned(j.session_id, session_id)) {
                found = j;
                break;
            }
        }
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

/// A completion that landed before its row existed. The subagent thread is
/// spawned before `registerSub` runs, so a fast finisher used to drop its
/// result here and leave the row it was about to create reading `running`
/// for the life of the process: never reaped, never decrementing
/// `jobs_active`, and (ownership following the false return) leaking the
/// caller's task/id copies. Held completions are consumed by the matching
/// `registerSub`, which marks its row done at creation instead.
const LateSub = struct {
    id: []u8,
    result: ?[]u8 = null,
    err_name: ?[]u8 = null,
};

var late_subs: std.ArrayList(LateSub) = .empty;

/// Bound on held completions: they exist only to close a race window of one
/// registration, so a handful covers any real burst, and a table that only
/// grows would trade the ghost-row leak for another one. Oldest entries are
/// dropped past the cap.
const max_late_subs = 16;

fn freeLate(rec: LateSub, gpa: std.mem.Allocator) void {
    gpa.free(rec.id);
    if (rec.result) |r| gpa.free(r);
    if (rec.err_name) |e| gpa.free(e);
}

pub fn registerSub(gpa: std.mem.Allocator, id: []const u8, session_id: []const u8, task: []const u8, thread: std.Thread) !void {
    mu.lock();
    defer mu.unlock();
    gpa_ref = gpa;
    if (activeLocked() >= max_active_jobs) {
        log.log(.warn, "job refused kind=subagent session={s}: {d} job(s) already running at the active cap {d}", .{ session_id, activeLocked(), max_active_jobs });
        return error.JobBusy;
    }
    const job = try gpa.create(SubJob);
    errdefer gpa.destroy(job);
    job.* = .{
        .id = try gpa.dupe(u8, id),
        .session_id = try gpa.dupe(u8, session_id),
        .task = try gpa.dupe(u8, task),
        .origin = Origin.capture(),
        .thread = thread,
    };
    // Consume a completion that raced ahead of this registration: attach its
    // outcome so the row is born done -- reapable like any other finished
    // job instead of stuck running forever. Counters stay balanced by
    // counting the completion here rather than adding an active that never
    // was.
    var late_done = false;
    for (late_subs.items, 0..) |rec, i| {
        if (!std.mem.eql(u8, rec.id, id)) continue;
        job.result = rec.result;
        job.err_name = rec.err_name;
        job.done.store(true, .release);
        const matched = late_subs.orderedRemove(i);
        gpa.free(matched.id);
        late_done = true;
        break;
    }
    reapDone(SubJob, &subs, gpa);
    subs.append(gpa, job) catch |err| {
        // Never join here: in the non-late case the worker thread is still
        // running the subagent, and it touches nothing left in `job`.
        gpa.free(job.id);
        gpa.free(job.session_id);
        gpa.free(job.task);
        if (job.result) |r| gpa.free(r);
        if (job.err_name) |e| gpa.free(e);
        return err;
    };
    _ = job_starts_total.fetchAdd(1, .monotonic);
    if (late_done) {
        _ = job_completions_total.fetchAdd(1, .monotonic);
        log.log(.debug, "job started kind=subagent job={s} session={s} (completion had raced ahead)", .{ id, session_id });
    } else {
        _ = jobs_active.fetchAdd(1, .monotonic);
        log.log(.info, "job started kind=subagent job={s} session={s}", .{ id, session_id });
    }
}

/// Marks a background subagent's row done and stores its result. Returns
/// whether the job table took ownership of the outcome -- either onto a
/// matching row, or held in `late_subs` for the registration that is about
/// to create one.
///
/// A true return is the ownership signal for the caller: the job table holds
/// its own copies, so the caller may free its originals. Only a completion
/// that could not be copied at all returns false, leaving ownership with the
/// caller.
pub fn finishSub(id: []const u8, result: ?[]const u8, err_name: ?[]const u8) bool {
    mu.lock();
    defer mu.unlock();
    const gpa = gpa_ref orelse return false;
    for (subs.items) |j| {
        if (!std.mem.eql(u8, j.id, id)) continue;
        if (result) |r| j.result = gpa.dupe(u8, r) catch null;
        if (err_name) |e| j.err_name = gpa.dupe(u8, e) catch null;
        j.done.store(true, .release);
        _ = job_completions_total.fetchAdd(1, .monotonic);
        subActive();
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
        return true;
    }
    // No row yet: hold the completion so `registerSub` can mark its row done
    // at creation (see `LateSub`). The completion counters are charged here,
    // where the work actually finished; registration then adds only
    // `starts_total`. The true return is also the caller's signal that the
    // job system owns copies of everything now, exactly as when a row
    // matched.
    held: {
        const id_copy = gpa.dupe(u8, id) catch break :held;
        var rec: LateSub = .{ .id = id_copy };
        if (result) |r| rec.result = gpa.dupe(u8, r) catch null;
        if (err_name) |e| rec.err_name = gpa.dupe(u8, e) catch null;
        while (late_subs.items.len >= max_late_subs) {
            const oldest = late_subs.orderedRemove(0);
            freeLate(oldest, gpa);
        }
        if (late_subs.append(gpa, rec)) {
            _ = job_completions_total.fetchAdd(1, .monotonic);
            log.log(.debug, "job completion raced ahead of registration job={s}; held for the row", .{id});
            return true;
        } else |_| {
            freeLate(rec, gpa);
        }
    }
    // Could not even copy the id: drop as before, loudly, with ownership
    // left to the caller.
    log.log(.warn, "job completion has no registered row job={s} result_dropped={}", .{
        id, result != null or err_name != null,
    });
    return false;
}

pub fn waitSub(arena: std.mem.Allocator, session_id: []const u8, id: []const u8) ![]const u8 {
    var found: ?*SubJob = null;
    var thread: ?std.Thread = null;
    {
        mu.lock();
        defer mu.unlock();
        for (subs.items) |j| {
            if (std.mem.eql(u8, j.id, id) and sessionOwned(j.session_id, session_id)) {
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
        for (execs.items) |j| {
            if (std.mem.eql(u8, j.id, id) and sessionOwned(j.session_id, session_id)) {
                found = j;
                break;
            }
        }
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

/// SIGTERM still-running exec children, join leftover waiter threads, and
/// free the tables. Call once at process exit: completed rows stay
/// retrievable until `max_retained_done`, and those copies plus the
/// ArrayList backings would otherwise leak into the DebugAllocator report.
pub fn deinit(gpa: std.mem.Allocator) void {
    {
        mu.lock();
        defer mu.unlock();
        for (execs.items) |j| {
            if (!j.done.load(.acquire) and j.pid > 0) {
                std.posix.kill(j.pid, std.posix.SIG.TERM) catch {};
            }
        }
    }
    testingClear(gpa);
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
    for (late_subs.items) |rec| freeLate(rec, gpa);
    late_subs.deinit(gpa);
    late_subs = .empty;
}

test "deinit on empty job tables is a no-op" {
    deinit(std.testing.allocator);
    deinit(std.testing.allocator);
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
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const id = startExec(io, std.testing.allocator, &reg, "sess-job", ".", &env, &.{"true"}) catch |err| switch (err) {
        error.InvalidArg => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(id);
    defer testingClear(std.testing.allocator);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try waitExec(arena_state.allocator(), "sess-job", id);
    try std.testing.expect(std.mem.find(u8, got, "\"done\":true") != null);
    try std.testing.expect(std.mem.find(u8, got, "\"exit\":0") != null);
    try std.testing.expect(reg.get("sess-job", id) == null);
}

test "wait and kill answer only the session that owns the job" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    defer testingClear(gpa);

    // Fabricated done rows: neither wait nor kill touches `child` or spawns
    // anything on these paths (done jobs are never signaled), so no process
    // is needed to pin the session rule.
    const exec_job = try gpa.create(ExecJob);
    exec_job.* = .{
        .id = try gpa.dupe(u8, "job-aaaa"),
        .session_id = try gpa.dupe(u8, "alpha"),
        .child = undefined,
        .pid = 0,
        .term = .{ .exited = 0 },
        .done = std.atomic.Value(bool).init(true),
    };
    try execs.append(gpa, exec_job);
    const sub_job = try gpa.create(SubJob);
    sub_job.* = .{
        .id = try gpa.dupe(u8, "sub-bbbb"),
        .session_id = try gpa.dupe(u8, "alpha"),
        .task = try gpa.dupe(u8, "task text"),
        .result = try gpa.dupe(u8, "parent-only answer"),
        .done = std.atomic.Value(bool).init(true),
    };
    try subs.append(gpa, sub_job);

    // Another session's guest gets the same answer as for a job that does
    // not exist: no exit status, no result text, no kill -- and an empty
    // caller scope owns nothing either.
    try std.testing.expectError(error.NotFound, waitExec(arena, "beta", "job-aaaa"));
    try std.testing.expectError(error.NotFound, waitSub(arena, "beta", "sub-bbbb"));
    try std.testing.expect(!kill(null, "beta", "job-aaaa"));
    try std.testing.expect(!kill(null, "", "job-aaaa"));

    // The owning session still waits and kills its own job.
    const got = try waitExec(arena, "alpha", "job-aaaa");
    try std.testing.expect(std.mem.find(u8, got, "\"exit\":0") != null);
    const sub_text = try waitSub(arena, "alpha", "sub-bbbb");
    try std.testing.expect(std.mem.find(u8, sub_text, "parent-only answer") != null);
    try std.testing.expect(kill(null, "alpha", "job-aaaa"));
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
        // The row exists by now, so the completion is attached and the
        // caller is told it may free its originals.
        try std.testing.expect(finishSub(id, "result text", null));
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

test "finishSub reports whether the job table took the outcome" {
    const gpa = std.testing.allocator;
    defer testingClear(gpa);
    var id_buf: [16]u8 = undefined;
    const id = makeId(1, &id_buf);
    const th = try std.Thread.spawn(.{}, struct {
        fn run() void {}
    }.run, .{});
    try registerSub(gpa, id, "sess-flag", "task text", th);
    // A completion for an id with no row is held for the registration that
    // may still be about to create it, so the table owns the copies and the
    // caller is told so.
    try std.testing.expect(finishSub("0000000000000000", "late result", null));
    try std.testing.expect(finishSub(id, "result text", null));
}

test "a completion that beats its registration lands on the row" {
    const gpa = std.testing.allocator;
    defer testingClear(gpa);
    // finishSub reads the allocator a prior registration left behind.
    gpa_ref = gpa;
    var id_buf: [16]u8 = undefined;
    const id = makeId(2, &id_buf);
    // The worker finishes before `registerSub` runs. The result used to be
    // dropped and the row it was about to create read `running` for the life
    // of the process, never reaped and never decrementing `jobs_active`.
    try std.testing.expect(finishSub(id, "raced result", null));
    const th = try std.Thread.spawn(.{}, struct {
        fn run() void {}
    }.run, .{});
    try registerSub(gpa, id, "sess-race", "task text", th);
    mu.lock();
    defer mu.unlock();
    try std.testing.expectEqual(@as(usize, 1), subs.items.len);
    const row = subs.items[0];
    try std.testing.expect(row.done.load(.acquire));
    try std.testing.expectEqualStrings("raced result", row.result.?);
    // The held entry is consumed, not left to accumulate.
    try std.testing.expectEqual(@as(usize, 0), late_subs.items.len);
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
