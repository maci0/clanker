//! Shared native OAuth mechanics for provider plugins.
//!
//! Plugins supply public endpoint/client metadata. This module generates PKCE
//! secrets, builds protocol requests, parses token replies, and preserves a
//! rotated-or-omitted refresh token without exposing secrets to WASM guests.

const std = @import("std");
const plugin_api = @import("oauth_plugins/api.zig");
const store = @import("oauth_store.zig");
const llm_client = @import("client.zig");
const build_options = @import("build_options");

const Sha256 = std.crypto.hash.sha2.Sha256;
const b64url = std.base64.url_safe_no_pad;

pub const Pkce = struct {
    verifier: []const u8,
    challenge: []const u8,
};

pub fn generatePkce(io: std.Io, alloc: std.mem.Allocator) !Pkce {
    var entropy: [32]u8 = undefined;
    std.Io.random(io, &entropy);
    const verifier = try alloc.alloc(u8, b64url.Encoder.calcSize(entropy.len));
    _ = b64url.Encoder.encode(verifier, &entropy);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(verifier, &digest, .{});
    const challenge = try alloc.alloc(u8, b64url.Encoder.calcSize(digest.len));
    _ = b64url.Encoder.encode(challenge, &digest);
    return .{ .verifier = verifier, .challenge = challenge };
}

pub fn appendFormField(out: *std.ArrayList(u8), alloc: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    if (out.items.len > 0) try out.append(alloc, '&');
    try appendFormValue(out, alloc, key);
    try out.append(alloc, '=');
    try appendFormValue(out, alloc, value);
}

fn appendFormValue(out: *std.ArrayList(u8), alloc: std.mem.Allocator, value: []const u8) !void {
    for (value) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try out.append(alloc, c),
        ' ' => try out.append(alloc, '+'),
        else => {
            var encoded: [3]u8 = undefined;
            const slice = std.fmt.bufPrint(&encoded, "%{X:0>2}", .{c}) catch unreachable;
            try out.appendSlice(alloc, slice);
        },
    };
}

fn appendScopes(out: *std.ArrayList(u8), alloc: std.mem.Allocator, scopes: []const []const u8) !void {
    for (scopes, 0..) |scope, i| {
        if (i > 0) try out.append(alloc, ' ');
        try out.appendSlice(alloc, scope);
    }
}

pub fn authorizationUrl(alloc: std.mem.Allocator, plugin: plugin_api.Plugin, pkce: Pkce, state: []const u8) ![]const u8 {
    if (plugin.flow != .pkce_manual) return error.WrongOAuthFlow;
    var query: std.ArrayList(u8) = .empty;
    try appendFormField(&query, alloc, "response_type", "code");
    try appendFormField(&query, alloc, "client_id", plugin.client_id);
    try appendFormField(&query, alloc, "redirect_uri", plugin.redirect_uri);
    var scopes: std.ArrayList(u8) = .empty;
    try appendScopes(&scopes, alloc, plugin.scopes);
    try appendFormField(&query, alloc, "scope", scopes.items);
    try appendFormField(&query, alloc, "code_challenge", pkce.challenge);
    try appendFormField(&query, alloc, "code_challenge_method", "S256");
    try appendFormField(&query, alloc, "state", state);
    if (plugin.authorize_code_param) try appendFormField(&query, alloc, "code", "true");
    return std.fmt.allocPrint(alloc, "{s}?{s}", .{ plugin.authorize_url, query.items });
}

pub fn refreshBody(alloc: std.mem.Allocator, plugin: plugin_api.Plugin, refresh_token: []const u8) ![]const u8 {
    if (refresh_token.len == 0) return error.MissingRefreshToken;
    var body: std.ArrayList(u8) = .empty;
    try appendFormField(&body, alloc, "grant_type", "refresh_token");
    try appendFormField(&body, alloc, "client_id", plugin.client_id);
    try appendFormField(&body, alloc, "refresh_token", refresh_token);
    return body.toOwnedSlice(alloc);
}

pub fn codeExchangeBody(alloc: std.mem.Allocator, plugin: plugin_api.Plugin, code: []const u8, verifier: []const u8) ![]const u8 {
    var body: std.ArrayList(u8) = .empty;
    try appendFormField(&body, alloc, "grant_type", "authorization_code");
    try appendFormField(&body, alloc, "client_id", plugin.client_id);
    try appendFormField(&body, alloc, "code", code);
    try appendFormField(&body, alloc, "redirect_uri", plugin.redirect_uri);
    try appendFormField(&body, alloc, "code_verifier", verifier);
    return body.toOwnedSlice(alloc);
}

fn refreshRequestBody(alloc: std.mem.Allocator, plugin: plugin_api.Plugin, refresh_token: []const u8) ![]const u8 {
    if (plugin.token_encoding == .form) return refreshBody(alloc, plugin, refresh_token);
    return std.fmt.allocPrint(alloc, "{{\"grant_type\":\"refresh_token\",\"client_id\":{f},\"refresh_token\":{f}}}", .{ std.json.fmt(plugin.client_id, .{}), std.json.fmt(refresh_token, .{}) });
}

fn exchangeRequestBody(alloc: std.mem.Allocator, plugin: plugin_api.Plugin, code: []const u8, verifier: []const u8, state: []const u8) ![]const u8 {
    if (plugin.token_encoding == .form) return codeExchangeBody(alloc, plugin, code, verifier);
    if (plugin.exchange_state and state.len == 0) return error.MissingOAuthState;
    return std.fmt.allocPrint(alloc, "{{\"grant_type\":\"authorization_code\",\"client_id\":{f},\"code\":{f},\"redirect_uri\":{f},\"code_verifier\":{f},\"state\":{f}}}", .{ std.json.fmt(plugin.client_id, .{}), std.json.fmt(code, .{}), std.json.fmt(plugin.redirect_uri, .{}), std.json.fmt(verifier, .{}), std.json.fmt(state, .{}) });
}

pub fn tokenRecord(alloc: std.mem.Allocator, raw: []const u8, previous_refresh: []const u8, now_ms: i64) !store.Record {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{ .allocate = .alloc_always });
    if (root != .object) return error.BadTokenResponse;
    const access = jsonString(root.object.get("access_token")) orelse return error.BadTokenResponse;
    if (access.len == 0) return error.BadTokenResponse;
    const next_refresh = jsonString(root.object.get("refresh_token")) orelse previous_refresh;
    const token_type = jsonString(root.object.get("token_type")) orelse "Bearer";
    const identity = jsonString(root.object.get("id_token")) orelse access;
    const expires_s = jsonPositiveInt(root.object.get("expires_in")) orelse 0;
    const expires_at_ms = if (expires_s == 0)
        (jwtExpiryMs(alloc, access) catch jwtExpiryMs(alloc, identity) catch 0)
    else
        std.math.add(i64, now_ms, std.math.mul(i64, expires_s, 1000) catch return error.BadTokenResponse) catch return error.BadTokenResponse;
    return .{
        .access_token = access,
        .refresh_token = next_refresh,
        .expires_at_ms = expires_at_ms,
        .token_type = token_type,
        .account_id = accountIdFromJwt(alloc, identity) catch "",
    };
}

fn accountIdFromJwt(alloc: std.mem.Allocator, token: []const u8) ![]const u8 {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return error.NotJwt;
    const payload = parts.next() orelse return error.NotJwt;
    const decoded_len = try b64url.Decoder.calcSizeForSlice(payload);
    const decoded = try alloc.alloc(u8, decoded_len);
    try b64url.Decoder.decode(decoded, payload);
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, decoded, .{ .allocate = .alloc_always });
    if (root != .object) return error.NotJwt;
    const auth_claim = root.object.get("https://api.openai.com/auth") orelse return error.NoAccountId;
    if (auth_claim != .object) return error.NoAccountId;
    return jsonString(auth_claim.object.get("chatgpt_account_id")) orelse return error.NoAccountId;
}

fn jwtExpiryMs(alloc: std.mem.Allocator, token: []const u8) !i64 {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return error.NotJwt;
    const payload = parts.next() orelse return error.NotJwt;
    const decoded_len = try b64url.Decoder.calcSizeForSlice(payload);
    const decoded = try alloc.alloc(u8, decoded_len);
    try b64url.Decoder.decode(decoded, payload);
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, decoded, .{});
    if (root != .object) return error.NotJwt;
    const exp = jsonPositiveInt(root.object.get("exp")) orelse return error.NoExpiry;
    return std.math.mul(i64, exp, 1000) catch error.BadTokenResponse;
}

const PostOutcome = union(enum) {
    ok: usize,
    status: struct { code: u16, len: usize },
    transport: []const u8,
};

const PostArgs = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    out: []u8,
    content_type: []const u8 = "application/x-www-form-urlencoded",
};

fn postTask(args: PostArgs, abort: *llm_client.Abort, done: *std.Io.Event) PostOutcome {
    defer done.set(args.io);
    var http: std.http.Client = .{ .allocator = args.gpa, .io = args.io };
    defer http.deinit();
    abort.arm(args.io, &http);
    defer abort.disarm(args.io);
    var writer: std.Io.Writer = .fixed(args.out);
    const response = http.fetch(.{
        .location = .{ .url = args.url },
        .method = .POST,
        .payload = args.body,
        .headers = .{
            .content_type = .{ .override = args.content_type },
            .user_agent = .{ .override = "clanker/" ++ build_options.version },
        },
        .response_writer = &writer,
    }) catch |err| return .{ .transport = @errorName(err) };
    const status = @intFromEnum(response.status);
    if (status >= 400) return .{ .status = .{ .code = status, .len = writer.end } };
    return .{ .ok = writer.end };
}

fn postWithTimeout(io: std.Io, args: PostArgs, timeout_ms: u32) ?PostOutcome {
    var abort: llm_client.Abort = .{};
    var done: std.Io.Event = .unset;
    var future = io.concurrent(postTask, .{ args, &abort, &done }) catch |err| return .{ .transport = @errorName(err) };
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .clock = .awake, .raw = .{ .nanoseconds = @as(i96, timeout_ms) * std.time.ns_per_ms } });
    while (!done.isSet()) {
        done.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout => {
                if (done.isSet()) break;
                if (deadline.durationFromNow(io).raw.nanoseconds > 0) continue;
                abort.trigger(io);
                _ = future.cancel(io);
                return null;
            },
            error.Canceled => {
                abort.trigger(io);
                _ = future.cancel(io);
                return null;
            },
        };
    }
    return future.await(io);
}

/// Exchange a refresh token under a finite wall-clock budget. Error bodies are
/// deliberately not returned or logged because providers may echo secrets.
pub fn refresh(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, plugin: plugin_api.Plugin, previous: store.Record, now_ms: i64) !store.Record {
    const body = try refreshRequestBody(arena, plugin, previous.refresh_token);
    var response_buf: [64 * 1024]u8 = undefined;
    const content_type = if (plugin.token_encoding == .json) "application/json" else "application/x-www-form-urlencoded";
    const outcome = postWithTimeout(io, .{ .io = io, .gpa = gpa, .url = plugin.token_url, .body = body, .out = &response_buf, .content_type = content_type }, 10_000) orelse return error.OAuthTokenTimeout;
    const response = switch (outcome) {
        .ok => |n| response_buf[0..n],
        .status => return error.OAuthTokenRejected,
        .transport => return error.OAuthTokenTransport,
    };
    var next = try tokenRecord(arena, response, previous.refresh_token, now_ms);
    next.scopes = previous.scopes;
    if (next.account_id.len == 0) next.account_id = previous.account_id;
    return next;
}

pub const DeviceAuthorization = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    verification_uri_complete: []const u8 = "",
    expires_in: u32,
    interval: u32,
};

pub const CodexDeviceAuthorization = struct {
    device_auth_id: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    interval: u32,
};

pub const CodexGrant = struct { code: []const u8, verifier: []const u8 };

pub fn parseDeviceAuthorization(alloc: std.mem.Allocator, raw: []const u8) !DeviceAuthorization {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{ .allocate = .alloc_always });
    if (root != .object) return error.BadDeviceResponse;
    const device_code = jsonString(root.object.get("device_code")) orelse return error.BadDeviceResponse;
    const user_code = jsonString(root.object.get("user_code")) orelse return error.BadDeviceResponse;
    const verification_uri = jsonString(root.object.get("verification_uri")) orelse jsonString(root.object.get("verification_url")) orelse return error.BadDeviceResponse;
    const expires = jsonPositiveInt(root.object.get("expires_in")) orelse return error.BadDeviceResponse;
    const interval = jsonPositiveInt(root.object.get("interval")) orelse 5;
    return .{
        .device_code = device_code,
        .user_code = user_code,
        .verification_uri = verification_uri,
        .verification_uri_complete = jsonString(root.object.get("verification_uri_complete")) orelse "",
        .expires_in = std.math.cast(u32, expires) orelse return error.BadDeviceResponse,
        .interval = std.math.cast(u32, interval) orelse return error.BadDeviceResponse,
    };
}

pub fn parseCodexDeviceAuthorization(alloc: std.mem.Allocator, raw: []const u8, fallback_uri: []const u8) !CodexDeviceAuthorization {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{ .allocate = .alloc_always });
    if (root != .object) return error.BadDeviceResponse;
    return .{
        .device_auth_id = jsonString(root.object.get("device_auth_id")) orelse return error.BadDeviceResponse,
        .user_code = jsonString(root.object.get("user_code")) orelse return error.BadDeviceResponse,
        .verification_uri = jsonString(root.object.get("verification_uri")) orelse fallback_uri,
        .interval = std.math.cast(u32, jsonPositiveInt(root.object.get("interval")) orelse 5) orelse return error.BadDeviceResponse,
    };
}

pub fn parseCodexGrant(alloc: std.mem.Allocator, raw: []const u8) !CodexGrant {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{ .allocate = .alloc_always });
    if (root != .object) return error.BadDeviceResponse;
    return .{
        .code = jsonString(root.object.get("authorization_code")) orelse return error.BadDeviceResponse,
        .verifier = jsonString(root.object.get("code_verifier")) orelse return error.BadDeviceResponse,
    };
}

pub fn deviceCodeBody(alloc: std.mem.Allocator, plugin: plugin_api.Plugin) ![]const u8 {
    var scopes: std.ArrayList(u8) = .empty;
    try appendScopes(&scopes, alloc, plugin.scopes);
    var body: std.ArrayList(u8) = .empty;
    try appendFormField(&body, alloc, "client_id", plugin.client_id);
    try appendFormField(&body, alloc, "scope", scopes.items);
    return body.toOwnedSlice(alloc);
}

pub fn devicePollBody(alloc: std.mem.Allocator, plugin: plugin_api.Plugin, device_code: []const u8) ![]const u8 {
    var body: std.ArrayList(u8) = .empty;
    try appendFormField(&body, alloc, "grant_type", "urn:ietf:params:oauth:grant-type:device_code");
    try appendFormField(&body, alloc, "client_id", plugin.client_id);
    try appendFormField(&body, alloc, "device_code", device_code);
    return body.toOwnedSlice(alloc);
}

pub const PollError = enum { pending, slow_down, expired, denied, rejected };

pub fn parsePollError(alloc: std.mem.Allocator, raw: []const u8) PollError {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{ .allocate = .alloc_always }) catch return .rejected;
    if (root != .object) return .rejected;
    const name = jsonString(root.object.get("error")) orelse return .rejected;
    if (std.mem.eql(u8, name, "authorization_pending")) return .pending;
    if (std.mem.eql(u8, name, "slow_down")) return .slow_down;
    if (std.mem.eql(u8, name, "expired_token")) return .expired;
    if (std.mem.eql(u8, name, "access_denied")) return .denied;
    return .rejected;
}

pub const DevicePoll = union(enum) { token: store.Record, wait: PollError };

fn requestBytes(io: std.Io, gpa: std.mem.Allocator, url: []const u8, body: []const u8, content_type: []const u8, out: []u8) !PostOutcome {
    return postWithTimeout(io, .{ .io = io, .gpa = gpa, .url = url, .body = body, .out = out, .content_type = content_type }, 10_000) orelse error.OAuthTokenTimeout;
}

pub fn requestDeviceAuthorization(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, plugin: plugin_api.Plugin) !DeviceAuthorization {
    if (plugin.flow != .device_code) return error.WrongOAuthFlow;
    const body = try deviceCodeBody(arena, plugin);
    var response_buf: [64 * 1024]u8 = undefined;
    const outcome = try requestBytes(io, gpa, plugin.device_code_url, body, "application/x-www-form-urlencoded", &response_buf);
    const raw = switch (outcome) {
        .ok => |n| response_buf[0..n],
        .status => return error.OAuthDeviceRejected,
        .transport => return error.OAuthDeviceTransport,
    };
    return parseDeviceAuthorization(arena, raw);
}

pub fn pollDeviceOnce(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, plugin: plugin_api.Plugin, device_code: []const u8, now_ms: i64) !DevicePoll {
    const body = try devicePollBody(arena, plugin, device_code);
    var response_buf: [64 * 1024]u8 = undefined;
    const outcome = try requestBytes(io, gpa, plugin.device_token_url, body, "application/x-www-form-urlencoded", &response_buf);
    return switch (outcome) {
        .ok => |n| blk: {
            var record = try tokenRecord(arena, response_buf[0..n], "", now_ms);
            record.scopes = plugin.scopes;
            break :blk .{ .token = record };
        },
        .status => |s| .{ .wait = parsePollError(arena, response_buf[0..s.len]) },
        .transport => error.OAuthDeviceTransport,
    };
}

pub fn requestCodexDeviceAuthorization(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, plugin: plugin_api.Plugin) !CodexDeviceAuthorization {
    if (plugin.flow != .codex_device) return error.WrongOAuthFlow;
    const body = try std.fmt.allocPrint(arena, "{{\"client_id\":{f}}}", .{std.json.fmt(plugin.client_id, .{})});
    var response_buf: [64 * 1024]u8 = undefined;
    const outcome = try requestBytes(io, gpa, plugin.device_code_url, body, "application/json", &response_buf);
    const raw = switch (outcome) {
        .ok => |n| response_buf[0..n],
        .status => return error.OAuthDeviceRejected,
        .transport => return error.OAuthDeviceTransport,
    };
    return parseCodexDeviceAuthorization(arena, raw, plugin.verification_url);
}

pub fn pollCodexDeviceOnce(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, plugin: plugin_api.Plugin, device: CodexDeviceAuthorization) !?CodexGrant {
    const body = try std.fmt.allocPrint(arena, "{{\"device_auth_id\":{f},\"user_code\":{f}}}", .{ std.json.fmt(device.device_auth_id, .{}), std.json.fmt(device.user_code, .{}) });
    var response_buf: [64 * 1024]u8 = undefined;
    const outcome = try requestBytes(io, gpa, plugin.device_token_url, body, "application/json", &response_buf);
    return switch (outcome) {
        .ok => |n| try parseCodexGrant(arena, response_buf[0..n]),
        .status => |s| if (s.code == 403 or s.code == 404)
            null
        else switch (parsePollError(arena, response_buf[0..s.len])) {
            .pending, .slow_down => null,
            else => error.OAuthDeviceRejected,
        },
        .transport => error.OAuthDeviceTransport,
    };
}

pub fn exchangeAuthorizationCode(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, plugin: plugin_api.Plugin, code: []const u8, verifier: []const u8, state: []const u8, now_ms: i64) !store.Record {
    const body = try exchangeRequestBody(arena, plugin, code, verifier, state);
    var response_buf: [64 * 1024]u8 = undefined;
    const content_type = if (plugin.token_encoding == .json) "application/json" else "application/x-www-form-urlencoded";
    const outcome = try requestBytes(io, gpa, plugin.token_url, body, content_type, &response_buf);
    const raw = switch (outcome) {
        .ok => |n| response_buf[0..n],
        .status => return error.OAuthTokenRejected,
        .transport => return error.OAuthTokenTransport,
    };
    var record = try tokenRecord(arena, raw, "", now_ms);
    record.scopes = plugin.scopes;
    return record;
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) v.string else null;
}

fn jsonPositiveInt(value: ?std.json.Value) ?i64 {
    const v = value orelse return null;
    const n: i64 = switch (v) {
        .integer => |n| n,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch return null,
        else => return null,
    };
    return if (n > 0) n else null;
}

test "PKCE challenge is SHA256 base64url of the verifier" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const p = try generatePkce(threaded.io(), arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 43), p.verifier.len);
    try std.testing.expectEqual(@as(usize, 43), p.challenge.len);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(p.verifier, &digest, .{});
    var expected: [43]u8 = undefined;
    _ = b64url.Encoder.encode(&expected, &digest);
    try std.testing.expectEqualStrings(&expected, p.challenge);
}

test "token response rotates refresh token and computes expiry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rotated = try tokenRecord(arena, "{\"access_token\":\"a2\",\"refresh_token\":\"r2\",\"expires_in\":3600}", "r1", 1000);
    try std.testing.expectEqualStrings("a2", rotated.access_token);
    try std.testing.expectEqualStrings("r2", rotated.refresh_token);
    try std.testing.expectEqual(@as(i64, 3_601_000), rotated.expires_at_ms);
    const preserved = try tokenRecord(arena, "{\"access_token\":\"a3\",\"expires_in\":\"60\"}", "r2", 1000);
    try std.testing.expectEqualStrings("r2", preserved.refresh_token);
    try std.testing.expectEqual(@as(i64, 61_000), preserved.expires_at_ms);
}

test "native OAuth requests percent-encode secrets and carry plugin metadata" {
    const registry = @import("oauth_plugins/registry.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = try refreshBody(arena, registry.find("codex").?.*, "r+/ secret");
    try std.testing.expect(std.mem.find(u8, body, "client_id=app_EMoamEEZ73f0CkXaXp7hrann") != null);
    try std.testing.expect(std.mem.find(u8, body, "refresh_token=r%2B%2F+secret") != null);
    const url = try authorizationUrl(arena, registry.find("claude").?.*, .{ .verifier = "v", .challenge = "c+" }, "state/value");
    try std.testing.expect(std.mem.startsWith(u8, url, "https://claude.com/cai/oauth/authorize?"));
    try std.testing.expect(std.mem.find(u8, url, "code_challenge=c%2B") != null);
    try std.testing.expect(std.mem.find(u8, url, "state=state%2Fvalue") != null);
    try std.testing.expect(std.mem.find(u8, url, "code=true") != null);
    const claude_body = try exchangeRequestBody(arena, registry.find("claude").?.*, "code+value", "verify", "bound-state");
    try std.testing.expect(std.mem.find(u8, claude_body, "\"state\":\"bound-state\"") != null);
    try std.testing.expect(std.mem.find(u8, claude_body, "code%2Bvalue") == null);
}

test "device response parsers keep provider verification URLs and pending state" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const xai = try parseDeviceAuthorization(arena, "{\"device_code\":\"d\",\"user_code\":\"U-C\",\"verification_uri\":\"https://x.ai/device\",\"verification_uri_complete\":\"https://x.ai/device?code=U-C\",\"expires_in\":900,\"interval\":5}");
    try std.testing.expectEqualStrings("https://x.ai/device", xai.verification_uri);
    try std.testing.expectEqual(@as(u32, 5), xai.interval);
    const codex = try parseCodexDeviceAuthorization(arena, "{\"device_auth_id\":\"id\",\"user_code\":\"ABCD\",\"interval\":3}", "https://auth.openai.com/codex/device");
    try std.testing.expectEqualStrings("https://auth.openai.com/codex/device", codex.verification_uri);
    try std.testing.expectEqual(PollError.pending, parsePollError(arena, "{\"error\":\"authorization_pending\"}"));
}
