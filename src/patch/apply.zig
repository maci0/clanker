//! Patch application: applies exact-match proposal changes to files under a
//! base directory. Path validation lives in src/improve/proposal.zig (the
//! protected anti-cheat boundary); this module only performs the text edits.

const std = @import("std");
const log = @import("../util/log.zig");
const proposal = @import("../improve/proposal.zig");

/// Applies the changes to files under `base`. Missing files are always created
/// with the proposed new content; present files are patched by first occurrence
/// replace (or append when old == "").
pub fn apply(base: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, changes: []const proposal.Change) !void {
    for (changes) |c| {
        const current = base.readFileAlloc(io, c.file, gpa, .limited(1 << 24)) catch |err| switch (err) {
            error.FileNotFound => {
                // New file: create the parent directory (it may not exist in
                // the staging tree, e.g. tools/ is not copied), then write.
                const dir = dirOf(c.file);
                if (dir.len > 0) {
                    base.createDirPath(io, dir) catch |perr| switch (perr) {
                        error.PathAlreadyExists => {},
                        else => return perr,
                    };
                }
                try base.writeFile(io, .{ .sub_path = c.file, .data = c.new });
                continue;
            },
            else => return err,
        };
        defer gpa.free(current);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        if (c.old.len == 0) {
            try out.appendSlice(gpa, current);
            try out.appendSlice(gpa, c.new);
        } else {
            const idx = std.mem.indexOf(u8, current, c.old) orelse {
                log.log(.error_, "old text not found in '{s}'", .{c.file});
                return error.OldTextNotFound;
            };
            try out.appendSlice(gpa, current[0..idx]);
            try out.appendSlice(gpa, c.new);
            try out.appendSlice(gpa, current[idx + c.old.len ..]);
        }
        try base.writeFile(io, .{ .sub_path = c.file, .data = out.items });
    }
}

fn dirOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[0..i];
    return "";
}
