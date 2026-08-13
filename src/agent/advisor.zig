//! Post-turn second-model critique. Fail-open: any error, timeout, or
//! unparseable reply is dropped and the main loop continues.

const std = @import("std");
const config = @import("../config.zig");
const types = @import("../llm/types.zig");
const client = @import("../llm/client.zig");
const log = @import("../util/log.zig");

pub const system_prompt =
    \\You are a silent advisor reviewing an AI agent's last turn.
    \\Your role: flag mistakes before they compound.
    \\Reply with JSON only: {"severity": "note"|"concern"|"blocker", "text": "..."}
    \\- note: informational, something the agent might want to consider
    \\- concern: a likely mistake or suboptimal approach worth correcting
    \\- blocker: a dangerous or destructive action the human should confirm before continuing
    \\Keep text under 150 words. Do not repeat what the agent said; say what it missed.
;

pub const Severity = enum { note, concern, blocker };

pub const Note = struct {
    severity: Severity,
    text: []const u8,
    tokens: u64 = 0,
};

pub fn parseNote(arena: std.mem.Allocator, raw: []const u8) ?Note {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n`");
    const start = std.mem.findScalar(u8, trimmed, '{') orelse return null;
    const end = std.mem.lastIndexOfScalar(u8, trimmed, '}') orelse return null;
    const slice = trimmed[start .. end + 1];
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, slice, .{}) catch return null;
    if (parsed != .object) return null;
    const sev_s = switch (parsed.object.get("severity") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    const sev = std.meta.stringToEnum(Severity, sev_s) orelse return null;
    const text = switch (parsed.object.get("text") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    if (text.len == 0) return null;
    return .{ .severity = sev, .text = text };
}

pub fn formatInjection(arena: std.mem.Allocator, note: Note) ![]const u8 {
    const tag = @tagName(note.severity);
    return std.fmt.allocPrint(arena, "[advisor: {s}]\n{s}\n[/advisor]\n", .{ tag, note.text });
}

/// Redact tool-call arguments for fs/exec tools. Names and a short result
/// preview stay; arguments become `<redacted>`.
pub fn summarizeTurn(
    arena: std.mem.Allocator,
    messages: []const types.Message,
    redact_names: []const []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (messages) |m| {
        try out.appendSlice(arena, @tagName(m.role));
        try out.appendSlice(arena, ": ");
        if (m.content) |c| {
            if (std.mem.startsWith(u8, c, "[advisor:")) continue;
            try out.appendSlice(arena, cap(c, 400));
        }
        if (m.tool_calls) |calls| {
            for (calls) |tc| {
                try out.appendSlice(arena, "\n  tool ");
                try out.appendSlice(arena, tc.name);
                if (shouldRedact(tc.name, redact_names)) {
                    try out.appendSlice(arena, " <redacted>");
                } else {
                    try out.appendSlice(arena, " ");
                    try out.appendSlice(arena, cap(tc.arguments, 200));
                }
            }
        }
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}

fn shouldRedact(name: []const u8, redact_names: []const []const u8) bool {
    for (redact_names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn cap(s: []const u8, n: usize) []const u8 {
    return if (s.len > n) s[0..n] else s;
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

    var abort = client.Abort{};
    var ctx = client.Ctx{
        .io = io,
        .gpa = gpa,
        .environ_map = environ_map,
        .cfg = cfg,
        .abort = &abort,
    };
    const msgs = [_]types.Message{
        .{ .role = .system, .content = system_prompt },
        .{ .role = .user, .content = summary },
    };
    var err_detail: ?[]const u8 = null;
    const resp = client.chat(&ctx, arena, .{
        .provider = provider,
        .messages = &msgs,
        .max_tokens = 256,
    }, &err_detail) catch |err| {
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

test "parseNote reads a fenced JSON object" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const note = parseNote(arena_state.allocator(),
        \\```json
        \\{"severity":"concern","text":"you skipped the tests"}
        \\```
    ).?;
    try std.testing.expectEqual(Severity.concern, note.severity);
    try std.testing.expectEqualStrings("you skipped the tests", note.text);
}

test "parseNote rejects missing fields and unknown severity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(parseNote(arena, "not json") == null);
    try std.testing.expect(parseNote(arena, "{\"severity\":\"info\",\"text\":\"x\"}") == null);
    try std.testing.expect(parseNote(arena, "{\"severity\":\"note\"}") == null);
}

test "summarizeTurn redacts named tools and strips prior advisor blocks" {
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

test "formatInjection wraps severity and text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try formatInjection(arena_state.allocator(), .{ .severity = .blocker, .text = "rm -rf" });
    try std.testing.expectEqualStrings("[advisor: blocker]\nrm -rf\n[/advisor]\n", out);
}

test "advisor is off by default" {
    try std.testing.expect(!(config.Advisor{}).enabled);
}
