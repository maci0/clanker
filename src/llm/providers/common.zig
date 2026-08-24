//! Helpers shared by every provider codec: JSON body assembly, the knobs that
//! mean the same thing on every wire format, and the default URL join.
//!
//! Only genuinely format-independent things belong here. Anything one provider
//! does differently stays in that provider's file, which is the point of the
//! split.

const std = @import("std");
const json = std.json;
const api = @import("api.zig");
const auth = @import("../auth.zig");
const config = @import("../../config.zig");
const sampling = @import("../sampling_profiles.zig");

/// The body grows to fit. It used to be capped at 1 MiB, which was ample for
/// tool schemas and then became a ceiling on how much source the
/// self-improvement engine could send: a context near the cap failed the whole
/// request with a bare WriteFailed, naming nothing.
pub const Builder = struct {
    out: std.Io.Writer.Allocating,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Builder {
        return .{ .out = .init(gpa), .gpa = gpa };
    }

    /// Creates a Stringify writing into the builder's writer. The returned
    /// Stringify is only valid while the Builder is alive.
    pub fn begin(self: *Builder) json.Stringify {
        return .{ .writer = &self.out.writer, .options = .{ .emit_null_optional_fields = false } };
    }

    /// Hands over the exact bytes written; the caller frees them with the
    /// builder's allocator.
    pub fn finish(self: *Builder) ![]u8 {
        return self.out.toOwnedSlice();
    }

    pub fn deinit(self: *Builder) void {
        self.out.deinit();
    }
};

/// Clamps the requested output budget to fit the model's context window:
/// never ask for more completion tokens than half the window.
pub fn clampedMaxTokens(params: api.RequestParams) u32 {
    const active = params.provider.activeModel();
    const requested = params.max_tokens orelse active.max_tokens;
    // An unknown context window (0) must not clamp a known budget down to
    // zero: the window is filled from the models.dev snapshot at load, and a
    // model the snapshot does not cover would otherwise ask for no completion
    // at all. Clamp only when the window is actually known.
    const window = active.context_window;
    if (window == 0) return requested;
    return @min(requested, window / 2);
}

/// The sampling knobs a request should carry, resolved but not yet written.
/// Precedence is per-run override, then the model's configured value, then
/// the use-case table (PRD 0024); an explicit config value still wins and the
/// table only fills a gap.
///
/// Separate from `writeSamplingParams` because the field *names* are per-wire
/// while the precedence chain is not: Gemini writes `topP` inside
/// `generationConfig` and the Responses API nests the effort under
/// `reasoning`, so those codecs resolve here and spell it themselves rather
/// than re-implementing three `orelse` chains each
/// (`gemini.zig` did, and its copy silently dropped the effort).
pub const Sampling = struct {
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    /// Wire string, not the config enum: the per-run override and the
    /// use-case table are already strings.
    reasoning_effort: ?[]const u8 = null,
};

pub fn resolveSampling(params: api.RequestParams) Sampling {
    const rec = sampling.forParams(params);
    const model = params.provider.activeModel();
    // The model's value is a validated enum — config rejects anything outside
    // the five levels — while the per-run override and the use-case table are
    // wire strings. Flatten to the wire form so the precedence chain stays one
    // expression.
    const model_effort: ?[]const u8 = if (model.reasoning_effort) |re| @tagName(re) else null;
    return .{
        .temperature = params.temperature orelse model.temperature orelse rec.temperature,
        .top_p = params.top_p orelse model.top_p orelse rec.top_p,
        .reasoning_effort = params.reasoning_effort orelse model_effort orelse rec.reasoning_effort,
    };
}

/// Writes `temperature`, `top_p`, and the reasoning knob into the body being
/// built, in the shape `thinkingSchemaOr(wire_default)` selects.
///
/// `wire_default` is the shape this endpoint accepts when neither the model
/// nor the provider names one, and the caller is the codec because that is
/// where wire knowledge lives (ADR 0004). It is not a style preference: a
/// single shared default is what put OpenAI's flat `reasoning_effort` on
/// `POST /v1/messages`, which Anthropic refuses as an extra input.
pub fn writeSamplingParams(s: *json.Stringify, params: api.RequestParams, wire_default: config.ThinkingSchema) !void {
    const schema = params.provider.thinkingSchemaOr(wire_default);
    const rec = resolveSampling(params);
    // Current Claude models (Opus 4.7 and later, Sonnet 5, Fable 5) removed
    // `temperature`, `top_p` and `top_k` outright and answer 400 on any
    // value, so the Anthropic thinking wire drops both writes rather than
    // reconciling them against the thinking block.
    if (schema != .anthropic_thinking) {
        if (rec.temperature) |t| {
            try s.objectField("temperature");
            try s.print("{d}", .{t});
        }
        if (rec.top_p) |tp| {
            try s.objectField("top_p");
            try s.print("{d}", .{tp});
        }
    }
    if (rec.reasoning_effort) |re| {
        // The knob's wire shape is a per-model/provider choice: some
        // endpoints want the flat OpenAI field, some the OpenRouter nest,
        // some GLM's thinking toggle, some Anthropic's adaptive block, and
        // some 400 on any of them.
        switch (schema) {
            .reasoning_effort => {
                try s.objectField("reasoning_effort");
                try s.write(re);
            },
            .reasoning => {
                try s.objectField("reasoning");
                try s.beginObject();
                try s.objectField("effort");
                try s.write(re);
                try s.endObject();
            },
            .thinking => {
                try s.objectField("thinking");
                try s.beginObject();
                try s.objectField("type");
                try s.write(if (std.mem.eql(u8, re, "none")) "disabled" else "enabled");
                try s.endObject();
            },
            .anthropic_thinking => try writeAnthropicThinking(s, re),
            .none => {},
        }
    }
}

/// Anthropic Messages' reasoning controls: `thinking.type` is the on/off
/// switch and `output_config.effort` carries the depth. `adaptive` is the only
/// on-mode on current models — `{"type":"enabled","budget_tokens":N}` is
/// removed from Opus 4.7 and later, Sonnet 5 and Fable 5 and answers 400, so
/// GLM's `enabled` (the `.thinking` arm above) is not a substitute. `none`
/// maps to `{"type":"disabled"}` and sends no effort, since the request is to
/// turn thinking off rather than to run it shallowly.
fn writeAnthropicThinking(s: *json.Stringify, effort: []const u8) !void {
    const off = std.mem.eql(u8, effort, "none");
    try s.objectField("thinking");
    try s.beginObject();
    try s.objectField("type");
    try s.write(if (off) "disabled" else "adaptive");
    try s.endObject();
    if (off) return;
    try s.objectField("output_config");
    try s.beginObject();
    try s.objectField("effort");
    try s.write(effort);
    try s.endObject();
}

/// `base_url` + the provider's `path` override, or the wire kind's default.
pub fn joinBaseAndPath(gpa: std.mem.Allocator, provider: *const config.Provider, default_path: []const u8) ![]u8 {
    const path = provider.path orelse default_path;
    const base = std.mem.trimEnd(u8, provider.base_url, "/");
    var norm_path: ?[]u8 = null;
    defer if (norm_path) |p| gpa.free(p);
    if (path.len == 0 or path[0] != '/') {
        norm_path = try std.fmt.allocPrint(gpa, "/{s}", .{path});
    }
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ base, norm_path orelse path });
}

/// Overlay `extra_json` (a JSON object) onto `body` (a JSON object), extra
/// keys last. Empty extra is a no-op copy. Invalid extra is fail-open: the
/// original body is returned so a bad hatch cannot 400 the model. Config load
/// already refused a non-object extra_body (ADR 0034).
pub fn mergeExtraBody(gpa: std.mem.Allocator, body: []const u8, extra_json: []const u8) error{OutOfMemory}![]u8 {
    if (extra_json.len == 0) return gpa.dupe(u8, body);
    const extra_parsed = std.json.parseFromSlice(std.json.Value, gpa, extra_json, .{}) catch return gpa.dupe(u8, body);
    defer extra_parsed.deinit();
    if (extra_parsed.value != .object) return gpa.dupe(u8, body);

    const body_parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return gpa.dupe(u8, body);
    defer body_parsed.deinit();
    if (body_parsed.value != .object) return gpa.dupe(u8, body);

    var w: std.Io.Writer.Allocating = .init(gpa);
    errdefer w.deinit();
    var s = json.Stringify{ .writer = &w.writer, .options = .{} };
    s.beginObject() catch return gpa.dupe(u8, body);
    var bit = body_parsed.value.object.iterator();
    while (bit.next()) |kv| {
        if (extra_parsed.value.object.get(kv.key_ptr.*)) |_| continue;
        s.objectField(kv.key_ptr.*) catch return gpa.dupe(u8, body);
        s.write(kv.value_ptr.*) catch return gpa.dupe(u8, body);
    }
    var eit = extra_parsed.value.object.iterator();
    while (eit.next()) |kv| {
        s.objectField(kv.key_ptr.*) catch return gpa.dupe(u8, body);
        s.write(kv.value_ptr.*) catch return gpa.dupe(u8, body);
    }
    s.endObject() catch return gpa.dupe(u8, body);
    return w.toOwnedSlice();
}

/// The SSE sentinel that ends an OpenAI-style stream. Anthropic never sends
/// it, but a proxy in front of one might, so both codecs honour it.
pub fn isDoneSentinel(payload: []const u8) bool {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    return std.ascii.eqlIgnoreCase(trimmed, "[DONE]");
}

/// The one auth application shared by every kind that presents its credential
/// as `Authorization: Bearer` regardless of how it was acquired, which is
/// every kind except Anthropic's `x-api-key` path.
pub fn bearerAuthHeaders(
    cred: auth.Credential,
    headers: *std.http.Client.Request.Headers,
    _: *api.ExtraHeaders,
) usize {
    if (cred.bearer) |b| headers.authorization = .{ .override = b };
    return 0;
}

// ------------------------------------------------------------------- tests --

test "mergeExtraBody overlays keys last and leaves an empty extra unchanged" {
    const gpa = std.testing.allocator;
    const body = "{\"model\":\"m\",\"max_tokens\":16}";
    const copied = try mergeExtraBody(gpa, body, "");
    defer gpa.free(copied);
    try std.testing.expectEqualStrings(body, copied);

    const merged = try mergeExtraBody(gpa, body, "{\"chat_template_kwargs\":{\"thinking\":true},\"max_tokens\":32}");
    defer gpa.free(merged);
    try std.testing.expect(std.mem.find(u8, merged, "\"chat_template_kwargs\"") != null);
    try std.testing.expect(std.mem.find(u8, merged, "\"thinking\":true") != null);
    try std.testing.expect(std.mem.find(u8, merged, "\"max_tokens\":32") != null);
    try std.testing.expect(std.mem.find(u8, merged, "\"max_tokens\":16") == null);
    try std.testing.expect(std.mem.find(u8, merged, "\"model\":\"m\"") != null);
}

test "mergeExtraBody fail-opens on a non-object extra" {
    const gpa = std.testing.allocator;
    const body = "{\"model\":\"m\"}";
    const copied = try mergeExtraBody(gpa, body, "[1]");
    defer gpa.free(copied);
    try std.testing.expectEqualStrings(body, copied);
}

test "a path override replaces the kind default and is slash-normalized" {
    const gpa = std.testing.allocator;
    var p = config.Provider{ .name = "p", .base_url = "https://api.test/", .default_model = "m" };

    const defaulted = try joinBaseAndPath(gpa, &p, "/chat/completions");
    defer gpa.free(defaulted);
    try std.testing.expectEqualStrings("https://api.test/chat/completions", defaulted);

    p.path = "v2/chat";
    const overridden = try joinBaseAndPath(gpa, &p, "/chat/completions");
    defer gpa.free(overridden);
    try std.testing.expectEqualStrings("https://api.test/v2/chat", overridden);
}

test "writeSamplingParams fills the use-case table when nothing is configured" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try config.Provider.single(arena, "p", "https://p.test", .openai_compat, "m", .{});
    var out: std.Io.Writer.Allocating = .init(arena);
    var s = json.Stringify{ .writer = &out.writer };
    try s.beginObject();
    try writeSamplingParams(&s, .{ .provider = &p, .messages = &.{} }, .reasoning_effort);
    try s.endObject();
    try std.testing.expect(std.mem.find(u8, out.written(), "\"temperature\":0.7") != null);
}

test "writeSamplingParams keeps an explicit model temperature" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var p = try config.Provider.single(arena, "p", "https://p.test", .openai_compat, "m", .{});
    var it = p.models.iterator();
    it.next().?.value_ptr.temperature = 0.2;
    var out: std.Io.Writer.Allocating = .init(arena);
    var s = json.Stringify{ .writer = &out.writer };
    try s.beginObject();
    try writeSamplingParams(&s, .{ .provider = &p, .messages = &.{} }, .reasoning_effort);
    try s.endObject();
    try std.testing.expect(std.mem.find(u8, out.written(), "\"temperature\":0.2") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "\"temperature\":0.7") == null);
}

test "writeSamplingParams sends reasoning_effort for thinking models" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var p = try config.Provider.single(arena, "p", "https://p.test", .openai_compat, "m", .{});
    var it = p.models.iterator();
    const caps = try arena.alloc([]const u8, 1);
    caps[0] = "thinking";
    it.next().?.value_ptr.capabilities = caps;
    var out: std.Io.Writer.Allocating = .init(arena);
    var s = json.Stringify{ .writer = &out.writer };
    try s.beginObject();
    try writeSamplingParams(&s, .{ .provider = &p, .messages = &.{} }, .reasoning_effort);
    try s.endObject();
    try std.testing.expect(std.mem.find(u8, out.written(), "\"reasoning_effort\":\"medium\"") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "temperature") == null);
}

/// Google API error envelope: `{"error":{"code":400,"message":"...","status":
/// "INVALID_ARGUMENT"}}`, which Vertex `rawPredict`/`generateContent` sometimes
/// wrap in a one-element array. Shared by the vertex kinds' `parseErrorDetail`:
/// their platform errors arrive in this shape, not the model publisher's, and
/// a 400 whose body no codec recognised used to reach the operator as a bare
/// "HTTP 400" with the one line naming the problem discarded
/// (docs/reports/investigations/2026-08-19-vertex-anthropic-400.md).
pub fn parseGoogleErrorMessage(arena: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const GoogleError = struct {
        @"error": ?struct {
            message: []const u8 = "",
            status: []const u8 = "",
        } = null,
    };
    const trimmed = std.mem.trimStart(u8, body, " \t\r\n");
    const parsed: GoogleError = if (std.mem.startsWith(u8, trimmed, "[")) blk: {
        const arr = json.parseFromSliceLeaky([]GoogleError, arena, trimmed, .{ .ignore_unknown_fields = true }) catch return null;
        for (arr) |entry| {
            if (entry.@"error" != null) break :blk entry;
        }
        // Array-wrapped flat errors: [{"message":"...","status":"PERMISSION_DENIED"}]
        const FlatEl = struct { message: []const u8 = "", status: []const u8 = "" };
        const flat_arr = json.parseFromSliceLeaky([]FlatEl, arena, trimmed, .{ .ignore_unknown_fields = true }) catch return null;
        for (flat_arr) |f| {
            if (f.message.len > 0 or f.status.len > 0) break :blk GoogleError{ .@"error" = .{ .message = f.message, .status = f.status } };
        }
        return null;
    } else json.parseFromSliceLeaky(GoogleError, arena, trimmed, .{ .ignore_unknown_fields = true }) catch return null;
    if (parsed.@"error") |e| {
        if (e.message.len == 0 and e.status.len == 0) return null;
        if (e.status.len == 0) return e.message;
        if (e.message.len == 0) return e.status;
        return std.fmt.allocPrint(arena, "{s}: {s}", .{ e.status, e.message }) catch e.message;
    }
    // Flat envelope: {"code":403,"message":"...","status":"PERMISSION_DENIED"} —
    // the shape GCP returns when the error is not nested under "error".
    const FlatError = struct {
        message: []const u8 = "",
        status: []const u8 = "",
    };
    if (!std.mem.startsWith(u8, trimmed, "[")) {
        const flat: ?FlatError = json.parseFromSliceLeaky(FlatError, arena, trimmed, .{ .ignore_unknown_fields = true }) catch null;
        if (flat) |f| {
            if (f.message.len == 0 and f.status.len == 0) return null;
            if (f.status.len == 0) return f.message;
            if (f.message.len == 0) return f.status;
            return std.fmt.allocPrint(arena, "{s}: {s}", .{ f.status, f.message }) catch f.message;
        }
    }
    // Last resort: surface a capped slice of the raw body so the operator
    // sees something actionable rather than a bare HTTP status with no detail.
    var end = trimmed.len;
    if (end > 512) {
        end = 512;
        // Keep the surfaced detail valid UTF-8: drop a partial codepoint at the
        // cap (trailing continuation bytes, plus the orphaned leading byte).
        while (end > 0 and (trimmed[end - 1] & 0xC0) == 0x80) end -= 1;
        if (end > 0 and (trimmed[end - 1] & 0xC0) == 0xC0) end -= 1;
    }
    const cap = trimmed[0..end];
    const detail = std.mem.trim(u8, cap, " \t\r\n");
    if (trimmed.len <= 512) return detail;
    return std.fmt.allocPrint(arena, "{s} [truncated]", .{detail}) catch detail;
}

test "parseGoogleErrorMessage reads the object and array envelopes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const object_form =
        \\{"error":{"code":400,"message":"Project is not allowed to use Publisher Model","status":"FAILED_PRECONDITION"}}
    ;
    try std.testing.expectEqualStrings(
        "FAILED_PRECONDITION: Project is not allowed to use Publisher Model",
        parseGoogleErrorMessage(arena, object_form).?,
    );

    const array_form =
        \\[{"error":{"code":400,"message":"Invalid JSON payload received.","status":"INVALID_ARGUMENT"}}]
    ;
    try std.testing.expectEqualStrings(
        "INVALID_ARGUMENT: Invalid JSON payload received.",
        parseGoogleErrorMessage(arena, array_form).?,
    );

    try std.testing.expect(parseGoogleErrorMessage(arena, "{\"candidates\":[]}") == null);
    try std.testing.expect(parseGoogleErrorMessage(arena, "not json at all") == null);
    try std.testing.expect(parseGoogleErrorMessage(arena, "[]") == null);
}

test "clampedMaxTokens leaves the budget intact when the context window is unknown" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var p = try config.Provider.single(arena, "p", "https://p.test", .openai_compat, "m", .{ .max_tokens = 16384 });
    var it = p.models.iterator();
    const m = it.next().?.value_ptr;

    // `Model.context_window` defaults to 131072, not 0, so `Provider.single`
    // above carries a *known* window and the assertion below passes through
    // the clamp (16384 < 65536), never reaching the `window == 0` return. This
    // test's comment used to claim the opposite, which left the zero-window
    // guard with no coverage at all (PRD 0024 known issue 4). Pin both paths
    // separately, starting with the default.
    try std.testing.expectEqual(@as(u32, 131072), m.context_window);
    try std.testing.expectEqual(@as(u32, 16384), clampedMaxTokens(.{ .provider = &p, .messages = &.{} }));

    // The guard itself: an unknown window (a hand-written `context_window = 0`,
    // or a snapshot row with no limit) must not clamp a known budget to zero.
    m.context_window = 0;
    try std.testing.expectEqual(@as(u32, 16384), clampedMaxTokens(.{ .provider = &p, .messages = &.{} }));

    // A known window still caps the budget at half of it.
    m.context_window = 16384;
    try std.testing.expectEqual(@as(u32, 8192), clampedMaxTokens(.{ .provider = &p, .messages = &.{} }));
}

test "the Anthropic thinking wire sends adaptive plus output_config.effort and no sampling" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var p = try config.Provider.single(arena, "p", "https://p.test", .anthropic, "m", .{ .temperature = 0.2, .top_p = 0.9, .reasoning_effort = .high });

    var out: std.Io.Writer.Allocating = .init(arena);
    var s = json.Stringify{ .writer = &out.writer };
    try s.beginObject();
    try writeSamplingParams(&s, .{ .provider = &p, .messages = &.{} }, .anthropic_thinking);
    try s.endObject();
    const body = out.written();

    try std.testing.expect(std.mem.find(u8, body, "\"thinking\":{\"type\":\"adaptive\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"output_config\":{\"effort\":\"high\"}") != null);
    // The three shapes that answer 400 on every current Claude model.
    try std.testing.expect(std.mem.find(u8, body, "reasoning_effort") == null);
    try std.testing.expect(std.mem.find(u8, body, "budget_tokens") == null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"enabled\"") == null);
    // Even an explicitly configured temperature/top_p is dropped: those are
    // removed from the models, not merely constrained alongside thinking.
    try std.testing.expect(std.mem.find(u8, body, "temperature") == null);
    try std.testing.expect(std.mem.find(u8, body, "top_p") == null);
}

test "effort none disables Anthropic thinking and sends no output_config" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try config.Provider.single(arena, "p", "https://p.test", .anthropic, "m", .{ .reasoning_effort = .none });

    var out: std.Io.Writer.Allocating = .init(arena);
    var s = json.Stringify{ .writer = &out.writer };
    try s.beginObject();
    try writeSamplingParams(&s, .{ .provider = &p, .messages = &.{} }, .anthropic_thinking);
    try s.endObject();
    const body = out.written();

    try std.testing.expect(std.mem.find(u8, body, "\"thinking\":{\"type\":\"disabled\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "output_config") == null);
}

test "the wire default is only the bottom of the chain" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A model that names its own schema still wins over the codec's default,
    // which is what lets an operator run an older Claude SKU on the flat field.
    const pinned = try config.Provider.single(arena, "p", "https://p.test", .anthropic, "m", .{ .reasoning_effort = .high, .thinking_schema = .reasoning_effort });
    try std.testing.expectEqual(config.ThinkingSchema.reasoning_effort, pinned.thinkingSchemaOr(.anthropic_thinking));

    var out: std.Io.Writer.Allocating = .init(arena);
    var s = json.Stringify{ .writer = &out.writer };
    try s.beginObject();
    try writeSamplingParams(&s, .{ .provider = &pinned, .messages = &.{} }, .anthropic_thinking);
    try s.endObject();
    try std.testing.expect(std.mem.find(u8, out.written(), "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "adaptive") == null);
}
