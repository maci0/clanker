//! The improve engine's proposal and plan LLM calls must survive a dead or
//! silent primary provider the way the agent loop does: `chatWithFallbackChain`
//! walks `agent.fallback_providers` after the primary fails, instead of the
//! engine aborting the whole improve-self run with ProposalRequestFailed.
//! Before this wiring, a local provider that accepted a connection and went
//! quiet (run's `provider 'ollama' did not answer within 900000ms`) killed the
//! run even though config.toml listed healthy fallbacks.

const std = @import("std");
const mock_llm = @import("mock_llm.zig");
const harness = @import("harness.zig");
const e2e_options = @import("e2e_options");

/// Primary provider dead (127.0.0.1:9 refuses the connect, the same
/// never-listening port the mesh fixtures use); the fallback a scripted mock.
/// No api_key_env on either, so both pass the offline credential gate and only
/// the transport decides — exactly the shape of `writeFallbackConfig` in
/// fallback_graph_test.zig, plus `fallback_providers` so the improve engine's
/// chain has somewhere to go.
fn writeImproveFallbackConfig(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator, mock_port: u16) !void {
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

test "improve-self falls back to a configured provider when the primary is down" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // One no-op proposal. The improve engine asks the plan phase first, then a
    // single-shot proposal; the fallback mock repeats its last scripted answer
    // for any request past the end of the script, so one entry serves both.
    // With --dry-run the empty-changes proposal is reported and not applied,
    // so the run ends cleanly instead of running the real gate.
    const proposal = try mock_llm.jsonTurn(gpa, "{\"summary\":\"noop\",\"rationale\":\"dry run\",\"changes\":[]}");
    defer gpa.free(proposal);
    const mock = try mock_llm.Server.start(io, gpa, &.{proposal});
    defer mock.stop();

    try writeImproveFallbackConfig(io, tmp.dir, gpa, mock.port);
    try harness.linkZigOut(io, tmp.dir);

    var result = try harness.run(gpa, io, tmp.dir, &.{ "improve-self", "--dry-run", "--iters", "1", "test improvement" });
    defer result.deinit(gpa);

    if (!result.ok()) std.debug.print("clanker improve-self failed.\nstdout: {s}\nstderr: {s}\n", .{ result.stdout, result.stderr });
    try std.testing.expect(result.ok());
    // The primary is a never-listening port, so no request could have reached
    // it; every request the mock saw was served through the fallback chain.
    // Request count > 0 proves the improve engine routed its LLM call to the
    // fallback rather than dying with ProposalRequestFailed.
    try std.testing.expect(mock.requestCount() >= 1);
}

/// A single healthy mock provider with a reasoning model (thinking schema
/// default `reasoning_effort`). Used to prove the improve engine answers a
/// reasoning-only empty-content response by retrying with reasoning disabled.
fn writeImproveReasoningConfig(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator, mock_port: u16) !void {
    const toml = try std.fmt.allocPrint(gpa,
        "default_provider = \"e2e-mock\"\n" ++
        "\n" ++
        "[providers.e2e-mock]\n" ++
        "kind = \"openai_compat\"\n" ++
        "base_url = \"http://127.0.0.1:{d}\"\n" ++
        "default_model = \"mock\"\n" ++
        "\n" ++
        "[models.\"e2e-mock/mock\"]\n" ++
        "provider = \"e2e-mock\"\n" ++
        "context_window = 32000\n" ++
        "max_tokens = 4096\n" ++
        "reasoning_effort = \"medium\"\n" ++
        "\n" ++
        "[agent]\n" ++
        "tools_dir = {f}\n" ++
        "\n",
        .{ mock_port, std.json.fmt(e2e_options.tools_manifests_dir, .{}) });
    defer gpa.free(toml);
    try dir.writeFile(io, .{ .sub_path = "config.toml", .data = toml });
}

test "improve-self retries with reasoning disabled after a reasoning-only empty-content response" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Request 0 is the plan phase (an empty idea list parses to zero ideas and
    // the iteration runs unplanned). Request 1 is proposal attempt 1, which
    // answers entirely in reasoning with empty content -- the model defect
    // under test. Request 2 is proposal attempt 2, which must have been sent
    // with reasoning_effort "none" and returns a valid no-op proposal that
    // ends the iteration cleanly under --dry-run.
    const plan = try mock_llm.jsonTurn(gpa, "{\"ideas\":[]}");
    defer gpa.free(plan);
    // Pure chain-of-thought with no draft JSON: nothing for lastProposalJson to
    // recover, so the empty-content path really fires and the engine must retry
    // without reasoning. (A reasoning text that happened to contain a complete
    // proposal would be recovered instead, which is fine behaviour but not the
    // case under test.)
    const reasoning_only = try mock_llm.reasoningOnlyTurn(gpa, "I should propose a patch. Let me weigh what to change in the scheduling code before writing the JSON answer.");
    defer gpa.free(reasoning_only);
    const proposal = try mock_llm.jsonTurn(gpa, "{\"summary\":\"noop\",\"rationale\":\"dry run\",\"changes\":[]}");
    defer gpa.free(proposal);

    const mock = try mock_llm.Server.start(io, gpa, &.{ plan, reasoning_only, proposal });
    defer mock.stop();

    try writeImproveReasoningConfig(io, tmp.dir, gpa, mock.port);
    try harness.linkZigOut(io, tmp.dir);

    var result = try harness.run(gpa, io, tmp.dir, &.{ "improve-self", "--dry-run", "--iters", "1", "test improvement" });
    defer result.deinit(gpa);

    try std.testing.expect(result.ok());

    // Attempt 1 (request index 1) rode the model's configured "medium"; the
    // retry (request index 2) must have forced reasoning off so the model
    // cannot bury the JSON in chain-of-thought again.
    const attempt2 = mock.request(2) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.find(u8, attempt2, "\"reasoning_effort\":\"none\"") != null);
    // The model's own configured effort still shows on the first attempt.
    const attempt1 = mock.request(1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.find(u8, attempt1, "\"reasoning_effort\":\"medium\"") != null);
}
