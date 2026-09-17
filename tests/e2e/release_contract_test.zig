const std = @import("std");
const harness = @import("harness.zig");
const options = @import("e2e_options");

test "release-check accepts spaces in binary paths and rejects mismatched versions" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var identity = try harness.run(gpa, io, tmp.dir, &.{"--version"});
    defer identity.deinit(gpa);
    try std.testing.expect(identity.ok());
    try std.testing.expect(std.mem.startsWith(u8, identity.stdout, "clanker "));
    const version = std.mem.trim(u8, identity.stdout[8..], "\r\n");
    const tag = try std.fmt.allocPrint(gpa, "v{s}", .{version});
    defer gpa.free(tag);
    const manifest = try std.fmt.allocPrint(gpa, ".{{\n    .version = \"{s}\",\n}}\n", .{version});
    defer gpa.free(manifest);
    const changelog = try std.fmt.allocPrint(gpa, "## [{s}] - 2026-09-18\n", .{version});
    defer gpa.free(changelog);
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = manifest });
    try tmp.dir.writeFile(io, .{ .sub_path = "CHANGELOG.md", .data = changelog });
    try tmp.dir.createDirPath(io, "release dir");
    try tmp.dir.symLink(io, harness.bin(), "release dir/clanker", .{});
    const script = try std.fs.path.resolve(gpa, &.{ options.docs_dir, "../scripts/release-check.sh" });
    defer gpa.free(script);

    for ([_][]const u8{ tag, "v999999.0.0" }, 0..) |candidate, index| {
        const result = try std.process.run(gpa, io, .{
            .argv = &.{ "bash", script, candidate, "./release dir/clanker" },
            .cwd = .{ .dir = tmp.dir },
            .stdout_limit = .limited(1 << 20),
            .stderr_limit = .limited(1 << 20),
        });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        const code = switch (result.term) {
            .exited => |code| code,
            else => return error.ScriptTerminated,
        };
        if (index == 0) {
            if (code != 0) std.debug.print("{s}", .{result.stderr});
            try std.testing.expectEqual(@as(u8, 0), code);
            const expected = try std.fmt.allocPrint(gpa, "release contract verified for {s}\n", .{tag});
            defer gpa.free(expected);
            try std.testing.expectEqualStrings(expected, result.stdout);
        } else {
            try std.testing.expect(code != 0);
            try std.testing.expect(std.mem.find(u8, result.stderr, "disagrees with build.zig.zon version") != null);
        }
    }
}
