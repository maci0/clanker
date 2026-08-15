//! `openai_compat`: OpenAI-style `/chat/completions` (DeepSeek, OpenAI,
//! Ollama, OpenRouter, Groq, kimi, vLLM, ...).
//!
//! Wire codec, auth application and the endpoint path for this one kind.
//! Everything shared with other providers is in `common.zig`; the HTTP, SSE
//! framing, retry and token accounting are in `../client.zig` and are not
//! forked per provider.

const std = @import("std");
const json = std.json;
const api = @import("api.zig");
const common = @import("common.zig");
const types = @import("../types.zig");
const config = @import("../../config.zig");
const log = @import("../../util/log.zig");
const redact = @import("../../util/redact.zig");

pub const provider: api.Provider = .{
    .kind = .openai_compat,
    // Both an API key and an OAuth access token ride `Authorization: Bearer`
    // here, so the key path needs no code and OAuth would add only credential
    // acquisition. They are not distinguishable by shape across the many
    // vendors this kind serves, so there is no `detect`: selecting OAuth means
    // saying so with `auth = "oauth_static"`.
    .auth = .{ .default = .api_key },
    .buildRequest = buildRequest,
    .parseResponse = parseResponse,
    .parseErrorDetail = parseErrorDetail,
    .parseStreamEvent = parseStreamEvent,
    .authHeaders = common.bearerAuthHeaders,
    .endpointUrl = endpointUrl,
};

const default_path = "/chat/completions";

fn endpointUrl(gpa: std.mem.Allocator, p: *const config.Provider, _: bool) anyerror![]u8 {
    return common.joinBaseAndPath(gpa, p, default_path);
}

// ---------------------------------------------------------------- request --

fn buildRequest(gpa: std.mem.Allocator, params: api.RequestParams) api.BuildError![]u8 {
    var b = common.Builder.init(gpa);
    errdefer b.deinit();
    var s = b.begin();

    try s.beginObject();
    try s.objectField("model");
    try s.write(params.provider.wireModelName());
    try s.objectField("messages");
    try s.beginArray();
    for (params.messages) |m| {
        try s.beginObject();
        try s.objectField("role");
        try s.write(m.role.asStr());
        if (m.images) |imgs| {
            // Multimodal: content is an array of text + image_url blocks.
            try s.objectField("content");
            try s.beginArray();
            if (m.content) |c| {
                try s.beginObject();
                try s.objectField("type");
                try s.write("text");
                try s.objectField("text");
                try s.write(c);
                try s.endObject();
            }
            for (imgs) |img| {
                try s.beginObject();
                try s.objectField("type");
                try s.write("image_url");
                try s.objectField("image_url");
                try s.beginObject();
                try s.objectField("url");
                const url = try std.fmt.allocPrint(gpa, "data:{s};base64,{s}", .{ img.mime, img.b64 });
                defer gpa.free(url);
                try s.write(url);
                try s.endObject();
                try s.endObject();
            }
            try s.endArray();
        } else if (m.content) |c| {
            try s.objectField("content");
            try s.write(c);
        }
        if (m.tool_calls) |calls| {
            try s.objectField("tool_calls");
            try s.beginArray();
            for (calls) |tc| {
                try s.beginObject();
                try s.objectField("id");
                try s.write(tc.id);
                try s.objectField("type");
                try s.write("function");
                try s.objectField("function");
                try s.beginObject();
                try s.objectField("name");
                try s.write(tc.name);
                try s.objectField("arguments");
                try s.write(tc.arguments);
                try s.endObject();
                try s.endObject();
            }
            try s.endArray();
        }
        if (m.tool_call_id) |tid| {
            try s.objectField("tool_call_id");
            try s.write(tid);
        }
        try s.endObject();
    }
    try s.endArray();

    if (params.tools != null and params.provider.effectiveToolSchema() == .none) {
        // The endpoint rejects a tools array; the turn runs without tool
        // calling rather than 400ing.
    } else if (params.tools) |tools| {
        try s.objectField("tools");
        try s.beginArray();
        for (tools) |t| {
            try s.beginObject();
            try s.objectField("type");
            try s.write("function");
            try s.objectField("function");
            try s.beginObject();
            try s.objectField("name");
            try s.write(t.name);
            try s.objectField("description");
            try s.write(t.description);
            try s.objectField("parameters");
            try s.write(t.input_schema);
            try s.endObject();
            try s.endObject();
        }
        try s.endArray();
    }

    try common.writeSamplingParams(&s, params);
    const max_tokens = common.clampedMaxTokens(params);
    try s.objectField("max_tokens");
    try s.print("{d}", .{max_tokens});
    try s.objectField("stream");
    try s.write(params.stream);
    if (params.stream) {
        // Ask the provider to include usage in the final chunk so streaming
        // runs still get token accounting.
        try s.objectField("stream_options");
        try s.beginObject();
        try s.objectField("include_usage");
        try s.write(true);
        try s.endObject();
    }
    // reasoning_effort is written by writeSamplingParams (config, then the
    // use-case table). A second write here would duplicate the field.
    if (params.response_format_json) {
        try s.objectField("response_format");
        try s.beginObject();
        try s.objectField("type");
        try s.write("json_object");
        try s.endObject();
    }
    try s.endObject();

    return try b.finish();
}

// --------------------------------------------------------------- response --

const Message = struct {
    role: []const u8 = "assistant",
    content: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
};

const ToolCall = struct {
    id: []const u8 = "",
    function: struct {
        name: []const u8 = "",
        arguments: []const u8 = "",
    } = .{},
};

const Choice = struct {
    message: Message = .{},
    finish_reason: ?[]const u8 = null,
};

const ApiError = struct {
    message: ?[]const u8 = null,
    type: ?[]const u8 = null,
};

const Usage = struct {
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    total_tokens: u32 = 0,
    // DeepSeek
    prompt_cache_hit_tokens: u32 = 0,
    prompt_cache_miss_tokens: u32 = 0,
    // Moonshot / Kimi
    cached_tokens: u32 = 0,
    // OpenAI-compatible
    prompt_tokens_details: ?struct { cached_tokens: u32 = 0 } = null,

    /// The three vendors above each report cache hits under a different name,
    /// and only some report misses; normalize to the canonical pair.
    fn normalize(self: Usage) api.PromptUsage {
        var hit = self.prompt_cache_hit_tokens;
        if (hit == 0) hit = self.cached_tokens;
        if (hit == 0) {
            if (self.prompt_tokens_details) |d| hit = d.cached_tokens;
        }
        var miss = self.prompt_cache_miss_tokens;
        if (miss == 0 and self.prompt_tokens > hit) miss = self.prompt_tokens - hit;
        return .{ .tokens = self.prompt_tokens, .cache_hit_tokens = hit, .cache_miss_tokens = miss };
    }
};

const Response = struct {
    choices: []const Choice = &.{},
    usage: ?Usage = null,
    @"error": ?ApiError = null,
};

fn parseResponse(arena: std.mem.Allocator, body: []const u8, err_detail: ?*?[]const u8) anyerror!types.ChatResponse {
    const parsed = try json.parseFromSliceLeaky(Response, arena, body, .{ .ignore_unknown_fields = true });
    if (parsed.@"error") |e| {
        // A 200 carrying an error body never reaches the HTTP error path, so
        // this is the only place the provider's reason is visible: log it AND
        // hand it to the caller, or a rate limit reads identically to a bad key.
        var log_detail_buf: [redact.max_log_detail_len]u8 = undefined;
        const msg = e.message orelse "no message";
        log.log(.error_, "openai provider error ({s}): {s}", .{ e.type orelse "unknown", redact.forLog(&log_detail_buf, msg) });
        if (err_detail) |d| d.* = if (e.message) |m| try redact.forCaller(arena, m) else e.type;
        return error.ApiError;
    }
    if (parsed.choices.len == 0) return error.EmptyChoices;
    const choice = parsed.choices[0];
    const msg = choice.message;

    // The parsed slices point into `body` (gpa-owned, freed after this
    // function returns); deep-copy everything we keep into the arena.
    var usage_out: ?types.Usage = null;
    if (parsed.usage) |u| {
        const p = u.normalize();
        usage_out = .{
            .prompt_tokens = p.tokens,
            .completion_tokens = u.completion_tokens,
            .total_tokens = u.total_tokens,
            .prompt_cache_hit_tokens = p.cache_hit_tokens,
            .prompt_cache_miss_tokens = p.cache_miss_tokens,
        };
    }
    var msg_out = types.Message{ .role = .assistant, .content = null };
    if (msg.content) |c| msg_out.content = try arena.dupe(u8, c);
    if (msg.tool_calls) |calls| {
        var list: std.ArrayList(types.ToolCall) = .empty;
        for (calls) |tc| {
            try list.append(arena, .{
                .id = try arena.dupe(u8, tc.id),
                .name = try arena.dupe(u8, tc.function.name),
                .arguments = try arena.dupe(u8, tc.function.arguments),
            });
        }
        msg_out.tool_calls = try list.toOwnedSlice(arena);
    }
    var finish_reason: ?[]const u8 = null;
    if (choice.finish_reason) |fr| finish_reason = try arena.dupe(u8, fr);
    var reasoning: ?[]const u8 = null;
    if (msg.reasoning_content) |rc| {
        if (rc.len > 0) reasoning = try arena.dupe(u8, rc);
    }
    return .{
        .message = msg_out,
        .usage = usage_out,
        .finish_reason = finish_reason,
        .reasoning = reasoning,
        .raw = try arena.dupe(u8, body),
    };
}

fn parseErrorDetail(arena: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const parsed = json.parseFromSliceLeaky(Response, arena, body, .{ .ignore_unknown_fields = true }) catch return null;
    if (parsed.@"error") |e| return e.message;
    return null;
}

// ----------------------------------------------------------------- stream --

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
    usage: ?Usage = null,
};

/// Empty strings on the wire mean "this fragment carries nothing", not "set
/// it to empty": a later fragment still has to be able to fill the field.
fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len > 0) v else null;
}

fn parseStreamEvent(chunk_arena: std.mem.Allocator, payload: []const u8) api.StreamParseError!?api.StreamEvent {
    if (common.isDoneSentinel(payload)) return .{ .done = true };

    const chunk = json.parseFromSliceLeaky(StreamChunk, chunk_arena, payload, .{ .ignore_unknown_fields = true }) catch {
        // Dropping a frame silently hides truncated or re-framed streams as
        // "the model said nothing". Log the byte count only, the payload is
        // raw provider output that may contain generated content or echoed
        // user data.
        log.log(.debug, "unparseable stream frame ({d} bytes)", .{payload.len});
        return null;
    };

    var ev: api.StreamEvent = .{};
    // The final chunk may carry usage with an empty choices list, so read it
    // before the choices guard.
    if (chunk.usage) |u| {
        if (u.total_tokens > 0) ev.usage = .{
            .prompt = u.normalize(),
            .completion = u.completion_tokens,
            .total = u.total_tokens,
        };
    }
    if (chunk.choices.len == 0) return ev;

    const choice = chunk.choices[0];
    ev.finish_reason = choice.finish_reason;
    ev.text = nonEmpty(choice.delta.content);
    if (choice.delta.tool_calls) |tcs| {
        const frags = try chunk_arena.alloc(api.ToolCallFragment, tcs.len);
        for (tcs, frags) |src, *dst| dst.* = .{
            .index = src.index,
            .id = nonEmpty(src.id),
            .name = nonEmpty(src.function.name),
            .arguments = nonEmpty(src.function.arguments),
        };
        ev.tool_calls = frags;
    }
    return ev;
}

// ------------------------------------------------------------------- tests --

test "openai request body golden" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = try config.Provider.single(arena, "deepseek", "https://api.deepseek.com", .openai_compat, "deepseek-chat", .{ .max_tokens = 512 });
    const messages = [_]types.Message{
        .{ .role = .system, .content = "be brief" },
        .{ .role = .user, .content = "hi" },
    };
    const body = try buildRequest(arena, .{
        .provider = &p,
        .messages = &messages,
        .temperature = 0.2,
    });
    defer arena.free(body);

    const expected =
        \\{"model":"deepseek-chat","messages":[{"role":"system","content":"be brief"},{"role":"user","content":"hi"}],"temperature":0.2,"max_tokens":512,"stream":false}
    ;
    try std.testing.expectEqualStrings(expected, body);
}

test "openai request body sends a model alias id as the wire SKU" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = try config.Provider.single(arena, "xai", "https://api.x.ai/v1", .openai_compat, "grok4.6-coding", .{
        .id = "grok-4.6",
        .temperature = 0.2,
        .max_tokens = 512,
    });
    const messages = [_]types.Message{.{ .role = .user, .content = "hi" }};
    const body = try buildRequest(arena, .{ .provider = &p, .messages = &messages });
    defer arena.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"grok-4.6\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "grok4.6-coding") == null);
}

test "openai request body sends reasoning_effort and omits it when unset" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = try config.Provider.single(arena, "ollama", "http://localhost:11434", .openai_compat, "llama3.3", .{ .max_tokens = 64, .reasoning_effort = .high });
    const messages = [_]types.Message{
        .{ .role = .user, .content = "hi" },
    };
    const body = try buildRequest(arena, .{
        .provider = &p,
        .messages = &messages,
    });
    defer arena.free(body);
    // Exactly once: writeSamplingParams is the only writer. This codec used to
    // write the field a second time from the model config directly, which a
    // presence check would not have caught.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "\"reasoning_effort\":\"high\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "reasoning_effort"));

    const plain = try config.Provider.single(arena, "ollama", "http://localhost:11434", .openai_compat, "llama3.3", .{ .max_tokens = 64 });
    const plain_body = try buildRequest(arena, .{
        .provider = &plain,
        .messages = &messages,
    });
    defer arena.free(plain_body);
    try std.testing.expect(std.mem.find(u8, plain_body, "reasoning_effort") == null);
}

test "thinking_schema picks the reasoning wire shape" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const messages = [_]types.Message{.{ .role = .user, .content = "hi" }};

    const nested = try config.Provider.single(arena, "or", "https://or.test/v1", .openai_compat, "m", .{ .max_tokens = 64, .reasoning_effort = .high, .thinking_schema = .reasoning });
    const nested_body = try buildRequest(arena, .{ .provider = &nested, .messages = &messages });
    defer arena.free(nested_body);
    try std.testing.expect(std.mem.find(u8, nested_body, "\"reasoning\":{\"effort\":\"high\"}") != null);
    try std.testing.expect(std.mem.find(u8, nested_body, "reasoning_effort") == null);

    const toggle = try config.Provider.single(arena, "zai", "https://zai.test/v1", .openai_compat, "m", .{ .max_tokens = 64, .reasoning_effort = .high, .thinking_schema = .thinking });
    const toggle_body = try buildRequest(arena, .{ .provider = &toggle, .messages = &messages });
    defer arena.free(toggle_body);
    try std.testing.expect(std.mem.find(u8, toggle_body, "\"thinking\":{\"type\":\"enabled\"}") != null);

    const off = try config.Provider.single(arena, "q", "https://q.test/v1", .openai_compat, "m", .{ .max_tokens = 64, .reasoning_effort = .high, .thinking_schema = .none });
    const off_body = try buildRequest(arena, .{ .provider = &off, .messages = &messages });
    defer arena.free(off_body);
    try std.testing.expect(std.mem.find(u8, off_body, "reasoning") == null);
    try std.testing.expect(std.mem.find(u8, off_body, "thinking") == null);
}

test "tool_schema none omits the tools array" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const messages = [_]types.Message{.{ .role = .user, .content = "hi" }};
    const tools = [_]types.ToolDef{.{ .name = "read_file", .description = "read", .input_schema = .null }};

    const bare = try config.Provider.single(arena, "q", "https://q.test/v1", .openai_compat, "m", .{ .max_tokens = 64, .tool_schema = .none });
    const body = try buildRequest(arena, .{ .provider = &bare, .messages = &messages, .tools = &tools });
    defer arena.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"tools\"") == null);

    const std_p = try config.Provider.single(arena, "q", "https://q.test/v1", .openai_compat, "m", .{ .max_tokens = 64 });
    const std_body = try buildRequest(arena, .{ .provider = &std_p, .messages = &messages, .tools = &tools });
    defer arena.free(std_body);
    try std.testing.expect(std.mem.find(u8, std_body, "\"tools\"") != null);
}

test "openai response parse with tool call" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"calculator","arguments":"{\"a\":2}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":4,"total_tokens":14}}
    ;
    const resp = try parseResponse(arena, body, null);
    try std.testing.expectEqual(types.Role.assistant, resp.message.role);
    try std.testing.expectEqual(@as(usize, 1), resp.message.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_1", resp.message.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("calculator", resp.message.tool_calls.?[0].name);
    try std.testing.expectEqualStrings("{\"a\":2}", resp.message.tool_calls.?[0].arguments);
    try std.testing.expectEqualStrings("tool_calls", resp.finish_reason.?);
    try std.testing.expectEqual(@as(u32, 14), resp.usage.?.total_tokens);
}

test "an error body in a 200 surfaces the provider's message to the caller" {
    // The HTTP error path never sees these bodies, so without err_detail the
    // caller gets a bare error.ApiError and no idea what the provider said.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"error":{"message":"Rate limit reached for requests","type":"rate_limit_error"}}
    ;
    var detail: ?[]const u8 = null;
    try std.testing.expectError(error.ApiError, parseResponse(arena, body, &detail));
    try std.testing.expectEqualStrings("Rate limit reached for requests", detail.?);

    // A null out-param (tests, future callers) still parses successfully.
    try std.testing.expectError(error.ApiError, parseResponse(arena, body, null));

    // And the HTTP-error path finds the same sentence.
    try std.testing.expectEqualStrings("Rate limit reached for requests", parseErrorDetail(arena, body).?);
    try std.testing.expect(parseErrorDetail(arena, "not json at all") == null);
}

test "cache-hit tokens are read from whichever field the vendor uses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Moonshot reports `cached_tokens` and no miss count.
    const body =
        \\{"choices":[{"message":{"content":"hi"}}],"usage":{"prompt_tokens":100,"completion_tokens":5,"total_tokens":105,"cached_tokens":60}}
    ;
    const resp = try parseResponse(arena, body, null);
    const u = resp.usage.?;
    try std.testing.expectEqual(@as(u32, 60), u.prompt_cache_hit_tokens);
    try std.testing.expectEqual(@as(u32, 40), u.prompt_cache_miss_tokens);
}

test "openai stream frames decode into neutral events" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = (try parseStreamEvent(arena, "{\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":\"stop\"}]}")).?;
    try std.testing.expectEqualStrings("hi", text.text.?);
    try std.testing.expectEqualStrings("stop", text.finish_reason.?);
    try std.testing.expect(!text.done);

    const tool = (try parseStreamEvent(arena,
        \\{"choices":[{"delta":{"tool_calls":[{"index":2,"id":"call_1","function":{"name":"calc","arguments":"{\"a\":"}}]}}]}
    )).?;
    try std.testing.expectEqual(@as(usize, 1), tool.tool_calls.len);
    try std.testing.expectEqual(@as(usize, 2), tool.tool_calls[0].index);
    try std.testing.expectEqualStrings("call_1", tool.tool_calls[0].id.?);
    try std.testing.expectEqualStrings("calc", tool.tool_calls[0].name.?);
    try std.testing.expectEqualStrings("{\"a\":", tool.tool_calls[0].arguments.?);

    // A continuation fragment carries arguments only; empty strings must not
    // overwrite an id or name a previous frame already supplied.
    const cont = (try parseStreamEvent(arena,
        \\{"choices":[{"delta":{"tool_calls":[{"index":2,"id":"","function":{"arguments":"2}"}}]}}]}
    )).?;
    try std.testing.expect(cont.tool_calls[0].id == null);
    try std.testing.expect(cont.tool_calls[0].name == null);
    try std.testing.expectEqualStrings("2}", cont.tool_calls[0].arguments.?);

    // Usage arrives in a final chunk with no choices at all.
    const usage = (try parseStreamEvent(arena,
        \\{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":4,"total_tokens":14}}
    )).?;
    try std.testing.expectEqual(@as(u32, 10), usage.usage.?.prompt.?.tokens);
    try std.testing.expectEqual(@as(u32, 4), usage.usage.?.completion.?);
    try std.testing.expectEqual(@as(u32, 14), usage.usage.?.total.?);

    // A zero-token usage report says nothing and must not blank a real one.
    const empty_usage = (try parseStreamEvent(arena, "{\"choices\":[],\"usage\":{\"total_tokens\":0}}")).?;
    try std.testing.expect(empty_usage.usage == null);

    try std.testing.expect((try parseStreamEvent(arena, "[DONE]")).?.done);
    try std.testing.expect(try parseStreamEvent(arena, "{ not json") == null);
}

test "fuzz: openai stream events never hang or crash on malformed payloads" {
    // parseStreamEvent sees whatever the provider sends on the SSE wire. The
    // property under test is simply that no byte sequence panics or allocates
    // without bound, including adversarial tool-call index fields.
    const F = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.slice(&buf);
            const payload = buf[0..len];

            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            _ = try parseStreamEvent(arena_state.allocator(), payload);
        }
    };
    try std.testing.fuzz({}, F.one, .{});
}

test "openai endpoint url" {
    const p = config.Provider{ .name = "m", .base_url = "https://api.deepseek.com/", .default_model = "x" };
    const url = try endpointUrl(std.testing.allocator, &p, false);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://api.deepseek.com/chat/completions", url);

    // Streaming is a body flag here, not a different endpoint.
    const stream_url = try endpointUrl(std.testing.allocator, &p, true);
    defer std.testing.allocator.free(stream_url);
    try std.testing.expectEqualStrings(url, stream_url);
}

test "the credential rides Authorization: Bearer whatever the strategy" {
    var headers: std.http.Client.Request.Headers = .{};
    var extra: api.ExtraHeaders = undefined;

    try std.testing.expectEqual(@as(usize, 0), provider.authHeaders(.{}, &headers, &extra));
    try std.testing.expect(headers.authorization == .default);

    const n = provider.authHeaders(.{ .value = "k", .bearer = "Bearer k" }, &headers, &extra);
    try std.testing.expectEqual(@as(usize, 0), n);
    try std.testing.expectEqualStrings("Bearer k", headers.authorization.override);
}
