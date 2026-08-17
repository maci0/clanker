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
    // Write through a symlinked destination rather than onto the link. The
    // atomic part is a rename, and a rename lands on the *link itself*, so a
    // linked path is silently replaced by a private regular file and every
    // later write goes somewhere nobody else reads. That is what detached an
    // improve worktree's `state/improvements.jsonl` from the checkout's
    // ledger: the link is created correctly, the first whole-file rewrite
    // replaced it, and 23 improvements were recorded into a copy that was
    // thrown away with the worktree
    // (docs/reports/bugs/2026-08-17-improve-ledger-written-to-a-worktree-copy.md).
    // `state/history` next to it survived only because it is a directory and
    // nothing renames over it.
    var link_buf: [4096]u8 = undefined;
    var joined_buf: [4096]u8 = undefined;
    const target: []const u8 = if (dir.readLink(io, sub_path, &link_buf)) |n| blk: {
        const link = link_buf[0..n];
        // An absolute target is used as-is: `openat` ignores the directory
        // handle for an absolute path. A relative one resolves against the
        // link's own directory, not against `dir`.
        if (link.len > 0 and link[0] == '/') break :blk link;
        const dir_end = std.mem.lastIndexOfScalar(u8, sub_path, '/') orelse break :blk link;
        break :blk std.fmt.bufPrint(&joined_buf, "{s}/{s}", .{ sub_path[0..dir_end], link }) catch break :blk link;
    } else |_| sub_path; // not a link (NotLink), or does not exist yet

    var af = try dir.createFileAtomic(io, target, .{ .replace = true, .make_path = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, data);
    try af.replace(io);
}

test "writeFile follows a symlinked destination instead of replacing the link" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The shape an improve worktree has: `state/improvements.jsonl` is a link
    // to the checkout's ledger, and the engine rewrites it whole through this
    // function. A rename lands on the link itself, so without following it the
    // worktree silently gains a private copy and every later append goes there
    // instead of to the file the next run reads.
    try tmp.dir.writeFile(io, .{ .sub_path = "real.jsonl", .data = "first\n" });
    try tmp.dir.symLink(io, "real.jsonl", "link.jsonl", .{});

    try writeFile(io, tmp.dir, "link.jsonl", "first\nsecond\n");

    var buf: [256]u8 = undefined;
    const n = tmp.dir.readLink(io, "link.jsonl", &buf) catch |err| {
        std.debug.print("link.jsonl is no longer a symlink: {s}\n", .{@errorName(err)});
        return err;
    };
    try std.testing.expectEqualStrings("real.jsonl", buf[0..n]);

    const through = try tmp.dir.readFileAlloc(io, "real.jsonl", allocator, .limited(1 << 10));
    defer allocator.free(through);
    try std.testing.expectEqualStrings("first\nsecond\n", through);
}

test "writeFile resolves a relative link target against the link's own directory" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A relative target is relative to the directory holding the *link*, not
    // to `dir`. Writing "shared/real.jsonl" straight through would create a
    // second file at the wrong depth and leave the link's own target stale.
    try tmp.dir.createDirPath(io, "state/shared");
    try tmp.dir.writeFile(io, .{ .sub_path = "state/shared/real.jsonl", .data = "first\n" });
    try tmp.dir.symLink(io, "shared/real.jsonl", "state/link.jsonl", .{});

    try writeFile(io, tmp.dir, "state/link.jsonl", "first\nsecond\n");

    var buf: [256]u8 = undefined;
    const n = try tmp.dir.readLink(io, "state/link.jsonl", &buf);
    try std.testing.expectEqualStrings("shared/real.jsonl", buf[0..n]);

    const through = try tmp.dir.readFileAlloc(io, "state/shared/real.jsonl", allocator, .limited(1 << 10));
    defer allocator.free(through);
    try std.testing.expectEqualStrings("first\nsecond\n", through);

    // Nothing landed at the un-joined spelling.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "shared/real.jsonl", .{}));
}

test "writeFile follows an absolute link target" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The shape `linkSharedState` writes: the link target is the checkout's
    // absolute path. `openat` ignores the directory handle for an absolute
    // path, so it is used as-is rather than joined onto the link's directory.
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const abs = try std.fmt.allocPrint(allocator, "{s}/real.jsonl", .{root_buf[0..root_len]});
    defer allocator.free(abs);

    try tmp.dir.writeFile(io, .{ .sub_path = "real.jsonl", .data = "first\n" });
    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.symLink(io, abs, "state/improvements.jsonl", .{});

    try writeFile(io, tmp.dir, "state/improvements.jsonl", "first\nsecond\n");

    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.readLink(io, "state/improvements.jsonl", &buf);
    try std.testing.expectEqualStrings(abs, buf[0..n]);

    const through = try tmp.dir.readFileAlloc(io, "real.jsonl", allocator, .limited(1 << 10));
    defer allocator.free(through);
    try std.testing.expectEqualStrings("first\nsecond\n", through);
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
