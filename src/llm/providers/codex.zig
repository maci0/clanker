//! Native Codex provider plugin: OpenAI Responses wire plus ChatGPT account
//! selection for OAuth grants. API keys use the same bearer header.
const std = @import("std");
const api = @import("api.zig");
const auth = @import("../auth.zig");
const config = @import("../../config.zig");
const common = @import("common.zig");
const responses = @import("responses.zig");

pub const provider: api.Provider = .{
    .kind = .codex,
    .auth = .{ .default = .api_key },
    .buildRequest = buildRequest,
    .parseResponse = responses.parseResponse,
    .parseErrorDetail = responses.parseErrorDetail,
    .parseStreamEvent = responses.parseStreamEvent,
    .authHeaders = authHeaders,
    .endpointUrl = endpointUrl,
};

fn buildRequest(gpa: std.mem.Allocator, params: api.RequestParams) api.BuildError![]u8 {
    return responses.buildWithOptions(gpa, params, .{ .max_output_tokens = false, .sampling = false });
}

fn authHeaders(cred: auth.Credential, headers: *std.http.Client.Request.Headers, extra: *api.ExtraHeaders) usize {
    if (cred.bearer) |bearer| headers.authorization = .{ .override = bearer };
    if (cred.account_id.len == 0) return 0;
    extra[0] = .{ .name = "ChatGPT-Account-Id", .value = cred.account_id };
    extra[1] = .{ .name = "OpenAI-Beta", .value = "responses=v1" };
    extra[2] = .{ .name = "originator", .value = "clanker" };
    return 3;
}

fn endpointUrl(gpa: std.mem.Allocator, p: *const config.Provider, _: bool) anyerror![]u8 {
    return common.joinBaseAndPath(gpa, p, "/responses");
}

test "Codex OAuth carries its selected ChatGPT account" {
    var headers: std.http.Client.Request.Headers = .{};
    var extra: api.ExtraHeaders = undefined;
    const n = authHeaders(.{ .bearer = "Bearer token", .strategy = .oauth_refresh, .account_id = "acct_1" }, &headers, &extra);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("ChatGPT-Account-Id", extra[0].name);
    try std.testing.expectEqualStrings("acct_1", extra[0].value);
    try std.testing.expectEqualStrings("responses=v1", extra[1].value);
    try std.testing.expectEqualStrings("clanker", extra[2].value);
}

test "Codex subscription request omits unsupported output and sampling parameters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const configured = try config.Provider.single(arena, "codex", "https://api.openai.com/v1", .codex, "gpt-5.6-sol", .{ .max_tokens = 100, .temperature = 0.2 });
    const body = try buildRequest(arena, .{ .provider = &configured, .messages = &.{.{ .role = .user, .content = "hi" }}, .max_tokens = 100, .temperature = 0.2 });
    try std.testing.expect(std.mem.find(u8, body, "max_output_tokens") == null);
    try std.testing.expect(std.mem.find(u8, body, "temperature") == null);
}
