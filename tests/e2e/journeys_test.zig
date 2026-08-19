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
    std.debug.print("pass: operator journey: add-goal persists the objective without starting a run\n", .{});
}

test "operator journey: add-goal twice with the same objective yields one goal" {
    // A double-click or a retried POST must not append a second row: the
    // second add is an idempotent replay of the first and returns the same
    // goal, so state/goals.json holds one record, not two.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try harness.writeMockConfig(io, tmp.dir, gpa, 9);
    try harness.linkZigOut(io, tmp.dir);

    const objective = "e2e-add-goal idempotent objective";
    var first = try harness.run(gpa, io, tmp.dir, &.{ "add-goal", objective });
    defer first.deinit(gpa);
    if (!first.ok()) std.debug.print("add-goal (first) failed.\nstdout: {s}\nstderr: {s}\n", .{ first.stdout, first.stderr });
    try std.testing.expect(first.ok());

    var second = try harness.run(gpa, io, tmp.dir, &.{ "add-goal", objective });
    defer second.deinit(gpa);
    if (!second.ok()) std.debug.print("add-goal (second) failed.\nstdout: {s}\nstderr: {s}\n", .{ second.stdout, second.stderr });
    try std.testing.expect(second.ok());

    // The objective names exactly one record; a duplicated goal would name two.
    const goals = try tmp.dir.readFileAlloc(io, "state/goals.json", gpa, .limited(1 << 20));
    defer gpa.free(goals);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, goals, objective));
    std.debug.print("pass: operator journey: add-goal twice yields one goal\n", .{});
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
    std.debug.print("pass: operator journey: schedule add then list shows the task\n", .{});
}

test "operator journey: reports rename moves the record, its inventory line, and keeps the marker" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try harness.writeMockConfig(io, tmp.dir, gpa, 9);
    try harness.linkZigOut(io, tmp.dir);

    // The store's inventory README with the markers create/rename maintain.
    try tmp.dir.createDirPath(io, "docs/reports/investigations");
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/reports/README.md", .data = "# Reports\n\n<!-- inventory:bug:start -->\nNo reports yet.\n<!-- inventory:bug:end -->\n\n<!-- inventory:investigation:start -->\nNo reports yet.\n<!-- inventory:investigation:end -->\n" });

    // create with an unmarked slug: the tool inserts the marker itself.
    var created = try harness.run(gpa, io, tmp.dir, &.{ "reports", "create", "missing-tool", "2026-08-17-e2e-rename-target", "A record to rename", "TL;DR for the rename journey" });
    defer created.deinit(gpa);
    if (!created.ok()) std.debug.print("reports create failed.\nstdout: {s}\nstderr: {s}\n", .{ created.stdout, created.stderr });
    try std.testing.expect(created.ok());
    const marked = "docs/reports/investigations/2026-08-17-missing-clanker-tool-e2e-rename-target.md";
    try std.testing.expect(std.mem.find(u8, created.stdout, marked) != null);

    // rename with a slug that drops the marker: it survives anyway.
    var renamed = try harness.run(gpa, io, tmp.dir, &.{ "reports", "rename", marked, "2026-08-17-e2e-renamed" });
    defer renamed.deinit(gpa);
    if (!renamed.ok()) std.debug.print("reports rename failed.\nstdout: {s}\nstderr: {s}\n", .{ renamed.stdout, renamed.stderr });
    try std.testing.expect(renamed.ok());
    const new_path = "docs/reports/investigations/2026-08-17-missing-clanker-tool-e2e-renamed.md";
    try std.testing.expect(std.mem.find(u8, renamed.stdout, new_path) != null);

    // The file moved and the old name is gone.
    const moved = try tmp.dir.readFileAlloc(io, new_path, gpa, .limited(1 << 20));
    defer gpa.free(moved);
    try std.testing.expect(std.mem.find(u8, moved, "A record to rename") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(io, marked, gpa, .limited(1 << 20)));

    // The inventory line follows the record.
    const index = try tmp.dir.readFileAlloc(io, "docs/reports/README.md", gpa, .limited(1 << 20));
    defer gpa.free(index);
    try std.testing.expect(std.mem.find(u8, index, "investigations/2026-08-17-missing-clanker-tool-e2e-renamed.md") != null);
    try std.testing.expect(std.mem.find(u8, index, "e2e-rename-target") == null);
    std.debug.print("pass: operator journey: reports rename moves the record, its inventory line, and keeps the marker\n", .{});
}

test "operator journey: rfc create then list shows the decision" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // No LLM: rfc goes through the sandboxed rfc guest, like reports does.
    try harness.writeMockConfig(io, tmp.dir, gpa, 9);
    try harness.linkZigOut(io, tmp.dir);

    // create renders docs/rfcs/TEMPLATE.md, so the store has to exist here the
    // way it does in the repo. The tool refuses rather than inventing a
    // skeleton, which is the behaviour being relied on, not worked around.
    try tmp.dir.createDirPath(io, "docs/rfcs");
    try tmp.dir.writeFile(io, .{
        .sub_path = "docs/rfcs/TEMPLATE.md",
        .data =
        \\# RFC {{number}} — {{title}}
        \\
        \\## Status
        \\
        \\{{status}} — opened {{date}}.
        \\
        \\## Overview
        \\
        \\{{overview}}
        \\
        \\## Recommendation
        \\
        \\**Confidence:** {{confidence}}/10
        \\
        \\## References
        \\
        \\{{references}}
        \\
        ,
    });

    const title = "e2e-rfc HTTP client for the proxy";
    const overview = "The proxy needs one HTTP client and the choice is not recorded.";
    var created = try harness.run(gpa, io, tmp.dir, &.{ "rfc", "create", title, overview });
    defer created.deinit(gpa);
    if (!created.ok()) std.debug.print("rfc create failed.\nstdout: {s}\nstderr: {s}\n", .{ created.stdout, created.stderr });
    try std.testing.expect(created.ok());
    try std.testing.expect(std.mem.find(u8, created.stdout, "docs/rfcs/") != null);

    var listed = try harness.run(gpa, io, tmp.dir, &.{ "rfc", "list" });
    defer listed.deinit(gpa);
    if (!listed.ok()) std.debug.print("rfc list failed.\nstdout: {s}\nstderr: {s}\n", .{ listed.stdout, listed.stderr });
    try std.testing.expect(listed.ok());
    try std.testing.expect(std.mem.find(u8, listed.stdout, title) != null);
    std.debug.print("pass: operator journey: rfc create then list shows the decision\n", .{});
}
