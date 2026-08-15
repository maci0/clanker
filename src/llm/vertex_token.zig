//! GCP access tokens for the Vertex providers.
//!
//! Two credential JSON shapes are accepted:
//!
//!   - `type=service_account`: an RS256 assertion is signed in-process
//!     (see `gcp_jwt.zig`) and exchanged at Google's token endpoint.
//!   - `type=authorized_user`: the refresh token from
//!     `gcloud auth application-default login` is exchanged in-process.
//!
//! Path resolution, first match: `service_account_file`, then
//! `GOOGLE_APPLICATION_CREDENTIALS`, then
//! `$CLOUDSDK_CONFIG/application_default_credentials.json`, then
//! `$HOME/.config/gcloud/application_default_credentials.json`.
//!
//! No `gcloud`, no Python, no subprocess: only `std.crypto` and the HTTP
//! client the harness already uses. Tokens are cached until shortly before
//! they expire, so this is one exchange per hour rather than one per request.

const std = @import("std");
const log = @import("../util/log.zig");
const gcp_jwt = @import("gcp_jwt.zig");
const build_options = @import("build_options");

const scope = "https://www.googleapis.com/auth/cloud-platform";
const grant_type = "urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer";
const default_token_uri = "https://oauth2.googleapis.com/token";
/// Refresh this long before the stated expiry, so a request never starts with
/// a token that dies mid-flight. Five minutes covers a slow first call plus a
/// retry, and costs nothing: tokens last an hour, so this is still one
/// exchange per hour.
const refresh_margin_s: i64 = 5 * 60;

var cached_token: ?[]const u8 = null;
var cached_for: []const u8 = "";
var expires_at: i64 = 0;

/// Guards the three variables above.
///
/// Tools that call the model are supposed to be marked `llm` in their
/// descriptor, which keeps them off the parallel worker threads. subagent, rlm
/// and reasoning were not marked, so two of them in one turn ran side by side
/// and both came through here: refreshing frees the previous token before
/// storing the new one, so one thread could free a pointer the other had just
/// been handed, or both could free the same one. Marking the descriptors fixes
/// those three; this makes the next unmarked tool a slow call rather than a
/// double free.
var cache_mutex: std.Io.Mutex = .init;

const TokenReply = struct {
    access_token: []const u8 = "",
    expires_in: i64 = 3600,
};

/// The fields of either ADC JSON shape that matter for minting.
const CredentialsFile = struct {
    type: []const u8 = "",
    client_email: []const u8 = "",
    private_key: []const u8 = "",
    token_uri: []const u8 = default_token_uri,
    client_id: []const u8 = "",
    client_secret: []const u8 = "",
    refresh_token: []const u8 = "",
};

pub const FileKind = enum { service_account, authorized_user };

/// Which credentials file to mint from. `explicit` is
/// `provider.service_account_file` and wins when set. Returned slices are
/// either borrowed from `explicit` / the environment or allocated on `arena`.
pub fn resolveCredentialsPath(
    arena: std.mem.Allocator,
    explicit: []const u8,
    environ: *const std.process.Environ.Map,
) ?[]const u8 {
    if (explicit.len > 0) return explicit;
    if (environ.get("GOOGLE_APPLICATION_CREDENTIALS")) |p| {
        if (p.len > 0) return p;
    }
    if (environ.get("CLOUDSDK_CONFIG")) |dir| {
        if (dir.len > 0) {
            return std.fmt.allocPrint(
                arena,
                "{s}/application_default_credentials.json",
                .{std.mem.trimEnd(u8, dir, "/")},
            ) catch return null;
        }
    }
    const home = environ.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return std.fmt.allocPrint(
        arena,
        "{s}/.config/gcloud/application_default_credentials.json",
        .{std.mem.trimEnd(u8, home, "/")},
    ) catch null;
}

/// Classifies a parsed credentials object. Incomplete fields and unknown
/// `type` values (workload identity, impersonation) are errors: those ADC
/// shapes need a different mint and must not be treated as a service account.
pub fn classifyFile(c: anytype) error{ UnsupportedAdcType, IncompleteCredentials }!FileKind {
    if (c.type.len == 0) {
        if (c.private_key.len > 0 and c.client_email.len > 0) return .service_account;
        if (c.refresh_token.len > 0 and c.client_id.len > 0) return .authorized_user;
        return error.IncompleteCredentials;
    }
    if (std.ascii.eqlIgnoreCase(c.type, "authorized_user")) {
        if (c.client_id.len == 0 or c.client_secret.len == 0 or c.refresh_token.len == 0)
            return error.IncompleteCredentials;
        return .authorized_user;
    }
    if (std.ascii.eqlIgnoreCase(c.type, "service_account")) {
        if (c.client_email.len == 0 or c.private_key.len == 0)
            return error.IncompleteCredentials;
        return .service_account;
    }
    return error.UnsupportedAdcType;
}

/// Returns a bearer token for the resolved credentials file, minting one if
/// the cache is empty, stale, or for a different account. The returned slice
/// is a fresh `gpa`-owned copy the caller must free: the cache entry it was
/// copied from can be freed by a later refresh the instant this call releases
/// the lock, so handing back a borrowed pointer into the cache would let that
/// refresh free memory a caller is still reading.
pub fn get(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: *std.process.Environ.Map,
    explicit_path: []const u8,
) ![]const u8 {
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
    // Held across the whole exchange, not just the store: two callers that
    // both miss would otherwise both mint, and the loser would free a token
    // the winner is already using.
    cache_mutex.lockUncancelable(io);
    defer cache_mutex.unlock(io);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = resolveCredentialsPath(arena, explicit_path, environ) orelse {
        log.log(.error_, "vertex: no credentials file (set service_account_file, GOOGLE_APPLICATION_CREDENTIALS, or run gcloud auth application-default login)", .{});
        return error.VertexTokenFailed;
    };
    if (cached_token) |tok| {
        if (cacheHit(now, expires_at, cached_for, path)) return try gpa.dupe(u8, tok);
    }

    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| {
        log.log(.error_, "vertex: cannot read credentials '{s}': {s}", .{ path, @errorName(err) });
        return error.VertexTokenFailed;
    };
    const creds = std.json.parseFromSliceLeaky(CredentialsFile, arena, raw, .{ .ignore_unknown_fields = true }) catch {
        log.log(.error_, "vertex: credentials file is not valid JSON", .{});
        return error.VertexTokenFailed;
    };
    const kind = classifyFile(creds) catch |err| {
        switch (err) {
            error.UnsupportedAdcType => log.log(.error_, "vertex: credentials type \"{s}\" is not supported (service_account or authorized_user)", .{creds.type}),
            error.IncompleteCredentials => log.log(.error_, "vertex: credentials file is missing required fields", .{}),
        }
        return error.VertexTokenFailed;
    };

    const reply = switch (kind) {
        .service_account => try mintServiceAccount(io, gpa, arena, creds, now),
        .authorized_user => try mintAuthorizedUser(io, gpa, arena, creds),
    };

    if (cached_token) |old| gpa.free(old);
    if (cached_for.len > 0) gpa.free(cached_for);
    cached_token = try gpa.dupe(u8, reply.access_token);
    cached_for = try gpa.dupe(u8, path);
    expires_at = now + @max(0, reply.expires_in - refresh_margin_s);
    log.log(.debug, "vertex: access token minted, valid ~{d}s", .{reply.expires_in});
    return try gpa.dupe(u8, cached_token.?);
}

fn mintServiceAccount(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    creds: CredentialsFile,
    now: i64,
) !TokenReply {
    const sa = gcp_jwt.ServiceAccount{
        .client_email = creds.client_email,
        .private_key = creds.private_key,
        .token_uri = if (creds.token_uri.len > 0) creds.token_uri else default_token_uri,
    };
    const jwt = gcp_jwt.assertion(arena, sa, scope, now) catch |err| {
        log.log(.error_, "vertex: cannot sign the assertion: {s}", .{@errorName(err)});
        return error.VertexTokenFailed;
    };
    const body = try std.fmt.allocPrint(arena, "grant_type={s}&assertion={s}", .{ grant_type, jwt });
    return postToken(io, gpa, arena, sa.token_uri, body);
}

fn mintAuthorizedUser(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    creds: CredentialsFile,
) !TokenReply {
    var body: std.ArrayList(u8) = .empty;
    try appendFormField(&body, arena, "grant_type", "refresh_token");
    try appendFormField(&body, arena, "client_id", creds.client_id);
    try appendFormField(&body, arena, "client_secret", creds.client_secret);
    try appendFormField(&body, arena, "refresh_token", creds.refresh_token);
    const url = if (creds.token_uri.len > 0) creds.token_uri else default_token_uri;
    return postToken(io, gpa, arena, url, body.items);
}

fn postToken(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
) !TokenReply {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var buf: [16 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
            .user_agent = .{ .override = "clanker/" ++ build_options.version },
        },
        .response_writer = &w,
    }) catch |err| {
        log.log(.error_, "vertex: token request failed: {s}", .{@errorName(err)});
        return error.VertexTokenFailed;
    };
    const response = buf[0..w.end];
    if (@intFromEnum(res.status) >= 400) {
        // The raw body from the token endpoint may mirror or include sensitive
        // credential material on some error paths.  Log the status and length
        // only, never the response body, so logs cannot leak secrets.
        log.log(.error_, "vertex: token endpoint returned {d} ({d} bytes)", .{ @intFromEnum(res.status), response.len });
        return error.VertexTokenFailed;
    }

    const reply = std.json.parseFromSliceLeaky(TokenReply, arena, response, .{ .ignore_unknown_fields = true }) catch {
        log.log(.error_, "vertex: token endpoint returned no JSON", .{});
        return error.VertexTokenFailed;
    };
    if (reply.access_token.len == 0) {
        log.log(.error_, "vertex: token endpoint returned no access_token", .{});
        return error.VertexTokenFailed;
    }
    return reply;
}

fn appendFormField(list: *std.ArrayList(u8), alloc: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    if (list.items.len > 0) try list.append(alloc, '&');
    try list.appendSlice(alloc, key);
    try list.append(alloc, '=');
    try appendFormValue(list, alloc, value);
}

fn appendFormValue(list: *std.ArrayList(u8), alloc: std.mem.Allocator, value: []const u8) !void {
    for (value) |c| {
        if (isFormUnreserved(c)) {
            try list.append(alloc, c);
        } else if (c == ' ') {
            try list.append(alloc, '+');
        } else {
            var hex: [3]u8 = undefined;
            const written = std.fmt.bufPrint(&hex, "%{X:0>2}", .{c}) catch unreachable;
            try list.appendSlice(alloc, written);
        }
    }
}

fn isFormUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

/// Frees the cached token; call once at shutdown.
pub fn deinit(io: std.Io, gpa: std.mem.Allocator) void {
    cache_mutex.lockUncancelable(io);
    defer cache_mutex.unlock(io);
    if (cached_token) |tok| gpa.free(tok);
    if (cached_for.len > 0) gpa.free(cached_for);
    cached_token = null;
    cached_for = "";
    expires_at = 0;
}

// ------------------------------------------------------------------- tests --

/// The renewal decision, split out so it can be tested without a network call:
/// a cached token is reused only while it belongs to this account and has not
/// reached its refresh deadline (expiry minus the margin).
fn cacheHit(now: i64, expires: i64, cached_account: []const u8, want_account: []const u8) bool {
    return now < expires and std.mem.eql(u8, cached_account, want_account);
}

test "token cache renews on expiry and on a different account" {
    const expiry = 1000 + (3600 - refresh_margin_s);

    // Fresh: reused.
    try std.testing.expect(cacheHit(1000, expiry, "sa.json", "sa.json"));
    // A second before the refresh deadline: still reused.
    try std.testing.expect(cacheHit(expiry - 1, expiry, "sa.json", "sa.json"));
    // At the deadline, five minutes before Google expires it: renewed.
    try std.testing.expect(!cacheHit(expiry, expiry, "sa.json", "sa.json"));
    // Past it: renewed.
    try std.testing.expect(!cacheHit(expiry + 60, expiry, "sa.json", "sa.json"));
    // Same clock, different service account: renewed rather than reused.
    try std.testing.expect(!cacheHit(1000, expiry, "sa.json", "other.json"));
    // Cold start (deinit or first call): renewed.
    try std.testing.expect(!cacheHit(1000, 0, "", "sa.json"));
}

test "classifyFile tells service_account from authorized_user" {
    const sa = CredentialsFile{
        .type = "service_account",
        .client_email = "sa@proj.iam.gserviceaccount.com",
        .private_key = "-----BEGIN PRIVATE KEY-----\n",
    };
    try std.testing.expectEqual(FileKind.service_account, try classifyFile(sa));

    const user = CredentialsFile{
        .type = "authorized_user",
        .client_id = "123.apps.googleusercontent.com",
        .client_secret = "GOCSPX-secret",
        .refresh_token = "1//refresh",
    };
    try std.testing.expectEqual(FileKind.authorized_user, try classifyFile(user));

    // A type-less SA JSON (the fields themselves are enough).
    try std.testing.expectEqual(FileKind.service_account, try classifyFile(CredentialsFile{
        .client_email = "sa@proj.iam.gserviceaccount.com",
        .private_key = "k",
    }));

    try std.testing.expectError(error.IncompleteCredentials, classifyFile(CredentialsFile{ .type = "authorized_user" }));
    try std.testing.expectError(error.UnsupportedAdcType, classifyFile(CredentialsFile{ .type = "external_account" }));
}

test "resolveCredentialsPath prefers explicit, then GAC, then CLOUDSDK_CONFIG, then HOME" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(resolveCredentialsPath(arena, "", &env_map) == null);

    try env_map.put("HOME", "/home/op");
    try std.testing.expectEqualStrings(
        "/home/op/.config/gcloud/application_default_credentials.json",
        resolveCredentialsPath(arena, "", &env_map).?,
    );

    try env_map.put("CLOUDSDK_CONFIG", "/opt/gcloud/");
    try std.testing.expectEqualStrings(
        "/opt/gcloud/application_default_credentials.json",
        resolveCredentialsPath(arena, "", &env_map).?,
    );

    try env_map.put("GOOGLE_APPLICATION_CREDENTIALS", "/secret/adc.json");
    try std.testing.expectEqualStrings(
        "/secret/adc.json",
        resolveCredentialsPath(arena, "", &env_map).?,
    );

    try std.testing.expectEqualStrings(
        "/cfg/sa.json",
        resolveCredentialsPath(arena, "/cfg/sa.json", &env_map).?,
    );
}

test "appendFormValue percent-encodes reserved bytes and keeps unreserved" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try appendFormField(&list, std.testing.allocator, "grant_type", "refresh_token");
    try appendFormField(&list, std.testing.allocator, "client_id", "123.apps.googleusercontent.com");
    try appendFormField(&list, std.testing.allocator, "refresh_token", "1//abc+def=ghi");
    try std.testing.expectEqualStrings(
        "grant_type=refresh_token&client_id=123.apps.googleusercontent.com&refresh_token=1%2F%2Fabc%2Bdef%3Dghi",
        list.items,
    );
}
