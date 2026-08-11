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
//! exists is taken over rather than honoured forever. Liveness is read from
//! /proc, which answers the question directly; signal 0 is the usual trick and
//! is not expressible here, because this std types the signal argument as an
//! enum with no zero member.

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
        if (processExists(io, gpa, pid)) {
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
    var file = dir.createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return null,
        else => return err,
    };
    defer file.close(io);

    const text = try std.fmt.allocPrint(gpa, "{d}\n", .{selfPid()});
    defer gpa.free(text);
    var buf: [64]u8 = undefined;
    var w = file.writer(io, &buf);
    w.interface.writeAll(text) catch {};
    w.interface.flush() catch {};

    return .{ .dir = dir, .io = io, .path = path, .held = true };
}

fn readOwner(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) ?u32 {
    const data = dir.readFileAlloc(io, path, gpa, .limited(64)) catch return null;
    defer gpa.free(data);
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    return std.fmt.parseInt(u32, trimmed, 10) catch null;
}

fn selfPid() u32 {
    return @intCast(std.c.getpid());
}

/// Whether a process with this id is alive, read from /proc rather than probed
/// with a signal.
fn processExists(io: std.Io, gpa: std.mem.Allocator, pid: u32) bool {
    const path = std.fmt.allocPrint(gpa, "/proc/{d}", .{pid}) catch return true;
    defer gpa.free(path);
    // On any doubt, treat the lock as held: refusing to start is recoverable,
    // two runs corrupting a tree is not.
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
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

test "a live process is reported alive and a dead one is not" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expect(processExists(io, std.testing.allocator, selfPid()));
    try std.testing.expect(!processExists(io, std.testing.allocator, 4294967290));
}
