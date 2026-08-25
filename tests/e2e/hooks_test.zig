//! Black-box proof for the Claude Code lifecycle bridge: the real CLI loads
//! hooks.json, denies a real tool call, injects context, and obeys a one-shot
//! Stop hook before accepting the next final answer.

const std = @import("std");
const mock_llm = @import("mock_llm.zig");
const harness = @import("harness.zig");

test "clanker run: lifecycle hooks deny inject and force one more step" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const turn0 = try mock_llm.toolCallTurn(gpa, "call_1", "load_tools", "{\"names\":[\"list_files\"]}");
    defer gpa.free(turn0);
    const turn1 = try mock_llm.toolCallTurn(gpa, "call_2", "list_files", "{\"path\":\".\"}");
    defer gpa.free(turn1);
    const turn2 = try mock_llm.textTurn(gpa, "premature answer");
    defer gpa.free(turn2);
    const final_text = "hook-aware final answer";
    const turn3 = try mock_llm.textTurn(gpa, final_text);
    defer gpa.free(turn3);
    const mock = try mock_llm.Server.start(io, gpa, &.{ turn0, turn1, turn2, turn3 });
    defer mock.stop();

    try harness.writeMockConfig(io, tmp.dir, gpa, mock.port);
    const original = try tmp.dir.readFileAlloc(io, "config.toml", gpa, .limited(1 << 20));
    defer gpa.free(original);
    const configured = try std.fmt.allocPrint(gpa,
        \\{s}repl_exec_allow = ["printf", "python3"]
        \\
        \\[hooks]
        \\enabled = true
        \\config_path = "hooks.json"
        \\default_timeout_ms = 10000
        \\
    , .{original});
    defer gpa.free(configured);
    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data = configured });

    const stop_command =
        \\python3 -c "import os
        \\p='stop.once'
        \\first=not os.path.exists(p)
        \\open(p,'a').close()
        \\q=chr(34)
        \\deny='{'+q+'decision'+q+':'+q+'deny'+q+','+q+'reason'+q+':'+q+'stop-hook-continue'+q+'}'
        \\print(deny if first else '{}')"
    ;
    const hooks_json = try std.fmt.allocPrint(gpa,
        \\{{"hooks":{{
        \\  "SessionStart":[{{"hooks":[{{"type":"command","command":"printf '{{\\\"additionalContext\\\":\\\"session-marker\\\"}}'"}}]}}],
        \\  "UserPromptSubmit":[{{"hooks":[{{"type":"command","command":"printf '{{\\\"additionalContext\\\":\\\"prompt-marker\\\"}}'"}}]}}],
        \\  "PreToolUse":[{{"matcher":"list_files","hooks":[{{"type":"command","command":"printf '{{\\\"decision\\\":\\\"deny\\\",\\\"reason\\\":\\\"pre-hook-denied\\\"}}'"}}]}}],
        \\  "PostToolUse":[{{"matcher":"list_files","hooks":[{{"type":"command","command":"printf '{{\\\"additionalContext\\\":\\\"post-marker\\\"}}'"}}]}}],
        \\  "Stop":[{{"hooks":[{{"type":"command","command":{f}}}]}}]
        \\}}}}
    , .{std.json.fmt(stop_command, .{})});
    defer gpa.free(hooks_json);
    try tmp.dir.writeFile(io, .{ .sub_path = "hooks.json", .data = hooks_json });
    try harness.linkZigOut(io, tmp.dir);

    var result = try harness.run(gpa, io, tmp.dir, &.{ "run", "exercise lifecycle hooks" });
    defer result.deinit(gpa);
    if (!result.ok() or std.mem.find(u8, result.stdout, final_text) == null) std.debug.print("hook e2e failed.\nstdout: {s}\nstderr: {s}\n", .{ result.stdout, result.stderr });
    try std.testing.expect(result.ok());
    try std.testing.expect(std.mem.find(u8, result.stdout, final_text) != null);
    try std.testing.expectEqual(@as(usize, 4), mock.requestCount());

    const first = mock.request(0) orelse return error.MissingFirstRequest;
    try std.testing.expect(std.mem.find(u8, first, "session-marker") != null);
    try std.testing.expect(std.mem.find(u8, first, "prompt-marker") != null);
    const third = mock.request(2) orelse return error.MissingThirdRequest;
    try std.testing.expect(std.mem.find(u8, third, "pre-hook-denied") != null);
    try std.testing.expect(std.mem.find(u8, third, "post-marker") != null);
    const fourth = mock.request(3) orelse return error.MissingFourthRequest;
    try std.testing.expect(std.mem.find(u8, fourth, "stop-hook-continue") != null);
}
