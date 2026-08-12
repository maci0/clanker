//! Provider adapters: build provider-specific request bodies and parse
//! provider-specific responses into the canonical `types` structures.
//!
//! Supported kinds:
//!   - openai_compat: OpenAI-style `/chat/completions` (DeepSeek, OpenAI,
//!     Ollama, OpenRouter, Groq, ...).
//!   - anthropic: Anthropic Messages API.

const std = @import("std");
const json = std.json;
const types = @import("types.zig");
const config = @import("../config.zig");
const log = @import("../util/log.zig");

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

/// Clamps the requested output budget to fit the model's context window:
/// never ask for more completion tokens than half the window.
fn clampedMaxTokens(params: RequestParams) u32 {
    const active = params.provider.activeModel();
    return @min(params.max_tokens orelse active.max_tokens, active.context_window / 2);
}

/// The body grows to fit. It used to be capped at 1 MiB, which was ample for
/// tool schemas and then became a ceiling on how much source the
/// self-improvement engine could send: a context near the cap failed the whole
/// request with a bare WriteFailed, naming nothing.
/// Serializes a request body for the provider into a newly allocated buffer
/// (caller frees).
pub fn buildRequest(gpa: std.mem.Allocator, params: RequestParams) BuildError![]u8 {
    return switch (params.provider.kind) {
        .openai_compat => buildOpenAI(gpa, params),
        // Vertex speaks the Anthropic message format, minus the model field
        // (it is in the URL) and plus anthropic_version.
        .anthropic, .vertex_anthropic => buildAnthropic(gpa, params),
    };
}

fn newBuilder(gpa: std.mem.Allocator) !Builder {
    return .{ .out = .init(gpa), .gpa = gpa };
}

const Builder = struct {
    out: std.Io.Writer.Allocating,
    gpa: std.mem.Allocator,
};

/// Creates a Stringify writing into the builder's writer. The returned
/// Stringify is only valid while the Builder is alive.
fn begin(b: *Builder) json.Stringify {
    return .{ .writer = &b.out.writer, .options = .{ .emit_null_optional_fields = false } };
}

/// Hands over the exact bytes written; the caller frees them with the
/// builder's allocator.
fn finish(b: *Builder) ![]u8 {
    return b.out.toOwnedSlice();
}

fn jstr(s: *json.Stringify, value: []const u8) !void {
    try s.write(value);
}

fn jval(s: *json.Stringify, value: anytype) !void {
    try s.write(value);
}

/// Writes `temperature` and `top_p` when configured. Only sent when
/// configured: both knobs narrow the same distribution, so a model left at
/// its provider default is deliberately left there rather than given a value
/// this harness invented.
fn writeSamplingParams(s: *json.Stringify, params: RequestParams) !void {
    const temp = params.temperature orelse params.provider.activeModel().temperature;
    if (temp) |t| {
        try s.objectField("temperature");
        try s.print("{d}", .{t});
    }
    const nucleus = params.top_p orelse params.provider.activeModel().top_p;
    if (nucleus) |tp| {
        try s.objectField("top_p");
        try s.print("{d}", .{tp});
    }
}

// ---------------------------------------------------------------- openai --

fn buildOpenAI(gpa: std.mem.Allocator, params: RequestParams) BuildError![]u8 {
    var b = try newBuilder(gpa);
    errdefer b.out.deinit();
    var s = begin(&b);

    try s.beginObject();
    try s.objectField("model");
    try jstr(&s, params.provider.activeModelName());
    try s.objectField("messages");
    try s.beginArray();
    for (params.messages) |m| {
        try s.beginObject();
        try s.objectField("role");
        try jstr(&s, m.role.asStr());
        if (m.images) |imgs| {
            // Multimodal: content is an array of text + image_url blocks.
            try s.objectField("content");
            try s.beginArray();
            if (m.content) |c| {
                try s.beginObject();
                try s.objectField("type");
                try jstr(&s, "text");
                try s.objectField("text");
                try jstr(&s, c);
                try s.endObject();
            }
            for (imgs) |img| {
                try s.beginObject();
                try s.objectField("type");
                try jstr(&s, "image_url");
                try s.objectField("image_url");
                try s.beginObject();
                try s.objectField("url");
                const url = try std.fmt.allocPrint(gpa, "data:{s};base64,{s}", .{ img.mime, img.b64 });
                defer gpa.free(url);
                try jstr(&s, url);
                try s.endObject();
                try s.endObject();
            }
            try s.endArray();
        } else if (m.content) |c| {
            try s.objectField("content");
            try jstr(&s, c);
        }
        if (m.tool_calls) |calls| {
            try s.objectField("tool_calls");
            try s.beginArray();
            for (calls) |tc| {
                try s.beginObject();
                try s.objectField("id");
                try jstr(&s, tc.id);
                try s.objectField("type");
                try jstr(&s, "function");
                try s.objectField("function");
                try s.beginObject();
                try s.objectField("name");
                try jstr(&s, tc.name);
                try s.objectField("arguments");
                try jstr(&s, tc.arguments);
                try s.endObject();
                try s.endObject();
            }
            try s.endArray();
        }
        if (m.tool_call_id) |tid| {
            try s.objectField("tool_call_id");
            try jstr(&s, tid);
        }
        try s.endObject();
    }
    try s.endArray();

    if (params.tools) |tools| {
        try s.objectField("tools");
        try s.beginArray();
        for (tools) |t| {
            try s.beginObject();
            try s.objectField("type");
            try jstr(&s, "function");
            try s.objectField("function");
            try s.beginObject();
            try s.objectField("name");
            try jstr(&s, t.name);
            try s.objectField("description");
            try jstr(&s, t.description);
            try s.objectField("parameters");
            try jval(&s, t.input_schema);
            try s.endObject();
            try s.endObject();
        }
        try s.endArray();
    }

    try writeSamplingParams(&s, params);
    const max_tokens = clampedMaxTokens(params);
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
    if (params.provider.activeModel().reasoning_effort) |re| {
        try s.objectField("reasoning_effort");
        try jstr(&s, re);
    }
    if (params.response_format_json) {
        try s.objectField("response_format");
        try s.beginObject();
        try s.objectField("type");
        try jstr(&s, "json_object");
        try s.endObject();
    }
    try s.endObject();

    return try finish(&b);
}

const OpenAIMessage = struct {
    role: []const u8 = "assistant",
    content: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
    tool_calls: ?[]const OpenAIToolCall = null,
};

const OpenAIToolCall = struct {
    id: []const u8 = "",
    function: struct {
        name: []const u8 = "",
        arguments: []const u8 = "",
    } = .{},
};

const OpenAIChoice = struct {
    message: OpenAIMessage = .{},
    finish_reason: ?[]const u8 = null,
};

const OpenAIError = struct {
    message: ?[]const u8 = null,
    type: ?[]const u8 = null,
};

const OpenAIUsage = struct {
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
};

const OpenAIResponse = struct {
    choices: []const OpenAIChoice = &.{},
    usage: ?OpenAIUsage = null,
    @"error": ?OpenAIError = null,
};

fn parseOpenAI(arena: std.mem.Allocator, body: []const u8, err_detail: ?*?[]const u8) !types.ChatResponse {
    const parsed = try json.parseFromSliceLeaky(OpenAIResponse, arena, body, .{ .ignore_unknown_fields = true });
    if (parsed.@"error") |e| {
        // A 200 carrying an error body never reaches the HTTP error path, so
        // this is the only place the provider's reason is visible: log it AND
        // hand it to the caller, or a rate limit reads identically to a bad key.
        log.log(.error_, "openai provider error ({s}): {s}", .{ e.type orelse "unknown", e.message orelse "no message" });
        if (err_detail) |d| d.* = if (e.message) |m| try arena.dupe(u8, m) else e.type;
        return error.ApiError;
    }
    if (parsed.choices.len == 0) return error.EmptyChoices;
    const choice = parsed.choices[0];
    const msg = choice.message;

    // The parsed slices point into `body` (gpa-owned, freed after this
    // function returns); deep-copy everything we keep into the arena.
    var usage_out: ?types.Usage = null;
    if (parsed.usage) |u| {
        var hit = u.prompt_cache_hit_tokens;
        if (hit == 0) hit = u.cached_tokens;
        if (hit == 0) {
            if (u.prompt_tokens_details) |d| hit = d.cached_tokens;
        }
        var miss = u.prompt_cache_miss_tokens;
        if (miss == 0 and u.prompt_tokens > hit) miss = u.prompt_tokens - hit;
        usage_out = .{
            .prompt_tokens = u.prompt_tokens,
            .completion_tokens = u.completion_tokens,
            .total_tokens = u.total_tokens,
            .prompt_cache_hit_tokens = hit,
            .prompt_cache_miss_tokens = miss,
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

/// Best-effort extraction of the API error message from an error body.
pub fn parseErrorDetail(arena: std.mem.Allocator, kind: config.ProviderKind, body: []const u8) ?[]const u8 {
    switch (kind) {
        .openai_compat => {
            const parsed = json.parseFromSliceLeaky(OpenAIResponse, arena, body, .{ .ignore_unknown_fields = true }) catch return null;
            if (parsed.@"error") |e| return e.message;
            return null;
        },
        .anthropic, .vertex_anthropic => {
            const parsed = json.parseFromSliceLeaky(AnthropicError, arena, body, .{ .ignore_unknown_fields = true }) catch return null;
            if (parsed.@"error") |e| return e.message;
            return null;
        },
    }
}

// -------------------------------------------------------------- anthropic --

const AnthropicError = struct {
    @"error": ?struct {
        message: ?[]const u8 = null,
        type: ?[]const u8 = null,
    } = null,
};

fn buildAnthropic(gpa: std.mem.Allocator, params: RequestParams) BuildError![]u8 {
    var b = try newBuilder(gpa);
    errdefer b.out.deinit();
    // Scratch space for re-parsing tool arguments; freed when the body is
    // built, so the parsed values never outlive this call.
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    var s = begin(&b);

    try s.beginObject();
    if (params.provider.kind == .vertex_anthropic) {
        // Vertex takes the model in the URL and requires this version tag.
        try s.objectField("anthropic_version");
        try jstr(&s, "vertex-2023-10-16");
    } else {
        try s.objectField("model");
        try jstr(&s, params.provider.activeModelName());
    }
    // Anthropic streams only when asked in the body; the endpoint verb alone
    // (Vertex's :streamRawPredict) is not enough.
    if (params.stream) {
        try s.objectField("stream");
        try s.write(true);
    }
    const max_tokens = clampedMaxTokens(params);
    try s.objectField("max_tokens");
    try s.print("{d}", .{max_tokens});

    // Anthropic takes the system prompt as a top-level field.
    var system_parts: std.ArrayList([]const u8) = .empty;
    // The list is gpa-backed; only the strings it points at belong to the
    // caller's arena.
    defer system_parts.deinit(gpa);
    for (params.messages) |m| {
        if (m.role == .system and m.content != null) try system_parts.append(gpa, m.content.?);
    }
    if (system_parts.items.len > 0) {
        try s.objectField("system");
        // Always the block form, so a block can carry a cache breakpoint.
        // Tools and the system prompt are the stable prefix of every turn in a
        // run, and they render ahead of the messages, so a breakpoint here
        // caches both: without it a long system prompt is re-billed in full on
        // every iteration.
        //
        // The last two blocks are marked rather than only the last. A lookup
        // matches the longest cached prefix, so a caller that puts what changes
        // in its final block keeps the bulk cached when that block changes.
        // The improve engine does exactly this: the file it is about to patch
        // sits alone at the end, and everything before it survives the patch.
        try s.beginArray();
        const first_marked = system_parts.items.len -| 2;
        for (system_parts.items, 0..) |part, i| {
            try s.beginObject();
            try s.objectField("type");
            try jstr(&s, "text");
            try s.objectField("text");
            try jstr(&s, part);
            if (i >= first_marked) {
                try s.objectField("cache_control");
                try s.beginObject();
                try s.objectField("type");
                try jstr(&s, "ephemeral");
                try s.endObject();
            }
            try s.endObject();
        }
        try s.endArray();
    }

    try s.objectField("messages");
    try s.beginArray();
    for (params.messages) |m| {
        if (m.role == .system) continue;
        try s.beginObject();
        try s.objectField("role");
        try jstr(&s, switch (m.role) {
            .system => "user", // unreachable; skipped above
            .user => "user",
            .assistant => "assistant",
            .tool => "user",
        });
        try s.objectField("content");
        try s.beginArray();
        switch (m.role) {
            .tool => {
                try s.beginObject();
                try s.objectField("type");
                try jstr(&s, "tool_result");
                try s.objectField("tool_use_id");
                try jstr(&s, m.tool_call_id orelse "");
                try s.objectField("content");
                // Canonical array form: Anthropic accepts tool_result content
                // either as a bare string or as an array of content blocks,
                // but some Claude-compatible gateways normalize each block
                // into `{ "tool_result": { content: [...] } }` and only
                // accept the array form — a bare string fails with
                // "content.0: Input should be a valid dictionary or object
                // to extract fields from". The array form satisfies both.
                try s.beginArray();
                try s.beginObject();
                try s.objectField("type");
                try jstr(&s, "text");
                try s.objectField("text");
                try jstr(&s, m.content orelse "");
                try s.endObject();
                try s.endArray();
                try s.endObject();
            },
            .assistant => {
                // Text first, then tool_use — the order the model produced
                // them. An assistant turn whose last block is text reads as a
                // prefill to continue, which Anthropic rejects outright
                // ("does not support assistant message prefill"); that fires
                // on every replayed turn where the model both spoke and
                // called a tool.
                if (m.content) |c| {
                    if (c.len > 0) {
                        try s.beginObject();
                        try s.objectField("type");
                        try jstr(&s, "text");
                        try s.objectField("text");
                        try jstr(&s, c);
                        try s.endObject();
                    }
                }
                if (m.tool_calls) |calls| {
                    for (calls) |tc| {
                        try s.beginObject();
                        try s.objectField("type");
                        try jstr(&s, "tool_use");
                        try s.objectField("id");
                        try jstr(&s, tc.id);
                        try s.objectField("name");
                        try jstr(&s, tc.name);
                        try s.objectField("input");
                        // Embed the raw arguments JSON.
                        const input = json.parseFromSliceLeaky(json.Value, scratch, tc.arguments, .{}) catch json.Value{ .object = .empty };
                        try jval(&s, input);
                        try s.endObject();
                    }
                }
            },
            else => {
                try s.beginObject();
                try s.objectField("type");
                try jstr(&s, "text");
                try s.objectField("text");
                try jstr(&s, m.content orelse "");
                try s.endObject();
            },
        }
        try s.endArray();
        try s.endObject();
    }
    try s.endArray();

    if (params.tools) |tools| {
        try s.objectField("tools");
        try s.beginArray();
        for (tools) |t| {
            try s.beginObject();
            try s.objectField("name");
            try jstr(&s, t.name);
            try s.objectField("description");
            try jstr(&s, t.description);
            try s.objectField("input_schema");
            try jval(&s, t.input_schema);
            try s.endObject();
        }
        try s.endArray();
    }

    try writeSamplingParams(&s, params);
    try s.endObject();

    return try finish(&b);
}

const AnthropicBlock = struct {
    type: []const u8 = "",
    text: ?[]const u8 = null,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    input: ?std.json.Value = null,
};

const AnthropicResponse = struct {
    content: []const AnthropicBlock = &.{},
    stop_reason: ?[]const u8 = null,
    usage: ?struct {
        input_tokens: u32 = 0,
        output_tokens: u32 = 0,
        cache_read_input_tokens: u32 = 0,
        cache_creation_input_tokens: u32 = 0,
    } = null,
    @"error": ?struct {
        message: ?[]const u8 = null,
        type: ?[]const u8 = null,
    } = null,
};

fn parseAnthropic(arena: std.mem.Allocator, body: []const u8, err_detail: ?*?[]const u8) !types.ChatResponse {
    const parsed = try json.parseFromSliceLeaky(AnthropicResponse, arena, body, .{ .ignore_unknown_fields = true });
    if (parsed.@"error") |e| {
        // A 200 carrying an error body never reaches the HTTP error path, so
        // this is the only place the reason is visible: log it AND hand it to
        // the caller.
        log.log(.error_, "anthropic error ({s}): {s}", .{ e.type orelse "unknown", e.message orelse "no message" });
        if (err_detail) |d| d.* = if (e.message) |m| try arena.dupe(u8, m) else e.type;
        return error.ApiError;
    }

    var text_parts: std.ArrayList(u8) = .empty;
    var calls: std.ArrayList(types.ToolCall) = .empty;

    for (parsed.content) |block| {
        if (std.mem.eql(u8, block.type, "text")) {
            if (block.text) |t| try text_parts.appendSlice(arena, t);
        } else if (std.mem.eql(u8, block.type, "tool_use")) {
            // Growable: a fixed buffer silently truncated large tool inputs
            // into invalid JSON that the next request then replayed.
            var args: std.Io.Writer.Allocating = .init(arena);
            if (block.input) |inp| {
                try json.Stringify.value(inp, .{}, &args.writer);
            }
            const written = args.written();
            try calls.append(arena, .{
                .id = try arena.dupe(u8, block.id orelse ""),
                .name = try arena.dupe(u8, block.name orelse ""),
                // A tool taking no arguments must still replay as valid JSON.
                .arguments = if (written.len > 0) written else "{}",
            });
        }
    }

    var msg = types.Message{ .role = .assistant, .content = null };
    if (text_parts.items.len > 0) {
        msg.content = try text_parts.toOwnedSlice(arena);
    }
    if (calls.items.len > 0) {
        msg.tool_calls = try calls.toOwnedSlice(arena);
    }

    var usage: ?types.Usage = null;
    if (parsed.usage) |u| {
        // `input_tokens` already excludes cached reads and cache writes, so
        // the prompt total is the sum of all three (same accounting as the
        // streaming path, which otherwise reported different numbers for the
        // same request).
        const hit = u.cache_read_input_tokens;
        const miss = u.input_tokens + u.cache_creation_input_tokens;
        const prompt = hit + miss;
        usage = .{
            .prompt_tokens = prompt,
            .completion_tokens = u.output_tokens,
            .total_tokens = prompt + u.output_tokens,
            .prompt_cache_hit_tokens = hit,
            .prompt_cache_miss_tokens = miss,
        };
    }

    return .{
        .message = msg,
        .usage = usage,
        .finish_reason = parsed.stop_reason,
        .raw = try arena.dupe(u8, body),
    };
}

// ------------------------------------------------------------------ public --

pub fn parseResponse(arena: std.mem.Allocator, kind: config.ProviderKind, body: []const u8, err_detail: ?*?[]const u8) !types.ChatResponse {
    return switch (kind) {
        .openai_compat => parseOpenAI(arena, body, err_detail),
        .anthropic, .vertex_anthropic => parseAnthropic(arena, body, err_detail),
    };
}

// ------------------------------------------------------------------- tests --

test "openai request body golden" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const provider = try config.Provider.single(arena, "deepseek", "https://api.deepseek.com", .openai_compat, "deepseek-chat", .{ .max_tokens = 512 });
    const messages = [_]types.Message{
        .{ .role = .system, .content = "be brief" },
        .{ .role = .user, .content = "hi" },
    };
    const body = try buildRequest(arena, .{
        .provider = &provider,
        .messages = &messages,
        .temperature = 0.2,
    });
    defer arena.free(body);

    const expected =
        \\{"model":"deepseek-chat","messages":[{"role":"system","content":"be brief"},{"role":"user","content":"hi"}],"temperature":0.2,"max_tokens":512,"stream":false}
    ;
    try std.testing.expectEqualStrings(expected, body);
}

test "openai response parse with tool call" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"calculator","arguments":"{\"a\":2}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":4,"total_tokens":14}}
    ;
    const resp = try parseOpenAI(arena, body, null);
    try std.testing.expectEqual(types.Role.assistant, resp.message.role);
    try std.testing.expectEqual(@as(usize, 1), resp.message.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_1", resp.message.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("calculator", resp.message.tool_calls.?[0].name);
    try std.testing.expectEqualStrings("{\"a\":2}", resp.message.tool_calls.?[0].arguments);
    try std.testing.expectEqualStrings("tool_calls", resp.finish_reason.?);
    try std.testing.expectEqual(@as(u32, 14), resp.usage.?.total_tokens);
}

test "anthropic request body has system field and content blocks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const provider = try config.Provider.single(arena, "claude", "https://api.anthropic.com", .anthropic, "claude-sonnet", .{ .max_tokens = 256 });
    const messages = [_]types.Message{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "hello" },
    };
    const body = try buildRequest(arena, .{ .provider = &provider, .messages = &messages });
    defer arena.free(body);

    const parsed = try json.parseFromSliceLeaky(json.Value, arena, body, .{});
    const obj = parsed.object;
    const system_blocks = obj.get("system").?.array.items;
    try std.testing.expectEqualStrings("sys", system_blocks[0].object.get("text").?.string);
    // The stable tools+system prefix carries the cache breakpoint.
    try std.testing.expectEqualStrings("ephemeral", system_blocks[0].object.get("cache_control").?.object.get("type").?.string);
    const msgs = obj.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expectEqualStrings("user", msgs[0].object.get("role").?.string);
}

test "vertex request body replays tool calls without leaking the parsed input" {
    // Regression: the tool-call arguments were re-parsed with the caller's
    // general-purpose allocator using the *Leaky variant, so every replayed
    // tool call leaked its parsed JSON. The body is built with the testing
    // allocator here, which fails the test if that comes back.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var provider = try config.Provider.single(arena, "vertex-opus", "", .vertex_anthropic, "claude-opus-4-6", .{
        .context_window = 1_048_576,
        .max_tokens = 32768,
    });
    provider.project = "my-project";
    provider.location = "us-east5";

    const calls = [_]types.ToolCall{
        .{ .id = "toolu_1", .name = "history", .arguments = "{\"n\":3}" },
        .{ .id = "toolu_2", .name = "roadmap", .arguments = "{}" },
    };
    const messages = [_]types.Message{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "what next?" },
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "toolu_1", .content = "recent history" },
        .{ .role = .tool, .tool_call_id = "toolu_2", .content = "(no planned items)" },
    };

    const body = try buildRequest(std.testing.allocator, .{ .provider = &provider, .messages = &messages });
    defer std.testing.allocator.free(body);

    const parsed = try json.parseFromSliceLeaky(json.Value, arena, body, .{});
    const obj = parsed.object;
    // Vertex takes the model in the URL and the version in the body.
    try std.testing.expectEqualStrings("vertex-2023-10-16", obj.get("anthropic_version").?.string);
    try std.testing.expect(obj.get("model") == null);
    // max_tokens is clamped to half the context window, so the configured
    // 32768 passes through untouched on a 1M-token model.
    try std.testing.expectEqual(@as(i64, 32768), obj.get("max_tokens").?.integer);

    const msgs = obj.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), msgs.len);
    const blocks = msgs[1].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("tool_use", blocks[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("history", blocks[0].object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 3), blocks[0].object.get("input").?.object.get("n").?.integer);
    // A no-argument call must serialize as an empty object, not a bare string.
    try std.testing.expectEqual(@as(usize, 0), blocks[1].object.get("input").?.object.count());
}

test "anthropic max_tokens is clamped to half the context window" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const provider = try config.Provider.single(arena, "claude", "https://api.anthropic.com", .anthropic, "claude-sonnet", .{
        .context_window = 8000,
        .max_tokens = 32000,
    });
    const messages = [_]types.Message{.{ .role = .user, .content = "hi" }};
    const body = try buildRequest(arena, .{ .provider = &provider, .messages = &messages });
    defer arena.free(body);

    const parsed = try json.parseFromSliceLeaky(json.Value, arena, body, .{});
    try std.testing.expectEqual(@as(i64, 4000), parsed.object.get("max_tokens").?.integer);
}

test "anthropic response parse keeps a no-argument tool call and counts cached prompt tokens" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"id":"msg_1","type":"message","role":"assistant","content":[
        \\{"type":"text","text":"Checking."},
        \\{"type":"tool_use","id":"toolu_1","name":"roadmap","input":{}},
        \\{"type":"tool_use","id":"toolu_2","name":"history","input":{"n":3}}
        \\],"stop_reason":"tool_use","usage":{"input_tokens":40,"output_tokens":35,"cache_read_input_tokens":10,"cache_creation_input_tokens":5}}
    ;
    const resp = try parseAnthropic(arena, body, null);

    try std.testing.expectEqualStrings("Checking.", resp.message.content.?);
    const calls = resp.message.tool_calls.?;
    try std.testing.expectEqual(@as(usize, 2), calls.len);
    // Empty input must serialize as an object, not an empty string: the next
    // request replays these arguments verbatim.
    try std.testing.expectEqualStrings("{}", calls[0].arguments);
    try std.testing.expectEqualStrings("{\"n\":3}", calls[1].arguments);
    try std.testing.expectEqualStrings("tool_use", resp.finish_reason.?);

    // Prompt tokens are uncached + cache writes + cache reads, matching the
    // streaming path's accounting for the same request.
    const u = resp.usage.?;
    try std.testing.expectEqual(@as(u32, 55), u.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 10), u.prompt_cache_hit_tokens);
    try std.testing.expectEqual(@as(u32, 45), u.prompt_cache_miss_tokens);
    try std.testing.expectEqual(@as(u32, 90), u.total_tokens);
}

test "a large tool input is not truncated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Bigger than the old fixed 64 KiB scratch buffer, which truncated the
    // arguments into invalid JSON without an error.
    const big = try arena.alloc(u8, 100 * 1024);
    @memset(big, 'x');
    const body = try std.fmt.allocPrint(
        arena,
        "{{\"content\":[{{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"write\",\"input\":{{\"text\":\"{s}\"}}}}]}}",
        .{big},
    );
    const resp = try parseAnthropic(arena, body, null);

    const args = resp.message.tool_calls.?[0].arguments;
    const reparsed = try json.parseFromSliceLeaky(json.Value, arena, args, .{});
    try std.testing.expectEqual(big.len, reparsed.object.get("text").?.string.len);
}

test "assistant text precedes tool_use in the anthropic body" {
    // Anthropic reads an assistant turn whose last block is text as a prefill
    // to continue and rejects the request, so a replayed turn where the model
    // spoke *and* called tools must put the text block first.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const provider = try config.Provider.single(arena, "claude", "https://api.anthropic.com", .anthropic, "claude-opus-4-6", .{ .max_tokens = 256 });
    const calls = [_]types.ToolCall{.{ .id = "toolu_1", .name = "roadmap", .arguments = "{}" }};
    const messages = [_]types.Message{
        .{ .role = .user, .content = "what next?" },
        .{ .role = .assistant, .content = "Let me check the roadmap.", .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "toolu_1", .content = "(no planned items)" },
    };
    const body = try buildRequest(arena, .{ .provider = &provider, .messages = &messages });
    defer arena.free(body);

    const parsed = try json.parseFromSliceLeaky(json.Value, arena, body, .{});
    const msgs = parsed.object.get("messages").?.array.items;
    const blocks = msgs[1].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("text", blocks[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("tool_use", blocks[1].object.get("type").?.string);
    // The conversation still has to end on a user turn.
    try std.testing.expectEqualStrings("user", msgs[msgs.len - 1].object.get("role").?.string);
}

test "a tool_result's content is an array of text blocks, not a bare string" {
    // Regression: the tool_result `content` was serialized as a bare JSON
    // string. Anthropic accepts that, but some Claude-compatible gateways
    // normalize each content block into `{ "tool_result": { content: [...] } }`
    // and require the array form; a bare string made `content[0]` a single
    // character and failed with "Input should be a valid dictionary or object
    // to extract fields from".
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const provider = try config.Provider.single(arena, "claude", "https://api.anthropic.com", .anthropic, "claude-opus-4-6", .{ .max_tokens = 256 });
    const calls = [_]types.ToolCall{.{ .id = "toolu_1", .name = "roadmap", .arguments = "{}" }};
    const messages = [_]types.Message{
        .{ .role = .user, .content = "go" },
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "toolu_1", .content = "tool output" },
    };
    const body = try buildRequest(arena, .{ .provider = &provider, .messages = &messages });
    defer arena.free(body);

    const parsed = try json.parseFromSliceLeaky(json.Value, arena, body, .{});
    const outer = parsed.object.get("messages").?.array.items[2].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), outer.len);
    try std.testing.expectEqualStrings("tool_result", outer[0].object.get("type").?.string);
    const blocks = outer[0].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings("text", blocks[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("tool output", blocks[0].object.get("text").?.string);
}

test "an assistant turn with empty content emits no text block" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const provider = try config.Provider.single(arena, "claude", "https://api.anthropic.com", .anthropic, "claude-opus-4-6", .{ .max_tokens = 256 });
    const calls = [_]types.ToolCall{.{ .id = "toolu_1", .name = "roadmap", .arguments = "{}" }};
    const messages = [_]types.Message{
        .{ .role = .user, .content = "go" },
        .{ .role = .assistant, .content = "", .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "toolu_1", .content = "ok" },
    };
    const body = try buildRequest(arena, .{ .provider = &provider, .messages = &messages });
    defer arena.free(body);

    const parsed = try json.parseFromSliceLeaky(json.Value, arena, body, .{});
    const blocks = parsed.object.get("messages").?.array.items[1].object.get("content").?.array.items;
    // An empty text block is rejected by the API; only the tool_use survives.
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings("tool_use", blocks[0].object.get("type").?.string);
}

test "an error body in a 200 surfaces the provider's message to the caller" {
    // The HTTP error path never sees these bodies, so without err_detail the
    // caller gets a bare error.ApiError and no idea what the provider said.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const openai_body =
        \\{"error":{"message":"Rate limit reached for requests","type":"rate_limit_error"}}
    ;
    var detail: ?[]const u8 = null;
    try std.testing.expectError(error.ApiError, parseOpenAI(arena, openai_body, &detail));
    try std.testing.expectEqualStrings("Rate limit reached for requests", detail.?);

    const anthropic_body =
        \\{"error":{"message":"model: claude-nope not found","type":"not_found_error"}}
    ;
    detail = null;
    try std.testing.expectError(error.ApiError, parseAnthropic(arena, anthropic_body, &detail));
    try std.testing.expectEqualStrings("model: claude-nope not found", detail.?);

    // A null out-param (tests, future callers) still parses successfully.
    try std.testing.expectError(error.ApiError, parseOpenAI(arena, openai_body, null));
}
