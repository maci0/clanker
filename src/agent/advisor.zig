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
    const provider = cfg.provider(if (cfg.advisor.provider.len > 0) cfg.advisor.provider else null) catch |err| {
        log.log(.debug, "advisor skipped: {s}", .{@errorName(err)});
        return null;
    };
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
