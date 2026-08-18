//! Black-box `clanker commit`: the plan it reports and the commits it writes
//! have to be the same thing, in both directions.
//!
//! One commit per group: the apply path ran `git add` per group and then a bare
//! `git commit`, which commits the whole index -- so anything staged before the
//! verb ran landed in the first group's commit, and the later groups found
//! nothing left to commit.
//!
//! The staged content and nothing more: `git add` stages the working-tree copy
//! and a pathspec `git commit -- <files>` commits the working-tree copy, so an
//! index narrowed to one session's hunks was widened with whatever else was in
//! those files.
//!
//! Neither shape is odd: staging first, and narrowing the index to one
//! session's hunks, are both what
//! docs/runbooks/concurrent-agent-sessions-on-one-checkout.md tells a session
//! to do so it commits only its own work.

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

test "clanker commit writes the plan it previewed, without asking the model twice" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Two scripted answers over the same diff. If the apply path asks again it
    // gets the second one, which is what a truncated or differently-sampled
    // reply looks like in the field.
    const previewed =
        "{\"commits\":[" ++
        "{\"message\":\"docs: add the alpha note\",\"files\":[\"alpha.md\"]}," ++
        "{\"message\":\"docs: add the beta note\",\"files\":[\"beta.md\"]}]}";
    const resampled =
        "{\"commits\":[" ++
        "{\"message\":\"chore: update working tree\",\"files\":[\"alpha.md\",\"beta.md\"]}]}";
    const first = try mock_llm.jsonTurn(gpa, previewed);
    defer gpa.free(first);
    const second = try mock_llm.jsonTurn(gpa, resampled);
    defer gpa.free(second);
    const mock = try mock_llm.Server.start(io, gpa, &.{ first, second });
    defer mock.stop();

    try harness.writeMockConfig(io, tmp.dir, gpa, mock.port);
    try harness.linkZigOut(io, tmp.dir);
    try harness.initGitRepo(gpa, io, tmp.dir);
    gpa.free(try git(gpa, io, tmp.dir, &.{ "git", "config", "user.name", "e2e" }));
    gpa.free(try git(gpa, io, tmp.dir, &.{ "git", "config", "user.email", "e2e@example.invalid" }));

    try tmp.dir.writeFile(io, .{ .sub_path = "alpha.md", .data = "alpha\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "beta.md", .data = "beta\n" });
    gpa.free(try git(gpa, io, tmp.dir, &.{ "git", "add", "alpha.md", "beta.md" }));

    var result = try harness.run(gpa, io, tmp.dir, &.{ "commit", "--yes" });
    defer result.deinit(gpa);
    if (!result.ok()) std.debug.print("clanker commit failed.\nstdout: {s}\nstderr: {s}\n", .{ result.stdout, result.stderr });
    try std.testing.expect(result.ok());

    // The confirmed plan is what landed.
    const messages = try git(gpa, io, tmp.dir, &.{ "git", "log", "--format=%s", "-2" });
    defer gpa.free(messages);
    if (std.mem.find(u8, messages, "chore: update working tree") != null)
        std.debug.print("the apply path recomputed the plan:\n{s}\n", .{messages});
    try std.testing.expect(std.mem.find(u8, messages, "chore: update working tree") == null);
    try std.testing.expect(std.mem.find(u8, messages, "docs: add the alpha note") != null);
    try std.testing.expect(std.mem.find(u8, messages, "docs: add the beta note") != null);

    // And the grouping call was made once, not once per smart_commit call.
    try std.testing.expectEqual(@as(usize, 1), mock.requestCount());
}

test "clanker commit in scope staged commits the index, not the worktree" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const plan =
        "{\"commits\":[" ++
        "{\"message\":\"docs: add the shared note\",\"files\":[\"shared.md\"]}," ++
        "{\"message\":\"docs: add the other note\",\"files\":[\"other.md\"]}]}";
    const turn = try mock_llm.jsonTurn(gpa, plan);
    defer gpa.free(turn);
    const mock = try mock_llm.Server.start(io, gpa, &.{ turn, turn });
    defer mock.stop();

    try harness.writeMockConfig(io, tmp.dir, gpa, mock.port);
    try harness.linkZigOut(io, tmp.dir);
    try harness.initGitRepo(gpa, io, tmp.dir);
    gpa.free(try git(gpa, io, tmp.dir, &.{ "git", "config", "user.name", "e2e" }));
    gpa.free(try git(gpa, io, tmp.dir, &.{ "git", "config", "user.email", "e2e@example.invalid" }));

    // The shape docs/runbooks/concurrent-agent-sessions-on-one-checkout.md
    // produces: this session's line is staged, another session's line is in the
    // worktree and deliberately left out of the index.
    try tmp.dir.writeFile(io, .{ .sub_path = "shared.md", .data = "mine\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "other.md", .data = "other\n" });
    gpa.free(try git(gpa, io, tmp.dir, &.{ "git", "add", "shared.md", "other.md" }));
    try tmp.dir.writeFile(io, .{ .sub_path = "shared.md", .data = "mine\ntheirs-unfinished\n" });

    var result = try harness.run(gpa, io, tmp.dir, &.{ "commit", "--yes" });
    defer result.deinit(gpa);
    if (!result.ok()) std.debug.print("clanker commit failed.\nstdout: {s}\nstderr: {s}\n", .{ result.stdout, result.stderr });
    try std.testing.expect(result.ok());

    // The commit carries the staged content only. `git add` before the commit,
    // or a pathspec `git commit -- <files>`, would both have swept the other
    // session's line in.
    const touching = try git(gpa, io, tmp.dir, &.{ "git", "log", "-1", "--format=%H", "--", "shared.md" });
    defer gpa.free(touching);
    const rev = std.mem.trim(u8, touching, " \t\r\n");
    try std.testing.expect(rev.len > 0);
    const blob = try std.fmt.allocPrint(gpa, "{s}:shared.md", .{rev});
    defer gpa.free(blob);
    const in_history = try git(gpa, io, tmp.dir, &.{ "git", "show", blob });
    defer gpa.free(in_history);
    if (std.mem.find(u8, in_history, "theirs-unfinished") != null)
        std.debug.print("commit widened to the worktree copy:\n{s}\n", .{in_history});
    try std.testing.expect(std.mem.find(u8, in_history, "theirs-unfinished") == null);
    try std.testing.expect(std.mem.find(u8, in_history, "mine") != null);

    // The other session's edit is still in the worktree, still unstaged.
    const worktree = try tmp.dir.readFileAlloc(io, "shared.md", gpa, .limited(1 << 16));
    defer gpa.free(worktree);
    try std.testing.expect(std.mem.find(u8, worktree, "theirs-unfinished") != null);
    const unstaged = try git(gpa, io, tmp.dir, &.{ "git", "diff", "--name-only" });
    defer gpa.free(unstaged);
    try std.testing.expect(std.mem.find(u8, unstaged, "shared.md") != null);
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

test "clanker commit --yes refuses to auto-apply a degraded fallback plan" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A grouping reply cut off mid-JSON: what a reasoning model's answer
    // looks like when the descriptor's max_tokens grant is spent before the
    // plan is complete (completion_tokens == the grant, exactly). The guest
    // cannot parse it and falls back to one generic commit -- which --yes
    // must not write on its own: "yes" approved a model-grouped plan, not
    // whatever the fallback produced.
    const truncated = "{\"commits\":[{\"message\":\"feat: add the alpha no";
    const turn = try mock_llm.jsonTurn(gpa, truncated);
    defer gpa.free(turn);
    const mock = try mock_llm.Server.start(io, gpa, &.{turn});
    defer mock.stop();

    try harness.writeMockConfig(io, tmp.dir, gpa, mock.port);
    try harness.linkZigOut(io, tmp.dir);
    try harness.initGitRepo(gpa, io, tmp.dir);
    gpa.free(try git(gpa, io, tmp.dir, &.{ "git", "config", "user.name", "e2e" }));
    gpa.free(try git(gpa, io, tmp.dir, &.{ "git", "config", "user.email", "e2e@example.invalid" }));

    try tmp.dir.writeFile(io, .{ .sub_path = "alpha.md", .data = "alpha\n" });
    gpa.free(try git(gpa, io, tmp.dir, &.{ "git", "add", "alpha.md" }));
    const before = try git(gpa, io, tmp.dir, &.{ "git", "log", "--oneline" });
    defer gpa.free(before);

    var result = try harness.run(gpa, io, tmp.dir, &.{ "commit", "--yes" });
    defer result.deinit(gpa);

    // The verb fails loudly instead of writing the fallback plan. The
    // refusal is an operator-facing diagnostic, so it lands on stderr
    // (`printUsageError`, the util/diag.zig convention; 757d61f9 moved it
    // there from stdout) while the degraded plan's note stays on stdout
    // with the preview.
    if (result.ok()) std.debug.print("degraded plan was auto-applied.\nstdout: {s}\n", .{result.stdout});
    try std.testing.expect(!result.ok());
    try std.testing.expect(std.mem.find(u8, result.stderr, "degraded") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "fell back to one generic commit") != null);

    // And nothing was committed: the log is unchanged and the file is still
    // staged for whoever retries.
    const after = try git(gpa, io, tmp.dir, &.{ "git", "log", "--oneline" });
    defer gpa.free(after);
    try std.testing.expectEqual(countLines(before), countLines(after));
    const staged = try git(gpa, io, tmp.dir, &.{ "git", "diff", "--staged", "--name-only" });
    defer gpa.free(staged);
    try std.testing.expect(std.mem.find(u8, staged, "alpha.md") != null);
}
