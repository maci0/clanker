//! HTTP transport for LLM chat completions, with retry/backoff and
//! provider-aware error detail extraction.

const std = @import("std");
const types = @import("types.zig");
const providers = @import("providers.zig");
const config = @import("../config.zig");
const log = @import("../util/log.zig");
const mock_server = @import("mock_server.zig");

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

/// Streaming variant of `chat`: sends the request with `stream: true` and
/// parses the SSE response incrementally. `on_delta` is invoked for every
/// content fragment as it arrives (used by the REPL/TUI to render tokens
/// live). Tool-call fragments are accumulated across chunks and assembled
/// into a normal ChatResponse, so callers can treat the result exactly like
/// a non-streaming reply.
pub fn chatStream(
    ctx: *Ctx,
    arena: std.mem.Allocator,
    params: providers.RequestParams,
    err_detail: *?[]const u8,
    on_delta: *const fn ([]const u8) void,
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

    var p = params;
    p.stream = true;
    const body = try providers.buildRequest(ctx.gpa, p);
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

    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var req = try client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .headers = headers,
        .extra_headers = extra[0..extra_len],
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(body);
    try body_writer.end();
    try req.connection.?.flush();

    var redirect_buffer: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    if (@intFromEnum(response.head.status) >= 400) {
        const reader = response.reader(&.{});
        var ebuf: [16384]u8 = undefined;
        var err_body: std.ArrayList(u8) = .empty;
        defer err_body.deinit(ctx.gpa);
        while (true) {
            const n = reader.readSliceShort(&ebuf) catch break;
            if (n == 0) break;
            err_body.appendSlice(ctx.gpa, ebuf[0..n]) catch break;
        }
        err_detail.* = try std.fmt.allocPrint(arena, "HTTP {d}: {s}", .{ @intFromEnum(response.head.status), err_body.items });
        return error.ApiError;
    }

    var chunk_arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer chunk_arena_state.deinit();
    const chunk_arena = chunk_arena_state.allocator();

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(ctx.gpa);
    var calls: std.ArrayList(types.ToolCall) = .empty;
    defer calls.deinit(ctx.gpa);
    var call_ids: std.ArrayList([]const u8) = .empty;
    defer call_ids.deinit(ctx.gpa);
    var call_names: std.ArrayList([]const u8) = .empty;
    defer call_names.deinit(ctx.gpa);
    var call_args: std.ArrayList(std.ArrayList(u8)) = .empty;
    defer {
        for (call_args.items) |*a| a.deinit(ctx.gpa);
        call_args.deinit(ctx.gpa);
    }

    const reader = response.reader(&.{});
    var buf: [8192]u8 = undefined;
    var sse: std.ArrayList(u8) = .empty;
    defer sse.deinit(ctx.gpa);
    var sse_done = false;
    var stream_usage: ?StreamUsage = null;
    while (!sse_done) {
        const n = reader.readSliceShort(&buf) catch |err| {
            log.log(.error_, "stream read failed: {s}", .{@errorName(err)});
            break;
        };
        if (n == 0) break;
        try sse.appendSlice(ctx.gpa, buf[0..n]);
        // Process complete frames (data: ... blank line). `frame` is a view
        // into sse.items, so handle it fully before the buffer is shifted.
        while (std.mem.indexOf(u8, sse.items, "\n\n")) |frame_end| {
            const frame = sse.items[0..frame_end];
            var frame_done = false;
            var it = std.mem.splitScalar(u8, frame, '\n');
            while (it.next()) |raw_line| {
                const line = std.mem.trimEnd(u8, raw_line, "\r");
                if (!std.mem.startsWith(u8, line, "data:")) continue;
                const payload = std.mem.trimStart(u8, line[5..], " ");
                if (std.mem.eql(u8, payload, "[DONE]")) {
                    frame_done = true;
                    break;
                }
                const chunk = std.json.parseFromSliceLeaky(StreamChunk, chunk_arena, payload, .{ .ignore_unknown_fields = true }) catch continue;
                // The final chunk may carry usage with an empty choices list;
                // capture it before the choices guard.
                if (chunk.usage) |u| {
                    if (u.total_tokens > 0) stream_usage = u;
                }
                if (chunk.choices.len == 0) continue;
                const choice = chunk.choices[0];
                if (choice.delta.content) |c| {
                    if (c.len > 0) {
                        try content.appendSlice(ctx.gpa, c);
                        on_delta(c);
                    }
                }
                if (choice.delta.tool_calls) |tcs| {
                    for (tcs) |frag| {
                        const idx = frag.index;
                        while (call_args.items.len <= idx) {
                            try call_args.append(ctx.gpa, .empty);
                            try call_ids.append(ctx.gpa, "");
                            try call_names.append(ctx.gpa, "");
                        }
                        if (frag.id) |fid| {
                            if (fid.len > 0 and call_ids.items[idx].len == 0) call_ids.items[idx] = try arena.dupe(u8, fid);
                        }
                        if (frag.function.name) |fname| {
                            if (fname.len > 0 and call_names.items[idx].len == 0) call_names.items[idx] = try arena.dupe(u8, fname);
                        }
                        if (frag.function.arguments) |fargs| {
                            if (fargs.len > 0) try call_args.items[idx].appendSlice(ctx.gpa, fargs);
                        }
                    }
                }
            }
            const rest = sse.items[frame_end + 2 ..];
            std.mem.copyForwards(u8, sse.items[0..rest.len], rest);
            sse.items.len = rest.len;
            if (frame_done) {
                sse_done = true;
                break;
            }
        }
    }

    var msg = types.Message{ .role = .assistant };
    if (content.items.len > 0) msg.content = try arena.dupe(u8, content.items);
    var usage_out: ?types.Usage = null;
    if (stream_usage) |su| {
        if (su.total_tokens > 0) {
            var hit = su.prompt_cache_hit_tokens;
            if (hit == 0) hit = su.cached_tokens;
            if (hit == 0) {
                if (su.prompt_tokens_details) |d| hit = d.cached_tokens;
            }
            var miss = su.prompt_cache_miss_tokens;
            if (miss == 0 and su.prompt_tokens > hit) miss = su.prompt_tokens - hit;
            usage_out = .{
                .prompt_tokens = su.prompt_tokens,
                .completion_tokens = su.completion_tokens,
                .total_tokens = su.total_tokens,
                .prompt_cache_hit_tokens = hit,
                .prompt_cache_miss_tokens = miss,
            };
        }
    }
    if (call_args.items.len > 0) {
        for (call_args.items, 0..) |*args_list, i| {
            if (args_list.items.len == 0) continue;
            try calls.append(arena, .{
                .id = call_ids.items[i],
                .name = call_names.items[i],
                .arguments = try arena.dupe(u8, args_list.items),
            });
        }
        msg.tool_calls = try calls.toOwnedSlice(arena);
    }
    return .{ .message = msg, .usage = usage_out };
}

const StreamUsage = struct {
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    total_tokens: u32 = 0,
    prompt_cache_hit_tokens: u32 = 0,
    prompt_cache_miss_tokens: u32 = 0,
    cached_tokens: u32 = 0,
    prompt_tokens_details: ?struct { cached_tokens: u32 = 0 } = null,
};

const StreamFunction = struct {
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
};

const StreamToolCallFragment = struct {
    index: usize = 0,
    id: ?[]const u8 = null,
    function: StreamFunction = .{},
};

const StreamDelta = struct {
    content: ?[]const u8 = null,
    tool_calls: ?[]const StreamToolCallFragment = null,
};

const StreamChoice = struct {
    delta: StreamDelta = .{},
};

const StreamChunk = struct {
    choices: []const StreamChoice = &.{},
    usage: ?StreamUsage = null,
};

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

test "streaming chat assembles SSE deltas" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const mock = try mock_server.MockServer.start(io, std.testing.allocator, .openai_stream);
    defer mock.stop();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("MOCK_API_KEY", "test-key");

    const provider = config.Provider{
        .name = "mock-stream",
        .base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{mock.port}),
        .api_key_env = "MOCK_API_KEY",
        .model = "mock",
        .max_tokens = 64,
    };
    defer std.testing.allocator.free(provider.base_url);

    var ctx = Ctx{ .io = io, .gpa = std.testing.allocator, .environ_map = &env };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const messages = [_]types.Message{
        .{ .role = .user, .content = "hi" },
    };

    const Sink = struct {
        var collected: std.ArrayList(u8) = .empty;
        fn cb(d: []const u8) void {
            _ = @This().collected.appendSlice(std.testing.allocator, d) catch {};
        }
    };
    var err_detail: ?[]const u8 = null;
    const resp = try chatStream(&ctx, arena, .{
        .provider = &provider,
        .messages = &messages,
    }, &err_detail, Sink.cb);

    defer {
        for (Sink.collected.items) |_| {}
        Sink.collected.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("Hello from the mock stream", resp.message.content orelse "");
    try std.testing.expectEqualStrings("Hello from the mock stream", Sink.collected.items);
}
