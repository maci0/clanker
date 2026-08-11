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
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, final_text) != null);

    try std.testing.expectEqual(@as(usize, 3), mock.requestCount());
    const third_request = mock.request(2) orelse return error.MissingThirdRequest;
    try std.testing.expect(std.mem.indexOf(u8, third_request, "\"tool_call_id\":\"call_2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, third_request, "hello.txt") != null);
}
