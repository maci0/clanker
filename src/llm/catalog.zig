//! Which models.dev providers clanker can actually run.
//!
//! models.dev names an API by the AI SDK `npm` package, not by a wire kind.
//! Support is that package plus a reachable base URL (catalog `api`, or a
//! default we know for the official host) and an auth strategy we already
//! implement. A new vendor on `@ai-sdk/openai-compatible` with an `api` URL
//! is supported without a new row. Gemini-native, Vertex, and Azure each have
//! a kind and a row below; Bedrock needs a new `ProviderKind` before it
//! belongs here.

const std = @import("std");
const config = @import("../config.zig");
const models_dev = @import("models_dev.zig");

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
    /// False when the URL is built from project/resource, not catalog `api`.
    needs_base: bool = true,
    /// When catalog `api` already ends in `/v1`, use this instead of the kind
    /// default (`/v1/messages` would double the prefix).
    path_if_api_ends_v1: ?[]const u8 = null,
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
    .{ "@ai-sdk/anthropic", NpmRow{ .kind = .anthropic, .auth = .api_key, .default_base = "https://api.anthropic.com", .path_if_api_ends_v1 = "/messages" } },
    .{ "@ai-sdk/google-vertex/anthropic", NpmRow{ .kind = .vertex_anthropic, .auth = .oauth_refresh, .needs_base = false } },
    .{ "@ai-sdk/google-vertex", NpmRow{ .kind = .vertex, .auth = .oauth_refresh, .needs_base = false } },
    .{ "@ai-sdk/google", NpmRow{ .kind = .gemini, .auth = .api_key, .default_base = "https://generativelanguage.googleapis.com/v1beta" } },
    .{ "@ai-sdk/azure", NpmRow{ .kind = .azure_openai, .auth = .api_key, .needs_base = false } },
});

/// Classify a models.dev provider from its npm package, catalog `api` URL,
/// and first env var. Null means we have no wire+auth for it.
pub fn classify(npm: []const u8, api: []const u8, env0: []const u8) ?Support {
    const row = npm_rows.get(npm) orelse return null;
    const base = if (api.len > 0) api else row.default_base;
    // Vertex builds the URL from project/location. Azure needs the
    // resource host from the operator (`https://<name>.openai.azure.com`).
    if (base.len == 0 and row.needs_base) return null;

    var path: ?[]const u8 = null;
    if (row.path_if_api_ends_v1) |override| {
        if (api.len > 0) {
            const trimmed = std.mem.trimEnd(u8, api, "/");
            if (std.mem.endsWith(u8, trimmed, "/v1")) path = override;
        }
    }

    return .{
        .kind = row.kind,
        .auth = row.auth,
        .base_url = base,
        .path = path,
        .api_key_env = env0,
    };
}

// Not `util/json.zig`'s strFieldOrNull: this drops empty strings too. An
// empty `npm`/`api` name is a broken models.dev row, and treating it as
// absent here is the fail-closed read the catalog wants.
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

/// Cap shared by `GET /api/catalog` and any other search surface. A broader
/// query is a paging problem the search box solves better than a giant body.
pub const max_search_hits: usize = 200;

/// One models.dev row the UI and `clanker providers catalog` both print.
pub const SearchHit = struct {
    provider: []const u8,
    kind: []const u8,
    auth: []const u8,
    base_url: []const u8 = "",
    api_key_env: []const u8 = "",
    path: ?[]const u8 = null,
    id: []const u8,
    display: []const u8 = "",
    context: ?i64 = null,
    output: ?i64 = null,
    cost_in: ?f64 = null,
    cost_out: ?f64 = null,
    reasoning: bool = false,
    tool_call: bool = false,
    temperature_ok: bool = false,
    capabilities: []const []const u8 = &.{},
};

pub fn queryMatches(query: []const u8, provider_id: []const u8, model_id: []const u8, family: []const u8) bool {
    if (query.len == 0) return false;
    return std.ascii.findIgnoreCase(provider_id, query) != null or
        std.ascii.findIgnoreCase(model_id, query) != null or
        std.ascii.findIgnoreCase(family, query) != null;
}

fn hitFrom(
    arena: std.mem.Allocator,
    provider_id: []const u8,
    model_id: []const u8,
    m: std.json.Value,
    support: Support,
) SearchHit {
    var hit = SearchHit{
        .provider = provider_id,
        .kind = @tagName(support.kind),
        .auth = @tagName(support.auth),
        .base_url = support.base_url,
        .api_key_env = support.api_key_env,
        .path = support.path,
        .id = model_id,
    };
    if (m != .object) return hit;
    if (fieldStr(m.object, "name")) |disp| hit.display = disp;
    if (m.object.get("limit")) |l| if (l == .object) {
        // Catalog data is network input; a limit past i64 keeps the field
        // unset rather than trapping the narrowing conversion.
        if (models_dev.jsonNum(l.object, "context")) |ctx| hit.context = config.intFromFloatChecked(ctx) orelse hit.context;
        if (models_dev.jsonNum(l.object, "output")) |o| hit.output = config.intFromFloatChecked(o) orelse hit.output;
    };
    if (m.object.get("cost")) |c| if (c == .object) {
        if (models_dev.jsonNum(c.object, "input")) |ci| hit.cost_in = ci;
        if (models_dev.jsonNum(c.object, "output")) |co| hit.cost_out = co;
    };
    if (m.object.get("reasoning")) |r| {
        if (r == .bool) hit.reasoning = r.bool;
    }
    if (m.object.get("tool_call")) |t| {
        if (t == .bool) hit.tool_call = t.bool;
    }
    if (m.object.get("temperature")) |t| {
        if (t == .bool) hit.temperature_ok = t.bool;
    }
    hit.capabilities = models_dev.capabilities(arena, m) catch &.{};
    return hit;
}

/// Supported catalog models whose id, provider, or family contains `query`.
pub fn collectHits(
    arena: std.mem.Allocator,
    catalog: std.json.Value,
    query: []const u8,
    max: usize,
) !struct { hits: []SearchHit, truncated: bool } {
    var list: std.ArrayList(SearchHit) = .empty;
    if (catalog != .object) return .{ .hits = &.{}, .truncated = false };
    var it = catalog.object.iterator();
    outer: while (it.next()) |kv| {
        const support = classifyEntry(kv.value_ptr.*) orelse continue;
        if (kv.value_ptr.* != .object) continue;
        const models_v = kv.value_ptr.object.get("models") orelse continue;
        if (models_v != .object) continue;
        var mit = models_v.object.iterator();
        while (mit.next()) |mkv| {
            const family = if (mkv.value_ptr.* == .object)
                fieldStr(mkv.value_ptr.object, "family") orelse ""
            else
                "";
            if (!queryMatches(query, kv.key_ptr.*, mkv.key_ptr.*, family)) continue;
            try list.append(arena, hitFrom(arena, kv.key_ptr.*, mkv.key_ptr.*, mkv.value_ptr.*, support));
            if (list.items.len >= max) break :outer;
        }
    }
    const truncated = list.items.len >= max;
    return .{ .hits = try list.toOwnedSlice(arena), .truncated = truncated };
}

fn writeHit(s: *std.json.Stringify, h: SearchHit) !void {
    try s.beginObject();
    try s.objectField("provider");
    try s.write(h.provider);
    try s.objectField("kind");
    try s.write(h.kind);
    try s.objectField("auth");
    try s.write(h.auth);
    if (h.base_url.len > 0) {
        try s.objectField("base_url");
        try s.write(h.base_url);
    }
    if (h.api_key_env.len > 0) {
        try s.objectField("api_key_env");
        try s.write(h.api_key_env);
    }
    if (h.path) |path| {
        try s.objectField("path");
        try s.write(path);
    }
    try s.objectField("id");
    try s.write(h.id);
    if (h.display.len > 0) {
        try s.objectField("display");
        try s.write(h.display);
    }
    if (h.context) |ctx| {
        try s.objectField("context");
        try s.print("{d}", .{ctx});
    }
    if (h.output) |o| {
        try s.objectField("output");
        try s.print("{d}", .{o});
    }
    if (h.cost_in) |ci| {
        try s.objectField("cost_in");
        try s.print("{d:.2}", .{ci});
    }
    if (h.cost_out) |co| {
        try s.objectField("cost_out");
        try s.print("{d:.2}", .{co});
    }
    if (h.reasoning) {
        try s.objectField("reasoning");
        try s.write(true);
    }
    if (h.tool_call) {
        try s.objectField("tool_call");
        try s.write(true);
    }
    if (h.temperature_ok) {
        try s.objectField("temperature_ok");
        try s.write(true);
    }
    if (h.capabilities.len > 0) {
        try s.objectField("capabilities");
        try s.beginArray();
        for (h.capabilities) |cap| try s.write(cap);
        try s.endArray();
    }
    try s.endObject();
}

/// `{ok, models, truncated}` — the `/api/catalog` body.
pub fn writeSearch(s: *std.json.Stringify, hits: []const SearchHit, truncated: bool) !void {
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("models");
    try s.beginArray();
    for (hits) |h| try writeHit(s, h);
    try s.endArray();
    try s.objectField("truncated");
    try s.write(truncated);
    try s.endObject();
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

test "Vertex AI is vertex + oauth_refresh without a base URL" {
    const s = classify("@ai-sdk/google-vertex", "", "").?;
    try std.testing.expectEqual(config.ProviderKind.vertex, s.kind);
    try std.testing.expectEqual(config.AuthStrategy.oauth_refresh, s.auth);
    try std.testing.expectEqualStrings("", s.base_url);
}

test "Bedrock stays unsupported" {
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

const search_sample =
    \\{
    \\  "moonshotai": {
    \\    "npm": "@ai-sdk/openai-compatible",
    \\    "api": "https://api.moonshot.ai/v1",
    \\    "env": ["MOONSHOT_API_KEY"],
    \\    "models": {
    \\      "kimi-k3": {
    \\        "name": "Kimi K3",
    \\        "family": "kimi-k3",
    \\        "reasoning": true,
    \\        "tool_call": true,
    \\        "limit": {"context": 1048576, "output": 131072},
    \\        "cost": {"input": 3, "output": 15}
    \\      }
    \\    }
    \\  },
    \\  "unknown-vendor": {
    \\    "npm": "@ai-sdk/amazon-bedrock",
    \\    "models": { "secret": { "family": "kimi-k3" } }
    \\  }
    \\}
;

test "queryMatches is case-insensitive on provider, model, and family" {
    try std.testing.expect(queryMatches("KIMI", "moonshotai", "kimi-k3", "kimi-k3"));
    try std.testing.expect(queryMatches("moon", "moonshotai", "kimi-k3", ""));
    try std.testing.expect(queryMatches("k3", "x", "other", "kimi-k3"));
    try std.testing.expect(!queryMatches("claude", "moonshotai", "kimi-k3", "kimi-k3"));
    try std.testing.expect(!queryMatches("", "moonshotai", "kimi-k3", "kimi-k3"));
}

test "collectHits skips unsupported vendors and fills the /api/catalog fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const catalog = try std.json.parseFromSliceLeaky(std.json.Value, arena, search_sample, .{});

    const found = try collectHits(arena, catalog, "kimi", max_search_hits);
    try std.testing.expectEqual(@as(usize, 1), found.hits.len);
    try std.testing.expect(!found.truncated);
    try std.testing.expectEqualStrings("moonshotai", found.hits[0].provider);
    try std.testing.expectEqualStrings("kimi-k3", found.hits[0].id);
    try std.testing.expectEqualStrings("openai_compat", found.hits[0].kind);
    try std.testing.expectEqualStrings("Kimi K3", found.hits[0].display);
    try std.testing.expectEqual(@as(i64, 1048576), found.hits[0].context.?);
    try std.testing.expect(found.hits[0].reasoning);
    try std.testing.expectEqual(@as(usize, 2), found.hits[0].capabilities.len);

    const none = try collectHits(arena, catalog, "claude", max_search_hits);
    try std.testing.expectEqual(@as(usize, 0), none.hits.len);

    const capped = try collectHits(arena, catalog, "kimi", 1);
    try std.testing.expect(capped.truncated);
}
