//! Operator journeys the rest of the e2e suite does not cover: persist a
//! goal without running it, and add then list a schedule entry. Each test
//! owns a temp cwd and drives the real `clanker` binary.

const std = @import("std");
const harness = @import("harness.zig");

test "operator journey: add-goal persists the objective without starting a run" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // No LLM: add-goal calls the sandboxed goal_add guest and stops.
    try harness.writeMockConfig(io, tmp.dir, gpa, 9);
    try harness.linkZigOut(io, tmp.dir);

    const objective = "e2e-add-goal persist this exact objective";
    const criterion = "state/goals.json still names e2e-add-goal";
    var result = try harness.run(gpa, io, tmp.dir, &.{ "add-goal", objective, criterion });
    defer result.deinit(gpa);
    if (!result.ok()) std.debug.print("add-goal failed.\nstdout: {s}\nstderr: {s}\n", .{ result.stdout, result.stderr });
    try std.testing.expect(result.ok());
    try std.testing.expect(std.mem.find(u8, result.stdout, "added goal ") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "clanker run --goal ") != null);

    const goals = try tmp.dir.readFileAlloc(io, "state/goals.json", gpa, .limited(1 << 20));
    defer gpa.free(goals);
    try std.testing.expect(std.mem.find(u8, goals, objective) != null);
    try std.testing.expect(std.mem.find(u8, goals, criterion) != null);
}

test "operator journey: schedule add then list shows the task" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try harness.writeMockConfig(io, tmp.dir, gpa, 9);
    try harness.linkZigOut(io, tmp.dir);

    const spec = "0 9 * * 1-5";
    const task = "e2e-sched marker summarize commits";
    var added = try harness.run(gpa, io, tmp.dir, &.{ "schedule", "add", spec, task });
    defer added.deinit(gpa);
    if (!added.ok()) std.debug.print("schedule add failed.\nstdout: {s}\nstderr: {s}\n", .{ added.stdout, added.stderr });
    try std.testing.expect(added.ok());
    try std.testing.expect(std.mem.find(u8, added.stdout, spec) != null);
    try std.testing.expect(std.mem.find(u8, added.stdout, "Nothing fires on its own") != null);
    try std.testing.expect(std.mem.find(u8, added.stdout, "added ") != null);

    const store = try tmp.dir.readFileAlloc(io, "state/schedule.json", gpa, .limited(1 << 20));
    defer gpa.free(store);
    try std.testing.expect(std.mem.find(u8, store, task) != null);
    try std.testing.expect(std.mem.find(u8, store, spec) != null);

    var listed = try harness.run(gpa, io, tmp.dir, &.{"schedule"});
    defer listed.deinit(gpa);
    if (!listed.ok()) std.debug.print("schedule list failed.\nstdout: {s}\nstderr: {s}\n", .{ listed.stdout, listed.stderr });
    try std.testing.expect(listed.ok());
    try std.testing.expect(std.mem.find(u8, listed.stdout, task) != null);
    try std.testing.expect(std.mem.find(u8, listed.stdout, spec) != null);
}
