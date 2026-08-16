//! `azure_openai`: Azure OpenAI chat completions.
//!
//! The body is OpenAI's. The differences are transport: the deployment name
//! lives in the URL, the version is a query parameter, and the key rides
//! `api-key` rather than `Authorization: Bearer`.

const std = @import("std");
const api = @import("api.zig");
const openai = @import("openai.zig");
const common = @import("common.zig");
const auth = @import("../auth.zig");
const config = @import("../../config.zig");

pub const default_api_version = "2024-10-21";

pub const provider: api.Provider = .{
    .kind = .azure_openai,
    .auth = .{ .default = .api_key, .required = true },
    .proxy = .{ .family = .openai, .vtable_chat = true },
    .buildRequest = openai.provider.buildRequest,
    .parseResponse = openai.provider.parseResponse,
    .parseErrorDetail = openai.provider.parseErrorDetail,
    .parseStreamEvent = openai.provider.parseStreamEvent,
    .authHeaders = authHeaders,
    .endpointUrl = endpointUrl,
};

fn authHeaders(cred: auth.Credential, _: *std.http.Client.Request.Headers, extra: *api.ExtraHeaders) usize {
    const key = cred.value orelse return 0;
    extra[0] = .{ .name = "api-key", .value = key };
    return 1;
}

fn endpointUrl(gpa: std.mem.Allocator, p: *const config.Provider, _: bool) anyerror![]u8 {
    const version = if (p.api_version.len > 0) p.api_version else default_api_version;
    if (p.path) |_| {
        const joined = try common.joinBaseAndPath(gpa, p, "/chat/completions");
        defer gpa.free(joined);
        return std.fmt.allocPrint(gpa, "{s}?api-version={s}", .{ joined, version });
    }
    const base = std.mem.trimEnd(u8, p.base_url, "/");
    return std.fmt.allocPrint(
        gpa,
        "{s}/openai/deployments/{s}/chat/completions?api-version={s}",
        .{ base, p.wireModelName(), version },
    );
}

// ------------------------------------------------------------------- tests --

test "azure URL names the deployment and the api-version" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var p = try config.Provider.single(arena, "azure", "https://contoso.openai.azure.com", .azure_openai, "gpt-4o", .{});
    const url = try endpointUrl(arena, &p, false);
    try std.testing.expectEqualStrings(
        "https://contoso.openai.azure.com/openai/deployments/gpt-4o/chat/completions?api-version=2024-10-21",
        url,
    );

    p.api_version = "2024-12-01-preview";
    const preview = try endpointUrl(arena, &p, false);
    try std.testing.expectEqualStrings(
        "https://contoso.openai.azure.com/openai/deployments/gpt-4o/chat/completions?api-version=2024-12-01-preview",
        preview,
    );
}

test "azure path override still carries api-version" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var p = try config.Provider.single(arena, "azure", "https://contoso.openai.azure.com", .azure_openai, "gpt-4o", .{});
    p.path = "/openai/deployments/other/chat/completions";
    const url = try endpointUrl(arena, &p, false);
    try std.testing.expectEqualStrings(
        "https://contoso.openai.azure.com/openai/deployments/other/chat/completions?api-version=2024-10-21",
        url,
    );
}

test "azure puts the key on api-key, not Authorization" {
    var extra: api.ExtraHeaders = undefined;
    var headers: std.http.Client.Request.Headers = .{};
    const n = authHeaders(.{ .value = "secret-azure-key" }, &headers, &extra);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("api-key", extra[0].name);
    try std.testing.expectEqualStrings("secret-azure-key", extra[0].value);
    try std.testing.expect(headers.authorization == .default);
}
