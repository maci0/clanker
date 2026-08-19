//! One improvement run at a time, per working tree.
//!
//! Two `clanker improve-self` processes share a git tree, a zig cache and a
//! staging directory. They gate each other's half-applied work, promote over
//! each other, and their commits race: this repository has already ended up
//! with a tree that did not compile, and with a change promoted to disk whose
//! commit lost and left it uncommitted.
//!
//! The lock is a file holding the owning process id. A process that dies
//! without releasing leaves the file behind, so a lock whose owner no longer
//! exists is taken over rather than honoured forever. Liveness is probed with
//! signal 0, the usual trick: this std types the signal argument as an enum,
//! but a non-exhaustive one, so 0 is expressible after all. /proc, which this
//! used to read instead, does not exist on macOS or the BSDs — so every lookup
//! there answered "no such process" and the lock was never honoured at all.

const std = @import("std");
const log = @import("log.zig");

pub const Lock = struct {
    dir: std.Io.Dir,
    io: std.Io,
    path: []const u8,
    held: bool = false,

    /// Releases the lock if this process holds it. Safe to call twice.
    pub fn release(self: *Lock) void {
        if (!self.held) return;
        self.held = false;
        self.dir.deleteFile(self.io, self.path) catch |err| {
            log.log(.warn, "could not remove the run lock {s}: {s}", .{ self.path, @errorName(err) });
        };
    }
};

pub const Error = error{Busy};

/// Takes the lock, or fails with `Busy` and the id of the process that holds
/// it. `path` is relative to `dir`.
pub fn acquire(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    path: []const u8,
    holder: *?u32,
) !Lock {
    if (try tryCreate(io, gpa, dir, path)) |lock| return lock;

    // Held, or left behind. Only the second is ours to clear.
    const owner = readOwner(io, gpa, dir, path);
    if (owner) |pid| {
        if (processExists(pid)) {
            holder.* = pid;
            return Error.Busy;
        }
        log.log(.info, "clearing a run lock left by process {d}, which no longer exists", .{pid});
    } else {
        log.log(.info, "clearing a run lock with no readable owner", .{});
    }
    dir.deleteFile(io, path) catch {};

    if (try tryCreate(io, gpa, dir, path)) |lock| return lock;
    // Someone else won the race for the stale lock; theirs is valid.
    holder.* = readOwner(io, gpa, dir, path);
    return Error.Busy;
}

fn tryCreate(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) !?Lock {
    // The exclusive flock is held from create until the close below, i.e.
    // across the pid write. O_EXCL create only succeeds on a file that did
    // not exist, so the flock never contends at open; its job is to tell a
    // concurrent `readOwner` that the pid is not there yet. Without it the
    // file is visible to other processes the instant O_EXCL returns, and a
    // second acquirer could read the empty file, decide the lock was stale,
    // delete it and create its own — two improve-self runs in one tree,
    // which is the corruption this lock exists to prevent.
    var file = dir.createFile(io, path, .{ .exclusive = true, .lock = .exclusive }) catch |err| switch (err) {
        error.PathAlreadyExists => return null,
        else => return err,
    };
    defer file.close(io);

    const text = try std.fmt.allocPrint(gpa, "{d}\n", .{selfPid()});
    defer gpa.free(text);
    var buf: [64]u8 = undefined;
    var w = file.writer(io, &buf);
    w.interface.writeAll(text) catch |err| {
        dir.deleteFile(io, path) catch {};
        return err;
    };
    w.interface.flush() catch |err| {
        dir.deleteFile(io, path) catch {};
        return err;
    };

    return .{ .dir = dir, .io = io, .path = path, .held = true };
}

fn readOwner(io: std.Io, _: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) ?u32 {
    // The open takes a blocking exclusive flock, matching the flock the
    // creator holds across its pid write in `tryCreate`. A read that raced
    // the create used to see the empty file between O_EXCL and the write,
    // and `acquire` then deleted a lock that was being taken right then;
    // now the open waits for the creator to finish writing (or to die,
    // which releases the flock) and only then reads, so an unreadable owner
    // is genuinely stale, never mid-write.
    var file = dir.openFile(io, path, .{ .lock = .exclusive }) catch return null;
    defer file.close(io);
    var buf: [64]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch return null;
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return std.fmt.parseInt(u32, trimmed, 10) catch null;
}

fn selfPid() u32 {
    return @intCast(std.c.getpid());
}

/// Whether a process with this id is alive, probed with signal 0, which runs
/// kill(2)'s existence and permission checks and delivers nothing.
fn processExists(pid: u32) bool {
    // kill(2) reads 0 and negative pids as process *group* selectors, and a
    // value past pid_t cannot name a process at all: none of them is a live
    // owner, and passing them through would probe something else entirely.
    if (pid == 0 or pid > std.math.maxInt(std.posix.pid_t)) return false;
    // Residual posix: kill(2) liveness probe has no std.Io equivalent.
    // Only ProcessNotFound (ESRCH) is a confirmed absence. PermissionDenied
    // (EPERM) means it is alive and owned by another user, and Unexpected is
    // doubt, which the comment at the top promises to treat as held: refusing
    // to start is recoverable, two runs corrupting a tree is not.
    std.posix.kill(@intCast(pid), @enumFromInt(0)) catch |err| {
        return err != error.ProcessNotFound;
    };
    return true;
}

// ------------------------------------------------------------------- tests --

test "a second acquire fails while the first is held, and succeeds after release" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var holder: ?u32 = null;
    var first = try acquire(io, std.testing.allocator, tmp.dir, "run.lock", &holder);
    try std.testing.expect(first.held);

    try std.testing.expectError(Error.Busy, acquire(io, std.testing.allocator, tmp.dir, "run.lock", &holder));
    // The caller can say who is in the way.
    try std.testing.expectEqual(selfPid(), holder orelse 0);

    first.release();
    var second = try acquire(io, std.testing.allocator, tmp.dir, "run.lock", &holder);
    try std.testing.expect(second.held);
    second.release();

    // Releasing twice is not an error, and does not remove someone else's lock.
    second.release();
}

test "a lock left by a dead process is taken over" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A pid that cannot be running: the kernel's own limit is well below this.
    try tmp.dir.writeFile(io, .{ .sub_path = "run.lock", .data = "4294967290\n" });
    var holder: ?u32 = null;
    var lock = try acquire(io, std.testing.allocator, tmp.dir, "run.lock", &holder);
    try std.testing.expect(lock.held);
    try std.testing.expectEqual(selfPid(), readOwner(io, std.testing.allocator, tmp.dir, "run.lock") orelse 0);
    lock.release();

    // Garbage in the file is treated the same way: it names no live owner.
    try tmp.dir.writeFile(io, .{ .sub_path = "run.lock", .data = "not a pid" });
    var again = try acquire(io, std.testing.allocator, tmp.dir, "run.lock", &holder);
    try std.testing.expect(again.held);
    again.release();
}

test "a lock being written by a live process is waited for, not stolen" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The creator's race window, reproduced: the file exists (O_EXCL create)
    // but the pid has not been written yet, and the creator holds the
    // exclusive flock across the window, the way tryCreate now does.
    var creator = try tmp.dir.createFile(io, "run.lock", .{ .exclusive = true, .lock = .exclusive });

    const Outcome = struct {
        err: ?anyerror = null,
        lock: ?Lock = null,
    };
    const Worker = struct {
        fn run(self: *Outcome, w_io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, holder: *?u32) void {
            if (acquire(w_io, gpa, dir, "run.lock", holder)) |lock| {
                self.lock = lock;
            } else |err| {
                self.err = err;
            }
        }
    };
    var outcome: Outcome = .{};
    var holder: ?u32 = null;
    const th = try std.Thread.spawn(.{}, Worker.run, .{ &outcome, io, std.testing.allocator, tmp.dir, &holder });

    // Give the second acquirer every chance to read while the file is still
    // empty (it blocks on the creator's flock instead), then complete the
    // pid write the creator was in the middle of.
    var scratch: [32]u8 = undefined;
    var w = creator.writer(io, &scratch);
    var pid_data: [32]u8 = undefined;
    try w.interface.writeAll(try std.fmt.bufPrint(&pid_data, "{d}\n", .{selfPid()}));
    try w.interface.flush();
    creator.close(io);

    th.join();
    // The second acquirer saw a live owner and reported Busy with its pid —
    // it must not have deleted the lock and acquired it itself.
    const got = outcome.err orelse return error.TestExpectedBusy;
    try std.testing.expectEqual(@as(anyerror, error.Busy), got);
    try std.testing.expect(outcome.lock == null);
    try std.testing.expectEqual(selfPid(), holder orelse 0);
    try std.testing.expect((tmp.dir.statFile(io, "run.lock", .{}) catch null) != null);
}

test "a live process is reported alive and a dead one is not" {
    try std.testing.expect(processExists(selfPid()));

    // Past every platform's pid ceiling (macOS stops at 99999, Linux at
    // 4194304), so nothing can be running under it, but still inside pid_t.
    try std.testing.expect(!processExists(0x7fff_fff0));

    // Out of pid_t's range entirely, and the group selectors: none of these
    // names a process, and each one has to be rejected before it reaches
    // kill(2) rather than by it.
    try std.testing.expect(!processExists(4294967290));
    try std.testing.expect(!processExists(0));
}
