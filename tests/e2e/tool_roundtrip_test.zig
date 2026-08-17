//! Proves the full stack end to end: the real `clanker` binary, spawned as a
//! subprocess, parses a task, calls the (scripted, local) LLM, loads the
//! `list_files` tool's schema (tools are gated behind `load_tools`, not
//! offered up front — see the comment below), actually executes it as a
//! sandboxed WASM module against a real temp directory, sends the real
//! result back, and prints the LLM's real final answer to stdout. Nothing
//! here is stubbed except the LLM itself — the sandbox, the tool, and the
//! filesystem are all real.

const std = @import("std");
const mock_llm = @import("mock_llm.zig");
const harness = @import("harness.zig");

test "clanker run: a tool call round-trips through the real sandbox" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A real marker only the sandboxed tool, not this test, can have put into
    // the second LLM request: if it shows up there, list_files really ran.
    try tmp.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "marker\n" });

    const final_text = "I see hello.txt in the directory.";
    // Tools are not offered by name up front: the system prompt exposes only
    // `load_tools`, and calling any other tool cold fails "unknown tool" (a
    // real behavior this test found, not an assumption) — so the scripted
    // model has to load_tools(["list_files"]) before it can call it.
    const turn0 = try mock_llm.toolCallTurn(gpa, "call_1", "load_tools", "{\"names\":[\"list_files\"]}");
    defer gpa.free(turn0);
    const turn1 = try mock_llm.toolCallTurn(gpa, "call_2", "list_files", "{\"path\":\".\"}");
    defer gpa.free(turn1);
    const turn2 = try mock_llm.textTurn(gpa, final_text);
    defer gpa.free(turn2);

    const mock = try mock_llm.Server.start(io, gpa, &.{ turn0, turn1, turn2 });
    defer mock.stop();
    try harness.writeMockConfig(io, tmp.dir, gpa, mock.port);
    try harness.linkZigOut(io, tmp.dir);

    var result = try harness.run(gpa, io, tmp.dir, &.{ "run", "list the files in this directory" });
    defer result.deinit(gpa);

    if (!result.ok()) std.debug.print("clanker run failed.\nstdout: {s}\nstderr: {s}\n", .{ result.stdout, result.stderr });
    try std.testing.expect(result.ok());
    try std.testing.expect(std.mem.find(u8, result.stdout, final_text) != null);

    try std.testing.expectEqual(@as(usize, 3), mock.requestCount());
    const third_request = mock.request(2) orelse return error.MissingThirdRequest;
    try std.testing.expect(std.mem.find(u8, third_request, "\"tool_call_id\":\"call_2\"") != null);
    try std.testing.expect(std.mem.find(u8, third_request, "hello.txt") != null);
}

test "clanker run: an answer truncated to empty is a failure, not silence" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Regression: the final reply hits the completion cap before emitting a
    // byte (finish_reason "length", empty content). The run used to exit 0
    // with no answer and no warning, so a script reading the exit status
    // believed the task succeeded (observed live, run-1786940774).
    const turn0 = try mock_llm.emptyLengthTurn(gpa);
    defer gpa.free(turn0);

    const mock = try mock_llm.Server.start(io, gpa, &.{turn0});
    defer mock.stop();
    try harness.writeMockConfig(io, tmp.dir, gpa, mock.port);
    try harness.linkZigOut(io, tmp.dir);

    var result = try harness.run(gpa, io, tmp.dir, &.{ "run", "say hi" });
    defer result.deinit(gpa);

    if (result.ok()) std.debug.print("clanker run unexpectedly succeeded.\nstdout: {s}\nstderr: {s}\n", .{ result.stdout, result.stderr });
    try std.testing.expect(!result.ok());
    // The failure names the cause, so the operator knows to raise the cap.
    try std.testing.expect(std.mem.find(u8, result.stderr, "completion-token limit") != null);
}

test "clanker run --worktree: goal and session state stay in the checkout" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `goal_add` is the persist guest. `goal` is the CLI/TUI loop (ADR 0012).
    const turn0 = try mock_llm.toolCallTurn(gpa, "call_1", "load_tools", "{\"names\":[\"goal_add\"]}");
    defer gpa.free(turn0);
    const turn1 = try mock_llm.toolCallTurn(gpa, "call_2", "goal_add", "{\"objective\":\"exercise shared worktree state\",\"completion_criterion\":\"the checkout retains the goal\"}");
    defer gpa.free(turn1);
    const final_text = "goal saved from the isolated worktree";
    const turn2 = try mock_llm.textTurn(gpa, final_text);
    defer gpa.free(turn2);
    const mock = try mock_llm.Server.start(io, gpa, &.{ turn0, turn1, turn2 });
    defer mock.stop();

    try harness.writeMockConfig(io, tmp.dir, gpa, mock.port);
    try harness.linkZigOut(io, tmp.dir);
    const config_before_hooks = try tmp.dir.readFileAlloc(io, "config.toml", gpa, .limited(1 << 20));
    defer gpa.free(config_before_hooks);
    const config_with_hooks = try std.fmt.allocPrint(gpa,
        \\{s}
        \\repl_exec_allow = ["printf"]
        \\ 
        \\ [hooks]
        \\ enabled = true
        \\ config_path = ".claude/settings.json"
        \\ default_timeout_ms = 2000
        \\ 
    , .{config_before_hooks});
    defer gpa.free(config_with_hooks);
    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data = config_with_hooks });
    try tmp.dir.createDirPath(io, ".claude");
    try tmp.dir.writeFile(io, .{ .sub_path = ".claude/settings.json", .data =
        \\{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"printf '{\\\"additionalContext\\\":\\\"shared-claude-marker\\\"}'"}]}]}}
    });
    try harness.initGitRepo(gpa, io, tmp.dir);

    var result = try harness.run(gpa, io, tmp.dir, &.{ "run", "--worktree", "--session", "worktree-state", "persist a goal" });
    defer result.deinit(gpa);
    if (!result.ok()) std.debug.print("worktree goal e2e failed.\nstdout: {s}\nstderr: {s}\n", .{ result.stdout, result.stderr });
    try std.testing.expect(result.ok());
    try std.testing.expect(std.mem.find(u8, result.stdout, final_text) != null);
    const first_request = mock.request(0) orelse return error.MissingFirstRequest;
    try std.testing.expect(std.mem.find(u8, first_request, "shared-claude-marker") != null);

    // The goal guest and the native session writer use different path
    // mechanisms. Both must land in the checkout, even when state/ did not
    // exist before the worktree was created.
    const goals = try tmp.dir.readFileAlloc(io, "state/goals.json", gpa, .limited(1 << 20));
    defer gpa.free(goals);
    try std.testing.expect(std.mem.find(u8, goals, "exercise shared worktree state") != null);
    const session = try tmp.dir.readFileAlloc(io, "state/sessions/worktree-state.json", gpa, .limited(1 << 20));
    defer gpa.free(session);
    try std.testing.expect(std.mem.find(u8, session, "persist a goal") != null);
}
