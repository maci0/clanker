//! An advisory lock around a read-modify-write on a state file.
//!
//! Several clanker processes share one state directory: an agent run, the
//! staged evals a promotion gate spawns, a loop driving the CLI. Any code that
//! reads a whole file, adds to it, and writes it back is a lost record waiting
//! to happen, because both writers start from the same contents and the second
//! write discards the first. The failure is silent: the file stays well formed
//! and is merely short. Measured on the chatroom log, six writers posting ten
//! messages each kept twelve of sixty.
//!
//! The lock is taken on a file of its own, never on the file being rewritten:
//! a rewrite replaces that file, and a lock held on a replaced file guards
//! nothing.

const std = @import("std");
const log = @import("log.zig");

pub const Guard = struct {
    file: ?std.Io.File = null,
    io: std.Io,

    pub fn release(self: *Guard) void {
        if (self.file) |f| f.close(self.io);
        self.file = null;
    }
};

/// Takes the lock for `name` under `dir`, or reports that it could not.
///
/// Best effort by design: losing a record is bad, and refusing to record
/// anything because a lock could not be taken is worse. A failure warns and
/// the caller proceeds unserialised.
pub fn acquire(io: std.Io, base: std.Io.Dir, dir: []const u8, name: []const u8, gpa: std.mem.Allocator) Guard {
    const path = std.fmt.allocPrint(gpa, "{s}/{s}.lock", .{ dir, name }) catch return .{ .io = io };
    defer gpa.free(path);
    const file = base.createFile(io, path, .{ .truncate = false, .lock = .exclusive }) catch |err| {
        log.log(.warn, "could not lock {s} ({s}); a concurrent write may be lost", .{ path, @errorName(err) });
        return .{ .io = io };
    };
    return .{ .file = file, .io = io };
}
