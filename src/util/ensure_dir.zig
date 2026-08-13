//! `createDirPath` that accepts a path which is already a usable directory,
//! including one reached through a symlink.
//!
//! An isolated run (`clanker run --worktree`) has its `state` entry symlinked to
//! the checkout's, so every run shares one set of sessions, goals, stats and
//! notes rather than a per-worktree snapshot nobody reads. `createDirPath` on
//! that entry fails: the directory exists, so the mkdir returns EEXIST, and the
//! no-follow stat that decides whether that is fine sees a `sym_link` rather
//! than a `directory` and reports `NotDir`. Children under that link
//! (`state/sessions`) are fine: `createDirPath` follows the parent.
//!
//! Every caller here wants the same thing -- "make sure I can write in there" --
//! and each one bailed out with a warning instead, so an isolated run silently
//! stopped recording token stats, autolearn entries and tool usage while looking
//! healthy otherwise. Following the link is the right question to ask: what
//! matters is whether the path resolves to a directory, not how. Host-side
//! writers that create `state` (or another shared prefix) must call this, not
//! `createDirPath`, or a `--worktree` run drops the write.

const std = @import("std");

/// Creates `path` (and parents) under `base`, treating "already a directory"
/// as success even when the last component is a symlink to one. Errors that are
/// really errors -- no permission, a plain file in the way, a dangling link --
/// still propagate, so a caller that cannot write there still finds out.
pub fn ensureDir(base: std.Io.Dir, io: std.Io, path: []const u8) !void {
    base.createDirPath(io, path) catch |err| {
        // Follow the link deliberately: a symlink to a directory IS a directory
        // for every purpose a caller of this function has.
        const st = base.statFile(io, path, .{}) catch return err;
        if (st.kind == .directory) return;
        return err;
    };
}

test "ensureDir accepts a real directory, a symlink to one, and still refuses a file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Fresh path: created.
    try ensureDir(tmp.dir, io, "fresh/nested");
    const fresh = try tmp.dir.statFile(io, "fresh/nested", .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, fresh.kind);

    // Already a real directory: idempotent.
    try ensureDir(tmp.dir, io, "fresh/nested");

    // A symlink to a directory is what an isolated run's `state` is, and the
    // case plain createDirPath rejects with NotDir.
    try tmp.dir.createDir(io, "real_target", .default_dir);
    try tmp.dir.symLink(io, "real_target", "linked", .{ .is_directory = true });
    try std.testing.expectError(error.NotDir, tmp.dir.createDirPath(io, "linked"));
    try ensureDir(tmp.dir, io, "linked");

    // A child under that link (what saveSession asks for) already works
    // through createDirPath; ensureDir must not regress it.
    try tmp.dir.createDir(io, "real_state", .default_dir);
    try tmp.dir.symLink(io, "real_state", "state", .{ .is_directory = true });
    try ensureDir(tmp.dir, io, "state/sessions");
    const child = try tmp.dir.statFile(io, "state/sessions", .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, child.kind);

    // A plain file in the way is a genuine failure and must not be swallowed.
    try tmp.dir.writeFile(io, .{ .sub_path = "afile", .data = "" });
    try std.testing.expectError(error.NotDir, ensureDir(tmp.dir, io, "afile"));
}
