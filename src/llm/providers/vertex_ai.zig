//! `vertex`: Google Vertex AI.
//!
//! One provider, two wires, same GCP credential. A Claude model id uses the
//! existing Anthropic Vertex path (`:rawPredict`). Everything else uses
//! Gemini generateContent on `publishers/google`. `vertex_anthropic` remains
//! the Anthropic-only kind for configs that never want Gemini.

const std = @import("std");
const api = @import("api.zig");
const common = @import("common.zig");
const anthropic = @import("anthropic.zig");
const gemini = @import("gemini.zig");
const vertex = @import("vertex.zig");
const auth = @import("../auth.zig");
const config = @import("../../config.zig");
const vertex_token = @import("../vertex_token.zig");

pub const provider: api.Provider = .{
    .kind = .vertex,
    .auth = .{
        .default = .api_key,
        .mint = mint,
        .required = true,
        .quota_from_project = true,
        .needs_project_location = true,
        .file_credential = true,
    },
    .proxy = .{
        .family = .anthropic,
        .speaks = false,
        .chat_only = true,
        .vtable_chat = true,
        .vtable_messages = true,
        .always_vtable_url = true,
        .rewrite_vertex_body = true,
    },
    .buildRequest = buildRequest,
    .parseResponse = parseResponse,
    .parseErrorDetail = parseErrorDetail,
    .parseStreamEvent = parseStreamEvent,
    .authHeaders = vertex.authHeaders,
    .endpointUrl = endpointUrl,
};

fn mint(env: auth.Env, p: *const config.Provider) anyerror![]const u8 {
    return vertex_token.get(env.io, env.gpa, env.environ_map, p.service_account_file);
}

/// Claude (and any id that already names the Anthropic publisher) uses the
/// Anthropic Vertex wire. Gemini, Gemma, and anything else go through
/// generateContent.
pub fn isAnthropicModel(name: []const u8) bool {
    if (name.len >= 6 and std.ascii.startsWithIgnoreCase(name, "claude")) return true;
    var i: usize = 0;
    while (i + 9 <= name.len) : (i += 1) {
        if (std.ascii.startsWithIgnoreCase(name[i..], "anthropic")) return true;
    }
    return false;
}

fn looksLikeGemini(body: []const u8) bool {
    return std.mem.find(u8, body, "\"candidates\"") != null or
        std.mem.find(u8, body, "\"usageMetadata\"") != null;
}

fn buildRequest(gpa: std.mem.Allocator, params: api.RequestParams) api.BuildError![]u8 {
    if (isAnthropicModel(params.provider.wireModelName())) {
        return anthropic.buildBody(gpa, params, .{ .anthropic_version = vertex.body_version });
    }
    return gemini.provider.buildRequest(gpa, params);
}

fn parseResponse(arena: std.mem.Allocator, body: []const u8, err_detail: ?*?[]const u8) anyerror!@import("../types.zig").ChatResponse {
    if (looksLikeGemini(body)) return gemini.provider.parseResponse(arena, body, err_detail);
    return anthropic.provider.parseResponse(arena, body, err_detail);
}

fn parseErrorDetail(arena: std.mem.Allocator, body: []const u8) ?[]const u8 {
    if (gemini.provider.parseErrorDetail(arena, body)) |m| return m;
    return anthropic.provider.parseErrorDetail(arena, body);
}

fn parseStreamEvent(chunk_arena: std.mem.Allocator, payload: []const u8) api.StreamParseError!?api.StreamEvent {
    if (looksLikeGemini(payload)) return gemini.provider.parseStreamEvent(chunk_arena, payload);
    return anthropic.provider.parseStreamEvent(chunk_arena, payload);
}

fn endpointUrl(gpa: std.mem.Allocator, p: *const config.Provider, streaming: bool) anyerror![]u8 {
    if (p.project.len == 0 or p.location.len == 0) return error.VertexProjectMissing;
    var owned_base: ?[]u8 = null;
    defer if (owned_base) |b| gpa.free(b);
    const base = if (p.base_url.len > 0) std.mem.trimEnd(u8, p.base_url, "/") else blk: {
        owned_base = try std.fmt.allocPrint(gpa, "https://{s}-aiplatform.googleapis.com", .{p.location});
        break :blk owned_base.?;
    };

    const model = p.wireModelName();
    if (p.path) |path| {
        const joined = try common.joinBaseAndPath(gpa, p, path);
        defer gpa.free(joined);
        return gpa.dupe(u8, joined);
    }

    if (isAnthropicModel(model)) {
        const verb = if (streaming) "streamRawPredict" else "rawPredict";
        return std.fmt.allocPrint(
            gpa,
            "{s}/v1/projects/{s}/locations/{s}/publishers/anthropic/models/{s}:{s}",
            .{ base, p.project, p.location, model, verb },
        );
    }

    const verb = if (streaming) "streamGenerateContent?alt=sse" else "generateContent";
    if (std.mem.startsWith(u8, model, "publishers/")) {
        return std.fmt.allocPrint(
            gpa,
            "{s}/v1/projects/{s}/locations/{s}/{s}:{s}",
            .{ base, p.project, p.location, model, verb },
        );
    }
    return std.fmt.allocPrint(
        gpa,
        "{s}/v1/projects/{s}/locations/{s}/publishers/google/models/{s}:{s}",
        .{ base, p.project, p.location, model, verb },
    );
}

// ------------------------------------------------------------------- tests --

test "claude and anthropic ids select the Anthropic Vertex wire" {
    try std.testing.expect(isAnthropicModel("claude-opus-5@default"));
    try std.testing.expect(isAnthropicModel("claude-sonnet-5"));
    try std.testing.expect(isAnthropicModel("publishers/anthropic/models/claude-opus-4-6"));
    try std.testing.expect(!isAnthropicModel("gemini-2.5-flash"));
    try std.testing.expect(!isAnthropicModel("gemini-3.6-flash"));
    try std.testing.expect(!isAnthropicModel("gemma-4-31b-it"));
}

test "vertex AI Gemini URL uses generateContent on publishers/google" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var p = try config.Provider.single(arena, "vertex", "", .vertex, "gemini-2.5-flash", .{});
    p.project = "my-project";
    p.location = "us-east5";
    const url = try endpointUrl(arena, &p, false);
    try std.testing.expectEqualStrings(
        "https://us-east5-aiplatform.googleapis.com/v1/projects/my-project/locations/us-east5/publishers/google/models/gemini-2.5-flash:generateContent",
        url,
    );
    const stream = try endpointUrl(arena, &p, true);
    try std.testing.expectEqualStrings(
        "https://us-east5-aiplatform.googleapis.com/v1/projects/my-project/locations/us-east5/publishers/google/models/gemini-2.5-flash:streamGenerateContent?alt=sse",
        stream,
    );
}

test "vertex AI Claude URL uses the Anthropic rawPredict verb" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var p = try config.Provider.single(arena, "vertex", "", .vertex, "claude-opus-5@default", .{});
    p.project = "my-project";
    p.location = "us-east5";
    const url = try endpointUrl(arena, &p, true);
    try std.testing.expectEqualStrings(
        "https://us-east5-aiplatform.googleapis.com/v1/projects/my-project/locations/us-east5/publishers/anthropic/models/claude-opus-5@default:streamRawPredict",
        url,
    );
}

test "vertex AI Gemini body is generateContent, Claude body is Anthropic Vertex" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const messages = [_]@import("../types.zig").Message{
        .{ .role = .user, .content = "hi" },
    };

    var gem = try config.Provider.single(arena, "vertex", "", .vertex, "gemini-2.5-flash", .{ .max_tokens = 256 });
    gem.project = "p";
    gem.location = "us-east5";
    const gem_body = try buildRequest(arena, .{ .provider = &gem, .messages = &messages });
    try std.testing.expect(std.mem.find(u8, gem_body, "\"contents\"") != null);
    try std.testing.expect(std.mem.find(u8, gem_body, "anthropic_version") == null);

    var claude = try config.Provider.single(arena, "vertex", "", .vertex, "claude-opus-5@default", .{ .max_tokens = 256 });
    claude.project = "p";
    claude.location = "us-east5";
    const claude_body = try buildRequest(arena, .{ .provider = &claude, .messages = &messages });
    try std.testing.expect(std.mem.find(u8, claude_body, "\"anthropic_version\"") != null);
    try std.testing.expect(std.mem.find(u8, claude_body, "\"contents\"") == null);
}
