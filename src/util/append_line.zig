//! One line appended to the end of an open JSONL log.
//!
//! Three state logs are written this way -- `state/token_stats.jsonl`,
//! `state/autolearn.jsonl`, `state/reasoning.jsonl` -- and each had its own
//! copy of the same five steps. Two of those copies discarded every error
//! after the open: a stat, seek, write or flush that failed dropped the record
//! and returned as if it had been written, which is exactly the shape that
//! made the token log lose records silently once before (see the comment above
//! the lock in `src/stats/tokens.zig`). One implementation that returns its
//! error leaves the caller no way to be silent by accident.
//!
//! The caller still owns the lock: this only writes, and says nothing about who
//! may write at the same time.

const std = @import("std");

/// Appends `line` and a newline at the file's current end.
///
/// The offset is taken from the open handle, never from a separate stat of the
/// path: under a lock held across open-and-append, a size read before the open
/// can be stale by the time the write lands, and two writers then place their
/// records at the same offset and one replaces the other.
pub fn appendLine(io: std.Io, file: std.Io.File, line: []const u8) !void {
    const size = (try file.stat(io)).size;
    var wbuf: [512]u8 = undefined;
    var fw = file.writer(io, &wbuf);
    try fw.seekToUnbuffered(size);
    try fw.interface.writeAll(line);
    try fw.interface.writeAll("\n");
    try fw.flush();
}

test "appendLine appends rather than overwriting, and reports a failed write" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const file = try tmp.dir.createFile(io, "log.jsonl", .{ .truncate = false });
        defer file.close(io);
        try appendLine(io, file, "{\"n\":1}");
        try appendLine(io, file, "{\"n\":2}");
    }
    // A second open must land after the first two records, not on top of them:
    // the offset comes from the handle, so it is current at write time.
    {
        const file = try tmp.dir.createFile(io, "log.jsonl", .{ .truncate = false });
        defer file.close(io);
        try appendLine(io, file, "{\"n\":3}");
    }

    var buf: [256]u8 = undefined;
    const raw = try tmp.dir.readFile(io, "log.jsonl", &buf);
    try std.testing.expectEqualStrings("{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n", raw);

    // A handle with no write permission is the failure the callers used to
    // swallow: it must come back as an error, not as a silent no-op.
    const ro = try tmp.dir.openFile(io, "log.jsonl", .{ .mode = .read_only });
    defer ro.close(io);
    // Which errno the platform picks is not the point; that the caller is told
    // at all is. Pinning one name would make this a portability test.
    if (appendLine(io, ro, "{\"n\":4}")) |_| return error.TestExpectedWriteToFail else |_| {}
}
