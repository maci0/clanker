//! HTTP transport for LLM chat completions, with retry/backoff and
//! provider-aware error detail extraction.

const std = @import("std");
const types = @import("types.zig");
const providers = @import("providers.zig");
const config = @import("../config.zig");
const log = @import("../util/log.zig");

pub const Ctx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
};

/// Response body cap for chat completions (8 MiB).
const resp_cap = 8 << 20;
const max_attempts = 3;

const FetchOutcome = struct {
    status: std.http.Status,
    /// Response body (gpa-owned).
    body: []u8,
};

pub fn chat(
    ctx: *Ctx,
    arena: std.mem.Allocator,
    params: providers.RequestParams,
    err_detail: *?[]const u8,
) !types.ChatResponse {
    const provider = params.provider;

    const api_key: ?[]const u8 = if (provider.api_key_env) |env_name|
        ctx.environ_map.get(env_name)
    else
        null;
    if (provider.api_key_env != null and api_key == null) {
        log.log(.error_, "API key missing: set env var {s} (provider '{s}')", .{ provider.api_key_env.?, provider.name });
        return error.MissingApiKey;
    }

    const body = try providers.buildRequest(ctx.gpa, params);
    defer ctx.gpa.free(body);

    const url = try endpointUrl(ctx.gpa, provider);
    defer ctx.gpa.free(url);

    var client: std.http.Client = .{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();

    var bearer: ?[]const u8 = null;
    defer if (bearer) |b| ctx.gpa.free(b);
    if (api_key) |k| {
        bearer = try std.fmt.allocPrint(ctx.gpa, "Bearer {s}", .{k});
    }

    var attempt: u32 = 0;
    var outcome: FetchOutcome = undefined;
    while (true) {
        attempt += 1;
        outcome = try doFetch(ctx, &client, url, body, bearer, provider, arena, err_detail);
        if (isRetryable(outcome.status) and attempt < max_attempts) {
            const delay = attempt * std.time.ns_per_s;
            log.log(.warn, "HTTP {d} from '{s}', retrying in {d}s (attempt {d}/{d})", .{ @intFromEnum(outcome.status), provider.name, delay / std.time.ns_per_s, attempt, max_attempts });
            ctx.gpa.free(outcome.body);
            std.Io.sleep(ctx.io, .{ .nanoseconds = @intCast(delay) }, .awake) catch {};
            continue;
        }
        break;
    }
    defer ctx.gpa.free(outcome.body);

    if (@intFromEnum(outcome.status) >= 400) {
        if (err_detail.* == null) {
            err_detail.* = try arena.dupe(u8, outcome.body);
        }
        return error.ApiError;
    }

    return providers.parseResponse(arena, provider.kind, outcome.body);
}

fn doFetch(
    ctx: *Ctx,
    client: *std.http.Client,
    url: []const u8,
    body: []const u8,
    bearer: ?[]const u8,
    provider: *const config.Provider,
    arena: std.mem.Allocator,
    err_detail: *?[]const u8,
) !FetchOutcome {
    const resp_buf = try ctx.gpa.alloc(u8, resp_cap);
    defer ctx.gpa.free(resp_buf);
    var w: std.Io.Writer = .fixed(resp_buf);

    var headers: std.http.Client.Request.Headers = .{
        .content_type = .{ .override = "application/json" },
        .user_agent = .{ .override = "clanker/0.1.0" },
    };

    var extra: [2]std.http.Header = undefined;
    var extra_len: usize = 0;

    switch (provider.kind) {
        .openai_compat => {
            if (bearer) |b| headers.authorization = .{ .override = b };
        },
        .anthropic => {
            if (provider.api_key_env) |env_name| {
                if (ctx.environ_map.get(env_name)) |k| {
                    extra[extra_len] = .{ .name = "x-api-key", .value = k };
                    extra_len += 1;
                }
            }
            extra[extra_len] = .{ .name = "anthropic-version", .value = "2023-06-01" };
            extra_len += 1;
        },
    }

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .headers = headers,
        .extra_headers = extra[0..extra_len],
        .response_writer = &w,
    }) catch |err| {
        log.log(.error_, "request to '{s}' failed: {s}", .{ url, @errorName(err) });
        return err;
    };

    const response: []const u8 = resp_buf[0..w.end];

    if (@intFromEnum(result.status) >= 400) {
        if (providers.parseErrorDetail(arena, provider.kind, response)) |msg| {
            err_detail.* = try std.fmt.allocPrint(arena, "HTTP {d}: {s}", .{ @intFromEnum(result.status), msg });
        } else {
            err_detail.* = try std.fmt.allocPrint(arena, "HTTP {d}", .{@intFromEnum(result.status)});
        }
        log.log(.error_, "provider '{s}' returned {s}", .{ provider.name, err_detail.*.? });
    }

    return .{
        .status = result.status,
        .body = try ctx.gpa.dupe(u8, response),
    };
}

fn isRetryable(status: std.http.Status) bool {
    return switch (status) {
        .too_many_requests, .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout => true,
        else => false,
    };
}

fn endpointUrl(gpa: std.mem.Allocator, provider: *const config.Provider) ![]u8 {
    const path = provider.path orelse switch (provider.kind) {
        .openai_compat => "/chat/completions",
        .anthropic => "/v1/messages",
    };
    const base = std.mem.trimEnd(u8, provider.base_url, "/");
    var norm_path: ?[]u8 = null;
    defer if (norm_path) |p| gpa.free(p);
    if (path.len == 0 or path[0] != '/') {
        norm_path = try std.fmt.allocPrint(gpa, "/{s}", .{path});
    }
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ base, norm_path orelse path });
}

// ------------------------------------------------------------------- tests --

test "endpoint url building" {
    const mock = config.Provider{ .name = "m", .base_url = "https://api.deepseek.com/", .model = "x" };
    const url1 = try endpointUrl(std.testing.allocator, &mock);
    defer std.testing.allocator.free(url1);
    try std.testing.expectEqualStrings("https://api.deepseek.com/chat/completions", url1);

    const anthropic = config.Provider{ .name = "a", .kind = .anthropic, .base_url = "https://api.anthropic.com", .model = "x" };
    const url2 = try endpointUrl(std.testing.allocator, &anthropic);
    defer std.testing.allocator.free(url2);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", url2);
}
