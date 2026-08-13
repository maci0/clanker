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
    return @min(params.max_tokens orelse active.max_tokens, active.context_window / 2);
}

/// Writes `temperature`, `top_p`, and `reasoning_effort`. Precedence is
/// per-run override, then the model's configured value, then the use-case
/// table. An explicit config value still wins; the table only fills a gap.
pub fn writeSamplingParams(s: *json.Stringify, params: api.RequestParams) !void {
    const rec = sampling.forParams(params);
    const model = params.provider.activeModel();
    const temp = params.temperature orelse model.temperature orelse rec.temperature;
    if (temp) |t| {
        try s.objectField("temperature");
        try s.print("{d}", .{t});
    }
    const nucleus = params.top_p orelse model.top_p orelse rec.top_p;
    if (nucleus) |tp| {
        try s.objectField("top_p");
        try s.print("{d}", .{tp});
    }
    const effort = model.reasoning_effort orelse rec.reasoning_effort;
    if (effort) |re| {
        try s.objectField("reasoning_effort");
        try s.write(re);
    }
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

/// The SSE sentinel that ends an OpenAI-style stream. Anthropic never sends
/// it, but a proxy in front of one might, so both codecs honour it.
pub fn isDoneSentinel(payload: []const u8) bool {
    return std.mem.eql(u8, payload, "[DONE]");
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
    try writeSamplingParams(&s, .{ .provider = &p, .messages = &.{} });
    try s.endObject();
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"temperature\":0.7") != null);
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
    try writeSamplingParams(&s, .{ .provider = &p, .messages = &.{} });
    try s.endObject();
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"temperature\":0.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"temperature\":0.7") == null);
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
    try writeSamplingParams(&s, .{ .provider = &p, .messages = &.{} });
    try s.endObject();
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"reasoning_effort\":\"medium\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "temperature") == null);
}
