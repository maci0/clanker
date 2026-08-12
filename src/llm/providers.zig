//! The provider registry: the one table that lists every provider.
//!
//! A provider is a `providers/api.zig` vtable implemented by exactly one file
//! under `providers/`, holding that provider's wire codec, auth strategy and
//! transport quirks together. Adding one is a new file plus a row in
//! `registry` below (and the matching `kind = "..."` tag on
//! `config.ProviderKind`, which is the config surface and stays there) — not
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

// ------------------------------------------------------------------- tests --

test "every configurable kind resolves to its own provider" {
    for (std.enums.values(config.ProviderKind)) |kind| {
        try std.testing.expectEqual(kind, forKind(kind).kind);
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
