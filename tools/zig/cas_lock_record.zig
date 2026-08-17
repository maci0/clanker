//! The holder record inside a compare-and-swap lock file.
//!
//! `ck_fs_write_if` locks on `state/locks/<sha256-of-target>.lock` (ADR 0031)
//! and writes one fixed-width line into it naming who took the lock and when.
//! The host writes that line; the `janitor` guest reads it to decide which
//! lock files have aged out. Writer and reader share this module so the format
//! cannot drift between them.
//!
//! **The record is diagnostics, never correctness.** The lock is an `flock`,
//! and the kernel releases an `flock` when the last descriptor on it closes --
//! on a clean return, on a panic, on SIGKILL, on the machine losing power. A
//! held lock is therefore never stale, no holder has to prove liveness with a
//! heartbeat, and nothing may refuse or steal a lock on the strength of what
//! is written here. `src/util/run_lock.zig` is the contrasting case: it is a
//! *pid file*, which a dead owner really does leave behind, so it reclaims one
//! by probing the owner with signal 0 -- still a liveness question, not a
//! clock.
//!
//! What the record does answer is the question a zero-byte name cannot: which
//! run is inside `fs_write_if` on which file, and since when. It describes the
//! *last acquisition* rather than a live hold, because releasing the lock is a
//! `close` and a `close` cannot write. Whether a lock is held right now is
//! only ever answered by trying to take it:
//!
//!     flock -n state/locks/<name>.lock true
//!
//! Fixed width, written at offset 0, because `std.Io.File` exposes no
//! truncate: a shorter record would leave the tail of a longer earlier one
//! behind and the line would then read as a lie.

const std = @import("std");

/// Total bytes of a record, including the trailing newline.
pub const record_len = 256;

/// Renders the record for one acquisition into `buf`, padding with spaces.
///
/// Over-long inputs are truncated rather than refused: this runs on the CAS
/// write path, and a diagnostic line is never a reason to fail a write. The
/// *tail* of the target is what survives truncation, because the basename is
/// what identifies it while the leading checkout root is identical for every
/// record in the directory.
pub fn render(buf: *[record_len]u8, pid: u32, acquired_ms: i64, tool: []const u8, target: []const u8) void {
    @memset(buf, ' ');
    buf[record_len - 1] = '\n';

    const named = if (tool.len > 0) tool else "host";
    var head: [128]u8 = undefined;
    const prefix = std.fmt.bufPrint(&head, "pid={d} acquired_ms={d} tool={s} target=", .{
        pid,
        acquired_ms,
        named[0..@min(named.len, 32)],
    }) catch return;

    const room = record_len - 1;
    const n = @min(prefix.len, room);
    @memcpy(buf[0..n], prefix[0..n]);
    const t = @min(target.len, room - n);
    @memcpy(buf[n..][0..t], target[target.len - t ..]);
}

/// Reads one `key=` field out of a record, up to the next space or newline.
fn field(record: []const u8, key: []const u8) ?[]const u8 {
    // Anchored on the key *with* its `=`, so `tool=` cannot match inside a
    // target path that happens to contain the word.
    const at = std.mem.indexOf(u8, record, key) orelse return null;
    const rest = record[at + key.len ..];
    var end: usize = 0;
    while (end < rest.len and rest[end] != ' ' and rest[end] != '\n') end += 1;
    if (end == 0) return null;
    return rest[0..end];
}

/// When this lock was last acquired, or null if the record is absent or
/// unreadable. A null is not "old": a caller deciding what to delete has to
/// choose deliberately what to do with a record it cannot read.
pub fn acquiredMs(record: []const u8) ?i64 {
    const raw = field(record, "acquired_ms=") orelse return null;
    return std.fmt.parseInt(i64, raw, 10) catch null;
}

/// Whether the janitor may sweep the lock file this record came from: nothing
/// has re-acquired it for `keep_ms`.
///
/// This is a retention rule for the *file*, never a liveness verdict on the
/// lock -- see the module doc for why an `flock` can never be stale. Two
/// records are deliberately not old: one that cannot be parsed, which would
/// otherwise date to 1970 and take the whole directory with it, and one stamped
/// in the future, which is a clock that moved rather than a lock that aged.
pub fn agedOut(record: []const u8, now_ms: i64, keep_ms: i64) bool {
    const acquired = acquiredMs(record) orelse return false;
    if (now_ms < acquired) return false;
    return now_ms - acquired >= keep_ms;
}

/// The target path this lock guards, or null if unreadable. Truncated for a
/// very long path, so it is a diagnostic aid and not a path to open.
pub fn targetPath(record: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, record, "target=") orelse return null;
    const rest = record[at + "target=".len ..];
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    const trimmed = std.mem.trimEnd(u8, rest[0..end], " ");
    if (trimmed.len == 0) return null;
    return trimmed;
}

test "a rendered record round-trips through the parser" {
    var buf: [record_len]u8 = undefined;
    render(&buf, 4242, 1786939239341, "reports", "docs/reports/bugs/a.md");

    try std.testing.expectEqual(@as(usize, record_len), buf.len);
    try std.testing.expectEqual(@as(u8, '\n'), buf[record_len - 1]);
    try std.testing.expect(std.mem.startsWith(u8, &buf, "pid=4242 acquired_ms=1786939239341 tool=reports target="));
    try std.testing.expectEqual(@as(?i64, 1786939239341), acquiredMs(&buf));
    try std.testing.expectEqualStrings("docs/reports/bugs/a.md", targetPath(&buf).?);
}

test "a shorter record cannot leave the tail of a longer one behind" {
    // std.Io.File has no truncate, so the record is written at offset 0 over
    // whatever was there. Fixed width is what keeps the line honest.
    var buf: [record_len]u8 = undefined;
    render(&buf, 999999, 1786939239341, "research", "docs/research/a-very-long-note-name.md");
    render(&buf, 1, 2, "adr", "x.md");

    try std.testing.expectEqualStrings("x.md", targetPath(&buf).?);
    try std.testing.expectEqual(@as(?i64, 2), acquiredMs(&buf));
    try std.testing.expect(std.mem.indexOf(u8, &buf, "very-long") == null);
}

test "an over-long target keeps its tail, and the record stays exactly one line" {
    var buf: [record_len]u8 = undefined;
    const long = "/home/u/checkout/" ++ ("d/" ** 120) ++ "final-name.md";
    render(&buf, 7, 1, "prd", long);

    try std.testing.expectEqual(@as(u8, '\n'), buf[record_len - 1]);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, &buf, "\n"));
    try std.testing.expect(std.mem.endsWith(u8, targetPath(&buf).?, "final-name.md"));
}

test "an empty or malformed record reads as unknown rather than as old" {
    // The janitor's retention rule turns on acquiredMs. Reporting a garbage
    // record as timestamp zero would date it to 1970 and sweep every lock.
    try std.testing.expectEqual(@as(?i64, null), acquiredMs(""));
    try std.testing.expectEqual(@as(?i64, null), acquiredMs("pid=1 tool=x target=y\n"));
    try std.testing.expectEqual(@as(?i64, null), acquiredMs("acquired_ms=notanumber\n"));
    try std.testing.expectEqual(@as(?[]const u8, null), targetPath("pid=1\n"));
}

test "the sweep keeps a fresh lock, an unreadable one, and one stamped ahead" {
    const twelve_h: i64 = 12 * 60 * 60 * 1000;
    var buf: [record_len]u8 = undefined;

    render(&buf, 1, 1_000_000_000_000, "reports", "docs/reports/README.md");
    // Exactly at the window is old enough; a minute short of it is not.
    try std.testing.expect(agedOut(&buf, 1_000_000_000_000 + twelve_h, twelve_h));
    try std.testing.expect(!agedOut(&buf, 1_000_000_000_000 + twelve_h - 60_000, twelve_h));

    // A record nothing can parse is unknown, not old: sweeping on it would date
    // every unreadable lock to 1970 and delete live locks with the dead ones.
    try std.testing.expect(!agedOut("", 1_000_000_000_000, twelve_h));
    try std.testing.expect(!agedOut("pid=1 tool=x target=y\n", 1_000_000_000_000, twelve_h));

    // A clock that moved backwards is not an aged lock.
    try std.testing.expect(!agedOut(&buf, 999_999_000_000, twelve_h));
}

test "a target containing a field name does not confuse the parser" {
    var buf: [record_len]u8 = undefined;
    render(&buf, 5, 1786939239341, "reports", "docs/reports/tool=notafield.md");
    try std.testing.expectEqual(@as(?i64, 1786939239341), acquiredMs(&buf));
    try std.testing.expectEqualStrings("docs/reports/tool=notafield.md", targetPath(&buf).?);
}
