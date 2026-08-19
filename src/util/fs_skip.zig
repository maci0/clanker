//! The directories a filesystem walk must never descend into. Shared by the
//! host's `ck_fs_find`/`ck_fs_grep` and the `list_files` guest, the way
//! `util/glob.zig` is shared with the `git`/`gh` guests: without one table the
//! two walks answer differently about the same tree, and the divergence only
//! shows up as a search that reads hundreds of megabytes of build cache.
const std = @import("std");

/// Build caches, vendored dependencies, and the staging trees the improvement
/// engine leaves behind. Without this a search of the project answers mostly
/// with copies of the project.
pub const skip_dirs = std.StaticStringMap(void).initComptime(.{
    .{ ".git", {} },
    .{ ".zig-cache", {} },
    .{ ".venv", {} },
    .{ ".cache", {} },
    .{ "zig-out", {} },
    .{ "zig-pkg", {} },
    .{ "node_modules", {} },
    .{ "vendor", {} },
    .{ "staging", {} },
    .{ "history", {} },
    .{ "__pycache__", {} },
});

pub fn skipDir(name: []const u8) bool {
    return skip_dirs.get(name) != null;
}

test "skipDir names the cache and vendor trees a project-root walk must not enter" {
    try std.testing.expect(skipDir("node_modules"));
    try std.testing.expect(skipDir("zig-pkg"));
    try std.testing.expect(skipDir("zig-out"));
    try std.testing.expect(skipDir("vendor"));
    try std.testing.expect(skipDir("staging"));
    try std.testing.expect(skipDir("history"));
    try std.testing.expect(skipDir(".zig-cache"));
    try std.testing.expect(skipDir(".venv"));
    try std.testing.expect(skipDir(".cache"));
    try std.testing.expect(skipDir("__pycache__"));
    try std.testing.expect(!skipDir("src"));
    try std.testing.expect(!skipDir("tools"));
}
