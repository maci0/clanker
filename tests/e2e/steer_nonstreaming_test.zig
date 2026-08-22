//! Black-box `POST /api/steer` against a **non-streaming** `POST /api/run`.
//!
//! Steering is per in-flight run: `runRegister` in `src/cli.zig` claims a slot
//! keyed by goal id and/or session id, and `/api/steer` answers 404 when no
//! slot carries the key the client named. That registration used to sit inside
//! the `if (req.stream)` branch of the run handler, so a run started with
//! `stream:false` claimed nothing and was unsteerable for its whole life with
//! no indication to the caller
//! (docs/reports/bugs/2026-08-22-nonstreaming-runs-unsteerable.md).
//!
//! The run must still be working when the steer lands, so the mock provider
//! holds its answer (`holdResponses`) until the assertion has been made —
//! racing a mock-speed run to the finish line would pass either way.

const std = @import("std");
const mock_llm = @import("mock_llm.zig");
const harness = @import("harness.zig");

/// The `/api/run` POST, on its own thread: a non-streaming run answers only
/// when it is finished, and the whole point here is to act on it before then.
const RunJob = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    url: []const u8,
    payload: []const u8,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *RunJob) void {
        if (harness.httpPost(self.io, self.gpa, self.url, self.payload)) |body| {
            self.gpa.free(body);
        } else |_| {}
        self.done.store(true, .release);
    }
};

/// Waits until the mock provider has taken `want` requests. The mock records a
/// request before it answers, so this returning means a run is inside its LLM
/// call — and registration happens before the agent runs, so whatever slot the
/// run was ever going to claim is claimed by now.
fn waitRequests(io: std.Io, mock: *mock_llm.Server, want: usize, timeout_ms: u64) !void {
    const start = std.Io.Timestamp.now(io, .awake).nanoseconds;
    while (mock.requestCount() < want) {
        if (std.Io.Timestamp.now(io, .awake).nanoseconds - start > timeout_ms * std.time.ns_per_ms)
            return error.MockRequestTimeout;
        std.Io.sleep(io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch {};
    }
}

test "a non-streaming run registers a steer slot and takes a steering message" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A non-streaming run goes through `client.chat`, not `chatStream`, so the
    // scripted turn is a plain completion body -- an SSE one reaches it as
    // SyntaxError and the run dies before the assertion means anything.
    const turn0 = try mock_llm.jsonTurn(gpa, "counted");
    defer gpa.free(turn0);
    const mock = try mock_llm.Server.start(io, gpa, &.{turn0});
    defer mock.stop();
    mock.holdResponses();

    try harness.writeMockConfig(io, tmp.dir, gpa, mock.port);
    try harness.linkZigOut(io, tmp.dir);

    const webui = try harness.pickPort(io);
    var srv = try harness.spawnServe(io, tmp.dir, webui);
    defer srv.stop(io);

    var health_buf: [96]u8 = undefined;
    try harness.waitHttp(io, gpa, try std.fmt.bufPrint(&health_buf, "http://127.0.0.1:{d}/health/live", .{webui}), 10_000);

    var run_url_buf: [80]u8 = undefined;
    const run_url = try std.fmt.bufPrint(&run_url_buf, "http://127.0.0.1:{d}/api/run", .{webui});
    var job = RunJob{
        .io = io,
        .gpa = gpa,
        .url = run_url,
        .payload = "{\"task\":\"count to three\",\"session\":\"steer-nonstream\",\"stream\":false}",
    };
    const th = try std.Thread.spawn(.{}, RunJob.run, .{&job});
    // Reverse order: let the held answer go, then join the run thread, then
    // stop the mock. A failed assertion tears down the same way.
    defer th.join();
    defer mock.releaseHold();

    try waitRequests(io, mock, 1, 10_000);

    var steer_url_buf: [80]u8 = undefined;
    const steer_url = try std.fmt.bufPrint(&steer_url_buf, "http://127.0.0.1:{d}/api/steer", .{webui});
    var answer = try harness.httpRequest(io, gpa, .POST, steer_url, "{\"session\":\"steer-nonstream\",\"message\":\"stop after this turn\"}");
    defer answer.deinit(gpa);
    if (answer.status != 200)
        std.debug.print("POST /api/steer -> {d}\n{s}\n", .{ answer.status, answer.body });
    try std.testing.expectEqual(@as(u16, 200), answer.status);
    try std.testing.expect(answer.has("\"ok\":true"));
}
