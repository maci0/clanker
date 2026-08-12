//! The `Provider` vtable: the interface every provider file implements, and
//! the neutral data types that cross it.
//!
//! Per [ADR 0004](../../../docs/adrs/0004-providers-are-a-native-vtable-not-wasm.md)
//! a provider is a struct of native function pointers, not a WASM module: the
//! API key must not enter the sandbox, and the transport is on the per-token
//! hot path. Each provider groups its three concerns — wire codec, auth
//! strategy, transport quirks — in one file; the shared HTTP/SSE/retry/
//! token-counting core stays a single module (`../client.zig`).
//!
//! Nothing in here does I/O or touches a credential's source: `buildRequest`,
//! `parseResponse`, `parseErrorDetail` and `parseStreamEvent` are pure
//! functions of their inputs, which is what makes each provider's codec
//! unit-testable on the host with no server and no key.

const std = @import("std");
const types = @import("../types.zig");
const config = @import("../../config.zig");
const auth = @import("../auth.zig");

pub const RequestParams = struct {
    provider: *const config.Provider,
    messages: []const types.Message,
    tools: ?[]const types.ToolDef = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    max_tokens: ?u32 = null,
    response_format_json: bool = false,
    /// Ask the provider to stream the response (SSE). Consumed by
    /// client.chatStream, which parses the chunked deltas.
    stream: bool = false,
};

pub const BuildError = error{OutOfMemory} || std.Io.Writer.Error;

/// How many `extra_headers` slots a provider's `authHeaders` may fill.
/// Anthropic uses both (an auth header plus `anthropic-version`).
pub const max_extra_headers = 2;

pub const ExtraHeaders = [max_extra_headers]std.http.Header;

/// One tool-call fragment from a stream frame, addressed by block index.
/// Fields absent from this frame are null; the core accumulates across frames.
pub const ToolCallFragment = struct {
    index: usize,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
};

/// The prompt-token half of a usage report. Providers hand it over as a group
/// because the three numbers are only meaningful together: a frame that
/// reports fresh input tokens and no cache read means "zero cache hits", not
/// "cache hits unchanged".
pub const PromptUsage = struct {
    tokens: u32 = 0,
    cache_hit_tokens: u32 = 0,
    cache_miss_tokens: u32 = 0,
};

/// A usage report carried by one stream frame. Null fields are "this frame
/// says nothing about that", so the OpenAI shape (one complete snapshot in the
/// final chunk) and the Anthropic shape (input at `message_start`, output at
/// `message_delta`) both fold through the same accumulator.
pub const UsageUpdate = struct {
    prompt: ?PromptUsage = null,
    completion: ?u32 = null,
    /// An authoritative total from the provider. When null the core derives
    /// prompt + completion.
    total: ?u32 = null,

    /// Folds this update into the running total.
    pub fn apply(self: UsageUpdate, acc: *types.Usage) void {
        if (self.prompt) |p| {
            acc.prompt_tokens = p.tokens;
            acc.prompt_cache_hit_tokens = p.cache_hit_tokens;
            acc.prompt_cache_miss_tokens = p.cache_miss_tokens;
        }
        if (self.completion) |c| acc.completion_tokens = c;
        acc.total_tokens = self.total orelse (acc.prompt_tokens + acc.completion_tokens);
    }
};

/// What one SSE frame contributed, in terms the shared core understands.
/// Returning this instead of mutating the core's accumulators is what keeps
/// `parseStreamEvent` a pure function.
pub const StreamEvent = struct {
    /// Content delta to append and hand to `on_delta`.
    text: ?[]const u8 = null,
    tool_calls: []const ToolCallFragment = &.{},
    usage: ?UsageUpdate = null,
    finish_reason: ?[]const u8 = null,
    /// The provider says the stream is over (OpenAI's `[DONE]` sentinel).
    done: bool = false,
};

pub const StreamParseError = error{OutOfMemory};

/// One provider. Registered in `../providers.zig`; adding a provider is this
/// struct filled in by one new file plus one row in that table.
pub const Provider = struct {
    /// The `kind = "..."` this entry serves. One entry per kind.
    kind: config.ProviderKind,

    /// How this provider's credential is acquired (ADR 0005). The wire kind
    /// and the auth strategy are separate axes: a provider offering both an
    /// API key and OAuth carries the second here, not as a second kind.
    auth: auth.Spec = .{},

    // -- wire codec: pure, no I/O, no credentials ---------------------------

    /// Serializes a request body into a newly allocated buffer (caller frees).
    buildRequest: *const fn (gpa: std.mem.Allocator, params: RequestParams) BuildError![]u8,

    /// Parses a complete (non-streaming) response body. Slices in the result
    /// may point into `body`, which must outlive it, or into `arena`.
    parseResponse: *const fn (
        arena: std.mem.Allocator,
        body: []const u8,
        err_detail: ?*?[]const u8,
    ) anyerror!types.ChatResponse,

    /// Best-effort extraction of the provider's own error message from an
    /// error body, so an HTTP failure reports a sentence rather than a status.
    parseErrorDetail: *const fn (arena: std.mem.Allocator, body: []const u8) ?[]const u8,

    /// Parses one SSE `data:` payload. Null means "ignore this frame"
    /// (unknown event type, or unparseable — the core logs the byte count).
    /// Returned slices may point into `chunk_arena` or into `payload`; the
    /// core copies out everything it keeps before either is reused.
    parseStreamEvent: *const fn (
        chunk_arena: std.mem.Allocator,
        payload: []const u8,
    ) StreamParseError!?StreamEvent,

    // -- transport quirks ---------------------------------------------------

    /// Applies the resolved credential to the request, returning how many
    /// `extra` slots were filled. Header *application* is a per-wire-kind
    /// detail; where the credential came from is `auth` above.
    authHeaders: *const fn (
        cred: auth.Credential,
        headers: *std.http.Client.Request.Headers,
        extra: *ExtraHeaders,
    ) usize,

    /// Builds the request URL. `streaming` matters where the endpoint differs
    /// by verb rather than by a body flag (Vertex's `:streamRawPredict`).
    endpointUrl: *const fn (
        gpa: std.mem.Allocator,
        provider: *const config.Provider,
        streaming: bool,
    ) anyerror![]u8,
};

// ------------------------------------------------------------------- tests --

test "a usage update leaves untouched halves alone and derives the total" {
    var acc: types.Usage = .{};

    // Anthropic's message_start: prompt side only.
    (UsageUpdate{ .prompt = .{ .tokens = 480, .cache_hit_tokens = 8, .cache_miss_tokens = 472 } }).apply(&acc);
    try std.testing.expectEqual(@as(u32, 480), acc.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 0), acc.completion_tokens);
    try std.testing.expectEqual(@as(u32, 480), acc.total_tokens);

    // Anthropic's message_delta: output only, prompt survives.
    (UsageUpdate{ .completion = 89 }).apply(&acc);
    try std.testing.expectEqual(@as(u32, 480), acc.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 8), acc.prompt_cache_hit_tokens);
    try std.testing.expectEqual(@as(u32, 89), acc.completion_tokens);
    try std.testing.expectEqual(@as(u32, 569), acc.total_tokens);
}

test "a provider-reported total wins over prompt + completion" {
    var acc: types.Usage = .{};
    (UsageUpdate{
        .prompt = .{ .tokens = 10 },
        .completion = 4,
        .total = 99,
    }).apply(&acc);
    try std.testing.expectEqual(@as(u32, 99), acc.total_tokens);
}
