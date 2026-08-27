//! The shared transport core for LLM chat completions: HTTP, SSE framing,
//! retry/backoff, streaming accumulation and token accounting.
//!
//! Deliberately one module, not one per provider. Everything that differs
//! between providers (the wire codec, the auth headers, the endpoint URL)
//! is reached through the `providers.Provider` vtable resolved once per call,
//! so this file contains no kind-switch on `provider.kind` at all. See
//! [ADR 0004](../../docs/adrs/0004-providers-are-a-native-vtable-not-wasm.md).

const std = @import("std");
const utf8 = @import("../util/utf8.zig");
const types = @import("types.zig");
const providers = @import("registry.zig");
const oauth_plugins = @import("oauth_plugins/registry.zig");
const auth = @import("auth.zig");
const config = @import("../config.zig");
const log = @import("../util/log.zig");
const redact = @import("../util/redact.zig");
const token_stats = @import("../stats/tokens.zig");
const stream = @import("stream.zig");
const cache_cold = @import("cache_cold.zig");
const rate_limit = @import("rate_limit.zig");
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

/// Stack scratch handed to std.http: the redirect header buffer, the
/// decompress transfer buffers, and the SSE read chunk all share this size.
/// A chunk size, not a cap: any value works, 8 KiB keeps per-frame copies
/// small. Shared with the proxy, which drives the same reader shapes.
pub const http_scratch_buf_bytes: usize = 8192;

/// Stack scratch for reading an error body before it is summarized: the
/// provider's message is extracted, never the whole body, so one 16 KiB
/// chunk is enough. A chunk size, not a cap (`resp_cap` bounds the body).
const err_body_buf_bytes: usize = 16384;

/// Lets a caller on another thread rescue a `chat` that is blocked reading a
/// response which is never going to arrive.
///
/// **Why this has to exist.** `Io.Future.cancel` does not rescue it.
/// `Threaded.waitForCancelWithSignaling` only signals a thread it believes is
/// parked in a *cancelable* syscall, and a blocking read on an established
/// connection is not one, so cancel itself futex-waits with a null timeout and
/// never returns — the canceller wedges alongside the thread it was trying to
/// cancel. `std.http.Client` has no read timeout to fall back on either:
/// `ConnectTcpOptions.timeout` is declared and never referenced. So a host that
/// accepts a connection and then says nothing hangs `clanker providers check`
/// forever, which is the failure `pingWithTimeout` exists to prevent.
///
/// **The lever.** `shutdown(2)` on the socket makes the blocked read return
/// end-of-stream. Verified on this platform in isolation before this was built:
/// a thread blocked in `recv` returns `b''` 0.5s after another thread calls
/// `shutdown(SHUT_RDWR)`. `close` also unblocks it, with `EBADF`, but closing an
/// fd another thread is actively reading invites the descriptor-reuse race;
/// shutting the socket down leaves the fd valid and lets its owner free it on
/// its own unwind.
///
/// **Why this is not a use-after-free.** `trigger` only shuts sockets down. It
/// frees nothing and closes nothing. The worker still owns its `http.Client`
/// and still runs its own `defer client.deinit()`; all it sees is a read that
/// ends early, which it already handles as a transport error. `disarm` takes
/// the same mutex `trigger` holds, so a `chat` returning cannot pull the client
/// out from under an in-flight `trigger` — it blocks until that call is done.
///
/// Lock order is `Abort.mutex` then `ConnectionPool.mutex`, and nothing takes
/// them the other way round: the worker touches the pool alone during normal
/// operation and `Abort.mutex` alone at arm/disarm.
pub const Abort = struct {
    mutex: std.Io.Mutex = .init,
    /// Non-null only while a `chat` on some thread is using this client.
    client: ?*std.http.Client = null,
    /// Latched by `trigger`, including a trigger that found nothing armed.
    /// The retry loops read it to refuse a retry after a deliberate abort:
    /// the transport error a shutdown produces is retryable by shape, and a
    /// retried attempt opens a fresh connection that the one-shot watchdog
    /// which already fired would never shut down — the request then blocks
    /// forever in a read nothing will unblock.
    triggered: std.atomic.Value(bool) = .init(false),

    /// Point this handle at the client `chat` is about to use.
    pub fn arm(self: *Abort, io: std.Io, c: *std.http.Client) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.client = c;
    }

    /// Stop pointing at a client that is about to be destroyed. Blocks until
    /// any concurrent `trigger` has finished with it.
    pub fn disarm(self: *Abort, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.client = null;
    }

    /// Shut down every connection the armed client currently holds, so a read
    /// blocked on any of them returns instead of waiting forever. Safe to call
    /// when nothing is armed (does nothing) and safe to call more than once.
    pub fn trigger(self: *Abort, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        // Latch before checking what is armed: a trigger that raced ahead of
        // `arm` still means "this call is over", and the request must see
        // that the moment it next consults the flag.
        self.triggered.store(true, .release);
        const c = self.client orelse return;

        c.connection_pool.mutex.lockUncancelable(io);
        defer c.connection_pool.mutex.unlock(io);
        var it = c.connection_pool.used.first;
        while (it) |node| : (it = node.next) {
            const conn: *std.http.Client.Connection = @alignCast(@fieldParentPtr("pool_node", node));
            // Both directions: the read is what is stuck, but a half-written
            // request should not be left to dribble out either. A connection
            // that has already been torn down reports an error here, which is
            // exactly the state we were trying to reach.
            conn.stream_reader.stream.shutdown(io, .both) catch {};
        }
    }
};

/// Waits for one concurrent fetch task under a wall-clock budget, returning
/// false when the budget is spent or the wait itself was cancelled. The task
/// must set `done` on every exit, or the waiter is never woken.
///
/// On timeout the armed connections are shut down *before* the task is
/// cancelled: `Io.Future.cancel` cannot rescue a thread parked in a blocking
/// read on an established connection and would wedge the canceller alongside
/// it, whereas `shutdown(2)` makes that read return end-of-stream so the task
/// unwinds on its own (see `Abort`).
pub fn awaitTaskWithTimeout(
    io: std.Io,
    done: *std.Io.Event,
    future: anytype,
    abort: *Abort,
    timeout_ms: u32,
) bool {
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{
        .clock = .awake,
        .raw = .{ .nanoseconds = @as(i96, timeout_ms) * std.time.ns_per_ms },
    });
    while (!done.isSet()) {
        done.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
            // Spurious wakeups report Timeout too, so the deadline decides
            // whether the budget is really spent, not this return.
            error.Timeout => {
                if (done.isSet()) break;
                if (deadline.durationFromNow(io).raw.nanoseconds > 0) continue;
                abort.trigger(io);
                // cancel() joins the task, so nothing is left writing into
                // caller memory after this returns.
                _ = future.cancel(io);
                return false;
            },
            error.Canceled => {
                abort.trigger(io);
                _ = future.cancel(io);
                return false;
            },
        };
    }
    return true;
}

pub const Ctx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    /// Effective config, when the caller has one. Enables global token-usage
    /// recording (modules.token_stats); null callers (e.g. a provider ping)
    /// simply don't record.
    cfg: ?*const config.Config = null,
    /// Set by a caller that enforces its own deadline and needs a way to stop
    /// a wedged read (see `Abort`). Null everywhere else, which leaves the
    /// behaviour of every other call site exactly as it was.
    abort: ?*Abort = null,
    /// Liveness counter for `chatStreamWithTimeout`: `chatStream` bumps it
    /// once per read that returned bytes, and the watchdog on the other side
    /// samples it to tell "still arriving" from "gone quiet". A count, not a
    /// clock, so the streaming thread never has to read one. Null everywhere
    /// else, which leaves every other call site exactly as it was.
    stream_progress: ?*std.atomic.Value(u64) = null,
    /// Optional metadata attached by auto-thinking to the next main-model
    /// completion record. Side-channel clients leave both null.
    thinking_level: ?[]const u8 = null,
    thinking_classifier_ms: ?u64 = null,

    /// The slice of this context credential resolution needs.
    fn authEnv(self: *Ctx) auth.Env {
        return .{
            .io = self.io,
            .gpa = self.gpa,
            .environ_map = self.environ_map,
            .state_dir = if (self.cfg) |cfg| cfg.agent.state_dir else "state",
        };
    }
};

/// Whether the caller's deadline machinery has already aborted this call.
/// Consulted by the retry loops: retrying past a deliberate abort opens a
/// connection no watchdog is left to shut down.
fn abortWasTriggered(ctx: *const Ctx) bool {
    const a = ctx.abort orelse return false;
    return a.triggered.load(.acquire);
}

/// Response body cap for chat completions (8 MiB).
const resp_cap = 8 << 20;
const max_attempts = 3;

/// Process-local RED counters for LLM calls. Cardinality is zero (no
/// provider/model labels) so a busy loop cannot blow a time-series store;
/// per-provider detail lives in token_stats.jsonl and the correlated logs.
var llm_requests_total = std.atomic.Value(u64).init(0);
var llm_errors_total = std.atomic.Value(u64).init(0);
var llm_retries_total = std.atomic.Value(u64).init(0);
/// A lapsed deadline, counted apart from `llm_errors_total` because it is the
/// one provider failure retrying against the same endpoint cannot fix: the
/// call produced no error to classify, it produced nothing at all. A rising
/// share of these against a flat error count is a provider going quiet rather
/// than refusing, and the two want opposite responses.
var llm_timeouts_total = std.atomic.Value(u64).init(0);
/// Duration of every completed LLM call, successes and failures alike. The
/// per-call number already reaches `token_stats.jsonl`; without the aggregate
/// here, "is the provider slow?" has no answer that does not mean parsing a
/// log file. Buckets are seconds-scale on purpose -- an LLM call is nothing
/// like the millisecond-scale HTTP request the other histogram measures.
var llm_latency_ms_sum = std.atomic.Value(u64).init(0);
var llm_latency_le_1s = std.atomic.Value(u64).init(0);
var llm_latency_le_5s = std.atomic.Value(u64).init(0);
var llm_latency_le_15s = std.atomic.Value(u64).init(0);
var llm_latency_le_60s = std.atomic.Value(u64).init(0);

pub const LlmMetrics = struct {
    requests_total: u64,
    errors_total: u64,
    retries_total: u64,
    timeouts_total: u64,
    latency_ms_sum: u64,
    latency_le_1s: u64,
    latency_le_5s: u64,
    latency_le_15s: u64,
    latency_le_60s: u64,
};

pub fn snapshotMetrics() LlmMetrics {
    return .{
        .requests_total = llm_requests_total.load(.monotonic),
        .errors_total = llm_errors_total.load(.monotonic),
        .retries_total = llm_retries_total.load(.monotonic),
        .timeouts_total = llm_timeouts_total.load(.monotonic),
        .latency_ms_sum = llm_latency_ms_sum.load(.monotonic),
        .latency_le_1s = llm_latency_le_1s.load(.monotonic),
        .latency_le_5s = llm_latency_le_5s.load(.monotonic),
        .latency_le_15s = llm_latency_le_15s.load(.monotonic),
        .latency_le_60s = llm_latency_le_60s.load(.monotonic),
    };
}

/// Cumulative buckets, so each is "at most this long" and the count above
/// `le_60s` is `requests_total` minus it.
fn noteLatency(duration_ms: u64) void {
    _ = llm_latency_ms_sum.fetchAdd(duration_ms, .monotonic);
    if (duration_ms <= 1_000) _ = llm_latency_le_1s.fetchAdd(1, .monotonic);
    if (duration_ms <= 5_000) _ = llm_latency_le_5s.fetchAdd(1, .monotonic);
    if (duration_ms <= 15_000) _ = llm_latency_le_15s.fetchAdd(1, .monotonic);
    if (duration_ms <= 60_000) _ = llm_latency_le_60s.fetchAdd(1, .monotonic);
}

fn noteTimeout() void {
    _ = llm_timeouts_total.fetchAdd(1, .monotonic);
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
    /// Parsed `Retry-After` (integer seconds, capped) if the response carried
    /// one, so the non-streaming retry loop can honor it like `chatStream`
    /// does instead of sleeping the fixed backoff on a rate limit the server
    /// already priced.
    retry_after_ns: ?u64 = null,
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

fn wireProviderForCredential(provider: *const config.Provider, cred: auth.Credential) !config.Provider {
    var wire = provider.wireProvider();
    if (cred.strategy == .oauth_refresh and provider.oauth_plugin.len > 0) {
        const plugin = oauth_plugins.find(provider.oauth_plugin) orelse return error.UnknownOAuthPlugin;
        wire.base_url = plugin.api_base_url;
    }
    return wire;
}

test "native OAuth switches to the plugin API while API keys keep their configured API" {
    const provider = config.Provider{ .name = "codex", .kind = .codex, .base_url = "https://api.openai.com/v1", .default_model = "gpt", .oauth_plugin = "codex" };
    const keyed = try wireProviderForCredential(&provider, .{ .strategy = .api_key });
    try std.testing.expectEqualStrings("https://api.openai.com/v1", keyed.base_url);
    const oauth = try wireProviderForCredential(&provider, .{ .strategy = .oauth_refresh });
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex", oauth.base_url);
}

test "every native OAuth transport routes keys and grants independently" {
    for (oauth_plugins.plugins) |plugin| {
        const provider = config.Provider{ .name = plugin.name, .kind = plugin.provider_kind, .base_url = "https://key-api.test/v1", .default_model = "model", .oauth_plugin = plugin.name };
        const keyed = try wireProviderForCredential(&provider, .{ .strategy = .api_key });
        try std.testing.expectEqualStrings("https://key-api.test/v1", keyed.base_url);
        const oauth = try wireProviderForCredential(&provider, .{ .strategy = .oauth_refresh });
        try std.testing.expectEqualStrings(plugin.api_base_url, oauth.base_url);
    }
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

    // Endpoint override: a model can point at a different host/path than
    // its provider entry (local vLLM vs the hosted API). URL only — auth
    // and the rest of the request still come from `provider`.
    const wire = try wireProviderForCredential(provider, cred);
    const url = try impl.endpointUrl(ctx.gpa, &wire, false);
    defer ctx.gpa.free(url);

    var client: std.http.Client = .{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();
    // Ordering here is load-bearing: defers unwind last-in-first-out, so
    // `disarm` runs *before* `client.deinit()`. A caller's timeout thread can
    // therefore never be inside `trigger` holding this client at the moment it
    // is destroyed — `disarm` blocks until that call finishes.
    if (ctx.abort) |a| a.arm(ctx.io, &client);
    defer if (ctx.abort) |a| a.disarm(ctx.io);

    noteRequest();
    warnIfCacheCold(ctx, provider);
    var attempt: u32 = 0;
    var outcome: FetchOutcome = undefined;
    while (true) {
        attempt += 1;
        try rate_limit.waitFor(ctx.io, ctx.gpa, provider);
        outcome = doFetch(ctx, &client, url, body, cred, impl, provider, arena, err_detail) catch |err| {
            if (try retryAfterTransportError(ctx, arena, provider, attempt, llm_t0, err)) continue;
            return err;
        };
        if (isRetryable(outcome.status) and attempt < max_attempts and !abortWasTriggered(ctx)) {
            noteRetry();
            // The provider priced the wait in `Retry-After` (capped in
            // `parseRetryAfterNs`); fall back to the fixed backoff only when
            // the header is absent. Sleeping the fixed backoff through a
            // `Retry-After: 0` "retry now" makes a brief rate limit look like
            // a stall and stretches every retry storm.
            const delay = outcome.retry_after_ns orelse retryDelayNs(attempt, provider.name);
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
            err_detail.* = try std.fmt.allocPrint(arena, "HTTP {d}", .{@intFromEnum(outcome.status)});
        }
        var log_detail_buf: [redact.max_log_detail_len]u8 = undefined;
        const log_detail = redact.forLog(&log_detail_buf, err_detail.* orelse "ApiError");
        log.log(.error_, "provider '{s}' returned HTTP {d} after {d} attempt(s): {s}", .{
            provider.name, @intFromEnum(outcome.status), attempt, log_detail,
        });
        noteError();
        var stats_detail_buf: [redact.max_log_detail_len]u8 = undefined;
        recordFailure(ctx, arena, provider, @intFromEnum(outcome.status), redact.forStats(&stats_detail_buf, err_detail.* orelse "ApiError"), elapsedMs(ctx.io, llm_t0));
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
        var log_detail_buf: [redact.max_log_detail_len]u8 = undefined;
        const log_detail = redact.forLog(&log_detail_buf, err_detail.* orelse @errorName(err));
        log.log(.error_, "provider '{s}' returned an unreadable response: {s} ({s})", .{
            provider.name, @errorName(err), log_detail,
        });
        noteError();
        var stats_detail_buf: [redact.max_log_detail_len]u8 = undefined;
        recordFailure(ctx, arena, provider, @intFromEnum(outcome.status), redact.forStats(&stats_detail_buf, err_detail.* orelse @errorName(err)), elapsedMs(ctx.io, llm_t0));
        return err;
    };
    const ms: u64 = @intCast(@divTrunc(llm_t0.durationTo(std.Io.Timestamp.now(ctx.io, .awake)).nanoseconds, std.time.ns_per_ms));
    recordUsage(ctx, arena, provider, resp.usage, ms);
    var out = resp;
    applyReasoningFormat(provider, &out);
    return out;
}

/// Parse-side reasoning override (`reasoning_format`). The same weights can
/// answer differently by host: the DeepSeek API puts reasoning in its own
/// field while a local vLLM inlines `<think>...</think>` into the content.
/// Slices point into the same arena the response came from, so re-slicing
/// needs no copies.
fn applyReasoningFormat(provider: *const config.Provider, resp: *types.ChatResponse) void {
    switch (provider.effectiveReasoningFormat()) {
        .auto => {},
        .none => resp.reasoning = null,
        .think_tag => {
            const content = resp.message.content orelse return;
            const t = std.mem.trimStart(u8, content, " \t\r\n");
            if (!std.mem.startsWith(u8, t, "<think>")) return;
            const inner = t["<think>".len..];
            // Unclosed tag: the model is still "thinking" or truncated;
            // leave the content alone rather than guess at a boundary.
            const close = std.mem.find(u8, inner, "</think>") orelse return;
            const thought = std.mem.trim(u8, inner[0..close], " \t\r\n");
            if (resp.reasoning == null and thought.len > 0) resp.reasoning = thought;
            resp.message.content = std.mem.trimStart(u8, inner[close + "</think>".len ..], " \t\r\n");
        },
    }
}

fn boundedChatTask(
    ctx: *Ctx,
    arena: std.mem.Allocator,
    params: providers.RequestParams,
    err_detail: *?[]const u8,
    done: *std.Io.Event,
) anyerror!types.ChatResponse {
    defer done.set(ctx.io);
    return chat(ctx, arena, params, err_detail);
}

/// `chat` under a wall-clock ceiling. A timeout shuts down the worker's
/// armed HTTP connections before cancellation so a stalled socket cannot
/// wedge the caller while it waits for the concurrent task to unwind.
/// A zero timeout preserves the unbounded `chat` behaviour.
pub fn chatWithTimeout(
    ctx: *Ctx,
    arena: std.mem.Allocator,
    params: providers.RequestParams,
    err_detail: *?[]const u8,
    timeout_ms: u32,
) anyerror!types.ChatResponse {
    if (timeout_ms == 0) return chat(ctx, arena, params, err_detail);

    var done: std.Io.Event = .unset;
    var abort: Abort = .{};
    const previous_abort = ctx.abort;
    ctx.abort = &abort;
    defer ctx.abort = previous_abort;

    var future = ctx.io.concurrent(boundedChatTask, .{ ctx, arena, params, err_detail, &done }) catch
        return error.SystemResources;
    const deadline: std.Io.Clock.Timestamp = .fromNow(ctx.io, .{
        .clock = .awake,
        .raw = .{ .nanoseconds = @as(i96, timeout_ms) * std.time.ns_per_ms },
    });
    while (!done.isSet()) {
        done.waitTimeout(ctx.io, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout => {
                if (done.isSet()) break;
                if (deadline.durationFromNow(ctx.io).raw.nanoseconds > 0) continue;
                // One trigger is not enough. A short deadline can lapse
                // before the worker has armed the abort, or armed it before
                // its connection reached the pool; a trigger landing in that
                // window shuts down nothing, the worker then parks in a read,
                // and `future.cancel` cannot rescue a blocked read (see
                // `Abort`) — it wedges this thread alongside the worker.
                // Keep triggering until the worker itself reports done, and
                // only then reap the future.
                while (!done.isSet()) {
                    abort.trigger(ctx.io);
                    const tick: std.Io.Clock.Timestamp = .fromNow(ctx.io, .{
                        .clock = .awake,
                        .raw = .{ .nanoseconds = @as(i96, deadline_watch_tick_ms) * std.time.ns_per_ms },
                    });
                    done.waitTimeout(ctx.io, .{ .deadline = tick }) catch |werr| switch (werr) {
                        error.Timeout => {},
                        error.Canceled => break,
                    };
                }
                _ = future.cancel(ctx.io) catch {};
                noteTimeout();
                return error.Timeout;
            },
            error.Canceled => {
                abort.trigger(ctx.io);
                _ = future.cancel(ctx.io) catch {};
                return error.Canceled;
            },
        };
    }
    return future.await(ctx.io);
}

/// How often the watchdog wakes to compare the liveness counter against its
/// deadline. Small enough that a lapsed deadline is acted on promptly, large
/// enough that a long stream costs a few thousand wakeups rather than a busy
/// loop. Not added latency: the request thread sets `done` on its way out and
/// that wakes the wait immediately.
const deadline_watch_tick_ms: u64 = 250;

/// A deadline enforced from *another* thread while the request stays on the
/// caller's.
///
/// Which thread runs the request is not an implementation detail here.
/// `chatWithTimeout` moves `chat` onto a worker, which is fine for the
/// side-channel callers that use it (a classifier ping has no callback), but
/// the agent's own streaming turn drives `on_delta` through three threadlocals
/// — `stream_tally` and `ttsr_guard` in the agent loop, `run_stream_socket` in
/// the HTTP layer — and a threadlocal read on a worker thread is a different
/// variable. Streaming from a worker would silently stop rendering tokens,
/// blind the time-to-stop-rule guard, and leave the fallback chain believing
/// no content had arrived. Log context (`util/log.zig`) is threadlocal too.
///
/// So the watchdog goes to the worker instead. All it needs is a clock, a
/// counter and `Abort.trigger`, which is cross-thread by construction. This
/// also sidesteps the `Io.Future.cancel` wedge described on `Abort`: nothing
/// cancels a blocked thread here, the socket shutdown simply makes its read
/// return and the request unwinds itself.
const DeadlineWatch = struct {
    io: std.Io,
    abort: *Abort,
    /// Liveness counter, or null when the whole call is one deadline.
    progress: ?*std.atomic.Value(u64),
    /// Budget before anything has arrived.
    first_ms: u32,
    /// Budget between arrivals. Unused while `progress` is null.
    idle_ms: u32,
    provider_name: []const u8,
    streaming: bool,
    done: std.Io.Event = .unset,
    fired: std.atomic.Value(bool) = .init(false),

    fn watch(self: *DeadlineWatch) void {
        var seen: u64 = 0;
        var since = std.Io.Timestamp.now(self.io, .awake);
        while (!self.done.isSet()) {
            const tick: std.Io.Clock.Timestamp = .fromNow(self.io, .{
                .clock = .awake,
                .raw = .{ .nanoseconds = @as(i96, deadline_watch_tick_ms) * std.time.ns_per_ms },
            });
            self.done.waitTimeout(self.io, .{ .deadline = tick }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return,
            };
            if (self.done.isSet()) return;

            if (self.progress) |counter| {
                const now = counter.load(.acquire);
                if (now != seen) {
                    seen = now;
                    since = std.Io.Timestamp.now(self.io, .awake);
                    continue;
                }
            }
            // Which clock applies is decided by whether anything has arrived
            // yet, not by how long the call has been running.
            const budget_ms: u64 = if (seen == 0) self.first_ms else self.idle_ms;
            if (budget_ms == 0) continue;
            if (elapsedMs(self.io, since) < budget_ms) continue;

            if (self.streaming) {
                log.log(.error_, "provider '{s}' {s} for {d}ms; abandoning the stream", .{
                    self.provider_name,
                    if (seen == 0) "sent nothing" else "went quiet mid-stream",
                    budget_ms,
                });
            } else {
                log.log(.error_, "provider '{s}' did not answer within {d}ms; abandoning the request", .{ self.provider_name, budget_ms });
            }
            // Order matters: record the verdict before unblocking the reader,
            // so the request thread cannot finish and read `fired` as false.
            self.fired.store(true, .release);
            // Retrigger until the request thread reports done. The request
            // runs on the caller's thread here, so a one-shot trigger that
            // lands before it armed the abort — or before its connection
            // reached the pool — unblocks nothing, and with this watchdog
            // gone that thread would park in its read forever
            // (docs/reports/investigations/2026-08-18-bounded-chat-abort-test-hangs.md).
            while (!self.done.isSet()) {
                self.abort.trigger(self.io);
                const retick: std.Io.Clock.Timestamp = .fromNow(self.io, .{
                    .clock = .awake,
                    .raw = .{ .nanoseconds = @as(i96, deadline_watch_tick_ms) * std.time.ns_per_ms },
                });
                self.done.waitTimeout(self.io, .{ .deadline = retick }) catch |err| switch (err) {
                    error.Timeout => {},
                    error.Canceled => return,
                };
            }
            return;
        }
    }
};

/// `chatStream` under two deadlines, because a stream has two ways to hang and
/// one clock cannot describe both.
///
/// `first_byte_ms` bounds the silence *before* the response starts — connect,
/// request, response head, first SSE bytes. That is the failure a whole-call
/// ceiling would also catch, and the one an agent run actually hit: a provider
/// that accepted the connection and then said nothing, with no error to retry
/// because a call that never returns never produces one.
///
/// `idle_ms` bounds the gap *between* reads once bytes are flowing. It has to
/// be separate: a legitimate answer can stream for far longer than any sensible
/// whole-call ceiling, so bounding total duration would abandon healthy work.
/// What a healthy stream does not do is fall silent mid-answer.
///
/// The two are not interchangeable, and arming only `idle_ms` leaves a real
/// hole. `chatStream` reads with `readSliceShort`, which returns only once its
/// buffer is full or the stream ends, so "a read completed" is a coarse signal:
/// a provider that emits less than one buffer and then falls silent never
/// completes one, and to this watchdog looks exactly like a provider that never
/// answered at all. That case is the *first-byte* clock's, which is why it has
/// to stay armed even when a stream is expected.
///
/// Either at 0 disables that clock; both at 0 is plain `chatStream`.
pub fn chatStreamWithTimeout(
    ctx: *Ctx,
    arena: std.mem.Allocator,
    params: providers.RequestParams,
    err_detail: *?[]const u8,
    on_delta: *const fn ([]const u8) void,
    stop_flag: ?*std.atomic.Value(bool),
    first_byte_ms: u32,
    idle_ms: u32,
) anyerror!types.ChatResponse {
    if (first_byte_ms == 0 and idle_ms == 0) {
        return chatStream(ctx, arena, params, err_detail, on_delta, stop_flag);
    }

    var progress = std.atomic.Value(u64).init(0);
    const previous_progress = ctx.stream_progress;
    ctx.stream_progress = &progress;
    defer ctx.stream_progress = previous_progress;

    return underDeadline(ctx, .{
        .progress = &progress,
        .first_ms = first_byte_ms,
        .idle_ms = idle_ms,
        .provider_name = params.provider.name,
        .streaming = true,
    }, struct {
        fn call(c: *Ctx, a: std.mem.Allocator, p: providers.RequestParams, d: *?[]const u8, cb: *const fn ([]const u8) void, sf: ?*std.atomic.Value(bool)) anyerror!types.ChatResponse {
            return chatStream(c, a, p, d, cb, sf);
        }
    }.call, .{ ctx, arena, params, err_detail, on_delta, stop_flag });
}

/// `chat` under a whole-call ceiling, with the request left on the caller's
/// thread. Same clock `chatWithTimeout` applies, opposite arrangement: this is
/// the one the agent loop uses, because moving its request to a worker would
/// take the run's log context (`util/log.zig` `context` is threadlocal) off
/// every provider line the call emits. `chatWithTimeout` stays as it is for the
/// side-channel callers already built on it.
///
/// 0 is unbounded, which is plain `chat`.
pub fn chatWithDeadline(
    ctx: *Ctx,
    arena: std.mem.Allocator,
    params: providers.RequestParams,
    err_detail: *?[]const u8,
    timeout_ms: u32,
) anyerror!types.ChatResponse {
    if (timeout_ms == 0) return chat(ctx, arena, params, err_detail);
    // No progress counter: a non-streaming call has exactly one event to wait
    // for, so `first_ms` is the whole budget and the idle clock never applies.
    return underDeadline(ctx, .{
        .progress = null,
        .first_ms = timeout_ms,
        .idle_ms = 0,
        .provider_name = params.provider.name,
        .streaming = false,
    }, struct {
        fn call(c: *Ctx, a: std.mem.Allocator, p: providers.RequestParams, d: *?[]const u8) anyerror!types.ChatResponse {
            return chat(c, a, p, d);
        }
    }.call, .{ ctx, arena, params, err_detail });
}

/// What a `DeadlineWatch` needs that is not the request itself.
const DeadlineSpec = struct {
    progress: ?*std.atomic.Value(u64),
    first_ms: u32,
    idle_ms: u32,
    provider_name: []const u8,
    streaming: bool,
};

/// Runs `request` on this thread with a watchdog beside it, and reports a
/// lapsed deadline as `error.Timeout`.
///
/// The watchdog's abort makes the blocked read return, so `request` fails with
/// whatever transport error that produces; `fired` is what distinguishes "the
/// connection dropped" from "we dropped it", and it is checked before the
/// request's own result because that result is a consequence of the abort.
fn underDeadline(
    ctx: *Ctx,
    spec: DeadlineSpec,
    comptime request: anytype,
    args: anytype,
) anyerror!types.ChatResponse {
    var abort: Abort = .{};
    const previous_abort = ctx.abort;
    ctx.abort = &abort;
    defer ctx.abort = previous_abort;

    var watch: DeadlineWatch = .{
        .io = ctx.io,
        .abort = &abort,
        .progress = spec.progress,
        .first_ms = spec.first_ms,
        .idle_ms = spec.idle_ms,
        .provider_name = spec.provider_name,
        .streaming = spec.streaming,
    };
    var future = ctx.io.concurrent(DeadlineWatch.watch, .{&watch}) catch return error.SystemResources;

    const result = @call(.auto, request, args);

    // Wake the watchdog before awaiting it, or this joins a thread that is
    // still sleeping out its tick.
    watch.done.set(ctx.io);
    future.await(ctx.io);

    if (watch.fired.load(.acquire)) {
        noteTimeout();
        return error.Timeout;
    }
    return result;
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
/// Public so the proxy's token-stats row uses the same math.
pub fn totalCost(provider: *const config.Provider, u: types.Usage) f64 {
    const active = provider.activeModel();
    var cost: f64 = 0;
    if (active.cost_per_1m_input) |ci| cost += promptCost(u, ci);
    if (active.cost_per_1m_output) |co| cost += @as(f64, @floatFromInt(u.completion_tokens)) / 1_000_000.0 * co;
    return cost;
}

fn cacheTtlMs(provider: *const config.Provider) u64 {
    return provider.cacheTtlMs(providers.forKind(provider.kind).cache_ttl_ms);
}

fn warnIfCacheCold(ctx: *Ctx, provider: *const config.Provider) void {
    const ttl = cacheTtlMs(provider);
    if (ttl == 0) return;
    const now_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(ctx.io, .real).nanoseconds, std.time.ns_per_ms));
    const model = provider.activeModelName();
    const last = cache_cold.lastOk(provider.name, model);
    if (cache_cold.shouldWarn(last, now_ms, ttl)) {
        const idle_s = (now_ms - last) / 1000;
        log.log(.warn, "prompt cache likely cold for '{s}'/{s} ({d}s idle, ttl {d}s)", .{
            provider.name, model, idle_s, ttl / 1000,
        });
    }
}

/// Records one completion in the global token-usage log (best-effort). The
/// caller supplies `duration_ms`; 0 means "unknown" (chat() times the whole
/// call via `llm_t0` where the retry loop hides the true duration).
fn recordUsage(ctx: *Ctx, arena: std.mem.Allocator, provider: *const config.Provider, usage: ?types.Usage, duration_ms: u64) void {
    // Ahead of every guard below: latency is a RED signal, not a token-stats
    // detail, so turning `modules.token_stats` off must not also blind the
    // operator to how long the provider is taking. Same reason it sits before
    // the empty-usage return -- a call that reported no tokens still took time.
    noteLatency(duration_ms);
    // Cache-cold is the same class of signal: a last-ok stamp and unexpected
    // miss must land even when modules.token_stats is off or usage is empty
    // of prompt/completion counts (ADR 0035). afterUsage no-ops when the
    // provider reported no cache accounting.
    if (usage) |u| {
        const now_ms: u64 = @intCast(@divTrunc(std.Io.Timestamp.now(ctx.io, .real).nanoseconds, std.time.ns_per_ms));
        if (cache_cold.afterUsage(
            provider.name,
            provider.activeModelName(),
            u.prompt_cache_hit_tokens,
            u.prompt_cache_miss_tokens,
            now_ms,
            cacheTtlMs(provider),
        )) {
            log.log(.warn, "unexpected prompt-cache miss for '{s}'/{s}", .{
                provider.name, provider.activeModelName(),
            });
        }
    }
    const cfg = ctx.cfg orelse return;
    const u = usage orelse return;
    if (u.total_tokens == 0 and u.prompt_tokens == 0 and u.completion_tokens == 0) return;

    // --stream is independent of the token_stats module: one wants a live
    // reading on stdout, the other a durable log in state/, and a monitor
    // should not depend on the log being switched on.
    stream.emitUsage(ctx.io, .{
        .provider = provider.name,
        .model = provider.activeModelName(),
        .prompt_tokens = u.prompt_tokens,
        .completion_tokens = u.completion_tokens,
        .total_tokens = u.total_tokens,
        .cache_hit = u.prompt_cache_hit_tokens,
        .duration_ms = duration_ms,
    });

    if (!cfg.modules.token_stats) return;

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
        .thinking_level = ctx.thinking_level,
        .thinking_classifier_ms = ctx.thinking_classifier_ms,
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
    // Before the guards, for the reason given in `recordUsage`.
    noteLatency(duration_ms);
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
        .thinking_level = ctx.thinking_level,
        .thinking_classifier_ms = ctx.thinking_classifier_ms,
    });
}

fn elapsedMs(io: std.Io, started: std.Io.Timestamp) u64 {
    const ns = started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    return @intCast(@max(0, @divTrunc(ns, std.time.ns_per_ms)));
}

/// Jitter is hashed from the attempt and the provider name, not read off the
/// clock: the awake clock's nanosecond phase varies between runs of the same
/// seed, so a clock-derived delay would make a retry-timing-sensitive failure
/// unreproducible even with `agent.seed` pinned. A pure function of state the
/// run already fixed keeps two identical runs on identical backoff schedules.
fn retryDelayNs(attempt: u32, salt: []const u8) u64 {
    const base: u64 = @as(u64, attempt) * std.time.ns_per_s;
    const jitter: u64 = std.hash.Wyhash.hash(0x9E3779B97F4A7C15 ^ @as(u64, attempt), salt) % 500_000_000;
    return base + jitter;
}

/// Ceiling on a provider-supplied Retry-After so a hostile or misconfigured
/// header cannot park the retry loop for minutes. Three attempts at this
/// cap is already a long wait for a single turn.
const retry_after_cap_ns: u64 = 30 * std.time.ns_per_s;

/// Parse `Retry-After` as integer seconds. HTTP-date values are ignored and
/// the caller falls back to `retryDelayNs`. `0` is a valid "retry now".
fn parseRetryAfterNs(value: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return null;
    const secs = std.fmt.parseInt(u64, trimmed, 10) catch return null;
    const ns = secs *| std.time.ns_per_s;
    return @min(ns, retry_after_cap_ns);
}

fn headerValueIgnoreCase(head: std.http.Client.Response.Head, name: []const u8) ?[]const u8 {
    var it = head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

fn retryDelayForHead(attempt: u32, head: std.http.Client.Response.Head, salt: []const u8) u64 {
    if (headerValueIgnoreCase(head, "retry-after")) |v| {
        if (parseRetryAfterNs(v)) |ns| return ns;
    }
    return retryDelayNs(attempt, salt);
}

fn sendStreamBody(req: *std.http.Client.Request, body: []const u8) !void {
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(body);
    try body_writer.end();
    try req.connection.?.flush();
}

/// The transport-failure arm every attempt of the retry loop shares. Returns
/// true once the backoff has been slept and the attempt should be retried, and
/// false after the give-up has been logged and recorded, leaving the caller to
/// return the error it caught.
fn retryAfterTransportError(
    ctx: *Ctx,
    arena: std.mem.Allocator,
    provider: *const config.Provider,
    attempt: u32,
    llm_t0: std.Io.Timestamp,
    err: anyerror,
) !bool {
    if (!abortWasTriggered(ctx) and attempt < max_attempts and isRetryableTransport(err)) {
        noteRetry();
        try sleepRetry(ctx.io, attempt, provider.name, 0, @errorName(err));
        return true;
    }
    log.log(.error_, "request to '{s}' failed: {s} (attempt {d}/{d})", .{
        provider.name, @errorName(err), attempt, max_attempts,
    });
    noteError();
    recordFailure(ctx, arena, provider, 0, @errorName(err), elapsedMs(ctx.io, llm_t0));
    return false;
}

fn sleepRetry(io: std.Io, attempt: u32, provider_name: []const u8, http_status: u16, reason: []const u8) !void {
    const delay = retryDelayNs(attempt, provider_name);
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

/// The one `err_detail` shape for an HTTP >= 400 reply, shared by the
/// non-streaming and streaming paths: the provider's parsed error message when
/// its codec recognises the body, else the bare status — but never silence.
/// When no codec recognises the body, a capped, whitespace-flattened snippet
/// goes to the log at warn: a failing provider whose one explanatory line is
/// dropped on the floor cannot be diagnosed, which is how google-vertex's
/// every-request 400 stayed unroot-caused for a day
/// (docs/reports/investigations/2026-08-19-vertex-anthropic-400.md). The
/// caller-facing string still never carries raw body bytes.
fn httpErrorDetail(
    arena: std.mem.Allocator,
    impl: *const providers.Provider,
    provider_name: []const u8,
    status_code: u16,
    body: []const u8,
) ![]const u8 {
    if (impl.parseErrorDetail(arena, body)) |msg| {
        const capped = redact.forCaller(arena, msg) catch utf8.cap(msg, redact.max_caller_detail_len);
        return std.fmt.allocPrint(arena, "HTTP {d}: {s}", .{ status_code, capped });
    }
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    // Valid UTF-8 only: a compressed or binary body capped mid-byte would put
    // garbage on the operator's terminal, and says nothing anyway.
    if (trimmed.len != 0 and std.unicode.utf8ValidateSlice(trimmed[0..@min(trimmed.len, redact.max_log_detail_len)])) {
        var snippet_buf: [redact.max_log_detail_len]u8 = undefined;
        log.log(.warn, "provider '{s}' returned HTTP {d} with a body no codec recognised ({d} bytes): {s}", .{
            provider_name, status_code, body.len, redact.forLog(&snippet_buf, trimmed),
        });
    }
    return std.fmt.allocPrint(arena, "HTTP {d}", .{status_code});
}

test "httpErrorDetail keeps the parsed message and never the raw body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const impl = providers.forKind(.vertex_anthropic);

    // The array-wrapped Google envelope is the one Vertex rawPredict answers
    // with; before the vertex kinds learned it, this exact shape reached the
    // operator as a bare "HTTP 400".
    const google_array =
        \\[{"error":{"code":400,"message":"Request contains an invalid argument.","status":"INVALID_ARGUMENT"}}]
    ;
    try std.testing.expectEqualStrings(
        "HTTP 400: INVALID_ARGUMENT: Request contains an invalid argument.",
        try httpErrorDetail(arena, impl, "google-vertex-anthropic", 400, google_array),
    );

    // Unrecognised body: the caller string stays the bare status.
    try std.testing.expectEqualStrings(
        "HTTP 502",
        try httpErrorDetail(arena, impl, "google-vertex-anthropic", 502, "<html>bad gateway</html>"),
    );

    // Empty body: nothing to log, bare status.
    try std.testing.expectEqualStrings(
        "HTTP 500",
        try httpErrorDetail(arena, impl, "google-vertex-anthropic", 500, ""),
    );
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

    // Not `client.fetch`: that helper returns only the status and discards
    // the response head, so the retry loop could never see a `Retry-After`
    // header. Mirror its mechanics (request/send/receiveHead/read body) with
    // the head kept alive long enough to parse the header, exactly like the
    // streaming path in `chatStream` does.
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;

    var req = client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .headers = headers,
        .extra_headers = extra[0..extra_len],
    }) catch |err| {
        err_detail.* = std.fmt.allocPrint(arena, "couldn't reach '{s}' ({s})", .{ provider.name, @errorName(err) }) catch null;
        return err;
    };
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    sendStreamBody(&req, body) catch |err| {
        err_detail.* = std.fmt.allocPrint(arena, "couldn't reach '{s}' ({s})", .{ provider.name, @errorName(err) }) catch null;
        return err;
    };

    var redirect_buffer: [http_scratch_buf_bytes]u8 = undefined;
    var response = req.receiveHead(&redirect_buffer) catch |err| {
        err_detail.* = std.fmt.allocPrint(arena, "couldn't reach '{s}' ({s})", .{ provider.name, @errorName(err) }) catch null;
        return err;
    };

    // Read the header before the body read initializes the response stream:
    // that call invalidates the head's string slices, and the retry decision
    // happens only after the body has been consumed.
    const retry_after_ns: ?u64 = if (headerValueIgnoreCase(response.head, "retry-after")) |v| parseRetryAfterNs(v) else null;
    const status = response.head.status;

    // The client advertises gzip and providers compress bodies too, so the
    // raw reader would hand back binary. Decompress exactly as `fetch` does
    // (a no-op on identity-encoded bodies).
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try ctx.gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try ctx.gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (decompress_buffer.len > 0) ctx.gpa.free(decompress_buffer);
    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = reader.streamRemaining(&w) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };

    if (@intFromEnum(status) >= 400) {
        err_detail.* = try httpErrorDetail(arena, impl, provider.name, @intFromEnum(status), resp_buf[0..w.end]);
        var log_detail_buf: [redact.max_log_detail_len]u8 = undefined;
        log.log(.debug, "provider '{s}' returned {s}", .{ provider.name, redact.forLog(&log_detail_buf, err_detail.*.?) });
    }

    return .{
        .status = status,
        .retry_after_ns = retry_after_ns,
        .body = try ctx.gpa.dupe(u8, resp_buf[0..w.end]),
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

    // Same endpoint override as chat(): URL only, auth stays the provider's.
    const wire = try wireProviderForCredential(provider, cred);
    const url = try impl.endpointUrl(ctx.gpa, &wire, true);
    defer ctx.gpa.free(url);

    var client: std.http.Client = .{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();
    // Ordering here is load-bearing: defers unwind last-in-first-out, so
    // `disarm` runs *before* `client.deinit()`. A caller's timeout thread can
    // therefore never be inside `trigger` holding this client at the moment it
    // is destroyed — `disarm` blocks until that call finishes.
    if (ctx.abort) |a| a.arm(ctx.io, &client);
    defer if (ctx.abort) |a| a.disarm(ctx.io);

    noteRequest();
    warnIfCacheCold(ctx, provider);

    var headers = baseHeaders();
    var extra: providers.ExtraHeaders = undefined;
    var extra_len: usize = 0;
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;

    // Request lives in this slot so Response.request stays valid across the
    // rest of the call. A retry deinits the previous attempt before opening
    // a new one; the successful request is deferred to the function end.
    var req_slot: ?std.http.Client.Request = null;
    defer if (req_slot) |*r| r.deinit();
    var redirect_buffer: [http_scratch_buf_bytes]u8 = undefined;
    var response: std.http.Client.Response = undefined;
    var attempt: u32 = 0;
    while (true) {
        attempt += 1;
        if (stop_flag) |f| if (f.load(.acquire)) return error.Interrupted;
        if (req_slot) |*r| {
            r.deinit();
            req_slot = null;
        }
        try rate_limit.waitFor(ctx.io, ctx.gpa, provider);
        headers = baseHeaders();
        extra_len = impl.authHeaders(cred, &headers, &extra);

        const opened = client.request(.POST, uri, .{
            .redirect_behavior = .unhandled,
            .headers = headers,
            .extra_headers = extra[0..extra_len],
        }) catch |err| {
            if (try retryAfterTransportError(ctx, arena, provider, attempt, llm_t0, err)) continue;
            return err;
        };
        req_slot = opened;
        var req = &req_slot.?;

        req.transfer_encoding = .{ .content_length = body.len };
        // Request bodies contain the complete conversation, tool output, and
        // attachments. Debugging must never copy that user data into terminal or
        // CI logs; the byte count is enough to diagnose framing problems.
        if (ctx.environ_map.get("CLANKER_DEBUG_BODY") != null) {
            log.log(.debug, "LLM streaming request provider={s} bytes={d}", .{ provider.name, body.len });
        }
        sendStreamBody(req, body) catch |err| {
            if (try retryAfterTransportError(ctx, arena, provider, attempt, llm_t0, err)) continue;
            return err;
        };

        response = req.receiveHead(&redirect_buffer) catch |err| {
            if (try retryAfterTransportError(ctx, arena, provider, attempt, llm_t0, err)) continue;
            return err;
        };

        if (isRetryable(response.head.status) and attempt < max_attempts and !abortWasTriggered(ctx)) {
            noteRetry();
            const delay = retryDelayForHead(attempt, response.head, provider.name);
            log.log(.warn, "HTTP {d} from '{s}', retrying in {d}ms (attempt {d}/{d})", .{
                @intFromEnum(response.head.status), provider.name, delay / std.time.ns_per_ms, attempt, max_attempts,
            });
            try std.Io.sleep(ctx.io, .{ .nanoseconds = @intCast(delay) }, .awake);
            continue;
        }
        break;
    }

    if (@intFromEnum(response.head.status) >= 400) {
        // The client advertises gzip, and providers compress error bodies too:
        // the raw reader hands back binary, so the one line that says what is
        // wrong with the request arrives as garbage. Decompress it like the
        // success path does (a no-op on identity-encoded bodies).
        var err_transfer_buffer: [http_scratch_buf_bytes]u8 = undefined;
        var err_decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var err_decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&err_transfer_buffer, &err_decompress, &err_decompress_buffer);
        var ebuf: [err_body_buf_bytes]u8 = undefined;
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
        err_detail.* = try httpErrorDetail(arena, impl, provider.name, @intFromEnum(response.head.status), err_body.items);
        var log_detail_buf: [redact.max_log_detail_len]u8 = undefined;
        log.log(.error_, "provider '{s}' stream returned {s}", .{ provider.name, redact.forLog(&log_detail_buf, err_detail.*.?) });
        noteError();
        var stats_detail_buf: [redact.max_log_detail_len]u8 = undefined;
        recordFailure(ctx, arena, provider, @intFromEnum(response.head.status), redact.forStats(&stats_detail_buf, err_detail.*.?), elapsedMs(ctx.io, llm_t0));
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
    var transfer_buffer: [http_scratch_buf_bytes]u8 = undefined;
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);
    var buf: [http_scratch_buf_bytes]u8 = undefined;
    var sse: std.ArrayList(u8) = .empty;
    defer sse.deinit(ctx.gpa);
    var sse_done = false;
    var at_eof = false;
    var ttft_ms: ?u64 = null;
    // Frames already consumed from the front of `sse.items` (the parse
    // cursor). `frame` is a view into sse.items, so every frame is handled
    // fully before the cursor advances; the consumed prefix is compacted
    // away once per read chunk instead of once per frame, so a chunk that
    // coalesces many tiny frames does not memmove the whole remainder K
    // times (the old shift-per-frame was quadratic in the frame count).
    var sse_consumed: usize = 0;
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
        } else {
            // Bytes arrived, so the stream is alive: tell any watchdog before
            // parsing them. Every read counts, not every content delta — a
            // provider sending SSE keepalives is answering, and killing it for
            // producing no text would abandon a healthy slow stream.
            if (ctx.stream_progress) |counter| _ = counter.fetchAdd(1, .release);
            try appendResponseBytes(&sse, ctx.gpa, buf[0..n], resp_cap);
        }
        // Process complete frames (data: ... blank line), starting the search
        // at the parse cursor so consumed bytes are never rescanned.
        var frame_start = sse_consumed;
        while (std.mem.find(u8, sse.items[frame_start..], "\n\n")) |off| {
            const frame_end = frame_start + off;
            const frame = sse.items[frame_start..frame_end];
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
                if (ttft_ms == null) ttft_ms = elapsedMs(ctx.io, llm_t0);
                try acc.apply(ev, on_delta);
            }
            frame_start = frame_end + 2;
            if (frame_done) {
                sse_done = true;
                break;
            }
        }
        // Compact the consumed prefix once per chunk so the next read appends
        // to an empty tail instead of a buffer that grows for the stream's
        // whole life.
        sse_consumed = frame_start;
        if (sse_consumed > 0) {
            const rest = sse.items[sse_consumed..];
            std.mem.copyForwards(u8, sse.items[0..rest.len], rest);
            sse.items.len = rest.len;
            sse_consumed = 0;
        }
        if (at_eof) break;
    }

    var resp = try acc.finish();
    const ms: u64 = @intCast(@divTrunc(llm_t0.durationTo(std.Io.Timestamp.now(ctx.io, .awake)).nanoseconds, std.time.ns_per_ms));
    resp.ttft_ms = ttft_ms;
    applyReasoningFormat(provider, &resp);
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

test "reasoning_format think_tag splits content into reasoning and answer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = try config.Provider.single(arena, "vllm", "http://127.0.0.1:8000/v1", .openai_compat, "deepseek", .{ .max_tokens = 64, .reasoning_format = .think_tag });
    var resp = types.ChatResponse{ .message = .{ .role = .assistant, .content = "<think>step by step</think>\nfinal answer" } };
    applyReasoningFormat(&p, &resp);
    try std.testing.expectEqualStrings("step by step", resp.reasoning.?);
    try std.testing.expectEqualStrings("final answer", resp.message.content.?);

    // Unclosed tag stays untouched rather than guessing a boundary.
    var open = types.ChatResponse{ .message = .{ .role = .assistant, .content = "<think>never closed" } };
    applyReasoningFormat(&p, &open);
    try std.testing.expect(open.reasoning == null);
    try std.testing.expectEqualStrings("<think>never closed", open.message.content.?);

    // auto (a provider with no override anywhere) leaves the native parse alone.
    const auto_p = try config.Provider.single(arena, "api", "https://api.deepseek.com", .openai_compat, "deepseek", .{ .max_tokens = 64 });
    var plain = types.ChatResponse{ .message = .{ .role = .assistant, .content = "<think>x</think>y" } };
    applyReasoningFormat(&auto_p, &plain);
    try std.testing.expectEqualStrings("<think>x</think>y", plain.message.content.?);

    // none discards a provider-native reasoning field.
    const none_p = try config.Provider.single(arena, "q", "https://q.test/v1", .openai_compat, "m", .{ .max_tokens = 64, .reasoning_format = .none });
    var dropped = types.ChatResponse{ .message = .{ .role = .assistant, .content = "y" }, .reasoning = "secret chain" };
    applyReasoningFormat(&none_p, &dropped);
    try std.testing.expect(dropped.reasoning == null);
}

test "a model's base_url/path override the provider's for the URL only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = try config.Provider.single(arena, "deepseek", "https://api.deepseek.com", .openai_compat, "deepseek-v4-pro", .{ .max_tokens = 64, .base_url = "http://127.0.0.1:8000/v1", .path = "/custom/completions" });
    const wire = p.wireProvider();
    try std.testing.expectEqualStrings("http://127.0.0.1:8000/v1", wire.base_url);
    try std.testing.expectEqualStrings("/custom/completions", wire.path.?);
    // Auth-side fields are untouched on the original.
    try std.testing.expectEqualStrings("https://api.deepseek.com", p.base_url);
}

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

test "Retry-After is integer seconds, capped, and ignores HTTP-date" {
    try std.testing.expectEqual(@as(?u64, 0), parseRetryAfterNs("0"));
    try std.testing.expectEqual(@as(?u64, 2 * std.time.ns_per_s), parseRetryAfterNs(" 2 "));
    try std.testing.expectEqual(@as(?u64, retry_after_cap_ns), parseRetryAfterNs("999"));
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfterNs(""));
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfterNs("Wed, 21 Oct 2015 07:28:00 GMT"));
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfterNs("-1"));
}

test "retry backoff jitter is a pure function of attempt and provider" {
    // Same inputs, same delay: a run replayed with the pinned seed must wait
    // exactly as long between retries as the run that failed, or a failure
    // whose outcome turns on retry timing cannot be reproduced.
    try std.testing.expectEqual(retryDelayNs(2, "openai"), retryDelayNs(2, "openai"));
    // Jitter stays inside its [base, base + 500ms) window.
    const delay = retryDelayNs(2, "openai");
    try std.testing.expect(delay >= 2 * std.time.ns_per_s);
    try std.testing.expect(delay < 2 * std.time.ns_per_s + 500_000_000);
    // Different providers on the same attempt do not sync their waits.
    try std.testing.expect(retryDelayNs(3, "openai") != retryDelayNs(3, "anthropic"));
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

test "chatStream retries a 429 then streams the next response" {
    const mock_server = @import("mock_server.zig");
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const mock = try mock_server.MockServer.start(io, std.testing.allocator, .openai_stream_after_429);
    defer mock.stop();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("MOCK_API_KEY", "test-key");

    const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{mock.port});
    defer std.testing.allocator.free(base_url);
    var arena_for_provider = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_for_provider.deinit();
    var provider = try config.Provider.single(arena_for_provider.allocator(), "mock-stream-429", base_url, .openai_compat, "mock", .{ .max_tokens = 64 });
    provider.api_key_env = "MOCK_API_KEY";

    var ctx = Ctx{ .io = io, .gpa = std.testing.allocator, .environ_map = &env };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const messages = [_]types.Message{.{ .role = .user, .content = "hi" }};
    const Noop = struct {
        fn cb(_: []const u8) void {}
    };
    var err_detail: ?[]const u8 = null;
    const resp = try chatStream(&ctx, arena, .{
        .provider = &provider,
        .messages = &messages,
    }, &err_detail, Noop.cb, null);
    try std.testing.expectEqualStrings("Hello from the mock stream", resp.message.content orelse "");
    try std.testing.expectEqual(@as(usize, 2), mock.captured.items.len);
}

test "bounded chat aborts a provider that never sends a response" {
    const mock_server = @import("mock_server.zig");
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const mock = try mock_server.MockServer.start(io, std.testing.allocator, .stall);
    defer mock.stop();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("MOCK_API_KEY", "test-key");

    const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{mock.port});
    defer std.testing.allocator.free(base_url);
    var provider_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer provider_arena.deinit();
    var provider = try config.Provider.single(provider_arena.allocator(), "mock-stall", base_url, .openai_compat, "mock", .{});
    provider.api_key_env = "MOCK_API_KEY";

    var ctx = Ctx{ .io = io, .gpa = std.testing.allocator, .environ_map = &env };
    var response_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer response_arena.deinit();
    const messages = [_]types.Message{.{ .role = .user, .content = "hi" }};
    var err_detail: ?[]const u8 = null;
    try std.testing.expectError(error.Timeout, chatWithTimeout(&ctx, response_arena.allocator(), .{
        .provider = &provider,
        .messages = &messages,
        .max_tokens = 1,
    }, &err_detail, 30));
    try std.testing.expect(ctx.abort == null);
}

test "bounded stream aborts a provider that sends nothing at all" {
    const mock_server = @import("mock_server.zig");
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const mock = try mock_server.MockServer.start(io, std.testing.allocator, .stall);
    defer mock.stop();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("MOCK_API_KEY", "test-key");

    const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{mock.port});
    defer std.testing.allocator.free(base_url);
    var provider_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer provider_arena.deinit();
    var provider = try config.Provider.single(provider_arena.allocator(), "mock-stream-stall", base_url, .openai_compat, "mock", .{});
    provider.api_key_env = "MOCK_API_KEY";

    var ctx = Ctx{ .io = io, .gpa = std.testing.allocator, .environ_map = &env };
    var response_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer response_arena.deinit();
    const messages = [_]types.Message{.{ .role = .user, .content = "hi" }};
    const Noop = struct {
        fn cb(_: []const u8) void {}
    };
    var err_detail: ?[]const u8 = null;
    // Only the first-byte clock is armed: nothing ever arrives, so the idle
    // clock never applies and an unbounded idle setting must not rescue it.
    try std.testing.expectError(error.Timeout, chatStreamWithTimeout(&ctx, response_arena.allocator(), .{
        .provider = &provider,
        .messages = &messages,
        .max_tokens = 1,
    }, &err_detail, Noop.cb, null, 300, 0));
    try std.testing.expect(ctx.abort == null);
    try std.testing.expect(ctx.stream_progress == null);
}

test "bounded stream abandons a stream that starts and then goes quiet" {
    const mock_server = @import("mock_server.zig");
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const mock = try mock_server.MockServer.start(io, std.testing.allocator, .stream_then_stall);
    defer mock.stop();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("MOCK_API_KEY", "test-key");

    const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{mock.port});
    defer std.testing.allocator.free(base_url);
    var provider_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer provider_arena.deinit();
    var provider = try config.Provider.single(provider_arena.allocator(), "mock-stream-quiet", base_url, .openai_compat, "mock", .{});
    provider.api_key_env = "MOCK_API_KEY";

    var ctx = Ctx{ .io = io, .gpa = std.testing.allocator, .environ_map = &env };
    var response_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer response_arena.deinit();
    const messages = [_]types.Message{.{ .role = .user, .content = "hi" }};
    const Seen = struct {
        var count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
        // The agent's real callback reads threadlocals (`stream_tally`,
        // `ttsr_guard`, `run_stream_socket`), so a delta delivered on any
        // thread but the caller's would read a different variable and silently
        // stop rendering tokens. Recording the thread is how that stays true.
        var thread: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
        fn cb(_: []const u8) void {
            _ = count.fetchAdd(1, .monotonic);
            thread.store(std.Thread.getCurrentId(), .release);
        }
    };
    Seen.count.store(0, .monotonic);
    Seen.thread.store(0, .monotonic);
    var err_detail: ?[]const u8 = null;
    // No first-byte clock at all: the mock delivers more than one read buffer
    // before going quiet, so reads complete, the stream counts as started, and
    // only the idle clock can end this. A whole-call ceiling would be
    // indistinguishable from cutting off a slow but healthy answer.
    try std.testing.expectError(error.Timeout, chatStreamWithTimeout(&ctx, response_arena.allocator(), .{
        .provider = &provider,
        .messages = &messages,
        .max_tokens = 1,
    }, &err_detail, Seen.cb, null, 0, 300));
    try std.testing.expect(Seen.count.load(.monotonic) > 0);
    try std.testing.expectEqual(std.Thread.getCurrentId(), Seen.thread.load(.acquire));
    try std.testing.expect(ctx.abort == null);
    try std.testing.expect(ctx.stream_progress == null);
}

test "a deadlined non-streaming call keeps the request on the calling thread" {
    const mock_server = @import("mock_server.zig");
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const mock = try mock_server.MockServer.start(io, std.testing.allocator, .stall);
    defer mock.stop();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("MOCK_API_KEY", "test-key");

    const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{mock.port});
    defer std.testing.allocator.free(base_url);
    var provider_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer provider_arena.deinit();
    var provider = try config.Provider.single(provider_arena.allocator(), "mock-deadline", base_url, .openai_compat, "mock", .{});
    provider.api_key_env = "MOCK_API_KEY";

    var ctx = Ctx{ .io = io, .gpa = std.testing.allocator, .environ_map = &env };
    var response_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer response_arena.deinit();
    const messages = [_]types.Message{.{ .role = .user, .content = "hi" }};
    var err_detail: ?[]const u8 = null;
    try std.testing.expectError(error.Timeout, chatWithDeadline(&ctx, response_arena.allocator(), .{
        .provider = &provider,
        .messages = &messages,
        .max_tokens = 1,
    }, &err_detail, 300));
    try std.testing.expect(ctx.abort == null);
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
    var buf: [http_scratch_buf_bytes]u8 = undefined;
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
    var buf: [http_scratch_buf_bytes]u8 = undefined;
    const headers = try capturedAnthropicHeaders(std.testing.allocator, "sk-ant-oat01-secret", &buf);

    try std.testing.expect(std.mem.find(u8, headers, "authorization: Bearer sk-ant-oat01-secret") != null);
    try std.testing.expect(std.mem.find(u8, headers, "anthropic-beta: " ++ providers.anthropic.oauth_beta) != null);
    try std.testing.expect(std.mem.find(u8, headers, "anthropic-version: 2023-06-01") != null);
    // The token must not also be sent as an API key; the API rejects both at once.
    try std.testing.expect(std.mem.find(u8, headers, "x-api-key") == null);
}

test "totalCost prices input with the cache discount and output at list rates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var provider = try config.Provider.single(arena, "priced", "http://127.0.0.1:9/v1", .openai_compat, "m", .{});
    try provider.models.put(arena, "m", .{ .cost_per_1m_input = 3.0, .cost_per_1m_output = 15.0 });

    // 1M uncached input tokens + 1M output tokens at $3/$15 per 1M.
    const full = totalCost(&provider, .{ .prompt_tokens = 1_000_000, .completion_tokens = 1_000_000, .total_tokens = 2_000_000 });
    try std.testing.expectApproxEqAbs(@as(f64, 18.0), full, 0.0001);

    // A fully cache-hit prompt bills a tenth of the input rate.
    const cached = totalCost(&provider, .{ .prompt_tokens = 1_000_000, .prompt_cache_hit_tokens = 1_000_000, .total_tokens = 1_000_000 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), cached, 0.0001);

    // No pricing info on the model means the estimate is 0, not an error.
    var unpriced = try config.Provider.single(arena, "free", "http://127.0.0.1:9/v1", .openai_compat, "m", .{});
    try std.testing.expectApproxEqAbs(@as(f64, 0), totalCost(&unpriced, .{ .prompt_tokens = 1_000_000, .completion_tokens = 1_000_000, .total_tokens = 2_000_000 }), 0.0001);
}

test "chat retries a 503 and gives up after its same-provider attempts" {
    // The non-streaming half of the retry loop: `chatStream`'s 429 retry is
    // covered above, but plain `chat` retried on 5xx through the same
    // `max_attempts` budget without a test. `http_503` exists exactly to
    // exhaust it -- every attempt must reach the server, none may succeed.
    const mock_server = @import("mock_server.zig");
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const mock = try mock_server.MockServer.start(io, std.testing.allocator, .http_503);
    defer mock.stop();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("MOCK_API_KEY", "test-key");

    const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{mock.port});
    defer std.testing.allocator.free(base_url);
    var arena_for_provider = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_for_provider.deinit();
    var provider = try config.Provider.single(arena_for_provider.allocator(), "mock-503", base_url, .openai_compat, "mock", .{ .max_tokens = 64 });
    provider.api_key_env = "MOCK_API_KEY";

    var ctx = Ctx{ .io = io, .gpa = std.testing.allocator, .environ_map = &env };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const messages = [_]types.Message{.{ .role = .user, .content = "hi" }};
    var err_detail: ?[]const u8 = null;
    try std.testing.expectError(error.ApiError, chat(&ctx, arena, .{
        .provider = &provider,
        .messages = &messages,
    }, &err_detail));
    // One request per attempt: the retry loop hit the endpoint max_attempts
    // times and then surfaced the error instead of falling through.
    try std.testing.expectEqual(@as(usize, 3), mock.captured.items.len);
    try std.testing.expect(err_detail != null);
}

test "chat honors Retry-After on a 429 and retries immediately" {
    // The non-streaming retry loop used to sleep the fixed backoff through a
    // rate limit the server had already priced. With `Retry-After: 0` the
    // retry must fire at once; the fixed path would have slept at least a
    // second, which is what the elapsed-time bound below distinguishes.
    const mock_server = @import("mock_server.zig");
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const mock = try mock_server.MockServer.start(io, std.testing.allocator, .openai_after_429);
    defer mock.stop();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("MOCK_API_KEY", "test-key");

    const base_url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{mock.port});
    defer std.testing.allocator.free(base_url);
    var arena_for_provider = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_for_provider.deinit();
    var provider = try config.Provider.single(arena_for_provider.allocator(), "mock-429-ra", base_url, .openai_compat, "mock", .{ .max_tokens = 64 });
    provider.api_key_env = "MOCK_API_KEY";

    var ctx = Ctx{ .io = io, .gpa = std.testing.allocator, .environ_map = &env };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const messages = [_]types.Message{.{ .role = .user, .content = "hi" }};
    var err_detail: ?[]const u8 = null;

    const t0 = std.Io.Timestamp.now(io, .awake);
    const resp = try chat(&ctx, arena, .{
        .provider = &provider,
        .messages = &messages,
    }, &err_detail);
    const elapsed_ns = t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    const elapsed_ms = @divTrunc(elapsed_ns, std.time.ns_per_ms);

    try std.testing.expectEqualStrings("Hello from the mock", resp.message.content orelse "");
    try std.testing.expectEqual(@as(usize, 2), mock.captured.items.len);
    // Retry-After: 0 means "retry now". The fixed backoff for the first
    // attempt is 1s + jitter, so a correctly honored header completes well
    // under the bound and a regression back to the fixed backoff fails it.
    try std.testing.expect(elapsed_ms < 800);
}
