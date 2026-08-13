//! The shared transport core for LLM chat completions: HTTP, SSE framing,
//! retry/backoff, streaming accumulation and token accounting.
//!
//! Deliberately one module, not one per provider. Everything that differs
//! between providers (the wire codec, the auth headers, the endpoint URL)
//! is reached through the `providers.Provider` vtable resolved once per call,
//! so this file contains no `switch (provider.kind)` at all. See
//! [ADR 0004](../../docs/adrs/0004-providers-are-a-native-vtable-not-wasm.md).

const std = @import("std");
const types = @import("types.zig");
const providers = @import("providers.zig");
const auth = @import("auth.zig");
const config = @import("../config.zig");
const log = @import("../util/log.zig");
const token_stats = @import("../stats/tokens.zig");
const build_options = @import("build_options");

/// Reported to providers as the `User-Agent` header. Built from
/// build.zig.zon's `.version` so it can never drift from a hand-copied
/// literal.
const user_agent = "clanker/" ++ build_options.version;

/// Ceiling on the tool-call block index a stream frame may address. Both the
/// OpenAI and Anthropic event shapes carry this as a bare `usize` straight
/// from the wire; a malformed or hostile response with `index: 999999999`
/// used to grow `call_args`/`call_ids`/`call_names` one element at a time up
/// to that value, which is an unbounded allocation from an attacker-chosen
/// number rather than an actual block count.
const max_tool_call_slots: usize = 256;

pub const Ctx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    /// Effective config, when the caller has one. Enables global token-usage
    /// recording (modules.token_stats); null callers (e.g. a provider ping)
    /// simply don't record.
    cfg: ?*const config.Config = null,

    /// The slice of this context credential resolution needs.
    fn authEnv(self: *Ctx) auth.Env {
        return .{ .io = self.io, .gpa = self.gpa, .environ_map = self.environ_map };
    }
};

/// Response body cap for chat completions (8 MiB).
const resp_cap = 8 << 20;
const max_attempts = 3;

/// Process-local RED counters for LLM calls. Cardinality is zero (no
/// provider/model labels) so a busy loop cannot blow a time-series store;
/// per-provider detail lives in token_stats.jsonl and the correlated logs.
var llm_requests_total = std.atomic.Value(u64).init(0);
var llm_errors_total = std.atomic.Value(u64).init(0);
var llm_retries_total = std.atomic.Value(u64).init(0);

pub const LlmMetrics = struct {
    requests_total: u64,
    errors_total: u64,
    retries_total: u64,
};

pub fn snapshotMetrics() LlmMetrics {
    return .{
        .requests_total = llm_requests_total.load(.monotonic),
        .errors_total = llm_errors_total.load(.monotonic),
        .retries_total = llm_retries_total.load(.monotonic),
    };
}

fn noteRequest() void {
    _ = llm_requests_total.fetchAdd(1, .monotonic);
}

fn noteRetry() void {
    _ = llm_retries_total.fetchAdd(1, .monotonic);
}

fn noteError() void {
    _ = llm_errors_total.fetchAdd(1, .monotonic);
}

/// Appends provider-controlled bytes without allowing a malformed response to
/// grow a process-owned buffer indefinitely. The caller chooses whether the
/// limit applies to a complete body or to one protocol frame.
fn appendResponseBytes(list: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: []const u8, limit: usize) !void {
    if (bytes.len > limit -| list.items.len) return error.ResponseTooLarge;
    try list.appendSlice(gpa, bytes);
}

/// Appends one decoded streaming fragment while bounding the complete
/// assistant response, including text and tool arguments across all slots.
fn appendStreamBytes(list: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: []const u8, total: *usize) !void {
    if (bytes.len > resp_cap -| total.*) return error.ResponseTooLarge;
    try list.appendSlice(gpa, bytes);
    total.* += bytes.len;
}

const FetchOutcome = struct {
    status: std.http.Status,
    /// Response body (gpa-owned).
    body: []u8,
};

/// The request headers every provider gets, before its own auth is applied.
fn baseHeaders() std.http.Client.Request.Headers {
    return .{
        .content_type = .{ .override = "application/json" },
        .user_agent = .{ .override = user_agent },
    };
}

pub fn chat(
    ctx: *Ctx,
    arena: std.mem.Allocator,
    params: providers.RequestParams,
    err_detail: *?[]const u8,
) !types.ChatResponse {
    const provider = params.provider;
    const impl = providers.forKind(provider.kind);
    const llm_t0 = std.Io.Timestamp.now(ctx.io, .awake);

    const cred = try auth.resolve(ctx.authEnv(), impl.auth, provider);
    defer cred.deinit(ctx.gpa);

    const body = try impl.buildRequest(ctx.gpa, params);
    defer ctx.gpa.free(body);

    const url = try impl.endpointUrl(ctx.gpa, provider, false);
    defer ctx.gpa.free(url);

    var client: std.http.Client = .{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();

    noteRequest();
    var attempt: u32 = 0;
    var outcome: FetchOutcome = undefined;
    while (true) {
        attempt += 1;
        outcome = doFetch(ctx, &client, url, body, cred, impl, provider, arena, err_detail) catch |err| {
            if (attempt < max_attempts and isRetryableTransport(err)) {
                noteRetry();
                try sleepRetry(ctx.io, attempt, provider.name, 0, @errorName(err));
                continue;
            }
            log.log(.error_, "request to '{s}' failed: {s} (attempt {d}/{d})", .{
                provider.name, @errorName(err), attempt, max_attempts,
            });
            noteError();
            recordFailure(ctx, arena, provider, 0, @errorName(err), elapsedMs(ctx.io, llm_t0));
            return err;
        };
        if (isRetryable(outcome.status) and attempt < max_attempts) {
            noteRetry();
            const delay = retryDelayNs(ctx.io, attempt);
            log.log(.warn, "HTTP {d} from '{s}', retrying in {d}ms (attempt {d}/{d})", .{ @intFromEnum(outcome.status), provider.name, delay / std.time.ns_per_ms, attempt, max_attempts });
            ctx.gpa.free(outcome.body);
            // A cancellation during the backoff sleep must abort the retry,
            // not fall through and hammer the provider immediately with no
            // delay at all.
            try std.Io.sleep(ctx.io, .{ .nanoseconds = @intCast(delay) }, .awake);
            continue;
        }
        break;
    }
    defer ctx.gpa.free(outcome.body);

    if (@intFromEnum(outcome.status) >= 400) {
        if (err_detail.* == null) {
            err_detail.* = try arena.dupe(u8, outcome.body);
        }
        log.log(.error_, "provider '{s}' returned HTTP {d} after {d} attempt(s): {s}", .{
            provider.name, @intFromEnum(outcome.status), attempt, err_detail.* orelse "",
        });
        noteError();
        recordFailure(ctx, arena, provider, @intFromEnum(outcome.status), err_detail.* orelse "ApiError", elapsedMs(ctx.io, llm_t0));
        return error.ApiError;
    }

    // Parse from an arena copy: the parsers keep slices into the body (and the
    // response carries `raw`), while `outcome.body` is gpa-owned and freed on
    // the way out of this function.
    const body_owned = try arena.dupe(u8, outcome.body);
    // err_detail goes in here: a 200 carrying an error body never passes the
    // HTTP error path in doFetch, so without this the caller only sees a bare
    // error.ApiError with no idea what the provider said.
    const resp = impl.parseResponse(arena, body_owned, err_detail) catch |err| {
        log.log(.error_, "provider '{s}' returned an unreadable response: {s} ({s})", .{
            provider.name, @errorName(err), err_detail.* orelse "",
        });
        noteError();
        recordFailure(ctx, arena, provider, @intFromEnum(outcome.status), err_detail.* orelse @errorName(err), elapsedMs(ctx.io, llm_t0));
        return err;
    };
    const ms: u64 = @intCast(@divTrunc(llm_t0.durationTo(std.Io.Timestamp.now(ctx.io, .awake)).nanoseconds, std.time.ns_per_ms));
    recordUsage(ctx, arena, provider, resp.usage, ms);
    return resp;
}

/// Input-token cost, discounting the prefix served from the prompt cache: a
/// cache read bills at about a tenth of the input rate, so charging every
/// prompt token at full price overstates a cached run's cost by ~10x on the
/// cached span.
pub fn promptCost(u: types.Usage, per_1m_input: f64) f64 {
    const hit: f64 = @floatFromInt(u.prompt_cache_hit_tokens);
    const uncached: f64 = @floatFromInt(u.prompt_tokens - @min(u.prompt_cache_hit_tokens, u.prompt_tokens));
    return (uncached + hit * 0.1) / 1_000_000.0 * per_1m_input;
}

/// Total estimated cost (input + output) for a single completion, using the
/// provider's active model pricing. Returns 0 when pricing info is absent.
/// Public so CLI status bars and other callers can reuse the same math.
pub fn totalCost(provider: *const config.Provider, u: types.Usage) f64 {
    const active = provider.activeModel();
    var cost: f64 = 0;
    if (active.cost_per_1m_input) |ci| cost += promptCost(u, ci);
    if (active.cost_per_1m_output) |co| cost += @as(f64, @floatFromInt(u.completion_tokens)) / 1_000_000.0 * co;
    return cost;
}

/// Running per-session totals behind the REPL status line: one add() per turn
/// where the turn's resp.usage is consumed, and the composed line reads the
/// fields directly. Cost uses totalCost so the number matches the token-stats
/// log instead of drifting into a second pricing formula.
pub const SessionUsage = struct {
    prompt: u64 = 0,
    completion: u64 = 0,
    cache_hit: u64 = 0,
    cost: f64 = 0,

    pub fn add(self: *SessionUsage, provider: *const config.Provider, u: types.Usage) void {
        self.prompt += u.prompt_tokens;
        self.completion += u.completion_tokens;
        self.cache_hit += u.prompt_cache_hit_tokens;
        self.cost += totalCost(provider, u);
    }

    /// Cached share of all prompt tokens, 0-100; 0 before the first turn.
    pub fn cachePct(self: SessionUsage) u8 {
        if (self.prompt == 0) return 0;
        return @intCast(@min(self.cache_hit, self.prompt) * 100 / self.prompt);
    }

    /// The built-in status-line segment: `provider/model · ↑in ↓out tok · $cost · cache pct%`.
    /// Statusline tool segments are appended after this by the caller (the REPL),
    /// which owns the registry and the sandbox; this type only knows the totals.
    pub fn writeSegment(self: SessionUsage, w: *std.Io.Writer, provider: *const config.Provider) !void {
        try w.print("{s}/{s} · ↑{d} ↓{d} tok · ${d:.4} · cache {d}%", .{
            provider.name,
            provider.activeModelName(),
            self.prompt,
            self.completion,
            self.cost,
            self.cachePct(),
        });
    }
};

/// Records one completion in the global token-usage log (best-effort). The
/// caller supplies `duration_ms`; 0 means "unknown" (chat() times the whole
/// call via `llm_t0` where the retry loop hides the true duration).
fn recordUsage(ctx: *Ctx, arena: std.mem.Allocator, provider: *const config.Provider, usage: ?types.Usage, duration_ms: u64) void {
    const cfg = ctx.cfg orelse return;
    if (!cfg.modules.token_stats) return;
    const u = usage orelse return;
    if (u.total_tokens == 0 and u.prompt_tokens == 0 and u.completion_tokens == 0) return;

    const cost = totalCost(provider, u);

    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(ctx.io, .real).nanoseconds, 1_000_000_000));
    token_stats.append(std.Io.Dir.cwd(), ctx.io, ctx.gpa, arena, cfg.agent.state_dir, .{
        .ts = ts,
        .provider = provider.name,
        .model = provider.activeModelName(),
        .prompt_tokens = u.prompt_tokens,
        .completion_tokens = u.completion_tokens,
        .total_tokens = u.total_tokens,
        .cache_hit = u.prompt_cache_hit_tokens,
        .cache_miss = u.prompt_cache_miss_tokens,
        .cost = cost,
        .duration_ms = duration_ms,
        .ok = true,
        .request_id = log.getContext(),
    });
}

/// Records a completion that never produced usage: the operator question at
/// 3 AM is "is the provider failing?", and a log of only successes cannot
/// answer it. Tokens stay zero; `err` is a name or a parsed provider
/// message, never the raw body.
fn recordFailure(
    ctx: *Ctx,
    arena: std.mem.Allocator,
    provider: *const config.Provider,
    http_status: u16,
    err_name: []const u8,
    duration_ms: u64,
) void {
    const cfg = ctx.cfg orelse return;
    if (!cfg.modules.token_stats) return;

    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(ctx.io, .real).nanoseconds, 1_000_000_000));
    token_stats.append(std.Io.Dir.cwd(), ctx.io, ctx.gpa, arena, cfg.agent.state_dir, .{
        .ts = ts,
        .provider = provider.name,
        .model = provider.activeModelName(),
        .prompt_tokens = 0,
        .completion_tokens = 0,
        .total_tokens = 0,
        .cache_hit = 0,
        .cache_miss = 0,
        .cost = 0,
        .duration_ms = duration_ms,
        .ok = false,
        .http_status = http_status,
        .err = err_name,
        .request_id = log.getContext(),
    });
}

fn elapsedMs(io: std.Io, started: std.Io.Timestamp) u64 {
    const ns = started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    return @intCast(@max(0, @divTrunc(ns, std.time.ns_per_ms)));
}

fn retryDelayNs(io: std.Io, attempt: u32) u64 {
    const base: u64 = @as(u64, attempt) * std.time.ns_per_s;
    const jitter: u64 = @intCast(@mod(std.Io.Timestamp.now(io, .awake).nanoseconds, 500_000_000));
    return base + jitter;
}

fn sleepRetry(io: std.Io, attempt: u32, provider_name: []const u8, http_status: u16, reason: []const u8) !void {
    const delay = retryDelayNs(io, attempt);
    if (http_status == 0) {
        log.log(.warn, "request to '{s}' failed: {s}, retrying in {d}ms (attempt {d}/{d})", .{
            provider_name, reason, delay / std.time.ns_per_ms, attempt, max_attempts,
        });
    } else {
        log.log(.warn, "HTTP {d} from '{s}', retrying in {d}ms (attempt {d}/{d})", .{
            http_status, provider_name, delay / std.time.ns_per_ms, attempt, max_attempts,
        });
    }
    try std.Io.sleep(io, .{ .nanoseconds = @intCast(delay) }, .awake);
}

fn doFetch(
    ctx: *Ctx,
    client: *std.http.Client,
    url: []const u8,
    body: []const u8,
    cred: auth.Credential,
    impl: *const providers.Provider,
    provider: *const config.Provider,
    arena: std.mem.Allocator,
    err_detail: *?[]const u8,
) !FetchOutcome {
    const resp_buf = try ctx.gpa.alloc(u8, resp_cap);
    defer ctx.gpa.free(resp_buf);
    var w: std.Io.Writer = .fixed(resp_buf);

    var headers = baseHeaders();
    var extra: providers.ExtraHeaders = undefined;
    const extra_len = impl.authHeaders(cred, &headers, &extra);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .headers = headers,
        .extra_headers = extra[0..extra_len],
        .response_writer = &w,
    }) catch |err| {
        // The retry loop in chat() owns the operator-visible log line so a
        // transient blip is one warn and a terminal failure is one error,
        // not a debug line that vanishes at the default level.
        err_detail.* = std.fmt.allocPrint(arena, "couldn't reach '{s}' ({s})", .{ provider.name, @errorName(err) }) catch null;
        return err;
    };

    const response: []const u8 = resp_buf[0..w.end];

    if (@intFromEnum(result.status) >= 400) {
        if (impl.parseErrorDetail(arena, response)) |msg| {
            err_detail.* = try std.fmt.allocPrint(arena, "HTTP {d}: {s}", .{ @intFromEnum(result.status), msg });
        } else {
            err_detail.* = try std.fmt.allocPrint(arena, "HTTP {d}", .{@intFromEnum(result.status)});
        }
        log.log(.debug, "provider '{s}' returned {s}", .{ provider.name, err_detail.*.? });
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
    stop_flag: ?*std.atomic.Value(bool),
) !types.ChatResponse {
    const provider = params.provider;
    const impl = providers.forKind(provider.kind);
    const llm_t0 = std.Io.Timestamp.now(ctx.io, .awake);

    const cred = try auth.resolve(ctx.authEnv(), impl.auth, provider);
    defer cred.deinit(ctx.gpa);

    var p = params;
    p.stream = true;
    const body = try impl.buildRequest(ctx.gpa, p);
    defer ctx.gpa.free(body);

    const url = try impl.endpointUrl(ctx.gpa, provider, true);
    defer ctx.gpa.free(url);

    var client: std.http.Client = .{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();

    noteRequest();

    var headers = baseHeaders();
    var extra: providers.ExtraHeaders = undefined;
    const extra_len = impl.authHeaders(cred, &headers, &extra);

    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var req = try client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .headers = headers,
        .extra_headers = extra[0..extra_len],
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    // Request bodies contain the complete conversation, tool output, and
    // attachments. Debugging must never copy that user data into terminal or
    // CI logs; the byte count is enough to diagnose framing problems.
    if (ctx.environ_map.get("CLANKER_DEBUG_BODY") != null) {
        log.log(.debug, "LLM streaming request provider={s} bytes={d}", .{ provider.name, body.len });
    }
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(body);
    try body_writer.end();
    try req.connection.?.flush();

    var redirect_buffer: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    if (@intFromEnum(response.head.status) >= 400) {
        // The client advertises gzip, and providers compress error bodies too:
        // the raw reader hands back binary, so the one line that says what is
        // wrong with the request arrives as garbage. Decompress it like the
        // success path does (a no-op on identity-encoded bodies).
        var err_transfer_buffer: [8192]u8 = undefined;
        var err_decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var err_decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&err_transfer_buffer, &err_decompress, &err_decompress_buffer);
        var ebuf: [16384]u8 = undefined;
        var err_body: std.ArrayList(u8) = .empty;
        defer err_body.deinit(ctx.gpa);
        while (true) {
            const n = reader.readSliceShort(&ebuf) catch break;
            if (n == 0) break;
            appendResponseBytes(&err_body, ctx.gpa, ebuf[0..n], resp_cap) catch |err| switch (err) {
                error.ResponseTooLarge => return err,
                else => break,
            };
        }
        // Provider error bodies can echo prompts or upstream credentials.
        // Extract only the provider's documented error message, matching the
        // non-streaming path, and never surface the complete raw body.
        if (impl.parseErrorDetail(arena, err_body.items)) |msg| {
            err_detail.* = try std.fmt.allocPrint(arena, "HTTP {d}: {s}", .{ @intFromEnum(response.head.status), msg });
        } else {
            err_detail.* = try std.fmt.allocPrint(arena, "HTTP {d}", .{@intFromEnum(response.head.status)});
        }
        log.log(.error_, "provider '{s}' stream returned {s}", .{ provider.name, err_detail.*.? });
        noteError();
        recordFailure(ctx, arena, provider, @intFromEnum(response.head.status), err_detail.*.?, elapsedMs(ctx.io, llm_t0));
        return error.ApiError;
    }

    var chunk_arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer chunk_arena_state.deinit();
    const chunk_arena = chunk_arena_state.allocator();

    var acc = StreamAccumulator{ .gpa = ctx.gpa, .arena = arena };
    defer acc.deinit();

    // std.http.Client advertises gzip, and Vertex takes it up on the SSE
    // stream: a raw reader would hand back compressed bytes and every frame
    // would silently fail to parse. The decompressing reader is a no-op when
    // the response is identity-encoded, so it is correct for both.
    var transfer_buffer: [8192]u8 = undefined;
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);
    var buf: [8192]u8 = undefined;
    var sse: std.ArrayList(u8) = .empty;
    defer sse.deinit(ctx.gpa);
    var sse_done = false;
    var at_eof = false;
    while (!sse_done) {
        // A peek, not a consuming swap: Agent.stopRequested() is the one
        // place that consumes the flag, so a Ctrl-C caught here still gets
        // cleared correctly by the caller's catch block below.
        if (stop_flag) |f| if (f.load(.acquire)) return error.Interrupted;
        const n = reader.readSliceShort(&buf) catch |err| {
            // A dropped connection mid-stream must not read as a clean
            // completion: falling through to build a ChatResponse from
            // whatever was collected so far would hand the caller a
            // silently truncated "success" with no way to tell it apart
            // from a model that actually finished.
            log.log(.error_, "stream read failed from '{s}': {s}", .{ provider.name, @errorName(err) });
            noteError();
            recordFailure(ctx, arena, provider, 0, @errorName(err), elapsedMs(ctx.io, llm_t0));
            return err;
        };
        if (n == 0) {
            // A stream that ends without the terminating blank line still has
            // a complete last frame in the buffer; dropping it loses that
            // frame's stop_reason and output-token count.
            if (sse.items.len == 0) break;
            try appendResponseBytes(&sse, ctx.gpa, "\n\n", resp_cap);
            at_eof = true;
        } else try appendResponseBytes(&sse, ctx.gpa, buf[0..n], resp_cap);
        // Process complete frames (data: ... blank line). `frame` is a view
        // into sse.items, so handle it fully before the buffer is shifted.
        while (std.mem.find(u8, sse.items, "\n\n")) |frame_end| {
            const frame = sse.items[0..frame_end];
            var frame_done = false;
            var it = std.mem.splitScalar(u8, frame, '\n');
            while (it.next()) |raw_line| {
                // Every payload the chunk_arena feeds into (usage, finish
                // reason, tool-call fragments) is copied out via arena.dupe
                // or an appendSlice into a gpa-backed list before this
                // iteration ends, so nothing outlives the reset: without it,
                // a long stream re-parses every frame into an arena that
                // never shrinks until the whole response finishes.
                defer _ = chunk_arena_state.reset(.retain_capacity);
                const line = std.mem.trimEnd(u8, raw_line, "\r");
                if (!std.mem.startsWith(u8, line, "data:")) continue;
                const payload = std.mem.trimStart(u8, line[5..], " ");
                // The frame's meaning is the provider's business; folding it
                // into the response is this module's.
                const ev = try impl.parseStreamEvent(chunk_arena, payload) orelse continue;
                if (ev.done) {
                    frame_done = true;
                    break;
                }
                try acc.apply(ev, on_delta);
            }
            const rest = sse.items[frame_end + 2 ..];
            std.mem.copyForwards(u8, sse.items[0..rest.len], rest);
            sse.items.len = rest.len;
            if (frame_done) {
                sse_done = true;
                break;
            }
        }
        if (at_eof) break;
    }

    const resp = try acc.finish();
    const ms: u64 = @intCast(@divTrunc(llm_t0.durationTo(std.Io.Timestamp.now(ctx.io, .awake)).nanoseconds, std.time.ns_per_ms));
    recordUsage(ctx, arena, provider, resp.usage, ms);
    return resp;
}

/// The running assembly of a streamed response, one per `chatStream` call.
///
/// Provider-neutral by construction: every provider's `parseStreamEvent`
/// yields the same `providers.StreamEvent`, and this is the single place they
/// fold into a `ChatResponse`. Text and tool arguments accumulate in
/// gpa-backed buffers; anything kept past one frame is copied into `arena`,
/// because the chunk arena the parse used is reset after every line.
const StreamAccumulator = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    content: std.ArrayList(u8) = .empty,
    call_ids: std.ArrayList([]const u8) = .empty,
    call_names: std.ArrayList([]const u8) = .empty,
    call_args: std.ArrayList(std.ArrayList(u8)) = .empty,
    usage: ?types.Usage = null,
    finish_reason: ?[]const u8 = null,
    /// Total streamed bytes across the text and every tool-argument slot,
    /// so one bound covers the complete assistant response.
    bytes: usize = 0,

    fn deinit(self: *StreamAccumulator) void {
        self.content.deinit(self.gpa);
        self.call_ids.deinit(self.gpa);
        self.call_names.deinit(self.gpa);
        for (self.call_args.items) |*a| a.deinit(self.gpa);
        self.call_args.deinit(self.gpa);
    }

    fn apply(self: *StreamAccumulator, ev: providers.StreamEvent, on_delta: *const fn ([]const u8) void) !void {
        if (ev.text) |text| {
            if (text.len > 0) {
                try appendStreamBytes(&self.content, self.gpa, text, &self.bytes);
                on_delta(text);
            }
        }
        for (ev.tool_calls) |frag| try self.applyFragment(frag);
        if (ev.usage) |u| {
            var totals = self.usage orelse types.Usage{};
            u.apply(&totals);
            self.usage = totals;
        }
        if (ev.finish_reason) |fr| self.finish_reason = try self.arena.dupe(u8, fr);
    }

    fn applyFragment(self: *StreamAccumulator, frag: providers.ToolCallFragment) !void {
        const idx = frag.index;
        if (idx >= max_tool_call_slots) return;
        while (self.call_args.items.len <= idx) {
            try self.call_args.append(self.gpa, .empty);
            try self.call_ids.append(self.gpa, "");
            try self.call_names.append(self.gpa, "");
        }
        // First non-empty wins: OpenAI sends the id and name on the opening
        // fragment and argument-only fragments after it, and a later empty
        // string must not blank what the first one established.
        if (frag.id) |id| {
            if (id.len > 0 and self.call_ids.items[idx].len == 0) self.call_ids.items[idx] = try self.arena.dupe(u8, id);
        }
        if (frag.name) |name| {
            if (name.len > 0 and self.call_names.items[idx].len == 0) self.call_names.items[idx] = try self.arena.dupe(u8, name);
        }
        if (frag.arguments) |args| {
            if (args.len > 0) try appendStreamBytes(&self.call_args.items[idx], self.gpa, args, &self.bytes);
        }
    }

    /// Turns the per-block-index accumulators into a ChatResponse.
    ///
    /// A tool that takes no arguments streams a name but never an argument
    /// fragment, so a call is keyed on the name: keying on the fragments would
    /// drop it, and the agent loop would read the empty turn as a final answer
    /// and stop mid-task. Slots with no name were never a tool block and are
    /// skipped.
    fn finish(self: *StreamAccumulator) !types.ChatResponse {
        var msg = types.Message{ .role = .assistant };
        if (self.content.items.len > 0) msg.content = try self.arena.dupe(u8, self.content.items);

        var calls: std.ArrayList(types.ToolCall) = .empty;
        for (self.call_args.items, 0..) |args_list, i| {
            if (self.call_names.items[i].len == 0) continue;
            try calls.append(self.arena, .{
                .id = self.call_ids.items[i],
                .name = self.call_names.items[i],
                .arguments = if (args_list.items.len > 0) try self.arena.dupe(u8, args_list.items) else "{}",
            });
        }
        if (calls.items.len > 0) msg.tool_calls = try calls.toOwnedSlice(self.arena);

        // A usage report of all zeros says nothing; reporting it as real would
        // overwrite a caller's running totals with a free turn.
        var usage_out: ?types.Usage = null;
        if (self.usage) |u| {
            if (u.total_tokens > 0) usage_out = u;
        }
        return .{ .message = msg, .usage = usage_out, .finish_reason = self.finish_reason };
    }
};

fn isRetryable(status: std.http.Status) bool {
    return switch (status) {
        .too_many_requests, .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout => true,
        else => false,
    };
}

/// Transport failures that are worth another try: the remote is unreachable
/// or the connection dropped before a status existed. Auth, TLS, and parse
/// errors are not here; they fail the same way on every attempt.
fn isRetryableTransport(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.HostLacksNetworkAddresses,
        error.TemporaryNameServerFailure,
        error.UnknownHostName,
        error.NameServerFailure,
        error.Timeout,
        error.EndOfStream,
        error.ReadFailed,
        error.WriteFailed,
        => true,
        else => false,
    };
}

test "retryable statuses are the ones a later attempt can recover from" {
    try std.testing.expect(isRetryable(.too_many_requests));
    try std.testing.expect(isRetryable(.internal_server_error));
    try std.testing.expect(isRetryable(.bad_gateway));
    try std.testing.expect(isRetryable(.service_unavailable));
    try std.testing.expect(isRetryable(.gateway_timeout));
    try std.testing.expect(!isRetryable(.ok));
    try std.testing.expect(!isRetryable(.bad_request));
    try std.testing.expect(!isRetryable(.unauthorized));
    try std.testing.expect(!isRetryable(.forbidden));
    try std.testing.expect(!isRetryable(.not_found));
}

test "transport retries cover dropped connections, not auth or parse" {
    try std.testing.expect(isRetryableTransport(error.ConnectionRefused));
    try std.testing.expect(isRetryableTransport(error.ConnectionResetByPeer));
    try std.testing.expect(isRetryableTransport(error.Timeout));
    try std.testing.expect(!isRetryableTransport(error.OutOfMemory));
    try std.testing.expect(!isRetryableTransport(error.InvalidUrl));
    try std.testing.expect(!isRetryableTransport(error.ApiError));
}

// ------------------------------------------------------------------- tests --

test "provider response buffers reject bytes beyond their limit" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);

    try appendResponseBytes(&list, std.testing.allocator, "1234", 5);
    try std.testing.expectError(
        error.ResponseTooLarge,
        appendResponseBytes(&list, std.testing.allocator, "56", 5),
    );
    try std.testing.expectEqualStrings("1234", list.items);

    var stream_total: usize = resp_cap - 1;
    try appendStreamBytes(&list, std.testing.allocator, "5", &stream_total);
    try std.testing.expectError(
        error.ResponseTooLarge,
        appendStreamBytes(&list, std.testing.allocator, "6", &stream_total),
    );
}

/// Drives a provider's stream frames through the shared accumulator, the way
/// chatStream does, and hands back the assembled response.
fn foldFrames(
    arena: std.mem.Allocator,
    impl: *const providers.Provider,
    frames: []const []const u8,
    on_delta: *const fn ([]const u8) void,
) !types.ChatResponse {
    var acc = StreamAccumulator{ .gpa = std.testing.allocator, .arena = arena };
    defer acc.deinit();
    var chunk_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer chunk_state.deinit();
    for (frames) |f| {
        defer _ = chunk_state.reset(.retain_capacity);
        const ev = try impl.parseStreamEvent(chunk_state.allocator(), f) orelse continue;
        if (ev.done) break;
        try acc.apply(ev, on_delta);
    }
    return acc.finish();
}

const NoopDelta = struct {
    fn cb(_: []const u8) void {}
};

test "anthropic stream events fold into text, tool calls and usage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Frames taken from the Messages streaming docs, tool-use example.
    const frames = [_][]const u8{
        \\{"type":"message_start","message":{"usage":{"input_tokens":472,"cache_read_input_tokens":8,"output_tokens":2}}}
        ,
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
        ,
        \\{"type":"ping"}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Okay"}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", checking"}}
        ,
        \\{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01T1","name":"get_weather","input":{}}}
        ,
        \\{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"location\":"}}
        ,
        \\{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" \"SF\"}"}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"ignored"}}
        ,
        \\{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":89}}
        ,
        \\{"type":"message_stop"}
        ,
    };
    const resp = try foldFrames(arena, providers.forKind(.anthropic), &frames, NoopDelta.cb);

    try std.testing.expectEqualStrings("tool_use", resp.finish_reason.?);
    try std.testing.expectEqualStrings("Okay, checking", resp.message.content.?);
    // The text block at index 0 was never a tool call, so only one survives.
    const calls = resp.message.tool_calls.?;
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("toolu_01T1", calls[0].id);
    try std.testing.expectEqualStrings("get_weather", calls[0].name);
    try std.testing.expectEqualStrings("{\"location\": \"SF\"}", calls[0].arguments);

    const u = resp.usage.?;
    // input + cache_read are both prompt tokens; output comes from message_delta.
    try std.testing.expectEqual(@as(u32, 480), u.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 8), u.prompt_cache_hit_tokens);
    try std.testing.expectEqual(@as(u32, 89), u.completion_tokens);
    try std.testing.expectEqual(@as(u32, 569), u.total_tokens);
}

test "a no-argument tool call survives the stream" {
    // Regression: keying tool calls on argument fragments dropped calls to
    // tools that take no input (the model streamed a name and an empty
    // `input`, never an input_json_delta). The agent loop then saw a turn with
    // no tool calls and no text and stopped, reporting an empty final answer.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const frames = [_][]const u8{
        \\{"type":"message_start","message":{"usage":{"input_tokens":100,"output_tokens":1}}}
        ,
        \\{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_09","name":"roadmap","input":{}}}
        ,
        \\{"type":"content_block_stop","index":0}
        ,
        \\{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":35}}
        ,
    };
    const resp = try foldFrames(arena, providers.forKind(.anthropic), &frames, NoopDelta.cb);

    const calls = resp.message.tool_calls.?;
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("roadmap", calls[0].name);
    try std.testing.expectEqualStrings("toolu_09", calls[0].id);
    // Empty arguments must still be valid JSON for the next request body.
    try std.testing.expectEqualStrings("{}", calls[0].arguments);
    try std.testing.expectEqualStrings("tool_use", resp.finish_reason.?);
}

test "openai stream fragments fold through the same accumulator" {
    // The point of the vtable: one accumulator, two event vocabularies. The
    // id and name arrive on the opening fragment only, and the arguments are
    // concatenated from the ones after it.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const frames = [_][]const u8{
        \\{"choices":[{"delta":{"content":"Let me look."}}]}
        ,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"history","arguments":"{\"n\":"}}]}}]}
        ,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"","function":{"name":"","arguments":"3}"}}]}}]}
        ,
        \\{"choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":100,"completion_tokens":20,"total_tokens":120,"prompt_cache_hit_tokens":40}}
        ,
        "[DONE]",
    };
    const resp = try foldFrames(arena, providers.forKind(.openai_compat), &frames, NoopDelta.cb);

    try std.testing.expectEqualStrings("Let me look.", resp.message.content.?);
    const calls = resp.message.tool_calls.?;
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("call_1", calls[0].id);
    try std.testing.expectEqualStrings("history", calls[0].name);
    try std.testing.expectEqualStrings("{\"n\":3}", calls[0].arguments);
    try std.testing.expectEqualStrings("tool_calls", resp.finish_reason.?);

    const u = resp.usage.?;
    try std.testing.expectEqual(@as(u32, 120), u.total_tokens);
    try std.testing.expectEqual(@as(u32, 40), u.prompt_cache_hit_tokens);
    try std.testing.expectEqual(@as(u32, 60), u.prompt_cache_miss_tokens);
}

test "a tool-call slot index beyond the cap is dropped, not allocated" {
    // A hostile or malformed frame naming `index: 999999999` would otherwise
    // grow three lists one element at a time up to an attacker-chosen number.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var acc = StreamAccumulator{ .gpa = std.testing.allocator, .arena = arena_state.allocator() };
    defer acc.deinit();
    try acc.apply(.{ .tool_calls = &.{.{ .index = 999_999_999, .name = "boom" }} }, NoopDelta.cb);
    try std.testing.expectEqual(@as(usize, 0), acc.call_args.items.len);

    try acc.apply(.{ .tool_calls = &.{.{ .index = max_tool_call_slots - 1, .name = "ok" }} }, NoopDelta.cb);
    try std.testing.expectEqual(max_tool_call_slots, acc.call_args.items.len);
}

test "streaming chat assembles SSE deltas" {
    const mock_server = @import("mock_server.zig");
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const mock = try mock_server.MockServer.start(io, std.testing.allocator, .openai_stream);
    defer mock.stop();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("MOCK_API_KEY", "test-key");

    const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{mock.port});
    defer std.testing.allocator.free(base_url);
    var arena_for_provider = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_for_provider.deinit();
    var provider = try config.Provider.single(arena_for_provider.allocator(), "mock-stream", base_url, .openai_compat, "mock", .{ .max_tokens = 64 });
    provider.api_key_env = "MOCK_API_KEY";

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
    }, &err_detail, Sink.cb, null);

    defer {
        for (Sink.collected.items) |_| {}
        Sink.collected.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("Hello from the mock stream", resp.message.content orelse "");
    try std.testing.expectEqualStrings("Hello from the mock stream", Sink.collected.items);
}

test "vertex stream: no-arg tool call and a frame with no trailing blank line" {
    const mock_server = @import("mock_server.zig");
    // End-to-end over the real client path: the last frame arrives without the
    // terminating blank line (a close-delimited stream), and the tool call
    // carries no arguments. Both used to be dropped, which the agent loop then
    // read as an empty final answer.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const mock = try mock_server.MockServer.start(io, std.testing.allocator, .anthropic_stream);
    defer mock.stop();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("MOCK_VERTEX_TOKEN", "test-token");

    const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{mock.port});
    defer std.testing.allocator.free(base_url);
    var arena_for_provider = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_for_provider.deinit();
    var provider = try config.Provider.single(arena_for_provider.allocator(), "vertex-mock", base_url, .vertex_anthropic, "claude-opus-4-6", .{
        .context_window = 1_048_576,
        .max_tokens = 4096,
    });
    provider.api_key_env = "MOCK_VERTEX_TOKEN";
    provider.project = "p";
    provider.location = "us-east5";

    var ctx = Ctx{ .io = io, .gpa = std.testing.allocator, .environ_map = &env };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const messages = [_]types.Message{.{ .role = .user, .content = "what next?" }};
    const Noop = struct {
        fn cb(_: []const u8) void {}
    };
    var err_detail: ?[]const u8 = null;
    const resp = try chatStream(&ctx, arena, .{
        .provider = &provider,
        .messages = &messages,
    }, &err_detail, Noop.cb, null);

    try std.testing.expectEqualStrings("Checking the roadmap", resp.message.content orelse "");
    const calls = resp.message.tool_calls orelse return error.ToolCallDropped;
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("roadmap", calls[0].name);
    try std.testing.expectEqualStrings("{}", calls[0].arguments);
    // stop_reason and output tokens live in that unterminated last frame.
    try std.testing.expectEqualStrings("tool_use", resp.finish_reason.?);
    try std.testing.expectEqual(@as(u32, 35), resp.usage.?.completion_tokens);
    try std.testing.expectEqual(@as(u32, 50), resp.usage.?.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 10), resp.usage.?.prompt_cache_hit_tokens);

    // The request must target Vertex's streaming verb, not the Anthropic path.
    const captured = mock.lastCaptured().?;
    try std.testing.expect(std.mem.endsWith(u8, captured.target, ":streamRawPredict"));
    try std.testing.expect(std.mem.find(u8, captured.body, "\"stream\":true") != null);
}

test "vertex non-stream chat hits rawPredict, not streamRawPredict" {
    const mock_server = @import("mock_server.zig");
    // chat() never sets params.stream, so it must ask endpointUrl for the
    // blocking verb; passing `true` here previously sent a plain chat() call
    // at Vertex's SSE-only :streamRawPredict endpoint.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const mock = try mock_server.MockServer.start(io, std.testing.allocator, .anthropic_text);
    defer mock.stop();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("MOCK_VERTEX_TOKEN", "test-token");

    const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{mock.port});
    defer std.testing.allocator.free(base_url);
    var arena_for_provider = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_for_provider.deinit();
    var provider = try config.Provider.single(arena_for_provider.allocator(), "vertex-mock", base_url, .vertex_anthropic, "claude-opus-4-6", .{
        .context_window = 1_048_576,
        .max_tokens = 4096,
    });
    provider.api_key_env = "MOCK_VERTEX_TOKEN";
    provider.project = "p";
    provider.location = "us-east5";

    var ctx = Ctx{ .io = io, .gpa = std.testing.allocator, .environ_map = &env };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const messages = [_]types.Message{.{ .role = .user, .content = "hi" }};
    var err_detail: ?[]const u8 = null;
    _ = try chat(&ctx, arena, .{ .provider = &provider, .messages = &messages }, &err_detail);

    const captured = mock.lastCaptured().?;
    try std.testing.expect(std.mem.endsWith(u8, captured.target, ":rawPredict"));
    try std.testing.expect(!std.mem.endsWith(u8, captured.target, ":streamRawPredict"));
    try std.testing.expect(std.mem.find(u8, captured.body, "\"stream\":true") == null);
}

test "cached prompt tokens are billed at the cache-read rate" {
    // 1000 prompt tokens, 800 of them served from cache: 200 at full rate plus
    // 800 at a tenth, not 1000 at full rate.
    const u = types.Usage{
        .prompt_tokens = 1000,
        .completion_tokens = 0,
        .total_tokens = 1000,
        .prompt_cache_hit_tokens = 800,
        .prompt_cache_miss_tokens = 200,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 0.00140), promptCost(u, 5.0), 1e-9);

    // No cache: unchanged from the plain rate.
    const cold = types.Usage{ .prompt_tokens = 1000, .completion_tokens = 0, .total_tokens = 1000 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.005), promptCost(cold, 5.0), 1e-9);
}

test "session usage accumulates and renders the built-in status segment" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var provider = try config.Provider.single(arena, "mock", "https://x", .openai_compat, "model-x", .{});

    var su = SessionUsage{};
    try std.testing.expectEqual(@as(u8, 0), su.cachePct()); // before the first turn
    su.add(&provider, .{
        .prompt_tokens = 1000,
        .completion_tokens = 50,
        .total_tokens = 1050,
        .prompt_cache_hit_tokens = 250,
        .prompt_cache_miss_tokens = 750,
    });
    su.add(&provider, .{
        .prompt_tokens = 500,
        .completion_tokens = 25,
        .total_tokens = 525,
    });
    try std.testing.expectEqual(@as(u64, 1500), su.prompt);
    try std.testing.expectEqual(@as(u64, 75), su.completion);
    try std.testing.expectEqual(@as(u64, 250), su.cache_hit);
    try std.testing.expectEqual(@as(u8, 16), su.cachePct()); // 250/1500, truncated

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try su.writeSegment(&w, &provider);
    const line = w.buffered();
    try std.testing.expectEqualStrings("mock/model-x · ↑1500 ↓75 tok · $0.0000 · cache 16%", line);
}

/// Drives one `chat` call against the anthropic mock and returns the request
/// headers it saw, so a test can assert on how the key was presented.
fn capturedAnthropicHeaders(gpa: std.mem.Allocator, key: []const u8, out: []u8) ![]const u8 {
    const mock_server = @import("mock_server.zig");
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const mock = try mock_server.MockServer.start(io, gpa, .anthropic_text);
    defer mock.stop();

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("MOCK_ANTHROPIC_KEY", key);

    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{mock.port});
    defer gpa.free(base_url);
    var arena_for_provider = std.heap.ArenaAllocator.init(gpa);
    defer arena_for_provider.deinit();
    var provider = try config.Provider.single(arena_for_provider.allocator(), "anthropic-mock", base_url, .anthropic, "claude-sonnet-5", .{
        .context_window = 1_000_000,
        .max_tokens = 1024,
    });
    provider.api_key_env = "MOCK_ANTHROPIC_KEY";

    var ctx = Ctx{ .io = io, .gpa = gpa, .environ_map = &env };
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const messages = [_]types.Message{.{ .role = .user, .content = "hi" }};
    var err_detail: ?[]const u8 = null;
    _ = try chat(&ctx, arena_state.allocator(), .{
        .provider = &provider,
        .messages = &messages,
    }, &err_detail);

    const captured = mock.lastCaptured() orelse return error.NothingCaptured;
    if (captured.headers_raw.len > out.len) return error.HeadersTooLong;
    @memcpy(out[0..captured.headers_raw.len], captured.headers_raw);
    return out[0..captured.headers_raw.len];
}

test "anthropic api key goes on x-api-key" {
    var buf: [8192]u8 = undefined;
    const headers = try capturedAnthropicHeaders(std.testing.allocator, "sk-ant-api03-secret", &buf);

    try std.testing.expect(std.mem.find(u8, headers, "x-api-key: sk-ant-api03-secret") != null);
    try std.testing.expect(std.mem.find(u8, headers, "anthropic-version: 2023-06-01") != null);
    // The oauth beta must not be announced for a plain API key.
    try std.testing.expect(std.mem.find(u8, headers, providers.anthropic.oauth_beta) == null);
    // std.http.Client writes its built-in header names lowercase.
    try std.testing.expect(std.mem.find(u8, headers, "authorization:") == null);
}

test "anthropic oauth token goes on Authorization with the oauth beta" {
    // `/v1/messages` rejects an `sk-ant-oat…` token presented on x-api-key, so
    // it has to switch to bearer auth plus the beta header.
    var buf: [8192]u8 = undefined;
    const headers = try capturedAnthropicHeaders(std.testing.allocator, "sk-ant-oat01-secret", &buf);

    try std.testing.expect(std.mem.find(u8, headers, "authorization: Bearer sk-ant-oat01-secret") != null);
    try std.testing.expect(std.mem.find(u8, headers, "anthropic-beta: " ++ providers.anthropic.oauth_beta) != null);
    try std.testing.expect(std.mem.find(u8, headers, "anthropic-version: 2023-06-01") != null);
    // The token must not also be sent as an API key; the API rejects both at once.
    try std.testing.expect(std.mem.find(u8, headers, "x-api-key") == null);
}
