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
const client = @import("client.zig");
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
/// Fingerprint (size + mtime) of the credentials file `cached_for` was minted
/// from, so a rotation that rewrites the file in place is seen as a new
/// account rather than served from until expiry.
var cached_stamp: u64 = 0;
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
/// the cache is empty, stale, or for a different account (another path, or
/// the same path rewritten in place — a rotation). The returned slice is a
/// fresh `gpa`-owned copy the caller must free: the cache entry it was
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
    // Stamp the credentials file as it is on disk right now: a rotation that
    // rewrites the file in place (gcloud's `application-default login` does)
    // must not keep serving a token minted from the old account until it
    // expires. A failed stat reads as 0, which can only force a renewal.
    const stamp = credentialsStamp(io, path) catch 0;
    if (cached_token) |tok| {
        if (cacheHit(now, expires_at, cached_for, cached_stamp, path, stamp)) return try gpa.dupe(u8, tok);
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
    cached_stamp = stamp;
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

/// Fingerprint of the credentials file (size + mtime), the same shape the
/// wasm caches use, so an in-place rotation changes the key and the next
/// call mints from the new file instead of reusing the old token.
fn credentialsStamp(io: std.Io, path: []const u8) !u64 {
    const st = try std.Io.Dir.cwd().statFile(io, path, .{});
    var h = std.hash.Wyhash.init(0x7A3C1E5F9B2D4A68);
    h.update(std.mem.asBytes(&st.size));
    // Nanoseconds as i64, not `asBytes(&st.mtime)`: `i96` is stored in 16
    // bytes whose top 4 are unspecified, so the struct form hashes
    // uninitialized stack memory and the stamp changes between calls.
    const mtime_ns: i64 = @intCast(st.mtime.nanoseconds);
    h.update(std.mem.asBytes(&mtime_ns));
    return h.final();
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

/// What one token exchange did. Kept apart from `error.VertexTokenFailed` only
/// so `postToken` can log a timeout, a transport failure and a rejecting
/// endpoint distinctly; the error the caller sees is unchanged.
const PostOutcome = union(enum) {
    /// Bytes written into the caller's response buffer.
    ok: usize,
    /// Response arrived with a >= 400 status. Never carries the body.
    status: struct { status: u16, len: usize },
    /// Transport failure, carrying `@errorName` of the cause.
    transport: []const u8,
};

/// The arguments `postTokenTask` needs, bundled so it can be handed to
/// `io.concurrent` as a single value.
const PostArgs = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    /// Caller-owned; stays alive until the task is joined or cancelled.
    out: []u8,
};

/// The fetch half of `postToken`, as a concurrent task so the caller can put a
/// deadline on it. Every exit sets `done`, or the waiter is never woken.
///
/// The client is created *here* rather than passed in: `abort` has to point at
/// a live client for the whole blocking read and at nothing once it is torn
/// down, and owning both in one scope is what makes that pairing checkable.
fn postTokenTask(args: PostArgs, abort: *client.Abort, done: *std.Io.Event) PostOutcome {
    defer done.set(args.io);

    var http: std.http.Client = .{ .allocator = args.gpa, .io = args.io };
    defer http.deinit();
    abort.arm(args.io, &http);
    defer abort.disarm(args.io);

    var w: std.Io.Writer = .fixed(args.out);
    const res = http.fetch(.{
        .location = .{ .url = args.url },
        .method = .POST,
        .payload = args.body,
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
            .user_agent = .{ .override = "clanker/" ++ build_options.version },
        },
        .response_writer = &w,
    }) catch |err| return .{ .transport = @errorName(err) };

    const status = @intFromEnum(res.status);
    if (status >= 400) return .{ .status = .{ .status = status, .len = w.end } };
    return .{ .ok = w.end };
}

/// Runs `postTokenTask` under a wall-clock ceiling, returning null when the
/// budget is spent. The abort-before-cancel ordering that unstick a wedged
/// read lives in `client.awaitTaskWithTimeout`.
///
/// A missing worker is reported as a transport failure rather than falling back
/// to an unbounded call: an ungoverned wait under `cache_mutex` is the failure
/// being prevented.
fn postWithTimeout(io: std.Io, args: PostArgs, timeout_ms: u32) ?PostOutcome {
    var abort: client.Abort = .{};
    var done: std.Io.Event = .unset;

    if (timeout_ms == 0) return postTokenTask(args, &abort, &done);

    var future = io.concurrent(postTokenTask, .{ args, &abort, &done }) catch |err|
        return .{ .transport = @errorName(err) };
    if (!client.awaitTaskWithTimeout(io, &done, &future, &abort, timeout_ms)) return null;
    return future.await(io);
}

/// Wall-clock ceiling for one token exchange.
///
/// `std.http.Client` has no read timeout of its own (`ConnectTcpOptions.timeout`
/// is declared and never referenced -- see `client.Abort`), so a token endpoint
/// that resolves, accepts the connection and then says nothing blocks the
/// calling thread forever. Unbounded here it is worse than an unbounded chat:
/// `get` holds `cache_mutex` across the whole exchange, so one wedged
/// connection parks *every* Vertex caller in the process behind it, and
/// `lockUncancelable` means none of them can be cancelled out of it either.
/// The chat call's own `request_timeout_ms` never gets a chance to fire,
/// because minting happens before the request it guards.
///
/// Ten seconds is well past a healthy OAuth exchange (the body is a few hundred
/// bytes) and well short of "never".
const token_timeout_ms: u32 = 10_000;

fn postToken(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
) !TokenReply {
    var response_buf: [16 * 1024]u8 = undefined;
    const outcome = postWithTimeout(io, .{
        .io = io,
        .gpa = gpa,
        .url = url,
        .body = body,
        .out = &response_buf,
    }, token_timeout_ms) orelse {
        log.log(.error_, "vertex: token request to '{s}' timed out after {d}ms", .{ url, token_timeout_ms });
        return error.VertexTokenFailed;
    };
    const response = switch (outcome) {
        .transport => |name| {
            log.log(.error_, "vertex: token request failed: {s}", .{name});
            return error.VertexTokenFailed;
        },
        .status => |code| {
            // The raw body from the token endpoint may mirror or include
            // sensitive credential material on some error paths. Log the status
            // and length only, never the response body, so logs cannot leak
            // secrets.
            log.log(.error_, "vertex: token endpoint returned {d} ({d} bytes)", .{ code.status, code.len });
            return error.VertexTokenFailed;
        },
        .ok => |n| response_buf[0..n],
    };
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
    cached_stamp = 0;
    expires_at = 0;
}

// ------------------------------------------------------------------- tests --

/// The renewal decision, split out so it can be tested without a network call:
/// a cached token is reused only while it belongs to this account — same
/// credentials path AND the same file it was minted from (size + mtime) — and
/// has not reached its refresh deadline (expiry minus the margin).
fn cacheHit(now: i64, expires: i64, cached_path: []const u8, cached_file_stamp: u64, want_path: []const u8, want_file_stamp: u64) bool {
    return now < expires and cached_file_stamp == want_file_stamp and std.mem.eql(u8, cached_path, want_path);
}

test "token cache renews on expiry, on a different account, and on rotated credentials" {
    const expiry = 1000 + (3600 - refresh_margin_s);

    // Fresh, same account and same file: reused.
    try std.testing.expect(cacheHit(1000, expiry, "sa.json", 11, "sa.json", 11));
    // A second before the refresh deadline: still reused.
    try std.testing.expect(cacheHit(expiry - 1, expiry, "sa.json", 11, "sa.json", 11));
    // At the deadline, five minutes before Google expires it: renewed.
    try std.testing.expect(!cacheHit(expiry, expiry, "sa.json", 11, "sa.json", 11));
    // Past it: renewed.
    try std.testing.expect(!cacheHit(expiry + 60, expiry, "sa.json", 11, "sa.json", 11));
    // Same clock, different service account: renewed rather than reused.
    try std.testing.expect(!cacheHit(1000, expiry, "sa.json", 11, "other.json", 11));
    // Credentials rotated in place: the file's stamp changed, so renewed
    // rather than serving the old account's token until it expires.
    try std.testing.expect(!cacheHit(1000, expiry, "sa.json", 11, "sa.json", 12));
    // Cold start (deinit or first call): renewed.
    try std.testing.expect(!cacheHit(1000, 0, "", 0, "sa.json", 11));
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

test "postWithTimeout gives up on a token endpoint that accepts and never answers" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The failure this exists to prevent: a token endpoint that resolves,
    // completes the TCP handshake, and then sends nothing. The kernel's backlog
    // accepts for us, so `fetch` gets a live connection and blocks in a read
    // that no amount of `Io.Future.cancel` can rescue. Unbounded, this call is
    // made under `cache_mutex` via `lockUncancelable`, so it parks every other
    // Vertex caller in the process behind it for good.
    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/token", .{port});

    var out: [1024]u8 = undefined;
    const started = std.Io.Timestamp.now(io, .awake);
    const outcome = postWithTimeout(io, .{
        .io = io,
        .gpa = allocator,
        .url = url,
        .body = "grant_type=refresh_token",
        .out = &out,
    }, 300);
    const elapsed_ms = @divTrunc(started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds, std.time.ns_per_ms);

    // Null is the timeout, and it has to arrive on the budget rather than on
    // the OS connect timeout (~75s) an unbounded caller waits out.
    try std.testing.expect(outcome == null);
    try std.testing.expect(elapsed_ms < 30_000);
}
