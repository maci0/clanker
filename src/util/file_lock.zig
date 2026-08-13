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

/// Opening with O_CREAT can spuriously fail with ENOENT when several opens
/// race on a name that does not exist yet: macOS loses the create/lookup
/// race in the kernel and reports the file missing even though it is about
/// to exist (observed at ~2 in 400 racing creates on macOS 15 / APFS; a
/// plain create with no lock flag reproduces it, so it is not a locking
/// problem). The failure window is one concurrent create, so a handful of
/// immediate retries always clears it.
const max_create_attempts = 16;

/// dir.createFile that retries transient ENOENT from racing creates. Every
/// create of a shared file that must not silently drop work (the lock file
/// itself, an append target) goes through here.
pub fn createFileRetry(io: std.Io, base: std.Io.Dir, path: []const u8, opts: std.Io.Dir.CreateFileOptions) !std.Io.File {
    var attempts: u32 = 1;
    while (true) : (attempts += 1) {
        return base.createFile(io, path, opts) catch |err| {
            if (err == error.FileNotFound and attempts < max_create_attempts) continue;
            return err;
        };
    }
}

/// Takes the lock for `name` under `dir`, or reports that it could not.
///
/// Best effort by design: losing a record is bad, and refusing to record
/// anything because a lock could not be taken is worse. A failure warns and
/// the caller proceeds unserialised.
pub fn acquire(io: std.Io, base: std.Io.Dir, dir: []const u8, name: []const u8, gpa: std.mem.Allocator) Guard {
    const path = std.fmt.allocPrint(gpa, "{s}/{s}.lock", .{ dir, name }) catch return .{ .io = io };
    defer gpa.free(path);
    const file = createFileRetry(io, base, path, .{ .truncate = false, .lock = .exclusive }) catch |err| {
        log.log(.warn, "could not lock {s} ({s}); a concurrent write may be lost", .{ path, @errorName(err) });
        return .{ .io = io };
    };
    return .{ .file = file, .io = io };
}

test "racing creates of one file all succeed" {
    // Without the retry, ~2 in 400 concurrent creates of a not-yet-existing
    // name fail ENOENT on macOS, and every such failure is a silently
    // dropped record upstream.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const Worker = struct {
        dir: std.Io.Dir,
        io: std.Io,
        failures: u32 = 0,
        fn run(self: *@This()) void {
            var i: usize = 0;
            while (i < 50) : (i += 1) {
                var f = createFileRetry(self.io, self.dir, "x.txt", .{ .truncate = false }) catch {
                    self.failures += 1;
                    continue;
                };
                f.close(self.io);
            }
        }
    };

    var workers: [8]Worker = undefined;
    var threads: [8]std.Thread = undefined;
    for (&workers, 0..) |*w, i| {
        w.* = .{ .dir = tmp.dir, .io = io };
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{w});
    }
    for (&threads) |*t| t.join();
    for (&workers) |*w| try std.testing.expectEqual(@as(u32, 0), w.failures);
}
