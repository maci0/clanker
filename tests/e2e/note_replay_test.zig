//! `note_write` twice is one note, even when the two executions are two
//! harnesses.
//!
//! The store behind it is `state/learnings.md`, and the system prompt injects
//! it into *every future run*, so a duplicate is not one extra line in a log:
//! it is an extra bullet in every prompt from then on, spending context
//! forever.
//!
//! The interesting execution is the concurrent one, not the serial one. Two
//! calls in one turn take the sequential fallback (the second call of a
//! duplicated tool name does), so a read-then-scan dedup passes there. Two
//! harnesses over one store do not serialize, which is why the guest writes
//! under `fsWriteIf(expected_hash, ...)` rather than appending: an append
//! carries no digest, so it cannot say "only if absent" about a file another
//! writer changed while it was deciding.
//!
//! What this test proves is the end state under two real harnesses: one bullet.
//! It cannot time the guest's read-append window (microseconds) against two
//! process startups (hundreds of milliseconds), so it is a state assertion
//! over the real store, not a race detector. The property that closes the
//! window is in `notes_logic.appendNote` plus the compare-and-swap the guest
//! takes, and the second test below pins the shipped `duplicate` answer.

const std = @import("std");
const mock_llm = @import("mock_llm.zig");
const harness = @import("harness.zig");

const note = "read the manifest before adding a tool";

test "two harnesses writing the same note store one bullet" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const note_json = try std.fmt.allocPrint(gpa, "{{\"note\":{f}}}", .{std.json.fmt(note, .{})});
    defer gpa.free(note_json);

    // Each run gets its own scripted model: two harnesses, two turns, one
    // note. Started back to back and left to overlap, which is the window the
    // scan-only dedup lost.
    const mk = struct {
        fn turns(alloc: std.mem.Allocator, note_args: []const u8, ids: [3][]const u8) ![3][]const u8 {
            var t: [3][]const u8 = undefined;
            t[0] = try mock_llm.toolCallTurn(alloc, ids[0], "load_tools", "{\"names\":[\"note_write\"]}");
            t[1] = try mock_llm.toolCallTurn(alloc, ids[1], "note_write", note_args);
            t[2] = try mock_llm.textTurn(alloc, "Noted.");
            return t;
        }
    };
    const ta = try mk.turns(gpa, note_json, .{ "a1", "a2", "a3" });
    defer for (ta) |t| gpa.free(t);
    const tb = try mk.turns(gpa, note_json, .{ "b1", "b2", "b3" });
    defer for (tb) |t| gpa.free(t);

    const mock_a = try mock_llm.Server.start(io, gpa, &ta);
    defer mock_a.stop();
    const mock_b = try mock_llm.Server.start(io, gpa, &tb);
    defer mock_b.stop();

    // Two checkouts, one store: each harness gets its own config pointing at
    // its own scripted model, and both resolve `state/` to the same directory
    // through the same symlink an improve worktree uses. That is the shape a
    // TUI plus a cron plus a served run actually have, and it is what makes
    // the two executions concurrent without racing a shared config file.
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    try harness.writeMockConfig(io, tmp.dir, gpa, mock_a.port);
    try harness.linkZigOut(io, tmp.dir);
    try harness.writeMockConfig(io, tmp_b.dir, gpa, mock_b.port);
    try harness.linkZigOut(io, tmp_b.dir);
    const abs_a = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/state", .{tmp.sub_path});
    defer gpa.free(abs_a);
    try tmp_b.dir.symLink(io, abs_a, "state", .{});

    const Child = struct { thread: std.Thread, out: ?harness.Run = null, err: ?anyerror = null };
    const body = struct {
        fn one(gpa2: std.mem.Allocator, io2: std.Io, dir: std.Io.Dir, self2: *Child) void {
            const r = harness.run(gpa2, io2, dir, &.{ "run", "note a lesson" }) catch |e| {
                self2.err = e;
                return;
            };
            self2.out = r;
        }
    }.one;

    var a: Child = .{ .thread = undefined };
    var b: Child = .{ .thread = undefined };
    a.thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, body, .{ gpa, io, tmp.dir, &a });
    b.thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, body, .{ gpa, io, tmp_b.dir, &b });
    a.thread.join();
    b.thread.join();

    const runs: [2]*Child = .{ &a, &b };
    for (runs) |c| {
        if (c.err) |e| return e;
        var r = c.out orelse return error.MissingRunOutput;
        defer r.deinit(gpa);
        if (!r.ok()) std.debug.print("run failed.\nstdout: {s}\nstderr: {s}\n", .{ r.stdout, r.stderr });
        try std.testing.expect(r.ok());
    }

    // The shipped file is the store: assert on its bytes, not on a count
    // inside a request body, where the note legitimately appears more than
    // once (the tool result, and the Learnings section of the prompt).
    const stored = tmp.dir.readFileAlloc(io, "state/learnings.md", gpa, .limited(1 << 20)) catch |err| {
        std.debug.print("state/learnings.md unreadable: {s}\n", .{@errorName(err)});
        return err;
    };
    defer gpa.free(stored);
    try std.testing.expectEqualStrings("- " ++ note ++ "\n", stored);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, stored, note));
}

test "writing the same note twice in one run reports the second as a duplicate" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const note_json = try std.fmt.allocPrint(gpa, "{{\"note\":{f}}}", .{std.json.fmt(note, .{})});
    defer gpa.free(note_json);

    // load_tools first: tools are not offered up front (see
    // tool_roundtrip_test.zig). Then the same note twice with distinct call
    // ids -- the model repeating itself, not the transport replaying one
    // call.
    const turn0 = try mock_llm.toolCallTurn(gpa, "call_1", "load_tools", "{\"names\":[\"note_write\"]}");
    defer gpa.free(turn0);
    const turn1 = try mock_llm.toolCallTurn(gpa, "call_2", "note_write", note_json);
    defer gpa.free(turn1);
    const turn2 = try mock_llm.toolCallTurn(gpa, "call_3", "note_write", note_json);
    defer gpa.free(turn2);
    const turn3 = try mock_llm.textTurn(gpa, "Noted.");
    defer gpa.free(turn3);

    const mock = try mock_llm.Server.start(io, gpa, &.{ turn0, turn1, turn2, turn3 });
    defer mock.stop();
    try harness.writeMockConfig(io, tmp.dir, gpa, mock.port);
    try harness.linkZigOut(io, tmp.dir);

    var result = try harness.run(gpa, io, tmp.dir, &.{ "run", "note a lesson twice" });
    defer result.deinit(gpa);
    if (!result.ok()) std.debug.print("clanker run failed.\nstdout: {s}\nstderr: {s}\n", .{ result.stdout, result.stderr });
    try std.testing.expect(result.ok());

    const stored = tmp.dir.readFileAlloc(io, "state/learnings.md", gpa, .limited(1 << 20)) catch |err| {
        std.debug.print("state/learnings.md unreadable: {s}\n", .{@errorName(err)});
        return err;
    };
    defer gpa.free(stored);
    try std.testing.expectEqualStrings("- " ++ note ++ "\n", stored);

    // And the replay is reported as a duplicate rather than as a second
    // successful write, so the caller can tell one execution from two. The
    // second call's result rides the next request the model makes, which is
    // the last one before its final answer.
    const after_replay = mock.request(3) orelse return error.MissingReplayRequest;
    try std.testing.expect(std.mem.indexOf(u8, after_replay, "\"duplicate\\\":true") != null);
}
