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
pub const vertex_anthropic = @import("providers/vertex_anthropic.zig");
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
    vertex_anthropic.provider,
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

/// Why this provider cannot be called from this process right now, or null
/// when it can be attempted. This is the whole availability gate in one
/// place: the offline credential check (`unconfiguredReason`) plus, when an
/// `io` is supplied and the base_url is an explicit loopback endpoint, one
/// TCP connect (`loopbackAlive`). The TUI `/model` picker, the web UI's
/// `GET /api/providers` annotation and the `/api/run` refusal all call this
/// one function, so no surface can drift to a second notion of "usable".
/// Availability is per process by construction: the answer is this process's
/// environ plus which loopback ports answer on this machine.
pub fn unusableReason(
    arena: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    p: *const config.Provider,
    io: ?std.Io,
) ?[]const u8 {
    if (unconfiguredReason(arena, environ_map, p)) |reason| return reason;
    if (io) |the_io| {
        if (loopbackEndpoint(p.base_url)) |lb| {
            if (!loopbackAlive(the_io, lb.port))
                return std.fmt.allocPrint(arena, "nothing is listening on 127.0.0.1:{d}", .{lb.port}) catch "loopback endpoint is not listening";
        }
    }
    return null;
}

/// Host/port of an explicit loopback `base_url` (`127.0.0.1` or `localhost`
/// with a literal port), null for anything else. Only loopback endpoints are
/// probe candidates: a remote provider's reachability is not knowable without
/// network traffic, but a local server that refuses its own port is simply
/// not running, and `unconfiguredReason` deliberately passes keyless local
/// providers, so without the probe a stopped vllm/ollama still lists.
pub const LoopbackEndpoint = struct { port: u16 };

pub fn loopbackEndpoint(base_url: []const u8) ?LoopbackEndpoint {
    const rest = if (std.mem.find(u8, base_url, "://")) |i| base_url[i + 3 ..] else base_url;
    var host_end: usize = rest.len;
    for (rest, 0..) |c, i| {
        if (c == ':' or c == '/') {
            host_end = i;
            break;
        }
    }
    const host = rest[0..host_end];
    if (!std.mem.eql(u8, host, "127.0.0.1") and !std.mem.eql(u8, host, "localhost")) return null;
    if (host_end >= rest.len or rest[host_end] != ':') return null;
    const after = rest[host_end + 1 ..];
    const port_end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
    const port = std.fmt.parseInt(u16, after[0..port_end], 10) catch return null;
    return .{ .port = port };
}

/// One TCP connect to 127.0.0.1:port. Loopback answers immediately (accept
/// or refuse; no route to wait on), so this is the offline-adjacent probe the
/// `/model` picker may run at build time without pinging any provider
/// endpoint over a network. Errors other than an outright refusal keep the
/// provider listed: the probe exists to drop what is provably not running,
/// never to hide what it cannot judge.
pub fn loopbackAlive(io: std.Io, port: u16) bool {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return true;
    var stream = addr.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
        error.ConnectionRefused => return false,
        else => return true,
    };
    stream.close(io);
    return true;
}

// ------------------------------------------------------------------- tests --

test "loopbackEndpoint parses only explicit loopback host:port urls" {
    try std.testing.expectEqual(@as(u16, 11434), loopbackEndpoint("http://127.0.0.1:11434/v1").?.port);
    try std.testing.expectEqual(@as(u16, 8000), loopbackEndpoint("http://localhost:8000").?.port);
    try std.testing.expect(loopbackEndpoint("https://api.deepseek.com") == null);
    try std.testing.expect(loopbackEndpoint("http://127.0.0.1/v1") == null); // no literal port
    try std.testing.expect(loopbackEndpoint("http://192.168.1.4:8000/v1") == null);
    try std.testing.expect(loopbackEndpoint("") == null);
}

test "loopbackAlive distinguishes a listening loopback port from a refused one" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    const port = server.socket.address.getPort();
    try std.testing.expect(loopbackAlive(io, port));
    server.deinit(io);
    try std.testing.expect(!loopbackAlive(io, port));
}

test "unusableReason combines the credential gate with the loopback probe" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("SET_KEY", "x");

    // Credential half, no io: a missing key names the env var, a present one
    // passes, exactly as unconfiguredReason answers.
    var missing = config.Provider{ .name = "remote", .base_url = "https://x", .default_model = "m" };
    missing.api_key_env = "UNSET_KEY";
    try std.testing.expect(std.mem.find(u8, unusableReason(arena, &env, &missing, null).?, "UNSET_KEY") != null);
    var keyed = missing;
    keyed.api_key_env = "SET_KEY";
    try std.testing.expectEqual(@as(?[]const u8, null), unusableReason(arena, &env, &keyed, null));

    // Loopback half: a keyless local provider passes the credential gate in
    // every case, and the probe separates a listening port from a dead one.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    const port = server.socket.address.getPort();
    const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/v1", .{port});
    var local = config.Provider{ .name = "local", .base_url = url, .default_model = "m" };
    try std.testing.expectEqual(@as(?[]const u8, null), unusableReason(arena, &env, &local, io));
    server.deinit(io);
    const dead = unusableReason(arena, &env, &local, io).?;
    try std.testing.expect(std.mem.find(u8, dead, "not") != null and std.mem.find(u8, dead, "listening") != null);
    // Without an io the probe is skipped and the dead endpoint still passes.
    try std.testing.expectEqual(@as(?[]const u8, null), unusableReason(arena, &env, &local, null));
}

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
