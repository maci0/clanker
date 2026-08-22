//! `POST /api/run` with `stream: true` must announce the model serving each
//! agent iteration as an `llm_start` control frame. The web UI's live run
//! graph has always had a branch for that event
//! (`ui/app/app.js`: `evt.type === "llm_start"`), and no server path ever
//! emitted one, so the branch was dead and the live graph showed iterations
//! without their models
//! (docs/reports/bugs/2026-08-22-webui-llm-start-event-never-emitted.md).
//!
//! Driven against the real binary and a scripted mock provider, so the
//! assertion is about bytes the shipped handler put on a real socket.

const std = @import("std");
const harness = @import("harness.zig");
const mock_llm = @import("mock_llm.zig");

fn url(buf: []u8, port: u16, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ port, path });
}

/// The `\x01`-prefixed control line whose `type` is `needle`, without the
/// prefix or the trailing newline. Plain text and other events share the
/// stream, so scanning for the frame is what a client's splitter does too.
fn findEvent(body: []const u8, needle: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (line.len < 2 or line[0] != 1) continue;
        const json = line[1..];
        if (std.mem.find(u8, json, needle) != null) return json;
    }
    return null;
}

test "a streaming run announces the serving model as an llm_start frame" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const turn0 = try mock_llm.textTurn(gpa, "the mock answered");
    defer gpa.free(turn0);
    const mock = try mock_llm.Server.start(io, gpa, &.{turn0});
    defer mock.stop();

    try harness.writeMockConfig(io, tmp.dir, gpa, mock.port);
    try harness.linkZigOut(io, tmp.dir);

    const port = try harness.pickPort(io);
    var srv = try harness.spawnServe(io, tmp.dir, port);
    defer srv.stop(io);
    try harness.waitTcp(io, port, 8000);
    var wait_buf: [96]u8 = undefined;
    try harness.waitHttp(io, gpa, try url(&wait_buf, port, "/api/workflows"), 8000);

    var run_buf: [96]u8 = undefined;
    const body = try harness.httpPost(
        io,
        gpa,
        try url(&run_buf, port, "/api/run"),
        "{\"task\":\"say hi\",\"stream\":true}",
    );
    defer gpa.free(body);

    const frame = findEvent(body, "\"llm_start\"") orelse {
        std.debug.print("no llm_start frame in the run stream:\n{s}\n", .{body});
        return error.NoLlmStartEvent;
    };
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, frame, .{});
    try std.testing.expectEqualStrings("llm_start", parsed.object.get("type").?.string);
    // Named before the turn runs, so it is the config's provider and model —
    // the same pair the `done` trailer reports when nothing repoints it.
    try std.testing.expectEqualStrings("e2e-mock", parsed.object.get("served_by").?.string);
    try std.testing.expectEqualStrings("mock", parsed.object.get("model").?.string);
    try std.testing.expectEqual(@as(i64, 0), parsed.object.get("iteration").?.integer);
    // The frame precedes the answer it belongs to: a live viewer draws the
    // LLM step while it runs, not after the fact.
    const llm_at = std.mem.find(u8, body, "\"llm_start\"").?;
    const done_at = std.mem.find(u8, body, "\"done\"").?;
    try std.testing.expect(llm_at < done_at);
}
