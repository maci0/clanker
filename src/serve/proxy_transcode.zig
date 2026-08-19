//! Request/response/SSE transcoding for the serve proxy.
//!
//! Same-protocol forwards stay 1:1 in `proxy.zig`. This file is the other
//! half of a unified auth proxy: an OpenAI-compat client (Qwen, etc.) can
//! name a Vertex Claude model and clanker attaches GCP auth, rewrites the
//! Vertex URL/body, and speaks OpenAI on the way back.

const std = @import("std");
const json = std.json;
const config = @import("../config.zig");
const providers = @import("../llm/registry.zig");
const types = @import("../llm/types.zig");
const anthropic = @import("../llm/providers/anthropic.zig");
const openai = @import("../llm/providers/openai.zig");
const vertex_anthropic = @import("../llm/providers/vertex_anthropic.zig");

/// Drop `model` (Vertex addresses it in the URL) and set `anthropic_version`.
/// Other keys are kept: this is a field swap, not a rebuild.
pub fn rewriteVertexBody(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    var parsed = json.parseFromSlice(json.Value, gpa, body, .{}) catch return error.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.Malformed;
    _ = parsed.value.object.swapRemove("model");
    try parsed.value.object.put(gpa, "anthropic_version", .{ .string = vertex_anthropic.body_version });
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try json.Stringify.value(parsed.value, .{}, &out.writer);
    return out.toOwnedSlice();
}

pub fn openaiToAnthropic(
    gpa: std.mem.Allocator,
    provider: *const config.Provider,
    body: []const u8,
    vertex_body: bool,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const params = try parseOpenaiChat(arena, provider, body);
    const opts: anthropic.BodyOptions = if (vertex_body)
        .{ .anthropic_version = vertex_anthropic.body_version }
    else
        .{};
    return anthropic.buildBody(gpa, params, opts);
}

pub fn anthropicToOpenai(gpa: std.mem.Allocator, provider: *const config.Provider, body: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const params = try parseAnthropicMessages(arena, provider, body);
    return providers.forKind(.openai_compat).buildRequest(gpa, params);
}

pub fn openaiCompletion(gpa: std.mem.Allocator, model: []const u8, resp: types.ChatResponse) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var s = json.Stringify{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("id");
    try s.write("chatcmpl-clanker");
    try s.objectField("object");
    try s.write("chat.completion");
    try s.objectField("created");
    try s.write(0);
    try s.objectField("model");
    try s.write(model);
    try s.objectField("choices");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("index");
    try s.write(0);
    try s.objectField("message");
    try writeOpenaiMessage(&s, resp.message);
    try s.objectField("finish_reason");
    try s.write(openaiFinish(resp.finish_reason));
    try s.endObject();
    try s.endArray();
    if (resp.usage) |u| {
        try s.objectField("usage");
        try writeOpenaiUsage(&s, u);
    }
    try s.endObject();
    return out.toOwnedSlice();
}

pub fn anthropicMessage(gpa: std.mem.Allocator, model: []const u8, resp: types.ChatResponse) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var s = json.Stringify{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("id");
    try s.write("msg_clanker");
    try s.objectField("type");
    try s.write("message");
    try s.objectField("role");
    try s.write("assistant");
    try s.objectField("model");
    try s.write(model);
    try s.objectField("content");
    try s.beginArray();
    if (resp.message.content) |c| {
        if (c.len > 0) {
            try s.beginObject();
            try s.objectField("type");
            try s.write("text");
            try s.objectField("text");
            try s.write(c);
            try s.endObject();
        }
    }
    if (resp.message.tool_calls) |calls| {
        for (calls) |tc| {
            try s.beginObject();
            try s.objectField("type");
            try s.write("tool_use");
            try s.objectField("id");
            try s.write(tc.id);
            try s.objectField("name");
            try s.write(tc.name);
            try s.objectField("input");
            const parsed = json.parseFromSliceLeaky(json.Value, gpa, tc.arguments, .{}) catch json.Value{ .object = .empty };
            try s.write(parsed);
            try s.endObject();
        }
    }
    try s.endArray();
    try s.objectField("stop_reason");
    try s.write(anthropicStop(resp.finish_reason));
    if (resp.usage) |u| {
        try s.objectField("usage");
        try s.beginObject();
        try s.objectField("input_tokens");
        try s.write(u.prompt_cache_miss_tokens);
        try s.objectField("output_tokens");
        try s.write(u.completion_tokens);
        try s.objectField("cache_read_input_tokens");
        try s.write(u.prompt_cache_hit_tokens);
        try s.endObject();
    }
    try s.endObject();
    return out.toOwnedSlice();
}

pub const OpenaiStream = struct {
    model: []const u8,
    sent_role: bool = false,

    pub fn writeEvent(self: *OpenaiStream, gpa: std.mem.Allocator, ev: providers.StreamEvent) !?[]u8 {
        if (ev.done) return try std.fmt.allocPrint(gpa, "data: [DONE]\n\n", .{});
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        try out.writer.writeAll("data: ");
        var s = json.Stringify{ .writer = &out.writer };
        try s.beginObject();
        try s.objectField("id");
        try s.write("chatcmpl-clanker");
        try s.objectField("object");
        try s.write("chat.completion.chunk");
        try s.objectField("created");
        try s.write(0);
        try s.objectField("model");
        try s.write(self.model);
        try s.objectField("choices");
        try s.beginArray();
        try s.beginObject();
        try s.objectField("index");
        try s.write(0);
        try s.objectField("delta");
        try s.beginObject();
        if (!self.sent_role) {
            try s.objectField("role");
            try s.write("assistant");
            self.sent_role = true;
        }
        if (ev.text) |t| {
            try s.objectField("content");
            try s.write(t);
        }
        if (ev.tool_calls.len > 0) {
            try s.objectField("tool_calls");
            try s.beginArray();
            for (ev.tool_calls) |tc| {
                try s.beginObject();
                try s.objectField("index");
                try s.write(tc.index);
                if (tc.id) |id| {
                    try s.objectField("id");
                    try s.write(id);
                }
                try s.objectField("type");
                try s.write("function");
                try s.objectField("function");
                try s.beginObject();
                if (tc.name) |n| {
                    try s.objectField("name");
                    try s.write(n);
                }
                if (tc.arguments) |a| {
                    try s.objectField("arguments");
                    try s.write(a);
                }
                try s.endObject();
                try s.endObject();
            }
            try s.endArray();
        }
        try s.endObject();
        try s.objectField("finish_reason");
        if (ev.finish_reason) |fr| {
            try s.write(openaiFinish(fr));
        } else {
            try s.write(null);
        }
        try s.endObject();
        try s.endArray();
        if (ev.usage) |upd| {
            var acc = types.Usage{};
            upd.apply(&acc);
            try s.objectField("usage");
            try writeOpenaiUsage(&s, acc);
        }
        try s.endObject();
        try out.writer.writeAll("\n\n");
        return try out.toOwnedSlice();
    }
};

/// OpenAI (or Vertex) stream events rewritten as Anthropic SSE so Claude Code
/// can sit on `/v1/messages` in front of an openai_compat backend.
pub const AnthropicStream = struct {
    model: []const u8,
    started: bool = false,
    finished: bool = false,
    text_open: bool = false,
    tool_open: bool = false,
    next_index: usize = 0,
    block_index: usize = 0,

    pub fn writeEvent(self: *AnthropicStream, gpa: std.mem.Allocator, ev: providers.StreamEvent) !?[]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        if (!self.started) {
            try emitMessageStart(&out.writer, self.model);
            self.started = true;
        }
        if (ev.text) |t| {
            if (self.tool_open) {
                try emitBlockStop(&out.writer, self.block_index);
                self.tool_open = false;
            }
            if (!self.text_open) {
                self.block_index = self.next_index;
                self.next_index += 1;
                try emitTextStart(&out.writer, self.block_index);
                self.text_open = true;
            }
            try emitTextDelta(&out.writer, self.block_index, t);
        }
        for (ev.tool_calls) |tc| {
            if (self.text_open) {
                try emitBlockStop(&out.writer, self.block_index);
                self.text_open = false;
            }
            if (tc.id != null or tc.name != null) {
                if (self.tool_open) {
                    try emitBlockStop(&out.writer, self.block_index);
                }
                self.block_index = tc.index;
                if (self.next_index <= tc.index) self.next_index = tc.index + 1;
                try emitToolStart(&out.writer, tc.index, tc.id orelse "", tc.name orelse "");
                self.tool_open = true;
            }
            if (tc.arguments) |a| {
                if (!self.tool_open) {
                    self.block_index = tc.index;
                    try emitToolStart(&out.writer, tc.index, tc.id orelse "", tc.name orelse "");
                    self.tool_open = true;
                }
                try emitToolDelta(&out.writer, tc.index, a);
            }
        }
        if ((ev.finish_reason != null or ev.done) and !self.finished) {
            if (self.text_open or self.tool_open) {
                try emitBlockStop(&out.writer, self.block_index);
                self.text_open = false;
                self.tool_open = false;
            }
            const stop = anthropicStop(ev.finish_reason);
            try emitMessageDelta(&out.writer, stop, ev.usage);
            try emitRaw(&out.writer, "message_stop", "{\"type\":\"message_stop\"}");
            self.finished = true;
            return try out.toOwnedSlice();
        }
        if (self.finished) return null;
        if (out.written().len == 0) return null;
        return try out.toOwnedSlice();
    }
};

fn emitMessageStart(w: *std.Io.Writer, model: []const u8) !void {
    try w.writeAll("event: message_start\ndata: ");
    var s = json.Stringify{ .writer = w };
    try s.beginObject();
    try s.objectField("type");
    try s.write("message_start");
    try s.objectField("message");
    try s.beginObject();
    try s.objectField("id");
    try s.write("msg_clanker");
    try s.objectField("type");
    try s.write("message");
    try s.objectField("role");
    try s.write("assistant");
    try s.objectField("content");
    try s.beginArray();
    try s.endArray();
    try s.objectField("model");
    try s.write(model);
    try s.objectField("stop_reason");
    try s.write(null);
    try s.objectField("usage");
    try s.beginObject();
    try s.objectField("input_tokens");
    try s.write(0);
    try s.objectField("output_tokens");
    try s.write(0);
    try s.endObject();
    try s.endObject();
    try s.endObject();
    try w.writeAll("\n\n");
}

fn emitTextStart(w: *std.Io.Writer, index: usize) !void {
    try w.print("event: content_block_start\ndata: {{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n", .{index});
}

fn emitTextDelta(w: *std.Io.Writer, index: usize, text: []const u8) !void {
    try w.writeAll("event: content_block_delta\ndata: ");
    var s = json.Stringify{ .writer = w };
    try s.beginObject();
    try s.objectField("type");
    try s.write("content_block_delta");
    try s.objectField("index");
    try s.write(index);
    try s.objectField("delta");
    try s.beginObject();
    try s.objectField("type");
    try s.write("text_delta");
    try s.objectField("text");
    try s.write(text);
    try s.endObject();
    try s.endObject();
    try w.writeAll("\n\n");
}

fn emitToolStart(w: *std.Io.Writer, index: usize, id: []const u8, name: []const u8) !void {
    try w.writeAll("event: content_block_start\ndata: ");
    var s = json.Stringify{ .writer = w };
    try s.beginObject();
    try s.objectField("type");
    try s.write("content_block_start");
    try s.objectField("index");
    try s.write(index);
    try s.objectField("content_block");
    try s.beginObject();
    try s.objectField("type");
    try s.write("tool_use");
    try s.objectField("id");
    try s.write(id);
    try s.objectField("name");
    try s.write(name);
    try s.objectField("input");
    try s.beginObject();
    try s.endObject();
    try s.endObject();
    try s.endObject();
    try w.writeAll("\n\n");
}

fn emitToolDelta(w: *std.Io.Writer, index: usize, partial: []const u8) !void {
    try w.writeAll("event: content_block_delta\ndata: ");
    var s = json.Stringify{ .writer = w };
    try s.beginObject();
    try s.objectField("type");
    try s.write("content_block_delta");
    try s.objectField("index");
    try s.write(index);
    try s.objectField("delta");
    try s.beginObject();
    try s.objectField("type");
    try s.write("input_json_delta");
    try s.objectField("partial_json");
    try s.write(partial);
    try s.endObject();
    try s.endObject();
    try w.writeAll("\n\n");
}

fn emitBlockStop(w: *std.Io.Writer, index: usize) !void {
    try w.print("event: content_block_stop\ndata: {{\"type\":\"content_block_stop\",\"index\":{d}}}\n\n", .{index});
}

fn emitMessageDelta(w: *std.Io.Writer, stop: []const u8, usage: ?providers.UsageUpdate) !void {
    try w.writeAll("event: message_delta\ndata: ");
    var s = json.Stringify{ .writer = w };
    try s.beginObject();
    try s.objectField("type");
    try s.write("message_delta");
    try s.objectField("delta");
    try s.beginObject();
    try s.objectField("stop_reason");
    try s.write(stop);
    try s.endObject();
    if (usage) |upd| {
        var acc = types.Usage{};
        upd.apply(&acc);
        try s.objectField("usage");
        try s.beginObject();
        try s.objectField("output_tokens");
        try s.write(acc.completion_tokens);
        try s.endObject();
    }
    try s.endObject();
    try w.writeAll("\n\n");
}

fn emitRaw(w: *std.Io.Writer, event: []const u8, data: []const u8) !void {
    try w.print("event: {s}\ndata: {s}\n\n", .{ event, data });
}

pub fn ssePayloads(frame: []const u8, dest: *std.ArrayList([]const u8), gpa: std.mem.Allocator) !void {
    var it = std.mem.splitScalar(u8, frame, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const payload = std.mem.trimStart(u8, line["data:".len..], " ");
        if (payload.len == 0) continue;
        try dest.append(gpa, payload);
    }
}

fn writeOpenaiMessage(s: *json.Stringify, msg: types.Message) !void {
    try s.beginObject();
    try s.objectField("role");
    try s.write("assistant");
    try s.objectField("content");
    if (msg.content) |c| try s.write(c) else try s.write(null);
    if (msg.tool_calls) |calls| {
        try s.objectField("tool_calls");
        try openai.writeToolCalls(s, calls);
    }
    try s.endObject();
}

fn writeOpenaiUsage(s: *json.Stringify, u: types.Usage) !void {
    try s.beginObject();
    try s.objectField("prompt_tokens");
    try s.write(u.prompt_tokens);
    try s.objectField("completion_tokens");
    try s.write(u.completion_tokens);
    try s.objectField("total_tokens");
    try s.write(if (u.total_tokens > 0) u.total_tokens else u.prompt_tokens +| u.completion_tokens);
    try s.endObject();
}

fn openaiFinish(reason: ?[]const u8) []const u8 {
    const r = reason orelse return "stop";
    if (std.mem.eql(u8, r, "tool_use") or std.mem.eql(u8, r, "tool_calls")) return "tool_calls";
    if (std.mem.eql(u8, r, "max_tokens") or std.mem.eql(u8, r, "length")) return "length";
    if (std.mem.eql(u8, r, "end_turn") or std.mem.eql(u8, r, "stop")) return "stop";
    return r;
}

fn anthropicStop(reason: ?[]const u8) []const u8 {
    const r = reason orelse return "end_turn";
    if (std.mem.eql(u8, r, "tool_calls") or std.mem.eql(u8, r, "tool_use")) return "tool_use";
    if (std.mem.eql(u8, r, "length") or std.mem.eql(u8, r, "max_tokens")) return "max_tokens";
    if (std.mem.eql(u8, r, "stop") or std.mem.eql(u8, r, "end_turn")) return "end_turn";
    return r;
}

fn parseOpenaiChat(arena: std.mem.Allocator, provider: *const config.Provider, body: []const u8) !providers.RequestParams {
    const root = json.parseFromSliceLeaky(json.Value, arena, body, .{}) catch return error.Malformed;
    const obj = switch (root) {
        .object => |o| o,
        else => return error.Malformed,
    };
    const msgs_val = obj.get("messages") orelse return error.Malformed;
    const msgs_arr = switch (msgs_val) {
        .array => |a| a,
        else => return error.Malformed,
    };
    var messages: std.ArrayList(types.Message) = .empty;
    for (msgs_arr.items) |item| {
        try messages.append(arena, try parseOpenaiMessage(arena, item));
    }
    var tools: ?[]const types.ToolDef = null;
    if (obj.get("tools")) |tv| {
        tools = try parseOpenaiTools(arena, tv);
    }
    return .{
        .provider = provider,
        .messages = try messages.toOwnedSlice(arena),
        .tools = tools,
        .temperature = jsonF64(obj.get("temperature")),
        .top_p = jsonF64(obj.get("top_p")),
        .max_tokens = jsonU32(obj.get("max_tokens")) orelse jsonU32(obj.get("max_completion_tokens")),
        .response_format_json = isJsonObjectFormat(obj.get("response_format")),
        .stream = jsonBool(obj.get("stream")) orelse false,
    };
}

fn parseAnthropicMessages(arena: std.mem.Allocator, provider: *const config.Provider, body: []const u8) !providers.RequestParams {
    const root = json.parseFromSliceLeaky(json.Value, arena, body, .{}) catch return error.Malformed;
    const obj = switch (root) {
        .object => |o| o,
        else => return error.Malformed,
    };
    var messages: std.ArrayList(types.Message) = .empty;
    if (obj.get("system")) |sys| {
        if (try systemText(arena, sys)) |text| {
            try messages.append(arena, .{ .role = .system, .content = text });
        }
    }
    const msgs_val = obj.get("messages") orelse return error.Malformed;
    const msgs_arr = switch (msgs_val) {
        .array => |a| a,
        else => return error.Malformed,
    };
    for (msgs_arr.items) |item| {
        try appendAnthropicMessage(arena, &messages, item);
    }
    var tools: ?[]const types.ToolDef = null;
    if (obj.get("tools")) |tv| {
        tools = try parseAnthropicTools(arena, tv);
    }
    return .{
        .provider = provider,
        .messages = try messages.toOwnedSlice(arena),
        .tools = tools,
        .temperature = jsonF64(obj.get("temperature")),
        .top_p = jsonF64(obj.get("top_p")),
        .max_tokens = jsonU32(obj.get("max_tokens")),
        .stream = jsonBool(obj.get("stream")) orelse false,
    };
}

fn parseOpenaiMessage(arena: std.mem.Allocator, v: json.Value) !types.Message {
    const obj = switch (v) {
        .object => |o| o,
        else => return error.Malformed,
    };
    const role_s = switch (obj.get("role") orelse return error.Malformed) {
        .string => |s| s,
        else => return error.Malformed,
    };
    const role: types.Role = if (std.mem.eql(u8, role_s, "system"))
        .system
    else if (std.mem.eql(u8, role_s, "assistant"))
        .assistant
    else if (std.mem.eql(u8, role_s, "tool"))
        .tool
    else
        .user;

    var msg = types.Message{ .role = role };
    if (obj.get("tool_call_id")) |tid| {
        msg.tool_call_id = switch (tid) {
            .string => |s| s,
            else => null,
        };
    }
    if (obj.get("tool_calls")) |tcv| {
        msg.tool_calls = try parseOpenaiToolCalls(arena, tcv);
    }
    if (obj.get("content")) |cv| {
        switch (cv) {
            .string => |s| msg.content = s,
            .null => {},
            .array => |arr| {
                var text: std.ArrayList(u8) = .empty;
                var images: std.ArrayList(types.ImagePart) = .empty;
                for (arr.items) |part| {
                    const po = switch (part) {
                        .object => |o| o,
                        else => continue,
                    };
                    const typ = switch (po.get("type") orelse continue) {
                        .string => |s| s,
                        else => continue,
                    };
                    if (std.mem.eql(u8, typ, "text")) {
                        if (po.get("text")) |t| switch (t) {
                            .string => |s| try text.appendSlice(arena, s),
                            else => {},
                        };
                    } else if (std.mem.eql(u8, typ, "image_url")) {
                        if (imageFromOpenai(po.get("image_url"))) |img| try images.append(arena, img);
                    }
                }
                if (text.items.len > 0) msg.content = try text.toOwnedSlice(arena);
                if (images.items.len > 0) msg.images = try images.toOwnedSlice(arena);
            },
            else => {},
        }
    }
    return msg;
}

fn parseOpenaiToolCalls(arena: std.mem.Allocator, v: json.Value) ![]const types.ToolCall {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.Malformed,
    };
    var out: std.ArrayList(types.ToolCall) = .empty;
    for (arr.items) |item| {
        const o = switch (item) {
            .object => |m| m,
            else => continue,
        };
        const id = switch (o.get("id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const fn_obj = switch (o.get("function") orelse continue) {
            .object => |m| m,
            else => continue,
        };
        const name = switch (fn_obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const args = if (fn_obj.get("arguments")) |a| switch (a) {
            .string => |s| s,
            else => "{}",
        } else "{}";
        try out.append(arena, .{ .id = id, .name = name, .arguments = args });
    }
    return out.toOwnedSlice(arena);
}

fn parseOpenaiTools(arena: std.mem.Allocator, v: json.Value) ![]const types.ToolDef {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.Malformed,
    };
    var out: std.ArrayList(types.ToolDef) = .empty;
    for (arr.items) |item| {
        const o = switch (item) {
            .object => |m| m,
            else => continue,
        };
        const fn_obj = switch (o.get("function") orelse continue) {
            .object => |m| m,
            else => continue,
        };
        const name = switch (fn_obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const desc = if (fn_obj.get("description")) |d| switch (d) {
            .string => |s| s,
            else => "",
        } else "";
        const schema = fn_obj.get("parameters") orelse json.Value{ .object = .empty };
        try out.append(arena, .{ .name = name, .description = desc, .input_schema = schema });
    }
    return out.toOwnedSlice(arena);
}

fn imageFromOpenai(v: ?json.Value) ?types.ImagePart {
    const val = v orelse return null;
    const url = switch (val) {
        .string => |s| s,
        .object => |o| switch (o.get("url") orelse return null) {
            .string => |s| s,
            else => return null,
        },
        else => return null,
    };
    return parseDataUri(url);
}

fn parseDataUri(url: []const u8) ?types.ImagePart {
    if (!std.mem.startsWith(u8, url, "data:")) return null;
    const rest = url["data:".len..];
    const comma = std.mem.findScalar(u8, rest, ',') orelse return null;
    const meta = rest[0..comma];
    const b64 = rest[comma + 1 ..];
    const semi = std.mem.findScalar(u8, meta, ';') orelse return null;
    return .{ .mime = meta[0..semi], .b64 = b64 };
}

fn appendAnthropicMessage(arena: std.mem.Allocator, messages: *std.ArrayList(types.Message), v: json.Value) !void {
    const obj = switch (v) {
        .object => |o| o,
        else => return,
    };
    const role_s = switch (obj.get("role") orelse return) {
        .string => |s| s,
        else => return,
    };
    const content = obj.get("content") orelse return;
    switch (content) {
        .string => |s| {
            const role: types.Role = if (std.mem.eql(u8, role_s, "assistant")) .assistant else .user;
            try messages.append(arena, .{ .role = role, .content = s });
        },
        .array => |arr| {
            var text: std.ArrayList(u8) = .empty;
            var images: std.ArrayList(types.ImagePart) = .empty;
            var calls: std.ArrayList(types.ToolCall) = .empty;
            var results: std.ArrayList(types.Message) = .empty;
            for (arr.items) |part| {
                const po = switch (part) {
                    .object => |o| o,
                    else => continue,
                };
                const typ = switch (po.get("type") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                if (std.mem.eql(u8, typ, "text")) {
                    if (po.get("text")) |t| switch (t) {
                        .string => |s| try text.appendSlice(arena, s),
                        else => {},
                    };
                } else if (std.mem.eql(u8, typ, "image")) {
                    if (imageFromAnthropic(po.get("source"))) |img| try images.append(arena, img);
                } else if (std.mem.eql(u8, typ, "tool_use")) {
                    const id = switch (po.get("id") orelse continue) {
                        .string => |s| s,
                        else => continue,
                    };
                    const name = switch (po.get("name") orelse continue) {
                        .string => |s| s,
                        else => continue,
                    };
                    var args_w: std.Io.Writer.Allocating = .init(arena);
                    if (po.get("input")) |inp| try json.Stringify.value(inp, .{}, &args_w.writer);
                    const args = args_w.written();
                    try calls.append(arena, .{ .id = id, .name = name, .arguments = if (args.len > 0) args else "{}" });
                } else if (std.mem.eql(u8, typ, "tool_result")) {
                    const tid = switch (po.get("tool_use_id") orelse continue) {
                        .string => |s| s,
                        else => continue,
                    };
                    const c = try toolResultText(arena, po.get("content"));
                    try results.append(arena, .{ .role = .tool, .content = c, .tool_call_id = tid });
                }
            }
            if (std.mem.eql(u8, role_s, "assistant") or text.items.len > 0 or calls.items.len > 0 or images.items.len > 0) {
                const role: types.Role = if (std.mem.eql(u8, role_s, "assistant")) .assistant else .user;
                try messages.append(arena, .{
                    .role = role,
                    .content = if (text.items.len > 0) try text.toOwnedSlice(arena) else null,
                    .images = if (images.items.len > 0) try images.toOwnedSlice(arena) else null,
                    .tool_calls = if (calls.items.len > 0) try calls.toOwnedSlice(arena) else null,
                });
            }
            for (results.items) |m| try messages.append(arena, m);
        },
        else => {},
    }
}

fn imageFromAnthropic(v: ?json.Value) ?types.ImagePart {
    const val = v orelse return null;
    const o = switch (val) {
        .object => |m| m,
        else => return null,
    };
    const mime = switch (o.get("media_type") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    const data = switch (o.get("data") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    return .{ .mime = mime, .b64 = data };
}

fn toolResultText(arena: std.mem.Allocator, v: ?json.Value) ![]const u8 {
    const val = v orelse return "";
    return switch (val) {
        .string => |s| s,
        .array => |arr| blk: {
            var text: std.ArrayList(u8) = .empty;
            for (arr.items) |part| {
                const o = switch (part) {
                    .object => |m| m,
                    else => continue,
                };
                if (o.get("text")) |t| switch (t) {
                    .string => |s| try text.appendSlice(arena, s),
                    else => {},
                };
            }
            break :blk try text.toOwnedSlice(arena);
        },
        else => "",
    };
}

fn systemText(arena: std.mem.Allocator, v: json.Value) !?[]const u8 {
    return switch (v) {
        .string => |s| s,
        .array => |arr| blk: {
            var text: std.ArrayList(u8) = .empty;
            for (arr.items) |part| {
                const o = switch (part) {
                    .object => |m| m,
                    else => continue,
                };
                if (o.get("text")) |t| switch (t) {
                    .string => |s| try text.appendSlice(arena, s),
                    else => {},
                };
            }
            if (text.items.len == 0) break :blk null;
            break :blk try text.toOwnedSlice(arena);
        },
        else => null,
    };
}

fn parseAnthropicTools(arena: std.mem.Allocator, v: json.Value) ![]const types.ToolDef {
    const arr = switch (v) {
        .array => |a| a,
        else => return error.Malformed,
    };
    var out: std.ArrayList(types.ToolDef) = .empty;
    for (arr.items) |item| {
        const o = switch (item) {
            .object => |m| m,
            else => continue,
        };
        const name = switch (o.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const desc = if (o.get("description")) |d| switch (d) {
            .string => |s| s,
            else => "",
        } else "";
        const schema = o.get("input_schema") orelse json.Value{ .object = .empty };
        try out.append(arena, .{ .name = name, .description = desc, .input_schema = schema });
    }
    return out.toOwnedSlice(arena);
}

fn isJsonObjectFormat(v: ?json.Value) bool {
    const val = v orelse return false;
    const o = switch (val) {
        .object => |m| m,
        else => return false,
    };
    return switch (o.get("type") orelse return false) {
        .string => |s| std.mem.eql(u8, s, "json_object"),
        else => false,
    };
}

fn jsonBool(v: ?json.Value) ?bool {
    return switch (v orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

fn jsonF64(v: ?json.Value) ?f64 {
    return switch (v orelse return null) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

pub fn jsonU32(v: ?json.Value) ?u32 {
    return switch (v orelse return null) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
        else => null,
    };
}

// ------------------------------------------------------------------- tests --

test "openai chat transcodes to anthropic messages and vertex body" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const provider = try config.Provider.single(arena, "vertex", "https://example", .vertex_anthropic, "claude-sonnet-4", .{});

    const body =
        \\{"model":"claude-sonnet-4","messages":[{"role":"system","content":"be brief"},{"role":"user","content":"hi"}],"tools":[{"type":"function","function":{"name":"read","description":"read a file","parameters":{"type":"object"}}}],"stream":true,"max_tokens":64}
    ;
    const anth = try openaiToAnthropic(gpa, &provider, body, false);
    defer gpa.free(anth);
    try std.testing.expect(std.mem.find(u8, anth, "\"model\"") != null);
    try std.testing.expect(std.mem.find(u8, anth, "\"stream\":true") != null);
    try std.testing.expect(std.mem.find(u8, anth, "\"name\":\"read\"") != null);
    try std.testing.expect(std.mem.find(u8, anth, "stream_options") == null);
    try std.testing.expect(std.mem.find(u8, anth, "be brief") != null);

    const vtx = try openaiToAnthropic(gpa, &provider, body, true);
    defer gpa.free(vtx);
    try std.testing.expect(std.mem.find(u8, vtx, "anthropic_version") != null);
    try std.testing.expect(std.mem.find(u8, vtx, vertex_anthropic.body_version) != null);
    try std.testing.expect(std.mem.find(u8, vtx, "\"model\"") == null);
}

test "rewriteVertexBody keeps extra keys and swaps model for anthropic_version" {
    const gpa = std.testing.allocator;
    const out = try rewriteVertexBody(gpa, "{\"model\":\"claude-x\",\"messages\":[],\"foo\":1}");
    defer gpa.free(out);
    try std.testing.expect(std.mem.find(u8, out, "anthropic_version") != null);
    try std.testing.expect(std.mem.find(u8, out, "\"foo\":1") != null);
    try std.testing.expect(std.mem.find(u8, out, "\"model\"") == null);
}

test "openaiCompletion maps tool_use to tool_calls" {
    const gpa = std.testing.allocator;
    const body = try openaiCompletion(gpa, "claude-sonnet-4", .{
        .message = .{
            .role = .assistant,
            .content = "ok",
            .tool_calls = &.{.{ .id = "toolu_1", .name = "read", .arguments = "{\"p\":\"a\"}" }},
        },
        .finish_reason = "tool_use",
        .usage = .{ .prompt_tokens = 10, .completion_tokens = 4, .total_tokens = 14 },
    });
    defer gpa.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_calls\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"finish_reason\":\"tool_calls\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "chat.completion") != null);
}

test "OpenaiStream emits role then content then DONE" {
    const gpa = std.testing.allocator;
    var st = OpenaiStream{ .model = "m" };
    const a = (try st.writeEvent(gpa, .{ .text = "He" })).?;
    defer gpa.free(a);
    try std.testing.expect(std.mem.find(u8, a, "\"role\":\"assistant\"") != null);
    try std.testing.expect(std.mem.find(u8, a, "\"content\":\"He\"") != null);
    const b = (try st.writeEvent(gpa, .{ .text = "llo" })).?;
    defer gpa.free(b);
    try std.testing.expect(std.mem.find(u8, b, "\"role\"") == null);
    const d = (try st.writeEvent(gpa, .{ .done = true })).?;
    defer gpa.free(d);
    try std.testing.expectEqualStrings("data: [DONE]\n\n", d);
}

test "AnthropicStream emits message_start, text deltas, and message_stop" {
    const gpa = std.testing.allocator;
    var st = AnthropicStream{ .model = "claude-sonnet-4" };
    const a = (try st.writeEvent(gpa, .{ .text = "Hi" })).?;
    defer gpa.free(a);
    try std.testing.expect(std.mem.find(u8, a, "event: message_start") != null);
    try std.testing.expect(std.mem.find(u8, a, "event: content_block_delta") != null);
    try std.testing.expect(std.mem.find(u8, a, "text_delta") != null);
    const b = (try st.writeEvent(gpa, .{ .done = true })).?;
    defer gpa.free(b);
    try std.testing.expect(std.mem.find(u8, b, "event: message_stop") != null);
    try std.testing.expect(try st.writeEvent(gpa, .{ .done = true }) == null);
}

test "openaiCompletion saturates total_tokens instead of overflowing" {
    const gpa = std.testing.allocator;
    const body = try openaiCompletion(gpa, "m", .{
        .message = .{ .role = .assistant, .content = "" },
        .finish_reason = "stop",
        .usage = .{ .prompt_tokens = std.math.maxInt(u32) - 1, .completion_tokens = 2, .total_tokens = 0 },
    });
    defer gpa.free(body);
    try std.testing.expect(std.mem.find(u8, body, "4294967295") != null);
}
