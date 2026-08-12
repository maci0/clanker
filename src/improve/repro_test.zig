const std = @import("std");
const worktree = @import("worktree.zig");

test "repro worktree.create invalid free" {
    var dbg = std.heap.DebugAllocator(.{}).init;
    defer _ = dbg.deinit();
    const gpa = dbg.allocator();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Replicate the create() allocation/free pattern directly first.
    const cwd_path = std.process.currentPathAlloc(io, gpa) catch try gpa.dupe(u8, ".");
    gpa.free(cwd_path);
    std.debug.print("currentPathAlloc+free ok\n", .{});

    var created = worktree.create(gpa, io, "repro-invalid-free") catch |err| {
        std.debug.print("create failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer created.deinit(gpa);
    std.debug.print("create returned ok: path={s} branch={s}\n", .{ created.path, created.branch });
}
