//! Credential acquisition, the auth axis of the provider vtable.
//!
//! Per [ADR 0005](../../docs/adrs/0005-auth-is-a-strategy-axis-separate-from-wire-kind.md),
//! auth is not one-per-wire-kind: a provider can offer an API key *and* OAuth
//! over the same wire format. Two concerns are separated here:
//!
//!  1. **Credential acquisition** (this module), where the secret comes from:
//!     an env var, a pasted OAuth access token, or a token minted and renewed
//!     in-process. That is the `Strategy`.
//!  2. **Header application**, how the resolved credential rides the request
//!     (`Authorization: Bearer` vs `x-api-key`, plus any beta header). That is
//!     a per-wire-kind detail and lives in each provider's `authHeaders`.
//!
//! Everything here stays native: the token is a secret, and resolving or
//! minting it is exactly what the WASM sandbox withholds from guests
//! (ADR 0004).

const std = @import("std");
const config = @import("../config.zig");
const log = @import("../util/log.zig");

pub const Strategy = config.AuthStrategy;

/// The slice of `client.Ctx` credential resolution needs. Kept as its own
/// struct so this module does not import the client (which imports the
/// provider registry, which imports this).
pub const Env = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
};

/// How one wire kind acquires its credential. Declared by each provider in
/// its registry entry; the strategy itself is the axis, not the kind.
pub const Spec = struct {
    /// Strategy when neither the config nor `detect` says otherwise.
    default: Strategy = .api_key,
    /// Recognizes an OAuth access token by its shape, so a provider whose two
    /// credential types are distinguishable (Anthropic's `sk-ant-oat…`) keeps
    /// working with no config. Null means they are indistinguishable, and the
    /// explicit `auth = "..."` field is the only way to select OAuth: the
    /// default must fail loudly rather than guess wrong and send a token on
    /// the wrong header.
    detect: ?*const fn (credential: []const u8) Strategy = null,
    /// Mints and renews an access token in-process. Only consulted for
    /// `.oauth_refresh`; Vertex's GCP token is the one instance today.
    mint: ?*const fn (env: Env, provider: *const config.Provider) anyerror![]const u8 = null,
    /// The provider cannot work without a credential, even with no
    /// `api_key_env` configured (Vertex, which can be served by
    /// `service_account_file` or gcloud ADC instead).
    required: bool = false,
    /// When true, `Credential.quota_project` is `provider.project` (Vertex
    /// user ADC's `x-goog-user-project`). A Spec field, not a kind switch.
    quota_from_project: bool = false,
    /// The provider addresses the model in a URL built from `project` and
    /// `location` (Vertex). Config must require both at load, instead of a
    /// provider failing on the first request with VertexProjectMissing. A
    /// Spec field, not a `kind ==` check outside the provider files.
    needs_project_location: bool = false,
    /// The credential may come from a local file (`service_account_file` or
    /// gcloud ADC) resolved by `vertex_token`, not only an env var. Doctor
    /// reads this to know where to look when no `api_key_env` is configured.
    /// A Spec field, not a `kind ==` check outside the provider files.
    file_credential: bool = false,
};

/// A resolved credential, ready to be turned into headers.
pub const Credential = struct {
    /// The raw secret, or null when the provider is configured without one
    /// (a keyless local endpoint).
    value: ?[]const u8 = null,
    /// `value` pre-wrapped as an `Authorization` header value. Built once here
    /// so a provider's `authHeaders` never has to allocate.
    bearer: ?[]const u8 = null,
    /// How `value` was acquired. `authHeaders` reads this to decide between
    /// `x-api-key` and `Bearer` where a wire kind accepts both.
    strategy: Strategy = .api_key,
    /// True when `value` was minted here rather than borrowed from the
    /// environment, and so must be freed with the bearer.
    owns_value: bool = false,
    /// Vertex user ADC needs a billing project on the request
    /// (`x-goog-user-project`). Borrowed from `provider.project`; not owned.
    quota_project: []const u8 = "",

    pub fn deinit(self: Credential, gpa: std.mem.Allocator) void {
        if (self.bearer) |b| gpa.free(b);
        if (self.owns_value) if (self.value) |v| gpa.free(v);
    }
};

/// Picks the strategy for this request: an explicit `auth = "..."` in config
/// wins, then minting when the provider is configured for it and no static
/// credential is present, then the credential's own shape, then the wire
/// kind's default.
pub fn selectStrategy(spec: Spec, provider: *const config.Provider, raw: ?[]const u8) Strategy {
    if (provider.auth) |explicit| return explicit;
    // An env var still wins over minting: a short-lived token pasted in by
    // hand is the documented way to bypass the service account or ADC.
    // The file itself is resolved at mint time (explicit path, then
    // GOOGLE_APPLICATION_CREDENTIALS, then gcloud's well-known ADC).
    if (raw == null and spec.mint != null) return .oauth_refresh;
    if (raw) |k| if (spec.detect) |detect| return detect(k);
    return spec.default;
}

/// Resolves the provider's credential into a ready-to-send form. The caller
/// owns the result and must `deinit` it.
pub fn resolve(env: Env, spec: Spec, provider: *const config.Provider) !Credential {
    const raw: ?[]const u8 = if (provider.api_key_env) |env_name|
        env.environ_map.get(env_name)
    else
        null;
    const strategy = selectStrategy(spec, provider, raw);

    if (strategy == .oauth_refresh and raw == null) {
        const mint = spec.mint orelse {
            log.log(.error_, "provider '{s}': auth \"oauth_refresh\" is not supported by kind \"{s}\"", .{
                provider.name,
                @tagName(provider.kind),
            });
            return error.UnsupportedAuthStrategy;
        };
        const tok = try mint(env, provider);
        errdefer env.gpa.free(tok);
        return .{
            .value = tok,
            .bearer = try std.fmt.allocPrint(env.gpa, "Bearer {s}", .{tok}),
            .strategy = strategy,
            .owns_value = true,
            .quota_project = quotaProject(spec, provider),
        };
    }

    if (raw == null and (provider.api_key_env != null or spec.required)) {
        log.log(.error_, "no credential for provider '{s}': set {s}, service_account_file, or gcloud ADC", .{
            provider.name,
            provider.api_key_env orelse "an API key env var",
        });
        return error.MissingApiKey;
    }
    if (raw) |k| return .{
        .value = k,
        .bearer = try std.fmt.allocPrint(env.gpa, "Bearer {s}", .{k}),
        .strategy = strategy,
        .quota_project = quotaProject(spec, provider),
    };
    return .{ .strategy = strategy, .quota_project = quotaProject(spec, provider) };
}

fn quotaProject(spec: Spec, provider: *const config.Provider) []const u8 {
    return if (spec.quota_from_project) provider.project else "";
}

// ------------------------------------------------------------------- tests --

test "an explicit auth field overrides credential-shape detection" {
    const Detect = struct {
        fn f(_: []const u8) Strategy {
            return .oauth_static;
        }
    };
    const spec = Spec{ .detect = &Detect.f };
    var p = config.Provider{ .name = "p", .base_url = "https://x", .default_model = "m" };

    try std.testing.expectEqual(Strategy.oauth_static, selectStrategy(spec, &p, "whatever"));
    p.auth = .api_key;
    try std.testing.expectEqual(Strategy.api_key, selectStrategy(spec, &p, "whatever"));
}

test "minting is selected only when no static credential is present" {
    const Mint = struct {
        fn f(_: Env, _: *const config.Provider) anyerror![]const u8 {
            return error.NotCalled;
        }
    };
    const spec = Spec{ .mint = &Mint.f, .required = true };
    var p = config.Provider{ .name = "v", .base_url = "", .default_model = "m" };

    try std.testing.expectEqual(Strategy.oauth_refresh, selectStrategy(spec, &p, null));
    // A pasted token wins over minting (service account or ADC).
    try std.testing.expectEqual(Strategy.api_key, selectStrategy(spec, &p, "ya29.token"));
}

test "a provider with no credential source at all resolves to no credential" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const env = Env{ .io = threaded.io(), .gpa = std.testing.allocator, .environ_map = &env_map };

    const p = config.Provider{ .name = "local", .base_url = "http://127.0.0.1:11434/v1", .default_model = "m" };
    const cred = try resolve(env, .{}, &p);
    defer cred.deinit(std.testing.allocator);
    try std.testing.expect(cred.value == null);
    try std.testing.expect(cred.bearer == null);
}

test "a configured api_key_env with nothing in the environment fails loudly" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const env = Env{ .io = threaded.io(), .gpa = std.testing.allocator, .environ_map = &env_map };

    var p = config.Provider{ .name = "remote", .base_url = "https://x", .default_model = "m" };
    p.api_key_env = "DEFINITELY_UNSET_KEY_FOR_TEST";
    try std.testing.expectError(error.MissingApiKey, resolve(env, .{}, &p));
}

test "a resolved key is wrapped as a bearer value once" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("TEST_KEY", "secret-1");
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const env = Env{ .io = threaded.io(), .gpa = std.testing.allocator, .environ_map = &env_map };

    var p = config.Provider{ .name = "remote", .base_url = "https://x", .default_model = "m" };
    p.api_key_env = "TEST_KEY";
    const cred = try resolve(env, .{}, &p);
    defer cred.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("secret-1", cred.value.?);
    try std.testing.expectEqualStrings("Bearer secret-1", cred.bearer.?);
    try std.testing.expectEqual(Strategy.api_key, cred.strategy);
}

test "oauth_refresh on a kind that cannot mint is rejected, not silently downgraded" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const env = Env{ .io = threaded.io(), .gpa = std.testing.allocator, .environ_map = &env_map };

    var p = config.Provider{ .name = "x", .base_url = "https://x", .default_model = "m" };
    p.auth = .oauth_refresh;
    try std.testing.expectError(error.UnsupportedAuthStrategy, resolve(env, .{}, &p));
}

test "quota_project is a Spec field, not a kind switch" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("TEST_KEY", "secret-1");
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const env = Env{ .io = threaded.io(), .gpa = std.testing.allocator, .environ_map = &env_map };

    var p = config.Provider{ .name = "v", .base_url = "https://x", .default_model = "m", .project = "my-gcp" };
    p.api_key_env = "TEST_KEY";
    const with_quota = try resolve(env, .{ .quota_from_project = true }, &p);
    defer with_quota.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("my-gcp", with_quota.quota_project);

    const without = try resolve(env, .{}, &p);
    defer without.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", without.quota_project);
}
