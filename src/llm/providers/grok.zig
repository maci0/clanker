//! Native xAI Grok provider plugin using the Responses API.
const std = @import("std");
const api = @import("api.zig");
const config = @import("../../config.zig");
const common = @import("common.zig");
const responses = @import("responses.zig");

pub const provider: api.Provider = .{
    .kind = .grok,
    .auth = .{ .default = .api_key },
    .buildRequest = responses.buildRequest,
    .parseResponse = responses.parseResponse,
    .parseErrorDetail = responses.parseErrorDetail,
    .parseStreamEvent = responses.parseStreamEvent,
    .authHeaders = common.bearerAuthHeaders,
    .endpointUrl = endpointUrl,
};
fn endpointUrl(gpa: std.mem.Allocator, p: *const config.Provider, _: bool) anyerror![]u8 {
    return common.joinBaseAndPath(gpa, p, "/responses");
}

test "grok ships the configured per-model temperature and clamps the budget" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try config.Provider.single(arena, "grok", "https://api.x.ai/v1", .grok, "grok-4.6", .{ .temperature = 0.2, .top_p = 0.9, .context_window = 16384, .max_tokens = 16384 });

    // The agent loop sets neither params.temperature nor params.top_p; reading
    // only those discarded the configured value on every turn.
    const body = try provider.buildRequest(arena, .{ .provider = &p, .messages = &.{.{ .role = .user, .content = "hi" }} });
    try std.testing.expect(std.mem.find(u8, body, "\"temperature\":0.2") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"top_p\":0.9") != null);
    // clampedMaxTokens: half the 16384 window, not the requested 16384.
    try std.testing.expect(std.mem.find(u8, body, "\"max_output_tokens\":8192") != null);
}

test "grok falls back to the PRD 0024 use-case table" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const messages = [_]@import("../types.zig").Message{.{ .role = .user, .content = "hi" }};

    // Nothing configured: the chat row's 0.7.
    const plain = try config.Provider.single(arena, "grok", "https://api.x.ai/v1", .grok, "grok-4.6", .{});
    const chat = try provider.buildRequest(arena, .{ .provider = &plain, .messages = &messages });
    try std.testing.expect(std.mem.find(u8, chat, "\"temperature\":0.7") != null);

    // A thinking model gets the effort row instead, nested the way the
    // Responses API takes it rather than as the flat OpenAI field.
    var thinking = try config.Provider.single(arena, "grok", "https://api.x.ai/v1", .grok, "grok-4.6", .{});
    var it = thinking.models.iterator();
    const caps = try arena.alloc([]const u8, 1);
    caps[0] = "thinking";
    it.next().?.value_ptr.capabilities = caps;
    const reasoned = try provider.buildRequest(arena, .{ .provider = &thinking, .messages = &messages });
    try std.testing.expect(std.mem.find(u8, reasoned, "\"reasoning\":{\"effort\":\"medium\"}") != null);
    try std.testing.expect(std.mem.find(u8, reasoned, "\"reasoning_effort\"") == null);
    try std.testing.expect(std.mem.find(u8, reasoned, "temperature") == null);
}
