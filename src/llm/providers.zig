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

pub const RequestParams = struct {
    provider: *const config.Provider,
    messages: []const types.Message,
    tools: ?[]const types.ToolDef = null,
    temperature: ?f64 = null,
    max_tokens: ?u32 = null,
    response_format_json: bool = false,
    /// Ask the provider to stream the response (SSE). Consumed by
    /// client.chatStream, which parses the chunked deltas.
    stream: bool = false,
};

pub const BuildError = error{ OutOfMemory, BodyTooLarge } || std.Io.Writer.Error;

/// Upper bound for request bodies (large tool schemas).
const body_cap = 1 << 20;

/// Serializes a request body for the provider into a newly allocated buffer
/// (caller frees).
pub fn buildRequest(gpa: std.mem.Allocator, params: RequestParams) BuildError![]u8 {
    return switch (params.provider.kind) {
        .openai_compat => buildOpenAI(gpa, params),
        .anthropic => buildAnthropic(gpa, params),
    };
}

fn newBuilder(gpa: std.mem.Allocator) !Builder {
    const buf = try gpa.alloc(u8, body_cap);
    return .{ .buf = buf, .w = .fixed(buf), .gpa = gpa };
}

const Builder = struct {
    buf: []u8,
    w: std.Io.Writer,
    gpa: std.mem.Allocator,
};

/// Creates a Stringify writing into the builder's writer. The returned
/// Stringify is only valid while the Builder is alive.
fn begin(b: *Builder) json.Stringify {
    return .{ .writer = &b.w, .options = .{ .emit_null_optional_fields = false } };
}

/// Shrinks the buffer to the exact bytes written; the returned slice is the
/// exact allocation, so it can be freed with the builder's allocator.
fn finish(b: *Builder) ![]u8 {
    const end = b.w.end;
    b.buf = try b.gpa.realloc(b.buf, end);
    return b.buf;
}

fn jstr(s: *json.Stringify, value: []const u8) !void {
    try s.write(value);
}

fn jval(s: *json.Stringify, value: anytype) !void {
    try s.write(value);
}

// ---------------------------------------------------------------- openai --

fn buildOpenAI(gpa: std.mem.Allocator, params: RequestParams) BuildError![]u8 {
    var b = try newBuilder(gpa);
    errdefer gpa.free(b.buf);
    var s = begin(&b);

    try s.beginObject();
    try s.objectField("model");
    try jstr(&s, params.provider.model);
    try s.objectField("messages");
    try s.beginArray();
    for (params.messages) |m| {
        try s.beginObject();
        try s.objectField("role");
        try jstr(&s, m.role.asStr());
        if (m.content) |c| {
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

    const temp = params.temperature orelse params.provider.temperature;
    if (temp) |t| {
        try s.objectField("temperature");
        try s.print("{d}", .{t});
    }
    const max_tokens = params.max_tokens orelse params.provider.max_tokens;
    try s.objectField("max_tokens");
    try s.print("{d}", .{max_tokens});
    try s.objectField("stream");
    try s.write(params.stream);
    if (params.provider.reasoning_effort) |re| {
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

const OpenAIResponse = struct {
    choices: []const OpenAIChoice = &.{},
    usage: ?types.Usage = null,
    @"error": ?OpenAIError = null,
};

fn parseOpenAI(arena: std.mem.Allocator, body: []const u8) !types.ChatResponse {
    const parsed = try json.parseFromSliceLeaky(OpenAIResponse, arena, body, .{ .ignore_unknown_fields = true });
    if (parsed.@"error") |e| {
        _ = e;
        return error.ApiError;
    }
    if (parsed.choices.len == 0) return error.EmptyChoices;
    const choice = parsed.choices[0];
    const msg = choice.message;

    // The parsed slices point into `body` (gpa-owned, freed after this
    // function returns); deep-copy everything we keep into the arena.
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
        .usage = parsed.usage,
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
        .anthropic => {
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
    errdefer gpa.free(b.buf);
    var s = begin(&b);

    try s.beginObject();
    try s.objectField("model");
    try jstr(&s, params.provider.model);
    const max_tokens = params.max_tokens orelse params.provider.max_tokens;
    try s.objectField("max_tokens");
    try s.print("{d}", .{max_tokens});

    // Anthropic takes the system prompt as a top-level field.
    var system_parts: std.ArrayList([]const u8) = .empty;
    for (params.messages) |m| {
        if (m.role == .system and m.content != null) try system_parts.append(gpa, m.content.?);
    }
    if (system_parts.items.len > 0) {
        try s.objectField("system");
        if (system_parts.items.len == 1) {
            try jstr(&s, system_parts.items[0]);
        } else {
            try s.beginArray();
            for (system_parts.items) |part| {
                try s.beginObject();
                try s.objectField("type");
                try jstr(&s, "text");
                try s.objectField("text");
                try jstr(&s, part);
                try s.endObject();
            }
            try s.endArray();
        }
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
                try jstr(&s, m.content orelse "");
                try s.endObject();
            },
            .assistant => {
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
                        const input = json.parseFromSliceLeaky(json.Value, gpa, tc.arguments, .{}) catch json.Value{ .object = .empty };
                        try jval(&s, input);
                        try s.endObject();
                    }
                }
                if (m.content) |c| {
                    try s.beginObject();
                    try s.objectField("type");
                    try jstr(&s, "text");
                    try s.objectField("text");
                    try jstr(&s, c);
                    try s.endObject();
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

    const temp = params.temperature orelse params.provider.temperature;
    if (temp) |t| {
        try s.objectField("temperature");
        try s.print("{d}", .{t});
    }
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
    } = null,
    @"error": ?struct {
        message: ?[]const u8 = null,
        type: ?[]const u8 = null,
    } = null,
};

fn parseAnthropic(arena: std.mem.Allocator, body: []const u8) !types.ChatResponse {
    const parsed = try json.parseFromSliceLeaky(AnthropicResponse, arena, body, .{ .ignore_unknown_fields = true });
    if (parsed.@"error") |e| {
        _ = e;
        return error.ApiError;
    }

    var text_parts: std.ArrayList(u8) = .empty;
    var calls: std.ArrayList(types.ToolCall) = .empty;

    for (parsed.content) |block| {
        if (std.mem.eql(u8, block.type, "text")) {
            if (block.text) |t| try text_parts.appendSlice(arena, t);
        } else if (std.mem.eql(u8, block.type, "tool_use")) {
            const w_buf = try arena.alloc(u8, 64 * 1024);
            var w: std.Io.Writer = .fixed(w_buf);
            if (block.input) |inp| {
                json.Stringify.value(inp, .{}, &w) catch {};
            }
            try calls.append(arena, .{
                .id = try arena.dupe(u8, block.id orelse ""),
                .name = try arena.dupe(u8, block.name orelse ""),
                .arguments = try arena.dupe(u8, w_buf[0..w.end]),
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
        usage = .{ .prompt_tokens = u.input_tokens, .completion_tokens = u.output_tokens, .total_tokens = u.input_tokens + u.output_tokens };
    }

    return .{
        .message = msg,
        .usage = usage,
        .finish_reason = parsed.stop_reason,
        .raw = try arena.dupe(u8, body),
    };
}

// ------------------------------------------------------------------ public --

pub fn parseResponse(arena: std.mem.Allocator, kind: config.ProviderKind, body: []const u8) !types.ChatResponse {
    return switch (kind) {
        .openai_compat => parseOpenAI(arena, body),
        .anthropic => parseAnthropic(arena, body),
    };
}

// ------------------------------------------------------------------- tests --

test "openai request body golden" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const provider = config.Provider{
        .name = "deepseek",
        .base_url = "https://api.deepseek.com",
        .model = "deepseek-chat",
        .max_tokens = 512,
    };
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
    const resp = try parseOpenAI(arena, body);
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

    const provider = config.Provider{
        .name = "claude",
        .kind = .anthropic,
        .base_url = "https://api.anthropic.com",
        .model = "claude-sonnet",
        .max_tokens = 256,
    };
    const messages = [_]types.Message{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "hello" },
    };
    const body = try buildRequest(arena, .{ .provider = &provider, .messages = &messages });
    defer arena.free(body);

    const parsed = try json.parseFromSliceLeaky(json.Value, arena, body, .{});
    const obj = parsed.object;
    try std.testing.expectEqualStrings("sys", obj.get("system").?.string);
    const msgs = obj.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expectEqualStrings("user", msgs[0].object.get("role").?.string);
}
