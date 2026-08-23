//! Post-turn second-model critique. Fail-open: any error, timeout, or
//! unparseable reply is dropped and the main loop continues.
//!
//! Parse, summarize, and inject live in `tools/zig/advisor_logic.zig`
//! (host-tested, shared with the `advisor` guest). Provider resolution and
//! the fail-open `client.chat` call stay native (timeout + credentials).

const std = @import("std");
const config = @import("../config.zig");
const types = @import("../llm/types.zig");
const client = @import("../llm/client.zig");
const log = @import("../util/log.zig");
const logic = @import("advisor_logic");
const json_mod = std.json;

pub const system_prompt = logic.system_prompt;
pub const Severity = logic.Severity;
pub const Note = logic.Note;
pub const parseNote = logic.parseNote;
pub const formatInjection = logic.formatInjection;

pub fn summarizeTurn(
    arena: std.mem.Allocator,
    messages: []const types.Message,
    redact_names: []const []const u8,
) ![]const u8 {
    var converted = try std.ArrayList(logic.Message).initCapacity(arena, messages.len);
    for (messages) |m| {
        var calls: []const logic.ToolCall = &.{};
        if (m.tool_calls) |tcs| {
            const buf = try arena.alloc(logic.ToolCall, tcs.len);
            for (tcs, 0..) |tc, i| {
                buf[i] = .{ .name = tc.name, .arguments = tc.arguments };
            }
            calls = buf;
        }
        try converted.append(arena, .{
            .role = @tagName(m.role),
            .content = m.content,
            .tool_calls = calls,
        });
    }
    return logic.summarizeTurn(arena, converted.items, redact_names);
}

/// One fail-open advisor completion. Returns null on any error so the main
/// loop never sees an exception from this path.
pub fn review(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    cfg: *const config.Config,
    summary: []const u8,
) ?Note {
    if (!cfg.advisor.enabled) return null;
    const configured = cfg.provider(if (cfg.advisor.provider.len > 0) cfg.advisor.provider else null) catch |err| {
        log.log(.debug, "advisor skipped: {s}", .{@errorName(err)});
        return null;
    };
    // `advisor.model` is the whole point of the key -- "run the critique on a
    // cheap model" (docs/configuration.md `[advisor]`, PRD 0015's
    // `model = "gpt-4o-mini"  # cheap fast model`). It parsed, validated and
    // documented cleanly while nothing read it, so every enabled-advisor turn
    // silently billed the provider's `default_model`: the main, expensive
    // model, 256 completion tokens per tool batch.
    //
    // The copy is a shallow one and only `default_model` is reassigned, which
    // is the safe shape: `put`ting into a shallow-copied provider's `models`
    // map would alias the global config's map. Same pattern, same reason, as
    // `thinking.resolveClassifier`.
    var picked = configured.*;
    if (cfg.advisor.model.len > 0) {
        if (!picked.models.contains(cfg.advisor.model)) {
            // Not fatal: an unconfigured name still goes on the wire, exactly
            // as `default_model` would. Said out loud because a typo otherwise
            // reads as "the provider rejected the advisor".
            log.log(.debug, "advisor model '{s}' has no [models.\"{s}/{s}\"] entry; sending it with default model settings", .{
                cfg.advisor.model, picked.name, cfg.advisor.model,
            });
        }
        picked.default_model = cfg.advisor.model;
    }
    const provider = &picked;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx = client.Ctx{
        .io = io,
        .gpa = gpa,
        .environ_map = environ_map,
        .cfg = cfg,
    };
    const msgs = [_]types.Message{
        .{ .role = .system, .content = system_prompt },
        .{ .role = .user, .content = summary },
    };
    var err_detail: ?[]const u8 = null;
    const resp = client.chatWithTimeout(&ctx, arena, .{
        .provider = provider,
        .messages = &msgs,
        .max_tokens = 256,
    }, &err_detail, cfg.advisor.timeout_ms) catch |err| {
        log.log(.debug, "advisor failed: {s}", .{@errorName(err)});
        return null;
    };
    const raw = resp.message.content orelse return null;
    var note = parseNote(arena, raw) orelse {
        log.log(.debug, "advisor reply was not a note; dropping", .{});
        return null;
    };
    if (resp.usage) |u| note.tokens = u.total_tokens;
    const text = gpa.dupe(u8, note.text) catch return null;
    return .{ .severity = note.severity, .text = text, .tokens = note.tokens };
}

test "summarizeTurn converts native messages into the shared helper" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const calls = [_]types.ToolCall{.{ .id = "1", .name = "edit_file", .arguments = "{\"path\":\"/secret\"}" }};
    const msgs = [_]types.Message{
        .{ .role = .user, .content = "fix it" },
        .{ .role = .assistant, .content = "ok", .tool_calls = &calls },
        .{ .role = .system, .content = "[advisor: note]\nold\n[/advisor]\n" },
    };
    const out = try summarizeTurn(arena, &msgs, &.{"edit_file"});
    try std.testing.expect(std.mem.find(u8, out, "fix it") != null);
    try std.testing.expect(std.mem.find(u8, out, "<redacted>") != null);
    try std.testing.expect(std.mem.find(u8, out, "/secret") == null);
    try std.testing.expect(std.mem.find(u8, out, "[advisor:") == null);
}

test "advisor is off by default" {
    try std.testing.expect(!(config.Advisor{}).enabled);
}

test "review sends advisor.model, not the provider's default model" {
    // `advisor.model` used to be parsed, validated, documented and unread, so
    // the critique quietly ran on the main model. Read off the wire rather
    // than off the call chain: a mock provider records the body, and the
    // assertion is the `model` field it actually received.
    const mock_server = @import("../llm/mock_server.zig");
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const mock = try mock_server.MockServer.start(io, gpa, .anthropic_text);
    defer mock.stop();

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("MOCK_ADVISOR_KEY", "sk-test");

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base_url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{mock.port});

    var p = try config.Provider.single(arena, "critic", base_url, .anthropic, "expensive-main", .{ .max_tokens = 256 });
    p.api_key_env = "MOCK_ADVISOR_KEY";
    try p.models.put(arena, "cheap-critic", .{ .max_tokens = 256 });

    var cfg = config.Config{};
    try cfg.providers.put(arena, "critic", p);
    cfg.default_provider = "critic";
    cfg.advisor = .{ .enabled = true, .provider = "critic", .model = "cheap-critic", .timeout_ms = 30_000 };

    // The mock's canned prose is not a note, so `review` returns null; the
    // body it sent on the way there is the subject of the test.
    _ = review(io, gpa, &env, &cfg, "the turn summary");
    const sent = mock.lastCaptured() orelse return error.TestExpectedEqual;
    const body = try json_mod.parseFromSliceLeaky(json_mod.Value, arena, sent.body, .{});
    try std.testing.expectEqualStrings("cheap-critic", body.object.get("model").?.string);

    // Control: with no `advisor.model` the provider's default is what ships,
    // so the fix cannot be read as "always send some other model".
    cfg.advisor.model = "";
    _ = review(io, gpa, &env, &cfg, "the turn summary");
    const sent2 = mock.lastCaptured() orelse return error.TestExpectedEqual;
    const body2 = try json_mod.parseFromSliceLeaky(json_mod.Value, arena, sent2.body, .{});
    try std.testing.expectEqualStrings("expensive-main", body2.object.get("model").?.string);
}
