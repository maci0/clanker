//! HTTP transport for LLM chat completions, with retry/backoff and
//! provider-aware error detail extraction.

const std = @import("std");
const types = @import("types.zig");
const providers = @import("providers.zig");
const config = @import("../config.zig");
const log = @import("../util/log.zig");
const vertex_token = @import("vertex_token.zig");
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
};

/// Response body cap for chat completions (8 MiB).
const resp_cap = 8 << 20;
const max_attempts = 3;

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

/// Prefix on Anthropic OAuth access tokens (`sk-ant-oat01-…`), as minted by
/// `ant auth login`. Matched without the version digits so a later `oat02`
/// is still recognised.
const oauth_token_prefix = "sk-ant-oat";
const oauth_beta = "oauth-2025-04-20";

/// An OAuth access token is not an API key: `/v1/messages` rejects it on
/// `x-api-key`. It authenticates as `Authorization: Bearer` and additionally
/// requires the oauth beta header.
fn isOauthToken(key: []const u8) bool {
    return std.mem.startsWith(u8, key, oauth_token_prefix);
}

/// Applies the provider's auth headers, returning how many `extra` slots were
/// filled. `bearer` is the api key already wrapped as `Bearer <key>`.
fn applyAuthHeaders(
    ctx: *Ctx,
    provider: *const config.Provider,
    bearer: ?[]const u8,
    headers: *std.http.Client.Request.Headers,
    extra: *[2]std.http.Header,
) usize {
    var extra_len: usize = 0;
    switch (provider.kind) {
        .openai_compat => {
            if (bearer) |b| headers.authorization = .{ .override = b };
        },
        .anthropic => {
            const key: ?[]const u8 = if (provider.api_key_env) |env_name|
                ctx.environ_map.get(env_name)
            else
                null;
            if (key) |k| {
                if (isOauthToken(k)) {
                    if (bearer) |b| headers.authorization = .{ .override = b };
                    extra[extra_len] = .{ .name = "anthropic-beta", .value = oauth_beta };
                    extra_len += 1;
                } else {
                    extra[extra_len] = .{ .name = "x-api-key", .value = k };
                    extra_len += 1;
                }
            }
            extra[extra_len] = .{ .name = "anthropic-version", .value = "2023-06-01" };
            extra_len += 1;
        },
        // Vertex authenticates with a GCP OAuth bearer token, and carries the
        // anthropic version in the body rather than a header.
        .vertex_anthropic => {
            if (bearer) |b| headers.authorization = .{ .override = b };
        },
    }
    return extra_len;
}

const FetchOutcome = struct {
    status: std.http.Status,
    /// Response body (gpa-owned).
    body: []u8,
};

/// Resolves the provider's credential (env var, or a minted Vertex access
/// token) into a ready-to-send `Bearer ...` header value, gpa-owned.
fn resolveBearer(ctx: *Ctx, provider: *const config.Provider) !?[]const u8 {
    const api_key: ?[]const u8 = if (provider.api_key_env) |env_name|
        ctx.environ_map.get(env_name)
    else
        null;
    // Vertex takes a GCP access token. An env var still wins (handy for a
    // short-lived token pasted in by hand); otherwise it is minted from the
    // service account and cached until it nears expiry. `get` hands back a
    // fresh copy (see vertex_token.zig), so it is formatted into the header
    // and freed here rather than carried further as `api_key`.
    if (provider.kind == .vertex_anthropic and api_key == null and provider.service_account_file.len > 0) {
        const tok = try vertex_token.get(ctx.io, ctx.gpa, provider.service_account_file);
        defer ctx.gpa.free(tok);
        return try std.fmt.allocPrint(ctx.gpa, "Bearer {s}", .{tok});
    }
    if (api_key == null and (provider.api_key_env != null or provider.kind == .vertex_anthropic)) {
        log.log(.error_, "no credential for provider '{s}': set {s} or service_account_file", .{
            provider.name,
            provider.api_key_env orelse "an API key env var",
        });
        return error.MissingApiKey;
    }
    if (api_key) |k| return try std.fmt.allocPrint(ctx.gpa, "Bearer {s}", .{k});
    return null;
}

pub fn chat(
    ctx: *Ctx,
    arena: std.mem.Allocator,
    params: providers.RequestParams,
    err_detail: *?[]const u8,
) !types.ChatResponse {
    const provider = params.provider;
    const llm_t0 = std.Io.Timestamp.now(ctx.io, .awake);

    const bearer = try resolveBearer(ctx, provider);
    defer if (bearer) |b| ctx.gpa.free(b);

    const body = try providers.buildRequest(ctx.gpa, params);
    defer ctx.gpa.free(body);

    const url = try endpointUrl(ctx.gpa, provider, false);
    defer ctx.gpa.free(url);

    var client: std.http.Client = .{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();

    var attempt: u32 = 0;
    var outcome: FetchOutcome = undefined;
    while (true) {
        attempt += 1;
        outcome = try doFetch(ctx, &client, url, body, bearer, provider, arena, err_detail);
        if (isRetryable(outcome.status) and attempt < max_attempts) {
            const delay = attempt * std.time.ns_per_s;
            log.log(.warn, "HTTP {d} from '{s}', retrying in {d}s (attempt {d}/{d})", .{ @intFromEnum(outcome.status), provider.name, delay / std.time.ns_per_s, attempt, max_attempts });
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
        return error.ApiError;
    }

    // Parse from an arena copy: the parsers keep slices into the body (and the
    // response carries `raw`), while `outcome.body` is gpa-owned and freed on
    // the way out of this function.
    const body_owned = try arena.dupe(u8, outcome.body);
    // err_detail goes in here: a 200 carrying an error body never passes the
    // HTTP error path in doFetch, so without this the caller only sees a bare
    // error.ApiError with no idea what the provider said.
    const resp = try providers.parseResponse(arena, provider.kind, body_owned, err_detail);
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
    });
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
        .user_agent = .{ .override = user_agent },
    };

    var extra: [2]std.http.Header = undefined;
    const extra_len = applyAuthHeaders(ctx, provider, bearer, &headers, &extra);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .headers = headers,
        .extra_headers = extra[0..extra_len],
        .response_writer = &w,
    }) catch |err| {
        log.log(.error_, "request to '{s}' failed: {s}", .{ url, @errorName(err) });
        // Unlike an HTTP error status, this never reaches `err_detail` below,
        // so every caller that reports `err_detail orelse @errorName(err)`
        // would otherwise show the user a bare Zig error name (e.g.
        // "ConnectionRefused") instead of a sentence.
        err_detail.* = std.fmt.allocPrint(arena, "couldn't reach '{s}' ({s})", .{ provider.name, @errorName(err) }) catch null;
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
    stop_flag: ?*std.atomic.Value(bool),
) !types.ChatResponse {
    const provider = params.provider;
    const llm_t0 = std.Io.Timestamp.now(ctx.io, .awake);

    const bearer = try resolveBearer(ctx, provider);
    defer if (bearer) |b| ctx.gpa.free(b);

    var p = params;
    p.stream = true;
    const body = try providers.buildRequest(ctx.gpa, p);
    defer ctx.gpa.free(body);

    const url = try endpointUrl(ctx.gpa, provider, true);
    defer ctx.gpa.free(url);

    var client: std.http.Client = .{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();

    var headers: std.http.Client.Request.Headers = .{
        .content_type = .{ .override = "application/json" },
        .user_agent = .{ .override = user_agent },
    };
    var extra: [2]std.http.Header = undefined;
    const extra_len = applyAuthHeaders(ctx, provider, bearer, &headers, &extra);

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
        std.debug.print("LLM streaming request provider={s} bytes={d}\n", .{ provider.name, body.len });
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
        if (providers.parseErrorDetail(arena, provider.kind, err_body.items)) |msg| {
            err_detail.* = try std.fmt.allocPrint(arena, "HTTP {d}: {s}", .{ @intFromEnum(response.head.status), msg });
        } else {
            err_detail.* = try std.fmt.allocPrint(arena, "HTTP {d}", .{@intFromEnum(response.head.status)});
        }
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

    // Anthropic and Vertex stream a different event vocabulary from OpenAI:
    // typed events (content_block_delta, message_delta) instead of choices[].
    const anthropic_family = provider.kind == .anthropic or provider.kind == .vertex_anthropic;

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
    var stream_usage: ?StreamUsage = null;
    var finish_reason: ?[]const u8 = null;
    var stream_bytes: usize = 0;
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
            log.log(.error_, "stream read failed: {s}", .{@errorName(err)});
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
        while (std.mem.indexOf(u8, sse.items, "\n\n")) |frame_end| {
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
                if (std.mem.eql(u8, payload, "[DONE]")) {
                    frame_done = true;
                    break;
                }
                if (anthropic_family) {
                    try handleAnthropicEvent(ctx, arena, chunk_arena, payload, on_delta, &content, &call_ids, &call_names, &call_args, &stream_bytes, &stream_usage, &finish_reason);
                    continue;
                }
                const chunk = std.json.parseFromSliceLeaky(StreamChunk, chunk_arena, payload, .{ .ignore_unknown_fields = true }) catch {
                    // Dropping a frame silently hides truncated or re-framed
                    // streams as "the model said nothing".  Log the byte count
                    // only — the payload is raw provider output that may
                    // contain generated content or echoed user data.
                    log.log(.debug, "unparseable stream frame ({d} bytes)", .{payload.len});
                    continue;
                };
                // The final chunk may carry usage with an empty choices list;
                // capture it before the choices guard.
                if (chunk.usage) |u| {
                    if (u.total_tokens > 0) stream_usage = u;
                }
                if (chunk.choices.len == 0) continue;
                const choice = chunk.choices[0];
                if (choice.finish_reason) |fr| finish_reason = try arena.dupe(u8, fr);
                if (choice.delta.content) |c| {
                    if (c.len > 0) {
                        try appendStreamBytes(&content, ctx.gpa, c, &stream_bytes);
                        on_delta(c);
                    }
                }
                if (choice.delta.tool_calls) |tcs| {
                    for (tcs) |frag| {
                        const idx = frag.index;
                        if (idx >= max_tool_call_slots) continue;
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
                            if (fargs.len > 0) try appendStreamBytes(&call_args.items[idx], ctx.gpa, fargs, &stream_bytes);
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
        if (at_eof) break;
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
    const collected = try collectStreamCalls(arena, &calls, call_ids.items, call_names.items, call_args.items);
    if (collected.len > 0) msg.tool_calls = collected;
    const resp = types.ChatResponse{ .message = msg, .usage = usage_out, .finish_reason = finish_reason };
    const ms: u64 = @intCast(@divTrunc(llm_t0.durationTo(std.Io.Timestamp.now(ctx.io, .awake)).nanoseconds, std.time.ns_per_ms));
    recordUsage(ctx, arena, provider, resp.usage, ms);
    return resp;
}

/// Turns the per-block-index streaming accumulators into tool calls.
///
/// A tool that takes no arguments streams a name but never an argument
/// fragment, so the call is keyed on the name: keying on the fragments would
/// drop it, and the agent loop would read the empty turn as a final answer and
/// stop mid-task. Slots with no name were never a tool block and are skipped.
fn collectStreamCalls(
    arena: std.mem.Allocator,
    calls: *std.ArrayList(types.ToolCall),
    ids: []const []const u8,
    names: []const []const u8,
    args: []const std.ArrayList(u8),
) ![]types.ToolCall {
    for (args, 0..) |args_list, i| {
        if (names[i].len == 0) continue;
        try calls.append(arena, .{
            .id = ids[i],
            .name = names[i],
            .arguments = if (args_list.items.len > 0) try arena.dupe(u8, args_list.items) else "{}",
        });
    }
    return calls.toOwnedSlice(arena);
}

// ------------------------------------------------- anthropic SSE events --

/// One frame of an Anthropic (and Vertex) stream. Only the fields the harness
/// consumes are declared; everything else is ignored.
const AnthropicEvent = struct {
    type: []const u8 = "",
    index: usize = 0,
    message: ?struct {
        usage: ?AnthropicUsage = null,
    } = null,
    content_block: ?struct {
        type: []const u8 = "",
        id: ?[]const u8 = null,
        name: ?[]const u8 = null,
    } = null,
    delta: ?struct {
        type: []const u8 = "",
        text: ?[]const u8 = null,
        partial_json: ?[]const u8 = null,
        /// Only on `message_delta`: "end_turn", "tool_use", "max_tokens", ...
        stop_reason: ?[]const u8 = null,
    } = null,
    usage: ?AnthropicUsage = null,
};

const AnthropicUsage = struct {
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    cache_read_input_tokens: u32 = 0,
    cache_creation_input_tokens: u32 = 0,
};

/// Folds one Anthropic stream event into the accumulating response.
///
/// The shape differs from OpenAI in three ways that matter: text arrives as
/// `content_block_delta` with a `text_delta`, tool arguments arrive as
/// `input_json_delta` fragments that must be concatenated per block index, and
/// usage is split across `message_start` (input) and `message_delta` (output).
fn handleAnthropicEvent(
    ctx: *Ctx,
    arena: std.mem.Allocator,
    chunk_arena: std.mem.Allocator,
    payload: []const u8,
    on_delta: *const fn ([]const u8) void,
    content: *std.ArrayList(u8),
    call_ids: *std.ArrayList([]const u8),
    call_names: *std.ArrayList([]const u8),
    call_args: *std.ArrayList(std.ArrayList(u8)),
    stream_bytes: *usize,
    stream_usage: *?StreamUsage,
    finish_reason: *?[]const u8,
) !void {
    const ev = std.json.parseFromSliceLeaky(AnthropicEvent, chunk_arena, payload, .{ .ignore_unknown_fields = true }) catch {
        // Dropping a frame silently hides truncated or re-framed streams as
        // "the model said nothing".  Log the byte count only — the payload is
        // raw provider output that may contain generated content or echoed
        // user data.
        log.log(.debug, "unparseable stream frame ({d} bytes)", .{payload.len});
        return;
    };

    if (std.mem.eql(u8, ev.type, "message_start")) {
        if (ev.message) |m| {
            if (m.usage) |u| mergeAnthropicUsage(stream_usage, u);
        }
        return;
    }

    if (std.mem.eql(u8, ev.type, "content_block_start")) {
        const block = ev.content_block orelse return;
        if (!std.mem.eql(u8, block.type, "tool_use")) return;
        if (ev.index >= max_tool_call_slots) return;
        while (call_args.items.len <= ev.index) {
            try call_args.append(ctx.gpa, .empty);
            try call_ids.append(ctx.gpa, "");
            try call_names.append(ctx.gpa, "");
        }
        if (block.id) |id| call_ids.items[ev.index] = try arena.dupe(u8, id);
        if (block.name) |name| call_names.items[ev.index] = try arena.dupe(u8, name);
        return;
    }

    if (std.mem.eql(u8, ev.type, "content_block_delta")) {
        const d = ev.delta orelse return;
        if (d.text) |text| {
            if (text.len > 0) {
                try appendStreamBytes(content, ctx.gpa, text, stream_bytes);
                on_delta(text);
            }
            return;
        }
        if (d.partial_json) |frag| {
            if (frag.len == 0) return;
            if (ev.index >= max_tool_call_slots) return;
            while (call_args.items.len <= ev.index) {
                try call_args.append(ctx.gpa, .empty);
                try call_ids.append(ctx.gpa, "");
                try call_names.append(ctx.gpa, "");
            }
            try appendStreamBytes(&call_args.items[ev.index], ctx.gpa, frag, stream_bytes);
        }
        return;
    }

    if (std.mem.eql(u8, ev.type, "message_delta")) {
        if (ev.usage) |u| mergeAnthropicUsage(stream_usage, u);
        // The stop reason only ever arrives here; without it the agent loop
        // cannot tell "end_turn" from "max_tokens" (a truncated answer).
        if (ev.delta) |d| {
            if (d.stop_reason) |sr| finish_reason.* = try arena.dupe(u8, sr);
        }
        return;
    }
}

/// Anthropic reports input tokens once at the start and output tokens at the
/// end, so the two halves are merged rather than overwritten. `input_tokens`
/// excludes cache reads, which the harness counts as prompt tokens.
fn mergeAnthropicUsage(stream_usage: *?StreamUsage, u: AnthropicUsage) void {
    var acc = stream_usage.* orelse StreamUsage{};
    if (u.input_tokens > 0 or u.cache_read_input_tokens > 0 or u.cache_creation_input_tokens > 0) {
        acc.prompt_tokens = u.input_tokens + u.cache_read_input_tokens + u.cache_creation_input_tokens;
        acc.prompt_cache_hit_tokens = u.cache_read_input_tokens;
        acc.prompt_cache_miss_tokens = u.input_tokens + u.cache_creation_input_tokens;
    }
    if (u.output_tokens > 0) acc.completion_tokens = u.output_tokens;
    acc.total_tokens = acc.prompt_tokens + acc.completion_tokens;
    stream_usage.* = acc;
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
    finish_reason: ?[]const u8 = null,
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

fn endpointUrl(gpa: std.mem.Allocator, provider: *const config.Provider, streaming: bool) ![]u8 {
    // Vertex addresses the model in the path, so the URL cannot be a constant:
    // .../locations/<region>/publishers/anthropic/models/<model>:rawPredict
    if (provider.kind == .vertex_anthropic) {
        if (provider.project.len == 0 or provider.location.len == 0) return error.VertexProjectMissing;
        var owned_base: ?[]u8 = null;
        defer if (owned_base) |b| gpa.free(b);
        const base = if (provider.base_url.len > 0) std.mem.trimEnd(u8, provider.base_url, "/") else blk: {
            owned_base = try std.fmt.allocPrint(gpa, "https://{s}-aiplatform.googleapis.com", .{provider.location});
            break :blk owned_base.?;
        };
        // Streaming is a different verb on Vertex, not a body flag.
        const verb = if (streaming) "streamRawPredict" else "rawPredict";
        return std.fmt.allocPrint(
            gpa,
            "{s}/v1/projects/{s}/locations/{s}/publishers/anthropic/models/{s}:{s}",
            .{ base, provider.project, provider.location, provider.activeModelName(), verb },
        );
    }
    const path = provider.path orelse switch (provider.kind) {
        .openai_compat => "/chat/completions",
        .anthropic => "/v1/messages",
        .vertex_anthropic => unreachable,
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

test "endpoint url building" {
    const mock = config.Provider{ .name = "m", .base_url = "https://api.deepseek.com/", .default_model = "x" };
    const url1 = try endpointUrl(std.testing.allocator, &mock, false);
    defer std.testing.allocator.free(url1);
    try std.testing.expectEqualStrings("https://api.deepseek.com/chat/completions", url1);

    const anthropic = config.Provider{ .name = "a", .kind = .anthropic, .base_url = "https://api.anthropic.com", .default_model = "x" };
    const url2 = try endpointUrl(std.testing.allocator, &anthropic, false);
    defer std.testing.allocator.free(url2);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", url2);
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

test "anthropic stream events fold into text, tool calls and usage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var ctx = Ctx{ .io = threaded.io(), .gpa = std.testing.allocator, .environ_map = &env };

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(ctx.gpa);
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(ctx.gpa);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(ctx.gpa);
    var args: std.ArrayList(std.ArrayList(u8)) = .empty;
    defer {
        for (args.items) |*a| a.deinit(ctx.gpa);
        args.deinit(ctx.gpa);
    }
    var usage: ?StreamUsage = null;
    var stream_bytes: usize = 0;

    const Noop = struct {
        fn onDelta(_: []const u8) void {}
    };

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
    var finish_reason: ?[]const u8 = null;
    for (frames) |f| {
        try handleAnthropicEvent(&ctx, arena, arena, f, &Noop.onDelta, &content, &ids, &names, &args, &stream_bytes, &usage, &finish_reason);
    }

    try std.testing.expectEqualStrings("tool_use", finish_reason.?);
    try std.testing.expectEqualStrings("Okay, checking", content.items);
    try std.testing.expectEqual(@as(usize, 2), args.items.len);
    try std.testing.expectEqualStrings("toolu_01T1", ids.items[1]);
    try std.testing.expectEqualStrings("get_weather", names.items[1]);
    try std.testing.expectEqualStrings("{\"location\": \"SF\"}", args.items[1].items);

    const u = usage.?;
    // input + cache_read are both prompt tokens; output comes from message_delta.
    try std.testing.expectEqual(@as(u32, 480), u.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 8), u.prompt_cache_hit_tokens);
    try std.testing.expectEqual(@as(u32, 89), u.completion_tokens);
    try std.testing.expectEqual(@as(u32, 569), u.total_tokens);
}

test "fuzz: anthropic stream events never hang or crash on malformed payloads" {
    // handleAnthropicEvent parses whatever the wire sends as a stream frame,
    // including a bare `index` field that used to drive an unbounded
    // call_args/call_ids/call_names growth loop (index: 999999999999 would
    // try to allocate that many slots). The property here is just: no crash,
    // no unbounded allocation, for any bytes.
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var ctx = Ctx{ .io = threaded.io(), .gpa = std.testing.allocator, .environ_map = &env };

    const Noop = struct {
        fn onDelta(_: []const u8) void {}
    };

    const FCtx = struct {
        ctx: *Ctx,
        fn one(self: @This(), smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.slice(&buf);
            const payload = buf[0..len];

            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            var content: std.ArrayList(u8) = .empty;
            defer content.deinit(self.ctx.gpa);
            var ids: std.ArrayList([]const u8) = .empty;
            defer ids.deinit(self.ctx.gpa);
            var names: std.ArrayList([]const u8) = .empty;
            defer names.deinit(self.ctx.gpa);
            var args: std.ArrayList(std.ArrayList(u8)) = .empty;
            defer {
                for (args.items) |*a| a.deinit(self.ctx.gpa);
                args.deinit(self.ctx.gpa);
            }
            var usage: ?StreamUsage = null;
            var finish_reason: ?[]const u8 = null;
            var stream_bytes: usize = 0;

            try handleAnthropicEvent(self.ctx, arena, arena, payload, &Noop.onDelta, &content, &ids, &names, &args, &stream_bytes, &usage, &finish_reason);
        }
    };
    try std.testing.fuzz(FCtx{ .ctx = &ctx }, FCtx.one, .{});
}

test "a no-argument tool call survives the stream" {
    // Regression: keying tool calls on argument fragments dropped calls to
    // tools that take no input (the model streamed a name and an empty
    // `input`, never an input_json_delta). The agent loop then saw a turn with
    // no tool calls and no text and stopped, reporting an empty final answer.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var ctx = Ctx{ .io = threaded.io(), .gpa = std.testing.allocator, .environ_map = &env };

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(ctx.gpa);
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(ctx.gpa);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(ctx.gpa);
    var args: std.ArrayList(std.ArrayList(u8)) = .empty;
    defer {
        for (args.items) |*a| a.deinit(ctx.gpa);
        args.deinit(ctx.gpa);
    }
    var usage: ?StreamUsage = null;
    var finish_reason: ?[]const u8 = null;
    var stream_bytes: usize = 0;

    const Noop = struct {
        fn onDelta(_: []const u8) void {}
    };

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
    for (frames) |f| {
        try handleAnthropicEvent(&ctx, arena, arena, f, &Noop.onDelta, &content, &ids, &names, &args, &stream_bytes, &usage, &finish_reason);
    }

    var calls: std.ArrayList(types.ToolCall) = .empty;
    defer calls.deinit(arena);
    const collected = try collectStreamCalls(arena, &calls, ids.items, names.items, args.items);

    try std.testing.expectEqual(@as(usize, 1), collected.len);
    try std.testing.expectEqualStrings("roadmap", collected[0].name);
    try std.testing.expectEqualStrings("toolu_09", collected[0].id);
    // Empty arguments must still be valid JSON for the next request body.
    try std.testing.expectEqualStrings("{}", collected[0].arguments);
    try std.testing.expectEqualStrings("tool_use", finish_reason.?);
}

test "collectStreamCalls skips block indices that were never tool blocks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Index 0 is the assistant's text block: no name, so it is not a call.
    const ids = [_][]const u8{ "", "toolu_1" };
    const names = [_][]const u8{ "", "history" };
    var args = [_]std.ArrayList(u8){ .empty, .empty };
    try args[1].appendSlice(arena, "{\"n\":3}");

    var calls: std.ArrayList(types.ToolCall) = .empty;
    defer calls.deinit(arena);
    const collected = try collectStreamCalls(arena, &calls, &ids, &names, &args);

    try std.testing.expectEqual(@as(usize, 1), collected.len);
    try std.testing.expectEqualStrings("history", collected[0].name);
    try std.testing.expectEqualStrings("{\"n\":3}", collected[0].arguments);
}

test "openai stream chunks carry the finish reason" {
    const chunk = "{\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":\"stop\"}]}";
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSliceLeaky(StreamChunk, arena, chunk, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("stop", parsed.choices[0].finish_reason.?);
}

test "vertex endpoint url carries project, location, model and verb" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var provider = try config.Provider.single(arena, "vertex-opus", "", .vertex_anthropic, "claude-opus-4-6", .{});
    provider.project = "my-project";
    provider.location = "us-east5";

    const streaming = try endpointUrl(std.testing.allocator, &provider, true);
    defer std.testing.allocator.free(streaming);
    try std.testing.expectEqualStrings(
        "https://us-east5-aiplatform.googleapis.com/v1/projects/my-project/locations/us-east5/publishers/anthropic/models/claude-opus-4-6:streamRawPredict",
        streaming,
    );

    const blocking = try endpointUrl(std.testing.allocator, &provider, false);
    defer std.testing.allocator.free(blocking);
    try std.testing.expect(std.mem.endsWith(u8, blocking, ":rawPredict"));

    // A provider missing the GCP coordinates must fail loudly, not build a
    // URL with empty path segments.
    var bare = try config.Provider.single(arena, "vertex-bad", "", .vertex_anthropic, "claude-opus-4-6", .{});
    try std.testing.expectError(error.VertexProjectMissing, endpointUrl(std.testing.allocator, &bare, true));
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
    try std.testing.expect(std.mem.indexOf(u8, captured.body, "\"stream\":true") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, captured.body, "\"stream\":true") == null);
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

    try std.testing.expect(std.mem.indexOf(u8, headers, "x-api-key: sk-ant-api03-secret") != null);
    try std.testing.expect(std.mem.indexOf(u8, headers, "anthropic-version: 2023-06-01") != null);
    // The oauth beta must not be announced for a plain API key.
    try std.testing.expect(std.mem.indexOf(u8, headers, oauth_beta) == null);
    // std.http.Client writes its built-in header names lowercase.
    try std.testing.expect(std.mem.indexOf(u8, headers, "authorization:") == null);
}

test "anthropic oauth token goes on Authorization with the oauth beta" {
    // `/v1/messages` rejects an `sk-ant-oat…` token presented on x-api-key, so
    // it has to switch to bearer auth plus the beta header.
    var buf: [8192]u8 = undefined;
    const headers = try capturedAnthropicHeaders(std.testing.allocator, "sk-ant-oat01-secret", &buf);

    try std.testing.expect(std.mem.indexOf(u8, headers, "authorization: Bearer sk-ant-oat01-secret") != null);
    try std.testing.expect(std.mem.indexOf(u8, headers, "anthropic-beta: " ++ oauth_beta) != null);
    try std.testing.expect(std.mem.indexOf(u8, headers, "anthropic-version: 2023-06-01") != null);
    // The token must not also be sent as an API key; the API rejects both at once.
    try std.testing.expect(std.mem.indexOf(u8, headers, "x-api-key") == null);
}

test "oauth token prefix matching is version-agnostic" {
    try std.testing.expect(isOauthToken("sk-ant-oat01-abc"));
    try std.testing.expect(isOauthToken("sk-ant-oat02-abc"));
    try std.testing.expect(!isOauthToken("sk-ant-api03-abc"));
    try std.testing.expect(!isOauthToken(""));
}
