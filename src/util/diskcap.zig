//! A ceiling on the build cache.
//!
//! Every gate run compiles a staging tree, and zig's local cache is a link
//! farm that only ever grows: nothing in zig prunes it. On this machine it
//! reached 72 GB and filled the disk, at which point no gate can run and
//! self-improvement stops entirely.
//!
//! Dropping the local cache is cheap, which is what makes a hard cap the right
//! answer rather than a careful eviction policy: the expensive artifacts live
//! in zig's global cache, so the next build re-links them in about a second.

const std = @import("std");
const log = @import("log.zig");

/// Total bytes of the regular files under `rel`, following no symlinks.
/// Missing directory means zero, not an error: there is nothing to cap.
pub fn dirSize(io: std.Io, base: std.Io.Dir, gpa: std.mem.Allocator, rel: []const u8) u64 {
    var dir = base.openDir(io, rel, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var total: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const sub = std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel, entry.name }) catch continue;
        defer gpa.free(sub);
        switch (entry.kind) {
            .directory => total += dirSize(io, base, gpa, sub),
            .file => {
                const st = base.statFile(io, sub, .{}) catch continue;
                total += st.size;
            },
            else => {},
        }
    }
    return total;
}

/// Deletes `rel` when it exceeds `limit`, and reports whether it did.
///
/// Only ever a build cache: a recursive delete that takes a path is one wrong
/// argument away from eating the working tree, and this one runs unattended.
pub fn capBuildCache(
    gpa: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    rel: []const u8,
    limit: u64,
) bool {
    if (!isBuildCachePath(rel)) {
        log.log(.warn, "refusing to cap '{s}': not a build cache", .{rel});
        return false;
    }
    if (limit == 0) return false;
    const size = dirSize(io, base, gpa, rel);
    if (size <= limit) return false;

    log.log(.info, "build cache {s} is {d} MiB (limit {d} MiB); dropping it", .{
        rel,
        size >> 20,
        limit >> 20,
    });
    removeTree(gpa, io, base, rel);
    return true;
}

/// A path is a build cache when its last component is `.zig-cache` and it
/// contains no traversal.
pub fn isBuildCachePath(rel: []const u8) bool {
    if (rel.len == 0) return false;
    if (std.mem.find(u8, rel, "..") != null) return false;
    if (rel[0] == '/') return false;
    const name = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| rel[i + 1 ..] else rel;
    return std.mem.eql(u8, name, ".zig-cache");
}

/// Recursively deletes `rel` (relative to `base`), including symlinks and
/// other non-directory entries. Callers are responsible for validating that
/// `rel` is safe to remove: this walks and deletes unconditionally.
pub fn removeTree(gpa: std.mem.Allocator, io: std.Io, base: std.Io.Dir, rel: []const u8) void {
    var dir = base.openDir(io, rel, .{ .iterate = true }) catch return;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const sub = std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel, entry.name }) catch continue;
        defer gpa.free(sub);
        switch (entry.kind) {
            .directory => removeTree(gpa, io, base, sub),
            else => base.deleteFile(io, sub) catch {},
        }
    }
    dir.close(io);
    base.deleteDir(io, rel) catch {};
}

// ------------------------------------------------------------------- tests --

test "only a build cache can be capped" {
    // This deletes a directory tree unattended, so the predicate is the whole
    // safety story.
    try std.testing.expect(isBuildCachePath(".zig-cache"));
    try std.testing.expect(isBuildCachePath("state/staging/imp-1/.zig-cache"));
    try std.testing.expect(!isBuildCachePath("src"));
    try std.testing.expect(!isBuildCachePath(""));
    try std.testing.expect(!isBuildCachePath("/"));
    try std.testing.expect(!isBuildCachePath("/home/maci/.zig-cache"));
    try std.testing.expect(!isBuildCachePath("../.zig-cache"));
    try std.testing.expect(!isBuildCachePath(".zig-cache/o"));
}

test "a cache over the limit is dropped, one under it is left alone" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".zig-cache/o/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = ".zig-cache/o/deep/artifact", .data = "0123456789" });

    try std.testing.expectEqual(@as(u64, 10), dirSize(io, tmp.dir, std.testing.allocator, ".zig-cache"));

    // Under the limit: untouched.
    try std.testing.expect(!capBuildCache(std.testing.allocator, io, tmp.dir, ".zig-cache", 1024));
    try std.testing.expectEqual(@as(u64, 10), dirSize(io, tmp.dir, std.testing.allocator, ".zig-cache"));

    // Over it: gone, including the nesting.
    try std.testing.expect(capBuildCache(std.testing.allocator, io, tmp.dir, ".zig-cache", 4));
    try std.testing.expectEqual(@as(u64, 0), dirSize(io, tmp.dir, std.testing.allocator, ".zig-cache"));

    // A path that is not a build cache is refused even when it is huge.
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "0123456789" });
    try std.testing.expect(!capBuildCache(std.testing.allocator, io, tmp.dir, "src", 1));
    try std.testing.expectEqual(@as(u64, 10), dirSize(io, tmp.dir, std.testing.allocator, "src"));
}
