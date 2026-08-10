//! Atomic file writes: the destination either has its old complete contents
//! or its new complete contents, never a partial write. Matters wherever a
//! reader (a hot-reloaded process resuming a session, a peer reading
//! another instance's state) could otherwise observe a file truncated
//! mid-write by a crash, a kill, or an in-flight `execve` restart.

const std = @import("std");

/// Writes `data` to `sub_path` under `dir` via a temp file + atomic rename
/// (`Dir.createFileAtomic`), so a process death mid-write leaves the old
/// file intact instead of a truncated one. `make_path` creates missing
/// parent directories first, matching plain `Dir.writeFile`'s behavior when
/// callers already `createDirPath` before writing.
pub fn writeFile(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, data: []const u8) !void {
    var af = try dir.createFileAtomic(io, sub_path, .{ .replace = true, .make_path = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, data);
    try af.replace(io);
}

test "writeFile replaces existing content atomically" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "note.txt", "first");
    const first = try tmp.dir.readFileAlloc(io, "note.txt", allocator, .limited(1 << 10));
    defer allocator.free(first);
    try std.testing.expectEqualStrings("first", first);

    try writeFile(io, tmp.dir, "note.txt", "second, longer than first");
    const second = try tmp.dir.readFileAlloc(io, "note.txt", allocator, .limited(1 << 10));
    defer allocator.free(second);
    try std.testing.expectEqualStrings("second, longer than first", second);
}

test "writeFile creates missing parent directories" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(io, tmp.dir, "nested/deep/file.txt", "hi");
    const got = try tmp.dir.readFileAlloc(io, "nested/deep/file.txt", allocator, .limited(1 << 10));
    defer allocator.free(got);
    try std.testing.expectEqualStrings("hi", got);
}
