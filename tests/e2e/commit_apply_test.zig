//! Black-box `clanker commit`: the plan it reports and the commits it writes
//! have to be the same thing. The apply path runs `git add` per group and then
//! `git commit`, which commits the whole index -- so anything staged before the
//! verb ran lands in the first group's commit, and the later groups find
//! nothing left to commit.
//!
//! Staging before running the verb is not an odd thing to do: it is what
//! docs/runbooks/concurrent-agent-sessions-on-one-checkout.md tells a session
//! to do so it commits only its own paths.

const std = @import("std");
const mock_llm = @import("mock_llm.zig");
const harness = @import("harness.zig");

/// Runs git in `dir` and returns its stdout. Fails the test on a non-zero exit
/// rather than returning a plausible-looking empty string.
fn git(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .dir = dir },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer gpa.free(result.stderr);
    errdefer gpa.free(result.stdout);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("git {s} -> {d}\n{s}\n", .{ argv[1], code, result.stderr });
            return error.GitFailed;
        },
        else => return error.GitFailed,
    }
    return result.stdout;
}

fn countLines(s: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, s, " \t\r\n"), '\n');
    while (it.next()) |line| {
        if (line.len > 0) n += 1;
    }
    return n;
}

test "clanker commit writes one commit per group even when the index was already full" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Two groups over two unrelated files: no import edge between them, so the
    // topo sort cannot collapse them into one commit on a degenerate cycle.
    const plan =
        "{\"commits\":[" ++
        "{\"message\":\"docs: add the alpha note\",\"files\":[\"alpha.md\"]}," ++
        "{\"message\":\"docs: add the beta note\",\"files\":[\"beta.md\"]}]}";
    // One call for the preview, one for the apply. Non-streaming: a guest's
    // `ck_llm` goes through `client.chat`.
    const turn = try mock_llm.jsonTurn(gpa, plan);
    defer gpa.free(turn);
    const mock = try mock_llm.Server.start(io, gpa, &.{ turn, turn });
    defer mock.stop();

    try harness.writeMockConfig(io, tmp.dir, gpa, mock.port);
    try harness.linkZigOut(io, tmp.dir);
    try harness.initGitRepo(gpa, io, tmp.dir);
    // `clanker commit` runs a bare `git commit`, which needs an identity in the
    // repo -- the fixture's initial commit passes one with -c and leaves none.
    gpa.free(try git(gpa, io, tmp.dir, &.{ "git", "config", "user.name", "e2e" }));
    gpa.free(try git(gpa, io, tmp.dir, &.{ "git", "config", "user.email", "e2e@example.invalid" }));

    try tmp.dir.writeFile(io, .{ .sub_path = "alpha.md", .data = "alpha\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "beta.md", .data = "beta\n" });
    // Both staged up front, the way a session narrows the index to its own
    // paths before committing.
    gpa.free(try git(gpa, io, tmp.dir, &.{ "git", "add", "alpha.md", "beta.md" }));

    const before = try git(gpa, io, tmp.dir, &.{ "git", "log", "--oneline" });
    defer gpa.free(before);

    var result = try harness.run(gpa, io, tmp.dir, &.{ "commit", "--yes" });
    defer result.deinit(gpa);
    if (!result.ok()) std.debug.print("clanker commit failed.\nstdout: {s}\nstderr: {s}\n", .{ result.stdout, result.stderr });
    try std.testing.expect(result.ok());
    // The report is what the operator is told happened; the assertions below
    // check the repository against it.
    if (std.mem.find(u8, result.stdout, "committed 2 commit(s)") == null)
        std.debug.print("clanker commit reported:\n{s}\n", .{result.stdout});
    try std.testing.expect(std.mem.find(u8, result.stdout, "committed 2 commit(s)") != null);

    const after = try git(gpa, io, tmp.dir, &.{ "git", "log", "--oneline" });
    defer gpa.free(after);
    try std.testing.expectEqual(countLines(before) + 2, countLines(after));

    const head_files = try git(gpa, io, tmp.dir, &.{ "git", "show", "--name-only", "--format=", "HEAD" });
    defer gpa.free(head_files);
    const prev_files = try git(gpa, io, tmp.dir, &.{ "git", "show", "--name-only", "--format=", "HEAD~1" });
    defer gpa.free(prev_files);
    // Each commit carries its own group's file and not the other's. Which of
    // the two lands on top is the topo sort's call, so assert the split rather
    // than the order.
    try std.testing.expectEqual(@as(usize, 1), countLines(head_files));
    try std.testing.expectEqual(@as(usize, 1), countLines(prev_files));
    const head_is_beta = std.mem.find(u8, head_files, "beta.md") != null;
    if (head_is_beta) {
        try std.testing.expect(std.mem.find(u8, prev_files, "alpha.md") != null);
    } else {
        try std.testing.expect(std.mem.find(u8, head_files, "alpha.md") != null);
        try std.testing.expect(std.mem.find(u8, prev_files, "beta.md") != null);
    }

    // Nothing of the two groups is left behind. (The tree is not otherwise
    // clean: running the verb drops `config.local.toml` and `state/` into the
    // fixture, and `zig-out` is the harness's symlink.)
    const left = try git(gpa, io, tmp.dir, &.{ "git", "status", "--short" });
    defer gpa.free(left);
    try std.testing.expect(std.mem.find(u8, left, "alpha.md") == null);
    try std.testing.expect(std.mem.find(u8, left, "beta.md") == null);
}
