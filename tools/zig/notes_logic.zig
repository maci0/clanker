//! Pure rules for appending one bullet to the persistent notes file
//! (`state/learnings.md`), host-tested so `note_write`'s identity rule is
//! pinned rather than living only inside a guest that cannot run `test`
//! blocks. `note_forget`, the other writer of that one file, takes a substring
//! to erase rather than a note to add, so it has no use for the identity rule
//! here — what the two writers share is the compare-and-swap shape, and each
//! one now takes it.
//!
//! The build is the interesting half: `write_note` used to `ck_fs_append` a
//! rendered line, having first read the file and scanned it for an existing
//! bullet. Append is the one write of the three strengths that cannot express
//! "only if this note is absent" — it carries no digest — so two identical
//! executions racing (tools in one turn run in parallel, and a retry of a call
//! whose reply was lost) both read a file without the note and both appended.
//! Returning the whole new file lets the guest write it under
//! `fsWriteIf(expected_hash, ...)` and re-decide on `Mismatch`, which is the
//! same shape `forget_note` already used for the same reason.

const std = @import("std");

/// True when `existing` already has a `- {note}` line. Compared as a whole
/// line so a shorter note cannot match inside a longer one.
pub fn noteLinePresent(existing: []const u8, note: []const u8) bool {
    var it = std.mem.splitScalar(u8, existing, '\n');
    while (it.next()) |line| {
        const t = std.mem.trimEnd(u8, line, "\r");
        if (t.len >= 2 and t[0] == '-' and t[1] == ' ' and std.mem.eql(u8, t[2..], note)) return true;
    }
    return false;
}

/// The whole file with `note` appended as one bullet, or null when it is
/// already there. Whole-file rather than a fragment, because the caller writes
/// it compare-and-swap: an append is the one operation whose duplicate leaves
/// the store *unchanged* rather than merely equal, and an unchanged store is
/// exactly what makes the retry answer `duplicate` instead of writing again.
///
/// Returns null for the duplicate rather than the unchanged bytes so the caller
/// cannot mistake "wrote nothing" for "wrote the same thing twice": a caller
/// that wrote unchanged bytes under a stale digest would still hold a
/// compare-and-swap it never won.
pub fn appendNote(
    alloc: std.mem.Allocator,
    existing: []const u8,
    note: []const u8,
) !?[]const u8 {
    if (noteLinePresent(existing, note)) return null;
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(alloc);
    try line.appendSlice(alloc, existing);
    // A file that does not already end in a newline would otherwise get this
    // note glued onto its last line.
    if (existing.len > 0 and existing[existing.len - 1] != '\n') try line.append(alloc, '\n');
    try line.appendSlice(alloc, "- ");
    try line.appendSlice(alloc, note);
    try line.append(alloc, '\n');
    return try line.toOwnedSlice(alloc);
}

test "an existing note line is recognised as a whole line" {
    const file =
        \\
        \\- first lesson
        \\- second lesson
        \\
    ;
    try std.testing.expect(noteLinePresent(file, "first lesson"));
    try std.testing.expect(noteLinePresent(file, "second lesson"));
    // A prefix of a longer note is not that note: matching inside the line
    // would make appending "first" a no-op the caller reads as success.
    try std.testing.expect(!noteLinePresent(file, "first"));
    try std.testing.expect(!noteLinePresent(file, "lesson"));
    try std.testing.expect(!noteLinePresent(file, "third lesson"));
    // Windows line endings survive a round trip: a note written as `- x\r\n`
    // is found again rather than appended a second time.
    try std.testing.expect(noteLinePresent("- crlf note\r\n", "crlf note"));
}

test "appendNote returns null for a note already present" {
    const alloc = std.testing.allocator;
    const file = "- check CI is green\n";
    try std.testing.expectEqual(@as(?[]const u8, null), try appendNote(alloc, file, "check CI is green"));
    // The empty note is refused by the guest, but the rule holds for it too:
    // the bullet it writes is a line of its own, so the second call finds it
    // rather than adding a second empty bullet.
    const empty_once = (try appendNote(alloc, "", "")).?;
    defer alloc.free(empty_once);
    try std.testing.expectEqualStrings("- \n", empty_once);
    try std.testing.expectEqual(@as(?[]const u8, null), try appendNote(alloc, empty_once, ""));
}

test "appendNote builds the whole file with one more bullet" {
    const alloc = std.testing.allocator;
    // Appended after the existing content, not before it: `forget_note`
    // rewrites top to bottom and the file reads oldest-first to a human.
    {
        const got = (try appendNote(alloc, "- a\n", "b")).?;
        defer alloc.free(got);
        try std.testing.expectEqualStrings("- a\n- b\n", got);
    }
    // A file with no trailing newline gets one before the bullet, so the new
    // note is not glued onto the last line's text.
    {
        const got = (try appendNote(alloc, "- a", "b")).?;
        defer alloc.free(got);
        try std.testing.expectEqualStrings("- a\n- b\n", got);
    }
    // An empty file is the first-note case.
    {
        const got = (try appendNote(alloc, "", "only")).?;
        defer alloc.free(got);
        try std.testing.expectEqualStrings("- only\n", got);
    }
}

test "running appendNote twice leaves the file a single execution would" {
    const alloc = std.testing.allocator;
    // The retry horizon: a second call whose reply the first caller's network
    // ate, and a second call racing the first in parallel. Both re-run the
    // whole build from the file each time, so both are exercised.
    var file: []const u8 = try alloc.dupe(u8, "");
    const landed = (try appendNote(alloc, file, "the retry adds one bullet")).?;
    alloc.free(file);
    file = landed;
    // Every later execution answers null and writes nothing, which is what
    // the guest turns into `{"ok":true,"duplicate":true}`.
    for (0..3) |_| try std.testing.expectEqual(@as(?[]const u8, null), try appendNote(alloc, file, "the retry adds one bullet"));
    defer alloc.free(file);
    try std.testing.expectEqualStrings("- the retry adds one bullet\n", file);
}

test "a stale digest is refused, so the loser's re-read answers the duplicate" {
    const alloc = std.testing.allocator;
    // The race the compare-and-swap exists to close, modelled where it can be
    // pinned. Two executions read the same file, both decide to append the same
    // note, and only one write can land. The guest's shape is read / decide /
    // write-under-digest, and on Mismatch it re-reads and re-decides, so the
    // loser sees the winner's bullet and answers nothing rather than writing.
    // `ck_fs_write_if` is the enforcement (it compares the digest under the
    // state/locks flock); what this test pins is the decision that refusal
    // depends on being right.
    const seen = "";
    // Two independent executions build from the same read. Identical content,
    // so nothing here passes because the two notes happen to differ.
    const first_build = (try appendNote(alloc, seen, "one bullet")).?;
    defer alloc.free(first_build);
    const second_build = (try appendNote(alloc, seen, "one bullet")).?;
    defer alloc.free(second_build);
    try std.testing.expectEqualStrings(first_build, second_build);

    // One of them lands, carrying the digest of what it read.
    const file: []const u8 = try alloc.dupe(u8, first_build);
    defer alloc.free(file);

    // The other's write carries the same expected digest, so the host refuses
    // it. What it decides after re-reading is the property under test.
    try std.testing.expectEqual(@as(?[]const u8, null), try appendNote(alloc, file, "one bullet"));
    try std.testing.expectEqualStrings("- one bullet\n", file);
}
