//! OpenAI / Anthropic compatibility proxy mounted on `clanker serve`.
//!
//! 1:1 forward: inbound method, query, and body bytes go upstream unchanged
//! (except a documented `model` splice). Auth comes from the provider vtable.
//! Discovery is a projection of `[models.*]`. See docs/prds/0026-llm-proxy.md.

const std = @import("std");
const json = std.json;
const config = @import("../config.zig");
const providers = @import("../llm/providers.zig");
const auth = @import("../llm/auth.zig");
const client = @import("../llm/client.zig");
const types = @import("../llm/types.zig");
const token_stats = @import("../stats/tokens.zig");
const log = @import("../util/log.zig");
const rawhttp = @import("../util/rawhttp.zig");
const anthropic = @import("../llm/providers/anthropic.zig");
const build_options = @import("build_options");

pub const Surface = enum { webui, proxy, both };

pub const Family = enum { openai, anthropic };

pub const AuthResult = enum { missing, mismatch, ok };

pub const default_first_byte_s: u32 = 300;
pub const default_idle_s: u32 = 60;
pub const webui_reserved_slots: u32 = 8;

const user_agent = "clanker/" ++ build_options.version;
const extra_slots = 8;

pub fn isProxyPath(path: []const u8, surface: Surface) bool {
    return switch (surface) {
        .webui => false,
        .both => std.mem.eql(u8, path, "/proxy/v1") or std.mem.startsWith(u8, path, "/proxy/v1/"),
        .proxy => std.mem.eql(u8, path, "/v1") or std.mem.startsWith(u8, path, "/v1/"),
    };
}

/// On `.both`, strip the `/proxy` prefix so handle sees `/v1/…`.
pub fn stripProxyPrefix(path: []const u8, surface: Surface) []const u8 {
    if (surface == .both and std.mem.startsWith(u8, path, "/proxy")) return path["/proxy".len..];
    return path;
}

pub fn authorize(headers_raw: []const u8, expected: []const u8) AuthResult {
    const presented = presentedToken(headers_raw) orelse return .missing;
    if (!std.mem.eql(u8, presented, expected)) return .mismatch;
    return .ok;
}

pub const Ctx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: *const config.Config,
    environ_map: *std.process.Environ.Map,
    method: []const u8,
    /// Path after the `/proxy` strip: always `/v1/…`.
    path: []const u8,
    query: []const u8,
    headers_raw: []const u8,
    body: []const u8,
    stream: std.Io.net.Stream,
};

/// 401 from `handleConnection` before CSRF, so an SDK error parser works.
pub fn writeAuthError(stream: std.Io.net.Stream, path: []const u8, headers_raw: []const u8) u16 {
    return writeEnvelope(.{
        .io = undefined,
        .gpa = undefined,
        .cfg = undefined,
        .environ_map = undefined,
        .method = "GET",
        .path = path,
        .query = "",
        .headers_raw = headers_raw,
        .body = "",
        .stream = stream,
    }, 401, "invalid_api_key", "Invalid API key");
}

/// Dispatch one proxy request. Returns the inbound HTTP status written.
pub fn handle(ctx: Ctx) u16 {
    if (!std.mem.startsWith(u8, ctx.path, "/v1")) {
        return writeEnvelope(ctx, 404, "unknown_endpoint", "Not a /v1 path");
    }
    if (isWebsocketUpgrade(ctx.headers_raw)) {
        return writeEnvelope(ctx, 501, "unknown_endpoint", "Realtime WebSocket is not proxied");
    }

    const family = familyOf(ctx.path, ctx.headers_raw);
    const is_get = std.mem.eql(u8, ctx.method, "GET") or std.mem.eql(u8, ctx.method, "HEAD");
    if (is_get and isModelsList(ctx.path)) {
        return writeModelsList(ctx, family);
    }
    if (is_get) {
        if (modelsId(ctx.path)) |id| return writeModelsGet(ctx, family, id);
    }
    if (isModelsList(ctx.path) or modelsId(ctx.path) != null) {
        return writeAllow(ctx, 405, "GET");
    }
    return forward(ctx, family);
}

pub fn familyOf(v1_path: []const u8, headers_raw: []const u8) Family {
    const rest = v1Rest(v1_path);
    if (anthropicOnly(rest)) return .anthropic;
    if (sharedPath(rest) and headerValue(headers_raw, "anthropic-version") != null) return .anthropic;
    return .openai;
}

pub fn joinUpstream(gpa: std.mem.Allocator, base_url: []const u8, inbound_v1_path: []const u8, query: []const u8) ![]u8 {
    const base = std.mem.trimEnd(u8, base_url, "/");
    const rest = if (std.mem.endsWith(u8, base, "/v1") and std.mem.startsWith(u8, inbound_v1_path, "/v1"))
        inbound_v1_path["/v1".len..]
    else
        inbound_v1_path;
    if (query.len == 0) return std.fmt.allocPrint(gpa, "{s}{s}", .{ base, rest });
    return std.fmt.allocPrint(gpa, "{s}{s}?{s}", .{ base, rest, query });
}

const Resolved = struct {
    provider: config.Provider,
    wire_id: []const u8,
    splice: bool,
};

const LookupError = error{ ModelNotFound, ProtocolMismatch, MissingModel, AmbiguousProvider };

pub fn lookup(cfg: *const config.Config, family: Family, model: ?[]const u8) LookupError!Resolved {
    if (model) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len == 0) return error.MissingModel;
        if (try uniqueWire(cfg, family, trimmed)) |r| return r;
        if (try composite(cfg, family, trimmed)) |r| return r;
        if (aliasOf(cfg, trimmed)) |dest| {
            if (try composite(cfg, family, dest)) |r| return r;
        }
        return error.ModelNotFound;
    }
    return uniqueProvider(cfg, family);
}

pub fn spliceModel(gpa: std.mem.Allocator, body: []const u8, new_id: []const u8) ![]u8 {
    const span = findTopLevelStringField(body, "model") orelse return error.MissingModel;
    if (std.mem.eql(u8, span.value, new_id)) return gpa.dupe(u8, body);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, body[0..span.start]);
    try out.appendSlice(gpa, new_id);
    try out.appendSlice(gpa, body[span.end..]);
    return out.toOwnedSlice(gpa);
}

fn forward(ctx: Ctx, family: Family) u16 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const peek = peekBody(arena, ctx.body) catch {
        return writeEnvelope(ctx, 400, "malformed_request", "Request body is not JSON");
    };
    if (peek.stream == .bad) {
        return writeEnvelope(ctx, 400, "malformed_request", "stream must be a JSON boolean");
    }

    const resolved = lookup(ctx.cfg, family, peek.model) catch |err| switch (err) {
        error.MissingModel => return writeEnvelope(ctx, 400, "missing_required_parameter", "model is required when more than one provider speaks this protocol"),
        error.ModelNotFound => return writeEnvelope(ctx, 400, "model_not_found", "Unknown model for this route"),
        error.ProtocolMismatch => return writeEnvelope(ctx, 400, "protocol_mismatch", "Model does not speak this protocol"),
        error.AmbiguousProvider => return writeEnvelope(ctx, 400, "missing_required_parameter", "Send a model or configure a single provider for this protocol"),
    };

    if (resolved.provider.kind == .vertex_anthropic and !isMessagesCreate(ctx.path)) {
        return writeEnvelope(ctx, 400, "unknown_endpoint", "vertex_anthropic only serves POST /v1/messages");
    }

    var upstream_body = ctx.body;
    if (resolved.splice) {
        upstream_body = spliceModel(arena, ctx.body, resolved.wire_id) catch {
            return writeEnvelope(ctx, 400, "missing_required_parameter", "model must be a JSON string");
        };
    }

    const streaming = peek.stream == .yes or wantsEventStream(ctx.headers_raw, ctx.path);
    const impl = providers.forKind(resolved.provider.kind);
    const url = upstreamUrl(ctx.gpa, &resolved.provider, impl, ctx.path, ctx.query, streaming) catch {
        return writeEnvelope(ctx, 502, null, "Failed to build upstream URL");
    };
    defer ctx.gpa.free(url);

    const cred = auth.resolve(.{ .io = ctx.io, .gpa = ctx.gpa, .environ_map = ctx.environ_map }, impl.auth, &resolved.provider) catch |err| {
        log.log(.error_, "proxy auth resolve provider={s}: {s}", .{ resolved.provider.name, @errorName(err) });
        return writeEnvelope(ctx, 502, null, "Failed to resolve provider credentials");
    };
    defer cred.deinit(ctx.gpa);

    const t0 = std.Io.Timestamp.now(ctx.io, .awake);
    const status = pipe(ctx, family, &resolved.provider, impl, cred, url, upstream_body, streaming) catch |err| {
        const ms = elapsedMs(ctx.io, t0);
        recordFail(ctx, arena, &resolved.provider, 0, @errorName(err), ms);
        return switch (err) {
            error.Timeout => writeEnvelope(ctx, 504, null, "Upstream timed out"),
            else => writeEnvelope(ctx, 502, null, "Upstream connect failed"),
        };
    };
    const ms = elapsedMs(ctx.io, t0);
    log.log(.info, "proxy method={s} path={s} model={s} provider={s} stream={any} status={d} duration_ms={d}", .{
        ctx.method,
        ctx.path,
        resolved.wire_id,
        resolved.provider.name,
        streaming,
        status,
        ms,
    });
    if (status >= 400) {
        recordFail(ctx, arena, &resolved.provider, status, "upstream", ms);
    }
    return status;
}

fn pipe(
    ctx: Ctx,
    family: Family,
    provider: *const config.Provider,
    impl: *const providers.Provider,
    cred: auth.Credential,
    url: []const u8,
    body: []const u8,
    streaming: bool,
) !u16 {
    _ = family;
    const method = parseMethod(ctx.method) orelse return error.BadMethod;
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;

    var headers = std.http.Client.Request.Headers{
        .accept_encoding = .omit,
        .user_agent = .{ .override = user_agent },
    };
    if (headerValue(ctx.headers_raw, "user-agent")) |ua| headers.user_agent = .{ .override = ua };
    if (headerValue(ctx.headers_raw, "content-type")) |ct| {
        headers.content_type = .{ .override = ct };
    } else if (body.len > 0) {
        headers.content_type = .{ .override = "application/json" };
    } else {
        headers.content_type = .omit;
    }
    if (headerValue(ctx.headers_raw, "accept")) |ac| headers.accept = .{ .override = ac };

    var extra: [extra_slots]std.http.Header = undefined;
    var extra_len: usize = 0;

    var scratch: providers.ExtraHeaders = undefined;
    const n = impl.authHeaders(cred, &headers, &scratch);
    for (scratch[0..n]) |h| {
        extra[extra_len] = h;
        extra_len += 1;
    }
    extra_len = overlayAnthropic(ctx, provider, cred, &extra, extra_len);
    extra_len = copyIfPresent(ctx.headers_raw, "openai-organization", &extra, extra_len);
    extra_len = copyIfPresent(ctx.headers_raw, "openai-project", &extra, extra_len);
    extra_len = copyIfPresent(ctx.headers_raw, "openai-beta", &extra, extra_len);
    extra_len = copyIfPresent(ctx.headers_raw, "x-client-request-id", &extra, extra_len);

    var http_client: std.http.Client = .{ .allocator = ctx.gpa, .io = ctx.io };
    defer http_client.deinit();
    var abort: client.Abort = .{};
    abort.arm(ctx.io, &http_client);
    defer abort.disarm(ctx.io);

    var watch = Watch{
        .io = ctx.io,
        .abort = &abort,
        .first_byte_ns = timeoutNs(ctx.cfg.serve.proxy_first_byte_timeout_s, default_first_byte_s),
        .idle_ns = timeoutNs(ctx.cfg.serve.proxy_idle_timeout_s, default_idle_s),
        .started = std.time.nanoTimestamp(),
    };
    const watcher = std.Thread.spawn(.{}, Watch.loop, .{&watch}) catch null;
    defer {
        watch.stop.store(true, .release);
        if (watcher) |t| t.join();
    }

    var req = http_client.request(method, uri, .{
        .redirect_behavior = .unhandled,
        .headers = headers,
        .extra_headers = extra[0..extra_len],
    }) catch return error.ConnectFailed;
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    if (ctx.environ_map.get("CLANKER_DEBUG_BODY") != null) {
        log.log(.debug, "proxy upstream provider={s} bytes={d}", .{ provider.name, body.len });
    }
    if (body.len > 0) {
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(body);
        try body_writer.end();
    } else {
        try req.sendBodyComplete(&.{});
    }
    try req.connection.?.flush();

    var redirect_buffer: [8192]u8 = undefined;
    var response = req.receiveHead(&redirect_buffer) catch return error.Timeout;
    watch.markByte();

    const status: u16 = @intFromEnum(response.head.status);
    const ctype = response.head.content_type orelse if (streaming) "text/event-stream" else "application/json";
    const reason = reasonPhrase(status);

    if (streaming) {
        writeStreamHead(ctx.stream, status, reason, ctype);
        var buf: [8192]u8 = undefined;
        var transfer: [8192]u8 = undefined;
        const reader = response.reader(&transfer);
        var total: usize = 0;
        while (true) {
            const nread = reader.readSliceShort(&buf) catch break;
            if (nread == 0) break;
            watch.markByte();
            total += nread;
            if (total > rawhttp.max_body_bytes) break;
            rawhttp.writeAllFd(ctx.stream.socket.handle, buf[0..nread]);
        }
        return status;
    }

    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(ctx.gpa);
    var buf: [8192]u8 = undefined;
    var transfer: [8192]u8 = undefined;
    const reader = response.reader(&transfer);
    while (true) {
        const nread = reader.readSliceShort(&buf) catch break;
        if (nread == 0) break;
        watch.markByte();
        if (body_buf.items.len + nread > rawhttp.max_body_bytes) {
            return writeEnvelope(ctx, 502, null, "Upstream response too large");
        }
        body_buf.appendSlice(ctx.gpa, buf[0..nread]) catch return error.ConnectFailed;
    }
    writeFixed(ctx.stream, status, reason, ctype, body_buf.items);
    peekAndRecord(ctx, provider, status, body_buf.items, false);
    return status;
}

fn upstreamUrl(
    gpa: std.mem.Allocator,
    provider: *const config.Provider,
    impl: *const providers.Provider,
    path: []const u8,
    query: []const u8,
    streaming: bool,
) ![]u8 {
    const use_vtable = (provider.kind == .vertex_anthropic and isMessagesCreate(path)) or
        (provider.kind == .openai_compat and isChatCompletions(path)) or
        (provider.kind == .anthropic and isMessagesCreate(path));
    if (use_vtable) {
        const base = try impl.endpointUrl(gpa, provider, streaming);
        if (query.len == 0) return base;
        defer gpa.free(base);
        return std.fmt.allocPrint(gpa, "{s}?{s}", .{ base, query });
    }
    return joinUpstream(gpa, provider.base_url, path, query);
}

fn overlayAnthropic(
    ctx: Ctx,
    provider: *const config.Provider,
    cred: auth.Credential,
    extra: *[extra_slots]std.http.Header,
    extra_len: usize,
) usize {
    if (provider.kind != .anthropic) return extra_len;
    var len = extra_len;
    const client_ver = headerValue(ctx.headers_raw, "anthropic-version");
    if (client_ver) |v| {
        len = setNamed(extra, len, "anthropic-version", v);
    }
    const client_beta = headerValue(ctx.headers_raw, "anthropic-beta");
    const oauth = cred.strategy == .oauth_static or cred.strategy == .oauth_refresh;
    if (oauth) {
        const merged = mergeBetas(ctx.gpa, client_beta, anthropic.oauth_beta) catch client_beta orelse anthropic.oauth_beta;
        len = setNamed(extra, len, "anthropic-beta", merged);
    } else if (client_beta) |b| {
        len = setNamed(extra, len, "anthropic-beta", b);
    }
    return len;
}

fn mergeBetas(gpa: std.mem.Allocator, client_beta: ?[]const u8, required: []const u8) ![]const u8 {
    const raw = client_beta orelse return required;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        if (std.mem.eql(u8, std.mem.trim(u8, part, " "), required)) return raw;
    }
    return std.fmt.allocPrint(gpa, "{s},{s}", .{ raw, required });
}

fn setNamed(extra: *[extra_slots]std.http.Header, len: usize, name: []const u8, value: []const u8) usize {
    for (extra[0..len]) |*h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) {
            h.value = value;
            return len;
        }
    }
    if (len >= extra_slots) return len;
    extra[len] = .{ .name = name, .value = value };
    return len + 1;
}

fn copyIfPresent(headers_raw: []const u8, name: []const u8, extra: *[extra_slots]std.http.Header, len: usize) usize {
    const v = headerValue(headers_raw, name) orelse return len;
    return setNamed(extra, len, name, v);
}

const Watch = struct {
    io: std.Io,
    abort: *client.Abort,
    first_byte_ns: u64,
    idle_ns: u64,
    started: i128,
    first: std.atomic.Value(bool) = .init(false),
    last: std.atomic.Value(i128) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),

    fn markByte(self: *Watch) void {
        self.first.store(true, .release);
        self.last.store(std.time.nanoTimestamp(), .release);
    }

    fn loop(self: *Watch) void {
        while (!self.stop.load(.acquire)) {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            const now = std.time.nanoTimestamp();
            if (!self.first.load(.acquire)) {
                if (self.first_byte_ns > 0 and now - self.started > self.first_byte_ns) {
                    self.abort.trigger(self.io);
                    return;
                }
            } else if (self.idle_ns > 0) {
                const last = self.last.load(.acquire);
                if (now - last > self.idle_ns) {
                    self.abort.trigger(self.io);
                    return;
                }
            }
        }
    }
};

fn timeoutNs(configured: ?u32, default_s: u32) u64 {
    const s = configured orelse default_s;
    if (s == 0) return 0;
    return @as(u64, s) * std.time.ns_per_s;
}

fn elapsedMs(io: std.Io, t0: std.Io.Timestamp) u64 {
    const ns = t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    return @intCast(@max(@divTrunc(ns, std.time.ns_per_ms), 0));
}

fn peekAndRecord(ctx: Ctx, provider: *const config.Provider, status: u16, body: []const u8, stream: bool) void {
    _ = stream;
    if (status >= 400) return;
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const usage = peekUsage(arena, body) orelse return;
    if (!ctx.cfg.modules.token_stats) return;
    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(ctx.io, .real).nanoseconds, 1_000_000_000));
    token_stats.append(std.Io.Dir.cwd(), ctx.io, ctx.gpa, arena, ctx.cfg.agent.state_dir, .{
        .ts = ts,
        .provider = provider.name,
        .model = provider.activeModelName(),
        .prompt_tokens = usage.prompt_tokens,
        .completion_tokens = usage.completion_tokens,
        .total_tokens = usage.total_tokens,
        .cache_hit = usage.prompt_cache_hit_tokens,
        .cache_miss = usage.prompt_cache_miss_tokens,
        .cost = client.totalCost(provider, usage),
        .duration_ms = 0,
        .ok = true,
        .http_status = status,
        .request_id = log.getContext(),
    });
}

fn recordFail(ctx: Ctx, arena: std.mem.Allocator, provider: *const config.Provider, status: u16, err_name: []const u8, ms: u64) void {
    if (!ctx.cfg.modules.token_stats) return;
    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(ctx.io, .real).nanoseconds, 1_000_000_000));
    token_stats.append(std.Io.Dir.cwd(), ctx.io, ctx.gpa, arena, ctx.cfg.agent.state_dir, .{
        .ts = ts,
        .provider = provider.name,
        .model = provider.activeModelName(),
        .prompt_tokens = 0,
        .completion_tokens = 0,
        .total_tokens = 0,
        .cache_hit = 0,
        .cache_miss = 0,
        .cost = 0,
        .duration_ms = ms,
        .ok = false,
        .http_status = status,
        .err = err_name,
        .request_id = log.getContext(),
    });
}

fn peekUsage(arena: std.mem.Allocator, body: []const u8) ?types.Usage {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return null,
    };
    if (obj.get("usage")) |u| return usageFromValue(u);
    return null;
}

fn usageFromValue(v: json.Value) ?types.Usage {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    var u = types.Usage{};
    if (jsonU32(obj.get("prompt_tokens"))) |n| u.prompt_tokens = n;
    if (jsonU32(obj.get("completion_tokens"))) |n| u.completion_tokens = n;
    if (jsonU32(obj.get("total_tokens"))) |n| u.total_tokens = n;
    if (jsonU32(obj.get("prompt_cache_hit_tokens")) orelse jsonU32(nestedCached(obj))) |n| u.prompt_cache_hit_tokens = n;
    if (jsonU32(obj.get("input_tokens"))) |input| {
        const cache_read = jsonU32(obj.get("cache_read_input_tokens")) orelse 0;
        const cache_create = jsonU32(obj.get("cache_creation_input_tokens")) orelse 0;
        const output = jsonU32(obj.get("output_tokens")) orelse 0;
        u.prompt_tokens = input + cache_read + cache_create;
        u.completion_tokens = output;
        u.prompt_cache_hit_tokens = cache_read;
        u.prompt_cache_miss_tokens = input + cache_create;
        u.total_tokens = u.prompt_tokens + u.completion_tokens;
        return u;
    }
    if (u.total_tokens == 0) u.total_tokens = u.prompt_tokens + u.completion_tokens;
    if (u.prompt_cache_miss_tokens == 0 and u.prompt_tokens >= u.prompt_cache_hit_tokens)
        u.prompt_cache_miss_tokens = u.prompt_tokens - u.prompt_cache_hit_tokens;
    if (u.prompt_tokens == 0 and u.completion_tokens == 0 and u.total_tokens == 0) return null;
    return u;
}

fn nestedCached(obj: std.json.ObjectMap) ?std.json.Value {
    const details = obj.get("prompt_tokens_details") orelse return null;
    return switch (details) {
        .object => |o| o.get("cached_tokens"),
        else => null,
    };
}

fn jsonU32(v: ?std.json.Value) ?u32 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
        else => null,
    };
}

const Peek = struct {
    model: ?[]const u8 = null,
    stream: enum { absent, yes, no, bad } = .absent,
};

fn peekBody(arena: std.mem.Allocator, body: []const u8) !Peek {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return .{};
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch return error.Malformed;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.Malformed,
    };
    var peek = Peek{};
    if (obj.get("model")) |m| {
        peek.model = switch (m) {
            .string => |s| s,
            else => return error.Malformed,
        };
    }
    if (obj.get("stream")) |s| {
        peek.stream = switch (s) {
            .bool => |b| if (b) .yes else .no,
            else => .bad,
        };
    }
    return peek;
}

const StringSpan = struct { start: usize, end: usize, value: []const u8 };

fn findTopLevelStringField(body: []const u8, field: []const u8) ?StringSpan {
    var i: usize = 0;
    while (i < body.len and body[i] != '{') : (i += 1) {}
    if (i >= body.len) return null;
    i += 1;
    var depth: u32 = 1;
    var in_str = false;
    var escape = false;
    while (i < body.len and depth > 0) {
        const c = body[i];
        if (in_str) {
            if (escape) {
                escape = false;
            } else if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_str = false;
            }
            i += 1;
            continue;
        }
        if (c == '"') {
            const start = i + 1;
            i += 1;
            while (i < body.len) {
                if (body[i] == '\\') {
                    i += 2;
                    continue;
                }
                if (body[i] == '"') break;
                i += 1;
            }
            if (i >= body.len) return null;
            const key = body[start..i];
            i += 1;
            while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\n' or body[i] == '\r')) : (i += 1) {}
            if (i < body.len and body[i] == ':') {
                i += 1;
                while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\n' or body[i] == '\r')) : (i += 1) {}
                if (depth == 1 and std.mem.eql(u8, key, field) and i < body.len and body[i] == '"') {
                    const vstart = i + 1;
                    i += 1;
                    while (i < body.len) {
                        if (body[i] == '\\') {
                            i += 2;
                            continue;
                        }
                        if (body[i] == '"') {
                            return .{ .start = vstart, .end = i, .value = body[vstart..i] };
                        }
                        i += 1;
                    }
                    return null;
                }
            }
            continue;
        }
        if (c == '{' or c == '[') depth += 1;
        if (c == '}' or c == ']') depth -= 1;
        i += 1;
    }
    return null;
}

fn uniqueWire(cfg: *const config.Config, family: Family, id: []const u8) LookupError!?Resolved {
    var found: ?Resolved = null;
    var it = cfg.providers.iterator();
    while (it.next()) |kv| {
        const p = kv.value_ptr;
        if (!speaks(p.kind, family)) continue;
        if (p.models.get(id) == null) continue;
        if (found != null) return null;
        var copy = p.*;
        copy.default_model = id;
        found = .{ .provider = copy, .wire_id = id, .splice = false };
    }
    return found;
}

fn composite(cfg: *const config.Config, family: Family, name: []const u8) LookupError!?Resolved {
    const slash = std.mem.findScalar(u8, name, '/') orelse return null;
    const head = name[0..slash];
    const tail = name[slash + 1 ..];
    if (head.len == 0 or tail.len == 0) return null;
    const p = cfg.providers.getPtr(head) orelse return null;
    if (!speaks(p.kind, family)) return error.ProtocolMismatch;
    if (p.models.count() > 0 and p.models.get(tail) == null) return error.ModelNotFound;
    var copy = p.*;
    copy.default_model = tail;
    return .{ .provider = copy, .wire_id = tail, .splice = !std.mem.eql(u8, name, tail) };
}

fn aliasOf(cfg: *const config.Config, name: []const u8) ?[]const u8 {
    return cfg.serve.proxy_aliases.map.get(name);
}

fn uniqueProvider(cfg: *const config.Config, family: Family) LookupError!Resolved {
    var found: ?*const config.Provider = null;
    var it = cfg.providers.iterator();
    while (it.next()) |kv| {
        if (!speaks(kv.value_ptr.kind, family)) continue;
        if (found != null) return error.AmbiguousProvider;
        found = kv.value_ptr;
    }
    const p = found orelse return error.ModelNotFound;
    const copy = p.*;
    return .{ .provider = copy, .wire_id = copy.default_model, .splice = false };
}

fn speaks(kind: config.ProviderKind, family: Family) bool {
    return switch (family) {
        .openai => kind == .openai_compat,
        .anthropic => kind == .anthropic or kind == .vertex_anthropic,
    };
}

fn writeModelsList(ctx: Ctx, family: Family) u16 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &out.writer };
    collectModels(ctx.cfg, family, arena, &s) catch return writeEnvelope(ctx, 500, null, "Failed to list models");
    writeFixed(ctx.stream, 200, "OK", "application/json", out.written());
    return 200;
}

fn writeModelsGet(ctx: Ctx, family: Family, id: []const u8) u16 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const hit = findAdvertised(ctx.cfg, family, arena, id) orelse {
        return writeEnvelope(ctx, 404, "model_not_found", "Unknown model");
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &out.writer };
    writeOneModel(&s, family, hit.id, hit.owned_by, hit.display) catch {
        return writeEnvelope(ctx, 500, null, "Failed to encode model");
    };
    writeFixed(ctx.stream, 200, "OK", "application/json", out.written());
    return 200;
}

const Listed = struct { id: []const u8, owned_by: []const u8, display: []const u8 };

fn collectModels(cfg: *const config.Config, family: Family, arena: std.mem.Allocator, s: *std.json.Stringify) !void {
    try s.beginObject();
    if (family == .openai) {
        try s.objectField("object");
        try s.write("list");
    }
    try s.objectField("data");
    try s.beginArray();
    var it = cfg.providers.iterator();
    while (it.next()) |kv| {
        const p = kv.value_ptr;
        if (!speaks(p.kind, family)) continue;
        var mit = p.models.iterator();
        while (mit.next()) |m| {
            const id = try advertisedAlloc(arena, cfg, family, kv.key_ptr.*, m.key_ptr.*);
            const display = m.value_ptr.display orelse m.key_ptr.*;
            try writeOneModel(s, family, id, kv.key_ptr.*, display);
        }
    }
    try s.endArray();
    if (family == .anthropic) {
        try s.objectField("has_more");
        try s.write(false);
    }
    try s.endObject();
}

fn advertisedAlloc(arena: std.mem.Allocator, cfg: *const config.Config, family: Family, provider_name: []const u8, wire_id: []const u8) ![]const u8 {
    var hits: u32 = 0;
    var it = cfg.providers.iterator();
    while (it.next()) |kv| {
        if (!speaks(kv.value_ptr.kind, family)) continue;
        if (kv.value_ptr.models.get(wire_id) != null) hits += 1;
    }
    if (hits == 1) return wire_id;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ provider_name, wire_id });
}

fn findAdvertised(cfg: *const config.Config, family: Family, arena: std.mem.Allocator, want: []const u8) ?Listed {
    var it = cfg.providers.iterator();
    while (it.next()) |kv| {
        const p = kv.value_ptr;
        if (!speaks(p.kind, family)) continue;
        var mit = p.models.iterator();
        while (mit.next()) |m| {
            const id = advertisedAlloc(arena, cfg, family, kv.key_ptr.*, m.key_ptr.*) catch continue;
            if (std.mem.eql(u8, id, want) or std.mem.eql(u8, m.key_ptr.*, want)) {
                return .{ .id = id, .owned_by = kv.key_ptr.*, .display = m.value_ptr.display orelse m.key_ptr.* };
            }
        }
    }
    return null;
}

fn writeOneModel(s: *std.json.Stringify, family: Family, id: []const u8, owned_by: []const u8, display: []const u8) !void {
    try s.beginObject();
    try s.objectField("id");
    try s.write(id);
    switch (family) {
        .openai => {
            try s.objectField("object");
            try s.write("model");
            try s.objectField("created");
            try s.write(0);
            try s.objectField("owned_by");
            try s.write(owned_by);
        },
        .anthropic => {
            try s.objectField("type");
            try s.write("model");
            try s.objectField("display_name");
            try s.write(display);
            try s.objectField("created_at");
            try s.write("1970-01-01T00:00:00Z");
        },
    }
    try s.endObject();
}

fn writeEnvelope(ctx: Ctx, status: u16, code: ?[]const u8, message: []const u8) u16 {
    const family = familyOf(ctx.path, ctx.headers_raw);
    var buf: [1536]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    switch (family) {
        .openai => {
            w.writeAll("{\"error\":{\"message\":") catch {};
            std.json.Stringify.value(message, .{}, &w) catch {};
            w.writeAll(",\"type\":\"invalid_request_error\",\"param\":null,\"code\":") catch {};
            if (code) |c| {
                std.json.Stringify.value(c, .{}, &w) catch {};
            } else {
                w.writeAll("null") catch {};
            }
            w.writeAll("}}") catch {};
        },
        .anthropic => {
            w.writeAll("{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":") catch {};
            std.json.Stringify.value(message, .{}, &w) catch {};
            w.writeAll("}}") catch {};
        },
    }
    writeFixed(ctx.stream, status, reasonPhrase(status), "application/json", w.buffered());
    return status;
}

fn writeAllow(ctx: Ctx, status: u16, allow: []const u8) u16 {
    var hbuf: [512]u8 = undefined;
    const request_id = log.getContext();
    const body = "{\"error\":{\"message\":\"Method not allowed\",\"type\":\"invalid_request_error\",\"code\":\"method_not_allowed\"}}";
    const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 {d} Method Not Allowed\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nAllow: {s}\r\nX-Content-Type-Options: nosniff\r\nX-Request-ID: {s}\r\nConnection: close\r\n\r\n", .{
        status,
        body.len,
        allow,
        request_id,
    }) catch return status;
    rawhttp.writeAllFd(ctx.stream.socket.handle, hdr);
    rawhttp.writeAllFd(ctx.stream.socket.handle, body);
    return status;
}

fn writeFixed(stream: std.Io.net.Stream, status: u16, reason: []const u8, content_type: []const u8, body: []const u8) void {
    var hbuf: [768]u8 = undefined;
    const request_id = log.getContext();
    const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nX-Content-Type-Options: nosniff\r\nX-Request-ID: {s}\r\nConnection: close\r\n\r\n", .{
        status,
        reason,
        content_type,
        body.len,
        request_id,
    }) catch return;
    rawhttp.writeAllFd(stream.socket.handle, hdr);
    rawhttp.writeAllFd(stream.socket.handle, body);
}

fn writeStreamHead(stream: std.Io.net.Stream, status: u16, reason: []const u8, content_type: []const u8) void {
    var hbuf: [512]u8 = undefined;
    const request_id = log.getContext();
    const hdr = std.fmt.bufPrint(&hbuf, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nX-Content-Type-Options: nosniff\r\nX-Request-ID: {s}\r\nConnection: close\r\n\r\n", .{
        status,
        reason,
        content_type,
        request_id,
    }) catch return;
    rawhttp.writeAllFd(stream.socket.handle, hdr);
}

fn reasonPhrase(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Content Too Large",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "OK",
    };
}

fn presentedToken(headers_raw: []const u8) ?[]const u8 {
    if (headerValue(headers_raw, "authorization")) |b| {
        const t = std.mem.trim(u8, b, " ");
        if (t.len >= 7 and std.ascii.eqlIgnoreCase(t[0..7], "bearer ")) {
            return std.mem.trim(u8, t[7..], " ");
        }
        return t;
    }
    if (headerValue(headers_raw, "x-api-key")) |k| return std.mem.trim(u8, k, " ");
    return null;
}

pub fn headerValue(headers_raw: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers_raw, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

fn isWebsocketUpgrade(headers_raw: []const u8) bool {
    const u = headerValue(headers_raw, "upgrade") orelse return false;
    return std.ascii.eqlIgnoreCase(u, "websocket");
}

fn wantsEventStream(headers_raw: []const u8, path: []const u8) bool {
    if (std.mem.endsWith(u8, path, "/events/stream")) return true;
    const ac = headerValue(headers_raw, "accept") orelse return false;
    return std.mem.indexOf(u8, ac, "text/event-stream") != null;
}

fn parseMethod(s: []const u8) ?std.http.Method {
    if (std.mem.eql(u8, s, "GET")) return .GET;
    if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
    if (std.mem.eql(u8, s, "POST")) return .POST;
    if (std.mem.eql(u8, s, "PUT")) return .PUT;
    if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
    if (std.mem.eql(u8, s, "PATCH")) return .PATCH;
    if (std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
    return null;
}

fn v1Rest(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "/v1/")) return path[3..];
    if (std.mem.eql(u8, path, "/v1")) return "/";
    return path;
}

fn anthropicOnly(rest: []const u8) bool {
    return pathPrefix(rest, "/messages") or pathPrefix(rest, "/complete") or
        pathPrefix(rest, "/skills") or pathPrefix(rest, "/agents") or
        pathPrefix(rest, "/sessions") or pathPrefix(rest, "/environments");
}

fn sharedPath(rest: []const u8) bool {
    return pathPrefix(rest, "/models") or pathPrefix(rest, "/files");
}

fn pathPrefix(rest: []const u8, p: []const u8) bool {
    if (!std.mem.startsWith(u8, rest, p)) return false;
    if (rest.len == p.len) return true;
    const c = rest[p.len];
    return c == '/' or c == '?';
}

fn isModelsList(path: []const u8) bool {
    return std.mem.eql(u8, path, "/v1/models");
}

fn modelsId(path: []const u8) ?[]const u8 {
    const p = "/v1/models/";
    if (std.mem.startsWith(u8, path, p) and path.len > p.len) return path[p.len..];
    return null;
}

fn isChatCompletions(path: []const u8) bool {
    return std.mem.eql(u8, path, "/v1/chat/completions");
}

fn isMessagesCreate(path: []const u8) bool {
    return std.mem.eql(u8, path, "/v1/messages");
}

// ------------------------------------------------------------------- tests --

test "isProxyPath and stripProxyPrefix isolate /proxy/v1 on the shared socket" {
    try std.testing.expect(isProxyPath("/proxy/v1/models", .both));
    try std.testing.expect(isProxyPath("/proxy/v1", .both));
    try std.testing.expect(!isProxyPath("/v1/models", .both));
    try std.testing.expect(!isProxyPath("/api/run", .both));
    try std.testing.expect(!isProxyPath("/proxy/v1/models", .webui));
    try std.testing.expect(isProxyPath("/v1/chat/completions", .proxy));
    try std.testing.expect(!isProxyPath("/proxy/v1/models", .proxy));
    try std.testing.expectEqualStrings("/v1/models", stripProxyPrefix("/proxy/v1/models", .both));
    try std.testing.expectEqualStrings("/v1/models", stripProxyPrefix("/v1/models", .proxy));
}

test "familyOf uses path first and anthropic-version on shared routes" {
    try std.testing.expectEqual(Family.openai, familyOf("/v1/chat/completions", ""));
    try std.testing.expectEqual(Family.openai, familyOf("/v1/embeddings", ""));
    try std.testing.expectEqual(Family.openai, familyOf("/v1/responses", ""));
    try std.testing.expectEqual(Family.openai, familyOf("/v1/completions", ""));
    try std.testing.expectEqual(Family.openai, familyOf("/v1/audio/speech", ""));
    try std.testing.expectEqual(Family.anthropic, familyOf("/v1/messages", ""));
    try std.testing.expectEqual(Family.anthropic, familyOf("/v1/messages/count_tokens", ""));
    try std.testing.expectEqual(Family.anthropic, familyOf("/v1/messages/batches", ""));
    try std.testing.expectEqual(Family.anthropic, familyOf("/v1/complete", ""));
    try std.testing.expectEqual(Family.anthropic, familyOf("/v1/skills", ""));
    try std.testing.expectEqual(Family.openai, familyOf("/v1/completions", "anthropic-version: 2023-06-01\r\n"));
    try std.testing.expectEqual(Family.openai, familyOf("/v1/models", ""));
    try std.testing.expectEqual(Family.anthropic, familyOf("/v1/models", "GET / HTTP/1.1\r\nanthropic-version: 2023-06-01\r\n"));
    try std.testing.expectEqual(Family.openai, familyOf("/v1/files", ""));
    try std.testing.expectEqual(Family.anthropic, familyOf("/v1/files", "POST / HTTP/1.1\r\nanthropic-version: 2023-06-01\r\n"));
}

test "joinUpstream does not double /v1 on an OpenAI-style base" {
    const gpa = std.testing.allocator;
    const a = try joinUpstream(gpa, "https://api.openai.com/v1", "/v1/embeddings", "");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/embeddings", a);
    const b = try joinUpstream(gpa, "https://api.anthropic.com", "/v1/messages/count_tokens", "beta=1");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages/count_tokens?beta=1", b);
    const c = try joinUpstream(gpa, "https://api.openai.com/v1/", "/v1/chat/completions", "");
    defer gpa.free(c);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/chat/completions", c);
}

test "lookup unique wire id, composite, alias, protocol mismatch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cfg = config.Config{};
    try cfg.providers.put(arena, "kimi-k3", try config.Provider.single(arena, "kimi-k3", "http://x/v1", .openai_compat, "kimi-k3", .{}));
    try cfg.providers.put(arena, "anthropic", try config.Provider.single(arena, "anthropic", "https://api.anthropic.com", .anthropic, "claude-sonnet-4-20250514", .{ .display = "Claude Sonnet 4" }));
    try cfg.serve.proxy_aliases.map.put(arena, "claude-4-sonnet", "anthropic/claude-sonnet-4-20250514");

    const a = try lookup(&cfg, .openai, "kimi-k3");
    try std.testing.expectEqualStrings("kimi-k3", a.wire_id);
    try std.testing.expect(!a.splice);
    try std.testing.expectEqualStrings("kimi-k3", a.provider.name);

    const b = try lookup(&cfg, .openai, "kimi-k3/kimi-k3");
    try std.testing.expectEqualStrings("kimi-k3", b.wire_id);
    try std.testing.expect(b.splice);

    const c = try lookup(&cfg, .anthropic, "claude-4-sonnet");
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", c.wire_id);
    try std.testing.expect(c.splice);

    try std.testing.expectError(error.ProtocolMismatch, lookup(&cfg, .openai, "anthropic/claude-sonnet-4-20250514"));
    try std.testing.expectError(error.ModelNotFound, lookup(&cfg, .openai, "nope"));
}

test "lookup does not mutate cfg.providers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cfg = config.Config{};
    var p = try config.Provider.single(arena, "vertex", "https://example", .vertex_anthropic, "claude-opus-4-6", .{});
    try p.models.put(arena, "claude-sonnet-4", .{});
    try cfg.providers.put(arena, "vertex", p);

    const r = try lookup(&cfg, .anthropic, "claude-sonnet-4");
    try std.testing.expectEqualStrings("claude-sonnet-4", r.provider.default_model);
    try std.testing.expectEqualStrings("claude-opus-4-6", cfg.providers.getPtr("vertex").?.default_model);
}

test "spliceModel rewrites only the top-level model string" {
    const gpa = std.testing.allocator;
    const body = "{\"model\":\"kimi-k3/kimi-k3\",\"tools\":[{\"x\":1}],\"extra\":true}";
    const out = try spliceModel(gpa, body, "kimi-k3");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("{\"model\":\"kimi-k3\",\"tools\":[{\"x\":1}],\"extra\":true}", out);
    const same = try spliceModel(gpa, "{\"model\":\"kimi-k3\"}", "kimi-k3");
    defer gpa.free(same);
    try std.testing.expectEqualStrings("{\"model\":\"kimi-k3\"}", same);
}

test "authorize accepts Bearer and x-api-key" {
    try std.testing.expectEqual(AuthResult.ok, authorize("GET /\r\nAuthorization: Bearer secret\r\n", "secret"));
    try std.testing.expectEqual(AuthResult.ok, authorize("GET /\r\nx-api-key: secret\r\n", "secret"));
    try std.testing.expectEqual(AuthResult.mismatch, authorize("GET /\r\nAuthorization: Bearer nope\r\n", "secret"));
    try std.testing.expectEqual(AuthResult.missing, authorize("GET /\r\nHost: x\r\n", "secret"));
}

test "complete is Anthropic; completions is OpenAI" {
    try std.testing.expectEqual(Family.anthropic, familyOf("/v1/complete", ""));
    try std.testing.expectEqual(Family.openai, familyOf("/v1/completions", ""));
}
