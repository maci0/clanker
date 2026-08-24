//! Shared OpenAI Responses wire codec used by the Codex and Grok plugins.

const std = @import("std");
const api = @import("api.zig");
const common = @import("common.zig");
const types = @import("../types.zig");

pub const BuildOptions = struct {
    /// Send a completion budget. Off for Codex, whose ChatGPT subscription
    /// endpoint rejects it.
    max_output_tokens: bool = true,
    /// Resolve `temperature`/`top_p` and fill the reasoning effort from the
    /// full three-tier chain (per-run override, then model config, then the
    /// PRD 0024 use-case table). Off for Codex, which rejects the sampling
    /// pair; its effort then stays whatever the per-run override pinned, with
    /// no table fill, which is the behaviour its own test asserts.
    sampling: bool = true,
};

pub fn buildRequest(gpa: std.mem.Allocator, params: api.RequestParams) api.BuildError![]u8 {
    return buildWithOptions(gpa, params, .{});
}

pub fn buildWithOptions(gpa: std.mem.Allocator, params: api.RequestParams, options: BuildOptions) api.BuildError![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("model");
    try s.write(params.provider.wireModelName());
    try s.objectField("store");
    try s.write(false);
    try s.objectField("stream");
    try s.write(params.stream);
    // The three-tier chain, not `params` alone. The agent loop never sets
    // `params.temperature`/`top_p` and the webui's per-run override writes
    // into the provider's models map, so reading only `params` discarded both
    // the configured per-model value and PRD 0024's table on every turn
    // ([bug](../../../docs/reports/bugs/2026-08-23-grok-kind-drops-model-sampling.md)).
    const rec = common.resolveSampling(params);
    if (options.max_output_tokens) {
        // `clampedMaxTokens`, so the half-the-context-window clamp applies
        // here as it does on the chat-completions wire.
        try s.objectField("max_output_tokens");
        try s.print("{d}", .{common.clampedMaxTokens(params)});
    }
    if (options.sampling) if (rec.temperature) |value| {
        try s.objectField("temperature");
        try s.print("{d}", .{value});
    };
    if (options.sampling) if (rec.top_p) |value| {
        try s.objectField("top_p");
        try s.print("{d}", .{value});
    };
    if (params.response_format_json) {
        try s.objectField("text");
        try s.beginObject();
        try s.objectField("format");
        try s.beginObject();
        try s.objectField("type");
        try s.write("json_object");
        try s.endObject();
        try s.endObject();
    }
    // The Responses API's own nested shape, so this codec spells the field
    // itself rather than going through `writeSamplingParams` — which would
    // write the flat OpenAI field for these kinds. Codex keeps the per-run
    // pin only; Grok also takes the config and table tiers.
    const effort = if (options.sampling) rec.reasoning_effort else params.reasoning_effort;
    if (effort) |value| {
        try s.objectField("reasoning");
        try s.beginObject();
        try s.objectField("effort");
        try s.write(value);
        try s.endObject();
    }
    try s.objectField("input");
    try s.beginArray();
    for (params.messages) |m| {
        if (m.role == .tool) {
            try s.beginObject();
            try s.objectField("type");
            try s.write("function_call_output");
            try s.objectField("call_id");
            try s.write(m.tool_call_id orelse "");
            try s.objectField("output");
            try s.write(m.content orelse "");
            try s.endObject();
            continue;
        }
        try s.beginObject();
        try s.objectField("role");
        try s.write(m.role.asStr());
        try s.objectField("content");
        if (m.images) |images| {
            try s.beginArray();
            if (m.content) |text| {
                try s.beginObject();
                try s.objectField("type");
                try s.write("input_text");
                try s.objectField("text");
                try s.write(text);
                try s.endObject();
            }
            for (images) |image| {
                const url = try std.fmt.allocPrint(gpa, "data:{s};base64,{s}", .{ image.mime, image.b64 });
                defer gpa.free(url);
                try s.beginObject();
                try s.objectField("type");
                try s.write("input_image");
                try s.objectField("image_url");
                try s.write(url);
                try s.endObject();
            }
            try s.endArray();
        } else try s.write(m.content orelse "");
        try s.endObject();
        if (m.tool_calls) |calls| for (calls) |call| {
            try s.beginObject();
            try s.objectField("type");
            try s.write("function_call");
            try s.objectField("call_id");
            try s.write(call.id);
            try s.objectField("name");
            try s.write(call.name);
            try s.objectField("arguments");
            try s.write(call.arguments);
            try s.endObject();
        };
    }
    try s.endArray();
    if (params.tools) |tools| {
        try s.objectField("tools");
        try s.beginArray();
        for (tools) |tool| {
            if (tool.internal) continue;
            try s.beginObject();
            try s.objectField("type");
            try s.write("function");
            try s.objectField("name");
            try s.write(tool.name);
            try s.objectField("description");
            try s.write(tool.description);
            try s.objectField("parameters");
            try s.write(tool.input_schema);
            try s.endObject();
        }
        try s.endArray();
    }
    try s.endObject();
    return out.toOwnedSlice();
}

fn string(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn uint(obj: std.json.ObjectMap, key: []const u8) u32 {
    const value = obj.get(key) orelse return 0;
    if (value != .integer or value.integer < 0) return 0;
    return std.math.cast(u32, value.integer) orelse 0;
}

fn usageUpdate(obj: std.json.ObjectMap) api.UsageUpdate {
    const input = uint(obj, "input_tokens");
    const output = uint(obj, "output_tokens");
    var cached: u32 = 0;
    if (obj.get("input_tokens_details")) |details| {
        if (details == .object) cached = uint(details.object, "cached_tokens");
    }
    return .{
        .prompt = .{ .tokens = input, .cache_hit_tokens = cached, .cache_miss_tokens = input -| cached },
        .completion = output,
        .total = uint(obj, "total_tokens"),
    };
}

pub fn parseResponse(arena: std.mem.Allocator, body: []const u8, err_detail: ?*?[]const u8) anyerror!types.ChatResponse {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{ .allocate = .alloc_always });
    if (root != .object) return error.BadResponse;
    if (root.object.get("error")) |e| if (e == .object) {
        if (err_detail) |d| d.* = string(e.object, "message");
        return error.ApiError;
    };
    var text: std.ArrayList(u8) = .empty;
    var calls: std.ArrayList(types.ToolCall) = .empty;
    if (root.object.get("output")) |output| if (output == .array) for (output.array.items) |item| {
        if (item != .object) continue;
        const kind = string(item.object, "type") orelse "";
        if (std.mem.eql(u8, kind, "function_call")) {
            try calls.append(arena, .{ .id = string(item.object, "call_id") orelse string(item.object, "id") orelse "", .name = string(item.object, "name") orelse "", .arguments = string(item.object, "arguments") orelse "{}" });
        } else if (std.mem.eql(u8, kind, "message")) {
            if (item.object.get("content")) |content| if (content == .array) for (content.array.items) |part| {
                if (part == .object and std.mem.eql(u8, string(part.object, "type") orelse "", "output_text"))
                    try text.appendSlice(arena, string(part.object, "text") orelse "");
            };
        }
    };
    var usage: ?types.Usage = null;
    if (root.object.get("usage")) |u| if (u == .object) {
        const update = usageUpdate(u.object);
        var value: types.Usage = .{};
        update.apply(&value);
        usage = value;
    };
    return .{ .message = .{ .role = .assistant, .content = if (text.items.len > 0) try text.toOwnedSlice(arena) else null, .tool_calls = if (calls.items.len > 0) try calls.toOwnedSlice(arena) else null }, .usage = usage, .finish_reason = string(root.object, "status"), .raw = body };
}

pub fn parseErrorDetail(arena: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    if (root != .object) return null;
    const e = root.object.get("error") orelse return null;
    return if (e == .object) string(e.object, "message") else null;
}

pub fn parseStreamEvent(arena: std.mem.Allocator, payload: []const u8) api.StreamParseError!?api.StreamEvent {
    if (std.mem.eql(u8, payload, "[DONE]")) return .{ .done = true };
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{}) catch return null;
    if (root != .object) return null;
    const kind = string(root.object, "type") orelse return null;
    if (std.mem.eql(u8, kind, "response.output_text.delta")) return .{ .text = string(root.object, "delta") };
    if (std.mem.eql(u8, kind, "response.output_item.added")) if (root.object.get("item")) |item| if (item == .object and std.mem.eql(u8, string(item.object, "type") orelse "", "function_call")) {
        const frag = try arena.alloc(api.ToolCallFragment, 1);
        frag[0] = .{ .index = @intCast(uint(root.object, "output_index")), .id = string(item.object, "call_id") orelse string(item.object, "id"), .name = string(item.object, "name") };
        return .{ .tool_calls = frag };
    };
    if (std.mem.eql(u8, kind, "response.function_call_arguments.delta")) {
        const frag = try arena.alloc(api.ToolCallFragment, 1);
        frag[0] = .{ .index = @intCast(uint(root.object, "output_index")), .arguments = string(root.object, "delta") };
        return .{ .tool_calls = frag };
    }
    if (std.mem.eql(u8, kind, "response.completed")) {
        var event: api.StreamEvent = .{ .finish_reason = "stop" };
        if (root.object.get("response")) |response| {
            if (response == .object) if (response.object.get("usage")) |usage| {
                if (usage == .object) event.usage = usageUpdate(usage.object);
            };
        }
        // Keep this frame foldable by the core; EOF or a following [DONE]
        // terminates the stream. Marking it done would discard its usage.
        return event;
    }
    return .{};
}

test "Responses codec maps text tools and usage into neutral types" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const response = try parseResponse(arena, "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]},{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"exec\",\"arguments\":\"{}\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":2,\"total_tokens\":12,\"input_tokens_details\":{\"cached_tokens\":4}}}", null);
    try std.testing.expectEqualStrings("hi", response.message.content.?);
    try std.testing.expectEqualStrings("exec", response.message.tool_calls.?[0].name);
    try std.testing.expectEqual(@as(u32, 4), response.usage.?.prompt_cache_hit_tokens);
}

test "Responses completed stream frame preserves final usage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const event = (try parseStreamEvent(arena_state.allocator(), "{\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":9,\"output_tokens\":3,\"total_tokens\":12}}}")).?;
    try std.testing.expect(!event.done);
    try std.testing.expectEqual(@as(u32, 12), event.usage.?.total.?);
}
