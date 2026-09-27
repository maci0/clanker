//! `gemini`: Google Gemini generateContent (AI Studio).
//!
//! Wire codec, `x-goog-api-key` auth, and the `:generateContent` /
//! `:streamGenerateContent` verbs. Vertex Gemini is a different host and is
//! not this kind.

const std = @import("std");
const json = std.json;
const api = @import("api.zig");
const common = @import("common.zig");
const auth = @import("../auth.zig");
const types = @import("../types.zig");
const config = @import("../../config.zig");
const log = @import("../../util/log.zig");
const redact = @import("../../util/redact.zig");
const fuzz_corpus = @import("../../util/fuzz_corpus.zig");

pub const default_base = "https://generativelanguage.googleapis.com/v1beta";

pub const provider: api.Provider = .{
    .kind = .gemini,
    .auth = .{ .default = .api_key, .required = true },
    .proxy = .{ .family = .openai, .speaks = false, .enabled = false },
    .buildRequest = buildRequest,
    .parseResponse = parseResponse,
    .parseErrorDetail = parseErrorDetail,
    .parseStreamEvent = parseStreamEvent,
    .authHeaders = authHeaders,
    .endpointUrl = endpointUrl,
};

fn authHeaders(cred: auth.Credential, _: *std.http.Client.Request.Headers, extra: *api.ExtraHeaders) usize {
    const key = cred.value orelse return 0;
    extra[0] = .{ .name = "x-goog-api-key", .value = key };
    return 1;
}

fn endpointUrl(gpa: std.mem.Allocator, p: *const config.Provider, streaming: bool) anyerror![]u8 {
    const raw_base = if (p.base_url.len > 0) p.base_url else default_base;
    const base = std.mem.trimEnd(u8, raw_base, "/");
    if (p.path) |path| return common.joinBaseAndPath(gpa, p, path);
    const verb = if (streaming) "streamGenerateContent?alt=sse" else "generateContent";
    return std.fmt.allocPrint(gpa, "{s}/models/{s}:{s}", .{ base, p.wireModelName(), verb });
}

// ---------------------------------------------------------------- request --

fn buildRequest(gpa: std.mem.Allocator, params: api.RequestParams) api.BuildError![]u8 {
    var b = common.Builder.init(gpa);
    errdefer b.deinit();
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    var s = b.begin();

    try s.beginObject();

    var system_parts: std.ArrayList([]const u8) = .empty;
    defer system_parts.deinit(gpa);
    for (params.messages) |m| {
        if (m.role == .system) if (m.content) |c| if (c.len > 0) try system_parts.append(gpa, c);
    }
    if (system_parts.items.len > 0) {
        try s.objectField("systemInstruction");
        try s.beginObject();
        try s.objectField("parts");
        try s.beginArray();
        for (system_parts.items) |part| {
            try s.beginObject();
            try s.objectField("text");
            try s.write(part);
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
    }

    try s.objectField("contents");
    try s.beginArray();
    var pending_tools: std.ArrayList(types.Message) = .empty;
    defer pending_tools.deinit(gpa);
    for (params.messages) |m| {
        if (m.role == .system) continue;
        if (m.role == .tool) {
            try pending_tools.append(gpa, m);
            continue;
        }
        try flushToolResults(&s, scratch, params.messages, pending_tools.items);
        pending_tools.clearRetainingCapacity();
        try writeContent(&s, scratch, m);
    }
    try flushToolResults(&s, scratch, params.messages, pending_tools.items);
    try s.endArray();

    if (params.tools) |tools| {
        try s.objectField("tools");
        try s.beginArray();
        try s.beginObject();
        try s.objectField("functionDeclarations");
        try s.beginArray();
        for (tools) |t| {
            try s.beginObject();
            try s.objectField("name");
            try s.write(t.name);
            try s.objectField("description");
            try s.write(t.description);
            try s.objectField("parameters");
            try s.write(t.input_schema);
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
        try s.endArray();
    }

    try s.objectField("generationConfig");
    try s.beginObject();
    // One resolver, not a second copy of the precedence chain. Gemini spells
    // the fields itself (`topP`, inside `generationConfig`) but the three
    // tiers are the same everywhere; this file used to re-implement them,
    // which is how `reasoning_effort` came to be computed and dropped.
    // NOTE: the resolved effort is still unwritten here — `generationConfig`
    // has no `reasoning_effort` field and the correct Gemini `thinkingConfig`
    // shape is not established in-tree, so PRD 0024's thinking row remains
    // inert for `gemini` and `vertex`-Gemini. Tracked as a report; do not
    // guess a shape.
    const rec = common.resolveSampling(params);
    if (rec.temperature) |t| {
        try s.objectField("temperature");
        try s.print("{d}", .{t});
    }
    if (rec.top_p) |tp| {
        try s.objectField("topP");
        try s.print("{d}", .{tp});
    }
    try s.objectField("maxOutputTokens");
    try s.print("{d}", .{common.clampedMaxTokens(params)});
    if (params.response_format_json) {
        try s.objectField("responseMimeType");
        try s.write("application/json");
    }
    try s.endObject();

    try s.endObject();
    return try b.finish();
}

fn writeContent(s: *json.Stringify, scratch: std.mem.Allocator, m: types.Message) !void {
    try s.beginObject();
    try s.objectField("role");
    try s.write(switch (m.role) {
        .assistant => "model",
        else => "user",
    });
    try s.objectField("parts");
    try s.beginArray();
    if (m.content) |c| {
        if (c.len > 0) {
            try s.beginObject();
            try s.objectField("text");
            try s.write(c);
            try s.endObject();
        }
    }
    if (m.images) |imgs| {
        for (imgs) |img| {
            try s.beginObject();
            try s.objectField("inlineData");
            try s.beginObject();
            try s.objectField("mimeType");
            try s.write(img.mime);
            try s.objectField("data");
            try s.write(img.b64);
            try s.endObject();
            try s.endObject();
        }
    }
    if (m.tool_calls) |calls| {
        for (calls) |tc| {
            try s.beginObject();
            try s.objectField("functionCall");
            try s.beginObject();
            try s.objectField("name");
            try s.write(tc.name);
            try s.objectField("args");
            const input = json.parseFromSliceLeaky(json.Value, scratch, tc.arguments, .{}) catch json.Value{ .object = .empty };
            try s.write(input);
            try s.endObject();
            try s.endObject();
        }
    }
    try s.endArray();
    try s.endObject();
}

fn flushToolResults(
    s: *json.Stringify,
    scratch: std.mem.Allocator,
    messages: []const types.Message,
    tools: []const types.Message,
) !void {
    if (tools.len == 0) return;
    try s.beginObject();
    try s.objectField("role");
    try s.write("user");
    try s.objectField("parts");
    try s.beginArray();
    for (tools) |m| {
        try s.beginObject();
        try s.objectField("functionResponse");
        try s.beginObject();
        try s.objectField("name");
        try s.write(toolNameForId(messages, m.tool_call_id orelse ""));
        try s.objectField("response");
        try writeToolResponse(s, scratch, m.content orelse "");
        try s.endObject();
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

fn toolNameForId(messages: []const types.Message, id: []const u8) []const u8 {
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        if (messages[i].tool_calls) |calls| {
            for (calls) |tc| {
                if (std.mem.eql(u8, tc.id, id)) return tc.name;
            }
        }
    }
    return id;
}

fn writeToolResponse(s: *json.Stringify, scratch: std.mem.Allocator, content: []const u8) !void {
    if (content.len > 0) {
        if (json.parseFromSliceLeaky(json.Value, scratch, content, .{})) |parsed| {
            if (parsed == .object) {
                try s.write(parsed);
                return;
            }
        } else |_| {}
    }
    try s.beginObject();
    try s.objectField("result");
    try s.write(content);
    try s.endObject();
}

// --------------------------------------------------------------- response --

const FunctionCall = struct {
    name: []const u8 = "",
    args: ?json.Value = null,
};

const Part = struct {
    text: ?[]const u8 = null,
    thought: bool = false,
    functionCall: ?FunctionCall = null,
    inlineData: ?struct { mimeType: []const u8 = "", data: []const u8 = "" } = null,
};

const Content = struct {
    role: []const u8 = "model",
    parts: []const Part = &.{},
};

const Candidate = struct {
    content: Content = .{},
    finishReason: ?[]const u8 = null,
};

const UsageMetadata = struct {
    promptTokenCount: u32 = 0,
    candidatesTokenCount: u32 = 0,
    totalTokenCount: u32 = 0,
    cachedContentTokenCount: u32 = 0,
};

const ApiError = struct {
    message: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

const Response = struct {
    candidates: []const Candidate = &.{},
    usageMetadata: ?UsageMetadata = null,
    @"error": ?ApiError = null,
};

fn parseResponse(arena: std.mem.Allocator, body: []const u8, err_detail: ?*?[]const u8) anyerror!types.ChatResponse {
    const parsed = try json.parseFromSliceLeaky(Response, arena, body, .{ .ignore_unknown_fields = true });
    if (parsed.@"error") |e| {
        var log_detail_buf: [redact.max_log_detail_len]u8 = undefined;
        const msg = e.message orelse "no message";
        log.log(.error_, "gemini provider error ({s}): {s}", .{ e.status orelse "unknown", redact.forLog(&log_detail_buf, msg) });
        if (err_detail) |d| d.* = if (e.message) |m| try redact.forCaller(arena, m) else e.status;
        return error.ApiError;
    }
    if (parsed.candidates.len == 0) return error.EmptyChoices;
    const cand = parsed.candidates[0];

    var text_buf: std.ArrayList(u8) = .empty;
    var reasoning_buf: std.ArrayList(u8) = .empty;
    var calls: std.ArrayList(types.ToolCall) = .empty;
    for (cand.content.parts, 0..) |part, i| {
        if (part.functionCall) |fc| {
            const args = if (fc.args) |v| try jsonStringifyAlloc(arena, v) else "{}";
            try calls.append(arena, .{
                .id = try std.fmt.allocPrint(arena, "call_{d}", .{i}),
                .name = try arena.dupe(u8, fc.name),
                .arguments = args,
            });
            continue;
        }
        const t = part.text orelse continue;
        if (t.len == 0) continue;
        if (part.thought) {
            try reasoning_buf.appendSlice(arena, t);
        } else {
            try text_buf.appendSlice(arena, t);
        }
    }

    var usage_out: ?types.Usage = null;
    if (parsed.usageMetadata) |u| {
        const hit = u.cachedContentTokenCount;
        const miss = if (u.promptTokenCount >= hit) u.promptTokenCount - hit else u.promptTokenCount;
        usage_out = .{
            .prompt_tokens = u.promptTokenCount,
            .completion_tokens = u.candidatesTokenCount,
            .total_tokens = u.totalTokenCount,
            .prompt_cache_hit_tokens = hit,
            .prompt_cache_miss_tokens = miss,
        };
    }

    return .{
        .message = .{
            .role = .assistant,
            .content = if (text_buf.items.len > 0) try text_buf.toOwnedSlice(arena) else null,
            .tool_calls = if (calls.items.len > 0) try calls.toOwnedSlice(arena) else null,
        },
        .usage = usage_out,
        .finish_reason = try mapFinish(arena, cand.finishReason, calls.items.len > 0),
        .reasoning = if (reasoning_buf.items.len > 0) try reasoning_buf.toOwnedSlice(arena) else null,
        // `body` is the caller's arena-owned copy (client.zig dups the gpa
        // body into the arena before parsing), so aliasing it keeps the
        // documented "arena-owned" contract without a second full copy.
        .raw = body,
    };
}

fn mapFinish(arena: std.mem.Allocator, reason: ?[]const u8, has_tools: bool) !?[]const u8 {
    const r = reason orelse {
        if (has_tools) return try arena.dupe(u8, "tool_calls");
        return null;
    };
    if (std.mem.eql(u8, r, "STOP")) return try arena.dupe(u8, "stop");
    if (std.mem.eql(u8, r, "MAX_TOKENS")) return try arena.dupe(u8, "length");
    if (std.mem.eql(u8, r, "FUNCTION_CALL") or has_tools) return try arena.dupe(u8, "tool_calls");
    return try arena.dupe(u8, r);
}

fn jsonStringifyAlloc(arena: std.mem.Allocator, value: json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn parseErrorDetail(arena: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const parsed = json.parseFromSliceLeaky(Response, arena, body, .{ .ignore_unknown_fields = true }) catch return null;
    if (parsed.@"error") |e| return e.message;
    return null;
}

// ----------------------------------------------------------------- stream --

fn parseStreamEvent(chunk_arena: std.mem.Allocator, payload: []const u8) api.StreamParseError!?api.StreamEvent {
    if (common.isDoneSentinel(payload)) return .{ .done = true };
    const chunk = json.parseFromSliceLeaky(Response, chunk_arena, payload, .{ .ignore_unknown_fields = true }) catch {
        log.log(.debug, "unparseable gemini stream frame ({d} bytes)", .{payload.len});
        return null;
    };
    var ev: api.StreamEvent = .{};
    if (chunk.usageMetadata) |u| {
        if (u.totalTokenCount > 0 or u.promptTokenCount > 0) {
            const hit = u.cachedContentTokenCount;
            const miss = if (u.promptTokenCount >= hit) u.promptTokenCount - hit else u.promptTokenCount;
            ev.usage = .{
                .prompt = .{ .tokens = u.promptTokenCount, .cache_hit_tokens = hit, .cache_miss_tokens = miss },
                .completion = u.candidatesTokenCount,
                .total = u.totalTokenCount,
            };
        }
    }
    if (chunk.candidates.len == 0) return ev;
    const cand = chunk.candidates[0];
    if (cand.finishReason) |fr| ev.finish_reason = fr;

    var text: std.ArrayList(u8) = .empty;
    var frags: std.ArrayList(api.ToolCallFragment) = .empty;
    for (cand.content.parts, 0..) |part, i| {
        if (part.functionCall) |fc| {
            const args = if (fc.args) |v| jsonStringifyAlloc(chunk_arena, v) catch "{}" else null;
            try frags.append(chunk_arena, .{
                .index = i,
                .id = try std.fmt.allocPrint(chunk_arena, "call_{d}", .{i}),
                .name = if (fc.name.len > 0) fc.name else null,
                .arguments = args,
            });
            continue;
        }
        if (part.thought) continue;
        if (part.text) |t| if (t.len > 0) try text.appendSlice(chunk_arena, t);
    }
    if (text.items.len > 0) ev.text = text.items;
    if (frags.items.len > 0) ev.tool_calls = frags.items;
    return ev;
}

// ------------------------------------------------------------------- tests --

test "gemini URL uses generateContent and streamGenerateContent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try config.Provider.single(arena, "google", "", .gemini, "gemini-2.5-flash", .{});
    const url = try endpointUrl(arena, &p, false);
    try std.testing.expectEqualStrings(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
        url,
    );
    const stream = try endpointUrl(arena, &p, true);
    try std.testing.expectEqualStrings(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse",
        stream,
    );
}

test "gemini request body uses contents, systemInstruction, and functionDeclarations" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try config.Provider.single(arena, "google", "", .gemini, "gemini-2.5-flash", .{ .max_tokens = 256 });
    const schema = try json.parseFromSliceLeaky(json.Value, arena, "{\"type\":\"object\"}", .{});
    const tools = [_]types.ToolDef{.{ .name = "history", .description = "recent", .input_schema = schema }};
    const calls = [_]types.ToolCall{.{ .id = "call_1", .name = "history", .arguments = "{\"n\":3}" }};
    const messages = [_]types.Message{
        .{ .role = .system, .content = "be brief" },
        .{ .role = .user, .content = "hi" },
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "call_1", .content = "ok" },
    };
    const body = try buildRequest(arena, .{
        .provider = &p,
        .messages = &messages,
        .tools = &tools,
        .temperature = 0.2,
    });
    defer arena.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"systemInstruction\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"role\":\"model\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"functionCall\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"functionResponse\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"name\":\"history\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"maxOutputTokens\":256") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"temperature\":0.2") != null);
    try std.testing.expect(std.mem.find(u8, body, "chat/completions") == null);
}

test "gemini response parse reads text, functionCall, cache, and thought" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body =
        \\{"candidates":[{"content":{"role":"model","parts":[{"thought":true,"text":"hmm"},{"text":"hi"},{"functionCall":{"name":"history","args":{"n":3}}}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":4,"totalTokenCount":14,"cachedContentTokenCount":8}}
    ;
    const resp = try parseResponse(arena, body, null);
    try std.testing.expectEqualStrings("hi", resp.message.content.?);
    try std.testing.expectEqualStrings("hmm", resp.reasoning.?);
    try std.testing.expectEqual(@as(usize, 1), resp.message.tool_calls.?.len);
    try std.testing.expectEqualStrings("history", resp.message.tool_calls.?[0].name);
    const args = try json.parseFromSliceLeaky(json.Value, arena, resp.message.tool_calls.?[0].arguments, .{});
    try std.testing.expectEqual(@as(i64, 3), args.object.get("n").?.integer);
    try std.testing.expectEqualStrings("stop", resp.finish_reason.?);
    try std.testing.expectEqual(@as(u32, 8), resp.usage.?.prompt_cache_hit_tokens);
    try std.testing.expectEqual(@as(u32, 2), resp.usage.?.prompt_cache_miss_tokens);
}

test "gemini error body surfaces the provider message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body =
        \\{"error":{"code":400,"message":"API key not valid","status":"INVALID_ARGUMENT"}}
    ;
    var detail: ?[]const u8 = null;
    try std.testing.expectError(error.ApiError, parseResponse(arena, body, &detail));
    try std.testing.expectEqualStrings("API key not valid", detail.?);
    try std.testing.expectEqualStrings("API key not valid", parseErrorDetail(arena, body).?);
}

test "gemini stream frame yields a text delta" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ev = (try parseStreamEvent(arena,
        \\{"candidates":[{"content":{"parts":[{"text":"hel"}]}}]}
    )).?;
    try std.testing.expectEqualStrings("hel", ev.text.?);
}

/// Seed frames for the stream codec fuzz targets. Outside a fuzzing session
/// `std.testing.fuzz` replays only its corpus (plus the empty string), so
/// without seeds the harness would parse nothing and assert nothing; these are
/// the shapes the endpoint actually sends, plus the disagreeing-number and
/// malformed cases the invariants are written against.
const stream_fuzz_corpus = [_][]const u8{
    fuzz_corpus.entry("[DONE]"),
    fuzz_corpus.entry(""),
    fuzz_corpus.entry(
        \\{"candidates":[{"content":{"parts":[{"text":"Hello"}]},"finishReason":null}]}
    ),
    fuzz_corpus.entry(
        \\{"candidates":[{"content":{"parts":[{"text":"a"},{"text":"b"},{"functionCall":{"name":"read_file","args":{"path":"src/main.zig"}}},{"text":"thinking","thought":true}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":3,"totalTokenCount":13}}
    ),
    fuzz_corpus.entry(
        \\{"candidates":[{"content":{"parts":[{"functionCall":{"name":"f"}}]}}]}
    ),
    fuzz_corpus.entry(
        \\{"candidates":[{"content":{"parts":[{"text":""}]}}]}
    ),
    fuzz_corpus.entry(
        \\{"candidates":[{"content":{"parts":[]},"finishReason":"MAX_TOKENS"}],"usageMetadata":{"promptTokenCount":10,"cachedContentTokenCount":12,"candidatesTokenCount":3,"totalTokenCount":13}}
    ),
    fuzz_corpus.entry(
        \\{"usageMetadata":{"promptTokenCount":0,"totalTokenCount":0}}
    ),
    fuzz_corpus.entry(
        \\{"candidates":[]}
    ),
    fuzz_corpus.entry(
        \\{"candidates":[{"content":{"parts":[{"text":"héllo ✓ é"}]}}]}
    ),
    fuzz_corpus.entry(
        \\{"candidates":[{"content":{"parts":[{"functionCall":{"name":"","args":[1,2,3]}}]}}]}
    ),
    fuzz_corpus.entry(
        \\{"candidates":[{"content":{"parts":[{"functionCall":{"name":"a","args":{}}},{"functionCall":{"name":"b","args":{}}}]}}]}
    ),
    fuzz_corpus.entry(
        \\{"candidates":[{"content":{"parts":[{"text":"\ud800 lone surrogate"}]}}]}
    ),
    fuzz_corpus.entry(
        \\{ not json
    ),
    fuzz_corpus.entry("[]"),
    fuzz_corpus.entry("null"),
    fuzz_corpus.entry("3"),
};

test "fuzz: gemini stream events stay a well-formed event on any payload" {
    // parseStreamEvent sees whatever the endpoint sends on the SSE wire, so
    // the fuzzer feeds it the same untrusted bytes. Crashing is one failure
    // mode; the other is a *successfully parsed* event that lies about its own
    // shape, which the caller cannot check. So every field the codec fills
    // from a provider-supplied number is pinned here.
    const F = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.slice(&buf);

            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            const ev = (try parseStreamEvent(arena_state.allocator(), buf[0..len])) orelse return;

            // The sentinel is the only source of `done`, and it returns before
            // anything is read, so a done frame never also carries a delta.
            if (ev.done) {
                try std.testing.expect(ev.text == null);
                try std.testing.expect(ev.tool_calls.len == 0);
                try std.testing.expect(ev.usage == null);
                try std.testing.expect(ev.finish_reason == null);
                return;
            }
            // An empty delta would be appended as nothing and counted as a
            // first-token tick, so the codec only sets the field when non-empty.
            if (ev.text) |t| try std.testing.expect(t.len > 0);
            if (ev.finish_reason) |r| try std.testing.expect(r.len > 0);

            // Fragments are keyed by index, so two parts claiming one index
            // would fold into a single corrupt call, and the minted id has to
            // agree with the index the caller will look it up under.
            var prev: ?usize = null;
            for (ev.tool_calls) |f| {
                if (prev) |p| try std.testing.expect(f.index > p);
                prev = f.index;
                var id_buf: [32]u8 = undefined;
                const want_id = try std.fmt.bufPrint(&id_buf, "call_{d}", .{f.index});
                try std.testing.expectEqualStrings(want_id, f.id.?);
                if (f.name) |n| try std.testing.expect(n.len > 0);
            }

            // Token counts are provider-supplied and can disagree with each
            // other; the miss half is clamped, so it can never report less
            // than the prompt total once the cache read is added back.
            if (ev.usage) |u| {
                const p = u.prompt.?;
                try std.testing.expect(@as(u64, p.cache_miss_tokens) + p.cache_hit_tokens >= p.tokens);
            }
        }
    };
    try std.testing.fuzz({}, F.one, .{ .corpus = &stream_fuzz_corpus });
}

/// Whole-body seeds for the non-streaming codec: the same frames, minus the
/// `finishReason`-only shapes that never reach a full response.
const body_fuzz_corpus = [_][]const u8{
    fuzz_corpus.entry(
        \\{"candidates":[{"content":{"parts":[{"text":"hi"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":2,"totalTokenCount":12}}
    ),
    fuzz_corpus.entry(
        \\{"candidates":[{"content":{"parts":[{"text":"thought","thought":true},{"text":"answer"}]}}]}
    ),
    fuzz_corpus.entry(
        \\{"candidates":[{"content":{"parts":[{"functionCall":{"name":"exec","args":{"cmd":"ls"}}}]},"finishReason":"FUNCTION_CALL"}]}
    ),
    fuzz_corpus.entry(
        \\{"candidates":[{"content":{"parts":[{"functionCall":{"name":"a","args":{}}},{"functionCall":{"name":"b","args":{}}}]}}]}
    ),
    fuzz_corpus.entry(
        \\{"candidates":[{"content":{"parts":[{"text":"x"}]},"finishReason":"MAX_TOKENS"}],"usageMetadata":{"promptTokenCount":4,"cachedContentTokenCount":9,"candidatesTokenCount":1,"totalTokenCount":5}}
    ),
    fuzz_corpus.entry(
        \\{"candidates":[{"content":{"parts":[]}}]}
    ),
    fuzz_corpus.entry(
        \\{"candidates":[]}
    ),
    fuzz_corpus.entry(
        \\{"error":{"code":429,"message":"quota"}}
    ),
    fuzz_corpus.entry(
        \\{ not json
    ),
    fuzz_corpus.entry("[]"),
    fuzz_corpus.entry("null"),
};

test "fuzz: gemini non-stream bodies decode to a consistent assistant message" {
    // The non-streaming path takes the whole response body, so it sees every
    // byte the endpoint sends on a single frame. The same shape promises hold
    // here, and they are the ones the agent loop cannot re-check: a tool call
    // whose minted id disagrees with its position is executed under the wrong
    // key, and a usage report whose miss half is below the prompt total is
    // billed to the cache-miss column.
    const F = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.slice(&buf);

            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            const resp = parseResponse(arena_state.allocator(), buf[0..len], null) catch return;

            try std.testing.expectEqual(types.Role.assistant, resp.message.role);
            if (resp.message.content) |c| try std.testing.expect(c.len > 0);
            if (resp.reasoning) |r| try std.testing.expect(r.len > 0);
            if (resp.finish_reason) |r| try std.testing.expect(r.len > 0);

            // The id is minted from the part's position in `parts`, so it is
            // not derivable from the call list; what the loop does guarantee is
            // that two calls never collide on one id, since the agent loop
            // keys results by it.
            for (resp.message.tool_calls orelse &.{}, 0..) |call, i| {
                try std.testing.expect(std.mem.startsWith(u8, call.id, "call_"));
                try std.testing.expect(call.name.len > 0);
                try std.testing.expect(call.arguments.len > 0);
                for (resp.message.tool_calls.?[0..i]) |earlier| {
                    try std.testing.expect(!std.mem.eql(u8, earlier.id, call.id));
                }
            }

            if (resp.usage) |u| {
                try std.testing.expect(
                    @as(u64, u.prompt_cache_miss_tokens) + u.prompt_cache_hit_tokens >= u.prompt_tokens,
                );
            }
        }
    };
    try std.testing.fuzz({}, F.one, .{ .corpus = &body_fuzz_corpus });
}

test "gemini puts the key on x-goog-api-key" {
    var extra: api.ExtraHeaders = undefined;
    var headers: std.http.Client.Request.Headers = .{};
    const n = authHeaders(.{ .value = "AIzaSy" }, &headers, &extra);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("x-goog-api-key", extra[0].name);
    try std.testing.expectEqualStrings("AIzaSy", extra[0].value);
}
