//! The run graph must name the provider that actually served, not the one
//! the run started on. `chatWithFallbackChain` repoints the agent's provider
//! when the primary fails, and the graph used to keep the name stamped at run
//! start — so a run served entirely by the fallback finished looking like the
//! primary while `state/token_stats.jsonl` named the real server
//! (run-1787063448: graph said anthropic, the tokens were deepseek's).

const std = @import("std");
const mock_llm = @import("mock_llm.zig");
const harness = @import("harness.zig");
const e2e_options = @import("e2e_options");

/// Two providers: the default one dead (127.0.0.1:9 refuses the connect, the
/// same never-listening port the mesh fixtures use), the fallback a scripted
/// mock. No api_key_env on either, so both pass the offline credential gate
/// and only the transport decides.
fn writeFallbackConfig(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator, mock_port: u16) !void {
    const toml = try std.fmt.allocPrint(gpa,
        \\default_provider = "dead"
        \\
        \\[providers.dead]
        \\kind = "openai_compat"
        \\base_url = "http://127.0.0.1:9"
        \\default_model = "mock"
        \\
        \\[models."dead/mock"]
        \\provider = "dead"
        \\context_window = 32000
        \\max_tokens = 4096
        \\
        \\[providers.e2e-mock]
        \\kind = "openai_compat"
        \\base_url = "http://127.0.0.1:{d}"
        \\default_model = "mock2"
        \\
        \\[models."e2e-mock/mock2"]
        \\provider = "e2e-mock"
        \\context_window = 32000
        \\max_tokens = 4096
        \\
        \\[agent]
        \\tools_dir = {f}
        \\fallback_providers = ["e2e-mock"]
        \\
    , .{ mock_port, std.json.fmt(e2e_options.tools_manifests_dir, .{}) });
    defer gpa.free(toml);
    try dir.writeFile(io, .{ .sub_path = "config.toml", .data = toml });
}

test "a run served by the fallback provider records the fallback in its graph" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const final_text = "served by the fallback";
    const turn0 = try mock_llm.textTurn(gpa, final_text);
    defer gpa.free(turn0);
    const mock = try mock_llm.Server.start(io, gpa, &.{turn0});
    defer mock.stop();

    try writeFallbackConfig(io, tmp.dir, gpa, mock.port);
    try harness.linkZigOut(io, tmp.dir);

    var result = try harness.run(gpa, io, tmp.dir, &.{ "run", "say hi" });
    defer result.deinit(gpa);
    if (!result.ok()) std.debug.print("clanker run failed.\nstdout: {s}\nstderr: {s}\n", .{ result.stdout, result.stderr });
    try std.testing.expect(result.ok());
    try std.testing.expect(std.mem.find(u8, result.stdout, final_text) != null);
    // The dead primary never reached the mock; the one scripted turn did.
    try std.testing.expectEqual(@as(usize, 1), mock.requestCount());

    // The persisted graph names who served, not who was asked first.
    var runs = try tmp.dir.openDir(io, "state/runs", .{ .iterate = true });
    defer runs.close(io);
    var it = runs.iterate();
    var graphs: usize = 0;
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "run-")) continue;
        graphs += 1;
        // The id is minted at nanosecond resolution: two top-level runs
        // starting in the same second would otherwise share one file here and
        // one graph would silently overwrite the other (the collision that
        // moved sub-agent ids to nanoseconds). A seconds-wide id is 10 digits;
        // a nanosecond one is 19.
        const digits = entry.name["run-".len .. entry.name.len - ".json".len];
        try std.testing.expect(digits.len > 10);
        const body = try runs.readFileAlloc(io, entry.name, gpa, .limited(1 << 20));
        defer gpa.free(body);
        try std.testing.expect(std.mem.find(u8, body, "\"provider\":\"e2e-mock\"") != null);
        try std.testing.expect(std.mem.find(u8, body, "\"provider\":\"dead\"") == null);
    }
    try std.testing.expectEqual(@as(usize, 1), graphs);
}
