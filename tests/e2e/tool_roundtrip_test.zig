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

    // The recorded run keeps its answer readable after the fact: this is the
    // verb the missing-tool record asked for
    // (docs/reports/investigations/2026-08-17-missing-clanker-tool-no-verb-prints-a-runs-final-answer.md).
    var answered = try harness.run(gpa, io, tmp.dir, &.{ "graph", "answer" });
    defer answered.deinit(gpa);
    if (!answered.ok()) std.debug.print("graph answer failed.\nstdout: {s}\nstderr: {s}\n", .{ answered.stdout, answered.stderr });
    try std.testing.expect(answered.ok());
    try std.testing.expect(std.mem.find(u8, answered.stdout, final_text) != null);
}

test "clanker run: descriptor prompt_guidance reaches the wire in the system prompt" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const turn0 = try mock_llm.textTurn(gpa, "hi");
    defer gpa.free(turn0);
    const mock = try mock_llm.Server.start(io, gpa, &.{turn0});
    defer mock.stop();
    try harness.writeMockConfig(io, tmp.dir, gpa, mock.port);
    try harness.linkZigOut(io, tmp.dir);

    var result = try harness.run(gpa, io, tmp.dir, &.{ "run", "say hi" });
    defer result.deinit(gpa);
    if (!result.ok()) std.debug.print("clanker run failed.\nstdout: {s}\nstderr: {s}\n", .{ result.stdout, result.stderr });
    try std.testing.expect(result.ok());

    // The rfc descriptor declares prompt_guidance, so the very first request's
    // system prompt must carry the "## Tool guidance" section with the rfc
    // block — before any tool is loaded, which is the point: the rules ride
    // ahead of the lazy-loaded schema.
    try std.testing.expectEqual(@as(usize, 1), mock.requestCount());
    const first = mock.request(0) orelse return error.MissingRequest;
    try std.testing.expect(std.mem.find(u8, first, "## Tool guidance") != null);
    try std.testing.expect(std.mem.find(u8, first, "### rfc") != null);
    try std.testing.expect(std.mem.find(u8, first, "A docs/research/ note is never a source") != null);
}

test "clanker run --reasoning-effort pins the request's reasoning field" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const turn0 = try mock_llm.textTurn(gpa, "hi");
    defer gpa.free(turn0);
    const mock = try mock_llm.Server.start(io, gpa, &.{turn0});
    defer mock.stop();
    try harness.writeMockConfig(io, tmp.dir, gpa, mock.port);
    try harness.linkZigOut(io, tmp.dir);

    var result = try harness.run(gpa, io, tmp.dir, &.{ "run", "--reasoning-effort", "high", "say hi" });
    defer result.deinit(gpa);
    if (!result.ok()) std.debug.print("clanker run failed.\nstdout: {s}\nstderr: {s}\n", .{ result.stdout, result.stderr });
    try std.testing.expect(result.ok());

    // The pinned effort reaches the wire: the request body carries the flat
    // OpenAI field (the mock provider's thinking_schema default).
    try std.testing.expectEqual(@as(usize, 1), mock.requestCount());
    const first = mock.request(0) orelse return error.MissingRequest;
    try std.testing.expect(std.mem.find(u8, first, "\"reasoning_effort\":\"high\"") != null);

    // A bad value is a usage error before any request is made.
    var bad = try harness.run(gpa, io, tmp.dir, &.{ "run", "--reasoning-effort", "turbo", "say hi" });
    defer bad.deinit(gpa);
    try std.testing.expect(!bad.ok());
    try std.testing.expect(std.mem.find(u8, bad.stderr, "--reasoning-effort") != null);
    try std.testing.expectEqual(@as(usize, 1), mock.requestCount());
}

test "clanker run: the request uses the model max_tokens, not max_tokens_per_turn" {
    // Regression: llmChat / the streaming path sent agent.max_tokens_per_turn
    // (default 4096) as ChatParams.max_tokens. That key is the per-turn
    // input/compaction cap. Escalation run-1787011404 used deepseek-v4-pro
    // configured at 32768, still requested 4096, spent the grant on
    // reasoning_content, and died AnswerTruncatedToEmpty.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const turn0 = try mock_llm.textTurn(gpa, "ok");
    defer gpa.free(turn0);
    const mock = try mock_llm.Server.start(io, gpa, &.{turn0});
    defer mock.stop();
    try harness.writeMockConfig(io, tmp.dir, gpa, mock.port);
    try harness.linkZigOut(io, tmp.dir);

    const base = try tmp.dir.readFileAlloc(io, "config.toml", gpa, .limited(1 << 20));
    defer gpa.free(base);
    const patched = try std.mem.replaceOwned(u8, gpa, base, "max_tokens = 4096", "max_tokens = 8192");
    defer gpa.free(patched);
    const with_cap = try std.fmt.allocPrint(gpa,
        \\{s}
        \\max_tokens_per_turn = 4096
        \\
    , .{patched});
    defer gpa.free(with_cap);
    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data = with_cap });

    var result = try harness.run(gpa, io, tmp.dir, &.{ "run", "say hi" });
    defer result.deinit(gpa);
    if (!result.ok()) std.debug.print("clanker run failed.\nstdout: {s}\nstderr: {s}\n", .{ result.stdout, result.stderr });
    try std.testing.expect(result.ok());
    const first = mock.request(0) orelse return error.MissingRequest;
    try std.testing.expect(std.mem.find(u8, first, "\"max_tokens\":8192") != null);
    try std.testing.expect(std.mem.find(u8, first, "\"max_tokens\":4096") == null);
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
    // Sessions are SQLite files (`db_suffix = ".db"`, ADR 0033): the store
    // migrated away from JSON. Read the .db and look for the task text, which
    // SQLite stores as a contiguous string in the messages table.
    const session = try tmp.dir.readFileAlloc(io, "state/sessions/worktree-state.db", gpa, .limited(1 << 20));
    defer gpa.free(session);
    try std.testing.expect(std.mem.find(u8, session, "persist a goal") != null);
}
