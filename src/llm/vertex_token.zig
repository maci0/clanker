//! GCP access tokens for the `vertex_anthropic` provider.
//!
//! The service account JSON is read, an RS256 assertion is signed in-process
//! (see `gcp_jwt.zig`), and Google's token endpoint exchanges it for a bearer
//! token. No `gcloud`, no Python, no subprocess: only `std.crypto` and the
//! HTTP client the harness already uses.
//!
//! Tokens are cached until shortly before they expire, so this is one exchange
//! per hour rather than one per request.

const std = @import("std");
const log = @import("../util/log.zig");
const gcp_jwt = @import("gcp_jwt.zig");
const build_options = @import("build_options");

const scope = "https://www.googleapis.com/auth/cloud-platform";
const grant_type = "urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer";
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

/// Returns a bearer token for `service_account_file`, minting one if the cache
/// is empty, stale, or for a different account. The returned slice is a fresh
/// `gpa`-owned copy the caller must free: the cache entry it was copied from
/// can be freed by a later refresh the instant this call releases the lock, so
/// handing back a borrowed pointer into the cache would let that refresh free
/// memory a caller is still reading.
pub fn get(io: std.Io, gpa: std.mem.Allocator, service_account_file: []const u8) ![]const u8 {
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
    // Held across the whole exchange, not just the store: two callers that
    // both miss would otherwise both mint, and the loser would free a token
    // the winner is already using.
    cache_mutex.lockUncancelable(io);
    defer cache_mutex.unlock(io);
    if (cached_token) |tok| {
        if (cacheHit(now, expires_at, cached_for, service_account_file)) return try gpa.dupe(u8, tok);
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = std.Io.Dir.cwd().readFileAlloc(io, service_account_file, arena, .limited(1 << 20)) catch |err| {
        log.log(.error_, "vertex: cannot read service account '{s}': {s}", .{ service_account_file, @errorName(err) });
        return error.VertexTokenFailed;
    };
    const sa = std.json.parseFromSliceLeaky(gcp_jwt.ServiceAccount, arena, raw, .{ .ignore_unknown_fields = true }) catch {
        log.log(.error_, "vertex: service account file is not valid JSON", .{});
        return error.VertexTokenFailed;
    };

    const jwt = gcp_jwt.assertion(arena, sa, scope, now) catch |err| {
        log.log(.error_, "vertex: cannot sign the assertion: {s}", .{@errorName(err)});
        return error.VertexTokenFailed;
    };
    const body = try std.fmt.allocPrint(arena, "grant_type={s}&assertion={s}", .{ grant_type, jwt });

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var buf: [16 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const res = client.fetch(.{
        .location = .{ .url = sa.token_uri },
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

    if (cached_token) |old| gpa.free(old);
    if (cached_for.len > 0) gpa.free(cached_for);
    cached_token = try gpa.dupe(u8, reply.access_token);
    cached_for = try gpa.dupe(u8, service_account_file);
    expires_at = now + @max(0, reply.expires_in - refresh_margin_s);
    log.log(.info, "vertex: access token minted, valid ~{d}s", .{reply.expires_in});
    return try gpa.dupe(u8, cached_token.?);
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
