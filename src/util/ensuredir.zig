//! `createDirPath` that accepts a path which is already a usable directory,
//! including one reached through a symlink.
//!
//! An isolated run (`clanker run --worktree`) has its `state` entry symlinked to
//! the checkout's, so every run shares one set of sessions, goals, stats and
//! notes rather than a per-worktree snapshot nobody reads. `createDirPath` on
//! that entry fails: the directory exists, so the mkdir returns EEXIST, and the
//! no-follow stat that decides whether that is fine sees a `sym_link` rather
//! than a `directory` and reports `NotDir`. The same walk fails on a child
//! (`state/sessions`) even when the target under the link is missing, because
//! it never gets past the `state` component.
//!
//! Every caller here wants the same thing -- "make sure I can write in there" --
//! and each one bailed out with a warning instead, so an isolated run silently
//! stopped recording token stats, autolearn entries and tool usage while looking
//! healthy otherwise. Following the link is the right question to ask: what
//! matters is whether the path resolves to a directory, not how.

const std = @import("std");

/// Creates `path` (and parents) under `base`, treating "already a directory"
/// as success even when a component is a symlink to one. Errors that are
/// really errors -- no permission, a plain file in the way, a dangling link --
/// still propagate, so a caller that cannot write there still finds out.
pub fn ensureDir(base: std.Io.Dir, io: std.Io, path: []const u8) !void {
    base.createDirPath(io, path) catch |err| {
        // Follow the link deliberately: a symlink to a directory IS a directory
        // for every purpose a caller of this function has.
        const st = base.statFile(io, path, .{}) catch {
            try createUnderLinks(base, io, path);
            return;
        };
        if (st.kind == .directory) return;
        return err;
    };
}

/// Walks `path` one component at a time, following directory symlinks, so a
/// child such as `state/sessions` can be created when `state` itself is a
/// link. `createDirPath` never reaches that child: it rejects the `state`
/// component as `NotDir`.
fn createUnderLinks(base: std.Io.Dir, io: std.Io, path: []const u8) !void {
    var current = base;
    var opened: ?std.Io.Dir = null;
    defer if (opened) |*d| d.close(io);

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        current.createDir(io, part, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        const next = try current.openDir(io, part, .{});
        if (opened) |*d| d.close(io);
        opened = next;
        current = next;
    }
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

    // A child under that link is what saveSession / recordReasoning need:
    // createDirPath never gets past the `state` component.
    try tmp.dir.createDir(io, "real_state", .default_dir);
    try tmp.dir.symLink(io, "real_state", "state", .{ .is_directory = true });
    try std.testing.expectError(error.NotDir, tmp.dir.createDirPath(io, "state/sessions"));
    try ensureDir(tmp.dir, io, "state/sessions");
    const child = try tmp.dir.statFile(io, "state/sessions", .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, child.kind);
    // Idempotent once the child exists through the link.
    try ensureDir(tmp.dir, io, "state/sessions");

    // A plain file in the way is a genuine failure and must not be swallowed.
    try tmp.dir.writeFile(io, .{ .sub_path = "afile", .data = "" });
    try std.testing.expectError(error.NotDir, ensureDir(tmp.dir, io, "afile"));
}
