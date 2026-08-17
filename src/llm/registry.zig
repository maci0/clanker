//! The provider registry: the one table that lists every provider.
//!
//! A provider is a `providers/api.zig` vtable implemented by exactly one file
//! under `providers/`, holding that provider's wire codec, auth strategy and
//! transport quirks together. Adding one is a new file plus a row in
//! `registry` below (and the matching `kind = "..."` tag on
//! `config.ProviderKind`, which is the config surface and stays there), not
//! an edit to seven switches spread across the client. See
//! [ADR 0004](../../docs/adrs/0004-providers-are-a-native-vtable-not-wasm.md).
//!
//! The shared HTTP/SSE/retry/token-counting core deliberately stays one
//! module (`client.zig`); nothing here forks it.

const std = @import("std");
const config = @import("../config.zig");

pub const api = @import("providers/api.zig");
pub const openai = @import("providers/openai.zig");
pub const anthropic = @import("providers/anthropic.zig");
pub const vertex = @import("providers/vertex.zig");
pub const vertex_ai = @import("providers/vertex_ai.zig");
pub const azure = @import("providers/azure.zig");
pub const gemini = @import("providers/gemini.zig");

/// Re-exported so callers keep saying `providers.RequestParams` rather than
/// reaching into the interface module.
pub const Provider = api.Provider;
pub const RequestParams = api.RequestParams;
pub const BuildError = api.BuildError;
pub const StreamEvent = api.StreamEvent;
pub const ToolCallFragment = api.ToolCallFragment;
pub const UsageUpdate = api.UsageUpdate;
pub const ExtraHeaders = api.ExtraHeaders;
pub const max_extra_headers = api.max_extra_headers;

/// Every provider, one row each.
pub const registry = [_]Provider{
    openai.provider,
    anthropic.provider,
    vertex.provider,
    vertex_ai.provider,
    azure.provider,
    gemini.provider,
};

/// The vtable for a configured provider. Resolved once per request by the
/// client, then called through for the whole exchange.
pub fn forKind(kind: config.ProviderKind) *const Provider {
    // Comptime-indexed by the enum, so a new tag with no registry row is a
    // compile error rather than a lookup that falls through at runtime.
    const table = comptime blk: {
        var t: [std.enums.values(config.ProviderKind).len]*const Provider = undefined;
        var seen = [_]bool{false} ** t.len;
        for (&registry) |*p| {
            const idx = @intFromEnum(p.kind);
            if (seen[idx]) @compileError("two providers registered for kind " ++ @tagName(p.kind));
            seen[idx] = true;
            t[idx] = p;
        }
        for (seen, 0..) |ok, i| {
            if (!ok) @compileError("no provider registered for kind " ++ @tagName(@as(config.ProviderKind, @enumFromInt(i))));
        }
        break :blk t;
    };
    return table[@intFromEnum(kind)];
}

/// Why a configured provider cannot possibly answer, decided from config and
/// environment alone with nothing sent. This is the offline availability gate
/// `clanker providers check` applies before it pings, extracted here so the
/// TUI `/model` picker can apply the same filter without a second copy or a
/// socket. Null means the provider is configured enough to attempt: a local
/// keyless endpoint like ollama on 127.0.0.1 counts, and so does a Vertex
/// entry whose URL is built from project/location at request time.
pub fn unconfiguredReason(
    arena: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    p: *const config.Provider,
) ?[]const u8 {
    if (p.base_url.len == 0 and !forKind(p.kind).auth.needs_project_location) return "base_url is empty";
    if (p.base_url.len > 0 and !std.mem.startsWith(u8, p.base_url, "http://") and !std.mem.startsWith(u8, p.base_url, "https://"))
        return std.fmt.allocPrint(arena, "base_url '{s}' has no http:// or https:// scheme", .{p.base_url}) catch "base_url has no scheme";
    if (p.api_key_env) |env_name| {
        if (environ_map.get(env_name) == null)
            return std.fmt.allocPrint(arena, "{s} not set", .{env_name}) catch "api key env not set";
    }
    return null;
}

// ------------------------------------------------------------------- tests --

test "every configurable kind resolves to its own provider" {
    for (std.enums.values(config.ProviderKind)) |kind| {
        try std.testing.expectEqual(kind, forKind(kind).kind);
    }
}

test "the vertex kinds own the project-location and file-credential flags" {
    // config.zig and doctor.zig read these off the vtable instead of
    // switching on `provider.kind`; the flags must stay attached to the
    // providers that set them, and absent elsewhere.
    for (std.enums.values(config.ProviderKind)) |kind| {
        const spec = forKind(kind).auth;
        const is_vertex = kind == .vertex or kind == .vertex_anthropic;
        try std.testing.expectEqual(is_vertex, spec.needs_project_location);
        try std.testing.expectEqual(is_vertex, spec.file_credential);
    }
}

test "the registry covers exactly the kinds config accepts" {
    // The two lists are the whole cost of adding a provider; a tag that
    // parses out of config but has no implementation would otherwise only
    // surface on the first request.
    for (std.enums.values(config.ProviderKind)) |kind| {
        try std.testing.expectEqual(kind, config.ProviderKind.fromStr(@tagName(kind)).?);
    }
    try std.testing.expectEqual(std.enums.values(config.ProviderKind).len, registry.len);
    try std.testing.expect(config.ProviderKind.fromStr("no_such_kind") == null);
}

test "unconfiguredReason gates on URL scheme and api_key_env, keyless local passes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("SET_KEY", "x");

    var local = config.Provider{ .name = "local", .base_url = "http://127.0.0.1:11434/v1", .default_model = "m" };
    try std.testing.expectEqual(@as(?[]const u8, null), unconfiguredReason(arena, &env, &local));

    var missing = config.Provider{ .name = "remote", .base_url = "https://x", .default_model = "m" };
    missing.api_key_env = "UNSET_KEY";
    try std.testing.expect(unconfiguredReason(arena, &env, &missing) != null);

    var set = missing;
    set.api_key_env = "SET_KEY";
    try std.testing.expectEqual(@as(?[]const u8, null), unconfiguredReason(arena, &env, &set));

    var no_scheme = config.Provider{ .name = "bad", .base_url = "api.example.com", .default_model = "m" };
    try std.testing.expect(unconfiguredReason(arena, &env, &no_scheme) != null);

    // Vertex builds its URL from project/location, so an empty base_url is
    // the usual config, not a missing setup.
    var vertex_provider = config.Provider{ .name = "v", .kind = .vertex, .base_url = "", .default_model = "m" };
    try std.testing.expectEqual(@as(?[]const u8, null), unconfiguredReason(arena, &env, &vertex_provider));
}
