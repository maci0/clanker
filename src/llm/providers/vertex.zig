//! `vertex_anthropic`: Anthropic models served through Google Vertex AI.
//!
//! Same wire codec as `anthropic.zig` (re-exported below, not copied) with
//! three deployment differences, which is exactly the split the vtable is for:
//!
//!   - the model is addressed in the URL, so the body carries
//!     `anthropic_version` instead of `model`;
//!   - streaming is a different verb (`:streamRawPredict`), not a body flag
//!     alone;
//!   - the credential is a GCP OAuth access token minted from a service
//!     account or gcloud ADC (`authorized_user`) and renewed in-process,
//!     `oauth_refresh` in ADR 0005's terms.

const std = @import("std");
const api = @import("api.zig");
const anthropic = @import("anthropic.zig");
const auth = @import("../auth.zig");
const config = @import("../../config.zig");
const vertex_token = @import("../vertex_token.zig");

/// Vertex pins the message-format version in the body rather than a header.
pub const body_version = "vertex-2023-10-16";

pub const provider: api.Provider = .{
    .kind = .vertex_anthropic,
    .auth = .{
        // An access token in `api_key_env` still wins (handy for a
        // short-lived token pasted in by hand); otherwise it is minted from
        // the service account or gcloud ADC and cached until it nears expiry.
        .default = .api_key,
        .mint = mint,
        .required = true,
        .quota_from_project = true,
    },
    .proxy = .{
        .family = .anthropic,
        .chat_only = true,
        .vtable_messages = true,
        .always_vtable_url = true,
        .rewrite_vertex_body = true,
        .vertex_body = true,
    },
    .buildRequest = buildRequest,
    // The codec is Anthropic's, unchanged.
    .parseResponse = anthropic.provider.parseResponse,
    .parseErrorDetail = anthropic.provider.parseErrorDetail,
    .parseStreamEvent = anthropic.provider.parseStreamEvent,
    // A GCP access token is a bearer token, and the anthropic version lives in
    // the body, so none of Anthropic's header juggling applies.
    .authHeaders = authHeaders,
    .endpointUrl = endpointUrl,
};

fn buildRequest(gpa: std.mem.Allocator, params: api.RequestParams) api.BuildError![]u8 {
    return anthropic.buildBody(gpa, params, .{ .anthropic_version = body_version });
}

fn mint(env: auth.Env, p: *const config.Provider) anyerror![]const u8 {
    return vertex_token.get(env.io, env.gpa, env.environ_map, p.service_account_file);
}

/// Bearer plus `x-goog-user-project`. User ADC (and some org policies) bill
/// against that project; `provider.project` is already required for the URL.
pub fn authHeaders(
    cred: auth.Credential,
    headers: *std.http.Client.Request.Headers,
    extra: *api.ExtraHeaders,
) usize {
    if (cred.bearer) |b| headers.authorization = .{ .override = b };
    if (cred.quota_project.len == 0) return 0;
    extra[0] = .{ .name = "x-goog-user-project", .value = cred.quota_project };
    return 1;
}

/// Vertex addresses the model in the path, so the URL cannot be a constant:
/// `.../locations/<region>/publishers/anthropic/models/<model>:rawPredict`.
fn endpointUrl(gpa: std.mem.Allocator, p: *const config.Provider, streaming: bool) anyerror![]u8 {
    if (p.project.len == 0 or p.location.len == 0) return error.VertexProjectMissing;
    var owned_base: ?[]u8 = null;
    defer if (owned_base) |b| gpa.free(b);
    const base = if (p.base_url.len > 0) std.mem.trimEnd(u8, p.base_url, "/") else blk: {
        owned_base = try std.fmt.allocPrint(gpa, "https://{s}-aiplatform.googleapis.com", .{p.location});
        break :blk owned_base.?;
    };
    // Streaming is a different verb on Vertex, not a body flag.
    const verb = if (streaming) "streamRawPredict" else "rawPredict";
    return std.fmt.allocPrint(
        gpa,
        "{s}/v1/projects/{s}/locations/{s}/publishers/anthropic/models/{s}:{s}",
        .{ base, p.project, p.location, p.wireModelName(), verb },
    );
}

// ------------------------------------------------------------------- tests --

const types = @import("../types.zig");
const json = std.json;

test "vertex request body replays tool calls without leaking the parsed input" {
    // Regression: the tool-call arguments were re-parsed with the caller's
    // general-purpose allocator using the *Leaky variant, so every replayed
    // tool call leaked its parsed JSON. The body is built with the testing
    // allocator here, which fails the test if that comes back.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var p = try config.Provider.single(arena, "vertex-opus", "", .vertex_anthropic, "claude-opus-4-6", .{
        .context_window = 1_048_576,
        .max_tokens = 32768,
    });
    p.project = "my-project";
    p.location = "us-east5";

    const calls = [_]types.ToolCall{
        .{ .id = "toolu_1", .name = "history", .arguments = "{\"n\":3}" },
        .{ .id = "toolu_2", .name = "roadmap", .arguments = "{}" },
    };
    const messages = [_]types.Message{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "what next?" },
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "toolu_1", .content = "recent history" },
        .{ .role = .tool, .tool_call_id = "toolu_2", .content = "(no planned items)" },
    };

    const body = try buildRequest(std.testing.allocator, .{ .provider = &p, .messages = &messages });
    defer std.testing.allocator.free(body);

    const parsed = try json.parseFromSliceLeaky(json.Value, arena, body, .{});
    const obj = parsed.object;
    // Vertex takes the model in the URL and the version in the body.
    try std.testing.expectEqualStrings("vertex-2023-10-16", obj.get("anthropic_version").?.string);
    try std.testing.expect(obj.get("model") == null);
    // max_tokens is clamped to half the context window, so the configured
    // 32768 passes through untouched on a 1M-token model.
    try std.testing.expectEqual(@as(i64, 32768), obj.get("max_tokens").?.integer);

    const msgs = obj.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), msgs.len);
    const blocks = msgs[1].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("tool_use", blocks[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("history", blocks[0].object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 3), blocks[0].object.get("input").?.object.get("n").?.integer);
    // A no-argument call must serialize as an empty object, not a bare string.
    try std.testing.expectEqual(@as(usize, 0), blocks[1].object.get("input").?.object.count());
}

test "vertex endpoint url carries project, location, model and verb" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var p = try config.Provider.single(arena, "vertex-opus", "", .vertex_anthropic, "claude-opus-4-6", .{});
    p.project = "my-project";
    p.location = "us-east5";

    const streaming = try endpointUrl(std.testing.allocator, &p, true);
    defer std.testing.allocator.free(streaming);
    try std.testing.expectEqualStrings(
        "https://us-east5-aiplatform.googleapis.com/v1/projects/my-project/locations/us-east5/publishers/anthropic/models/claude-opus-4-6:streamRawPredict",
        streaming,
    );

    const blocking = try endpointUrl(std.testing.allocator, &p, false);
    defer std.testing.allocator.free(blocking);
    try std.testing.expect(std.mem.endsWith(u8, blocking, ":rawPredict"));

    // A provider missing the GCP coordinates must fail loudly, not build a
    // URL with empty path segments.
    var bare = try config.Provider.single(arena, "vertex-bad", "", .vertex_anthropic, "claude-opus-4-6", .{});
    try std.testing.expectError(error.VertexProjectMissing, endpointUrl(std.testing.allocator, &bare, true));
}

test "vertex mints when no token is pasted in" {
    var p = config.Provider{ .name = "v", .base_url = "", .default_model = "m" };
    p.kind = .vertex_anthropic;

    try std.testing.expectEqual(auth.Strategy.oauth_refresh, auth.selectStrategy(provider.auth, &p, null));
    try std.testing.expectEqual(auth.Strategy.api_key, auth.selectStrategy(provider.auth, &p, "ya29.pasted"));

    // No file, no GAC, no HOME: mint is selected but cannot resolve a
    // credentials path, so resolve fails rather than send unauthenticated.
    var no_sa = config.Provider{ .name = "v2", .base_url = "", .default_model = "m" };
    no_sa.kind = .vertex_anthropic;
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    try std.testing.expectError(error.VertexTokenFailed, auth.resolve(
        .{ .io = threaded.io(), .gpa = std.testing.allocator, .environ_map = &env_map },
        provider.auth,
        &no_sa,
    ));
}

test "vertex auth headers carry the quota project" {
    var headers: std.http.Client.Request.Headers = .{};
    var extra: api.ExtraHeaders = undefined;
    const n = authHeaders(.{
        .value = "tok",
        .bearer = "Bearer tok",
        .quota_project = "my-gcp-project",
    }, &headers, &extra);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("x-goog-user-project", extra[0].name);
    try std.testing.expectEqualStrings("my-gcp-project", extra[0].value);
    try std.testing.expectEqualStrings("Bearer tok", headers.authorization.override);
}
