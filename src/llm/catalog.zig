//! Which models.dev providers clanker can actually run.
//!
//! models.dev names an API by the AI SDK `npm` package, not by a wire kind.
//! Support is that package plus a reachable base URL (catalog `api`, or a
//! default we know for the official host) and an auth strategy we already
//! implement. A new vendor on `@ai-sdk/openai-compatible` with an `api` URL
//! is supported without a new row. Gemini-native, Bedrock, Azure, and
//! similar need a new `ProviderKind` before they belong here.

const std = @import("std");
const config = @import("../config.zig");

pub const Support = struct {
    kind: config.ProviderKind,
    auth: config.AuthStrategy,
    /// Suggested `[providers.*] base_url`. Empty for Vertex (URL is built
    /// from project/location).
    base_url: []const u8 = "",
    /// Suggested `path` override. Null means the kind default
    /// (`/chat/completions` or `/v1/messages`).
    path: ?[]const u8 = null,
    /// First catalog `env` entry, if any. Empty means keyless.
    api_key_env: []const u8 = "",
};

const NpmRow = struct {
    kind: config.ProviderKind,
    auth: config.AuthStrategy,
    default_base: []const u8 = "",
};

/// Closed table: npm package → wire kind + default auth + implied host.
/// `@ai-sdk/openai-compatible` has no default host; the catalog `api` is
/// required. Official SDKs that omit `api` get the vendor's public base.
const npm_rows = std.StaticStringMap(NpmRow).initComptime(.{
    .{ "@ai-sdk/openai-compatible", NpmRow{ .kind = .openai_compat, .auth = .api_key } },
    .{ "@ai-sdk/openai", NpmRow{ .kind = .openai_compat, .auth = .api_key, .default_base = "https://api.openai.com/v1" } },
    .{ "@ai-sdk/xai", NpmRow{ .kind = .openai_compat, .auth = .api_key, .default_base = "https://api.x.ai/v1" } },
    .{ "@ai-sdk/groq", NpmRow{ .kind = .openai_compat, .auth = .api_key, .default_base = "https://api.groq.com/openai/v1" } },
    .{ "@ai-sdk/togetherai", NpmRow{ .kind = .openai_compat, .auth = .api_key, .default_base = "https://api.together.xyz/v1" } },
    .{ "@ai-sdk/cerebras", NpmRow{ .kind = .openai_compat, .auth = .api_key, .default_base = "https://api.cerebras.ai/v1" } },
    .{ "@ai-sdk/deepinfra", NpmRow{ .kind = .openai_compat, .auth = .api_key, .default_base = "https://api.deepinfra.com/v1/openai" } },
    .{ "@ai-sdk/mistral", NpmRow{ .kind = .openai_compat, .auth = .api_key, .default_base = "https://api.mistral.ai/v1" } },
    .{ "@openrouter/ai-sdk-provider", NpmRow{ .kind = .openai_compat, .auth = .api_key, .default_base = "https://openrouter.ai/api/v1" } },
    .{ "@ai-sdk/anthropic", NpmRow{ .kind = .anthropic, .auth = .api_key, .default_base = "https://api.anthropic.com" } },
    .{ "@ai-sdk/google-vertex/anthropic", NpmRow{ .kind = .vertex_anthropic, .auth = .oauth_refresh } },
    .{ "@ai-sdk/google", NpmRow{ .kind = .gemini, .auth = .api_key, .default_base = "https://generativelanguage.googleapis.com/v1beta" } },
    .{ "@ai-sdk/azure", NpmRow{ .kind = .azure_openai, .auth = .api_key } },
});

/// Classify a models.dev provider from its npm package, catalog `api` URL,
/// and first env var. Null means we have no wire+auth for it.
pub fn classify(npm: []const u8, api: []const u8, env0: []const u8) ?Support {
    const row = npm_rows.get(npm) orelse return null;
    const base = if (api.len > 0) api else row.default_base;
    // Vertex builds the URL from project/location. Azure needs the
    // resource host from the operator (`https://<name>.openai.azure.com`).
    if (base.len == 0 and row.kind != .vertex_anthropic and row.kind != .azure_openai) return null;

    var path: ?[]const u8 = null;
    if (row.kind == .anthropic and api.len > 0) {
        // Those entries already end in /v1. The anthropic kind default is
        // /v1/messages, which would double the prefix.
        const trimmed = std.mem.trimEnd(u8, api, "/");
        if (std.mem.endsWith(u8, trimmed, "/v1")) path = "/messages";
    }

    return .{
        .kind = row.kind,
        .auth = row.auth,
        .base_url = base,
        .path = path,
        .api_key_env = env0,
    };
}

fn fieldStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

fn firstEnv(obj: std.json.ObjectMap) []const u8 {
    const envs = obj.get("env") orelse return "";
    if (envs != .array) return "";
    for (envs.array.items) |item| {
        if (item == .string and item.string.len > 0) return item.string;
    }
    return "";
}

/// Classify one models.dev provider object (`npm`, `api`, `env`).
pub fn classifyEntry(entry: std.json.Value) ?Support {
    if (entry != .object) return null;
    const npm = fieldStr(entry.object, "npm") orelse return null;
    const api = fieldStr(entry.object, "api") orelse "";
    return classify(npm, api, firstEnv(entry.object));
}

test "openai-compatible with an api URL is openai_compat + api_key" {
    const s = classify("@ai-sdk/openai-compatible", "https://api.deepseek.com", "DEEPSEEK_API_KEY").?;
    try std.testing.expectEqual(config.ProviderKind.openai_compat, s.kind);
    try std.testing.expectEqual(config.AuthStrategy.api_key, s.auth);
    try std.testing.expectEqualStrings("https://api.deepseek.com", s.base_url);
    try std.testing.expect(s.path == null);
    try std.testing.expectEqualStrings("DEEPSEEK_API_KEY", s.api_key_env);
}

test "openai-compatible without an api URL is unsupported" {
    try std.testing.expect(classify("@ai-sdk/openai-compatible", "", "X") == null);
}

test "official OpenAI and xAI fill in the public base URL" {
    const oai = classify("@ai-sdk/openai", "", "OPENAI_API_KEY").?;
    try std.testing.expectEqualStrings("https://api.openai.com/v1", oai.base_url);
    const xai = classify("@ai-sdk/xai", "", "XAI_API_KEY").?;
    try std.testing.expectEqualStrings("https://api.x.ai/v1", xai.base_url);
}

test "Anthropic Messages API is anthropic + api_key; /v1 hosts get path /messages" {
    const official = classify("@ai-sdk/anthropic", "", "ANTHROPIC_API_KEY").?;
    try std.testing.expectEqual(config.ProviderKind.anthropic, official.kind);
    try std.testing.expectEqualStrings("https://api.anthropic.com", official.base_url);
    try std.testing.expect(official.path == null);

    const mm = classify("@ai-sdk/anthropic", "https://api.minimax.io/anthropic/v1", "MINIMAX_API_KEY").?;
    try std.testing.expectEqualStrings("/messages", mm.path.?);
}

test "Vertex Anthropic is vertex_anthropic + oauth_refresh without a base URL" {
    const s = classify("@ai-sdk/google-vertex/anthropic", "", "").?;
    try std.testing.expectEqual(config.ProviderKind.vertex_anthropic, s.kind);
    try std.testing.expectEqual(config.AuthStrategy.oauth_refresh, s.auth);
    try std.testing.expectEqualStrings("", s.base_url);
}

test "Gemini AI Studio is gemini + api_key with the public base URL" {
    const s = classify("@ai-sdk/google", "", "GOOGLE_API_KEY").?;
    try std.testing.expectEqual(config.ProviderKind.gemini, s.kind);
    try std.testing.expectEqual(config.AuthStrategy.api_key, s.auth);
    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com/v1beta", s.base_url);
}

test "Azure OpenAI is azure_openai + api_key without a default host" {
    const s = classify("@ai-sdk/azure", "", "AZURE_API_KEY").?;
    try std.testing.expectEqual(config.ProviderKind.azure_openai, s.kind);
    try std.testing.expectEqualStrings("", s.base_url);
    try std.testing.expectEqualStrings("AZURE_API_KEY", s.api_key_env);
}

test "Vertex Gemini and Bedrock stay unsupported" {
    try std.testing.expect(classify("@ai-sdk/google-vertex", "", "") == null);
    try std.testing.expect(classify("@ai-sdk/amazon-bedrock", "", "") == null);
}

test "classifyEntry reads npm, api, and the first env var" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entry = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"npm":"@ai-sdk/openai-compatible","api":"https://api.moonshot.ai/v1","env":["MOONSHOT_API_KEY"]}
    , .{});
    const s = classifyEntry(entry).?;
    try std.testing.expectEqual(config.ProviderKind.openai_compat, s.kind);
    try std.testing.expectEqualStrings("https://api.moonshot.ai/v1", s.base_url);
    try std.testing.expectEqualStrings("MOONSHOT_API_KEY", s.api_key_env);
}
