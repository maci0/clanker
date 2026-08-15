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
const sampling = @import("../sampling_profiles.zig");
const log = @import("../../util/log.zig");
const redact = @import("../../util/redact.zig");

pub const default_base = "https://generativelanguage.googleapis.com/v1beta";

pub const provider: api.Provider = .{
    .kind = .gemini,
    .auth = .{ .default = .api_key, .required = true },
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
    return std.fmt.allocPrint(gpa, "{s}/models/{s}:{s}", .{ base, p.activeModelName(), verb });
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
    const rec = sampling.forParams(params);
    const model = params.provider.activeModel();
    const temp = params.temperature orelse model.temperature orelse rec.temperature;
    if (temp) |t| {
        try s.objectField("temperature");
        try s.print("{d}", .{t});
    }
    const nucleus = params.top_p orelse model.top_p orelse rec.top_p;
    if (nucleus) |tp| {
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
        .raw = try arena.dupe(u8, body),
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
    try std.testing.expect(std.mem.indexOf(u8, body, "\"systemInstruction\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"functionCall\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"functionResponse\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"history\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"maxOutputTokens\":256") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "chat/completions") == null);
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
    try std.testing.expectEqualStrings("{\"n\":3}", resp.message.tool_calls.?[0].arguments);
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

test "gemini puts the key on x-goog-api-key" {
    var extra: api.ExtraHeaders = undefined;
    var headers: std.http.Client.Request.Headers = .{};
    const n = authHeaders(.{ .value = "AIzaSy" }, &headers, &extra);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("x-goog-api-key", extra[0].name);
    try std.testing.expectEqualStrings("AIzaSy", extra[0].value);
}
